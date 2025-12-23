## Canonicalize tree-sitter CST to canonical AST
##
## This module converts tree-sitter CST nodes to our canonical AST
## representation. The canonical AST is designed to be structurally
## comparable with the AST derived from Nim compiler's PNode.

import std/[json, tables, strutils, options, sequtils]
import ../../tests/nim/ts_parser_bridge

type
  CanonProfile* = enum
    ## Canonicalization profile
    cpLossless  ## Minimal transformation, keep CST refs
    cpNim       ## Aggressive Nim-like canonicalization

  CanonError* = object
    ## Error during canonicalization
    message*: string
    path*: seq[string]
    nodeType*: string

  CanonResult* = object
    ## Result of canonicalization
    ast*: JsonNode
    errors*: seq[CanonError]

proc newSpan(node: Node): JsonNode =
  ## Create span object from tree-sitter node
  %*{
    "startByte": node.startByte,
    "endByte": node.endByte,
    "startPoint": {
      "row": node.startPoint.row,
      "column": node.startPoint.column
    },
    "endPoint": {
      "row": node.endPoint.row,
      "column": node.endPoint.column
    }
  }

proc addCstRef(result: var JsonNode, node: Node, profile: CanonProfile) =
  ## Add CST reference for debugging
  if profile == cpLossless:
    result["cst"] = %*{
      "nodeType": node.nodeType,
      "startByte": node.startByte,
      "endByte": node.endByte
    }

proc canonicalize*(node: Node, source: string, profile: CanonProfile = cpNim): JsonNode

proc getNamedChildren(node: Node): seq[Node] =
  ## Get all named children
  result = @[]
  for child in node.namedChildren:
    result.add child

proc getFieldNode(node: Node, fieldName: string): Option[Node] =
  ## Get child by field name
  node.childByFieldName(fieldName)

proc getFieldSkipTokens(node: Node, targetField: string): Option[Node] =
  ## Get a field value, skipping any `:` or `=` tokens
  ## This is needed because the grammar assigns fields to sequences that
  ## include delimiter tokens (e.g., _equals_suite = seq("=", suite))
  for i in 0 ..< node.childCount:
    let fieldName = node.fieldNameForChild(i)
    if fieldName == targetField:
      let child = node.child(i)
      # Skip delimiter tokens, get the actual content
      if child.nodeType notin ["=", ":"]:
        return some(child)
  none(Node)

proc getBodyField(node: Node): Option[Node] =
  ## Get the actual body field, skipping any `=` or `:` token
  getFieldSkipTokens(node, "body")

proc getAllBodyFields(node: Node): seq[Node] =
  ## Get ALL body fields (for routines with multi-statement bodies)
  ## Tree-sitter produces multiple body: fields when _suite contains multiple statements
  for i in 0 ..< node.childCount:
    let fieldName = node.fieldNameForChild(i)
    if fieldName == "body":
      let child = node.child(i)
      if child.nodeType notin ["=", ":"]:
        result.add child

proc unwrapExpression(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Unwrap expression wrapper nodes to get to the actual expression
  var current = node

  # Walk through expression wrappers
  while current.nodeType in ["expression", "infix_expression", "assign_expr",
                              "op2_expr", "or_expr", "and_expr", "cmp_expr",
                              "range_expr", "amp_expr", "add_expr", "mul_expr",
                              "pow_expr", "prefix_expr", "postfix_expr"]:
    # Check if this node has operator fields - if so, it's a real operation
    let opField = current.childByFieldName("operator")
    if opField.isSome:
      break

    # Otherwise, try to unwrap
    let children = current.getNamedChildren()
    if children.len == 1:
      current = children[0]
    else:
      break

  canonicalize(current, source, profile)

proc canonicalizeIdent(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize identifier
  let name = node.text

  result = %*{
    "kind": "Ident",
    "name": name,
    "span": newSpan(node)
  }
  result.addCstRef(node, profile)

proc canonicalizeQualifiedIdent(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize qualified identifier (a.b.c)
  var parts: seq[JsonNode] = @[]

  for child in node.namedChildren:
    if child.nodeType in ["symbol", "identifier"]:
      parts.add canonicalize(child, source, profile)

  if parts.len == 0:
    result = %*{"kind": "Empty", "span": newSpan(node)}
  elif parts.len == 1:
    result = parts[0]
  else:
    # Build a dotted chain (Dot(Dot(a, b), c)) to mirror Nim's nkDotExpr
    result = parts[0]
    for i in 1 ..< parts.len:
      result = %*{
        "kind": "Dot",
        "base": result,
        "field": parts[i],
        "span": newSpan(node)
      }
    result.addCstRef(node, profile)

proc stripTypeSuffix(text: string): string =
  ## Strip type suffix from numeric literal (both 'u64 and u64 styles)
  var cleanText = text
  # First check for apostrophe-style suffix (e.g., 123'u64)
  let apostropheIdx = cleanText.find('\'')
  if apostropheIdx >= 0:
    return cleanText[0 ..< apostropheIdx]
  # Check for no-apostrophe suffixes for integers: i8, i16, i32, i64, u8, u16, u32, u64
  # and for floats: f32, f64, f, d
  for suffix in ["u64", "u32", "u16", "u8", "i64", "i32", "i16", "i8", "f64", "f32", "f", "d"]:
    if cleanText.endsWith(suffix):
      return cleanText[0 ..< cleanText.len - suffix.len]
  return cleanText

proc parseIntLiteral(text: string): string =
  ## Parse integer literal and return normalized decimal string
  var cleanText = text.replace("_", "")
  cleanText = stripTypeSuffix(cleanText)

  try:
    if cleanText.startsWith("0x") or cleanText.startsWith("0X"):
      return $parseHexInt(cleanText)
    elif cleanText.startsWith("0b") or cleanText.startsWith("0B"):
      return $parseBinInt(cleanText)
    elif cleanText.startsWith("0o") or cleanText.startsWith("0O"):
      return $parseOctInt(cleanText)
    else:
      return $parseInt(cleanText)
  except:
    return cleanText

proc parseFloatLiteral(text: string): string =
  ## Parse float literal and return normalized string
  var cleanText = text.replace("_", "")
  cleanText = stripTypeSuffix(cleanText)

  try:
    let f = parseFloat(cleanText)
    return $f
  except:
    return cleanText

proc interpretEscapes(s: string): string =
  ## Interpret escape sequences in a string
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of 'n': result.add '\n'; i += 2
      of 'r': result.add '\r'; i += 2
      of 't': result.add '\t'; i += 2
      of '\\': result.add '\\'; i += 2
      of '"': result.add '"'; i += 2
      of '\'': result.add '\''; i += 2
      of '0': result.add '\0'; i += 2
      of 'a': result.add '\a'; i += 2
      of 'b': result.add '\b'; i += 2
      of 'f': result.add '\f'; i += 2
      of 'v': result.add '\v'; i += 2
      of 'e': result.add '\e'; i += 2
      of 'x':
        # Hex escape \xHH
        if i + 3 < s.len:
          try:
            let hexVal = parseHexInt("0x" & s[i+2..i+3])
            result.add chr(hexVal)
            i += 4
          except:
            result.add s[i]
            i += 1
        else:
          result.add s[i]
          i += 1
      else:
        result.add s[i]
        i += 1
    else:
      result.add s[i]
      i += 1

const standardTypeSuffixes = ["u64", "u32", "u16", "u8", "i64", "i32", "i16", "i8", "f64", "f32", "f", "d"]

proc getCustomSuffix(text: string): tuple[number: string, suffix: string] =
  ## Check if literal has a custom suffix (not a standard type suffix)
  ## Returns the number part and suffix, or empty suffix if standard or none
  let apostropheIdx = text.find('\'')
  if apostropheIdx < 0:
    return (text, "")

  let suffix = text[apostropheIdx + 1 .. ^1]
  let numberPart = text[0 ..< apostropheIdx]

  # Check if it's a standard type suffix
  for stdSuffix in standardTypeSuffixes:
    if suffix == stdSuffix:
      return (numberPart, "")  # Standard suffix, treat as regular literal

  # Custom suffix - return both parts
  return (numberPart, suffix)

proc canonizeLiteral(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize literal nodes
  let text = node.text

  case node.nodeType
  of "integer_literal":
    let (numberPart, customSuffix) = getCustomSuffix(text)
    if customSuffix.len > 0:
      # Custom literal suffix becomes a Dot expression: 10'kg -> 10.kg
      let intLit = %*{
        "kind": "IntLit",
        "value": parseIntLiteral(numberPart),
        "span": newSpan(node)
      }
      result = %*{
        "kind": "Dot",
        "base": intLit,
        "field": {"kind": "Ident", "name": customSuffix, "span": newSpan(node)},
        "span": newSpan(node)
      }
    else:
      result = %*{
        "kind": "IntLit",
        "value": parseIntLiteral(text),
        "span": newSpan(node)
      }

  of "float_literal":
    let (numberPart, customSuffix) = getCustomSuffix(text)
    if customSuffix.len > 0:
      # Custom literal suffix becomes a Dot expression
      let floatLit = %*{
        "kind": "FloatLit",
        "value": parseFloatLiteral(numberPart),
        "span": newSpan(node)
      }
      result = %*{
        "kind": "Dot",
        "base": floatLit,
        "field": {"kind": "Ident", "name": customSuffix, "span": newSpan(node)},
        "span": newSpan(node)
      }
    else:
      result = %*{
        "kind": "FloatLit",
        "value": parseFloatLiteral(text),
        "span": newSpan(node)
      }

  of "string_literal":
    result = %*{
      "kind": "StringLit",
      "value": interpretEscapes(text[1..^2]),  # Strip quotes and interpret escapes
      "span": newSpan(node)
    }

  of "raw_string_literal":
    result = %*{
      "kind": "StringLit",
      "value": text[2..^2],  # Strip r" and " - no escape interpretation
      "raw": true,
      "span": newSpan(node)
    }

  of "triple_string_literal":
    let val = if text.startsWith("r\"\"\"") or text.startsWith("R\"\"\""):
                text[4..^4]
              else:
                text[3..^4]
    result = %*{
      "kind": "StringLit",
      "value": val,
      "triple": true,
      "span": newSpan(node)
    }

  of "char_literal":
    result = %*{
      "kind": "CharLit",
      "value": interpretEscapes(text[1..^2]),  # Strip quotes and interpret escapes
      "span": newSpan(node)
    }

  of "nil_literal":
    result = %*{
      "kind": "NilLit",
      "span": newSpan(node)
    }

  of "boolean_literal":
    # Nim treats true/false as identifiers, not literals
    result = %*{
      "kind": "Ident",
      "name": text,
      "span": newSpan(node)
    }

  else:
    result = %*{
      "kind": "Unknown",
      "nodeType": node.nodeType,
      "text": text,
      "span": newSpan(node)
    }

  result.addCstRef(node, profile)

proc canonicalizeInfix(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize infix expression
  ## CST structure: first child is left operand, then alternating (operator, operand)
  ## e.g., add_expr: mul_expr (operator mul_expr)*

  var operands: seq[Node] = @[]
  var operators: seq[string] = @[]

  for i in 0 ..< node.childCount:
    let child = node.child(i)
    let fieldName = node.fieldNameForChild(i)

    if fieldName == "operator":
      operators.add child.text
    elif child.isNamed:
      operands.add child

  # If no operators found, this is just a wrapper - unwrap it
  if operators.len == 0:
    if operands.len == 1:
      return canonicalize(operands[0], source, profile)
    elif operands.len == 0:
      return %*{"kind": "Empty", "span": newSpan(node)}

  # Build left-associative chain of infix expressions
  result = canonicalize(operands[0], source, profile)

  for i in 0 ..< operators.len:
    let rightIdx = i + 1
    if rightIdx < operands.len:
      result = %*{
        "kind": "Infix",
        "operator": operators[i],
        "left": result,
        "right": canonicalize(operands[rightIdx], source, profile),
        "span": newSpan(node)
      }
      result.addCstRef(node, profile)

proc canonicalizePrefix(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize prefix expression
  let opField = node.childByFieldName("operator")
  let operandField = node.childByFieldName("operand")

  if opField.isNone or operandField.isNone:
    # Not a prefix, unwrap
    let children = node.getNamedChildren()
    if children.len == 1:
      return canonicalize(children[0], source, profile)
    return canonicalize(node.child(0), source, profile)

  let op = opField.get.text
  let operand = operandField.get

  # Check for negative integer/float literal folding
  # Nim folds -5 into a single IntLit with value "-5"
  if op == "-":
    let unwrapped = unwrapExpression(operand, source, profile)
    if unwrapped.hasKey("kind"):
      let kind = unwrapped["kind"].getStr
      if kind == "IntLit":
        result = %*{
          "kind": "IntLit",
          "value": "-" & unwrapped["value"].getStr,
          "span": newSpan(node)
        }
        result.addCstRef(node, profile)
        return
      elif kind == "FloatLit":
        result = %*{
          "kind": "FloatLit",
          "value": "-" & unwrapped["value"].getStr,
          "span": newSpan(node)
        }
        result.addCstRef(node, profile)
        return

  result = %*{
    "kind": "Prefix",
    "operator": op,
    "operand": canonicalize(operandField.get, source, profile),
    "span": newSpan(node)
  }
  result.addCstRef(node, profile)

proc canonicalizeCall(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize call expression
  var callee: JsonNode = nil
  var args: seq[JsonNode] = @[]

  # postfix_expr with call_suffix
  # Find the base and collect suffixes
  for i in 0 ..< node.namedChildCount:
    let child = node.namedChild(i)

    if child.nodeType == "call_suffix":
      # Process call arguments
      for arg in child.namedChildren:
        if arg.nodeType == "argument":
          args.add canonicalize(arg, source, profile)
        elif arg.nodeType == "expression":
          args.add canonicalize(arg, source, profile)
    elif callee == nil:
      callee = canonicalize(child, source, profile)

  if callee == nil:
    callee = %*{"kind": "Ident", "name": "", "span": newSpan(node)}

  result = %*{
    "kind": "Call",
    "callee": callee,
    "args": args,
    "span": newSpan(node)
  }
  result.addCstRef(node, profile)

proc canonicalizeCommand(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize command expression (no-paren call)
  let funcField = node.childByFieldName("function")
  var args: seq[JsonNode] = @[]

  for child in node.namedChildren:
    if child.nodeType in ["command_first_arg", "command_arg"]:
      args.add canonicalize(child, source, profile)

  result = %*{
    "kind": "Command",
    "callee": if funcField.isSome: canonicalize(funcField.get, source, profile)
              else: %*{"kind": "Ident", "name": "", "span": newSpan(node)},
    "args": args,
    "span": newSpan(node)
  }
  result.addCstRef(node, profile)

proc canonicalizeCallWithBlocks(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize call with trailing blocks (like echo "x": body)
  let callField = node.childByFieldName("call")

  # Get base call/expression
  var baseCall: JsonNode = nil
  if callField.isSome:
    baseCall = canonicalize(callField.get, source, profile)

  # Collect all blocks (inline_stmt_list, suite, do_block, simple_stmt_line, etc.)
  var blockArgs: seq[JsonNode] = @[]
  var blockStmts: seq[JsonNode] = @[]  # Collect simple_stmt_line children
  var blockSpan: JsonNode = nil
  for child in node.namedChildren:
    if child.nodeType == "do_block":
      # Flush any accumulated simple_stmt_lines first
      if blockStmts.len > 0:
        blockArgs.add %*{"kind": "StmtList", "stmts": blockStmts, "span": blockSpan}
        blockStmts = @[]
        blockSpan = nil
      # do blocks become Lambda (or StmtList if no params)
      blockArgs.add canonicalize(child, source, profile)
    elif child.nodeType in ["inline_stmt_list", "suite"]:
      # Flush any accumulated simple_stmt_lines first
      if blockStmts.len > 0:
        blockArgs.add %*{"kind": "StmtList", "stmts": blockStmts, "span": blockSpan}
        blockStmts = @[]
        blockSpan = nil
      let bodyCanon = canonicalize(child, source, profile)
      let body = if bodyCanon["kind"].getStr == "StmtList": bodyCanon
                 else: %*{"kind": "StmtList", "stmts": [bodyCanon], "span": bodyCanon["span"]}
      blockArgs.add body
    elif child.nodeType == "simple_stmt_line":
      # Collect individual statement lines into a StmtList
      let stmtCanon = canonicalize(child, source, profile)
      if stmtCanon["kind"].getStr == "StmtList":
        for stmt in stmtCanon["stmts"]:
          blockStmts.add stmt
      else:
        blockStmts.add stmtCanon
      if blockSpan == nil:
        blockSpan = newSpan(child)
      else:
        blockSpan["endByte"] = newSpan(child)["endByte"]
        blockSpan["endPoint"] = newSpan(child)["endPoint"]

  # Flush any remaining simple_stmt_lines
  if blockStmts.len > 0:
    blockArgs.add %*{"kind": "StmtList", "stmts": blockStmts, "span": blockSpan}

  # Merge into a Call
  if baseCall != nil:
    let baseKind = baseCall["kind"].getStr
    if baseKind in ["Call", "Command"]:
      # Add block args to the existing call
      var args = baseCall["args"].getElems()
      for blockArg in blockArgs:
        args.add blockArg
      result = %*{
        "kind": "Call",
        "callee": baseCall["callee"],
        "args": args,
        "span": newSpan(node)
      }
    else:
      # Treat base as callee, blocks as args
      result = %*{
        "kind": "Call",
        "callee": baseCall,
        "args": blockArgs,
        "span": newSpan(node)
      }
  else:
    result = %*{
      "kind": "Call",
      "callee": %*{"kind": "Empty"},
      "args": blockArgs,
      "span": newSpan(node)
    }
  result.addCstRef(node, profile)

proc canonicalizeIf(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize if expression/statement
  ## Multi-line if bodies have multiple children with same field name
  ## Structure: condition, consequence+, [elif, condition, body+]*, [else, alternative+]
  var branches: seq[JsonNode] = @[]
  var elseBranch: JsonNode = nil

  # Collect body statements - multiple consequence/alternative children form one body
  var currentCond: JsonNode = nil
  var currentBodyStmts: seq[JsonNode] = @[]
  var currentBodySpan: JsonNode = nil
  var collectingAlternative = false

  proc flushBody() =
    if currentBodyStmts.len > 0:
      let body = %*{
        "kind": "StmtList",
        "stmts": currentBodyStmts,
        "span": currentBodySpan
      }
      if collectingAlternative:
        elseBranch = body
      elif currentCond != nil:
        branches.add %*{
          "condition": currentCond,
          "body": body
        }
      currentCond = nil
      currentBodyStmts = @[]
      currentBodySpan = nil
      collectingAlternative = false

  for i in 0 ..< node.childCount:
    let child = node.child(i)
    let fieldName = node.fieldNameForChild(i)

    case child.nodeType
    of "if", ":", ",":
      # Skip keywords and punctuation
      discard
    of "elif":
      flushBody()
    of "else":
      flushBody()
      collectingAlternative = true
    else:
      if child.isNamed:
        if fieldName == "condition":
          flushBody()
          currentCond = canonicalize(child, source, profile)
        elif fieldName == "consequence" or fieldName == "alternative" or
             (fieldName == "" and currentCond != nil):
          # Handle consequence, alternative, AND elif bodies (which have no field name)
          let bodyCanon = canonicalize(child, source, profile)
          # Flatten StmtList children
          if bodyCanon["kind"].getStr == "StmtList":
            for stmt in bodyCanon["stmts"]:
              currentBodyStmts.add stmt
          else:
            currentBodyStmts.add bodyCanon
          if currentBodySpan == nil:
            currentBodySpan = bodyCanon["span"]
          else:
            # Extend span to cover all statements
            currentBodySpan["endByte"] = bodyCanon["span"]["endByte"]
            currentBodySpan["endPoint"] = bodyCanon["span"]["endPoint"]

  # Flush any remaining body
  flushBody()

  let kind = if node.nodeType.endsWith("_expr"): "IfExpr" else: "IfStmt"

  result = %*{
    "kind": kind,
    "branches": branches,
    "span": newSpan(node)
  }
  if elseBranch != nil:
    result["elseBranch"] = elseBranch
  result.addCstRef(node, profile)

proc canonicalizeCase(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize case statement/expression
  let exprField = node.childByFieldName("expression")
  var branches: seq[JsonNode] = @[]
  var elseBranch: JsonNode = nil

  for child in node.namedChildren:
    case child.nodeType
    of "of_branch", "case_expr_branch":
      var patterns: seq[JsonNode] = @[]
      var body: JsonNode = nil
      var hasExpressionList = false

      # First pass: check if this is an "of" branch (has expression_list) or "else" branch
      for branchChild in child.namedChildren:
        if branchChild.nodeType == "expression_list":
          hasExpressionList = true
          break

      for branchChild in child.namedChildren:
        if branchChild.nodeType == "expression_list":
          for expr in branchChild.namedChildren:
            patterns.add canonicalize(expr, source, profile)
        elif branchChild.nodeType == "expression":
          if hasExpressionList or child.nodeType == "of_branch":
            # This is an "of" branch - expression after pattern list is the body
            if patterns.len == 0:
              # Single pattern without expression_list (of_branch form)
              patterns.add canonicalize(branchChild, source, profile)
            else:
              body = canonicalize(branchChild, source, profile)
          else:
            # This is an "else" branch in case_expr_branch - no patterns, just body
            body = canonicalize(branchChild, source, profile)

      if body == nil and child.namedChildCount > 0:
        body = canonicalize(child.namedChild(child.namedChildCount - 1), source, profile)

      # Wrap body in StmtList if it's not already a StmtList (Nim always wraps branch bodies)
      if body != nil and body["kind"].getStr != "StmtList":
        body = %*{
          "kind": "StmtList",
          "stmts": [body],
          "span": body["span"]
        }

      if patterns.len > 0:
        # This is an "of" branch
        branches.add %*{
          "patterns": patterns,
          "body": body
        }
      elif body != nil and not hasExpressionList and child.nodeType == "case_expr_branch":
        # This is an "else" branch in case_expr_branch
        elseBranch = body
    of "else_branch":
      if child.namedChildCount > 0:
        elseBranch = canonicalize(child.namedChild(0), source, profile)
        # Wrap else branch body in StmtList if needed
        if elseBranch != nil and elseBranch["kind"].getStr != "StmtList":
          elseBranch = %*{
            "kind": "StmtList",
            "stmts": [elseBranch],
            "span": elseBranch["span"]
          }
    else:
      discard

  result = %*{
    "kind": if node.nodeType.contains("expr"): "CaseExpr" else: "CaseStmt",
    "expr": if exprField.isSome: canonicalize(exprField.get, source, profile)
            else: %*{"kind": "Empty"},
    "branches": branches,
    "span": newSpan(node)
  }
  if elseBranch != nil:
    result["elseBranch"] = elseBranch
  result.addCstRef(node, profile)

proc canonicalizeWhile(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize while statement
  let condField = node.childByFieldName("condition")
  let bodyFields = getAllBodyFields(node)

  var body: JsonNode = %*{"kind": "Empty", "span": newSpan(node)}
  if bodyFields.len > 0:
    var bodyStmts: seq[JsonNode] = @[]
    for bodyNode in bodyFields:
      let bodyCanon = canonicalize(bodyNode, source, profile)
      if bodyCanon["kind"].getStr == "StmtList":
        for stmt in bodyCanon["stmts"]:
          bodyStmts.add stmt
      else:
        bodyStmts.add bodyCanon
    body = %*{
      "kind": "StmtList",
      "stmts": bodyStmts,
      "span": newSpan(bodyFields[0])
    }

  result = %*{
    "kind": "WhileStmt",
    "condition": if condField.isSome: canonicalize(condField.get, source, profile)
                 else: %*{"kind": "Empty"},
    "body": body,
    "span": newSpan(node)
  }
  result.addCstRef(node, profile)

proc canonicalizeFor(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize for statement
  let varsField = node.childByFieldName("variables")
  let iterField = node.childByFieldName("iterable")
  let bodyFields = getAllBodyFields(node)

  var vars: seq[JsonNode] = @[]
  if varsField.isSome:
    let v = varsField.get
    if v.nodeType == "for_pattern":
      for child in v.namedChildren:
        vars.add canonicalize(child, source, profile)
    else:
      vars.add canonicalize(v, source, profile)

  var body: JsonNode = %*{"kind": "Empty", "span": newSpan(node)}
  if bodyFields.len > 0:
    var bodyStmts: seq[JsonNode] = @[]
    for bodyNode in bodyFields:
      let bodyCanon = canonicalize(bodyNode, source, profile)
      if bodyCanon["kind"].getStr == "StmtList":
        for stmt in bodyCanon["stmts"]:
          bodyStmts.add stmt
      else:
        bodyStmts.add bodyCanon
    body = %*{
      "kind": "StmtList",
      "stmts": bodyStmts,
      "span": newSpan(bodyFields[0])
    }

  result = %*{
    "kind": "ForStmt",
    "vars": vars,
    "iter": if iterField.isSome: canonicalize(iterField.get, source, profile)
            else: %*{"kind": "Empty"},
    "body": body,
    "span": newSpan(node)
  }
  result.addCstRef(node, profile)

proc canonicalizeTry(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize try statement/expression
  var body: JsonNode = nil
  var excepts: seq[JsonNode] = @[]
  var finallyBranch: JsonNode = nil

  for child in node.namedChildren:
    case child.nodeType
    of "except_branch", "except_expr_branch":
      var types: seq[JsonNode] = @[]
      var exceptBody: JsonNode = nil

      # Structure:
      # - With types: expression_list (types), then expression (body)
      # - Without types: just expression (body)
      for i in 0 ..< child.childCount:
        let branchChild = child.child(i)
        let fieldName = child.fieldNameForChild(i)

        if branchChild.nodeType == "expression_list":
          for expr in branchChild.namedChildren:
            types.add canonicalize(expr, source, profile)
        elif fieldName == "name":
          # Binding name: Nim's parser produces `type as name` as an infix node.
          let nameNode = canonicalize(branchChild, source, profile)
          if types.len == 0:
            types.add %*{
              "kind": "Infix",
              "operator": "as",
              "left": %*{"kind": "Ident", "name": "", "span": newSpan(branchChild)},
              "right": nameNode,
              "span": newSpan(branchChild)
            }
          else:
            let base = types[^1]
            types[^1] = %*{
              "kind": "Infix",
              "operator": "as",
              "left": base,
              "right": nameNode,
              "span": newSpan(branchChild)
            }
        elif branchChild.isNamed and branchChild.nodeType in ["expression", "inline_stmt_list", "suite", "simple_stmt_line"]:
          # The last expression/stmt_list is always the body
          let bodyCanon = canonicalize(branchChild, source, profile)
          exceptBody = if bodyCanon["kind"].getStr == "StmtList": bodyCanon
                       else: %*{"kind": "StmtList", "stmts": [bodyCanon], "span": bodyCanon["span"]}

      excepts.add %*{
        "types": types,
        "body": if exceptBody != nil: exceptBody else: %*{"kind": "StmtList", "stmts": [], "span": newSpan(child)}
      }
    of "finally_branch", "finally_expr_branch":
      if child.namedChildCount > 0:
        let finCanon = canonicalize(child.namedChild(0), source, profile)
        finallyBranch = if finCanon["kind"].getStr == "StmtList": finCanon
                        else: %*{"kind": "StmtList", "stmts": [finCanon], "span": finCanon["span"]}
    else:
      if body == nil:
        let bodyCanon = canonicalize(child, source, profile)
        body = if bodyCanon["kind"].getStr == "StmtList": bodyCanon
               else: %*{"kind": "StmtList", "stmts": [bodyCanon], "span": bodyCanon["span"]}

  result = %*{
    "kind": "TryStmt",  # Nim always uses TryStmt, even for try expressions
    "body": if body != nil: body else: %*{"kind": "StmtList", "stmts": [], "span": newSpan(node)},
    "excepts": excepts,
    "span": newSpan(node)
  }
  if finallyBranch != nil:
    result["finally"] = finallyBranch
  result.addCstRef(node, profile)

proc canonicalizeBlock(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize block statement/expression
  let nameField = node.childByFieldName("name")
  let bodyFields = getAllBodyFields(node)

  result = %*{
    "kind": "BlockStmt",  # Nim always uses BlockStmt, even for block expressions
    "span": newSpan(node)
  }

  if nameField.isSome:
    result["name"] = canonicalize(nameField.get, source, profile)

  if bodyFields.len > 0:
    var bodyStmts: seq[JsonNode] = @[]
    for bodyNode in bodyFields:
      let bodyCanon = canonicalize(bodyNode, source, profile)
      if bodyCanon["kind"].getStr == "StmtList":
        for stmt in bodyCanon["stmts"]:
          bodyStmts.add stmt
      else:
        bodyStmts.add bodyCanon
    result["body"] = %*{
      "kind": "StmtList",
      "stmts": bodyStmts,
      "span": newSpan(bodyFields[0])
    }

  result.addCstRef(node, profile)

proc canonicalizeRoutine(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize routine (proc/func/etc) definition
  let kindField = node.childByFieldName("kind")
  let nameField = node.childByFieldName("name")
  let genericField = node.childByFieldName("generic_params")
  let paramsField = node.childByFieldName("params")
  let returnField = node.childByFieldName("return_type")
  let pragmasField = node.childByFieldName("pragmas")
  let bodyFields = getAllBodyFields(node)

  let routineKind = if kindField.isSome: kindField.get.text else: "proc"

  result = %*{
    "kind": "RoutineDef",
    "routineKind": routineKind,
    "span": newSpan(node)
  }

  if nameField.isSome:
    let nameNode = nameField.get
    if nameNode.nodeType == "exported_symbol":
      # Check for export marker
      let exportedField = nameNode.childByFieldName("exported")
      if exportedField.isSome:
        result["exported"] = %true

      for child in nameNode.namedChildren:
        if child.nodeType in ["symbol", "identifier"]:
          result["name"] = canonicalize(child, source, profile)
          break
    else:
      result["name"] = canonicalize(nameNode, source, profile)

  if genericField.isSome:
    result["genericParams"] = canonicalize(genericField.get, source, profile)

  if paramsField.isSome:
    result["params"] = canonicalize(paramsField.get, source, profile)

  if returnField.isSome:
    result["returnType"] = canonicalize(returnField.get, source, profile)

  if pragmasField.isSome:
    result["pragmas"] = canonicalize(pragmasField.get, source, profile)

  if bodyFields.len > 0:
    # Nim always wraps routine bodies in StmtList
    # Tree-sitter may produce multiple body: fields for multi-statement bodies
    var bodyStmts: seq[JsonNode] = @[]
    for bodyNode in bodyFields:
      let bodyCanon = canonicalize(bodyNode, source, profile)
      if bodyCanon["kind"].getStr == "StmtList":
        for stmt in bodyCanon["stmts"]:
          bodyStmts.add stmt
      else:
        bodyStmts.add bodyCanon

    result["body"] = %*{
      "kind": "StmtList",
      "stmts": bodyStmts,
      "span": if bodyFields.len > 0: newSpan(bodyFields[0]) else: %*{"startByte": 0, "endByte": 0}
    }

  result.addCstRef(node, profile)

proc canonicalizeSection(node: Node, source: string, kind: string, defKind: string, profile: CanonProfile): JsonNode =
  ## Canonicalize const/let/var/type sections
  var defs: seq[JsonNode] = @[]

  for child in node.namedChildren:
    if child.nodeType in ["decl_def", "type_def"]:
      var def = canonicalize(child, source, profile)
      def["kind"] = %defKind
      defs.add def
    elif child.nodeType == "tuple_decl":
      # Tuple unpacking: (a, b) = expr -> wrapped with section's defKind
      var def = canonicalize(child, source, profile)
      def["kind"] = %defKind
      defs.add def

  result = %*{
    "kind": kind,
    "defs": defs,
    "span": newSpan(node)
  }
  result.addCstRef(node, profile)

proc canonicalizeStmtList(node: Node, source: string, profile: CanonProfile): JsonNode =
  ## Canonicalize statement list
  var stmts: seq[JsonNode] = @[]

  for child in node.namedChildren:
    # Skip comments - they're not part of the AST
    if child.nodeType == "comment":
      continue
    let canon = canonicalize(child, source, profile)
    if canon["kind"].getStr == "Empty":
      continue
    # Flatten nested StmtLists (e.g., from simple_stmt_line with multiple statements)
    if canon["kind"].getStr == "StmtList" and canon.hasKey("stmts"):
      for stmt in canon["stmts"]:
        stmts.add stmt
    else:
      stmts.add canon

  result = %*{
    "kind": "StmtList",
    "stmts": stmts,
    "span": newSpan(node)
  }
  result.addCstRef(node, profile)

proc canonicalize*(node: Node, source: string, profile: CanonProfile = cpNim): JsonNode =
  ## Main canonicalization entry point
  if node.isNull:
    return %*{"kind": "Empty", "span": {"startByte": 0, "endByte": 0, "startPoint": {"row": 0, "column": 0}, "endPoint": {"row": 0, "column": 0}}}

  let nodeType = node.nodeType

  case nodeType
  of "source_file":
    result = canonicalizeStmtList(node, source, profile)

  of "identifier":
    result = canonicalizeIdent(node, source, profile)

  of "symbol":
    # symbol can contain identifier or quoted_identifier
    let child = node.namedChild(0)
    if not child.isNull:
      result = canonicalize(child, source, profile)
    else:
      result = canonicalizeIdent(node, source, profile)

  of "quoted_identifier":
    # Nim's parser splits quoted identifiers into tokens and joins with spaces
    # e.g., `=destroy` becomes "= destroy", `hello world` becomes "hello world"
    let content = node.text[1..^2]  # Strip backticks
    # Split into parts matching Nim's tokenization
    var parts: seq[string] = @[]
    var i = 0
    while i < content.len:
      if content[i] in Whitespace:
        # Skip whitespace between tokens
        inc i
      elif content[i] in {'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF'}:
        # Identifier
        var j = i
        while j < content.len and content[j] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}:
          inc j
        parts.add content[i..<j]
        i = j
      elif content[i] in {'0'..'9'}:
        # Number (part of identifier)
        var j = i
        while j < content.len and content[j] in {'0'..'9'}:
          inc j
        parts.add content[i..<j]
        i = j
      else:
        # Operator or special char
        var j = i
        # Collect consecutive operator chars
        while j < content.len and content[j] notin {'a'..'z', 'A'..'Z', '0'..'9', '_', ' ', '\t', '\x80'..'\xFF'}:
          inc j
        if j > i:
          parts.add content[i..<j]
          i = j
        else:
          inc i  # Skip unknown char
    result = %*{
      "kind": "Ident",
      "name": parts.join(" "),
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "qualified_identifier":
    result = canonicalizeQualifiedIdent(node, source, profile)

  of "literal":
    let child = node.namedChild(0)
    if not child.isNull:
      result = canonicalize(child, source, profile)
    else:
      result = canonizeLiteral(node, source, profile)

  of "integer_literal", "float_literal", "string_literal", "raw_string_literal",
     "triple_string_literal", "char_literal", "nil_literal", "boolean_literal":
    result = canonizeLiteral(node, source, profile)

  of "expression":
    result = unwrapExpression(node, source, profile)

  of "infix_expression", "assign_expr", "op2_expr", "or_expr", "and_expr",
     "cmp_expr", "range_expr", "amp_expr", "add_expr", "mul_expr", "pow_expr":
    let opField = node.childByFieldName("operator")
    if opField.isSome:
      result = canonicalizeInfix(node, source, profile)
    else:
      # Check for multiple named children (e.g., arrow expressions with repeat)
      # In this case, look for operator tokens among non-named children
      let namedChildren = node.getNamedChildren()
      if namedChildren.len == 1:
        result = canonicalize(namedChildren[0], source, profile)
      elif namedChildren.len >= 2:
        # For infix_expression with repeat(seq(op, expr)), the operator may not
        # appear as a child node. Extract operator from source between operands.
        let firstEnd = namedChildren[0].endByte
        let secondStart = namedChildren[1].startByte
        var opText = ""

        # First try to find operator among children
        for i in 0 ..< node.childCount:
          let child = node.child(i)
          if child.nodeType in ["arrow_operator", "->", "~>", "=>"]:
            opText = child.text
            break
          elif not child.isNamed and child.text in ["->", "~>", "=>"]:
            opText = child.text
            break

        # If not found, extract from source text between operands
        if opText.len == 0 and secondStart > firstEnd:
          let between = source[firstEnd ..< secondStart].strip()
          # Match arrow operators: ->, ~>, =>, or user-defined ending in [-~=]>
          if between in ["->", "~>", "=>"] or
             (between.len >= 2 and between[^1] == '>' and between[^2] in {'-', '~', '='}):
            opText = between

        if opText.len > 0:
          # Build chained infix for multiple operands
          result = canonicalize(namedChildren[0], source, profile)
          for i in 1 ..< namedChildren.len:
            result = %*{
              "kind": "Infix",
              "operator": opText,
              "left": result,
              "right": canonicalize(namedChildren[i], source, profile),
              "span": newSpan(node)
            }
          result.addCstRef(node, profile)
        else:
          result = %*{"kind": "Empty", "span": newSpan(node)}
      else:
        result = %*{"kind": "Empty", "span": newSpan(node)}

  of "prefix_expr":
    result = canonicalizePrefix(node, source, profile)

  of "postfix_expr":
    # Check for call/index/dot suffixes
    var hasSuffix = false
    for child in node.namedChildren:
      if child.nodeType in ["call_suffix", "index_suffix", "dot_suffix", "brace_suffix"]:
        hasSuffix = true
        break

    if hasSuffix:
      # Process as call/index/dot chain
      var base: JsonNode = nil
      for i in 0 ..< node.namedChildCount:
        let child = node.namedChild(i)
        case child.nodeType
        of "call_suffix":
          var args: seq[JsonNode] = @[]
          for arg in child.namedChildren:
            args.add canonicalize(arg, source, profile)
          # Check for cast[T](x) pattern
          if base != nil and base["kind"].getStr == "Index":
            let indexBase = base["base"]
            if indexBase != nil and indexBase["kind"].getStr == "Ident" and
               indexBase["name"].getStr == "cast":
              # This is cast[T](x) -> produce Cast node
              let indices = base["indices"].getElems()
              base = %*{
                "kind": "Cast",
                "targetType": if indices.len > 0: indices[0] else: %*{"kind": "Empty"},
                "expr": if args.len > 0: args[0] else: %*{"kind": "Empty"},
                "span": newSpan(node)
              }
            else:
              base = %*{
                "kind": "Call",
                "callee": base,
                "args": args,
                "span": newSpan(node)
              }
          else:
            base = %*{
              "kind": "Call",
              "callee": base,
              "args": args,
              "span": newSpan(node)
            }
        of "index_suffix":
          var indices: seq[JsonNode] = @[]
          for idx in child.namedChildren:
            indices.add canonicalize(idx, source, profile)
          base = %*{
            "kind": "Index",
            "base": base,
            "indices": indices,
            "span": newSpan(node)
          }
        of "dot_suffix":
          if child.namedChildCount > 0:
            base = %*{
              "kind": "Dot",
              "base": base,
              "field": canonicalize(child.namedChild(0), source, profile),
              "span": newSpan(node)
            }
        of "brace_suffix":
          # Curly expression: f{1, 2}
          var elements: seq[JsonNode] = @[]
          for elem in child.namedChildren:
            elements.add canonicalize(elem, source, profile)
          base = %*{
            "kind": "CurlyExpr",
            "callee": base,
            "elements": elements,
            "span": newSpan(node)
          }
        else:
          if base == nil:
            base = canonicalize(child, source, profile)
      result = base
    else:
      # Unwrap
      let children = node.getNamedChildren()
      if children.len == 1:
        result = canonicalize(children[0], source, profile)
      else:
        result = %*{"kind": "Empty", "span": newSpan(node)}

  of "command_expr":
    result = canonicalizeCommand(node, source, profile)

  of "call_with_blocks":
    result = canonicalizeCallWithBlocks(node, source, profile)

  of "if_stmt":
    result = canonicalizeIf(node, source, profile)

  of "if_expr":
    result = canonicalizeIf(node, source, profile)

  of "case_stmt":
    result = canonicalizeCase(node, source, profile)

  of "case_expr":
    result = canonicalizeCase(node, source, profile)

  of "while_stmt":
    result = canonicalizeWhile(node, source, profile)

  of "for_stmt":
    result = canonicalizeFor(node, source, profile)

  of "try_stmt", "try_expr":
    result = canonicalizeTry(node, source, profile)

  of "block_stmt", "block_expr":
    result = canonicalizeBlock(node, source, profile)

  of "decl_def":
    # Variable/constant definition: name [: type] [= value]
    # Matches Nim's nkIdentDefs format: names array, type, value
    var names: seq[JsonNode] = @[]
    var typ: JsonNode = nil
    var value: JsonNode = nil
    var exported = false

    for child in node.namedChildren:
      case child.nodeType
      of "exported_symbol":
        names.add canonicalize(child, source, profile)
        # Check if it's exported (has * suffix)
        if child.text.endsWith("*"):
          exported = true
      of "symbol":
        names.add canonicalize(child, source, profile)
      of "type_expr":
        typ = canonicalize(child, source, profile)
      of "expression":
        value = canonicalize(child, source, profile)
      else:
        discard

    result = %*{
      "kind": "IdentDefs",
      "names": names,
      "span": newSpan(node)
    }
    if typ != nil:
      result["type"] = typ
    if value != nil:
      result["value"] = value
    if exported:
      result["exported"] = %true
    result.addCstRef(node, profile)

  of "type_def":
    # Type definition: name [generic_params] = value
    let nameField = node.childByFieldName("name")
    let valueField = node.childByFieldName("value")
    let genericField = node.childByFieldName("generic_params")

    result = %*{
      "kind": "TypeDef",
      "span": newSpan(node)
    }

    if nameField.isSome:
      let nameNode = nameField.get
      if nameNode.nodeType == "exported_symbol":
        # Extract actual name from exported_symbol
        result["name"] = canonicalize(nameNode, source, profile)
        if nameNode.text.endsWith("*"):
          result["exported"] = %true
      else:
        result["name"] = canonicalize(nameNode, source, profile)

    if genericField.isSome:
      result["genericParams"] = canonicalize(genericField.get, source, profile)

    if valueField.isSome:
      result["value"] = canonicalize(valueField.get, source, profile)

    result.addCstRef(node, profile)

  of "enum_def":
    # Enum type definition
    var fields: seq[JsonNode] = @[]
    for child in node.namedChildren:
      if child.nodeType == "enum_field_def":
        fields.add canonicalize(child, source, profile)

    result = %*{
      "kind": "EnumType",
      "fields": fields,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "enum_field_def":
    # Enum field: name [= value]
    let nameField = node.childByFieldName("name")
    let valueField = node.childByFieldName("value")

    result = %*{
      "kind": "EnumField",
      "span": newSpan(node)
    }
    if nameField.isSome:
      result["name"] = canonicalize(nameField.get, source, profile)
    if valueField.isSome:
      result["value"] = canonicalize(valueField.get, source, profile)
    result.addCstRef(node, profile)

  of "object_def":
    # Object type definition
    # Grammar matches: "object" | "ref object" | "ptr object"
    # Need to check if it's ref/ptr and wrap accordingly
    var fields: seq[JsonNode] = @[]
    var parent: JsonNode = nil
    var isRef = false
    var isPtr = false

    # Check if this is ref object or ptr object by looking at the first child
    for i in 0 ..< node.childCount:
      let child = node.child(i)
      if child.nodeType == "ref":
        isRef = true
        break
      elif child.nodeType == "ptr":
        isPtr = true
        break
      elif child.nodeType == "object":
        break  # Just plain object

    for child in node.namedChildren:
      if child.nodeType == "of_clause":
        # Inheritance
        if child.namedChildCount > 0:
          parent = canonicalize(child.namedChild(0), source, profile)
      elif child.nodeType in ["field_def", "rec_list", "object_fields"]:
        fields.add canonicalize(child, source, profile)
      elif child.nodeType in ["case_field", "when_field"]:
        fields.add canonicalize(child, source, profile)

    var objType = %*{
      "kind": "ObjectType",
      "fields": fields,
      "span": newSpan(node)
    }
    if parent != nil:
      objType["parent"] = parent

    # Wrap in RefType or PtrType if needed
    if isRef:
      result = %*{
        "kind": "RefType",
        "base": objType,
        "span": newSpan(node)
      }
    elif isPtr:
      result = %*{
        "kind": "PtrType",
        "base": objType,
        "span": newSpan(node)
      }
    else:
      result = objType
    result.addCstRef(node, profile)

  of "concept_def":
    # Concept type definition
    var params: seq[JsonNode] = @[]
    var bodyStmts: seq[JsonNode] = @[]

    for child in node.namedChildren:
      if child.nodeType in ["symbol", "identifier"]:
        params.add canonicalize(child, source, profile)
      elif child.nodeType == "concept_constraint":
        for c in child.namedChildren:
          bodyStmts.add canonicalize(c, source, profile)
      elif child.nodeType in ["inline_stmt_list", "suite"]:
        let bodyCanon = canonicalize(child, source, profile)
        if bodyCanon["kind"].getStr == "StmtList":
          for stmt in bodyCanon["stmts"].getElems:
            bodyStmts.add stmt
        else:
          bodyStmts.add bodyCanon
      elif child.nodeType == "routine_header":
        # Proc signature constraint in concept
        bodyStmts.add canonicalize(child, source, profile)
      elif child.nodeType == "simple_stmt_line":
        # Simple statement line in concept body
        let stmtCanon = canonicalize(child, source, profile)
        if stmtCanon["kind"].getStr == "StmtList":
          for stmt in stmtCanon["stmts"].getElems:
            bodyStmts.add stmt
        else:
          bodyStmts.add stmtCanon

    result = %*{
      "kind": "TypeClass",
      "params": params,
      "span": newSpan(node)
    }
    if bodyStmts.len > 0:
      result["body"] = %*{
        "kind": "StmtList",
        "stmts": bodyStmts,
        "span": newSpan(node)
      }
    result.addCstRef(node, profile)

  of "routine_definition":
    result = canonicalizeRoutine(node, source, profile)

  of "routine_header":
    # Routine header (signature without body) - used in concepts
    result = canonicalizeRoutine(node, source, profile)

  of "proc_expr":
    # Anonymous proc/lambda - similar to routine_definition but kind is "Lambda"
    let kindField = node.childByFieldName("kind")
    let paramsField = node.childByFieldName("params")
    let returnField = node.childByFieldName("return_type")
    let pragmasField = node.childByFieldName("pragmas")
    let bodyField = getBodyField(node)

    result = %*{
      "kind": "Lambda",
      "routineKind": if kindField.isSome: kindField.get.text else: "proc",
      "span": newSpan(node)
    }

    if paramsField.isSome:
      result["params"] = canonicalize(paramsField.get, source, profile)

    if returnField.isSome:
      result["returnType"] = canonicalize(returnField.get, source, profile)

    if pragmasField.isSome:
      result["pragmas"] = canonicalize(pragmasField.get, source, profile)

    if bodyField.isSome:
      let bodyCanon = canonicalize(bodyField.get, source, profile)
      if bodyCanon["kind"].getStr == "StmtList":
        result["body"] = bodyCanon
      else:
        result["body"] = %*{
          "kind": "StmtList",
          "stmts": [bodyCanon],
          "span": newSpan(bodyField.get)
        }

    result.addCstRef(node, profile)

  of "do_block":
    # do block - anonymous proc like structure
    # If no params, Nim produces StmtList; if has params, produces Lambda
    let paramsField = node.childByFieldName("params")

    # Find body (inline_stmt_list or suite)
    var bodyNode: JsonNode = nil
    for child in node.namedChildren:
      if child.nodeType in ["inline_stmt_list", "suite"]:
        let bodyCanon = canonicalize(child, source, profile)
        if bodyCanon["kind"].getStr == "StmtList":
          bodyNode = bodyCanon
        else:
          bodyNode = %*{
            "kind": "StmtList",
            "stmts": [bodyCanon],
            "span": newSpan(child)
          }
        break

    if paramsField.isNone:
      # No params - just produce StmtList (like Nim does)
      if bodyNode != nil:
        result = bodyNode
      else:
        result = %*{"kind": "StmtList", "stmts": [], "span": newSpan(node)}
    else:
      # Has params - produce Lambda
      result = %*{
        "kind": "Lambda",
        "routineKind": "proc",
        "span": newSpan(node)
      }
      result["params"] = canonicalize(paramsField.get, source, profile)
      if bodyNode != nil:
        result["body"] = bodyNode

    result.addCstRef(node, profile)

  of "const_section":
    result = canonicalizeSection(node, source, "ConstSection", "ConstDef", profile)

  of "let_section":
    result = canonicalizeSection(node, source, "LetSection", "LetDef", profile)

  of "var_section":
    result = canonicalizeSection(node, source, "VarSection", "VarDef", profile)

  of "type_section":
    result = canonicalizeSection(node, source, "TypeSection", "TypeDef", profile)

  of "using_section":
    result = canonicalizeSection(node, source, "UsingSection", "UsingDef", profile)

  of "simple_stmt_line":
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = canonicalizeStmtList(node, source, profile)

  of "simple_stmt":
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = canonicalizeStmtList(node, source, profile)

  of "return_stmt":
    result = %*{
      "kind": "Return",
      "span": newSpan(node)
    }
    if node.namedChildCount > 0:
      result["value"] = canonicalize(node.namedChild(0), source, profile)
    result.addCstRef(node, profile)

  of "discard_stmt":
    result = %*{
      "kind": "Discard",
      "span": newSpan(node)
    }
    if node.namedChildCount > 0:
      result["value"] = canonicalize(node.namedChild(0), source, profile)
    result.addCstRef(node, profile)

  of "yield_stmt":
    result = %*{
      "kind": "Yield",
      "span": newSpan(node)
    }
    if node.namedChildCount > 0:
      result["value"] = canonicalize(node.namedChild(0), source, profile)
    result.addCstRef(node, profile)

  of "raise_stmt":
    result = %*{
      "kind": "Raise",
      "span": newSpan(node)
    }
    if node.namedChildCount > 0:
      result["value"] = canonicalize(node.namedChild(0), source, profile)
    result.addCstRef(node, profile)

  of "break_stmt":
    result = %*{
      "kind": "Break",
      "span": newSpan(node)
    }
    if node.namedChildCount > 0:
      result["label"] = canonicalize(node.namedChild(0), source, profile)
    result.addCstRef(node, profile)

  of "continue_stmt":
    result = %*{
      "kind": "Continue",
      "span": newSpan(node)
    }
    if node.namedChildCount > 0:
      result["label"] = canonicalize(node.namedChild(0), source, profile)
    result.addCstRef(node, profile)

  of "bind_stmt":
    var items: seq[JsonNode] = @[]
    for child in node.namedChildren:
      items.add canonicalize(child, source, profile)
    result = %*{
      "kind": "Bind",
      "items": items,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "mixin_stmt":
    var items: seq[JsonNode] = @[]
    for child in node.namedChildren:
      items.add canonicalize(child, source, profile)
    result = %*{
      "kind": "Mixin",
      "items": items,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "section_stmt", "compound_stmt":
    # Generic statement wrappers - unwrap to inner content
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = canonicalizeStmtList(node, source, profile)

  of "inline_stmt_list":
    # Inline statement list - unwrap single child or create StmtList
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = canonicalizeStmtList(node, source, profile)

  of "exported_symbol":
    # Exported symbol wrapper - extract the inner symbol
    var innerNode: Node
    for child in node.namedChildren:
      if child.nodeType in ["symbol", "identifier", "quoted_identifier"]:
        innerNode = child
        break
    if not innerNode.isNull:
      result = canonicalize(innerNode, source, profile)
    else:
      result = %*{"kind": "Empty", "span": newSpan(node)}

  of "import_stmt":
    var items: seq[JsonNode] = @[]
    for child in node.namedChildren:
      items.add canonicalize(child, source, profile)
    result = %*{
      "kind": "Import",
      "items": items,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "from_import_stmt":
    var module: JsonNode = nil
    var items: seq[JsonNode] = @[]
    for child in node.namedChildren:
      if module == nil:
        module = canonicalize(child, source, profile)
      else:
        items.add canonicalize(child, source, profile)
    result = %*{
      "kind": "FromImport",
      "module": module,
      "items": items,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "export_stmt":
    var items: seq[JsonNode] = @[]
    for child in node.namedChildren:
      items.add canonicalize(child, source, profile)
    result = %*{
      "kind": "Export",
      "items": items,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "include_stmt":
    var items: seq[JsonNode] = @[]
    for child in node.namedChildren:
      items.add canonicalize(child, source, profile)
    result = %*{
      "kind": "Include",
      "items": items,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "when_stmt":
    # When statement (compile-time if)
    # Structure: children alternate between condition fields and body children
    # - First condition + body = when branch
    # - Subsequent condition + body = elif branches
    # - Body without preceding condition = else branch
    var branches: seq[JsonNode] = @[]
    var elseBranch: JsonNode = nil
    var pendingCondition: JsonNode = nil
    var conditions: seq[Node] = @[]
    var bodies: seq[Node] = @[]

    # Separate conditions and bodies by iterating through all children
    for i in 0 ..< node.childCount:
      let fieldName = node.fieldNameForChild(i)
      let child = node.child(i)
      if fieldName == "condition":
        conditions.add child
      elif child.nodeType in ["simple_stmt_line", "inline_stmt_list", "suite", "section_stmt", "compound_stmt"]:
        bodies.add child

    # Match conditions with bodies
    # conditions[0] -> bodies[0] (when branch)
    # conditions[1] -> bodies[1] (elif branch)
    # ...
    # If there are more bodies than conditions, the last body is the else
    for i in 0 ..< conditions.len:
      if i < bodies.len:
        let bodyCanon = canonicalize(bodies[i], source, profile)
        let body = if bodyCanon["kind"].getStr == "StmtList": bodyCanon
                   else: %*{"kind": "StmtList", "stmts": [bodyCanon], "span": bodyCanon["span"]}
        branches.add %*{
          "condition": canonicalize(conditions[i], source, profile),
          "body": body
        }

    # If there are more bodies than conditions, the last body is else
    if bodies.len > conditions.len:
      let elseBody = bodies[^1]
      let elseCanon = canonicalize(elseBody, source, profile)
      elseBranch = if elseCanon["kind"].getStr == "StmtList": elseCanon
                   else: %*{"kind": "StmtList", "stmts": [elseCanon], "span": elseCanon["span"]}

    result = %*{
      "kind": "When",
      "branches": branches,
      "span": newSpan(node)
    }
    if elseBranch != nil:
      result["elseBranch"] = elseBranch
    result.addCstRef(node, profile)

  of "static_stmt":
    # static_stmt has body as unnamed child (inline_stmt_list, suite, or simple_stmt_line)
    var body: JsonNode = %*{"kind": "Empty", "span": newSpan(node)}
    for child in node.namedChildren:
      if child.nodeType in ["inline_stmt_list", "suite", "simple_stmt_line"]:
        let bodyCanon = canonicalize(child, source, profile)
        body = if bodyCanon["kind"].getStr == "StmtList": bodyCanon
               else: %*{"kind": "StmtList", "stmts": [bodyCanon], "span": bodyCanon["span"]}
        break
    result = %*{
      "kind": "Static",
      "body": body,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "defer_stmt":
    # defer_stmt has body as unnamed child (inline_stmt_list, suite, or simple_stmt_line)
    var body: JsonNode = %*{"kind": "Empty", "span": newSpan(node)}
    for child in node.namedChildren:
      if child.nodeType in ["inline_stmt_list", "suite", "simple_stmt_line"]:
        let bodyCanon = canonicalize(child, source, profile)
        body = if bodyCanon["kind"].getStr == "StmtList": bodyCanon
               else: %*{"kind": "StmtList", "stmts": [bodyCanon], "span": bodyCanon["span"]}
        break
    result = %*{
      "kind": "Defer",
      "body": body,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "asm_stmt":
    var pragmas: JsonNode = nil
    var code: JsonNode = nil
    for child in node.namedChildren:
      if child.nodeType == "pragma":
        pragmas = canonicalize(child, source, profile)
      else:
        code = canonicalize(child, source, profile)
    result = %*{
      "kind": "Asm",
      "span": newSpan(node)
    }
    if pragmas != nil:
      result["pragmas"] = pragmas
    if code != nil:
      result["code"] = code
    result.addCstRef(node, profile)

  of "import_symbol":
    # Unwrap import symbol wrapper
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = %*{
        "kind": "Ident",
        "name": node.text,
        "span": newSpan(node)
      }

  of "import_path":
    # import_path contains symbols separated by "." or "/" and possibly brackets
    # For "." separators, use Dot expression. For "/" separators, use Infix.
    type SymOrSep = object
      isSymbol: bool
      symbol: JsonNode
      separator: string

    var items: seq[SymOrSep] = @[]
    var hasBracket = false
    var bracketStartIdx = -1

    for i in 0 ..< node.childCount:
      let child = node.child(i)
      if child.nodeType == "symbol":
        items.add SymOrSep(isSymbol: true, symbol: canonicalize(child, source, profile))
      elif child.nodeType == "string_literal":
        # String path like "path/to/module"
        items.add SymOrSep(isSymbol: true, symbol: canonicalize(child, source, profile))
      elif child.nodeType == ".":
        items.add SymOrSep(isSymbol: false, separator: ".")
      elif child.nodeType == "/":
        items.add SymOrSep(isSymbol: false, separator: "/")
      elif child.nodeType == "[":
        hasBracket = true
        # Count symbols collected so far
        bracketStartIdx = 0
        for item in items:
          if item.isSymbol:
            inc bracketStartIdx

    # Collect symbols
    var symbols: seq[JsonNode] = @[]
    var separators: seq[string] = @[]
    for item in items:
      if item.isSymbol:
        symbols.add item.symbol
      else:
        separators.add item.separator

    if symbols.len == 0:
      result = %*{"kind": "Empty"}
    elif symbols.len == 1:
      result = symbols[0]
    elif hasBracket and bracketStartIdx > 0:
      # Build base from symbols before bracket
      var base = symbols[0]
      for i in 1 ..< bracketStartIdx:
        let sep = if i - 1 < separators.len: separators[i - 1] else: "/"
        if sep == ".":
          base = %*{
            "kind": "Dot",
            "base": base,
            "field": symbols[i],
            "span": newSpan(node)
          }
        else:
          base = %*{
            "kind": "Infix",
            "operator": "/",
            "left": base,
            "right": symbols[i],
            "span": newSpan(node)
          }
      var bracketItems: seq[JsonNode] = @[]
      for i in bracketStartIdx ..< symbols.len:
        bracketItems.add symbols[i]
      result = %*{
        "kind": "Infix",
        "operator": "/",
        "left": base,
        "right": %*{
          "kind": "Array",
          "elements": bracketItems,
          "span": newSpan(node)
        },
        "span": newSpan(node)
      }
    else:
      # Build a chain based on separators
      result = symbols[0]
      for i in 1 ..< symbols.len:
        let sep = if i - 1 < separators.len: separators[i - 1] else: "/"
        if sep == ".":
          result = %*{
            "kind": "Dot",
            "base": result,
            "field": symbols[i],
            "span": newSpan(node)
          }
        else:
          result = %*{
            "kind": "Infix",
            "operator": "/",
            "left": result,
            "right": symbols[i],
            "span": newSpan(node)
          }
    result.addCstRef(node, profile)

  of "expr_stmt":
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = canonicalizeStmtList(node, source, profile)

  of "assignment_stmt":
    let leftField = node.childByFieldName("left")
    let rightField = node.childByFieldName("right")
    result = %*{
      "kind": "Assign",
      "left": if leftField.isSome: canonicalize(leftField.get, source, profile) else: %*{"kind": "Empty"},
      "right": if rightField.isSome: canonicalize(rightField.get, source, profile) else: %*{"kind": "Empty"},
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "paren_expr":
    # Parenthesized expressions
    if node.namedChildCount == 1:
      let inner = canonicalize(node.namedChild(0), source, profile)
      # Nim wraps control-flow expressions in parentheses as StmtListExpr
      # and uses statement kinds (IfStmt, etc.) instead of expression kinds
      # Also, inside StmtListExpr, branch bodies are NOT wrapped in StmtList
      let innerKind = inner["kind"].getStr
      if innerKind in ["IfExpr", "CaseExpr", "TryExpr", "BlockExpr"]:
        # Convert expression kinds to statement kinds inside StmtListExpr
        var stmtInner = inner.copy
        case innerKind
        of "IfExpr": stmtInner["kind"] = %"IfStmt"
        of "CaseExpr": stmtInner["kind"] = %"CaseStmt"
        of "TryExpr": stmtInner["kind"] = %"TryStmt"
        of "BlockExpr": stmtInner["kind"] = %"BlockStmt"
        else: discard

        # Unwrap single-element StmtList bodies in branches (StmtListExpr behavior)
        if stmtInner.hasKey("branches"):
          var newBranches = newJArray()
          for branch in stmtInner["branches"]:
            var newBranch = branch.copy
            if newBranch.hasKey("body"):
              let body = newBranch["body"]
              if body["kind"].getStr == "StmtList" and body["stmts"].len == 1:
                newBranch["body"] = body["stmts"][0]
            newBranches.add newBranch
          stmtInner["branches"] = newBranches
        if stmtInner.hasKey("elseBranch"):
          let elseBranch = stmtInner["elseBranch"]
          if elseBranch["kind"].getStr == "StmtList" and elseBranch["stmts"].len == 1:
            stmtInner["elseBranch"] = elseBranch["stmts"][0]

        result = %*{
          "kind": "StmtList",
          "stmts": [stmtInner],
          "span": newSpan(node)
        }
        result.addCstRef(node, profile)
      else:
        result = inner
    else:
      result = %*{"kind": "Empty", "span": newSpan(node)}

  of "tuple_expr":
    var elements: seq[JsonNode] = @[]
    for child in node.namedChildren:
      elements.add canonicalize(child, source, profile)
    result = %*{
      "kind": "Tuple",
      "elements": elements,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "array_expr":
    var elements: seq[JsonNode] = @[]
    for child in node.namedChildren:
      elements.add canonicalize(child, source, profile)
    result = %*{
      "kind": "Array",
      "elements": elements,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "curly_expr", "set_expr":
    # Check if this is a table constructor (has key: value pairs) or a set
    # Empty table {:} is distinguished from empty set {} by the presence of :
    var isTable = false
    for child in node.namedChildren:
      if child.nodeType == "curly_element":
        let keyField = child.childByFieldName("key")
        if keyField.isSome:
          isTable = true
          break

    # Check for empty table {:} - no named children but has : token
    if not isTable and node.namedChildCount == 0:
      for i in 0 ..< node.childCount:
        let child = node.child(i)
        if child.nodeType == ":":
          isTable = true
          break

    var elements: seq[JsonNode] = @[]
    for child in node.namedChildren:
      elements.add canonicalize(child, source, profile)

    if isTable:
      result = %*{
        "kind": "TableConstr",
        "elements": elements,
        "span": newSpan(node)
      }
    else:
      result = %*{
        "kind": "Set",
        "elements": elements,
        "span": newSpan(node)
      }
    result.addCstRef(node, profile)

  of "curly_element":
    # Check if this is a key: value pair (table element) or just a value (set element)
    let keyField = node.childByFieldName("key")
    let valueField = node.childByFieldName("value")

    if keyField.isSome and valueField.isSome:
      # Table element: key: value -> ExprColon
      result = %*{
        "kind": "ExprColon",
        "left": canonicalize(keyField.get, source, profile),
        "right": canonicalize(valueField.get, source, profile),
        "span": newSpan(node)
      }
    else:
      # Set element - unwrap the expression
      let children = node.getNamedChildren()
      if children.len == 1:
        result = canonicalize(children[0], source, profile)
      else:
        result = %*{"kind": "Empty", "span": newSpan(node)}

  of "stmt_list_expr":
    # Statement list expression: (stmt1; stmt2; expr) -> StmtList
    result = canonicalizeStmtList(node, source, profile)

  of "named_tuple_element":
    # Named tuple element like (a: 1) -> ExprColon
    let nameField = node.childByFieldName("name")
    let valueField = node.childByFieldName("value")

    if nameField.isSome and valueField.isSome:
      result = %*{
        "kind": "ExprColon",
        "left": canonicalize(nameField.get, source, profile),
        "right": canonicalize(valueField.get, source, profile),
        "span": newSpan(node)
      }
    else:
      # Fallback - just unwrap
      let children = node.getNamedChildren()
      if children.len == 1:
        result = canonicalize(children[0], source, profile)
      else:
        result = %*{"kind": "Empty", "span": newSpan(node)}
    result.addCstRef(node, profile)

  of "tuple_element":
    # Tuple element wrapper - unwrap to inner content
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = %*{"kind": "Empty", "span": newSpan(node)}

  of "ptr_type":
    # ptr T -> PtrType
    let baseField = node.childByFieldName("base")
    result = %*{
      "kind": "PtrType",
      "base": if baseField.isSome: canonicalize(baseField.get, source, profile)
              else: %*{"kind": "Empty"},
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "ref_type":
    # ref T -> RefType
    let baseField = node.childByFieldName("base")
    result = %*{
      "kind": "RefType",
      "base": if baseField.isSome: canonicalize(baseField.get, source, profile)
              else: %*{"kind": "Empty"},
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "lent_type":
    # lent T -> LentType (similar to RefType)
    let baseField = node.childByFieldName("base")
    result = %*{
      "kind": "LentType",
      "base": if baseField.isSome: canonicalize(baseField.get, source, profile)
              else: %*{"kind": "Empty"},
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "generic_type":
    # Generic type like seq[int], range[0..100] -> Index (matches Nim's nkBracketExpr)
    let nameField = node.childByFieldName("name")
    var indices: seq[JsonNode] = @[]
    for child in node.namedChildren:
      if child.nodeType == "type_arg":
        # type_arg can contain type_expr or expression
        for argChild in child.namedChildren:
          indices.add canonicalize(argChild, source, profile)
    result = %*{
      "kind": "Index",
      "base": if nameField.isSome: canonicalize(nameField.get, source, profile)
              else: %*{"kind": "Empty"},
      "indices": indices,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "type_constraint":
    # Type constraint in generic params - unwrap to inner type
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = %*{"kind": "Empty", "span": newSpan(node)}

  of "type_or_constraint":
    # T: int | string -> Infix with | operator
    let children = node.getNamedChildren()
    if children.len >= 2:
      result = %*{
        "kind": "Infix",
        "op": %*{"kind": "Ident", "name": "|"},
        "left": canonicalize(children[0], source, profile),
        "right": canonicalize(children[1], source, profile),
        "span": newSpan(node)
      }
    else:
      result = %*{"kind": "Empty", "span": newSpan(node)}
    result.addCstRef(node, profile)

  of "type_and_constraint":
    # T: int and string -> Infix with and operator
    let children = node.getNamedChildren()
    if children.len >= 2:
      result = %*{
        "kind": "Infix",
        "op": %*{"kind": "Ident", "name": "and"},
        "left": canonicalize(children[0], source, profile),
        "right": canonicalize(children[1], source, profile),
        "span": newSpan(node)
      }
    else:
      result = %*{"kind": "Empty", "span": newSpan(node)}
    result.addCstRef(node, profile)

  of "type_not_constraint":
    # not T -> Prefix with not operator
    let children = node.getNamedChildren()
    if children.len >= 1:
      result = %*{
        "kind": "Prefix",
        "op": %*{"kind": "Ident", "name": "not"},
        "operand": canonicalize(children[0], source, profile),
        "span": newSpan(node)
      }
    else:
      result = %*{"kind": "Empty", "span": newSpan(node)}
    result.addCstRef(node, profile)

  of "tuple_decl":
    # Tuple unpacking: (a, b) = expr -> matches Nim's nkVarTuple structure
    # Nim puts all children (names + type + value) into elements
    var elements: seq[JsonNode] = @[]
    for child in node.namedChildren:
      case child.nodeType
      of "exported_symbol":
        elements.add canonicalize(child, source, profile)
      of "tuple_decl":
        # Nested tuple unpacking
        elements.add canonicalize(child, source, profile)
      of "expression":
        elements.add canonicalize(child, source, profile)
      else:
        discard
    result = %*{
      "kind": "Tuple",
      "elements": elements,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "proc_type", "iterator_type":
    # proc(x: int): int -> ProcType
    let paramsField = node.childByFieldName("params")
    let returnTypeField = node.childByFieldName("return_type")
    let pragmasField = node.childByFieldName("pragmas")

    result = %*{
      "kind": if node.nodeType == "proc_type": "ProcType" else: "IteratorType",
      "span": newSpan(node)
    }

    # Build params list with return type embedded
    var params: seq[JsonNode] = @[]
    var returnType: JsonNode = nil

    if returnTypeField.isSome:
      returnType = canonicalize(returnTypeField.get, source, profile)

    if paramsField.isSome:
      let paramList = paramsField.get
      for child in paramList.namedChildren:
        if child.nodeType == "param_decl":
          params.add canonicalize(child, source, profile)

    # Create ParamList with return type
    var paramListNode = %*{
      "kind": "ParamList",
      "params": params,
      "span": if paramsField.isSome: newSpan(paramsField.get) else: newSpan(node)
    }
    if returnType != nil:
      paramListNode["returnType"] = returnType

    result["params"] = paramListNode

    if pragmasField.isSome:
      result["pragmas"] = canonicalize(pragmasField.get, source, profile)

    result.addCstRef(node, profile)

  of "pointer_type":
    # pointer keyword alone is just an Ident
    result = %*{
      "kind": "Ident",
      "name": "pointer",
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "type_call":
    # type_call like typeof(x) -> Call
    let nameField = node.childByFieldName("name")
    var args: seq[JsonNode] = @[]
    for child in node.namedChildren:
      if child.nodeType == "expression":
        args.add canonicalize(child, source, profile)

    result = %*{
      "kind": "Call",
      "callee": if nameField.isSome: canonicalize(nameField.get, source, profile)
                else: %*{"kind": "Empty"},
      "args": args,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "generalized_string":
    # Generalized string like fmt"hello" or sql"""query""" becomes Call(Ident("fmt"), [StringLit("hello")])
    let text = node.text
    # Find the quote to split identifier from string content
    let quoteIdx = text.find('"')
    if quoteIdx > 0:
      let funcName = text[0 ..< quoteIdx]
      var stringContent: string
      # Check for triple-quoted string
      if text.len > quoteIdx + 5 and text[quoteIdx..quoteIdx+2] == "\"\"\"":
        # Triple-quoted: sql"""content"""
        stringContent = text[quoteIdx + 3 ..< text.len - 3]
      else:
        # Single-quoted: fmt"content"
        stringContent = text[quoteIdx + 1 ..< text.len - 1]
      result = %*{
        "kind": "Call",
        "callee": {"kind": "Ident", "name": funcName, "span": newSpan(node)},
        "args": [{"kind": "StringLit", "value": stringContent, "span": newSpan(node)}],
        "span": newSpan(node)
      }
    else:
      result = %*{
        "kind": "StringLit",
        "value": text,
        "span": newSpan(node)
      }
    result.addCstRef(node, profile)

  of "postfixable_primary", "expression_form_primary", "primary":
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = %*{"kind": "Empty", "span": newSpan(node)}

  of "type_expr":
    # Type expressions - unwrap to inner type or identifier
    let children = node.getNamedChildren()
    if children.len == 1:
      result = canonicalize(children[0], source, profile)
    elif children.len == 0:
      # Might be a simple type identifier as text
      result = %*{
        "kind": "Ident",
        "name": node.text,
        "span": newSpan(node)
      }
    else:
      result = canonicalizeStmtList(node, source, profile)

  of "tuple_type":
    # Tuple type: tuple[a: int, b: string] or tuple[a, b: int]
    var fields: seq[JsonNode] = @[]
    for child in node.namedChildren:
      if child.nodeType == "tuple_field":
        fields.add canonicalize(child, source, profile)
    result = %*{
      "kind": "TupleTy",
      "fields": fields,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "tuple_field":
    # Tuple field: a, b: int (can have multiple names)
    var names: seq[JsonNode] = @[]
    var typ: JsonNode = nil
    for child in node.namedChildren:
      if child.nodeType == "symbol":
        names.add canonicalize(child, source, profile)
      elif child.nodeType == "type_expr":
        typ = canonicalize(child, source, profile)
    result = %*{
      "kind": "IdentDefs",
      "names": names,
      "span": newSpan(node)
    }
    if typ != nil:
      result["type"] = typ
    result.addCstRef(node, profile)

  of "argument", "command_first_arg", "command_arg":
    # Handle argument wrappers
    let children = node.getNamedChildren()
    if children.len == 2 and children[0].nodeType == "symbol":
      # Named argument: x: 1 -> ExprColon
      result = %*{
        "kind": "ExprColon",
        "left": canonicalize(children[0], source, profile),
        "right": canonicalize(children[1], source, profile),
        "span": newSpan(node)
      }
      result.addCstRef(node, profile)
    elif children.len == 1:
      result = canonicalize(children[0], source, profile)
    else:
      result = canonicalizeStmtList(node, source, profile)

  of "param_list":
    var params: seq[JsonNode] = @[]
    for child in node.namedChildren:
      if child.nodeType == "param_decl":
        params.add canonicalize(child, source, profile)
    result = %*{
      "kind": "ParamList",
      "params": params,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "pragma":
    var items: seq[JsonNode] = @[]
    for child in node.namedChildren:
      items.add canonicalize(child, source, profile)
    result = %*{
      "kind": "Pragma",
      "items": items,
      "span": newSpan(node)
    }
    result.addCstRef(node, profile)

  of "import_expr":
    # import_expr contains import_path, except clause, and potentially an alias
    # import os as sys  => (import_expr (import_path ...) (symbol "sys"))
    if node.namedChildCount == 0:
      result = %*{"kind": "Empty"}
    elif node.namedChildCount >= 2:
      # Check if second child is a symbol (alias)
      let secondChild = node.namedChild(1)
      if secondChild.nodeType == "symbol":
        # This is import with alias: import os as sys
        # Nim represents this as Infix("as", os, sys)
        result = %*{
          "kind": "Infix",
          "operator": "as",
          "left": canonicalize(node.namedChild(0), source, profile),
          "right": canonicalize(secondChild, source, profile),
          "span": newSpan(node)
        }
      else:
        # Other cases (except clause, etc)
        result = canonicalize(node.namedChild(0), source, profile)
    else:
      result = canonicalize(node.namedChild(0), source, profile)

  else:
    # Fallback: create node with children
    var children: seq[JsonNode] = @[]
    for child in node.namedChildren:
      children.add canonicalize(child, source, profile)

    result = %*{
      "kind": "Unknown:" & nodeType,
      "span": newSpan(node)
    }
    if children.len > 0:
      result["children"] = %children
    result.addCstRef(node, profile)

proc canonicalizeCst*(node: Node, source: string, profile: CanonProfile = cpNim): CanonResult =
  ## Canonicalize a CST node and return result with errors
  try:
    result.ast = canonicalize(node, source, profile)
    result.errors = @[]
  except:
    result.ast = nil
    result.errors = @[CanonError(message: getCurrentExceptionMsg())]

when isMainModule:
  let source = """
proc hello*(name: string): string =
  result = "Hello, " & name

let x = 1 + 2 * 3
"""

  let parser = newParser()
  let tree = parser.parse(source)
  let canonResult = canonicalizeCst(tree.rootNode, source, cpLossless)
  echo canonResult.ast.pretty

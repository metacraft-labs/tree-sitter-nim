## Canonicalize Nim compiler PNode AST to canonical AST
##
## This module converts PNode (Nim compiler's internal AST) to our
## canonical AST representation. The canonical AST is designed to be
## structurally comparable with the AST derived from tree-sitter CST.

import std/[json, tables, strutils, options]
import compiler/ast

type
  CanonProfile* = enum
    ## Canonicalization profile
    cpLossless  ## Minimal transformation, keep debug info
    cpNim       ## Aggressive Nim-like canonicalization

  CanonError* = object
    ## Error during canonicalization
    message*: string
    path*: seq[string]
    nodeKind*: string

  CanonResult* = object
    ## Result of canonicalization
    ast*: JsonNode
    errors*: seq[CanonError]

proc newSpan(node: PNode): JsonNode =
  ## Create span object from PNode info
  ## Note: PNode only has line/col info, not byte offsets
  %*{
    "startByte": -1,  # Not available from PNode
    "endByte": -1,
    "startPoint": {
      "row": node.info.line.int - 1,  # 0-indexed
      "column": node.info.col.int
    },
    "endPoint": {
      "row": node.info.line.int - 1,
      "column": node.info.col.int
    }
  }

proc addNimRef(result: var JsonNode, node: PNode) =
  ## Add Nim PNode reference for debugging
  result["nim"] = %*{"nk": $node.kind}

proc canonicalizeIdent(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize identifier node
  result = %*{
    "kind": "Ident",
    "name": if node.kind == nkIdent: node.ident.s else: node.sym.name.s,
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeLiteral(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize literal nodes
  case node.kind
  of nkIntLit..nkUInt64Lit:
    result = %*{
      "kind": "IntLit",
      "value": $node.intVal,
      "span": newSpan(node)
    }
  of nkFloatLit..nkFloat128Lit:
    result = %*{
      "kind": "FloatLit",
      "value": $node.floatVal,
      "span": newSpan(node)
    }
  of nkStrLit:
    result = %*{
      "kind": "StringLit",
      "value": node.strVal,
      "span": newSpan(node)
    }
  of nkRStrLit:
    result = %*{
      "kind": "StringLit",
      "value": node.strVal,
      "raw": true,
      "span": newSpan(node)
    }
  of nkTripleStrLit:
    result = %*{
      "kind": "StringLit",
      "value": node.strVal,
      "triple": true,
      "span": newSpan(node)
    }
  of nkCharLit:
    result = %*{
      "kind": "CharLit",
      "value": $chr(node.intVal.int),
      "span": newSpan(node)
    }
  of nkNilLit:
    result = %*{
      "kind": "NilLit",
      "span": newSpan(node)
    }
  else:
    result = %*{
      "kind": "Unknown",
      "nodeKind": $node.kind,
      "span": newSpan(node)
    }

  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalize*(node: PNode, profile: CanonProfile = cpNim): JsonNode

proc canonicalizeChildren(node: PNode, profile: CanonProfile): seq[JsonNode] =
  ## Canonicalize all children
  result = @[]
  for i in 0 ..< node.safeLen:
    if node[i] != nil:
      result.add canonicalize(node[i], profile)

proc canonicalizeInfix(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize infix expression
  # nkInfix: [0] = operator, [1] = left, [2] = right
  let opNode = node[0]
  let opName = if opNode.kind == nkIdent: opNode.ident.s
               elif opNode.kind == nkSym: opNode.sym.name.s
               else: ""

  result = %*{
    "kind": "Infix",
    "operator": opName,
    "left": canonicalize(node[1], profile),
    "right": canonicalize(node[2], profile),
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizePrefix(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize prefix expression
  # nkPrefix: [0] = operator, [1] = operand
  let opNode = node[0]
  let opName = if opNode.kind == nkIdent: opNode.ident.s
               elif opNode.kind == nkSym: opNode.sym.name.s
               else: ""

  result = %*{
    "kind": "Prefix",
    "operator": opName,
    "operand": canonicalize(node[1], profile),
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeCall(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize call expression
  # nkCall/nkCommand: [0] = callee, [1..n] = arguments
  var args: seq[JsonNode] = @[]
  for i in 1 ..< node.safeLen:
    if node[i] != nil:
      args.add canonicalize(node[i], profile)

  let kind = if node.kind == nkCommand: "Command" else: "Call"

  result = %*{
    "kind": kind,
    "callee": canonicalize(node[0], profile),
    "args": args,
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeDot(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize dot expression
  # nkDotExpr: [0] = base, [1] = field
  result = %*{
    "kind": "Dot",
    "base": canonicalize(node[0], profile),
    "field": canonicalize(node[1], profile),
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeIndex(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize bracket/index expression
  # nkBracketExpr: [0] = base, [1..n] = indices
  var indices: seq[JsonNode] = @[]
  for i in 1 ..< node.safeLen:
    if node[i] != nil:
      indices.add canonicalize(node[i], profile)

  result = %*{
    "kind": "Index",
    "base": canonicalize(node[0], profile),
    "indices": indices,
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeIf(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize if expression/statement
  var branches: seq[JsonNode] = @[]
  var elseBranch: JsonNode = nil

  for i in 0 ..< node.safeLen:
    let branch = node[i]
    if branch == nil:
      continue

    case branch.kind
    of nkElifBranch, nkElifExpr:
      branches.add %*{
        "condition": canonicalize(branch[0], profile),
        "body": canonicalize(branch[1], profile)
      }
    of nkElse, nkElseExpr:
      elseBranch = canonicalize(branch[0], profile)
    else:
      discard

  result = %*{
    "kind": if node.kind == nkIfExpr: "IfExpr" else: "IfStmt",
    "branches": branches,
    "span": newSpan(node)
  }
  if elseBranch != nil:
    result["elseBranch"] = elseBranch
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeCase(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize case statement
  var branches: seq[JsonNode] = @[]
  var elseBranch: JsonNode = nil

  # [0] = expression, [1..n] = branches
  for i in 1 ..< node.safeLen:
    let branch = node[i]
    if branch == nil:
      continue

    case branch.kind
    of nkOfBranch:
      var patterns: seq[JsonNode] = @[]
      for j in 0 ..< branch.safeLen - 1:
        patterns.add canonicalize(branch[j], profile)
      branches.add %*{
        "patterns": patterns,
        "body": canonicalize(branch[branch.safeLen - 1], profile)
      }
    of nkElse:
      elseBranch = canonicalize(branch[0], profile)
    else:
      discard

  result = %*{
    "kind": "CaseStmt",
    "expr": canonicalize(node[0], profile),
    "branches": branches,
    "span": newSpan(node)
  }
  if elseBranch != nil:
    result["elseBranch"] = elseBranch
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeWhile(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize while statement
  result = %*{
    "kind": "WhileStmt",
    "condition": canonicalize(node[0], profile),
    "body": canonicalize(node[1], profile),
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeFor(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize for statement
  # nkForStmt: [0..n-2] = loop vars, [n-1] = iterator, [n] = body
  var vars: seq[JsonNode] = @[]
  for i in 0 ..< node.safeLen - 2:
    vars.add canonicalize(node[i], profile)

  result = %*{
    "kind": "ForStmt",
    "vars": vars,
    "iter": canonicalize(node[node.safeLen - 2], profile),
    "body": canonicalize(node[node.safeLen - 1], profile),
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeTry(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize try statement
  var excepts: seq[JsonNode] = @[]
  var finallyBranch: JsonNode = nil

  for i in 1 ..< node.safeLen:
    let branch = node[i]
    if branch == nil:
      continue

    case branch.kind
    of nkExceptBranch:
      var types: seq[JsonNode] = @[]
      for j in 0 ..< branch.safeLen - 1:
        types.add canonicalize(branch[j], profile)
      excepts.add %*{
        "types": types,
        "body": canonicalize(branch[branch.safeLen - 1], profile)
      }
    of nkFinally:
      finallyBranch = canonicalize(branch[0], profile)
    else:
      discard

  result = %*{
    "kind": "TryStmt",
    "body": canonicalize(node[0], profile),
    "excepts": excepts,
    "span": newSpan(node)
  }
  if finallyBranch != nil:
    result["finally"] = finallyBranch
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeBlock(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize block statement/expression
  result = %*{
    "kind": if node.kind == nkBlockExpr: "BlockExpr" else: "BlockStmt",
    "span": newSpan(node)
  }

  if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
    result["name"] = canonicalize(node[0], profile)

  if node.safeLen > 1:
    result["body"] = canonicalize(node[1], profile)

  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeStmtList(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize statement list
  var stmts: seq[JsonNode] = @[]
  for i in 0 ..< node.safeLen:
    if node[i] != nil and node[i].kind != nkEmpty:
      stmts.add canonicalize(node[i], profile)

  result = %*{
    "kind": "StmtList",
    "stmts": stmts,
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeRoutine(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize proc/func/method/etc definition
  let routineKind = case node.kind
    of nkProcDef: "proc"
    of nkFuncDef: "func"
    of nkMethodDef: "method"
    of nkIteratorDef: "iterator"
    of nkMacroDef: "macro"
    of nkTemplateDef: "template"
    of nkConverterDef: "converter"
    else: "proc"

  # nkProcDef: [0]=name, [1]=pattern, [2]=generic, [3]=params, [4]=pragmas, [5]=reserved, [6]=body
  result = %*{
    "kind": "RoutineDef",
    "routineKind": routineKind,
    "span": newSpan(node)
  }

  # Name (handle exported symbols)
  if node.safeLen > 0 and node[0] != nil:
    let nameNode = node[0]
    if nameNode.kind == nkPostfix:
      # Exported: postfix(*, name)
      result["name"] = canonicalize(nameNode[1], profile)
      result["exported"] = %true
    else:
      result["name"] = canonicalize(nameNode, profile)

  # Generic params
  if node.safeLen > 2 and node[2] != nil and node[2].kind != nkEmpty:
    result["genericParams"] = canonicalize(node[2], profile)

  # Params
  if node.safeLen > 3 and node[3] != nil and node[3].kind != nkEmpty:
    result["params"] = canonicalize(node[3], profile)

  # Pragmas
  if node.safeLen > 4 and node[4] != nil and node[4].kind != nkEmpty:
    result["pragmas"] = canonicalize(node[4], profile)

  # Body
  if node.safeLen > 6 and node[6] != nil and node[6].kind != nkEmpty:
    result["body"] = canonicalize(node[6], profile)

  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeSection(node: PNode, kind: string, defKind: string, profile: CanonProfile): JsonNode =
  ## Canonicalize const/let/var/type sections
  var defs: seq[JsonNode] = @[]
  for i in 0 ..< node.safeLen:
    if node[i] != nil:
      var def = canonicalize(node[i], profile)
      def["kind"] = %defKind
      defs.add def

  result = %*{
    "kind": kind,
    "defs": defs,
    "span": newSpan(node)
  }
  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeIdentDefs(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize identifier definitions (used in let/var/param)
  # nkIdentDefs: [0..n-2] = names, [n-1] = type, [n] = value
  var names: seq[JsonNode] = @[]
  for i in 0 ..< node.safeLen - 2:
    let nameNode = node[i]
    if nameNode.kind == nkPostfix:
      names.add canonicalize(nameNode[1], profile)
    else:
      names.add canonicalize(nameNode, profile)

  result = %*{
    "kind": "IdentDefs",
    "names": names,
    "span": newSpan(node)
  }

  # Type
  if node.safeLen >= 2 and node[node.safeLen - 2] != nil and node[node.safeLen - 2].kind != nkEmpty:
    result["type"] = canonicalize(node[node.safeLen - 2], profile)

  # Value
  if node.safeLen >= 1 and node[node.safeLen - 1] != nil and node[node.safeLen - 1].kind != nkEmpty:
    result["value"] = canonicalize(node[node.safeLen - 1], profile)

  # Check for exported
  for i in 0 ..< node.safeLen - 2:
    if node[i].kind == nkPostfix:
      result["exported"] = %true
      break

  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalizeTypeDef(node: PNode, profile: CanonProfile): JsonNode =
  ## Canonicalize type definition
  # nkTypeDef: [0] = name, [1] = generic, [2] = value
  result = %*{
    "kind": "TypeDef",
    "span": newSpan(node)
  }

  if node.safeLen > 0 and node[0] != nil:
    let nameNode = node[0]
    if nameNode.kind == nkPostfix:
      result["name"] = canonicalize(nameNode[1], profile)
      result["exported"] = %true
    elif nameNode.kind == nkPragmaExpr:
      # Name with pragma
      if nameNode.safeLen > 0:
        if nameNode[0].kind == nkPostfix:
          result["name"] = canonicalize(nameNode[0][1], profile)
          result["exported"] = %true
        else:
          result["name"] = canonicalize(nameNode[0], profile)
      if nameNode.safeLen > 1:
        result["pragmas"] = canonicalize(nameNode[1], profile)
    else:
      result["name"] = canonicalize(nameNode, profile)

  if node.safeLen > 1 and node[1] != nil and node[1].kind != nkEmpty:
    result["genericParams"] = canonicalize(node[1], profile)

  if node.safeLen > 2 and node[2] != nil:
    result["value"] = canonicalize(node[2], profile)

  if profile == cpLossless:
    result.addNimRef(node)

proc canonicalize*(node: PNode, profile: CanonProfile = cpNim): JsonNode =
  ## Main canonicalization entry point
  if node == nil:
    return %*{"kind": "Empty", "span": {"startByte": -1, "endByte": -1, "startPoint": {"row": 0, "column": 0}, "endPoint": {"row": 0, "column": 0}}}

  case node.kind
  of nkIdent, nkSym:
    result = canonicalizeIdent(node, profile)
  of nkIntLit..nkUInt64Lit, nkFloatLit..nkFloat128Lit,
     nkStrLit, nkRStrLit, nkTripleStrLit, nkCharLit, nkNilLit:
    result = canonicalizeLiteral(node, profile)
  of nkInfix:
    result = canonicalizeInfix(node, profile)
  of nkPrefix:
    result = canonicalizePrefix(node, profile)
  of nkCall, nkCallStrLit, nkCommand:
    result = canonicalizeCall(node, profile)
  of nkDotExpr:
    result = canonicalizeDot(node, profile)
  of nkBracketExpr:
    result = canonicalizeIndex(node, profile)
  of nkIfExpr, nkIfStmt:
    result = canonicalizeIf(node, profile)
  of nkCaseStmt:
    result = canonicalizeCase(node, profile)
  of nkWhileStmt:
    result = canonicalizeWhile(node, profile)
  of nkForStmt:
    result = canonicalizeFor(node, profile)
  of nkTryStmt:
    result = canonicalizeTry(node, profile)
  of nkBlockExpr, nkBlockStmt:
    result = canonicalizeBlock(node, profile)
  of nkStmtList, nkStmtListExpr:
    result = canonicalizeStmtList(node, profile)
  of nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef,
     nkMacroDef, nkTemplateDef, nkConverterDef:
    result = canonicalizeRoutine(node, profile)
  of nkLambda, nkDo:
    # Anonymous proc/lambda
    result = %*{
      "kind": "Lambda",
      "routineKind": "proc",
      "span": newSpan(node)
    }
    # Params
    if node.safeLen > 3 and node[3] != nil and node[3].kind != nkEmpty:
      result["params"] = canonicalize(node[3], profile)
    # Pragmas
    if node.safeLen > 4 and node[4] != nil and node[4].kind != nkEmpty:
      result["pragmas"] = canonicalize(node[4], profile)
    # Body
    if node.safeLen > 6 and node[6] != nil and node[6].kind != nkEmpty:
      result["body"] = canonicalize(node[6], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkConstSection:
    result = canonicalizeSection(node, "ConstSection", "ConstDef", profile)
  of nkLetSection:
    result = canonicalizeSection(node, "LetSection", "LetDef", profile)
  of nkVarSection:
    result = canonicalizeSection(node, "VarSection", "VarDef", profile)
  of nkTypeSection:
    result = canonicalizeSection(node, "TypeSection", "TypeDef", profile)
  of nkUsingStmt:
    result = canonicalizeSection(node, "UsingSection", "UsingDef", profile)
  of nkIdentDefs, nkConstDef:
    result = canonicalizeIdentDefs(node, profile)
  of nkTypeDef:
    result = canonicalizeTypeDef(node, profile)
  of nkReturnStmt:
    result = %*{
      "kind": "Return",
      "span": newSpan(node)
    }
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["value"] = canonicalize(node[0], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkDiscardStmt:
    result = %*{
      "kind": "Discard",
      "span": newSpan(node)
    }
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["value"] = canonicalize(node[0], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkAsgn:
    result = %*{
      "kind": "Assign",
      "left": canonicalize(node[0], profile),
      "right": canonicalize(node[1], profile),
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkPar:
    # Parenthesized expression - unwrap to just the inner expression
    if node.safeLen == 1:
      result = canonicalize(node[0], profile)
    else:
      # Tuple
      var elements: seq[JsonNode] = @[]
      for child in node:
        elements.add canonicalize(child, profile)
      result = %*{
        "kind": "Tuple",
        "elements": elements,
        "span": newSpan(node)
      }
      if profile == cpLossless:
        result.addNimRef(node)
  of nkTupleConstr:
    var elements: seq[JsonNode] = @[]
    for child in node:
      elements.add canonicalize(child, profile)
    result = %*{
      "kind": "Tuple",
      "elements": elements,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkBracket:
    var elements: seq[JsonNode] = @[]
    for child in node:
      elements.add canonicalize(child, profile)
    result = %*{
      "kind": "Array",
      "elements": elements,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkCurly:
    var elements: seq[JsonNode] = @[]
    for child in node:
      elements.add canonicalize(child, profile)
    result = %*{
      "kind": "Set",
      "elements": elements,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkRange:
    result = %*{
      "kind": "Range",
      "start": canonicalize(node[0], profile),
      "stop": canonicalize(node[1], profile),
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkEmpty:
    result = %*{
      "kind": "Empty",
      "span": newSpan(node)
    }
  of nkPragma:
    var items: seq[JsonNode] = @[]
    for child in node:
      items.add canonicalize(child, profile)
    result = %*{
      "kind": "Pragma",
      "items": items,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkFormalParams:
    var params: seq[JsonNode] = @[]
    # [0] = return type, [1..n] = params
    for i in 1 ..< node.safeLen:
      params.add canonicalize(node[i], profile)
    result = %*{
      "kind": "ParamList",
      "params": params,
      "span": newSpan(node)
    }
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["returnType"] = canonicalize(node[0], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkYieldStmt:
    result = %*{
      "kind": "Yield",
      "span": newSpan(node)
    }
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["value"] = canonicalize(node[0], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkRaiseStmt:
    result = %*{
      "kind": "Raise",
      "span": newSpan(node)
    }
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["value"] = canonicalize(node[0], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkBreakStmt:
    result = %*{
      "kind": "Break",
      "span": newSpan(node)
    }
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["label"] = canonicalize(node[0], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkContinueStmt:
    result = %*{
      "kind": "Continue",
      "span": newSpan(node)
    }
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["label"] = canonicalize(node[0], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkBindStmt:
    var items: seq[JsonNode] = @[]
    for child in node:
      items.add canonicalize(child, profile)
    result = %*{
      "kind": "Bind",
      "items": items,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkMixinStmt:
    var items: seq[JsonNode] = @[]
    for child in node:
      items.add canonicalize(child, profile)
    result = %*{
      "kind": "Mixin",
      "items": items,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkImportStmt, nkImportExceptStmt:
    var items: seq[JsonNode] = @[]
    for child in node:
      items.add canonicalize(child, profile)
    result = %*{
      "kind": "Import",
      "items": items,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkFromStmt:
    var module: JsonNode = nil
    var items: seq[JsonNode] = @[]
    for i in 0 ..< node.safeLen:
      if i == 0:
        module = canonicalize(node[i], profile)
      else:
        items.add canonicalize(node[i], profile)
    result = %*{
      "kind": "FromImport",
      "module": module,
      "items": items,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkExportStmt, nkExportExceptStmt:
    var items: seq[JsonNode] = @[]
    for child in node:
      items.add canonicalize(child, profile)
    result = %*{
      "kind": "Export",
      "items": items,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkIncludeStmt:
    var items: seq[JsonNode] = @[]
    for child in node:
      items.add canonicalize(child, profile)
    result = %*{
      "kind": "Include",
      "items": items,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkWhenStmt:
    var branches: seq[JsonNode] = @[]
    var elseBranch: JsonNode = nil
    for i in 0 ..< node.safeLen:
      let branch = node[i]
      if branch == nil:
        continue
      case branch.kind
      of nkElifBranch, nkElifExpr:
        branches.add %*{
          "condition": canonicalize(branch[0], profile),
          "body": canonicalize(branch[1], profile)
        }
      of nkElse, nkElseExpr:
        elseBranch = canonicalize(branch[0], profile)
      else:
        discard
    result = %*{
      "kind": "When",
      "branches": branches,
      "span": newSpan(node)
    }
    if elseBranch != nil:
      result["elseBranch"] = elseBranch
    if profile == cpLossless:
      result.addNimRef(node)
  of nkStaticStmt:
    result = %*{
      "kind": "Static",
      "body": if node.safeLen > 0: canonicalize(node[0], profile) else: %*{"kind": "Empty"},
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkDefer:
    result = %*{
      "kind": "Defer",
      "body": if node.safeLen > 0: canonicalize(node[0], profile) else: %*{"kind": "Empty"},
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkAsmStmt:
    result = %*{
      "kind": "Asm",
      "span": newSpan(node)
    }
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["pragmas"] = canonicalize(node[0], profile)
    if node.safeLen > 1 and node[1] != nil:
      result["code"] = canonicalize(node[1], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkTableConstr:
    # Table constructor {key: value, ...}
    var elements: seq[JsonNode] = @[]
    for child in node:
      elements.add canonicalize(child, profile)
    result = %*{
      "kind": "TableConstr",
      "elements": elements,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkPtrTy:
    # ptr T
    result = %*{
      "kind": "PtrType",
      "base": if node.safeLen > 0: canonicalize(node[0], profile) else: %*{"kind": "Empty"},
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkRefTy:
    # ref T
    result = %*{
      "kind": "RefType",
      "base": if node.safeLen > 0: canonicalize(node[0], profile) else: %*{"kind": "Empty"},
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkTupleTy:
    # Tuple type: tuple[a: int, b: string]
    var fields: seq[JsonNode] = @[]
    for i in 0 ..< node.safeLen:
      if node[i] != nil and node[i].kind != nkEmpty:
        fields.add canonicalize(node[i], profile)
    result = %*{
      "kind": "TupleTy",
      "fields": fields,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkExprColonExpr:
    # key: value expression
    result = %*{
      "kind": "ExprColon",
      "left": canonicalize(node[0], profile),
      "right": canonicalize(node[1], profile),
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkCurlyExpr:
    # Curly expression: f{1, 2}
    var callee: JsonNode = nil
    var elements: seq[JsonNode] = @[]
    for i in 0 ..< node.safeLen:
      if node[i] != nil:
        if i == 0:
          callee = canonicalize(node[i], profile)
        else:
          elements.add canonicalize(node[i], profile)
    result = %*{
      "kind": "CurlyExpr",
      "callee": if callee != nil: callee else: %*{"kind": "Empty"},
      "elements": elements,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkEnumTy:
    # Enum type
    var fields: seq[JsonNode] = @[]
    for i in 0 ..< node.safeLen:
      if node[i] != nil and node[i].kind != nkEmpty:
        fields.add canonicalize(node[i], profile)
    result = %*{
      "kind": "EnumType",
      "fields": fields,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkEnumFieldDef:
    # Enum field: name [= value]
    result = %*{
      "kind": "EnumField",
      "span": newSpan(node)
    }
    if node.safeLen > 0:
      result["name"] = canonicalize(node[0], profile)
    if node.safeLen > 1 and node[1].kind != nkEmpty:
      result["value"] = canonicalize(node[1], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkObjectTy:
    # Object type
    var fields: seq[JsonNode] = @[]
    var parent: JsonNode = nil
    for i in 0 ..< node.safeLen:
      if node[i] == nil:
        continue
      case node[i].kind
      of nkOfInherit:
        if node[i].safeLen > 0:
          parent = canonicalize(node[i][0], profile)
      of nkRecList:
        fields.add canonicalize(node[i], profile)
      of nkRecCase:
        fields.add canonicalize(node[i], profile)
      else:
        discard
    result = %*{
      "kind": "ObjectType",
      "fields": fields,
      "span": newSpan(node)
    }
    if parent != nil:
      result["parent"] = parent
    if profile == cpLossless:
      result.addNimRef(node)
  of nkTypeClassTy:
    # Concept type
    var params: seq[JsonNode] = @[]
    var body: JsonNode = nil
    for i in 0 ..< node.safeLen:
      if node[i] == nil:
        continue
      case node[i].kind
      of nkArgList:
        for j in 0 ..< node[i].safeLen:
          params.add canonicalize(node[i][j], profile)
      of nkStmtList:
        body = canonicalize(node[i], profile)
      else:
        discard
    result = %*{
      "kind": "TypeClass",
      "params": params,
      "span": newSpan(node)
    }
    if body != nil:
      result["body"] = body
    if profile == cpLossless:
      result.addNimRef(node)
  of nkProcTy:
    # Proc type: proc(x: int): int
    result = %*{
      "kind": "ProcType",
      "span": newSpan(node)
    }
    # [0] = formal params, [1] = pragmas
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["params"] = canonicalize(node[0], profile)
    if node.safeLen > 1 and node[1] != nil and node[1].kind != nkEmpty:
      result["pragmas"] = canonicalize(node[1], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkIteratorTy:
    # Iterator type
    result = %*{
      "kind": "IteratorType",
      "span": newSpan(node)
    }
    if node.safeLen > 0 and node[0] != nil and node[0].kind != nkEmpty:
      result["params"] = canonicalize(node[0], profile)
    if node.safeLen > 1 and node[1] != nil and node[1].kind != nkEmpty:
      result["pragmas"] = canonicalize(node[1], profile)
    if profile == cpLossless:
      result.addNimRef(node)
  of nkVarTuple:
    # Tuple for destructuring: (a, b) = ...
    var elements: seq[JsonNode] = @[]
    for i in 0 ..< node.safeLen:
      if node[i] != nil and node[i].kind != nkEmpty:
        elements.add canonicalize(node[i], profile)
    result = %*{
      "kind": "Tuple",
      "elements": elements,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkAccQuoted:
    # Quoted identifier `foo` or `hello world`
    # Concatenate all identifiers inside with spaces
    var parts: seq[string] = @[]
    for i in 0 ..< node.safeLen:
      if node[i] != nil and node[i].kind == nkIdent:
        parts.add node[i].ident.s
    result = %*{
      "kind": "Ident",
      "name": parts.join(" "),
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  of nkObjConstr:
    # Object constructor: Type(field: value, ...)
    var callee: JsonNode = nil
    var args: seq[JsonNode] = @[]
    for i in 0 ..< node.safeLen:
      if node[i] == nil:
        continue
      if i == 0:
        callee = canonicalize(node[i], profile)
      else:
        args.add canonicalize(node[i], profile)
    result = %*{
      "kind": "Call",
      "callee": if callee != nil: callee else: %*{"kind": "Empty"},
      "args": args,
      "span": newSpan(node)
    }
    if profile == cpLossless:
      result.addNimRef(node)
  else:
    # Fallback: create generic node with children
    result = %*{
      "kind": "Unknown:" & $node.kind,
      "span": newSpan(node)
    }
    if node.safeLen > 0:
      result["children"] = %canonicalizeChildren(node, profile)
    if profile == cpLossless:
      result.addNimRef(node)

proc canonicalizePNode*(node: PNode, profile: CanonProfile = cpNim): CanonResult =
  ## Canonicalize a PNode and return result with errors
  try:
    result.ast = canonicalize(node, profile)
    result.errors = @[]
  except:
    result.ast = nil
    result.errors = @[CanonError(message: getCurrentExceptionMsg())]

when isMainModule:
  import ../tests/nim/nim_parser_bridge

  let source = """
proc hello*(name: string): string =
  result = "Hello, " & name

let x = 1 + 2 * 3
"""

  let parseResult = parseWithNimCompiler(source)
  if parseResult.success:
    let canonResult = canonicalizePNode(parseResult.node, cpLossless)
    echo canonResult.ast.pretty
  else:
    echo "Parse failed"

## Nim compiler parser bridge
##
## This module provides an interface to the Nim compiler's parser,
## allowing us to parse Nim source code and access the resulting PNode AST.
## This is used for meaning-fidelity testing against the canonical parser.

import std/[os, strutils, strformat]

# Import Nim compiler modules
import compiler/[
  ast,
  idents,
  options,
  parser,
  llstream,
  pathutils,
  lineinfos,
  msgs
]

# Suppress Nim compiler's writeln output
var suppressOutput = false

proc hookWriteln(output: string) =
  if not suppressOutput:
    echo output

type
  ParseResult* = object
    ## Result of parsing with Nim compiler
    success*: bool
    node*: PNode
    errors*: seq[string]
    filename*: string

  NimParserError* = object of CatchableError
    ## Error during Nim parsing

proc nimVersion*(): string =
  ## Get the Nim compiler version
  NimVersion

proc parseWithNimCompiler*(source: string, filename: string = "test.nim"): ParseResult =
  ## Parse source code using the Nim compiler's parser
  ##
  ## Returns the resulting PNode AST and any errors encountered.
  result.filename = filename
  result.errors = @[]

  # Create identifier cache (shared across parses for efficiency)
  let cache = newIdentCache()

  # Create configuration
  let conf = newConfigRef()

  # Suppress most messages by clearing note sets
  conf.notes = {}
  conf.foreignPackageNotes = {}
  conf.mainPackageNotes = {}

  # Set high error max to prevent early quit
  conf.errorMax = 1000

  # Set up structured error hook to capture errors
  var capturedErrors: seq[string] = @[]
  conf.structuredErrorHook = proc(config: ConfigRef; info: TLineInfo; msg: string; severity: Severity) =
    capturedErrors.add(msg)

  # Suppress writeln output
  suppressOutput = true
  conf.writelnHook = hookWriteln

  # Create a stream from the source
  let stream = llStreamOpen(source)
  if stream.isNil:
    result.success = false
    result.errors.add "Failed to create stream from source"
    return

  try:
    # Parse the source
    var p: Parser
    openParser(p, AbsoluteFile(filename), stream, cache, conf)

    result.node = parseAll(p)

    # Check if there were any errors
    if capturedErrors.len > 0 or conf.errorCounter > 0:
      result.success = false
      result.errors = capturedErrors
      if capturedErrors.len == 0:
        result.errors.add "Parse failed with " & $conf.errorCounter & " error(s)"
    else:
      result.success = true

    closeParser(p)
  except CatchableError:
    result.success = false
    result.errors.add getCurrentExceptionMsg()
  except Defect:
    result.success = false
    result.errors.add "Defect: " & getCurrentExceptionMsg()
  finally:
    suppressOutput = false

proc nodeKindName*(node: PNode): string =
  ## Get the string name of a PNode's kind
  $node.kind

proc nodeInfo*(node: PNode): tuple[line: int, col: int] =
  ## Get line/column info for a node
  (node.info.line.int, node.info.col.int)

proc hasChildren*(node: PNode): bool =
  ## Check if node has children
  node.safeLen > 0

proc childCount*(node: PNode): int =
  ## Get the number of children
  node.safeLen

proc child*(node: PNode, idx: int): PNode =
  ## Get child at index
  if idx >= 0 and idx < node.safeLen:
    node[idx]
  else:
    nil

iterator children*(node: PNode): PNode =
  ## Iterate over children
  for i in 0 ..< node.safeLen:
    yield node[i]

proc identName*(node: PNode): string =
  ## Get the name of an identifier node
  if node.kind == nkIdent:
    node.ident.s
  elif node.kind == nkSym:
    node.sym.name.s
  else:
    ""

proc intVal*(node: PNode): BiggestInt =
  ## Get integer value
  if node.kind in {nkIntLit..nkUInt64Lit}:
    node.intVal
  else:
    0

proc floatVal*(node: PNode): BiggestFloat =
  ## Get float value
  if node.kind in {nkFloatLit..nkFloat128Lit}:
    node.floatVal
  else:
    0.0

proc strVal*(node: PNode): string =
  ## Get string value
  if node.kind in {nkStrLit..nkTripleStrLit}:
    node.strVal
  else:
    ""

proc charVal*(node: PNode): char =
  ## Get char value
  if node.kind == nkCharLit:
    chr(node.intVal.int)
  else:
    '\0'

proc isError*(node: PNode): bool =
  ## Check if node is an error node
  node.kind == nkError

proc walk*(node: PNode): iterator(): PNode =
  ## Pre-order walk of the AST
  result = iterator(): PNode =
    var stack: seq[PNode] = @[node]
    while stack.len > 0:
      let current = stack.pop()
      if current.isNil:
        continue
      yield current
      # Add children in reverse order for left-to-right traversal
      for i in countdown(current.safeLen - 1, 0):
        stack.add current[i]

proc treeRepr*(node: PNode, indent: int = 0): string =
  ## Get a tree representation of the AST (for debugging)
  let prefix = "  ".repeat(indent)

  result = prefix & $node.kind

  case node.kind
  of nkIdent:
    result.add ": " & node.ident.s
  of nkSym:
    result.add ": " & node.sym.name.s
  of nkIntLit..nkUInt64Lit:
    result.add ": " & $node.intVal
  of nkFloatLit..nkFloat128Lit:
    result.add ": " & $node.floatVal
  of nkStrLit..nkTripleStrLit:
    result.add ": \"" & node.strVal & "\""
  of nkCharLit:
    result.add ": '" & $chr(node.intVal.int) & "'"
  else:
    discard

  result.add "\n"

  for child in node.children:
    if child != nil:
      result.add treeRepr(child, indent + 1)

proc pnodeKindToCanonical*(kind: TNodeKind): string =
  ## Map PNode kind to canonical AST kind
  ##
  ## This provides the mapping from Nim's internal node kinds to our
  ## canonical AST node kinds.
  case kind
  of nkIdent, nkSym:
    "Ident"
  of nkIntLit..nkUInt64Lit:
    "IntLit"
  of nkFloatLit..nkFloat128Lit:
    "FloatLit"
  of nkStrLit, nkRStrLit:
    "StringLit"
  of nkTripleStrLit:
    "StringLit"  # Triple string is still a string
  of nkCharLit:
    "CharLit"
  of nkNilLit:
    "NilLit"
  of nkInfix:
    "Infix"
  of nkPrefix:
    "Prefix"
  of nkPostfix:
    "Postfix"  # Export marker a*
  of nkCall, nkCallStrLit:
    "Call"
  of nkCommand:
    "Command"
  of nkDotExpr:
    "Dot"
  of nkBracketExpr:
    "Index"
  of nkCurlyExpr:
    "CurlyIndex"
  of nkIfExpr, nkIfStmt:
    "IfExpr"
  of nkWhenStmt:
    "WhenStmt"
  of nkCaseStmt:
    "CaseStmt"
  of nkWhileStmt:
    "WhileStmt"
  of nkForStmt:
    "ForStmt"
  of nkTryStmt:
    "TryStmt"
  of nkBlockExpr, nkBlockStmt:
    "BlockExpr"
  of nkStmtList, nkStmtListExpr:
    "StmtList"
  of nkAsgn:
    "Assign"
  of nkReturnStmt:
    "Return"
  of nkRaiseStmt:
    "Raise"
  of nkYieldStmt:
    "Yield"
  of nkDiscardStmt:
    "Discard"
  of nkBreakStmt:
    "Break"
  of nkContinueStmt:
    "Continue"
  of nkImportStmt, nkImportExceptStmt:
    "Import"
  of nkExportStmt, nkExportExceptStmt:
    "Export"
  of nkFromStmt:
    "FromImport"
  of nkConstSection:
    "ConstSection"
  of nkLetSection:
    "LetSection"
  of nkVarSection:
    "VarSection"
  of nkTypeSection:
    "TypeSection"
  of nkConstDef:
    "ConstDef"
  of nkIdentDefs:
    "IdentDefs"  # Used in let/var/param declarations
  of nkTypeDef:
    "TypeDef"
  of nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef,
     nkMacroDef, nkTemplateDef, nkConverterDef:
    "RoutineDef"
  of nkLambda, nkDo:
    "Lambda"
  of nkFormalParams:
    "ParamList"
  of nkGenericParams:
    "GenericParams"
  of nkPragma:
    "Pragma"
  of nkPragmaExpr:
    "PragmaExpr"
  of nkPar:
    "Paren"  # Parenthesized expression or tuple
  of nkTupleConstr:
    "Tuple"
  of nkBracket:
    "Array"
  of nkCurly:
    "Set"
  of nkTableConstr:
    "TableConstr"
  of nkRange:
    "Range"
  of nkRefTy:
    "RefType"
  of nkPtrTy:
    "PtrType"
  of nkVarTy:
    "VarType"
  of nkDistinctTy:
    "DistinctType"
  of nkProcTy:
    "ProcType"
  of nkIteratorTy:
    "IteratorType"
  of nkTupleClassTy:
    "TupleType"
  of nkTupleTy:
    "TupleType"
  of nkObjectTy:
    "ObjectType"
  of nkEnumTy:
    "EnumType"
  of nkEnumFieldDef:
    "EnumField"
  of nkRecList:
    "RecordFields"
  of nkRecCase:
    "RecordCase"
  of nkOfBranch:
    "OfBranch"
  of nkElifBranch:
    "ElifBranch"
  of nkElse:
    "ElseBranch"
  of nkExceptBranch:
    "ExceptBranch"
  of nkFinally:
    "FinallyBranch"
  of nkEmpty:
    "Empty"
  of nkCommentStmt:
    "Comment"
  of nkAsmStmt:
    "Asm"
  of nkDefer:
    "Defer"
  of nkStaticStmt:
    "Static"
  of nkBindStmt:
    "Bind"
  of nkMixinStmt:
    "Mixin"
  of nkIncludeStmt:
    "Include"
  of nkUsingStmt:
    "Using"
  of nkCast:
    "Cast"
  of nkObjConstr:
    "ObjConstr"
  of nkExprColonExpr:
    "ExprColon"  # key: value
  of nkExprEqExpr:
    "ExprEq"  # key = value
  of nkAccQuoted:
    "AccQuoted"  # `identifier`
  else:
    "Unknown:" & $kind

when isMainModule:
  # Test the Nim parser bridge
  echo "Nim version: ", nimVersion()

  let testCases = @[
    "let x = 1",
    "proc foo() = discard",
    "let x = 1 + 2 * 3",
    """
proc hello*(name: string): string =
  result = "Hello, " & name
""",
  ]

  for source in testCases:
    echo "\n--- Test ---"
    echo "Source: ", source.replace("\n", "\\n")

    let result = parseWithNimCompiler(source)

    if result.success:
      echo "Parse successful"
      echo "\nAST:"
      echo treeRepr(result.node)
    else:
      echo "Parse failed:"
      for err in result.errors:
        echo "  ", err

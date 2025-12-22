## Test runner for tree-sitter-nim
##
## Runs byte-fidelity and meaning-fidelity tests on the corpus.
## Usage:
##   nim c -r tests/nim/test_runner.nim [options]
##
## Options:
##   --bytes-only     Run only byte-fidelity tests
##   --nim-only       Run only Nim parity tests
##   --verbose        Print detailed output
##   --filter=NAME    Only run tests matching NAME
##   --corpus=PATH    Path to corpus directory (default: test/corpus)

import std/[os, strutils, strformat, times, json, terminal, parseopt]

import corpus_loader
import ts_parser_bridge
import reconstruct_bytes
import nim_parser_bridge
import ../../ast/nim/canonicalize_cst
import ../../ast/nim/canonicalize_pnode

type
  TestResult = object
    test: CorpusTest
    byteFidelityPassed: bool
    byteFidelityMessage: string
    nimParityPassed: bool
    nimParityMessage: string
    skippedBytes: bool
    skippedNim: bool
    xfailNim: bool

  TestStats = object
    total: int
    passed: int
    failed: int
    skipped: int
    xfailPassed: int  # Expected failures that failed (good)
    xfailFailed: int  # Expected failures that passed (unexpected)

  RunOptions = object
    bytesOnly: bool
    nimOnly: bool
    verbose: bool
    filter: string
    corpusPath: string

proc colorize(s: string, color: ForegroundColor): string =
  if isatty(stdout):
    result = ansiForegroundColorCode(color) & s & ansiResetCode
  else:
    result = s

proc green(s: string): string = colorize(s, fgGreen)
proc red(s: string): string = colorize(s, fgRed)
proc yellow(s: string): string = colorize(s, fgYellow)
proc cyan(s: string): string = colorize(s, fgCyan)

proc runByteFidelityTest(test: CorpusTest, parser: Parser): tuple[passed: bool, message: string] =
  ## Run byte-fidelity test for a single corpus test
  try:
    let tree = parser.parse(test.source)
    let rootNode = tree.rootNode

    let reconstructionResult = runByteFidelityTest(test.source, rootNode)

    if reconstructionResult.success:
      return (true, "")
    else:
      return (false, reconstructionResult.message)
  except:
    return (false, "Exception: " & getCurrentExceptionMsg())

proc compareAst(cstAst, nimAst: JsonNode, path: string = "$"): tuple[equal: bool, message: string] =
  ## Compare two canonical ASTs and report first difference
  if cstAst == nil and nimAst == nil:
    return (true, "")

  if cstAst == nil:
    return (false, fmt"Path {path}: CST AST is nil, Nim AST exists")

  if nimAst == nil:
    return (false, fmt"Path {path}: Nim AST is nil, CST AST exists")

  # Compare kinds
  let cstKind = cstAst{"kind"}.getStr("")
  let nimKind = nimAst{"kind"}.getStr("")

  if cstKind != nimKind:
    return (false, fmt"Path {path}: kinds differ - CST: {cstKind}, Nim: {nimKind}")

  # Compare key fields based on kind
  case cstKind
  of "Ident":
    let cstName = cstAst{"name"}.getStr("")
    let nimName = nimAst{"name"}.getStr("")
    if cstName != nimName:
      return (false, fmt"Path {path}.name: CST: {cstName}, Nim: {nimName}")

  of "IntLit", "FloatLit", "StringLit", "CharLit":
    let cstVal = cstAst{"value"}.getStr("")
    let nimVal = nimAst{"value"}.getStr("")
    if cstVal != nimVal:
      return (false, fmt"Path {path}.value: CST: {cstVal}, Nim: {nimVal}")

  of "Infix", "Prefix":
    let cstOp = cstAst{"operator"}.getStr("")
    let nimOp = nimAst{"operator"}.getStr("")
    if cstOp != nimOp:
      return (false, fmt"Path {path}.operator: CST: {cstOp}, Nim: {nimOp}")

  else:
    discard

  # Only compare fields if both are objects
  if cstAst.kind != JObject or nimAst.kind != JObject:
    # For non-object nodes, just compare by value
    if cstAst != nimAst:
      return (false, fmt"Path {path}: values differ")
    return (true, "")

  # Compare children/fields recursively
  for key in ["left", "right", "operand", "callee", "condition", "body",
              "consequence", "alternative", "expr", "name", "value", "type"]:
    if cstAst.hasKey(key) or nimAst.hasKey(key):
      let cstChild = cstAst{key}
      let nimChild = nimAst{key}
      let (equal, msg) = compareAst(cstChild, nimChild, fmt"{path}.{key}")
      if not equal:
        return (false, msg)

  # Compare array fields
  for key in ["args", "stmts", "branches", "elements", "parts", "vars",
              "params", "defs", "items", "types", "excepts", "patterns"]:
    if cstAst.hasKey(key) or nimAst.hasKey(key):
      let cstArr = cstAst{key}
      let nimArr = nimAst{key}

      if cstArr.kind != JArray and nimArr.kind != JArray:
        continue

      if cstArr.kind != JArray:
        return (false, fmt"Path {path}.{key}: CST is not array")

      if nimArr.kind != JArray:
        return (false, fmt"Path {path}.{key}: Nim is not array")

      if cstArr.len != nimArr.len:
        return (false, fmt"Path {path}.{key}: array lengths differ - CST: {cstArr.len}, Nim: {nimArr.len}")

      for i in 0 ..< cstArr.len:
        let (equal, msg) = compareAst(cstArr[i], nimArr[i], fmt"{path}.{key}[{i}]")
        if not equal:
          return (false, msg)

  return (true, "")

proc runNimParityTest(test: CorpusTest, parser: Parser): tuple[passed: bool, message: string] =
  ## Run meaning-fidelity test for a single corpus test
  try:
    # Parse with tree-sitter
    let tree = parser.parse(test.source)
    let cstResult = canonicalizeCst(tree.rootNode, test.source, cpNim)

    if cstResult.errors.len > 0:
      return (false, "CST canonicalization errors: " & cstResult.errors[0].message)

    # Parse with Nim compiler
    let nimResult = parseWithNimCompiler(test.source, test.corpusFile)

    if not nimResult.success:
      return (false, "Nim parser errors: " & nimResult.errors.join(", "))

    let nimCanonResult = canonicalizePNode(nimResult.node, cpNim)

    if nimCanonResult.errors.len > 0:
      return (false, "Nim canonicalization errors: " & nimCanonResult.errors[0].message)

    # Compare ASTs
    let (equal, message) = compareAst(cstResult.ast, nimCanonResult.ast)

    if equal:
      return (true, "")
    else:
      return (false, message)

  except:
    return (false, "Exception: " & getCurrentExceptionMsg())

proc runTest(test: CorpusTest, parser: Parser, options: RunOptions): TestResult =
  ## Run all applicable tests for a single corpus test
  result.test = test
  result.skippedBytes = test.shouldSkipBytes
  result.skippedNim = test.shouldSkipNim
  result.xfailNim = test.isXfailNim

  # Byte fidelity test
  if not options.nimOnly and not result.skippedBytes:
    let (passed, message) = runByteFidelityTest(test, parser)
    result.byteFidelityPassed = passed
    result.byteFidelityMessage = message
  else:
    result.byteFidelityPassed = true

  # Nim parity test
  if not options.bytesOnly and not result.skippedNim:
    let (passed, message) = runNimParityTest(test, parser)
    result.nimParityPassed = passed
    result.nimParityMessage = message
  else:
    result.nimParityPassed = true

proc printResult(result: TestResult, options: RunOptions) =
  ## Print test result
  let testId = result.test.testId

  var status: string
  var details: seq[string] = @[]

  if result.skippedBytes and result.skippedNim:
    status = yellow("SKIP")
    details.add "skipped"
  elif not result.byteFidelityPassed:
    status = red("FAIL")
    details.add "bytes"
    if options.verbose:
      details.add result.byteFidelityMessage
  elif not result.nimParityPassed:
    if result.xfailNim:
      status = yellow("XFAIL")
      details.add "expected nim failure"
    else:
      status = red("FAIL")
      details.add "nim parity"
      if options.verbose:
        details.add result.nimParityMessage
  else:
    if result.xfailNim:
      status = red("XPASS")
      details.add "unexpected pass (was xfail)"
    else:
      status = green("PASS")

  echo fmt"[{status}] {testId}"
  if options.verbose and details.len > 0:
    for detail in details:
      if detail.len > 0:
        echo "       " & detail

proc updateStats(stats: var TestStats, result: TestResult) =
  ## Update statistics based on test result
  stats.total.inc

  if result.skippedBytes and result.skippedNim:
    stats.skipped.inc
    return

  let passed = result.byteFidelityPassed and result.nimParityPassed

  if result.xfailNim:
    if passed:
      stats.xfailFailed.inc  # Unexpected pass
    else:
      stats.xfailPassed.inc  # Expected failure
      stats.passed.inc
  elif passed:
    stats.passed.inc
  else:
    stats.failed.inc

proc printSummary(stats: TestStats, duration: Duration) =
  ## Print test summary
  echo ""
  echo "=" .repeat(60)
  echo fmt"Test Summary ({duration.inMilliseconds}ms)"
  echo "=" .repeat(60)
  echo fmt"Total:    {stats.total}"
  echo fmt"Passed:   {green($stats.passed)}"
  echo fmt"Failed:   {red($stats.failed)}"
  echo fmt"Skipped:  {yellow($stats.skipped)}"

  if stats.xfailPassed > 0:
    echo fmt"XFail:    {stats.xfailPassed} (expected failures)"

  if stats.xfailFailed > 0:
    echo fmt"XPass:    {red($stats.xfailFailed)} (unexpected passes)"

  echo ""

  if stats.failed > 0:
    echo red("TESTS FAILED")
  else:
    echo green("ALL TESTS PASSED")

proc parseOptions(): RunOptions =
  ## Parse command line options
  result.corpusPath = "test/corpus"

  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "bytes-only":
        result.bytesOnly = true
      of "nim-only":
        result.nimOnly = true
      of "verbose", "v":
        result.verbose = true
      of "filter", "f":
        result.filter = p.val
      of "corpus":
        result.corpusPath = p.val
      of "help", "h":
        echo """
tree-sitter-nim test runner

Usage: test_runner [options]

Options:
  --bytes-only     Run only byte-fidelity tests
  --nim-only       Run only Nim parity tests
  --verbose, -v    Print detailed output
  --filter=NAME    Only run tests matching NAME
  --corpus=PATH    Path to corpus directory (default: test/corpus)
  --help, -h       Show this help
"""
        quit(0)
      else:
        echo fmt"Unknown option: {p.key}"
        quit(1)
    of cmdArgument:
      discard

proc main() =
  let options = parseOptions()

  echo "tree-sitter-nim Test Runner"
  echo fmt"Nim version: {nimVersion()}"
  echo ""

  # Load corpus
  let tests = loadAllCorpusTests(options.corpusPath)
  echo fmt"Loaded {tests.len} tests from {options.corpusPath}"
  echo ""

  # Create parser
  let parser = newParser()

  # Run tests
  let startTime = getTime()
  var stats: TestStats
  var results: seq[TestResult] = @[]

  for test in tests:
    # Apply filter
    if options.filter.len > 0:
      if not test.testId.contains(options.filter):
        continue

    let result = runTest(test, parser, options)
    results.add result
    printResult(result, options)
    updateStats(stats, result)

  let duration = getTime() - startTime

  # Print summary
  printSummary(stats, duration)

  # Exit with error code if tests failed
  if stats.failed > 0 or stats.xfailFailed > 0:
    quit(1)

when isMainModule:
  main()

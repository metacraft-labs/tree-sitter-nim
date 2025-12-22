## Byte-fidelity test runner for tree-sitter-nim
##
## This is a standalone test runner that only tests byte-fidelity,
## without requiring the Nim compiler internals.
##
## Usage:
##   nim c -r tests/nim/test_byte_fidelity.nim [options]
##
## Options:
##   --verbose        Print detailed output
##   --filter=NAME    Only run tests matching NAME
##   --corpus=PATH    Path to corpus directory (default: test/corpus)

import std/[os, strutils, strformat, times, terminal, parseopt]

import corpus_loader
import ts_parser_bridge
import reconstruct_bytes

type
  TestResult = object
    test: CorpusTest
    passed: bool
    message: string
    skipped: bool

  TestStats = object
    total: int
    passed: int
    failed: int
    skipped: int

  RunOptions = object
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

proc runByteFidelityTest(test: CorpusTest, parser: Parser): TestResult =
  ## Run byte-fidelity test for a single corpus test
  result.test = test
  result.skipped = test.shouldSkipBytes

  if result.skipped:
    return

  try:
    let tree = parser.parse(test.source)
    let rootNode = tree.rootNode

    let reconstructionResult = runByteFidelityTest(test.source, rootNode)

    result.passed = reconstructionResult.success
    result.message = reconstructionResult.message
  except:
    result.passed = false
    result.message = "Exception: " & getCurrentExceptionMsg()

proc printResult(result: TestResult, options: RunOptions) =
  ## Print test result
  let testId = result.test.testId

  var status: string

  if result.skipped:
    status = yellow("SKIP")
  elif result.passed:
    status = green("PASS")
  else:
    status = red("FAIL")

  echo fmt"[{status}] {testId}"
  if options.verbose and not result.passed and not result.skipped:
    if result.message.len > 0:
      for line in result.message.splitLines:
        echo "       " & line

proc updateStats(stats: var TestStats, result: TestResult) =
  ## Update statistics based on test result
  stats.total.inc

  if result.skipped:
    stats.skipped.inc
  elif result.passed:
    stats.passed.inc
  else:
    stats.failed.inc

proc printSummary(stats: TestStats, duration: Duration) =
  ## Print test summary
  echo ""
  echo "=" .repeat(60)
  echo fmt"Byte-Fidelity Test Summary ({duration.inMilliseconds}ms)"
  echo "=" .repeat(60)
  echo fmt"Total:    {stats.total}"
  echo fmt"Passed:   {green($stats.passed)}"
  echo fmt"Failed:   {red($stats.failed)}"
  echo fmt"Skipped:  {yellow($stats.skipped)}"
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
      of "verbose", "v":
        result.verbose = true
      of "filter", "f":
        result.filter = p.val
      of "corpus":
        result.corpusPath = p.val
      of "help", "h":
        echo """
tree-sitter-nim byte-fidelity test runner

Usage: test_byte_fidelity [options]

Options:
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

  echo "tree-sitter-nim Byte-Fidelity Test Runner"
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

    let result = runByteFidelityTest(test, parser)
    results.add result
    printResult(result, options)
    updateStats(stats, result)

  let duration = getTime() - startTime

  # Print summary
  printSummary(stats, duration)

  # Exit with error code if tests failed
  if stats.failed > 0:
    quit(1)

when isMainModule:
  main()

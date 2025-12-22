## Corpus loader for tree-sitter test files
##
## Parses test/corpus/*.txt files in tree-sitter's test format:
##
## ```
## ==================
## test name
## ==================
## <input source>
## ---
## <expected S-expression>
## ```

import std/[os, strutils]

type
  TestDirective* = enum
    ## Test directives that can be specified in comments
    tdSkipNim      ## Skip Nim compiler equivalence test
    tdSkipBytes    ## Skip byte reconstruction test
    tdXfailNim     ## Expected to fail Nim parity test
    tdProfileLossless  ## Use lossless canonicalization profile
    tdProfileNim   ## Use nim canonicalization profile

  CorpusTest* = object
    ## A single test case from the corpus
    name*: string           ## Test name
    source*: string         ## Source code to parse
    expected*: string       ## Expected S-expression (for tree-sitter test)
    directives*: set[TestDirective]  ## Parsed directives
    corpusFile*: string     ## Source corpus file path
    lineNumber*: int        ## Line number in corpus file

  CorpusFile* = object
    ## A corpus file containing multiple tests
    path*: string
    tests*: seq[CorpusTest]

const
  TestSeparator = "=================="
  InputSeparator = "---"
  DirectivePrefix = "# tsnimtest:"

proc parseDirectives(source: string): set[TestDirective] =
  ## Parse test directives from source comments
  result = {}
  for line in source.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith(DirectivePrefix):
      let directive = trimmed[DirectivePrefix.len..^1].strip()
      case directive
      of "skip-nim":
        result.incl tdSkipNim
      of "skip-bytes":
        result.incl tdSkipBytes
      of "xfail-nim":
        result.incl tdXfailNim
      of "profile=lossless":
        result.incl tdProfileLossless
      of "profile=nim":
        result.incl tdProfileNim
      else:
        # Unknown directive, ignore
        discard

proc parseCorpusFile*(path: string): CorpusFile =
  ## Parse a tree-sitter corpus file into individual test cases
  result.path = path
  result.tests = @[]

  let content = readFile(path)
  let lines = content.splitLines()

  var i = 0
  while i < lines.len:
    # Skip empty lines
    while i < lines.len and lines[i].strip() == "":
      inc i

    if i >= lines.len:
      break

    # Look for test separator
    if not lines[i].startsWith(TestSeparator):
      inc i
      continue

    let startLine = i
    inc i

    # Read test name (may span multiple lines until next separator)
    var testName = ""
    while i < lines.len and not lines[i].startsWith(TestSeparator):
      if testName.len > 0:
        testName.add " "
      testName.add lines[i].strip()
      inc i

    if i >= lines.len:
      break

    # Skip closing separator
    inc i

    # Read input source until ---
    var sourceLines: seq[string] = @[]
    while i < lines.len and lines[i] != InputSeparator:
      sourceLines.add lines[i]
      inc i

    if i >= lines.len:
      break

    # Skip ---
    inc i

    # Read expected S-expression until next test separator or EOF
    var expectedLines: seq[string] = @[]
    while i < lines.len and not lines[i].startsWith(TestSeparator):
      expectedLines.add lines[i]
      inc i

    let source = sourceLines.join("\n")
    let expected = expectedLines.join("\n")

    result.tests.add CorpusTest(
      name: testName,
      source: source,
      expected: expected,
      directives: parseDirectives(source),
      corpusFile: path,
      lineNumber: startLine + 1
    )

proc loadCorpusDirectory*(dir: string): seq[CorpusFile] =
  ## Load all corpus files from a directory
  result = @[]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".txt"):
      result.add parseCorpusFile(path)

proc loadAllCorpusTests*(corpusDir: string = "test/corpus"): seq[CorpusTest] =
  ## Load all tests from all corpus files
  result = @[]
  for corpusFile in loadCorpusDirectory(corpusDir):
    result.add corpusFile.tests

proc hasDirective*(test: CorpusTest, directive: TestDirective): bool =
  ## Check if a test has a specific directive
  directive in test.directives

proc shouldSkipBytes*(test: CorpusTest): bool =
  ## Check if byte-fidelity test should be skipped
  tdSkipBytes in test.directives

proc shouldSkipNim*(test: CorpusTest): bool =
  ## Check if Nim parity test should be skipped
  tdSkipNim in test.directives

proc isXfailNim*(test: CorpusTest): bool =
  ## Check if Nim parity test is expected to fail
  tdXfailNim in test.directives

proc getProfile*(test: CorpusTest): string =
  ## Get the canonicalization profile for a test
  if tdProfileLossless in test.directives:
    "lossless"
  elif tdProfileNim in test.directives:
    "nim"
  else:
    "nim"  # Default to nim profile

proc testId*(test: CorpusTest): string =
  ## Get a unique identifier for a test
  let fileName = test.corpusFile.extractFilename()
  fileName & "::" & test.name

when isMainModule:
  # Test the corpus loader
  import std/strformat

  let tests = loadAllCorpusTests()
  echo fmt"Loaded {tests.len} tests from corpus"

  for test in tests[0..min(4, tests.len - 1)]:
    echo fmt"\n--- {test.testId} ---"
    echo fmt"Source ({test.source.len} bytes):"
    echo test.source[0..min(100, test.source.len - 1)]
    echo fmt"Directives: {test.directives}"

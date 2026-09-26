# Package

version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Tree-sitter grammar for Nim - testing utilities"
license       = "MIT"
srcDir        = "."
bin           = @["tests/nim/test_runner"]

# Dependencies

requires "nim >= 2.0.0"

# Tasks

task test, "Run byte-fidelity and meaning-fidelity tests":
  exec "nim c -r --hints:off tests/nim/test_nimcache_is_worktree_local.nim"
  exec "nim c -r tests/nim/test_runner"

task testBytes, "Run only byte-fidelity tests":
  exec "nim c -r tests/nim/test_runner --bytes-only"

task testNim, "Run only Nim parity tests":
  exec "nim c -r tests/nim/test_runner --nim-only"

task testVerbose, "Run all tests with verbose output":
  exec "nim c -r tests/nim/test_runner --verbose"

task testCorpusLoader, "Test the corpus loader":
  exec "nim c -r tests/nim/corpus_loader"

task testTsBridge, "Test the tree-sitter parser bridge":
  exec "nim c -r tests/nim/ts_parser_bridge"

task testNimBridge, "Test the Nim parser bridge":
  exec "nim c -r tests/nim/nim_parser_bridge"

task testReconstruct, "Test byte reconstruction":
  exec "nim c -r tests/nim/reconstruct_bytes"

task testCstCanon, "Test CST canonicalization":
  exec "nim c -r ast/nim/canonicalize_cst"

task testPnodeCanon, "Test PNode canonicalization":
  exec "nim c -r ast/nim/canonicalize_pnode"

task treeSitterTest, "Run tree-sitter's built-in tests":
  exec "tree-sitter test"

task all, "Run all tests (tree-sitter and custom)":
  exec "tree-sitter test"
  exec "nimble test"

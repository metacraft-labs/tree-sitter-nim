# tree-sitter-nim development tasks

# Default: list available commands
default:
    @just --list

# Generate parser only if needed (grammar.js newer than parser.c or parser.c missing)
generate:
    #!/usr/bin/env bash
    set -e
    if [ ! -f "src/parser.c" ]; then
        echo "parser.c doesn't exist, generating..."
        tree-sitter generate
    elif [ "grammar.js" -nt "src/parser.c" ]; then
        echo "grammar.js is newer than parser.c, regenerating..."
        tree-sitter generate
    else
        echo "parser.c is up to date"
    fi

# Force regenerate parser (ignores cache)
generate-force:
    tree-sitter generate

# Run all tests (tree-sitter grammar/highlight + byte-fidelity + parity)
test:
    @echo "=== Tree-sitter Tests (grammar + highlighting) ==="
    @script -q -c "tree-sitter test" /dev/null
    @echo ""
    @echo "=== Byte-Fidelity Tests ==="
    @nim c -f -r --hints:off tests/nim/test_byte_fidelity.nim
    @echo ""
    @echo "=== Parity Tests (CST-to-AST vs Nim compiler) ==="
    @if [ -z "{{nim_compiler_path}}" ]; then \
        echo "Warning: Cannot find Nim compiler sources. Skipping parity tests."; \
        echo "Use 'nix develop' or set NIM_COMPILER_PATH for full test suite."; \
    else \
        nim c -f -r --hints:off --path:{{nim_compiler_path}} tests/nim/test_runner.nim --nim-only; \
    fi

# Run only tree-sitter tests (grammar + highlighting)
test-grammar:
    @script -q -c "tree-sitter test" /dev/null

# Run tests and update expected output
test-update:
    tree-sitter test --update

# Nim compiler source path (needed for parity tests that use compiler internals)
# Auto-detect from Nix environment if not set
nim_compiler_path := `ls -d /nix/store/*-nim-unwrapped-*/nim 2>/dev/null | head -1 || echo ""`

# Run byte-fidelity tests (Nim)
test-bytes:
    nim c -f -r tests/nim/test_byte_fidelity.nim

# Run byte-fidelity tests with verbose output
test-bytes-verbose:
    nim c -f -r tests/nim/test_byte_fidelity.nim --verbose

# Run Nim parity tests (requires Nim compiler sources)
test-parity:
    @if [ -z "{{nim_compiler_path}}" ]; then \
        echo "Error: Cannot find Nim compiler sources. Set NIM_COMPILER_PATH or use nix develop."; \
        exit 1; \
    fi
    nim c -f -r --hints:off --path:{{nim_compiler_path}} tests/nim/test_runner.nim --nim-only

# Run Nim parity tests with verbose output
test-parity-verbose:
    @if [ -z "{{nim_compiler_path}}" ]; then \
        echo "Error: Cannot find Nim compiler sources. Set NIM_COMPILER_PATH or use nix develop."; \
        exit 1; \
    fi
    nim c -f -r --hints:off --path:{{nim_compiler_path}} tests/nim/test_runner.nim --nim-only --verbose

# Run full test suite (tree-sitter + byte-fidelity + parity)
test-full:
    @if [ -z "{{nim_compiler_path}}" ]; then \
        echo "Error: Cannot find Nim compiler sources. Set NIM_COMPILER_PATH or use nix develop."; \
        exit 1; \
    fi
    nim c -f -r --hints:off --path:{{nim_compiler_path}} tests/nim/test_runner.nim

# Alias for 'test' (runs all tests)
test-all: test

# Generate parser and run tests
check: generate test

# Parse a specific file (useful for debugging)
parse file:
    tree-sitter parse {{file}}

# Parse from stdin (pipe code to this)
parse-stdin:
    @echo "Enter Nim code, then Ctrl+D:"
    @cat > /tmp/nim-parse-tmp.nim && tree-sitter parse /tmp/nim-parse-tmp.nim

# Lint all files (runs pre-commit hooks)
lint:
    pre-commit run --all-files

# Format JavaScript and JSON files
format:
    prettier --write grammar.js package.json

# Check formatting without modifying files
format-check:
    prettier --check grammar.js package.json

# Install dependencies
install:
    npm install

# Clean generated files
clean:
    rm -rf build/
    rm -rf node_modules/
    rm -f src/parser.c src/tree_sitter/parser.h

# Clean and reinstall
reinstall: clean install generate

# Build native bindings
build:
    npm run build

# Publish to npm (dry run)
publish-dry:
    npm publish --dry-run

# Publish to npm
publish:
    npm publish

# Highlight a file using the grammar
highlight file:
    tree-sitter highlight {{file}}

# Open playground in browser
playground:
    tree-sitter build --wasm
    tree-sitter playground

# Show grammar statistics
stats:
    @echo "Grammar size:"
    @wc -l grammar.js
    @echo ""
    @echo "Test corpus:"
    @find test/corpus -name "*.txt" -exec wc -l {} + | tail -1
    @echo ""
    @echo "Number of test cases:"
    @grep -c "^==================" test/corpus/*.txt | awk -F: '{sum += $2} END {print sum}'

# Update flake lock file
flake-update:
    nix flake update

# Check flake outputs
flake-check:
    nix flake check

# Get current version
@current-version:
    python scripts/bump-version.py current

# Bump patch version (0.1.0 -> 0.1.1), commit and tag
bump-patch-version:
    python scripts/bump-version.py patch

# Bump minor version (0.1.0 -> 0.2.0), commit and tag
bump-minor-version:
    python scripts/bump-version.py minor

# Bump major version (0.1.0 -> 1.0.0), commit and tag
bump-major-version:
    python scripts/bump-version.py major

# Generate a repomix bundle for expert review
# Includes all essential hand-written files, excludes generated code
repomix:
    repomix --include "README.md,CLAUDE.md,Grammar-Design-Goals.md,Testing-Strategy-Spec.md,grammar.js,src/scanner.c,ast/README.md,ast/schema/ast.schema.json,ast/nim/*.nim,tests/nim/*.nim,test/corpus/*.txt,test/highlight/*.nim,queries/*.scm,package.json,tree-sitter.json,tree_sitter_nim.nimble,Justfile,flake.nix"

# tree-sitter-nim development tasks

# Default: list available commands
default:
    @just --list

# Generate the parser from grammar.js
generate:
    npx tree-sitter generate

# Run all tests
test:
    npx tree-sitter test

# Run tests and update expected output
test-update:
    npx tree-sitter test --update

# Generate parser and run tests
check: generate test

# Parse a specific file (useful for debugging)
parse file:
    npx tree-sitter parse {{file}}

# Parse from stdin (pipe code to this)
parse-stdin:
    @echo "Enter Nim code, then Ctrl+D:"
    @cat > /tmp/nim-parse-tmp.nim && npx tree-sitter parse /tmp/nim-parse-tmp.nim

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
    npx tree-sitter highlight {{file}}

# Open playground in browser
playground:
    npx tree-sitter build --wasm
    npx tree-sitter playground

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

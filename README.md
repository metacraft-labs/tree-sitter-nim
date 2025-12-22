# tree-sitter-nim

A [Tree-sitter](https://tree-sitter.github.io/tree-sitter/) grammar for the [Nim](https://nim-lang.org/) programming language.

## Features

- **Complete Nim syntax support** including all expression forms, control flow, declarations, and types
- **INDENT/DEDENT layout parsing** via external scanner
- **Nested block comments** (`#[ ... ]#` and `##[ ... ]##`)
- **Strong spaces** differentiation (call vs command forms)
- **CST-to-AST canonicalization** for semantic tooling
- **Parity testing** against the Nim compiler's parser

## Project Structure

```
tree-sitter-nim/
├── grammar.js              # Main grammar definition
├── src/
│   ├── scanner.c           # External scanner for indentation
│   ├── parser.c            # Generated parser (do not edit)
│   └── grammar.json        # Generated grammar spec
├── queries/
│   └── highlights.scm      # Syntax highlighting queries
├── test/corpus/            # Tree-sitter test cases
├── ast/
│   ├── nim/
│   │   ├── canonicalize_cst.nim    # CST -> canonical AST
│   │   └── canonicalize_pnode.nim  # Nim PNode -> canonical AST
│   └── schema/
│       └── ast.schema.json         # Canonical AST schema
└── tests/nim/              # Parity test infrastructure
```

## Quick Start

### Using Nix (recommended)

```bash
nix develop
just test          # Run tree-sitter grammar tests
just test-parity   # Run CST-to-AST parity tests
```

### Manual Setup

Prerequisites:

- Node.js
- tree-sitter CLI (`npm i -g tree-sitter-cli`)
- Nim 2.0+ (for parity tests)

```bash
npm install
tree-sitter generate
tree-sitter test
```

## Development Commands

Using [Just](https://github.com/casey/just):

```bash
just generate      # Regenerate parser from grammar.js
just test          # Run tree-sitter grammar tests
just test-parity   # Run CST vs Nim compiler parity tests
just parse FILE    # Parse a Nim file and show CST
```

## Testing

The project maintains two layers of correctness:

### 1. Grammar Tests (234 tests)

Standard tree-sitter corpus tests in `test/corpus/`:

```bash
tree-sitter test
```

### 2. Parity Tests (234 tests)

Verify that our CST-to-AST canonicalization matches Nim's compiler AST:

```bash
just test-parity
```

This runs both:

- **Byte-fidelity**: CST spans allow exact source reconstruction
- **Semantic parity**: Canonical AST matches Nim compiler's parse

## CST-to-AST Conversion

For semantic tooling, use the canonicalization layer:

```nim
import ast/nim/canonicalize_cst
import tests/nim/ts_parser_bridge

let parser = newParser()
let tree = parser.parse(source)
let result = canonicalizeCst(tree.rootNode, source)
echo result.ast.pretty
```

The canonical AST normalizes:

- Operator precedence and associativity
- Call forms (command vs parenthesized)
- Control flow structures
- Declaration sections

## Design Documentation

- **[Grammar-Design-Goals.md](Grammar-Design-Goals.md)** - CST design principles, node naming conventions, operator precedence
- **[Testing-Strategy-Spec.md](Testing-Strategy-Spec.md)** - Testing methodology, canonical AST schema, implementation details

## Editor Integration

The grammar works with editors supporting tree-sitter:

- Neovim (nvim-treesitter)
- Helix
- Emacs (tree-sitter mode)
- VS Code (with tree-sitter extension)

Highlight queries are in `queries/highlights.scm`.

## Language Bindings

### Rust

```bash
cd bindings/rust
cargo test
```

### Nim

```bash
nimble install
```

## Contributing

1. Make changes to `grammar.js`
2. Run `just generate` to regenerate the parser
3. Add tests to `test/corpus/`
4. Run `just test && just test-parity` to verify
5. Submit a PR

## License

MIT

## Links

- [Nim Language](https://nim-lang.org/)
- [Nim Manual](https://nim-lang.org/docs/manual.html)
- [Tree-sitter](https://tree-sitter.github.io/tree-sitter/)

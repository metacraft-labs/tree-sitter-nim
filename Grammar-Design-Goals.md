# Grammar Design Goals

This repository provides a Tree-sitter grammar for Nim.

Tree-sitter produces a **Concrete Syntax Tree (CST)** optimized for incremental parsing and editor tooling.
We treat the CST as a stable API surface for downstream consumers (highlighters, editors, code navigation, etc.).

Separately, we provide (or plan to provide) a CST-to-AST conversion layer for consumers who want a more semantic,
Nim-like tree.

## Primary Goals

1. **Stable, query-friendly CST**
   - Node names and shapes should be stable across releases.
   - Tree-sitter queries (highlights/locals/tags/folds) should be easy to write and robust.

2. **Accurate source mapping**
   - Node byte ranges must precisely match the underlying source bytes.
   - The CST must support byte-precise tooling (rename, quick fixes, refactors).

3. **Good error recovery**
   - The grammar should produce useful partial trees for incomplete or invalid code.
   - Edits should not cause large unrelated parts of the tree to become `ERROR`.

4. **Interoperability**
   - The grammar should work well with common editor ecosystems (Neovim, Helix, Emacs, etc.).
   - Provide standard query files in `queries/`.

## Non-goals

- A "compiler AST" inside the grammar itself.
- Byte-for-byte pretty-printing from the CST alone (without the original source buffer).
- Reproducing Nim compiler internal node kinds one-to-one in the CST.

## Node Naming Conventions

### General

- Use `lower_snake_case` for all named nodes.
- Prefer descriptive names aligned with Nim concepts:
  - `if_stmt`, `while_stmt`, `for_stmt`, `case_stmt`
  - `proc_decl`, `type_section`, `var_section`
  - `call`, `infix_expression`, `prefix_expression`
- Avoid abbreviations unless they are standard Nim terms (e.g. `pragma`).

### Leaf nodes (preferred)

- `identifier`
- `qualified_identifier`
- `symbol` (only if it matches Nim's syntax category)
- `integer_literal`, `float_literal`
- `string_literal`, `raw_string_literal`, `triple_string_literal`
- `char_literal`
- `comment`

### Wrapper nodes

Wrapper nodes are acceptable when they:

- make the CST shape more consistent
- improve error recovery
- improve query ergonomics

Examples:

- `parenthesized_expression`
- `argument_list`
- `parameter_list`
- `block`

## Field Naming Conventions

Field names matter as much as node names.

Use consistent field names across similar constructs:

### Expressions

- Binary/infix:
  - `left`, `operator`, `right`
- Unary/prefix:
  - `operator`, `operand`
- Calls:
  - `function` or `callee` (pick one and keep it consistent)
  - `arguments`

### Control flow

- If:
  - `condition`, `consequence`, `alternative`
- While/For:
  - `condition` or `iterator`
  - `body`

### Declarations

- Names:
  - `name`
- Types:
  - `type`
- Values/initializers:
  - `value`

## CST Shape Guidelines

1. **Minimize ambiguity**
   - Avoid rules where "sometimes it's a node, sometimes it's a bare seq".
   - Prefer stable list nodes (`*_list`, `block`, etc.).

2. **Prefer named structure, anonymous punctuation**
   - Structural constructs should be named nodes.
   - Punctuation should remain anonymous tokens when possible.

3. **Error recovery is first-class**
   - Favor rules that allow continuing after a malformed element.
   - Prefer list forms that can skip bad items and continue parsing.

4. **Don't overfit to a single consumer**
   - Editors mostly want a predictable CST.
   - Semantic tools can build an AST layer on top.

## Query Files

We maintain query files under `queries/`:

- `highlights.scm`
- `locals.scm`
- `tags.scm`
  (and optionally `folds.scm`, `indents.scm`, `injections.scm` if needed)

These are part of the user-facing contract.

## Versioning Policy

- CST node names/shapes: stable; changes require a major version bump and clear release notes.
- Query captures: stable; additions are fine, breaking changes require a major bump.
- CST-to-AST schema (if provided): versioned separately and documented in `ast/`.

## Testing Policy

We maintain two correctness layers:

1. **Byte-fidelity**: CST spans allow exact reconstruction of original bytes using node ranges + gaps.
2. **Meaning-fidelity**: CST-to-AST canonicalization matches Nim compiler parse followed by canonicalization.

Both are required for accepting grammar changes that affect parsing or structure.

## Precedence and Associativity

Nim's operator precedence is based on the first character of the operator token.
The grammar follows the same precedence model from `lexer.nim:getPrecedence`:

| Tier | Operators                                                              | Precedence Level                                 |
| ---- | ---------------------------------------------------------------------- | ------------------------------------------------ |
| 10   | `$` `^`                                                                | Highest infix (both same tier, left-associative) |
| 9    | `*` `/` `div` `mod` `shl` `shr` `%` `\`                                | Multiplicative                                   |
| 8    | `+` `-` `\|` `~`                                                       | Additive (note: `\|` is add-level, NOT or-level) |
| 7    | `&`                                                                    | Ampersand/concatenation                          |
| 6    | `..`                                                                   | Range/dot operators                              |
| 5    | `==` `!=` `<` `>` `<=` `>=` `in` `notin` `is` `isnot` `of` `as` `from` | Comparison                                       |
| 4    | `and`                                                                  | Logical and                                      |
| 3    | `or` `xor`                                                             | Logical or                                       |
| 2    | `@` `:` `?`                                                            | Miscellaneous operators                          |
| 1    | `+=` `-=` etc.                                                         | Assignment-like operators                        |
| 0    | `->` `~>` `=>`                                                         | Arrow operators (lowest)                         |

## Strong Spaces

Nim uses "strong spaces" to differentiate between call and command forms:

```nim
foo(x)   # call with parens (no space before open paren)
foo x    # command call (space separates callee from args)
foo[0]   # indexing (no space before bracket)
foo [0]  # command call with array literal argument
```

The grammar enforces this using `token.immediate` for call/index suffixes.

## Generalized String Literals

Nim supports generalized string literals where an identifier immediately precedes a string:

```nim
re"^pattern$"      # regex literal
fmt"hello {name}"  # format string
sql"SELECT * ..."  # SQL literal
```

These are lexically single tokens but semantically calls (`nkCallStrLit` in Nim's AST).
The grammar handles these as special suffixes.

## Further Reading

- [Nim Manual](https://nim-lang.org/docs/manual.html)
- [Nim Compiler Internals](https://nim-lang.github.io/Nim/intern.html)
- [Tree-sitter Documentation](https://tree-sitter.github.io/tree-sitter/)

# Canonical AST for tree-sitter-nim

This directory contains the canonical AST schema and conversion utilities for tree-sitter-nim.

## Purpose

The canonical AST provides a semantic representation of Nim code that:

- Ignores trivia (whitespace, comments)
- Normalizes syntactic sugar
- Is stable across CST refactors
- Retains source mapping for tooling
- Can be derived from both tree-sitter CST and Nim compiler's PNode AST

## Directory Structure

```
ast/
  schema/
    ast.schema.json     # JSON Schema for the canonical AST
  nim/
    canonicalize_cst.nim    # CST -> canonical AST conversion
    canonicalize_pnode.nim  # PNode -> canonical AST conversion
  README.md             # This file
```

## Schema

The canonical AST is defined by `schema/ast.schema.json`. Every node has:

- `kind`: String identifying the node type
- `span`: Source location with `startByte`, `endByte`, `startPoint`, `endPoint`

Optional debug fields:

- `cst`: Reference to original CST node (nodeType, startByte, endByte)
- `nim`: Reference to original Nim PNode kind
- `errors`: Any conversion errors

## Usage

### From CST (tree-sitter)

```nim
import ast/nim/canonicalize_cst
import tests/nim/ts_parser_bridge

let parser = newTSParser()
let tree = parser.parse(source)
let ast = canonicalizeCst(tree.rootNode, source)
```

### From PNode (Nim compiler)

```nim
import ast/nim/canonicalize_pnode
import tests/nim/nim_parser_bridge

let pnode = parseWithNimCompiler(source, "test.nim")
let ast = canonicalizePNode(pnode, source)
```

### Profiles

Two canonicalization profiles are supported:

| Profile    | Description                            |
| ---------- | -------------------------------------- |
| `lossless` | Minimal desugaring, keeps CST backrefs |
| `nim`      | Aggressive Nim-like canonicalization   |

## Node Kinds

See [Testing-Strategy-Spec.md](../Testing-Strategy-Spec.md#canonical-ast-node-kinds) for the complete list of node kinds and their fields.

## Testing

The canonical AST is tested by comparing:

1. CST -> canonical AST
2. PNode -> canonical AST

Both should produce structurally identical results for valid Nim code.

Run tests with:

```bash
nimble test
# or
nim c -r tests/nim/test_runner.nim
```

# Testing Strategy Specification

This document specifies the testing strategy for tree-sitter-nim, including byte-fidelity testing,
meaning-fidelity testing, and the CST-to-AST conversion design.

## Goals

We want two independent guarantees:

1. **Lossless for text mapping (byte-fidelity):**
   For each test input source `S` (bytes), `tree-sitter parse(S)` produces a CST whose token spans
   can be used to reconstruct **exactly `S`** (byte-for-byte) via a deterministic algorithm.

2. **Lossless for meaning (semantic fidelity):**
   A canonical "Nim-like AST" derived from:
   - (A) `tree-sitter CST -> canonical AST`

   must match the canonical AST derived from:
   - (B) `Nim compiler parser (in-process) -> Nim PNode AST -> canonical AST`

The combination gives you:

- **byte-correct mapping** for tooling/editing workflows
- **meaning-correct mapping** for semantic tooling
- confidence your CST-to-AST builder isn't accidentally depending on trivia or ambiguous CST shapes

## Non-goals

- Proving that **CST alone** (without original text) can be "unparsed" into identical bytes.
  Tree-sitter intentionally treats whitespace/comments as "extras"; full byte fidelity comes from
  **spans + original buffer**.
- Enforcing Nim compiler's renderer round-trips formatting/bytes. Nim's AST is semantic; it
  typically discards trivia.

---

## Repository Additions

### New directories

```
ast/
  schema/
    ast.schema.json     # Canonical AST JSON schema
  nim/
    canonicalize_pnode.nim   # Nim PNode -> canonical AST
    canonicalize_cst.nim     # CST -> canonical AST
  README.md

tests/
  nim/
    test_runner.nim         # Main test runner
    corpus_loader.nim       # Tree-sitter corpus parser
    nim_parser_bridge.nim   # Nim compiler parser integration
    ts_parser_bridge.nim    # Tree-sitter parser bridge
    reconstruct_bytes.nim   # Byte reconstruction from CST
```

### New CI job

- `nimble test` (or `nim c -r tests/nim/test_runner.nim`) in addition to `tree-sitter test`.

---

## Part A: Test Inputs & Corpus Loading

### Source of test cases

Reuse existing `test/corpus/*.txt` (tree-sitter corpus format).

Each case has:

- a name block
- the input source text
- `---`
- expected S-expression tree output (existing)

We'll ignore the expected S-expression for the new tests (we keep it for `tree-sitter test`).

### Loader rules

For each corpus file:

1. Split into tests by:

   ```
   ==================
   <name>
   ==================
   <input>
   ---
   <expected>
   ```

2. Take `<input>` as the source to validate.

### Metadata directives (optional)

Allow "skip" or "xfail" tags inside the input via comments so the corpus stays self-contained:

```nim
# tsnimtest: skip-nim     (skip Nim compiler equivalence)
# tsnimtest: skip-bytes   (skip byte reconstruction)
# tsnimtest: xfail-nim    (known Nim parser mismatch)
# tsnimtest: profile=lossless|nim  (controls canonicalization mode)
```

---

## Part B: Byte-Fidelity Test (Lossless for Text Mapping)

### Definition

For a source byte buffer `S` and parsed tree `T`, define a deterministic reconstruction algorithm:

1. Enumerate all leaf **tokens** in source order, including anonymous punctuation tokens.
2. For each consecutive token `t[i]`, `t[i+1]`, copy:
   - `S[prevEnd .. nextStart]` gaps verbatim (this includes whitespace, comments, newline conventions)
   - token text slices `S[token.startByte .. token.endByte]` verbatim
3. Include prefix gap from `0..firstTokenStart` and suffix gap from `lastTokenEnd..len(S)`.

### Acceptance criteria

- Reconstruction produces exact bytes: `reconstructed == S`
- Root node span covers the content (leading/trailing whitespace may be outside)
- Presence of `ERROR` or `MISSING` nodes does **not** fail the byte test by itself. They are tolerated; failure only occurs if reconstruction or coverage fails. Use corpus directives to mark intentionally invalid inputs (still skip Nim parity).

### Why this is the right notion

It proves your CST spans are consistent and ordered, and that your grammar doesn't create
tokenization anomalies that make tooling unable to "splice" text precisely.

### Algorithm (pseudocode)

```nim
proc reconstructBytes(source: string, rootNode: TSNode): string =
  var result = ""
  var prevEnd = 0

  proc visit(node: TSNode) =
    if node.childCount == 0:
      # Leaf node - copy gap then token
      let startByte = node.startByte
      let endByte = node.endByte

      # Copy any gap between previous end and this start
      if startByte > prevEnd:
        result.add source[prevEnd ..< startByte]

      # Copy the token itself
      result.add source[startByte ..< endByte]
      prevEnd = endByte
    else:
      # Internal node - visit children
      for i in 0 ..< node.childCount:
        visit(node.child(i))

  visit(rootNode)

  # Copy any trailing content
  if prevEnd < source.len:
    result.add source[prevEnd ..< source.len]

  result
```

---

## Part C: Meaning-Fidelity Test (CST-to-AST matches Nim Compiler AST)

### Overview of the pipeline

**Pipeline 1: CST-based canonical AST**

```
S (bytes)
  -> tree-sitter parse
  -> CST
  -> canonical AST (our schema)
```

**Pipeline 2: Nim compiler canonical AST**

```
S (text)
  -> Nim compiler/parser.parseString
  -> PNode AST
  -> canonical AST (same schema)
```

**Compare:**

- `canonical_from_cst == canonical_from_nim` (deep structural equality)

### Canonical AST schema principles

#### Purpose

Provide a stable semantic representation that:

- ignores trivia (whitespace/comments)
- normalizes syntactic sugar
- is stable across CST refactors and minor Nim compiler AST variations
- retains source mapping for diagnostics and downstream tooling

#### Required fields on every node

| Field      | Type   | Description                                                                  |
| ---------- | ------ | ---------------------------------------------------------------------------- |
| `kind`     | string | Node kind (e.g., "Call", "Infix", "IfExpr")                                  |
| `span`     | object | `{ startByte, endByte, startPoint: {row, column}, endPoint: {row, column} }` |
| `children` | array  | Child nodes (OR typed fields like `left`/`right`/`operator`)                 |

#### Optional fields

| Field    | Type   | Description                                                   |
| -------- | ------ | ------------------------------------------------------------- |
| `cst`    | object | `{ nodeType, startByte, endByte }` for debugging              |
| `nim`    | object | `{ nk: "nkInfix" \| ... }` debug-only, original Nim node kind |
| `errors` | array  | Any errors during conversion                                  |

### Canonicalization rules (core)

1. **Parentheses** do not create semantic nodes unless Nim AST distinguishes them meaningfully (generally it doesn't).

2. **Operator precedence** is normalized so that `a + b * c` becomes `Add(a, Mul(b,c))`.

3. **Call forms** normalize:
   - command-style, paren calls, generic instantiation if applicable

4. **Blocks** normalize to `StmtList([ ... ])`

5. **Identifiers** normalize to `Ident(name)`

6. **Qualified identifiers** normalize to `Qualified(parts:[...])`

7. **Literals** normalize to:
   - `IntLit(value, base?)`
   - `FloatLit(value)`
   - `StringLit(value, rawKind?)`
   - etc.

### Span rule

- Span should cover the syntactic extent _that semantically belongs to the node_.
- For composed nodes, span is usually from first child's start to last child's end.
- For operators/calls, include operator token range if possible (recommended).

---

## Part D: Nim Compiler Integration (in-process)

### Implementation approach

Write the test runner in Nim and import the compiler modules, using the compiler's parser API.

The Nim compiler modules (`lexer`, `parser`, `ast`, `renderer`) are documented as the compiler's internal architecture.

### Pseudocode

```nim
import compiler/[parser, ast, idents, options, pathutils, lineinfos, msgs]

proc parseWithNimCompiler(src: string, filename: string): PNode =
  let cache = newIdentCache()
  let conf = newConfigRef()
  conf.options.excl(optHints)  # Suppress hints

  # Create a file info for the source
  let fileIdx = fileInfoIdx(conf, AbsoluteFile(filename))

  # Parse the source string
  result = parseString(src, cache, conf, filename = filename)
```

### Error handling

Use error handlers to capture parser errors deterministically.
For "valid" corpus tests, assert: no errors.

### Version pinning

Because Nim's internal AST details can change across versions, the test runner should:

- print Nim version at start (for debugging)
- optionally pin Nim version in CI (recommended)
- canonicalize aggressively enough that small internal differences don't cause churn

---

## Part E: Test Runner Design

### Single-threaded execution (initial implementation)

The initial implementation runs tests sequentially:

```nim
proc runAllTests() =
  var passed = 0
  var failed = 0
  var skipped = 0

  for corpusFile in walkDir("test/corpus"):
    if not corpusFile.endsWith(".txt"):
      continue

    for test in loadCorpusFile(corpusFile):
      # Check for skip directives
      if test.hasDirective("skip-nim") and test.hasDirective("skip-bytes"):
        skipped.inc
        continue

      # Run byte-fidelity test
      if not test.hasDirective("skip-bytes"):
        let byteResult = runByteFidelityTest(test)
        if byteResult.failed:
          failed.inc
          reportFailure(test, byteResult)
          continue

      # Run meaning-fidelity test
      if not test.hasDirective("skip-nim"):
        let meaningResult = runMeaningFidelityTest(test)
        if meaningResult.failed:
          if test.hasDirective("xfail-nim"):
            # Expected failure
            passed.inc
          else:
            failed.inc
            reportFailure(test, meaningResult)
          continue

      passed.inc

  echo "Results: ", passed, " passed, ", failed, " failed, ", skipped, " skipped"
```

### Determinism requirements

- stable iteration order
- stable JSON output key order (if snapshotting)
- no timestamps or nondeterministic IDs in canonical AST

---

## Part F: Test Runner Outputs

For failures, print:

- corpus file + test name
- failing stage(s)
- minimal diffs:
  - for bytes: first differing byte index + small hexdump window
  - for AST: JSON diff path (e.g. `body[2].callee.name`)

### Example output

```
FAIL: test/corpus/expressions.txt :: basic precedence mul over add
  Stage: byte-fidelity
  First difference at byte 15:
    Expected: 0x2A (*)
    Got:      0x2B (+)

  Context:
    "discard 1 + 2 * 3"
                 ^~~~
```

```
FAIL: test/corpus/operators.txt :: infix with custom operator
  Stage: meaning-fidelity
  AST difference at path: $.body[0].operator
    CST produced: "+++"
    Nim produced: "++"
```

---

# CST-to-AST Pass Design Proposal

## Objectives

- Provide a **reference implementation** of CST-to-canonical AST.
- Make it consumable by:
  - semantic tooling (LSP, linters, refactoring, indexing)
  - optional compiler-parity workflows
- Keep editors and "flat" consumers happy by not forcing AST-like CST design changes.

## Deliverables

1. `ast/schema/ast.schema.json`
2. `ast/nim/canonicalize_cst.nim` - CST to canonical AST builder
3. `ast/nim/canonicalize_pnode.nim` - Nim PNode canonicalizer
4. `ast/README.md` - usage & extension points

## Builder architecture

### Phase 1: CST normalization (mechanical)

Goal: make the CST easier to consume by higher-level logic:

- unwrap common wrappers (`expression`, `parenthesized_expression`, etc.)
- normalize list nodes to arrays
- standardize "block" representation
- standardize call shapes (`callee`, `args`)
- standardize operator shapes (`left`, `op`, `right`)

### Phase 2: Semantic construction

Goal: produce canonical AST node kinds

- build `Call`, `Infix`, `Prefix`, control flow nodes, declaration nodes
- apply precedence & associativity canonicalization
- unify sugar forms

### Profiles

Support two profiles:

| Profile    | Description                                           |
| ---------- | ----------------------------------------------------- |
| `lossless` | Minimal desugaring, keep `cst` backrefs on every node |
| `nim`      | Aggressively Nim-ish canonicalization                 |

## Consumption examples

### Example 1: Editor (highlighting only)

Users rely on:

- CST stability
- `queries/highlights.scm`

They never touch the AST.

### Example 2: LSP / analyzer (semantic tooling)

**Nim**

```nim
import tree_sitter_nim
import ast/nim/canonicalize_cst

let parser = newTSParser()
parser.setLanguage(treeSitterNim())

let tree = parser.parse(source)
let ast = canonicalizeCst(tree.rootNode, source, profile = "nim")

# Use ast for semantic analysis
for node in ast.walk:
  if node.kind == "Call":
    analyzeCall(node)
```

### Example 3: Refactoring tool (byte-precise rewrite)

Use CST spans to compute edits:

- find node range
- replace bytes exactly
- formatting left to user/formatter

```nim
proc renameSymbol(source: string, tree: TSTree, oldName, newName: string): string =
  var edits: seq[(int, int, string)]

  proc visit(node: TSNode) =
    if node.nodeType == "symbol":
      let text = source[node.startByte ..< node.endByte]
      if text == oldName:
        edits.add (node.startByte, node.endByte, newName)

    for i in 0 ..< node.childCount:
      visit(node.child(i))

  visit(tree.rootNode)

  # Apply edits in reverse order to preserve offsets
  result = source
  for i in countdown(edits.high, 0):
    let (start, stop, replacement) = edits[i]
    result = result[0 ..< start] & replacement & result[stop ..< result.len]
```

---

## Canonical AST Node Kinds

### Expressions

| Kind        | Fields                                | Description                  |
| ----------- | ------------------------------------- | ---------------------------- |
| `Ident`     | `name: string`                        | Identifier                   |
| `Qualified` | `parts: [Ident]`                      | Qualified identifier (a.b.c) |
| `IntLit`    | `value: string, base?: int`           | Integer literal              |
| `FloatLit`  | `value: string`                       | Float literal                |
| `StringLit` | `value: string, raw?: bool`           | String literal               |
| `CharLit`   | `value: string`                       | Character literal            |
| `NilLit`    | -                                     | Nil literal                  |
| `BoolLit`   | `value: bool`                         | Boolean literal              |
| `Infix`     | `left, operator, right`               | Infix expression             |
| `Prefix`    | `operator, operand`                   | Prefix expression            |
| `Call`      | `callee, args: []`                    | Function call                |
| `Command`   | `callee, args: []`                    | Command call (no parens)     |
| `Index`     | `base, indices: []`                   | Index expression             |
| `Dot`       | `base, field`                         | Dot expression               |
| `IfExpr`    | `condition, consequence, alternative` | If expression                |
| `CaseExpr`  | `expr, branches: []`                  | Case expression              |
| `BlockExpr` | `name?, body`                         | Block expression             |
| `TryExpr`   | `body, excepts: [], finally?`         | Try expression               |
| `Lambda`    | `kind, params?, returnType?, body?`   | Anonymous proc/func/iterator |
| `Tuple`     | `elements: []`                        | Tuple expression             |
| `Array`     | `elements: []`                        | Array expression             |
| `Set`       | `elements: []`                        | Set/table expression         |
| `Range`     | `start, stop`                         | Range expression             |
| `Cast`      | `type, expr`                          | Cast expression              |

### Statements

| Kind        | Fields                        | Description        |
| ----------- | ----------------------------- | ------------------ |
| `StmtList`  | `stmts: []`                   | Statement list     |
| `Assign`    | `left, right`                 | Assignment         |
| `Return`    | `value?`                      | Return statement   |
| `Raise`     | `value?`                      | Raise statement    |
| `Yield`     | `value?`                      | Yield statement    |
| `Discard`   | `value?`                      | Discard statement  |
| `Break`     | `label?`                      | Break statement    |
| `Continue`  | `label?`                      | Continue statement |
| `IfStmt`    | `branches: [], else?`         | If statement       |
| `WhenStmt`  | `branches: [], else?`         | When statement     |
| `CaseStmt`  | `expr, branches: [], else?`   | Case statement     |
| `WhileStmt` | `condition, body`             | While statement    |
| `ForStmt`   | `vars, iter, body`            | For statement      |
| `TryStmt`   | `body, excepts: [], finally?` | Try statement      |
| `BlockStmt` | `name?, body`                 | Block statement    |

### Declarations

| Kind           | Fields                                                              | Description        |
| -------------- | ------------------------------------------------------------------- | ------------------ |
| `ConstSection` | `defs: []`                                                          | Const section      |
| `LetSection`   | `defs: []`                                                          | Let section        |
| `VarSection`   | `defs: []`                                                          | Var section        |
| `TypeSection`  | `defs: []`                                                          | Type section       |
| `ConstDef`     | `name, type?, value`                                                | Const definition   |
| `LetDef`       | `name, type?, value?`                                               | Let definition     |
| `VarDef`       | `name, type?, value?`                                               | Var definition     |
| `TypeDef`      | `name, genericParams?, value`                                       | Type definition    |
| `RoutineDef`   | `kind, name, genericParams?, params?, returnType?, pragmas?, body?` | Routine definition |

### Types

| Kind           | Fields                           | Description                |
| -------------- | -------------------------------- | -------------------------- |
| `TypeRef`      | `name`                           | Simple type reference      |
| `GenericType`  | `name, args: []`                 | Generic type instantiation |
| `RefType`      | `base`                           | Reference type             |
| `PtrType`      | `base`                           | Pointer type               |
| `VarType`      | `base`                           | Var type                   |
| `DistinctType` | `base`                           | Distinct type              |
| `ProcType`     | `params?, returnType?, pragmas?` | Proc type                  |
| `TupleType`    | `fields: []`                     | Tuple type                 |
| `ObjectType`   | `parent?, fields: []`            | Object type                |
| `EnumType`     | `fields: []`                     | Enum type                  |

---

## Implementation Notes

### Tree-sitter Nim bindings

The test runner uses Nim bindings for tree-sitter. Options include:

1. **nim-tree-sitter** - Community Nim bindings
2. **Custom FFI wrapper** - Minimal wrapper around tree-sitter C API

### CST traversal

```nim
type
  TSNode = object
    # tree-sitter node wrapper

  AstNode = ref object
    kind: string
    span: Span
    children: seq[AstNode]
    fields: Table[string, AstNode]

proc childByFieldName(node: TSNode, name: string): TSNode
proc childCount(node: TSNode): int
proc child(node: TSNode, idx: int): TSNode
proc nodeType(node: TSNode): string
proc startByte(node: TSNode): int
proc endByte(node: TSNode): int
```

### Error handling during canonicalization

```nim
type
  CanonError = object
    message: string
    path: seq[string]
    span: Span

proc canonicalize(node: TSNode, source: string): (AstNode, seq[CanonError]) =
  var errors: seq[CanonError]

  proc visit(node: TSNode, path: seq[string]): AstNode =
    case node.nodeType
    of "ERROR":
      errors.add CanonError(
        message: "Parse error",
        path: path,
        span: node.span
      )
      return nil
    of "infix_expression":
      # ... canonicalize infix
    # ... other cases

  result = (visit(node, @[]), errors)
```

---

## Future Extensions

### Multi-threaded execution

A future version may add parallel test execution:

- Use a worker pool sized to CPU cores
- Maintain a global "Nim parse mutex" as a fallback
- Parallelize tree-sitter parsing and CST canonicalization (pure operations)

### Snapshot testing

Optional "golden" AST snapshots:

- `fixtures/expected/<corpusfile>/<testname>.ast.json`
- Enable with `--update-snapshots` flag

### Incremental testing

- Track which tests are affected by grammar changes
- Run only affected tests during development

---

## References

- [Nim compiler parser module](https://nim-lang.org/docs/compiler/parser.html)
- [Nim compiler internals](https://nim-lang.github.io/Nim/intern.html)
- [Tree-sitter documentation](https://tree-sitter.github.io/tree-sitter/)
- [Tree-sitter corpus format](https://tree-sitter.github.io/tree-sitter/creating-parsers#command-test)

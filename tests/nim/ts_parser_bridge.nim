## Tree-sitter parser bridge for Nim
##
## Provides FFI bindings to tree-sitter C API and wraps tree-sitter-nim parser.
## This module allows parsing Nim source code and traversing the resulting CST.

import std/[options, os, strutils]

const
  # tests/nim/ts_parser_bridge.nim -> tests/nim -> tests -> repo root
  repoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  srcDir = repoRoot / "src"

{.passL: "-ltree-sitter".}
{.passL: "-L" & srcDir.}
{.passC: "-I" & srcDir.}

# Compile tree-sitter-nim parser sources with explicit include path
{.compile(srcDir / "parser.c", "-I" & srcDir).}
{.compile(srcDir / "scanner.c", "-I" & srcDir).}

type
  TSLanguage* {.importc, header: "<tree_sitter/api.h>".} = object
  TSParser* {.importc, header: "<tree_sitter/api.h>".} = object
  TSTree* {.importc, header: "<tree_sitter/api.h>".} = object
  TSNode* {.importc, header: "<tree_sitter/api.h>".} = object

  TSPoint* {.importc, header: "<tree_sitter/api.h>".} = object
    row*: uint32
    column*: uint32

  TSSymbol* = uint16

  TSInputEncoding* {.size: sizeof(cint).} = enum
    TSInputEncodingUTF8 = 0
    TSInputEncodingUTF16 = 1

  # Nim-friendly wrapper types
  Point* = object
    row*: int
    column*: int

  Span* = object
    startByte*: int
    endByte*: int
    startPoint*: Point
    endPoint*: Point

  Node* = object
    ## Nim-friendly wrapper around TSNode
    raw: TSNode
    source: string  # Keep reference to source for text extraction

  TreeObj = object
    ## Nim-friendly wrapper around TSTree
    raw: ptr TSTree
    source: string

  Tree* = ref TreeObj

  ParserObj = object
    ## Nim-friendly wrapper around TSParser
    raw: ptr TSParser

  Parser* = ref ParserObj

# External tree-sitter API
proc tree_sitter_nim(): ptr TSLanguage {.importc.}

proc ts_parser_new(): ptr TSParser {.importc, header: "<tree_sitter/api.h>".}
proc ts_parser_delete(parser: ptr TSParser) {.importc, header: "<tree_sitter/api.h>".}
proc ts_parser_set_language(parser: ptr TSParser, language: ptr TSLanguage): bool {.importc, header: "<tree_sitter/api.h>".}
proc ts_parser_parse_string(parser: ptr TSParser, old_tree: ptr TSTree, str: cstring, len: uint32): ptr TSTree {.importc, header: "<tree_sitter/api.h>".}

proc ts_tree_delete(tree: ptr TSTree) {.importc, header: "<tree_sitter/api.h>".}
proc ts_tree_root_node(tree: ptr TSTree): TSNode {.importc, header: "<tree_sitter/api.h>".}

proc ts_node_type(node: TSNode): cstring {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_symbol(node: TSNode): TSSymbol {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_start_byte(node: TSNode): uint32 {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_end_byte(node: TSNode): uint32 {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_start_point(node: TSNode): TSPoint {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_end_point(node: TSNode): TSPoint {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_child_count(node: TSNode): uint32 {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_child(node: TSNode, index: uint32): TSNode {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_named_child_count(node: TSNode): uint32 {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_named_child(node: TSNode, index: uint32): TSNode {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_child_by_field_name(node: TSNode, name: cstring, nameLen: uint32): TSNode {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_field_name_for_child(node: TSNode, index: uint32): cstring {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_parent(node: TSNode): TSNode {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_next_sibling(node: TSNode): TSNode {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_prev_sibling(node: TSNode): TSNode {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_next_named_sibling(node: TSNode): TSNode {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_prev_named_sibling(node: TSNode): TSNode {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_is_named(node: TSNode): bool {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_is_null(node: TSNode): bool {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_is_missing(node: TSNode): bool {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_is_extra(node: TSNode): bool {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_has_error(node: TSNode): bool {.importc, header: "<tree_sitter/api.h>".}
proc ts_node_string(node: TSNode): cstring {.importc, header: "<tree_sitter/api.h>".}

proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc ts_node_eq(a: TSNode, b: TSNode): bool {.importc, header: "<tree_sitter/api.h>".}

# Destructors for wrapper types (must be defined before first use)

proc `=destroy`(p: ParserObj) =
  if p.raw != nil:
    ts_parser_delete(p.raw)

proc `=destroy`(t: TreeObj) =
  if t.raw != nil:
    ts_tree_delete(t.raw)

# Wrapper implementations

proc newParser*(): Parser =
  ## Create a new tree-sitter parser for Nim
  result = Parser(raw: ts_parser_new())
  if not ts_parser_set_language(result.raw, tree_sitter_nim()):
    raise newException(ValueError, "Failed to set Nim language")

proc parse*(parser: Parser, source: string): Tree =
  ## Parse source code and return a syntax tree
  let rawTree = ts_parser_parse_string(parser.raw, nil, source.cstring, source.len.uint32)
  if rawTree == nil:
    raise newException(ValueError, "Failed to parse source")
  result = Tree(raw: rawTree, source: source)

proc rootNode*(tree: Tree): Node =
  ## Get the root node of the tree
  Node(raw: ts_tree_root_node(tree.raw), source: tree.source)

# Node methods

proc nodeType*(node: Node): string =
  ## Get the type/kind of a node
  $ts_node_type(node.raw)

proc isNamed*(node: Node): bool =
  ## Check if this is a named node
  ts_node_is_named(node.raw)

proc isNull*(node: Node): bool =
  ## Check if this node is null
  ts_node_is_null(node.raw)

proc `==`*(a, b: Node): bool =
  ## Compare two nodes for equality
  ts_node_eq(a.raw, b.raw)

proc isMissing*(node: Node): bool =
  ## Check if this node is missing (inserted by error recovery)
  ts_node_is_missing(node.raw)

proc isExtra*(node: Node): bool =
  ## Check if this is an extra node (comments, etc.)
  ts_node_is_extra(node.raw)

proc hasError*(node: Node): bool =
  ## Check if this node or any descendant has an error
  ts_node_has_error(node.raw)

proc startByte*(node: Node): int =
  ## Get the start byte offset
  ts_node_start_byte(node.raw).int

proc endByte*(node: Node): int =
  ## Get the end byte offset
  ts_node_end_byte(node.raw).int

proc startPoint*(node: Node): Point =
  ## Get the start row/column
  let p = ts_node_start_point(node.raw)
  Point(row: p.row.int, column: p.column.int)

proc endPoint*(node: Node): Point =
  ## Get the end row/column
  let p = ts_node_end_point(node.raw)
  Point(row: p.row.int, column: p.column.int)

proc span*(node: Node): Span =
  ## Get the full span of a node
  Span(
    startByte: node.startByte,
    endByte: node.endByte,
    startPoint: node.startPoint,
    endPoint: node.endPoint
  )

proc text*(node: Node): string =
  ## Get the source text for a node
  let s = node.startByte
  let e = node.endByte
  if s >= 0 and e <= node.source.len and s <= e:
    node.source[s ..< e]
  else:
    ""

proc childCount*(node: Node): int =
  ## Get the number of children (including anonymous)
  ts_node_child_count(node.raw).int

proc namedChildCount*(node: Node): int =
  ## Get the number of named children
  ts_node_named_child_count(node.raw).int

proc child*(node: Node, index: int): Node =
  ## Get child at index (including anonymous)
  Node(raw: ts_node_child(node.raw, index.uint32), source: node.source)

proc namedChild*(node: Node, index: int): Node =
  ## Get named child at index
  Node(raw: ts_node_named_child(node.raw, index.uint32), source: node.source)

proc childByFieldName*(node: Node, name: string): Option[Node] =
  ## Get child by field name
  let child = ts_node_child_by_field_name(node.raw, name.cstring, name.len.uint32)
  if ts_node_is_null(child):
    none(Node)
  else:
    some(Node(raw: child, source: node.source))

proc fieldNameForChild*(node: Node, index: int): string =
  ## Get the field name for a child at index
  let name = ts_node_field_name_for_child(node.raw, index.uint32)
  if name == nil:
    ""
  else:
    $name

proc parent*(node: Node): Option[Node] =
  ## Get the parent node
  let p = ts_node_parent(node.raw)
  if ts_node_is_null(p):
    none(Node)
  else:
    some(Node(raw: p, source: node.source))

proc nextSibling*(node: Node): Option[Node] =
  ## Get the next sibling node
  let s = ts_node_next_sibling(node.raw)
  if ts_node_is_null(s):
    none(Node)
  else:
    some(Node(raw: s, source: node.source))

proc prevSibling*(node: Node): Option[Node] =
  ## Get the previous sibling node
  let s = ts_node_prev_sibling(node.raw)
  if ts_node_is_null(s):
    none(Node)
  else:
    some(Node(raw: s, source: node.source))

proc nextNamedSibling*(node: Node): Option[Node] =
  ## Get the next named sibling node
  let s = ts_node_next_named_sibling(node.raw)
  if ts_node_is_null(s):
    none(Node)
  else:
    some(Node(raw: s, source: node.source))

proc prevNamedSibling*(node: Node): Option[Node] =
  ## Get the previous named sibling node
  let s = ts_node_prev_named_sibling(node.raw)
  if ts_node_is_null(s):
    none(Node)
  else:
    some(Node(raw: s, source: node.source))

proc sexp*(node: Node): string =
  ## Get S-expression representation of the tree
  let s = ts_node_string(node.raw)
  result = $s
  free(s)

iterator children*(node: Node): Node =
  ## Iterate over all children (including anonymous)
  for i in 0 ..< node.childCount:
    yield node.child(i)

iterator namedChildren*(node: Node): Node =
  ## Iterate over named children only
  for i in 0 ..< node.namedChildCount:
    yield node.namedChild(i)

iterator childrenWithFieldNames*(node: Node): tuple[name: string, node: Node] =
  ## Iterate over all children with their field names
  for i in 0 ..< node.childCount:
    yield (node.fieldNameForChild(i), node.child(i))

iterator walk*(node: Node): Node =
  ## Pre-order traversal over all nodes in the subtree
  var stack: seq[Node] = @[node]
  while stack.len > 0:
    let current = stack.pop()
    yield current
    # Add children in reverse order so they're visited left-to-right
    for i in countdown(current.childCount - 1, 0):
      stack.add current.child(i)

iterator walkLeaves*(node: Node): Node =
  ## Iterate over leaf nodes only
  var stack: seq[Node] = @[node]
  while stack.len > 0:
    let current = stack.pop()
    if current.childCount == 0:
      yield current
    else:
      for i in countdown(current.childCount - 1, 0):
        stack.add current.child(i)

proc `$`*(node: Node): string =
  ## String representation
  node.nodeType & "[" & $node.startByte & ".." & $node.endByte & "]"

proc `$`*(span: Span): string =
  ## String representation of span
  $span.startByte & ".." & $span.endByte &
    " (" & $span.startPoint.row & ":" & $span.startPoint.column &
    "-" & $span.endPoint.row & ":" & $span.endPoint.column & ")"

when isMainModule:
  # Test the parser bridge
  let source = """
proc hello*(name: string): string =
  result = "Hello, " & name
"""

  let parser = newParser()
  let tree = parser.parse(source)
  let root = tree.rootNode

  echo "Root: ", root
  echo "Root type: ", root.nodeType
  echo "Root span: ", root.span
  echo "Has error: ", root.hasError

  echo "\nS-expression:"
  echo root.sexp

  echo "\nLeaf nodes:"
  for leaf in root.walkLeaves:
    echo "  ", leaf, ": \"", leaf.text.replace("\n", "\\n"), "\""

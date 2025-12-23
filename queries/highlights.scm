; Nim Tree-sitter Syntax Highlighting Queries
; ===========================================

; Comments
; --------
(comment) @comment

; Literals
; --------
(integer_literal) @number
(float_literal) @number.float

(string_literal) @string
(raw_string_literal) @string
(triple_string_literal) @string
(char_literal) @character

(boolean_literal) @constant.builtin
(nil_literal) @constant.builtin

; Generalized string literals (e.g., re"pattern", fmt"hello")
(generalized_string) @string.special

; Identifiers
; -----------
(identifier) @variable

; Quoted identifiers (e.g., `+`, `my-var`)
(quoted_identifier) @variable

; Qualified identifiers (e.g., system.echo)
(qualified_identifier
  (symbol) @module
  .
  (symbol) @variable)

; Constants - UPPER_CASE identifiers
((identifier) @constant
  (#match? @constant "^[A-Z][A-Z0-9_]+$"))

; Type names - PascalCase identifiers (in type contexts)
(type_expr
  (qualified_identifier
    (symbol
      (identifier) @type)))

(generic_type
  name: (qualified_identifier
    (symbol
      (identifier) @type)))

; Function Definitions
; --------------------
(routine_definition
  kind: (routine_kind) @keyword.function
  name: (exported_symbol
    (symbol
      (identifier) @function.definition)))

(routine_definition
  kind: (routine_kind) @keyword.function
  name: (exported_symbol
    (symbol
      (quoted_identifier) @function.definition)))

; Routine headers (forward declarations)
(routine_header
  kind: (routine_kind) @keyword.function
  name: (exported_symbol
    (symbol
      (identifier) @function.definition)))

; Lambda/anonymous procs
(proc_expr
  (param_list) @punctuation.bracket)

; Function Calls
; --------------
; Direct call: foo(x)
(call_suffix
  "(" @punctuation.bracket
  ")" @punctuation.bracket)

(postfix_expr
  (postfixable_primary
    (symbol
      (identifier) @function.call))
  (call_suffix))

(postfix_expr
  (postfixable_primary
    (symbol
      (quoted_identifier) @function.call))
  (call_suffix))

; Method call: x.foo()
(postfix_expr
  (dot_suffix
    (symbol_or_keyword
      (symbol
        (identifier) @function.method))))

; Command call: echo "hello"
(command_expr
  (postfixable_primary
    (symbol
      (identifier) @function.call)))

; Call with blocks: x.map do (y): y + 1
(call_with_blocks
  call: (_
    (postfixable_primary
      (symbol
        (identifier) @function.call))))

; Parameters
; ----------
(param_decl
  (symbol
    (identifier) @variable.parameter))

(param_decl
  modifier: (param_modifier) @keyword.modifier)

; Generic parameters
(generic_param
  (symbol
    (identifier) @type.parameter))

; For loop variables
(for_pattern
  (symbol
    (identifier) @variable))

; Type Definitions
; ----------------
(type_def
  name: (exported_symbol
    (symbol
      (identifier) @type.definition)))

; Enum fields
(enum_field_def
  name: (exported_symbol
    (symbol
      (identifier) @constant)))

; Object fields
(object_field
  name: (exported_symbol
    (symbol
      (identifier) @property)))

; Tuple fields
(tuple_field
  (symbol
    (identifier) @property))

; Variable Definitions
; --------------------
(decl_def
  (exported_symbol
    (symbol
      (identifier) @variable.definition)))

; Tuple unpacking
(tuple_decl
  (exported_symbol
    (symbol
      (identifier) @variable.definition)))

; Operators
; ---------
(add_operator) @operator
(mul_operator) @operator
(pow_operator) @operator
(cmp_operator) @operator
(amp_operator) @operator
(range_operator) @operator
(arrow_operator) @operator
(assign_operator) @operator
(or_operator) @operator
(and_operator) @operator
(op2_operator) @operator
(type_cmp_operator) @operator
(unary_operator) @operator
(custom_prefix_operator) @operator

; Assignment
(assignment_stmt
  "=" @operator)

; Punctuation
; -----------
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket

"," @punctuation.delimiter
";" @punctuation.delimiter
":" @punctuation.delimiter
"." @punctuation.delimiter

; Pragmas
; -------
(pragma
  "{." @punctuation.special
  ".}" @punctuation.special)

(pragma_item
  (symbol
    (identifier) @attribute))

; Export marker
(exported_symbol
  "*" @punctuation.special)

; Keywords
; --------
; Control flow
[
  "if"
  "elif"
  "else"
  "when"
  "case"
  "of"
] @keyword.conditional

[
  "while"
  "for"
  "in"
] @keyword.repeat

[
  "try"
  "except"
  "finally"
  "raise"
] @keyword.exception

[
  "break"
  "continue"
  "return"
  "yield"
] @keyword.return

; Definitions
[
  "proc"
  "func"
  "method"
  "iterator"
  "macro"
  "template"
  "converter"
] @keyword.function

[
  "type"
  "object"
  "enum"
  "concept"
  "tuple"
  "distinct"
] @keyword.type

[
  "var"
  "let"
  "const"
  "using"
] @keyword.storage

; Modifiers
[
  "ref"
  "ptr"
  "static"
  "lent"
  "sink"
  "out"
] @keyword.modifier

; Imports/exports
[
  "import"
  "export"
  "include"
  "from"
  "as"
  "except"
] @keyword.import

; Other keywords
[
  "block"
  "defer"
  "do"
  "discard"
  "asm"
  "bind"
  "mixin"
  "cast"
  "nil"
] @keyword

; Operators as keywords
[
  "and"
  "or"
  "xor"
  "not"
  "div"
  "mod"
  "shl"
  "shr"
  "is"
  "isnot"
  "notin"
] @keyword.operator

; Built-in types (common ones)
((identifier) @type.builtin
  (#any-of? @type.builtin
    "int" "int8" "int16" "int32" "int64"
    "uint" "uint8" "uint16" "uint32" "uint64"
    "float" "float32" "float64"
    "bool" "char" "string" "cstring"
    "void" "auto" "any"
    "seq" "array" "set" "Table" "HashSet"
    "openArray" "varargs" "typedesc" "range"
    "Natural" "Positive" "BiggestInt" "BiggestFloat"
    "SomeInteger" "SomeFloat" "SomeNumber" "SomeOrdinal"))

; Built-in functions (common ones)
((identifier) @function.builtin
  (#any-of? @function.builtin
    "echo" "debugEcho" "quit" "assert" "doAssert"
    "len" "high" "low" "sizeof" "typeof" "repr"
    "add" "del" "delete" "insert" "pop" "contains"
    "newSeq" "newString" "new" "alloc" "dealloc" "realloc"
    "inc" "dec" "succ" "pred" "abs" "min" "max" "clamp"
    "ord" "chr" "toInt" "toFloat" "toBool"
    "defined" "declared" "compiles" "compileTime"
    "likely" "unlikely"
    "move" "sink" "lent"
    "staticRead" "staticExec" "gorge" "slurp"))

; Special identifiers
((identifier) @variable.builtin
  (#any-of? @variable.builtin "result" "self" "this"))

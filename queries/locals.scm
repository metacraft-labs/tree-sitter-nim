; Nim Tree-sitter Locals Queries
; ==============================
; Defines scopes, definitions, and references for semantic navigation

; Scopes
; ------

; Module scope (implicit - whole file)
(source_file) @local.scope

; Routine scopes
(routine_definition) @local.scope
(proc_expr) @local.scope

; Block scopes
(block_stmt) @local.scope
(block_expr) @local.scope

; Control flow scopes
(if_stmt) @local.scope
(if_expr) @local.scope
(when_stmt) @local.scope
(case_stmt) @local.scope
(case_expr) @local.scope
(while_stmt) @local.scope
(for_stmt) @local.scope
(try_stmt) @local.scope
(try_expr) @local.scope

; Type definition scopes
(object_def) @local.scope
(enum_def) @local.scope
(concept_def) @local.scope

; Do block scope
(do_block) @local.scope

; Definitions
; -----------

; Variable definitions (let, var, const)
(decl_def
  (exported_symbol
    (symbol
      (identifier) @local.definition.variable)))

(decl_def
  (exported_symbol
    (symbol
      (quoted_identifier) @local.definition.variable)))

; Tuple unpacking definitions
(tuple_decl
  (exported_symbol
    (symbol
      (identifier) @local.definition.variable)))

; Function definitions
(routine_definition
  name: (exported_symbol
    (symbol
      (identifier) @local.definition.function)))

(routine_definition
  name: (exported_symbol
    (symbol
      (quoted_identifier) @local.definition.function)))

; Type definitions
(type_def
  name: (exported_symbol
    (symbol
      (identifier) @local.definition.type)))

; Enum field definitions
(enum_field_def
  name: (exported_symbol
    (symbol
      (identifier) @local.definition.constant)))

; Parameter definitions
(param_decl
  (symbol
    (identifier) @local.definition.parameter))

; Generic parameter definitions
(generic_param
  (symbol
    (identifier) @local.definition.type))

; For loop variable definitions
(for_pattern
  (symbol
    (identifier) @local.definition.variable))

; Object field definitions
(object_field
  name: (exported_symbol
    (symbol
      (identifier) @local.definition.field)))

; Tuple field definitions
(tuple_field
  (symbol
    (identifier) @local.definition.field))

; References
; ----------

; Any identifier use is potentially a reference
(symbol
  (identifier) @local.reference)

(symbol
  (quoted_identifier) @local.reference)

; Qualified identifier references
(qualified_identifier
  (symbol
    (identifier) @local.reference))

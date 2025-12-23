; Nim Tree-sitter Tags Queries
; ============================
; Defines symbols for outline views and code navigation

; Function definitions
; --------------------
(routine_definition
  kind: (routine_kind) @kind
  name: (exported_symbol
    (symbol) @name)) @definition.function

; Forward declarations (routine headers without body)
(routine_header
  kind: (routine_kind) @kind
  name: (exported_symbol
    (symbol) @name)) @definition.function

; Type definitions
; ----------------
; Object types
(type_def
  name: (exported_symbol
    (symbol) @name)
  value: (object_def)) @definition.class

; Enum types
(type_def
  name: (exported_symbol
    (symbol) @name)
  value: (enum_def)) @definition.enum

; Concept types
(type_def
  name: (exported_symbol
    (symbol) @name)
  value: (concept_def)) @definition.interface

; All other type definitions (aliases, distinct, ref, ptr, tuple, etc.)
(type_def
  name: (exported_symbol
    (symbol) @name)) @definition.type

; Enum fields
; -----------
(enum_field_def
  name: (exported_symbol
    (symbol) @name)) @definition.constant

; Object fields
; -------------
(object_field
  name: (exported_symbol
    (symbol) @name)) @definition.field

; Constant definitions
; --------------------
(const_section
  (decl_def
    (exported_symbol
      (symbol) @name))) @definition.constant

; Variable definitions (module-level)
; -----------------------------------
(section_stmt
  (var_section
    (decl_def
      (exported_symbol
        (symbol) @name)))) @definition.variable

(section_stmt
  (let_section
    (decl_def
      (exported_symbol
        (symbol) @name)))) @definition.variable

; Import references
; -----------------
(import_stmt
  (import_expr
    (import_path
      (symbol) @name))) @reference.module

(from_import_stmt
  (import_path
    (symbol) @name)) @reference.module

; References
; ----------
; Function calls
(postfix_expr
  (postfixable_primary
    (symbol) @name)
  (call_suffix)) @reference.call

; Command calls
(command_expr
  (postfixable_primary
    (symbol) @name)) @reference.call

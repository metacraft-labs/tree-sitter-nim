; Nim Tree-sitter Folds Queries
; =============================
; Defines foldable regions for code editors

; Routine definitions are foldable
(routine_definition) @fold

; Type sections
(type_section) @fold

; Variable/const/let sections
(var_section) @fold
(let_section) @fold
(const_section) @fold

; Control flow blocks
(if_stmt) @fold
(if_expr) @fold
(when_stmt) @fold
(case_stmt) @fold
(case_expr) @fold
(while_stmt) @fold
(for_stmt) @fold

; Exception handling
(try_stmt) @fold
(try_expr) @fold
(except_branch) @fold
(finally_branch) @fold

; Block statements
(block_stmt) @fold
(block_expr) @fold

; Object definitions
(object_def) @fold

; Enum definitions
(enum_def) @fold

; Concept definitions
(concept_def) @fold

; Tuple types with fields
(tuple_type) @fold

; Case branches in variant objects
(object_case) @fold
(object_of_branch) @fold
(object_else_branch) @fold

; Do blocks
(do_block) @fold

; Inline statement lists (multi-line)
(inline_stmt_list) @fold

; Comments (multi-line block comments)
(comment) @fold

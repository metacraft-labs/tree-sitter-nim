; Nim Tree-sitter Indents Queries
; ===============================
; Defines indentation rules for code editors (nvim-treesitter format)

; Indent after these constructs
[
  (routine_definition)
  (if_stmt)
  (if_expr)
  (when_stmt)
  (case_stmt)
  (case_expr)
  (while_stmt)
  (for_stmt)
  (try_stmt)
  (try_expr)
  (block_stmt)
  (block_expr)
  (object_def)
  (enum_def)
  (concept_def)
  (type_section)
  (var_section)
  (let_section)
  (const_section)
  (except_branch)
  (finally_branch)
  (of_branch)
  (else_branch)
  (object_case)
  (object_of_branch)
  (object_else_branch)
  (object_when)
  (do_block)
  (proc_expr)
] @indent.begin

; Dedent on these tokens
[
  "elif"
  "else"
  "except"
  "finally"
  "of"
] @indent.branch

; End indent at closing constructs
[
  (routine_definition)
  (if_stmt)
  (if_expr)
  (when_stmt)
  (case_stmt)
  (case_expr)
  (while_stmt)
  (for_stmt)
  (try_stmt)
  (try_expr)
  (block_stmt)
  (block_expr)
] @indent.end

; Auto-indent after colon
":" @indent.begin

; Brackets
"(" @indent.begin
")" @indent.end
"[" @indent.begin
"]" @indent.end
"{" @indent.begin
"}" @indent.end

; Ignore comments for indentation calculation
(comment) @indent.ignore

; Zero indent for top-level items
(source_file
  (_) @indent.zero)

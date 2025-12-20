// Nim's operator precedence from lexer.nim:getPrecedence (higher = binds tighter)
// 10: $ ^        (highest infix - both same tier!)
//  9: * / div mod shl shr % \
//  8: + - | ~    (note: | is add-level, NOT or-level)
//  7: &
//  6: ..         (range/dot operators)
//  5: == != < > <= >= in notin is isnot of as from
//  4: and
//  3: or xor
//  1: assignment-like operators (+=, *=, etc. - but not bare =)
//  0: -> ~> =>   (arrow operators - lowest)
const PREC = {
  ARROW: 0, // -> ~> => (lowest)
  ASSIGN_OP: 1, // += -= *= etc (assignment-like operators)
  OR: 2, // or xor
  AND: 3, // and
  CMP: 4, // == != < > in is of as etc
  RANGE: 5, // .. and dot-operators
  AMP: 6, // &
  ADD: 7, // + - | ~
  MUL: 8, // * / % div mod shl shr
  POW: 9, // $ ^ (same tier, left associative)
  PREFIX: 10,
  CALL: 11,
  COMMAND: -1, // Lower than all expression operators
};

function sep1(rule, sep) {
  return seq(rule, repeat(seq(sep, rule)));
}
function commaSep(rule) {
  return optional(sep1(rule, ","));
}
function commaSep1(rule) {
  return sep1(rule, ",");
}

module.exports = grammar({
  name: "nim",

  externals: ($) => [
    $._indent,
    $._dedent,
    $._newline,
    $._soft_newline,
    $.comment,
  ],

  extras: ($) => [$._ws, $._soft_newline, $.comment],

  conflicts: ($) => [
    [$.routine_definition],
    [$.qualified_identifier],
    [$.type_expr, $.generic_type],
    [$.type_expr, $.type_call],
    [$.primary, $.type_expr],
    [$.primary, $.generic_type],
    [$.primary, $.type_call],
    [$.param_decl],
    [$.enum_def],
    [$.enum_field_def],
    [$.command_arg, $.qualified_identifier],
    [$.command_first_arg, $.qualified_identifier],
    [$.import_symbol, $.qualified_identifier],
    [$.object_def],
    [$.object_def, $.object_type],
    [$.proc_type],
    [$.iterator_type],
    [$.object_case],
    [$.object_type],
    [$.concept_def],
    [$.expr_stmt, $._expr_body],
    [$.assignment_stmt, $._expr_body],
    [$._suite, $._expr_body],
  ],

  word: ($) => $.identifier,

  rules: {
    source_file: ($) => repeat($._statement),

    // Whitespace token for extras and explicit whitespace requirements
    _ws: (_) => token(/[ \t\f\r]+/),

    _statement: ($) =>
      choice($.simple_stmt_line, $.compound_stmt, $.section_stmt, $._newline),

    // -------------------------------
    // Simple statements (line-terminated)
    // -------------------------------
    simple_stmt_line: ($) => seq(sep1($.simple_stmt, ";"), $._newline),

    simple_stmt: ($) =>
      choice(
        $.return_stmt,
        $.raise_stmt,
        $.yield_stmt,
        $.discard_stmt,
        $.break_stmt,
        $.continue_stmt,
        $.import_stmt,
        $.export_stmt,
        $.include_stmt,
        $.from_import_stmt,
        $.bind_stmt,
        $.mixin_stmt,
        $.pragma_stmt,
        $.expr_stmt,
      ),

    // Standalone pragma statement: {.push warnings: off.}, {.pop.}
    pragma_stmt: ($) => $.pragma,

    return_stmt: ($) => seq("return", optional($.expression)),
    raise_stmt: ($) => seq("raise", optional($.expression)),
    yield_stmt: ($) => seq("yield", optional($.expression)),
    discard_stmt: ($) => seq("discard", optional($.expression)),
    break_stmt: ($) => seq("break", optional($.expression)),
    continue_stmt: ($) => seq("continue", optional($.expression)),

    // Import statements with optional rename (as) and optional except clause
    import_stmt: ($) =>
      seq(
        "import",
        sep1($.import_expr, ","),
        optional(seq("except", sep1($.symbol, ","))),
      ),
    export_stmt: ($) =>
      seq(
        "export",
        sep1($.import_expr, ","),
        optional(seq("except", sep1($.symbol, ","))),
      ),
    include_stmt: ($) => seq("include", sep1($.import_path, ",")),

    import_expr: ($) =>
      seq($.import_path, optional(seq("as", field("alias", $.symbol)))),

    // from X import Y - does NOT support except (that's only on import/export)
    from_import_stmt: ($) =>
      seq("from", $.import_path, "import", sep1($.import_symbol, ",")),

    import_symbol: ($) =>
      seq(
        choice($.symbol, $.qualified_identifier),
        optional(seq("as", field("alias", $.symbol))),
      ),

    // Import path supports: os, std.os, std/os, std/[os, strutils], "path/to/module"
    import_path: ($) =>
      choice($.string_literal, $._import_path_simple, $._import_path_bracket),

    _import_path_simple: ($) =>
      seq($.symbol, repeat(seq(choice(".", "/"), $.symbol))),

    _import_path_bracket: ($) =>
      seq(
        $.symbol,
        repeat(seq(choice(".", "/"), $.symbol)),
        "/",
        "[",
        sep1($.symbol, ","),
        optional(","),
        "]",
      ),

    bind_stmt: ($) => seq("bind", sep1($.symbol, ",")),
    mixin_stmt: ($) => seq("mixin", sep1($.symbol, ",")),

    expr_stmt: ($) => choice($.assignment_stmt, $.expression),

    // Assignment statement with = or assignment operators (+=, -=, *=, etc.)
    // Assignment operators are those ending with = but not starting with = < > !
    assignment_stmt: ($) =>
      prec.right(
        seq(
          field("left", $.expression),
          field("operator", choice("=", $.assignment_operator)),
          field("right", $.expression),
        ),
      ),

    // Assignment operators: end with = but don't start with = < > !
    // Examples: +=, -=, *=, /=, &=, |=, ^=, $=, @=, etc.
    // Note: ==, !=, <=, >= are comparison operators, not assignment
    assignment_operator: (_) =>
      token(/[+\-*\/%&|^$@~:\\][=+\-*\/<>@$~&%|!?^.:\\]*=/),

    // -------------------------------
    // Compound statements (suite-based)
    // -------------------------------
    compound_stmt: ($) =>
      choice(
        $.if_stmt,
        $.when_stmt,
        $.while_stmt,
        $.for_stmt,
        $.try_stmt,
        $.case_stmt,
        $.block_stmt,
        $.static_stmt,
        $.defer_stmt,
        $.asm_stmt,
        $.routine_definition,
      ),

    // Unified suite handling - reusable for both : and = forms
    _suite: ($) =>
      choice(
        seq($.inline_stmt_list, $._newline),
        seq(
          $._newline,
          repeat($._newline),
          $._indent,
          repeat($._statement),
          $._dedent,
        ),
      ),

    _colon_suite: ($) => seq(":", $._suite),

    _equals_suite: ($) => seq("=", $._suite),

    inline_stmt_list: ($) => sep1($.simple_stmt, ";"),

    if_stmt: ($) =>
      seq(
        "if",
        field("condition", $.expression),
        field("consequence", $._colon_suite),
        repeat(seq("elif", field("condition", $.expression), $._colon_suite)),
        optional(seq("else", field("alternative", $._colon_suite))),
      ),

    when_stmt: ($) =>
      seq(
        "when",
        field("condition", $.expression),
        $._colon_suite,
        repeat(seq("elif", field("condition", $.expression), $._colon_suite)),
        optional(seq("else", $._colon_suite)),
      ),

    while_stmt: ($) =>
      seq(
        "while",
        field("condition", $.expression),
        field("body", $._colon_suite),
      ),

    for_stmt: ($) =>
      seq(
        "for",
        field("variables", $.for_pattern),
        "in",
        field("iterable", $.expression),
        field("body", $._colon_suite),
      ),

    // For loop pattern: single variable, multiple variables, or tuple destructuring
    // Examples: for x in ..., for x, y in ..., for (a, b) in ...
    for_pattern: ($) =>
      choice(
        sep1($.symbol, ","), // x or x, y
        $.tuple_expr, // (a, b) destructuring
      ),

    // try can have: (1) except branches + optional finally, or (2) finally only
    try_stmt: ($) =>
      seq(
        "try",
        $._colon_suite,
        choice(
          seq(repeat1($.except_branch), optional($.finally_branch)),
          $.finally_branch,
        ),
      ),

    except_branch: ($) =>
      seq("except", optional($.expression_list), $._colon_suite),

    finally_branch: ($) => seq("finally", $._colon_suite),

    // case statement with proper ordering: of branches first, then optional else at end
    // Nim's structure: case expr: (of expr: suite)+ (else: suite)?
    // At least one of branch is required
    case_stmt: ($) =>
      seq(
        "case",
        field("expression", $.expression),
        optional(":"),
        $._newline,
        repeat($._newline),
        $._indent,
        // Require at least one of_branch
        repeat($._newline),
        $.of_branch,
        repeat(choice($.of_branch, $._newline)),
        optional(seq($.else_branch, repeat($._newline))),
        $._dedent,
      ),

    of_branch: ($) => seq("of", $.expression_list, $._colon_suite),
    else_branch: ($) => seq("else", $._colon_suite),

    block_stmt: ($) =>
      seq(
        "block",
        optional(field("name", $.symbol)),
        field("body", $._colon_suite),
      ),
    static_stmt: ($) => seq("static", $._colon_suite),
    defer_stmt: ($) => seq("defer", $._colon_suite),

    asm_stmt: ($) =>
      seq(
        "asm",
        optional($.pragma),
        choice($.string_literal, $.triple_string_literal, $._colon_suite),
      ),

    // -------------------------------
    // Sections
    // -------------------------------
    section_stmt: ($) =>
      choice(
        $.type_section,
        $.const_section,
        $.let_section,
        $.var_section,
        $.using_section,
      ),

    // Per-section body rules - each section only allows its specific item type
    // This reduces ambiguity and prevents invalid parses (e.g., type_def in var section)
    _type_section_body: ($) =>
      seq(
        $._newline,
        repeat($._newline),
        $._indent,
        repeat(choice($.type_def, $._newline)),
        $._dedent,
      ),

    _decl_section_body: ($) =>
      seq(
        $._newline,
        repeat($._newline),
        $._indent,
        repeat(choice($.decl_def, $._newline)),
        $._dedent,
      ),

    // Type section supports both block and inline forms
    // Block form only allows type_def, inline form is a single type_def
    type_section: ($) =>
      seq(
        "type",
        choice(
          $._type_section_body,
          $.type_def, // Inline form: type Foo = int
        ),
      ),

    // Const section supports both block and inline forms
    // Block form only allows decl_def, inline form is a single decl_def
    const_section: ($) =>
      seq(
        "const",
        choice(
          $._decl_section_body,
          $.decl_def, // Inline form: const N = 10
        ),
      ),

    // Let section supports both block and inline forms
    let_section: ($) =>
      seq(
        "let",
        choice(
          $._decl_section_body,
          $.decl_def, // Inline form: let x = 1
        ),
      ),

    // Var section supports both block and inline forms
    var_section: ($) =>
      seq(
        "var",
        choice(
          $._decl_section_body,
          $.decl_def, // Inline form: var x = 1
        ),
      ),

    // Using section supports both block and inline forms
    using_section: ($) =>
      seq(
        "using",
        choice(
          $._decl_section_body,
          $.decl_def, // Inline form: using x: int
        ),
      ),

    type_def: ($) =>
      seq(
        field("name", $.exported_symbol),
        optional($.generic_params),
        optional($.pragma),
        "=",
        field("value", $._type_def_value),
      ),

    _type_def_value: ($) =>
      choice($.type_expr, $.enum_def, $.object_def, $.concept_def),

    // Enum definition with optional values
    // Nim allows both comma-separated and newline-separated enum fields
    enum_def: ($) =>
      seq(
        "enum",
        optional($.pragma),
        optional(
          choice(
            // Inline form: enum A, B, C (comma-separated, optional trailing comma)
            seq(commaSep1($.enum_field_def), optional(",")),
            // Indented form - can have comma-separated or newline-separated fields
            seq(
              $._newline,
              repeat($._newline),
              $._indent,
              repeat(choice($._enum_field_line, $._newline)),
              $._dedent,
            ),
          ),
        ),
      ),

    // A line of enum fields (can have multiple comma-separated fields)
    _enum_field_line: ($) =>
      prec.left(seq(commaSep1($.enum_field_def), optional(","))),

    // Enum field without trailing comma - commas are handled by the list rule
    enum_field_def: ($) =>
      seq(
        field("name", $.exported_symbol),
        optional($.pragma),
        optional(seq("=", field("value", $.expression))),
      ),

    // Object definition with fields
    // Uses seq("ref", "object") instead of "ref object" to handle whitespace properly
    // Supports: fields, case branches, when branches, nil, discard
    object_def: ($) =>
      seq(
        choice("object", seq("ref", "object"), seq("ptr", "object")),
        optional(seq("of", field("parent", $.type_expr))),
        optional($.pragma),
        optional(
          seq(
            $._newline,
            repeat($._newline),
            $._indent,
            repeat(choice($._object_part, $._newline)),
            $._dedent,
          ),
        ),
      ),

    // Object parts: fields, case variants, when branches, nil, discard
    _object_part: ($) =>
      choice(
        $.object_field,
        $.object_case,
        $.object_when,
        $.object_nil,
        $.object_discard,
      ),

    object_field: ($) =>
      seq(
        sep1(field("name", $.exported_symbol), ","),
        optional($.pragma),
        ":",
        field("type", $.type_expr),
        optional(seq("=", field("default", $.expression))),
        $._newline,
      ),

    // When branch inside object (compile-time conditional fields)
    // when defined(windows):
    //   handle: HANDLE
    // else:
    //   fd: cint
    object_when: ($) =>
      seq(
        "when",
        field("condition", $.expression),
        ":",
        $._newline,
        repeat($._newline),
        $._indent,
        repeat(choice($._object_part, $._newline)),
        $._dedent,
        repeat(
          seq(
            "elif",
            field("condition", $.expression),
            ":",
            $._newline,
            repeat($._newline),
            $._indent,
            repeat(choice($._object_part, $._newline)),
            $._dedent,
          ),
        ),
        optional(
          seq(
            "else",
            ":",
            $._newline,
            repeat($._newline),
            $._indent,
            repeat(choice($._object_part, $._newline)),
            $._dedent,
          ),
        ),
      ),

    // nil part in object - indicates no fields (used in variant objects)
    object_nil: ($) => seq("nil", $._newline),

    // discard part in object - similar to nil
    object_discard: ($) => seq("discard", $._newline),

    // Variant object (case inside object)
    // In Nim, the of/else branches are at the same indentation level as the case,
    // not indented further. The fields inside of/else branches ARE indented.
    // Proper ordering: of branches first, then optional else at end
    // Nim's structure: case discriminator: Type (of values: fields)* (else: fields)?
    object_case: ($) =>
      seq(
        "case",
        field("discriminator", $.symbol),
        ":",
        field("discriminator_type", $.type_expr),
        $._newline,
        repeat($._newline),
        repeat(choice($.object_of_branch, $._newline)),
        optional(seq($.object_else_branch, repeat($._newline))),
      ),

    object_of_branch: ($) =>
      seq(
        "of",
        $.expression_list,
        ":",
        $._newline,
        repeat($._newline),
        $._indent,
        repeat(choice($._object_part, $._newline)),
        $._dedent,
      ),

    object_else_branch: ($) =>
      seq(
        "else",
        ":",
        $._newline,
        repeat($._newline),
        $._indent,
        repeat(choice($._object_part, $._newline)),
        $._dedent,
      ),

    // Concept definition: concept x, y or concept x of SomeType
    // Body contains constraint expressions that must be satisfied
    concept_def: ($) =>
      seq(
        "concept",
        optional(seq(sep1($.symbol, ","), optional(seq("of", $.type_expr)))),
        optional(
          seq(
            $._newline,
            repeat($._newline),
            $._indent,
            repeat(choice($.concept_constraint, $._newline)),
            $._dedent,
          ),
        ),
      ),

    // A concept constraint is an expression that must be valid/true for the concept
    concept_constraint: ($) => seq($.expression, $._newline),

    decl_def: ($) =>
      seq(
        sep1($.exported_symbol, ","),
        optional(seq(":", $.type_expr)),
        optional(seq("=", $.expression)),
      ),

    // -------------------------------
    // Routines
    // -------------------------------
    // Routine definition requires a name (anonymous procs are proc_expr in expressions)
    routine_definition: ($) =>
      seq(
        field("kind", $.routine_kind),
        field("name", $.exported_symbol),
        optional(field("generic_params", $.generic_params)),
        optional(field("params", $.param_list)),
        optional(seq(":", field("return_type", $.type_expr))),
        optional(field("pragmas", $.pragma)),
        // Nim routines only use = for body, not :
        optional(field("body", $._equals_suite)),
      ),

    routine_kind: (_) =>
      prec(
        1,
        choice(
          "proc",
          "func",
          "iterator",
          "method",
          "macro",
          "template",
          "converter",
        ),
      ),

    // Anonymous proc/func/iterator expression (lambda)
    // Can appear in expression contexts: let f = proc(x: int): int = x * 2
    // Body uses = form (with either suite or inline expression)
    // Note: proc_expr requires at least parens or a body to distinguish from proc_type
    proc_expr: ($) =>
      prec.right(
        1,
        seq(
          field("kind", choice("proc", "func", "iterator")),
          optional(field("generic_params", $.generic_params)),
          // Parens are required for proc_expr to distinguish from bare proc type
          field("params", $.param_list),
          optional(seq(":", field("return_type", $.type_expr))),
          optional(field("pragmas", $.pragma)),
          optional(field("body", $._equals_suite)),
        ),
      ),

    generic_params: ($) =>
      seq("[", commaSep($.generic_param), optional(","), "]"),
    generic_param: ($) =>
      seq(
        $.symbol,
        optional(seq(":", $.type_expr)),
        optional(seq("=", $.type_expr)),
      ),

    param_list: ($) => seq("(", commaSep($.param_decl), optional(","), ")"),
    // Parameter declaration with optional modifiers (var, out, sink, lent)
    // Examples: proc f(var x: int), proc g(out y: int), proc h(sink s: string)
    param_decl: ($) =>
      seq(
        optional(field("modifier", $.param_modifier)),
        sep1($.symbol, ","),
        optional(seq(":", $.type_expr)),
        optional(seq("=", $.expression)),
      ),

    // Parameter modifiers that change calling conventions
    param_modifier: (_) => choice("var", "out", "sink", "lent"),

    // -------------------------------
    // Expressions
    // -------------------------------
    // Expression hierarchy follows Nim's precedence from lexer.nim:getPrecedence
    // Arrow operators are the lowest precedence (0), then or/xor (3), and (4), etc.
    expression: ($) => choice($.command_expr, prec(PREC.CALL, $.arrow_expr)),

    // Command call syntax: echo "hello", foo a, b, foo a + b
    // Strong spaces are enforced via token.immediate on suffixes:
    //   foo(x)  -> call with parens (call_suffix uses token.immediate)
    //   foo x   -> command call (no immediate binding, so whitespace separates)
    //   foo[0]  -> indexing (index_suffix uses token.immediate)
    //   foo [0] -> command call with array literal arg
    // The first argument can be a full expression (arrow_expr) to support:
    //   foo a + b  # parses as foo(a + b)
    //   foo not x  # parses as foo(not x)
    // Now supports do_block after command calls: map xs do (x): x + 1
    command_expr: ($) =>
      prec.left(
        PREC.COMMAND,
        seq(
          field("function", $.postfix_expr),
          $.command_first_arg,
          repeat(seq(",", $.command_arg)),
          optional($._block_arg),
          optional($.do_block),
        ),
      ),

    // First command arg - allows full arrow_expr to support expressions like:
    //   foo a + b  (parsed as foo(a + b))
    //   foo not x  (parsed as foo(not x))
    // Named arguments with : or = also supported
    command_first_arg: ($) =>
      choice(
        seq($.symbol, ":", $.arrow_expr), // Named argument (must come first to avoid ambiguity)
        seq($.symbol, "=", $.arrow_expr), // Named argument with =
        $.arrow_expr, // Full expression including a + b, not x, etc.
      ),

    command_arg: ($) =>
      choice(
        seq($.symbol, ":", $.arrow_expr), // Named argument
        seq($.symbol, "=", $.arrow_expr), // Named argument with =
        $.arrow_expr,
      ),

    // Block argument: foo arg: body
    // Note: _colon_suite already includes the ":", so we use it directly
    _block_arg: ($) => field("block", $._colon_suite),

    // Operator expressions based on Nim's precedence model from lexer.nim:getPrecedence
    // Precedence is determined by the first character of the operator token
    // User-defined operators follow the same rules as built-in ones
    //
    // Nim precedence tiers (higher = binds tighter):
    //  10: $ ^        (highest infix - SAME tier, left associative)
    //   9: * / div mod shl shr % \
    //   8: + - | ~    (note: | is add-level, NOT or-level)
    //   7: &
    //   6: ..         (range/dot operators)
    //   5: == != < > <= >= in notin is isnot of as from
    //   4: and
    //   3: or xor
    //   0: -> ~> =>   (arrow operators - lowest)

    // Arrow operators have the LOWEST precedence (0)
    // This means: a -> b or c  parses as  a -> (b or c)
    arrow_expr: ($) =>
      prec.left(
        PREC.ARROW,
        seq(
          $.assign_op_expr,
          repeat(
            seq(choice("->", "~>", "=>", $.arrow_operator), $.assign_op_expr),
          ),
        ),
      ),

    // Assignment-like operators in expression context (precedence 1)
    // These are operators ending in = (but not ==, !=, <=, >=)
    // Right-associative like assignment
    // Examples: +=, -=, *=, &= etc.
    // Note: In Nim, operators ending in = have assignment precedence (1)
    // EXCEPT when they start with ~ or ? (those keep their first-char precedence)
    assign_op_expr: ($) =>
      prec.right(
        PREC.ASSIGN_OP,
        seq($.or_expr, optional(seq($.assignment_operator, $.assign_op_expr))),
      ),

    // or/xor operators (precedence 3)
    // Note: | is NOT here - it's in add_expr (precedence 8)
    or_expr: ($) =>
      prec.left(
        PREC.OR,
        seq($.and_expr, repeat(seq(choice("or", "xor"), $.and_expr))),
      ),

    // and operator (precedence 4)
    and_expr: ($) =>
      prec.left(PREC.AND, seq($.cmp_expr, repeat(seq("and", $.cmp_expr)))),

    // Comparison operators (precedence 5)
    // User-defined operators starting with = < > ! are also comparison operators
    // Note: Arrow operators are NOT here - they have their own lowest tier
    // Note: is/isnot/of/as are handled separately in type_relation_expr because
    // they take a type_expr on the RHS, not a range_expr
    cmp_expr: ($) =>
      prec.left(
        PREC.CMP,
        seq(
          $.type_relation_expr,
          repeat(
            seq(
              choice(
                // Built-in comparison operators
                "==",
                "!=",
                "<=",
                ">=",
                "<",
                ">",
                "in",
                "notin",
                "from",
                // User-defined comparison operators (start with = < > !)
                $.cmp_operator,
              ),
              $.type_relation_expr,
            ),
          ),
        ),
      ),

    // Type relation operators: is, isnot, of, as
    // These take a type_expr on the RHS (e.g., x as ptr int, x of SomeType)
    type_relation_expr: ($) =>
      prec.left(
        PREC.CMP,
        seq(
          $.range_expr,
          optional(seq(choice("is", "isnot", "of", "as"), $.type_expr)),
        ),
      ),

    // Range/dot operators (precedence 6)
    // Note: This is LOWER than & (precedence 7)
    // So: a & b .. c  parses as  (a & b) .. c
    range_expr: ($) =>
      prec.left(
        PREC.RANGE,
        seq(
          $.amp_expr,
          repeat(seq(choice("..", "..<", $.range_operator), $.amp_expr)),
        ),
      ),

    // Ampersand operators (precedence 7)
    // Built-in: & (string concat), user-defined: && and other &-prefixed operators
    // Note: This binds TIGHTER than .. (precedence 6)
    amp_expr: ($) =>
      prec.left(
        PREC.AMP,
        seq($.add_expr, repeat(seq(choice("&", $.amp_operator), $.add_expr))),
      ),

    // Additive operators (precedence 8): + - | ~
    // IMPORTANT: | is here at add-level, NOT at or-level!
    // So: a or b | c  parses as  a or (b | c)
    // Includes user-defined operators starting with these characters
    add_expr: ($) =>
      prec.left(
        PREC.ADD,
        seq(
          $.mul_expr,
          repeat(seq(choice("+", "-", "|", "~", $.add_operator), $.mul_expr)),
        ),
      ),

    // Multiplicative operators (precedence 9): * / % div mod shl shr \
    // Note: shl/shr are ONLY here, not in add tier
    // Includes user-defined operators starting with * / % \
    mul_expr: ($) =>
      prec.left(
        PREC.MUL,
        seq(
          $.pow_expr,
          repeat(
            seq(
              choice(
                "*",
                "/",
                "%",
                "\\",
                "div",
                "mod",
                "shl",
                "shr",
                $.mul_operator,
              ),
              $.pow_expr,
            ),
          ),
        ),
      ),

    // Power/highest infix operators (precedence 10): $ and ^
    // IMPORTANT: $ and ^ share the SAME precedence tier, left associative
    // So: a $ b ^ c  parses as  (a $ b) ^ c
    pow_expr: ($) =>
      prec.left(
        PREC.POW,
        seq(
          $.prefix_expr,
          repeat(
            seq(
              choice("$", "^", $.dollar_operator, $.hat_operator),
              $.prefix_expr,
            ),
          ),
        ),
      ),

    // User-defined operator tokens based on first character
    // These match Nim's lexer.nim:getPrecedence character classes
    //
    // IMPORTANT: Operators ending in = have assignment precedence (1) UNLESS
    // they start with ~ or ? (those keep their first-char precedence).
    // So we exclude =$ endings from tier tokens and route them through assignment_operator.
    //
    // Pattern breakdown:
    // - [=+\-*\/<>@$~&%|!?^.:\\]* matches zero or more operator chars
    // - [+\-*\/<>@$~&%|!?^.:\\] (no =) at the end ensures no = ending
    // - OR match single additional char if not =
    arrow_operator: (_) => token(/->|~>|=>|[\-~=][=+\-*\/<>@$~&%|!?^.:\\]*>/),
    // $ operators: $+ $* etc, but NOT $= (assignment-like) unless starts with ~ or ?
    dollar_operator: (_) =>
      token(
        /\$[=+\-*\/<>@$~&%|!?^.:\\]*[+\-*\/<>@$~&%|!?^.:\\]|\$[~?][=+\-*\/<>@$~&%|!?^.:\\]*/,
      ),
    // ^ operators: ^+ ^* etc, but NOT ^= (assignment-like) unless starts with ~ or ?
    hat_operator: (_) =>
      token(
        /\^[=+\-*\/<>@$~&%|!?^.:\\]*[+\-*\/<>@$~&%|!?^.:\\]|\^[~?][=+\-*\/<>@$~&%|!?^.:\\]*/,
      ),
    // * / % \ operators, but NOT *= /= etc (assignment-like) unless starts with ~ or ?
    mul_operator: (_) =>
      token(
        /[*%\\/][=+\-*\/<>@$~&%|!?^.:\\]*[+\-*\/<>@$~&%|!?^.:\\]|[*%\\/][~?][=+\-*\/<>@$~&%|!?^.:\\]*/,
      ),
    // + - ~ | operators, but NOT += -= etc (assignment-like)
    // Note: ~ and ? starting operators keep their precedence even with = ending
    add_operator: (_) =>
      token(
        /[+\-|][=+\-*\/<>@$~&%|!?^.:\\]*[+\-*\/<>@$~&%|!?^.:\\]|[+\-|][~?][=+\-*\/<>@$~&%|!?^.:\\]*|~[=+\-*\/<>@$~&%|!?^.:\\]+/,
      ),
    // & operators, but NOT &= (assignment-like) unless starts with ~ or ?
    amp_operator: (_) =>
      token(
        /&[=+\-*\/<>@$~&%|!?^.:\\]*[+\-*\/<>@$~&%|!?^.:\\]|&[~?][=+\-*\/<>@$~&%|!?^.:\\]*/,
      ),
    // .. operators, but NOT ..= (assignment-like) unless starts with ~ or ?
    range_operator: (_) =>
      token(
        /\.\.[=+\-*\/<>@$~&%|!?^.:\\]*[+\-*\/<>@$~&%|!?^.:\\]|\.\.[~?][=+\-*\/<>@$~&%|!?^.:\\]*/,
      ),
    // = ! < > operators (comparison tier) - these can end in = (==, !=, <=, >=)
    cmp_operator: (_) => token(/[=!<>][=+\-*\/<>@$~&%|!?^.:\\]+/),

    prefix_expr: ($) =>
      prec.right(
        PREC.PREFIX,
        choice(
          seq(
            choice("+", "-", "not", "~", "@", "$", $.prefix_operator),
            $.prefix_expr,
          ),
          $.postfix_expr,
        ),
      ),

    // User-defined prefix operators (any operator chars)
    prefix_operator: (_) =>
      token(prec(-2, /[=+\-*\/<>@$~&%|!?^.:\\][=+\-*\/<>@$~&%|!?^.:\\]+/)),

    postfix_expr: ($) =>
      prec.left(
        PREC.CALL,
        seq(
          $.primary,
          repeat(
            choice(
              $.call_suffix,
              $.index_suffix,
              $.dot_suffix,
              $.brace_suffix,
              $.pragma_suffix,
              $.do_block,
            ),
          ),
        ),
      ),

    call_suffix: ($) =>
      seq(token.immediate("("), commaSep($.argument), optional(","), ")"),
    argument: ($) =>
      choice(
        $.expression,
        seq($.symbol, ":", $.expression),
        seq($.symbol, "=", $.expression),
      ),

    index_suffix: ($) =>
      seq(token.immediate("["), commaSep($.expression), optional(","), "]"),
    brace_suffix: ($) =>
      seq(token.immediate("{"), commaSep($.expression), optional(","), "}"),
    dot_suffix: ($) => seq(".", $.symbol_or_keyword),
    pragma_suffix: ($) => $.pragma,

    // Do block: xs.map do (x: int) -> int {.gcsafe.}: x * 2
    // Supports optional params, return type, and pragma
    do_block: ($) =>
      seq(
        "do",
        optional(field("params", $.param_list)),
        optional(seq("->", field("return_type", $.type_expr))),
        optional(field("pragmas", $.pragma)),
        $._colon_suite,
      ),

    // Symbol or keyword - allows keywords after dot (e.g., x.type, x.addr)
    // The Nim parser allows symbolOrKeyword in dot suffix contexts
    symbol_or_keyword: ($) =>
      choice(
        $.symbol,
        // Common keywords that can appear after dot
        "type",
        "addr",
        "ptr",
        "ref",
        "nil",
        "true",
        "false",
        "and",
        "or",
        "not",
        "xor",
        "div",
        "mod",
        "shl",
        "shr",
        "in",
        "notin",
        "is",
        "isnot",
        "of",
        "as",
      ),

    primary: ($) =>
      choice(
        $.literal,
        $.qualified_identifier,
        $.paren_expr,
        $.tuple_expr,
        $.array_expr,
        $.curly_expr,
        // Expression forms of statements - can appear as primary expressions
        $.if_expr,
        $.case_expr,
        $.try_expr,
        $.block_expr,
        // Anonymous proc/func/iterator expressions (lambdas)
        $.proc_expr,
      ),

    // Parenthesized expression: (expr) - just grouping, not a tuple
    // Also supports statement-list expressions: (discard 1; 2)
    // Note: () is an empty tuple, handled by tuple_expr
    paren_expr: ($) =>
      prec(
        2,
        choice(
          seq("(", $.expression, ")"),
          // Statement-list expression: (stmt; stmt; expr) or (stmt;)
          $.stmt_list_expr,
        ),
      ),

    // Statement-list expression in parentheses: (discard 1; 2)
    // Requires at least one semicolon to distinguish from plain paren_expr
    // Examples: (discard 1; 2), (let x = 1; x), (discard;)
    stmt_list_expr: ($) =>
      seq(
        "(",
        $.simple_stmt,
        ";",
        choice(
          seq(repeat(seq($.simple_stmt, ";")), optional($.expression)),
          $.expression,
        ),
        ")",
      ),

    // Expression body - can be inline expression or indented suite
    // Used for if_expr, case_expr, try_expr, block_expr branches
    // This allows multi-line expression forms like:
    //   let x = if cond:
    //     echo "hi"
    //     1
    //   else:
    //     2
    _expr_body: ($) =>
      choice(
        $.expression,
        seq(
          $._newline,
          repeat($._newline),
          $._indent,
          repeat($._statement),
          $._dedent,
        ),
      ),

    // Expression form of if - now supports both inline and multi-line bodies
    // Inline: if cond: 1 else: 2
    // Multi-line: if cond:
    //               echo "hi"
    //               1
    //             else:
    //               2
    if_expr: ($) =>
      prec.right(
        seq(
          "if",
          field("condition", $.expression),
          ":",
          field("consequence", $._expr_body),
          repeat(
            seq("elif", field("condition", $.expression), ":", $._expr_body),
          ),
          "else",
          ":",
          field("alternative", $._expr_body),
        ),
      ),

    // Expression form of case - now supports both inline and multi-line bodies
    case_expr: ($) =>
      prec.left(
        seq(
          "case",
          field("expression", $.expression),
          repeat1($.case_expr_branch),
        ),
      ),

    case_expr_branch: ($) =>
      choice(
        seq("of", $.expression_list, ":", $._expr_body),
        seq("else", ":", $._expr_body),
      ),

    // Expression form of try - now supports both inline and multi-line bodies
    try_expr: ($) =>
      prec.right(
        seq(
          "try",
          ":",
          field("body", $._expr_body),
          choice(
            seq(repeat1($.except_expr_branch), optional($.finally_expr_branch)),
            $.finally_expr_branch,
          ),
        ),
      ),

    except_expr_branch: ($) =>
      seq("except", optional($.expression_list), ":", $._expr_body),

    finally_expr_branch: ($) => seq("finally", ":", $._expr_body),

    // Expression form of block - now supports both inline and multi-line bodies
    block_expr: ($) =>
      prec.right(
        10,
        seq(
          "block",
          optional(field("name", $.symbol)),
          ":",
          field("body", $._expr_body),
        ),
      ),

    // Tuple expression: (a, b) or (a,) or () or (x: 1, y: 2)
    // In Nim:
    //   (a, b)  - tuple with 2 elements (NO trailing comma required)
    //   (a,)    - single-element tuple (trailing comma required to distinguish from paren_expr)
    //   ()      - empty tuple
    // Named fields are also supported: (x: 1, y: 2)
    tuple_expr: ($) =>
      choice(
        // Empty tuple: ()
        seq("(", ")"),
        // Single-element tuple (requires trailing comma): (a,)
        seq("(", $.tuple_element, ",", ")"),
        // Multi-element tuple: (a, b) or (a, b,)
        seq(
          "(",
          $.tuple_element,
          ",",
          $.tuple_element,
          repeat(seq(",", $.tuple_element)),
          optional(","),
          ")",
        ),
      ),

    tuple_element: ($) =>
      choice($.expression, seq($.symbol, ":", $.expression)),

    expression_list: ($) => sep1($.expression, ","),

    array_expr: ($) => seq("[", commaSep($.expression), optional(","), "]"),

    // Curly brace expressions support both set-like and table-like constructors:
    //   {1, 2, 3}        # set-like
    //   {"a": 1, "b": 2} # table-like
    //   {:}              # empty table constructor
    //   {}               # empty set/table
    curly_expr: ($) =>
      seq(
        "{",
        choice(
          // Empty table constructor: {:}
          ":",
          // Elements (either set elements or key-value pairs)
          seq(commaSep($.curly_element), optional(",")),
        ),
        "}",
      ),

    // A curly element can be a simple expression (set) or key:value pair (table)
    curly_element: ($) =>
      choice(
        seq(field("key", $.expression), ":", field("value", $.expression)), // Table pair
        $.expression, // Set element
      ),

    // Keep set_expr as alias for compatibility
    set_expr: ($) => $.curly_expr,

    // -------------------------------
    // Types - each type form has its own named node for better AST structure
    // -------------------------------
    type_expr: ($) =>
      choice(
        $.ref_type,
        $.ptr_type,
        $.pointer_type,
        $.var_type,
        $.out_type,
        $.distinct_type,
        $.static_type,
        $.tuple_type,
        $.proc_type,
        $.iterator_type,
        $.object_type,
        $.generic_type,
        $.type_call, // typeof(x), type(x), etc.
        $.qualified_identifier, // Simple type name (must be last to avoid conflicts)
      ),

    // Reference type: ref T
    ref_type: ($) => seq("ref", field("base", $.type_expr)),

    // Pointer type: ptr T
    ptr_type: ($) => seq("ptr", field("base", $.type_expr)),

    // Untyped pointer: pointer (standalone, no type argument)
    // This is different from ptr T which is a typed pointer
    pointer_type: (_) => "pointer",

    // Var type (mutable parameter): var T
    var_type: ($) => seq("var", field("base", $.type_expr)),

    // Out type: out T
    out_type: ($) => seq("out", field("base", $.type_expr)),

    // Distinct type: distinct T
    distinct_type: ($) => seq("distinct", field("base", $.type_expr)),

    // Static type: static T
    static_type: ($) => seq("static", field("base", $.type_expr)),

    // Tuple type: tuple[a: int, b: string] or tuple[int, string]
    tuple_type: ($) =>
      seq(
        "tuple",
        "[",
        choice(
          seq(commaSep($.tuple_field), optional(",")), // Named tuple
          seq(commaSep($.type_expr), optional(",")), // Anonymous tuple
        ),
        "]",
      ),

    // Proc type: proc(x: int): bool {.pragma.}
    proc_type: ($) =>
      seq(
        "proc",
        optional(field("params", $.param_list)),
        optional(seq(":", field("return_type", $.type_expr))),
        optional(field("pragmas", $.pragma)),
      ),

    // Iterator type: iterator(x: int): int {.pragma.}
    iterator_type: ($) =>
      seq(
        "iterator",
        optional(field("params", $.param_list)),
        optional(seq(":", field("return_type", $.type_expr))),
        optional(field("pragmas", $.pragma)),
      ),

    // Object type (inline, without fields): object or object of Parent
    object_type: ($) =>
      seq("object", optional(seq("of", field("parent", $.type_expr)))),

    // Generic type instantiation: Foo[T, U] or array[0..10, int]
    // Type arguments can be types or expressions (e.g., range literals)
    generic_type: ($) =>
      seq(
        field("name", $.qualified_identifier),
        "[",
        commaSep1($.type_arg),
        optional(","),
        "]",
      ),

    // Type call: typeof(x), type(x), typedesc(T), etc.
    // These are type-returning expressions used in type contexts
    type_call: ($) =>
      seq(
        field("name", $.qualified_identifier),
        token.immediate("("),
        commaSep($.expression),
        optional(","),
        ")",
      ),

    tuple_field: ($) => seq($.symbol, ":", $.type_expr),

    // Type arguments can be types or expressions (for array[0..10, int] etc.)
    type_arg: ($) => choice($.type_expr, $.expression),

    // -------------------------------
    // Pragmas
    // -------------------------------
    // Nim's parser accepts both .} and } as pragma closers
    pragma: ($) =>
      seq("{.", commaSep($.pragma_item), optional(","), choice(".}", "}")),
    pragma_item: ($) =>
      seq(
        $.symbol,
        optional(choice(seq(":", $.expression), seq("=", $.expression))),
      ),

    // -------------------------------
    // Identifiers / literals
    // -------------------------------
    identifier: (_) => /[A-Za-z\u0080-\u00FF][A-Za-z0-9\u0080-\u00FF_]*/,
    quoted_identifier: (_) => /`[^`\r\n]+`/,
    symbol: ($) => choice($.identifier, $.quoted_identifier),
    // Exported symbol with visibility marker * (e.g., proc foo*(), type Bar*)
    exported_symbol: ($) => seq($.symbol, optional(field("exported", "*"))),
    qualified_identifier: ($) => seq($.symbol, repeat(seq(".", $.symbol))),

    literal: ($) =>
      choice(
        $.boolean_literal,
        $.integer_literal,
        $.float_literal,
        $.string_literal,
        $.raw_string_literal,
        $.triple_string_literal,
        $.char_literal,
        $.nil_literal,
      ),

    boolean_literal: (_) => choice("true", "false"),
    nil_literal: (_) => "nil",

    integer_literal: (_) =>
      /0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*/,
    float_literal: (_) =>
      /[0-9][0-9_]*\.[0-9_]+([eE][+-]?[0-9_]+)?|[0-9][0-9_]*[eE][+-]?[0-9_]+/,

    // String literal with escape sequences
    // Nim escape sequences: \n \r \t \\ \" \' \a \b \e \f \v \xHH \0..9+
    string_literal: (_) =>
      token(
        seq(
          '"',
          repeat(
            choice(
              /[^"\\\r\n]+/, // Regular characters
              /\\[nrtabefv\\'"]/, // Simple escapes
              /\\x[0-9a-fA-F]{2}/, // Hex escape
              /\\[0-9]+/, // Decimal escape
              /\\/, // Backslash (fallback for unknown escapes)
            ),
          ),
          '"',
        ),
      ),

    // Raw string literal: r"..." or R"..."
    // Double quotes inside are escaped by doubling: r"foo""bar" -> foo"bar
    raw_string_literal: (_) =>
      token(seq(/[rR]/, '"', repeat(choice(/[^"\r\n]+/, '""')), '"')),

    // Triple-quoted string literal (can span multiple lines)
    // Can optionally be raw: r"""..."""
    // Practical approximation; for perfect Nim behavior you'll eventually
    // want a string external scanner too.
    triple_string_literal: (_) =>
      token(
        seq(
          optional(/[rR]/),
          '"""',
          repeat(choice(/[^"]+/, /"[^"]/, /""[^"]/)),
          '"""',
        ),
      ),

    // Character literal: 'x' or '\n' etc.
    // Nim escape sequences: \n \r \t \\ \' \" \a \b \e \f \v \xHH \0..9+
    char_literal: (_) =>
      token(
        seq(
          "'",
          choice(
            /[^'\\\r\n]/, // Single regular character
            /\\[nrtabefv\\'"]/, // Simple escapes
            /\\x[0-9a-fA-F]{2}/, // Hex escape
            /\\[0-9]+/, // Decimal escape
          ),
          "'",
        ),
      ),
  },
});

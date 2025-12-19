const PREC = {
  OR: 1,
  AND: 2,
  CMP: 3,
  RANGE: 4,
  ADD: 5,
  MUL: 6,
  PREFIX: 7,
  CALL: 8,
  COMMAND: 0, // Lower than expression operators
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
    [$.type_expr],
    [$.primary, $.type_expr],
    [$.param_decl],
    [$.enum_field_def],
    [$.enum_def],
    [$.command_arg, $.qualified_identifier],
    [$.command_first_arg, $.qualified_identifier],
    [$.command_first_arg, $.primary],
    [$.import_symbol, $.qualified_identifier],
    [$.object_def],
    [$.object_case],
    [$.object_def, $.type_expr],
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

    assignment_stmt: ($) =>
      prec.right(
        seq(field("left", $.expression), "=", field("right", $.expression)),
      ),

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
        field("variables", sep1($.symbol, ",")),
        "in",
        field("iterable", $.expression),
        field("body", $._colon_suite),
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

    case_stmt: ($) =>
      seq(
        "case",
        field("expression", $.expression),
        optional(":"),
        $._newline,
        repeat($._newline),
        $._indent,
        repeat(choice($.case_branch, $._newline)),
        $._dedent,
      ),

    case_branch: ($) => choice($.of_branch, $.else_branch),
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

    _section_body: ($) =>
      seq(
        $._newline,
        repeat($._newline),
        $._indent,
        repeat(choice($.section_item, $._newline)),
        $._dedent,
      ),

    section_item: ($) => choice($.type_def, $.decl_def),

    type_section: ($) => seq("type", $._section_body),
    const_section: ($) => seq("const", $._section_body),
    let_section: ($) => seq("let", $._section_body),
    var_section: ($) => seq("var", $._section_body),
    using_section: ($) => seq("using", $._section_body),

    type_def: ($) =>
      seq(
        field("name", $.exported_symbol),
        optional($.generic_params),
        optional($.pragma),
        "=",
        field("value", $._type_def_value),
      ),

    _type_def_value: ($) => choice($.type_expr, $.enum_def, $.object_def),

    // Enum definition with optional values
    enum_def: ($) =>
      seq(
        "enum",
        optional($.pragma),
        optional(
          choice(
            // Inline form: enum A, B, C
            seq(commaSep1($.enum_field_def)),
            // Indented form
            seq(
              $._newline,
              repeat($._newline),
              $._indent,
              repeat(choice($.enum_field_def, $._newline)),
              $._dedent,
            ),
          ),
        ),
      ),

    enum_field_def: ($) =>
      seq(
        field("name", $.exported_symbol),
        optional($.pragma),
        optional(seq("=", field("value", $.expression))),
        optional(","),
      ),

    // Object definition with fields
    object_def: ($) =>
      seq(
        choice("object", "ref object", "ptr object"),
        optional(seq("of", field("parent", $.type_expr))),
        optional($.pragma),
        optional(
          seq(
            $._newline,
            repeat($._newline),
            $._indent,
            repeat(choice($.object_field, $.object_case, $._newline)),
            $._dedent,
          ),
        ),
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

    // Variant object (case inside object)
    object_case: ($) =>
      seq(
        "case",
        field("discriminator", $.symbol),
        ":",
        field("discriminator_type", $.type_expr),
        $._newline,
        repeat($._newline),
        repeat(choice($.object_of_branch, $.object_else_branch, $._newline)),
      ),

    object_of_branch: ($) =>
      seq(
        "of",
        $.expression_list,
        ":",
        $._newline,
        repeat($._newline),
        $._indent,
        repeat(choice($.object_field, $._newline)),
        $._dedent,
      ),

    object_else_branch: ($) =>
      seq(
        "else",
        ":",
        $._newline,
        repeat($._newline),
        $._indent,
        repeat(choice($.object_field, $._newline)),
        $._dedent,
      ),

    decl_def: ($) =>
      seq(
        sep1($.exported_symbol, ","),
        optional(seq(":", $.type_expr)),
        optional(seq("=", $.expression)),
      ),

    // -------------------------------
    // Routines
    // -------------------------------
    routine_definition: ($) =>
      seq(
        field(
          "kind",
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
        optional(field("name", $.exported_symbol)),
        optional(field("generic_params", $.generic_params)),
        optional(field("params", $.param_list)),
        optional(seq(":", field("return_type", $.type_expr))),
        optional(field("pragmas", $.pragma)),
        // Nim routines only use = for body, not :
        optional(field("body", $._equals_suite)),
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
    param_decl: ($) =>
      seq(
        sep1($.symbol, ","),
        optional(seq(":", $.type_expr)),
        optional(seq("=", $.expression)),
      ),

    // -------------------------------
    // Expressions
    // -------------------------------
    expression: ($) => choice($.command_expr, prec(PREC.CALL, $.or_expr)),

    // Command call syntax: echo "hello", foo a, b
    // Strong spaces: suffix openers ([, {, () use token.immediate so they bind
    // tightly without preceding whitespace, while command syntax naturally
    // requires whitespace to separate function from arguments
    command_expr: ($) =>
      prec.left(
        PREC.COMMAND,
        seq(
          field("function", $.postfix_expr),
          $.command_first_arg,
          repeat(seq(",", $.command_arg)),
          optional($._block_arg),
        ),
      ),

    // First command arg - with strong spaces (token.immediate on suffixes),
    // we can now allow parenthesized expressions like: echo (1, 2)
    command_first_arg: ($) =>
      choice(
        $.literal, // String, number, etc.
        $.array_expr, // [1, 2, 3]
        $.set_expr, // {1, 2, 3}
        $.paren_expr, // (expr) - now allowed with strong spaces
        $.tuple_expr, // (a, b, c)
        seq("@", $.array_expr), // @[1, 2, 3]
        seq(choice("-", "+", "@", "$", "not"), $.prefix_expr), // Prefix operators
        $.qualified_identifier, // Bare identifier
        seq($.symbol, ":", $.or_expr), // Named argument
        seq($.symbol, "=", $.or_expr), // Named argument with =
      ),

    command_arg: ($) =>
      choice(
        $.or_expr,
        seq($.symbol, ":", $.or_expr),
        seq($.symbol, "=", $.or_expr),
      ),

    // Block argument: foo arg: body
    _block_arg: ($) => seq(":", $._suite),

    or_expr: ($) =>
      prec.left(
        PREC.OR,
        seq($.and_expr, repeat(seq(choice("or", "xor"), $.and_expr))),
      ),

    and_expr: ($) =>
      prec.left(PREC.AND, seq($.cmp_expr, repeat(seq("and", $.cmp_expr)))),

    cmp_expr: ($) =>
      prec.left(
        PREC.CMP,
        seq(
          $.range_expr,
          repeat(
            seq(
              choice(
                "==",
                "!=",
                "<=",
                ">=",
                "<",
                ">",
                "in",
                "notin",
                "is",
                "isnot",
                "of",
                "as",
                "from",
              ),
              $.range_expr,
            ),
          ),
        ),
      ),

    range_expr: ($) =>
      prec.left(
        PREC.RANGE,
        seq($.add_expr, repeat(seq(choice("..", "..<"), $.add_expr))),
      ),

    add_expr: ($) =>
      prec.left(
        PREC.ADD,
        seq(
          $.mul_expr,
          repeat(seq(choice("+", "-", "|", "~", "&"), $.mul_expr)),
        ),
      ),

    mul_expr: ($) =>
      prec.left(
        PREC.MUL,
        seq(
          $.prefix_expr,
          repeat(
            seq(
              choice("*", "/", "%", "div", "mod", "shl", "shr"),
              $.prefix_expr,
            ),
          ),
        ),
      ),

    prefix_expr: ($) =>
      prec.right(
        PREC.PREFIX,
        choice(
          seq(choice("+", "-", "not", "~", "@", "$"), $.prefix_expr),
          $.postfix_expr,
        ),
      ),

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
    dot_suffix: ($) => seq(".", $.symbol),
    pragma_suffix: ($) => $.pragma,

    // Do block: xs.map do (x: int) -> int: x * 2
    do_block: ($) =>
      seq(
        "do",
        optional($.param_list),
        optional(seq("->", $.type_expr)),
        $._colon_suite,
      ),

    primary: ($) =>
      choice(
        $.literal,
        $.qualified_identifier,
        $.paren_expr,
        $.tuple_expr,
        $.array_expr,
        $.set_expr,
      ),

    // Parenthesized expression or tuple with optional named fields
    paren_expr: ($) => seq("(", optional($.expression), ")"),

    // Tuple expression with named fields: (x: 1, y: 2) or (1, 2, 3)
    tuple_expr: ($) =>
      seq(
        "(",
        $.tuple_element,
        ",",
        commaSep($.tuple_element),
        optional(","),
        ")",
      ),

    tuple_element: ($) =>
      choice($.expression, seq($.symbol, ":", $.expression)),

    expression_list: ($) => sep1($.expression, ","),

    array_expr: ($) => seq("[", commaSep($.expression), optional(","), "]"),
    set_expr: ($) => seq("{", commaSep($.expression), optional(","), "}"),

    // -------------------------------
    // Types
    // -------------------------------
    type_expr: ($) =>
      choice(
        $.qualified_identifier,
        seq(
          choice("ref", "ptr", "var", "out", "distinct", "static"),
          $.type_expr,
        ),
        seq("tuple", "[", commaSep($.tuple_field), optional(","), "]"),
        seq("tuple", "[", commaSep($.type_expr), optional(","), "]"),
        seq(
          "proc",
          optional($.param_list),
          optional(seq(":", $.type_expr)),
          optional($.pragma),
        ),
        seq(
          "iterator",
          optional($.param_list),
          optional(seq(":", $.type_expr)),
          optional($.pragma),
        ),
        // Object type (inline, without fields)
        seq("object", optional(seq("of", $.type_expr))),
        // Generic type instantiation: Foo[T, U] or array[0..10, int]
        // Type arguments can be types or expressions (e.g., range literals)
        seq(
          $.qualified_identifier,
          "[",
          commaSep1($.type_arg),
          optional(","),
          "]",
        ),
      ),

    tuple_field: ($) => seq($.symbol, ":", $.type_expr),

    // Type arguments can be types or expressions (for array[0..10, int] etc.)
    type_arg: ($) => choice($.type_expr, $.expression),

    // -------------------------------
    // Pragmas
    // -------------------------------
    pragma: ($) => seq("{.", commaSep($.pragma_item), optional(","), ".}"),
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

    string_literal: (_) =>
      token(seq('"', repeat(choice(/[^"\\\r\n]+/, /\\./)), '"')),
    raw_string_literal: (_) =>
      token(seq(/[rR]/, '"', repeat(choice(/[^"\r\n]+/, '""')), '"')),

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

    char_literal: (_) => token(seq("'", choice(/[^'\\\r\n]/, /\\./), "'")),
  },
});

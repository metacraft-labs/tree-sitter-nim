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
  // Operator precedence tiers based on Nim's lexer.nim:getPrecedence
  // These are used for user-defined operators based on first character
  OP_DOLLAR: 10, // $ operators (highest)
  OP_HAT: 9, // ^ operators
  OP_MUL: 8, // * / div mod shl shr % and .* operators
  OP_ADD: 7, // + - | ~ or xor .+ operators
  OP_AMP: 6, // & operators
  OP_RANGE: 5, // .. operators
  OP_CMP: 4, // == != < > <= >= in notin is isnot of as from .= .< operators
  OP_ARROW: 3, // -> ~> => operators
  OP_ASSIGN: 2, // = operators (assignment-like, but not bare =)
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
    [$.primary, $.type_expr],
    [$.primary, $.generic_type],
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

    _type_def_value: ($) => choice($.type_expr, $.enum_def, $.object_def),

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
    // In Nim, the of/else branches are at the same indentation level as the case,
    // not indented further. The fields inside of/else branches ARE indented.
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
    expression: ($) => choice($.command_expr, prec(PREC.CALL, $.or_expr)),

    // Command call syntax: echo "hello", foo a, b, foo a + b
    // Strong spaces are enforced via token.immediate on suffixes:
    //   foo(x)  -> call with parens (call_suffix uses token.immediate)
    //   foo x   -> command call (no immediate binding, so whitespace separates)
    //   foo[0]  -> indexing (index_suffix uses token.immediate)
    //   foo [0] -> command call with array literal arg
    // The first argument can be a full expression (or_expr) to support:
    //   foo a + b  # parses as foo(a + b)
    //   foo not x  # parses as foo(not x)
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

    // First command arg - allows full or_expr to support expressions like:
    //   foo a + b  (parsed as foo(a + b))
    //   foo not x  (parsed as foo(not x))
    // Named arguments with : or = also supported
    command_first_arg: ($) =>
      choice(
        seq($.symbol, ":", $.or_expr), // Named argument (must come first to avoid ambiguity)
        seq($.symbol, "=", $.or_expr), // Named argument with =
        $.or_expr, // Full expression including a + b, not x, etc.
      ),

    command_arg: ($) =>
      choice(
        seq($.symbol, ":", $.or_expr), // Named argument
        seq($.symbol, "=", $.or_expr), // Named argument with =
        $.or_expr,
      ),

    // Block argument: foo arg: body
    _block_arg: ($) => seq(":", $._suite),

    // Operator expressions based on Nim's precedence model from lexer.nim:getPrecedence
    // Precedence is determined by the first character of the operator token
    // User-defined operators follow the same rules as built-in ones

    or_expr: ($) =>
      prec.left(
        PREC.OR,
        seq($.and_expr, repeat(seq(choice("or", "xor"), $.and_expr))),
      ),

    and_expr: ($) =>
      prec.left(PREC.AND, seq($.cmp_expr, repeat(seq("and", $.cmp_expr)))),

    // Comparison operators and arrow operators
    // Includes user-defined operators starting with = < > !
    cmp_expr: ($) =>
      prec.left(
        PREC.CMP,
        seq(
          $.amp_expr,
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
                "is",
                "isnot",
                "of",
                "as",
                "from",
                // Arrow operators (precedence 3, but grouped with cmp for simplicity)
                "->",
                "~>",
                "=>",
                // User-defined comparison operators (start with = < > !)
                $.cmp_operator,
              ),
              $.amp_expr,
            ),
          ),
        ),
      ),

    // Ampersand operators (precedence 6)
    // Built-in: & (bitwise and), user-defined: && and other &-prefixed operators
    amp_expr: ($) =>
      prec.left(
        PREC.ADD - 1,
        seq(
          $.range_expr,
          repeat(seq(choice("&", $.amp_operator), $.range_expr)),
        ),
      ),

    // Range operators
    range_expr: ($) =>
      prec.left(
        PREC.RANGE,
        seq(
          $.add_expr,
          repeat(seq(choice("..", "..<", $.range_operator), $.add_expr)),
        ),
      ),

    // Additive operators: + - | ~
    // Includes user-defined operators starting with these characters
    add_expr: ($) =>
      prec.left(
        PREC.ADD,
        seq(
          $.mul_expr,
          repeat(seq(choice("+", "-", "|", "~", $.add_operator), $.mul_expr)),
        ),
      ),

    // Multiplicative operators: * / % div mod shl shr
    // Includes user-defined operators starting with * / % \ .
    mul_expr: ($) =>
      prec.left(
        PREC.MUL,
        seq(
          $.dollar_expr,
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
              $.dollar_expr,
            ),
          ),
        ),
      ),

    // Dollar operators have highest precedence (precedence 10)
    dollar_expr: ($) =>
      prec.left(
        PREC.MUL + 2,
        seq($.hat_expr, repeat(seq($.dollar_operator, $.hat_expr))),
      ),

    // Hat/caret operators (precedence 9)
    hat_expr: ($) =>
      prec.left(
        PREC.MUL + 1,
        seq($.prefix_expr, repeat(seq($.hat_operator, $.prefix_expr))),
      ),

    // User-defined operator tokens based on first character
    // These match Nim's lexer.nim:getPrecedence character classes
    // Note: Operators that overlap with built-ins (like ++) require careful precedence
    // The regex requires at least one additional operator char after the first to avoid
    // conflicts with single-char built-in operators
    dollar_operator: (_) => token(/\$[=+\-*\/<>@$~&%|!?^.:\\]+/),
    hat_operator: (_) => token(/\^[=+\-*\/<>@$~&%|!?^.:\\]+/),
    mul_operator: (_) =>
      token(/[*%\\][=+\-*\/<>@$~&%|!?^.:\\]+|\/[=+\-*\/<>@$~&%|!?^.:\\]+/),
    add_operator: (_) => token(/[+\-~|][=+\-*\/<>@$~&%|!?^.:\\]+/),
    amp_operator: (_) => token(/&[=+\-*\/<>@$~&%|!?^.:\\]+/),
    range_operator: (_) => token(/\.\.[=+\-*\/<>@$~&%|!?^.:\\]+/),
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
        $.curly_expr,
      ),

    // Parenthesized expression or tuple with optional named fields
    // Note: Expression forms of statements (if_expr, case_expr, try_expr, block_expr)
    // are handled through the parenthesized form: (if cond: 1 else: 2)
    // or through Nim's statement-as-expression in appropriate contexts.
    // The compound_stmt forms handle these when used as statements.
    paren_expr: ($) => seq("(", optional($._paren_content), ")"),

    // Inside parens we can have regular expressions or expression forms of statements
    _paren_content: ($) =>
      choice($.if_expr, $.case_expr, $.try_expr, $.block_expr, $.expression),

    // Expression form of if: (if cond: 1 else: 2)
    if_expr: ($) =>
      prec.right(
        seq(
          "if",
          field("condition", $.expression),
          ":",
          field("consequence", $.expression),
          repeat(
            seq("elif", field("condition", $.expression), ":", $.expression),
          ),
          "else",
          ":",
          field("alternative", $.expression),
        ),
      ),

    // Expression form of case: (case k of 1: "a" else: "b")
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
        seq("of", $.expression_list, ":", $.expression),
        seq("else", ":", $.expression),
      ),

    // Expression form of try: (try: f() except: g())
    try_expr: ($) =>
      prec.right(
        seq(
          "try",
          ":",
          field("body", $.expression),
          choice(
            seq(repeat1($.except_expr_branch), optional($.finally_expr_branch)),
            $.finally_expr_branch,
          ),
        ),
      ),

    except_expr_branch: ($) =>
      seq("except", optional($.expression_list), ":", $.expression),

    finally_expr_branch: ($) => seq("finally", ":", $.expression),

    // Expression form of block: (block: computeValue())
    block_expr: ($) =>
      prec.right(
        seq(
          "block",
          optional(field("name", $.symbol)),
          ":",
          field("body", $.expression),
        ),
      ),

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
        $.var_type,
        $.out_type,
        $.distinct_type,
        $.static_type,
        $.tuple_type,
        $.proc_type,
        $.iterator_type,
        $.object_type,
        $.generic_type,
        $.qualified_identifier, // Simple type name (must be last to avoid conflicts)
      ),

    // Reference type: ref T
    ref_type: ($) => seq("ref", field("base", $.type_expr)),

    // Pointer type: ptr T
    ptr_type: ($) => seq("ptr", field("base", $.type_expr)),

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

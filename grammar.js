const PREC = {
  OR: 1,
  AND: 2,
  CMP: 3,
  RANGE: 4,
  ADD: 5,
  MUL: 6,
  PREFIX: 7,
  CALL: 8,
};

function sep1(rule, sep) { return seq(rule, repeat(seq(sep, rule))); }
function commaSep(rule) { return optional(sep1(rule, ',')); }

module.exports = grammar({
  name: 'nim',

  externals: $ => [
    $._indent,
    $._dedent,
    $._newline,
    $._soft_newline,
    $.comment,
  ],

  extras: $ => [
    /[ \t\f\r]+/,
    $._soft_newline,
    $.comment,
  ],

  conflicts: $ => [
    [$.routine_definition],
    [$.qualified_identifier],
    [$.type_expr],
    [$.primary, $.type_expr],
    [$.param_decl],
    [$.from_import_stmt, $.qualified_identifier],
  ],

  word: $ => $.identifier,

  rules: {
    source_file: $ => repeat($._statement),

    _statement: $ => choice(
      $.simple_stmt_line,
      $.compound_stmt,
      $.section_stmt,
      $._newline
    ),

    // -------------------------------
    // Simple statements (line-terminated)
    // -------------------------------
    simple_stmt_line: $ => seq(
      sep1($.simple_stmt, ';'),
      $._newline
    ),

    simple_stmt: $ => choice(
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
      $.expr_stmt
    ),

    return_stmt: $ => seq('return', optional($.expression)),
    raise_stmt: $ => seq('raise', optional($.expression)),
    yield_stmt: $ => seq('yield', optional($.expression)),
    discard_stmt: $ => seq('discard', optional($.expression)),
    break_stmt: $ => seq('break', optional($.expression)),
    continue_stmt: $ => seq('continue', optional($.expression)),

    import_stmt: $ => seq('import', sep1($.import_path, ',')),
    export_stmt: $ => seq('export', sep1($.import_path, ',')),
    include_stmt: $ => seq('include', sep1($.import_path, ',')),

    from_import_stmt: $ => seq(
      'from',
      $.import_path,
      'import',
      choice(
        seq('except', sep1($.symbol, ',')),
        sep1(choice($.symbol, $.qualified_identifier), ',')
      )
    ),

    import_path: $ => choice($.qualified_identifier, $.string_literal),

    bind_stmt: $ => seq('bind', sep1($.symbol, ',')),
    mixin_stmt: $ => seq('mixin', sep1($.symbol, ',')),

    expr_stmt: $ => choice(
      $.assignment_stmt,
      $.expression
    ),

    assignment_stmt: $ => prec.right(seq(
      field('left', $.expression),
      '=',
      field('right', $.expression)
    )),

    // -------------------------------
    // Compound statements (suite-based)
    // -------------------------------
    compound_stmt: $ => choice(
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
      $.routine_definition
    ),

    _colon_suite: $ => choice(
      seq(':', $.inline_stmt_list, $._newline),
      seq(':', $._newline, repeat($._newline), $._indent, repeat($._statement), $._dedent)
    ),

    inline_stmt_list: $ => sep1($.simple_stmt, ';'),

    if_stmt: $ => seq(
      'if', $.expression,
      $._colon_suite,
      repeat(seq('elif', $.expression, $._colon_suite)),
      optional(seq('else', $._colon_suite))
    ),

    when_stmt: $ => seq(
      'when', $.expression,
      $._colon_suite,
      repeat(seq('elif', $.expression, $._colon_suite)),
      optional(seq('else', $._colon_suite))
    ),

    while_stmt: $ => seq('while', $.expression, $._colon_suite),

    for_stmt: $ => seq(
      'for',
      sep1($.symbol, ','),
      'in',
      $.expression,
      $._colon_suite
    ),

    try_stmt: $ => seq(
      'try',
      $._colon_suite,
      repeat1($.except_branch),
      optional($.finally_branch)
    ),

    except_branch: $ => seq(
      'except',
      optional($.expression_list),
      $._colon_suite
    ),

    finally_branch: $ => seq('finally', $._colon_suite),

    case_stmt: $ => seq(
      'case',
      $.expression,
      optional(':'),
      $._newline,
      repeat($._newline),
      $._indent,
      repeat(choice($.case_branch, $._newline)),
      $._dedent
    ),

    case_branch: $ => choice($.of_branch, $.else_branch),
    of_branch: $ => seq('of', $.expression_list, $._colon_suite),
    else_branch: $ => seq('else', $._colon_suite),

    block_stmt: $ => seq('block', optional($.symbol), $._colon_suite),
    static_stmt: $ => seq('static', $._colon_suite),
    defer_stmt: $ => seq('defer', $._colon_suite),

    asm_stmt: $ => seq(
      'asm',
      optional($.pragma),
      choice($.string_literal, $.triple_string_literal, $._colon_suite)
    ),

    // -------------------------------
    // Sections
    // -------------------------------
    section_stmt: $ => choice(
      $.type_section,
      $.const_section,
      $.let_section,
      $.var_section,
      $.using_section
    ),

    _section_body: $ => seq(
      $._newline,
      repeat($._newline),
      $._indent,
      repeat(choice($.section_item, $._newline)),
      $._dedent
    ),

    section_item: $ => choice($.type_def, $.decl_def),

    type_section: $ => seq('type', $._section_body),
    const_section: $ => seq('const', $._section_body),
    let_section: $ => seq('let', $._section_body),
    var_section: $ => seq('var', $._section_body),
    using_section: $ => seq('using', $._section_body),

    type_def: $ => seq(
      field('name', $.symbol),
      optional($.generic_params),
      '=',
      field('value', $.type_expr)
    ),

    decl_def: $ => seq(
      sep1($.symbol, ','),
      optional(seq(':', $.type_expr)),
      optional(seq('=', $.expression))
    ),

    // -------------------------------
    // Routines
    // -------------------------------
    routine_definition: $ => seq(
      field('kind', choice('proc','func','iterator','method','macro','template','converter')),
      optional(field('name', $.symbol)),
      optional($.generic_params),
      optional($.param_list),
      optional(seq(':', $.type_expr)),
      optional($.pragma),
      optional(choice(
        seq('=', $.expression),
        $._colon_suite
      ))
    ),

    generic_params: $ => seq('[', commaSep($.generic_param), optional(','), ']'),
    generic_param: $ => seq($.symbol, optional(seq(':', $.type_expr)), optional(seq('=', $.type_expr))),

    param_list: $ => seq('(', commaSep($.param_decl), optional(','), ')'),
    param_decl: $ => seq(
      sep1($.symbol, ','),
      optional(seq(':', $.type_expr)),
      optional(seq('=', $.expression))
    ),

    // -------------------------------
    // Expressions
    // -------------------------------
    expression: $ => $.or_expr,

    or_expr: $ => prec.left(PREC.OR,
      seq($.and_expr, repeat(seq(choice('or','xor'), $.and_expr)))
    ),

    and_expr: $ => prec.left(PREC.AND,
      seq($.cmp_expr, repeat(seq('and', $.cmp_expr)))
    ),

    cmp_expr: $ => prec.left(PREC.CMP, seq(
      $.range_expr,
      repeat(seq(choice(
        '==','!=','<=','>=','<','>',
        'in','notin','is','isnot','of','as','from'
      ), $.range_expr))
    )),

    range_expr: $ => prec.left(PREC.RANGE, seq(
      $.add_expr,
      repeat(seq(choice('..','..<'), $.add_expr))
    )),

    add_expr: $ => prec.left(PREC.ADD, seq(
      $.mul_expr,
      repeat(seq(choice('+','-','|','~','&'), $.mul_expr))
    )),

    mul_expr: $ => prec.left(PREC.MUL, seq(
      $.prefix_expr,
      repeat(seq(choice('*','/','%','div','mod','shl','shr'), $.prefix_expr))
    )),

    prefix_expr: $ => prec.right(PREC.PREFIX, choice(
      seq(choice('+','-','not','~'), $.prefix_expr),
      $.postfix_expr
    )),

    postfix_expr: $ => prec.left(PREC.CALL, seq(
      $.primary,
      repeat(choice($.call_suffix, $.index_suffix, $.dot_suffix, $.brace_suffix))
    )),

    call_suffix: $ => seq('(', commaSep($.argument), optional(','), ')'),
    argument: $ => choice(
      $.expression,
      seq($.symbol, ':', $.expression),
      seq($.symbol, '=', $.expression)
    ),

    index_suffix: $ => seq('[', commaSep($.expression), optional(','), ']'),
    brace_suffix: $ => seq('{', commaSep($.expression), optional(','), '}'),
    dot_suffix: $ => seq('.', $.symbol),

    primary: $ => choice(
      $.literal,
      $.qualified_identifier,
      $.paren_expr,
      $.array_expr,
      $.set_expr
    ),

    paren_expr: $ => seq('(', optional($.expression_list), ')'),
    expression_list: $ => sep1($.expression, ','),

    array_expr: $ => seq('[', commaSep($.expression), optional(','), ']'),
    set_expr: $ => seq('{', commaSep($.expression), optional(','), '}'),

    // -------------------------------
    // Types (starter)
    // -------------------------------
    type_expr: $ => choice(
      $.qualified_identifier,
      seq(choice('ref','ptr','var','out','distinct'), $.type_expr),
      seq('tuple', '[', commaSep($.tuple_field), optional(','), ']'),
      seq('proc', optional($.param_list), optional(seq(':', $.type_expr))),
      seq('object', optional(seq('of', $.type_expr)))
    ),

    tuple_field: $ => seq($.symbol, ':', $.type_expr),

    // -------------------------------
    // Pragmas
    // -------------------------------
    pragma: $ => seq('{.', commaSep($.pragma_item), optional(','), '.}'),
    pragma_item: $ => seq($.symbol, optional(seq(':', $.expression))),

    // -------------------------------
    // Identifiers / literals
    // -------------------------------
    identifier: _ => /[A-Za-z\u0080-\u00FF][A-Za-z0-9\u0080-\u00FF_]*/,
    quoted_identifier: _ => /`[^`\r\n]+`/,
    symbol: $ => choice($.identifier, $.quoted_identifier),
    qualified_identifier: $ => seq($.symbol, repeat(seq('.', $.symbol))),

    literal: $ => choice(
      $.integer_literal,
      $.float_literal,
      $.string_literal,
      $.raw_string_literal,
      $.triple_string_literal,
      $.char_literal,
      'nil'
    ),

    integer_literal: _ => /0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*/,
    float_literal: _ => /[0-9][0-9_]*\.[0-9_]+([eE][+-]?[0-9_]+)?|[0-9][0-9_]*[eE][+-]?[0-9_]+/,

    string_literal: _ => token(seq('"', repeat(choice(/[^"\\\r\n]+/, /\\./)), '"')),
    raw_string_literal: _ => token(seq(/[rR]/, '"', repeat(choice(/[^"\r\n]+/, '""')), '"')),

    // Practical approximation; for perfect Nim behavior you'll eventually
    // want a string external scanner too.
    triple_string_literal: _ => token(seq(
      optional(/[rR]/),
      '"""',
      repeat(choice(/[^"]+/, /"[^"]/ , /""[^"]/)),
      '"""'
    )),

    char_literal: _ => token(seq("'", choice(/[^'\\\r\n]/, /\\./), "'")),
  }
});

; Keywords (as literal tokens in grammar)
[
  "if" "elif" "else" "when" "while" "for" "in"
  "try" "except" "finally" "case" "of"
  "block" "static" "defer" "asm"
  "return" "raise" "yield" "discard" "break" "continue"
  "import" "export" "include" "from" "bind" "mixin"
  "type" "const" "let" "var" "using"
  "proc" "func" "iterator" "method" "macro" "template" "converter"
  "ref" "ptr" "distinct" "tuple" "object" "nil"
] @keyword

(comment) @comment

(string_literal) @string
(raw_string_literal) @string
(triple_string_literal) @string
(char_literal) @string.special

(integer_literal) @number
(float_literal) @number

(symbol) @variable
(quoted_identifier) @variable
(qualified_identifier) @variable

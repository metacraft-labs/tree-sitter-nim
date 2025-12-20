#include <tree_sitter/parser.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum TokenType {
  INDENT,
  DEDENT,
  NEWLINE,
  SOFT_NEWLINE,
  COMMENT,
  // Operator tokens classified by precedence (from Nim's lexer.nim getPrecedence)
  OP0_ARROW,       // -> ~> => and operators ending in [-~=]>
  OP1_ASSIGNMENT,  // operators ending in = (except == != <= >= and ~= ?=)
  OP2_MISC,        // @ : ? operators (default precedence tier)
  OP3_OR,          // or xor (keywords, not scanned here)
  OP4_AND,         // and (keyword, not scanned here)
  OP5_CMP,         // = < > ! operators (comparison tier)
  OP6_RANGE,       // .. operators
  OP7_AMP,         // & operators
  OP8_ADD,         // + - ~ | operators
  OP9_MUL,         // * / % \ operators
  OP10_POW,        // $ ^ operators
};

typedef struct {
  uint16_t indents[256];
  uint16_t indent_len;
  uint16_t pending_dedents;
  bool pending_indent;
  bool eof_newline_emitted;
} Scanner;

// Check if character is a valid operator character
static bool is_operator_char(int32_t c) {
  switch (c) {
    case '=': case '+': case '-': case '*': case '/':
    case '<': case '>': case '@': case '$': case '~':
    case '&': case '%': case '|': case '!': case '?':
    case '^': case '.': case ':': case '\\':
      return true;
    default:
      return false;
  }
}

static void advance(TSLexer *lexer, bool skip) { lexer->advance(lexer, skip); }
static bool is_newline(int32_t c) { return c == '\n' || c == '\r'; }

static void consume_newline(TSLexer *lexer) {
  if (lexer->lookahead == '\r') {
    advance(lexer, true);
    if (lexer->lookahead == '\n') advance(lexer, true);
  } else {
    advance(lexer, true);
  }
}

static uint32_t consume_indent(TSLexer *lexer) {
  uint32_t indent = 0;
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t') {
    if (lexer->lookahead == '\t') indent += 8;
    else indent += 1;
    advance(lexer, true);
  }
  return indent;
}

static bool scan_line_comment(TSLexer *lexer) {
  while (lexer->lookahead && !is_newline(lexer->lookahead)) {
    advance(lexer, false);
  }
  lexer->mark_end(lexer);
  return true;
}

static bool scan_block_comment(TSLexer *lexer, bool doc) {
  int nesting = 1;

  while (lexer->lookahead) {
    if (lexer->lookahead == '#') {
      advance(lexer, false);
      if (!doc && lexer->lookahead == '[') {
        advance(lexer, false);
        nesting++;
        continue;
      }
      if (doc && lexer->lookahead == '#') {
        advance(lexer, false);
        if (lexer->lookahead == '[') {
          advance(lexer, false);
          nesting++;
          continue;
        }
      }
      continue;
    }
    if (lexer->lookahead == ']') {
      advance(lexer, false);
      if (lexer->lookahead == '#') {
        advance(lexer, false);
        if (doc) {
          if (lexer->lookahead == '#') {
            advance(lexer, false);
          } else {
            continue;
          }
        }
        nesting--;
        if (nesting == 0) {
          lexer->mark_end(lexer);
          return true;
        }
        continue;
      }
      continue;
    }
    advance(lexer, false);
  }

  lexer->mark_end(lexer);
  return true;
}

static bool scan_comment(TSLexer *lexer) {
  advance(lexer, false);
  if (lexer->lookahead == '#') {
    advance(lexer, false);
    if (lexer->lookahead == '[') {
      advance(lexer, false);
      return scan_block_comment(lexer, true);
    }
    return scan_line_comment(lexer);
  }
  if (lexer->lookahead == '[') {
    advance(lexer, false);
    return scan_block_comment(lexer, false);
  }
  return scan_line_comment(lexer);
}

// Get precedence based on Nim's lexer.nim getPrecedence function
// Returns the token type for the operator
static int get_operator_precedence(const char *op, int len) {
  if (len == 0) return -1;

  char first = op[0];
  char last = op[len - 1];
  char penultimate = len >= 2 ? op[len - 2] : '\0';

  // Arrow operators: last char is '>' and penultimate is one of '-' '~' '='
  // e.g., ->, ~>, =>, <->, ***=>
  if (last == '>' && (penultimate == '-' || penultimate == '~' || penultimate == '=')) {
    return OP0_ARROW;
  }

  // Assignment operators: end in '=' but not == != <= >=
  // EXCEPT: operators starting with ~ or ? keep their first-char precedence
  if (last == '=' && len >= 2 && first != '~' && first != '?') {
    // Check it's not a comparison operator
    if (len == 2 && (first == '=' || first == '!' || first == '<' || first == '>')) {
      // These are comparison operators, not assignment
    } else {
      return OP1_ASSIGNMENT;
    }
  }

  // Classify by first character (Nim's primary rule)
  switch (first) {
    case '$': case '^':
      return OP10_POW;

    case '*': case '%': case '/': case '\\':
      return OP9_MUL;

    case '+': case '-': case '~': case '|':
      return OP8_ADD;

    case '&':
      return OP7_AMP;

    case '.':
      // Check for .. operators
      if (len >= 2 && op[1] == '.') {
        return OP6_RANGE;
      }
      return OP5_CMP;  // Single dot operators are comparison-like

    case '=': case '<': case '>': case '!':
      return OP5_CMP;

    case '@': case ':': case '?':
      return OP2_MISC;

    default:
      return OP2_MISC;  // Default precedence
  }
}

// Scan an operator and classify it
static bool scan_operator(TSLexer *lexer, const bool *valid) {
  if (!is_operator_char(lexer->lookahead)) {
    return false;
  }

  // Don't scan operators that would conflict with other grammar rules
  // These are handled directly in grammar.js:
  // - '=' alone (assignment)
  // - '.' alone (dot access)
  // - ':' alone (type annotation, etc.)
  // - '..' and '..<' (range operators - too common to scan here)

  char op[64];
  int len = 0;
  int32_t first = lexer->lookahead;

  // Collect operator characters
  while (is_operator_char(lexer->lookahead) && len < 63) {
    op[len++] = (char)lexer->lookahead;
    advance(lexer, false);
  }
  op[len] = '\0';

  // Skip single-character operators that are handled in grammar.js
  if (len == 1) {
    switch (first) {
      case '=': case '.': case ':': case '+': case '-':
      case '*': case '/': case '<': case '>': case '&':
      case '@': case '$': case '~': case '^': case '|':
      case '%': case '!': case '?': case '\\':
        return false;
    }
  }

  // Skip '..' and '..<' - these are fundamental and handled in grammar.js
  if (len == 2 && op[0] == '.' && op[1] == '.') {
    return false;
  }
  if (len == 3 && op[0] == '.' && op[1] == '.' && op[2] == '<') {
    return false;
  }

  int prec = get_operator_precedence(op, len);
  if (prec < 0) return false;

  // Check if this token type is valid in current parse context
  if (valid[prec]) {
    lexer->result_symbol = prec;
    lexer->mark_end(lexer);
    return true;
  }

  return false;
}

void *tree_sitter_nim_external_scanner_create(void) {
  Scanner *s = (Scanner *)calloc(1, sizeof(Scanner));
  s->indents[0] = 0;
  s->indent_len = 1;
  return s;
}

void tree_sitter_nim_external_scanner_destroy(void *payload) {
  free(payload);
}

unsigned tree_sitter_nim_external_scanner_serialize(void *payload, char *buffer) {
  Scanner *s = (Scanner *)payload;
  unsigned i = 0;
  buffer[i++] = (char)s->indent_len;
  buffer[i++] = (char)s->pending_dedents;
  buffer[i++] = (char)(s->pending_indent ? 1 : 0);
  buffer[i++] = (char)(s->eof_newline_emitted ? 1 : 0);

  for (unsigned j = 0; j < s->indent_len; j++) {
    buffer[i++] = (char)(s->indents[j] & 0xFF);
    buffer[i++] = (char)(s->indents[j] >> 8);
  }
  return i;
}

void tree_sitter_nim_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  Scanner *s = (Scanner *)payload;
  if (length < 4) return;

  unsigned i = 0;
  s->indent_len = (uint8_t)buffer[i++];
  s->pending_dedents = (uint8_t)buffer[i++];
  s->pending_indent = buffer[i++] != 0;
  s->eof_newline_emitted = buffer[i++] != 0;

  if (s->indent_len == 0) s->indent_len = 1;

  for (unsigned j = 0; j < s->indent_len && i + 1 < length; j++) {
    uint16_t lo = (uint8_t)buffer[i++];
    uint16_t hi = (uint8_t)buffer[i++];
    s->indents[j] = lo | (hi << 8);
  }
}

bool tree_sitter_nim_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid) {
  Scanner *s = (Scanner *)payload;

  // Emit queued INDENT/DEDENT tokens first
  if (s->pending_indent && valid[INDENT]) {
    s->pending_indent = false;
    lexer->result_symbol = INDENT;
    return true;
  }
  if (s->pending_dedents > 0 && valid[DEDENT]) {
    s->pending_dedents--;
    lexer->result_symbol = DEDENT;
    return true;
  }

  // Comments
  if (valid[COMMENT] && lexer->lookahead == '#') {
    lexer->result_symbol = COMMENT;
    return scan_comment(lexer);
  }

  // EOF handling
  if (lexer->lookahead == 0) {
    if (valid[NEWLINE] && !s->eof_newline_emitted) {
      s->eof_newline_emitted = true;
      while (s->indent_len > 1) {
        s->indent_len--;
        s->pending_dedents++;
      }
      lexer->result_symbol = NEWLINE;
      return true;
    }
    if (valid[DEDENT] && s->pending_dedents > 0) {
      s->pending_dedents--;
      lexer->result_symbol = DEDENT;
      return true;
    }
    if (valid[DEDENT] && s->indent_len > 1) {
      s->indent_len--;
      lexer->result_symbol = DEDENT;
      return true;
    }
    return false;
  }

  // Newline handling
  if (is_newline(lexer->lookahead)) {
    consume_newline(lexer);
    lexer->mark_end(lexer);

    uint32_t indent = consume_indent(lexer);
    int32_t next = lexer->lookahead;
    bool hard_newline = valid[NEWLINE];

    if (hard_newline) {
      bool blank = is_newline(next) || next == 0;
      bool comment_only = (next == '#');
      uint32_t current = s->indents[s->indent_len - 1];

      if (!blank && !comment_only) {
        if (indent > current) {
          if (s->indent_len < 256) {
            s->indents[s->indent_len++] = (uint16_t)indent;
            s->pending_indent = true;
          }
        } else if (indent < current) {
          while (s->indent_len > 1 && indent < s->indents[s->indent_len - 1]) {
            s->indent_len--;
            s->pending_dedents++;
          }
        }
      }
    }

    lexer->result_symbol = hard_newline ? NEWLINE : SOFT_NEWLINE;
    return true;
  }

  // Try to scan operators
  // Check if any operator token types are valid
  bool any_op_valid = valid[OP0_ARROW] || valid[OP1_ASSIGNMENT] ||
                      valid[OP2_MISC] || valid[OP5_CMP] ||
                      valid[OP6_RANGE] || valid[OP7_AMP] ||
                      valid[OP8_ADD] || valid[OP9_MUL] || valid[OP10_POW];

  if (any_op_valid && is_operator_char(lexer->lookahead)) {
    return scan_operator(lexer, valid);
  }

  return false;
}

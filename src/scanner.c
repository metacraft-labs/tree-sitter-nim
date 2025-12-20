#include <tree_sitter/parser.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

enum TokenType {
  INDENT,
  DEDENT,
  NEWLINE,
  SOFT_NEWLINE,
  COMMENT,
};

typedef struct {
  uint16_t indents[256];
  uint16_t indent_len;
  uint16_t pending_dedents;
  bool pending_indent;
  bool eof_newline_emitted;  // Track if we've emitted synthetic newline at EOF
} Scanner;

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
    if (lexer->lookahead == '\t') indent += 8; // Nim forbids tabs; tolerate for robustness
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
  // Opening already consumed: "#[" or "##["
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
  // At '#'
  advance(lexer, false);

  if (lexer->lookahead == '#') {
    advance(lexer, false);
    if (lexer->lookahead == '[') {
      advance(lexer, false);
      return scan_block_comment(lexer, true); // doc block: ##[ ]##
    }
    return scan_line_comment(lexer); // doc line: ##
  }

  if (lexer->lookahead == '[') {
    advance(lexer, false);
    return scan_block_comment(lexer, false); // block: #[ ]#
  }

  return scan_line_comment(lexer); // line: #
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

  // Emit queued INDENT/DEDENT tokens first.
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

  // Comments (nested block comments supported)
  if (valid[COMMENT] && lexer->lookahead == '#') {
    lexer->result_symbol = COMMENT;
    return scan_comment(lexer);
  }

  // EOF handling: emit synthetic NEWLINE first (once), then flush remaining DEDENTs.
  // This ensures files without trailing newlines parse correctly.
  if (lexer->lookahead == 0) {
    // First, emit a synthetic NEWLINE at EOF if the parser can accept it
    // and we haven't already emitted one
    if (valid[NEWLINE] && !s->eof_newline_emitted) {
      s->eof_newline_emitted = true;
      // Queue up dedents for remaining indentation levels
      while (s->indent_len > 1) {
        s->indent_len--;
        s->pending_dedents++;
      }
      lexer->result_symbol = NEWLINE;
      return true;
    }
    // Then flush remaining dedents
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

  // Newline handling -> NEWLINE or SOFT_NEWLINE depending on grammar context.
  if (is_newline(lexer->lookahead)) {
    consume_newline(lexer);
    lexer->mark_end(lexer);

    uint32_t indent = consume_indent(lexer);
    int32_t next = lexer->lookahead;

    bool hard_newline = valid[NEWLINE];

    // Only update indentation stack on hard newlines.
    // Soft newlines are used for line continuation contexts where indentation
    // must not affect the layout stack.
    if (hard_newline) {
      // Blank or comment-only lines should not affect indentation stack.
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

  return false;
}

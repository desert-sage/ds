// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The layout tokens of DS ([LLEX.6]): NEWLINE at the end of a statement, and
// INDENT and DEDENT where the indentation of the next non-blank line rises or
// falls. tree-sitter asks for one only where the grammar can take it, so inside
// a bracket group, where none is valid, a line break is whitespace and any
// indentation is legal ([LLEX.7.5.5]).
//
// The shape is tree-sitter-python's scanner, without its strings: DS has no
// line continuation, and its strings are the grammar's.
//
// - The stack of indent columns starts empty, which stands for column 0
//   ([LLEX.6.2]).
// - A blank line, or one holding only a comment, moves nothing ([LLEX.6.6.1]);
//   a DEDENT waits until the comments indented as the block it closes have been
//   read, so they stay inside it.
// - At the end of the file every open level closes ([LLEX.6.5]).
//
// The 4-space rule ([LLEX.6.4]) and the refused tab ([LGRA.2.2.1]) are the
// compiler's diagnostics: this scanner takes any rise as one level, so a
// program the compiler refuses for its indentation still has a tree.

#include "tree_sitter/parser.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum TokenType { NEWLINE, INDENT, DEDENT };

#define MAX_DEPTH 256

typedef struct {
    uint16_t depth;
    uint16_t columns[MAX_DEPTH];
} Scanner;

static void skip(TSLexer *lexer) { lexer->advance(lexer, true); }

void *tree_sitter_ds_external_scanner_create(void) {
    Scanner *scanner = calloc(1, sizeof(Scanner));
    return scanner;
}

void tree_sitter_ds_external_scanner_destroy(void *payload) { free(payload); }

unsigned tree_sitter_ds_external_scanner_serialize(void *payload, char *buffer) {
    Scanner *scanner = payload;
    unsigned size = scanner->depth * sizeof(uint16_t);
    if (size > TREE_SITTER_SERIALIZATION_BUFFER_SIZE) size = TREE_SITTER_SERIALIZATION_BUFFER_SIZE;
    memcpy(buffer, scanner->columns, size);
    return size;
}

void tree_sitter_ds_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
    Scanner *scanner = payload;
    scanner->depth = (uint16_t)(length / sizeof(uint16_t));
    if (scanner->depth > MAX_DEPTH) scanner->depth = MAX_DEPTH;
    if (scanner->depth) memcpy(scanner->columns, buffer, scanner->depth * sizeof(uint16_t));
}

bool tree_sitter_ds_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    Scanner *scanner = payload;

    // In error recovery every token is valid; no layout token is made up then.
    if (valid_symbols[NEWLINE] && valid_symbols[INDENT] && valid_symbols[DEDENT]) return false;

    // The token ends where the line does: what follows is read again by the
    // grammar's own lexer, comments included.
    lexer->mark_end(lexer);

    bool found_end_of_line = false;
    uint32_t column = 0;
    int32_t first_comment_column = -1;

    for (;;) {
        if (lexer->lookahead == '\n') {
            found_end_of_line = true;
            column = 0;
            skip(lexer);
        } else if (lexer->lookahead == ' ') {
            column++;
            skip(lexer);
        } else if (lexer->lookahead == '\t') {
            column += 4;
            skip(lexer);
        } else if (lexer->lookahead == '\r' || lexer->lookahead == '\f') {
            skip(lexer);
        } else if (lexer->lookahead == '#') {
            // A comment after code on the same line is the grammar's extra.
            if (!found_end_of_line) return false;
            if (first_comment_column == -1) first_comment_column = (int32_t)column;
            while (lexer->lookahead && lexer->lookahead != '\n') skip(lexer);
            column = 0;
        } else if (lexer->eof(lexer)) {
            found_end_of_line = true;
            column = 0;
            break;
        } else {
            break;
        }
    }

    if (!found_end_of_line) return false;

    uint16_t current = scanner->depth ? scanner->columns[scanner->depth - 1] : 0;

    if (valid_symbols[INDENT] && column > current && scanner->depth < MAX_DEPTH) {
        scanner->columns[scanner->depth++] = (uint16_t)column;
        lexer->result_symbol = INDENT;
        return true;
    }

    if (valid_symbols[DEDENT] && column < current && first_comment_column < (int32_t)current) {
        scanner->depth--;
        lexer->result_symbol = DEDENT;
        return true;
    }

    if (valid_symbols[NEWLINE]) {
        lexer->result_symbol = NEWLINE;
        return true;
    }

    return false;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* ds_text — bounded text building for libds, with no printf underneath
 * ([IARC.1.16]). The contract is snprintf's: NUL-terminated after every append (when
 * `cap > 0`), and text past `cap - 1` is dropped and still counted.
 */
#ifndef LIBDS_DS_TEXT_H
#define LIBDS_DS_TEXT_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    char  *buf;
    size_t cap;
    size_t len;     /* the length of the full text, cut or not */
} ds_text_t;

ds_text_t ds_text(char *buf, size_t cap);

void ds_text_char(ds_text_t *t, char c);
void ds_text_str(ds_text_t *t, const char *s);              /* NULL writes nothing */
void ds_text_strn(ds_text_t *t, const char *s, size_t n);   /* n bytes, NULs included */
void ds_text_i64(ds_text_t *t, int64_t v);
void ds_text_u64(ds_text_t *t, uint64_t v);
/* printf's `%0<width>lld`: zeros after the sign, the sign counting toward
   `width`; a value wider than `width` is written whole */
void ds_text_i64_zpad(ds_text_t *t, int64_t v, unsigned width);
/* lowercase hexadecimal, at least `min_digits` digits, no prefix */
void ds_text_hex(ds_text_t *t, uint64_t v, unsigned min_digits);
void ds_text_float(ds_text_t *t, double v);                 /* canonical text */

/* The full length, as snprintf returns it. */
int ds_text_len(const ds_text_t *t);

/* Whether the `n` bytes at `s` are well-formed UTF-8 (RFC 3629) ([LSTR.8.5]). U+0000
   is well-formed; a caller that refuses it does so itself. */
int ds_utf8_well_formed(const char *s, size_t n);

#endif /* LIBDS_DS_TEXT_H */

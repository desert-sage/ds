/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
#include "ds_text.h"

#include <limits.h>

#include "float_fmt.h"

ds_text_t ds_text(char *buf, size_t cap)
{
    ds_text_t t = { buf, cap, 0 };
    if (cap > 0) buf[0] = '\0';
    return t;
}

void ds_text_char(ds_text_t *t, char c)
{
    if (t->cap > 0 && t->len < t->cap - 1) {
        t->buf[t->len] = c;
        t->buf[t->len + 1] = '\0';
    }
    t->len++;
}

void ds_text_strn(ds_text_t *t, const char *s, size_t n)
{
    for (size_t i = 0; i < n; i++) ds_text_char(t, s[i]);
}

void ds_text_str(ds_text_t *t, const char *s)
{
    if (s == NULL) return;
    while (*s) ds_text_char(t, *s++);
}

void ds_text_u64(ds_text_t *t, uint64_t v)
{
    char d[20];
    int n = 0;
    do { d[n++] = (char) ('0' + v % 10u); v /= 10u; } while (v);
    while (n > 0) ds_text_char(t, d[--n]);
}

void ds_text_i64(ds_text_t *t, int64_t v)
{
    if (v < 0) {
        ds_text_char(t, '-');
        /* -(v + 1) + 1 in unsigned arithmetic: INT64_MIN has no positive int64 */
        ds_text_u64(t, (uint64_t) (-(v + 1)) + 1u);
    } else {
        ds_text_u64(t, (uint64_t) v);
    }
}

void ds_text_i64_zpad(ds_text_t *t, int64_t v, unsigned width)
{
    uint64_t m = v < 0 ? (uint64_t) (-(v + 1)) + 1u : (uint64_t) v;
    unsigned digits = 1;
    for (uint64_t r = m / 10u; r; r /= 10u) digits++;
    unsigned used = digits + (v < 0 ? 1u : 0u);
    if (v < 0) ds_text_char(t, '-');
    for (unsigned i = used; i < width; i++) ds_text_char(t, '0');
    ds_text_u64(t, m);
}

void ds_text_hex(ds_text_t *t, uint64_t v, unsigned min_digits)
{
    static const char digits[] = "0123456789abcdef";
    char d[16];
    unsigned n = 0;
    do { d[n++] = digits[v & 0xfu]; v >>= 4; } while (v);
    for (unsigned i = n; i < min_digits; i++) ds_text_char(t, '0');
    while (n > 0) ds_text_char(t, d[--n]);
}

void ds_text_float(ds_text_t *t, double v)
{
    char b[32];
    int n = ds_fmt_float(b, sizeof b, v);
    ds_text_strn(t, b, (size_t) n);
}

int ds_text_len(const ds_text_t *t)
{
    return t->len > (size_t) INT_MAX ? INT_MAX : (int) t->len;
}

int ds_utf8_well_formed(const char *s, size_t n)
{
    const unsigned char *p = (const unsigned char *) s;
    size_t i = 0;
    while (i < n) {
        const unsigned c = p[i];
        if (c < 0x80u) { i++; continue; }
        size_t   len;
        uint32_t cp, min;
        if      ((c & 0xE0u) == 0xC0u) { len = 2; cp = c & 0x1Fu; min = 0x80u; }
        else if ((c & 0xF0u) == 0xE0u) { len = 3; cp = c & 0x0Fu; min = 0x800u; }
        else if ((c & 0xF8u) == 0xF0u) { len = 4; cp = c & 0x07u; min = 0x10000u; }
        else return 0;
        if (n - i < len) return 0;
        for (size_t k = 1; k < len; k++) {
            if ((p[i + k] & 0xC0u) != 0x80u) return 0;
            cp = (cp << 6) | (p[i + k] & 0x3Fu);
        }
        if (cp < min || cp > 0x10FFFFu || (cp >= 0xD800u && cp <= 0xDFFFu))
            return 0;
        i += len;
    }
    return 1;
}

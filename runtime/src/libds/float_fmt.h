/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* float_fmt — DS's Float text, both directions ([LDET.3.2.7], [LDET.3.2.8]).
 *
 * No libc conversion routine is underneath any of it ([IARC.1.16]). The digits come
 * from vendored code (`vendor/README.md`): Dragonbox for Float to shortest text
 * (float_text/float_shortest.cc), fast_float for text to Float
 * (float_text/float_parse.cc). Only the shape of the text is DS's own.
 *
 * A NaN renders "nan" whatever its sign ([LCST.4.5.6]): x86_64's and aarch64's default
 * NaNs differ in sign.
 */
#ifndef LIBDS_FLOAT_FMT_H
#define LIBDS_FLOAT_FMT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Render `v` as DS's canonical Float text into `buf` (capacity `cap`) and
   return the full length (bytes, excluding the NUL), snprintf-style: when
   `cap` is too small the text is cut and NUL-terminated, and the return value
   still says how long it is. The longest output is 24 bytes (a negative
   17-significant-digit value in scientific form); callers pass at least 32. */
int ds_fmt_float(char *buf, size_t cap, double v);

/* `v` with exactly `prec` decimals, correctly rounded, ties to even, no exponent;
   `prec == 0` writes no decimal point. The sign is kept: "-0.00". Returns the full
   length as ds_fmt_float does. A finite value can need ~310 + `prec` bytes. */
int ds_fmt_float_fixed(char *buf, size_t cap, double v, unsigned prec);

/* ds_fmt_float_fixed's arithmetic, external so formal/cbmc can reach each piece.
   Contracts are beside the definitions in float_fmt.c. */
#define DS_FX_LIMBS 36                  /* 10 * 2^1074 < 2^1078 fits 34 limbs */
typedef struct { uint32_t w[DS_FX_LIMBS]; } ds_fx_big_t;
typedef struct {
    uint64_t ip;                        /* floor(x) */
    unsigned kdig;                      /* min(prec, s): places that can be non-zero */
    int      up;                        /* round the last kept place up */
    int      last_non9;                 /* where that carry stops; -1 = into ip */
} ds_fx_plan_t;
void     ds_fx_frac_init(ds_fx_big_t *f, uint64_t m, unsigned s);
int      ds_fx_next_digit(ds_fx_big_t *f, unsigned s);
int      ds_fx_cmp_half(const ds_fx_big_t *f, unsigned s);
void     ds_fx_plan(ds_fx_big_t *f, uint64_t m, unsigned s, unsigned prec,
                    ds_fx_plan_t *p);
void     ds_fx_int_init(ds_fx_big_t *n, uint64_t m, unsigned e);
uint32_t ds_fx_divmod_1e9(ds_fx_big_t *n);

/* Parse exactly the `n` bytes at `s` as an RFC 8259 JSON number, correctly
   rounded, ties to even, any number of digits ([LDET.3.2.8]). A magnitude
   beyond the largest finite double reads as ±Inf and one below the smallest
   subnormal as ±0, as strtod gives. 0 on success with `*out` set; -1 when the
   bytes are not exactly one JSON number, with `*out` untouched. */
int ds_parse_float_json(const char *s, size_t n, double *out);

/* `String::Float?` ([LCST.4.5.8]): exactly the `n` bytes at `s` are an
   optional sign and then an INT_LIT or a FLOAT_LIT as a source literal spells
   them ([LLEX.11.1], [LLEX.11.2]; `_` separators, `0x` / `0b` / `0o`), or
   `inf`. The value correctly rounded, ties to even; `-0.0` keeps its sign.
   0 on success; -1 for anything else and for a finite spelling that rounds to
   an infinity, which the caller turns into `null`. No whitespace, no NaN
   spelling, no C hex float, no locale. Allocates nothing. */
int ds_parse_float_text(const char *s, size_t n, double *out);

/* `String::Int?` ([LCST.4.5.7]): exactly the `n` bytes at `s` are an optional
   sign and then an INT_LIT ([LLEX.11.1]) whose value lies in the 64-bit range.
   0 on success with `*out` set; -1 for anything else. */
int ds_parse_int_text(const char *s, size_t n, int64_t *out);

/* The shortest round-trip digits of `v`, finite and non-zero, as Dragonbox
   writes them: [-]D[.DDD]E[-]N, uppercase `E`, no trailing zero in the
   significand ("1E0", "1.5E2", "-2.5E-10"). Not NUL-terminated; returns the
   length. `buf` holds at least DS_FLOAT_SHORTEST_MAX bytes. ds_fmt_float's
   input, and nothing else's: everything else wants the shaped text. */
#define DS_FLOAT_SHORTEST_MAX 24
int ds_float_shortest(double v, char *buf);

#ifdef __cplusplus
}
#endif

#endif /* LIBDS_FLOAT_FMT_H */

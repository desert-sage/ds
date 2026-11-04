/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* float_fmt.c — the shaping half of DS's Float text. See float_fmt.h. */
#include "float_fmt.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

#include "ds_text.h"

/* The shortest form, read apart: `dig` holds the significant digits (no
   leading or trailing zero), `e` is the decimal exponent of the first one. */
typedef struct {
    int  neg;
    int  ndig;
    int  e;
    char dig[17];
} shortest_t;

/* `v` finite and non-zero. Dragonbox writes [-]D[.DDD]E[-]N with no trailing
   zeros in the mantissa: "1E0", "1.5E2", "-2.5E-10". */
static void shortest_of(double v, shortest_t *s)
{
    char r[DS_FLOAT_SHORTEST_MAX];
    int n = ds_float_shortest(v, r);
    int i = 0;
    s->neg = 0;
    s->ndig = 0;
    if (r[i] == '-') { s->neg = 1; i++; }
    s->dig[s->ndig++] = r[i++];
    if (i < n && r[i] == '.') {
        for (i++; i < n && r[i] != 'E'; i++) s->dig[s->ndig++] = r[i];
    }
    i++;                                       /* the 'E' */
    int esign = 1;
    if (i < n && r[i] == '-') { esign = -1; i++; }
    int e = 0;
    for (; i < n; i++) e = e * 10 + (r[i] - '0');
    s->e = esign * e;
}

#define put(o, c)    ds_text_char((o), (c))
#define puts_(o, s)  ds_text_str((o), (s))
#define finish(o)    ds_text_len(o)

/* nan / ±inf, the two spellings both formats share; 1 if `v` was one */
static int non_finite(ds_text_t *o, double v)
{
    if (isnan(v)) { puts_(o, "nan"); return 1; }
    if (isinf(v)) { puts_(o, v < 0.0 ? "-inf" : "inf"); return 1; }
    return 0;
}

int ds_fmt_float(char *buf, size_t cap, double v)
{
    ds_text_t o = ds_text(buf, cap);
    if (non_finite(&o, v)) return finish(&o);
    if (v == 0.0) { puts_(&o, signbit(v) ? "-0.0" : "0.0"); return finish(&o); }

    shortest_t s;
    shortest_of(v, &s);
    if (s.neg) put(&o, '-');

    if (s.e >= -4 && s.e <= 15) {              /* fixed */
        if (s.e >= 0) {
            int int_digits = s.e + 1;
            if (s.ndig <= int_digits) {        /* whole number: pad, keep ".0" */
                for (int i = 0; i < s.ndig; i++) put(&o, s.dig[i]);
                for (int i = s.ndig; i < int_digits; i++) put(&o, '0');
                puts_(&o, ".0");
            } else {                           /* split at the decimal point */
                for (int i = 0; i < int_digits; i++) put(&o, s.dig[i]);
                put(&o, '.');
                for (int i = int_digits; i < s.ndig; i++) put(&o, s.dig[i]);
            }
        } else {                               /* 0.<zeros><digits> */
            puts_(&o, "0.");
            for (int i = 0; i < -s.e - 1; i++) put(&o, '0');
            for (int i = 0; i < s.ndig; i++) put(&o, s.dig[i]);
        }
    } else {                                   /* scientific, no trailing ".0" */
        put(&o, s.dig[0]);
        if (s.ndig > 1) {
            put(&o, '.');
            for (int i = 1; i < s.ndig; i++) put(&o, s.dig[i]);
        }
        put(&o, 'e');
        put(&o, s.e < 0 ? '-' : '+');
        int ea = s.e < 0 ? -s.e : s.e;
        char eb[4];
        int en = 0;
        do { eb[en++] = (char) ('0' + ea % 10); ea /= 10; } while (ea);
        while (en < 2) eb[en++] = '0';
        while (en > 0) put(&o, eb[--en]);
    }
    return finish(&o);
}

/* Fixed precision: a finite double is m * 2^e exactly (m < 2^53), rounded here in
 * integer arithmetic on a small bignum.
 *
 *   - e >= 0: an integer below 2^1024. Nothing rounds.
 *   - e <  0: with s = -e (1..1074), the fraction has at most s decimal places. Digits
 *     come from multiplying it by 10 and lifting what crosses bit s.
 *
 * Nothing allocates. A round-up can carry through trailing 9s into the integer part,
 * so the digits are generated twice: once to decide (ds_fx_plan), once to write.
 *
 * The `requires` / `ensures` below are what formal/cbmc asserts. A ds_fx_big_t denotes
 * the integer sum(w[i] * 2^(32 i)).
 */

/* requires: 1 <= s <= 1074, m < 2^53
 * ensures:  F = m mod 2^s  (the fraction of m * 2^-s, scaled by 2^s); F < 2^s */
void ds_fx_frac_init(ds_fx_big_t *f, uint64_t m, unsigned s)
{
    memset(f, 0, sizeof *f);
    if (s < 64u) m &= (((uint64_t) 1) << s) - 1u;
    f->w[0] = (uint32_t) m;
    f->w[1] = (uint32_t) (m >> 32);
}

/* requires: 1 <= s <= 1074, F < 2^s
 * ensures:  returns d = floor(10 F / 2^s), so 0 <= d <= 9;
 *           F' = 10 F mod 2^s, so F' < 2^s again
 *
 * F < 2^s puts every set bit of 10 F below bit s + 4, so the multiply stops at limb
 * s / 32 + 1 with no carry out. */
int ds_fx_next_digit(ds_fx_big_t *f, unsigned s)
{
    const unsigned li = s / 32u, bi = s % 32u;    /* li <= 33 */
    uint64_t carry = 0;
    for (unsigned i = 0; i <= li + 1u; i++) {
        uint64_t t = (uint64_t) f->w[i] * 10u + carry;
        f->w[i] = (uint32_t) t;
        carry = t >> 32;
    }
    const uint64_t hi = (uint64_t) f->w[li] | ((uint64_t) f->w[li + 1u] << 32);
    const int digit = (int) ((hi >> bi) & 0xFu);
    f->w[li] &= bi ? (((uint32_t) 1u) << bi) - 1u : 0u;
    f->w[li + 1u] = 0;
    return digit;
}

/* requires: 1 <= s <= 1074, F < 2^s
 * ensures:  returns -1, 0 or +1 as F is below, at or above 2^(s-1) */
int ds_fx_cmp_half(const ds_fx_big_t *f, unsigned s)
{
    const unsigned hb = s - 1u, li = hb / 32u, bi = hb % 32u;
    if (!((f->w[li] >> bi) & 1u)) return -1;
    if (f->w[li] & ((((uint32_t) 1u) << bi) - 1u)) return 1;
    for (unsigned i = 0; i < li; i++) if (f->w[i]) return 1;
    return 0;
}

/* requires: 1 <= s <= 1074, m < 2^53, x = m * 2^-s
 * ensures:  p->ip = floor(x); p->kdig = min(prec, s);
 *           with d_1 .. d_kdig the first kdig decimal places of x and
 *           R = frac(x * 10^kdig):
 *             p->up = R > 1/2, or R = 1/2 and the last digit kept (d_kdig,
 *                     or ip's last digit when kdig = 0) is odd — round half
 *                     to even; R = 0 whenever kdig = s;
 *             p->last_non9 = the largest k < kdig with d_(k+1) != 9, else -1.
 *           So the correctly rounded text is ip + (up && last_non9 < 0), then
 *           the places with d_(last_non9 + 1) incremented and every place
 *           after it 0 when up, unchanged when not. */
void ds_fx_plan(ds_fx_big_t *f, uint64_t m, unsigned s, unsigned prec,
                ds_fx_plan_t *p)
{
    p->ip = s < 64u ? m >> s : 0u;                /* < 2^53 */
    p->kdig = prec < s ? prec : s;
    p->last_non9 = -1;
    int last = (int) (p->ip % 10u);
    ds_fx_frac_init(f, m, s);
    for (unsigned k = 0; k < p->kdig; k++) {
        last = ds_fx_next_digit(f, s);
        if (last != 9) p->last_non9 = (int) k;
    }
    p->up = 0;
    if (p->kdig < s) {                            /* else R = 0 */
        const int c = ds_fx_cmp_half(f, s);
        p->up = c > 0 || (c == 0 && (last & 1));
    }
}

/* requires: m < 2^53, 0 <= e <= 971 (so N < 2^1024)
 * ensures:  N = m * 2^e */
void ds_fx_int_init(ds_fx_big_t *n, uint64_t m, unsigned e)
{
    memset(n, 0, sizeof *n);
    const unsigned li = e / 32u, bi = e % 32u;    /* li <= 30 */
    const uint64_t lo = m << bi;                  /* the low 64 bits of m * 2^bi */
    const uint64_t hi = bi ? m >> (64u - bi) : 0u;   /* the rest, < 2^21 */
    n->w[li] = (uint32_t) lo;
    n->w[li + 1u] = (uint32_t) (lo >> 32);
    n->w[li + 2u] = (uint32_t) hi;
}

/* requires: N < 2^1024
 * ensures:  returns N mod 10^9; N' = floor(N / 10^9) */
uint32_t ds_fx_divmod_1e9(ds_fx_big_t *n)
{
    uint64_t rem = 0;
    for (int i = DS_FX_LIMBS - 1; i >= 0; i--) {
        const uint64_t cur = (rem << 32) | n->w[i];  /* rem < 10^9 < 2^30 */
        n->w[i] = (uint32_t) (cur / 1000000000u);
        rem = cur % 1000000000u;
    }
    return (uint32_t) rem;
}

static int fx_is_zero(const ds_fx_big_t *n)
{
    for (int i = 0; i < DS_FX_LIMBS; i++) if (n->w[i]) return 0;
    return 1;
}

/* m * 2^e, e >= 0, in decimal: base-10^9 chunks, least significant first */
static void fx_put_big_int(ds_text_t *o, ds_fx_big_t *n, uint64_t m, unsigned e)
{
    uint32_t chunk[DS_FX_LIMBS];                  /* 10^9 > 2^29: <= 36 for 2^1024 */
    int nc = 0;
    ds_fx_int_init(n, m, e);
    do chunk[nc++] = ds_fx_divmod_1e9(n); while (!fx_is_zero(n));
    ds_text_u64(o, chunk[nc - 1]);
    for (int i = nc - 2; i >= 0; i--) {
        char d[9];
        uint32_t c = chunk[i];
        for (int k = 8; k >= 0; k--) { d[k] = (char) ('0' + c % 10u); c /= 10u; }
        for (int k = 0; k < 9; k++) put(o, d[k]);
    }
}

int ds_fmt_float_fixed(char *buf, size_t cap, double v, unsigned prec)
{
    ds_text_t o = ds_text(buf, cap);
    if (non_finite(&o, v)) return finish(&o);
    if (signbit(v)) put(&o, '-');      /* kept even when every digit is 0 */

    uint64_t bits;
    memcpy(&bits, &v, sizeof bits);
    const unsigned bexp = (unsigned) ((bits >> 52) & 0x7FFu);
    uint64_t m = bits & ((((uint64_t) 1) << 52) - 1u);
    int e;
    if (bexp == 0) e = -1074;                     /* subnormal, or zero */
    else { m |= ((uint64_t) 1) << 52; e = (int) bexp - 1075; }

    ds_fx_big_t big;                              /* the one buffer, both paths */

    if (m == 0 || e >= 0) {                       /* zero, or an integer */
        if (m == 0) put(&o, '0');
        else fx_put_big_int(&o, &big, m, (unsigned) e);
        if (prec > 0) {
            put(&o, '.');
            for (unsigned k = 0; k < prec; k++) put(&o, '0');
        }
        return finish(&o);
    }

    const unsigned s = (unsigned) -e;
    ds_fx_plan_t p;
    ds_fx_plan(&big, m, s, prec, &p);             /* pass 1: decide */

    /* Pass 2: ds_fx_plan's `ensures`, read as a recipe. */
    ds_text_u64(&o, (p.up && p.last_non9 < 0) ? p.ip + 1u : p.ip);
    if (prec > 0) {
        put(&o, '.');
        ds_fx_frac_init(&big, m, s);
        for (unsigned k = 0; k < p.kdig; k++) {
            int d = ds_fx_next_digit(&big, s);
            if (p.up && (int) k == p.last_non9) d += 1;
            else if (p.up && (int) k > p.last_non9) d = 0;
            put(&o, (char) ('0' + d));
        }
        for (unsigned k = p.kdig; k < prec; k++) put(&o, '0');
    }
    return finish(&o);
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* int_ops — DS integer arithmetic ([LDET.3.2.2]), done in uint64_t where signed C would
 * be undefined.
 *
 * Total but for the preconditions the callers check: a non-zero divisor ([LEXP.7.15],
 * [LEXP.7.16]) and a non-negative shift count ([LEXP.7.14.1]).
 */
#ifndef LIBDS_INT_OPS_H
#define LIBDS_INT_OPS_H

#include <stdint.h>

/* [LEXP.7.13.1]: overflow wraps. */
static inline int64_t ds_i64_add(int64_t a, int64_t b) {
    return (int64_t)((uint64_t)a + (uint64_t)b);
}
static inline int64_t ds_i64_sub(int64_t a, int64_t b) {
    return (int64_t)((uint64_t)a - (uint64_t)b);
}
static inline int64_t ds_i64_mul(int64_t a, int64_t b) {
    return (int64_t)((uint64_t)a * (uint64_t)b);
}
static inline int64_t ds_i64_neg(int64_t a) {
    return (int64_t)(0u - (uint64_t)a);
}

/* [LEXP.3.2]: the wrap makes |INT64_MIN| INT64_MIN. */
static inline int64_t ds_i64_abs(int64_t a) {
    return a < 0 ? ds_i64_neg(a) : a;
}

/* [LEXP.3.2]: INT64_MIN answers 64; 0 answers 0. */
static inline int64_t ds_i64_bit_length(int64_t a) {
    uint64_t m = a < 0 ? 0u - (uint64_t)a : (uint64_t)a;
    int64_t n = 0;
    while (m != 0) {
        n++;
        m >>= 1;
    }
    return n;
}

/* Requires exp >= 0. Wraps as `a * a * ... * a` does; `0 ** 0 == 1`. */
static inline int64_t ds_i64_pow(int64_t base, int64_t exp) {
    int64_t result = 1;
    uint64_t e = (uint64_t)exp;
    while (e != 0) {
        if (e & 1u) result = ds_i64_mul(result, base);
        e >>= 1;
        if (e != 0) base = ds_i64_mul(base, base);
    }
    return result;
}

/* [LEXP.7.5]: rounds toward negative infinity. INT64_MIN / -1 wraps. */
static inline int64_t ds_i64_floordiv(int64_t a, int64_t b) {
    if (a == INT64_MIN && b == -1) {
        return INT64_MIN;
    }
    int64_t q = a / b;
    int64_t r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) {
        q -= 1;
    }
    return q;
}

/* [LEXP.7.6]: the sign of the divisor. INT64_MIN % -1 would be UB in C. */
static inline int64_t ds_i64_floormod(int64_t a, int64_t b) {
    if (a == INT64_MIN && b == -1) {
        return 0;
    }
    int64_t r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) {
        r += b;
    }
    return r;
}

/* [LEXP.7.14.1]: a count of 64 or more gives 0 (formal/saw/i64_shl.saw). The `& 63` is
   a no-op below 64: clang turns the guard into a select and computes the shift
   speculatively, and an LLVM `shl` by 64 or more is poison even in the arm not taken. */
static inline int64_t ds_i64_shl(int64_t a, int64_t count) {
    if (count >= 64) {
        return 0;
    }
    return (int64_t)((uint64_t)a << (count & 63));
}

/* [LEXP.7.14.1]: floor(a / 2^count) (formal/saw/i64_shr.saw). C's `>>` on a negative
   value is implementation-defined. */
static inline int64_t ds_i64_shr(int64_t a, int64_t count) {
    if (count >= 64) {
        return a < 0 ? -1 : 0;
    }
    uint64_t n = (uint64_t)count;
    if (a < 0) {
        return (int64_t)~((~(uint64_t)a) >> n);
    }
    return (int64_t)((uint64_t)a >> n);
}

/* The five `Int` members of [LEXP.3.7.3], over p = the 64-bit pattern of `x`. The caller
   raises DOMAIN outside each one's domain ([LEXP.3.7.4]). Each `& 63` is as in
   ds_i64_shl. */

/* 1 <= w <= 64. */
static inline uint64_t ds_u64_low_mask(int64_t w) {
    return w >= 64 ? ~(uint64_t)0 : (((uint64_t)1 << (w & 63)) - 1u);
}

/* x.bits(lo, w): floor(p / 2^lo) mod 2^w. 0 <= lo, 1 <= w, lo + w <= 64. */
static inline int64_t ds_i64_bits(int64_t x, int64_t lo, int64_t w) {
    return (int64_t)(((uint64_t)x >> (lo & 63)) & ds_u64_low_mask(w));
}

/* x.sign_extend(w): u - 2^w when u >= 2^(w-1), else u, u = p mod 2^w.
   1 <= w <= 64; at 64 it is x. */
static inline int64_t ds_i64_sign_extend(int64_t x, int64_t w) {
    if (w >= 64) {
        return x;
    }
    uint64_t mask = ds_u64_low_mask(w);
    uint64_t u = (uint64_t)x & mask;
    if ((u >> ((w - 1) & 63)) & 1u) {
        u |= ~mask;
    }
    return (int64_t)u;
}

/* x.swap_bytes(w): the low w/8 bytes of p in reverse order. w in 16, 32, 64. */
static inline int64_t ds_i64_swap_bytes(int64_t x, int64_t w) {
    uint64_t p = (uint64_t)x;
    uint64_t r = 0;
    for (int64_t i = 0; i < w / 8; i++) {
        r = (r << 8) | ((p >> ((8 * i) & 63)) & 0xFFu);
    }
    return (int64_t)r;
}

/* x.leading_zeros: 64 for 0. Not __builtin_clzll, which is undefined at 0. */
static inline int64_t ds_i64_leading_zeros(int64_t x) {
    uint64_t p = (uint64_t)x;
    int64_t n = 64;
    while (p != 0) {
        n--;
        p >>= 1;
    }
    return n;
}

/* x.trailing_zeros: the largest k <= 64 with 2^k dividing p, 64 for 0. */
static inline int64_t ds_i64_trailing_zeros(int64_t x) {
    uint64_t p = (uint64_t)x;
    int64_t n = 0;
    while (n < 64 && (p & 1u) == 0) {
        n++;
        p >>= 1;
    }
    return n;
}

#endif /* LIBDS_INT_OPS_H */

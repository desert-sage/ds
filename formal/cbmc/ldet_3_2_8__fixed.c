/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 *@spec [LDET.3.2.8]
 *
 * ldet_3_2_8__fixed.c -- CBMC harnesses for the exact arithmetic under
 * ds_fmt_float_fixed: the binary value correctly rounded to N places, ties to
 * even.
 *
 * WHAT THIS IS. GLUE written by the implementer: memory-safety and
 * undefined-behaviour checks over the whole input domain, and exact checks
 * whose REFERENCE is a primitive of the tool -- CBMC's native
 * `unsigned __int128` -- over the sub-domain that fits
 * it. The contract the primitives are checked against is the `requires` /
 * `ensures` block beside each one in runtime/src/libds/float_fmt.c. Whether
 * those contracts state [LDET.3.2.8] faithfully, and the unbounded proof that
 * they compose into correct rounding, are the Logician's.
 *
 * CBMC proves a STATED PROPERTY, and where a loop is involved only up to an
 * unwind bound; every bound below carries --unwinding-assertions, so CBMC
 * proves the bound sufficient rather than assuming it. Every entry point says
 * which of three kinds it is:
 *   BOUNDS  -- the whole domain the contract admits; no out-of-bounds access,
 *              no undefined shift, and the contract's range postconditions.
 *   EXACT   -- equality with the __int128 reference, on the sub-domain where
 *              the reference fits. What that EXCLUDES is stated with it.
 *
 * Entry points are named <lowercased-clause-id>__<tag> (§11 discipline).
 *
 *@cbmc-src runtime/src/libds/float_fmt.c runtime/src/libds/ds_text.c
 */

#include <stdint.h>
#include <string.h>

#include "float_fmt.h"

typedef unsigned __int128 u128;

static unsigned nondet_unsigned(void);
static uint64_t nondet_u64(void);

/* the integer the low four limbs denote; the rest must be zero for it to be
   the whole value */
static u128 as128(const ds_fx_big_t *b)
{
    return (u128) b->w[0] | ((u128) b->w[1] << 32)
         | ((u128) b->w[2] << 64) | ((u128) b->w[3] << 96);
}

/* B < 2^s, as limbs: everything from bit s up is zero */
static int below_pow2(const ds_fx_big_t *b, unsigned s)
{
    const unsigned li = s / 32u, bi = s % 32u;
    for (unsigned i = li + 1u; i < DS_FX_LIMBS; i++) if (b->w[i]) return 0;
    if (li < DS_FX_LIMBS && (b->w[li] >> bi) != 0u) return 0;
    return 1;
}

/* a nondet F with F < 2^s */
static void nondet_below(ds_fx_big_t *f, unsigned s)
{
    __CPROVER_havoc_object(f);
    __CPROVER_assume(below_pow2(f, s));
}

/* -------------------------------------------------------------------------
 * ldet_3_2_8__next_digit_bounds -- BOUNDS.
 *
 * Domain: every s in 1..1074 and every F < 2^s: all that ds_fx_next_digit's
 * `requires` admits, and every value a double's fraction can take.
 * Postconditions checked: the digit is 0..9, and F' < 2^s again, so the
 * precondition holds for the next call -- the invariant the digit loop rests
 * on. Bound: the multiply runs s/32 + 2 <= 35 iterations; --unwind 36. */
/*@cbmc ldet_3_2_8__next_digit_bounds --bounds-check --pointer-check --undefined-shift-check --unwind 36 --unwinding-assertions */
void ldet_3_2_8__next_digit_bounds(void)
{
    ds_fx_big_t f;
    const unsigned s = nondet_unsigned();
    __CPROVER_assume(s >= 1u && s <= 1074u);
    nondet_below(&f, s);
    const int d = ds_fx_next_digit(&f, s);
    __CPROVER_assert(d >= 0 && d <= 9, "LDET.3.2.8: a place is one decimal digit");
    __CPROVER_assert(below_pow2(&f, s), "LDET.3.2.8: the remainder stays below 2^s");
}

/* -------------------------------------------------------------------------
 * ldet_3_2_8__next_digit_exact -- EXACT, against __int128.
 *
 * Domain: s in 1..123 and F < 2^s, so 10 F < 2^127 fits the reference.
 * EXCLUDES s in 124..1074, which ldet_3_2_8__next_digit_full checks against a
 * 1152-bit reference: no uniformity argument is relied on. Kept as a second,
 * independent reference over the range __int128 reaches. */
/*@cbmc ldet_3_2_8__next_digit_exact --bounds-check --pointer-check --undefined-shift-check --unwind 36 --unwinding-assertions */
void ldet_3_2_8__next_digit_exact(void)
{
    ds_fx_big_t f;
    const unsigned s = nondet_unsigned();
    __CPROVER_assume(s >= 1u && s <= 123u);
    nondet_below(&f, s);
    const u128 ten_f = as128(&f) * 10u;
    const u128 mask = (((u128) 1) << s) - 1u;
    const int d = ds_fx_next_digit(&f, s);
    __CPROVER_assert((u128) d == (ten_f >> s), "LDET.3.2.8: digit = floor(10F / 2^s)");
    __CPROVER_assert(as128(&f) == (ten_f & mask), "LDET.3.2.8: F' = 10F mod 2^s");
    __CPROVER_assert(below_pow2(&f, 128u), "LDET.3.2.8: nothing written above limb 3");
}

/* -------------------------------------------------------------------------
 * ldet_3_2_8__cmp_half_bounds -- BOUNDS, every s in 1..1074, every F < 2^s.
 * ldet_3_2_8__cmp_half_exact  -- EXACT for s in 1..127; EXCLUDES 128..1074,
 * which ldet_3_2_8__cmp_half_full checks against a 1152-bit reference. */
/*@cbmc ldet_3_2_8__cmp_half_bounds --bounds-check --pointer-check --undefined-shift-check --unwind 36 --unwinding-assertions */
void ldet_3_2_8__cmp_half_bounds(void)
{
    ds_fx_big_t f;
    const unsigned s = nondet_unsigned();
    __CPROVER_assume(s >= 1u && s <= 1074u);
    nondet_below(&f, s);
    const int c = ds_fx_cmp_half(&f, s);
    __CPROVER_assert(c == -1 || c == 0 || c == 1, "LDET.3.2.8: a three-way answer");
}

/*@cbmc ldet_3_2_8__cmp_half_exact --bounds-check --pointer-check --undefined-shift-check --unwind 36 --unwinding-assertions */
void ldet_3_2_8__cmp_half_exact(void)
{
    ds_fx_big_t f;
    const unsigned s = nondet_unsigned();
    __CPROVER_assume(s >= 1u && s <= 127u);
    nondet_below(&f, s);
    const u128 v = as128(&f), half = ((u128) 1) << (s - 1u);
    const int c = ds_fx_cmp_half(&f, s);
    __CPROVER_assert(c == (v < half ? -1 : v == half ? 0 : 1),
                     "LDET.3.2.8: the remainder against half a step");
}

/* -------------------------------------------------------------------------
 * ldet_3_2_8__frac_init_full, ldet_3_2_8__next_digit_full,
 * ldet_3_2_8__cmp_half_full -- EXACT over the WHOLE domain, s in 1..1074.
 *
 * The reference is CBMC's arbitrary-width unsigned bit-vector, wide enough for
 * the whole buffer (36 limbs, 1152 bits): a primitive of the tool (§12.3), as
 * __int128 is, without its width limit. So the uniformity argument the
 * __int128 checks above rest on -- "exact for s <= 123, the same code for
 * s <= 1074" -- is not needed: these check every s the contract admits.
 * What makes them cheap is that the reference never divides and never
 * multiplies two symbolic values: 10 V is two shifts and an add, and `>> s`,
 * `& mask` are a shifter. Supplied by the Logician (§12, "CBMC functional
 * assertions"); the harness shape is the implementer's. */
typedef unsigned __CPROVER_bitvector[1152] wide;

/* the integer a ds_fx_big_t denotes, sum(w[i] * 2^(32 i)), in full */
static wide value(const ds_fx_big_t *b)
{
    wide v = 0;
    for (unsigned i = 0; i < DS_FX_LIMBS; i++) v |= ((wide) b->w[i]) << (32u * i);
    return v;
}

/*@cbmc ldet_3_2_8__frac_init_full --bounds-check --pointer-check --undefined-shift-check --unwind 37 --unwinding-assertions */
void ldet_3_2_8__frac_init_full(void)
{
    ds_fx_big_t f;
    const uint64_t m = nondet_u64();
    const unsigned s = nondet_unsigned();
    __CPROVER_assume(m < (((uint64_t) 1) << 53) && s >= 1u && s <= 1074u);
    ds_fx_frac_init(&f, m, s);
    const wide mask = (((wide) 1) << s) - 1u;
    __CPROVER_assert(value(&f) == (((wide) m) & mask), "LDET.3.2.8: F = m mod 2^s");
}

/*@cbmc ldet_3_2_8__next_digit_full --bounds-check --pointer-check --undefined-shift-check --unwind 37 --unwinding-assertions */
void ldet_3_2_8__next_digit_full(void)
{
    ds_fx_big_t f;
    const unsigned s = nondet_unsigned();
    __CPROVER_assume(s >= 1u && s <= 1074u);
    nondet_below(&f, s);
    const wide v = value(&f);
    const wide ten_v = (v << 3) + (v << 1);         /* 10 V < 10 * 2^1074 < 2^1152 */
    const wide mask = (((wide) 1) << s) - 1u;
    const int d = ds_fx_next_digit(&f, s);
    __CPROVER_assert((wide) d == (ten_v >> s), "LDET.3.2.8: digit = floor(10F / 2^s)");
    __CPROVER_assert(value(&f) == (ten_v & mask), "LDET.3.2.8: F' = 10F mod 2^s");
}

/*@cbmc ldet_3_2_8__cmp_half_full --bounds-check --pointer-check --undefined-shift-check --unwind 37 --unwinding-assertions */
void ldet_3_2_8__cmp_half_full(void)
{
    ds_fx_big_t f;
    const unsigned s = nondet_unsigned();
    __CPROVER_assume(s >= 1u && s <= 1074u);
    nondet_below(&f, s);
    const wide v = value(&f), half = ((wide) 1) << (s - 1u);
    const int c = ds_fx_cmp_half(&f, s);
    __CPROVER_assert(c == (v < half ? -1 : v == half ? 0 : 1),
                     "LDET.3.2.8: the remainder against half a step");
}

/* -------------------------------------------------------------------------
 * ldet_3_2_8__int_init_exact -- EXACT over the WHOLE domain.
 *
 * Every m < 2^53 and every e in 0..971 (so m * 2^e < 2^1024, the integer
 * doubles). No reference width limit applies: m * 2^e is (m * 2^(e%32)) placed
 * at limb e/32, and m * 2^(e%32) < 2^84 fits the reference. So this checks the
 * placement exactly for all inputs, and that nothing else is written. */
/*@cbmc ldet_3_2_8__int_init_exact --bounds-check --pointer-check --undefined-shift-check --unwind 37 --unwinding-assertions */
void ldet_3_2_8__int_init_exact(void)
{
    ds_fx_big_t n;
    const uint64_t m = nondet_u64();
    const unsigned e = nondet_unsigned();
    __CPROVER_assume(m < (((uint64_t) 1) << 53) && e <= 971u);
    ds_fx_int_init(&n, m, e);
    const unsigned li = e / 32u;
    const u128 got = (u128) n.w[li] | ((u128) n.w[li + 1u] << 32)
                   | ((u128) n.w[li + 2u] << 64);
    __CPROVER_assert(got == ((u128) m << (e % 32u)), "LDET.3.2.8: N = m * 2^e");
    for (unsigned i = 0; i < DS_FX_LIMBS; i++)
        if (i < li || i > li + 2u)
            __CPROVER_assert(n.w[i] == 0u, "LDET.3.2.8: no stray limb");
}

/* -------------------------------------------------------------------------
 * ldet_3_2_8__divmod_bounds -- BOUNDS: every N < 2^1024; the remainder is
 *   below 10^9 and N' < 2^1024 again.
 *
 * NO EXACT CHECK HERE, deliberately. That long division by 10^9 computes
 * floor(N / 10^9) and N mod 10^9 is an equivalence between a divider and a
 * multiplier, which is the classic worst case for a SAT solver: an exact
 * harness over N < 2^128 ran 38 minutes without an answer where
 * every other entry point here answers in seconds. It is a short induction
 * over the limbs for an unbounded prover, and it is proved there:
 * formal/idris/FixedRound.idr, ldet_3_2_8__divmod_sound (the pass divides)
 * and ldet_3_2_8__divmod_limb_fits (every quotient limb fits, so the uint64
 * steps do not wrap). The printf differential in test_float_fmt.c exercises
 * it to DBL_MAX besides. */
/*@cbmc ldet_3_2_8__divmod_bounds --bounds-check --pointer-check --undefined-shift-check --unwind 37 --unwinding-assertions */
void ldet_3_2_8__divmod_bounds(void)
{
    ds_fx_big_t n;
    nondet_below(&n, 1024u);
    const uint32_t r = ds_fx_divmod_1e9(&n);
    __CPROVER_assert(r < 1000000000u, "LDET.3.2.8: a base-10^9 chunk");
    __CPROVER_assert(below_pow2(&n, 1024u), "LDET.3.2.8: the quotient stays in range");
}

/* -------------------------------------------------------------------------
 * ldet_3_2_8__plan_rounds_p<N>, ldet_3_2_8__plan_short_fraction -- EXACT,
 * end to end over ds_fx_plan.
 *
 * The decision the whole formatter rests on, against the definition it
 * implements: with x = m * 2^-s and K = min(prec, s),
 *   q = floor(m * 10^K / 2^s)            the kept digits, as an integer
 *   r = m * 10^K mod 2^s                 what was dropped, scaled by 2^s
 *   up  <=> r > 2^(s-1), or r = 2^(s-1) and q is odd     (half to even)
 *   ip  =  floor(x) = q / 10^K
 *   last_non9 = the last of the K places that is not 9, else -1.
 *
 * ONE PRECISION PER ENTRY POINT, and why. The first form took s and prec both
 * symbolic, which made 10^K symbolic and every product in the reference a full
 * 64 x 64 multiplier; it ran 47 minutes at 1.5 GB without an answer. With prec
 * a constant, 10^K is a constant whenever s >= prec, every reference product
 * is a multiply by a constant, and m (53 bits) and s stay fully symbolic. The
 * specification is one function, plan_check, called from each entry point.
 *
 * Domain, per entry point ldet_3_2_8__plan_rounds_p<N>: every m < 2^53, every
 * s in max(1, N)..60, precision N for N in {0, 1, 2, 3, 6, 10, 18}. Together:
 * every double in [2^-60, 2^53) with a fraction, at those seven precisions,
 * and every carry shape -- none, into a place, through 9s, into the integer
 * part. ldet_3_2_8__plan_short_fraction covers s < prec, where the fraction
 * has fewer binary places than were asked for and nothing may round.
 * EXCLUDES s > 60, and the precisions 4, 5, 7..9, 11..17 and above 18: the
 * code is the same loop with another trip count, and the printf differential
 * covers them meanwhile. Bound: the plan's digit loop runs K <= 18 times;
 * --unwind 20.
 *
 * TWO STEPS, by cost. p0 and p1 are what the corpus ties ([LDET.3.2.8]'s
 * `checks.cbmc`, and FixedRound.idr's notes cite them alone); with the nine
 * primitives above they are `cbmc.stamp`. p2, p3, p6, p10, p18 and
 * plan_short_fraction are the
 * untied precision sweep after the `@cbmc-step sweep` marker below:
 * `cbmc-sweep.stamp`, run when named. Measured under
 * an 1800 s wall: p2 proves in 699 s; p6, p18 and
 * plan_short_fraction each run past 1800 s with no verdict, so the sweep is
 * above two hours on its own and above the bound in any order. What a sweep
 * entry point proves is the EXCLUDES sentence above with its precision put
 * back; nothing the corpus claims rests on it. plan_short_fraction's cost is
 * the symbolic 10^K its own comment names. */

/* WHERE THE CARRY STOPS, without a divider and without a symbolic power of
   ten: for each candidate stop L (K is a constant here, so L ranges over
   constants), last_non9 = L must mean the places after L are 9 and place L
   is not. Each floor is a nondet integer CONSTRAINED by its bracket,
   a * P <= frac < (a + 1) * P, which exactly one value satisfies -- so the
   assumes can never be unsatisfiable and cannot make the check pass
   vacuously. Products are 128-bit, so a wrapped product cannot satisfy a
   bracket. */
static void check_stop(u128 frac, unsigned K, int last_non9)
{
    if (last_non9 < 0) {
        u128 all9 = 1;
        for (unsigned i = 0; i < K; i++) all9 *= 10u;
        __CPROVER_assert(frac == all9 - 1u, "LDET.3.2.8: every place is 9");
        return;
    }
    __CPROVER_assert((unsigned) last_non9 < K, "LDET.3.2.8: the stop is a kept place");
    u128 P = 1;                                    /* 10^(K - 1 - L), built by constants */
    for (unsigned L = K; L-- > 0; ) {
        if ((unsigned) last_non9 == L) {
            const u128 a = (u128) nondet_u64(), b = (u128) nondet_u64();
            __CPROVER_assume(a * P <= frac && frac < (a + 1u) * P);   /* a = floor(frac / P) */
            __CPROVER_assume(b * 10u <= a && a < (b + 1u) * 10u);     /* b = floor(a / 10) */
            __CPROVER_assert(frac - a * P == P - 1u, "LDET.3.2.8: the places after the stop are 9");
            __CPROVER_assert(a - b * 10u != 9u, "LDET.3.2.8: the place at the stop is not 9");
        }
        P *= 10u;
    }
}

/* the contract of ds_fx_plan, for one (m, s, prec) */
static void plan_check(uint64_t m, unsigned s, unsigned prec)
{
    ds_fx_big_t f;
    ds_fx_plan_t p;
    ds_fx_plan(&f, m, s, prec, &p);

    const unsigned K = prec < s ? prec : s;
    u128 pow10 = 1;
    for (unsigned i = 0; i < K; i++) pow10 *= 10u;
    const u128 scaled = (u128) m * pow10;
    const u128 q = scaled >> s;
    const u128 r = scaled & ((((u128) 1) << s) - 1u);
    const u128 half = ((u128) 1) << (s - 1u);
    const int up = r > half || (r == half && (q & 1u));

    __CPROVER_assert(p.kdig == K, "LDET.3.2.8: K = min(prec, s)");
    /* ip = floor(q / 10^K), by its bracket: no 128-bit divider */
    __CPROVER_assert((u128) p.ip * pow10 <= q && q < ((u128) p.ip + 1u) * pow10,
                     "LDET.3.2.8: ip = floor(x)");
    __CPROVER_assert(p.up == up, "LDET.3.2.8: rounds half to even");
    check_stop(q - (u128) p.ip * pow10, K, p.last_non9);
}

#define PLAN_AT(N)                                                          \
    void ldet_3_2_8__plan_rounds_p##N(void)                                 \
    {                                                                       \
        const uint64_t m = nondet_u64();                                    \
        const unsigned s = nondet_unsigned();                               \
        __CPROVER_assume(m < (((uint64_t) 1) << 53));                       \
        __CPROVER_assume(s >= 1u && s >= (N) && s <= 60u);                  \
        plan_check(m, s, (N));                                              \
    }

/*@cbmc ldet_3_2_8__plan_rounds_p0 --bounds-check --pointer-check --undefined-shift-check --unwind 20 --unwinding-assertions */
PLAN_AT(0)
/*@cbmc ldet_3_2_8__plan_rounds_p1 --bounds-check --pointer-check --undefined-shift-check --unwind 20 --unwinding-assertions */
PLAN_AT(1)

/* The untied precision sweep, `cbmc-sweep.stamp`: everything from here to
   the end of the file. See TWO STEPS above. */
/*@cbmc-step sweep */
/*@cbmc ldet_3_2_8__plan_rounds_p2 --bounds-check --pointer-check --undefined-shift-check --unwind 20 --unwinding-assertions */
PLAN_AT(2)
/*@cbmc ldet_3_2_8__plan_rounds_p3 --bounds-check --pointer-check --undefined-shift-check --unwind 20 --unwinding-assertions */
PLAN_AT(3)
/*@cbmc ldet_3_2_8__plan_rounds_p6 --bounds-check --pointer-check --undefined-shift-check --unwind 20 --unwinding-assertions */
PLAN_AT(6)
/*@cbmc ldet_3_2_8__plan_rounds_p10 --bounds-check --pointer-check --undefined-shift-check --unwind 20 --unwinding-assertions */
PLAN_AT(10)
/*@cbmc ldet_3_2_8__plan_rounds_p18 --bounds-check --pointer-check --undefined-shift-check --unwind 20 --unwinding-assertions */
PLAN_AT(18)

/* s < prec: the fraction has s binary places, so s decimal ones, and the
   plan must keep all of them and round nothing. prec 19 with s in 1..18;
   10^K is symbolic here but small (K <= 18). */
/*@cbmc ldet_3_2_8__plan_short_fraction --bounds-check --pointer-check --undefined-shift-check --unwind 20 --unwinding-assertions */
void ldet_3_2_8__plan_short_fraction(void)
{
    const uint64_t m = nondet_u64();
    const unsigned s = nondet_unsigned();
    __CPROVER_assume(m < (((uint64_t) 1) << 53));
    __CPROVER_assume(s >= 1u && s <= 18u);
    plan_check(m, s, 19u);
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_helpers.c -- the helpers a row's libds.a calls, called as it calls them
 * ([NDET.1.4] part 2).
 *
 *     ds_helpers SYMBOL < operands      (one case a line, as testfloat_gen writes)
 *     ds_helpers fenv | planted_fenv    (no input)
 *
 * Part 2 of "shown": the helper set the link actually uses, `nm -u` of the
 * row's libds and CORE-MATH objects, every helper part 1 does not exercise
 * covered. The release's helper check derives the set from the row's
 * archive, never by hand, and classifies each symbol as covered (a case
 * here) or declared not arithmetic (its table, with reasons); anything else
 * fails. This program is the
 * covered half. It decides nothing: for each case it writes the operands, the
 * helper's result and the exception flags it raised, and the driver judges
 * them, against SoftFloat through testfloat_ver for the rounding functions,
 * and against exact arithmetic in Python for the rest.
 *
 * WHICH SYMBOL IS CALLED. The helper itself, by its own name, through a
 * pointer, between feclearexcept() and fetestexcept(): compiled with libds's
 * flags and -fno-builtin, so `floor` is the C library's floor, not an
 * instruction the compiler chose for this file. The compiler-runtime helpers
 * (`__multi3`, `__floatuntidf`, ...) and NetBSD's classification functions
 * are declared here and called directly. Each case is compiled in only when
 * the row's archive references the symbol (`-DDS_HAVE_<symbol>`, from the
 * derivation), so this links on every row and tests what that row uses.
 *
 * WHAT IS LEFT OUT. A case with a signalling-NaN f64 operand, while Claim A
 * stands (ds_testfloat_io.h), counted by the line this writes to stderr.
 * Nothing else: the operands the driver sends are each helper's domain, and
 * where C or the runtime ABI leaves a result unspecified (an out-of-range
 * llround, a zero to __clzdi2) the driver's reference says so, case by case.
 *
 * THE NEGATIVE FIXTURES ([STYL.5.10.5]): the
 * `planted_*` entries are wrong helpers of each kind the driver judges, and
 * `planted_fenv` the environment scenario with feupdateenv replaced by
 * fesetenv. They call no symbol under test, so they are present on every
 * row, and the driver fails unless each is refused.
 */
#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ds_testfloat_io.h"

#ifndef __SIZEOF_INT128__
#error "ds_helpers needs a 128-bit integer for the 128-bit helpers' operands"
#endif
typedef unsigned __int128 u128;
typedef __int128 i128;

/* ---- the runtime-ABI helpers, as libgcc and compiler-rt declare them ---- */

#ifdef DS_HAVE___popcountdi2
extern int __popcountdi2(long long);
#endif
#ifdef DS_HAVE___clzdi2
extern int __clzdi2(long long);
#endif
#ifdef DS_HAVE___ctzdi2
extern int __ctzdi2(long long);
#endif
#ifdef DS_HAVE___ashlti3
extern i128 __ashlti3(i128, int);
#endif
#ifdef DS_HAVE___lshrti3
extern i128 __lshrti3(i128, int);
#endif
#ifdef DS_HAVE___multi3
extern i128 __multi3(i128, i128);
#endif
#ifdef DS_HAVE___floatuntidf
extern double __floatuntidf(u128);
#endif
#ifdef DS_HAVE___isnand
extern int __isnand(double);
#endif
#ifdef DS_HAVE___isinfd
extern int __isinfd(double);
#endif
#ifdef DS_HAVE___isfinited
extern int __isfinited(double);
#endif
#ifdef DS_HAVE___signbitd
extern int __signbitd(double);
#endif

/* ---- each case: operands in, result out, as 128-bit words ------------- */

typedef u128 (*op_fn)(const u128 *a);

#define F(i) dbl((uint64_t) a[i])

#ifdef DS_HAVE_floor
static u128 op_floor(const u128 *a) { return bits(floor(F(0))); }
#endif
#ifdef DS_HAVE_ceil
static u128 op_ceil(const u128 *a) { return bits(ceil(F(0))); }
#endif
#ifdef DS_HAVE_trunc
static u128 op_trunc(const u128 *a) { return bits(trunc(F(0))); }
#endif
#ifdef DS_HAVE_round
static u128 op_round(const u128 *a) { return bits(round(F(0))); }
#endif
#ifdef DS_HAVE_rint
static u128 op_rint(const u128 *a) { return bits(rint(F(0))); }
#endif
#ifdef DS_HAVE_llround
static u128 op_llround(const u128 *a) { return (uint64_t) (long long) llround(F(0)); }
#endif
#ifdef DS_HAVE_fmax
static u128 op_fmax(const u128 *a) { return bits(fmax(F(0), F(1))); }
#endif
#ifdef DS_HAVE_fmin
static u128 op_fmin(const u128 *a) { return bits(fmin(F(0), F(1))); }
#endif
#ifdef DS_HAVE___isnand
static u128 op_isnand(const u128 *a) { return (uint32_t) __isnand(F(0)); }
#endif
#ifdef DS_HAVE___isinfd
static u128 op_isinfd(const u128 *a) { return (uint32_t) __isinfd(F(0)); }
#endif
#ifdef DS_HAVE___isfinited
static u128 op_isfinited(const u128 *a) { return (uint32_t) __isfinited(F(0)); }
#endif
#ifdef DS_HAVE___signbitd
static u128 op_signbitd(const u128 *a) { return (uint32_t) __signbitd(F(0)); }
#endif
#ifdef DS_HAVE___popcountdi2
static u128 op_popcountdi2(const u128 *a) { return (uint32_t) __popcountdi2((long long) (uint64_t) a[0]); }
#endif
#ifdef DS_HAVE___clzdi2
static u128 op_clzdi2(const u128 *a) { return (uint32_t) __clzdi2((long long) (uint64_t) a[0]); }
#endif
#ifdef DS_HAVE___ctzdi2
static u128 op_ctzdi2(const u128 *a) { return (uint32_t) __ctzdi2((long long) (uint64_t) a[0]); }
#endif
#ifdef DS_HAVE___ashlti3
static u128 op_ashlti3(const u128 *a) { return (u128) __ashlti3((i128) a[0], (int) a[1]); }
#endif
#ifdef DS_HAVE___lshrti3
static u128 op_lshrti3(const u128 *a) { return (u128) __lshrti3((i128) a[0], (int) a[1]); }
#endif
#ifdef DS_HAVE___multi3
static u128 op_multi3(const u128 *a) { return (u128) __multi3((i128) a[0], (i128) a[1]); }
#endif
#ifdef DS_HAVE___floatuntidf
static u128 op_floatuntidf(const u128 *a) { return bits(__floatuntidf(a[0])); }
#endif

/* ---- the planted wrong helpers, one of each kind the driver judges ---- */

/* floor as truncation: wrong for every negative non-integer. */
static u128 planted_floor(const u128 *a) { return bits(trunc(F(0))); }

/* fmax as a comparison: returns the NaN where fmax returns the number. */
static u128 planted_fmax(const u128 *a) { return bits(F(0) > F(1) ? F(0) : F(1)); }

/* signbit as a comparison: wrong for -0 and for a NaN with its sign set. */
static u128 planted_signbitd(const u128 *a) { return (uint32_t) (F(0) < 0.0); }

/* A 128-bit product missing the high-by-low cross term. */
static u128 planted_multi3(const u128 *a)
{
    uint64_t alo = (uint64_t) a[0], blo = (uint64_t) a[1], bhi = (uint64_t) (a[1] >> 64);
    return (u128) alo * blo + ((u128) (alo * bhi) << 64);
}

/* u128 to double in two roundings, each half on its own: a defect only
   targeted draws find. */
static u128 planted_floatuntidf(const u128 *a)
{
    return bits((double) (uint64_t) (a[0] >> 64) * 18446744073709551616.0
                + (double) (uint64_t) a[0]);
}

#undef F

/* ---- the table: the symbol, its operands' and result's widths in hex
        digits (32 for a 128-bit word, 1 for a Bool), and whether the
        operands are f64 ---------------------------------------------------- */

struct helper {
    const char *name;
    op_fn op;
    int n;
    int in_width[2];
    int float_in;
    int out_width;
};

static const struct helper HELPERS[] = {
#ifdef DS_HAVE_floor
    { "floor",         op_floor,         1, {16},     1, 16 },
#endif
#ifdef DS_HAVE_ceil
    { "ceil",          op_ceil,          1, {16},     1, 16 },
#endif
#ifdef DS_HAVE_trunc
    { "trunc",         op_trunc,         1, {16},     1, 16 },
#endif
#ifdef DS_HAVE_round
    { "round",         op_round,         1, {16},     1, 16 },
#endif
#ifdef DS_HAVE_rint
    { "rint",          op_rint,          1, {16},     1, 16 },
#endif
#ifdef DS_HAVE_llround
    { "llround",       op_llround,       1, {16},     1, 16 },
#endif
#ifdef DS_HAVE_fmax
    { "fmax",          op_fmax,          2, {16, 16}, 1, 16 },
#endif
#ifdef DS_HAVE_fmin
    { "fmin",          op_fmin,          2, {16, 16}, 1, 16 },
#endif
#ifdef DS_HAVE___isnand
    { "__isnand",      op_isnand,        1, {16},     1,  8 },
#endif
#ifdef DS_HAVE___isinfd
    { "__isinfd",      op_isinfd,        1, {16},     1,  8 },
#endif
#ifdef DS_HAVE___isfinited
    { "__isfinited",   op_isfinited,     1, {16},     1,  8 },
#endif
#ifdef DS_HAVE___signbitd
    { "__signbitd",    op_signbitd,      1, {16},     1,  8 },
#endif
#ifdef DS_HAVE___popcountdi2
    { "__popcountdi2", op_popcountdi2,   1, {16},     0,  8 },
#endif
#ifdef DS_HAVE___clzdi2
    { "__clzdi2",      op_clzdi2,        1, {16},     0,  8 },
#endif
#ifdef DS_HAVE___ctzdi2
    { "__ctzdi2",      op_ctzdi2,        1, {16},     0,  8 },
#endif
#ifdef DS_HAVE___ashlti3
    { "__ashlti3",     op_ashlti3,       2, {32, 8},  0, 32 },
#endif
#ifdef DS_HAVE___lshrti3
    { "__lshrti3",     op_lshrti3,       2, {32, 8},  0, 32 },
#endif
#ifdef DS_HAVE___multi3
    { "__multi3",      op_multi3,        2, {32, 32}, 0, 32 },
#endif
#ifdef DS_HAVE___floatuntidf
    { "__floatuntidf", op_floatuntidf,   1, {32},     0, 16 },
#endif
    { "planted_floor",       planted_floor,       1, {16},     1, 16 },
    { "planted_fmax",        planted_fmax,        2, {16, 16}, 1, 16 },
    { "planted_signbitd",    planted_signbitd,    1, {16},     1,  8 },
    { "planted_multi3",      planted_multi3,      2, {32, 32}, 0, 32 },
    { "planted_floatuntidf", planted_floatuntidf, 1, {32},     0, 16 },
};

/* C11 F.10.6 lets these raise inexact or not (ceil's "or nearbyint instead
   of rint"), so that one flag is dropped from what they raised and the driver
   judges them `-notexact`; rint's inexact is C's, and is kept. */
static int inexact_unspecified(const char *name)
{
    static const char *const names[] = { "floor", "ceil", "trunc", "round", "planted_floor" };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
        if (strcmp(name, names[i]) == 0) return 1;
    return 0;
}

/* ---- the floating-point environment: a scenario, observed --------------

   CORE-MATH and libds save, change and restore the environment around their
   arithmetic ([LDET.3.6.1]). What a correct fenv does is stated by C11 7.6;
   this performs each call the archive references and writes what it
   observed, one `key value` line each, and the driver holds every line to C's
   statement. `planted` replaces feupdateenv with fesetenv, which drops the
   exceptions raised under feholdexcept. */

static volatile double one = 1.0, three = 3.0;

static void observe(const char *key, long value)
{
    printf("%s %ld\n", key, value);
}

static void fenv_scenario(int planted)
{
    fenv_t env;
    fexcept_t saved;

    observe("FE_ALL_EXCEPT", ALL_EXCEPTIONS);
    observe("FE_INEXACT", FE_INEXACT);
    observe("FE_UNDERFLOW", FE_UNDERFLOW);
    observe("FE_OVERFLOW", FE_OVERFLOW);
    observe("FE_DIVBYZERO", FE_DIVBYZERO);
    observe("FE_INVALID", FE_INVALID);
    observe("FE_TONEAREST", FE_TONEAREST);
    observe("FE_DOWNWARD", FE_DOWNWARD);
    observe("FE_UPWARD", FE_UPWARD);
    observe("FE_TOWARDZERO", FE_TOWARDZERO);

    observe("round.initial", fegetround());
    static const int modes[] = { FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO };
    for (size_t i = 0; i < sizeof modes / sizeof modes[0]; i++) {
        char key[48];
        snprintf(key, sizeof key, "round.set.%d", modes[i]);
        observe(key, fesetround(modes[i]));
        snprintf(key, sizeof key, "round.get.%d", modes[i]);
        observe(key, fegetround());
        /* 1/3 is inexact either side of zero: its last bit says the mode. */
        snprintf(key, sizeof key, "third.%d", modes[i]);
        observe(key, (long) (bits(one / three) & 0xFFFF));
        snprintf(key, sizeof key, "negthird.%d", modes[i]);
        observe(key, (long) (bits(-one / three) & 0xFFFF));
    }
    fesetround(FE_TONEAREST);

    static const int each[] = { FE_INEXACT, FE_UNDERFLOW, FE_OVERFLOW, FE_DIVBYZERO, FE_INVALID };
    for (size_t i = 0; i < sizeof each / sizeof each[0]; i++) {
        char key[48];
        feclearexcept(ALL_EXCEPTIONS);
        snprintf(key, sizeof key, "raise.%d", each[i]);
        observe(key, feraiseexcept(each[i]));
        snprintf(key, sizeof key, "test.%d", each[i]);
        observe(key, fetestexcept(ALL_EXCEPTIONS));
        feclearexcept(each[i]);
        snprintf(key, sizeof key, "cleared.%d", each[i]);
        observe(key, fetestexcept(ALL_EXCEPTIONS));
    }

    feclearexcept(ALL_EXCEPTIONS);
    feraiseexcept(FE_INEXACT | FE_OVERFLOW);
    observe("flag.get", fegetexceptflag(&saved, ALL_EXCEPTIONS));
    feclearexcept(ALL_EXCEPTIONS);
    observe("flag.between", fetestexcept(ALL_EXCEPTIONS));
    observe("flag.set", fesetexceptflag(&saved, ALL_EXCEPTIONS));
    observe("flag.after", fetestexcept(ALL_EXCEPTIONS));

    feclearexcept(ALL_EXCEPTIONS);
    fesetround(FE_DOWNWARD);
    feraiseexcept(FE_DIVBYZERO);
    observe("env.get", fegetenv(&env));
    fesetround(FE_TONEAREST);
    feclearexcept(ALL_EXCEPTIONS);
    observe("env.set", fesetenv(&env));
    observe("env.round", fegetround());
    observe("env.flags", fetestexcept(ALL_EXCEPTIONS));

    feclearexcept(ALL_EXCEPTIONS);
    fesetround(FE_UPWARD);
    feraiseexcept(FE_INVALID);
    observe("hold", feholdexcept(&env));
    observe("hold.flags", fetestexcept(ALL_EXCEPTIONS));
    observe("hold.round", fegetround());
    feraiseexcept(FE_UNDERFLOW);
    observe("update", planted ? fesetenv(&env) : feupdateenv(&env));
    observe("update.flags", fetestexcept(ALL_EXCEPTIONS));
    observe("update.round", fegetround());

    observe("default.set", fesetenv(FE_DFL_ENV));
    observe("default.round", fegetround());
    observe("default.flags", fetestexcept(ALL_EXCEPTIONS));
}

int main(int argc, char **argv)
{
    if (argc == 2 && (strcmp(argv[1], "fenv") == 0 || strcmp(argv[1], "planted_fenv") == 0)) {
        fenv_scenario(argv[1][0] == 'p');
        return fflush(stdout) == 0 ? 0 : 2;
    }
    const struct helper *h = NULL;
    const int flags_from_input = argc == 3 && strcmp(argv[1], "--flags-from-input") == 0;
    if (argc == 2 || flags_from_input)
        for (size_t i = 0; i < sizeof HELPERS / sizeof HELPERS[0]; i++)
            if (strcmp(argv[argc - 1], HELPERS[i].name) == 0) h = &HELPERS[i];
    if (h == NULL) {
        fprintf(stderr, "usage: ds_helpers [--flags-from-input] SYMBOL | fenv | "
                        "planted_fenv (a symbol this row's archive references, or a "
                        "planted_* fixture)\n");
        return 2;
    }
    if (fesetround(FE_TONEAREST) != 0) {
        fprintf(stderr, "ds_helpers: cannot set round to nearest even\n");
        return 2;
    }
    static char inbuf[1 << 16], outbuf[1 << 16];
    setvbuf(stdin, inbuf, _IOFBF, sizeof inbuf);
    setvbuf(stdout, outbuf, _IOFBF, sizeof outbuf);
    const int kept_flags = inexact_unspecified(h->name) ? ALL_EXCEPTIONS & ~FE_INEXACT
                                                        : ALL_EXCEPTIONS;

    unsigned long long lines = 0, tested = 0, skipped_snan = 0;
    char line[160], out[200];
    while (fgets(line, sizeof line, stdin)) {
        lines++;
        u128 a[2];
        const char *p = line;
        uint64_t expected_flags = 0;
        for (int i = 0; i < h->n; i++) {
            uint64_t hi, lo;
            char sep = i + 1 < h->n || flags_from_input ? ' ' : '\n';
            if (!read_hex128(&p, h->in_width[i], sep, &hi, &lo)
                || (flags_from_input && i + 1 == h->n
                    && !read_expected_flags(&p, h->out_width, &expected_flags))) {
                fprintf(stderr, "ds_helpers: %s: line %llu is not %d operand(s) of the "
                                "widths it takes%s: %s", h->name, lines, h->n,
                        flags_from_input ? ", a result and flags" : "", line);
                return 2;
            }
            a[i] = (u128) hi << 64 | lo;
        }
        int snan = 0;
        for (int i = 0; h->float_in && i < h->n; i++) snan |= is_signalling_nan((uint64_t) a[i]);
        if (snan) { skipped_snan++; continue; }

        feclearexcept(ALL_EXCEPTIONS);
        u128 z = h->op(a);
        int raised = fetestexcept(ALL_EXCEPTIONS) & kept_flags;
        tested++;

        char *q = out;
        for (int i = 0; i < h->n; i++) {
            q = write_hex128(q, (uint64_t) (a[i] >> 64), (uint64_t) a[i], h->in_width[i]);
            *q++ = ' ';
        }
        q = write_hex128(q, (uint64_t) (z >> 64), (uint64_t) z, h->out_width);
        *q++ = ' ';
        q = write_hex(q, flags_from_input ? expected_flags : softfloat_flags(raised), 2);
        *q++ = '\n';
        fwrite(out, 1, (size_t) (q - out), stdout);
    }
    if (ferror(stdin)) {
        fprintf(stderr, "ds_helpers: %s: a read error after %llu lines\n", h->name, lines);
        return 2;
    }
    if (fflush(stdout) != 0 || ferror(stdout)) {
        fprintf(stderr, "ds_helpers: %s: a write error after %llu lines\n", h->name, lines);
        return DS_TESTFLOAT_WRITE_ERROR;
    }
    fprintf(stderr, "ds_helpers: %s read=%llu tested=%llu skipped_snan=%llu\n",
            h->name, lines, tested, skipped_snan);
    return 0;
}

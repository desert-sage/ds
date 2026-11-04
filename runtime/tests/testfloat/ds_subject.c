/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_subject.c -- a row's double arithmetic as libds computes it, between
 * TestFloat's generator and its verifier ([NDET.1.4]).
 *
 *     testfloat_gen -level L <type> [n] | ds_subject FUNCTION | testfloat_ver ... FUNCTION
 *
 * [NDET.1.4] admits a row's doubles "only once [they have] been shown correct
 * on that target, against the archive that row ships", and part 1 of
 * "shown" is TestFloat against SoftFloat.
 * TestFloat's own pipeline for an implementation it does not link is this one:
 * testfloat_gen writes each case's operands, the implementation appends its
 * result and exception flags, and testfloat_ver recomputes the case with
 * SoftFloat and reports every difference. This program is the middle stage.
 * It never sees an expected result, and decides nothing about correctness:
 * SoftFloat is the reference and testfloat_ver the comparison, both unmodified.
 *
 * WHAT "AS LIBDS COMPUTES IT" MEANS. On a hosted row libds has no function for
 * `+`: the compiler emits the operation inline, with libds's flags. So each
 * operation is written the way libds writes it, in a translation unit compiled
 * with libds's flags (the driver's, which a pin holds to libds.build's
 * archive compile), and linked against the row's libds.a for what libds supplies:
 *
 *   - f64_mulAdd is ds_libm_fma, libds's own fma on every row ([IARC.7.14]),
 *     never the C library's, which not every libc rounds once;
 *   - f64_sqrt and f64_roundToInt are the C library's sqrt() and rint(),
 *     which libds's builtins call (builtins.c);
 *   - the comparisons are C's operators, `==` quiet and `<`, `<=` signalling
 *     (C11 Annex F), with isless() and islessequal() for the quiet forms and
 *     `a <= b && a >= b` for the signalling equality C has no operator for;
 *   - the conversions are C casts: to an integer, truncation (testfloat_ver's
 *     `-rminMag -exact`).
 *
 * Each operation is a function of its own, called through a pointer between
 * feclearexcept() and fetestexcept(), so the compiler can move no part of it
 * out from between the two. Flags are read from <fenv.h>, in round to nearest
 * even, the only mode the check runs. On a row with no exception flags
 * (wasm32), `--flags-from-input` judges results only (ds_testfloat_io.h).
 *
 * WHAT IT LEAVES OUT (every bound states what it excludes). A case is
 * skipped, never computed and never
 * passed on, when
 *
 *   - any f64 operand is a signalling NaN, while Claim A stands: that no
 *     Float either runtime computes on is one. On amd64, musl's fma returns
 *     an sNaN addend unquieted with no invalid flag, and glibc's rint returns
 *     an sNaN unquieted;
 *   - the function converts to ui32 or ui64 and the operand's integral part
 *     is not representable in it (NaN, an infinity, -1 or below, 2^32 or
 *     2^64 and above), where C leaves the conversion undefined (C11
 *     6.3.1.4p1). The release's float-to-unsigned census is what this rests
 *     on: no such
 *     conversion is compiled unless declared in range, in each row's archive
 *     and the Mercury runtime's generated C. gcc on x86 raises no invalid flag
 *     there. In-range unsigned conversions are tested.
 *
 * Both are judged on the operand's bits, before any floating-point operation.
 * Every skipped case is counted, by reason, on the last line this writes to
 * stderr; the driver prints it and holds it against testfloat_ver's own count.
 * If Claim A is refuted, or the census refuses a conversion, that exclusion
 * goes.
 *
 * THE NEGATIVE FIXTURE ([STYL.5.10.5]). Compiled with DS_TESTFLOAT_PLANTED_FMA, f64_mulAdd is `x*y + z`: two
 * roundings where fma has one, the generic fma picolibc and newlib ship. The
 * driver builds that subject too, on every run, and fails unless testfloat_ver
 * refuses it. The exclusions' own fixture is the driver's FILTER_CASES.
 */
#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core_math.h"   /* ds_libm_fma */
#include "ds_testfloat_io.h"

#ifdef DS_TESTFLOAT_PLANTED_FMA
/* The planted wrong helper: two roundings. -ffp-contract=off keeps the
   compiler from fusing it back into the fma it stands in for. */
static double subj_fma(double x, double y, double z)
{
    return x * y + z;
}
#else
#define subj_fma ds_libm_fma
#endif

/* ---- the operations, each on its operands' bits ----------------------- */

typedef uint64_t (*op_fn)(const uint64_t *a);

static uint64_t op_ui32_to_f64(const uint64_t *a) { return bits((double) (uint32_t) a[0]); }
static uint64_t op_ui64_to_f64(const uint64_t *a) { return bits((double) a[0]); }
static uint64_t op_i32_to_f64(const uint64_t *a)  { return bits((double) (int32_t) (uint32_t) a[0]); }
static uint64_t op_i64_to_f64(const uint64_t *a)  { return bits((double) (int64_t) a[0]); }

static uint64_t op_f64_to_ui32(const uint64_t *a) { return (uint32_t) dbl(a[0]); }
static uint64_t op_f64_to_ui64(const uint64_t *a) { return (uint64_t) dbl(a[0]); }
static uint64_t op_f64_to_i32(const uint64_t *a)  { return (uint32_t) (int32_t) dbl(a[0]); }
static uint64_t op_f64_to_i64(const uint64_t *a)  { return (uint64_t) (int64_t) dbl(a[0]); }

static uint64_t op_f64_roundToInt(const uint64_t *a) { return bits(rint(dbl(a[0]))); }
static uint64_t op_f64_sqrt(const uint64_t *a)       { return bits(sqrt(dbl(a[0]))); }

static uint64_t op_f64_add(const uint64_t *a) { return bits(dbl(a[0]) + dbl(a[1])); }
static uint64_t op_f64_sub(const uint64_t *a) { return bits(dbl(a[0]) - dbl(a[1])); }
static uint64_t op_f64_mul(const uint64_t *a) { return bits(dbl(a[0]) * dbl(a[1])); }
static uint64_t op_f64_div(const uint64_t *a) { return bits(dbl(a[0]) / dbl(a[1])); }

static uint64_t op_f64_mulAdd(const uint64_t *a)
{
    return bits(subj_fma(dbl(a[0]), dbl(a[1]), dbl(a[2])));
}

static uint64_t op_f64_eq(const uint64_t *a) { return dbl(a[0]) == dbl(a[1]); }
static uint64_t op_f64_le(const uint64_t *a) { return dbl(a[0]) <= dbl(a[1]); }
static uint64_t op_f64_lt(const uint64_t *a) { return dbl(a[0]) < dbl(a[1]); }

static uint64_t op_f64_eq_signaling(const uint64_t *a)
{
    double x = dbl(a[0]), y = dbl(a[1]);
    return x <= y && x >= y;
}

static uint64_t op_f64_le_quiet(const uint64_t *a) { return islessequal(dbl(a[0]), dbl(a[1])); }
static uint64_t op_f64_lt_quiet(const uint64_t *a) { return isless(dbl(a[0]), dbl(a[1])); }

/* ---- the table: testfloat_ver's name, the operands' and result's widths
        in hex digits (1 is a Bool), and the unsigned limit ---------------- */

/* The bits of 2^32 and 2^64: an operand at or above either, or of any NaN or
   infinity of either sign, or at or below -1, has no ui32 or ui64 value. */
#define TWO_POW_32 UINT64_C(0x41F0000000000000)
#define TWO_POW_64 UINT64_C(0x43F0000000000000)

struct function {
    const char *name;
    op_fn op;
    int n;              /* operands */
    int in_width;       /* each operand: 8 or 16 */
    int float_in;       /* the operands are f64 */
    int out_width;      /* 1, 8 or 16 */
    uint64_t ui_limit;  /* converts to an unsigned type: TWO_POW_32 or _64 */
};

static const struct function FUNCTIONS[] = {
    { "ui32_to_f64",      op_ui32_to_f64,      1,  8, 0, 16, 0 },
    { "ui64_to_f64",      op_ui64_to_f64,      1, 16, 0, 16, 0 },
    { "i32_to_f64",       op_i32_to_f64,       1,  8, 0, 16, 0 },
    { "i64_to_f64",       op_i64_to_f64,       1, 16, 0, 16, 0 },
    { "f64_to_ui32",      op_f64_to_ui32,      1, 16, 1,  8, TWO_POW_32 },
    { "f64_to_ui64",      op_f64_to_ui64,      1, 16, 1, 16, TWO_POW_64 },
    { "f64_to_i32",       op_f64_to_i32,       1, 16, 1,  8, 0 },
    { "f64_to_i64",       op_f64_to_i64,       1, 16, 1, 16, 0 },
    { "f64_roundToInt",   op_f64_roundToInt,   1, 16, 1, 16, 0 },
    { "f64_sqrt",         op_f64_sqrt,         1, 16, 1, 16, 0 },
    { "f64_add",          op_f64_add,          2, 16, 1, 16, 0 },
    { "f64_sub",          op_f64_sub,          2, 16, 1, 16, 0 },
    { "f64_mul",          op_f64_mul,          2, 16, 1, 16, 0 },
    { "f64_div",          op_f64_div,          2, 16, 1, 16, 0 },
    { "f64_mulAdd",       op_f64_mulAdd,       3, 16, 1, 16, 0 },
    { "f64_eq",           op_f64_eq,           2, 16, 1,  1, 0 },
    { "f64_le",           op_f64_le,           2, 16, 1,  1, 0 },
    { "f64_lt",           op_f64_lt,           2, 16, 1,  1, 0 },
    { "f64_eq_signaling", op_f64_eq_signaling, 2, 16, 1,  1, 0 },
    { "f64_le_quiet",     op_f64_le_quiet,     2, 16, 1,  1, 0 },
    { "f64_lt_quiet",     op_f64_lt_quiet,     2, 16, 1,  1, 0 },
};

/* ---- the unsigned exclusion, on bits (the signalling-NaN one is
        ds_testfloat_io.h's, shared with ds_helpers.c) -------------------- */

static int unsigned_out_of_range(uint64_t b, uint64_t limit)
{
    if (b >> 63)    /* -1 or below, -inf, a NaN with its sign bit set */
        return (b & UINT64_C(0x7FFFFFFFFFFFFFFF)) >= UINT64_C(0x3FF0000000000000);
    return b >= limit;   /* the limit or above, +inf, a NaN */
}

int main(int argc, char **argv)
{
    const struct function *f = NULL;
    const int flags_from_input = argc == 3 && strcmp(argv[1], "--flags-from-input") == 0;
    if (argc == 2 || flags_from_input)
        for (size_t i = 0; i < sizeof FUNCTIONS / sizeof FUNCTIONS[0]; i++)
            if (strcmp(argv[argc - 1], FUNCTIONS[i].name) == 0) f = &FUNCTIONS[i];
    if (f == NULL) {
        fprintf(stderr, "usage: ds_subject [--flags-from-input] FUNCTION (testfloat_ver's "
                        "name: f64_add, f64_to_ui32, ...)\n");
        return 2;
    }
    if (fesetround(FE_TONEAREST) != 0) {
        fprintf(stderr, "ds_subject: cannot set round to nearest even\n");
        return 2;
    }
    static char inbuf[1 << 16], outbuf[1 << 16];
    setvbuf(stdin, inbuf, _IOFBF, sizeof inbuf);
    setvbuf(stdout, outbuf, _IOFBF, sizeof outbuf);

    unsigned long long lines = 0, tested = 0, skipped_snan = 0, skipped_unsigned = 0;
    char line[128], out[160];
    while (fgets(line, sizeof line, stdin)) {
        lines++;
        uint64_t a[3];
        const char *p = line;
        uint64_t expected_flags = 0;
        for (int i = 0; i < f->n; i++) {
            char sep = i + 1 < f->n || flags_from_input ? ' ' : '\n';
            if (!read_hex(&p, f->in_width, sep, &a[i])
                || (flags_from_input && i + 1 == f->n
                    && !read_expected_flags(&p, f->out_width, &expected_flags))) {
                fprintf(stderr, "ds_subject: %s: line %llu is not %d operand(s) of %d hex "
                                "digits%s: %s", f->name, lines, f->n, f->in_width,
                        flags_from_input ? ", a result and flags" : "", line);
                return 2;
            }
        }
        int snan = 0;
        for (int i = 0; f->float_in && i < f->n; i++) snan |= is_signalling_nan(a[i]);
        if (snan) { skipped_snan++; continue; }
        if (f->ui_limit && unsigned_out_of_range(a[0], f->ui_limit)) {
            skipped_unsigned++;
            continue;
        }

        feclearexcept(ALL_EXCEPTIONS);
        uint64_t z = f->op(a);
        int raised = fetestexcept(ALL_EXCEPTIONS);
        tested++;

        char *q = out;
        for (int i = 0; i < f->n; i++) {
            q = write_hex(q, a[i], f->in_width);
            *q++ = ' ';
        }
        if (f->out_width == 1) *q++ = z ? '1' : '0';
        else q = write_hex(q, z, f->out_width);
        *q++ = ' ';
        q = write_hex(q, flags_from_input ? expected_flags : softfloat_flags(raised), 2);
        *q++ = '\n';
        fwrite(out, 1, (size_t) (q - out), stdout);
    }
    if (ferror(stdin)) {
        fprintf(stderr, "ds_subject: %s: a read error after %llu lines\n", f->name, lines);
        return 2;
    }
    if (fflush(stdout) != 0 || ferror(stdout)) {
        /* Exit 3, and only here: the reader stopped, which is how a refusal
           ends where a write to a closed pipe is an error, not SIGPIPE
           (node). The driver tells the two apart by the status. */
        fprintf(stderr, "ds_subject: %s: a write error after %llu lines\n", f->name, lines);
        return DS_TESTFLOAT_WRITE_ERROR;
    }
    fprintf(stderr, "ds_subject: %s read=%llu tested=%llu skipped_snan=%llu "
                    "skipped_unsigned_range=%llu\n",
            f->name, lines, tested, skipped_snan, skipped_unsigned);
    return 0;
}

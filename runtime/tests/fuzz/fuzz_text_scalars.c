/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * fuzz_text_scalars.c -- coverage-guided fuzzing of libds's text-to-number
 * readers. A rule's `s::Int?` and `s::Float?` ([LCST.4.5.7], [LCST.4.5.8])
 * hand them a String slot's bytes, and a String slot is whatever the host
 * asserted, so they read untrusted text of any length. They are called
 * directly, not through an engine, for throughput: each is a pure function of
 * its (ptr, len), and adapters.c passes a String value's bytes to it
 * unchanged.
 *
 * WHAT IT DRIVES, by name ([STYL.5.10.8]): ds_parse_int_text and
 * ds_parse_float_text over the input, ds_parse_float_json over the same bytes,
 * and ds_fmt_float, whose canonical text property 2 reads back. libFuzzer
 * hands the target a buffer of exactly the input's length, so a read past the
 * end, the defect a (ptr, len) reader is most exposed to, is ASan's.
 *
 * WHAT IT ASSERTS, each a trap:
 *
 *   1. AN INT READS BACK. A value ds_parse_int_text returns is returned again
 *      from its decimal spelling and from its sign-and-hex spelling.
 *   2. A FLOAT READS BACK. A value ds_parse_float_text returns is returned bit
 *      for bit from the canonical text ds_fmt_float writes for it, -0.0 and
 *      the infinities included.
 *   3. AN INT IS A FLOAT. Every spelling ds_parse_int_text accepts,
 *      ds_parse_float_text accepts too, as the same number correctly rounded:
 *      the literal grammars are one grammar ([LLEX.11.1], [LLEX.11.2]), and
 *      C's int64-to-double conversion rounds to nearest, ties to even, as
 *      both readers do.
 *   4. A JSON NUMBER IS A DS LITERAL. RFC 8259's number is a subset of the
 *      decimal literal, so when ds_parse_float_json accepts the bytes with a
 *      finite value, ds_parse_float_text accepts them with the same bits; and
 *      when the JSON value is infinite, the cast refuses, since [LCST.4.5.8]
 *      makes a spelling that rounds to an infinity `null`. The two reach
 *      fast_float by different roads: the JSON reader directly, the cast
 *      through scan_literal's rewrite, so this compares the rewrite.
 *
 * The counts are printed at exit and read by the gate: a REPLAY that ran
 * none of the four leaves its count at zero, and the gate refuses that.
 */

#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "float_fmt.h"

#define FAIL(why) do {                                          \
        fprintf(stderr, "fuzz_text_scalars: %s\n", (why));      \
        __builtin_trap();                                       \
    } while (0)

/* Counted over every input but libFuzzer's empty first one: what each
   property ran on. */
static unsigned long judged, ints, floats, jsons;

static void report_judged(void)
{
    fprintf(stderr, "fuzz_text_scalars: judged %lu input(s): %lu int, "
                    "%lu float, %lu json\n",
            judged, ints, floats, jsons);
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void) argc;
    (void) argv;
    if (atexit(report_judged) != 0) abort();
    return 0;
}

static bool same_bits(double a, double b)
{
    return memcmp(&a, &b, sizeof a) == 0;
}

static void check_int(const char *s, size_t n)
{
    int64_t v;
    if (ds_parse_int_text(s, n, &v) != 0) return;
    ints++;

    /* 1. Decimal, then sign and hex. The magnitude of INT64_MIN is taken in
          unsigned arithmetic, where it is representable. */
    char    text[48];
    int64_t back;
    int     len = snprintf(text, sizeof text, "%" PRId64, v);
    if (ds_parse_int_text(text, (size_t) len, &back) != 0 || back != v)
        FAIL("an Int does not read back from its decimal spelling");
    uint64_t mag = v < 0 ? 0u - (uint64_t) v : (uint64_t) v;
    len = snprintf(text, sizeof text, "%s0x%" PRIx64, v < 0 ? "-" : "", mag);
    if (ds_parse_int_text(text, (size_t) len, &back) != 0 || back != v)
        FAIL("an Int does not read back from its hex spelling");

    /* 3. The same spelling is a Float. */
    double f;
    if (ds_parse_float_text(s, n, &f) != 0)
        FAIL("ds_parse_float_text refuses a spelling ds_parse_int_text accepts");
    if (f != (double) v)
        FAIL("an Int spelling reads as another Float than its value rounded");
}

static void check_float(const char *s, size_t n)
{
    double v;
    if (ds_parse_float_text(s, n, &v) != 0) return;
    floats++;
    if (isnan(v)) FAIL("ds_parse_float_text returned a NaN");

    /* 2. The canonical text reads back bit for bit. */
    char   text[64];
    int    len = ds_fmt_float(text, sizeof text, v);
    double back;
    if (len < 0 || (size_t) len >= sizeof text)
        FAIL("ds_fmt_float wrote no text, or more than its 24 bytes");
    if (ds_parse_float_text(text, (size_t) len, &back) != 0 || !same_bits(back, v))
        FAIL("a Float does not read back from its canonical text");
}

static void check_json(const char *s, size_t n)
{
    double j;
    if (ds_parse_float_json(s, n, &j) != 0) return;
    jsons++;

    /* 4. A JSON number is a DS literal. */
    double v;
    int    r = ds_parse_float_text(s, n, &v);
    if (isinf(j)) {
        if (r == 0) FAIL("the cast accepts a number that rounds to an infinity");
    } else if (r != 0 || !same_bits(v, j)) {
        FAIL("a JSON number reads as another Float through the cast");
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    const char *s = (const char *) data;
    check_int(s, size);
    check_float(s, size);
    check_json(s, size);
    if (size > 0) judged++;
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_float_fmt — float_fmt.h, reached directly: the canonical Float -> text
 * form (ds_fmt_float, [LDET.3.2.7]: the shortest round-trip decimal, a whole
 * float keeping its `.0`), fixed precision (the binary value correctly
 * rounded), the JSON-number parse, the `String::Float?` and `String::Int?`
 * parses, and the round trip [LDET.3.2.8] requires.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <float.h>
#include <math.h>

#include "float_fmt.h"

static int fails = 0;

static uint64_t bits(double v)
{
    uint64_t b;
    memcpy(&b, &v, sizeof b);
    return b;
}

static void check_fixed(double v, unsigned prec, const char *want)
{
    char buf[400];
    int n = ds_fmt_float_fixed(buf, sizeof buf, v, prec);
    if (strcmp(buf, want) != 0 || n != (int) strlen(want)) {
        fprintf(stderr, "FAIL: ds_fmt_float_fixed(%.17g, %u) -> got \"%s\" (%d), want \"%s\"\n",
                v, prec, buf, n, want);
        fails++;
    }
}

/* `text` must parse to exactly `want`, bit for bit (so -0.0 is told apart) */
static void check_parse(int (*parse)(const char *, size_t, double *), const char *name,
                        const char *text, double want)
{
    double got = 12345.0;
    if (parse(text, strlen(text), &got) != 0) {
        fprintf(stderr, "FAIL: %s(\"%s\") refused, want %.17g\n", name, text, want);
        fails++;
    } else if (bits(got) != bits(want)) {
        fprintf(stderr, "FAIL: %s(\"%s\") -> %.17g, want %.17g\n", name, text, got, want);
        fails++;
    }
}

static void check_refused(int (*parse)(const char *, size_t, double *), const char *name,
                          const char *text)
{
    double got = 12345.0;
    if (parse(text, strlen(text), &got) == 0) {
        fprintf(stderr, "FAIL: %s(\"%s\") accepted (%.17g), want refused\n", name, text, got);
        fails++;
    } else if (got != 12345.0) {
        fprintf(stderr, "FAIL: %s(\"%s\") refused but wrote its output\n", name, text);
        fails++;
    }
}

/* the canonical text of `v` parses back to `v` itself */
static void check_round_trip(double v)
{
    char buf[64];
    int n = ds_fmt_float(buf, sizeof buf, v);
    double back = 12345.0;
    if (ds_parse_float_text(buf, (size_t) n, &back) != 0 || bits(back) != bits(v)) {
        fprintf(stderr, "FAIL: round trip of %.17g via \"%s\" gave %.17g\n", v, buf, back);
        fails++;
    }
}

/* ds_fmt_float_fixed against this host's printf("%.*f").
 *
 * The test may use printf where libds may not ([IARC.1.16] binds the archive,
 * not its tests), and that is what makes printf an INDEPENDENT reference here:
 * glibc's and musl's %f convert the exact binary value with the current
 * rounding mode, round-to-nearest ties-to-even — the contract the formatter
 * claims — through code that shares nothing with it.
 *
 * Three populations, because each finds a different defect: exact decimal
 * ties (i/1024 — every one is a tie at some precision, which is where
 * half-even differs from half-up); carries through 9s and across the integer
 * boundary; and pseudo-random bit patterns over the whole finite range,
 * subnormals and DBL_MAX included, at small and very large precisions (a
 * precision past the value's binary places writes its exact digits and
 * zeros). Deterministic: a fixed xorshift seed, so a failure reproduces. */
static void differential_one(double v, unsigned prec)
{
    static char got[2048], want[2048];
    int n = ds_fmt_float_fixed(got, sizeof got, v, prec);
    int w = snprintf(want, sizeof want, "%.*f", (int) prec, v);
    if (n != w || strcmp(got, want) != 0) {
        if (fails < 20)
            fprintf(stderr, "FAIL: ds_fmt_float_fixed(%a, %u) -> \"%.60s...\", "
                    "printf gives \"%.60s...\"\n", v, prec, got, want);
        fails++;
    }
}

static void differential_fixed(void)
{
    static const unsigned precs[] = { 0, 1, 2, 3, 4, 6, 9, 15, 17, 20, 40 };
    const size_t np = sizeof precs / sizeof precs[0];
    int before = fails;

    for (int i = -4096; i <= 4096; i++)                     /* exact ties */
        for (unsigned p = 0; p <= 10; p++)
            differential_one(i / 1024.0, p);

    static const double carries[] = { 0.5, 0.95, 0.995, 0.9995, 9.5, 99.95,
                                      999.9999, 0.0049999, 0.005, 0.0050001,
                                      1e-300, 4.9e-324, 2.2250738585072014e-308,
                                      DBL_MAX, 9007199254740993.0, 1e22, 1e23 };
    for (size_t i = 0; i < sizeof carries / sizeof carries[0]; i++)
        for (size_t p = 0; p < np; p++) {
            differential_one(carries[i], precs[p]);
            differential_one(-carries[i], precs[p]);
        }
    differential_one(4.9e-324, 1074);                        /* every place */
    differential_one(4.9e-324, 1100);                        /* and past them */
    differential_one(DBL_MAX, 0);

    uint64_t x = 0x9E3779B97F4A7C15u;                        /* xorshift64 */
    for (int i = 0; i < 20000; i++) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        double v;
        memcpy(&v, &x, sizeof v);
        if (!isfinite(v)) continue;
        differential_one(v, precs[(size_t) i % np]);
    }
    if (fails == before)
        printf("test_float_fmt: fixed precision agrees with printf(\"%%.*f\")\n");
}

static void check(double v, const char *want)
{
    char buf[64];
    ds_fmt_float(buf, sizeof buf, v);
    if (strcmp(buf, want) != 0) {
        fprintf(stderr, "FAIL: ds_fmt_float -> got \"%s\", want \"%s\"\n",
                buf, want);
        fails++;
    }
}

int main(void)
{
    /* Whole floats keep `.0`. */
    check(42.0, "42.0");
    check(5.0, "5.0");
    check(100.0, "100.0");
    check(120.0, "120.0");
    check(-42.0, "-42.0");

    /* Fractional values. */
    check(1.5, "1.5");
    check(0.5, "0.5");
    check(1234.5, "1234.5");

    /* Full-precision: the shortest round-trip, not %g's 6 sig-figs. */
    check(3.141592653589793, "3.141592653589793");
    check(0.1 + 0.2, "0.30000000000000004");

    /* Fixed for 1e-4 <= |x| < 1e16 (E in [-4, 15]); scientific outside. */
    check(0.0001, "0.0001");
    check(1e-5, "1e-05");
    check(1e15, "1000000000000000.0");
    check(1e16, "1e+16");
    check(1e-100, "1e-100");
    check(1e100, "1e+100");

    /* Scientific carries a multi-digit mantissa with no trailing ".0", the
       exponent stays lowercase / always-signed / >=2 digits, and negatives
       keep their sign ahead of the mantissa. */
    check(1.5e16, "1.5e+16");
    check(1.25e20, "1.25e+20");
    check(-2.5e-10, "-2.5e-10");

    /* Signed zero: preserved by the serializer. */
    check(0.0, "0.0");
    check(copysign(0.0, -1.0), "-0.0");

    /* Non-finite: the text plane renders Inf; the JSON data plane guards
       isfinite before reaching here. */
    check(INFINITY, "inf");
    check(-INFINITY, "-inf");
    /* A NaN renders "nan" whatever its sign; the default NaNs of
       x86_64 and aarch64 differ in sign. */
    check(NAN, "nan");
    check(copysign(NAN, -1.0), "nan");

    /* The extremes of the shortest form: the smallest subnormal, the smallest
       normal, the largest finite value, and 2^53 + 2 above the integer range
       a double counts exactly. */
    check(5e-324, "5e-324");
    check(2.2250738585072014e-308, "2.2250738585072014e-308");
    check(DBL_MAX, "1.7976931348623157e+308");
    check(9007199254740994.0, "9007199254740994.0");
    check(1.2345678901234568e17, "1.2345678901234568e+17");
    /* The double nearest 1e23 lies below it (9.999999999999999e22), and its
       shortest digits are still "1": the classic case a non-shortest printer
       gets wrong. */
    check(1e23, "1e+23");

    /* snprintf's contract without snprintf: a short buffer is cut and
       terminated, and the return value is still the whole length. */
    {
        char small[5];
        int n = ds_fmt_float(small, sizeof small, 3.141592653589793);
        if (n != 17 || strcmp(small, "3.14") != 0) {
            fprintf(stderr, "FAIL: short buffer -> \"%s\" (%d), want \"3.14\" (17)\n", small, n);
            fails++;
        }
    }

    /* Fixed precision is the BINARY value correctly rounded, ties to even —
       Python's format(x, ".Nf") — not the shortest text cut or re-rounded.
       Each case below is one the other two readings get wrong:
       0.125 is an exact tie and goes to the even "0.12"; 2.675 is
       2.67499999999999982… in binary and goes down, though its shortest text
       "2.675" looks like a tie; 0.129 and 1.999 go UP, where truncation kept
       "0.12" / "1"; 0.999 carries through the 9s into the integer part. */
    check_fixed(0.125, 2, "0.12");
    check_fixed(0.375, 2, "0.38");
    check_fixed(2.675, 2, "2.67");
    check_fixed(0.129, 2, "0.13");
    check_fixed(-0.129, 2, "-0.13");
    check_fixed(1.999, 0, "2");
    check_fixed(0.999, 2, "1.00");
    check_fixed(9.9999, 3, "10.000");
    check_fixed(0.5, 0, "0");
    check_fixed(1.5, 0, "2");
    check_fixed(2.5, 0, "2");
    check_fixed(-0.5, 0, "-0");
    check_fixed(0.0049, 2, "0.00");
    check_fixed(0.0051, 2, "0.01");
    check_fixed(3.14159, 0, "3");
    check_fixed(1.0, 3, "1.000");
    check_fixed(123.456, 5, "123.45600");
    check_fixed(1e-5, 6, "0.000010");
    check_fixed(1e-10, 2, "0.00");
    check_fixed(-1e-10, 2, "-0.00");
    check_fixed(0.0, 2, "0.00");
    check_fixed(copysign(0.0, -1.0), 0, "-0");
    check_fixed(1e20, 1, "100000000000000000000.0");
    check_fixed(-42.5, 1, "-42.5");
    check_fixed(INFINITY, 2, "inf");
    check_fixed(-INFINITY, 2, "-inf");
    /* 0.1's exact binary digits at 20 places, and the smallest subnormal at 0. */
    check_fixed(0.1, 20, "0.10000000000000000555");
    check_fixed(5e-324, 0, "0");

    differential_fixed();

    /* JSON numbers, correctly rounded, ties to even, any length. */
    check_parse(ds_parse_float_json, "json", "1.5", 1.5);
    check_parse(ds_parse_float_json, "json", "0.1", 0.1);
    check_parse(ds_parse_float_json, "json", "-0.0", copysign(0.0, -1.0));
    check_parse(ds_parse_float_json, "json", "-0", copysign(0.0, -1.0));
    check_parse(ds_parse_float_json, "json", "1E2", 100.0);
    check_parse(ds_parse_float_json, "json", "1e-05", 1e-5);
    /* halfway between 2^53 and 2^53 + 2: ties to even, down */
    check_parse(ds_parse_float_json, "json", "9007199254740993", 9007199254740992.0);
    /* the same halfway point with a long tail above it: up — the digit that
       decides it is the 45th */
    check_parse(ds_parse_float_json, "json",
                "9007199254740993.0000000000000000000000000001", 9007199254740994.0);
    /* the subnormal boundary and the largest finite value */
    check_parse(ds_parse_float_json, "json", "4.9406564584124654e-324", 5e-324);
    check_parse(ds_parse_float_json, "json", "2.2250738585072014e-308", 2.2250738585072014e-308);
    check_parse(ds_parse_float_json, "json", "1.7976931348623157e308", DBL_MAX);
    /* beyond the range: ±Inf above, ±0 below, as strtod gives */
    check_parse(ds_parse_float_json, "json", "1e400", INFINITY);
    check_parse(ds_parse_float_json, "json", "-1e400", -INFINITY);
    check_parse(ds_parse_float_json, "json", "1e-400", 0.0);
    check_parse(ds_parse_float_json, "json", "-1e-400", copysign(0.0, -1.0));

    /* Not a JSON number: refused, and the output left alone. */
    check_refused(ds_parse_float_json, "json", "");
    check_refused(ds_parse_float_json, "json", "+1");
    check_refused(ds_parse_float_json, "json", " 1");
    check_refused(ds_parse_float_json, "json", "1 ");
    check_refused(ds_parse_float_json, "json", "1.");
    check_refused(ds_parse_float_json, "json", ".5");
    check_refused(ds_parse_float_json, "json", "01");
    check_refused(ds_parse_float_json, "json", "1e");
    check_refused(ds_parse_float_json, "json", "0x1p3");
    check_refused(ds_parse_float_json, "json", "inf");
    check_refused(ds_parse_float_json, "json", "NaN");

    /* String::Float? ([LCST.4.5.8]): a signed INT_LIT or FLOAT_LIT as
       source spells it, or `inf`. */
    check_parse(ds_parse_float_text, "text", "inf", INFINITY);
    check_parse(ds_parse_float_text, "text", "-inf", -INFINITY);
    check_parse(ds_parse_float_text, "text", "+inf", INFINITY);
    check_parse(ds_parse_float_text, "text", "42.0", 42.0);
    check_parse(ds_parse_float_text, "text", "1_500", 1500.0);
    check_parse(ds_parse_float_text, "text", "1_500.25", 1500.25);
    check_parse(ds_parse_float_text, "text", "+1.5E3", 1500.0);
    check_parse(ds_parse_float_text, "text", "15e2", 1500.0);
    check_parse(ds_parse_float_text, "text", "1.5e+0_3", 1500.0);
    check_parse(ds_parse_float_text, "text", "007.5", 7.5);
    check_parse(ds_parse_float_text, "text", "0.000_125", 0.000125);
    check_parse(ds_parse_float_text, "text", "-0", copysign(0.0, -1.0));
    check_parse(ds_parse_float_text, "text", "-0.0", copysign(0.0, -1.0));
    check_parse(ds_parse_float_text, "text", "0x5DC", 1500.0);
    check_parse(ds_parse_float_text, "text", "-0b101_1101_1100", -1500.0);
    check_parse(ds_parse_float_text, "text", "0o2734", 1500.0);
    /* 2^53 + 1 in hex, a tie: to even, down; one more bit below it, up */
    check_parse(ds_parse_float_text, "text", "0x20_0000_0000_0001", 9007199254740992.0);
    check_parse(ds_parse_float_text, "text", "0x40_0000_0000_0003", 18014398509481988.0);
    /* past 64 bits in hex: 2^64 + 1, 65 significant bits, rounds to 2^64 */
    check_parse(ds_parse_float_text, "text", "0x1_0000_0000_0000_0001", 18446744073709551616.0);
    /* the same decimal tie, separators and all */
    check_parse(ds_parse_float_text, "text", "9_007_199_254_740_993", 9007199254740992.0);
    check_parse(ds_parse_float_text, "text", "1e-400", 0.0);
    check_refused(ds_parse_float_text, "text", "Infinity");
    check_refused(ds_parse_float_text, "text", "INF");
    check_refused(ds_parse_float_text, "text", "nan");
    check_refused(ds_parse_float_text, "text", " 1.5");
    check_refused(ds_parse_float_text, "text", "1.5 ");
    check_refused(ds_parse_float_text, "text", "");
    check_refused(ds_parse_float_text, "text", "1.");
    check_refused(ds_parse_float_text, "text", ".5");
    check_refused(ds_parse_float_text, "text", "1e");
    check_refused(ds_parse_float_text, "text", "1_.5");
    check_refused(ds_parse_float_text, "text", "1._5");
    check_refused(ds_parse_float_text, "text", "1e_5");
    check_refused(ds_parse_float_text, "text", "_1");
    check_refused(ds_parse_float_text, "text", "1_");
    /* [LLEX.11.1], [LLEX.11.2]: one `_` between two digits, never two */
    check_refused(ds_parse_float_text, "text", "1__0.5");
    check_refused(ds_parse_float_text, "text", "1.2__5");
    check_refused(ds_parse_float_text, "text", "1e1__0");
    check_refused(ds_parse_float_text, "text", "0x1__F");
    check_refused(ds_parse_float_text, "text", "0x_5");
    check_refused(ds_parse_float_text, "text", "0X5");
    check_refused(ds_parse_float_text, "text", "0x1p3");
    check_refused(ds_parse_float_text, "text", "0x1.8");
    check_refused(ds_parse_float_text, "text", "1e400");
    check_refused(ds_parse_float_text, "text", "-1e400");
    check_refused(ds_parse_float_text, "text", "5_s");
    check_refused(ds_parse_float_text, "text", "++1");

    /* String::Int? ([LCST.4.5.7]). */
    {
        static const struct { const char *t; int64_t want; } ok[] = {
            { "31", 31 }, { "3_1", 31 }, { "+31", 31 }, { "0x1f", 31 },
            { "0x1F", 31 }, { "0b1_1111", 31 }, { "0o37", 31 }, { "-0x1F", -31 },
            { "007", 7 }, { "1_0", 10 },
            { "9223372036854775807", INT64_MAX },
            { "-9223372036854775808", INT64_MIN },
            { "-0x8000_0000_0000_0000", INT64_MIN },
        };
        static const char *const bad[] = {
            "", "+", "-", " 31", "31 ", "3.1", "3e1", "31_", "_31", "0x_1F",
            "0X1F", "0x", "0b2", "0o8", "0xG", "9223372036854775808",
            "-9223372036854775809", "0x1_0000_0000_0000_0000", "31s", "31_s",
            /* [LLEX.11.1]: one `_` between two digits, never two */
            "1__0", "1__2", "0x1__F", "0b1__1",
        };
        for (size_t i = 0; i < sizeof ok / sizeof ok[0]; i++) {
            int64_t got = 0;
            if (ds_parse_int_text(ok[i].t, strlen(ok[i].t), &got) != 0 || got != ok[i].want) {
                fprintf(stderr, "FAIL: int(\"%s\") gave %lld, want %lld\n",
                        ok[i].t, (long long) got, (long long) ok[i].want);
                fails++;
            }
        }
        for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
            int64_t got = 12345;
            if (ds_parse_int_text(bad[i], strlen(bad[i]), &got) == 0 || got != 12345) {
                fprintf(stderr, "FAIL: int(\"%s\") accepted or wrote %lld\n",
                        bad[i], (long long) got);
                fails++;
            }
        }
    }

    /* The round trip [LDET.3.2.8] requires, through the two halves this file
       pins: every value's canonical text reads back as the value itself. */
    {
        const double vs[] = { 0.0, 0.1, 0.5, 1.0 / 3.0, 2.0 / 3.0, 42.0, 1e23, 1e-5,
                              5e-324, 2.2250738585072014e-308, 2.225073858507201e-308,
                              DBL_MAX, 9007199254740994.0, 1.5e16, 123456.789,
                              -2.5e-10, INFINITY, -INFINITY };
        for (size_t i = 0; i < sizeof vs / sizeof vs[0]; i++) {
            check_round_trip(vs[i]);
            check_round_trip(-vs[i]);
        }
    }

    if (fails) {
        fprintf(stderr, "test_float_fmt: %d case(s) FAILED\n", fails);
        return 1;
    }
    printf("test_float_fmt: OK\n");
    return 0;
}

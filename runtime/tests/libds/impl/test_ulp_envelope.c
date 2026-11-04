/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [LDET.3.4.1]'s 0-ULP commitment, as the platform delivers it: the
 * hardware's correctly rounded operations, the compiler's contraction and
 * folding, and the rounding mode. DS's `**` is CORE-MATH's `pow`, which
 * test_ulp_pow checks.
 *
 * Each platform checks itself against the committed bits; the table is the
 * commitment, so changing a number changes what DS promises.
 *
 *   VALUE rows compare the IEEE-754 bits.
 *   TEXT rows compare the bits and then libc's `snprintf("%g")` text.
 *
 * `%a` is not compared: glibc and musl render the minimum subnormal
 * differently, and DS uses `%a` nowhere.
 *
 * It links only libm, so the ulp-musl and ulp-build checks compile this same
 * file on images where libds is not built.
 */
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

static int fails = 0;
static int checked = 0;   /* rows actually compared — printed, so a
                             filtered or short-circuited run is visible */

static uint64_t bits(double d)
{
    uint64_t u;
    memcpy(&u, &d, sizeof u);
    return u;
}

/* The comparators, split from the reporting so the self-test below can drive
   them without printing a failure that did not happen. */
static int cmp_bits(double got, uint64_t want) { return bits(got) != want; }

static int cmp_text(double got, const char *want_g)
{
    char buf[64];
    snprintf(buf, sizeof buf, "%g", got);
    return strcmp(buf, want_g) != 0;
}

/* The comparators detect a mismatch, checked on every run before any row is
   trusted ([STYL.5.10.5]). */
static int selftest(void)
{
    int bad = 0;
    if (cmp_bits(1.0, 0x3ff0000000000000ULL) != 0) bad = 1;  /* must agree */
    if (cmp_bits(1.0, 0x3ff0000000000001ULL) == 0) bad = 1;  /* must differ */
    if (cmp_text(0.5, "0.5") != 0)                 bad = 1;
    if (cmp_text(0.5, "0.4999")  == 0)             bad = 1;
    if (bad)
        fprintf(stderr,
                "FAIL selftest: the comparators do not detect a mismatch — "
                "every row below would pass vacuously\n");
    return bad;
}

/* A VALUE row: the bits are the commitment. */
static void v(const char *what, double got, uint64_t want)
{
    checked++;
    if (cmp_bits(got, want)) {
        fprintf(stderr,
                "FAIL value  %-30s got %016llx (%a)  want %016llx\n",
                what, (unsigned long long)bits(got), got,
                (unsigned long long)want);
        fails++;
    }
}

/* A TEXT row: the bits, then `%g`'s rendering. */
static void t(const char *what, double got, uint64_t want_bits,
              const char *want_g)
{
    char buf[64];
    checked++;
    if (cmp_bits(got, want_bits)) {
        fprintf(stderr,
                "FAIL value  %-30s got %016llx  want %016llx\n",
                what, (unsigned long long)bits(got),
                (unsigned long long)want_bits);
        fails++;
        return;
    }
    snprintf(buf, sizeof buf, "%g", got);
    if (cmp_text(got, want_g)) {
        fprintf(stderr,
                "FAIL text   %-30s %%g gave \"%s\"  want \"%s\"\n",
                what, buf, want_g);
        fails++;
    }
}

int main(void)
{
    fails += selftest();

    /* Signature first: a failure report is useless without it. */
#if defined(__GLIBC__)
    printf("ulp: libc glibc %d.%d", __GLIBC__, __GLIBC_MINOR__);
#elif defined(__APPLE__)
    printf("ulp: libc apple-libm");
#else
    printf("ulp: libc non-glibc (musl/bsd)");   /* musl defines no version */
#endif
    printf(", arch %s\n",
#if defined(__x86_64__)
        "x86_64"
#elif defined(__aarch64__)
        "aarch64"
#elif defined(__riscv)
        "riscv64"
#else
        "other"
#endif
    );

    /* ---- CONTROLS ------------------------------------------------------
     * + - * / and sqrt are correctly-rounded by IEEE-754 and the hardware,
     * not by the library, so these must hold everywhere. A control failing
     * means the toolchain or the flags diverged, and nothing below it is
     * interpretable until that is explained. */
    v("0.1 + 0.2",              0.1 + 0.2,          0x3fd3333333333334ULL);
    v("1.0 / 3.0",              1.0 / 3.0,          0x3fd5555555555555ULL);
    v("2.0 / 3.0 * 3.0",        2.0 / 3.0 * 3.0,    0x4000000000000000ULL);
    v("sqrt(2.0)",              sqrt(2.0),          0x3ff6a09e667f3bcdULL);
    v("sqrt(1e-300)",           sqrt(1e-300),       0x20ca2fe76a3f9475ULL);
    /* The shape the series backends actually compute: Welford/EWMA is
       + - * / and sqrt, nothing else. */
    v("welford-ish",
      sqrt((13.7 - 9.1) * (13.7 - 9.1) / 3.0),      0x40053f19f665d460ULL);

    /* ---- SUBJECT: FMA contraction -------------------------------------
     *
     * `a*b + c` contracted into a fused multiply-add rounds once instead of
     * twice. FMA is baseline on aarch64 and absent from baseline x86-64, so
     * libds and this test compile with -ffp-contract=off (libds.build).
     * `volatile` keeps the compiler from folding the expression at compile
     * time. */
    {
        volatile double a = 0.1, b = 0.2;
        volatile double prod = a * b;          /* forced to round here */
        double c = -(double)prod;
        double stepwise = (double)prod + c;    /* exactly 0 */
        double maybe_fused = a * b + c;        /* 0 unless contracted */
        if (bits(stepwise) != bits(maybe_fused)) {
            fprintf(stderr,
                    "FAIL fma    the compiler CONTRACTED a*b+c into an FMA\n"
                    "            stepwise %016llx  fused %016llx\n"
                    "            [LDET.3.4.1] cannot hold across ISAs while this\n"
                    "            is on: FMA is baseline on aarch64 and absent\n"
                    "            from baseline x86-64, so the same source gives\n"
                    "            two answers. Build libds -ffp-contract=off.\n",
                    (unsigned long long)bits(stepwise),
                    (unsigned long long)bits(maybe_fused));
            fails++;
        }
    }

    /* ---- SUBJECT: the rounding MODE, which rint() reads ----------------
     * round(x) lowers to rint(), which honours the current rounding
     * direction rather than defining one. DS never sets it, so these pin the
     * round-to-nearest-ties-to-even default that [LDET] assumes. */
    v("rint(2.5) ties to even",  rint(2.5),   0x4000000000000000ULL); /*  2 */
    v("rint(3.5) ties to even",  rint(3.5),   0x4010000000000000ULL); /*  4 */
    v("rint(-2.5) ties to even", rint(-2.5),  0xc000000000000000ULL); /* -2 */
    v("rint(0.5) ties to even",  rint(0.5),   0x0000000000000000ULL); /*  0 */

    /* ---- SUBJECT: composite shapes the author surface computes. Each is
     * correctly rounded op by op; these rows pin the order and the absence
     * of contraction. */
    {
        /* euclidean_distance_2d: sqrt(dx*dx + dy*dy) */
        volatile double x1 = 1.7, y1 = 2.3, x2 = 9.1, y2 = -4.6;
        double dx = (double)x1 - (double)x2, dy = (double)y1 - (double)y2;
        v("euclidean_2d shape", sqrt(dx * dx + dy * dy), 0x40243c51144fde99ULL);
    }
    {
        /* series stdev: ss/(n-1) then sqrt */
        volatile double s0 = 13.7, s1 = 9.1, s2 = 11.4;
        double mean = ((double)s0 + (double)s1 + (double)s2) / 3.0;
        double d0 = (double)s0 - mean, d1 = (double)s1 - mean,
               d2 = (double)s2 - mean;
        double ss = d0 * d0 + d1 * d1 + d2 * d2;
        v("sample stdev shape", sqrt(ss / 2.0), 0x4002666666666666ULL);
    }
    {
        /* degrees(): x * (180.0/pi), the divisor folded at compile time by
         * the compiler's own arithmetic. */
        volatile double r = 1.0;
        v("degrees() constant",
          (double)r * (180.0 / 3.14159265358979323846),
          0x404ca5dc1a63c1f8ULL);
    }

    /* ---- SUBJECT: libc's %g text ---------------------------------------- */
    t("text 1.0/3.0",      1.0 / 3.0,    0x3fd5555555555555ULL, "0.333333");
    t("text 0.1+0.2",      0.1 + 0.2,    0x3fd3333333333334ULL, "0.3");
    t("text 1e-310",       1e-310,       0x000012688b70e62bULL, "1e-310");
    t("text 5e-324",       5e-324,       0x0000000000000001ULL, "4.94066e-324");
    t("text 1e22",         1e22,         0x4480f0cf064dd592ULL, "1e+22");
    t("text 1e23",         1e23,         0x44b52d02c7e14af6ULL, "1e+23");
    t("text -0.0",         -0.0,         0x8000000000000000ULL, "-0");
    t("text 123456789.5",  123456789.5,  0x419d6f3456000000ULL, "1.23457e+08");
    t("text 2.5",          2.5,          0x4004000000000000ULL, "2.5");

    if (fails) {
        fprintf(stderr,
                "\ntest_ulp_envelope: %d row(s) DIVERGED on this platform.\n"
                "[LDET.3.4.1] commits to bit-identical results everywhere, so a\n"
                "row here is a conformance failure, not a test to relax. Do NOT\n"
                "update the expected values to match: they are the commitment.\n"
                "A real divergence is a ruling — narrow the guarantee, or drop\n"
                "the construct that caused it.\n",
                fails);
        return 1;
    }
    printf("test_ulp_envelope: OK (%d rows, 0 ULP)\n", checked);
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The bits DS's Float `**` gives. `builtin_pow`'s Float path (builtins.c)
 * calls ds_cm_pow, CORE-MATH's correctly rounded `pow` compiled into libds.a
 * ([LEXP.3.9.2]); this file calls the same symbol.
 *
 * Each expected value is the correctly rounded result, so changing one
 * changes what DS promises. The inputs are where `pow` implementations
 * diverge: non-integral exponents, values near 1 raised to huge powers, and
 * decimal rounding boundaries.
 *
 * ds_cm_pow is in another object, so the compiler cannot fold it. The test
 * runs in round-to-nearest-even, the mode CORE-MATH's result is defined in
 * and the one libds evaluates in ([LDET.3.6.1]).
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "core_math.h"

static int fails = 0;
static int checked = 0;   /* rows actually compared -- printed, so a short run
                             is visible */

static uint64_t bits(double d)
{
    uint64_t u;
    memcpy(&u, &d, sizeof u);
    return u;
}

static int cmp_bits(double got, uint64_t want) { return bits(got) != want; }

/* The comparator detects a mismatch, checked before any row is trusted
   ([STYL.5.10.5]). */
static int selftest(void)
{
    int bad = 0;
    if (cmp_bits(1.0, 0x3ff0000000000000ULL) != 0) bad = 1;  /* must agree */
    if (cmp_bits(1.0, 0x3ff0000000000001ULL) == 0) bad = 1;  /* must differ */
    if (bad)
        fprintf(stderr,
                "FAIL selftest: the comparator does not detect a mismatch -- "
                "every row below would pass vacuously\n");
    return bad;
}

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

int main(void)
{
    fails += selftest();

    v("2.0 ** 10.0",            ds_cm_pow(2.0, 10.0),       0x4090000000000000ULL);
    v("1.0000001 ** 3.0",       ds_cm_pow(1.0000001, 3.0),  0x3ff000005087d858ULL);
    v("2.0 ** 0.5",             ds_cm_pow(2.0, 0.5),        0x3ff6a09e667f3bcdULL);
    v("3.0 ** (1/3)",           ds_cm_pow(3.0, 1.0 / 3.0),  0x3ff7137449123ef6ULL);
    v("1.1 ** 2.5",             ds_cm_pow(1.1, 2.5),        0x3ff44e1080833b25ULL);
    v("0.9999999999 ** 1e6",    ds_cm_pow(0.9999999999, 1e6), 0x3fefff2e4b96afdaULL);
    v("7.389056098930649 ** .7",
      ds_cm_pow(7.3890560989306495, 0.7),                   0x4010388657115a46ULL);
    v("1e-5 ** 0.1",            ds_cm_pow(1e-5, 0.1),       0x3fd43d136248490fULL);
    v("1.0000000000000002**1e15",
      ds_cm_pow(1.0000000000000002, 1e15),                  0x3ff3fa60615291eeULL);
    v("10.0 ** 22.0",           ds_cm_pow(10.0, 22.0),      0x4480f0cf064dd592ULL);
    v("10.0 ** 23.0",           ds_cm_pow(10.0, 23.0),      0x44b52d02c7e14af6ULL);
    v("0.5 ** 1074.0",          ds_cm_pow(0.5, 1074.0),     0x0000000000000001ULL);

    if (fails) {
        fprintf(stderr,
                "\ntest_ulp_pow: %d row(s) DIVERGED.\n"
                "ds_cm_pow is CORE-MATH's correctly rounded pow, so a row here\n"
                "means the vendored source, its compile flags or the rounding mode\n"
                "moved. Do NOT update the expected values to match: they are the\n"
                "commitment ([LDET.3.4.1]).\n",
                fails);
        return 1;
    }
    printf("test_ulp_pow: OK (%d rows, 0 ULP)\n", checked);
    return 0;
}

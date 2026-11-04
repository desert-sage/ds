/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* core_math_fenv — force-included into each CORE-MATH compile, so the vendored
 * files stay unmodified. The floating-point macros CORE-MATH names, for a
 * soft-float target that defines none (C11 7.6p6); and roundeven and fma mapped
 * to libds's own.
 *
 * No returned double depends on the exception macros: a tested flag feeds only
 * `errno` (compiled out) or the flags CORE-MATH restores.
 */
#ifndef LIBDS_CORE_MATH_FENV_H
#define LIBDS_CORE_MATH_FENV_H

#include <fenv.h>

#ifndef FE_DIVBYZERO
#define FE_DIVBYZERO 0
#endif
#ifndef FE_INEXACT
#define FE_INEXACT 0
#endif
#ifndef FE_INVALID
#define FE_INVALID 0
#endif
#ifndef FE_OVERFLOW
#define FE_OVERFLOW 0
#endif
#ifndef FE_UNDERFLOW
#define FE_UNDERFLOW 0
#endif

/* C11 7.6p7. CORE-MATH switches on `fegetround()` with a case per direction, so
 * an absent one stops the compile. A case the target does not support is
 * unreachable, and needs only a distinct value; a collision is a duplicate `case`
 * label, which the compiler refuses. */
#ifndef FE_TONEAREST
#define FE_TONEAREST 0
#endif
#ifndef FE_DOWNWARD
#define FE_DOWNWARD (-1)
#endif
#ifndef FE_UPWARD
#define FE_UPWARD (-2)
#endif
#ifndef FE_TOWARDZERO
#define FE_TOWARDZERO (-3)
#endif

/* CORE-MATH's `roundeven_finite` reads `__ARM_ARCH >= 8` as AArch64 and picks
 * `frintn` asm, which a 32-bit Armv8-M core lacks. Undefined here on 32-bit Arm, so
 * it takes its portable C arm. The system headers come first, so none compiles
 * without the macro. */
#if defined(__arm__) && !defined(__aarch64__)
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#undef __ARM_ARCH
#endif

/* roundeven is libds's own, on every row, with no external name. Where a target
 * has no rounding instruction the compiler lowers `__builtin_roundeven` to the C
 * library's `roundeven`, which is C23 and not in every libc. A `#define roundeven`
 * alone would not do: the call emitted for the builtin carries the library name.
 * <math.h> comes first, so the mapping cannot rename its declaration into a clash.
 *
 * The body is mcu_libm/roundeven.c's. */
#include <math.h>
#include <stdint.h>
#include <string.h>

static inline double ds_cm_roundeven(double x)
{
    uint64_t u;
    memcpy(&u, &x, 8);
    int biased = (int)((u >> 52) & 0x7ff);
    if (biased == 0x7ff) return x + x;             /* NaN (quieted) or infinity */
    int e = biased - 1023;
    uint64_t sign = u & ((uint64_t)1 << 63);
    if (e >= 52) return x;                          /* already an integer */
    if (e < -1) {                                   /* |x| < 0.5, zero included */
        memcpy(&x, &sign, 8);
        return x;
    }
    if (e == -1) {                                  /* 0.5 <= |x| < 1 */
        uint64_t r = (u & ~((uint64_t)1 << 63)) == 0x3fe0000000000000ull
                         ? sign                          /* exactly 0.5: to 0 */
                         : sign | 0x3ff0000000000000ull; /* otherwise: to 1 */
        memcpy(&x, &r, 8);
        return x;
    }
    uint64_t unit = (uint64_t)1 << (52 - e);        /* the value 1 at this exponent */
    uint64_t frac = u & (unit - 1);
    if (frac == 0) return x;
    uint64_t half = unit >> 1;
    u &= ~(unit - 1);
    if (frac > half || (frac == half && (u & unit))) u += unit; /* carries into the exponent */
    memcpy(&x, &u, 8);
    return x;
}

#undef roundeven
#define roundeven ds_cm_roundeven
#define __builtin_roundeven ds_cm_roundeven

/* fma is libds's own wherever it is a call ([IARC.7.14]): with no instruction the
 * compiler emits a call to the C library's `fma`, which not every libc rounds once.
 * The builtin's name is mapped, for roundeven's reason. */
#if !defined(__FP_FAST_FMA)
double ds_libm_fma(double x, double y, double z);
#undef fma
#define fma ds_libm_fma
#define __builtin_fma ds_libm_fma
#endif

#endif /* LIBDS_CORE_MATH_FENV_H */

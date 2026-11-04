/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* core_math — the CORE-MATH entry points libds calls ([LEXP.3.9.1]), compiled
 * unmodified from the files vendor/source.lock pins, each `cr_<fn>` renamed
 * `ds_cm_<fn>` with -D. */
#ifndef LIBDS_CORE_MATH_H
#define LIBDS_CORE_MATH_H

#include <float.h>

/* CORE-MATH's correctness argument assumes double operations evaluate in double. */
#if !defined(FLT_EVAL_METHOD) || FLT_EVAL_METHOD != 0
#error "libds: CORE-MATH needs FLT_EVAL_METHOD == 0 (no x87 extended evaluation)"
#endif

double ds_cm_exp(double x);
double ds_cm_log(double x);      /* FN_LN: the `log` builtin */
double ds_cm_log2(double x);
double ds_cm_log10(double x);
double ds_cm_sin(double x);
double ds_cm_cos(double x);
double ds_cm_tan(double x);
double ds_cm_asin(double x);
double ds_cm_acos(double x);
double ds_cm_atan(double x);
double ds_cm_atan2(double y, double x);
double ds_cm_sinh(double x);
double ds_cm_cosh(double x);
double ds_cm_tanh(double x);
double ds_cm_pow(double x, double y);

/* The worst-case branches' printf and exit, renamed at compile time
   (core_math_unreachable.c). Not for any other caller. */
int ds_cm_unreachable_report(const char *text, ...);
void ds_cm_unreachable_exit(int status) __attribute__((noreturn));

/* Not CORE-MATH: libds's own fused multiply-add ([IARC.7.14]), musl's `fma` from
   the [musl] pin, renamed at compile time. */
double ds_libm_fma(double x, double y, double z);

#endif /* LIBDS_CORE_MATH_H */

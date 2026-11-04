% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.core_math -- the transcendentals, correctly rounded, from the code libds
% runs ([LEXP.3.9.1]).
%
% Each function is CORE-MATH, compiled as libds.build compiles it, so the runtime
% differential compares a function with itself ([LDET.3.3a.8]). `fma` is musl's
% ([IARC.7.14]), as libds's `builtin_fma` calls it. The compiler's `const` folder
% calls these too.
%
% Each `promise_pure` is a promise ledger entry, and true: a correctly rounded
% function depends only on its arguments once the mode is round-to-nearest-even,
% and each call sets that mode and restores the caller's ([LDET.3.6.1]).
%
% A pole is ±inf and an argument outside the domain NaN, CORE-MATH's own answers
% ([LEXP.3.9.3]).
%-----------------------------------------------------------------------------%

:- module ds.core_math.
:- interface.

:- func exp(float) = float.
:- func ln(float) = float.         % FN_LN: the `log` builtin, the natural log
:- func log2(float) = float.
:- func log10(float) = float.
:- func sin(float) = float.
:- func cos(float) = float.
:- func tan(float) = float.
:- func asin(float) = float.
:- func acos(float) = float.
:- func atan(float) = float.
:- func atan2(float, float) = float.   % atan2(y, x), C's argument order
:- func sinh(float) = float.
:- func cosh(float) = float.
:- func tanh(float) = float.
:- func pow(float, float) = float.
:- func fma(float, float, float) = float.  % x*y + z, rounded once

%-----------------------------------------------------------------------------%
:- implementation.

:- pragma foreign_decl("C", "
#include <fenv.h>
#include <math.h>
#include \"core_math.h\"

/* [LDET.3.6.1]: the function runs in round-to-nearest-even and the caller's
   mode is restored before control returns. fesetround is skipped when the mode
   is already nearest, which it is unless an integrator set another. */
#define DS_CM_RN(expr, out) do {                          \\
        int ds_cm_saved_ = fegetround();                  \\
        if (ds_cm_saved_ != FE_TONEAREST)                 \\
            fesetround(FE_TONEAREST);                     \\
        (out) = (expr);                                   \\
        if (ds_cm_saved_ != FE_TONEAREST)                 \\
            fesetround(ds_cm_saved_);                     \\
    } while (0)
").

:- pragma foreign_proc("C", exp(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_exp(X), R);").
:- pragma foreign_proc("C", ln(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_log(X), R);").
:- pragma foreign_proc("C", log2(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_log2(X), R);").
:- pragma foreign_proc("C", log10(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_log10(X), R);").
:- pragma foreign_proc("C", sin(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_sin(X), R);").
:- pragma foreign_proc("C", cos(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_cos(X), R);").
:- pragma foreign_proc("C", tan(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_tan(X), R);").
:- pragma foreign_proc("C", asin(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_asin(X), R);").
:- pragma foreign_proc("C", acos(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_acos(X), R);").
:- pragma foreign_proc("C", atan(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_atan(X), R);").
:- pragma foreign_proc("C", atan2(Y::in, X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_atan2(Y, X), R);").
:- pragma foreign_proc("C", sinh(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_sinh(X), R);").
:- pragma foreign_proc("C", cosh(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_cosh(X), R);").
:- pragma foreign_proc("C", tanh(X::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_tanh(X), R);").
:- pragma foreign_proc("C", pow(X::in, Y::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_cm_pow(X, Y), R);").
:- pragma foreign_proc("C", fma(X::in, Y::in, Z::in) = (R::out),
    [will_not_call_mercury, promise_pure, thread_safe],
    "DS_CM_RN(ds_libm_fma(X, Y, Z), R);").

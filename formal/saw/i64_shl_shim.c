/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * i64_shl_shim.c — SAW harness translation unit for DS's left shift
 * ([LEXP.7.14.1]). `ds_i64_shl` is a `static inline` in int_ops.h, so it emits no
 * external symbol on its own; this TU exposes it under a clause-named symbol so
 * SAW can llvm_verify the REAL header logic rather than a re-typed copy.
 *
 * Same shape as i64_shr_shim.c.
 */
#include <stdint.h>

#include "int_ops.h"   /* the real ds_i64_shl ([LEXP.7.14.1]) */

int64_t lexp_7_14_1__i64_shl(int64_t a, int64_t count)
{
    return ds_i64_shl(a, count);
}

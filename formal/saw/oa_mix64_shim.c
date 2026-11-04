/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * oa_mix64_shim.c — SAW harness translation unit for the unified open-addressing
 * map's hash finalizer ([IRET.28.5]). `oa_mix64` is a `static inline` in oa.h, so
 * it emits no external symbol on its own; this TU exposes it under a clause-named
 * symbol so SAW can llvm_verify the REAL header logic (not a re-typed copy)
 * against the Cryptol reference in oa_mix64.saw.
 *
 * The exported symbol carries the [IRET.28.5] trace tag in its name, matching the
 * <lowercased-clause-id>__<tag> discipline the other formal lanes use.
 */
#include <stdint.h>

#include "oa.h"   /* the real oa_mix64 splitmix64 finalizer ([IRET.28.5]) */

uint64_t iret_28_5__oa_mix64(uint64_t h)
{
    return oa_mix64(h);
}

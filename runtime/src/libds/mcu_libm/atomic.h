/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * atomic.h -- the one thing musl's src/math/fma.c ([IARC.7.14]) takes from musl's
 * internal atomic.h, which pulls in the rest of its tree. fma.c calls it only on a value
 * it has tested nonzero.
 */
#ifndef DS_MCU_LIBM_ATOMIC_H
#define DS_MCU_LIBM_ATOMIC_H

#include <stdint.h>

static inline int a_clz_64(uint64_t x)
{
    return __builtin_clzll(x);
}

#endif

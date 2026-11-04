/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * platform.h -- how SoftFloat and TestFloat are built for [NDET.1.4]'s
 * double-backend check, in place of the per-build-directory copies
 * upstream ships and vendor/ does not take (vendor/source.lock).
 *
 * ONE HEADER FOR EVERY HOSTED ROW. Upstream writes one per platform; what
 * differs between DS's rows is asked of the compiler instead:
 *
 *   - byte order: every hosted row is little-endian (amd64, arm64, rv64gc,
 *     NetBSD amd64, wasm32), and a row that is not fails here rather than
 *     testing with the reference's words reversed;
 *   - a 128-bit integer: SoftFloat's fast path where the compiler has one
 *     (`__SIZEOF_INT128__`), and its portable code where it does not
 *     (wasm32). Either computes the same reference; only its speed differs.
 *
 * SoftFloat's own sources are compiled with DS_TESTFLOAT_SOFTFLOAT, which
 * pulls in its GCC options header, as upstream's SoftFloat platform.h does;
 * TestFloat's, like upstream's TestFloat platform.h, take only the two
 * definitions every source needs.
 *
 * This configures the REFERENCE, never the subject: the operations under test
 * are compiled in ds_subject.c with libds's own flags, which includes nothing
 * of SoftFloat's or TestFloat's, so nothing here reaches them.
 */
#ifndef DS_TESTFLOAT_PLATFORM_H
#define DS_TESTFLOAT_PLATFORM_H

#if !defined(__BYTE_ORDER__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "the double-backend check is configured for little-endian rows only"
#endif
#define LITTLEENDIAN 1

#ifdef __GNUC_STDC_INLINE__
#define INLINE inline
#else
#define INLINE extern inline
#endif

#ifdef DS_TESTFLOAT_SOFTFLOAT
#define SOFTFLOAT_BUILTIN_CLZ 1
#ifdef __SIZEOF_INT128__
#define SOFTFLOAT_INTRINSIC_INT128 1
#endif
#include "opts-GCC.h"
#endif

#endif /* DS_TESTFLOAT_PLATFORM_H */

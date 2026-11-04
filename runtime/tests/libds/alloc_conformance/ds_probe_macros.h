/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_probe_macros.h — the macro-mode override (IALC.1.2).
 *
 * Passed to the libds build as -DDS_ALLOC_HEADER="ds_probe_macros.h": when
 * ds_alloc.h is in DS_ALLOC_MACRO mode it includes this header before its
 * libc fallbacks, so every DS_* in libds expands directly to the counting
 * probe at compile time.
 *
 * Each allocating macro names its site first (alloc_probe.h, probe_site), so
 * rdsc-9-8-oom can say where a failed request was made ([RDSC.9.8]).
 */
#ifndef DS_PROBE_MACROS_H
#define DS_PROBE_MACROS_H

#include "alloc_probe.h"

#define DS_PROBE_SITE     probe_site(__FILE__, __func__)
#define DS_MALLOC(n)      (DS_PROBE_SITE, probe_malloc((n)))
#define DS_CALLOC(n, sz)  (DS_PROBE_SITE, probe_calloc((n), (sz)))
#define DS_REALLOC(p, n)  (DS_PROBE_SITE, probe_realloc((p), (n)))
#define DS_FREE(p)        probe_free((p))
#define DS_STRDUP(s)      (DS_PROBE_SITE, probe_strdup((s)))
#define DS_STRNDUP(s, n)  (DS_PROBE_SITE, probe_strndup((s), (n)))

#endif /* DS_PROBE_MACROS_H */

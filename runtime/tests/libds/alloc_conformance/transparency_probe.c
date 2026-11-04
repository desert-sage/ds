/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * transparency_probe.c — the IALC.10.3 transparency probe.
 *
 * scripts/libds/transparency_check.py compiles it through ds_alloc.h's macro
 * layer and as a raw twin with each DS_* rewritten to the libc call, and
 * compares the two .text sections: identical .text shows the default
 * (no-override) build carries no allocator cost.
 *
 * Functions are external and return their results so -O2 cannot fold the
 * calls away.
 */
#include <stddef.h>

#include "ds_alloc.h"

void *tp_malloc(size_t n)                 { return DS_MALLOC(n); }
void *tp_calloc(size_t a, size_t b)       { return DS_CALLOC(a, b); }
void *tp_realloc(void *p, size_t n)       { return DS_REALLOC(p, n); }
void  tp_free(void *p)                    { DS_FREE(p); }
char *tp_strdup(const char *s)            { return DS_STRDUP(s); }
char *tp_strndup(const char *s, size_t n) { return DS_STRNDUP(s, n); }

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_override_weak.c — the weak-symbol override (IALC.5).
 *
 * Strong ds_* definitions that the linker picks over libds's weak defaults
 * when linked against a DS_ALLOC_MODE=2 libds.a, routing every DS_*
 * allocation in libds to the counting probe. This is the link-time
 * override an integrator performs with no recompile of libds.
 */
#include <stddef.h>

#include "alloc_probe.h"

void  *ds_malloc(size_t n)                 { return probe_malloc(n); }
void  *ds_calloc(size_t count, size_t sz)  { return probe_calloc(count, sz); }
void  *ds_realloc(void *p, size_t n)       { return probe_realloc(p, n); }
void   ds_free(void *p)                     { probe_free(p); }
char  *ds_strdup(const char *s)             { return probe_strdup(s); }
char  *ds_strndup(const char *s, size_t n)  { return probe_strndup(s, n); }

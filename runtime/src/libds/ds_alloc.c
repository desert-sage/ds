/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_alloc.c — the one libds translation unit permitted to call libc's allocators
 * directly ([IALC.1.3]).
 */
#include <stdlib.h>
#include <string.h>

#include "ds_alloc.h"

#if DS_ALLOC_MODE == DS_ALLOC_WEAK

__attribute__((weak)) void *ds_malloc(size_t n)              { return malloc(n); }
__attribute__((weak)) void *ds_calloc(size_t n, size_t sz)  { return calloc(n, sz); }
__attribute__((weak)) void *ds_realloc(void *p, size_t n)   { return realloc(p, n); }
__attribute__((weak)) void  ds_free(void *p)                { free(p); }
__attribute__((weak)) char *ds_strdup(const char *s)        { return strdup(s); }
__attribute__((weak)) char *ds_strndup(const char *s, size_t n) { return strndup(s, n); }

#else /* DS_ALLOC_MACRO */

void  ds_free(void *p)    { DS_FREE(p); }
void *ds_malloc(size_t n) { return DS_MALLOC(n); }

#endif

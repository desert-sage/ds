/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * alloc_probe.h — a magic-header counting allocator used to prove, at
 * runtime, that an integrator allocator override captures every libds
 * allocation (IALC.10).
 *
 * The probe_* functions are the actual allocator; the two override
 * mechanisms wire libds's DS_* / ds_* to them:
 *   - weak-symbol override: ds_override_weak.c defines strong ds_* that
 *     forward here (link-time, IALC.5);
 *   - macro override:        ds_probe_macros.h maps DS_* here, baked into
 *     libds via -DDS_ALLOC_HEADER (compile-time, IALC.1.2).
 *
 * Each allocation carries a magic + size header, so ds_free of a pointer
 * the probe did not hand out is detected (cross-allocator free), and a
 * non-zero outstanding total at teardown is a leak.
 */
#ifndef DS_ALLOC_PROBE_H
#define DS_ALLOC_PROBE_H

#include <stddef.h>

void  *probe_malloc(size_t n);
void  *probe_calloc(size_t count, size_t size);
void  *probe_realloc(void *p, size_t n);
void   probe_free(void *p);
char  *probe_strdup(const char *s);
char  *probe_strndup(const char *s, size_t cap);

/* Introspection. */
size_t probe_n_alloc(void);      /* count of malloc/calloc/strdup/strndup/realloc-from-NULL */
size_t probe_outstanding(void);  /* live bytes handed out and not yet freed */
size_t probe_n_badfree(void);    /* ds_free/realloc of a non-probe pointer */
void   probe_reset(void);

/* Fault injection ([RDSC.9.8]). A REQUEST is any call that can fail:
   malloc, calloc, strdup, strndup, and realloc whatever its pointer.
   probe_n_requests counts them. probe_fail_at(n) makes the n-th request from
   now fail, as an exhausted allocator does (NULL, the old block untouched),
   and only that one; 0 disarms it. probe_failed says whether the armed
   request was reached and failed. */
size_t probe_n_requests(void);
void   probe_fail_at(size_t n);
int    probe_failed(void);

/* A request's SITE ([RDSC.9.8]): the file and function that make it.
   The macro leg's DS_* name it (ds_probe_macros.h), calling probe_site just
   before the request. The weak leg's ds_* forward with none, so its requests
   carry NULL. probe_failed_site gives the armed request's site once it has
   failed, and probe_n_sited counts the requests made with one. */
void   probe_site(const char *file, const char *func);
void   probe_failed_site(const char **file, const char **func);
size_t probe_n_sited(void);

#endif /* DS_ALLOC_PROBE_H */

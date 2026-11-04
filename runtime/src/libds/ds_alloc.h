/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_alloc.h — libds internal allocation layer ([IALC]). Only ds_alloc.c may call
 * libc's allocators directly.
 *
 * Not the regex engine: ds_re2.cc, RE2 and Abseil allocate through C++'s global
 * operator new/delete ([IALC.3.3]).
 *
 * DS_ALLOC_MODE ([IALC.1.2]):
 *   DS_ALLOC_WEAK (the default): the weak ds_* functions in ds_alloc.c, which an
 *     integrator overrides at link with a strong matched set ([IALC.5]).
 *   DS_ALLOC_MACRO: inline to the functions DS_ALLOC_HEADER defines, otherwise to
 *     libc's.
 */
#ifndef LIBDS2_DS_ALLOC_H
#define LIBDS2_DS_ALLOC_H

#include <stddef.h>

#define DS_ALLOC_MACRO 1
#define DS_ALLOC_WEAK  2
#ifndef DS_ALLOC_MODE
   /* The weak default would silently ignore a header-only override. */
#  ifdef DS_ALLOC_HEADER
#    define DS_ALLOC_MODE DS_ALLOC_MACRO
#  else
#    define DS_ALLOC_MODE DS_ALLOC_WEAK
#  endif
#endif

/* Exported in both modes ([IALC.1.3], [IALC.4.2]). */
void  *ds_malloc(size_t n);
void   ds_free(void *p);

#if DS_ALLOC_MODE == DS_ALLOC_WEAK

void  *ds_calloc(size_t n, size_t sz);
void  *ds_realloc(void *p, size_t n);
char  *ds_strdup(const char *s);
char  *ds_strndup(const char *s, size_t n);

#  define DS_MALLOC(n)      ds_malloc((n))
#  define DS_CALLOC(n, sz)  ds_calloc((n), (sz))
#  define DS_REALLOC(p, n)  ds_realloc((p), (n))
#  define DS_FREE(p)        ds_free((p))
#  define DS_STRDUP(s)      ds_strdup((s))
#  define DS_STRNDUP(s, n)  ds_strndup((s), (n))

#else /* DS_ALLOC_MODE == DS_ALLOC_MACRO */

#  ifdef DS_ALLOC_HEADER
#    include DS_ALLOC_HEADER
#  endif
#  include <stdlib.h>
#  include <string.h>
#  ifndef DS_MALLOC
#    define DS_MALLOC(n)      malloc((n))
#  endif
#  ifndef DS_CALLOC
#    define DS_CALLOC(n, sz)  calloc((n), (sz))
#  endif
#  ifndef DS_REALLOC
#    define DS_REALLOC(p, n)  realloc((p), (n))
#  endif
#  ifndef DS_FREE
#    define DS_FREE(p)        free((p))
#  endif
#  ifndef DS_STRDUP
#    define DS_STRDUP(s)      strdup((s))
#  endif
#  ifndef DS_STRNDUP
#    define DS_STRNDUP(s, n)  strndup((s), (n))
#  endif

#endif

#endif /* LIBDS2_DS_ALLOC_H */

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_re2.h — C-callable RE2, the engine DS's regex is defined by ([LREG.7.1],
 * [LREG.8.1]). A build that disables the `regex` dialect form links none of this.
 */
#ifndef LIBDS2_DS_RE2_H
#define LIBDS2_DS_RE2_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque compiled pattern. Owns its RE2; free with ds_re2_free. */
typedef struct ds_re2 ds_re2_t;

/* DS's three regex flags ([LREG.5]). */
#define DS_RE2_ICASE      (1u << 0)   /* `i` — fold case. */
#define DS_RE2_MULTILINE  (1u << 1)   /* `m` — `^`/`$` also match at line
                                         boundaries. */
#define DS_RE2_DOTALL     (1u << 2)   /* `s` — `.` matches `\n` too. */

/* Compile `pattern` under `flags`. NULL on an invalid pattern, with RE2's own text
 * in `err` when err != NULL. A failed allocation is also NULL, with DS_RE2_ERR_OOM
 * in `err`, for the caller to compare against this definition. */
#define DS_RE2_ERR_OOM "out of memory compiling regex"

ds_re2_t *ds_re2_compile(const char *pattern,
                         unsigned    flags,
                         char       *err,
                         size_t      errcap);

/* Same, over `len` bytes, which need not be followed by a NUL. */
ds_re2_t *ds_re2_compile_n(const char *pattern,
                           size_t      len,
                           unsigned    flags,
                           char       *err,
                           size_t      errcap);

/* The match entry points can run out of memory ([IALC.3.6]): they then return false
 * and set `*oom`, which a caller must never read as "no match" ([IERR.8.7]). `*oom`
 * is written on every call and must not be NULL. RE2 is not documented as
 * exception-safe, so drop a pattern after an `*oom`. */

/* True iff `re` matches anywhere in the NUL-terminated `text`. */
bool ds_re2_match(const ds_re2_t *re, const char *text, bool *oom);

/* Same, over `len` bytes, so an embedded NUL is matched against. */
bool ds_re2_match_n(const ds_re2_t *re, const char *text, size_t len,
                    bool *oom);

int ds_re2_group_count(const ds_re2_t *re);

/* Name of capturing group `index` (1-based), or NULL when it is unnamed or out of
 * range. The string is owned by `re`, until ds_re2_free. */
const char *ds_re2_group_name(const ds_re2_t *re, int index);

/* Capture extraction ([LREG.4.1]): one partial match, filling groups 1..n_out.
 * On false the out arrays are untouched. A group that did not participate gets
 * (NULL, 0), as does one past the pattern's count: bound n_out by ds_re2_group_count
 * to tell them apart.
 *
 * The pieces point into `text`: intern or copy before it goes away. */
bool ds_re2_capture(const ds_re2_t  *re,
                    const char      *text,
                    const char     **out_ptr,
                    size_t          *out_len,
                    int              n_out,
                    bool            *oom);

/* Same, over `len` bytes of `text`, which need not be followed by a NUL. */
bool ds_re2_capture_n(const ds_re2_t  *re,
                      const char      *text,
                      size_t           len,
                      const char     **out_ptr,
                      size_t          *out_len,
                      int              n_out,
                      bool            *oom);

/* NULL-safe. */
void ds_re2_free(ds_re2_t *re);

/* Whether this build links RE2 ([RDSC.16.2.7], [NLFC.10.1]). */
bool ds_re2_available(void);

#ifdef __cplusplus
}   /* extern "C" */
#endif

#endif  /* LIBDS2_DS_RE2_H */

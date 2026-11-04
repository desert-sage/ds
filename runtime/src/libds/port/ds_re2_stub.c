/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * port/ds_re2_stub.c — the `regex` dialect form, declined: no pattern compiles, and
 * nothing of RE2 is linked. test_re2_stub_covers_header.py holds this file to ds_re2.h.
 *
 * In `port/`, so a build names it explicitly: a missing reference is an undefined
 * symbol at link, not a runtime that quietly matches nothing.
 */
#include "ds_re2.h"

ds_re2_t *ds_re2_compile(const char *pattern, unsigned flags,
                         char *err, size_t errcap)
{
    (void) pattern; (void) flags;
    if (err != NULL && errcap > 0) {
        static const char msg[] = "regex unavailable: this build links no RE2";
        size_t i = 0;
        while (msg[i] != '\0' && i + 1 < errcap) { err[i] = msg[i]; i++; }
        err[i] = '\0';
    }
    return NULL;
}

ds_re2_t *ds_re2_compile_n(const char *pattern, size_t len, unsigned flags,
                           char *err, size_t errcap)
{
    (void) len;
    return ds_re2_compile(pattern, flags, err, errcap);
}

/* `*oom` is false on every entry point here: nothing is allocated. */
bool ds_re2_match(const ds_re2_t *re, const char *text, bool *oom)
{
    (void) re; (void) text;
    if (oom != NULL) *oom = false;
    return false;
}

bool ds_re2_match_n(const ds_re2_t *re, const char *text, size_t len,
                    bool *oom)
{
    (void) re; (void) text; (void) len;
    if (oom != NULL) *oom = false;
    return false;
}

int ds_re2_group_count(const ds_re2_t *re)
{
    (void) re;
    return 0;
}

const char *ds_re2_group_name(const ds_re2_t *re, int index)
{
    (void) re; (void) index;
    return NULL;
}

bool ds_re2_capture(const ds_re2_t  *re,
                    const char      *text,
                    const char     **out_ptr,
                    size_t          *out_len,
                    int              n_out,
                    bool            *oom)
{
    (void) re; (void) text; (void) out_ptr; (void) out_len; (void) n_out;
    if (oom != NULL) *oom = false;
    return false;
}

bool ds_re2_capture_n(const ds_re2_t  *re,
                      const char      *text,
                      size_t           len,
                      const char     **out_ptr,
                      size_t          *out_len,
                      int              n_out,
                      bool            *oom)
{
    (void) len;
    return ds_re2_capture(re, text, out_ptr, out_len, n_out, oom);
}

void ds_re2_free(ds_re2_t *re)
{
    (void) re;
}

/* The build's `regex` capability ([RDSC.16.2.7]): absent. */
bool ds_re2_available(void)
{
    return false;
}

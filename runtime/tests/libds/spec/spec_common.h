/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * spec_common.h — small conveniences for spec tests.
 *
 * Public API only — the standard fail/expect_* helpers plus spec_load_ds()
 * (compile DS source to .dsc via the `dsc` CLI, then ds_engine_load_dsc).
 * Everything else a spec test needs lives in libds.h. No internal headers.
 */
#ifndef LIBDS2_SPEC_COMMON_H
#define LIBDS2_SPEC_COMMON_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "libds.h"

static inline int spec_fail(const char *msg, ds_result_t r)
{
    fprintf(stderr, "FAIL: %s: status=%d detail=%s\n",
            msg, r.status, r.detail ? r.detail : "(null)");
    return 1;
}

#define EXPECT_OK(what, r) do { \
    if ((r).status != DS_OK) return spec_fail(what, (r)); \
} while (0)

#define EXPECT_STATUS(what, r, want) do { \
    if ((r).status != (want)) { \
        fprintf(stderr, "FAIL: %s: want status %d, got %d (%s)\n", \
                what, (want), (r).status, \
                (r).detail ? (r).detail : "(null)"); \
        return 1; \
    } \
} while (0)

/* Whether `ds_src` has a `use` line: `use` at the start of a line, followed by
 * a space, a `:` or the line's end ([LGRA.3.1]). */
static inline int spec_has_use_line(const char *ds_src)
{
    for (const char *p = ds_src; p != NULL; p = strchr(p, '\n')) {
        if (*p == '\n') p++;
        if (strncmp(p, "use", 3) == 0
                && (p[3] == ' ' || p[3] == ':' || p[3] == '\n'
                    || p[3] == '\0'))
            return 1;
    }
    return 0;
}

/* -------- DS rule loading --------
 *
 * libds loads only compiled .dsc artefacts. spec_load_ds() writes DS source
 * to a scratch file, compiles it with the `dsc` this commit built
 * (DS_MERCURY_DSC, below), and loads the artefact.
 *
 * Returns the ds_engine_load_dsc result, or DS_ERR_PARSE if the compiler
 * refuses the source or a scratch file fails. Black-box: public API, libc
 * and the `dsc` CLI only.
 *
 * A source with no `use` line is compiled as though it began with
 * `use default`: without one it is a library ([LDIA.2.10.1]), which `dsc`
 * refuses to build ([LDIA.2.10.8]).
 *
 * The scratch files go under DS_MERCURY_SCRATCH, the real-disk directory
 * scripts/private/gate/gate.py makes for every gate that has the compiler,
 * never under /tmp (BUILD-RUNBOOK.md §4). An unset variable is an error, not
 * a fallback. */
static inline int spec_scratch_template(char *buf, size_t n, const char *stem)
{
    const char *dir = getenv("DS_MERCURY_SCRATCH");
    if (!dir || !*dir) return 0;
    int w = snprintf(buf, n, "%s/%s_XXXXXX", dir, stem);
    return w > 0 && (size_t) w < n;
}

/* Compile `ds_src` as spec_load_ds does and hand back the artefact's bytes,
 * which the caller frees with free(): for a test that edits an artefact
 * before it loads it. The status is spec_load_ds's for the same failure. */
static inline ds_result_t spec_compile_ds(const char *ds_src,
                                          uint8_t **out, size_t *out_len)
{
    *out = NULL;
    *out_len = 0;
    char ds_path[1024];
    char dsc_path[1024];
    if (!spec_scratch_template(ds_path, sizeof ds_path, "spec_ds")
            || !spec_scratch_template(dsc_path, sizeof dsc_path, "spec_dsc"))
        return DS_ERR_R(DS_ERR_PARSE,
                        "spec_load_ds: DS_MERCURY_SCRATCH is unset or too long");
    int  dfd = mkstemp(ds_path);
    if (dfd < 0) return DS_ERR_R(DS_ERR_PARSE, "spec_load_ds: mkstemp(.ds)");
    int  cfd = mkstemp(dsc_path);
    if (cfd < 0) {
        close(dfd); unlink(ds_path);
        return DS_ERR_R(DS_ERR_PARSE, "spec_load_ds: mkstemp(.dsc)");
    }
    close(cfd);                 /* dsc writes the artefact itself */

    FILE *df = fdopen(dfd, "w");
    if (!df) {
        close(dfd); unlink(ds_path); unlink(dsc_path);
        return DS_ERR_R(DS_ERR_PARSE, "spec_load_ds: fdopen");
    }
    if (!spec_has_use_line(ds_src))
        fputs("use default\n", df);
    fputs(ds_src, df);
    fclose(df);

    /* The compiler is the one this commit built: mercury.build makes
     * `.build/mdsc/dsc_cli`, and scripts/private/gate/gate.py names it in
     * DS_MERCURY_DSC for every gate. PATH is not consulted, since a `dsc`
     * there is whatever the image carries, and the artefact must come from
     * this commit's compiler to load in this commit's libds ([LDET.1.10]). */
    const char *dsc = getenv("DS_MERCURY_DSC");
    if (!dsc || !*dsc) {
        unlink(ds_path); unlink(dsc_path);
        return DS_ERR_R(DS_ERR_PARSE,
                        "spec_load_ds: DS_MERCURY_DSC is unset: no compiler");
    }
    /* A command that does not fit is an error, not a truncated command. The
     * compiler's output goes to the test's stderr, so the test's stdout stays
     * its verdict and a refusal's diagnostics are in the log. */
    char cmd[4096];
    int w = snprintf(cmd, sizeof cmd,
                     "'%s' compile '%s' -o '%s' 1>&2",
                     dsc, ds_path, dsc_path);
    if (w < 0 || (size_t) w >= sizeof cmd) {
        unlink(ds_path); unlink(dsc_path);
        return DS_ERR_R(DS_ERR_PARSE, "spec_load_ds: dsc command too long");
    }
    int rc = system(cmd);
    if (rc != 0) {
        unlink(ds_path); unlink(dsc_path);
        return DS_ERR_R(DS_ERR_PARSE, "spec_load_ds: dsc compile failed");
    }

    FILE *cf = fopen(dsc_path, "rb");
    if (!cf) {
        unlink(ds_path); unlink(dsc_path);
        return DS_ERR_R(DS_ERR_PARSE, "spec_load_ds: open .dsc");
    }
    fseek(cf, 0, SEEK_END);
    long n = ftell(cf);
    fseek(cf, 0, SEEK_SET);
    if (n <= 0) {
        fclose(cf); unlink(ds_path); unlink(dsc_path);
        return DS_ERR_R(DS_ERR_PARSE, "spec_load_ds: empty .dsc");
    }
    uint8_t *buf = (uint8_t *) malloc((size_t) n);
    if (!buf) {
        fclose(cf); unlink(ds_path); unlink(dsc_path);
        return DS_ERR_R(DS_ERR_OOM, "spec_load_ds: OOM");
    }
    size_t got = fread(buf, 1, (size_t) n, cf);
    fclose(cf);
    unlink(ds_path);
    unlink(dsc_path);
    if (got != (size_t) n) {
        free(buf);
        return DS_ERR_R(DS_ERR_PARSE, "spec_load_ds: short read");
    }
    *out = buf;
    *out_len = got;
    return DS_OK_R;
}

static inline ds_result_t spec_load_ds(ds_engine_t *engine, const char *ds_src)
{
    uint8_t *buf = NULL;
    size_t   len = 0;
    ds_result_t r = spec_compile_ds(ds_src, &buf, &len);
    if (r.status != DS_OK) return r;
    r = ds_engine_load_dsc(engine, buf, len);
    free(buf);
    return r;
}

#endif /* LIBDS2_SPEC_COMMON_H */

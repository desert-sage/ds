/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * conformance_main — allocator-override conformance harness (IALC.10).
 *
 * Shows an integrator allocator override captures every libds allocation.
 * libds.build links it two ways, each against its own libds.a:
 *
 *   weak  (strong ds_*, DS_ALLOC_MODE=2 libds.a)
 *   macro (DS_ALLOC_HEADER=ds_probe_macros.h)
 *
 * and scripts/libds/run_conf.py runs each binary once per workload, which
 * argv[1] names. Either link mode routes every libds allocation to the
 * magic-header probe, so each run asserts:
 *   - the override IS taken         (probe_n_alloc > 0)        IALC.5
 *   - no cross-allocator free       (probe_n_badfree == 0)
 *   - every byte is released        (probe_outstanding == 0)   IALC.10.2
 * The full-dsc workload also drives protobuf-c
 * (ds_engine_load_dsc -> &ds_pb_allocator -> DS_MALLOC/DS_FREE -> probe),
 * so its balance shows protobuf-c both allocates and frees through the
 * override.
 *
 * The harness's own bookkeeping (the .dsc read buffer) uses libc directly
 * and is invisible to the probe.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "libds.h"
#include "alloc_probe.h"

/* In libds.a but not libds.h ([NRTM.9.1]; src/libds/engine.h). This harness
   is built against the public include directory only, so it declares the one
   internal call it makes. */
ds_result_t ds_engine_set_wm_max(ds_engine_t *engine, uint32_t n_max);

/* Compile a tiny .ds to a real .dsc with the `dsc` CLI — the spec_load_ds
 * pattern (runtime/tests/libds/spec/spec_common.h). On success *out is a libc
 * buffer of *out_len bytes, the caller's to free(). The libc malloc/free here
 * are the harness's own and are not probed. */
static ds_result_t compile_real_dsc(const char *ds_src, uint8_t **out,
                                    size_t *out_len)
{
    /* Scratch under DS_MERCURY_SCRATCH, the real-disk directory scripts/private/gate/gate.py
     * makes beside DS_MERCURY_DSC, never under /tmp (BUILD-RUNBOOK.md §4),
     * as spec_load_ds does. Unset is an error, not a fallback. */
    const char *scratch = getenv("DS_MERCURY_SCRATCH");
    char ds_path[1024];
    char dsc_path[1024];
    if (!scratch || !*scratch
            || snprintf(ds_path, sizeof ds_path, "%s/ialc_ds_XXXXXX", scratch)
                   >= (int) sizeof ds_path
            || snprintf(dsc_path, sizeof dsc_path, "%s/ialc_dsc_XXXXXX", scratch)
                   >= (int) sizeof dsc_path)
        return DS_ERR_R(DS_ERR_PARSE, "DS_MERCURY_SCRATCH is unset or too long");
    int  dfd = mkstemp(ds_path);
    if (dfd < 0) return DS_ERR_R(DS_ERR_PARSE, "mkstemp .ds");
    int  cfd = mkstemp(dsc_path);
    if (cfd < 0) { close(dfd); unlink(ds_path); return DS_ERR_R(DS_ERR_PARSE, "mkstemp .dsc"); }
    close(cfd);

    FILE *df = fdopen(dfd, "w");
    if (!df) { close(dfd); unlink(ds_path); unlink(dsc_path); return DS_ERR_R(DS_ERR_PARSE, "fdopen"); }
    fputs(ds_src, df);
    fclose(df);

    /* The Mercury `dsc` this commit's ci.build built (`mdsc-bin`), which
     * scripts/private/gate/gate.py names in DS_MERCURY_DSC -- the compiler `conformance` uses,
     * for the reason spec_common.h's spec_load_ds states. Not `dsc` on PATH,
     * and no fallback to it. */
    const char *dsc = getenv("DS_MERCURY_DSC");
    if (!dsc || !*dsc) {
        unlink(ds_path); unlink(dsc_path);
        return DS_ERR_R(DS_ERR_PARSE, "DS_MERCURY_DSC is unset: no compiler to compile the workload");
    }
    char cmd[4096];
    int w = snprintf(cmd, sizeof cmd,
             /* stderr stays visible: a refused workload must say why, or a
                compile failure reads as nothing but "-100 dsc compile failed". */
             "'%s' compile '%s' -o '%s' >/dev/null",
             dsc, ds_path, dsc_path);
    /* A truncated command would run something other than the compile. */
    if (w < 0 || (size_t) w >= sizeof cmd) {
        unlink(ds_path); unlink(dsc_path);
        return DS_ERR_R(DS_ERR_PARSE, "dsc command too long");
    }
    if (system(cmd) != 0) { unlink(ds_path); unlink(dsc_path); return DS_ERR_R(DS_ERR_PARSE, "dsc compile failed"); }

    FILE *cf = fopen(dsc_path, "rb");
    if (!cf) { unlink(ds_path); unlink(dsc_path); return DS_ERR_R(DS_ERR_PARSE, "open .dsc"); }
    fseek(cf, 0, SEEK_END);
    long n = ftell(cf);
    fseek(cf, 0, SEEK_SET);
    if (n <= 0) { fclose(cf); unlink(ds_path); unlink(dsc_path); return DS_ERR_R(DS_ERR_PARSE, "empty .dsc"); }
    uint8_t *buf = (uint8_t *) malloc((size_t) n);   /* libc: harness-owned, not probed */
    if (!buf) { fclose(cf); unlink(ds_path); unlink(dsc_path); return DS_ERR_R(DS_ERR_OOM, "OOM"); }
    size_t got = fread(buf, 1, (size_t) n, cf);
    fclose(cf);
    unlink(ds_path);
    unlink(dsc_path);
    if (got != (size_t) n) { free(buf); return DS_ERR_R(DS_ERR_PARSE, "short read"); }
    *out     = buf;
    *out_len = got;
    return DS_OK_R;
}

/* Compile, and load the artefact into `engine`. */
static ds_result_t load_real_dsc(ds_engine_t *engine, const char *ds_src)
{
    uint8_t *buf = NULL;
    size_t   len = 0;
    ds_result_t r = compile_real_dsc(ds_src, &buf, &len);
    if (r.status != DS_OK) return r;
    r = ds_engine_load_dsc(engine, buf, len);
    free(buf);
    return r;
}

/* No protobuf: engine lifecycle + JSON parse/serialize round-trip, the
 * owned raw buffer released via ds_free (IALC.4.3). */
static int run_no_protobuf(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) { fprintf(stderr, "engine_new\n"); return 1; }

    const char *src = "{\"a\":1,\"b\":[2,3,4],\"c\":\"hello world\",\"d\":{\"e\":true}}";
    ds_json_t  *t = NULL;
    if (ds_json_parse(src, strlen(src), &t).status != DS_OK) { fprintf(stderr, "json_parse\n"); return 1; }
    char  *out = NULL;
    size_t ol  = 0;
    if (ds_json_serialize(t, &out, &ol).status != DS_OK || out == NULL) { fprintf(stderr, "json_serialize\n"); return 1; }
    ds_free(out);
    ds_json_free(t);
    ds_engine_free(e);
    return 0;
}

/* Full DSC cycle: compile + load a real artefact, which unpacks/free_unpacks
 * its protobuf atoms through &ds_pb_allocator -> the override. */
static int run_full_dsc(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) { fprintf(stderr, "engine_new\n"); return 1; }

    ds_result_t r = load_real_dsc(
        e,
        "use default\n\n"
        "schema ShortTTL scope ttl 100_ms:\n    v: Int\n\n"
        "schema Logical scope logical:\n    v: Int key\n");
    if (r.status != DS_OK) {
        fprintf(stderr, "load_dsc: %d %s\n", r.status, r.detail ? r.detail : "(null)");
        ds_engine_free(e);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* [RDSC.9.8]'s exception: THE SITES WHOSE FAILURE A LOAD MAY
 * ABSORB, each an allocation of capacity the engine also grows on demand,
 * with why. A site is the file and function that make the request, as the
 * macro leg's probe records them (ds_probe_macros.h). A function is the finest
 * grain the probe sees: rehash_into is also how an insert grows the table
 * (intern.c, grow), and that caller returns its failure, so a failure a load
 * absorbs in rehash_into is ds_rete_intern_presz's. A site added here is a
 * reading of the clause, and goes to the spec coordinator with its reason. */
static const struct {
    const char *file;   /* what __FILE__ ends with, after a '/' or whole */
    const char *func;
    const char *why;
} RDSC_9_8_ABSORBABLE[] = {
    { "rete/intern.c", "rehash_into",
      "ds_rete_intern_presz's pre-size of the intern table (rete/loader.c), "
      "which an insert grows on demand" },
};
#define N_RDSC_9_8_ABSORBABLE \
    (sizeof RDSC_9_8_ABSORBABLE / sizeof RDSC_9_8_ABSORBABLE[0])

static bool rdsc_9_8_file_is(const char *file, const char *want)
{
    const size_t n = strlen(file), m = strlen(want);
    return n >= m && strcmp(file + n - m, want) == 0
        && (n == m || file[n - m - 1] == '/');
}

/* The table's row for a site, or -1. */
static int rdsc_9_8_absorbable(const char *file, const char *func)
{
    if (file == NULL || func == NULL) return -1;
    for (size_t k = 0; k < N_RDSC_9_8_ABSORBABLE; k++)
        if (rdsc_9_8_file_is(file, RDSC_9_8_ABSORBABLE[k].file)
                && strcmp(func, RDSC_9_8_ABSORBABLE[k].func) == 0)
            return (int) k;
    return -1;
}

/* THE VERDICT ON ONE FAILED REQUEST, request `i` of `n_load`, whose load
 * answered `status`, made at (file, func). `sited` is whether this leg's
 * requests name their sites. NULL passes; anything else is the reason the
 * request fails the sweep. A pure function, so the fixture below can feed it
 * every shape it must refuse. */
static const char *rdsc_9_8_judge(size_t i, size_t n_load, ds_status_t status,
                                  bool sited, const char *file, const char *func)
{
    if (status == DS_OK) {
        if (i == n_load)
            return "the last request, the apply phase's, was absorbed: it must "
                   "fail the load with DS_ERR_OOM";
        if (!sited) return NULL;   /* the weak leg: see run_rdsc_9_8_oom */
        if (rdsc_9_8_absorbable(file, func) < 0)
            return "a load absorbed a failure at a site [RDSC.9.8] does not let "
                   "it absorb: no capacity grown on demand, by this table";
        return NULL;
    }
    if (i == n_load && status != DS_ERR_OOM)
        return "the last request, the apply phase's, failed the load with "
               "another status than DS_ERR_OOM";
    return NULL;
}

/* A row of the table no failed request was absorbed at, or -1: the table names
 * a site this load no longer absorbs at, and is stale. */
static int rdsc_9_8_stale(const size_t *absorbed_at)
{
    for (size_t k = 0; k < N_RDSC_9_8_ABSORBABLE; k++)
        if (absorbed_at[k] == 0) return (int) k;
    return -1;
}

/* THE NEGATIVE FIXTURE ([STYL.5.10.5]): the judge and
 * the staleness check, fed on every run each shape they must refuse and the
 * shapes they must pass. A judge that passed everything would pass the sweep
 * too, and a sweep over a fixed libds shows none of the refusals. */
static int rdsc_9_8_fixture(void)
{
    static const struct {
        size_t i, n; ds_status_t status; bool sited;
        const char *file, *func; bool refused; const char *what;
    } cases[] = {
        { 3, 9, DS_OK, true, "schema.c", "schema_reg_map_rebuild", true,
          "an absorbed failure at a site the table does not name" },
        { 3, 9, DS_OK, true, NULL, NULL, true,
          "an absorbed failure with no site, in the sited leg" },
        { 3, 9, DS_OK, true, "xrete/intern.c", "rehash_into", true,
          "a file that only ends like the table's" },
        { 3, 9, DS_OK, true, "rete/intern.c", "grow", true,
          "the table's file, another function" },
        { 9, 9, DS_OK, true, "rete/intern.c", "rehash_into", true,
          "the last request absorbed, even at the table's site" },
        { 9, 9, DS_OK, false, NULL, NULL, true,
          "the last request absorbed, in the unsited leg" },
        { 9, 9, DS_ERR_DSC_DECODE, true, "engine.c", "f", true,
          "the last request failing the load with another status" },
        { 3, 9, DS_OK, true, "rete/intern.c", "rehash_into", false,
          "an absorbed failure at the table's site" },
        { 3, 9, DS_OK, true, "src/libds/rete/intern.c", "rehash_into", false,
          "the table's file, under a longer path" },
        { 3, 9, DS_OK, false, NULL, NULL, false,
          "an absorbed failure in the unsited leg, before the last" },
        { 9, 9, DS_ERR_OOM, true, "engine.c", "ds_engine_rule_meta_map_rebuild",
          false, "the last request failing the load with DS_ERR_OOM" },
        { 3, 9, DS_ERR_DSC_DECODE, true, "ds_pb_alloc.c", "f", false,
          "an earlier request failing the load with another status" },
    };
    int failed = 0;
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        const char *v = rdsc_9_8_judge(cases[c].i, cases[c].n, cases[c].status,
                                       cases[c].sited, cases[c].file,
                                       cases[c].func);
        if ((v != NULL) != cases[c].refused) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom fixture]: %s was %s\n",
                    cases[c].what, v != NULL ? "refused" : "passed");
            failed = 1;
        }
    }
    size_t none[N_RDSC_9_8_ABSORBABLE] = {0}, each[N_RDSC_9_8_ABSORBABLE];
    for (size_t k = 0; k < N_RDSC_9_8_ABSORBABLE; k++) each[k] = 1;
    if (rdsc_9_8_stale(none) < 0) {
        fprintf(stderr, "FAIL[rdsc-9-8-oom fixture]: a table row nothing was "
                "absorbed at was not called stale\n");
        failed = 1;
    }
    if (rdsc_9_8_stale(each) >= 0) {
        fprintf(stderr, "FAIL[rdsc-9-8-oom fixture]: a table every row of "
                "which absorbed was called stale\n");
        failed = 1;
    }
    return failed;
}

/* [RDSC.9.8]: A LOAD WHOSE ALLOCATION FAILS IS SPENT, unless the allocation
 * reserved capacity the engine also grows on demand, and the engine still
 * releases everything it holds ([NCBK.2.9]).
 *
 * One artefact with schemas, a rule and an `initial:` block, compiled once.
 * CONTROL, twice: a clean load on a fresh engine, counting the allocation
 * requests it makes. The two counts must agree, or a fault injected below
 * would land on a request other than the one counted. Then every request in
 * turn, each on a fresh engine, request i failing. Each is judged
 * (rdsc_9_8_judge):
 *   - a load that fails must spend its engine -- ds_engine_halted reads halted
 *     with DS_ENGINE_FAULT_UNSPECIFIED ([NCBK.2.11]), a second load and a pump
 *     are DS_ERR_ENGINE_HALTED -- and ds_engine_free must answer DS_OK;
 *   - a load that absorbs the failure must have absorbed it at a site
 *     RDSC_9_8_ABSORBABLE names, and every row must absorb at least once;
 *   - THE LAST REQUEST IS THE APPLY PHASE'S: the walk precedes dsc_apply and
 *     nothing after it allocates. Its failure must fail the load with
 *     DS_ERR_OOM ([NERR.8.2]); absorbing it fails the sweep.
 * main()'s balance check after the sweep is the teardown half: no byte
 * outstanding after any of those partial loads. Other failed loads are a
 * census of codes, not judged on their code: an allocation inside a protobuf-c
 * unpack fails as the unpack does, so the walk can report it as
 * DS_ERR_DSC_DECODE.
 *
 * THE SITES ARE JUDGED IN THE MACRO LEG ONLY. Its requests name their sites,
 * and RDSC_9_8_SITED says so: if none does, its libds.a was not built with
 * ds_probe_macros.h, and the sweep fails rather than judge nothing. The weak
 * leg's allocator is reached through ds_malloc, which names no caller, so it
 * judges everything but the site. Both legs run the same libds code over the
 * same requests, which the control loads count alike. */
/* @spec [RDSC.9.8] */
static int run_rdsc_9_8_oom(void)
{
#ifdef RDSC_9_8_SITED
    const bool sited = true;
#else
    const bool sited = false;
#endif
    if (rdsc_9_8_fixture() != 0) return 1;

    static const char SRC[] =
        "use default\n"
        "\n"
        "schema Reading scope logical:\n"
        "    id: String key\n"
        "    v: Int mutable\n"
        "\n"
        "schema Seen scope explicit:\n"
        "    k: Int\n"
        "\n"
        "initial:\n"
        "    Seen k: 1\n"
        "    cache \"a\": 1\n"
        "\n"
        "rule high:\n"
        "    Reading r where r.v > 10\n"
        "->\n"
        "    log info \"high {r.id}\"\n";
    uint8_t *dsc = NULL;
    size_t   len = 0;
    ds_result_t r = compile_real_dsc(SRC, &dsc, &len);
    if (r.status != DS_OK) {
        fprintf(stderr, "compile: %d %s\n", r.status, r.detail ? r.detail : "(null)");
        return 1;
    }

    int    failed = 0;
    size_t n_load = 0;
    for (int k = 0; k < 2 && !failed; k++) {
        ds_engine_t *e = NULL;
        if (ds_engine_new(NULL, &e).status != DS_OK) { free(dsc); return 1; }
        const size_t before = probe_n_requests(), sited0 = probe_n_sited();
        r = ds_engine_load_dsc(e, dsc, len);
        const size_t used = probe_n_requests() - before;
        const size_t with_site = probe_n_sited() - sited0;
        ds_engine_free(e);
        if (r.status != DS_OK) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom]: control load: %d %s\n",
                    r.status, r.detail ? r.detail : "(null)");
            failed = 1;
        } else if (used == 0) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom]: the control load made no "
                    "request the probe saw\n");
            failed = 1;
        } else if (sited && with_site == 0) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom]: the macro leg's control load "
                    "made %zu requests and none named its site: libds.a was "
                    "not built with ds_probe_macros.h\n", used);
            failed = 1;
        } else if (k == 1 && used != n_load) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom]: the control loads made %zu "
                    "and %zu requests\n", n_load, used);
            failed = 1;
        }
        n_load = used;
    }

    /* The census: how many failed loads answered each status. */
    struct { int status; size_t n; } census[16];
    size_t n_census = 0, n_ok = 0, n_leaky = 0;
    size_t absorbed_at[N_RDSC_9_8_ABSORBABLE] = {0};
    for (size_t i = 1; i <= n_load && !failed; i++) {
        /* Each request's own balance: what is outstanding, and the bad frees,
           from before its engine exists to after it is freed. */
        const size_t out0 = probe_outstanding(), bad0 = probe_n_badfree();
        char detail[200] = "";
        ds_engine_t *e = NULL;
        if (ds_engine_new(NULL, &e).status != DS_OK) { free(dsc); return 1; }
        probe_fail_at(i);
        r = ds_engine_load_dsc(e, dsc, len);
        snprintf(detail, sizeof detail, "%s", r.detail ? r.detail : "");
        const int reached = probe_failed();
        const char *file = NULL, *func = NULL;
        probe_failed_site(&file, &func);
        probe_fail_at(0);
        const char *verdict = reached
            ? rdsc_9_8_judge(i, n_load, r.status, sited, file, func) : NULL;
        if (!reached) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom]: request %zu of %zu was never "
                    "made\n", i, n_load);
            failed = 1;
        } else if (verdict != NULL) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom]: request %zu of %zu, at %s %s, "
                    "load status %d: %s\n", i, n_load,
                    file ? file : "(no site)", func ? func : "", r.status,
                    verdict);
            failed = 1;
        }
        if (reached && r.status == DS_OK) {
            /* A failure the load absorbed, at a site the table names (or in
               the weak leg, which names none). */
            n_ok++;
            const int row = rdsc_9_8_absorbable(file, func);
            if (row >= 0) absorbed_at[row]++;
            printf("  absorbed: request %zu of %zu at %s %s\n", i, n_load,
                   file ? file : "(no site)", func ? func : "");
        } else if (reached) {
            bool halted = false;
            ds_engine_fault_t fault = DS_ENGINE_FAULT_ARTEFACT_LIED;
            ds_result_t hr = ds_engine_halted(e, &halted, &fault);
            ds_status_t again = ds_engine_load_dsc(e, dsc, len).status;
            ds_status_t pump  = ds_engine_pump(e).status;
            if (hr.status != DS_OK || !halted
                || fault != DS_ENGINE_FAULT_UNSPECIFIED
                || again != DS_ERR_ENGINE_HALTED
                || pump != DS_ERR_ENGINE_HALTED) {
                fprintf(stderr, "FAIL[rdsc-9-8-oom]: request %zu failed, load "
                        "status %d: halted=%d fault=%d, a second load %d, a "
                        "pump %d\n", i, r.status, (int) halted, (int) fault,
                        again, pump);
                failed = 1;
            }
            size_t c = 0;
            while (c < n_census && census[c].status != r.status) c++;
            if (c == n_census && n_census < sizeof census / sizeof census[0]) {
                census[n_census].status = r.status;
                census[n_census].n      = 0;
                n_census++;
            }
            if (c < n_census) census[c].n++;
        }
        if (ds_engine_free(e).status != DS_OK) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom]: ds_engine_free after request "
                    "%zu failed\n", i);
            failed = 1;
        }
        /* [NCBK.2.9]: the engine releases everything it holds, whatever state
           the failed load left. Named per request, so the site can be found;
           main()'s totals would only say that some request leaked. */
        const size_t leaked = probe_outstanding() - out0;
        const size_t bad    = probe_n_badfree() - bad0;
        if (leaked != 0 || bad != 0) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom]: request %zu of %zu (load "
                    "status %d, %s): %zu byte(s) left outstanding, %zu bad "
                    "free(s) after ds_engine_free\n", i, n_load, r.status,
                    detail, leaked, bad);
            n_leaky++;
        }
    }
    free(dsc);
    if (n_leaky != 0) failed = 1;

    if (!failed && n_ok == n_load) {
        fprintf(stderr, "FAIL[rdsc-9-8-oom]: no failed request failed the "
                "load\n");
        failed = 1;
    }
    if (!failed && sited) {
        const int stale = rdsc_9_8_stale(absorbed_at);
        if (stale >= 0) {
            fprintf(stderr, "FAIL[rdsc-9-8-oom]: no failure was absorbed at "
                    "%s %s, which the table lets a load absorb (%s): the "
                    "table is stale\n", RDSC_9_8_ABSORBABLE[stale].file,
                    RDSC_9_8_ABSORBABLE[stale].func,
                    RDSC_9_8_ABSORBABLE[stale].why);
            failed = 1;
        }
    }
    if (!sited)
        printf("  rdsc-9-8-oom: the weak leg's requests name no site; the "
               "absorbable-site table is judged in the macro leg\n");
    {   /* Printed pass or fail: the data, not a verdict. */
        printf("  rdsc-9-8-oom: %zu requests per load, each failed in turn; "
               "%zu absorbed, %zu leaky;", n_load, n_ok, n_leaky);
        for (size_t c = 0; c < n_census; c++)
            printf(" status %d x%zu", census[c].status, census[c].n);
        printf("\n");
    }
    return failed;
}

/* [IALC.8.2]: under `+constspace` the pump is allocation-free; [NRTM.1.1]:
 * steady-state operation does no `malloc`. Engage the constant-space pools,
 * supersede one key repeatedly, and count the probe's allocations across the
 * loop. With `constspace` false the same workload runs with the pools off.
 *
 * No go_live: a +constspace-only engine does not transition through INIT/LIVE
 * ([LCSP.6.5]), so the pump runs with the pools engaged and the series row
 * map open.
 *
 * The count is a delta, not a probe_reset(): a reset mid-run would make
 * teardown read as cross-allocator frees.
 *
 * One fixed String identity, interned on the warm-up assert, and a Float
 * payload, so the delta is the pump's and not interning's.
 *
 * The program declares no series, so this says nothing of the
 * superseded-sample queue a series on a keyed schema adds: the grammar has no
 * bounded sliding ring-buffer series under +constspace. */
static int run_supersede_alloc(bool constspace, size_t *out_delta)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) {
        fprintf(stderr, "engine_new\n");
        return 1;
    }

    /* The +constspace CapabilityInfo arms pending_rt at load; set_wm_max engages the
     * slab pools. The control compiles the same program without it, so the
     * same workload runs with pools OFF. */
    ds_result_t r = load_real_dsc(
        e,
        constspace
        ? "use default:\n"
          "    constspace: true\n"
          "\n"
          "schema Trade scope logical:\n"
          "    symbol: String key\n"
          "    price: Float mutable\n"
          "\n"
          "rule r:\n"
          "    Trade t where t.price > 0.0\n"
          "->\n"
          "    log info \"x\"\n"
        : "use default\n"
          "\n"
          "schema Trade scope logical:\n"
          "    symbol: String key\n"
          "    price: Float mutable\n"
          "\n"
          "rule r:\n"
          "    Trade t where t.price > 0.0\n"
          "->\n"
          "    log info \"x\"\n");
    if (r.status != DS_OK) {
        fprintf(stderr, "load_dsc [%s]: %d %s\n",
                constspace ? "constspace" : "control",
                r.status, r.detail ? r.detail : "(null)");
        ds_engine_free(e);
        return 1;
    }

    /* Engages the slab pools. Not on the control: set_wm_max allocates the
     * pools, so the control would run pooled too. */
    if (constspace) {
        r = ds_engine_set_wm_max(e, 64);
        if (r.status != DS_OK) {
            fprintf(stderr, "set_wm_max: %s\n", r.detail ? r.detail : "(null)");
            ds_engine_free(e);
            return 1;
        }
    }

    const ds_schema_t *sc = NULL;
    if (ds_engine_schema_find(e, "Trade", &sc).status != DS_OK || sc == NULL) {
        fprintf(stderr, "schema_find(Trade)\n");
        ds_engine_free(e);
        return 1;
    }

    /* One assert to warm every lazily-allocated thing (the intern entry for
       the identity, the WM row). */
    ds_slot_value_t v[2];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_STRING; v[0].v.s = "AAPL";
    v[1].kind = DS_SLOT_FLOAT;  v[1].v.f = 100.0;
    ds_fact_t *f = NULL;
    if (ds_engine_assert(e, sc, v, 2, &f).status != DS_OK) {
        fprintf(stderr, "warm assert\n"); ds_engine_free(e); return 1;
    }
    (void)ds_engine_pump(e);

    const size_t before = probe_n_alloc();

    /* Several asserts against the SAME key per pump: each supersedes a fact
     * the pump has not yet seen. */
    for (int round = 0; round < 16; round++) {
        for (int i = 0; i < 4; i++) {
            v[1].v.f = 100.0 + (double)(round * 4 + i);   /* same key */
            f = NULL;
            if (ds_engine_assert(e, sc, v, 2, &f).status != DS_OK) {
                fprintf(stderr, "steady assert %d/%d\n", round, i);
                ds_engine_free(e);
                return 1;
            }
        }
        (void)ds_engine_pump(e);           /* drains the queue */
    }

    const size_t after = probe_n_alloc();
    if (out_delta) *out_delta = after - before;

    /* Did the supersedes land? A zero delta is ambiguous between
       "allocation-free" and "never ran", so the workload has to show it ran.
       65 asserts against one key on a logical schema must leave exactly ONE
       fact: zero means the asserts never reached working memory, and more
       than one means they did not supersede. */
    size_t live = 0;
    if (ds_engine_fact_count(e, &live).status != DS_OK || live != 1) {
        fprintf(stderr,
                "FAIL[%s]: %zu live Trade fact(s) after 65 same-key asserts, "
                "expected 1 — the supersede path did not run, so a zero "
                "allocation delta would mean 'never ran', not "
                "'allocation-free'\n",
                constspace ? "constspace" : "control", live);
        ds_engine_free(e);
        return 1;
    }

    ds_engine_free(e);

    return 0;
}

/* Not run: constspace is deferred, so the compiler refuses the
 * `constspace: true` program run_supersede_alloc builds, and run_conf.py does
 * not name this workload.
 *
 * [RTCT.12.3] — "the zero-allocation chart is evidence only beside a non-RT
 * control showing non-zero. A zero with no positive control is
 * indistinguishable from a dead counter."
 *
 * So this runs the SAME workload twice: once with +constspace (pools engaged,
 * must allocate nothing per IALC.8.2) and once without (same code path, no
 * pools, expected to allocate). A zero from the first is only meaningful
 * beside a non-zero from the second. */
static int run_rt_supersede(void)
{
    size_t rt_delta = 0, ctl_delta = 0;

    if (run_supersede_alloc(true,  &rt_delta)  != 0) return 1;
    if (run_supersede_alloc(false, &ctl_delta) != 0) return 1;

    int failed = 0;
    if (ctl_delta == 0) {
        fprintf(stderr,
                "FAIL[rt-supersede]: control allocated nothing either — the "
                "probe is not observing this path, so the +constspace zero "
                "proves nothing (RTCT.12.3)\n");
        failed = 1;
    }
    if (rt_delta != 0) {
        fprintf(stderr,
                "FAIL[rt-supersede]: %zu allocation(s) in +constspace steady "
                "state; the pump must be allocation-free (IALC.8.2 / "
                "NRTM.1.1). Control allocated %zu.\n", rt_delta, ctl_delta);
        failed = 1;
    }
    if (!failed)
        printf("  rt-supersede: +constspace=0 alloc, control=%zu (positive "
               "control live)\n", ctl_delta);
    return failed;
}

int main(int argc, char **argv)
{
    const char *wl = (argc > 1) ? argv[1] : "no-protobuf";

    probe_reset();
    int rc;
    if      (strcmp(wl, "no-protobuf") == 0) rc = run_no_protobuf();
    else if (strcmp(wl, "full-dsc")    == 0) rc = run_full_dsc();
    else if (strcmp(wl, "rt-supersede") == 0) rc = run_rt_supersede();
    else if (strcmp(wl, "rdsc-9-8-oom") == 0) rc = run_rdsc_9_8_oom();
    else { fprintf(stderr, "unknown workload: %s\n", wl); return 2; }

    if (rc != 0) { fprintf(stderr, "FAIL[%s]: workload errored\n", wl); return 1; }

    int failed = 0;
    if (probe_n_alloc() == 0) {
        fprintf(stderr, "FAIL[%s]: override never taken (n_alloc=0) — libds did "
                        "not allocate through the probe\n", wl);
        failed = 1;
    }
    if (probe_n_badfree() != 0) {
        fprintf(stderr, "FAIL[%s]: %zu cross-allocator free(s)\n", wl, probe_n_badfree());
        failed = 1;
    }
    if (probe_outstanding() != 0) {
        fprintf(stderr, "FAIL[%s]: %zu byte(s) outstanding after teardown (leak)\n",
                wl, probe_outstanding());
        failed = 1;
    }

    if (!failed) {
        printf("alloc_conformance[%s]: OK (n_alloc=%zu outstanding=0; override taken, balanced)\n",
               wl, probe_n_alloc());
    }
    return failed;
}

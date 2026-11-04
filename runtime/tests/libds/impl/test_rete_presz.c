/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Pre-sizing the hash tables:
 *   - ds_rete_intern_presz / lock
 *   - ds_rete_alpha_mem_presz
 *   - ds_rete_tms_presz
 *   - ds_rete_wm_presz
 *   - ds_rete_terminal_presz_refract
 *   - ds_rete_engine_presz_rt_tables: all tables reach target capacity
 *   - Intern lock: growth attempt after lock returns DS_ERR_OOM
 *   - Non-RT engine: presz_rt_tables returns DS_ERR_RT_UNSAFE
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/alpha.h"
#include "rete/engine.h"
#include "rete/intern.h"
static int g_mode = 0;
#include "test_dual_mode.h"

#include "rete/pool.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/tms.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d (%s)\n",
                what, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

static int expect_status(const char *what, ds_result_t r, int want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want %d got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

/* Build an RT engine with pools ready, N_max = n_max. */
static ds_rete_engine_t *make_rt_engine(ds_rete_schema_t **schema_out,
                                         uint32_t n_max)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false },
        { .name = "k", .type = DS_RETE_VAL_STR, .is_key = true  },
    };
    ds_rete_schema_register(e, "T", DS_RETE_SCOPE_PLAIN, 0,
                             slots, 2, schema_out);
    ds_rete_engine_set_wm_max(e, n_max);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_token_depth(e, 4);
    ds_rete_engine_init_rt_pools(e);
    return e;
}

/* Expected pre-size capacity: next pow2 >= 4 * N_max, min 8. */
static size_t expected_cap(uint32_t n)
{
    size_t target = (n == 0) ? 8u : (size_t)n * 4u;
    size_t c = 8u;
    while (c < target) c <<= 1;
    return c;
}

static int test_intern_presz_grows(void)
{
    ds_rete_intern_t *intern = NULL;
    ds_rete_intern_init(&intern);
    /* Default cap is 64 (INIT_BUCKETS). Pre-size to 256. */
    if (expect_ok("intern_presz", ds_rete_intern_presz(intern, 256))) return 1;
    /* Intern a string — should succeed. */
    const char *p;
    if (expect_ok("intern after presz",
                  ds_rete_intern_cstr(intern, "hello", &p))) return 1;
    ds_rete_intern_destroy(intern);
    return 0;
}

static int test_intern_lock_blocks_growth(void)
{
    /* intern_init starts at cap 64 (INIT_BUCKETS), and an insert grows the
       table once n * 100 / cap reaches 70 (MAX_LOAD_PCT) before it: 45
       strings fit, and the 46th would grow it. */
    ds_rete_intern_t *intern = NULL;
    ds_rete_intern_init(&intern);
    ds_rete_intern_lock(intern); /* lock at cap=64 */

    const char *p;
    char buf[8];
    for (int i = 0; i < 44; i++) {
        snprintf(buf, sizeof(buf), "s%d", i);
        if (expect_ok("intern before limit",
                      ds_rete_intern_cstr(intern, buf, &p))) return 1;
    }
    snprintf(buf, sizeof(buf), "s44");
    if (expect_ok("intern s44", ds_rete_intern_cstr(intern, buf, &p))) return 1;
    if (expect_status("intern over limit",
                      ds_rete_intern_cstr(intern, "overflow_unique_xyz_999", &p),
                      DS_ERR_OOM)) return 1;
    /* Re-intern already-known string must still succeed (no growth needed). */
    if (expect_ok("re-intern existing",
                  ds_rete_intern_cstr(intern, "s0", &p))) return 1;
    ds_rete_intern_destroy(intern);
    return 0;
}

static int test_alpha_mem_presz(void)
{
    /* Alpha memory is an oa map: create a node so the map's hash/eq
       callbacks are initialised, then presz reserves it. */
    ds_rete_alpha_node_t *n = NULL;
    if (expect_ok("create", ds_rete_alpha_node_create(0, NULL, 0, &n))) return 1;
    if (expect_ok("alpha_mem_presz", ds_rete_alpha_mem_presz(&n->memory, 64))) return 1;
    if (n->memory.map.cap < 64) return fail("alpha mem cap should be >= 64");
    ds_rete_alpha_node_destroy(n);
    return 0;
}

static int test_tms_presz(void)
{
    ds_tms_table_t tms;
    ds_tms_table_init(&tms);
    if (expect_ok("tms_presz", ds_tms_presz(&tms, 128))) return 1;
    if (tms.map.cap < 128) return fail("tms cap should be >= 128");
    ds_tms_table_destroy(&tms);
    return 0;
}

static int test_wm_presz(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    /* WM is an oa map with cap 0 at create; presz reserves so `target` live
       facts fit without a later grow. */
    size_t target = 256;
    if (expect_ok("wm_presz", ds_rete_wm_presz(e, target))) return 1;
    if (e->wm_map.cap < target) return fail("wm cap should grow to target");
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_terminal_presz_refract(void)
{
    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create("test_rule", 0, &term);
    if (expect_ok("presz_refract", ds_rete_terminal_presz_refract(term, 64)))
        return 1;
    if (term->refract_cap < 64) return fail("refract cap should be >= 64");
    ds_rete_terminal_destroy(term);
    return 0;
}

static int test_presz_rt_tables_full(void)
{
    SKIP_IF_NON_RT;
    ds_rete_schema_t *schema = NULL;
    uint32_t N = 16;
    ds_rete_engine_t *e = make_rt_engine(&schema, N);

    if (expect_ok("presz_rt_tables",
                  ds_rete_engine_presz_rt_tables(e))) return 1;

    size_t cap = expected_cap(N);

    /* WM map */
    if (e->wm_map.cap < cap)
        return fail("WM hash cap below expected");

    /* Per-schema identity hash */
    if (schema->id_dedup) {
        if (schema->id_map.cap < cap)
            return fail("identity hash cap below expected");
    }

    /* TMS table */
    if (e->tms.map.cap < cap)
        return fail("TMS cap below expected");

    /* Intern table is locked — presz with tiny cap is a noop (already larger). */
    ds_result_t pr = ds_rete_intern_presz(e->intern, 1);
    if (pr.status != DS_OK)
        return fail("intern presz(1) on large table should be noop/ok");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_presz_requires_rt_mode(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    if (expect_status("presz without rt_mode",
                      ds_rete_engine_presz_rt_tables(e),
                      DS_ERR_RT_UNSAFE)) return 1;
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_presz_requires_pools_ready(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_engine_set_wm_max(e, 10);
    ds_rete_engine_set_rt_mode(e, true);
    /* pools not initialised */
    if (expect_status("presz without pools",
                      ds_rete_engine_presz_rt_tables(e),
                      DS_ERR_RT_UNSAFE)) return 1;
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_wm_does_not_grow_after_presz(void)
{
    SKIP_IF_NON_RT;
    /* After presz_rt_tables, asserting N_max facts must NOT trigger a WM
       resize: cap stays constant. */
    ds_rete_schema_t *schema = NULL;
    uint32_t N = 8;
    ds_rete_engine_t *e = make_rt_engine(&schema, N);
    ds_rete_engine_presz_rt_tables(e);

    size_t cap_before = e->wm_map.cap;
    char name[3] = {0};
    for (uint32_t i = 0; i < N; i++) {
        name[0] = 'a' + (char)i;
        const char *iname;
        ds_rete_intern_cstr(e->intern, name, &iname);
        ds_rete_val_t s[] = {
            ds_rete_val_int((int64_t)i),
            ds_rete_val_str(iname, 1),
        };
        ds_rete_fact_t *f = NULL;
        if (expect_ok("assert", ds_rete_wm_assert(e, 0, s, &f))) return 1;
    }
    if (e->wm_map.cap != cap_before)
        return fail("WM cap changed after presz — resize occurred");

    ds_rete_engine_destroy(e);
    return 0;
}

int main(void)
{
    int total_fails = 0;
    const char *tags[] = {"non-RT", "RT"};

    for (int mode = 0; mode <= 1; mode++) {
        g_mode = mode;
        const char *tag = tags[mode];
        int fails = 0;
        printf("\n=== test_rete_presz [%s] ===\n", tag);

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL [%s]: " #t "\n", tag); fails++; } \
    else    { printf("  pass [%s]: " #t "\n", tag); } \
} while (0)

        RUN(test_intern_presz_grows);
        RUN(test_intern_lock_blocks_growth);
        RUN(test_alpha_mem_presz);
        RUN(test_tms_presz);
        RUN(test_wm_presz);
        RUN(test_terminal_presz_refract);
        RUN(test_presz_rt_tables_full);
        RUN(test_presz_requires_rt_mode);
        RUN(test_presz_requires_pools_ready);
        RUN(test_wm_does_not_grow_after_presz);

#undef RUN

        if (fails == 0)
            printf("=== test_rete_presz [%s]: ALL PASSED ===\n", tag);
        else
            fprintf(stderr, "=== test_rete_presz [%s]: %d FAILED ===\n", tag, fails);
        total_fails += fails;
    }
    return total_fails ? 1 : 0;
}

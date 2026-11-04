/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_rete_go_live():
 *   - DS_ERR_RT_LIVE when engine is already in LIVE mode
 *   - DS_ERR_RT_PRECOND when rt_mode not enabled (P1)
 *   - DS_ERR_RT_PRECOND when wm_max_facts == 0 (P2)
 *   - DS_ERR_RT_PRECOND when pools not ready (P3)
 *   - DS_ERR_RT_PRECOND when presz_rt_tables not called / intern not locked (P4)
 *   - DS_ERR_RT_PRECOND when max_fires_rt == 0 (P5)
 *   - DS_ERR_RT_PRECOND when clock_fn is NULL (P6)
 *   - DS_OK on successful go_live: flags set correctly
 *   - presz_rt_tables returns DS_ERR_RT_LIVE after go_live
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "rete/engine.h"
#include "rete/intern.h"
#include "rete/schema_reg.h"

static int g_mode = 0;

#include "test_dual_mode.h"

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

/* go_live refused for the precondition `tag` names ("RTDS.8.2/P2"), and no
   other. Every precondition answers DS_ERR_RT_PRECOND, so the status alone
   would pass a test whose own guard was gone and a later one refused. */
static int expect_precond(const char *what, ds_result_t r, const char *tag)
{
    if (expect_status(what, r, DS_ERR_RT_PRECOND)) return 1;
    if (!r.detail || !strstr(r.detail, tag)) {
        fprintf(stderr, "FAIL: %s: want a refusal for %s, got (%s)\n",
                what, tag, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

static int64_t mock_clock(void *ctx) { (void)ctx; return 1000000000LL; }

/* Build a fully-initialised engine ready for go_live, N=16. */
static ds_rete_engine_t *make_ready_engine(void)
{
    ds_rete_engine_t *e = NULL;
    if (ds_rete_engine_create(&e).status != DS_OK) return NULL;
    ds_rete_set_clock(e, mock_clock, NULL);
    ds_rete_engine_set_wm_max(e, 16);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_max_fires_rt(e, 4);
    if (ds_rete_engine_init_rt_pools(e).status != DS_OK) {
        ds_rete_engine_destroy(e); return NULL;
    }
    if (ds_rete_engine_presz_rt_tables(e).status != DS_OK) {
        ds_rete_engine_destroy(e); return NULL;
    }
    return e;
}

/* Each precondition test meets every precondition before its own, so it
   fails if its own guard is removed. */

static int test_go_live_already_live(void)
{
    ds_rete_engine_t *e = make_ready_engine();
    if (!e) return fail("make_ready_engine");
    int r = 0;
    r += expect_ok("first go_live", ds_rete_go_live(e));
    r += expect_status("second go_live", ds_rete_go_live(e), DS_ERR_RT_LIVE);
    ds_rete_engine_destroy(e);
    return r;
}

static int test_go_live_precond_no_rt_mode(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_set_clock(e, mock_clock, NULL);
    /* rt_mode NOT set */
    int r = expect_precond("no rt_mode", ds_rete_go_live(e), "RTDS.8.2/P1");
    ds_rete_engine_destroy(e);
    return r;
}

static int test_go_live_precond_no_wm_max(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_set_clock(e, mock_clock, NULL);
    ds_rete_engine_set_wm_max(e, 16);
    ds_rete_engine_set_rt_mode(e, true);
    /* set_rt_mode refuses while wm_max_facts is 0, so rt_mode is set with a
       cap first and the cap cleared last: P1 passes and P2 refuses. */
    e->wm_max_facts = 0;
    int r = expect_precond("no wm_max", ds_rete_go_live(e), "RTDS.8.2/P2");
    ds_rete_engine_destroy(e);
    return r;
}

static int test_go_live_precond_no_pools(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_set_clock(e, mock_clock, NULL);
    ds_rete_engine_set_wm_max(e, 16);
    ds_rete_engine_set_rt_mode(e, true);
    /* init_rt_pools NOT called */
    int r = expect_precond("no pools", ds_rete_go_live(e), "RTDS.8.2/P3");
    ds_rete_engine_destroy(e);
    return r;
}

static int test_go_live_precond_no_presz(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_set_clock(e, mock_clock, NULL);
    ds_rete_engine_set_wm_max(e, 16);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_max_fires_rt(e, 4);
    ds_rete_engine_init_rt_pools(e);
    /* presz_rt_tables NOT called — intern not locked */
    int r = expect_precond("no presz", ds_rete_go_live(e), "RTDS.8.2/P4");
    ds_rete_engine_destroy(e);
    return r;
}

static int test_go_live_precond_no_max_fires(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_set_clock(e, mock_clock, NULL);
    ds_rete_engine_set_wm_max(e, 16);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_init_rt_pools(e);
    ds_rete_engine_presz_rt_tables(e);
    /* max_fires_rt cleared last, so no setup step can give it a value. */
    e->max_fires_rt = 0;
    int r = expect_precond("no max_fires", ds_rete_go_live(e), "RTDS.8.2/P5");
    ds_rete_engine_destroy(e);
    return r;
}

static int test_go_live_precond_no_clock(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_engine_set_wm_max(e, 16);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_max_fires_rt(e, 4);
    ds_rete_engine_init_rt_pools(e);
    ds_rete_engine_presz_rt_tables(e);
    /* ds_rete_engine_create installs a default clock; cleared last, so no
       setup step can install one again. */
    e->clock_fn = NULL;
    int r = expect_precond("no clock", ds_rete_go_live(e), "RTDS.8.2/P6");
    ds_rete_engine_destroy(e);
    return r;
}

static int test_go_live_success_flags(void)
{
    ds_rete_engine_t *e = make_ready_engine();
    if (!e) return fail("make_ready_engine");
    int r = 0;
    r += expect_ok("go_live", ds_rete_go_live(e));
    if (!e->live)                 r += fail("live not set");
    ds_rete_engine_destroy(e);
    return r;
}

static int test_presz_blocked_after_live(void)
{
    ds_rete_engine_t *e = make_ready_engine();
    if (!e) return fail("make_ready_engine");
    int r = 0;
    r += expect_ok("go_live", ds_rete_go_live(e));
    r += expect_status("presz after live",
                       ds_rete_engine_presz_rt_tables(e), DS_ERR_RT_LIVE);
    ds_rete_engine_destroy(e);
    return r;
}

int main(void)
{
    int fails = 0;

    fails += test_go_live_already_live();
    fails += test_go_live_precond_no_rt_mode();
    fails += test_go_live_precond_no_wm_max();
    fails += test_go_live_precond_no_pools();
    fails += test_go_live_precond_no_presz();
    fails += test_go_live_precond_no_max_fires();
    fails += test_go_live_precond_no_clock();
    fails += test_go_live_success_flags();
    fails += test_presz_blocked_after_live();

    if (fails == 0)
        printf("OK  test_rete_go_live (%d tests)\n", 9);
    else
        fprintf(stderr, "FAILED: %d test(s) failed\n", fails);

    return fails ? 1 : 0;
}

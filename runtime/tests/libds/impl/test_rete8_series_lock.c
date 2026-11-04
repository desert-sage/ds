/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The series state registry's row_map lock:
 *   - ds_series_state_registry_lock sets row_map_locked.
 *   - lookup_or_insert succeeds before lock (returns a row).
 *   - lookup_or_insert returns NULL after lock for an unknown key.
 *   - lookup_or_insert still returns existing rows after lock.
 *   - go_live on a standalone Rete engine skips the series lock
 *     (ds_engine_back is NULL — series lock is a noop; no crash).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "rete/engine.h"
#include "series/state.h"

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

static int64_t mock_clock(void *ctx) { (void)ctx; return 1000000000LL; }

static ds_series_state_registry_t make_reg(void)
{
    ds_series_state_registry_t reg;
    ds_series_state_registry_init(&reg);
    return reg;
}

static int test_lock_sets_flag(void)
{
    ds_series_state_registry_t reg = make_reg();
    if (reg.row_map_locked)
        return fail("row_map_locked should be false after init");
    ds_series_state_registry_lock(&reg);
    if (!reg.row_map_locked)
        return fail("row_map_locked should be true after lock");
    ds_series_state_registry_dispose(&reg);
    return 0;
}

static int test_lookup_or_insert_before_lock(void)
{
    ds_series_state_registry_t reg = make_reg();
    /* lookup_or_insert with a NULL engine is OK when there are no slot
       backends yet (current_slot_count=0, no grow_row_slots call). */
    ds_series_state_row_t *row = ds_series_state_lookup_or_insert(
        NULL, &reg, 0, "Schema", "slot", "id", "val1", 0u);
    int fails = 0;
    if (row == NULL) fails += fail("lookup_or_insert before lock should succeed");
    ds_series_state_registry_dispose(&reg);
    return fails;
}

static int test_lookup_or_insert_blocked_after_lock(void)
{
    ds_series_state_registry_t reg = make_reg();
    ds_series_state_registry_lock(&reg);
    /* Unknown key after lock — should return NULL (engine=NULL, no pending set). */
    ds_series_state_row_t *row = ds_series_state_lookup_or_insert(
        NULL, &reg, 0, "Schema", "slot", "id", "new_val", 0u);
    int fails = 0;
    if (row != NULL)
        fails += fail("lookup_or_insert after lock for unknown key should return NULL");
    ds_series_state_registry_dispose(&reg);
    return fails;
}

static int test_existing_row_still_found_after_lock(void)
{
    ds_series_state_registry_t reg = make_reg();
    ds_series_state_row_t *before = ds_series_state_lookup_or_insert(
        NULL, &reg, 0, "Schema", "slot", "id", "val1", 0u);
    if (before == NULL) {
        ds_series_state_registry_dispose(&reg);
        return fail("insert before lock failed");
    }
    ds_series_state_registry_lock(&reg);
    ds_series_state_row_t *after = ds_series_state_lookup_or_insert(
        NULL, &reg, 0, "Schema", "slot", "id", "val1", 0u);
    int fails = 0;
    if (after == NULL)
        fails += fail("existing row not found after lock");
    else if (after != before)
        fails += fail("returned different row after lock for same key");
    ds_series_state_registry_dispose(&reg);
    return fails;
}

static int test_go_live_standalone_no_crash(void)
{
    ds_rete_engine_t *engine = NULL;
    if (ds_rete_engine_create(&engine).status != DS_OK)
        return fail("engine_create");
    ds_rete_set_clock(engine, mock_clock, NULL);
    ds_rete_engine_set_wm_max(engine, 16);
    ds_rete_engine_set_rt_mode(engine, true);
    ds_rete_engine_set_max_fires_rt(engine, 4);
    ds_rete_engine_init_rt_pools(engine);
    ds_rete_engine_presz_rt_tables(engine);
    /* engine->ds_engine_back is NULL — series_go_live is skipped. */
    int fails = 0;
    fails += expect_ok("go_live standalone", ds_rete_go_live(engine));
    ds_rete_engine_destroy(engine);
    return fails;
}

int main(void)
{
    int fails = 0;

    fails += test_lock_sets_flag();
    fails += test_lookup_or_insert_before_lock();
    fails += test_lookup_or_insert_blocked_after_lock();
    fails += test_existing_row_still_found_after_lock();
    fails += test_go_live_standalone_no_crash();

    if (fails == 0)
        printf("OK  test_rete8_series_lock (%d tests)\n", 5);
    else
        fprintf(stderr, "FAILED: %d test(s) failed\n", fails);

    return fails ? 1 : 0;
}

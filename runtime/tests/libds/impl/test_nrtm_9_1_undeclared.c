/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The entry points this edition does not declare stay out of libds.h. The
 * test is that this file compiles against libds.h alone: each name is
 * declared here as something else, so a libds.h that still declares it is a
 * conflicting redeclaration, and a macro libds.h still defines is an
 * `#error`. Every name is `static`, so none collides at link time with
 * libds's internal definitions (engine.h keeps some for libds's own tests
 * and the RFCS replayer).
 *
 * Held out: realtime's entry points ([NRTM.9.1], [NRTM.3.1]); hydration's
 * two, deferred with hydration ([LHYD.6.2], [LHYD.7.4]); host schema
 * registration ([NFCT.1.1]); and three codes with no producer, retired as
 * [IERR.2.8a] retires a code. test_series_backend_internal holds out the
 * samples plane's.
 *
 * What stays public is used too, so the test cannot pass by libds.h losing
 * it: the cache's caps ([NSTG.2.6.1], [LSTO.4.7.5]), and the slot descriptor
 * and lifecycle enum that ds_schema_get_slot and ds_schema_get_lifecycle read
 * a loaded schema back through.
 */
#include <stdio.h>

#include "libds.h"

/* @spec [NRTM.9.1] */
/* @spec [NRTM.3.1] */
#if defined(DS_WM_UNLIMITED)
#error "libds.h still defines DS_WM_UNLIMITED ([NRTM.3.1])"
#endif

/* The retired codes. */
#if defined(DS_ERR_DUPLICATE)
#error "libds.h still defines DS_ERR_DUPLICATE (-6), which nothing returns"
#endif
#if defined(DS_ERR_SLOT_MARKER_INVALID)
#error "libds.h still defines DS_ERR_SLOT_MARKER_INVALID (-105), which nothing returns"
#endif
#if defined(DS_ERR_SCHEMA_DUPLICATE)
#error "libds.h still defines DS_ERR_SCHEMA_DUPLICATE (-603), which nothing returns"
#endif

static int ds_engine_go_live = 1;
static int ds_engine_get_rt_config_binding = 2;
static int ds_contract_dump_canonical = 3;
static int ds_engine_set_wm_max = 4;
static int ds_engine_set_rt_token_depth = 5;
static int ds_engine_set_rt_token_pool_cap = 6;
static int ds_engine_set_rt_presz_cap = 7;
typedef struct { char c; } ds_rt_config_binding_t;

/* Hydration. */
static int ds_engine_assert_with_ttl = 8;
static int ds_engine_set_hydration_budget = 9;

/* @spec [NFCT.1.1] */
static int ds_engine_register_schema = 10;

int main(void)
{
    int sum = ds_engine_go_live + ds_engine_get_rt_config_binding
            + ds_contract_dump_canonical + ds_engine_set_wm_max
            + ds_engine_set_rt_token_depth + ds_engine_set_rt_token_pool_cap
            + ds_engine_set_rt_presz_cap
            + ds_engine_assert_with_ttl + ds_engine_set_hydration_budget
            + ds_engine_register_schema;
    ds_rt_config_binding_t b = { 'b' };

    /* What stays public. */
    ds_result_t (*cap)(ds_engine_t *, uint32_t, uint64_t) =
        ds_engine_set_cache_cap;
    ds_slot_desc_t slot = { .name = "s", .type = DS_SLOT_TYPE_INT };
    ds_schema_lifecycle_t life = DS_SCHEMA_LIFECYCLE_LOGICAL;

    if (sum != 55 || b.c != 'b' || cap == NULL || slot.type != DS_SLOT_TYPE_INT
            || life != DS_SCHEMA_LIFECYCLE_LOGICAL) {
        fprintf(stderr, "FAIL: test_nrtm_9_1_undeclared\n");
        return 1;
    }
    printf("OK  test_nrtm_9_1_undeclared\n");
    return 0;
}

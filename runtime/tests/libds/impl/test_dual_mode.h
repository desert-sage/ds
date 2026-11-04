/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_dual_mode.h — shared infrastructure for running Rete tests in
 * both non-RT (g_mode=0) and RT (g_mode=1) configurations.
 *
 * Include once per test file, before any test functions.
 *
 * Usage:
 *   - Declare: static int g_mode = 0;
 *   - Call apply_rt(engine, n_max) after schema registration.
 *   - Guard mode-specific tests with SKIP_IF_RT / SKIP_IF_NON_RT.
 */
#ifndef TEST_DUAL_MODE_H
#define TEST_DUAL_MODE_H

#include "rete/engine.h"

/* Default RT parameters used when a test doesn't specify its own. */
#define DM_RT_N_MAX        64u
#define DM_RT_TOKEN_DEPTH  4u

/* Skip helpers — return 0 (pass/skip) in the wrong mode. */
#define SKIP_IF_RT     do { if (g_mode == 1) return 0; } while (0)
#define SKIP_IF_NON_RT do { if (g_mode == 0) return 0; } while (0)

/*
 * apply_rt — configure an engine for RT mode when g_mode == 1.
 * Call after all schemas are registered, before any asserts.
 * n_max: 0 = use DM_RT_N_MAX.
 *
 * Requires: extern int g_mode; declared visible before this header.
 * Each test file declares: static int g_mode = 0;  BEFORE the #include.
 */
static void apply_rt(ds_rete_engine_t *e, uint32_t n_max)
{
    if (g_mode != 1) return;
    if (n_max == 0) n_max = DM_RT_N_MAX;
    ds_rete_engine_set_wm_max(e, n_max);
    ds_rete_engine_set_rt_mode(e, true);
    ds_rete_engine_set_token_depth(e, DM_RT_TOKEN_DEPTH);
    ds_rete_engine_init_rt_pools(e);
    ds_rete_engine_presz_rt_tables(e);
}

/* Unused: `_run_both_modes_impl` is defined nowhere, and each test file runs
   both modes from its own main(). */
#define RUN_BOTH_MODES(suite, body) \
    _run_both_modes_impl(suite, _SUITE_BODY_##suite)

#endif /* TEST_DUAL_MODE_H */

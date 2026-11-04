/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The realtime pump's wall-clock time (CLOCK_MONOTONIC) under an adversarial
 * load: N_RULES single-pattern rules on one schema, N_ASSERT new facts a pump,
 * so N_RULES x N_ASSERT firings, through fire_fn callbacks so nothing
 * allocates. It prints pmin, pmean, pmax and the T_wcet fit coefficients.
 *
 * The budget (RETE4_WCET_BUDGET_NS, default 10 ms) is asserted only when
 * DS_WCET_ASSERT=1. The clock reads the host's load as much as the Rete:
 * under a parallel build natively, and far more under valgrind, whose lane
 * runs the same binary. An honest budget is microseconds, and a budget wide
 * enough to survive a contended host would always pass.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <inttypes.h>

#include "libds.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/intern.h"
#include "rete/loader.h"
#include "rete/pool.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

#define N_RULES      8
#define WM_MAX      128
#define N_PUMP_ITER 1000
#define N_ASSERT     8      /* new facts per cycle; wraps by val%WM_MAX */
#define DEFAULT_BUDGET_NS  ((int64_t)10000000LL)  /* 10 ms */

static int64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int fail_msg(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d (%s)\n",
                what, r.status, r.detail ? r.detail : "");
        return 1;
    }
    return 0;
}

static volatile long g_fires = 0;
static void fire_cb(const char *r, ds_rete_token_t *t, void *ctx)
{
    (void)r; (void)t; (void)ctx;
    g_fires++;
}

static ds_rete_engine_t *build_adversarial_engine(void)
{
    ds_rete_engine_t *e = NULL;
    if (ds_rete_engine_create(&e).status != DS_OK) return NULL;

    ds_rete_slot_desc_t slots[] = {{ .name="val", .type=DS_RETE_VAL_INT }};
    ds_rete_schema_t *sc = NULL;
    if (ds_rete_schema_register(e, "Trig", DS_RETE_SCOPE_PLAIN, 0,
                                slots, 1, &sc).status != DS_OK) goto fail;

    /* N_RULES independent single-pattern rules, each alpha node separate. */
    static ds_alfa_atom_t alfas[N_RULES];
    static ds_beta_atom_t betas[N_RULES];
    static ds_term_atom_t terms[N_RULES];
    static char rule_names[N_RULES][32];

    for (int i = 0; i < N_RULES; i++) {
        snprintf(rule_names[i], sizeof(rule_names[i]), "rule_%d", i);
        alfas[i].node_id    = (uint32_t)(1 + 2*i);
        alfas[i].schema_name= "Trig";
        alfas[i].tests      = NULL;
        alfas[i].test_count = 0;
        betas[i].node_id        = (uint32_t)(2 + 2*i);
        betas[i].right_alpha_id = (uint32_t)(1 + 2*i);
        betas[i].left_parent_id = 0;
        betas[i].join_tests     = NULL;
        betas[i].join_test_count= 0;
        betas[i].is_negative    = false;
        terms[i].node_id        = (uint32_t)(2*N_RULES + 1 + i);
        terms[i].parent_beta_id = (uint32_t)(2 + 2*i);
        terms[i].rule_name      = rule_names[i];
        terms[i].bind_count     = 1;
        terms[i].actions        = NULL;
        terms[i].action_count   = 0;
    }
    ds_rete_network_t net = { .alfas=alfas, .alfa_count=N_RULES,
                              .betas=betas, .beta_count=N_RULES,
                              .terms=terms, .term_count=N_RULES };
    if (expect_ok("load_network", ds_rete_load_network(e, &net))) goto fail;

    for (uint32_t i = 0; i < e->owned_terminal_count; i++)
        e->owned_terminals[i]->fire_fn = fire_cb;

    if (expect_ok("set_wm_max", ds_rete_engine_set_wm_max(e, WM_MAX))) goto fail;
    if (expect_ok("set_rt_mode", ds_rete_engine_set_rt_mode(e, true))) goto fail;
    if (expect_ok("init_rt_pools", ds_rete_engine_init_rt_pools(e))) goto fail;
    if (expect_ok("presz_rt_tables", ds_rete_engine_presz_rt_tables(e))) goto fail;
    /* Prime token_budget with one empty run. */
    ds_rete_run(e, 1, NULL);
    return e;

fail:
    ds_rete_engine_destroy(e);
    return NULL;
}

static int test_wcet_measurement(int64_t budget_ns, int gate)
{
    ds_rete_engine_t *e = build_adversarial_engine();
    if (!e) return fail_msg("build_adversarial_engine failed");

    ds_rete_schema_t *sc = e->schemas_by_id[0];
    const uint32_t max_fires = (uint32_t)(N_ASSERT * N_RULES + 16);

    int64_t pmin  =  INT64_MAX;
    int64_t pmax  = -INT64_MAX;
    int64_t ptotal = 0;
    long    total_fires = 0;

    for (int iter = 0; iter < N_PUMP_ITER; iter++) {
        e->cycle_generation++;

        /* Assert N_ASSERT Trig facts with distinct values (wraps by val%WM_MAX).
           Plain scope: same val identity replaces old fact, keeping WM bounded. */
        for (int j = 0; j < N_ASSERT; j++) {
            int64_t val = (int64_t)((iter * N_ASSERT + j) % WM_MAX);
            ds_rete_val_t v = ds_rete_val_int(val);
            ds_rete_fact_t *f = NULL;
            ds_rete_wm_assert(e, sc->id, &v, &f);
        }

        int64_t t0 = now_ns();
        uint32_t fired = 0;
        g_fires = 0;
        ds_rete_run(e, max_fires, &fired);
        int64_t elapsed = now_ns() - t0;

        total_fires += g_fires;
        if (elapsed < pmin) pmin  = elapsed;
        if (elapsed > pmax) pmax  = elapsed;
        ptotal += elapsed;
    }

    int64_t pmean = ptotal / N_PUMP_ITER;

    printf("adversarial RT pump timing (%d iters):\n", N_PUMP_ITER);
    printf("  N_RULES=%d  N_ASSERT=%d  WM_MAX=%d  max_fires=%u\n",
           N_RULES, N_ASSERT, WM_MAX, max_fires);
    printf("  pmin  = %" PRId64 " ns\n", pmin);
    printf("  pmean = %" PRId64 " ns\n", pmean);
    printf("  pmax  = %" PRId64 " ns  (%.3f µs  %.3f ms)\n",
           pmax, (double)pmax/1e3, (double)pmax/1e6);
    printf("  total rules fired: %ld  avg/pump: %.1f\n",
           total_fires, (double)total_fires/N_PUMP_ITER);
    printf("T_wcet formula coefficients:\n");
    printf("  c_alpha = pmax / (R × N_max) = %.2f ns per rule per WM slot\n",
           (double)pmax / ((double)N_RULES * WM_MAX));
    printf("  c_fire  = pmax / max_fires   = %.2f ns per rule firing\n",
           (double)pmax / max_fires);
    printf("gate: budget=%" PRId64 " ns  pmax=%" PRId64 " ns  ",
           budget_ns, pmax);

    ds_rete_engine_destroy(e);

    if (!gate) {
        printf("NOT ASSERTED (set DS_WCET_ASSERT=1 to gate)\n");
        return 0;
    }
    if (pmax > budget_ns) {
        printf("FAIL\n");
        fprintf(stderr,
                "FAIL: pmax=%" PRId64 " ns > budget=%" PRId64 " ns\n",
                pmax, budget_ns);
        return 1;
    }
    printf("PASS\n");
    return 0;
}

int main(void)
{
    int64_t budget_ns = DEFAULT_BUDGET_NS;
    const char *env = getenv("RETE4_WCET_BUDGET_NS");
    if (env) {
        long long b = atoll(env);
        if (b > 0) budget_ns = (int64_t)b;
    }

    const char *gate_env = getenv("DS_WCET_ASSERT");
    const int gate = (gate_env && strcmp(gate_env, "1") == 0);

    int fail = 0;
    printf("--- WCET measurement (budget=%" PRId64 " ns%s) ---\n",
           budget_ns, gate ? "" : ", NOT asserted");
    fail |= test_wcet_measurement(budget_ns, gate);

    if (!fail) {
        printf("PASS: test_rete4_wcet%s\n",
               gate ? "" : " (measurement only — wall-clock gate not asserted)");
    }
    return fail;
}

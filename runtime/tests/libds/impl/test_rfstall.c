/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A TTL schema asserted on every tick, whose rule emits another TTL fact,
 * keeps firing through TTL churn: the rule fires on each of 60 mock-clock
 * ticks. The engine runs on the RT slab pools; DS_RFSTALL_RT=0 in the
 * environment runs it on malloc-backed facts instead.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d (%s)\n",
                what, r.status, r.detail ? r.detail : "");
        return 1;
    }
    return 0;
}

/* ---- fire counter (overrides the DS recorder before-fire hook) ---- */
static long g_fires = 0;
static void on_fire(const char *rule, void *ctx) { (void)rule; (void)ctx; g_fires++; }

/* ---- expr builders ---- */
static ds_rete_expr_t *lit_int(int64_t v)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = v; return e;
}

/* Register a single-int-slot schema; ds_engine_register_schema registers it
   into the Rete engine too, so the Rete handle is fetched by name. `scope`
   is unused. */
static int reg(ds_engine_t *engine, const char *name,
               ds_schema_lifecycle_t lc, ds_rete_scope_t scope, uint64_t ttl,
               const ds_schema_t **out_ds, const ds_rete_schema_t **out_rs)
{
    (void)scope;
    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_INT };
    ds_result_t r = ds_engine_register_schema(engine, name, lc, ttl, &sd, 1, out_ds);
    if (r.status != DS_OK) { fprintf(stderr, "FAIL: DS reg %s\n", name); return 1; }
    const ds_rete_schema_t *rs = ds_rete_schema_by_name(engine->rete_engine, name);
    if (rs == NULL) { fprintf(stderr, "FAIL: rete reg %s\n", name); return 1; }
    if (out_rs) *out_rs = rs;
    return 0;
}

int main(void)
{
    const char *rt_env = getenv("DS_RFSTALL_RT");
    bool rt = (rt_env == NULL) || (rt_env[0] != '0');
    const int TICKS = 60;
    const uint64_t HB_TTL = 3, PX_TTL = 15;

    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (expect_ok("engine_new", ds_engine_new(&cfg, &e))) return 1;
    if (expect_ok("clock_mode", ds_engine_clock_set_mode(e, DS_CLOCK_MOCK))) return 1;
    if (expect_ok("clock_set0", ds_engine_clock_set(e, 1))) return 1;

    /* Hb: TTL input with a rule. Px: TTL fact emitted by Hb's rule. */
    const ds_schema_t *hb_ds = NULL, *px_ds = NULL;
    const ds_rete_schema_t *hb_rs = NULL, *px_rs = NULL;
    if (reg(e, "Hb", DS_SCHEMA_LIFECYCLE_TTL, DS_RETE_SCOPE_TTL, HB_TTL, &hb_ds, &hb_rs)) return 1;
    if (reg(e, "Px", DS_SCHEMA_LIFECYCLE_TTL, DS_RETE_SCOPE_TTL, PX_TTL, &px_ds, &px_rs)) return 1;

    /* Network: AlphaNode(Hb) -> BetaNode(root x Hb) -> TerminalNode "hb_rule": emit Px(v=0). */
    ds_rete_expr_t *pv = lit_int(0);
    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = pv };
    ds_rete_action_t action = {
        .kind = DS_RETE_ACTION_ASSERT, .schema_id = px_rs->id,
        .assigns = &assign, .assign_count = 1,
    };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Hb" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{
        .node_id = 3, .parent_beta_id = 2, .rule_name = "hb_rule",
        .actions = &action, .action_count = 1,
    }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    if (expect_ok("load_network", ds_rete_load_network(e->rete_engine, &net))) {
        ds_rete_expr_free_tree(pv); return 1;
    }

    if (rt) {
        ds_rete_engine_t *re = e->rete_engine;
        if (expect_ok("set_wm_max",  ds_rete_engine_set_wm_max(re, 32))) return 1;
        if (expect_ok("set_rt_mode", ds_rete_engine_set_rt_mode(re, true))) return 1;
        if (expect_ok("token_depth", ds_rete_engine_set_token_depth(re, 4))) return 1;
        if (expect_ok("init_pools",  ds_rete_engine_init_rt_pools(re))) return 1;
        if (expect_ok("presz",       ds_rete_engine_presz_rt_tables(re))) return 1;
    }

    /* Override the recorder before-fire hook with our counter. */
    ds_rete_set_before_fire(e->rete_engine, on_fire, NULL);

    printf("test_rfstall: mode=%s, %d ticks, Hb ttl=%llu Px ttl=%llu\n",
           rt ? "RT" : "non-RT", TICKS,
           (unsigned long long)HB_TTL, (unsigned long long)PX_TTL);

    long prev = 0;
    int stalled_at = -1;
    for (int i = 0; i < TICKS; i++) {
        if (expect_ok("clock_set", ds_engine_clock_set(e, (uint64_t)(2 + i)))) return 1;
        ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = i };
        if (expect_ok("assert Hb", ds_engine_assert(e, hb_ds, &sv, 1, NULL))) return 1;
        if (expect_ok("pump", ds_engine_pump(e))) return 1;

        if (g_fires == prev && stalled_at < 0) {
            stalled_at = i;
            fprintf(stderr,
                    "STALL: hb_rule did not fire at tick %d "
                    "(fires stuck at %ld; wm_n=%zu)\n",
                    i, g_fires, ds_rete_wm_count(e->rete_engine));
        }
        prev = g_fires;
    }

    printf("test_rfstall: total fires=%ld / %d ticks\n", g_fires, TICKS);
    ds_engine_free(e);

    if (stalled_at >= 0) {
        fprintf(stderr, "test_rfstall: FAILED — rule stalled at tick %d\n", stalled_at);
        return 1;
    }
    printf("test_rfstall: OK — rule fired every tick\n");
    return 0;
}

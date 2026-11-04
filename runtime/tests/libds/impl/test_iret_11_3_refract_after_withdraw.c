/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [IRET.11.3] [IRET.10.5]
 * `rule w: S s -> withdraw s`: the withdraw frees s's rete fact, and the
 * terminal then marks the activation refracted on the token's fact-id tuple.
 * Reading that tuple after the actions is a use-after-free that only the asan
 * and memcheck lanes see, so this file is vg and leak "yes" in libds.build.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"

static int failures = 0;
#define CHECK(cond, msg)                                                      \
    do { if (!(cond)) {                                                       \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);     \
        failures++; } } while (0)
#define CHECK_OK(r, msg)                                                      \
    do { ds_result_t rr_ = (r);                                              \
        if (rr_.status != DS_OK) {                                            \
            fprintf(stderr, "FAIL: %s: status=%d detail=%s (%s:%d)\n", (msg), \
                    rr_.status, rr_.detail ? rr_.detail : "(null)",           \
                    __FILE__, __LINE__); failures++; } } while (0)

static int g_fires = 0;

static ds_result_t on_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void)e; (void)u;
    if (ev->kind == DS_EV_RULE_FIRE_BEGIN) g_fires++;
    return DS_OK_R;
}

static size_t live_facts(ds_engine_t *e)
{
    size_t n = 0;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
    return n;
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) {
        fprintf(stderr, "FAIL: engine_new\n"); return 1;
    }
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock 0");

    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *s = NULL;
    CHECK_OK(ds_engine_register_schema(e, "S", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, &sd, 1, &s), "reg S");
    if (s == NULL) { ds_engine_free(e); return 1; }

    /* `rule w: S s -> withdraw s` ([IRET.10.5]). */
    ds_rete_action_t action = { .kind = DS_RETE_ACTION_WITHDRAW,
                                .withdraw_pattern_index = 0 };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "S" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1,
                                 .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "w",
                                 .actions = &action, .action_count = 1 }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    if (ds_rete_load_network(e->rete_engine, &net).status != DS_OK) {
        fprintf(stderr, "FAIL: load network\n");
        ds_engine_free(e);
        return 1;
    }
    CHECK_OK(ds_engine_set_stream_callback(e, on_event, NULL), "stream cb");

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 1 };
    CHECK_OK(ds_engine_assert(e, s, &sv, 1, NULL), "assert S(1)");
    CHECK(live_facts(e) == 1, "premise: S(1) is live before the pump");
    CHECK_OK(ds_engine_pump(e), "pump 1");
    CHECK(g_fires == 1, "pump 1 fires `w` once");
    CHECK(live_facts(e) == 0, "`withdraw s` took S(1) out ([IRET.10.5])");

    /* A new S(1) is a new tuple, so refraction lets it fire ([IRET.11.3]); a
       refraction entry read from freed memory could suppress it. */
    CHECK_OK(ds_engine_clock_advance(e, 1000), "advance");
    CHECK_OK(ds_engine_assert(e, s, &sv, 1, NULL), "assert S(1) again");
    CHECK_OK(ds_engine_pump(e), "pump 2");
    CHECK(g_fires == 2, "pump 2 fires `w` again, for the new fact");
    CHECK(live_facts(e) == 0, "and withdraws it");

    CHECK_OK(ds_engine_set_stream_callback(e, NULL, NULL), "stream cb off");
    ds_engine_free(e);
    if (failures) {
        fprintf(stderr, "test_iret_11_3_refract_after_withdraw: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_iret_11_3_refract_after_withdraw: OK\n");
    return 0;
}

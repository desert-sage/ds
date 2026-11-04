/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Whether two activations from one assert share a creation timetag: two rules
 * over one schema, reached through one shared alpha ([IRET.6.6]). The agenda
 * is read before any pump, since an activation's timetag is not observable
 * once it has fired. It reports the measurement and passes either way; the
 * firing order's first key is the terminal ordinal ([LDET.5.4]).
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/agenda.h"
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

/* One shared alpha, a beta and a terminal per rule, no actions: what the
   compiler emits for two rules matching the same fact. */
static int build_two_rules(ds_engine_t *e, const ds_schema_t **out_src)
{
    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    if (ds_engine_register_schema(e, "Src", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  0, &sd, 1, out_src).status != DS_OK)
        return 1;

    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src" }};
    ds_beta_atom_t betas[2] = {
        { .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 },
        { .node_id = 3, .right_alpha_id = 1, .left_parent_id = 0 },
    };
    ds_term_atom_t terms[2] = {
        { .node_id = 4, .parent_beta_id = 2, .rule_name = "rule_a",
          .actions = NULL, .action_count = 0 },
        { .node_id = 5, .parent_beta_id = 3, .rule_name = "rule_b",
          .actions = NULL, .action_count = 0 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 2,
                              .terms = terms, .term_count = 2 };
    return ds_rete_load_network(e->rete_engine, &net).status != DS_OK;
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) {
        fprintf(stderr, "FAIL: engine_new\n"); return 1;
    }
    const ds_schema_t *src = NULL;
    if (build_two_rules(e, &src)) {
        fprintf(stderr, "FAIL: build_two_rules\n"); ds_engine_free(e); return 1;
    }
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 5 };
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, src, &sv, 1, &f), "assert Src(5)");

    ds_rete_agenda_t *ag = &e->rete_engine->agenda;
    printf("  %u activation(s) on the agenda\n", ag->count);
    CHECK(ag->count == 2, "one fact over two rules => two activations");

    int64_t tt[2] = { -1, -1 };
    for (uint32_t i = 0; i < ag->count && i < 2; i++) {
        ds_rete_activation_t *a = ag->items[i];
        tt[i] = a->creation_timetag;
        printf("    rule=%-8s creation_timetag=%lld\n",
               a->terminal && a->terminal->rule_name ? a->terminal->rule_name
                                                     : "(null)",
               (long long)a->creation_timetag);
    }

    if (ag->count == 2) {
        if (tt[0] == tt[1]) {
            printf("  the two share a creation timetag\n");
        } else {
            printf("  the creation timetags differ (%lld vs %lld)\n",
                   (long long)tt[0], (long long)tt[1]);
        }
    }

    ds_engine_free(e);
    if (failures) {
        fprintf(stderr, "test_ordinal_reachability: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_ordinal_reachability: OK\n");
    return 0;
}

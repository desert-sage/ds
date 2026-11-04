/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NDBG.4.1] [NDBG.4.2] [NDBG.4.3]
 * ds_fact_t carries two ids: `fact_id`, and `rete_id`, the paired Rete
 * fact's ([IDAT.4.1]). The debug API takes and reports `fact_id`; the TMS
 * and the Rete engine hold Rete ids. The two counters agree while every DS
 * assert makes one Rete fact in the same order, so each test drives the Rete
 * counter ahead to tell them apart.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "wm.h"              /* ds_fact_t — fact_id / rete_id are internal */
#include "rete/engine.h"     /* next_fact_id, tms */
#include "rete/loader.h"     /* ds_rete_load_network — match_trace's alphas */
#include "rete/tms.h"        /* ds_tms_add */
#include "rete/terminal.h"   /* owned_terminals' type */

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

#define CHECK_OK(r, msg)                                                      \
    do {                                                                      \
        ds_result_t rr_ = (r);                                                \
        if (rr_.status != DS_OK) {                                            \
            fprintf(stderr, "FAIL: %s: status=%d detail=%s (%s:%d)\n", (msg), \
                    rr_.status, rr_.detail ? rr_.detail : "(null)",           \
                    __FILE__, __LINE__);                                      \
            failures++;                                                       \
        }                                                                     \
    } while (0)

static const ds_slot_desc_t SLOTS[1] = {
    { .name = "v", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
};

/* An arbitrary activation timetag and rule name to justify the fact with. */
#define TT     4242
#define RULE   "derives_it"

/* ---- ds_engine_rete_match_trace takes the DS id --------------------------
 *
 * Two schemas, one alpha each, and the Rete counter one ahead: B is DS id 1,
 * Rete id 2; A is DS id 2, Rete id 3. A's trace names schema A. */

typedef struct { int calls; char last_detail[256]; } trace_seen_t;

static void trace_cb(const char *node_id, const char *node_kind,
                     const char *result, const char *detail, void *user)
{
    (void) node_id; (void) node_kind; (void) result;
    trace_seen_t *s = (trace_seen_t *) user;
    s->calls++;
    snprintf(s->last_detail, sizeof s->last_detail, "%s", detail ? detail : "");
}

static void match_trace_resolves_the_ds_id(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "match_trace: engine_new");
    if (!e) return;

    const ds_schema_t *sa = NULL, *sb = NULL;
    CHECK_OK(ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sa), "register A");
    CHECK_OK(ds_engine_register_schema(e, "B", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sb), "register B");

    ds_alfa_atom_t alfas[2] = {
        { .node_id = 1, .schema_name = "A" },
        { .node_id = 2, .schema_name = "B" },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 2 };
    CHECK_OK(ds_rete_load_network(e->rete_engine, &net), "load two alphas");

    e->rete_engine->next_fact_id += 1;

    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 1;
    ds_fact_t *fb = NULL, *fa = NULL;
    CHECK_OK(ds_engine_assert(e, sb, v, 1, &fb), "assert B");
    CHECK_OK(ds_engine_assert(e, sa, v, 1, &fa), "assert A");
    if (!fa || !fb) { ds_engine_free(e); return; }

    /* The premise: A's DS id is B's Rete id. */
    CHECK((uint64_t) fb->rete_id == fa->fact_id,
          "A's DS id coincides with B's rete id, so a conflation is visible");

    trace_seen_t seen = { 0 };
    CHECK_OK(ds_engine_rete_match_trace(e, fa->fact_id, trace_cb, &seen),
             "match_trace A");
    CHECK(seen.calls == 1, "one alpha traced for A");
    CHECK(strcmp(seen.last_detail, "schema A passed (no alpha filter)") == 0,
          "match_trace on A's DS id traces A, not the fact at that rete id");

    /* A DS id no live fact carries traces nothing. */
    trace_seen_t none = { 0 };
    CHECK_OK(ds_engine_rete_match_trace(e, fa->fact_id + 1000u, trace_cb,
                                        &none), "match_trace unknown id");
    CHECK(none.calls == 0, "an unknown DS id traces nothing");

    ds_engine_free(e);
}

/* ---- ds_engine_refracted_activations reports DS ids ----------------------
 *
 * A fired activation's token holds Rete fact ids; with the Rete counter one
 * ahead, A's Rete id is 2 and its DS id 1.
 *
 * [NDBG.4.3]: the listing is the refraction set. A pump fires the terminal on
 * both facts; retracting A' ends its activation ([IRET.11.3.2]), so only A's
 * entry is listed, and every listed fact is live. */

typedef struct {
    int      calls;
    uint32_t n;
    uint64_t ids[4];
    char     rule[32];
    char     reason[32];
    char     detail[64];
} refract_seen_t;

static void refract_cb(const char *rule_name, const char *reason,
                       const char *detail, const uint64_t *fact_ids,
                       uint32_t fact_count, void *user)
{
    refract_seen_t *s = (refract_seen_t *) user;
    s->calls++;
    s->n = fact_count;
    for (uint32_t i = 0; i < fact_count && i < 4; i++) s->ids[i] = fact_ids[i];
    snprintf(s->rule, sizeof s->rule, "%s", rule_name ? rule_name : "");
    snprintf(s->reason, sizeof s->reason, "%s", reason ? reason : "");
    snprintf(s->detail, sizeof s->detail, "%s", detail ? detail : "");
}

/* @spec [IRET.11.3.2] [IRET.8.2] */
static void refracted_activations_report_ds_ids(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "refracted: engine_new");
    if (!e) return;

    const ds_schema_t *sa = NULL;
    CHECK_OK(ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sa), "refracted: register A");
    ds_alfa_atom_t alfa = { .node_id = 1, .schema_name = "A" };
    ds_beta_atom_t beta = { .node_id = 2, .right_alpha_id = 1 };
    ds_term_atom_t term = { .node_id = 3, .parent_beta_id = 2, .rule_name = RULE };
    ds_rete_network_t net = { .alfas = &alfa, .alfa_count = 1,
                              .betas = &beta, .beta_count = 1,
                              .terms = &term, .term_count = 1 };
    CHECK_OK(ds_rete_load_network(e->rete_engine, &net), "refracted: load");
    ds_rete_engine_t *re = e->rete_engine;
    CHECK(re->owned_terminal_count == 1, "refracted: one terminal loaded");
    if (re->owned_terminal_count != 1) { ds_engine_free(e); return; }

    re->next_fact_id += 1;

    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 1;
    ds_fact_t *fa = NULL, *gone = NULL;
    CHECK_OK(ds_engine_assert(e, sa, v, 1, &fa), "refracted: assert A");
    v[0].v.i = 2;
    CHECK_OK(ds_engine_assert(e, sa, v, 1, &gone), "refracted: assert A'");
    if (!fa || !gone) { ds_engine_free(e); return; }
    CHECK(fa->fact_id != (uint64_t) fa->rete_id,
          "refracted: the two id spaces diverged, so this test can tell them apart");

    CHECK_OK(ds_engine_pump(e), "refracted: pump fires both matches");
    CHECK_OK(ds_engine_retract(e, gone), "refracted: retract A'");

    refract_seen_t seen = { 0 };
    CHECK_OK(ds_engine_refracted_activations(e, NULL, refract_cb, &seen),
             "refracted_activations");
    CHECK(seen.calls == 1,
          "refracted: one entry -- A' left the set when its activation ended");
    CHECK(seen.n == 1, "refracted: the one fact of A's token");
    CHECK(seen.ids[0] == fa->fact_id,
          "refracted: a live fact is reported by its DS fact_id, not its rete id");
    CHECK(strcmp(seen.rule, RULE) == 0, "refracted: the rule is named");
    CHECK(strcmp(seen.reason, "refraction") == 0, "refracted: the reason");
    CHECK(strcmp(seen.detail, "fired, and not re-created since") == 0,
          "refracted: the detail names no cycle and no hash");

    ds_engine_free(e);
}

/* ---- [NDBG.4.3]: the refraction set survives an unrelated assert ---------
 *
 * [IRET.11.3.2]: "Nothing else clears it -- not an unrelated assert or
 * retract, not a pump boundary." Schema A drives the terminal and B is in no
 * pattern; asserting B and pumping again leaves A's entry listed. */

/* @spec [IRET.11.3.2] */
static void refraction_survives_an_unrelated_assert(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "survives: engine_new");
    if (!e) return;

    const ds_schema_t *sa = NULL, *sb = NULL;
    CHECK_OK(ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sa), "survives: register A");
    CHECK_OK(ds_engine_register_schema(e, "B", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sb), "survives: register B");
    ds_alfa_atom_t alfa = { .node_id = 1, .schema_name = "A" };
    ds_beta_atom_t beta = { .node_id = 2, .right_alpha_id = 1 };
    ds_term_atom_t term = { .node_id = 3, .parent_beta_id = 2, .rule_name = RULE };
    ds_rete_network_t net = { .alfas = &alfa, .alfa_count = 1,
                              .betas = &beta, .beta_count = 1,
                              .terms = &term, .term_count = 1 };
    CHECK_OK(ds_rete_load_network(e->rete_engine, &net), "survives: load");

    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 1;
    ds_fact_t *fa = NULL;
    CHECK_OK(ds_engine_assert(e, sa, v, 1, &fa), "survives: assert A");
    CHECK_OK(ds_engine_pump(e), "survives: pump fires A's match");
    if (!fa) { ds_engine_free(e); return; }

    refract_seen_t before = { 0 };
    CHECK_OK(ds_engine_refracted_activations(e, NULL, refract_cb, &before),
             "survives: listing after the firing");
    CHECK(before.calls == 1 && before.n == 1 && before.ids[0] == fa->fact_id,
          "survives: premise -- A's fired match is listed");

    CHECK_OK(ds_engine_assert(e, sb, v, 1, NULL), "survives: assert unrelated B");
    CHECK_OK(ds_engine_pump(e), "survives: pump again");

    refract_seen_t after = { 0 };
    CHECK_OK(ds_engine_refracted_activations(e, NULL, refract_cb, &after),
             "survives: listing after the unrelated assert");
    CHECK(after.calls == 1 && after.n == 1 && after.ids[0] == fa->fact_id,
          "survives: an unrelated assert and a pump boundary remove nothing "
          "from the refraction set ([IRET.11.3.2])");

    ds_engine_free(e);
}

/* ---- [NDBG.4.1] / [NDBG.4.2]: a node is named by its artefact node_id ----
 *
 * Two alpha nodes whose artefact node_ids (7 and 9) are not their positions
 * in libds's node arrays (0 and 1), a beta (11) and a terminal (13). The
 * network enumeration and the match trace both name every node, and each end
 * of an edge, by the decimal text of its node_id. */

typedef struct {
    int  nodes;
    int  edges;
    char ids[8][16];
    char from[4][16];
    char to[4][16];
} net_seen_t;

static void net_node_cb(const char *id, const char *kind, const char *label,
                        const char *filter, uint32_t occ, bool negative,
                        void *user)
{
    (void) kind; (void) label; (void) filter; (void) occ; (void) negative;
    net_seen_t *s = (net_seen_t *) user;
    if (s->nodes < 8) snprintf(s->ids[s->nodes], 16, "%s", id ? id : "");
    s->nodes++;
}

static void net_edge_cb(const char *from, const char *to, void *user)
{
    net_seen_t *s = (net_seen_t *) user;
    if (s->edges < 4) {
        snprintf(s->from[s->edges], 16, "%s", from ? from : "");
        snprintf(s->to[s->edges], 16, "%s", to ? to : "");
    }
    s->edges++;
}

typedef struct { int calls; char ids[4][16]; } trace_ids_t;

static void trace_id_cb(const char *node_id, const char *node_kind,
                        const char *result, const char *detail, void *user)
{
    (void) node_kind; (void) result; (void) detail;
    trace_ids_t *s = (trace_ids_t *) user;
    if (s->calls < 4) snprintf(s->ids[s->calls], 16, "%s", node_id ? node_id : "");
    s->calls++;
}

static void nodes_are_named_by_their_artefact_node_id(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "node ids: engine_new");
    if (!e) return;

    const ds_schema_t *sa = NULL;
    CHECK_OK(ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sa), "node ids: register A");
    ds_alfa_atom_t alfas[2] = {
        { .node_id = 7, .schema_name = "A" },
        { .node_id = 9, .schema_name = "A" },
    };
    ds_beta_atom_t beta = { .node_id = 11, .right_alpha_id = 9 };
    ds_term_atom_t term = { .node_id = 13, .parent_beta_id = 11, .rule_name = RULE };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 2,
                              .betas = &beta, .beta_count = 1,
                              .terms = &term, .term_count = 1 };
    CHECK_OK(ds_rete_load_network(e->rete_engine, &net), "node ids: load");

    net_seen_t seen;
    memset(&seen, 0, sizeof seen);
    CHECK_OK(ds_engine_rete_network(e, NULL, false, net_node_cb, &seen,
                                    net_edge_cb, &seen), "node ids: network");
    CHECK(seen.nodes == 4, "node ids: four nodes enumerated");
    CHECK(strcmp(seen.ids[0], "7") == 0 && strcmp(seen.ids[1], "9") == 0,
          "node ids: the alphas are named 7 and 9, their artefact node_ids");
    CHECK(strcmp(seen.ids[2], "11") == 0, "node ids: the beta is named 11");
    CHECK(strcmp(seen.ids[3], "13") == 0, "node ids: the terminal is named 13");
    CHECK(seen.edges == 2, "node ids: alpha -> beta and beta -> terminal");
    CHECK(strcmp(seen.from[0], "9") == 0 && strcmp(seen.to[0], "11") == 0,
          "node ids: the alpha edge is 9 -> 11");
    CHECK(strcmp(seen.from[1], "11") == 0 && strcmp(seen.to[1], "13") == 0,
          "node ids: the terminal edge is 11 -> 13");

    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 1;
    ds_fact_t *fa = NULL;
    CHECK_OK(ds_engine_assert(e, sa, v, 1, &fa), "node ids: assert A");
    if (!fa) { ds_engine_free(e); return; }

    trace_ids_t tr;
    memset(&tr, 0, sizeof tr);
    CHECK_OK(ds_engine_rete_match_trace(e, fa->fact_id, trace_id_cb, &tr),
             "node ids: match trace");
    CHECK(tr.calls == 2, "node ids: both of A's alphas traced");
    CHECK(strcmp(tr.ids[0], "7") == 0 && strcmp(tr.ids[1], "9") == 0,
          "node ids: the trace names the alphas 7 and 9");

    ds_engine_free(e);
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return 1;

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Pkt", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sc),
             "register_schema");

    /* Drive the Rete id counter ahead of the DS one, as nothing in the
       public API does. */
    CHECK(e->rete_engine != NULL, "native rete engine present");
    if (!e->rete_engine) { ds_engine_free(e); return 1; }
    e->rete_engine->next_fact_id += 100;

    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 7;
    ds_fact_t *fact = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 1, &fact), "assert");
    if (!fact) { ds_engine_free(e); return 1; }

    /* The premise: the two ids differ. */
    CHECK(fact->fact_id != (uint64_t)fact->rete_id,
          "the two id spaces diverged, so this test can tell them apart");

    /* Justify the fact as a rule firing would: the TMS records the Rete
       id. */
    CHECK_OK(ds_tms_add(&e->rete_engine->tms, TT, RULE, fact->rete_id),
             "tms_add");

    /* The API takes the DS id. It must resolve to the same fact. */
    int64_t  *tts = NULL;
    char    **rns = NULL;
    uint32_t  n   = 0;
    CHECK_OK(ds_engine_get_justifiers(e, fact->fact_id, &tts, &rns, &n),
             "get_justifiers");
    CHECK(n == 1, "one justifier for the asserted fact");
    if (n == 1) {
        CHECK(tts[0] == TT, "the activation timetag survives the translation");
        CHECK(rns[0] != NULL && strcmp(rns[0], RULE) == 0, "the rule name");
    }
    for (uint32_t i = 0; i < n; i++) DS_FREE(rns[i]);
    DS_FREE(tts);
    DS_FREE(rns);

    /* A DS id no live fact carries reports nothing; here it is the fact's
       own Rete id. */
    tts = NULL; rns = NULL; n = 0;
    CHECK_OK(ds_engine_get_justifiers(e, (uint64_t)fact->rete_id,
                                      &tts, &rns, &n),
             "get_justifiers on a rete id");
    CHECK(n == 0, "a rete id is not a DS fact_id and resolves to no fact");
    for (uint32_t i = 0; i < n; i++) DS_FREE(rns[i]);
    DS_FREE(tts);
    DS_FREE(rns);

    ds_engine_free(e);

    match_trace_resolves_the_ds_id();
    refracted_activations_report_ds_ids();
    refraction_survives_an_unrelated_assert();
    nodes_are_named_by_their_artefact_node_id();

    if (failures) {
        fprintf(stderr, "test_tms_id_spaces: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_tms_id_spaces: OK\n");
    return 0;
}

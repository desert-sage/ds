/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The three network reads of libds.h: their refusals ([NDBG.7.1]), the order
 * and the strings of ds_engine_rete_network ([NDBG.4.1]), and the strings of
 * ds_engine_rete_match_trace ([NDBG.4.2]).
 *
 * Public API only.
 */
#include "spec_common.h"

/* Every rule here has two patterns, so every beta shape shows: `joined`'s second
   join carries a join test, and `cross`'s carries none. */
static const char *NETWORK_PROGRAM =
    "schema A scope logical:\n"
    "    k: Int key\n"
    "\n"
    "schema B scope logical:\n"
    "    k: Int key\n"
    "\n"
    "rule joined:\n"
    "    A a\n"
    "    B b where b.k == a.k\n"
    "->\n"
    "    log info \"joined\"\n"
    "\n"
    "rule cross:\n"
    "    A a\n"
    "    B b\n"
    "->\n"
    "    log info \"cross {a.k} {b.k}\"\n";

/* Two alphas on one schema: `high`'s tests `v`, and `any`'s tests nothing. */
static const char *TRACE_PROGRAM =
    "schema M scope logical:\n"
    "    k: Int key\n"
    "    v: Int mutable\n"
    "\n"
    "rule high:\n"
    "    M m where m.v > 5\n"
    "->\n"
    "    log info \"high\"\n"
    "\n"
    "rule any:\n"
    "    M m\n"
    "->\n"
    "    log info \"any {m.k}\"\n";

static void no_node(const char *id, const char *kind, const char *label,
                    const char *filter, uint32_t occ, bool neg, void *user)
{
    (void) id; (void) kind; (void) label; (void) filter; (void) occ; (void) neg;
    ++*(int *) user;
}

static void no_edge(const char *from, const char *to, void *user)
{
    (void) from; (void) to;
    ++*(int *) user;
}

static void no_trace(const char *id, const char *kind, const char *result,
                     const char *detail, void *user)
{
    (void) id; (void) kind; (void) result; (void) detail;
    ++*(int *) user;
}

static void no_refract(const char *rule, const char *reason, const char *detail,
                       const uint64_t *ids, uint32_t n, void *user)
{
    (void) rule; (void) reason; (void) detail; (void) ids; (void) n;
    ++*(int *) user;
}

/* DS_ERR_INVAL, with a detail naming the argument. */
static int expect_refused(const char *what, ds_result_t r, const char *argument)
{
    EXPECT_STATUS(what, r, DS_ERR_INVAL);
    if (r.detail == NULL || strstr(r.detail, argument) == NULL) {
        fprintf(stderr, "FAIL: %s: the detail does not name %s: %s\n",
                what, argument, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

/* @spec [NDBG.7.1] */
static int test_ndbg_7_1__a_null_engine_or_callback_is_refused(void)
{
    int fired = 0;
    if (expect_refused("network, NULL engine",
            ds_engine_rete_network(NULL, NULL, false, no_node, &fired, no_edge, &fired),
            "engine")) return 1;
    if (expect_refused("trace, NULL engine",
            ds_engine_rete_match_trace(NULL, 1u, no_trace, &fired), "engine")) return 1;
    if (expect_refused("refracted, NULL engine",
            ds_engine_refracted_activations(NULL, NULL, no_refract, &fired),
            "engine")) return 1;

    ds_engine_t *e = NULL;
    EXPECT_OK("engine_new", ds_engine_new(NULL, &e));
    EXPECT_OK("load", spec_load_ds(e, NETWORK_PROGRAM));

    /* edge_cb is optional and node_cb is not: refused even with edge_cb set, so
       the edges are not walked either. */
    if (expect_refused("network, NULL node_cb",
            ds_engine_rete_network(e, NULL, false, NULL, NULL, no_edge, &fired),
            "node_cb")) return 1;
    if (expect_refused("trace, NULL cb",
            ds_engine_rete_match_trace(e, 1u, NULL, NULL), "cb")) return 1;
    if (expect_refused("refracted, NULL cb",
            ds_engine_refracted_activations(e, NULL, NULL, NULL), "cb")) return 1;
    if (fired != 0) {
        fprintf(stderr, "FAIL: a refused read fired %d callbacks\n", fired);
        return 1;
    }

    /* The control: with its callbacks, the same engine answers and fires them. */
    EXPECT_OK("network",
              ds_engine_rete_network(e, NULL, false, no_node, &fired, no_edge, &fired));
    if (fired == 0) {
        fprintf(stderr, "FAIL: premise: the network reported nothing\n");
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

typedef struct {
    int  phase;           /* 0 alpha, 1 beta, 2 terminal, 3 edge */
    int  counts[4];
    int  out_of_order;
    int  bad_beta;
    int  beta_with_join, beta_without;
    char ids[1024];
} walk_t;

static void walk_node(const char *id, const char *kind, const char *label,
                      const char *filter, uint32_t occ, bool neg, void *user)
{
    (void) occ; (void) neg;
    walk_t *w = user;
    int phase = strcmp(kind, "alpha") == 0 ? 0
              : strcmp(kind, "beta") == 0 ? 1
              : strcmp(kind, "terminal") == 0 ? 2 : 3;
    if (phase < w->phase || phase == 3) w->out_of_order++;
    w->phase = phase;
    w->counts[phase]++;
    if (phase == 1) {
        if (strcmp(label, "join") != 0) w->bad_beta++;
        if (strcmp(filter, "join") == 0) w->beta_with_join++;
        else if (filter[0] == '\0') w->beta_without++;
        else w->bad_beta++;
    }
    strncat(w->ids, id, sizeof w->ids - strlen(w->ids) - 2);
    strcat(w->ids, ",");
}

static void walk_edge(const char *from, const char *to, void *user)
{
    (void) from; (void) to;
    walk_t *w = user;
    w->phase = 3;
    w->counts[3]++;
}

/* @spec [NDBG.4.1] */
static int test_ndbg_4_1__nodes_come_before_edges(void)
{
    ds_engine_t *e = NULL;
    EXPECT_OK("engine_new", ds_engine_new(NULL, &e));
    EXPECT_OK("load", spec_load_ds(e, NETWORK_PROGRAM));

    static walk_t both, nodes_only;
    EXPECT_OK("network",
              ds_engine_rete_network(e, NULL, false, walk_node, &both, walk_edge, &both));
    if (both.out_of_order != 0) {
        fprintf(stderr, "FAIL: %d nodes came out of order\n", both.out_of_order);
        return 1;
    }
    if (both.counts[0] == 0 || both.counts[1] == 0 || both.counts[2] != 2
            || both.counts[3] == 0) {
        fprintf(stderr, "FAIL: premise: %d alphas, %d betas, %d terminals, %d edges\n",
                both.counts[0], both.counts[1], both.counts[2], both.counts[3]);
        return 1;
    }
    if (both.bad_beta != 0 || both.beta_with_join == 0 || both.beta_without == 0) {
        fprintf(stderr, "FAIL: betas: %d bad, %d with join tests, %d without\n",
                both.bad_beta, both.beta_with_join, both.beta_without);
        return 1;
    }

    /* A NULL edge_cb: the same nodes, in the same order. */
    EXPECT_OK("network, NULL edge_cb",
              ds_engine_rete_network(e, NULL, false, walk_node, &nodes_only, NULL, NULL));
    if (strcmp(both.ids, nodes_only.ids) != 0) {
        fprintf(stderr, "FAIL: nodes %s with edge_cb, %s without\n",
                both.ids, nodes_only.ids);
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

typedef struct { int passed, filtered, other; } trace_t;

static void count_trace(const char *id, const char *kind, const char *result,
                        const char *detail, void *user)
{
    (void) id; (void) kind; (void) detail;
    trace_t *t = user;
    if (strcmp(result, "passed") == 0) t->passed++;
    else if (strcmp(result, "filtered") == 0) t->filtered++;
    else t->other++;
}

/* @spec [NDBG.4.2] */
static int test_ndbg_4_2__the_trace_result_is_passed_or_filtered(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *m = NULL;
    ds_fact_t *fact = NULL;
    uint64_t id = 0;
    EXPECT_OK("engine_new", ds_engine_new(NULL, &e));
    EXPECT_OK("load", spec_load_ds(e, TRACE_PROGRAM));
    EXPECT_OK("find M", ds_engine_schema_find(e, "M", &m));
    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT; v[0].v.i = 1;
    v[1].kind = DS_SLOT_INT; v[1].v.i = 1;   /* below `high`'s 5 */
    EXPECT_OK("assert", ds_engine_assert(e, m, v, 2, &fact));
    EXPECT_OK("fact id", ds_fact_get_id(fact, &id));

    trace_t t = {0, 0, 0};
    EXPECT_OK("trace", ds_engine_rete_match_trace(e, id, count_trace, &t));
    if (t.passed != 1 || t.filtered != 1 || t.other != 0) {
        fprintf(stderr, "FAIL: %d passed, %d filtered, %d other; want 1, 1, 0\n",
                t.passed, t.filtered, t.other);
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

int main(void)
{
    if (test_ndbg_7_1__a_null_engine_or_callback_is_refused()) return 1;
    if (test_ndbg_4_1__nodes_come_before_edges()) return 1;
    if (test_ndbg_4_2__the_trace_result_is_passed_or_filtered()) return 1;
    printf("test_introspection_spec: OK\n");
    return 0;
}

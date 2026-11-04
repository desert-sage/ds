/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NDBG.4.1]
 * ds_engine_rete_network's `rule_filter` restricts the read to the nodes
 * reachable from one rule's terminal.
 *
 * Two rules share one engine:
 *
 *   both:   alpha 1 (A) ─┐                        (two patterns)
 *                         join 10 ─ join 11 ─ terminal 20
 *           alpha 2 (B) ──────────────┘
 *
 *   other:  alpha 3 (C) ─ join 12 ─ terminal 21   (one pattern)
 *
 * Filtered to `both`, the read must name exactly {1, 2, 10, 11, 20} and the
 * four edges among them, and nothing of `other`.
 *
 * And `include_occupancy`: UINT32_MAX on every node when false, the live count
 * when true. Inside a callback the call is refused ([RARC.13.16];
 * test_reentry), so true always gives the count.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/loader.h"     /* ds_rete_load_network */

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

/* What one read reported: node ids with their occupancy, and edges as
   "from>to". Bounded well above the eight nodes and six edges here, and a read
   past the bound is counted, so an overflow shows as a wrong count. */
#define MAXN 16

typedef struct {
    int      nodes;
    char     id[MAXN][16];
    uint32_t occ[MAXN];
    int      edges;
    char     edge[MAXN][32];
} seen_t;

static void node_cb(const char *id, const char *kind, const char *label,
                    const char *filter, uint32_t occ, bool negative, void *user)
{
    (void) kind; (void) label; (void) filter; (void) negative;
    seen_t *s = (seen_t *) user;
    if (s->nodes < MAXN) {
        snprintf(s->id[s->nodes], sizeof s->id[0], "%s", id ? id : "");
        s->occ[s->nodes] = occ;
    }
    s->nodes++;
}

static void edge_cb(const char *from, const char *to, void *user)
{
    seen_t *s = (seen_t *) user;
    if (s->edges < MAXN)
        snprintf(s->edge[s->edges], sizeof s->edge[0], "%s>%s",
                 from ? from : "", to ? to : "");
    s->edges++;
}

static int node_at(const seen_t *s, const char *id)
{
    for (int i = 0; i < s->nodes && i < MAXN; i++)
        if (strcmp(s->id[i], id) == 0) return i;
    return -1;
}

static bool has_edge(const seen_t *s, const char *edge)
{
    for (int i = 0; i < s->edges && i < MAXN; i++)
        if (strcmp(s->edge[i], edge) == 0) return true;
    return false;
}

/* Exactly `ids` and exactly `edges`, in any order. */
static void expect(const seen_t *s, const char *const *ids, int n_ids,
                   const char *const *edges, int n_edges, const char *what)
{
    char msg[160];
    snprintf(msg, sizeof msg, "%s: %d nodes", what, n_ids);
    CHECK(s->nodes == n_ids, msg);
    for (int i = 0; i < n_ids; i++) {
        snprintf(msg, sizeof msg, "%s: node %s reported", what, ids[i]);
        CHECK(node_at(s, ids[i]) >= 0, msg);
    }
    snprintf(msg, sizeof msg, "%s: %d edges", what, n_edges);
    CHECK(s->edges == n_edges, msg);
    for (int i = 0; i < n_edges; i++) {
        snprintf(msg, sizeof msg, "%s: edge %s reported", what, edges[i]);
        CHECK(has_edge(s, edges[i]), msg);
    }
    /* Every edge joins two reported nodes. */
    for (int i = 0; i < s->edges && i < MAXN; i++) {
        char from[16], to[16];
        const char *gt = strchr(s->edge[i], '>');
        if (!gt) { CHECK(false, "an edge has two ends"); continue; }
        snprintf(from, sizeof from, "%.*s", (int)(gt - s->edge[i]), s->edge[i]);
        snprintf(to, sizeof to, "%s", gt + 1);
        snprintf(msg, sizeof msg, "%s: edge %s joins two reported nodes",
                 what, s->edge[i]);
        CHECK(node_at(s, from) >= 0 && node_at(s, to) >= 0, msg);
    }
}

static seen_t read_network(ds_engine_t *e, const char *rule, bool occ)
{
    seen_t s;
    memset(&s, 0, sizeof s);
    CHECK_OK(ds_engine_rete_network(e, rule, occ, node_cb, &s, edge_cb, &s),
             "rete_network");
    return s;
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return 1;

    const ds_schema_t *sa = NULL, *sb = NULL, *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sa), "register A");
    CHECK_OK(ds_engine_register_schema(e, "B", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sb), "register B");
    CHECK_OK(ds_engine_register_schema(e, "C", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sc), "register C");

    ds_alfa_atom_t alfas[3] = {
        { .node_id = 1, .schema_name = "A" },
        { .node_id = 2, .schema_name = "B" },
        { .node_id = 3, .schema_name = "C" },
    };
    ds_beta_atom_t betas[3] = {
        { .node_id = 10, .right_alpha_id = 1, .left_parent_id = 0 },
        { .node_id = 11, .right_alpha_id = 2, .left_parent_id = 10 },
        { .node_id = 12, .right_alpha_id = 3, .left_parent_id = 0 },
    };
    ds_term_atom_t terms[2] = {
        { .node_id = 20, .parent_beta_id = 11, .rule_name = "both" },
        { .node_id = 21, .parent_beta_id = 12, .rule_name = "other" },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 3,
                              .betas = betas, .beta_count = 3,
                              .terms = terms, .term_count = 2 };
    CHECK_OK(ds_rete_load_network(e->rete_engine, &net), "load the network");

    /* The premise: unfiltered, the whole network and its six edges. If the
       loader wired it otherwise, the filtered checks below would be judging
       some other graph. */
    {
        static const char *const ids[] = { "1", "2", "3", "10", "11", "12",
                                           "20", "21" };
        static const char *const edges[] = { "1>10", "10>11", "2>11",
                                             "11>20", "3>12", "12>21" };
        seen_t s = read_network(e, NULL, false);
        expect(&s, ids, 8, edges, 6, "unfiltered");
    }

    /* The two-pattern rule: both alphas, both joins, its terminal. */
    {
        static const char *const ids[] = { "1", "2", "10", "11", "20" };
        static const char *const edges[] = { "1>10", "10>11", "2>11",
                                             "11>20" };
        seen_t s = read_network(e, "both", false);
        expect(&s, ids, 5, edges, 4, "rule_filter both");
        CHECK(node_at(&s, "3") < 0 && node_at(&s, "12") < 0
              && node_at(&s, "21") < 0,
              "rule_filter both: nothing of rule other");
    }

    /* The one-pattern rule: nothing of `both` comes through. */
    {
        static const char *const ids[] = { "3", "12", "21" };
        static const char *const edges[] = { "3>12", "12>21" };
        seen_t s = read_network(e, "other", false);
        expect(&s, ids, 3, edges, 2, "rule_filter other");
    }

    /* A name no rule has: nothing at all. */
    {
        seen_t s = read_network(e, "no_such_rule", false);
        expect(&s, NULL, 0, NULL, 0, "rule_filter no_such_rule");
    }

    /* Occupancy. One A fact: alpha 1 holds it, alpha 2 holds none. */
    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 1;
    CHECK_OK(ds_engine_assert(e, sa, v, 1, NULL), "assert A");
    {
        seen_t off = read_network(e, "both", false);
        bool all_max = off.nodes == 5;
        for (int i = 0; i < off.nodes && i < MAXN; i++)
            all_max = all_max && off.occ[i] == UINT32_MAX;
        CHECK(all_max, "include_occupancy false: UINT32_MAX on every node");

        seen_t on = read_network(e, "both", true);
        int a1 = node_at(&on, "1"), a2 = node_at(&on, "2");
        CHECK(a1 >= 0 && on.occ[a1] == 1,
              "include_occupancy true: alpha 1 holds the one A fact");
        CHECK(a2 >= 0 && on.occ[a2] == 0,
              "include_occupancy true: alpha 2 holds no fact, and says 0");
    }

    ds_engine_free(e);

    if (failures) {
        fprintf(stderr, "test_ndbg_4_1_rule_filter: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_ndbg_4_1_rule_filter: OK\n");
    return 0;
}

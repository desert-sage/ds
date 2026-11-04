/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_reentry — the engine is not re-entrant ([RARC.13.16], [NLFC.3.3]).
 *
 * A callback runs on the engine's own stack holding a live handle, so calling
 * back into THAT engine is re-entry and every ds_engine_* call answers
 * DS_ERR_STATE. Every call: a read from inside a callback sees a pump
 * part-drained, and a torn snapshot announces nothing about being torn.
 * Calling a DIFFERENT engine is the intended cross-tier pattern and must keep
 * working, because the depth is per engine.
 *
 * A host assert on a healthy engine runs two integrator callbacks from inside
 * ds_engine_assert, the metric callback and the stream callback, so a guard
 * only one of them raises goes red here. The halted case is
 * test_fault_emission's.
 *
 * [RARC.13.17]: an enumerating read's callback refuses re-entry too. The
 * four reads that call back once per item -- ds_engine_for_each_fact,
 * ds_engine_rete_network, ds_engine_rete_match_trace and
 * ds_engine_refracted_activations -- are not on the pump's stack, but a walk
 * is in progress. One test per read, each named for the read it drives
 * ([STYL.5.10.8]): from inside the read's callback, a read and a retract on
 * the engine being enumerated are DS_ERR_STATE, and nothing was retracted.
 * The for_each_fact case also calls a second engine from inside, which
 * succeeds.
 *
 * The network is loaded directly (one alpha, beta and terminal, as
 * test_tms_id_spaces does) and a pump fires its terminal on both facts, so
 * each read has at least one item to call back on; every test asserts its
 * callback ran, or it would pass on a read that calls nothing.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "wm.h"              /* ds_fact_t's rete_id */
#include "rete/engine.h"     /* owned_terminals */
#include "rete/loader.h"     /* ds_rete_load_network */
#include "rete/terminal.h"   /* owned_terminals' type */

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

typedef struct {
    ds_engine_t       *self;
    ds_engine_t       *other;
    const ds_schema_t *self_schema;
    const ds_schema_t *other_schema;

    int         stream_seen;
    ds_status_t self_read;      /* fact_count on the engine that called us */
    ds_status_t self_mutate;    /* assert on it */
    ds_status_t self_free;      /* ds_engine_free on it */
    ds_status_t other_read;     /* fact_count on a different engine */
    ds_status_t other_mutate;   /* assert on a different engine */

    int         metric_seen;
    ds_status_t metric_read;    /* schema_count from inside the metric cb */
} probe_t;

static const ds_slot_value_t k_val = { .kind = DS_SLOT_INT, .v.i = 1 };

static ds_result_t on_stream(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    probe_t *p = (probe_t *) user;
    if (ev->kind != DS_EV_FACT_ASSERT || p->stream_seen) return DS_OK_R;
    p->stream_seen = 1;

    size_t n = 0;
    p->self_read   = ds_engine_fact_count(e, &n).status;
    p->self_mutate = ds_engine_assert(e, p->self_schema, &k_val, 1, NULL).status;

    p->other_read   = ds_engine_fact_count(p->other, &n).status;
    p->other_mutate = ds_engine_assert(p->other, p->other_schema, &k_val, 1,
                                       NULL).status;

    /* Last: without the guard this frees the engine whose stack we are on,
       and a regression shows as a truncated suite, not a FAIL line. */
    p->self_free = ds_engine_free(e).status;
    return DS_OK_R;
}

static ds_result_t on_metric(ds_engine_t *e, const ds_metric_t *m, void *user)
{
    (void) m;
    probe_t *p = (probe_t *) user;
    if (p->metric_seen) return DS_OK_R;
    p->metric_seen = 1;
    size_t n = 0;
    p->metric_read = ds_engine_schema_count(e, &n).status;
    return DS_OK_R;
}

static int open_engine(ds_engine_t **out, const ds_schema_t **out_schema)
{
    ds_engine_config_t cfg = {0};
    if (ds_engine_new(&cfg, out).status != DS_OK || *out == NULL) return 1;
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_MUTABLE };
    /* A keyless logical schema is a singleton, so the counts below are
       exact. */
    return ds_engine_register_schema(*out, "S", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                     0, &sd, 1, out_schema)
               .status != DS_OK;
}

static void test_rarc_13_16__every_call_from_a_callback_is_refused(void)
{
    probe_t p;
    memset(&p, 0, sizeof(p));
    p.self_read = p.self_mutate = p.self_free = DS_OK;
    p.other_read = p.other_mutate = p.metric_read = -1;

    if (open_engine(&p.self, &p.self_schema) ||
        open_engine(&p.other, &p.other_schema)) {
        fprintf(stderr, "FAIL: open_engine\n"); g_fails++; goto done;
    }
    CHECK(ds_engine_set_stream_callback(p.self, on_stream, &p).status == DS_OK,
          "stream callback registers");
    CHECK(ds_engine_set_metric_callback(p.self, on_metric, &p).status == DS_OK,
          "metric callback registers");

    CHECK(ds_engine_assert(p.self, p.self_schema, &k_val, 1, NULL).status
              == DS_OK, "the host assert itself succeeds");

    CHECK(p.stream_seen, "the stream callback ran inside the assert");
    CHECK(p.self_read == DS_ERR_STATE,
          "a READ on the calling engine is refused: DS_ERR_STATE");
    CHECK(p.self_mutate == DS_ERR_STATE,
          "a mutation on the calling engine is refused: DS_ERR_STATE");
    CHECK(p.self_free == DS_ERR_STATE,
          "freeing the calling engine from its own callback is refused");
    CHECK(p.other_read == DS_OK,
          "a read on a DIFFERENT engine still answers");
    CHECK(p.other_mutate == DS_OK,
          "and so does a mutation on it -- the cross-tier pattern");

    CHECK(p.metric_seen, "the metric callback ran inside the assert");
    CHECK(p.metric_read == DS_ERR_STATE,
          "the metric callback is guarded too, not only the stream");

    CHECK(p.self->callback_depth == 0,
          "the depth is back to zero once the callbacks return");
    size_t n_self = 0, n_other = 0;
    CHECK(ds_engine_fact_count(p.self, &n_self).status == DS_OK && n_self == 1,
          "after the callback, reads answer -- and the refused assert "
          "added nothing");
    CHECK(ds_engine_fact_count(p.other, &n_other).status == DS_OK
              && n_other == 1,
          "the assert on the other engine landed");

done:
    if (p.self)  ds_engine_free(p.self);
    if (p.other) ds_engine_free(p.other);
}

/* [RARC.13.17]: the four enumerating reads. */
typedef struct {
    ds_engine_t       *self;
    ds_engine_t       *other;
    ds_fact_t         *victim;     /* a live fact on self, for the retract */
    const ds_schema_t *other_schema;

    int         seen;
    ds_status_t self_read;         /* fact_count on the engine enumerated */
    ds_status_t self_retract;      /* retract on it */
    ds_status_t other_read;        /* fact_count on a different engine */
} visit_probe_t;

/* What every visitor does, once: a read and a retract on the engine being
   enumerated, and a read on the other engine. */
static void probe_from_inside(visit_probe_t *p)
{
    if (p->seen++) return;
    size_t n = 0;
    p->self_read    = ds_engine_fact_count(p->self, &n).status;
    p->self_retract = ds_engine_retract(p->self, p->victim).status;
    p->other_read   = ds_engine_fact_count(p->other, &n).status;
}

static ds_result_t visit_fact(const ds_fact_t *f, void *user)
{
    (void) f;
    probe_from_inside((visit_probe_t *) user);
    return DS_OK_R;
}

static void visit_node(const char *id, const char *kind, const char *label,
                       const char *filter, uint32_t occ, bool negative,
                       void *user)
{
    (void) id; (void) kind; (void) label; (void) filter; (void) occ;
    (void) negative;
    probe_from_inside((visit_probe_t *) user);
}

static void visit_edge(const char *from, const char *to, void *user)
{
    (void) from; (void) to;
    probe_from_inside((visit_probe_t *) user);
}

static void visit_trace(const char *node_id, const char *node_kind,
                        const char *result, const char *detail, void *user)
{
    (void) node_id; (void) node_kind; (void) result; (void) detail;
    probe_from_inside((visit_probe_t *) user);
}

static void visit_refract(const char *rule, const char *reason,
                          const char *detail, const uint64_t *ids,
                          uint32_t n, void *user)
{
    (void) rule; (void) reason; (void) detail; (void) ids; (void) n;
    probe_from_inside((visit_probe_t *) user);
}

/* An engine with one keyed LOGICAL schema `A`, a loaded alpha -> beta ->
   terminal network over it, two live facts (v = 1, v = 2), and both matches
   fired by a pump, so the terminal's refraction set names both. */
static int open_networked(visit_probe_t *p)
{
    memset(p, 0, sizeof(*p));
    p->self_read = p->self_retract = DS_OK;
    p->other_read = -1;

    ds_engine_config_t cfg = {0};
    if (ds_engine_new(&cfg, &p->self).status != DS_OK || p->self == NULL)
        return 1;
    if (open_engine(&p->other, &p->other_schema)) return 1;

    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *sa = NULL;
    if (ds_engine_register_schema(p->self, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  &sd, 1, &sa).status != DS_OK)
        return 1;
    ds_alfa_atom_t alfa = { .node_id = 1, .schema_name = "A" };
    ds_beta_atom_t beta = { .node_id = 2, .right_alpha_id = 1 };
    ds_term_atom_t term = { .node_id = 3, .parent_beta_id = 2,
                            .rule_name = "r" };
    ds_rete_network_t net = { .alfas = &alfa, .alfa_count = 1,
                              .betas = &beta, .beta_count = 1,
                              .terms = &term, .term_count = 1 };
    if (ds_rete_load_network(p->self->rete_engine, &net).status != DS_OK)
        return 1;

    ds_slot_value_t v = { .kind = DS_SLOT_INT, .v.i = 1 };
    ds_fact_t *first = NULL;
    if (ds_engine_assert(p->self, sa, &v, 1, &first).status != DS_OK) return 1;
    v.v.i = 2;
    if (ds_engine_assert(p->self, sa, &v, 1, &p->victim).status != DS_OK)
        return 1;

    ds_rete_engine_t *re = p->self->rete_engine;
    if (re->owned_terminal_count != 1) return 1;
    /* The pump fires r once per fact (it has no actions), so both matches
       refract ([IRET.11.3]) and refracted_activations has entries to call
       back on ([NDBG.4.3]: the listing is the refraction set, which only a
       firing adds to). */
    (void) first;
    return ds_engine_pump(p->self).status != DS_OK;
}

/* The checks every read shares: its callback ran, both calls on the
   enumerated engine were refused, the refused retract retracted nothing, and
   the depth is back to zero. */
static void expect_refused(visit_probe_t *p, const char *read)
{
    char msg[160];
    snprintf(msg, sizeof msg, "%s: its callback ran", read);
    CHECK(p->seen > 0, msg);
    snprintf(msg, sizeof msg, "%s: a READ from inside is DS_ERR_STATE", read);
    CHECK(p->self_read == DS_ERR_STATE, msg);
    snprintf(msg, sizeof msg, "%s: a RETRACT from inside is DS_ERR_STATE", read);
    CHECK(p->self_retract == DS_ERR_STATE, msg);
    snprintf(msg, sizeof msg, "%s: the depth is zero after the read", read);
    CHECK(p->self->callback_depth == 0, msg);
    size_t n = 0;
    snprintf(msg, sizeof msg, "%s: the refused retract retracted nothing", read);
    CHECK(ds_engine_fact_count(p->self, &n).status == DS_OK && n == 2, msg);
}

static void close_networked(visit_probe_t *p)
{
    if (p->self)  ds_engine_free(p->self);
    if (p->other) ds_engine_free(p->other);
}

static void test_rarc_13_17__for_each_fact_visitor_refuses_reentry(void)
{
    visit_probe_t p;
    if (open_networked(&p)) {
        fprintf(stderr, "FAIL: for_each_fact rig\n"); g_fails++;
        close_networked(&p); return;
    }
    CHECK(ds_engine_for_each_fact(p.self, NULL, visit_fact, &p).status == DS_OK,
          "for_each_fact returns OK");
    expect_refused(&p, "ds_engine_for_each_fact");
    CHECK(p.other_read == DS_OK,
          "ds_engine_for_each_fact: a read on a DIFFERENT engine still answers");
    close_networked(&p);
}

static void test_rarc_13_17__rete_network_node_cb_refuses_reentry(void)
{
    visit_probe_t p;
    if (open_networked(&p)) {
        fprintf(stderr, "FAIL: rete_network rig\n"); g_fails++;
        close_networked(&p); return;
    }
    /* The edge callback is a no-op probe here, so the node callback is the
       one under test: it runs first, on the alpha. */
    visit_probe_t edges;
    memset(&edges, 0, sizeof edges);
    edges.seen = 1;
    CHECK(ds_engine_rete_network(p.self, NULL, true, visit_node, &p,
                                 visit_edge, &edges).status == DS_OK,
          "rete_network returns OK");
    expect_refused(&p, "ds_engine_rete_network node_cb");
    close_networked(&p);
}

static void test_rarc_13_17__rete_network_edge_cb_refuses_reentry(void)
{
    visit_probe_t p;
    if (open_networked(&p)) {
        fprintf(stderr, "FAIL: rete_network edge rig\n"); g_fails++;
        close_networked(&p); return;
    }
    visit_probe_t nodes;
    memset(&nodes, 0, sizeof nodes);
    nodes.seen = 1;
    CHECK(ds_engine_rete_network(p.self, NULL, false, visit_node, &nodes,
                                 visit_edge, &p).status == DS_OK,
          "rete_network returns OK");
    expect_refused(&p, "ds_engine_rete_network edge_cb");
    close_networked(&p);
}

static void test_rarc_13_17__rete_match_trace_cb_refuses_reentry(void)
{
    visit_probe_t p;
    if (open_networked(&p)) {
        fprintf(stderr, "FAIL: match_trace rig\n"); g_fails++;
        close_networked(&p); return;
    }
    CHECK(ds_engine_rete_match_trace(p.self, p.victim->fact_id, visit_trace,
                                     &p).status == DS_OK,
          "rete_match_trace returns OK");
    expect_refused(&p, "ds_engine_rete_match_trace");
    close_networked(&p);
}

static void test_rarc_13_17__refracted_activations_cb_refuses_reentry(void)
{
    visit_probe_t p;
    if (open_networked(&p)) {
        fprintf(stderr, "FAIL: refracted_activations rig\n"); g_fails++;
        close_networked(&p); return;
    }
    CHECK(ds_engine_refracted_activations(p.self, NULL, visit_refract,
                                          &p).status == DS_OK,
          "refracted_activations returns OK");
    expect_refused(&p, "ds_engine_refracted_activations");
    close_networked(&p);
}

int main(void)
{
    printf("=== test_reentry ===\n");
    test_rarc_13_16__every_call_from_a_callback_is_refused();
    test_rarc_13_17__for_each_fact_visitor_refuses_reentry();
    test_rarc_13_17__rete_network_node_cb_refuses_reentry();
    test_rarc_13_17__rete_network_edge_cb_refuses_reentry();
    test_rarc_13_17__rete_match_trace_cb_refuses_reentry();
    test_rarc_13_17__refracted_activations_cb_refuses_reentry();
    if (g_fails) {
        fprintf(stderr, "test_reentry: %d FAILURE(S)\n", g_fails);
        return 1;
    }
    printf("=== test_reentry: ALL PASSED ===\n");
    return 0;
}

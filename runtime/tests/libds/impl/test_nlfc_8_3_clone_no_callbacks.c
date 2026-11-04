/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.8.3]
 * A clone starts with no callbacks and no `user` pointer of the source's.
 * PATH: ds_engine_clone (engine_clone.c, clone_ds_config), then a pump of the
 * clone whose `call` reaches bridge_call, which reads the clone's
 * dispatcher.call_cb. The network is cloned before any fact exists.
 *
 *   - Clone A, with nothing registered: DS_ERR_STORAGE_UNAVAILABLE, as on a
 *     new engine, and neither of the source's callbacks hears anything.
 *   - Clone B, with its own call callback: B's user receives the call.
 *   - The source, last: the positive control that the rule calls at all.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/intern.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

typedef struct { int n_calls; const void *last_user; } call_probe_t;

static ds_result_t call_probe_cb(ds_engine_t *e, const ds_call_request_t *req,
                                 void *user)
{
    (void) e; (void) req;
    call_probe_t *p = (call_probe_t *) user;
    p->n_calls++;
    p->last_user = user;
    return DS_OK_R;
}

static ds_result_t count_stream_cb(ds_engine_t *e, const ds_stream_ev_t *ev,
                                   void *user)
{
    (void) e; (void) ev;
    (*(int *) user)++;
    return DS_OK_R;
}

static const char *istr(ds_engine_t *engine, const char *s)
{
    const char *p = NULL;
    ds_rete_intern_cstr(engine->rete_engine->intern, s, &p);
    return p;
}

static ds_rete_expr_t *lit_str(ds_engine_t *engine, const char *s)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    e->lit_str = istr(engine, s); return e;
}

/* (ds-call <service> <correlation> [<name> <value>]...): FN_CALL's operands
   are the service, the correlation, then one name/value pair per kwarg
   (RDSC.4a.9.4). No kwargs here: the test is about who receives the call. */
static ds_rete_expr_t *call_expr(ds_engine_t *engine)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    e->call.op = DS_FN_CALL;
    e->call.args = calloc(2, sizeof(*e->call.args));
    e->call.args[0] = lit_str(engine, "svc.notify");
    e->call.args[1] = lit_str(engine, "corr-1");
    e->call.arg_count = 2;
    return e;
}

static int build_net(ds_engine_t *engine, const ds_schema_t **out_src)
{
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    if (ds_engine_register_schema(engine, "Src", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  0, &sd, 1, out_src).status != DS_OK)
        return 1;
    ds_rete_action_t action = { .kind = DS_RETE_ACTION_CALL,
                                .expr = call_expr(engine) };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src" }};
    ds_beta_atom_t betas[1] = {
        { .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 } };
    ds_term_atom_t terms[1] = {
        { .node_id = 3, .parent_beta_id = 2, .rule_name = "notify",
          .actions = &action, .action_count = 1 } };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    if (ds_rete_load_network(engine->rete_engine, &net).status != DS_OK) {
        ds_rete_expr_free_tree(action.expr);
        return 1;
    }
    return 0;
}

/* Assert Src(1) on `e` (looked up by name: a clone has its own schema). */
static ds_result_t assert_src(ds_engine_t *e)
{
    const ds_schema_t *s = NULL;
    ds_result_t r = ds_engine_schema_find(e, "Src", &s);
    if (r.status != DS_OK) return r;
    if (s == NULL) return DS_ERR_R(DS_ERR_NOT_FOUND, "no Src");
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 1 };
    ds_fact_t *f = NULL;
    return ds_engine_assert(e, s, &sv, 1, &f);
}

static void test_a_clone_starts_with_no_callbacks(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *src = NULL, *a = NULL, *b = NULL;
    if (ds_engine_new(&cfg, &src).status != DS_OK || !src) {
        fprintf(stderr, "FAIL: engine_new\n"); g_fails++; return;
    }
    const ds_schema_t *src_s = NULL;
    if (build_net(src, &src_s)) {
        fprintf(stderr, "FAIL: build_net\n"); g_fails++; goto done;
    }

    call_probe_t src_probe = {0};
    int          src_events = 0;
    CHECK(ds_engine_set_call_callback(src, call_probe_cb, &src_probe).status
              == DS_OK, "source registers a call callback");
    CHECK(ds_engine_set_stream_callback(src, count_stream_cb, &src_events).status
              == DS_OK, "source registers a stream callback");

    CHECK(ds_engine_clone(src, &a).status == DS_OK && a, "clone A");
    CHECK(ds_engine_clone(src, &b).status == DS_OK && b, "clone B");
    if (!a || !b) goto done;

    /* A: nothing registered. */
    CHECK(assert_src(a).status == DS_OK, "assert on A");
    ds_result_t ra = ds_engine_pump(a);
    CHECK(ra.status == DS_ERR_STORAGE_UNAVAILABLE,
          "A's call has no handler: DS_ERR_STORAGE_UNAVAILABLE, as on a new "
          "engine ([NLFC.8.3])");
    CHECK(src_probe.n_calls == 0, "the source's call callback was not invoked");
    CHECK(src_events == 0,
          "the source's stream callback saw none of A's events");

    /* B: its own call callback. */
    call_probe_t b_probe = {0};
    CHECK(ds_engine_set_call_callback(b, call_probe_cb, &b_probe).status
              == DS_OK, "B registers its own call callback");
    CHECK(assert_src(b).status == DS_OK, "assert on B");
    CHECK(ds_engine_pump(b).status == DS_OK, "B's pump is DS_OK");
    CHECK(b_probe.n_calls == 1 && b_probe.last_user == &b_probe,
          "B's call reached B's callback with B's user");
    CHECK(src_probe.n_calls == 0, "and still not the source's");
    CHECK(src_events == 0, "nor the source's stream");

    /* The source: the positive control that the rule calls. */
    CHECK(ds_engine_assert(src, src_s,
                           &(ds_slot_value_t){ .kind = DS_SLOT_INT, .v.i = 1 },
                           1, &(ds_fact_t *){0}).status == DS_OK,
          "assert on the source");
    CHECK(ds_engine_pump(src).status == DS_OK, "the source's pump is DS_OK");
    CHECK(src_probe.n_calls == 1 && src_probe.last_user == &src_probe,
          "the source's callback ran once, for its own firing -- premise");
    CHECK(src_events > 0, "and its stream saw its own events -- premise");

done:
    if (a)   ds_engine_free(a);
    if (b)   ds_engine_free(b);
    if (src) ds_engine_free(src);
}

int main(void)
{
    printf("=== test_nlfc_8_3_clone_no_callbacks ===\n");
    test_a_clone_starts_with_no_callbacks();
    if (g_fails) {
        fprintf(stderr, "test_nlfc_8_3_clone_no_callbacks: %d FAILURE(S)\n",
                g_fails);
        return 1;
    }
    printf("=== test_nlfc_8_3_clone_no_callbacks: ALL PASSED ===\n");
    return 0;
}

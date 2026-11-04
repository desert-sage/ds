/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A series read nothing can answer is DS_ERR_SERIES_NO_BACKING; one that is
 * merely early is silent. In every case below the row holds no live backend
 * instance, so only the declaration (engine->series_decls) tells them apart:
 *
 *   served, no instance yet  -> silent  ([LSER.9.1.1] allocates lazily)
 *   unserved                 -> DS_ERR_SERIES_NO_BACKING
 *   no row at all            -> silent  (nothing absorbed for this key)
 *
 * No compiled program reaches an unserved read, so the state is built
 * directly. SeriesBackendRingBuffer serves COUNT but not ACTIVE_FRACTION,
 * which is SeriesBackendIntervalPulse's.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"
#include "engine.h"
#include "fn.h"
#include "builtin_fn.h"
#include "rete/action.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/val.h"
#include "rfcs/rfcs.h"
#include "series/builtin_backends.h"
#include "series/registry.h"
#include "series/state.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

/* An engine that declares one series, Trade.price by symbol on
   SeriesBackendRingBuffer, with a state row for AAPL and no backend instance
   allocated: a program after its load and before its first sample. */
static ds_engine_t *make_engine(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) return NULL;

    /* One decl, appended the way the DSC apply phase would. The three name
       fields are owned by the engine and freed at teardown, so they must come
       from the same allocator the engine frees with. */
    struct ds_series_decl_record *d = DS_CALLOC(1, sizeof(*d));
    if (d == NULL) { ds_engine_free(e); return NULL; }
    d->atom_field         = DS_ATOM_SERIES_BACKEND_RING_BUFFER;
    d->schema_name        = DS_STRDUP("Trade");
    d->slot_name          = DS_STRDUP("price");
    d->identity_slot_name = DS_STRDUP("symbol");
    d->window_ns          = 10000000000ULL;
    d->max_samples        = 64;
    if (d->schema_name == NULL || d->slot_name == NULL
        || d->identity_slot_name == NULL) {
        ds_engine_free(e);
        return NULL;
    }
    e->series_decls     = d;
    e->n_series_decls   = 1;
    e->cap_series_decls = 1;

    /* The row, with no instance in it. The window is part of the row key
       ([RDSC.5a.8.1]); `read_series` reads the same 10 s. */
    if (ds_series_state_lookup_or_insert(e, &e->series_state,
                                         e->n_backend_slots,
                                         "Trade", "price", "symbol",
                                         "AAPL", 10000000000ULL) == NULL) {
        ds_engine_free(e);
        return NULL;
    }
    return e;
}

/* Invoke a registered series read adapter exactly as the Rete CALL evaluator
 * would, and report the status the pump would surface afterwards. */
static ds_result_t read_series(ds_engine_t *e, ds_builtin_fn_t op,
                               const char *identity, ds_rete_val_t *out)
{
    const ds_fn_slot_t *slot = ds_lookup_fn((uint32_t)op);
    if (slot == NULL) return DS_ERR_R(DS_ERR_INTERNAL, "op unregistered");

    ds_rete_val_t args[5];
    args[0] = ds_rete_val_str("Trade",  5u);
    args[1] = ds_rete_val_str("price",  5u);
    args[2] = ds_rete_val_str("symbol", 6u);
    args[3] = ds_rete_val_str(identity, (uint32_t)strlen(identity));
    args[4] = ds_rete_val_int(10000000000LL);

    ds_result_t dropped;
    ds_engine_take_pending(e, &dropped);   /* isolate this call */

    ds_result_t r = slot->fn(e->rete_engine, NULL, args, 5u, out);
    if (r.status != DS_OK) return r;

    ds_result_t pend;
    ds_engine_take_pending(e, &pend);
    return pend;
}

/* A declared, served aggregation whose instance is not allocated yet is
   silent ([LSER.9.1.1]). */
static int test_served_but_unallocated_is_silent(void)
{
    ds_engine_t *e = make_engine();
    if (e == NULL) return fail("served: engine setup");

    ds_rete_val_t out;
    ds_result_t   pend = read_series(e, DS_FN_SERIES_COUNT, "AAPL", &out);

    int fails = 0;
    if (pend.status != DS_OK) {
        fprintf(stderr,
                "FAIL: a declared-and-served aggregation reported %d (%s); "
                "an unallocated instance is legitimate (LSER.9.1.1)\n",
                pend.status, pend.detail ? pend.detail : "(null)");
        fails = 1;
    }
    ds_engine_free(e);
    return fails;
}

/* No declared backing serves ACTIVE_FRACTION on this row. */
static int test_unserved_agg_is_reported(void)
{
    ds_engine_t *e = make_engine();
    if (e == NULL) return fail("unserved: engine setup");

    ds_rete_val_t out;
    ds_result_t   pend = read_series(e, DS_FN_SERIES_ACTIVE_FRACTION,
                                     "AAPL", &out);

    int fails = 0;
    if (pend.status != DS_ERR_SERIES_NO_BACKING) {
        fprintf(stderr,
                "FAIL: active_fraction on a ring-buffer-only row reported "
                "%d, expected DS_ERR_SERIES_NO_BACKING (%d). The runtime "
                "answered a read nothing can compute instead of reporting "
                "it\n",
                pend.status, DS_ERR_SERIES_NO_BACKING);
        fails = 1;
    }
    ds_engine_free(e);
    return fails;
}

/* No row for this key: nothing has been absorbed, so the neutral zero is
   the answer, silently. */
static int test_absent_row_is_silent(void)
{
    ds_engine_t *e = make_engine();
    if (e == NULL) return fail("absent: engine setup");

    ds_rete_val_t out;
    ds_result_t   pend = read_series(e, DS_FN_SERIES_COUNT, "ZZZZ", &out);

    int fails = 0;
    if (pend.status != DS_OK) {
        fprintf(stderr,
                "FAIL: a read against a key with no state row reported %d; "
                "'nothing absorbed yet' is not an error\n", pend.status);
        fails = 1;
    }
    ds_engine_free(e);
    return fails;
}

/* ---- [RFCS.6.7]: a replay goes on past this pump status -------------------
   A hand-loaded rule: `Go` fires one action, the read nothing serves, and the
   pump reports DS_ERR_SERIES_NO_BACKING. */
static uint8_t g_stream[8192];
static size_t  g_stream_len;

static ds_result_t stream_sink(const uint8_t *bytes, size_t len, void *user)
{
    (void)user;
    if (g_stream_len + len > sizeof g_stream)
        return DS_ERR_R(DS_ERR_INVAL, "sink overflow");
    memcpy(g_stream + g_stream_len, bytes, len);
    g_stream_len += len;
    return DS_OK_R;
}

static ds_rete_expr_t *ex_str(const char *s)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    e->lit_str = s;
    return e;
}

/* The loader borrows the action array, so it lives as long as the engine. */
typedef struct {
    const ds_schema_t *go;
    ds_rete_action_t   act[1];
} go_rig;

static int go_rig_open(ds_engine_t *e, go_rig *g)
{
    static const ds_slot_desc_t K = {
        .name = "k", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY };
    memset(g, 0, sizeof *g);
    if (ds_engine_register_schema(e, "Go", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  &K, 1, &g->go).status != DS_OK)
        return 1;

    ds_rete_expr_t *read = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    read->call.op = DS_FN_SERIES_ACTIVE_FRACTION;
    read->call.args = calloc(5, sizeof *read->call.args);
    read->call.args[0] = ex_str("Trade");
    read->call.args[1] = ex_str("price");
    read->call.args[2] = ex_str("symbol");
    read->call.args[3] = ex_str("AAPL");
    read->call.args[4] = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    read->call.args[4]->lit_int = 10000000000LL;
    read->call.arg_count = 5;
    g->act[0] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL, .expr = read };

    ds_alfa_atom_t alfa = { .node_id = 1, .schema_name = "Go" };
    ds_beta_atom_t beta = { .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 };
    ds_term_atom_t term = { .node_id = 3, .parent_beta_id = 2, .rule_name = "reads",
                            .actions = g->act, .action_count = 1 };
    ds_rete_network_t net = { .alfas = &alfa, .alfa_count = 1,
                              .betas = &beta, .beta_count = 1,
                              .terms = &term, .term_count = 1 };
    return ds_rete_load_network(e->rete_engine, &net).status != DS_OK;
}

static ds_result_t assert_go(ds_engine_t *e, const go_rig *g, int64_t k)
{
    ds_slot_value_t v;
    memset(&v, 0, sizeof v);
    v.kind = DS_SLOT_INT;
    v.v.i = k;
    return ds_engine_assert(e, g->go, &v, 1, NULL);
}

/* @spec [RFCS.6.7]
   Go(2) comes after the first pump that reports the status, and the replay
   delivers both. */
static int test_rfcs_6_7__series_no_backing_replays_past_its_pump(void)
{
    static go_rig g_src, g_dst;
    static ds_rfcs_recorder_t rec;
    static uint8_t recbuf[4096], strbuf[4096];
    ds_engine_t *src = make_engine(), *dst = make_engine();
    int fails = 0;
    if (src == NULL || dst == NULL
            || go_rig_open(src, &g_src) != 0 || go_rig_open(dst, &g_dst) != 0) {
        fails = fail("replay: setup");
        goto done;
    }

    g_stream_len = 0;
    if (ds_rfcs_record_to(src, &rec, stream_sink, NULL, recbuf,
                          sizeof recbuf).status != DS_OK) {
        fails = fail("replay: record_to");
        goto done;
    }
    for (int64_t k = 1; k <= 2; k++) {
        if (assert_go(src, &g_src, k).status != DS_OK)
            fails += fail("replay: assert Go");
        if (ds_engine_pump(src).status != DS_ERR_SERIES_NO_BACKING)
            fails += fail("replay: the pump reports DS_ERR_SERIES_NO_BACKING");
    }
    ds_engine_set_stream_callback(src, NULL, NULL);
    if (rec.last.status != DS_OK)
        fails += fail("replay: the recorder had no error");

    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof res);
    ds_result_t r = ds_rfcs_replay(dst, g_stream, g_stream_len, strbuf,
                                   sizeof strbuf, &res);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: the replay returned %d (%s); [RFCS.6.7] makes "
                "the pump's status an outcome\n",
                r.status, r.detail ? r.detail : "(null)");
        fails++;
    }
    if (res.asserts != 2) {
        fprintf(stderr, "FAIL: the replay delivered %llu input(s), not both\n",
                (unsigned long long) res.asserts);
        fails++;
    }

done:
    if (dst != NULL) ds_engine_free(dst);
    if (src != NULL) ds_engine_free(src);
    return fails;
}

/* `ds_engine_new` registers the closed set, so registering again, one
   backend or the whole set, is DS_ERR_STATE and leaves the seven slots as
   they were. */
static int test_second_registration_is_refused(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK)
        return fail("duplicate: engine_new");
    const size_t before = e->n_backend_slots;

    int fails = 0;
    ds_result_t one = ds_engine_register_ring_buffer_backend(e);
    if (one.status != DS_ERR_STATE) {
        fprintf(stderr, "FAIL: re-registering SeriesBackendRingBuffer returned "
                "%d, expected "
                "DS_ERR_STATE (%d)\n", one.status, DS_ERR_STATE);
        fails = 1;
    }
    ds_result_t all = ds_series_register_builtin_backends(e);
    if (all.status != DS_ERR_STATE) {
        fprintf(stderr, "FAIL: re-registering the closed set returned %d, "
                "expected DS_ERR_STATE (%d)\n",
                all.status, DS_ERR_STATE);
        fails = 1;
    }
    if (before != 7 || e->n_backend_slots != before) {
        fprintf(stderr, "FAIL: the slot table holds %zu backends (was %zu); "
                "expected the seven, unchanged by a refused registration\n",
                e->n_backend_slots, before);
        fails = 1;
    }
    ds_engine_free(e);
    return fails;
}

int main(void)
{
    int fails = 0;

    fails += test_served_but_unallocated_is_silent();
    fails += test_unserved_agg_is_reported();
    fails += test_absent_row_is_silent();
    fails += test_second_registration_is_refused();
    fails += test_rfcs_6_7__series_no_backing_replays_past_its_pump();

    if (fails == 0)
        printf("OK  test_series_no_backing (%d tests)\n", 5);
    else
        fprintf(stderr, "FAILED: %d test(s) failed\n", fails);

    return fails ? 1 : 0;
}

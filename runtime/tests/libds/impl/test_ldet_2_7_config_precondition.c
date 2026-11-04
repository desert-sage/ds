/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LDET.2.7] [LSTO.4.7.5] [NDET.8.1] [NSTG.2.6.1]
 * Engine configuration is a precondition of replay, shown with the cache
 * bound: no atom records it, so a replay reproduces the run only under the
 * bound the recording engine had.
 *
 *   ra  (A a)  cache "ka": "1"
 *   rb  (B b)  cache "kb": "2"           -- refused under cap_keys = 1
 *   rc  (C c)  emit Out(val: c.val, got: cached("kb") ?? "miss")
 *
 * The refused write is a compared BoundsError (RFCS.6.7), where a replay under
 * another bound diverges; Out shows the bound also changes what `cached()`
 * returns. It is in impl/ because the replayer, `rfcs/rfcs.h`, is internal.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rfcs/rfcs.h"

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

static ds_rete_expr_t *ex_str(const char *s)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    e->lit_str = s;
    return e;
}

static ds_rete_expr_t *ex_int(int64_t v)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = v;
    return e;
}

static ds_rete_expr_t *ex_var(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = pat;
    e->var.slot_index = slot;
    return e;
}

/* (ds-cache-set key json 0): the compiler's lowering of `cache key: json`. */
static ds_rete_expr_t *ex_cache_set(const char *key, const char *json)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    e->call.op = DS_FN_CACHE_SET;
    e->call.args = calloc(3, sizeof(*e->call.args));
    e->call.args[0] = ex_str(key);
    e->call.args[1] = ex_str(json);
    e->call.args[2] = ex_int(0);
    e->call.arg_count = 3;
    return e;
}

/* `cached(key) ?? "miss"`: (ds-cache-get key), whose miss is null and whose hit
   is the stored JSON text, under COALESCE. */
static ds_rete_expr_t *ex_cached_or_miss(const char *key)
{
    ds_rete_expr_t *get = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    get->call.op = DS_FN_CACHE_GET;
    get->call.args = calloc(1, sizeof(*get->call.args));
    get->call.args[0] = ex_str(key);
    get->call.arg_count = 1;
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_COALESCE);
    e->coalesce.left = get;
    e->coalesce.right = ex_str("miss");
    return e;
}

/* The loader borrows the action arrays, so each engine's rig lives as long as
   the engine does. */
typedef struct {
    const ds_schema_t    *a, *b, *c;
    ds_rete_slot_assign_t assigns[2];
    ds_rete_action_t      ra[1], rb[1], rc[1];
} rig;

static int rig_open(ds_engine_t *e, rig *g)
{
    static const ds_slot_desc_t VAL = {
        .name = "val", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY };
    static const ds_slot_desc_t OUT[2] = {
        { .name = "val", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "got", .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    const ds_schema_t *out = NULL;
    memset(g, 0, sizeof(*g));
    if (ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  &VAL, 1, &g->a).status != DS_OK
        || ds_engine_register_schema(e, "B", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     &VAL, 1, &g->b).status != DS_OK
        || ds_engine_register_schema(e, "C", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     &VAL, 1, &g->c).status != DS_OK
        || ds_engine_register_schema(e, "Out", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     OUT, 2, &out).status != DS_OK)
        return 1;
    const ds_rete_schema_t *ors = ds_rete_schema_by_name(e->rete_engine, "Out");
    if (ors == NULL)
        return 1;

    g->ra[0] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL,
                                   .expr = ex_cache_set("ka", "1") };
    g->rb[0] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL,
                                   .expr = ex_cache_set("kb", "2") };
    g->assigns[0] = (ds_rete_slot_assign_t){ .slot_index = 0,
                                             .expr = ex_var(0, 0) };
    g->assigns[1] = (ds_rete_slot_assign_t){ .slot_index = 1,
                                             .expr = ex_cached_or_miss("kb") };
    g->rc[0] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_ASSERT,
                                   .schema_id = ors->id,
                                   .assigns = g->assigns, .assign_count = 2 };

    ds_alfa_atom_t alfas[3] = {
        { .node_id = 1, .schema_name = "A" },
        { .node_id = 2, .schema_name = "B" },
        { .node_id = 3, .schema_name = "C" },
    };
    ds_beta_atom_t betas[3] = {
        { .node_id = 4, .right_alpha_id = 1, .left_parent_id = 0 },
        { .node_id = 5, .right_alpha_id = 2, .left_parent_id = 0 },
        { .node_id = 6, .right_alpha_id = 3, .left_parent_id = 0 },
    };
    ds_term_atom_t terms[3] = {
        { .node_id = 7, .parent_beta_id = 4, .rule_name = "ra",
          .actions = g->ra, .action_count = 1 },
        { .node_id = 8, .parent_beta_id = 5, .rule_name = "rb",
          .actions = g->rb, .action_count = 1 },
        { .node_id = 9, .parent_beta_id = 6, .rule_name = "rc",
          .actions = g->rc, .action_count = 1 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 3,
                              .betas = betas, .beta_count = 3,
                              .terms = terms, .term_count = 3 };
    return ds_rete_load_network(e->rete_engine, &net).status != DS_OK;
}

/* A bound of 0 keys is no bound (NSTG.2.6.1), so `cap_keys` doubles as "give
   the engine this setting or none". */
static ds_engine_t *engine_with(rig *g, uint32_t cap_keys)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL)
        return NULL;
    if (rig_open(e, g) != 0) {
        ds_engine_free(e);
        return NULL;
    }
    if (ds_engine_set_cache_cap(e, cap_keys, 0).status != DS_OK) {
        ds_engine_free(e);
        return NULL;
    }
    return e;
}

static ds_result_t assert_val(ds_engine_t *e, const ds_schema_t *sc, int64_t v)
{
    ds_slot_value_t sv;
    memset(&sv, 0, sizeof(sv));
    sv.kind = DS_SLOT_INT;
    sv.v.i = v;
    return ds_engine_assert(e, sc, &sv, 1, NULL);
}

typedef struct { uint8_t buf[8192]; size_t len; } recording;

static ds_result_t sink(const uint8_t *bytes, size_t len, void *user)
{
    recording *r = user;
    if (r->len + len > sizeof(r->buf))
        return (ds_result_t){ DS_ERR_INVAL, "sink overflow" };
    memcpy(r->buf + r->len, bytes, len);
    r->len += len;
    return (ds_result_t){ DS_OK, NULL };
}

/* What rc's Out read for "kb": 1 = "miss", 2 = the string "2", 0 = no Out or
   anything else. */
typedef struct { int seen; } got_probe;

static ds_result_t probe_out(const ds_fact_t *fact, void *user)
{
    got_probe *p = user;
    ds_slot_value_t v;
    if (ds_fact_get_slot(fact, 1, NULL, &v).status != DS_OK)
        return (ds_result_t){ DS_OK, NULL };
    if (v.kind == DS_SLOT_STRING && v.v.s && strcmp(v.v.s, "miss") == 0)
        p->seen = 1;
    else if (v.kind == DS_SLOT_STRING && v.v.s && strcmp(v.v.s, "2") == 0)
        p->seen = 2;
    return (ds_result_t){ DS_OK, NULL };
}

static int out_got(ds_engine_t *e)
{
    const ds_schema_t *sc = NULL;
    got_probe p = { 0 };
    if (ds_engine_schema_find(e, "Out", &sc).status != DS_OK)
        return 0;
    if (ds_engine_for_each_fact(e, sc, probe_out, &p).status != DS_OK)
        return 0;
    return p.seen;
}

/* Record A(1), B(2), C(3), each pumped, under `cap_keys`. Returns what rc's Out
   read, and the second pump's status in *out_breach_status. */
static int record_run(uint32_t cap_keys, recording *out,
                      ds_status_t *out_breach_status)
{
    static rig g;
    ds_engine_t *e = engine_with(&g, cap_keys);
    CHECK(e != NULL, "recording engine opens");
    if (e == NULL)
        return 0;

    static uint8_t recbuf[4096];
    ds_rfcs_recorder_t rec;
    out->len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, sink, out, recbuf, sizeof(recbuf)),
             "record_to");

    CHECK_OK(assert_val(e, g.a, 1), "assert A(1)");
    CHECK_OK(ds_engine_pump(e), "ra's write fills the one key");
    CHECK_OK(assert_val(e, g.b, 2), "assert B(2)");
    *out_breach_status = ds_engine_pump(e).status;
    CHECK_OK(assert_val(e, g.c, 3), "assert C(3)");
    CHECK_OK(ds_engine_pump(e), "rc reads cached(\"kb\") and emits Out");
    CHECK(rec.last.status == DS_OK, "recorder had no error");

    int got = out_got(e);
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
    return got;
}

static ds_status_t replay_with(const recording *r, uint32_t cap_keys)
{
    static rig g;
    ds_engine_t *e = engine_with(&g, cap_keys);
    CHECK(e != NULL, "replaying engine opens");
    if (e == NULL)
        return DS_ERR_INVAL;
    static uint8_t strbuf[8192];
    ds_rfcs_replay_result_t rr;
    ds_status_t s = ds_rfcs_replay(e, r->buf, r->len, strbuf, sizeof(strbuf),
                                   &rr).status;
    ds_engine_free(e);
    return s;
}

int main(void)
{
    static recording bounded, unbounded;
    ds_status_t breach = DS_OK;

    /* Under cap_keys = 1, rb's write is refused, the pump reports it
       (LSTO.4.7.5, RTCT.7.2) and the run goes on. */
    int got_bounded = record_run(1, &bounded, &breach);
    CHECK(breach == DS_ERR_CONTRACT_BREACH,
          "case 1: rb's write is refused and the pump reports the breach");
    CHECK(got_bounded == 1,
          "case 1: Out read cached(\"kb\") as a miss: the bound refused the write");

    CHECK(replay_with(&bounded, 1) == DS_OK,
          "case 2: replayed under the recorded bound, the run reproduces");

    CHECK(replay_with(&bounded, 0) == DS_ERR_FS_DIVERGENCE,
          "case 3: replayed with no bound, the replay diverges");

    /* A bound that admits the write diverges too: the replay needs the
       recording's setting, not merely some bound. */
    CHECK(replay_with(&bounded, 2) == DS_ERR_FS_DIVERGENCE,
          "case 4: replayed under a bound of two keys, the replay diverges");

    ds_status_t unbounded_pump = DS_OK;
    int got_unbounded = record_run(0, &unbounded, &unbounded_pump);
    CHECK(unbounded_pump == DS_OK, "case 5: with no bound, no write is refused");
    CHECK(got_unbounded == 2,
          "case 5: with no bound, Out read cached(\"kb\") as \"2\"");
    CHECK(replay_with(&unbounded, 1) == DS_ERR_FS_DIVERGENCE,
          "case 5: an unbounded recording replayed under a bound diverges");

    CHECK(replay_with(&unbounded, 0) == DS_OK,
          "case 6: an unbounded recording replayed unbounded reproduces");

    if (failures) {
        fprintf(stderr, "test_ldet_2_7_config_precondition: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_ldet_2_7_config_precondition: OK\n");
    return 0;
}

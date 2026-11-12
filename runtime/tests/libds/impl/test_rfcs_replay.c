/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [RFCS.16.3]
 * ds_rfcs_replay. Records a scenario on a source engine (two asserts, one
 * of them retracted), replays it into a cold engine that holds only the same
 * schema, and checks that exactly the un-retracted fact survives, with its
 * slot values ([LDET.1.1]).
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <stdlib.h>

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

static const ds_slot_desc_t SLOTS[2] = {
    { .name = "count", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
    { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
};

static const ds_schema_t *register_pkt(ds_engine_t *e)
{
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Pkt", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 2, &sc),
             "register_schema");
    return sc;
}

/* recorder sink: append framed atoms into a flat buffer. */
static uint8_t g_stream[8192];
static size_t g_stream_len = 0;

static ds_result_t test_sink(const uint8_t *bytes, size_t len, void *user)
{
    (void)user;
    if (g_stream_len + len > sizeof(g_stream))
        return (ds_result_t){ DS_ERR_INVAL, "sink overflow" };
    memcpy(g_stream + g_stream_len, bytes, len);
    g_stream_len += len;
    return (ds_result_t){ DS_OK, NULL };
}

/* wm visitor: collect the (count,label) of every surviving fact. */
typedef struct {
    int      n;
    int64_t  count[8];
    char     label[8][32];
} wm_snapshot;

static ds_result_t collect_fact(const ds_fact_t *fact, void *user)
{
    wm_snapshot *s = (wm_snapshot *)user;
    if (s->n >= 8)
        return (ds_result_t){ DS_OK, NULL };
    ds_slot_value_t c, l;
    ds_fact_get_slot(fact, 0, NULL, &c);
    ds_fact_get_slot(fact, 1, NULL, &l);
    s->count[s->n] = c.v.i;
    snprintf(s->label[s->n], sizeof(s->label[s->n]), "%s", l.v.s ? l.v.s : "");
    s->n++;
    return (ds_result_t){ DS_OK, NULL };
}

/* ---- [RFCS.6.7]: a host assert a bound refuses --------------------------
   `Line{k key, text mutable}` with `text` given a `capacity` of 3 -- white-box,
   on the network's slot descriptor, because the public registration call has
   no capacity argument and a slot gets one only from a loaded artefact. */
static const ds_slot_desc_t LINE_SLOTS[2] = {
    { .name = "k",    .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
    { .name = "text", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_MUTABLE },
};

static const ds_schema_t *register_line(ds_engine_t *e, uint32_t capacity)
{
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Line", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       LINE_SLOTS, 2, &sc),
             "register Line");
    const ds_rete_schema_t *rs = ds_rete_schema_by_name(e->rete_engine, "Line");
    CHECK(rs != NULL && rs->slot_count == 2, "Line is in the network");
    if (rs != NULL && rs->slot_count == 2)
        rs->slots[1].capacity = capacity;
    return sc;
}

static ds_result_t assert_line(ds_engine_t *e, const ds_schema_t *sc,
                               int64_t k, const char *text)
{
    ds_slot_value_t v[2];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i = k;
    v[1].kind = DS_SLOT_STRING;
    v[1].v.s = text;
    ds_fact_t *f = NULL;
    return ds_engine_assert(e, sc, v, 2, &f);
}

/* A chaining stream callback ([RFCS] ds_rfcs_recorder_on_event): frames each
   event, then logs its kind, every FactAssert's `text` and the BoundsError. */
typedef struct {
    ds_rfcs_recorder_t *rec;
    int                 n;
    ds_stream_ev_kind_t kinds[32];
    int                 n_asserts;
    char                text[8][16];
    int                 n_bounds;
    int                 cap;
    uint64_t            limit, observed;
} cap_log;

static ds_result_t cap_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    cap_log *L = (cap_log *)u;
    ds_result_t r = ds_rfcs_recorder_on_event(e, ev, L->rec);
    if (L->n < 32) L->kinds[L->n++] = ev->kind;
    if (ev->kind == DS_EV_FACT_ASSERT && L->n_asserts < 8) {
        ds_slot_value_t t;
        memset(&t, 0, sizeof(t));
        ds_fact_get_slot(ev->p.fact_assert.fact, 1, NULL, &t);
        snprintf(L->text[L->n_asserts++], sizeof(L->text[0]), "%s",
                 (t.kind == DS_SLOT_STRING && t.v.s) ? t.v.s : "");
    }
    if (ev->kind == DS_EV_BOUNDS_ERROR) {
        L->n_bounds++;
        L->cap      = (int)ev->p.bounds_error.cap;
        L->limit    = ev->p.bounds_error.limit;
        L->observed = ev->p.bounds_error.observed;
    }
    return r;
}

/* @spec [NFCT.5.1] [RFCS.6.7] */
static void test_rfcs_6_7_refused_input_is_recorded(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *src = NULL;
    CHECK_OK(ds_engine_new(&cfg, &src), "engine_new capacity src");
    if (!src) return;
    const ds_schema_t *sc = register_line(src, 3);

    ds_rfcs_recorder_t rec;
    uint8_t recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_begin(src, &rec, test_sink, NULL, recbuf,
                                  sizeof(recbuf)), "record_begin");
    cap_log L;
    memset(&L, 0, sizeof(L));
    L.rec = &rec;
    CHECK_OK(ds_engine_set_stream_callback(src, cap_cb, &L), "chain callback");

    CHECK_OK(assert_line(src, sc, 1, "abc"), "three codepoints fit");
    const int before = L.n;
    ds_result_t refused = assert_line(src, sc, 2, "abcd");
    CHECK(refused.status == DS_ERR_CONTRACT_BREACH,
          "four codepoints are refused as a bound (LSTR.11.3)");
    CHECK_OK(assert_line(src, sc, 3, "ab"), "two codepoints fit");
    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_set_stream_callback(src, NULL, NULL);

    /* THE REFUSED INPUT IS RECORDED, AND FIRST: its FactAssert, carrying what
       arrived, then the BoundsError -- with no event between them. */
    {
        int fa = -1;
        for (int i = before; i < L.n; i++)
            if (L.kinds[i] == DS_EV_FACT_ASSERT) { fa = i; break; }
        CHECK(fa >= 0 && fa + 1 < L.n
              && L.kinds[fa + 1] == DS_EV_BOUNDS_ERROR,
              "the refused assert's FactAssert is followed by its BoundsError");
    }
    CHECK(L.n_asserts == 3, "three FactAsserts: two admitted, one refused");
    CHECK(L.n_asserts >= 2 && strcmp(L.text[1], "abcd") == 0,
          "the refused FactAssert carries the value that arrived");
    CHECK(L.n_bounds == 1 && L.cap == (int)DS_CAP_VALUE_CAPACITY
          && L.limit == 3 && L.observed == 4,
          "BoundsError(CAP_VALUE_CAPACITY, 3, 4)");

    /* THE REPLAY DELIVERS IT, THE ENGINE REFUSES IT AGAIN, AND THE TWO
       BoundsErrors ARE COMPARED. Not a replay failure ([RFCS.6.7]). */
    {
        ds_engine_t *dst = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new capacity dst");
        (void)register_line(dst, 3);
        static uint8_t strbuf[8192];
        ds_rfcs_replay_result_t rr;
        CHECK_OK(ds_rfcs_replay(dst, g_stream, g_stream_len, strbuf,
                                sizeof(strbuf), &rr),
                 "a refused input replays as a refusal");
        CHECK(rr.asserts == 3, "all three inputs delivered");
        wm_snapshot snap;
        memset(&snap, 0, sizeof(snap));
        const ds_schema_t *dsc = NULL;
        CHECK_OK(ds_engine_schema_find(dst, "Line", &dsc), "schema_find Line");
        CHECK_OK(ds_engine_for_each_fact(dst, dsc, collect_fact, &snap),
                 "for_each_fact Line");
        CHECK(snap.n == 2, "the refused input never entered on replay");
        ds_engine_free(dst);
    }

    /* THE COMPARE IS LIVE. Replayed into an engine whose slot has no
       capacity, the input is admitted, no BoundsError is re-derived, and the
       recorded one has no counterpart: a divergence, not a pass. */
    {
        ds_engine_t *dst = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new no-capacity dst");
        (void)register_line(dst, 0);
        static uint8_t strbuf[8192];
        ds_rfcs_replay_result_t rr;
        ds_result_t r = ds_rfcs_replay(dst, g_stream, g_stream_len, strbuf,
                                       sizeof(strbuf), &rr);
        CHECK(r.status == DS_ERR_FS_DIVERGENCE,
              "an un-refused replay diverges at the recorded BoundsError");
        ds_engine_free(dst);
    }

    ds_engine_free(src);
}

/* ---- [RFCS.6.7]: a host call that is not a well-formed input records
   nothing -------------------------------------------------------------------
   The C API names a schema by handle, so "a schema this engine does not
   hold" is one registered with another engine. It is the first call on
   `home`, where a consumed input would take the engine's first clock sample;
   the refusal comes before the sample, so no event reaches the stream. */
static ds_result_t count_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void)e;
    (void)ev;
    (*(int *)u)++;
    return (ds_result_t){ DS_OK, NULL };
}

/* @spec [RFCS.6.7] */
static void test_rfcs_6_7_unknown_schema_records_nothing(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *home = NULL, *other = NULL;
    CHECK_OK(ds_engine_new(&cfg, &home), "engine_new home");
    CHECK_OK(ds_engine_new(&cfg, &other), "engine_new other");
    if (!home || !other) return;
    (void)register_pkt(home);
    const ds_schema_t *foreign = register_line(other, 0);

    int events = 0;
    CHECK_OK(ds_engine_set_stream_callback(home, count_cb, &events),
             "count home's events");
    ds_result_t r = assert_line(home, foreign, 1, "abc");
    CHECK(r.status == DS_ERR_SCHEMA_UNKNOWN,
          "a schema the engine does not hold is refused (NFCT.1.1)");
    {
        char diag[160];
        snprintf(diag, sizeof(diag),
                 "the refused call recorded nothing, not even a tick "
                 "(got %d event(s))", events);
        CHECK(events == 0, diag);
    }
    size_t n = 1;
    CHECK_OK(ds_engine_fact_count(home, &n), "fact_count home");
    CHECK(n == 0, "and nothing entered working memory");

    ds_engine_set_stream_callback(home, NULL, NULL);
    ds_engine_free(other);
    ds_engine_free(home);
}

/* ---- [RFCS.6.7]: a bound refuses a rule's write, inside a pump ------------
   A cache write a `cache_cap` refuses records its BoundsError inside the
   firing, the firing stops at the write ([LSTO.4.7.5]), and the pump returns
   DS_ERR_CONTRACT_BREACH ([RTCT.7.2]); the run continues. A replay of that
   recording continues too, re-deriving and comparing each BoundsError, and
   reaches the inputs taken after the breach.

   Two rules over a hand-loaded network: `ra` (A) writes "ka"; `rb` (B)
   writes "kb" and then emits Out(b.val). Under cap_keys = 1, "ka" fills the
   cache, so every `rb` firing is refused at its write and never emits. The
   bound is engine configuration, so the replaying engine is given it too
   ([LDET.2.7]). */
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

/* The loader borrows the action arrays, so each engine's live as long as it. */
typedef struct {
    const ds_schema_t    *a, *b;
    ds_rete_slot_assign_t assign;
    ds_rete_action_t      ra[1], rb[2];
} pump_rig;

static int pump_rig_open(ds_engine_t *e, pump_rig *g)
{
    static const ds_slot_desc_t VAL = {
        .name = "val", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *out = NULL;
    memset(g, 0, sizeof(*g));
    if (ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  &VAL, 1, &g->a).status != DS_OK
        || ds_engine_register_schema(e, "B", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     &VAL, 1, &g->b).status != DS_OK
        || ds_engine_register_schema(e, "Out", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     &VAL, 1, &out).status != DS_OK)
        return 1;
    const ds_rete_schema_t *ors = ds_rete_schema_by_name(e->rete_engine, "Out");
    if (ors == NULL)
        return 1;

    g->ra[0] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL,
                                   .expr = ex_cache_set("ka", "1") };
    g->rb[0] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_CALL,
                                   .expr = ex_cache_set("kb", "2") };
    g->assign.slot_index = 0;
    g->assign.expr = ex_var(0, 0);
    g->rb[1] = (ds_rete_action_t){ .kind = DS_RETE_ACTION_ASSERT,
                                   .schema_id = ors->id,
                                   .assigns = &g->assign, .assign_count = 1 };

    ds_alfa_atom_t alfas[2] = {
        { .node_id = 1, .schema_name = "A" },
        { .node_id = 2, .schema_name = "B" },
    };
    ds_beta_atom_t betas[2] = {
        { .node_id = 3, .right_alpha_id = 1, .left_parent_id = 0 },
        { .node_id = 4, .right_alpha_id = 2, .left_parent_id = 0 },
    };
    ds_term_atom_t terms[2] = {
        { .node_id = 5, .parent_beta_id = 3, .rule_name = "ra",
          .actions = g->ra, .action_count = 1 },
        { .node_id = 6, .parent_beta_id = 4, .rule_name = "rb",
          .actions = g->rb, .action_count = 2 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 2,
                              .betas = betas, .beta_count = 2,
                              .terms = terms, .term_count = 2 };
    return ds_rete_load_network(e->rete_engine, &net).status != DS_OK;
}

static ds_result_t assert_val(ds_engine_t *e, const ds_schema_t *sc, int64_t v)
{
    ds_slot_value_t sv;
    memset(&sv, 0, sizeof(sv));
    sv.kind = DS_SLOT_INT;
    sv.v.i = v;
    return ds_engine_assert(e, sc, &sv, 1, NULL);
}

static ds_result_t count_fact(const ds_fact_t *fact, void *user)
{
    (void)fact;
    (*(int *)user)++;
    return (ds_result_t){ DS_OK, NULL };
}

static int out_count(ds_engine_t *e)
{
    const ds_schema_t *sc = NULL;
    int n = 0;
    if (ds_engine_schema_find(e, "Out", &sc).status != DS_OK)
        return -1;
    if (ds_engine_for_each_fact(e, sc, count_fact, &n).status != DS_OK)
        return -1;
    return n;
}

/* @spec [LSTO.4.7.5] [RFCS.6.7] */
static void test_rfcs_6_7_refused_rule_write_replays_past_the_pump(void)
{
    static pump_rig g_src, g_same, g_none;
    ds_engine_config_t cfg = {0};

    ds_engine_t *src = NULL;
    CHECK_OK(ds_engine_new(&cfg, &src), "engine_new pump-breach src");
    if (!src) return;
    CHECK(pump_rig_open(src, &g_src) == 0, "src network loads");
    CHECK_OK(ds_engine_set_cache_cap(src, 1, 0), "src cache_cap 1");

    ds_rfcs_recorder_t rec;
    uint8_t recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(src, &rec, test_sink, NULL, recbuf,
                               sizeof(recbuf)), "record_to");

    CHECK_OK(assert_val(src, g_src.a, 1), "assert A(1)");
    CHECK_OK(ds_engine_pump(src), "ra's write fills the cache");
    CHECK_OK(assert_val(src, g_src.b, 2), "assert B(2)");
    CHECK(ds_engine_pump(src).status == DS_ERR_CONTRACT_BREACH,
          "rb's write is refused, and the pump reports it (RTCT.7.2)");
    CHECK_OK(assert_val(src, g_src.b, 3), "assert B(3) after the breach");
    CHECK(ds_engine_pump(src).status == DS_ERR_CONTRACT_BREACH,
          "refused again, in a later pump");
    CHECK(rec.last.status == DS_OK, "recorder had no error");
    CHECK(out_count(src) == 0,
          "each refused firing stopped at its write: no Out (LSTO.4.7.5)");
    ds_engine_set_stream_callback(src, NULL, NULL);

    /* THE SAME BOUND: the replay continues past each breaching pump, and both
       BoundsErrors compare. */
    {
        ds_engine_t *dst = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new pump-breach same");
        if (dst) {
            CHECK(pump_rig_open(dst, &g_same) == 0, "same network loads");
            CHECK_OK(ds_engine_set_cache_cap(dst, 1, 0), "same cache_cap 1");
            static uint8_t strbuf[8192];
            ds_rfcs_replay_result_t rr;
            CHECK_OK(ds_rfcs_replay(dst, g_stream, g_stream_len, strbuf,
                                    sizeof(strbuf), &rr),
                     "a breach the recording holds is replayed past, not failed on");
            /* `asserts` counts each FactAssert delivered and each FactEmit
               compared: three inputs, and no Out. B(3) arrives after the
               first breaching pump. */
            CHECK(rr.asserts == 3,
                  "three inputs delivered, past the first breaching pump");
            CHECK(out_count(dst) == 0, "no Out re-derived, as none was recorded");
            ds_engine_free(dst);
        }
    }

    /* THE COMPARE IS LIVE. With no bound, both writes succeed, no BoundsError
       is re-derived, and the recorded one has no counterpart. */
    {
        ds_engine_t *dst = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new pump-breach none");
        if (dst) {
            CHECK(pump_rig_open(dst, &g_none) == 0, "unbounded network loads");
            static uint8_t strbuf[8192];
            ds_rfcs_replay_result_t rr;
            ds_result_t r = ds_rfcs_replay(dst, g_stream, g_stream_len, strbuf,
                                           sizeof(strbuf), &rr);
            CHECK(r.status == DS_ERR_FS_DIVERGENCE,
                  "an unbounded replay diverges at the recorded BoundsError");
            ds_engine_free(dst);
        }
    }

    ds_engine_free(src);
}

static ds_fact_t *assert_pkt(ds_engine_t *e, const ds_schema_t *sc,
                             int64_t count, const char *label)
{
    ds_slot_value_t v[2];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i = count;
    v[1].kind = DS_SLOT_STRING;
    v[1].v.s = label;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 2, &f), "assert");
    return f;
}

/* [RFCS.7.3]: the recording without the FactAssert of the fact its
   FactRetract names, every other atom's frame copied byte for byte. Each
   frame's extent is the reader's position before and after it. 0 if there
   is no FactRetract, or `out` is too small. */
static size_t drop_retracted_assert(const uint8_t *in, size_t len,
                                    uint8_t *out, size_t cap)
{
    ds_rfcs_reader_t rd;
    uint32_t         atom = 0;
    const uint8_t   *body = NULL;
    size_t           blen = 0;
    bool             done = false;
    uint64_t         gone = 0;
    bool             have = false;

    ds_rfcs_reader_init(&rd, in, len);
    while (ds_rfcs_next(&rd, &atom, &body, &blen, &done).status == DS_OK && !done) {
        ds_rfcs_fcrt_t fr;
        if (atom == DS_ATOM_FACT_RETRACT
                && ds_rfcs_decode_fcrt(body, blen, &fr).status == DS_OK) {
            gone = fr.fact_id;
            have = true;
        }
    }
    if (!have)
        return 0;

    size_t n = 0;
    done = false;
    ds_rfcs_reader_init(&rd, in, len);
    for (;;) {
        const size_t start = rd.pos;
        if (ds_rfcs_next(&rd, &atom, &body, &blen, &done).status != DS_OK || done)
            break;
        ds_rfcs_fcem_t fc;
        if (atom == DS_ATOM_FACT_ASSERT
                && ds_rfcs_decode_fcem(body, blen, &fc).status == DS_OK
                && fc.fact_id == gone)
            continue;
        const size_t w = rd.pos - start;
        if (n + w > cap)
            return 0;
        memcpy(out + n, in + start, w);
        n += w;
    }
    return n;
}

/* [RFCS.5.4]'s first case: the recording without its SchemaDef and Slot
   atoms, every other frame copied byte for byte -- [RCTS.1.2.18]'s
   `drop_schema_def`, for a recording of one schema. 0 if nothing was
   dropped, or `out` is too small. */
static size_t drop_announcements(const uint8_t *in, size_t len,
                                 uint8_t *out, size_t cap)
{
    ds_rfcs_reader_t rd;
    uint32_t         atom = 0;
    const uint8_t   *body = NULL;
    size_t           blen = 0;
    bool             done = false;
    bool             dropped = false;
    size_t           n = 0;

    ds_rfcs_reader_init(&rd, in, len);
    for (;;) {
        const size_t start = rd.pos;
        if (ds_rfcs_next(&rd, &atom, &body, &blen, &done).status != DS_OK || done)
            break;
        if (atom == DS_ATOM_SCHEMA_DEF || atom == DS_ATOM_SLOT) {
            dropped = true;
            continue;
        }
        const size_t w = rd.pos - start;
        if (n + w > cap)
            return 0;
        memcpy(out + n, in + start, w);
        n += w;
    }
    return dropped ? n : 0;
}

/* ---- [RFCS.10.5]: a ClockAdvance outside the clock's range -----------------
   A run's recording with a ClockAdvance of clock_ns -1 added at its end: no run
   records one and no fixture can edit one. The replay delivers the run's assert
   and ends at the atom with DS_ERR_TIME_RANGE. The control replays the recording
   without the atom. The Mercury runtime's ds.replay ends the same replay with
   the same code (test_ds's
   test_rfcs_10_5_a_clock_outside_the_range_ends_the_replay). */
/* @spec [RFCS.10.5] */
static void test_rfcs_10_5__a_clock_outside_the_range_ends_the_replay(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *src = NULL;
    CHECK_OK(ds_engine_new(&cfg, &src), "engine_new clock-range src");
    if (!src) return;
    const ds_schema_t *ssc = register_pkt(src);

    ds_rfcs_recorder_t rec;
    uint8_t recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(src, &rec, test_sink, NULL, recbuf,
                               sizeof(recbuf)), "record_to clock-range");
    (void)assert_pkt(src, ssc, 42, "alpha");
    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_set_stream_callback(src, NULL, NULL);
    const size_t run_len = g_stream_len;

    size_t added = 0;
    CHECK_OK(ds_rfcs_encode_clka(0, -1, false, 0, g_stream + g_stream_len,
                                 sizeof(g_stream) - g_stream_len, &added),
             "encode a ClockAdvance of -1");
    g_stream_len += added;

    static uint8_t strbuf[8192];
    for (int whole = 0; whole < 2; whole++) {
        ds_engine_t *dst = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new clock-range dst");
        if (!dst) break;
        (void)register_pkt(dst);
        ds_rfcs_replay_result_t rr;
        memset(&rr, 0, sizeof rr);
        ds_result_t r = ds_rfcs_replay(dst, g_stream,
                                       whole ? run_len : g_stream_len, strbuf,
                                       sizeof(strbuf), &rr);
        CHECK(rr.asserts == 1, "the run's assert is delivered");
        if (whole) {
            CHECK_OK(r, "the recording without the atom replays");
        } else {
            char diag[200];
            snprintf(diag, sizeof diag,
                     "a ClockAdvance of -1 ends the replay with "
                     "DS_ERR_TIME_RANGE (got %d: %s)",
                     r.status, r.detail ? r.detail : "(null)");
            CHECK(r.status == DS_ERR_TIME_RANGE, diag);
        }
        ds_engine_free(dst);
    }
    ds_engine_free(src);
}

/* ---- [RFCS.6.7]: a replayed pump refused before its step ------------------
   The run, with no seed: a pump at a mock clock of INT64_MAX - 1 s, then
   Pkt(42, "alpha") and a second pump. A pump refused before its step
   ([NLFC.9.5]) leaves no PumpBoundary, so no run records one, and a replay
   meets one only on an engine that is not the run's: one the host seeded,
   which [RFCS.26.2] forbids. Seeded with "k" for 1 h, the first replayed pump
   would give "k" a deadline past the Time range, and is refused with
   DS_ERR_TIME_RANGE, a status no clause makes an outcome: the replay ends
   there and delivers nothing after it. The control replays the same
   recording into an unseeded engine, which reproduces the run, so the seed is
   the only difference. The Mercury runtime's ds.replay ends the same replay
   with the same code (test_ds check_replay_pump_time_range). */
/* @spec [RFCS.6.7] */
static void test_rfcs_6_7_time_range_pump_ends_the_replay(void)
{
    const uint64_t hour_ns = 3600ull * 1000000000ull;
    ds_engine_config_t cfg = {0};
    ds_engine_t *src = NULL;
    CHECK_OK(ds_engine_new(&cfg, &src), "engine_new time-range src");
    if (!src) return;
    const ds_schema_t *ssc = register_pkt(src);
    CHECK_OK(ds_engine_clock_set_mode(src, DS_CLOCK_MOCK), "src mock clock");
    CHECK_OK(ds_engine_clock_set(src, (uint64_t)INT64_MAX - 1000000000ull),
             "src clock at INT64_MAX - 1 s");

    ds_rfcs_recorder_t rec;
    uint8_t recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(src, &rec, test_sink, NULL, recbuf,
                               sizeof(recbuf)), "record_to");
    CHECK_OK(ds_engine_pump(src), "the run's first pump, with no seed");
    (void)assert_pkt(src, ssc, 42, "alpha");
    CHECK_OK(ds_engine_pump(src), "the run's second pump");
    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_set_stream_callback(src, NULL, NULL);

    /* SEEDED: the first replayed pump is refused, and the replay ends. */
    {
        ds_engine_t *dst = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new time-range seeded");
        if (dst) {
            (void)register_pkt(dst);
            ds_json_t *one = NULL;
            CHECK_OK(ds_json_parse("1", 1, &one), "json_parse 1");
            CHECK_OK(ds_engine_cache_seed(dst, "k", one, hour_ns),
                     "seed k, ttl 1 h");
            static uint8_t strbuf[8192];
            ds_rfcs_replay_result_t rr;
            memset(&rr, 0, sizeof rr);
            ds_result_t r = ds_rfcs_replay(dst, g_stream, g_stream_len, strbuf,
                                           sizeof(strbuf), &rr);
            {
                char diag[200];
                snprintf(diag, sizeof diag,
                         "a replayed pump refused before its step ends the "
                         "replay with DS_ERR_TIME_RANGE (got %d: %s)",
                         r.status, r.detail ? r.detail : "(null)");
                CHECK(r.status == DS_ERR_TIME_RANGE, diag);
            }
            CHECK(rr.asserts == 0, "nothing after the refused pump is delivered");
            size_t n = 1;
            CHECK_OK(ds_engine_fact_count(dst, &n), "fact_count seeded");
            CHECK(n == 0, "and nothing entered working memory");
            ds_engine_free(dst);
            ds_json_free(one);
        }
    }

    /* THE CONTROL: unseeded, the same recording replays whole. */
    {
        ds_engine_t *dst = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new time-range unseeded");
        if (dst) {
            (void)register_pkt(dst);
            static uint8_t strbuf[8192];
            ds_rfcs_replay_result_t rr;
            memset(&rr, 0, sizeof rr);
            CHECK_OK(ds_rfcs_replay(dst, g_stream, g_stream_len, strbuf,
                                    sizeof(strbuf), &rr),
                     "unseeded, the recording replays");
            CHECK(rr.asserts == 1, "the Pkt between the pumps is delivered");
            size_t n = 0;
            CHECK_OK(ds_engine_fact_count(dst, &n), "fact_count unseeded");
            CHECK(n == 1, "and it is in working memory");
            ds_engine_free(dst);
        }
    }

    ds_engine_free(src);
}

/* ds_rfcs_replay_finish frees the compare recorder, so it leaves no pointer to
   it in the stream slot, on a running engine and on one the replay halted.
   White-box: the halt is set on the latch, and the slot has no public
   read. */
static void test_replay_finish_empties_the_slot(void)
{
    for (int halt = 0; halt < 2; halt++) {
        ds_engine_config_t cfg = {0};
        ds_engine_t *e = NULL;
        CHECK_OK(ds_engine_new(&cfg, &e), "engine_new finish slot");
        if (!e) return;
        ds_rfcs_replay_ctx_t *ctx = NULL;
        CHECK_OK(ds_rfcs_replay_begin(e, NULL, &ctx), "replay_begin finish slot");
        if (ctx != NULL) {
            CHECK(e->recorder.stream_cb != NULL, "the replay's recorder is installed");
            e->halted = halt != 0;
            (void)ds_rfcs_replay_finish(ctx, NULL);
            CHECK(e->recorder.stream_cb == NULL, "finish empties the stream slot");
            CHECK(e->recorder.stream_user == NULL, "finish empties the slot's context");
        }
        ds_engine_free(e);
    }
}

int main(void)
{
    /* --- record a scenario on the source engine --- */
    ds_engine_config_t cfg = {0};
    ds_engine_t *src = NULL;
    CHECK_OK(ds_engine_new(&cfg, &src), "engine_new src");
    if (!src)
        return 1;
    const ds_schema_t *ssc = register_pkt(src);

    ds_rfcs_recorder_t rec;
    uint8_t recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(src, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    /* A stays; B is asserted then retracted. */
    (void)assert_pkt(src, ssc, 42, "alpha");
    ds_fact_t *b = assert_pkt(src, ssc, 7, "bravo");
    CHECK_OK(ds_engine_retract(src, b), "retract B");
    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_set_stream_callback(src, NULL, NULL);

    /* --- replay into a cold engine that knows only the schema --- */
    ds_engine_t *dst = NULL;
    CHECK_OK(ds_engine_new(&cfg, &dst), "engine_new dst");
    if (!dst)
        return 1;
    (void)register_pkt(dst);

    /* String slots are borrowed by the engine for each fact's lifetime, so the
       arena must outlive the for_each_fact readback below (and ds_engine_free). */
    static uint8_t strbuf[8192];
    ds_rfcs_replay_result_t rr;
    CHECK_OK(ds_rfcs_replay(dst, g_stream, g_stream_len, strbuf, sizeof(strbuf), &rr),
             "replay");
    CHECK(rr.asserts == 2, "replay applied two asserts");
    CHECK(rr.retracts == 1, "replay applied one retract");
    /* source had no DSC loaded, so the header carries no dsc_hash to match. */
    CHECK(!rr.header_verified, "no dsc_hash to positively verify");

    /* --- verify the reconstructed working memory --- */
    wm_snapshot snap;
    memset(&snap, 0, sizeof(snap));
    const ds_schema_t *dsc = NULL;
    CHECK_OK(ds_engine_schema_find(dst, "Pkt", &dsc), "schema_find dst");
    CHECK_OK(ds_engine_for_each_fact(dst, dsc, collect_fact, &snap),
             "for_each_fact");
    {
        char diag[160];
        snprintf(diag, sizeof(diag),
                 "exactly the un-retracted fact survives (got n=%d)", snap.n);
        CHECK(snap.n == 1, diag);
    }
    if (snap.n == 1) {
        char diag[160];
        snprintf(diag, sizeof(diag),
                 "surviving fact is the asserted-not-retracted one "
                 "(got count=%lld label=%s)",
                 (long long)snap.count[0], snap.label[0]);
        CHECK(snap.count[0] == 42 && strcmp(snap.label[0], "alpha") == 0, diag);
    }

    /* --- a second cold replay of the same recording --- */
    {
        /* No dsc_hash on either side: unverifiable, not a mismatch. The
           mismatch is test_rfcs_golden's test_header_binding. */
        static uint8_t strbuf2[8192];
        ds_rfcs_replay_result_t rr2;
        ds_engine_t *dst2 = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst2), "engine_new dst2");
        (void)register_pkt(dst2);
        CHECK_OK(ds_rfcs_replay(dst2, g_stream, g_stream_len, strbuf2, sizeof(strbuf2), &rr2),
                 "replay again");
        CHECK(rr2.asserts == 2 && rr2.retracts == 1, "second replay matches");
        ds_engine_free(dst2);
    }

    /* --- [RFCS.19.3]: atoms at 260 and 323 are refused ---
       The same recording with both appended, hand-framed: 260 {sig_alg 1,
       key_id "K", seal_time "T", signature AA BB} and 323 {tag "license"
       NUL-padded to 16, text "hello"}. Neither number is in the registry, so
       neither names a member of Atom's oneof. The replay applies every input
       before them, leaving the working memory the plain one did, and is then
       refused with DS_ERR_PARSE; neither atom is counted in `skipped`. */
    {
        static const uint8_t seal_260[] = {
            0x0A, 0x0F,                         /* outer: field 1, len 15 */
            0xA2, 0x10, 0x0C,                   /* inner: 260, len 12 */
            0x08, 0x01, 0x12, 0x01, 0x4B,
            0x1A, 0x01, 0x54, 0x22, 0x02, 0xAA, 0xBB
        };
        static const uint8_t note_323[] = {
            0x0A, 0x1C,                          /* outer: field 1, len 28 */
            0x9A, 0x14, 0x19,                    /* inner: 323, len 25 */
            0x0A, 0x10,                          /* tag, len 16 */
            'l', 'i', 'c', 'e', 'n', 's', 'e',
            0, 0, 0, 0, 0, 0, 0, 0, 0,
            0x12, 0x05, 'h', 'e', 'l', 'l', 'o'  /* text, len 5 */
        };
        static uint8_t sealed[8192 + 512];
        CHECK(g_stream_len + sizeof seal_260 + sizeof note_323 <= sizeof sealed,
              "room for the recording and both atoms");
        memcpy(sealed, g_stream, g_stream_len);
        memcpy(sealed + g_stream_len, seal_260, sizeof seal_260);
        memcpy(sealed + g_stream_len + sizeof seal_260, note_323, sizeof note_323);
        size_t sealed_len = g_stream_len + sizeof seal_260 + sizeof note_323;

        static uint8_t strbuf3[8192];
        ds_rfcs_replay_result_t rr3;
        ds_engine_t *dst3 = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst3), "engine_new dst3");
        (void)register_pkt(dst3);
        memset(&rr3, 0, sizeof rr3);
        CHECK(ds_rfcs_replay(dst3, sealed, sealed_len, strbuf3, sizeof(strbuf3), &rr3).status
                  == DS_ERR_PARSE,
              "a stream with a 260 and a 323 appended is refused (RFCS.19.3)");
        CHECK(rr3.asserts == rr.asserts && rr3.retracts == rr.retracts,
              "every input before the 260 was applied");
        CHECK(rr3.skipped == rr.skipped,
              "the 260 is refused, not counted in `skipped`");

        wm_snapshot snap3;
        memset(&snap3, 0, sizeof(snap3));
        const ds_schema_t *dsc3 = NULL;
        CHECK_OK(ds_engine_schema_find(dst3, "Pkt", &dsc3), "schema_find dst3");
        CHECK_OK(ds_engine_for_each_fact(dst3, dsc3, collect_fact, &snap3),
                 "for_each_fact dst3");
        CHECK(snap3.n == snap.n
                  && (snap3.n != 1
                      || (snap3.count[0] == snap.count[0]
                          && strcmp(snap3.label[0], snap.label[0]) == 0)),
              "the refusal leaves the working memory the inputs before it made");
        ds_engine_free(dst3);
    }

    /* --- [RFCS.19.3]: an unknown field number is refused where it stands ---
       The same recording with a hand-framed atom at an unallocated number
       planted after the StreamHeader, between two known atoms: 322, then 100.
       Each replay is refused with DS_ERR_PARSE before any input after the
       plant is applied. Both go through replay_drain's ds_pbf_lookup
       refusal. */
    {
        static const uint8_t x_322[] = { 0x0A, 0x05, 0x92, 0x14, 0x02, 0x08, 0x01 };
        static const uint8_t x_100[] = { 0x0A, 0x05, 0xA2, 0x06, 0x02, 0x08, 0x01 };

        /* Where the first atom ends: the reader's position after one step. */
        ds_rfcs_reader_t rd;
        uint32_t first = 0;
        const uint8_t *bd = NULL;
        size_t bl = 0;
        bool done = false;
        ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
        CHECK_OK(ds_rfcs_next(&rd, &first, &bd, &bl, &done), "read the first atom");
        size_t cut = rd.pos;
        CHECK(!done && cut > 0 && cut < g_stream_len,
              "the recording has atoms after its first");

        static uint8_t planted[8192 + 16];
        memcpy(planted, g_stream, cut);
        memcpy(planted + cut, x_322, sizeof x_322);
        memcpy(planted + cut + sizeof x_322, g_stream + cut, g_stream_len - cut);
        size_t planted_len = g_stream_len + sizeof x_322;

        static uint8_t strbuf4[8192];
        ds_rfcs_replay_result_t rr4;
        ds_engine_t *dst4 = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst4), "engine_new dst4");
        (void)register_pkt(dst4);
        memset(&rr4, 0, sizeof rr4);
        CHECK(ds_rfcs_replay(dst4, planted, planted_len, strbuf4, sizeof(strbuf4), &rr4).status
                  == DS_ERR_PARSE,
              "a 322 after the StreamHeader is refused (RFCS.19.3)");
        CHECK(rr4.asserts == 0 && rr4.retracts == 0,
              "no input after the 322 was applied");
        ds_engine_free(dst4);

        memcpy(planted + cut, x_100, sizeof x_100);
        static uint8_t strbuf5[8192];
        ds_rfcs_replay_result_t rr5;
        ds_engine_t *dst5 = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst5), "engine_new dst5");
        (void)register_pkt(dst5);
        memset(&rr5, 0, sizeof rr5);
        CHECK(ds_rfcs_replay(dst5, planted, planted_len, strbuf5, sizeof(strbuf5), &rr5).status
                  == DS_ERR_PARSE,
              "a 100 after the StreamHeader is refused (RFCS.19.3)");
        CHECK(rr5.asserts == 0 && rr5.retracts == 0,
              "no input after the 100 was applied");
        ds_engine_free(dst5);
    }

    /* --- [RFCS.3.1]: 259, held for the deferred Checkpoint, is refused
       between two inputs ---
       The same recording with a hand-framed atom at 259 planted between A's
       FactAssert and B's, its body a Checkpoint's {seq 3, wm_count 1}. 259 is
       not in the registry, so it names no member of Atom's oneof
       ([RFCS.19.3]): A's assert is applied, the replay is refused with
       DS_ERR_PARSE at the 259, and B's assert is not applied. */
    {
        static const uint8_t cpkt_259[] = {
            0x0A, 0x07,                          /* outer: field 1, len 7 */
            0x9A, 0x10, 0x04,                    /* inner: 259, len 4 */
            0x08, 0x03, 0x18, 0x01               /* seq 3, wm_count 1 */
        };

        /* Where the first FactAssert ends. */
        ds_rfcs_reader_t rd;
        uint32_t atom = 0;
        const uint8_t *bd = NULL;
        size_t bl = 0;
        bool done = false;
        size_t cut = 0;
        ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
        while (ds_rfcs_next(&rd, &atom, &bd, &bl, &done).status == DS_OK && !done) {
            if (atom == DS_ATOM_FACT_ASSERT) {
                cut = rd.pos;
                break;
            }
        }
        CHECK(cut > 0 && cut < g_stream_len,
              "the recording has a FactAssert with atoms after it");

        static uint8_t planted[8192 + 16];
        memcpy(planted, g_stream, cut);
        memcpy(planted + cut, cpkt_259, sizeof cpkt_259);
        memcpy(planted + cut + sizeof cpkt_259, g_stream + cut, g_stream_len - cut);
        size_t planted_len = g_stream_len + sizeof cpkt_259;

        static uint8_t strbuf6[8192];
        ds_rfcs_replay_result_t rr6;
        ds_engine_t *dst6 = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst6), "engine_new dst6");
        (void)register_pkt(dst6);
        memset(&rr6, 0, sizeof rr6);
        CHECK(ds_rfcs_replay(dst6, planted, planted_len, strbuf6, sizeof(strbuf6), &rr6).status
                  == DS_ERR_PARSE,
              "a 259 between two inputs is refused (RFCS.19.3)");
        CHECK(rr6.asserts == 1 && rr6.retracts == 0,
              "A's assert before the 259 was applied, and nothing after it");
        ds_engine_free(dst6);
    }

    /* --- [RFCS.7.3], [RFCS.5.4]: the two reader refusals' codes ---
       The same recording with B's FactAssert dropped: its FactRetract names a
       fact_id no earlier FactAssert or FactEmit carries, after A's assert was
       delivered: DS_ERR_FS_UNKNOWN_FACT_ID. And the whole recording replayed
       into an engine that does not hold Pkt: DS_ERR_SCHEMA_UNKNOWN. The
       Mercury runtime's ds.replay refuses both with the same codes (test_ds
       check_reader_refusals). */
    {
        static uint8_t cut_stream[8192];
        const size_t cut_len = drop_retracted_assert(g_stream, g_stream_len,
                                                     cut_stream,
                                                     sizeof cut_stream);
        CHECK(cut_len > 0 && cut_len < g_stream_len,
              "the recording without B's FactAssert");
        static uint8_t strbuf6[8192];
        ds_rfcs_replay_result_t rr6;
        ds_engine_t *dst6 = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst6), "engine_new dst6");
        (void)register_pkt(dst6);
        ds_result_t r6 = ds_rfcs_replay(dst6, cut_stream, cut_len, strbuf6,
                                        sizeof strbuf6, &rr6);
        {
            char diag[200];
            snprintf(diag, sizeof diag,
                     "[RFCS.7.3] a FactRetract of an unknown fact_id refuses the "
                     "replay with DS_ERR_FS_UNKNOWN_FACT_ID (got %d: %s)",
                     r6.status, r6.detail ? r6.detail : "(null)");
            CHECK(r6.status == DS_ERR_FS_UNKNOWN_FACT_ID, diag);
        }
        ds_engine_free(dst6);

        static uint8_t strbuf7[8192];
        ds_rfcs_replay_result_t rr7;
        ds_engine_t *dst7 = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst7), "engine_new dst7 (no Pkt)");
        ds_result_t r7 = ds_rfcs_replay(dst7, g_stream, g_stream_len, strbuf7,
                                        sizeof strbuf7, &rr7);
        {
            char diag[200];
            snprintf(diag, sizeof diag,
                     "[RFCS.5.4] a FactAssert of a schema the engine does not "
                     "hold refuses the replay with DS_ERR_SCHEMA_UNKNOWN "
                     "(got %d: %s)",
                     r7.status, r7.detail ? r7.detail : "(null)");
            CHECK(r7.status == DS_ERR_SCHEMA_UNKNOWN, diag);
        }
        ds_engine_free(dst7);
    }

    /* --- [RFCS.5.4]'s first case: no SchemaDef announced it ---
       The same recording without its SchemaDef and Slot atoms, replayed into
       an engine that does hold Pkt: the stream never announced it
       ([RFCS.5.3]), so its first FactAssert is DS_ERR_SCHEMA_UNKNOWN, with
       the announcement pool's detail, and nothing is applied. The Mercury
       runtime's reader stops at the same atom (test_ds
       check_reader_refusals). */
    {
        static uint8_t bare[8192];
        const size_t bare_len = drop_announcements(g_stream, g_stream_len,
                                                   bare, sizeof bare);
        CHECK(bare_len > 0 && bare_len < g_stream_len,
              "the recording without its announcement");
        static uint8_t strbuf8[8192];
        ds_rfcs_replay_result_t rr8;
        memset(&rr8, 0, sizeof rr8);
        ds_engine_t *dst8 = NULL;
        CHECK_OK(ds_engine_new(&cfg, &dst8), "engine_new dst8");
        (void)register_pkt(dst8);
        ds_result_t r8 = ds_rfcs_replay(dst8, bare, bare_len, strbuf8,
                                        sizeof strbuf8, &rr8);
        {
            char diag[240];
            snprintf(diag, sizeof diag,
                     "[RFCS.5.4] a FactAssert no SchemaDef announced refuses "
                     "the replay with DS_ERR_SCHEMA_UNKNOWN, from the pool "
                     "(got %d: %s)",
                     r8.status, r8.detail ? r8.detail : "(null)");
            CHECK(r8.status == DS_ERR_SCHEMA_UNKNOWN
                      && r8.detail != NULL
                      && strstr(r8.detail, "no SchemaDef announced") != NULL,
                  diag);
        }
        size_t n8 = 1;
        CHECK_OK(ds_engine_fact_count(dst8, &n8), "fact_count dst8");
        CHECK(n8 == 0, "[RFCS.5.4] and nothing entered working memory");
        ds_engine_free(dst8);
    }

    ds_engine_free(dst);
    ds_engine_free(src);

    test_rfcs_6_7_refused_input_is_recorded();
    test_rfcs_6_7_unknown_schema_records_nothing();
    test_rfcs_6_7_refused_rule_write_replays_past_the_pump();
    test_rfcs_6_7_time_range_pump_ends_the_replay();
    test_rfcs_10_5__a_clock_outside_the_range_ends_the_replay();
    test_replay_finish_empties_the_slot();

    if (failures) {
        fprintf(stderr, "test_rfcs_replay: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_replay: OK\n");
    return 0;
}

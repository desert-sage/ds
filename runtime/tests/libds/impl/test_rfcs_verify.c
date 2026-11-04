/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Verify-mode replay ([LFST.9.3.1]). A firing program's recording is
 * replayed under the pump-per-input cadence ([LFST.9.2.1]); the replay
 * re-fires the rule and compares each re-derived compare atom with the
 * record.
 *   1. a clean round trip verifies;
 *   2. a flipped byte in a RuleFireAnnotation or a CallIssued diverges;
 *   3. a rule renamed in the replaying engine diverges on rule_name;
 *   4-6. two inputs verify, with and without a derived fact, and a replay
 *      spends exactly the events the recording spent;
 *   7. FactWithdraw is compared in both directions ([RFCS.7a.3]);
 *   8. `timetag` is compared by pairing ([LFST.9.3.6]): renamed timetags
 *      replay clean, and a broken pairing either way diverges.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/val.h"
#include "builtin_fn.h"
#include "rfcs/rfcs.h"
#include "dsc/pbf_reader.h"

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

/* ---- network-building helpers (mirror test_engine_rete_integration.c) ---- */

static ds_rete_expr_t *lit_int(int64_t v)
{ ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT); e->lit_int = v; return e; }
static ds_rete_expr_t *evar(uint16_t pat, uint16_t slot)
{ ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
  e->var.pattern_index = pat; e->var.slot_index = slot; return e; }
static ds_rete_expr_t *binop(ds_rete_binop_t op, ds_rete_expr_t *l, ds_rete_expr_t *r)
{ ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
  e->binop.op = op; e->binop.left = l; e->binop.right = r; return e; }
static ds_rete_expr_t *lit_str(const char *s)
{ ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR); e->lit_str = s; return e; }

/* No-op call callback so `adapter_ds_call` succeeds and emits ACTION_CALL. */
static ds_result_t noop_call(ds_engine_t *e, const ds_call_request_t *req, void *u)
{ (void)e; (void)req; (void)u; return (ds_result_t){ DS_OK, NULL }; }

static int setup_schema(ds_engine_t *e, const char *name,
                        const ds_schema_t **out_ds, const ds_rete_schema_t **out_rs)
{
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    ds_result_t r = ds_engine_register_schema(e, name, DS_SCHEMA_LIFECYCLE_LOGICAL,
                                              0, &sd, 1, out_ds);
    if (r.status != DS_OK) return 1;
    *out_rs = ds_rete_schema_by_name(e->rete_engine, name);
    return *out_rs == NULL;
}

/* Build "Src -> Out(val*2)" under `rule_name`. Returns the Src DS schema. */
static int build_net(ds_engine_t *e, const char *rule_name, int with_assert,
                     const ds_schema_t **out_src_ds)
{
    const ds_schema_t *src_ds = NULL, *out_ds = NULL;
    const ds_rete_schema_t *src_rs = NULL, *out_rs = NULL;
    if (setup_schema(e, "Src", &src_ds, &src_rs)) return 1;
    if (setup_schema(e, "Out", &out_ds, &out_rs)) return 1;
    (void)out_ds;

    ds_rete_expr_t *rexpr = binop(DS_RETE_BINOP_MUL, evar(0, 0), lit_int(2));
    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = rexpr };

    /* A CALL action too, so the fire re-derives a CallIssued. FN_CALL's
       operands are the service, the correlation, then one name/value pair per
       kwarg ([RDSC.4a.9.4]). */
    ds_rete_expr_t **call_args = malloc(4 * sizeof(*call_args));
    call_args[0] = lit_str("svc.notify");
    call_args[1] = lit_str("corr-1");
    call_args[2] = lit_str("n");
    call_args[3] = lit_int(1);
    ds_rete_expr_t *call_expr = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    call_expr->call.op = DS_FN_CALL;
    call_expr->call.args = call_args;
    call_expr->call.arg_count = 4;

    /* with_assert == 0 drops the ASSERT: a CALL-only rule, whose firing
       derives no fact. */
    ds_rete_action_t actions[2] = {
        { .kind = DS_RETE_ACTION_ASSERT, .schema_id = out_rs->id,
          .assigns = &assign, .assign_count = 1 },
        { .kind = DS_RETE_ACTION_CALL, .expr = call_expr },
    };
    ds_rete_action_t *act = with_assert ? &actions[0] : &actions[1];
    uint16_t          nact = with_assert ? 2 : 1;
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2, .rule_name = rule_name,
                                 .actions = act, .action_count = nact }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    ds_result_t r = ds_rete_load_network(e->rete_engine, &net);
    if (r.status != DS_OK) { ds_rete_expr_free_tree(rexpr); return 1; }
    *out_src_ds = src_ds;
    return 0;
}

/* Build "Src -> Out(val*2)" with no CALL, as a LOGICAL_ASSERT when `logical`
   (the TMS justifies Out, so retracting Src withdraws it: FactWithdraw,
   JUSTIFIER_ENDED) or a plain ASSERT otherwise (Out outlives Src, no FactWithdraw).
   The two differ in the withdrawal and in nothing else the stream carries
   before it, which is what lets cases 7b and 7c isolate the FactWithdraw compare. */
static int build_tms_net(ds_engine_t *e, int logical, const ds_schema_t **out_src_ds)
{
    const ds_schema_t *src_ds = NULL, *out_ds = NULL;
    const ds_rete_schema_t *src_rs = NULL, *out_rs = NULL;
    if (setup_schema(e, "Src", &src_ds, &src_rs)) return 1;
    if (setup_schema(e, "Out", &out_ds, &out_rs)) return 1;
    (void)out_ds;

    ds_rete_expr_t *rexpr = binop(DS_RETE_BINOP_MUL, evar(0, 0), lit_int(2));
    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = rexpr };
    ds_rete_action_t act = {
        .kind = logical ? DS_RETE_ACTION_LOGICAL_ASSERT : DS_RETE_ACTION_ASSERT,
        .schema_id = out_rs->id, .assigns = &assign, .assign_count = 1 };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2, .rule_name = "derive_rule",
                                 .actions = &act, .action_count = 1 }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    ds_result_t r = ds_rete_load_network(e->rete_engine, &net);
    if (r.status != DS_OK) { ds_rete_expr_free_tree(rexpr); return 1; }
    *out_src_ds = src_ds;
    return 0;
}

/* ---- record sink ---- */
typedef struct { uint8_t *buf; size_t len, cap; } sink_ctx;
static ds_result_t append_sink(const uint8_t *bytes, size_t n, void *user)
{
    sink_ctx *c = user;
    if (c->len + n > c->cap) return (ds_result_t){ DS_ERR_INVAL, "sink overflow" };
    memcpy(c->buf + c->len, bytes, n);
    c->len += n;
    return (ds_result_t){ DS_OK, NULL };
}

/* Record a single Src(5) assert + fire under `rule_name` into `stream`. */
static int record_firing(const char *rule_name, uint8_t *stream, size_t cap, size_t *out_len)
{
    const int with_assert = 1;
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) return 1;
    const ds_schema_t *src_ds = NULL;
    if (build_net(e, rule_name, with_assert, &src_ds)) { ds_engine_free(e); return 1; }
    ds_engine_set_call_callback(e, noop_call, NULL);

    /* RuleFireAnnotation carries clock_ns, so the recording runs on a mock
       clock, whose clock_set the replay reproduces ([LFST.9.2]). */
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock mode");

    static uint8_t recbuf[8192];
    sink_ctx ctx = { stream, 0, cap };
    ds_rfcs_recorder_t rec;
    CHECK_OK(ds_rfcs_record_to(e, &rec, append_sink, &ctx, recbuf, sizeof(recbuf)),
             "record_to");
    CHECK_OK(ds_engine_clock_set(e, 1000000000ull), "clock_set -> ClockAdvance");

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 5 };
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, src_ds, &sv, 1, &f), "assert Src(5)");
    CHECK_OK(ds_engine_pump(e), "pump");
    CHECK_OK(rec.last, "recorder had no error");

    ds_engine_set_stream_callback(e, NULL, NULL);
    *out_len = ctx.len;
    ds_engine_free(e);
    return 0;
}

/* Record two Src asserts, each with its own pump ([LFST.9.2.1]). `seq` is a
   field of the compared bodies, so the second input's atoms compare only if
   the replay spent the seqs the recording spent on the first. */
static int record_firing_two(const char *rule_name, int with_assert, uint64_t *out_seq,
                             uint8_t *stream, size_t cap, size_t *out_len)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) return 1;
    const ds_schema_t *src_ds = NULL;
    if (build_net(e, rule_name, with_assert, &src_ds)) { ds_engine_free(e); return 1; }
    ds_engine_set_call_callback(e, noop_call, NULL);
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock mode");

    static uint8_t recbuf[16384];
    sink_ctx ctx = { stream, 0, cap };
    ds_rfcs_recorder_t rec;
    CHECK_OK(ds_rfcs_record_to(e, &rec, append_sink, &ctx, recbuf, sizeof(recbuf)),
             "record_to");
    CHECK_OK(ds_engine_clock_set(e, 1000000000ull), "clock_set -> ClockAdvance");

    /* Src is keyed on `val`, so 5 and 7 are two distinct facts and each
       fires the rule once, emitting Out(10) then Out(14). */
    for (int64_t v = 5; v <= 7; v += 2) {
        ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = v };
        ds_fact_t *f = NULL;
        CHECK_OK(ds_engine_assert(e, src_ds, &sv, 1, &f), "assert Src");
        CHECK_OK(ds_engine_pump(e), "pump");
    }
    CHECK_OK(rec.last, "recorder had no error");

    ds_engine_set_stream_callback(e, NULL, NULL);
    *out_len = ctx.len;
    if (out_seq) *out_seq = e->next_seq;
    ds_engine_free(e);
    return 0;
}

/* Record one input, and report the recording engine's final next_seq: a
   count of events, whether or not a stream callback is installed, in the
   recording engine and the replaying one alike. */
static int record_firing_seq(const char *rule_name, int with_assert,
                             uint64_t *out_seq, uint8_t *stream, size_t cap,
                             size_t *out_len)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) return 1;
    const ds_schema_t *src_ds = NULL;
    if (build_net(e, rule_name, with_assert, &src_ds)) { ds_engine_free(e); return 1; }
    ds_engine_set_call_callback(e, noop_call, NULL);
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock mode");
    static uint8_t recbuf[8192];
    sink_ctx ctx = { stream, 0, cap };
    ds_rfcs_recorder_t rec;
    CHECK_OK(ds_rfcs_record_to(e, &rec, append_sink, &ctx, recbuf, sizeof(recbuf)),
             "record_to");
    CHECK_OK(ds_engine_clock_set(e, 1000000000ull), "clock_set -> ClockAdvance");
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 5 };
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, src_ds, &sv, 1, &f), "assert Src(5)");
    CHECK_OK(ds_engine_pump(e), "pump");
    CHECK_OK(rec.last, "recorder had no error");
    ds_engine_set_stream_callback(e, NULL, NULL);
    *out_len = ctx.len;
    *out_seq = e->next_seq;
    ds_engine_free(e);
    return 0;
}

/* Verify-replay `stream` and report the REPLAY engine's final next_seq. */
static ds_result_t replay_seq(const char *rule_name, int with_assert,
                              const uint8_t *stream, size_t len, uint64_t *out_seq)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK)
        return (ds_result_t){ DS_ERR_INVAL, "engine_new" };
    const ds_schema_t *src_ds = NULL;
    if (build_net(e, rule_name, with_assert, &src_ds)) {
        ds_engine_free(e); return (ds_result_t){ DS_ERR_INVAL, "build_net" };
    }
    ds_engine_set_call_callback(e, noop_call, NULL);
    static uint8_t sbuf[8192];
    ds_rfcs_replay_result_t rr;
    ds_result_t r = ds_rfcs_replay(e, stream, len, sbuf, sizeof(sbuf), &rr);
    *out_seq = e->next_seq;
    ds_engine_free(e);
    return r;
}

/* Replay `stream` into a fresh engine built under `rule_name`. */
static ds_result_t replay_into_n(const char *rule_name, int with_assert,
                                 const uint8_t *stream, size_t len,
                                 ds_rfcs_replay_result_t *rr)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK)
        return (ds_result_t){ DS_ERR_INVAL, "engine_new" };
    const ds_schema_t *src_ds = NULL;
    if (build_net(e, rule_name, with_assert, &src_ds)) { ds_engine_free(e); return (ds_result_t){ DS_ERR_INVAL, "build_net" }; }
    ds_engine_set_call_callback(e, noop_call, NULL);
    static uint8_t strbuf[8192];
    ds_result_t r = ds_rfcs_replay(e, stream, len, strbuf, sizeof(strbuf), rr);
    ds_engine_free(e);
    return r;
}

/* Cases 1-3 all use the fact-deriving rule. */
static ds_result_t replay_into(const char *rule_name, const uint8_t *stream, size_t len,
                               ds_rfcs_replay_result_t *rr)
{ return replay_into_n(rule_name, 1, stream, len, rr); }

/* Record Src(5) asserted and pumped, then retracted and pumped, on the TMS
   net. Under `logical` the second pump withdraws Out(10), so the stream
   carries a FactWithdraw. */
static int record_withdrawal(int logical, uint8_t *stream, size_t cap, size_t *out_len)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) return 1;
    const ds_schema_t *src_ds = NULL;
    if (build_tms_net(e, logical, &src_ds)) { ds_engine_free(e); return 1; }
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock mode");

    static uint8_t recbuf[8192];
    sink_ctx ctx = { stream, 0, cap };
    ds_rfcs_recorder_t rec;
    CHECK_OK(ds_rfcs_record_to(e, &rec, append_sink, &ctx, recbuf, sizeof(recbuf)),
             "record_to");
    CHECK_OK(ds_engine_clock_set(e, 1000000000ull), "clock_set -> ClockAdvance");

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 5 };
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, src_ds, &sv, 1, &f), "assert Src(5)");
    CHECK_OK(ds_engine_pump(e), "pump after assert");
    CHECK_OK(ds_engine_retract(e, f), "retract Src(5)");
    CHECK_OK(ds_engine_pump(e), "pump after retract");
    CHECK_OK(rec.last, "recorder had no error");

    ds_engine_set_stream_callback(e, NULL, NULL);
    *out_len = ctx.len;
    ds_engine_free(e);
    return 0;
}

static ds_result_t replay_withdrawal(int logical, const uint8_t *stream, size_t len,
                                     ds_rfcs_replay_result_t *rr)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK)
        return (ds_result_t){ DS_ERR_INVAL, "engine_new" };
    const ds_schema_t *src_ds = NULL;
    if (build_tms_net(e, logical, &src_ds)) {
        ds_engine_free(e); return (ds_result_t){ DS_ERR_INVAL, "build_tms_net" };
    }
    static uint8_t strbuf[8192];
    ds_result_t r = ds_rfcs_replay(e, stream, len, strbuf, sizeof(strbuf), rr);
    ds_engine_free(e);
    return r;
}

/* Does the stream carry an atom of this field number (DS_ATOM_*)? */
static int stream_has(const uint8_t *stream, size_t len, uint32_t atom)
{
    ds_rfcs_reader_t rd;
    uint32_t         got = 0;
    const uint8_t   *body = NULL;
    size_t           blen = 0;
    bool             done = false;

    ds_rfcs_reader_init(&rd, stream, len);
    while (ds_rfcs_next(&rd, &got, &body, &blen, &done).status == DS_OK && !done)
        if (got == atom)
            return 1;
    return 0;
}

/* Flip the first body byte of the first `atom` atom in the stream. The
   reader's body pointer points into `stream`. */
static int flip_first_atom_byte(uint8_t *stream, size_t len, uint32_t atom)
{
    ds_rfcs_reader_t rd;
    uint32_t         got = 0;
    const uint8_t   *body = NULL;
    size_t           blen = 0;
    bool             done = false;

    ds_rfcs_reader_init(&rd, stream, len);
    while (ds_rfcs_next(&rd, &got, &body, &blen, &done).status == DS_OK && !done) {
        if (got == atom && blen > 0) {
            stream[body - stream] ^= 0xFF;   /* corrupt the first body byte */
            return 1;
        }
    }
    return 0;
}

/* ---- timetag rewriting (case 8, [LFST.9.3.6]) ---- */

/* What a recorded timetag becomes: `tt` as found in an atom of field number
   `atom`. */
typedef int64_t (*tt_map_fn)(int64_t tt, uint32_t atom, void *u);

/* Rewrite every timetag in the stream's RuleFireAnnotation (field 6) and
   CallIssued (field 8) atoms through `map`, in place. Each is a one-byte
   varint here (a small counter), and the map must keep it one byte, so no
   frame length moves. The number the map changed, or -1 when a timetag is
   not, or would not stay, one byte. */
static int rewrite_timetags(uint8_t *stream, size_t len, tt_map_fn map, void *u)
{
    ds_rfcs_reader_t rd;
    uint32_t         got = 0;
    const uint8_t   *body = NULL;
    size_t           blen = 0;
    bool             done = false;
    int              n = 0;

    ds_rfcs_reader_init(&rd, stream, len);
    while (ds_rfcs_next(&rd, &got, &body, &blen, &done).status == DS_OK && !done) {
        uint32_t tf = got == DS_ATOM_RULE_FIRE_ANNOTATION ? 6
                    : got == DS_ATOM_CALL_ISSUED          ? 8 : 0;
        if (tf == 0)
            continue;
        size_t pos = 0;
        while (pos < blen) {
            ds_pbf_field_t f;
            if (ds_pbf_next_field(body, blen, pos, &f) != DS_PBF_OK)
                return -1;
            if (f.field == tf && f.wire == 0) {
                int64_t to = map((int64_t)f.u64, got, u);
                if (f.next - pos != 2 || f.u64 >= 128 || to <= 0 || to >= 128)
                    return -1;
                stream[(size_t)(body - stream) + pos + 1] = (uint8_t)to;
                n += to != (int64_t)f.u64;
            }
            pos = f.next;
        }
    }
    return n;
}

/* The distinct RuleFireAnnotation timetags, in the order they first occur:
   one per firing. A map that changes nothing. */
typedef struct { int64_t tt[8]; int n; } tt_seen;
static int64_t tt_collect(int64_t tt, uint32_t atom, void *u)
{
    tt_seen *s = u;
    if (atom == DS_ATOM_RULE_FIRE_ANNOTATION) {
        int known = 0;
        for (int i = 0; i < s->n; i++)
            known |= s->tt[i] == tt;
        if (!known && s->n < 8)
            s->tt[s->n++] = tt;
    }
    return tt;
}

static int64_t tt_offset(int64_t tt, uint32_t atom, void *u)
{ (void)atom; (void)u; return tt + 50; }

/* The second firing's timetag becomes the first's, everywhere it occurs. */
static int64_t tt_merge(int64_t tt, uint32_t atom, void *u)
{
    const tt_seen *s = u;
    (void)atom;
    return tt == s->tt[1] ? s->tt[0] : tt;
}

/* The second firing's CallIssued alone takes a timetag no firing has. */
static int64_t tt_split_call(int64_t tt, uint32_t atom, void *u)
{
    const tt_seen *s = u;
    return (atom == DS_ATOM_CALL_ISSUED && tt == s->tt[1]) ? 120 : tt;
}

int main(void)
{
    static uint8_t stream[8192];
    size_t slen = 0;

    /* Case 1 — a clean round trip verifies. */
    if (record_firing("double_rule", stream, sizeof(stream), &slen)) {
        fprintf(stderr, "FAIL: record_firing\n"); return 1;
    }
    {
        ds_rfcs_replay_result_t rr;
        CHECK_OK(replay_into("double_rule", stream, slen, &rr),
                 "clean verify round-trip");
        CHECK(rr.rule_fires >= 2, "begin+end RuleFireAnnotation were re-derived and matched");
        CHECK(rr.calls >= 1, "the re-derived CallIssued was matched too");
    }

    /* Case 2a — a flipped RuleFireAnnotation byte is caught. */
    {
        static uint8_t bad[8192];
        memcpy(bad, stream, slen);
        CHECK(flip_first_atom_byte(bad, slen, DS_ATOM_RULE_FIRE_ANNOTATION), "stream has a RuleFireAnnotation to flip");
        ds_rfcs_replay_result_t rr;
        ds_result_t r = replay_into("double_rule", bad, slen, &rr);
        CHECK(r.status == DS_ERR_FS_DIVERGENCE, "flipped RuleFireAnnotation -> DS_ERR_FS_DIVERGENCE");
    }

    /* Case 2b — a flipped CallIssued byte is caught. */
    {
        static uint8_t bad[8192];
        memcpy(bad, stream, slen);
        CHECK(flip_first_atom_byte(bad, slen, DS_ATOM_CALL_ISSUED), "stream has a CallIssued to flip");
        ds_rfcs_replay_result_t rr;
        ds_result_t r = replay_into("double_rule", bad, slen, &rr);
        CHECK(r.status == DS_ERR_FS_DIVERGENCE, "flipped CallIssued -> DS_ERR_FS_DIVERGENCE");
    }

    /* Case 3 — the "double_rule" recording replayed into an engine whose rule
       is "double_rule_v2", with the same action: the re-derived
       RuleFireAnnotation's rule_name differs, and the compare catches it. */
    {
        ds_rfcs_replay_result_t rr;
        ds_result_t r = replay_into("double_rule_v2", stream, slen, &rr);
        CHECK(r.status == DS_ERR_FS_DIVERGENCE,
              "fire divergence (rule_name) caught by the compare");
    }

    /* Case 4 — the clean round trip over two inputs: the second input's
       compare atoms carry seqs that depend on every event before them. */
    {
        static uint8_t s2[16384];
        size_t s2len = 0;
        if (record_firing_two("double_rule", 1, NULL, s2, sizeof(s2), &s2len)) {
            fprintf(stderr, "FAIL: record_firing_two\n"); return 1;
        }
        ds_rfcs_replay_result_t rr;
        ds_result_t r = replay_into_n("double_rule", 1, s2, s2len, &rr);
        CHECK_OK(r, "clean verify round-trip over two inputs");
        if (r.status == DS_OK) {
            CHECK(rr.rule_fires >= 4, "two fires => four RuleFireAnnotation matched");
            CHECK(rr.calls >= 2, "two re-derived CALLs matched");
        }
    }

    /* Case 5 — case 4's control: the same, except the rule derives no
       fact. */
    {
        static uint8_t s3[16384];
        size_t s3len = 0;
        if (record_firing_two("call_only_rule", 0, NULL, s3, sizeof(s3), &s3len)) {
            fprintf(stderr, "FAIL: record_firing_two (call-only)\n"); return 1;
        }
        ds_rfcs_replay_result_t rr;
        ds_result_t r = replay_into_n("call_only_rule", 0, s3, s3len, &rr);
        CHECK_OK(r, "control: two inputs, no derived fact, verifies");
        if (r.status == DS_OK) {
            CHECK(rr.rule_fires >= 4, "control: two fires => four RuleFireAnnotation matched");
            CHECK(rr.calls >= 2, "control: two re-derived CALLs matched");
            CHECK(rr.asserts == 2, "control: only the two Src inputs are FactAsserts");
        }
    }

    /* Case 6 — a single-input round trip, with and without a derived fact:
       the replay spends exactly as many events as the recording. */
    {
        static uint8_t s4[8192];
        size_t s4len = 0;
        uint64_t rec_seq = 0, rep_seq = 0;

        if (record_firing_seq("double_rule", 1, &rec_seq, s4, sizeof(s4), &s4len)) {
            fprintf(stderr, "FAIL: record_firing_seq (derived)\n"); return 1;
        }
        ds_result_t r = replay_seq("double_rule", 1, s4, s4len, &rep_seq);
        CHECK_OK(r, "seq probe: single-input derived round-trip still verifies");
        fprintf(stderr, "seq derived : record=%llu replay=%llu drift=%lld\n",
                (unsigned long long)rec_seq, (unsigned long long)rep_seq,
                (long long)rep_seq - (long long)rec_seq);

        static uint8_t s5[8192];
        size_t s5len = 0;
        uint64_t crec = 0, crep = 0;
        if (record_firing_seq("call_only_rule", 0, &crec, s5, sizeof(s5), &s5len)) {
            fprintf(stderr, "FAIL: record_firing_seq (control)\n"); return 1;
        }
        ds_result_t r2 = replay_seq("call_only_rule", 0, s5, s5len, &crep);
        CHECK_OK(r2, "seq probe: single-input control round-trip verifies");
        fprintf(stderr, "seq control : record=%llu replay=%llu drift=%lld\n",
                (unsigned long long)crec, (unsigned long long)crep,
                (long long)crep - (long long)crec);

        CHECK(crep == crec, "control: replay spends exactly the recorded events");
        CHECK(rep_seq == rec_seq,
              "derived: replay spends exactly the recorded events");
    }

    /* Case 7 — FactWithdraw is a compare atom ([RFCS.7a.3]). */
    {
        static uint8_t wl[8192], wp[8192];
        size_t wllen = 0, wplen = 0;
        if (record_withdrawal(1, wl, sizeof(wl), &wllen) ||
            record_withdrawal(0, wp, sizeof(wp), &wplen)) {
            fprintf(stderr, "FAIL: record_withdrawal\n"); return 1;
        }
        CHECK(stream_has(wl, wllen, DS_ATOM_FACT_WITHDRAW),
              "the logical recording withdraws Out: it carries a FactWithdraw");
        CHECK(!stream_has(wp, wplen, DS_ATOM_FACT_WITHDRAW),
              "the plain recording keeps Out: it carries no FactWithdraw");

        /* 7a — the withdrawal is re-derived, matched and counted. */
        ds_rfcs_replay_result_t rr;
        ds_result_t r = replay_withdrawal(1, wl, wllen, &rr);
        CHECK_OK(r, "a re-derived withdrawal verifies");
        if (r.status == DS_OK)
            CHECK(rr.withdrawals == 1, "the FactWithdraw was matched, not skipped");

        /* 7b — a recorded withdrawal the replay does not re-derive. The
           replay's rule asserts Out without a justification, so retracting
           Src leaves it standing. */
        r = replay_withdrawal(0, wl, wllen, &rr);
        CHECK(r.status == DS_ERR_FS_DIVERGENCE,
              "an un-re-derived withdrawal -> DS_ERR_FS_DIVERGENCE");
        /* ...at the withdrawal: everything before it matches. */
        CHECK(r.detail && strstr(r.detail, "no re-derived counterpart"),
              "7b diverges at the recorded FactWithdraw, not before it");

        /* 7c — the other direction: the replay withdraws a fact the
           recording kept, leaving a re-derived FactWithdraw with no recorded one. */
        r = replay_withdrawal(1, wp, wplen, &rr);
        CHECK(r.status == DS_ERR_FS_DIVERGENCE,
              "a withdrawal the recording lacks -> DS_ERR_FS_DIVERGENCE");
        CHECK(r.detail && strstr(r.detail, "more compare atoms"),
              "7c diverges on the surplus FactWithdraw, not before it");

        /* 7d — a flipped FactWithdraw byte is caught. */
        static uint8_t bad[8192];
        memcpy(bad, wl, wllen);
        CHECK(flip_first_atom_byte(bad, wllen, DS_ATOM_FACT_WITHDRAW), "stream has a FactWithdraw to flip");
        r = replay_withdrawal(1, bad, wllen, &rr);
        CHECK(r.status == DS_ERR_FS_DIVERGENCE, "flipped FactWithdraw -> DS_ERR_FS_DIVERGENCE");
    }

    /* Case 8 — `timetag` is compared by pairing, not by value ([RFCS.11.2],
       [LFST.9.3.6]). Two firings, each a RuleFireAnnotation pair and a
       CallIssued, recorded by this engine and then rewritten as another
       conforming engine's recording might carry them. */
    {
        static uint8_t s8[16384];
        size_t s8len = 0;
        if (record_firing_two("double_rule", 1, NULL, s8, sizeof(s8), &s8len)) {
            fprintf(stderr, "FAIL: record_firing_two (timetag)\n"); return 1;
        }
        tt_seen seen = { .n = 0 };
        CHECK(rewrite_timetags(s8, s8len, tt_collect, &seen) == 0,
              "the recording's timetags are one-byte varints to rewrite");
        CHECK(seen.n == 2, "two firings, two distinct timetags");

        /* 8a — every timetag renamed by a constant replays clean: the
           pairing holds throughout. */
        static uint8_t ren[16384];
        memcpy(ren, s8, s8len);
        CHECK(rewrite_timetags(ren, s8len, tt_offset, NULL) >= 6,
              "8a: every RuleFireAnnotation and CallIssued timetag rewritten");
        ds_rfcs_replay_result_t rr;
        ds_result_t r = replay_into_n("double_rule", 1, ren, s8len, &rr);
        CHECK_OK(r, "8a: renamed timetags replay clean ([LFST.9.3.6])");
        if (r.status == DS_OK) {
            CHECK(rr.rule_fires >= 4, "8a: four RuleFireAnnotation matched");
            CHECK(rr.calls >= 2, "8a: two CallIssued matched");
        }

        if (seen.n == 2) {
            /* 8b — the second firing given the first's timetag: two firings
               the engine keeps apart share one recorded timetag, so the
               re-derived second breaks the pairing the first made. */
            static uint8_t mrg[16384];
            memcpy(mrg, s8, s8len);
            CHECK(rewrite_timetags(mrg, s8len, tt_merge, &seen) > 0,
                  "8b: the second firing's timetags rewritten");
            r = replay_into_n("double_rule", 1, mrg, s8len, &rr);
            CHECK(r.status == DS_ERR_FS_DIVERGENCE,
                  "8b: two firings sharing one timetag -> DS_ERR_FS_DIVERGENCE");
            CHECK(r.detail && strstr(r.detail, "pairing"),
                  "8b diverges on the pairing, not on another byte");

            /* 8c — the second firing's CallIssued alone takes a fresh
               timetag. Its RuleFireAnnotation paired the re-derived one with
               another recorded value, so this one breaks the pairing in the
               other direction: re-derived to recorded. */
            static uint8_t spl[16384];
            memcpy(spl, s8, s8len);
            CHECK(rewrite_timetags(spl, s8len, tt_split_call, &seen) == 1,
                  "8c: exactly the second CallIssued's timetag rewritten");
            r = replay_into_n("double_rule", 1, spl, s8len, &rr);
            CHECK(r.status == DS_ERR_FS_DIVERGENCE,
                  "8c: a CallIssued leaving its firing's pairing -> DS_ERR_FS_DIVERGENCE");
            CHECK(r.detail && strstr(r.detail, "pairing"),
                  "8c diverges on the pairing, not on another byte");
        }
    }

    if (failures) { fprintf(stderr, "test_rfcs_verify: %d failure(s)\n", failures); return 1; }
    printf("test_rfcs_verify: OK\n");
    return 0;
}

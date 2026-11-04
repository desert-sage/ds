/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A recording is a function of its input and the ids the integrator gave
 * ([LFST.5.6], [RFCS.4.3], [RFCS.4.4], [NLFC.1.2]).
 *
 *   1. Two FRESH mock-clock engines (not clones) given the same run_id and
 *      tier_id, driven by the same input, record byte-identical streams.
 *   2. The same with no ids: byte-identical, and every recorded event_id is
 *      distinct, distinguished by seq alone.
 *   3. The header records what was given: session_id "r1", tier_id "t1", in
 *      the session header and in the recording's StreamHeader.
 *   4. An empty string is the same as NULL: getters answer NULL, the header
 *      answers "", and the recording is byte-identical to case 2's.
 *   5. Nothing is adopted from the trace: a verify replay given the recorded
 *      ids reproduces every FactEmit, and one given no ids diverges on the
 *      FactEmit's event_id ([RFCS.4.3]: a replay is GIVEN the ids).
 *   6. Ids and a schema name longer than 64 bytes: the header decodes the
 *      ids whole, and a replay given them verifies.
 *
 * The program fires a rule, so the stream carries a compare-class FactEmit
 * whose event_id a verify replay re-derives, beside the integrator's
 * FactAssert.
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
#include "rfcs/rfcs.h"

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

/* ---- the program: Src(val) -> Out(val * 2), both logical, keyed on val --- */

/* The source schema's name. Case 6 gives it one longer than 64 bytes. */
static const char *src_schema = "Src";

static int setup_schema(ds_engine_t *e, const char *name,
                        const ds_schema_t **out_ds,
                        const ds_rete_schema_t **out_rs)
{
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    if (ds_engine_register_schema(e, name, DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  &sd, 1, out_ds).status != DS_OK)
        return 1;
    *out_rs = ds_rete_schema_by_name(e->rete_engine, name);
    return *out_rs == NULL;
}

static int build_net(ds_engine_t *e, const ds_schema_t **out_src)
{
    const ds_schema_t *src_ds = NULL, *out_ds = NULL;
    const ds_rete_schema_t *src_rs = NULL, *out_rs = NULL;
    if (setup_schema(e, src_schema, &src_ds, &src_rs)) return 1;
    if (setup_schema(e, "Out", &out_ds, &out_rs)) return 1;
    (void)out_ds;

    ds_rete_expr_t *l = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    l->var.pattern_index = 0;
    l->var.slot_index = 0;
    ds_rete_expr_t *r = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    r->lit_int = 2;
    ds_rete_expr_t *mul = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    mul->binop.op = DS_RETE_BINOP_MUL;
    mul->binop.left = l;
    mul->binop.right = r;
    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = mul };
    ds_rete_action_t act = { .kind = DS_RETE_ACTION_ASSERT,
                             .schema_id = out_rs->id,
                             .assigns = &assign, .assign_count = 1 };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = src_schema }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1,
                                 .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "double",
                                 .actions = &act, .action_count = 1 }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    if (ds_rete_load_network(e->rete_engine, &net).status != DS_OK) {
        ds_rete_expr_free_tree(mul);
        return 1;
    }
    *out_src = src_ds;
    return 0;
}

/* A FRESH engine with the given ids and the program loaded. */
static ds_engine_t *fresh(const char *run_id, const char *tier_id,
                          const ds_schema_t **out_src)
{
    ds_engine_config_t cfg = { .run_id = run_id, .tier_id = tier_id };
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) return NULL;
    if (build_net(e, out_src)) { ds_engine_free(e); return NULL; }
    return e;
}

/* ---- recording ----------------------------------------------------------- */

typedef struct { uint8_t bytes[16384]; size_t len; } capture_t;

static ds_result_t capture_sink(const uint8_t *bytes, size_t n, void *user)
{
    capture_t *c = user;
    if (c->len + n > sizeof(c->bytes))
        return (ds_result_t){ DS_ERR_INVAL, "capture overflow" };
    memcpy(c->bytes + c->len, bytes, n);
    c->len += n;
    return (ds_result_t){ DS_OK, NULL };
}

/* Record, on a fresh engine with the given ids: a clock set, two Src asserts
   each with its own pump ([LFST.9.2.1]), so two FactAsserts and two
   FactEmits. */
static int record(const char *run_id, const char *tier_id, capture_t *out)
{
    const ds_schema_t *src = NULL;
    ds_engine_t *e = fresh(run_id, tier_id, &src);
    if (e == NULL) { failures++; fprintf(stderr, "FAIL: engine\n"); return 1; }
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    static uint8_t recbuf[16384];
    ds_rfcs_recorder_t rec;
    out->len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, capture_sink, out, recbuf,
                               sizeof(recbuf)), "record_to");
    CHECK_OK(ds_engine_clock_set(e, 1000000000ull), "clock_set");
    for (int64_t v = 5; v <= 7; v += 2) {
        ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = v };
        ds_fact_t *f = NULL;
        CHECK_OK(ds_engine_assert(e, src, &sv, 1, &f), "assert Src");
        CHECK_OK(ds_engine_pump(e), "pump");
    }
    CHECK_OK(rec.last, "the recorder had no error");
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
    return 0;
}

static bool same(const capture_t *a, const capture_t *b)
{
    return a->len == b->len && memcmp(a->bytes, b->bytes, a->len) == 0;
}

/* Every FactAssert and FactEmit event_id in `c`, and the StreamHeader header,
   as views into the capture. */
typedef struct {
    ds_rfcs_str_t ids[16];
    uint64_t seqs[16];
    int n;
    ds_rfcs_header_t hdr;
    bool have_hdr;
} scan_t;

static void scan(const capture_t *c, scan_t *s)
{
    memset(s, 0, sizeof(*s));
    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, c->bytes, c->len);
    for (;;) {
        uint32_t atom = 0;
        const uint8_t *body = NULL;
        size_t blen = 0;
        bool done = false;
        if (ds_rfcs_next(&rd, &atom, &body, &blen, &done).status != DS_OK) {
            failures++;
            fprintf(stderr, "FAIL: the recording does not frame\n");
            return;
        }
        if (done) return;
        if (atom == DS_ATOM_STREAM_HEADER) {
            CHECK_OK(ds_rfcs_decode_header(body, blen, &s->hdr), "StreamHeader");
            s->have_hdr = true;
            continue;
        }
        ds_rfcs_fcem_t a;
        bool fcem = atom == DS_ATOM_FACT_ASSERT;
        bool femt = atom == DS_ATOM_FACT_EMIT;
        if (!fcem && !femt) continue;
        ds_result_t r = fcem ? ds_rfcs_decode_fcem(body, blen, &a)
                             : ds_rfcs_decode_femt(body, blen, &a);
        CHECK_OK(r, fcem ? "FactAssert" : "FactEmit");
        if (r.status == DS_OK && s->n < 16) {
            s->ids[s->n] = a.event_id;
            s->seqs[s->n] = a.seq;
            s->n++;
        }
    }
}

/* ---- 1, 3 ---------------------------------------------------------------- */

/* @spec [LFST.4.4] [LFST.5.6] [RARC.5.8.8] [RFCS.4.3] [RFCS.4.4] */
static void test_same_ids_record_byte_identically(void)
{
    static capture_t a, b;
    if (record("r1", "t1", &a) || record("r1", "t1", &b)) return;
    CHECK(a.len > 0, "something was recorded");
    CHECK(same(&a, &b),
          "1: two fresh runs given the same ids record byte-identically");

    scan_t s;
    scan(&a, &s);
    CHECK(s.have_hdr && ds_rfcs_str_eq(s.hdr.session_id, "r1"),
          "3: the StreamHeader's session_id is the run id given");
    CHECK(s.have_hdr && ds_rfcs_str_eq(s.hdr.tier_id, "t1"),
          "3: the StreamHeader's tier_id is the tier id given");
    CHECK(s.n == 4, "two FactAsserts and two FactEmits");
    for (int i = 0; i < s.n; i++) {
        char want[DS_RFCS_EVENT_ID_LEN];
        ds_rfcs_gen_event_id("r1", "t1", s.seqs[i], want);
        CHECK(ds_rfcs_str_eq(s.ids[i], want),
              "every event_id derives from (run_id, tier_id, seq)");
    }

    const ds_schema_t *src = NULL;
    ds_engine_t *e = fresh("r1", "t1", &src);
    if (e == NULL) { failures++; return; }
    ds_session_header_t h;
    CHECK(ds_engine_get_session_header(e, &h).status == DS_OK
              && strcmp(h.session_id, "r1") == 0
              && strcmp(h.tier_id, "t1") == 0,
          "3: the session header reports the ids given");
    ds_engine_free(e);
}

/* ---- 2, 4 ---------------------------------------------------------------- */

/* @spec [LFST.5.6] [NLFC.1.2] */
static void test_no_ids_and_empty_ids_record_alike(void)
{
    static capture_t a, b, empty;
    if (record(NULL, NULL, &a) || record(NULL, NULL, &b)
            || record("", "", &empty))
        return;
    CHECK(same(&a, &b),
          "2: two fresh runs given no ids record byte-identically");

    scan_t s;
    scan(&a, &s);
    CHECK(s.have_hdr && s.hdr.session_id.len == 0
              && s.hdr.tier_id.len == 0,
          "2: with no ids the StreamHeader carries empty session_id and tier_id");
    CHECK(s.n == 4, "two FactAsserts and two FactEmits");
    for (int i = 0; i < s.n; i++) {
        CHECK(s.ids[i].len != 0, "every FactAssert carries an event_id");
        for (int j = 0; j < i; j++)
            CHECK(s.ids[i].len != s.ids[j].len
                      || memcmp(s.ids[i].ptr, s.ids[j].ptr, s.ids[i].len) != 0,
                  "2: every event_id is distinct, by seq alone");
    }

    CHECK(same(&a, &empty),
          "4: ids given as \"\" record exactly as no ids");
    const ds_schema_t *src = NULL;
    ds_engine_t *e = fresh("", "", &src);
    if (e == NULL) { failures++; return; }
    const char *got = (const char *)1;
    CHECK(ds_engine_get_run_id(e, &got).status == DS_OK && got == NULL,
          "4: a run id given as \"\" reads NULL");
    got = (const char *)1;
    CHECK(ds_engine_get_tier_id(e, &got).status == DS_OK && got == NULL,
          "4: a tier id given as \"\" reads NULL");
    ds_session_header_t h;
    CHECK(ds_engine_get_session_header(e, &h).status == DS_OK
              && h.session_id[0] == '\0' && h.tier_id[0] == '\0',
          "4: and the session header reports \"\" for both");
    ds_engine_free(e);
}

/* ---- 5 ------------------------------------------------------------------- */

static ds_result_t verify_with(const char *run_id, const char *tier_id,
                               const capture_t *c,
                               ds_rfcs_replay_result_t *rr)
{
    const ds_schema_t *src = NULL;
    ds_engine_t *e = fresh(run_id, tier_id, &src);
    if (e == NULL) return (ds_result_t){ DS_ERR_INVAL, "engine" };
    static uint8_t strbuf[8192];
    ds_result_t r = ds_rfcs_replay(e, c->bytes, c->len, strbuf,
                                   sizeof(strbuf), rr);
    ds_engine_free(e);
    return r;
}

/* @spec [RFCS.4.3] */
static void test_a_replay_is_given_the_ids(void)
{
    static capture_t rec;
    if (record("r1", "t1", &rec)) return;
    ds_rfcs_replay_result_t rr;
    memset(&rr, 0, sizeof(rr));
    CHECK_OK(verify_with("r1", "t1", &rec, &rr),
             "5: a replay given the recorded ids verifies");

    memset(&rr, 0, sizeof(rr));
    ds_result_t r = verify_with(NULL, NULL, &rec, &rr);
    CHECK(r.status == DS_ERR_FS_DIVERGENCE,
          "5: a replay given no ids diverges: nothing is adopted from the "
          "trace");
}

/* ---- 6 ------------------------------------------------------------------- */

/* A view's bytes as a C string in `buf`; false if it does not fit. */
static bool view_to_cstr(ds_rfcs_str_t v, char *buf, size_t cap)
{
    if (v.len >= cap) return false;
    memcpy(buf, v.ptr, v.len);
    buf[v.len] = '\0';
    return true;
}

/* 6: ids and a schema name longer than 64 bytes. The header decodes the ids
   whole, so a replay given them verifies ([RFCS.4.3]), and the replay finds
   the schema its FactAsserts name ([RFCS.5.4]), as the Mercury runtime
   does. */
/* @spec [RFCS.4.3] [RFCS.4.4] [RFCS.5.4] */
static void test_long_ids_and_schema_name_replay(void)
{
    static char run[101], tier[101], name[71];
    for (size_t i = 0; i < 100; i++) {
        run[i]  = (char)('a' + (int)(i % 26u));
        tier[i] = (char)('A' + (int)(i % 26u));
    }
    run[100] = tier[100] = '\0';
    name[0] = 'S';
    for (size_t i = 1; i < 70; i++)
        name[i] = (char)('a' + (int)(i % 26u));
    name[70] = '\0';

    src_schema = name;
    static capture_t rec;
    if (record(run, tier, &rec)) { src_schema = "Src"; return; }

    scan_t s;
    scan(&rec, &s);
    CHECK(s.have_hdr && ds_rfcs_str_eq(s.hdr.session_id, run),
          "6: a 100-byte run id decodes from the header whole");
    CHECK(s.have_hdr && ds_rfcs_str_eq(s.hdr.tier_id, tier),
          "6: a 100-byte tier id decodes from the header whole");

    char run2[128], tier2[128];
    CHECK(view_to_cstr(s.hdr.session_id, run2, sizeof run2)
              && view_to_cstr(s.hdr.tier_id, tier2, sizeof tier2),
          "6: the decoded ids are the ids' length");
    ds_rfcs_replay_result_t rr;
    memset(&rr, 0, sizeof(rr));
    CHECK_OK(verify_with(run2, tier2, &rec, &rr),
             "6: a replay given the decoded ids verifies, and finds the "
             "70-byte schema its FactAsserts name");
    CHECK(rr.asserts > 0, "6: and it replayed the asserts");
    src_schema = "Src";
}

int main(void)
{
    printf("=== test_rfcs_replay_determinism ===\n");
    test_same_ids_record_byte_identically();
    test_no_ids_and_empty_ids_record_alike();
    test_a_replay_is_given_the_ids();
    test_long_ids_and_schema_name_replay();
    if (failures) {
        fprintf(stderr, "test_rfcs_replay_determinism: %d FAILURE(S)\n",
                failures);
        return 1;
    }
    printf("=== test_rfcs_replay_determinism: ALL PASSED ===\n");
    return 0;
}

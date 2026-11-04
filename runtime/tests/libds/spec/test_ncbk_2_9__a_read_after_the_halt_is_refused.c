/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NCBK.2.9]
 * After an EngineError a read of working memory, a schema or the
 * introspection surface is refused with DS_ERR_ENGINE_HALTED, decided by the
 * latch; four calls stay valid: ds_engine_halted,
 * ds_engine_get_platform_signature, ds_engine_get_session_header and
 * ds_engine_free.
 *
 * THE HALT comes from spec_tamper.h's negative fixture: a program doing
 * arithmetic on `lied`, its compiled artefact edited so that slot declares
 * String, so the one pump that fires the rule raises
 * ENGINE_FAULT_ARTEFACT_LIED.
 *
 * THE PATH: each public read's entry -> its NULL checks -> the latch check
 * (engine.h's DS_ENGINE_REFUSE_IF_HALTED), before any engine state is read
 * ([STYL.5.10.8]).
 *
 *   unedited. The same program, compiled and not edited, after the same
 *      assert and pump: every read below answers DS_OK. So each refusal
 *      below is the halt's.
 *   (a) ds_engine_fact_find, by the id the assert's fact had
 *       ([NFCT.6.4]: "a fact lookup by id is such a read"), returns
 *       DS_ERR_ENGINE_HALTED.
 *   (b) ds_engine_fact_count and ds_engine_for_each_fact, a working-memory
 *       read and an enumeration, return DS_ERR_ENGINE_HALTED, and the
 *       visitor is never called.
 *   (c) ds_engine_schema_find, a schema read, returns DS_ERR_ENGINE_HALTED.
 *   (d) ds_engine_rete_network, the introspection surface, returns
 *       DS_ERR_ENGINE_HALTED, and no node callback runs.
 *   (e) ds_engine_halted reports ARTEFACT_LIED; the platform signature and
 *       the session header answer DS_OK, the header with the load-time
 *       dsc_hash ([NDET.2.1]); ds_engine_free completes, and the memcheck
 *       lane runs this binary.
 *   (f) A read through a handle taken before the halt, once the halting call
 *       has returned: ds_fact_get_id on the asserted fact and
 *       ds_schema_get_name on P's schema each return DS_ERR_ENGINE_HALTED,
 *       and DS_OK unedited.
 *
 * THE WINDOW ([NCBK.2.9]'s handle paragraph): the call that raises the
 * EngineError answers a handle read until it has delivered the EngineError.
 * The case is an upsert whose own retract halts: Q's token is blocked by P
 * (`no P`), the upsert retracts the old P, the released token joins R, and R's
 * `where` reads `lied`, which the negative fixture declares String. The
 * `where` names `q` too, so it is a join test that runs only when Q's token
 * meets R, never on R's own arrival. The EngineError is held behind the
 * upsert's records ([RFCS.6.7]), so they reach the stream callback with the
 * latch set and the EngineError not yet delivered.
 *   (g) In the stream callback, the upsert's FactAssert and the old P's
 *       FactRetract each answer ds_fact_get_id with DS_OK, ahead of the
 *       EngineError.
 *   (h) In the EngineError's own callback, a read through Q's fact handle is
 *       refused: delivering the EngineError closes the window.
 *   (i) After the call returns, Q's fact handle and P's schema handle are
 *       refused. The FactAssert's handle is not read again: it is a view the
 *       engine frees once its callback returns ([NFCT.5.1]), so Q's live fact
 *       stands for it.
 *   unedited, the same steps: the upsert is DS_OK, and every read answers.
 */
#include "spec_common.h"
#include "spec_tamper.h"

#include <stdbool.h>

static const char *PROGRAM =
    "schema P scope logical:\n"
    "    id: Int key\n"
    "    lied: Int mutable\n"
    "\n"
    "schema Out scope logical:\n"
    "    id: Int key\n"
    "    v: Int mutable\n"
    "\n"
    "rule halt_at_fire:\n"
    "    P p\n"
    "->\n"
    "    emit Out logical id: p.id v: p.lied + 1\n";

/* A loaded engine, from the negative fixture when `lying`, with P(1)
   asserted and one pump run. *out_id is the asserted fact's id, *out_fact
   its handle and *out_p P's schema handle, all taken before the pump;
   *pump_status the pump's status. */
static int run_one_pump(bool lying, ds_engine_t **out, uint64_t *out_id,
                        const ds_fact_t **out_fact, const ds_schema_t **out_p,
                        int *pump_status)
{
    *out = NULL;
    uint8_t *dsc = NULL;
    size_t   len = 0;
    ds_result_t r = spec_compile_ds(PROGRAM, &dsc, &len);
    if (r.status != DS_OK) return spec_fail("compile", r);
    if (lying && lie(dsc, len)) { free(dsc); return 1; }
    ds_engine_t *e = NULL;
    r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) { free(dsc); return spec_fail("engine_new", r); }
    r = ds_engine_load_dsc(e, dsc, len);
    free(dsc);
    if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("load_dsc", r); }
    const ds_schema_t *p = NULL;
    r = ds_engine_schema_find(e, "P", &p);
    if (r.status != DS_OK || p == NULL) {
        ds_engine_free(e);
        return spec_fail("find P", r);
    }
    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 1;
    if (lying) {
        v[1].kind = DS_SLOT_STRING;
        v[1].v.s  = "x";
    } else {
        v[1].kind = DS_SLOT_INT;
        v[1].v.i  = 1;
    }
    ds_fact_t *fact = NULL;
    r = ds_engine_assert(e, p, v, 2, &fact);
    if (r.status != DS_OK || fact == NULL) {
        ds_engine_free(e);
        return spec_fail("premise: the assert is admitted; the edited slot is "
                         "read at fire time", r);
    }
    r = ds_fact_get_id(fact, out_id);
    if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("fact id", r); }
    *out_fact = fact;
    *out_p = p;
    *pump_status = ds_engine_pump(e).status;
    *out = e;
    return 0;
}

static ds_result_t count_visit(const ds_fact_t *fact, void *user)
{
    (void) fact;
    (*(int *) user)++;
    return DS_OK_R;
}

static void count_node(const char *id, const char *kind, const char *label,
                       const char *filter, uint32_t occupancy, bool is_negative,
                       void *user)
{
    (void) id; (void) kind; (void) label; (void) filter; (void) occupancy;
    (void) is_negative;
    (*(int *) user)++;
}

/* The walk calls its edge callback unconditionally, so one is given. */
static void count_edge(const char *from, const char *to, void *user)
{
    (void) from; (void) to;
    (*(int *) user)++;
}

/* `got` against `want`, named `what`. */
static int expect_status(const char *what, ds_result_t got, int want)
{
    if (got.status == want) return 0;
    fprintf(stderr, "FAIL: %s: want %d, got %d (%s)\n", what, want, got.status,
            got.detail ? got.detail : "(null)");
    return 1;
}

/* Every read (a) to (d), each expecting `want`. */
static int reads(ds_engine_t *e, uint64_t id, int want, const char *when)
{
    int rc = 0;
    char what[160];

    ds_fact_t *found = NULL;
    snprintf(what, sizeof what, "%s: (a) ds_engine_fact_find", when);
    rc |= expect_status(what, ds_engine_fact_find(e, id, &found), want);

    size_t count = 0;
    snprintf(what, sizeof what, "%s: (b) ds_engine_fact_count", when);
    rc |= expect_status(what, ds_engine_fact_count(e, &count), want);

    int visited = 0;
    snprintf(what, sizeof what, "%s: (b) ds_engine_for_each_fact", when);
    rc |= expect_status(what,
        ds_engine_for_each_fact(e, NULL, count_visit, &visited), want);
    if (want == DS_ERR_ENGINE_HALTED && visited != 0) {
        fprintf(stderr, "FAIL: %s: (b) the refused enumeration visited %d "
                        "facts\n", when, visited);
        rc = 1;
    }

    const ds_schema_t *s = NULL;
    snprintf(what, sizeof what, "%s: (c) ds_engine_schema_find", when);
    rc |= expect_status(what, ds_engine_schema_find(e, "P", &s), want);

    int nodes = 0, edges = 0;
    snprintf(what, sizeof what, "%s: (d) ds_engine_rete_network", when);
    rc |= expect_status(what,
        ds_engine_rete_network(e, NULL, false, count_node, &nodes,
                               count_edge, &edges),
        want);
    if (want == DS_ERR_ENGINE_HALTED && nodes != 0) {
        fprintf(stderr, "FAIL: %s: (d) the refused network walk reported %d "
                        "nodes\n", when, nodes);
        rc = 1;
    }
    if (want == DS_OK && nodes == 0) {
        fprintf(stderr, "FAIL: %s: (d) premise: the network walk reported no "
                        "node\n", when);
        rc = 1;
    }
    return rc;
}

/* (f): the handles, each expecting `want`. */
static int handle_reads(const ds_fact_t *fact, const ds_schema_t *p, int want,
                        const char *when)
{
    int rc = 0;
    char what[160];
    uint64_t id = 0;
    snprintf(what, sizeof what, "%s: (f) ds_fact_get_id on a handle taken "
                                "before the pump", when);
    rc |= expect_status(what, ds_fact_get_id(fact, &id), want);
    const char *name = NULL;
    snprintf(what, sizeof what, "%s: (f) ds_schema_get_name on P's handle",
             when);
    rc |= expect_status(what, ds_schema_get_name(p, &name), want);
    return rc;
}

/* ---- the window: an upsert whose own retract halts ----------------------- */

static const char *UPSERT =
    "schema Q scope logical:\n"
    "    id: Int key\n"
    "\n"
    "schema P scope logical:\n"
    "    id: Int key\n"
    "    v: Int mutable\n"
    "\n"
    "schema R scope logical:\n"
    "    id: Int key\n"
    "    lied: Int mutable\n"
    "\n"
    "rule halt_at_release:\n"
    "    Q q\n"
    "    no P p where p.id == q.id\n"
    "    R r where r.lied + q.id > 0\n"
    "->\n"
    "    log info \"never\"\n";

/* What the stream callback saw while the upsert ran. */
typedef struct {
    bool             upserting;
    const ds_fact_t *q;               /* Q's live fact, taken before */
    int              assert_seen, assert_status;
    uint64_t         assert_id;
    int              retract_seen, retract_status;
    uint64_t         retract_id;
    int              error_seen, error_q_status;
} window_t;

static ds_result_t window_cb(ds_engine_t *engine, const ds_stream_ev_t *ev,
                             void *user)
{
    (void) engine;
    window_t *w = user;
    if (!w->upserting) return DS_OK_R;
    if (ev->kind == DS_EV_FACT_ASSERT && w->assert_seen == 0) {
        w->assert_seen = 1;
        w->assert_status =
            ds_fact_get_id(ev->p.fact_assert.fact, &w->assert_id).status;
    } else if (ev->kind == DS_EV_FACT_RETRACT && w->retract_seen == 0) {
        w->retract_seen = 1;
        w->retract_status =
            ds_fact_get_id(ev->p.fact_retract.fact, &w->retract_id).status;
    } else if (ev->kind == DS_EV_ENGINE_ERROR) {
        uint64_t id = 0;
        w->error_seen = 1;
        w->error_q_status = ds_fact_get_id(w->q, &id).status;
    }
    return DS_OK_R;
}

static ds_result_t assert_one(ds_engine_t *e, const char *schema,
                              const ds_slot_value_t *v, uint32_t n,
                              ds_fact_t **out)
{
    const ds_schema_t *s = NULL;
    ds_result_t r = ds_engine_schema_find(e, schema, &s);
    if (r.status != DS_OK) return r;
    if (s == NULL) return DS_ERR_R(DS_ERR_NOT_FOUND, "no such schema");
    return ds_engine_assert(e, s, v, n, out);
}

static int expect_int(const char *what, int got, int want)
{
    if (got == want) return 0;
    fprintf(stderr, "FAIL: %s: want %d, got %d\n", what, want, got);
    return 1;
}

static int run_window(bool lying)
{
    const char *when = lying ? "window" : "window unedited";
    uint8_t *dsc = NULL;
    size_t   len = 0;
    ds_result_t r = spec_compile_ds(UPSERT, &dsc, &len);
    if (r.status != DS_OK) return spec_fail("compile UPSERT", r);
    if (lying && lie(dsc, len)) { free(dsc); return 1; }
    ds_engine_t *e = NULL;
    r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) { free(dsc); return spec_fail("engine_new", r); }
    r = ds_engine_load_dsc(e, dsc, len);
    free(dsc);
    if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("load_dsc", r); }

    int rc = 0;
    window_t w;
    memset(&w, 0, sizeof w);
    const ds_schema_t *p = NULL;
    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);

    /* P first, so Q's token is blocked from the start; then Q; then R, which
       meets no released token and so runs no join test. */
    v[0].kind = DS_SLOT_INT; v[0].v.i = 1;
    v[1].kind = DS_SLOT_INT; v[1].v.i = 1;
    ds_fact_t *old_p = NULL;
    r = assert_one(e, "P", v, 2, &old_p);
    if (r.status != DS_OK) { rc = spec_fail("premise: assert P", r); goto done; }
    uint64_t old_p_id = 0;
    (void) ds_fact_get_id(old_p, &old_p_id);
    ds_fact_t *q = NULL;
    r = assert_one(e, "Q", v, 1, &q);
    if (r.status != DS_OK) { rc = spec_fail("premise: assert Q", r); goto done; }
    w.q = q;
    if (lying) {
        v[1].kind = DS_SLOT_STRING; v[1].v.s = "x";
    }
    r = assert_one(e, "R", v, 2, NULL);
    if (r.status != DS_OK) {
        rc = spec_fail("premise: assert R; nothing it meets runs its join", r);
        goto done;
    }
    r = ds_engine_schema_find(e, "P", &p);
    if (r.status != DS_OK || p == NULL) { rc = spec_fail("find P", r); goto done; }

    r = ds_engine_set_stream_callback(e, window_cb, &w);
    if (r.status != DS_OK) { rc = spec_fail("set_stream_callback", r); goto done; }

    /* The upsert: the same key, another `v`. */
    v[1].kind = DS_SLOT_INT; v[1].v.i = 2;
    w.upserting = true;
    r = assert_one(e, "P", v, 2, NULL);
    w.upserting = false;
    char what[160];
    snprintf(what, sizeof what, "%s: the upsert", when);
    rc |= expect_status(what, r, lying ? DS_ERR_ENGINE_HALTED : DS_OK);

    /* (g) */
    snprintf(what, sizeof what, "%s: (g) the upsert's FactAssert was delivered",
             when);
    rc |= expect_int(what, w.assert_seen, 1);
    snprintf(what, sizeof what, "%s: (g) ds_fact_get_id on the FactAssert's "
                                "handle, in its callback", when);
    rc |= expect_int(what, w.assert_status, DS_OK);
    snprintf(what, sizeof what, "%s: (g) the old P's FactRetract was delivered",
             when);
    rc |= expect_int(what, w.retract_seen, 1);
    snprintf(what, sizeof what, "%s: (g) ds_fact_get_id on the FactRetract's "
                                "handle, in its callback", when);
    rc |= expect_int(what, w.retract_status, DS_OK);
    if (w.retract_status == DS_OK && w.retract_id != old_p_id) {
        fprintf(stderr, "FAIL: %s: (g) the FactRetract names fact %llu, want "
                        "the old P, %llu\n", when,
                (unsigned long long) w.retract_id,
                (unsigned long long) old_p_id);
        rc = 1;
    }

    if (lying) {
        /* (h) */
        rc |= expect_int("window: (h) the EngineError was delivered",
                         w.error_seen, 1);
        rc |= expect_int("window: (h) Q's handle, in the EngineError's own "
                         "callback", w.error_q_status, DS_ERR_ENGINE_HALTED);
    } else {
        rc |= expect_int("window unedited: no EngineError", w.error_seen, 0);
    }

    /* (i) */
    uint64_t id = 0;
    snprintf(what, sizeof what, "%s: (i) Q's handle after the call", when);
    rc |= expect_status(what, ds_fact_get_id(q, &id),
                        lying ? DS_ERR_ENGINE_HALTED : DS_OK);
    const char *name = NULL;
    snprintf(what, sizeof what, "%s: (i) P's schema handle after the call",
             when);
    rc |= expect_status(what, ds_schema_get_name(p, &name),
                        lying ? DS_ERR_ENGINE_HALTED : DS_OK);
done:
    ds_engine_free(e);
    return rc;
}

static int test_unedited_every_read_answers(void)
{
    ds_engine_t *e = NULL;
    uint64_t id = 0;
    const ds_fact_t *fact = NULL;
    const ds_schema_t *p = NULL;
    int pumped = 0;
    if (run_one_pump(false, &e, &id, &fact, &p, &pumped)) return 1;
    int rc = 0;
    if (pumped != DS_OK) {
        fprintf(stderr, "FAIL: unedited: the pump: want DS_OK, got %d\n",
                pumped);
        rc = 1;
    }
    rc |= reads(e, id, DS_OK, "unedited");
    rc |= handle_reads(fact, p, DS_OK, "unedited");
    ds_engine_free(e);
    return rc;
}

static int test_reads_after_the_halt_are_refused(void)
{
    ds_engine_t *e = NULL;
    uint64_t id = 0;
    const ds_fact_t *fact = NULL;
    const ds_schema_t *p = NULL;
    int pumped = 0;
    if (run_one_pump(true, &e, &id, &fact, &p, &pumped)) return 1;
    int rc = 0;
    if (pumped != DS_ERR_ENGINE_HALTED) {
        fprintf(stderr, "FAIL: premise: the negative fixture's pump: want "
                        "DS_ERR_ENGINE_HALTED, got %d\n", pumped);
        ds_engine_free(e);
        return 1;
    }
    rc |= reads(e, id, DS_ERR_ENGINE_HALTED, "halted");
    rc |= handle_reads(fact, p, DS_ERR_ENGINE_HALTED, "halted");

    /* (e) The four that stay valid. */
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    ds_result_t r = ds_engine_halted(e, &halted, &fault);
    if (r.status != DS_OK || !halted || fault != DS_ENGINE_FAULT_ARTEFACT_LIED) {
        fprintf(stderr, "FAIL: (e) ds_engine_halted: status %d halted=%d "
                        "fault=%d, want DS_OK on ARTEFACT_LIED\n",
                r.status, (int) halted, (int) fault);
        rc = 1;
    }
    ds_platform_signature_t sig;
    memset(&sig, 0, sizeof sig);
    rc |= expect_status("(e) ds_engine_get_platform_signature",
                        ds_engine_get_platform_signature(e, &sig), DS_OK);
    ds_session_header_t hdr;
    memset(&hdr, 0, sizeof hdr);
    rc |= expect_status("(e) ds_engine_get_session_header",
                        ds_engine_get_session_header(e, &hdr), DS_OK);
    if (hdr.dsc_hash == NULL || hdr.dsc_hash_len != 32) {
        fprintf(stderr, "FAIL: (e) the session header lost the load-time "
                        "dsc_hash (len %zu)\n", hdr.dsc_hash_len);
        rc = 1;
    }
    ds_engine_free(e);
    return rc;
}

int main(void)
{
    int failed = 0;
    failed |= test_unedited_every_read_answers();
    failed |= test_reads_after_the_halt_are_refused();
    failed |= run_window(false);
    failed |= run_window(true);
    if (failed) {
        fprintf(stderr, "test_ncbk_2_9__a_read_after_the_halt_is_refused: FAILED\n");
        return 1;
    }
    printf("test_ncbk_2_9__a_read_after_the_halt_is_refused: OK\n");
    return 0;
}

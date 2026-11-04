/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_fact_stamps — what a fact keeps so it can leave the engine as a
 * FactExternal ([RFCS.23.5], [LFST.5.6]):
 *
 *   1. [LFST.5.6] assert_seq is the seq of the fact's OWN FactAssert record,
 *      as the stream numbered it.
 *   2. [LFST.5.6] "The fact keeps that event_id for as long as it is in
 *      working memory": a no-op reassert emits a second FactAssert against
 *      the same live fact, with a new seq, and the fact's assert_seq stays.
 *   3. [RFCS.23.5] asserted_wall_ns is the held wall sample when the fact
 *      entered, "the value now() would have given at that moment".
 *   4. [RFCS.23.5] With no wall value ([LTIM.2.8.3]) asserted_at is absent:
 *      asserted_wall_set is false.
 *   5. A meaningful change is a retract and a new fact: the new fact has its
 *      own FactAssert's seq and the wall sample of its own step.
 *   6. The clone keeps every fact as it is, stamps included.
 *
 * With the seq stamped on EVERY FactAssert, 2 fails; with the wall read at a
 * later step instead of the entry, 5 fails.
 */
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"          /* ds_engine_register_schema, libds-internal */
#include "wm.h"              /* ds_fact_t's stamps are internal */

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

/* ---- observe the FactAssert records ---------------------------------- */

typedef struct { uint64_t seq[16]; ds_fact_t *fact[16]; int n; } asserts_t;

static ds_result_t observe(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    asserts_t *a = (asserts_t *) user;
    if (ev->kind != DS_EV_FACT_ASSERT) return DS_OK_R;
    if (a->n >= 16) return DS_OK_R;
    a->seq[a->n]  = ev->seq;
    a->fact[a->n] = ev->p.fact_assert.fact;
    a->n++;
    return DS_OK_R;
}

/* One logical schema `S`: key `k`, mutable `v`, on the mock clock. */
static ds_engine_t *engine_with_schema(const ds_schema_t **out_s)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) return NULL;
    ds_slot_desc_t sd[2] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "v", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    if (ds_engine_register_schema(e, "S", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  sd, 2, out_s).status != DS_OK
            || ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status != DS_OK) {
        ds_engine_free(e);
        return NULL;
    }
    return e;
}

static ds_result_t assert_kv(ds_engine_t *e, const ds_schema_t *s,
                             int64_t k, int64_t v, ds_fact_t **out)
{
    ds_slot_value_t sv[2] = {
        { .kind = DS_SLOT_INT, .v.i = k },
        { .kind = DS_SLOT_INT, .v.i = v },
    };
    return ds_engine_assert(e, s, sv, 2, out);
}

/* ---- 1, 2, 3, 5 ------------------------------------------------------- */

static void test_seq_and_wall_are_the_entry_record_and_sample(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = engine_with_schema(&s);
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }
    asserts_t a = {0};
    ds_engine_set_stream_callback(e, observe, &a);

    CHECK(ds_engine_wall_clock_set(e, 1700000000000000000LL).status == DS_OK,
          "set the wall clock");
    ds_fact_t *f = NULL;
    CHECK(assert_kv(e, s, 1, 10, &f).status == DS_OK && f != NULL,
          "assert S(1, 10)");
    CHECK(a.n == 1 && a.fact[0] == f, "one FactAssert, for that fact");
    if (a.n == 1 && f != NULL) {
        /* 1 */
        CHECK(f->assert_seq_set, "the seq is stamped");
        CHECK(f->assert_seq == a.seq[0], "and is the FactAssert's own seq");
        /* 3 */
        CHECK(f->asserted_wall_set, "the wall instant is stamped");
        CHECK(f->asserted_wall_ns == 1700000000000000000LL,
              "and is the held wall sample at entry");
    }

    /* 2: the same identity and the same slots -- a no-op. The engine records
       it as an input arriving, against the live fact, under a new
       seq; the fact keeps the first. */
    CHECK(ds_engine_wall_clock_set(e, 1700000000500000000LL).status == DS_OK,
          "move the wall clock");
    ds_fact_t *g = NULL;
    CHECK(assert_kv(e, s, 1, 10, &g).status == DS_OK, "reassert S(1, 10)");
    CHECK(g == f, "the no-op returns the live fact");
    CHECK(a.n == 2 && a.seq[1] > a.seq[0],
          "a second FactAssert, with a later seq");
    if (a.n == 2 && f != NULL) {
        CHECK(f->assert_seq == a.seq[0],
              "the fact keeps its first FactAssert's seq");
        CHECK(f->asserted_wall_ns == 1700000000000000000LL,
              "and the wall instant it entered at");
    }

    /* 5: a mutable slot moved -- a retract and a new fact. */
    ds_fact_t *h = NULL;
    CHECK(assert_kv(e, s, 1, 11, &h).status == DS_OK && h != NULL,
          "assert S(1, 11)");
    if (h != NULL && a.n >= 3) {
        CHECK(a.fact[a.n - 1] == h, "the last FactAssert is the new fact's");
        CHECK(h->assert_seq_set && h->assert_seq == a.seq[a.n - 1],
              "the new fact carries its own FactAssert's seq");
        CHECK(h->asserted_wall_set
                  && h->asserted_wall_ns == 1700000000500000000LL,
              "and the wall sample of the step it entered at");
    }
    ds_engine_free(e);
}

/* ---- 4 ---------------------------------------------------------------- */

/* @spec [RFCS.23.5] */
static void test_no_wall_value_leaves_asserted_at_absent(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = engine_with_schema(&s);
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }
    ds_fact_t *f = NULL;
    CHECK(assert_kv(e, s, 1, 10, &f).status == DS_OK && f != NULL,
          "assert with the mock wall clock never set");
    if (f != NULL) {
        CHECK(!f->asserted_wall_set, "asserted_at is absent");
        CHECK(f->assert_seq_set, "and the seq is stamped regardless");
    }
    ds_engine_free(e);
}

/* ---- 6 ---------------------------------------------------------------- */

typedef struct { uint64_t want; const ds_fact_t *found; } find_t;

static ds_result_t find_by_id(const ds_fact_t *fact, void *user)
{
    find_t *f = (find_t *) user;
    if (fact->fact_id == f->want) f->found = fact;
    return DS_OK_R;
}

static void test_the_clone_keeps_the_stamps(void)
{
    const ds_schema_t *s = NULL;
    ds_engine_t *e = engine_with_schema(&s);
    if (e == NULL) { g_fails++; fprintf(stderr, "FAIL: engine\n"); return; }
    CHECK(ds_engine_wall_clock_set(e, 42).status == DS_OK, "wall 42");
    ds_fact_t *f = NULL;
    CHECK(assert_kv(e, s, 7, 1, &f).status == DS_OK && f != NULL, "assert");
    ds_engine_t *c = NULL;
    CHECK(ds_engine_clone(e, &c).status == DS_OK && c != NULL, "clone");
    if (c != NULL && f != NULL) {
        find_t q = { .want = f->fact_id, .found = NULL };
        CHECK(ds_engine_for_each_fact(c, NULL, find_by_id, &q).status == DS_OK
                  && q.found != NULL, "the clone holds the fact under its id");
        if (q.found != NULL) {
            CHECK(q.found->assert_seq_set
                      && q.found->assert_seq == f->assert_seq,
                  "with the same seq");
            CHECK(q.found->asserted_wall_set
                      && q.found->asserted_wall_ns == 42,
                  "and the same wall instant");
        }
        ds_engine_free(c);
    }
    ds_engine_free(e);
}

/* 7. The integrator gives the engine its run id and tier id at creation;
      either may be absent. The
      engine copies them, reports them back, and the session header records
      them ([RFCS.4.3], [RFCS.4.4]); the clone carries both. */
static void test_run_and_tier_ids_are_the_integrators(void)
{
    char run[] = "run-7", tier[] = "edge";
    ds_engine_config_t cfg = { .run_id = run, .tier_id = tier };
    ds_engine_t *e = NULL;
    CHECK(ds_engine_new(&cfg, &e).status == DS_OK && e != NULL, "engine");
    if (e == NULL) return;
    /* The caller's strings may go: the engine copied them. */
    run[0] = 'X'; tier[0] = 'X';
    const char *got = NULL;
    CHECK(ds_engine_get_run_id(e, &got).status == DS_OK && got != NULL
              && strcmp(got, "run-7") == 0, "run_id is copied and reported");
    CHECK(ds_engine_get_tier_id(e, &got).status == DS_OK && got != NULL
              && strcmp(got, "edge") == 0, "tier_id is copied and reported");
    ds_session_header_t hdr;
    CHECK(ds_engine_get_session_header(e, &hdr).status == DS_OK
              && strcmp(hdr.tier_id, "edge") == 0,
          "the session header carries the tier id");
    CHECK(strcmp(hdr.session_id, "run-7") == 0,
          "and records the run id as its session_id ([RFCS.4.3])");
    ds_engine_t *c = NULL;
    CHECK(ds_engine_clone(e, &c).status == DS_OK && c != NULL, "clone");
    if (c != NULL) {
        CHECK(ds_engine_get_run_id(c, &got).status == DS_OK && got != NULL
                  && strcmp(got, "run-7") == 0, "the clone has the run id");
        CHECK(ds_engine_get_tier_id(c, &got).status == DS_OK && got != NULL
                  && strcmp(got, "edge") == 0, "and the tier id");
        ds_engine_free(c);
    }
    ds_engine_free(e);

    /* Absent: NULL in, NULL out, "" in the session header. */
    ds_engine_config_t none = {0};
    e = NULL;
    CHECK(ds_engine_new(&none, &e).status == DS_OK && e != NULL, "engine, no ids");
    if (e == NULL) return;
    got = (const char *) 1;
    CHECK(ds_engine_get_run_id(e, &got).status == DS_OK && got == NULL,
          "an absent run_id reads NULL");
    got = (const char *) 1;
    CHECK(ds_engine_get_tier_id(e, &got).status == DS_OK && got == NULL,
          "an absent tier_id reads NULL");
    CHECK(ds_engine_get_session_header(e, &hdr).status == DS_OK
              && strcmp(hdr.tier_id, "") == 0,
          "and the session header's tier_id is empty");
    CHECK(strcmp(hdr.session_id, "") == 0,
          "and so is its session_id: the engine mints none");
    ds_engine_free(e);
}

/* 8. [NLFC.1.2], [LSTR.8.5]: each id must be well-formed UTF-8,
      and ds_engine_new refuses one that is not with DS_ERR_ENCODING and
      creates no engine: *out is NULL. An encoded surrogate (`r` ED A0 80) and
      a lone C0 are refused; a well-formed non-ASCII id (`r` C3 A9, "ré") is
      accepted and read back as given. PATH: ds_engine_new's
      nlfc_1_2_id_well_formed, before anything is allocated. The Mercury
      runtime is held to the same bytes (test_ds.m, check_nlfc_1_2_ids). */
static void nlfc_1_2_ids(int tier, const char *which)
{
    static const char *const ill[] = { "r\xED\xA0\x80", "\xC0" };
    char label[128];
    for (size_t i = 0; i < sizeof ill / sizeof ill[0]; i++) {
        ds_engine_config_t cfg = {0};
        if (tier) cfg.tier_id = ill[i]; else cfg.run_id = ill[i];
        ds_engine_t *e = (ds_engine_t *) 1;    /* must come back NULL */
        ds_result_t r = ds_engine_new(&cfg, &e);
        snprintf(label, sizeof label,
                 "an ill-formed %s (case %zu) is DS_ERR_ENCODING, no engine",
                 which, i);
        CHECK(r.status == DS_ERR_ENCODING && e == NULL, label);
        if (r.status == DS_OK && e != NULL && e != (ds_engine_t *) 1)
            ds_engine_free(e);
    }
    ds_engine_config_t ok = {0};
    if (tier) ok.tier_id = "r\xC3\xA9"; else ok.run_id = "r\xC3\xA9";
    ds_engine_t *e = NULL;
    snprintf(label, sizeof label, "a well-formed non-ASCII %s is accepted",
             which);
    CHECK(ds_engine_new(&ok, &e).status == DS_OK && e != NULL, label);
    if (e == NULL) return;
    const char *got = NULL;
    ds_result_t g = tier ? ds_engine_get_tier_id(e, &got)
                         : ds_engine_get_run_id(e, &got);
    snprintf(label, sizeof label, "and its %s reads back unchanged", which);
    CHECK(g.status == DS_OK && got != NULL && strcmp(got, "r\xC3\xA9") == 0,
          label);
    ds_engine_free(e);
}

/* @spec [NLFC.1.2] */
static void test_nlfc_1_2__ill_formed_run_id_is_refused(void)
{
    nlfc_1_2_ids(0, "run_id");
}

/* @spec [NLFC.1.2] */
static void test_nlfc_1_2__ill_formed_tier_id_is_refused(void)
{
    nlfc_1_2_ids(1, "tier_id");
}

int main(void)
{
    printf("=== test_fact_stamps ===\n");
    test_seq_and_wall_are_the_entry_record_and_sample();
    test_no_wall_value_leaves_asserted_at_absent();
    test_the_clone_keeps_the_stamps();
    test_run_and_tier_ids_are_the_integrators();
    test_nlfc_1_2__ill_formed_run_id_is_refused();
    test_nlfc_1_2__ill_formed_tier_id_is_refused();
    if (g_fails) {
        fprintf(stderr, "test_fact_stamps: %d FAILURE(S)\n", g_fails);
        return 1;
    }
    printf("=== test_fact_stamps: ALL PASSED ===\n");
    return 0;
}

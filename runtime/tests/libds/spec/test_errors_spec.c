/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_errors_spec — spec conformance for the error-code surface.
 *
 * Spec: IERR.2 (status-code taxonomy),
 *   IERR.3 (ds_result_t shape: success has NULL detail, error
 *   has non-NULL detail except DS_ERR_OOM), and IERR.4.1.1 (a detail
 *   from a call that leaves no engine is static).
 *
 * One spec test per documented error code reachable through the public API.
 * Out of scope: DS_ERR_INTERNAL ("must never fire in a correct build"),
 * DS_ERR_OOM (needs a deterministic OOM), and the codes that only an
 * integrator's typed callback originates (DS_ERR_STORAGE_QUERY_FAILED,
 * DS_ERR_STORAGE_NOT_FOUND).
 *
 * Public API only — no internal headers.
 */
#include "spec_common.h"

/* ============== Helpers ============== */

static int new_engine(ds_engine_t **out)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    *out = e;
    return 0;
}

/* Assert that `r` is the documented error: matching status code AND
   non-NULL detail (per IERR.3.3, only DS_ERR_OOM is allowed to have
   NULL detail; none of the codes exercised in this drill fall into
   that exception). */
#define EXPECT_ERR_WITH_DETAIL(what, r, want) do { \
    if ((r).status != (want)) { \
        fprintf(stderr, "FAIL: %s: want status %d, got %d (%s)\n", \
                what, (want), (r).status, \
                (r).detail ? (r).detail : "(null)"); \
        return 1; \
    } \
    if ((r).detail == NULL) { \
        fprintf(stderr, \
                "FAIL: %s: status %d returned NULL detail (IERR.3.3)\n", \
                what, (want)); \
        return 1; \
    } \
    if ((r).detail[0] == '\0') { \
        fprintf(stderr, \
                "FAIL: %s: status %d detail is empty\n", what, (want)); \
        return 1; \
    } \
} while (0)

/* ============== IERR.3 result-shape invariants ============== */

/* IERR.3.2 — success returns {DS_OK, NULL}. */
static int test_ierr_3_2__success_has_null_detail(void)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: engine_new not OK\n"); return 1;
    }
    if (r.detail != NULL) {
        fprintf(stderr,
                "FAIL: success result had non-NULL detail \"%s\"\n",
                r.detail);
        return 1;
    }
    /* Several more successful calls should all return NULL detail. */
    size_t c = 0;
    r = ds_engine_schema_count(e, &c);
    if (r.status != DS_OK || r.detail != NULL) {
        fprintf(stderr, "FAIL: schema_count success detail=%s\n",
                r.detail ? r.detail : "(null)");
        return 1;
    }
    r = ds_engine_fact_count(e, &c);
    if (r.status != DS_OK || r.detail != NULL) {
        fprintf(stderr, "FAIL: fact_count success detail=%s\n",
                r.detail ? r.detail : "(null)");
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IERR.3.3 — every error returns a non-NULL, non-empty detail.
   Sanity-pinned across several distinct error codes from
   different categories; per-code coverage lives in the
   per-code scenarios below. */
/* @spec [NERR.2.3] */
static int test_ierr_3_3__every_error_has_non_null_detail(void)
{
    /* DS_ERR_INVAL via NULL engine. */
    {
        size_t c = 0;
        ds_result_t r = ds_engine_schema_count(NULL, &c);
        EXPECT_ERR_WITH_DETAIL("INVAL", r, DS_ERR_INVAL);
    }
    /* DS_ERR_PARSE via ds_json_parse on bad input. */
    {
        ds_json_t *t = NULL;
        ds_result_t r = ds_json_parse("{not json", 9, &t);
        EXPECT_ERR_WITH_DETAIL("PARSE", r, DS_ERR_PARSE);
    }
    /* DS_ERR_SLOT_TYPE_MISMATCH via a Float into an Int slot of a loaded
       schema. */
    {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        ds_result_t r = spec_load_ds(e,
            "schema K scope logical:\n    v: Int key\n");
        EXPECT_OK("load K", r);
        const ds_schema_t *s = NULL;
        r = ds_engine_schema_find(e, "K", &s);
        EXPECT_OK("find K", r);
        ds_slot_value_t bad[] = { { .kind = DS_SLOT_FLOAT, .v.f = 1.5 } };
        r = ds_engine_assert(e, s, bad, 1, NULL);
        EXPECT_ERR_WITH_DETAIL("SLOT_TYPE_MISMATCH", r,
                               DS_ERR_SLOT_TYPE_MISMATCH);
        ds_engine_free(e);
    }
    return 0;
}

/* ============== IERR.4.1.1 — a detail with no engine to hold it ============== */

/* [IERR.4.1.1]: a call that acts on no engine, and a ds_engine_new that
   fails and so leaves none, return a static detail, valid for the life of
   the process. The details are ds_json_parse's refusal of malformed text and
   ds_engine_new's refusal of a run_id that is not well-formed UTF-8. Each is
   kept, as the pointer and as a copy of its text; after further calls that
   allocate and free, both pointers still read their original text. */
/* @spec [IERR.4.1.1] */
static int test_ierr_4_1_1__engineless_detail_is_static(void)
{
    ds_json_t *t = NULL;
    const ds_result_t parse = ds_json_parse("{not json", 9, &t);
    EXPECT_ERR_WITH_DETAIL("ds_json_parse on malformed text", parse,
                           DS_ERR_PARSE);
    char parse_text[256];
    snprintf(parse_text, sizeof parse_text, "%s", parse.detail);

    static const char bad_id[] = { 'r', (char) 0xFF, 'n', '\0' };
    ds_engine_config_t cfg = {0};
    cfg.run_id = bad_id;
    ds_engine_t *none = NULL;
    const ds_result_t made = ds_engine_new(&cfg, &none);
    EXPECT_ERR_WITH_DETAIL("ds_engine_new with an ill-formed run_id", made,
                           DS_ERR_ENCODING);
    if (none != NULL) {
        fprintf(stderr, "FAIL: a refused ds_engine_new left an engine\n");
        return 1;
    }
    char made_text[256];
    snprintf(made_text, sizeof made_text, "%s", made.detail);

    /* Further calls, each of which allocates and frees. */
    ds_json_t *u = NULL;
    ds_result_t r = ds_json_parse("[1,2,3]", 7, &u);
    EXPECT_OK("ds_json_parse", r);
    char *s = NULL;
    r = ds_json_serialize(u, &s, NULL);
    EXPECT_OK("ds_json_serialize", r);
    ds_free(s);
    ds_json_free(u);
    ds_json_t *v = NULL;
    r = ds_json_parse("[1,", 3, &v);
    EXPECT_STATUS("a second refusal", r, DS_ERR_PARSE);
    ds_engine_t *e = NULL;
    if (new_engine(&e)) return 1;
    ds_engine_free(e);

    if (strcmp(parse.detail, parse_text) != 0) {
        fprintf(stderr, "FAIL: ds_json_parse's detail changed after later "
                "calls: \"%s\", was \"%s\"\n", parse.detail, parse_text);
        return 1;
    }
    if (strcmp(made.detail, made_text) != 0) {
        fprintf(stderr, "FAIL: a refused ds_engine_new's detail changed "
                "after later calls: \"%s\", was \"%s\"\n", made.detail,
                made_text);
        return 1;
    }
    return 0;
}

/* ============== IERR.2.3 — generic errors (-1 .. -99) ============== */

/* DS_ERR_INVAL: NULL engine on ds_engine_assert (sample of the "caller
   passed something wrong" bucket). */
/* @spec [IERR.2.3.1] */
static int test_ierr_2_3__inval_on_null_engine(void)
{
    ds_slot_value_t v[] = { { .kind = DS_SLOT_INT, .v.i = 1 } };
    ds_result_t r = ds_engine_assert(NULL, NULL, v, 1, NULL);
    EXPECT_ERR_WITH_DETAIL("INVAL", r, DS_ERR_INVAL);
    return 0;
}

/* DS_ERR_STATE: clock_set called while engine is in LIVE mode.
   Per libds.h: "Error (DS_ERR_STATE) if the engine is in live
   mode." Engines start in LIVE per IARC.3.11. */
/* @spec [NTST.3.2] [IERR.2.3.1] */
static int test_ierr_2_3__state_on_clock_set_in_live_mode(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    ds_clock_mode_t mode;
    ds_result_t r = ds_engine_clock_mode(e, &mode);
    EXPECT_OK("clock_mode", r);
    if (mode != DS_CLOCK_LIVE) {
        fprintf(stderr, "FAIL: engine did not start in LIVE\n"); return 1;
    }
    r = ds_engine_clock_set(e, 1234);
    EXPECT_ERR_WITH_DETAIL("clock_set in LIVE", r, DS_ERR_STATE);
    /* Same for clock_advance. */
    r = ds_engine_clock_advance(e, 100);
    EXPECT_ERR_WITH_DETAIL("clock_advance in LIVE", r, DS_ERR_STATE);
    ds_engine_free(e);
    return 0;
}

/* DS_ERR_UNSUPPORTED is not driven here: its one public producer,
   ds_engine_mem, returns it only for an engine with no Rete network, which
   ds_engine_new never makes. */

/* ================== IERR.2.4 — input errors (-100..-199) ================== */

/* DS_ERR_PARSE: ds_json_parse on syntactically broken input, the simplest
   direct producer. [NERR.5]'s table states the code. */
/* @spec [NERR.5] */
static int test_ierr_2_4__parse_on_bad_json(void)
{
    ds_json_t *t = NULL;
    ds_result_t r = ds_json_parse("{not json", 9, &t);
    EXPECT_ERR_WITH_DETAIL("bad JSON", r, DS_ERR_PARSE);
    /* Out is NULL on error per the doc contract. */
    if (t != NULL) {
        fprintf(stderr, "FAIL: parse error left non-NULL out\n"); return 1;
    }
    return 0;
}

/* IERR.2.4 — ds_engine_assert rejects a slot value whose kind does not match
   the schema-declared slot type (DS_ERR_SLOT_TYPE_MISMATCH): no implicit
   coercion, even between numeric kinds. */
/* @spec [NFCT.2.3] */
static int test_ierr_2_4__slot_type_mismatch_on_wrong_kind(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    ds_result_t r = spec_load_ds(e, "schema K scope logical:\n    v: Int key\n");
    EXPECT_OK("load K", r);
    const ds_schema_t *s = NULL;
    r = ds_engine_schema_find(e, "K", &s);
    EXPECT_OK("find K", r);
    /* FLOAT value into an Int slot — no implicit widening. */
    ds_slot_value_t bad[] = { { .kind = DS_SLOT_FLOAT, .v.f = 1.5 } };
    r = ds_engine_assert(e, s, bad, 1, NULL);
    EXPECT_ERR_WITH_DETAIL("int slot vs float kind", r, DS_ERR_SLOT_TYPE_MISMATCH);
    ds_engine_free(e);
    return 0;
}

/* ============== IERR.2.5 — runtime errors (-200..-299) ============== */

static ds_result_t failing_cache_set_cb(ds_engine_t *e, const ds_cache_write_t *write,
                                        void *user)
{
    (void)e; (void)write; (void)user;
    return DS_ERR_R(DS_ERR_ACTION_FAILED, "cache set cb deliberately fails");
}

/* IERR.2.5 — a cache persistence hook returning non-OK propagates out of
   ds_engine_pump ([IDSP.1.3]), through the engine's pending slot. */
/* @spec [NCBK.7.5] */
static int test_ierr_2_5__action_failed_propagates_from_cb(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    ds_result_t r = spec_load_ds(e,
        "schema Trig scope logical:\n    tag: String key\n\n"
        "rule r:\n"
        "    Trig t where t.tag == \"x\"\n"
        "->\n"
        "    cache key: \"k\" value: t.tag\n");
    EXPECT_OK("load cache rule", r);
    r = ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, failing_cache_set_cb, NULL, NULL);
    EXPECT_OK("set cache cbs", r);
    const ds_schema_t *trig = NULL;
    r = ds_engine_schema_find(e, "Trig", &trig);
    EXPECT_OK("find Trig", r);
    ds_slot_value_t v[] = { { .kind = DS_SLOT_STRING, .v.s = "x" } };
    r = ds_engine_assert(e, trig, v, 1, NULL);
    EXPECT_OK("assert", r);
    r = ds_engine_pump(e);
    EXPECT_STATUS("pump surfaces cb error", r, DS_ERR_ACTION_FAILED);
    ds_engine_free(e);
    return 0;
}

/* ============== IERR.2.7 — storage / call errors (-400..-499) ============== */

/* IERR.2.7 — an essential verb, `call`, firing with no callback registered
   surfaces DS_ERR_STORAGE_UNAVAILABLE through ds_engine_pump. */
/* @spec [IDSP.6.4] */
static int test_ierr_2_7__storage_unavailable_on_null_call_cb(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    ds_result_t r = spec_load_ds(e,
        "schema Trig scope logical:\n    tag: String key\n\n"
        "service audit.put:\n    kwarg id: Int\n    no response\n\n"
        "rule r:\n"
        "    Trig t where t.tag == \"x\"\n"
        "->\n"
        "    call audit.put id: 1 nocooldown\n");
    EXPECT_OK("load call rule", r);
    /* Deliberately register NO call callback → the verb is unavailable. */
    const ds_schema_t *trig = NULL;
    r = ds_engine_schema_find(e, "Trig", &trig);
    EXPECT_OK("find Trig", r);
    ds_slot_value_t v[] = { { .kind = DS_SLOT_STRING, .v.s = "x" } };
    r = ds_engine_assert(e, trig, v, 1, NULL);
    EXPECT_OK("assert", r);
    r = ds_engine_pump(e);
    EXPECT_STATUS("pump surfaces storage_unavailable", r,
                  DS_ERR_STORAGE_UNAVAILABLE);
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_ierr_3_2__success_has_null_detail();
    failed |= test_ierr_3_3__every_error_has_non_null_detail();
    failed |= test_ierr_4_1_1__engineless_detail_is_static();
    failed |= test_ierr_2_3__inval_on_null_engine();
    failed |= test_ierr_2_3__state_on_clock_set_in_live_mode();
    failed |= test_ierr_2_4__parse_on_bad_json();
    failed |= test_ierr_2_4__slot_type_mismatch_on_wrong_kind();
    failed |= test_ierr_2_5__action_failed_propagates_from_cb();
    failed |= test_ierr_2_7__storage_unavailable_on_null_call_cb();
    if (!failed) printf("test_errors_spec: OK\n");
    return failed;
}

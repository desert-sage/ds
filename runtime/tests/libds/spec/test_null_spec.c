/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The `null` value model, black-box through libds.h: a null slot on the
 * ds_engine_assert path, and `where` and `no` over one.
 *   [LNUL.9.1] `null` is a slot-value kind, DS_SLOT_NULL.
 *   [LNUL.6.1] two nulls are equal, so a null-bearing fact dedupes against
 *              itself.
 *
 * A null slot's value is checked through the assert and dedup contract:
 * re-asserting the same null is a no-op (the same fact pointer), and a
 * non-null value on the mutable slot replaces the fact (a fresh fact_id).
 */
#include "spec_common.h"

static int new_engine(ds_engine_t **out)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    *out = e;
    return 0;
}

/* [LNUL.9.1] — a `null` in a MUTABLE (non-key) slot: asserts, dedupes
 * against an identical null, and is distinct from a concrete value. */
static int test_lnul_9_1__null_mutable_slot_round_trip(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    ds_result_t r = spec_load_ds(
        e, "schema NM scope logical:\n    k: Int key\n    v: Float? mutable\n");
    if (r.status != DS_OK) return spec_fail("load NM", r);
    r = ds_engine_schema_find(e, "NM", &s);
    if (r.status != DS_OK || s == NULL) return spec_fail("find NM", r);

    ds_slot_value_t vnull[] = { { .kind = DS_SLOT_INT,  .v.i = 1 },
                                { .kind = DS_SLOT_NULL } };
    ds_slot_value_t vval[]  = { { .kind = DS_SLOT_INT,   .v.i = 1 },
                                { .kind = DS_SLOT_FLOAT, .v.f = 3.5 } };

    ds_fact_t *p1 = NULL, *p2 = NULL, *p3 = NULL;
    uint64_t id1 = 0, id3 = 0;
    r = ds_engine_assert(e, s, vnull, 2, &p1);
    if (r.status != DS_OK) return spec_fail("assert null-mutable", r);
    /* Capture the fact_id BEFORE the value-supersede — the supersede retracts
       and frees the null-fact wrapper, so p1 must not be dereferenced after. */
    if (ds_fact_get_id(p1, &id1).status != DS_OK)
        return spec_fail("fact_id(null-mutable)", r);
    r = ds_engine_assert(e, s, vnull, 2, &p2);
    if (r.status != DS_OK) return spec_fail("reassert null-mutable", r);
    if (p1 != p2) {
        fprintf(stderr, "FAIL: null==null did not dedupe (p1 != p2)\n");
        return 1;
    }
    r = ds_engine_assert(e, s, vval, 2, &p3);
    if (r.status != DS_OK) return spec_fail("assert value-supersede", r);
    if (ds_fact_get_id(p3, &id3).status != DS_OK)
        return spec_fail("fact_id(value-supersede)", r);
    /* Null to 3.5 on the same key replaces the fact, with a fresh fact_id.
       Compared by fact_id, not pointer: the old wrapper is freed on the
       replace, and the allocator may hand its address to the new one. */
    if (id1 == id3) {
        fprintf(stderr, "FAIL: null and 3.5 got the same fact_id (no supersede)\n");
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* [LNUL.8.10] — a nullable identity KEY is rejected at compile (spec_load_ds
 * fails). The null-dedup SUBSTRATE (no-op-reassert equality with a null value)
 * is exercised on a nullable NON-key slot: the identity key is a concrete
 * Int, and a null in the `mutable` payload dedupes against an identical null
 * ([LNUL.6.1]) and stays distinct from a concrete value. */
static int test_lnul_8_10__nullable_key_rejected_nonkey_substrate(void)
{
    /* (a) a nullable identity key is rejected ([LNUL.8.10]). */
    {
        ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
        ds_result_t r = spec_load_ds(
            e, "schema NK scope logical:\n    k: Float? key\n");
        if (r.status == DS_OK) {
            fprintf(stderr, "FAIL: nullable `key` slot was accepted\n");
            ds_engine_free(e);
            return 1;
        }
        ds_engine_free(e);
    }

    /* (b) the null-dedup substrate on a nullable NON-key slot. */
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    ds_result_t r = spec_load_ds(
        e, "schema OK scope logical:\n    k: Int key\n    v: Float? mutable\n");
    if (r.status != DS_OK) return spec_fail("load OK", r);
    r = ds_engine_schema_find(e, "OK", &s);
    if (r.status != DS_OK || s == NULL) return spec_fail("find OK", r);

    ds_slot_value_t vnull[] = { { .kind = DS_SLOT_INT, .v.i = 1 },
                                { .kind = DS_SLOT_NULL } };
    ds_slot_value_t vval[]  = { { .kind = DS_SLOT_INT,   .v.i = 1 },
                                { .kind = DS_SLOT_FLOAT, .v.f = 7.0 } };

    ds_fact_t *p1 = NULL, *p2 = NULL, *p3 = NULL;
    uint64_t id1 = 0, id3 = 0;
    r = ds_engine_assert(e, s, vnull, 2, &p1);
    if (r.status != DS_OK) return spec_fail("assert null-payload", r);
    if (ds_fact_get_id(p1, &id1).status != DS_OK)
        return spec_fail("fact_id(null-payload)", r);
    r = ds_engine_assert(e, s, vnull, 2, &p2);
    if (r.status != DS_OK) return spec_fail("reassert null-payload", r);
    if (p1 != p2) {
        fprintf(stderr, "FAIL: null payload did not dedupe (p1 != p2)\n");
        return 1;
    }
    r = ds_engine_assert(e, s, vval, 2, &p3);
    if (r.status != DS_OK) return spec_fail("assert concrete-payload", r);
    if (ds_fact_get_id(p3, &id3).status != DS_OK)
        return spec_fail("fact_id(concrete-payload)", r);
    /* Null to 7.0 is a fresh fact; by fact_id, as above. */
    if (id1 == id3) {
        fprintf(stderr, "FAIL: null payload got the same fact_id as 7.0 (no supersede)\n");
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* [LNUL.3.1] — a DS_SLOT_NULL value in a NON-nullable slot is rejected on
 * assert (the runtime's defense-in-depth beyond the compiler's [LNUL.5.1]
 * gate). */
static int test_lnul_3_1__null_in_nonnullable_rejected(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    const ds_schema_t *s = NULL;
    ds_result_t r = spec_load_ds(
        e, "schema NN scope logical:\n    k: Int key\n    v: Float mutable\n");
    if (r.status != DS_OK) return spec_fail("load NN", r);
    r = ds_engine_schema_find(e, "NN", &s);
    if (r.status != DS_OK || !s) return spec_fail("find NN", r);
    ds_slot_value_t v[] = { { .kind = DS_SLOT_INT, .v.i = 1 },
                            { .kind = DS_SLOT_NULL } };
    r = ds_engine_assert(e, s, v, 2, NULL);
    if (r.status == DS_OK) {
        fprintf(stderr, "FAIL: null admitted into a non-nullable slot\n");
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* [LNUL.3.4] — a Json document whose root is null is the canonical null, so a
   Json slot holds it only as null:

     (a) root-null into a non-nullable `Json`  -> refused, as any null into a
         slot not declared `T?` is ([LNUL.3.1]).
     (b) root-null into a nullable `Json?`     -> stored, as the canonical null:
         the slot reads back DS_SLOT_NULL, not a document, so one
         representation of null is reachable as a slot value.
     (c) DS_SLOT_NULL into `Json?`             -> stored, the ordinary way.
     (d) an object containing a null           -> accepted. {"a": null} is a
         document, not the canonical null; [LNUL.8.4] governs reading the
         leaf. */
static int test_lnul_3_4__root_null_json_is_the_canonical_null(void)
{
    ds_engine_t *e = NULL; if (new_engine(&e)) return 1;
    ds_result_t r = spec_load_ds(
        e, "schema J scope logical:\n    k: Int key\n    doc: Json mutable\n"
           "schema JQ scope logical:\n    k: Int key\n    doc: Json? mutable\n");
    if (r.status != DS_OK) return spec_fail("load J/JQ", r);

    const ds_schema_t *sj = NULL, *sq = NULL;
    r = ds_engine_schema_find(e, "J", &sj);
    if (r.status != DS_OK || !sj) return spec_fail("find J", r);
    r = ds_engine_schema_find(e, "JQ", &sq);
    if (r.status != DS_OK || !sq) return spec_fail("find JQ", r);

    /* (a) root-null document into a non-nullable Json slot. */
    ds_json_t *root_null = NULL;
    if (ds_json_new_null(&root_null).status != DS_OK)
        return spec_fail("json_new_null", DS_OK_R);
    ds_slot_value_t a[] = { { .kind = DS_SLOT_INT,  .v.i = 1 },
                            { .kind = DS_SLOT_JSON, .v.json = root_null } };
    r = ds_engine_assert(e, sj, a, 2, NULL);
    if (r.status == DS_OK) {
        fprintf(stderr, "FAIL: root-null Json admitted into a `Json` slot\n");
        return 1;
    }
    ds_json_free(root_null);

    /* (b) into a NULLABLE one it is stored, and stored as null: the slot reads
       back DS_SLOT_NULL, so the second representation is unreachable. */
    if (ds_json_new_null(&root_null).status != DS_OK)
        return spec_fail("json_new_null 2", DS_OK_R);
    ds_slot_value_t b[] = { { .kind = DS_SLOT_INT,  .v.i = 2 },
                            { .kind = DS_SLOT_JSON, .v.json = root_null } };
    ds_fact_t *fb = NULL;
    r = ds_engine_assert(e, sq, b, 2, &fb);
    if (r.status != DS_OK || fb == NULL)
        return spec_fail("root-null Json refused by a Json? slot", r);
    ds_slot_value_t got;
    r = ds_fact_get_slot(fb, 1, NULL, &got);
    if (r.status != DS_OK) return spec_fail("get_slot doc", r);
    if (got.kind != DS_SLOT_NULL) {
        fprintf(stderr, "FAIL: a root-null Json in a `Json?` slot reads back as "
                        "kind %d, not DS_SLOT_NULL -- two representations of "
                        "null are reachable\n", (int)got.kind);
        return 1;
    }
    ds_json_free(root_null);

    /* (c) the nullable slot still holds null the ordinary way. */
    ds_slot_value_t c[] = { { .kind = DS_SLOT_INT, .v.i = 3 },
                            { .kind = DS_SLOT_NULL } };
    r = ds_engine_assert(e, sq, c, 2, NULL);
    if (r.status != DS_OK)
        return spec_fail("DS_SLOT_NULL refused by a Json? slot", r);

    /* (d) a document that merely CONTAINS a null is untouched. */
    ds_json_t *obj = NULL, *leaf = NULL;
    if (ds_json_new_object(&obj).status != DS_OK) return spec_fail("new_object", DS_OK_R);
    if (ds_json_new_null(&leaf).status != DS_OK)   return spec_fail("new_null leaf", DS_OK_R);
    if (ds_json_object_set(obj, "a", 1, leaf).status != DS_OK)
        return spec_fail("object_set", DS_OK_R);
    ds_slot_value_t d[] = { { .kind = DS_SLOT_INT,  .v.i = 4 },
                            { .kind = DS_SLOT_JSON, .v.json = obj } };
    r = ds_engine_assert(e, sj, d, 2, NULL);
    if (r.status != DS_OK)
        return spec_fail("{\"a\": null} refused by a Json slot", r);
    ds_json_free(obj);

    ds_engine_free(e);
    return 0;
}

/* ============== End-to-end `where` firing (LNUL.4.3, WF vectors) ==============
 *
 * Each compiles a one-rule program and fires it on a null or a present slot:
 * a rule fires only when its `where` is true. WF-n are the conformance
 * vectors' labels for the same cases. */

typedef struct { int n_emit; int n_fire; } fire_probe_t;

static ds_result_t fire_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void)e;
    fire_probe_t *p = (fire_probe_t *)u;
    if (ev->kind == DS_EV_ACTION_EMIT)      p->n_emit++;
    else if (ev->kind == DS_EV_RULE_FIRE_BEGIN) p->n_fire++;
    return DS_OK_R;
}

/* Load a one-rule program, assert one Sensor{entity_id, state}, pump, and
   return the number of ACTION_EMIT events observed (the rule emits a marker
   fact iff it fires). `state_null` selects a null vs a concrete state. */
static int run_where(const char *where_pred, bool state_null,
                     double state_val, int *out_emits)
{
    char src[512];
    snprintf(src, sizeof src,
        "schema Sensor scope logical:\n"
        "    entity_id: String key\n"
        "    state: Float? mutable\n\n"
        "schema Marker scope logical:\n"
        "    entity_id: String key\n\n"
        "rule r:\n"
        "    Sensor s where %s\n"
        "->\n"
        "    emit Marker logical entity_id: s.entity_id\n", where_pred);

    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    r = spec_load_ds(e, src);
    if (r.status != DS_OK) return spec_fail("load where-rule", r);
    const ds_schema_t *sensor = NULL;
    r = ds_engine_schema_find(e, "Sensor", &sensor);
    if (r.status != DS_OK || !sensor) return spec_fail("find Sensor", r);
    fire_probe_t p = {0};
    r = ds_engine_set_stream_callback(e, fire_cb, &p);
    if (r.status != DS_OK) return spec_fail("set_stream_cb", r);

    ds_slot_value_t v[2];
    v[0].kind = DS_SLOT_STRING; v[0].v.s = "a";
    if (state_null) { v[1].kind = DS_SLOT_NULL; }
    else            { v[1].kind = DS_SLOT_FLOAT; v[1].v.f = state_val; }
    r = ds_engine_assert(e, sensor, v, 2, NULL);
    if (r.status != DS_OK) return spec_fail("assert sensor", r);
    r = ds_engine_pump(e);
    if (r.status != DS_OK) return spec_fail("pump", r);

    *out_emits = p.n_emit;
    ds_engine_free(e);
    return 0;
}

/* WF-5 ([LNUL.4.4]) — `s.state is null` fires when state is null. */
static int test_wf5_eq_null_fires_on_null(void)
{
    int emits = -1;
    if (run_where("s.state is null", true, 0.0, &emits)) return 1;
    if (emits != 1) {
        fprintf(stderr, "FAIL: WF-5 `is null` on null: emits=%d want 1\n", emits);
        return 1;
    }
    return 0;
}

/* WF-6 ([LNUL.4.4]) — `s.state is null` does not fire on a present value. */
static int test_wf6_eq_null_no_fire_on_present(void)
{
    int emits = -1;
    if (run_where("s.state is null", false, 10.0, &emits)) return 1;
    if (emits != 0) {
        fprintf(stderr, "FAIL: WF-6 `is null` on 10.0: emits=%d want 0\n", emits);
        return 1;
    }
    return 0;
}

/* WF-3 ([LNUL.4.3]) — `s.state > 85` does not fire on a null reading: the
   comparison is null, and null does not fire. */
static int test_wf3_gt_no_fire_on_null(void)
{
    int emits = -1;
    if (run_where("s.state > 85.0", true, 0.0, &emits)) return 1;
    if (emits != 0) {
        fprintf(stderr, "FAIL: WF-3 `> 85` on null: emits=%d want 0\n", emits);
        return 1;
    }
    return 0;
}

/* WF-1 — `s.state > 85` fires on a present value above threshold. */
static int test_wf1_gt_fires_on_present(void)
{
    int emits = -1;
    if (run_where("s.state > 85.0", false, 90.0, &emits)) return 1;
    if (emits != 1) {
        fprintf(stderr, "FAIL: WF-1 `> 85` on 90.0: emits=%d want 1\n", emits);
        return 1;
    }
    return 0;
}

/* WF-9 / WF-10 ([LNUL.5.3], [LNUL.8.9]) — `??` uses its default when the
   reading is null: `(s.state ?? 0.0) > 85` does not fire on null, and
   `(s.state ?? 100.0) > 85` does. On a present value it is the value. */
static int test_coalesce_default_on_null(void)
{
    int f = 0, emits = -1;
    if (run_where("(s.state ?? 0.0) > 85.0",   true,  0.0,  &emits)) return 1;
    if (emits != 0) { fprintf(stderr, "FAIL: WF-9 `?? 0.0` on null: emits=%d want 0\n", emits); f = 1; }
    if (run_where("(s.state ?? 100.0) > 85.0", true,  0.0,  &emits)) return 1;
    if (emits != 1) { fprintf(stderr, "FAIL: WF-10 `?? 100.0` on null: emits=%d want 1\n", emits); f = 1; }
    if (run_where("(s.state ?? 0.0) > 85.0",   false, 90.0, &emits)) return 1;
    if (emits != 1) { fprintf(stderr, "FAIL: `?? 0.0` on 90.0: emits=%d want 1\n", emits); f = 1; }
    return f;
}

/* ============== N1 — negated-existence blocks on null ([LNUL.4.7]) ==========
 *
 * `no Sensor s where s.state > 85` is satisfied only if, for every sensor,
 * the test is false. A hot sensor blocks it, and so does a null reading. */

/* Assert one Sensor (optional) then a Tick, pump, and return the count of
   AllCool emits — the `all_cool` rule fires iff the negated guard holds. */
static int run_negation(bool has_sensor, bool state_null, double state_val,
                        int *out_emits)
{
    const char *src =
        "schema Tick scope logical:\n    id: Int key\n\n"
        "schema Sensor scope logical:\n"
        "    entity_id: String key\n    state: Float? mutable\n\n"
        "schema AllCool scope logical:\n    id: Int key\n\n"
        "rule all_cool:\n"
        "    Tick t\n"
        "    no Sensor s where s.state > 85.0\n"
        "->\n"
        "    emit AllCool logical id: t.id\n";

    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    r = spec_load_ds(e, src);
    if (r.status != DS_OK) return spec_fail("load negation-rule", r);
    const ds_schema_t *tick = NULL, *sensor = NULL;
    if (ds_engine_schema_find(e, "Tick", &tick).status != DS_OK || !tick)
        return spec_fail("find Tick", r);
    if (ds_engine_schema_find(e, "Sensor", &sensor).status != DS_OK || !sensor)
        return spec_fail("find Sensor", r);
    fire_probe_t p = {0};
    r = ds_engine_set_stream_callback(e, fire_cb, &p);
    if (r.status != DS_OK) return spec_fail("set_stream_cb", r);

    if (has_sensor) {
        ds_slot_value_t sv[2];
        sv[0].kind = DS_SLOT_STRING; sv[0].v.s = "a";
        if (state_null) { sv[1].kind = DS_SLOT_NULL; }
        else            { sv[1].kind = DS_SLOT_FLOAT; sv[1].v.f = state_val; }
        r = ds_engine_assert(e, sensor, sv, 2, NULL);
        if (r.status != DS_OK) return spec_fail("assert sensor", r);
    }
    ds_slot_value_t tv[] = { { .kind = DS_SLOT_INT, .v.i = 1 } };
    r = ds_engine_assert(e, tick, tv, 1, NULL);
    if (r.status != DS_OK) return spec_fail("assert tick", r);
    r = ds_engine_pump(e);
    if (r.status != DS_OK) return spec_fail("pump", r);

    *out_emits = p.n_emit;
    ds_engine_free(e);
    return 0;
}

static int _neg_case(const char *what, bool has_sensor, bool state_null,
                     double state_val, int want)
{
    int emits = -1;
    if (run_negation(has_sensor, state_null, state_val, &emits)) return 1;
    if (emits != want) {
        fprintf(stderr, "FAIL: N1 %s: emits=%d want %d\n", what, emits, want);
        return 1;
    }
    return 0;
}

static int test_n1_negation_blocks_on_null(void)
{
    int f = 0;
    /* no sensor at all → nothing to block → "all cool" fires */
    f |= _neg_case("no-sensor",   false, false, 0.0,  1);
    /* a cool sensor (10 > 85 is false) → does not block → fires */
    f |= _neg_case("cool-sensor", true,  false, 10.0, 1);
    /* a hot sensor (90 > 85 is true) → blocks → does NOT fire */
    f |= _neg_case("hot-sensor",  true,  false, 90.0, 0);
    /* a null reading → blocks ([LNUL.4.7]) → does not fire */
    f |= _neg_case("null-sensor", true,  true,  0.0,  0);
    return f;
}

int main(void)
{
    int failed = 0;
    failed |= test_lnul_9_1__null_mutable_slot_round_trip();
    failed |= test_lnul_8_10__nullable_key_rejected_nonkey_substrate();
    failed |= test_lnul_3_1__null_in_nonnullable_rejected();
    failed |= test_lnul_3_4__root_null_json_is_the_canonical_null();
    failed |= test_wf5_eq_null_fires_on_null();
    failed |= test_wf6_eq_null_no_fire_on_present();
    failed |= test_wf3_gt_no_fire_on_null();
    failed |= test_wf1_gt_fires_on_present();
    failed |= test_coalesce_default_on_null();
    failed |= test_n1_negation_blocks_on_null();
    if (!failed) printf("test_null_spec: OK\n");
    return failed;
}

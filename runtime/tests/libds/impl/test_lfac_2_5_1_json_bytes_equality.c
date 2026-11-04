/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A Json slot compares by deep structural equality ([LFAC.2.5.1]) and a Bytes
 * slot by byte content ([LFAC.2.5.4]), in the no-op reassertion test and in
 * the identity key. Mercury's ds.fact slot_unchanged is `A = B` on a Json term
 * whose object members are sorted. Each no-op case has a control that must be
 * a change, so an equality that answers true for everything fails.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_register_schema, libds-internal */

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

static int g_retracts = 0;

static ds_result_t on_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void)e; (void)u;
    if (ev->kind == DS_EV_FACT_RETRACT) g_retracts++;
    return DS_OK_R;
}

static ds_json_t *json(const char *text)
{
    ds_json_t *t = NULL;
    CHECK_OK(ds_json_parse(text, strlen(text), &t), text);
    return t;
}

static ds_engine_t *new_engine(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (e != NULL)
        CHECK_OK(ds_engine_set_stream_callback(e, on_event, NULL), "stream cb");
    return e;
}

static uint64_t id_of(const ds_fact_t *f)
{
    uint64_t id = 0;
    if (f != NULL) (void)ds_fact_get_id(f, &id);
    return id;
}

/* Assert S(id: "a", doc: <text>, raw: <bytes>) and return the fact's id. */
static uint64_t assert_s(ds_engine_t *e, const ds_schema_t *s,
                         const char *doc, const uint8_t *raw, size_t raw_len)
{
    ds_json_t *tree = json(doc);
    ds_slot_value_t v[3];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_STRING; v[0].v.s = "a";
    v[1].kind = DS_SLOT_JSON;   v[1].v.json = tree;
    v[2].kind = DS_SLOT_BYTES;  v[2].v.bytes.data = raw;
    v[2].v.bytes.len = raw_len;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, s, v, 3, &f), doc);
    uint64_t id = id_of(f);
    ds_json_free(tree);       /* the engine cloned it ([NFCT.2.4]) */
    return id;
}

/* The no-op reassertion ([LFAC.2.5.1], [LFAC.2.5.4]). */
static void test_noop(void)
{
    ds_engine_t *e = new_engine();
    if (e == NULL) return;
    ds_slot_desc_t sd[3] = {
        { .name = "id",  .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
        { .name = "doc", .type = DS_SLOT_TYPE_JSON,   .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "raw", .type = DS_SLOT_TYPE_BYTES,  .identity_role = DS_IDENTITY_MUTABLE },
    };
    const ds_schema_t *s = NULL;
    CHECK_OK(ds_engine_register_schema(e, "S", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, sd, 3, &s), "register S");
    if (s == NULL) { ds_engine_free(e); return; }

    /* Two separate buffers with the same content: equality is by content. */
    uint8_t raw1[4] = { 'a', 'b', 0, 'c' };
    uint8_t raw2[4] = { 'a', 'b', 0, 'c' };
    uint8_t raw3[4] = { 'a', 'b', 0, 'd' };

    uint64_t id1 = assert_s(e, s, "{\"x\": 1, \"y\": [1, 2, {\"z\": null}]}", raw1, 4);
    g_retracts = 0;

    /* The same document with its keys in another order, and equal bytes from
       another buffer: a no-op. */
    uint64_t id2 = assert_s(e, s, "{\"y\": [1, 2, {\"z\": null}], \"x\": 1}", raw2, 4);
    CHECK(id2 == id1, "an equal Json (keys reordered) and equal Bytes reassert "
                      "keeps the fact: a no-op ([LFAC.2.5.1], [LFAC.2.5.4])");
    CHECK(g_retracts == 0, "the no-op emits no FACT_RETRACT");

    /* Controls: each a meaningful change. */
    uint64_t id3 = assert_s(e, s, "{\"y\": [1, 2, {\"z\": null}], \"x\": 2}", raw2, 4);
    CHECK(id3 != id1, "a different Json value is a change");
    uint64_t id4 = assert_s(e, s, "{\"y\": [1, 2, {\"z\": null}], \"x\": 2}", raw3, 4);
    CHECK(id4 != id3, "different Bytes content is a change");
    uint64_t id5 = assert_s(e, s, "{\"y\": [1, 2, {\"z\": null}], \"x\": 2.0}", raw3, 4);
    CHECK(id5 != id4, "1 and 1.0 are different Json kinds: a change");
    uint64_t id6 = assert_s(e, s, "{\"y\": [2, 1, {\"z\": null}], \"x\": 2.0}", raw3, 4);
    CHECK(id6 != id5, "an array is ordered: a change");
    CHECK(g_retracts == 4, "each of the four changes retracts the old fact");

    size_t n = 0;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
    CHECK(n == 1, "one live S throughout");
    printf("  no-op: ids %llu %llu | changes %llu %llu %llu %llu | retracts %d\n",
           (unsigned long long)id1, (unsigned long long)id2,
           (unsigned long long)id3, (unsigned long long)id4,
           (unsigned long long)id5, (unsigned long long)id6, g_retracts);
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* The identity key ([LFAC.1.7], [LFAC.2.5.4]): equal Json or Bytes keys are one
   fact, so a second assert is an upsert, not a second fact. */
static void test_identity(void)
{
    ds_engine_t *e = new_engine();
    if (e == NULL) return;
    ds_slot_desc_t sd[3] = {
        { .name = "k",   .type = DS_SLOT_TYPE_JSON,  .identity_role = DS_IDENTITY_KEY },
        { .name = "b",   .type = DS_SLOT_TYPE_BYTES, .identity_role = DS_IDENTITY_KEY },
        { .name = "n",   .type = DS_SLOT_TYPE_INT,   .identity_role = DS_IDENTITY_MUTABLE },
    };
    const ds_schema_t *s = NULL;
    CHECK_OK(ds_engine_register_schema(e, "K", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, sd, 3, &s), "register K");
    if (s == NULL) { ds_engine_free(e); return; }

    struct { const char *k; uint8_t b[2]; int64_t n; } rows[4] = {
        { "{\"a\": 1, \"b\": 2}", { 1, 2 }, 1 },
        { "{\"b\": 2, \"a\": 1}", { 1, 2 }, 2 },   /* same key: an upsert */
        { "{\"a\": 1, \"b\": 3}", { 1, 2 }, 3 },   /* another Json key */
        { "{\"b\": 2, \"a\": 1}", { 1, 3 }, 4 },   /* another Bytes key */
    };
    size_t counts[4] = { 0, 0, 0, 0 };
    for (int r = 0; r < 4; r++) {
        ds_json_t *tree = json(rows[r].k);
        uint8_t buf[2] = { rows[r].b[0], rows[r].b[1] };
        ds_slot_value_t v[3];
        memset(v, 0, sizeof(v));
        v[0].kind = DS_SLOT_JSON;  v[0].v.json = tree;
        v[1].kind = DS_SLOT_BYTES; v[1].v.bytes.data = buf; v[1].v.bytes.len = 2;
        v[2].kind = DS_SLOT_INT;   v[2].v.i = rows[r].n;
        ds_fact_t *f = NULL;
        CHECK_OK(ds_engine_assert(e, s, v, 3, &f), rows[r].k);
        ds_json_free(tree);
        CHECK_OK(ds_engine_fact_count(e, &counts[r]), "fact_count");
    }
    printf("  identity: live K after each assert: %zu %zu %zu %zu\n",
           counts[0], counts[1], counts[2], counts[3]);
    CHECK(counts[0] == 1, "first K");
    CHECK(counts[1] == 1, "an equal Json key (reordered) and equal Bytes key "
                          "is the same fact: an upsert ([LFAC.1.7])");
    CHECK(counts[2] == 2, "a different Json key is a second fact");
    CHECK(counts[3] == 3, "a different Bytes key is a third fact");
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

int main(void)
{
    test_noop();
    test_identity();
    if (failures) {
        fprintf(stderr, "test_lfac_2_5_1_json_bytes_equality: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_lfac_2_5_1_json_bytes_equality: OK\n");
    return 0;
}

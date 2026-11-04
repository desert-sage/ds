/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A fact wrapper owns its String and Bytes slots: libds.h makes `v.s` and
 * `v.bytes` engine-lifetime. Each test reads a slot back after the buffer it
 * was asserted or replayed from has been overwritten or freed.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/intern.h"
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

static const ds_slot_desc_t SLOTS[3] = {
    { .name = "label", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
    { .name = "blob",  .type = DS_SLOT_TYPE_BYTES,  .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "n",     .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_MUTABLE },
};

static ds_engine_t *new_engine_with_schema(const ds_schema_t **out_sc)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return NULL;
    CHECK_OK(ds_engine_register_schema(e, "Rec", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 3, out_sc), "register_schema");
    return e;
}

/* ---- 1. the wrapper must not alias the caller's buffer ------------------ */

static void test_slots_survive_caller_buffer_reuse(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine_with_schema(&sc);
    if (!e || !sc) { if (e) ds_engine_free(e); return; }

    /* Stack buffers, as a host decoding into scratch would use. */
    char    sbuf[32];
    uint8_t bbuf[8];
    memcpy(sbuf, "alpha", 6);
    memcpy(bbuf, "\x01\x02\x03\x04", 4);

    ds_slot_value_t vals[3];
    memset(vals, 0, sizeof(vals));
    vals[0].kind = DS_SLOT_STRING; vals[0].v.s = sbuf;
    vals[1].kind = DS_SLOT_BYTES;  vals[1].v.bytes.data = bbuf;
                                   vals[1].v.bytes.len  = 4;
    vals[2].kind = DS_SLOT_INT;    vals[2].v.i = 7;

    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, sc, vals, 3, &f), "assert");

    /* Scribble over both buffers — the host is entitled to. */
    memset(sbuf, 'X', sizeof(sbuf));
    memset(bbuf, 0xEE, sizeof(bbuf));

    ds_slot_value_t got;
    memset(&got, 0, sizeof(got));
    CHECK_OK(ds_fact_get_slot(f, 0, NULL, &got), "get_slot(label)");
    CHECK(got.kind == DS_SLOT_STRING, "label is STRING");
    CHECK(got.v.s != NULL && strcmp(got.v.s, "alpha") == 0,
          "label reads back as asserted, not as the scribbled buffer");

    memset(&got, 0, sizeof(got));
    CHECK_OK(ds_fact_get_slot(f, 1, NULL, &got), "get_slot(blob)");
    CHECK(got.kind == DS_SLOT_BYTES, "blob is BYTES");
    CHECK(got.v.bytes.len == 4, "blob length preserved");
    CHECK(got.v.bytes.data != NULL &&
          memcmp(got.v.bytes.data, "\x01\x02\x03\x04", 4) == 0,
          "blob reads back as asserted, not as the scribbled buffer");

    ds_engine_free(e);
}

/* ---- 2. a no-op reassert must not leak an intern reference -------------- */

static void test_noop_reassert_does_not_leak(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine_with_schema(&sc);
    if (!e || !sc) { if (e) ds_engine_free(e); return; }

    char a[16], b[16];
    memcpy(a, "same", 5);
    memcpy(b, "same", 5);          /* equal contents, DIFFERENT buffer */

    ds_slot_value_t v[3];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_STRING; v[0].v.s = a;
    v[1].kind = DS_SLOT_BYTES;  v[1].v.bytes.data = (const uint8_t *)"zz";
                                v[1].v.bytes.len  = 2;
    v[2].kind = DS_SLOT_INT;    v[2].v.i = 1;

    ds_fact_t *f1 = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 3, &f1), "assert #1");

    /* Reassert the identical fact from the other buffer: rete suppresses it
       (identity and slots equal) and returns the existing wrapper. */
    v[0].v.s = b;
    ds_fact_t *f2 = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 3, &f2), "assert #2 (no-op)");

    /* Not `f1 == f2`: the fact pool is LIFO, so a recycled address cannot
       tell the same wrapper from a new one. One live fact shows nothing was
       duplicated. */
    size_t nfacts = 0;
    CHECK_OK(ds_engine_fact_count(e, &nfacts), "fact_count after no-op");
    CHECK(nfacts == 1, "a no-op reassert leaves exactly one fact");

    /* Still readable, still correct, still not pointing at either buffer. */
    memset(a, 'X', sizeof(a));
    memset(b, 'Y', sizeof(b));
    ds_slot_value_t got;
    memset(&got, 0, sizeof(got));
    CHECK_OK(ds_fact_get_slot(f2, 0, NULL, &got), "get_slot after no-op");
    CHECK(got.v.s != NULL && strcmp(got.v.s, "same") == 0,
          "value survives a no-op reassert from a reused buffer");

    /* Retract, then the interned value must be gone: one acquire, one
       release. A leaked reference keeps the entry alive and findable. */
    CHECK_OK(ds_engine_retract(e, f2), "retract");
    const char *found = NULL;
    (void)ds_rete_intern_find(e->rete_engine->intern, "same", 4, &found);
    CHECK(found == NULL,
          "the interned String is released exactly once (no leaked reference)");

    ds_engine_free(e);
}

/* ---- 3. the engine keeps nothing pointing into a freed decode arena ----- */

/* Captures the replayed fact's String slot so it can be checked after the
   walk (the visitor must not mutate the engine, and need not here). */
typedef struct { char label[32]; uint32_t blob_len; uint8_t blob[8]; int seen; }
        grab_t;

static ds_result_t grab_visitor(const ds_fact_t *fact, void *user)
{
    grab_t *g = (grab_t *)user;
    ds_slot_value_t v;

    memset(&v, 0, sizeof(v));
    if (ds_fact_get_slot(fact, 0, NULL, &v).status == DS_OK
            && v.kind == DS_SLOT_STRING && v.v.s != NULL) {
        snprintf(g->label, sizeof(g->label), "%s", v.v.s);
    }
    memset(&v, 0, sizeof(v));
    if (ds_fact_get_slot(fact, 1, NULL, &v).status == DS_OK
            && v.kind == DS_SLOT_BYTES && v.v.bytes.data != NULL
            && v.v.bytes.len <= sizeof(g->blob)) {
        memcpy(g->blob, v.v.bytes.data, v.v.bytes.len);
        g->blob_len = (uint32_t)v.v.bytes.len;
    }
    g->seen++;
    return DS_OK_R;
}

static void test_replay_does_not_borrow_the_callers_arena(void)
{
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine_with_schema(&sc);
    if (!e || !sc) { if (e) ds_engine_free(e); return; }

    /* Source fact, so its typed body can be encoded (encode_fact_body takes a
       ds_fact_t, mirroring what a live recorder has to hand). */
    ds_slot_value_t v[3];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_STRING; v[0].v.s = "replayed";
    v[1].kind = DS_SLOT_BYTES;  v[1].v.bytes.data = (const uint8_t *)"\x09\x08";
                                v[1].v.bytes.len  = 2;
    v[2].kind = DS_SLOT_INT;    v[2].v.i = 42;
    ds_fact_t *src = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 3, &src), "assert source fact");

    ds_session_header_t h;
    memset(&h, 0, sizeof(h));
    CHECK_OK(ds_engine_get_session_header(e, &h), "session header");

    uint8_t stream[1024] = {0};   /* replay decodes the whole buffer */
    uint8_t body[256];
    size_t  used = 0, n = 0, blen = 0;
    CHECK_OK(ds_rfcs_encode_header(&h, stream, sizeof(stream), &n),
             "encode StreamHeader");
    used += n;
    /* Rec's announcement: a replay refuses a FactAssert no SchemaDef
       announced ([RFCS.5.4]). */
    CHECK_OK(ds_rfcs_encode_schema_def("Rec", stream + used,
                                       sizeof(stream) - used, &n),
             "encode Rec's SchemaDef");
    used += n;
    CHECK_OK(ds_rfcs_encode_fact_body(src, body, sizeof(body), &blen),
             "encode fact body");
    CHECK_OK(ds_rfcs_encode_fcem(1, "Rec", body, blen, 0, 0, 0, "",
                                 stream + used, sizeof(stream) - used, &n),
             "encode FactAssert");
    used += n;

    /* Replay into a second engine through a heap arena freed at once, then
       scribble the stream. */
    const ds_schema_t *sc2 = NULL;
    ds_engine_t *e2 = new_engine_with_schema(&sc2);
    if (!e2) { ds_engine_free(e); return; }

    size_t   arena_cap = 2 * used + 64;
    uint8_t *arena     = (uint8_t *)malloc(arena_cap);
    CHECK(arena != NULL, "arena alloc");
    if (arena) {
        ds_rfcs_replay_result_t rr;
        memset(&rr, 0, sizeof(rr));
        CHECK_OK(ds_rfcs_replay(e2, stream, used, arena, arena_cap, &rr),
                 "replay");
        CHECK(rr.asserts == 1, "one fact applied");
        memset(arena, 0xCD, arena_cap);   /* poison, then release */
        free(arena);
    }
    memset(stream, 0xAB, sizeof(stream)); /* and scribble the stream itself */

    size_t cnt = 0;
    CHECK_OK(ds_engine_fact_count(e2, &cnt), "fact_count");
    CHECK(cnt == 1, "one fact in WM after replay");

    grab_t g;
    memset(&g, 0, sizeof(g));
    CHECK_OK(ds_engine_for_each_fact(e2, NULL, grab_visitor, &g), "walk");
    CHECK(g.seen == 1, "visited the replayed fact");
    CHECK(strcmp(g.label, "replayed") == 0,
          "replayed String survives the freed decode arena");
    CHECK(g.blob_len == 2 && memcmp(g.blob, "\x09\x08", 2) == 0,
          "replayed Bytes survives the scribbled stream buffer");

    ds_engine_free(e2);
    ds_engine_free(e);
}

int main(void)
{
    test_slots_survive_caller_buffer_reuse();
    test_noop_reassert_does_not_leak();
    test_replay_does_not_borrow_the_callers_arena();

    if (failures) {
        fprintf(stderr, "test_slot_ownership: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_slot_ownership: OK\n");
    return 0;
}

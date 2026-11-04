/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NFCT.1.1] [RFCS.5.1] [RFCS.26.1] [RFCS.26.2]
 * The recorder writes its header and schema prelude when the schema set is
 * final ([RFCS.5.1], [NFCT.1.1]), with the host's cache seeds in that
 * prelude ([RFCS.26.1]).
 *
 * Schemas reach the engine until its first stream event, and a load is
 * refused after it. So a recording begun during setup writes nothing until
 * that event, then the StreamHeader and every schema the engine holds,
 * before the event's own atom. A recording begun after the first event
 * writes them at once.
 *
 * The schemas are registered through libds's internal entry point
 * (engine.h): the recorder announces whatever schemas the engine holds,
 * however they arrived.
 */
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_register_schema, libds-internal */
#include "rfcs/rfcs.h"
#include "dsc/pbf_reader.h"   /* test 7 walks the raw frames to move one */

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

typedef struct {
    uint8_t bytes[65536];
    size_t  len;
} capture_t;

static ds_result_t capture_sink(const uint8_t *bytes, size_t len, void *user)
{
    capture_t *c = (capture_t *)user;
    if (c->len + len > sizeof(c->bytes))
        return (ds_result_t){ DS_ERR_INVAL, "capture overflow" };
    memcpy(c->bytes + c->len, bytes, len);
    c->len += len;
    return (ds_result_t){ DS_OK, NULL };
}

/* The atoms of a captured stream, in order: each one's field number, and
   whether its body holds `needle`. Returns the count, or -1 if the stream
   does not read. */
#define MAX_ATOMS 64
typedef struct {
    uint32_t atom;
    int      names;
} atom_t;

static int read_atoms(const capture_t *c, const char *needle, atom_t *out)
{
    ds_rfcs_reader_t r;
    ds_rfcs_reader_init(&r, c->bytes, c->len);
    size_t nl = strlen(needle);
    int n = 0;
    for (;;) {
        uint32_t atom = 0;
        const uint8_t *body = NULL;
        size_t blen = 0;
        bool done = false;
        if (ds_rfcs_next(&r, &atom, &body, &blen, &done).status != DS_OK)
            return -1;
        if (done || n == MAX_ATOMS)
            return n;
        out[n].atom = atom;
        out[n].names = 0;
        for (size_t i = 0; nl > 0 && i + nl <= blen; i++)
            if (memcmp(body + i, needle, nl) == 0) { out[n].names = 1; break; }
        n++;
    }
}

static const ds_slot_desc_t ADAPTER[2] = {
    { .name = "dev", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
    { .name = "v",   .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_MUTABLE },
};

static ds_engine_t *new_engine(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return NULL;
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 1000), "clock_set");
    return e;
}

static ds_result_t assert_adapter(ds_engine_t *e, const ds_schema_t *sc,
                                  const char *dev, int64_t v)
{
    ds_slot_value_t vals[2];
    memset(vals, 0, sizeof(vals));
    vals[0].kind = DS_SLOT_STRING;
    vals[0].v.s = dev;
    vals[1].kind = DS_SLOT_INT;
    vals[1].v.i = v;
    ds_fact_t *f = NULL;
    return ds_engine_assert(e, sc, vals, 2, &f);
}

/* 1 and 2. Begun on a fresh engine: nothing before the first event; the
   schema registered after the recording began is in the prelude, ahead of the
   fact naming it; and the first event closes registration. */
static void test_prelude_waits_for_the_first_event(void)
{
    ds_engine_t *e = new_engine();
    if (!e)
        return;

    static capture_t cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t buf[16384];
    CHECK_OK(ds_rfcs_record_to(e, &rec, capture_sink, &cap, buf, sizeof(buf)),
             "record_to on a fresh engine");
    CHECK(cap.len == 0,
          "RFCS.5.1: nothing is written before the engine's first event");

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Adapter",
                                       DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       ADAPTER, 2, &sc),
             "registered after record_to, before the first event");
    CHECK(cap.len == 0, "a registration emits no event and writes nothing");

    CHECK_OK(assert_adapter(e, sc, "PRELUDE-dev", 1), "the first event");

    atom_t atoms[MAX_ATOMS];
    int n = read_atoms(&cap, "Adapter", atoms);
    CHECK(n > 0, "the recording reads");
    if (n > 0) {
        CHECK(atoms[0].atom == DS_ATOM_STREAM_HEADER, "the header comes first");
        CHECK(n > 1 && atoms[1].atom == DS_ATOM_SCHEMA_DEF && atoms[1].names,
              "RFCS.5.1: the schema registered after record_to is announced "
              "right after the header");
        int prelude_end = 1;
        while (prelude_end < n
               && (atoms[prelude_end].atom == DS_ATOM_SCHEMA_DEF
                   || atoms[prelude_end].atom == DS_ATOM_SLOT))
            prelude_end++;
        CHECK(prelude_end == 4, "one SchemaDef and its two SLOTs");
        int fcem = -1;
        for (int i = 0; i < n; i++)
            if (atoms[i].atom == DS_ATOM_FACT_ASSERT && atoms[i].names) {
                fcem = i;
                break;
            }
        CHECK(fcem >= prelude_end,
              "the fact naming the schema follows its announcement");
        for (int i = prelude_end; i < n; i++)
            CHECK(atoms[i].atom != DS_ATOM_SCHEMA_DEF,
                  "RFCS.5.1: no schema is announced after the prelude");
    }

    /* 2. The assert emitted the engine's first stream event, and no pump has
       run: a load is refused all the same, before its bytes are read. */
    size_t before = 0;
    CHECK_OK(ds_engine_schema_count(e, &before), "schema_count");
    static const uint8_t NOT_READ[1] = { 0 };
    ds_result_t r = ds_engine_load_dsc(e, NOT_READ, sizeof NOT_READ);
    CHECK(r.status == DS_ERR_STATE,
          "NFCT.1.1: a load after the first stream event, before any pump, is "
          "DS_ERR_STATE");
    size_t after = 0;
    CHECK_OK(ds_engine_schema_count(e, &after), "schema_count after");
    CHECK(after == before, "and the refused load registers nothing");

    ds_engine_set_stream_callback(e, NULL, NULL);
    CHECK_OK(rec.last, "the recorder had no error");
    ds_engine_free(e);
}

/* 3. Begun after the engine's first event: the set is final already, so the
   header and the prelude go out at once. */
static void test_prelude_at_once_after_an_event(void)
{
    ds_engine_t *e = new_engine();
    if (!e)
        return;
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Adapter",
                                       DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       ADAPTER, 2, &sc),
             "register before any event");
    CHECK_OK(ds_engine_pump(e), "the first event");

    static capture_t cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t buf[16384];
    CHECK_OK(ds_rfcs_record_to(e, &rec, capture_sink, &cap, buf, sizeof(buf)),
             "record_to after the first event");
    atom_t atoms[MAX_ATOMS];
    int n = read_atoms(&cap, "Adapter", atoms);
    CHECK(n == 4, "RFCS.5.1: the header and the prelude, written at once");
    if (n == 4) {
        CHECK(atoms[0].atom == DS_ATOM_STREAM_HEADER, "the header first");
        CHECK(atoms[1].atom == DS_ATOM_SCHEMA_DEF && atoms[1].names,
              "then the schema");
    }

    ds_engine_set_stream_callback(e, NULL, NULL);
    CHECK_OK(rec.last, "the recorder had no error");
    ds_engine_free(e);
}

/* 4. No event, no recording: the header waits for an event that never came. */
static void test_no_event_no_recording(void)
{
    ds_engine_t *e = new_engine();
    if (!e)
        return;

    static capture_t cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t buf[4096];
    CHECK_OK(ds_rfcs_record_to(e, &rec, capture_sink, &cap, buf, sizeof(buf)),
             "record_to");
    ds_engine_set_stream_callback(e, NULL, NULL);
    CHECK(cap.len == 0, "a recording over which no event happened is empty");
    CHECK_OK(rec.last, "and is no error");
    ds_engine_free(e);
}

/* Each atom of a captured stream, with its body, which points into the
   capture. Returns the count, or -1 if the stream does not read. */
typedef struct {
    uint32_t       atom;
    const uint8_t *body;
    size_t         len;
} body_atom_t;

static int read_bodies(const capture_t *c, body_atom_t *out)
{
    ds_rfcs_reader_t r;
    ds_rfcs_reader_init(&r, c->bytes, c->len);
    int n = 0;
    for (;;) {
        uint32_t atom = 0;
        const uint8_t *body = NULL;
        size_t blen = 0;
        bool done = false;
        if (ds_rfcs_next(&r, &atom, &body, &blen, &done).status != DS_OK)
            return -1;
        if (done || n == MAX_ATOMS)
            return n;
        out[n].atom = atom;
        out[n].body = body;
        out[n].len  = blen;
        n++;
    }
}

static int body_is(const body_atom_t *a, const uint8_t *want, size_t len)
{
    return a->len == len && memcmp(a->body, want, len) == 0;
}

static ds_result_t seed(ds_engine_t *e, const char *key, const char *json,
                        uint64_t ttl_ns)
{
    ds_json_t *v = NULL;
    ds_result_t r = ds_json_parse(json, strlen(json), &v);
    if (r.status != DS_OK)
        return r;
    r = ds_engine_cache_seed(e, key, v, ttl_ns);
    ds_json_free(v);
    return r;
}

/* The recording test 5 makes, for tests 5 and 7: Adapter registered, "zeta"
   seeded with 1 and no expiry, then "alpha" with "on" and a 5000 ns TTL, then
   one assert. */
static capture_t seeded_cap;

static void record_seeded(void)
{
    ds_engine_t *e = new_engine();
    if (!e)
        return;
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Adapter",
                                       DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       ADAPTER, 2, &sc), "register");
    CHECK_OK(seed(e, "zeta", "1", DS_CACHE_TTL_NONE), "seed zeta first");
    CHECK_OK(seed(e, "alpha", "\"on\"", 5000), "seed alpha second");
    static ds_rfcs_recorder_t rec;
    static uint8_t buf[16384];
    CHECK_OK(ds_rfcs_record_to(e, &rec, capture_sink, &seeded_cap, buf,
                               sizeof(buf)), "record_to");
    CHECK_OK(assert_adapter(e, sc, "dev", 1), "the first event");
    ds_engine_set_stream_callback(e, NULL, NULL);
    CHECK_OK(rec.last, "the recorder had no error");
    ds_engine_free(e);
}

/* 5. [RFCS.26.1]: one CacheSeed per seeded key, after the schema
   announcement and before the first event atom, ordered by key. The bodies
   are written out by hand: `key` = 1, `value_json` = 2, `deadline_ns` = 3,
   proto3's zero omitted.
     alpha  0A 05 "alpha"  12 04 "\"on\""  18 F0 2E   deadline 6000
     zeta   0A 04 "zeta"   12 01 "1"                  no expiry: no field 3
   The deadline is 6000: the mock clock reads 1000 at the engine's first
   sample, and a seed's 5000 ns TTL counts from that sample ([NLFC.9.4]). */
/* @spec [RFCS.26.1] */
static void test_rfcs_26_1__seeds_in_the_prelude_by_key(void)
{
    static const uint8_t ALPHA[] = {
        0x0A, 0x05, 'a', 'l', 'p', 'h', 'a',
        0x12, 0x04, '"', 'o', 'n', '"',
        0x18, 0xF0, 0x2E,
    };
    static const uint8_t ZETA[] = {
        0x0A, 0x04, 'z', 'e', 't', 'a',
        0x12, 0x01, '1',
    };
    body_atom_t atoms[MAX_ATOMS];
    int n = read_bodies(&seeded_cap, atoms);
    CHECK(n > 6, "the seeded recording reads");
    if (n <= 6)
        return;
    CHECK(atoms[0].atom == DS_ATOM_STREAM_HEADER
              && atoms[1].atom == DS_ATOM_SCHEMA_DEF
              && atoms[2].atom == DS_ATOM_SLOT && atoms[3].atom == DS_ATOM_SLOT,
          "the header, then the schema announcement");
    CHECK(atoms[4].atom == DS_ATOM_CACHE_SEED && body_is(&atoms[4], ALPHA,
                                                         sizeof ALPHA),
          "RFCS.26.1: alpha's CacheSeed first, its deadline as the cache holds "
          "it, though it was seeded second");
    CHECK(atoms[5].atom == DS_ATOM_CACHE_SEED && body_is(&atoms[5], ZETA,
                                                         sizeof ZETA),
          "RFCS.26.1: then zeta's, with no deadline");
    CHECK(atoms[6].atom == DS_ATOM_CLOCK_ADVANCE,
          "RFCS.26.1: the seeds come before the first event atom");
    for (int i = 7; i < n; i++)
        CHECK(atoms[i].atom != DS_ATOM_CACHE_SEED,
              "RFCS.26.1: no CacheSeed after the prelude");
}

/* 6. [RFCS.26.1]: a recorder attached after the engine's first stream event
   writes no CacheSeed, though the cache holds the host's seed. */
/* @spec [RFCS.26.1] */
static void test_rfcs_26_1__a_late_recorder_writes_no_seed(void)
{
    ds_engine_t *e = new_engine();
    if (!e)
        return;
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Adapter",
                                       DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       ADAPTER, 2, &sc), "register");
    CHECK_OK(seed(e, "k", "1", DS_CACHE_TTL_NONE), "a host seed");
    CHECK_OK(ds_engine_pump(e), "the first event");
    static capture_t cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t buf[16384];
    CHECK_OK(ds_rfcs_record_to(e, &rec, capture_sink, &cap, buf, sizeof(buf)),
             "record_to after the first event");
    body_atom_t atoms[MAX_ATOMS];
    int n = read_bodies(&cap, atoms);
    CHECK(n == 4, "the header and the schema prelude, and no CacheSeed");
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* Replay `bytes` into a fresh engine holding Adapter. */
static ds_result_t replay_into_fresh(const uint8_t *bytes, size_t len)
{
    ds_engine_t *e = new_engine();
    if (!e)
        return (ds_result_t){ DS_ERR_OOM, "engine" };
    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Adapter",
                                       DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       ADAPTER, 2, &sc), "register");
    static uint8_t strbuf[4096];
    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof res);
    ds_result_t r = ds_rfcs_replay(e, bytes, len, strbuf, sizeof strbuf, &res);
    ds_engine_free(e);
    return r;
}

/* 7. [RFCS.26.2]: a CacheSeed after an event atom, which no recorder writes,
   is DS_ERR_FS_DIVERGENCE. The recording of test 5 with its first CacheSeed
   moved to just after the first ClockAdvance; the frames are copied whole, so
   nothing else changes. The control: the unaltered recording replays with no
   refusal, so the refusal is the move's. */
/* @spec [RFCS.26.2] */
static void test_rfcs_26_2__a_seed_after_an_event_diverges(void)
{
    ds_result_t control = replay_into_fresh(seeded_cap.bytes, seeded_cap.len);
    CHECK_OK(control, "the unaltered recording replays");

    /* Each frame's extent, by its body's place: a frame ends where the next
       body's frame begins, so the reader walks the raw frames. */
    ds_pbf_atom_t f[MAX_ATOMS];
    int n = 0;
    for (size_t pos = 0; n < MAX_ATOMS
         && ds_pbf_next_atom(seeded_cap.bytes, seeded_cap.len, pos, &f[n])
                == DS_PBF_OK;
         pos = f[n].next, n++)
        ;
    int s = -1, t = -1;
    for (int i = 0; i < n; i++) {
        if (s < 0 && f[i].field == DS_ATOM_CACHE_SEED) s = i;
        if (t < 0 && f[i].field == DS_ATOM_CLOCK_ADVANCE) t = i;
    }
    CHECK(s >= 0 && t > s, "a CacheSeed precedes the first ClockAdvance");
    if (s < 0 || t <= s)
        return;
    size_t s_at  = s == 0 ? 0 : f[s - 1].next;
    size_t s_end = f[s].next, t_end = f[t].next;
    static capture_t moved;
    moved.len = 0;
    memcpy(moved.bytes, seeded_cap.bytes, s_at);
    moved.len = s_at;
    memcpy(moved.bytes + moved.len, seeded_cap.bytes + s_end, t_end - s_end);
    moved.len += t_end - s_end;
    memcpy(moved.bytes + moved.len, seeded_cap.bytes + s_at, s_end - s_at);
    moved.len += s_end - s_at;
    memcpy(moved.bytes + moved.len, seeded_cap.bytes + t_end,
           seeded_cap.len - t_end);
    moved.len += seeded_cap.len - t_end;
    CHECK(moved.len == seeded_cap.len, "the move keeps every byte");

    ds_result_t r = replay_into_fresh(moved.bytes, moved.len);
    CHECK(r.status == DS_ERR_FS_DIVERGENCE,
          "RFCS.26.2: a CacheSeed after an event atom diverges");
}

int main(void)
{
    test_prelude_waits_for_the_first_event();
    test_prelude_at_once_after_an_event();
    test_no_event_no_recording();
    record_seeded();
    test_rfcs_26_1__seeds_in_the_prelude_by_key();
    test_rfcs_26_1__a_late_recorder_writes_no_seed();
    test_rfcs_26_2__a_seed_after_an_event_diverges();

    if (failures) {
        fprintf(stderr, "test_rfcs_prelude: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_prelude: OK\n");
    return 0;
}

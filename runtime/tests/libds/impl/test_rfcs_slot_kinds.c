/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [RDSC.5.5.8] [RFCS.5.1]
 * A trace's Slot atoms carry the declared kind, the temporal kinds included
 * ([RFCS.5.1], [RDSC.5.5.8]). A schema with a Time, a Date and a Duration
 * slot is announced, and its Slot atoms are read back: kinds 8, 9 and 10.
 * One fact's FactAssert body shows the three values travel as their int64
 * (UTC ns, days since the epoch, ns), a negative day count included. The
 * negative Duration asserted is recorded as 0, the value working memory
 * holds ([NFCT.2.3]).
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_register_schema, libds-internal */
#include "rfcs/rfcs.h"
#include "slot.pb-c.h"

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

static uint8_t g_stream[8192];
static size_t  g_stream_len = 0;

static ds_result_t test_sink(const uint8_t *bytes, size_t len, void *user)
{
    (void)user;
    if (g_stream_len + len > sizeof(g_stream))
        return (ds_result_t){ DS_ERR_INVAL, "sink overflow" };
    memcpy(g_stream + g_stream_len, bytes, len);
    g_stream_len += len;
    return (ds_result_t){ DS_OK, NULL };
}

static const ds_slot_desc_t SLOTS[3] = {
    { .name = "seen", .type = DS_SLOT_TYPE_TIME,     .identity_role = DS_IDENTITY_KEY },
    { .name = "due",  .type = DS_SLOT_TYPE_DATE,     .identity_role = DS_IDENTITY_KEY },
    { .name = "span", .type = DS_SLOT_TYPE_DURATION, .identity_role = DS_IDENTITY_KEY },
};

static const Ds__V1__SlotKind WANT_KIND[3] = {
    DS__V1__SLOT_KIND__SLOT_KIND_TIME,
    DS__V1__SLOT_KIND__SLOT_KIND_DATE,
    DS__V1__SLOT_KIND__SLOT_KIND_DURATION,
};

/* 2026-10-11T00:00:00Z in UTC ns; a day count before the epoch; a negative
   Duration, stored and so recorded as 0: a Duration is never negative
   ([NFCT.2.3], [LTIM.1.3.1]). */
static const int64_t ASSERT_VALUE[3] = {
    INT64_C(1791676800000000000),
    INT64_C(-1),
    INT64_C(-5000000000),
};
static const int64_t WANT_VALUE[3] = {
    INT64_C(1791676800000000000),
    INT64_C(-1),
    INT64_C(0),
};

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return 1;

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "When", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 3, &sc),
             "register_schema with Time, Date and Duration slots");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 1000), "clock 1000");

    ds_rfcs_recorder_t rec;
    uint8_t recbuf[4096];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    ds_slot_value_t v[3];
    memset(v, 0, sizeof(v));
    for (int s = 0; s < 3; s++) {
        v[s].kind = DS_SLOT_INT;
        v[s].v.i  = ASSERT_VALUE[s];
    }
    ds_fact_t *fact = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 3, &fact), "assert a When");
    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_set_stream_callback(e, NULL, NULL);

    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
    uint32_t atom;
    const uint8_t *body;
    size_t blen;
    bool done = false;
    int slots_seen = 0;
    bool fcem_seen = false;

    for (;;) {
        ds_result_t r = ds_rfcs_next(&rd, &atom, &body, &blen, &done);
        CHECK_OK(r, "next atom");
        if (r.status != DS_OK || done) break;

        if (atom == DS_ATOM_SLOT) {
            Ds__V1__Slot *sl = ds__v1__slot__unpack(NULL, blen, body);
            CHECK(sl != NULL, "Slot body decodes");
            if (sl == NULL) continue;
            CHECK(sl->schema_name && strcmp(sl->schema_name, "When") == 0,
                  "Slot names its schema");
            if (slots_seen < 3) {
                CHECK(sl->slot_name
                          && strcmp(sl->slot_name, SLOTS[slots_seen].name) == 0,
                      "Slot slot_name in declaration order");
                if (sl->kind != WANT_KIND[slots_seen])
                    fprintf(stderr, "  slot %s: kind %d, want %d\n",
                            SLOTS[slots_seen].name, (int)sl->kind,
                            (int)WANT_KIND[slots_seen]);
                CHECK(sl->kind == WANT_KIND[slots_seen],
                      "Slot kind is the declared kind");
            }
            slots_seen++;
            ds__v1__slot__free_unpacked(sl, NULL);
        } else if (atom == DS_ATOM_FACT_ASSERT) {
            ds_rfcs_fcem_t fc;
            CHECK_OK(ds_rfcs_decode_fcem(body, blen, &fc), "decode FactAssert");
            ds_slot_value_t dv[3];
            char scratch[64];
            uint32_t dn = 0;
            CHECK_OK(ds_rfcs_decode_fact_body(sc, fc.fact, fc.fact_len, dv, 3,
                                              scratch, sizeof(scratch), &dn),
                     "decode FactAssert fact body");
            CHECK(dn == 3, "three slot values");
            for (uint32_t s = 0; s < dn && s < 3; s++) {
                CHECK(dv[s].kind == DS_SLOT_INT,
                      "a temporal value decodes Int-represented");
                CHECK(dv[s].v.i == WANT_VALUE[s],
                      "a temporal value survives the trace as its int64");
            }
            fcem_seen = true;
        }
    }

    CHECK(slots_seen == 3, "the schema announces exactly three Slot atoms");
    CHECK(fcem_seen, "the assert is recorded");

    ds_engine_free(e);

    if (failures) {
        fprintf(stderr, "test_rfcs_slot_kinds: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_rfcs_slot_kinds: OK\n");
    return 0;
}

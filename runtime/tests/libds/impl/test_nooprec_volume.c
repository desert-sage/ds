/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The stream volume a recorded no-op reassertion adds ([RFCS.6.7]). Each row
 * records a sensor series in full ("after"), and again with the unchanged
 * reports left out ("before"), which is the same input with no no-op atoms.
 * `sensor` is the key and `value` the payload, so a changed report is an
 * identity update ([RARC.5.2.5]: FactRetract + FactAssert) and an unchanged
 * one a no-op (one FactAssert). The duty cycle is swept.
 *
 * It asserts a bound, not a constant (the encoding is test_rfcs_codec's): the
 * no-op atoms are on the stream at scale ([LFST.12.8]), and the cost stays
 * under one change pair per no-op.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rfcs/rfcs.h"

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

/* Counting sink: the stream is never stored, so the series length is not
   bounded by a fixed buffer and the sweep can use a realistic report count. */
static size_t g_bytes = 0;

static ds_result_t count_sink(const uint8_t *bytes, size_t len, void *user)
{
    (void)bytes;
    (void)user;
    g_bytes += len;
    return (ds_result_t){ DS_OK, NULL };
}

static const ds_slot_desc_t SLOTS[2] = {
    { .name = "sensor", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
    { .name = "value",  .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_MUTABLE },
};

#define SENSORS 8
#define REPORTS 250

/* Both columns advance time per report, not per assert, so the two streams
   differ only by the no-op atoms. */
#define CLOCK_BASE_NS 1000000000ull
#define CLOCK_STEP_NS 1000000ull

/* Record SENSORS sensors reporting REPORTS times each, the value changing once
   every `period` reports. With skip_noops the unchanged reports are not
   asserted. Returns bytes, or 0 on setup failure. */
static size_t record_series(int period, bool skip_noops)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t       *e   = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || !e)
        return 0;

    const ds_schema_t *sc = NULL;
    if (ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  SLOTS, 2, &sc).status != DS_OK) {
        ds_engine_free(e);
        return 0;
    }

    /* Mock time: atoms carry a varint `ts`, whose width depends on its value,
       so under the live clock the period-1 control's two columns differ.
       clock_set after set_mode is required: switching to DS_CLOCK_MOCK seeds
       the mock clock from the live reading. */
    if (ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status != DS_OK
            || ds_engine_clock_set(e, CLOCK_BASE_NS).status != DS_OK) {
        ds_engine_free(e);
        return 0;
    }

    ds_rfcs_recorder_t rec;
    uint8_t            recbuf[4096];
    g_bytes = 0;
    if (ds_rfcs_record_to(e, &rec, count_sink, NULL, recbuf, sizeof(recbuf))
            .status != DS_OK) {
        ds_engine_free(e);
        return 0;
    }

    for (int r = 0; r < REPORTS; r++) {
        if (ds_engine_clock_set(e, CLOCK_BASE_NS + (uint64_t)r * CLOCK_STEP_NS)
                .status != DS_OK) {
            ds_engine_free(e);
            return 0;
        }
        /* A report is "changed" when it opens a new period. Report 0 is the
           first sighting of each sensor, so it is always asserted. */
        const bool changed = (r % period) == 0;
        if (skip_noops && !changed)
            continue;
        for (int s = 0; s < SENSORS; s++) {
            ds_slot_value_t v[2];
            memset(v, 0, sizeof(v));
            v[0].kind = DS_SLOT_INT;
            v[0].v.i  = s;
            v[1].kind = DS_SLOT_INT;
            v[1].v.i  = r / period;   /* constant within a period */
            ds_fact_t *f = NULL;
            if (ds_engine_assert(e, sc, v, 2, &f).status != DS_OK) {
                ds_engine_free(e);
                return 0;
            }
        }
    }

    ds_engine_set_stream_callback(e, NULL, NULL);
    const size_t total = g_bytes;
    CHECK(rec.last.status == DS_OK, "recorder had no error");
    ds_engine_free(e);
    return total;
}

int main(void)
{
    /* period 1 is the no-op-free control: every report changes the value, so
       the two columns must agree exactly. Anything else means the skip_noops
       stand-in is not measuring what it claims to. */
    static const int PERIODS[] = { 1, 2, 4, 10, 30 };

    printf("test_nooprec_volume: %d sensors x %d reports\n", SENSORS, REPORTS);
    printf("  period  no-op%%   before(B)    after(B)   ratio\n");

    for (size_t i = 0; i < sizeof(PERIODS) / sizeof(PERIODS[0]); i++) {
        const int    p      = PERIODS[i];
        const size_t before = record_series(p, true);
        const size_t after  = record_series(p, false);

        CHECK(before > 0 && after > 0, "series recorded");
        if (before == 0 || after == 0)
            continue;

        printf("  %6d  %5d%%  %10zu  %10zu   %5.2fx\n",
               p, 100 - (100 / p), before, after,
               (double)after / (double)before);

        if (p == 1) {
            CHECK(after == before,
                  "period 1 has no no-ops, so both columns must agree");
            continue;
        }

        /* [LFST.12.8]: no-ops are not suppressed. */
        CHECK(after > before, "recording no-ops grows the stream");

        /* A no-op FactAssert cannot exceed a change's FactRetract + FactAssert
           pair. */
        CHECK((double)after / (double)before < (double)p,
              "no-op cost stays under one change-pair per no-op");
    }

    if (failures) {
        fprintf(stderr, "test_nooprec_volume: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_nooprec_volume: OK\n");
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The four fault atoms reach a recording.
 *
 * Only BoundsError is driven through a live fault: a contract wm_max breach,
 * the contract set directly on the Rete engine. Its path is the raise,
 * `recorder_emit_fault`, the recorder's stream callback,
 * `ds_rfcs_encode_bnds` and the sink. ComputationError, TypeError and
 * EngineError are checked at the encoder only.
 *
 * These bodies have no decoder, so each field is shown to reach the wire by
 * encoding twice with that field changed and requiring the bytes to differ.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "rfcs/rfcs.h"
#include "engine.h"       /* ds_engine.rete_engine — the contract is set directly */
#include "rete/engine.h"  /* has_contract / contract_wm_max */

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

/* ---- the recording sink ------------------------------------------------ */

static uint8_t g_stream[16384];
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

/* How many atoms of field number `want` (DS_ATOM_*) the recorded stream
   carries, and the body length of the first one (0 when absent). */
static int count_atom(uint32_t want, size_t *first_body_len)
{
    int    n = 0;
    if (first_body_len) *first_body_len = 0;

    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, g_stream, g_stream_len);
    for (;;) {
        uint32_t       atom = 0;
        const uint8_t *body = NULL;
        size_t         blen = 0;
        bool           done = false;
        CHECK_OK(ds_rfcs_next(&rd, &atom, &body, &blen, &done), "reader next");
        if (done)
            break;
        if (atom == want) {
            if (n == 0 && first_body_len) *first_body_len = blen;
            n++;
        }
    }
    return n;
}

/* ---- the wiring case: a wm_max breach becomes a BoundsError atom --------------- */

#define WM_CAP 2u

/* `level` is the key, so each value is its own fact and working memory
   reaches the cap. */
static const ds_slot_desc_t SLOTS[1] = {
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_KEY },
};

static void test_wm_max_breach_records_a_bnds(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t       *e   = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return;

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, SLOTS, 1, &sc),
             "register_schema");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "clock_set_mode");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock_set 0");

    CHECK(e->rete_engine != NULL, "the rete engine exists");
    if (e->rete_engine) {
        e->rete_engine->has_contract    = true;
        e->rete_engine->contract_wm_max = WM_CAP;
    }

    static ds_rfcs_recorder_t rec;
    static uint8_t            recbuf[8192];
    g_stream_len = 0;
    CHECK_OK(ds_rfcs_record_to(e, &rec, test_sink, NULL, recbuf, sizeof(recbuf)),
             "record_to");

    /* Fill working memory to the cap, then one past it. */
    ds_result_t last = DS_OK_R;
    for (unsigned i = 0; i < WM_CAP + 1u; i++) {
        ds_slot_value_t v[1];
        memset(v, 0, sizeof(v));
        v[0].kind = DS_SLOT_INT;
        v[0].v.i  = (int64_t)i;
        last = ds_engine_assert(e, sc, v, 1, NULL);
    }
    CHECK(last.status == DS_ERR_CONTRACT_BREACH,
          "the assert past the contract wm_max breached — premise of the rest");

    size_t blen = 0;
    CHECK(count_atom(DS_ATOM_BOUNDS_ERROR, &blen) >= 1,
          "the breach reached the recording as a BoundsError atom");
    CHECK(blen > 0, "and the BoundsError body is not empty");

    CHECK(rec.last.status == DS_OK, "recorder had no error of its own");
    ds_engine_set_stream_callback(e, NULL, NULL);
    ds_engine_free(e);
}

/* ---- the encoder half -------------------------------------------------- */

#define DIFFERS(a, alen, b, blen, msg)                                        \
    CHECK((alen) != (blen) || memcmp((a), (b), (alen)) != 0, (msg))

/* The reader finds each encoder's body under that encoder's atom. */
static void test_each_encoder_frames_its_own_atom(void)
{
    size_t n = 0;

    g_stream_len = 0;
    CHECK_OK(ds_rfcs_encode_eerr(1, 100, (uint32_t)DS_TRAP_DIVIDE_BY_ZERO,
                                 "r", 7, "S", "slot", 42, 3,
                                 g_stream, sizeof(g_stream), &n), "encode_eerr");
    g_stream_len = n;
    CHECK(count_atom(DS_ATOM_COMPUTATION_ERROR, NULL) == 1, "ComputationError frames as ComputationError");

    g_stream_len = 0;
    CHECK_OK(ds_rfcs_encode_type(2, 200, 5, "S", "slot", "Int", "r",
                                 g_stream, sizeof(g_stream), &n), "encode_type");
    g_stream_len = n;
    CHECK(count_atom(DS_ATOM_TYPE_ERROR, NULL) == 1, "TypeError frames as TypeError");

    g_stream_len = 0;
    CHECK_OK(ds_rfcs_encode_bnds(3, 300, (uint32_t)DS_CAP_WM_MAX, 64, 65,
                                 "r", 9,
                                 g_stream, sizeof(g_stream), &n), "encode_bnds");
    g_stream_len = n;
    CHECK(count_atom(DS_ATOM_BOUNDS_ERROR, NULL) == 1, "BoundsError frames as BoundsError");

    g_stream_len = 0;
    CHECK_OK(ds_rfcs_encode_engf(4, 400,
                                 (uint32_t)DS_ENGINE_FAULT_ARTEFACT_LIED, 6, "r",
                                 g_stream, sizeof(g_stream), &n), "encode_engf");
    g_stream_len = n;
    CHECK(count_atom(DS_ATOM_ENGINE_ERROR, NULL) == 1, "EngineError frames as EngineError");

    CHECK(count_atom(DS_ATOM_COMPUTATION_ERROR, NULL) == 0 &&
          count_atom(DS_ATOM_TYPE_ERROR, NULL) == 0 &&
          count_atom(DS_ATOM_BOUNDS_ERROR, NULL) == 0,
          "the EngineError stream carries no other fault atom");
}

static void test_every_field_reaches_the_wire(void)
{
    uint8_t a[512], b[512];
    size_t  alen = 0, blen = 0;

    CHECK_OK(ds_rfcs_encode_eerr(1, 100, (uint32_t)DS_TRAP_DIVIDE_BY_ZERO,
                                 "r", 7, "S", "slot", 42, 3,
                                 a, sizeof(a), &alen), "eerr a");
    CHECK_OK(ds_rfcs_encode_eerr(1, 100, (uint32_t)DS_TRAP_DOMAIN,
                                 "r", 7, "S", "slot", 42, 3,
                                 b, sizeof(b), &blen), "eerr kind");
    DIFFERS(a, alen, b, blen, "ComputationError: trap kind reaches the wire");

    CHECK_OK(ds_rfcs_encode_eerr(1, 100, (uint32_t)DS_TRAP_DIVIDE_BY_ZERO,
                                 "OTHER", 7, "S", "slot", 42, 3,
                                 b, sizeof(b), &blen), "eerr rule");
    DIFFERS(a, alen, b, blen, "ComputationError: rule_name reaches the wire");

    CHECK_OK(ds_rfcs_encode_eerr(1, 100, (uint32_t)DS_TRAP_DIVIDE_BY_ZERO,
                                 "r", 8, "S", "slot", 42, 3,
                                 b, sizeof(b), &blen), "eerr timetag");
    DIFFERS(a, alen, b, blen, "ComputationError: timetag reaches the wire");

    CHECK_OK(ds_rfcs_encode_eerr(1, 100, (uint32_t)DS_TRAP_DIVIDE_BY_ZERO,
                                 "r", 7, "S", "slot", 43, 3,
                                 b, sizeof(b), &blen), "eerr fact_id");
    DIFFERS(a, alen, b, blen, "ComputationError: fact_id reaches the wire");

    CHECK_OK(ds_rfcs_encode_type(2, 200, 5, "S", "slot", "Int", "r",
                                 a, sizeof(a), &alen), "type a");
    CHECK_OK(ds_rfcs_encode_type(2, 200, 5, "S", "slot", "Float", "r",
                                 b, sizeof(b), &blen), "type actual");
    DIFFERS(a, alen, b, blen, "TypeError: actual reaches the wire");

    CHECK_OK(ds_rfcs_encode_type(2, 200, 6, "S", "slot", "Int", "r",
                                 b, sizeof(b), &blen), "type node");
    DIFFERS(a, alen, b, blen, "TypeError: node_id reaches the wire");

    /* [LERR.9.11]: every fault names a rule, field 7. */
    CHECK_OK(ds_rfcs_encode_type(2, 200, 5, "S", "slot", "Int", "$beta_5",
                                 b, sizeof(b), &blen), "type rule");
    DIFFERS(a, alen, b, blen, "TypeError: rule_name reaches the wire");

    CHECK_OK(ds_rfcs_encode_bnds(3, 300, (uint32_t)DS_CAP_WM_MAX, 64, 65,
                                 "r", 9, a, sizeof(a), &alen), "bnds a");
    CHECK_OK(ds_rfcs_encode_bnds(3, 300, (uint32_t)DS_CAP_WM_MAX, 65, 64,
                                 "r", 9, b, sizeof(b), &blen), "bnds swap");
    DIFFERS(a, alen, b, blen,
            "BoundsError: limit and observed are distinct fields, not one value");

    CHECK_OK(ds_rfcs_encode_bnds(3, 300, (uint32_t)DS_CAP_AGENDA, 64, 65,
                                 "r", 9, b, sizeof(b), &blen), "bnds cap");
    DIFFERS(a, alen, b, blen, "BoundsError: cap reaches the wire");

    CHECK_OK(ds_rfcs_encode_engf(4, 400,
                                 (uint32_t)DS_ENGINE_FAULT_ARTEFACT_LIED, 6, "r",
                                 a, sizeof(a), &alen), "engf a");
    CHECK_OK(ds_rfcs_encode_engf(4, 400,
                                 (uint32_t)DS_ENGINE_FAULT_PATTERN_INDEX, 6, "r",
                                 b, sizeof(b), &blen), "engf fault");
    DIFFERS(a, alen, b, blen, "EngineError: fault reaches the wire");

    CHECK_OK(ds_rfcs_encode_engf(4, 400,
                                 (uint32_t)DS_ENGINE_FAULT_ARTEFACT_LIED, 7, "r",
                                 b, sizeof(b), &blen), "engf node");
    DIFFERS(a, alen, b, blen, "EngineError: node_id reaches the wire");

    /* [LERR.9.11]: every fault names a rule, field 5. */
    CHECK_OK(ds_rfcs_encode_engf(4, 400,
                                 (uint32_t)DS_ENGINE_FAULT_ARTEFACT_LIED, 6,
                                 "$engine", b, sizeof(b), &blen), "engf rule");
    DIFFERS(a, alen, b, blen, "EngineError: rule_name reaches the wire");

    /* All four encoders write seq alike; one check stands for them. */
    CHECK_OK(ds_rfcs_encode_engf(5, 400,
                                 (uint32_t)DS_ENGINE_FAULT_ARTEFACT_LIED, 6, "r",
                                 b, sizeof(b), &blen), "engf seq");
    DIFFERS(a, alen, b, blen, "EngineError: seq reaches the wire");
}

static void test_null_out_len_is_refused(void)
{
    uint8_t buf[64];
    CHECK(ds_rfcs_encode_eerr(1, 1, 0, "r", 0, "S", "s", 0, 0,
                              buf, sizeof(buf), NULL).status == DS_ERR_INVAL,
          "encode_eerr refuses a NULL out_len");
    CHECK(ds_rfcs_encode_type(1, 1, 0, "S", "s", "Int", "r",
                              buf, sizeof(buf), NULL).status == DS_ERR_INVAL,
          "encode_type refuses a NULL out_len");
    CHECK(ds_rfcs_encode_bnds(1, 1, 0, 0, 0, "r", 0,
                              buf, sizeof(buf), NULL).status == DS_ERR_INVAL,
          "encode_bnds refuses a NULL out_len");
    CHECK(ds_rfcs_encode_engf(1, 1, 0, 0, "r",
                              buf, sizeof(buf), NULL).status == DS_ERR_INVAL,
          "encode_engf refuses a NULL out_len");
}

int main(void)
{
    printf("=== test_rfcs_fault_record ===\n");
    test_wm_max_breach_records_a_bnds();
    test_each_encoder_frames_its_own_atom();
    test_every_field_reaches_the_wire();
    test_null_out_len_is_refused();
    if (failures) {
        fprintf(stderr, "test_rfcs_fault_record: %d FAILURE(S)\n", failures);
        return 1;
    }
    printf("=== test_rfcs_fault_record: ALL PASSED ===\n");
    return 0;
}

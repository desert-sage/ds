/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Where one host call breaks several refusals, the first in the clause's
 * order decides.
 *
 *   [NFCT.2.11] ds_engine_assert: halted, unknown schema, arity, slot kinds,
 *               NaN, Json limits, encoding, Date range, TimeZoneOffset row,
 *               TTL deadline, held seed deadline.
 *   [NLFC.9.6]  ds_engine_cache_seed: halted, window, TTL range, Json limit,
 *               encoding.
 *
 * One test per adjacent pair. Each input breaks exactly the two steps it is
 * named for, and must answer the earlier step's status with nothing asserted,
 * nothing recorded and the cache as it was. Each carries a control: the later
 * step's defect alone. Where a step judges slot values, the later step's
 * value sits in the earlier slot, so a runtime that judged slot by slot
 * rather than step by step fails.
 *
 * Two pairs cannot be built, in either runtime, and two bridges take their
 * place:
 *   - date_range_before_tz_row: the `TimeZoneOffset` schema has no `Date`
 *     slot ([LIMP.12.2]). encoding_before_tz_row joins step 7 to step 9.
 *   - tz_row_before_ttl_deadline: `TimeZoneOffset` is `logical` and
 *     ds_engine_assert takes no TTL, so step 10 never judges a row.
 *     tz_row_before_held_seed_deadline joins step 9 to step 11.
 * Steps 8, 10 and 11 all answer DS_ERR_TIME_RANGE, so their order among
 * themselves is not observable at this API.
 *
 * White-box in three places: the halt latch is set directly (`halted`), an
 * over-limit `Json` value is a tree whose node count is raised past
 * DS_JSON_MAX_NODES (no builder makes one), and the cache's key count is read.
 *
 * The Mercury runtime is held to the same pairs under the same labels
 * (runtime/mercury/test/test_ds.m, check_nfct_2_11_refusal_order).
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"          /* ds_engine_register_schema; `halted` */
#include "cache.h"           /* ds_cache_key_count */
#include "internal/json.h"   /* the tree's node count */

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

#define SEC_NS            1000000000ull
#define HOUR_NS           (3600ull * SEC_NS)
#define INT64_MAX_LESS_1S ((uint64_t) INT64_MAX - SEC_NS)
/* A day count no `Date` holds ([LTIM.1.2.2]). */
#define DAY_OUT_OF_RANGE  INT64_MAX
/* An overlong form: no well-formed UTF-8 ([LSTR.8.5]). */
#define ILL_FORMED        "\xC0\xAF"

/* `Mix`: d Date, s String, j Json, f Float, n Int. The order puts each later
   step's slot ahead of the earlier step's it is paired with. */
enum { MIX_D, MIX_S, MIX_J, MIX_F, MIX_N, MIX_SLOTS };

static const ds_slot_desc_t MIX[MIX_SLOTS] = {
    { .name = "d", .type = DS_SLOT_TYPE_DATE,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
    { .name = "s", .type = DS_SLOT_TYPE_STRING,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
    { .name = "j", .type = DS_SLOT_TYPE_JSON,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
    { .name = "f", .type = DS_SLOT_TYPE_FLOAT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
    { .name = "n", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

/* The built-in's shape ([LIMP.12.2]), as test_rete_time.c's pub_tzo. */
static const ds_slot_desc_t TZO[4] = {
    { .name = "zone",        .type = DS_SLOT_TYPE_STRING,
      .identity_role = DS_IDENTITY_KEY },
    { .name = "valid_from",  .type = DS_SLOT_TYPE_TIME,
      .identity_role = DS_IDENTITY_KEY },
    { .name = "valid_until", .type = DS_SLOT_TYPE_TIME,
      .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "offset_s",    .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_MUTABLE },
};

typedef struct {
    ds_engine_t       *e;
    const ds_schema_t *mix;
    const ds_schema_t *tzo;
    ds_json_t         *one;     /* a Json value within every limit */
    ds_json_t         *over;    /* one past DS_JSON_MAX_NODES */
    uint32_t           saved_nodes;
    int                events;
} rig_t;

static ds_result_t count_events(ds_engine_t *e, const ds_stream_ev_t *ev,
                                void *user)
{
    (void) e; (void) ev;
    (*(int *) user)++;
    return (ds_result_t){ DS_OK, NULL };
}

/* A fresh engine holding `Mix` (ttl 1 s) and `TimeZoneOffset`, a mock clock
   at `clock_ns`, and a stream counter. Nothing is asserted or seeded. */
static int rig_new(rig_t *g, uint64_t clock_ns)
{
    memset(g, 0, sizeof *g);
    ds_engine_config_t cfg = {0};
    if (ds_engine_new(&cfg, &g->e).status != DS_OK || g->e == NULL
        || ds_engine_register_schema(g->e, "Mix", DS_SCHEMA_LIFECYCLE_TTL,
                                     SEC_NS, MIX, MIX_SLOTS,
                                     &g->mix).status != DS_OK
        || ds_engine_register_schema(g->e, "TimeZoneOffset",
                                     DS_SCHEMA_LIFECYCLE_LOGICAL, 0, TZO, 4,
                                     &g->tzo).status != DS_OK
        || ds_engine_set_stream_callback(g->e, count_events,
                                         &g->events).status != DS_OK
        || ds_engine_clock_set_mode(g->e, DS_CLOCK_MOCK).status != DS_OK
        || ds_engine_clock_set(g->e, clock_ns).status != DS_OK
        || ds_json_new_int(1, &g->one).status != DS_OK
        || ds_json_new_int(1, &g->over).status != DS_OK) {
        fprintf(stderr, "FAIL: the rig could not be built\n");
        failures++;
        return 1;
    }
    g->saved_nodes = g->over->nodes;
    g->over->nodes = DS_JSON_MAX_NODES + 1;
    return 0;
}

static void rig_free(rig_t *g)
{
    if (g->over != NULL) g->over->nodes = g->saved_nodes;
    ds_json_free(g->over);
    ds_json_free(g->one);
    ds_engine_free(g->e);
}

/* Every slot of `Mix` admitted: the base each case breaks two steps of. */
static void mix_ok(const rig_t *g, ds_slot_value_t v[MIX_SLOTS])
{
    v[MIX_D] = (ds_slot_value_t){ .kind = DS_SLOT_INT,    .v.i = 0 };
    v[MIX_S] = (ds_slot_value_t){ .kind = DS_SLOT_STRING, .v.s = "x" };
    v[MIX_J] = (ds_slot_value_t){ .kind = DS_SLOT_JSON,   .v.json = g->one };
    v[MIX_F] = (ds_slot_value_t){ .kind = DS_SLOT_FLOAT,  .v.f = 1.0 };
    v[MIX_N] = (ds_slot_value_t){ .kind = DS_SLOT_INT,    .v.i = 1 };
}

static void tz_row(ds_slot_value_t v[4], const char *zone, int64_t from,
                   int64_t until)
{
    v[0] = (ds_slot_value_t){ .kind = DS_SLOT_STRING, .v.s = zone };
    v[1] = (ds_slot_value_t){ .kind = DS_SLOT_INT,    .v.i = from };
    v[2] = (ds_slot_value_t){ .kind = DS_SLOT_INT,    .v.i = until };
    v[3] = (ds_slot_value_t){ .kind = DS_SLOT_INT,    .v.i = 0 };
}

/* The assert is refused with `want` and records no event. On an engine that
   still answers, it also hands back no fact and leaves working memory empty;
   a halted engine answers neither question, and nothing here asks it to. */
static void expect_assert(rig_t *g, const char *label,
                          const ds_schema_t *schema,
                          const ds_slot_value_t *v, uint32_t n,
                          ds_status_t want)
{
    const int events0 = g->events;
    const bool halted = g->e->halted;
    ds_fact_t *fact = NULL;
    ds_fact_t **out = &fact;
    if (!halted) fact = (ds_fact_t *) &fact;  /* not NULL: the refusal clears it */
    else out = NULL;
    ds_result_t r = ds_engine_assert(g->e, schema, v, n, out);
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: status %d (%s), want %d\n", label,
                (int) r.status, r.detail ? r.detail : "", (int) want);
        failures++;
        return;
    }
    CHECK(g->events == events0, label);
    if (!halted) {
        size_t live = (size_t) -1;
        CHECK(fact == NULL, label);
        CHECK(ds_engine_fact_count(g->e, &live).status == DS_OK && live == 0,
              label);
    }
}

/* The seed is refused with `want` and the cache holds what it held. */
static void expect_seed(rig_t *g, const char *label, const char *key,
                        const ds_json_t *value, uint64_t ttl_ns,
                        ds_status_t want)
{
    const uint32_t keys0 = ds_cache_key_count(&g->e->cache);
    ds_result_t r = ds_engine_cache_seed(g->e, key, value, ttl_ns);
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: status %d (%s), want %d\n", label,
                (int) r.status, r.detail ? r.detail : "", (int) want);
        failures++;
        return;
    }
    CHECK(ds_cache_key_count(&g->e->cache) == keys0, label);
}

/* ================= [NFCT.2.11] ds_engine_assert ================= */

/* @spec [NFCT.2.11] -- steps 1 and 2: a halted engine handed a schema it
   does not hold. The schema is a second engine's, under a name this one does
   not hold, because only a foreign handle drives step 2 in libds. That is
   undefined behaviour ([IDAT.1.6]): this pins libds's own outcome of it, and
   no caller may rely on it. */
static void test_nfct_2_11__halted_before_unknown_schema(void)
{
    rig_t g, other;
    if (rig_new(&g, 0)) return;
    if (rig_new(&other, 0)) { rig_free(&g); return; }
    const ds_schema_t *stranger = NULL;
    if (ds_engine_register_schema(other.e, "Stranger",
                                  DS_SCHEMA_LIFECYCLE_TTL, SEC_NS, MIX,
                                  MIX_SLOTS, &stranger).status != DS_OK) {
        CHECK(0, "register Stranger");
    } else {
        ds_slot_value_t v[MIX_SLOTS];
        mix_ok(&g, v);
        expect_assert(&g, "control: unknown schema alone", stranger, v,
                      MIX_SLOTS, DS_ERR_SCHEMA_UNKNOWN);
        g.e->halted = true;
        expect_assert(&g, "halted before unknown schema", stranger, v,
                      MIX_SLOTS, DS_ERR_ENGINE_HALTED);
        g.e->halted = false;
    }
    rig_free(&other);
    rig_free(&g);
}

/* @spec [NFCT.2.11] -- steps 2 and 3. As above, only a foreign handle drives
   step 2 in libds. That is undefined behaviour ([IDAT.1.6]): this pins libds's
   own outcome of it, and no caller may rely on it. */
static void test_nfct_2_11__unknown_schema_before_arity(void)
{
    rig_t g, other;
    if (rig_new(&g, 0)) return;
    if (rig_new(&other, 0)) { rig_free(&g); return; }
    const ds_schema_t *stranger = NULL;
    if (ds_engine_register_schema(other.e, "Stranger",
                                  DS_SCHEMA_LIFECYCLE_TTL, SEC_NS, MIX,
                                  MIX_SLOTS, &stranger).status != DS_OK) {
        CHECK(0, "register Stranger");
    } else {
        ds_slot_value_t v[MIX_SLOTS];
        mix_ok(&g, v);
        expect_assert(&g, "control: arity alone", g.mix, v, MIX_SLOTS - 1,
                      DS_ERR_INVAL);
        expect_assert(&g, "unknown schema before arity", stranger, v,
                      MIX_SLOTS - 1, DS_ERR_SCHEMA_UNKNOWN);
    }
    rig_free(&other);
    rig_free(&g);
}

/* @spec [NFCT.2.11] -- steps 3 and 4: one value short, and a String where
   the `Date` goes. */
static void test_nfct_2_11__arity_before_kind(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    ds_slot_value_t v[MIX_SLOTS];
    mix_ok(&g, v);
    v[MIX_D] = (ds_slot_value_t){ .kind = DS_SLOT_STRING, .v.s = "x" };
    expect_assert(&g, "control: kind alone", g.mix, v, MIX_SLOTS,
                  DS_ERR_SLOT_TYPE_MISMATCH);
    expect_assert(&g, "arity before kind", g.mix, v, MIX_SLOTS - 1,
                  DS_ERR_INVAL);
    rig_free(&g);
}

/* @spec [NFCT.2.11] -- steps 4 and 5: a NaN in `f`, and a String in `n`,
   the later slot. */
static void test_nfct_2_11__kind_before_nan(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    ds_slot_value_t v[MIX_SLOTS];
    mix_ok(&g, v);
    v[MIX_F].v.f = (double) NAN;
    expect_assert(&g, "control: NaN alone", g.mix, v, MIX_SLOTS,
                  DS_ERR_NAN_REJECTED);
    v[MIX_N] = (ds_slot_value_t){ .kind = DS_SLOT_STRING, .v.s = "x" };
    expect_assert(&g, "kind before NaN", g.mix, v, MIX_SLOTS,
                  DS_ERR_SLOT_TYPE_MISMATCH);
    rig_free(&g);
}

/* @spec [NFCT.2.11] -- steps 5 and 6: an over-limit `Json` in `j`, and a
   NaN in `f`, the later slot. */
static void test_nfct_2_11__nan_before_json_limit(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    ds_slot_value_t v[MIX_SLOTS];
    mix_ok(&g, v);
    v[MIX_J].v.json = g.over;
    expect_assert(&g, "control: Json limit alone", g.mix, v, MIX_SLOTS,
                  DS_ERR_JSON_LIMIT);
    v[MIX_F].v.f = (double) NAN;
    expect_assert(&g, "NaN before Json limit", g.mix, v, MIX_SLOTS,
                  DS_ERR_NAN_REJECTED);
    rig_free(&g);
}

/* @spec [NFCT.2.11] -- steps 6 and 7: ill-formed text in `s`, and an
   over-limit `Json` in `j`, the later slot. */
static void test_nfct_2_11__json_limit_before_encoding(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    ds_slot_value_t v[MIX_SLOTS];
    mix_ok(&g, v);
    v[MIX_S].v.s = ILL_FORMED;
    expect_assert(&g, "control: encoding alone", g.mix, v, MIX_SLOTS,
                  DS_ERR_ENCODING);
    v[MIX_J].v.json = g.over;
    expect_assert(&g, "Json limit before encoding", g.mix, v, MIX_SLOTS,
                  DS_ERR_JSON_LIMIT);
    rig_free(&g);
}

/* @spec [NFCT.2.11] -- steps 7 and 8: a `Date` out of range in `d`, and
   ill-formed text in `s`, the later slot. */
static void test_nfct_2_11__encoding_before_date_range(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    ds_slot_value_t v[MIX_SLOTS];
    mix_ok(&g, v);
    v[MIX_D].v.i = DAY_OUT_OF_RANGE;
    expect_assert(&g, "control: Date range alone", g.mix, v, MIX_SLOTS,
                  DS_ERR_TIME_RANGE);
    v[MIX_S].v.s = ILL_FORMED;
    expect_assert(&g, "encoding before Date range", g.mix, v, MIX_SLOTS,
                  DS_ERR_ENCODING);
    rig_free(&g);
}

/* @spec [NFCT.2.11] -- steps 7 and 9, the bridge for the Date range and the
   row, which no input breaks together: an empty period whose zone is
   ill-formed. */
static void test_nfct_2_11__encoding_before_tz_row(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    ds_slot_value_t v[4];
    tz_row(v, "Asia/Tokyo", 100, 100);
    expect_assert(&g, "control: the row alone", g.tzo, v, 4, DS_ERR_INVAL);
    tz_row(v, ILL_FORMED, 100, 100);
    expect_assert(&g, "encoding before the row", g.tzo, v, 4,
                  DS_ERR_ENCODING);
    rig_free(&g);
}

/* @spec [NFCT.2.11] -- steps 9 and 11, the bridge for the row and the TTL
   deadline, which no input breaks together: seeded with 1 h at a mock clock
   of INT64_MAX - 1 s, this call's sample would fix the seed's deadline past
   the `Time` range ([NLFC.9.5]), and the row's period is empty. */
static void test_nfct_2_11__tz_row_before_held_seed_deadline(void)
{
    rig_t g;
    if (rig_new(&g, INT64_MAX_LESS_1S)) return;
    CHECK(ds_engine_cache_seed(g.e, "k", g.one, HOUR_NS).status == DS_OK,
          "seed k, ttl 1 h");
    ds_slot_value_t v[4];
    tz_row(v, "Asia/Tokyo", 0, 100);
    expect_assert(&g, "control: the held seed's deadline alone", g.tzo, v, 4,
                  DS_ERR_TIME_RANGE);
    tz_row(v, "Asia/Tokyo", 100, 100);
    expect_assert(&g, "the row before the held seed's deadline", g.tzo, v, 4,
                  DS_ERR_INVAL);
    rig_free(&g);
}

/* ================= [NLFC.9.6] ds_engine_cache_seed ================= */

/* Asserts an admitted `Mix`, the engine's first stream event: the seeding
   window closes ([NLFC.9.2]). */
static int close_window(rig_t *g)
{
    ds_slot_value_t v[MIX_SLOTS];
    mix_ok(g, v);
    if (ds_engine_assert(g->e, g->mix, v, MIX_SLOTS, NULL).status != DS_OK
        || g->events == 0) {
        fprintf(stderr, "FAIL: the window-closing assert\n");
        failures++;
        return 1;
    }
    return 0;
}

/* @spec [NLFC.9.6] -- steps 1 and 2. */
static void test_nlfc_9_6__halted_before_window(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    if (close_window(&g)) { rig_free(&g); return; }
    expect_seed(&g, "control: the window alone", "k", g.one,
                DS_CACHE_TTL_NONE, DS_ERR_STATE);
    g.e->halted = true;
    expect_seed(&g, "halted before the window", "k", g.one,
                DS_CACHE_TTL_NONE, DS_ERR_ENGINE_HALTED);
    g.e->halted = false;
    rig_free(&g);
}

/* @spec [NLFC.9.6] -- steps 2 and 3: a TTL of 2^63 ns. */
static void test_nlfc_9_6__window_before_ttl_range(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    expect_seed(&g, "control: the TTL range alone", "k", g.one,
                (uint64_t) INT64_MAX + 1u, DS_ERR_TIME_RANGE);
    if (close_window(&g)) { rig_free(&g); return; }
    expect_seed(&g, "the window before the TTL range", "k", g.one,
                (uint64_t) INT64_MAX + 1u, DS_ERR_STATE);
    rig_free(&g);
}

/* @spec [NLFC.9.6] -- steps 3 and 4. */
static void test_nlfc_9_6__ttl_range_before_json_limit(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    expect_seed(&g, "control: the Json limit alone", "k", g.over,
                DS_CACHE_TTL_NONE, DS_ERR_JSON_LIMIT);
    expect_seed(&g, "the TTL range before the Json limit", "k", g.over,
                (uint64_t) INT64_MAX + 1u, DS_ERR_TIME_RANGE);
    rig_free(&g);
}

/* @spec [NLFC.9.6] -- steps 4 and 5: an ill-formed key. */
static void test_nlfc_9_6__json_limit_before_encoding(void)
{
    rig_t g;
    if (rig_new(&g, 0)) return;
    expect_seed(&g, "control: encoding alone", ILL_FORMED, g.one,
                DS_CACHE_TTL_NONE, DS_ERR_ENCODING);
    expect_seed(&g, "the Json limit before encoding", ILL_FORMED, g.over,
                DS_CACHE_TTL_NONE, DS_ERR_JSON_LIMIT);
    rig_free(&g);
}

int main(void)
{
    printf("=== test_nfct_2_11_refusal_order ===\n");
    test_nfct_2_11__halted_before_unknown_schema();
    test_nfct_2_11__unknown_schema_before_arity();
    test_nfct_2_11__arity_before_kind();
    test_nfct_2_11__kind_before_nan();
    test_nfct_2_11__nan_before_json_limit();
    test_nfct_2_11__json_limit_before_encoding();
    test_nfct_2_11__encoding_before_date_range();
    test_nfct_2_11__encoding_before_tz_row();
    test_nfct_2_11__tz_row_before_held_seed_deadline();
    test_nlfc_9_6__halted_before_window();
    test_nlfc_9_6__window_before_ttl_range();
    test_nlfc_9_6__ttl_range_before_json_limit();
    test_nlfc_9_6__json_limit_before_encoding();
    if (failures) {
        fprintf(stderr, "test_nfct_2_11_refusal_order: %d FAILURE(S)\n",
                failures);
        return 1;
    }
    printf("=== test_nfct_2_11_refusal_order: ALL PASSED ===\n");
    return 0;
}

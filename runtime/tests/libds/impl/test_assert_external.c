/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [RFCS.24.1]
 * test_assert_external — ds_engine_assert_external ([NCBK.10.4], [RFCS.23.4],
 * [RFCS.23.7]).
 *
 * A fact leaves one engine as a FactExternal (ds_fact_external_pack, the bytes
 * a publish or a fact argument carries) and another engine asserts it. The
 * record carries no event_id ([RFCS.23.5]); the receiver gives every fact it
 * asserts its own, through the ordinary path.
 *
 *   1. A round trip: the record's fact and the fact it references both arrive,
 *      the reference resolved to the inlined copy, the values intact.
 *   2. [RFCS.23.7] step 1, a fact sent back to the engine that published it:
 *      the nested reference is EQUAL to a live fact, so it is that fact, not a
 *      key conflict (step 3).
 *   3. The same with a ttl reference, which has no key: a receiver that
 *      asserts the copy instead of reusing the live fact leaves two.
 *   4. Step 1 on a tier that holds an equal fact of its own: the reference is
 *      that fact.
 *   5. Step 3: a live fact with the reference's key and different values
 *      refuses the WHOLE record: nothing asserted, nothing replaced.
 *   6. One fact inlined twice in one record: the second copy is the first,
 *      not a conflict with it.
 *   7. [RFCS.23.4]: references nested 16 deep are accepted, 17 deep refused as
 *      DS_ERR_PARSE.
 *  7b. [NCBK.10.4]: a record nested 100 000 deep is refused the same
 *      way, before protobuf-c's unbounded unpack recurses on it; and one
 *      nested too deep under an undeclared schema is DS_ERR_PARSE, not
 *      DS_ERR_SCHEMA_UNKNOWN, as in the Mercury runtime.
 *   8. A schema the receiver does not declare: DS_ERR_SCHEMA_UNKNOWN; a schema
 *      whose shape differs: DS_ERR_SCHEMA_HASH_MISMATCH; bytes that are not a
 *      FactExternal: DS_ERR_PARSE.
 *   9. [LSTR.1.5]: a String or Json field holding U+0000 refuses the record
 *      as DS_ERR_PARSE, rather than arriving cut at the NUL.
 *  9b. LGRA.5.8.6: a received Json field's text limit is its own,
 *      106496 bytes: the host's 24576 and 24577 both arrive, 106496 is
 *      admitted, 106497 refused unread, and 16384 U+0001 (98306 bytes)
 *      held by one engine reaches another.
 *  9c. LGRA.5.8.7a: a Json value is written as one text, byte for byte the
 *      Mercury runtime's.
 *  9d. LGRA.5.8.8: a received Json field's -0.0 arrives as +0.0.
 *  10. RFCS.23.7: one FactExternal is one input. A call that asserts an
 *      inlined copy and the received fact samples the clock once: one TICK,
 *      and one clock on both FactAsserts, under a live clock.
 *  11. RFCS.23.2 / RFCS.23.3: a Time, Date and Duration slot cross as
 *      KIND_INT and arrive as their declared types; the schema_hash is the
 *      SHA-256 of a SchemaShape whose temporal slots set `temporal_kind`,
 *      checked against bytes written out by hand; and a receiver that
 *      declares one of them `Int` refuses the record as
 *      DS_ERR_SCHEMA_HASH_MISMATCH.
 * 11b. LTIM.1.2.2: a Date field outside the Date range refuses the
 *      record whole as DS_ERR_TIME_RANGE, the Ref it references included.
 *  12. RFCS.24.1: a delivery refused whole is not recorded. The
 *      recording is byte-identical across a key-conflict refusal, and a fresh
 *      engine replays it with no divergence.
 *  13. RFCS.23.6: no TTL travels. A fact the sender holds under its
 *      own 10 s schema with a 60 s per-emit override arrives under the
 *      receiver's 30 s schema: live at 30 s - 1 ns, gone at 30 s.
 *  14. LGRA.24.3: a first step that is an external delivery, refused
 *      by the `initial` block's cache bound, places nothing and records its
 *      sample alone; after the bound is raised the next step applies the
 *      block under its own sample, and the recording replays clean.
 *  15. LGRA.24.3 / LTIM.2.8.3: the block's DOMAIN fault, for a fact
 *      whose `ts` the wall clock cannot fill, is recorded after the first
 *      step's input -- a host assert's FactAssert, or a pump's PumpBoundary.
 *  16. RFCS.26.1 / RFCS.26.2: the host's cache seeds are in the
 *      prelude and the `initial` block's items are not; a fresh engine given
 *      only the stream replays to the same cache, and one whose cache bound
 *      refuses a recorded seed diverges.
 *  17. RFCS.24.2 through ds_rfcs_apply_external_assert, one recorded
 *      ExternalAssert applied alone: its fact_ids bind a later FactRetract on
 *      an engine whose ids differ from the recorder's; one fact_id too many
 *      is DS_ERR_FS_DIVERGENCE; a recorded ttl_ns sets the received fact's
 *      deadline; and short arrays and a malformed body apply nothing.
 *  18. RFCS.23.7: a target the delivery's own asserts remove reads as
 *      gone, whether an answer's supersede took it or a cascade did, and the
 *      recording replays. Run under ASan: the point is that nothing reads the
 *      removed wrapper.
 *  19. NCBK.10.4: a value over its slot's capacity, a malformed
 *      TimeZoneOffset and a TTL deadline out of range, each in a nested copy
 *      after another, refuse the record whole: no fact, no sample, no event, no
 *      BoundsError.
 *  20. RFCS.24.2: a delivery an inlined copy's propagation halts stops there,
 *      and its recording replays.
 *
 * Every refusal is checked for asserting nothing, which is the half a status
 * check alone cannot see.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "dispatcher.h"      /* ds_fact_external_pack (RFCS.23) is internal */
#include "rfcs/rfcs.h"       /* the recorder and replayer, for test 12 */
#include "rfcs/fact_external.pb-c.h"  /* tests 9b and 9c read and craft records */
#include "sha256.h"          /* test 11's hash vector, test 14's seal */
/* Test 14 builds a `.dsc` by hand, as test_dsc_basic.c does: the C harness
   cannot compile DS source. */
#include "engine.h"          /* engine->cache, for the cache's key count */
#include "cache.h"
#include "dsc/pbf_reader.h"
#include "dsc/pbf_writer.h"
#include "test_ds_version.h"
#include "header.pb-c.h"
#include "schema_logical.pb-c.h"
/* Test 18's cascade needs a rule, built directly as
   test_ncbk_2_12_firing_timetag.c builds one. */
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

#define TTL_NS 60000000000ull   /* 60 s: nothing expires during a test */

/* `Ref` (logical: key `id`, mutable `note`; or ttl with the same two slots)
   and, unless `ref_only`, `Main` (logical: key `k`, mutable `r` referring to
   a Ref, mutable `x`). `x_type` lets one engine declare `Main` with another
   shape. */
typedef struct {
    ds_engine_t       *e;
    const ds_schema_t *ref;
    const ds_schema_t *main;
} tier_t;

static ds_engine_t *engine_new(const char *run_id)
{
    ds_engine_t *e = NULL;
    ds_engine_config_t cfg = { .run_id = run_id };
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) return NULL;
    if (ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status != DS_OK) {
        ds_engine_free(e);
        return NULL;
    }
    return e;
}

static bool tier_new_as(tier_t *t, const char *run_id, bool ref_only,
                        ds_slot_type_t x_type, bool ref_ttl)
{
    memset(t, 0, sizeof(*t));
    t->e = engine_new(run_id);
    if (t->e == NULL) return false;
    const ds_identity_role_t key = ref_ttl ? DS_IDENTITY_UNSPECIFIED : DS_IDENTITY_KEY;
    const ds_identity_role_t mut = ref_ttl ? DS_IDENTITY_UNSPECIFIED : DS_IDENTITY_MUTABLE;
    ds_slot_desc_t rs[2] = {
        { .name = "id",   .type = DS_SLOT_TYPE_STRING, .identity_role = key },
        { .name = "note", .type = DS_SLOT_TYPE_STRING, .identity_role = mut },
    };
    if (ds_engine_register_schema(t->e, "Ref",
                                  ref_ttl ? DS_SCHEMA_LIFECYCLE_TTL
                                          : DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  ref_ttl ? TTL_NS : 0, rs, 2, &t->ref).status != DS_OK)
        return false;
    if (ref_only) return true;
    ds_slot_desc_t ms[3] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
        { .name = "r", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = t->ref,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "x", .type = x_type,              .identity_role = DS_IDENTITY_MUTABLE },
    };
    return ds_engine_register_schema(t->e, "Main", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     ms, 3, &t->main).status == DS_OK;
}

static bool tier_new(tier_t *t, const char *run_id, bool ref_only,
                     ds_slot_type_t x_type)
{
    return tier_new_as(t, run_id, ref_only, x_type, false);
}

static ds_result_t assert_ref(tier_t *t, const char *id, const char *note,
                              ds_fact_t **out)
{
    ds_slot_value_t v[2] = {
        { .kind = DS_SLOT_STRING, .v.s = id },
        { .kind = DS_SLOT_STRING, .v.s = note },
    };
    return ds_engine_assert(t->e, t->ref, v, 2, out);
}

static ds_result_t assert_main(tier_t *t, int64_t k, ds_fact_t *ref, double x,
                               ds_fact_t **out)
{
    ds_slot_value_t v[3] = {
        { .kind = DS_SLOT_INT,      .v.i   = k },
        { .kind = DS_SLOT_FACT_REF, .v.ref = ref },
        { .kind = DS_SLOT_FLOAT,    .v.f   = x },
    };
    return ds_engine_assert(t->e, t->main, v, 3, out);
}

static size_t fact_count(ds_engine_t *e)
{
    size_t n = 0;
    if (ds_engine_fact_count(e, &n).status != DS_OK) return (size_t) -1;
    return n;
}

typedef struct { const ds_fact_t *found; int n; } one_t;

static ds_result_t take_one(const ds_fact_t *fact, void *user)
{
    one_t *o = (one_t *) user;
    o->found = fact;
    o->n++;
    return DS_OK_R;
}

static const ds_fact_t *only_fact(ds_engine_t *e, const ds_schema_t *s)
{
    one_t o = { NULL, 0 };
    if (ds_engine_for_each_fact(e, s, take_one, &o).status != DS_OK || o.n != 1)
        return NULL;
    return o.found;
}

static int count_of(ds_engine_t *e, const ds_schema_t *s)
{
    one_t o = { NULL, 0 };
    if (ds_engine_for_each_fact(e, s, take_one, &o).status != DS_OK) return -1;
    return o.n;
}

/* The fact slot `i` of `f` refers to, or NULL. */
static const ds_fact_t *ref_of(const ds_fact_t *f, uint32_t i)
{
    const char *name = NULL;
    ds_slot_value_t v;
    if (f == NULL || ds_fact_get_slot(f, i, &name, &v).status != DS_OK
            || v.kind != DS_SLOT_FACT_REF)
        return NULL;
    return v.v.ref;
}

/* Tier A: Ref("r1", "hello") and Main(1, -> r1, 2.5), and Main packed. */
static bool publisher_as(tier_t *a, bool ref_ttl, ds_fact_t **ref_out,
                         uint8_t **bytes, size_t *len)
{
    if (!tier_new_as(a, "A", false, DS_SLOT_TYPE_FLOAT, ref_ttl)) return false;
    ds_fact_t *r = NULL, *m = NULL;
    if (assert_ref(a, "r1", "hello", &r).status != DS_OK || r == NULL) return false;
    if (assert_main(a, 1, r, 2.5, &m).status != DS_OK || m == NULL) return false;
    if (ref_out != NULL) *ref_out = r;
    return ds_fact_external_pack(m, bytes, len).status == DS_OK;
}

static bool publisher(tier_t *a, uint8_t **bytes, size_t *len)
{
    return publisher_as(a, false, NULL, bytes, len);
}

/* ---- 1 -------------------------------------------------------------------- */

/* @spec [NCBK.10.4] */
static void test_round_trip(void)
{
    tier_t a, b;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(tier_new(&b, "B", false, DS_SLOT_TYPE_FLOAT), "tier B");
    if (bytes == NULL || b.e == NULL) goto done;

    ds_result_t r = ds_engine_assert_external(b.e, bytes, len);
    CHECK(r.status == DS_OK, "B asserts A's Main");
    CHECK(fact_count(b.e) == 2, "the Main and the Ref it inlines");

    const ds_fact_t *m = only_fact(b.e, b.main);
    const ds_fact_t *rf = only_fact(b.e, b.ref);
    CHECK(m != NULL && rf != NULL, "one of each");
    if (m != NULL && rf != NULL) {
        const char *name = NULL;
        ds_slot_value_t v;
        CHECK(ds_fact_get_slot(m, 0, &name, &v).status == DS_OK
                  && v.kind == DS_SLOT_INT && v.v.i == 1, "Main.k == 1");
        CHECK(ref_of(m, 1) == rf, "Main.r refers to the inlined copy B asserted");
        CHECK(ds_fact_get_slot(m, 2, &name, &v).status == DS_OK
                  && v.kind == DS_SLOT_FLOAT && v.v.f == 2.5, "Main.x == 2.5");
        CHECK(ds_fact_get_slot(rf, 1, &name, &v).status == DS_OK
                  && v.kind == DS_SLOT_STRING && strcmp(v.v.s, "hello") == 0,
              "Ref.note == \"hello\"");
    }
done:
    ds_free(bytes);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* ---- 2, 3 ----------------------------------------------------------------- */

static void sent_back(bool ref_ttl)
{
    tier_t a;
    ds_fact_t *r0 = NULL;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    CHECK(publisher_as(&a, ref_ttl, &r0, &bytes, &len), "tier A packs its Main");
    if (bytes == NULL) goto done;

    ds_result_t r = ds_engine_assert_external(a.e, bytes, len);
    CHECK(r.status == DS_OK,
          "A takes its own Main back: the nested Ref is equal to a live one "
          "(step 1), not refused as a key conflict (step 3)");
    CHECK(fact_count(a.e) == 2, "no second Ref, and the Main is a no-op");
    CHECK(count_of(a.e, a.ref) == 1, "one Ref: the live one was reused");
    CHECK(ref_of(only_fact(a.e, a.main), 1) == r0,
          "the Main still refers to the Ref A asserted first");
done:
    ds_free(bytes);
    ds_engine_free(a.e);
}

/* @spec [RFCS.23.7] */
static void test_sent_back_resolves_by_equality(void)
{
    sent_back(false);
}

/* @spec [RFCS.23.7] */
static void test_sent_back_ttl_reference_is_not_copied(void)
{
    sent_back(true);
}

/* ---- 4 -------------------------------------------------------------------- */

/* @spec [RFCS.23.7] */
static void test_an_equal_fact_on_another_tier_is_that_fact(void)
{
    tier_t a, b;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(tier_new(&b, "B", false, DS_SLOT_TYPE_FLOAT), "tier B");
    if (bytes == NULL || b.e == NULL) goto done;
    ds_fact_t *own = NULL;
    CHECK(assert_ref(&b, "r1", "hello", &own).status == DS_OK && own != NULL,
          "B holds a Ref(\"r1\", \"hello\") of its own");

    CHECK(ds_engine_assert_external(b.e, bytes, len).status == DS_OK,
          "B asserts A's Main");
    CHECK(fact_count(b.e) == 2, "the Main, and B's own Ref");
    CHECK(ref_of(only_fact(b.e, b.main), 1) == own,
          "Main.r refers to B's own Ref: equal is the same fact");
done:
    ds_free(bytes);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* ---- 5 -------------------------------------------------------------------- */

/* @spec [NCBK.10.4] [RFCS.23.7] */
static void test_same_key_different_values_refuses_the_whole_record(void)
{
    tier_t a, c;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(tier_new(&c, "C", false, DS_SLOT_TYPE_FLOAT), "tier C");
    if (bytes == NULL || c.e == NULL) goto done;
    ds_fact_t *own = NULL;
    CHECK(assert_ref(&c, "r1", "other", &own).status == DS_OK && own != NULL,
          "C holds its own Ref(\"r1\", \"other\")");

    ds_result_t r = ds_engine_assert_external(c.e, bytes, len);
    CHECK(r.status == DS_ERR_FACT_REF_CONFLICT,
          "a live Ref with the key and a different note refuses it");
    CHECK(fact_count(c.e) == 1, "nothing asserted");
    const ds_fact_t *rf = only_fact(c.e, c.ref);
    if (rf != NULL) {
        const char *name = NULL;
        ds_slot_value_t v;
        CHECK(ds_fact_get_slot(rf, 1, &name, &v).status == DS_OK
                  && strcmp(v.v.s, "other") == 0, "and nothing replaced");
    } else {
        CHECK(false, "C's own Ref is still live");
    }
done:
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* ---- 6 -------------------------------------------------------------------- */

/* `Ref` as in tier_new, and `Pair` (logical: key `k`, mutable `a` and `b`,
   both referring to a Ref). */
static bool pair_tier(tier_t *t, const char *run_id, const ds_schema_t **pair)
{
    if (!tier_new(t, run_id, true, DS_SLOT_TYPE_FLOAT)) return false;
    ds_slot_desc_t ps[3] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
        { .name = "a", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = t->ref,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "b", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = t->ref,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    return ds_engine_register_schema(t->e, "Pair", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     ps, 3, pair).status == DS_OK;
}

/* @spec [RFCS.23.7] */
static void test_one_fact_inlined_twice_is_one_fact(void)
{
    tier_t a, b;
    const ds_schema_t *pa = NULL, *pb = NULL;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    CHECK(pair_tier(&a, "A", &pa), "tier A with Pair");
    CHECK(pair_tier(&b, "B", &pb), "tier B with Pair");
    if (a.e == NULL || b.e == NULL || pa == NULL || pb == NULL) goto done;

    ds_fact_t *r = NULL, *p = NULL;
    CHECK(assert_ref(&a, "r1", "hello", &r).status == DS_OK && r != NULL, "A's Ref");
    ds_slot_value_t v[3] = {
        { .kind = DS_SLOT_INT,      .v.i   = 7 },
        { .kind = DS_SLOT_FACT_REF, .v.ref = r },
        { .kind = DS_SLOT_FACT_REF, .v.ref = r },
    };
    CHECK(ds_engine_assert(a.e, pa, v, 3, &p).status == DS_OK && p != NULL,
          "A's Pair, both slots the one Ref");
    CHECK(p != NULL && ds_fact_external_pack(p, &bytes, &len).status == DS_OK,
          "the record inlines the Ref twice");
    if (bytes == NULL) goto done;

    CHECK(ds_engine_assert_external(b.e, bytes, len).status == DS_OK,
          "the second copy is the first, not a key conflict with it");
    CHECK(fact_count(b.e) == 2, "one Ref and the Pair");
    const ds_fact_t *pair = only_fact(b.e, pb);
    const ds_fact_t *rf   = only_fact(b.e, b.ref);
    CHECK(rf != NULL && ref_of(pair, 1) == rf && ref_of(pair, 2) == rf,
          "both slots refer to the one Ref B asserted");
done:
    ds_free(bytes);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* ---- 7 -------------------------------------------------------------------- */

/* N0 .. N17: N0 (logical, key `n`), and each Ni (logical, key `n`, mutable `r`
   referring to N(i-1)). Packing Ni inlines a chain whose deepest fact, N0, is
   at depth i. */
#define CHAIN 18
static const char *const N_NAMES[CHAIN] = {
    "N0", "N1", "N2", "N3", "N4", "N5", "N6", "N7", "N8", "N9",
    "N10", "N11", "N12", "N13", "N14", "N15", "N16", "N17",
};

static bool chain_engine(ds_engine_t **out, const char *run_id,
                         const ds_schema_t *s[CHAIN])
{
    *out = engine_new(run_id);
    if (*out == NULL) return false;
    for (int i = 0; i < CHAIN; i++) {
        ds_slot_desc_t d[2] = {
            { .name = "n", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
            { .name = "r", .type = DS_SLOT_TYPE_SCHEMA,
              .schema_ref = i > 0 ? s[i - 1] : NULL,
              .identity_role = DS_IDENTITY_MUTABLE },
        };
        if (ds_engine_register_schema(*out, N_NAMES[i], DS_SCHEMA_LIFECYCLE_LOGICAL,
                                      0, d, i > 0 ? 2u : 1u, &s[i]).status != DS_OK)
            return false;
    }
    return true;
}

/* @spec [NCBK.10.4] [RFCS.23.4] */
static void test_nesting_is_at_most_16_deep(void)
{
    ds_engine_t *a = NULL, *b = NULL, *c = NULL;
    const ds_schema_t *sa[CHAIN], *sb[CHAIN], *sc[CHAIN];
    ds_fact_t *f[CHAIN] = { 0 };
    uint8_t *b16 = NULL, *b17 = NULL;
    size_t   l16 = 0, l17 = 0;
    CHECK(chain_engine(&a, "A", sa), "the publisher's chain schemas");
    CHECK(chain_engine(&b, "B", sb), "receiver B");
    CHECK(chain_engine(&c, "C", sc), "receiver C");
    if (a == NULL || b == NULL || c == NULL) goto done;

    for (int i = 0; i < CHAIN; i++) {
        ds_slot_value_t v[2] = {
            { .kind = DS_SLOT_INT,      .v.i   = i },
            { .kind = DS_SLOT_FACT_REF, .v.ref = i > 0 ? f[i - 1] : NULL },
        };
        CHECK(ds_engine_assert(a, sa[i], v, i > 0 ? 2u : 1u, &f[i]).status == DS_OK
                  && f[i] != NULL, "a link of the chain");
        if (f[i] == NULL) goto done;
    }
    CHECK(ds_fact_external_pack(f[16], &b16, &l16).status == DS_OK, "N16 packs");
    CHECK(ds_fact_external_pack(f[17], &b17, &l17).status == DS_OK,
          "N17 packs: a writer writes a deeper chain as it is");
    if (b16 == NULL || b17 == NULL) goto done;

    CHECK(ds_engine_assert_external(b, b16, l16).status == DS_OK,
          "N0 at depth 16 is accepted");
    CHECK(fact_count(b) == 17, "N0 .. N16 asserted");
    CHECK(ds_engine_assert_external(c, b17, l17).status == DS_ERR_PARSE,
          "N0 at depth 17 refuses the record as malformed");
    CHECK(fact_count(c) == 0, "nothing asserted");
done:
    ds_free(b17);
    ds_free(b16);
    ds_engine_free(c);
    ds_engine_free(b);
    ds_engine_free(a);
}

/* 7b. [NCBK.10.4]: a record nested 100 000 deep is refused as
   DS_ERR_PARSE, at RFCS.23.4's depth, and asserts nothing.

   PATH PINNED: ds_engine_assert_external -> fx_deliver -> fx_scan_nul, which
   refuses before ds__v1__fact_external__unpack. protobuf-c recurses on
   Arg.fact with no limit, so a refusal left to the unpack or the plan is a
   stack overflow, not a status. What shows the walk refused the 100 000-deep
   record is that the call RETURNS at all: the status and its detail do not,
   since fx_plan_node refuses a record nested past FX_MAX_DEPTH with the same
   status and the same detail ("fact references nested too deep"). What shows
   the ORDER is the 17-deep `Nope` record below: the walk refuses it as
   DS_ERR_PARSE before the plan would refuse its undeclared schema as
   DS_ERR_SCHEMA_UNKNOWN ([STYL.5.10.8]).

   The bytes are written by hand, innermost first, from the end of the buffer
   back. Packing them with protobuf-c would recurse as deep as unpacking
   does. */
#define DEEP 100000u

static size_t put_varint_before(uint8_t *buf, size_t pos, size_t v)
{
    uint8_t tmp[10];
    size_t  n = 0;
    do {
        tmp[n] = (uint8_t)(v & 0x7Fu);
        v >>= 7;
        if (v != 0u) tmp[n] |= 0x80u;
        n++;
    } while (v != 0u);
    pos -= n;
    memcpy(buf + pos, tmp, n);
    return pos;
}

static size_t put_before(uint8_t *buf, size_t pos, const uint8_t *b, size_t n)
{
    pos -= n;
    memcpy(buf + pos, b, n);
    return pos;
}

/* A FactExternal nested `wraps` deep, ending at buf[cap]: every level names
   the schema `schema` (its field 1, tag and length included) and holds one
   field `r` whose fact is the next, the innermost a bare `Ref`. Returns where
   it starts. */
static size_t deep_record(uint8_t *buf, size_t cap, unsigned wraps,
                          const uint8_t *schema, size_t schema_len)
{
    static const uint8_t ref_schema[] = { 0x0A, 0x03, 'R', 'e', 'f' };
    static const uint8_t name[]       = { 0x0A, 0x01, 'r' };  /* Arg.name */
    static const uint8_t fact_tag  = 0x4A;  /* Arg.fact, field 9, wire 2 */
    static const uint8_t field_tag = 0x1A;  /* FactExternal.fields, field 3 */
    size_t pos = put_before(buf, cap, ref_schema, sizeof ref_schema);
    for (unsigned i = 0; i < wraps; i++) {
        pos = put_varint_before(buf, pos, cap - pos);
        pos = put_before(buf, pos, &fact_tag, 1);
        pos = put_before(buf, pos, name, sizeof name);
        pos = put_varint_before(buf, pos, cap - pos);
        pos = put_before(buf, pos, &field_tag, 1);
        pos = put_before(buf, pos, schema, schema_len);
    }
    return pos;
}

/* @spec [NCBK.10.4] [RFCS.23.4] */
static void test_a_record_nested_past_the_bound_is_refused_unread(void)
{
    static const uint8_t main_schema[] = { 0x0A, 0x04, 'M', 'a', 'i', 'n' };
    static const uint8_t nope_schema[] = { 0x0A, 0x04, 'N', 'o', 'p', 'e' };
    const size_t cap = 24u * DEEP + 64u;
    uint8_t *buf = malloc(cap);
    tier_t b;
    memset(&b, 0, sizeof b);
    CHECK(buf != NULL, "the record's buffer");
    CHECK(tier_new(&b, "B", false, DS_SLOT_TYPE_FLOAT), "receiver B");
    if (buf == NULL || b.e == NULL) goto done;

    size_t pos = deep_record(buf, cap, DEEP, main_schema, sizeof main_schema);
    ds_result_t r = ds_engine_assert_external(b.e, buf + pos, cap - pos);
    CHECK(r.status == DS_ERR_PARSE, "a record 100 000 deep is refused as malformed");
    CHECK(r.detail != NULL && strstr(r.detail, "nested too deep") != NULL,
          "by the depth bound, before the unpack");
    CHECK(fact_count(b.e) == 0, "nothing asserted");

    /* Nested too deep under a schema B does not declare: the cap is checked
       over the whole record first, so DS_ERR_PARSE, not
       DS_ERR_SCHEMA_UNKNOWN. The Mercury runtime's test_ds pins the same. */
    pos = deep_record(buf, cap, 17u, nope_schema, sizeof nope_schema);
    r = ds_engine_assert_external(b.e, buf + pos, cap - pos);
    CHECK(r.status == DS_ERR_PARSE,
          "too deep under an unknown schema is refused as malformed");
    CHECK(fact_count(b.e) == 0, "nothing asserted");
done:
    free(buf);
    ds_engine_free(b.e);
}

/* ---- 8 -------------------------------------------------------------------- */

/* @spec [NCBK.10.4] */
static void test_refusals_assert_nothing(void)
{
    tier_t a, only_ref, other_shape;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(tier_new(&only_ref, "D", true, DS_SLOT_TYPE_FLOAT), "a tier with no Main");
    CHECK(tier_new(&other_shape, "E", false, DS_SLOT_TYPE_INT),
          "a tier whose Main.x is an Int");
    if (bytes == NULL || only_ref.e == NULL || other_shape.e == NULL) goto done;

    CHECK(ds_engine_assert_external(only_ref.e, bytes, len).status
              == DS_ERR_SCHEMA_UNKNOWN, "a schema it does not declare");
    CHECK(fact_count(only_ref.e) == 0, "nothing asserted, the Ref included");

    CHECK(ds_engine_assert_external(other_shape.e, bytes, len).status
              == DS_ERR_SCHEMA_HASH_MISMATCH, "a schema of another shape");
    CHECK(fact_count(other_shape.e) == 0, "nothing asserted, the Ref included");

    static const uint8_t junk[] = { 0xFF, 0xFF, 0xFF, 0xFF };
    CHECK(ds_engine_assert_external(other_shape.e, junk, sizeof junk).status
              == DS_ERR_PARSE, "bytes that are not a FactExternal");
    CHECK(fact_count(other_shape.e) == 0, "nothing asserted");
done:
    ds_free(bytes);
    ds_engine_free(other_shape.e);
    ds_engine_free(only_ref.e);
    ds_engine_free(a.e);
}

/* ---- 9 -------------------------------------------------------------------- */

/* Find `pat` in `b` and zero the byte `at` past its start. A field's tag and
   length lead the pattern, so it names one field, not stray matching bytes. */
static bool patch_nul(uint8_t *b, size_t len, const uint8_t *pat, size_t plen,
                      size_t at)
{
    for (size_t i = 0; i + plen <= len; i++) {
        if (memcmp(b + i, pat, plen) == 0) { b[i + at] = 0u; return true; }
    }
    return false;
}

/* [LSTR.1.5]: a FactExternal whose String or Json field holds U+0000
   is refused whole as DS_ERR_PARSE, and nothing is asserted.

   The refusal is the receiver's raw pre-scan (`fx_scan_nul`): protobuf-c's
   string decode drops the length, so without it the String would arrive as
   "he" and the Json text as "12". */
static void test_a_nul_in_a_text_field_refuses_the_record(void)
{
    /* A String: Ref.note "heZlo" (field 5, length 5) becomes "he\0lo". */
    tier_t a, b;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    ds_fact_t *r = NULL, *m = NULL;
    CHECK(tier_new(&a, "A", false, DS_SLOT_TYPE_FLOAT), "tier A");
    CHECK(tier_new(&b, "B", false, DS_SLOT_TYPE_FLOAT), "tier B");
    if (a.e == NULL || b.e == NULL) goto done;
    CHECK(assert_ref(&a, "r1", "heZlo", &r).status == DS_OK, "A's Ref");
    CHECK(assert_main(&a, 1, r, 2.5, &m).status == DS_OK, "A's Main");
    CHECK(m != NULL && ds_fact_external_pack(m, &bytes, &len).status == DS_OK,
          "A packs its Main");
    if (bytes == NULL) goto done;
    static const uint8_t note[] = { 0x2A, 0x05, 'h', 'e', 'Z', 'l', 'o' };
    CHECK(patch_nul(bytes, len, note, sizeof note, 4), "the note's bytes found");
    CHECK(ds_engine_assert_external(b.e, bytes, len).status == DS_ERR_PARSE,
          "a String field holding U+0000 is refused, not cut");
    CHECK(fact_count(b.e) == 0, "nothing asserted, the Ref included");
done:
    ds_free(bytes);
    ds_engine_free(b.e);
    ds_engine_free(a.e);

    /* A Json: Main.x 12345 (field 7, length 5) becomes "12\0" "45". */
    tier_t ja, jb;
    uint8_t *jbytes = NULL;
    size_t   jlen   = 0;
    ds_json_t *tree = NULL;
    CHECK(tier_new(&ja, "JA", false, DS_SLOT_TYPE_JSON), "tier JA");
    CHECK(tier_new(&jb, "JB", false, DS_SLOT_TYPE_JSON), "tier JB");
    if (ja.e == NULL || jb.e == NULL) goto jdone;
    CHECK(ds_json_new_int(12345, &tree).status == DS_OK, "the Json value");
    if (tree == NULL) goto jdone;
    ds_fact_t *jr = NULL, *jm = NULL;
    CHECK(assert_ref(&ja, "r1", "hello", &jr).status == DS_OK, "JA's Ref");
    ds_slot_value_t v[3] = {
        { .kind = DS_SLOT_INT,      .v.i    = 1 },
        { .kind = DS_SLOT_FACT_REF, .v.ref  = jr },
        { .kind = DS_SLOT_JSON,     .v.json = tree },
    };
    CHECK(ds_engine_assert(ja.e, ja.main, v, 3, &jm).status == DS_OK,
          "JA's Main");
    CHECK(jm != NULL && ds_fact_external_pack(jm, &jbytes, &jlen).status == DS_OK,
          "JA packs its Main");
    if (jbytes == NULL) goto jdone;
    static const uint8_t text[] = { 0x3A, 0x05, '1', '2', '3', '4', '5' };
    CHECK(patch_nul(jbytes, jlen, text, sizeof text, 4), "the Json text found");
    CHECK(ds_engine_assert_external(jb.e, jbytes, jlen).status == DS_ERR_PARSE,
          "a Json field holding U+0000 is refused, not read as its prefix");
    CHECK(fact_count(jb.e) == 0, "nothing asserted, the Ref included");
jdone:
    ds_json_free(tree);
    ds_free(jbytes);
    ds_engine_free(jb.e);
    ds_engine_free(ja.e);
}

/* LGRA.5.8.6: a received FactExternal's Json field has its own text limit,
   DS_JSON_MAX_FX_TEXT_BYTES, 106496 bytes, not the host's
   DS_JSON_MAX_TEXT_BYTES. That is the most text LGRA.5.8.7a writes
   for a value within the three tree limits, so a value one engine holds
   always reaches another. The Mercury runtime pins the same values
   (test_ds.m, "LGRA.5.8.6 a received Json field").

   PATH PINNED: ds_engine_assert_external -> fx_field's KIND_JSON arm ->
   ds_json_parse_capped(..., DS_JSON_MAX_FX_TEXT_BYTES). */

/* Tier A's Main with `x` the Json value `v`, packed by
   ds_fact_external_pack, the writer a publish and a fact argument use. */
static bool pack_json_main(tier_t *a, ds_json_t *v, uint8_t **bytes,
                           size_t *len)
{
    ds_fact_t *r = NULL, *m = NULL;
    if (assert_ref(a, "r1", "hello", &r).status != DS_OK) return false;
    ds_slot_value_t sv[3] = {
        { .kind = DS_SLOT_INT,      .v.i    = 1 },
        { .kind = DS_SLOT_FACT_REF, .v.ref  = r },
        { .kind = DS_SLOT_JSON,     .v.json = v },
    };
    if (ds_engine_assert(a->e, a->main, sv, 3, &m).status != DS_OK || m == NULL)
        return false;
    return ds_fact_external_pack(m, bytes, len).status == DS_OK;
}

/* `bytes` with Main.x's Json text replaced by `text`, re-packed. Unpacked
   and re-packed with protobuf-c, so every other field is the writer's: a
   text no engine would write, to reach the limit exactly. `*out` is
   malloc'd. */
static bool with_json_text(const uint8_t *bytes, size_t len, const char *text,
                           uint8_t **out, size_t *out_len)
{
    Ds__V1__FactExternal *fe = ds__v1__fact_external__unpack(NULL, len, bytes);
    if (fe == NULL) return false;
    bool ok = false;
    for (size_t i = 0; i < fe->n_fields; i++) {
        Ds__V1__Arg *f = fe->fields[i];
        if (strcmp(f->name, "x") != 0
                || f->value_case != DS__V1__ARG__VALUE_JSON_VALUE)
            continue;
        char *was = f->json_value;
        f->json_value = (char *) text;
        size_t n = ds__v1__fact_external__get_packed_size(fe);
        *out = malloc(n);
        if (*out != NULL) {
            *out_len = ds__v1__fact_external__pack(fe, *out);
            ok = *out_len == n;
        }
        f->json_value = was;
        break;
    }
    ds__v1__fact_external__free_unpacked(fe, NULL);
    return ok;
}

/* A value whose text is at or just past the host's limit, as A holds and
   packs it. One string, 4095 U+0001 then `tail`
   `a`s; the serializer writes each U+0001 as the six bytes `\u0001`, so the
   text is 24572 + tail bytes while the value is inside the tree limits
   (4099 + tail string bytes, one node, depth 1). A tail of 4 is the host's
   limit exactly and 5 one past it, and both arrive. What turns the second
   red: a receiver parsing at DS_JSON_MAX_TEXT_BYTES. */
static void host_limit_does_not_apply(size_t tail)
{
    static char s[4095 + 5];
    tier_t a, b;
    uint8_t   *bytes = NULL;
    size_t     len   = 0;
    ds_json_t *tree  = NULL;
    char      *text  = NULL;
    size_t     tlen  = 0;
    CHECK(tier_new(&a, "TA", false, DS_SLOT_TYPE_JSON), "tier TA");
    CHECK(tier_new(&b, "TB", false, DS_SLOT_TYPE_JSON), "tier TB");
    if (a.e == NULL || b.e == NULL) goto done;
    memset(s, 0x01, 4095);
    memset(s + 4095, 'a', tail);
    CHECK(ds_json_new_string(s, 4095 + tail, &tree).status == DS_OK,
          "the Json string");
    if (tree == NULL) goto done;
    CHECK(ds_json_serialize(tree, &text, &tlen).status == DS_OK
              && tlen == 24572 + tail,
          "the premise: the value's text is 24572 + tail bytes");
    CHECK(pack_json_main(&a, tree, &bytes, &len), "TA holds the value and packs it");
    if (bytes == NULL) goto done;
    CHECK(ds_engine_assert_external(b.e, bytes, len).status == DS_OK,
          tail == 4 ? "24576 bytes of Json text are admitted"
                    : "24577 bytes of Json text are admitted: the host's "
                      "limit is not the field's");
    CHECK(fact_count(b.e) == 2, "the Main and its Ref are asserted");
done:
    ds_free(text);
    ds_json_free(tree);
    ds_free(bytes);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* The field's limit itself, with crafted text: `1` and 106495 spaces is
   106496 bytes and admitted, as the Int 1; 106497 bytes of `x` are refused
   with DS_ERR_JSON_LIMIT and nothing asserted. The second is not JSON, so a
   parse that read it would refuse it as DS_ERR_PARSE: DS_ERR_JSON_LIMIT is
   the length, checked before a byte is read. What turns them red: a cap one
   byte either side of 106496. */
static void fx_limit_at(size_t n, bool admitted)
{
    tier_t a, b;
    uint8_t   *bytes = NULL, *crafted = NULL;
    size_t     len   = 0, clen = 0;
    ds_json_t *one   = NULL;
    char      *text  = malloc(n + 1);
    CHECK(text != NULL, "the text");
    CHECK(tier_new(&a, "FA", false, DS_SLOT_TYPE_JSON), "tier FA");
    CHECK(tier_new(&b, "FB", false, DS_SLOT_TYPE_JSON), "tier FB");
    if (text == NULL || a.e == NULL || b.e == NULL) goto done;
    if (admitted) {
        text[0] = '1';
        memset(text + 1, ' ', n - 1);
    } else {
        memset(text, 'x', n);
    }
    text[n] = '\0';
    CHECK(ds_json_new_int(1, &one).status == DS_OK, "the Json value");
    if (one == NULL) goto done;
    CHECK(pack_json_main(&a, one, &bytes, &len), "FA packs its Main");
    CHECK(bytes != NULL && with_json_text(bytes, len, text, &crafted, &clen),
          "the record, its Json text replaced");
    if (crafted == NULL) goto done;
    ds_result_t got = ds_engine_assert_external(b.e, crafted, clen);
    if (admitted) {
        CHECK(got.status == DS_OK, "106496 bytes of Json text are admitted");
        CHECK(fact_count(b.e) == 2, "the Main and its Ref are asserted");
        const ds_fact_t *m = only_fact(b.e, b.main);
        const char *name = NULL;
        ds_slot_value_t v;
        int64_t i = 0;
        CHECK(m != NULL && ds_fact_get_slot(m, 2, &name, &v).status == DS_OK
                  && v.kind == DS_SLOT_JSON
                  && ds_json_get_int(v.v.json, &i).status == DS_OK && i == 1,
              "Main.x is the Int 1");
    } else {
        CHECK(got.status == DS_ERR_JSON_LIMIT,
              "106497 bytes of Json text are DS_ERR_JSON_LIMIT, unread");
        CHECK(fact_count(b.e) == 0, "nothing asserted, the Ref included");
    }
done:
    free(crafted);
    ds_json_free(one);
    ds_free(bytes);
    free(text);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* The bound is reachable: 16384 U+0001, at the string-bytes limit and inside
   the other two, is 2 + 6 x 16384 = 98306 bytes of text. A holds it and
   packs it, over the host's limit and under the field's, and B receives it
   intact. */
static void the_bound_is_reachable(void)
{
    static char s[DS_JSON_MAX_STRING_BYTES];
    tier_t a, b;
    uint8_t   *bytes = NULL;
    size_t     len   = 0;
    ds_json_t *tree  = NULL;
    char      *text  = NULL;
    size_t     tlen  = 0;
    CHECK(tier_new(&a, "RA", false, DS_SLOT_TYPE_JSON), "tier RA");
    CHECK(tier_new(&b, "RB", false, DS_SLOT_TYPE_JSON), "tier RB");
    if (a.e == NULL || b.e == NULL) goto done;
    memset(s, 0x01, sizeof s);
    CHECK(ds_json_new_string(s, sizeof s, &tree).status == DS_OK,
          "16384 U+0001: the string-bytes limit, not past it");
    if (tree == NULL) goto done;
    CHECK(ds_json_serialize(tree, &text, &tlen).status == DS_OK && tlen == 98306,
          "the premise: its text is 98306 bytes");
    CHECK(pack_json_main(&a, tree, &bytes, &len), "RA holds the value and packs it");
    if (bytes == NULL) goto done;
    CHECK(ds_engine_assert_external(b.e, bytes, len).status == DS_OK,
          "RB receives it");
    const ds_fact_t *m = only_fact(b.e, b.main);
    const char *name = NULL, *got = NULL;
    size_t glen = 0;
    ds_slot_value_t v;
    CHECK(m != NULL && ds_fact_get_slot(m, 2, &name, &v).status == DS_OK
              && v.kind == DS_SLOT_JSON
              && ds_json_get_string(v.v.json, &got, &glen).status == DS_OK
              && glen == sizeof s && memcmp(got, s, sizeof s) == 0,
          "intact: 16384 U+0001");
done:
    ds_free(text);
    ds_json_free(tree);
    ds_free(bytes);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* @spec [LGRA.5.8.6] */
static void test_a_received_json_field_has_its_own_text_limit(void)
{
    CHECK(DS_JSON_MAX_FX_TEXT_BYTES
              == 6 * DS_JSON_MAX_STRING_BYTES + 32 * DS_JSON_MAX_NODES,
          "106496 = 6 x string bytes + 32 x nodes");
    host_limit_does_not_apply(4);
    host_limit_does_not_apply(5);
    fx_limit_at(DS_JSON_MAX_FX_TEXT_BYTES, true);
    fx_limit_at(DS_JSON_MAX_FX_TEXT_BYTES + 1, false);
    the_bound_is_reachable();
}

/* LGRA.5.8.7a: the one text a runtime writes for a Json value. An object
   built with its keys out of order is packed as a fact leaving the engine (ds_fact_external_pack), and the field's text is compared byte
   for byte with the text the Mercury runtime pins (test_ds.m,
   "LGRA.5.8.7a"): members by key bytes (`B` before `a`); `"`, `\`, U+0008,
   U+000C, U+000A, U+000D and U+0009 as their short forms; U+0001 and U+001F
   as `\u00` and two LOWERCASE hex digits; U+00E9 verbatim; no whitespace.

   PATH PINNED: ds_fact_external_pack -> fe_build's DS_SLOT_JSON arm ->
   ds_json_serialize. */
/* @spec [LGRA.5.8.7a] */
static void test_a_json_value_is_written_as_one_text(void)
{
    static const char want[] =
        "{\"B\":[true,null,1.5],"
        "\"a\":\"\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u001f\xc3\xa9\","
        "\"b\":-7}";
    static const char str[] = "\"\\\b\f\n\r\t\x01\x1f\xc3\xa9";
    tier_t a;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    ds_json_t *obj = NULL, *b = NULL, *s = NULL, *arr = NULL;
    ds_json_t *t = NULL, *n = NULL, *f = NULL;
    Ds__V1__FactExternal *fe = NULL;
    CHECK(tier_new(&a, "WA", false, DS_SLOT_TYPE_JSON), "tier WA");
    if (a.e == NULL) goto done;
    bool built =
        ds_json_new_object(&obj).status == DS_OK
        && ds_json_new_int(-7, &b).status == DS_OK
        && ds_json_object_set(obj, "b", 1, b).status == DS_OK
        && ds_json_new_string(str, sizeof str - 1, &s).status == DS_OK
        && ds_json_object_set(obj, "a", 1, s).status == DS_OK
        && ds_json_new_array(&arr).status == DS_OK
        && ds_json_new_bool(true, &t).status == DS_OK
        && ds_json_array_append(arr, t).status == DS_OK
        && ds_json_new_null(&n).status == DS_OK
        && ds_json_array_append(arr, n).status == DS_OK
        && ds_json_new_float(1.5, &f).status == DS_OK
        && ds_json_array_append(arr, f).status == DS_OK
        && ds_json_object_set(obj, "B", 1, arr).status == DS_OK;
    CHECK(built, "the object, keys b, a, B in that order");
    if (!built) goto done;
    CHECK(pack_json_main(&a, obj, &bytes, &len), "WA holds it and packs it");
    if (bytes == NULL) goto done;
    fe = ds__v1__fact_external__unpack(NULL, len, bytes);
    CHECK(fe != NULL, "the record unpacks");
    if (fe == NULL) goto done;
    const char *got = NULL;
    for (size_t i = 0; i < fe->n_fields; i++) {
        if (strcmp(fe->fields[i]->name, "x") == 0
                && fe->fields[i]->value_case == DS__V1__ARG__VALUE_JSON_VALUE)
            got = fe->fields[i]->json_value;
    }
    CHECK(got != NULL && strcmp(got, want) == 0,
          "Main.x's text is LGRA.5.8.7a's, byte for byte");
    if (got != NULL && strcmp(got, want) != 0)
        fprintf(stderr, "  got:  %s\n  want: %s\n", got, want);
done:
    if (fe != NULL) ds__v1__fact_external__free_unpacked(fe, NULL);
    ds_free(bytes);
    ds_json_free(obj);
    ds_engine_free(a.e);
}

/* LGRA.5.8.8 on the receive path: a received FactExternal whose Json
   field's text holds -0.0 arrives as +0.0, and the -1.5 beside it keeps its
   sign, so the fold is for zero only. The Mercury runtime pins the same
   (test_ds.m, "LGRA.5.8.8 a received Json field's -0.0").

   No engine writes -0.0 into Json text (a Json value holds none), so the
   record is A's packed Main with its Json text replaced.

   PATH PINNED: ds_engine_assert_external -> fx_field's KIND_JSON arm ->
   ds_json_parse_capped -> json_new_float_node's fold. */
static void test_a_received_zero_has_no_sign(void)
{
    static const char text[] = "{\"v\":-0.0,\"w\":-1.5}";
    tier_t a, b;
    uint8_t   *bytes = NULL, *crafted = NULL;
    size_t     len   = 0, clen = 0;
    ds_json_t *one   = NULL;
    CHECK(tier_new(&a, "ZA", false, DS_SLOT_TYPE_JSON), "tier ZA");
    CHECK(tier_new(&b, "ZB", false, DS_SLOT_TYPE_JSON), "tier ZB");
    if (a.e == NULL || b.e == NULL) goto done;
    CHECK(ds_json_new_int(1, &one).status == DS_OK, "the Json value");
    if (one == NULL) goto done;
    CHECK(pack_json_main(&a, one, &bytes, &len), "ZA packs its Main");
    CHECK(bytes != NULL && with_json_text(bytes, len, text, &crafted, &clen),
          "the record, its Json text `{\"v\":-0.0,\"w\":-1.5}`");
    if (crafted == NULL) goto done;
    CHECK(ds_engine_assert_external(b.e, crafted, clen).status == DS_OK,
          "ZB receives it");
    const ds_fact_t *m = only_fact(b.e, b.main);
    const char *name = NULL;
    ds_slot_value_t v;
    const ds_json_t *zv = NULL, *zw = NULL;
    double dv = 1.0, dw = 0.0;
    CHECK(m != NULL && ds_fact_get_slot(m, 2, &name, &v).status == DS_OK
              && v.kind == DS_SLOT_JSON
              && ds_json_object_get(v.v.json, "v", &zv).status == DS_OK
              && ds_json_object_get(v.v.json, "w", &zw).status == DS_OK
              && ds_json_get_float(zv, &dv).status == DS_OK
              && ds_json_get_float(zw, &dw).status == DS_OK,
          "Main.x holds the two Float leaves");
    CHECK(dv == 0.0 && !signbit(dv), "-0.0 arrived as +0.0");
    CHECK(dw == -1.5, "-1.5 kept its sign");
done:
    free(crafted);
    ds_json_free(one);
    ds_free(bytes);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* ---- 10 ------------------------------------------------------------------- */

/* The stream, as test 10 reads it: how many TICKs, and the clock of each
   FACT_ASSERT. */
typedef struct {
    int      ticks;
    int      asserts;
    uint64_t assert_clock[4];
} one_input_t;

static ds_result_t one_input_cb(ds_engine_t *e, const ds_stream_ev_t *ev,
                                void *user)
{
    (void) e;
    one_input_t *o = (one_input_t *) user;
    if (ev->kind == DS_EV_TICK) o->ticks++;
    if (ev->kind == DS_EV_FACT_ASSERT) {
        if (o->asserts < 4) o->assert_clock[o->asserts] = ev->clock_ns;
        o->asserts++;
    }
    return DS_OK_R;
}

/* RFCS.23.7: one FactExternal is ONE INPUT. B
   receives A's Main with its Ref inlined and new to B, so the call asserts
   two facts. Under the LIVE clock, which moves between any two reads, two
   samples would leave two TICKs and two clocks on the FactAsserts; one input
   samples once, so the stream carries one TICK and both facts share its
   clock. The wall clock is read in the same sample (ds_engine_clock_step), so
   one sample is also one `asserted_at`. */
/* @spec [RFCS.23.7] */
static void test_one_fact_external_is_one_input(void)
{
    tier_t a, b;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    one_input_t seen = { 0 };
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(tier_new(&b, "B", false, DS_SLOT_TYPE_FLOAT), "tier B");
    if (bytes == NULL || b.e == NULL) goto done;
    CHECK(ds_engine_clock_set_mode(b.e, DS_CLOCK_LIVE).status == DS_OK,
          "B runs on the live clock, which moves between reads");
    CHECK(ds_engine_set_stream_callback(b.e, one_input_cb, &seen).status == DS_OK,
          "B's stream is watched");

    CHECK(ds_engine_assert_external(b.e, bytes, len).status == DS_OK,
          "B asserts A's Main");
    CHECK(fact_count(b.e) == 2, "the Ref copy and the Main");
    CHECK(seen.asserts == 2, "a FactAssert for each fact");
    CHECK(seen.ticks == 1, "one TICK for the call: one input, one sample");
    CHECK(seen.asserts == 2 && seen.assert_clock[0] == seen.assert_clock[1],
          "both facts entered at the one sample");
done:
    ds_free(bytes);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* ---- 11 ------------------------------------------------------------------- */

/* `Stamp` (logical: key `k` Int, mutable `seen`, `day` and `span`), with
   `seen` declared `seen_type` so one tier can declare it Int. The names are
   134_temporal_external.ds's (`at` is a reserved word, [LLEX.9.5]). */
static bool stamp_engine(ds_engine_t **out, const char *run_id,
                         ds_slot_type_t seen_type, const ds_schema_t **stamp)
{
    *out = engine_new(run_id);
    if (*out == NULL) return false;
    ds_slot_desc_t d[4] = {
        { .name = "k",    .type = DS_SLOT_TYPE_INT,      .identity_role = DS_IDENTITY_KEY },
        { .name = "seen", .type = seen_type,             .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "day",  .type = DS_SLOT_TYPE_DATE,     .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "span", .type = DS_SLOT_TYPE_DURATION, .identity_role = DS_IDENTITY_MUTABLE },
    };
    return ds_engine_register_schema(*out, "Stamp", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                     0, d, 4, stamp).status == DS_OK;
}

/* Stamp's SchemaShape, encoded by hand rather than by protobuf-c, so the
   vector does not share the writer's encoder (RFCS.23.3): the name, then
   each slot in byte order of name -- day, k, seen, span -- as SlotShape
   messages (field 2). Each SlotShape writes its name (field 1); kind
   KIND_INT (0), nullable false and an empty ref_schema are defaults and
   omitted; a temporal slot adds temporal_kind (field 5, varint):
   SLOT_KIND_TIME 8, _DATE 9, _DURATION 10. `k` is an Int and has no
   field 5. */
static const uint8_t STAMP_SHAPE[] = {
    0x0A, 0x05, 'S', 't', 'a', 'm', 'p',
    0x12, 0x07,  0x0A, 0x03, 'd', 'a', 'y',            0x28, 0x09,
    0x12, 0x03,  0x0A, 0x01, 'k',
    0x12, 0x08,  0x0A, 0x04, 's', 'e', 'e', 'n',       0x28, 0x08,
    0x12, 0x08,  0x0A, 0x04, 's', 'p', 'a', 'n',       0x28, 0x0A,
};

/* @spec [RFCS.23.2] [RFCS.23.3] */
static void test_temporal_slots_cross_as_int(void)
{
    ds_engine_t *a = NULL, *b = NULL, *c = NULL;
    const ds_schema_t *sa = NULL, *sb = NULL, *sc = NULL;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    CHECK(stamp_engine(&a, "A", DS_SLOT_TYPE_TIME, &sa), "the publisher's Stamp");
    CHECK(stamp_engine(&b, "B", DS_SLOT_TYPE_TIME, &sb), "receiver B: the same Stamp");
    CHECK(stamp_engine(&c, "C", DS_SLOT_TYPE_INT, &sc),
          "receiver C: Stamp with `seen` declared Int");
    if (a == NULL || b == NULL || c == NULL) goto done;

    /* 2023-11-14T22:13:20Z, that date, 90 s (RDSC.5.5.8's integers). */
    ds_fact_t *f = NULL;
    ds_slot_value_t v[4] = {
        { .kind = DS_SLOT_INT, .v.i = 1 },
        { .kind = DS_SLOT_INT, .v.i = INT64_C(1700000000000000000) },
        { .kind = DS_SLOT_INT, .v.i = 19675 },
        { .kind = DS_SLOT_INT, .v.i = INT64_C(90000000000) },
    };
    CHECK(ds_engine_assert(a, sa, v, 4, &f).status == DS_OK && f != NULL,
          "A asserts a Stamp");
    CHECK(f != NULL && ds_fact_external_pack(f, &bytes, &len).status == DS_OK,
          "a fact with temporal slots packs: each is KIND_INT");
    if (bytes == NULL) goto done;

    /* The hash vector. protobuf-c writes FactExternal's fields in number
       order, so the record opens with `schema` (field 1, "Stamp") and then
       `schema_hash` (field 2, 32 bytes). */
    uint8_t want[DS_SHA256_DIGEST_LEN];
    ds_sha256(STAMP_SHAPE, sizeof STAMP_SHAPE, want);
    CHECK(len > 9u + DS_SHA256_DIGEST_LEN
              && memcmp(bytes, STAMP_SHAPE, 7) == 0
              && bytes[7] == 0x12 && bytes[8] == DS_SHA256_DIGEST_LEN,
          "the record opens with its schema and a 32-byte schema_hash");
    CHECK(len > 9u + DS_SHA256_DIGEST_LEN
              && memcmp(bytes + 9, want, DS_SHA256_DIGEST_LEN) == 0,
          "schema_hash is the SHA-256 of the hand-encoded SchemaShape, "
          "temporal_kind set on seen, day and span");

    CHECK(ds_engine_assert_external(b, bytes, len).status == DS_OK,
          "B asserts A's Stamp");
    const ds_fact_t   *got = only_fact(b, sb);
    const ds_schema_t *gs  = NULL;
    CHECK(got != NULL && ds_fact_get_schema(got, &gs).status == DS_OK
              && gs != NULL, "one Stamp arrives");
    if (got != NULL && gs != NULL) {
        static const ds_slot_type_t declared[4] = {
            DS_SLOT_TYPE_INT, DS_SLOT_TYPE_TIME, DS_SLOT_TYPE_DATE,
            DS_SLOT_TYPE_DURATION,
        };
        for (uint32_t i = 0; i < 4; i++) {
            const char *name = NULL;
            ds_slot_value_t gv;
            ds_slot_desc_t  d;
            CHECK(ds_fact_get_slot(got, i, &name, &gv).status == DS_OK
                      && gv.kind == DS_SLOT_INT && gv.v.i == v[i].v.i,
                  "each slot arrives with its integer");
            CHECK(ds_schema_get_slot(gs, i, &d).status == DS_OK
                      && d.type == declared[i],
                  "and is read as its declared type");
        }
    }

    CHECK(ds_engine_assert_external(c, bytes, len).status
              == DS_ERR_SCHEMA_HASH_MISMATCH,
          "a receiver declaring `seen` Int has another shape, though both "
          "are KIND_INT");
    CHECK(fact_count(c) == 0, "nothing asserted");
done:
    ds_free(bytes);
    ds_engine_free(c);
    ds_engine_free(b);
    ds_engine_free(a);
}

/* ---- 11b ------------------------------------------------------------------ */

/* `bytes` with the Int field `name` set to `value`, re-packed with protobuf-c
   as with_json_text does: a record no engine would write, since a publisher
   cannot hold the value. `*out` is malloc'd. */
static bool with_int_field(const uint8_t *bytes, size_t len, const char *name,
                           int64_t value, uint8_t **out, size_t *out_len)
{
    Ds__V1__FactExternal *fe = ds__v1__fact_external__unpack(NULL, len, bytes);
    if (fe == NULL) return false;
    bool ok = false;
    for (size_t i = 0; i < fe->n_fields; i++) {
        Ds__V1__Arg *f = fe->fields[i];
        if (strcmp(f->name, name) != 0
                || f->value_case != DS__V1__ARG__VALUE_INT_VALUE)
            continue;
        f->int_value = value;
        size_t n = ds__v1__fact_external__get_packed_size(fe);
        *out = malloc(n);
        if (*out != NULL) {
            *out_len = ds__v1__fact_external__pack(fe, *out);
            ok = *out_len == n;
        }
        break;
    }
    ds__v1__fact_external__free_unpacked(fe, NULL);
    return ok;
}

/* [LTIM.1.2.2]: a Date field outside the Date
   range, days -106751 through 106751, refuses the record whole with
   DS_ERR_TIME_RANGE, and nothing is asserted. A packs Main(1, -> Ref r1,
   x = the last Date), which B receives; the same record with `x` set one past
   either end is refused by C.

   THE CODE PATH: fx_field's KIND_INT arm, in the plan, before anything is
   asserted. The second phase would assert the inlined Ref first and only then
   have ds_engine_assert refuse Main, with the same status, so
   `fact_count(c) == 0` is what shows the refusal came from the plan. */
static void test_a_date_outside_its_range_refuses_the_record(void)
{
    tier_t a, b, c;
    uint8_t *bytes = NULL, *past = NULL, *before = NULL;
    size_t   len = 0, plen = 0, blen = 0;
    CHECK(tier_new(&a, "DA", false, DS_SLOT_TYPE_DATE), "tier DA: Main.x a Date");
    CHECK(tier_new(&b, "DB", false, DS_SLOT_TYPE_DATE), "tier DB");
    CHECK(tier_new(&c, "DC", false, DS_SLOT_TYPE_DATE), "tier DC");
    if (a.e == NULL || b.e == NULL || c.e == NULL) goto done;

    ds_fact_t *r = NULL, *m = NULL;
    CHECK(assert_ref(&a, "r1", "hello", &r).status == DS_OK && r != NULL,
          "DA asserts Ref r1");
    ds_slot_value_t v[3] = {
        { .kind = DS_SLOT_INT,      .v.i   = 1 },
        { .kind = DS_SLOT_FACT_REF, .v.ref = r },
        { .kind = DS_SLOT_INT,      .v.i   = 106751 },
    };
    CHECK(r != NULL && ds_engine_assert(a.e, a.main, v, 3, &m).status == DS_OK
              && m != NULL,
          "DA asserts Main on the last Date, 2262-04-11");
    CHECK(m != NULL && ds_fact_external_pack(m, &bytes, &len).status == DS_OK,
          "and packs it");
    if (bytes == NULL) goto done;
    CHECK(ds_engine_assert_external(b.e, bytes, len).status == DS_OK,
          "DB receives the last Date");
    CHECK(fact_count(b.e) == 2, "Main and its Ref on DB");

    CHECK(with_int_field(bytes, len, "x", 106752, &past, &plen),
          "the record with x = 106752, 2262-04-12");
    CHECK(with_int_field(bytes, len, "x", -106752, &before, &blen),
          "the record with x = -106752, 1677-09-21");
    if (past == NULL || before == NULL) goto done;

    CHECK(ds_engine_assert_external(c.e, past, plen).status == DS_ERR_TIME_RANGE,
          "a Date past the last is DS_ERR_TIME_RANGE");
    CHECK(ds_engine_assert_external(c.e, before, blen).status == DS_ERR_TIME_RANGE,
          "a Date before the first is DS_ERR_TIME_RANGE");
    CHECK(fact_count(c.e) == 0, "nothing asserted, the Ref included");
done:
    free(before);
    free(past);
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* ---- 12 ------------------------------------------------------------------- */

/* Every byte the recorder writes, in order. The recorder only appends, so a
   recording that did not grow across a call is byte-identical across it. */
typedef struct {
    uint8_t bytes[8192];
    size_t  len;
} capture_t;

static ds_result_t capture_sink(const uint8_t *bytes, size_t len, void *user)
{
    capture_t *c = (capture_t *) user;
    if (c->len + len > sizeof c->bytes)
        return (ds_result_t){ DS_ERR_INVAL, "capture overflow" };
    memcpy(c->bytes + c->len, bytes, len);
    c->len += len;
    return DS_OK_R;
}

/* RFCS.24.1: a delivery RFCS.23.7 refuses whole is not
   recorded, and the refusal is the call's status (NCBK.10.4).

   C records a run around a key-conflict refusal of A's Main: C's own Ref
   ("r1", "other") holds the key the record's inlined Ref ("r1", "hello")
   needs. THE CODE PATH: ds_engine_assert_external's first phase, the plan
   (fx_plan_node, then fx_resolve on the inlined copy), returns
   DS_ERR_FACT_REF_CONFLICT before the delivery opens, so no clock sample, no
   FactAssert and no ExternalAssert reach the stream. The input after it is recorded as
   usual, and a fresh engine replays the whole recording with no divergence:
   two FactAsserts, two Refs. */
static void test_a_refused_delivery_records_nothing(void)
{
    tier_t a, c, r;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    static uint8_t            strbuf[1024];
    memset(&cap, 0, sizeof cap);
    memset(&r, 0, sizeof r);
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(tier_new(&c, "C", false, DS_SLOT_TYPE_FLOAT), "tier C");
    CHECK(tier_new(&r, "C", false, DS_SLOT_TYPE_FLOAT), "the replaying engine");
    if (bytes == NULL || c.e == NULL || r.e == NULL) goto done;

    CHECK(ds_rfcs_record_to(c.e, &rec, capture_sink, &cap, buf, sizeof buf)
              .status == DS_OK, "C records");
    ds_fact_t *own = NULL;
    CHECK(assert_ref(&c, "r1", "other", &own).status == DS_OK && own != NULL,
          "C's own Ref(\"r1\", \"other\")");
    const size_t before = cap.len;

    CHECK(ds_engine_assert_external(c.e, bytes, len).status
              == DS_ERR_FACT_REF_CONFLICT,
          "the inlined Ref's key is held by a fact it does not equal");
    CHECK(cap.len == before,
          "the refused call recorded nothing: the recording is byte-identical");
    CHECK(fact_count(c.e) == 1, "and asserted nothing");

    ds_fact_t *next = NULL;
    CHECK(assert_ref(&c, "r2", "after", &next).status == DS_OK,
          "the next input");
    CHECK(cap.len > before, "is recorded");
    CHECK(ds_engine_set_stream_callback(c.e, NULL, NULL).status == DS_OK,
          "recording stops");
    CHECK(rec.last.status == DS_OK, "with no recorder failure");

    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof res);
    ds_result_t rr = ds_rfcs_replay(r.e, cap.bytes, cap.len, strbuf,
                                    sizeof strbuf, &res);
    CHECK(rr.status == DS_OK, "the recording replays with no divergence");
    CHECK(res.asserts == 2, "two FactAsserts: the refused call left none");
    CHECK(count_of(r.e, r.ref) == 2, "both Refs, and nothing else");
done:
    ds_free(bytes);
    ds_engine_free(r.e);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* ---- 13 ------------------------------------------------------------------- */

/* `Ref` alone, as a ttl schema whose TTL is `ttl_ns`. The shape is
   tier_new_as's ttl `Ref`: the schema hash covers no lifecycle and no TTL
   (RFCS.23.3), so two tiers that disagree on the TTL exchange facts. */
static bool ttl_ref_tier(tier_t *t, const char *run_id, uint64_t ttl_ns)
{
    memset(t, 0, sizeof(*t));
    t->e = engine_new(run_id);
    if (t->e == NULL) return false;
    ds_slot_desc_t rs[2] = {
        { .name = "id",   .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_UNSPECIFIED },
        { .name = "note", .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_UNSPECIFIED },
    };
    return ds_engine_register_schema(t->e, "Ref", DS_SCHEMA_LIFECYCLE_TTL,
                                     ttl_ns, rs, 2, &t->ref).status == DS_OK;
}

#define SEC_NS 1000000000ull

/* RFCS.23.6: "No TTL travels. A FactExternal carries no lifetime. The
   receiving engine applies its own schema's lifecycle". Tier A declares `Ref`
   ttl 10 s and asserts one with a 60 s per-emit override; tier B declares
   `Ref` ttl 30 s and receives it at 0 on its mock clock. A deadline from the
   sender's schema would expire it at 10 s, one from the override would keep
   it to 60 s; only B's own schema puts it at 30 s.

   PATH PINNED: ds_engine_assert_external -> the receiver's ordinary assert,
   whose TTL deadline is the receiving schema's ttl_ns from B's assert clock;
   then the pump's TTL sweep, which takes a fact once its deadline <= now. */
/* @spec [RFCS.23.6] */
static void test_no_ttl_travels(void)
{
    tier_t a, b;
    uint8_t *bytes = NULL;
    size_t len = 0;
    CHECK(ttl_ref_tier(&a, "A", 10 * SEC_NS), "tier A: Ref ttl 10 s");
    CHECK(ttl_ref_tier(&b, "B", 30 * SEC_NS), "tier B: Ref ttl 30 s");
    if (a.ref == NULL || b.ref == NULL) goto done;

    ds_slot_value_t v[2] = {
        { .kind = DS_SLOT_STRING, .v.s = "r1" },
        { .kind = DS_SLOT_STRING, .v.s = "hello" },
    };
    ds_fact_t *r = NULL;
    CHECK(ds_engine_assert_with_ttl(a.e, a.ref, v, 2, 60 * SEC_NS, &r).status
              == DS_OK && r != NULL,
          "A asserts its Ref with a 60 s per-emit override");
    uint64_t a_deadline = 0;
    CHECK(r != NULL && ds_fact_get_ttl_deadline_ns(r, &a_deadline).status
              == DS_OK && a_deadline == 60 * SEC_NS,
          "on A the override decides: 60 s");
    CHECK(r != NULL && ds_fact_external_pack(r, &bytes, &len).status == DS_OK,
          "A packs its Ref");
    if (bytes == NULL) goto done;

    CHECK(ds_engine_assert_external(b.e, bytes, len).status == DS_OK,
          "B receives it");
    const ds_fact_t *got = only_fact(b.e, b.ref);
    uint64_t b_deadline = 0;
    CHECK(got != NULL && ds_fact_get_ttl_deadline_ns(got, &b_deadline).status
              == DS_OK && b_deadline == 30 * SEC_NS,
          "on B its own schema decides: deadline 30 s, not 10 s or 60 s");

    CHECK(ds_engine_clock_set(b.e, 30 * SEC_NS - 1).status == DS_OK
              && ds_engine_pump(b.e).status == DS_OK,
          "B pumps at 30 s - 1 ns");
    CHECK(count_of(b.e, b.ref) == 1,
          "live at 30 s - 1 ns: A's 10 s did not travel");
    CHECK(ds_engine_clock_set(b.e, 30 * SEC_NS).status == DS_OK
              && ds_engine_pump(b.e).status == DS_OK,
          "B pumps at 30 s");
    CHECK(count_of(b.e, b.ref) == 0,
          "gone at 30 s: the 60 s override did not travel");
done:
    ds_free(bytes);
    ds_engine_free(b.e);
    ds_engine_free(a.e);
}

/* ---- 14 ------------------------------------------------------------------- */

/* A growable byte buffer for the hand-built artefact. */
typedef struct {
    uint8_t *data;
    size_t   len, cap;
} ie_buf_t;

static bool ie_put(ie_buf_t *b, const void *p, size_t n)
{
    if (b->len + n > b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 256;
        while (nc < b->len + n) nc *= 2;
        uint8_t *nd = realloc(b->data, nc);
        if (nd == NULL) return false;
        b->data = nd;
        b->cap  = nc;
    }
    if (n > 0) memcpy(b->data + b->len, p, n);
    b->len += n;
    return true;
}

/* One atom, framed by the production writer ([RFCS.19.1]), as
   test_dsc_basic.c frames its fixtures. */
static bool ie_frame(ie_buf_t *b, uint32_t field, const uint8_t *body, size_t n)
{
    size_t total = ds_pbf_framed_size(field, n);
    uint8_t *f = total ? malloc(total) : NULL;
    bool ok = f != NULL
           && ds_pbf_frame_atom(field, body, n, f, total, &total)
           && ie_put(b, f, total);
    free(f);
    return ok;
}

static bool ie_frame_msg(ie_buf_t *b, uint32_t field, const ProtobufCMessage *m)
{
    size_t n = protobuf_c_message_get_packed_size(m);
    uint8_t *body = malloc(n ? n : 1u);
    if (body == NULL) return false;
    protobuf_c_message_pack(m, body);
    bool ok = ie_frame(b, field, body, n);
    free(body);
    return ok;
}

static bool ie_schema(ie_buf_t *b, const char *schema)
{
    Ds__V1__SchemaLogical m = DS__V1__SCHEMA_LOGICAL__INIT;
    m.schema_name = (char *) schema;
    m.lifecycle   = DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_EXPLICIT;
    return ie_frame_msg(b, DS_ATOM_SCHEMA_LOGICAL, &m.base);
}

static bool ie_slot(ie_buf_t *b, const char *schema, const char *slot,
                    Ds__V1__SlotKind kind)
{
    Ds__V1__Slot m = DS__V1__SLOT__INIT;
    m.schema_name = (char *) schema;
    m.slot_name   = (char *) slot;
    m.kind        = kind;
    m.schema_ref  = "";
    return ie_frame_msg(b, DS_ATOM_SLOT, &m.base);
}

/* [RDSC.3.6]: zero the header's `dsc_sha256` (field 7 of the first atom),
   hash the artefact, write the digest in, as the compiler seals. */
static bool ie_seal(ie_buf_t *b)
{
    ds_pbf_atom_t a;
    if (ds_pbf_next_atom(b->data, b->len, 0, &a) != DS_PBF_OK
            || a.field != DS_ATOM_DSC_HEADER)
        return false;
    for (size_t pos = 0; pos < a.body_len;) {
        ds_pbf_field_t f;
        if (ds_pbf_next_field(a.body, a.body_len, pos, &f) != DS_PBF_OK)
            return false;
        if (f.field == 7u && f.wire == 2u && f.val_len == 32u) {
            uint8_t *at = b->data + (f.val - b->data);
            memset(at, 0, 32);
            uint8_t digest[32];
            ds_sha256(b->data, b->len, digest);
            memcpy(at, digest, 32);
            return true;
        }
        pos = f.next;
    }
    return false;
}

/* The artefact of the Mercury runtime's fixture 140_initial_external.ds, by
   hand: `Ref` (scope explicit: `id`, `note`, both String), `Seed` (scope
   explicit: `k` Int), and the block
       initial:
           Seed k: 1
           cache "a": 1
           cache "b": 2
   as one InitialFact and two InitialCacheSeeds (proto/initial.proto). Their
   bodies are written out byte by byte, so this fixture does not share
   protobuf-c's encoder with the reader it feeds:
     InitialFact       12 04 "Seed"            schema_name
                       1A 05 0A 01 "k" 10 01   slots[0] = { slot_name "k", i_val 1 }
     InitialCacheSeed  12 01 "a"  1A 02 10 01  20 01   key, value { i_val 1 }, order 1
     InitialCacheSeed  12 01 "b"  1A 02 10 02  20 02   key, value { i_val 2 }, order 2
   module_id is 0 throughout and left at its default. */
static bool ie_build(ie_buf_t *b)
{
    static uint8_t def_sha[32] = { 0xD5 };
    static uint8_t unsealed[32];
    static const uint8_t empty[1] = { 0 };
    static const uint8_t ifct[] = {
        0x12, 0x04, 'S', 'e', 'e', 'd',
        0x1A, 0x05, 0x0A, 0x01, 'k', 0x10, 0x01,
    };
    static const uint8_t icac_a[] = {
        0x12, 0x01, 'a', 0x1A, 0x02, 0x10, 0x01, 0x20, 0x01,
    };
    static const uint8_t icac_b[] = {
        0x12, 0x01, 'b', 0x1A, 0x02, 0x10, 0x02, 0x20, 0x02,
    };
    Ds__V1__DscHeader h = DS__V1__DSC_HEADER__INIT;
    h.compiler_version         = (char *) ds_test_accepted_version();
    h.dialect_def_sha256.data  = def_sha;
    h.dialect_def_sha256.len   = sizeof def_sha;
    h.dsc_sha256.data          = unsealed;
    h.dsc_sha256.len           = sizeof unsealed;
    return ie_frame_msg(b, DS_ATOM_DSC_HEADER, &h.base)
        && ie_frame(b, DS_ATOM_CAPABILITY_INFO, empty, 0)
        && ie_schema(b, "Ref")
        && ie_slot(b, "Ref", "id", DS__V1__SLOT_KIND__SLOT_KIND_STRING)
        && ie_slot(b, "Ref", "note", DS__V1__SLOT_KIND__SLOT_KIND_STRING)
        && ie_schema(b, "Seed")
        && ie_slot(b, "Seed", "k", DS__V1__SLOT_KIND__SLOT_KIND_INT)
        && ie_frame(b, DS_ATOM_INITIAL_FACT, ifct, sizeof ifct)
        && ie_frame(b, DS_ATOM_INITIAL_CACHE_SEED, icac_a, sizeof icac_a)
        && ie_frame(b, DS_ATOM_INITIAL_CACHE_SEED, icac_b, sizeof icac_b)
        && ie_seal(b);
}

/* How many atoms of `field` a recording holds. */
static int ie_count(const uint8_t *s, size_t len, uint32_t field)
{
    int n = 0;
    ds_pbf_atom_t a;
    for (size_t pos = 0; ds_pbf_next_atom(s, len, pos, &a) == DS_PBF_OK;
         pos = a.next)
        if (a.field == field) n++;
    return n;
}

static uint64_t seed_stamp(ds_engine_t *e)
{
    const ds_schema_t *seed = NULL;
    uint64_t at = UINT64_MAX;
    if (ds_engine_schema_find(e, "Seed", &seed).status != DS_OK || seed == NULL)
        return UINT64_MAX;
    const ds_fact_t *f = only_fact(e, seed);
    if (f == NULL || ds_fact_get_asserted_ns(f, &at).status != DS_OK)
        return UINT64_MAX;
    return at;
}

#define T1_NS 1000000000ull    /* the refused step's sample */
#define T2_NS 5000000000ull    /* the next step's */

/* LGRA.24.3: a refused step whose input is an external
   delivery records its sample and nothing else, because a stream holds only
   the `ExternalAssert`s the engine admitted (RFCS.24.1), so a replay never
   meets that refusal. The block stays pending, and the next step applies it.

   An engine bounded to one cache key loads an artefact whose block places
   `Seed` and seeds "a" and "b", and is recorded. Then:
     a. at T1 the first step is a delivery of tier A's Ref: -710, and working
        memory and the cache hold nothing of the block or the record;
     b. the recording so far holds that step's ClockAdvance, and no
        ExternalAssert, BoundsError or FactAssert;
     c. the bound is raised, and at T2 a host assert of a Ref is the next step:
        it applies the block under its own sample, so `Seed`'s entry stamp is
        T2, not T1, beside both cache keys. That pins the clause's "a step
        after the bound is raised applies the block", which no conformance
        harness can reach (both set caps only before the load).
     d. a fresh engine replays the recording with no divergence, applying the
        block at the replay's first step -- the Ref's FactAssert, after the
        orphan T1 sample and the T2 one, which a replay applies through the
        clock setters and not as steps (codec.c's ClockAdvance arm) -- so its
        `Seed` too is stamped T2.

   PATH PINNED: ds_engine_assert_external -> fx_deliver ->
   ds_engine_clock_step(DS_CLOCK_STEP_INPUT) -> ds_engine_initial_apply, whose
   plan refuses on the cache bound and, with no input pending, records
   nothing but the TICK the sample already wrote. The Mercury runtime's
   counterpart is test_ds.m's `check_initial_external` (ds.fact_receive.
   assert_external_with -> clock_step). */
static void test_a_refused_first_external_delivery(void)
{
    tier_t a;
    ds_engine_t *c = NULL, *r = NULL;
    ie_buf_t art = { 0 };
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    static uint8_t            strbuf[1024];
    memset(&cap, 0, sizeof cap);
    memset(&a, 0, sizeof a);

    CHECK(ie_build(&art), "the artefact builds");
    CHECK(ttl_ref_tier(&a, "A", TTL_NS), "tier A: a Ref of the same shape");
    ds_fact_t *src = NULL;
    CHECK(a.e != NULL && assert_ref(&a, "r1", "hello", &src).status == DS_OK
              && src != NULL
              && ds_fact_external_pack(src, &bytes, &len).status == DS_OK,
          "tier A packs its Ref");
    c = engine_new("C");
    r = engine_new("C");
    if (art.data == NULL || bytes == NULL || c == NULL || r == NULL) goto done;

    ds_result_t lr = ds_engine_load_dsc(c, art.data, art.len);
    CHECK(lr.status == DS_OK, "C loads the artefact");
    if (lr.status != DS_OK) {
        fprintf(stderr, "  load: %d %s\n", lr.status, lr.detail ? lr.detail : "");
        goto done;
    }
    CHECK(fact_count(c) == 0 && ds_cache_key_count(&c->cache) == 0,
          "between the load and the first step the block is pending");
    CHECK(ds_engine_set_cache_cap(c, 1, 0).status == DS_OK,
          "C is bounded to one cache key");
    CHECK(ds_rfcs_record_to(c, &rec, capture_sink, &cap, buf, sizeof buf)
              .status == DS_OK, "C records");

    /* a */
    CHECK(ds_engine_clock_set(c, T1_NS).status == DS_OK, "the clock at T1");
    CHECK(ds_engine_assert_external(c, bytes, len).status
              == DS_ERR_CONTRACT_BREACH,
          "a. the first step, an external delivery, is refused: -710");
    CHECK(fact_count(c) == 0,
          "a. nothing of the block and nothing of the record is asserted");
    CHECK(ds_cache_key_count(&c->cache) == 0, "a. and no cache key is seeded");

    /* b */
    CHECK(ie_count(cap.bytes, cap.len, DS_ATOM_CLOCK_ADVANCE) == 1,
          "b. the step's sample is recorded");
    CHECK(ie_count(cap.bytes, cap.len, DS_ATOM_EXTERNAL_ASSERT) == 0,
          "b. no ExternalAssert: the engine did not admit the delivery");
    CHECK(ie_count(cap.bytes, cap.len, DS_ATOM_BOUNDS_ERROR) == 0,
          "b. no BoundsError");
    CHECK(ie_count(cap.bytes, cap.len, DS_ATOM_FACT_ASSERT) == 0,
          "b. no FactAssert, of the block or the record");

    /* c */
    const ds_schema_t *ref = NULL;
    CHECK(ds_engine_schema_find(c, "Ref", &ref).status == DS_OK && ref != NULL,
          "C's Ref");
    CHECK(ds_engine_set_cache_cap(c, 0, 0).status == DS_OK,
          "c. the bound is raised");
    CHECK(ds_engine_clock_set(c, T2_NS).status == DS_OK, "the clock at T2");
    ds_slot_value_t v[2] = {
        { .kind = DS_SLOT_STRING, .v.s = "r2" },
        { .kind = DS_SLOT_STRING, .v.s = "after" },
    };
    CHECK(ref != NULL && ds_engine_assert(c, ref, v, 2, NULL).status == DS_OK,
          "c. the next step, a host assert, is taken");
    CHECK(fact_count(c) == 2, "c. the block's Seed and the asserted Ref");
    CHECK(seed_stamp(c) == T2_NS,
          "c. Seed's entry stamp is the second step's sample, not the first's");
    CHECK(ds_cache_key_count(&c->cache) == 2, "c. both cache keys are seeded");
    CHECK(ds_engine_set_stream_callback(c, NULL, NULL).status == DS_OK,
          "recording stops");
    CHECK(rec.last.status == DS_OK, "with no recorder failure");

    /* d */
    CHECK(ds_engine_load_dsc(r, art.data, art.len).status == DS_OK,
          "the replaying engine loads the same artefact");
    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof res);
    ds_result_t rr = ds_rfcs_replay(r, cap.bytes, cap.len, strbuf,
                                    sizeof strbuf, &res);
    CHECK(rr.status == DS_OK, "d. the recording replays with no divergence");
    if (rr.status != DS_OK)
        fprintf(stderr, "  replay: %d %s\n", rr.status, rr.detail ? rr.detail : "");
    CHECK(res.asserts == 1, "d. one FactAssert: the host's Ref");
    CHECK(fact_count(r) == 2, "d. the replay holds the Seed and the Ref");
    CHECK(seed_stamp(r) == T2_NS,
          "d. the replay applies the block at the second step's sample");
    CHECK(ds_cache_key_count(&r->cache) == 2, "d. and seeds both keys");
done:
    free(art.data);
    ds_free(bytes);
    ds_engine_free(r);
    ds_engine_free(c);
    ds_engine_free(a.e);
}

/* ---- 15 ------------------------------------------------------------------- */

/* The artefact of the Mercury runtime's fixture 147_initial_domain_order.ds,
   by hand: `Marker` (scope explicit: `k` Int, `ts` Time), `Trig` (scope
   explicit: `k` Int), and the block `initial: Marker k: 1` as one InitialFact,
   written out byte by byte as test 14's are:
     InitialFact  12 06 "Marker"            schema_name
                  1A 05 0A 01 "k" 10 01     slots[0] = { slot_name "k", i_val 1 }
   The fixture's `trig` rule is left out: the order under test is the step's,
   and no rule fires before a pump selects. */
static bool ie_build_domain(ie_buf_t *b)
{
    static uint8_t def_sha[32] = { 0xD5 };
    static uint8_t unsealed[32];
    static const uint8_t empty[1] = { 0 };
    static const uint8_t ifct[] = {
        0x12, 0x06, 'M', 'a', 'r', 'k', 'e', 'r',
        0x1A, 0x05, 0x0A, 0x01, 'k', 0x10, 0x01,
    };
    Ds__V1__DscHeader h = DS__V1__DSC_HEADER__INIT;
    h.compiler_version         = (char *) ds_test_accepted_version();
    h.dialect_def_sha256.data  = def_sha;
    h.dialect_def_sha256.len   = sizeof def_sha;
    h.dsc_sha256.data          = unsealed;
    h.dsc_sha256.len           = sizeof unsealed;
    return ie_frame_msg(b, DS_ATOM_DSC_HEADER, &h.base)
        && ie_frame(b, DS_ATOM_CAPABILITY_INFO, empty, 0)
        && ie_schema(b, "Marker")
        && ie_slot(b, "Marker", "k", DS__V1__SLOT_KIND__SLOT_KIND_INT)
        && ie_slot(b, "Marker", "ts", DS__V1__SLOT_KIND__SLOT_KIND_TIME)
        && ie_schema(b, "Trig")
        && ie_slot(b, "Trig", "k", DS__V1__SLOT_KIND__SLOT_KIND_INT)
        && ie_frame(b, DS_ATOM_INITIAL_FACT, ifct, sizeof ifct)
        && ie_seal(b);
}

/* The ordinal of the first atom of `field` in a recording, or -1. */
static int ie_index(const uint8_t *s, size_t len, uint32_t field)
{
    int i = 0;
    ds_pbf_atom_t a;
    for (size_t pos = 0; ds_pbf_next_atom(s, len, pos, &a) == DS_PBF_OK;
         pos = a.next, i++)
        if (a.field == field) return i;
    return -1;
}

/* [LGRA.24.3], [LTIM.2.8.3]: AN `initial`
   BLOCK'S DOMAIN FAULT IS RECORDED AFTER THE STEP'S INPUT. The step records
   its TICK, then its input, then the fault: the order the clause gives a
   bounds refusal at the same point.

   The artefact's block places a `Marker`, whose `ts` a mock clock with no
   wall value cannot fill, so applying it raises one ComputationError of kind
   DOMAIN. On two engines, each recorded from the load:
     a. the first step is a host assert of a `Trig`: the recording holds its
        ClockAdvance, then the Trig's FactAssert, then the ComputationError;
     b. the first step is a pump: its ClockAdvance, its PumpBoundary, then the
        ComputationError.
   Each holds exactly one ComputationError, after the input.

   PATH PINNED: ds_engine_clock_step -> ds_engine_initial_apply ->
   lgra_24_3_item -> ltim_2_8_3_block_fault -> ds_recorder_block_fault, and
   recorder_dispatch's flush after the input's record (the FactAssert from
   the assert bridge in a, ds_recorder_emit_pump in b). The Mercury runtime's
   counterpart is test_ds.m's `check_initial_domain_order`. */
static void test_an_initial_domain_fault_follows_the_input(void)
{
    ie_buf_t art = { 0 };
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    CHECK(ie_build_domain(&art), "the artefact builds");
    if (art.data == NULL) return;

    for (int pump = 0; pump <= 1; pump++) {
        const char *shape = pump ? "b. a first pump" : "a. a first host assert";
        memset(&cap, 0, sizeof cap);
        ds_engine_t *e = engine_new("D");
        if (e == NULL) {
            CHECK(false, "an engine");
            continue;
        }
        ds_result_t lr = ds_engine_load_dsc(e, art.data, art.len);
        CHECK(lr.status == DS_OK, "the engine loads the artefact");
        if (lr.status != DS_OK) {
            fprintf(stderr, "  load: %d %s\n", lr.status,
                    lr.detail ? lr.detail : "");
            ds_engine_free(e);
            continue;
        }
        CHECK(ds_rfcs_record_to(e, &rec, capture_sink, &cap, buf, sizeof buf)
                  .status == DS_OK, "the engine records");
        CHECK(ds_engine_clock_set(e, T1_NS).status == DS_OK, "the clock at T1");

        uint32_t input = DS_ATOM_PUMP_BOUNDARY;
        if (pump) {
            CHECK(ds_engine_pump(e).status == DS_OK, "b. the pump is taken");
        } else {
            input = DS_ATOM_FACT_ASSERT;
            const ds_schema_t *trig = NULL;
            ds_slot_value_t v[1] = { { .kind = DS_SLOT_INT, .v.i = 3 } };
            CHECK(ds_engine_schema_find(e, "Trig", &trig).status == DS_OK
                      && trig != NULL
                      && ds_engine_assert(e, trig, v, 1, NULL).status == DS_OK,
                  "a. the host assert is taken");
        }
        CHECK(ds_engine_set_stream_callback(e, NULL, NULL).status == DS_OK,
              "recording stops");
        CHECK(rec.last.status == DS_OK, "with no recorder failure");

        const int tick = ie_index(cap.bytes, cap.len, DS_ATOM_CLOCK_ADVANCE);
        const int in   = ie_index(cap.bytes, cap.len, input);
        const int ce   = ie_index(cap.bytes, cap.len, DS_ATOM_COMPUTATION_ERROR);
        if (!(tick >= 0 && in == tick + 1 && ce == in + 1))
            fprintf(stderr, "  %s: ClockAdvance %d, input %d, "
                    "ComputationError %d\n", shape, tick, in, ce);
        CHECK(tick >= 0 && in == tick + 1 && ce == in + 1,
              pump ? "b. ClockAdvance, PumpBoundary, then the block's DOMAIN "
                     "ComputationError"
                   : "a. ClockAdvance, the Trig's FactAssert, then the block's "
                     "DOMAIN ComputationError");
        CHECK(ie_count(cap.bytes, cap.len, DS_ATOM_COMPUTATION_ERROR) == 1,
              "one ComputationError: the block's one Marker");
        ds_engine_free(e);
    }
    free(art.data);
}

/* ---- 16 ------------------------------------------------------------------- */

/* The key a CacheSeed body names: field 1, written first ([RFCS.26.1]),
   copied into `out`. False for a body that does not open with it. */
static bool cs_key(const uint8_t *body, size_t len, char *out, size_t cap)
{
    if (len < 2 || body[0] != 0x0Au || body[1] >= 0x80u
            || (size_t) body[1] + 2u > len || (size_t) body[1] >= cap)
        return false;
    memcpy(out, body + 2, body[1]);
    out[body[1]] = '\0';
    return true;
}

/* The value text the cache holds for `key`, or NULL. */
static const char *cache_text(ds_engine_t *e, const char *key)
{
    const char *v = NULL;
    return ds_cache_get(&e->cache, key, 0, &v, NULL) ? v : NULL;
}

/* [RFCS.26.1]: the recorder writes a CacheSeed for each key the HOST seeded,
   in the prelude; the `initial` block's cache items are not host seeds and
   get none, because the artefact carries them and a replay applies them at
   its own first step ([LGRA.24.3]). [RFCS.26.2]: the replayer applies the
   seeds before its first input, so a fresh engine given only the stream ends
   with the run's cache; and a seed the replaying engine refuses is a
   divergence.

   Test 14's artefact seeds "a" = 1 and "b" = 2 in its block. The host seeds
   "a" = 9 and "c" = 3 before the first step. Then:
     a. the first step, a host assert, applies the block: "a" keeps the host's
        9 ([NLFC.9.3]) and "b" is placed, so the cache holds three keys;
     b. the recording holds exactly two CacheSeeds, "a" then "c", both before
        the first event atom. A recorder that wrote the cache as the run ended,
        or wrote the block's items, writes three;
     c. a fresh engine that loads the artefact and replays the recording,
        unseeded, diverges nowhere and holds "a" = 9, "b" = 2 and "c" = 3;
     d. a fresh engine bounded to one cache key refuses the second seed, and
        the replay stops with DS_ERR_FS_DIVERGENCE.

   PATH PINNED: rfcs/codec.c's rfcs_announce_seeds at the first event, and its
   replay arm through ds_engine_cache_seed_replay. The Mercury runtime's
   counterpart is test_ds.m's `check_prelude_seeds`. */
/* @spec [RFCS.26.1] */
static void test_rfcs_26_1__host_seeds_in_the_prelude_and_not_the_block(void)
{
    ds_engine_t *c = NULL, *r = NULL, *b = NULL;
    ie_buf_t art = { 0 };
    ds_json_t *nine = NULL, *three = NULL;
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    static uint8_t            strbuf[1024];
    memset(&cap, 0, sizeof cap);

    CHECK(ie_build(&art), "the artefact builds");
    CHECK(ds_json_parse("9", 1, &nine).status == DS_OK
              && ds_json_parse("3", 1, &three).status == DS_OK, "the values");
    c = engine_new("C");
    r = engine_new("C");
    b = engine_new("C");
    if (art.data == NULL || nine == NULL || three == NULL || c == NULL
            || r == NULL || b == NULL)
        goto done;

    CHECK(ds_engine_load_dsc(c, art.data, art.len).status == DS_OK,
          "C loads the artefact");
    CHECK(ds_engine_cache_seed(c, "a", nine, DS_CACHE_TTL_NONE).status == DS_OK
              && ds_engine_cache_seed(c, "c", three, DS_CACHE_TTL_NONE).status
                     == DS_OK,
          "the host seeds a and c before the first step");
    CHECK(ds_rfcs_record_to(c, &rec, capture_sink, &cap, buf, sizeof buf)
              .status == DS_OK, "C records");

    /* a */
    const ds_schema_t *ref = NULL;
    CHECK(ds_engine_schema_find(c, "Ref", &ref).status == DS_OK && ref != NULL,
          "C's Ref");
    CHECK(ds_engine_clock_set(c, T1_NS).status == DS_OK, "the clock at T1");
    ds_slot_value_t v[2] = {
        { .kind = DS_SLOT_STRING, .v.s = "r1" },
        { .kind = DS_SLOT_STRING, .v.s = "first" },
    };
    CHECK(ref != NULL && ds_engine_assert(c, ref, v, 2, NULL).status == DS_OK,
          "a. the first step, a host assert");
    CHECK(ds_cache_key_count(&c->cache) == 3, "a. the cache holds a, b and c");
    const char *a_text = cache_text(c, "a");
    CHECK(a_text != NULL && strcmp(a_text, "9") == 0,
          "a. a keeps the host's 9 (NLFC.9.3)");
    CHECK(ds_engine_set_stream_callback(c, NULL, NULL).status == DS_OK,
          "recording stops");
    CHECK(rec.last.status == DS_OK, "with no recorder failure");

    /* b */
    {
        char keys[2][8] = { "", "" };
        int n_seeds = 0, seed_after_event = 0, seen_event = 0;
        ds_pbf_atom_t at;
        for (size_t pos = 0;
             ds_pbf_next_atom(cap.bytes, cap.len, pos, &at) == DS_PBF_OK;
             pos = at.next) {
            if (at.field == DS_ATOM_CLOCK_ADVANCE
                    || at.field == DS_ATOM_FACT_ASSERT)
                seen_event = 1;
            if (at.field != DS_ATOM_CACHE_SEED)
                continue;
            if (seen_event)
                seed_after_event = 1;
            if (n_seeds < 2)
                CHECK(cs_key(at.body, at.body_len, keys[n_seeds],
                             sizeof keys[0]), "b. a CacheSeed names its key");
            n_seeds++;
        }
        CHECK(n_seeds == 2,
              "b. two CacheSeeds: the host's a and c, not the block's b");
        CHECK(strcmp(keys[0], "a") == 0 && strcmp(keys[1], "c") == 0,
              "b. a then c, by the key's bytes");
        CHECK(!seed_after_event, "b. every CacheSeed precedes the first event");
    }

    /* c */
    CHECK(ds_engine_load_dsc(r, art.data, art.len).status == DS_OK,
          "the replaying engine loads the artefact and is seeded with nothing");
    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof res);
    ds_result_t rr = ds_rfcs_replay(r, cap.bytes, cap.len, strbuf,
                                    sizeof strbuf, &res);
    CHECK(rr.status == DS_OK, "c. the recording replays with no divergence");
    if (rr.status != DS_OK)
        fprintf(stderr, "  replay: %d %s\n", rr.status, rr.detail ? rr.detail : "");
    const char *ra = cache_text(r, "a"), *rb = cache_text(r, "b"),
               *rc = cache_text(r, "c");
    CHECK(ds_cache_key_count(&r->cache) == 3, "c. the replay holds three keys");
    CHECK(ra != NULL && strcmp(ra, "9") == 0, "c. a = 9, the host's");
    CHECK(rb != NULL && strcmp(rb, "2") == 0, "c. b = 2, the block's");
    CHECK(rc != NULL && strcmp(rc, "3") == 0, "c. c = 3, the host's");

    /* d */
    CHECK(ds_engine_load_dsc(b, art.data, art.len).status == DS_OK,
          "a third engine loads the artefact");
    CHECK(ds_engine_set_cache_cap(b, 1, 0).status == DS_OK,
          "and is bounded to one cache key");
    memset(&res, 0, sizeof res);
    rr = ds_rfcs_replay(b, cap.bytes, cap.len, strbuf, sizeof strbuf, &res);
    CHECK(rr.status == DS_ERR_FS_DIVERGENCE,
          "d. a recorded seed the bound refuses is a divergence (RFCS.26.2)");
done:
    free(art.data);
    ds_json_free(nine);
    ds_json_free(three);
    ds_engine_free(b);
    ds_engine_free(r);
    ds_engine_free(c);
}

/* ---- 17 ------------------------------------------------------------------- */

/* The first atom `field` in a recording, as ds_rfcs_next yields it. */
static bool first_atom(const capture_t *cap, uint32_t field,
                       const uint8_t **body, size_t *len)
{
    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, cap->bytes, cap->len);
    for (;;) {
        uint32_t atom = 0;
        bool done = false;
        if (ds_rfcs_next(&rd, &atom, body, len, &done).status != DS_OK || done)
            return false;
        if (atom == field) return true;
    }
}

static size_t ea_varint(uint8_t *p, uint64_t v)
{
    size_t n = 0;
    do {
        p[n] = (uint8_t) (v & 0x7fu) | (v > 0x7fu ? 0x80u : 0u);
        v >>= 7;
        n++;
    } while (v != 0);
    return n;
}

/* An ExternalAssert body written by hand (external_assert.proto): `fact` = 1,
   each `fact_ids` element = 2 as its own varint field, which a proto3 reader
   takes as it takes the packed form, and `ttl_ns` = 3 when not 0. */
static size_t ea_craft(uint8_t *out, const uint8_t *fact, size_t fact_len,
                       const uint64_t *ids, size_t n_ids, uint64_t ttl_ns)
{
    size_t n = 0;
    out[n++] = 0x0au;
    n += ea_varint(out + n, fact_len);
    memcpy(out + n, fact, fact_len);
    n += fact_len;
    for (size_t i = 0; i < n_ids; i++) {
        out[n++] = 0x10u;
        n += ea_varint(out + n, ids[i]);
    }
    if (ttl_ns != 0) {
        out[n++] = 0x18u;
        n += ea_varint(out + n, ttl_ns);
    }
    return n;
}

/* RFCS.24.2 through ds_rfcs_apply_external_assert: one recorded
   ExternalAssert, applied alone, binds its `fact_ids` so that a later
   FactRetract resolves.

   C records a delivery of A's Main (the inlined Ref, then the Main) and then
   retracts the Main. R, which first asserts a Ref of its own so that its ids
   run one ahead of C's, applies the ExternalAssert through the call and the
   FactRetract through the binding it handed back. THE TEETH: R's id for the
   Main is not C's, so a reader that used the recorded id unbound would
   retract another fact or none, and the Main would stay. */
/* @spec [RFCS.24.2] */
static void test_one_recorded_external_assert_binds_its_ids(void)
{
    tier_t a, c, r;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    memset(&cap, 0, sizeof cap);
    memset(&c, 0, sizeof c);
    memset(&r, 0, sizeof r);
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(tier_new(&c, "C", false, DS_SLOT_TYPE_FLOAT), "tier C");
    CHECK(tier_new(&r, "C", false, DS_SLOT_TYPE_FLOAT), "the applying engine");
    if (bytes == NULL || c.e == NULL || r.e == NULL) goto done;

    CHECK(ds_rfcs_record_to(c.e, &rec, capture_sink, &cap, buf, sizeof buf)
              .status == DS_OK, "C records");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "C receives A's Main");
    const ds_fact_t *cm = only_fact(c.e, c.main);
    CHECK(cm != NULL && ds_engine_retract(c.e, (ds_fact_t *) cm).status == DS_OK,
          "C retracts the Main");
    CHECK(ds_engine_set_stream_callback(c.e, NULL, NULL).status == DS_OK
              && rec.last.status == DS_OK, "recording stops, with no failure");

    const uint8_t *ea = NULL, *rt = NULL;
    size_t ea_len = 0, rt_len = 0;
    CHECK(first_atom(&cap, DS_ATOM_EXTERNAL_ASSERT, &ea, &ea_len),
          "the recording holds the ExternalAssert");
    CHECK(first_atom(&cap, DS_ATOM_FACT_RETRACT, &rt, &rt_len),
          "and the FactRetract");
    if (ea == NULL || rt == NULL) goto done;

    ds_fact_t *pad = NULL;
    CHECK(assert_ref(&r, "r0", "pad", &pad).status == DS_OK,
          "R holds a Ref of its own first, so its ids run ahead of C's");

    uint64_t ids[4] = {0}, recorded[4] = {0};
    size_t n = 99;
    ds_result_t ar = ds_rfcs_apply_external_assert(r.e, ea, ea_len, ids,
                                                   recorded, 4, &n);
    CHECK(ar.status == DS_OK, "R applies the ExternalAssert");
    CHECK(n == 2, "two facts: the inlined Ref, then the Main (RFCS.24.3)");
    CHECK(fact_count(r.e) == 3, "R's own Ref, the inlined one and the Main");

    ds_rfcs_fcrt_t fr;
    memset(&fr, 0, sizeof fr);
    CHECK(ds_rfcs_decode_fcrt(rt, rt_len, &fr).status == DS_OK,
          "the FactRetract decodes");
    size_t at = n;
    for (size_t i = 0; i < n; i++)
        if (recorded[i] == fr.fact_id) at = i;
    CHECK(at == 1, "the retract names the Main's recorded id, the second");
    if (at >= n) goto done;
    CHECK(ids[at] != fr.fact_id,
          "R's id for the Main is not the recorded one: the binding is needed");

    ds_fact_t *unbound = NULL;
    (void) ds_engine_fact_find(r.e, fr.fact_id, &unbound);
    CHECK(unbound != only_fact(r.e, r.main),
          "the recorded id, unbound, does not name R's Main");
    ds_fact_t *bound = NULL;
    CHECK(ds_engine_fact_find(r.e, ids[at], &bound).status == DS_OK
              && bound != NULL && bound == only_fact(r.e, r.main),
          "the bound id names R's Main");
    CHECK(bound != NULL && ds_engine_retract(r.e, bound).status == DS_OK,
          "R applies the FactRetract through the binding");
    CHECK(count_of(r.e, r.main) == 0 && count_of(r.e, r.ref) == 2,
          "the Main is gone and both Refs are live, as on C");
done:
    ds_free(bytes);
    ds_engine_free(r.e);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* RFCS.24.2: a `fact_ids` one longer than the delivery asserts is
   DS_ERR_FS_DIVERGENCE, with nothing bound. The body is C's recorded one with
   one more id appended; the control is the body as recorded. */
/* @spec [RFCS.24.2] */
static void test_one_fact_id_too_many_is_a_divergence(void)
{
    tier_t a, c, r1, r2;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    static uint8_t            longer[4096];
    memset(&cap, 0, sizeof cap);
    memset(&c, 0, sizeof c);
    memset(&r1, 0, sizeof r1);
    memset(&r2, 0, sizeof r2);
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(tier_new(&c, "C", false, DS_SLOT_TYPE_FLOAT), "tier C");
    CHECK(tier_new(&r1, "C", false, DS_SLOT_TYPE_FLOAT), "engine R1");
    CHECK(tier_new(&r2, "C", false, DS_SLOT_TYPE_FLOAT), "engine R2");
    if (bytes == NULL || c.e == NULL || r1.e == NULL || r2.e == NULL) goto done;

    CHECK(ds_rfcs_record_to(c.e, &rec, capture_sink, &cap, buf, sizeof buf)
              .status == DS_OK, "C records");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "C receives A's Main");
    CHECK(ds_engine_set_stream_callback(c.e, NULL, NULL).status == DS_OK,
          "recording stops");
    const uint8_t *ea = NULL;
    size_t ea_len = 0;
    CHECK(first_atom(&cap, DS_ATOM_EXTERNAL_ASSERT, &ea, &ea_len),
          "the recording holds the ExternalAssert");
    if (ea == NULL || ea_len + 2 > sizeof longer) goto done;
    memcpy(longer, ea, ea_len);
    longer[ea_len]     = 0x10u;   /* one more fact_ids element: 99 */
    longer[ea_len + 1] = 0x63u;

    uint64_t ids[4], recorded[4];
    size_t n = 99;
    CHECK(ds_rfcs_apply_external_assert(r1.e, ea, ea_len, ids, recorded, 4, &n)
              .status == DS_OK && n == 2,
          "control: the body as recorded applies, two facts");
    n = 99;
    CHECK(ds_rfcs_apply_external_assert(r2.e, longer, ea_len + 2, ids,
                                        recorded, 4, &n).status
              == DS_ERR_FS_DIVERGENCE,
          "three fact_ids for a delivery of two is a divergence");
    CHECK(n == 0, "and binds nothing");
done:
    ds_free(bytes);
    ds_engine_free(r2.e);
    ds_engine_free(r1.e);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* RFCS.24.2: "apply `ttl_ns` to the received fact". R declares `Ref` ttl
   30 s and is at 7 s; a body carrying `ttl_ns` 5 s gives the received Ref the
   deadline 12 s, where its schema alone (the control, ttl_ns absent) gives
   37 s. */
/* @spec [RFCS.24.2] */
static void test_a_recorded_ttl_sets_the_received_deadline(void)
{
    tier_t a, r1, r2;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    static uint8_t body[1024];
    memset(&r1, 0, sizeof r1);
    memset(&r2, 0, sizeof r2);
    CHECK(ttl_ref_tier(&a, "A", 30 * SEC_NS), "tier A: Ref ttl 30 s");
    CHECK(ttl_ref_tier(&r1, "R", 30 * SEC_NS), "R1: Ref ttl 30 s");
    CHECK(ttl_ref_tier(&r2, "R", 30 * SEC_NS), "R2: Ref ttl 30 s");
    if (a.ref == NULL || r1.ref == NULL || r2.ref == NULL) goto done;

    ds_fact_t *f = NULL;
    CHECK(assert_ref(&a, "r1", "hello", &f).status == DS_OK && f != NULL,
          "A asserts its Ref");
    CHECK(f != NULL && ds_fact_external_pack(f, &bytes, &len).status == DS_OK,
          "A packs it");
    if (bytes == NULL || len + 32 > sizeof body) goto done;

    const uint64_t one_id = 1;
    struct { tier_t *t; uint64_t ttl; uint64_t want; const char *msg; } cases[2] = {
        { &r1, 5 * SEC_NS, 12 * SEC_NS,
          "ttl_ns 5 s at 7 s: the deadline is 12 s" },
        { &r2, 0,          37 * SEC_NS,
          "control, no ttl_ns: the schema's 30 s, 37 s" },
    };
    for (int k = 0; k < 2; k++) {
        tier_t *t = cases[k].t;
        CHECK(ds_engine_clock_set(t->e, 7 * SEC_NS).status == DS_OK,
              "the clock at 7 s");
        size_t blen = ea_craft(body, bytes, len, &one_id, 1, cases[k].ttl);
        uint64_t ids[1] = {0}, recorded[1] = {0};
        size_t n = 99;
        CHECK(ds_rfcs_apply_external_assert(t->e, body, blen, ids, recorded,
                                            1, &n).status == DS_OK
                  && n == 1 && recorded[0] == one_id,
              "the body applies, one fact, bound to the recorded id");
        ds_fact_t *got = NULL;
        uint64_t deadline = 0;
        CHECK(ds_engine_fact_find(t->e, ids[0], &got).status == DS_OK
                  && got != NULL
                  && ds_fact_get_ttl_deadline_ns(got, &deadline).status == DS_OK,
              "the received Ref, by its bound id");
        printf("    %s: deadline=%llu\n", cases[k].msg,
               (unsigned long long) deadline);
        CHECK(deadline == cases[k].want, cases[k].msg);
    }
done:
    ds_free(bytes);
    ds_engine_free(r2.e);
    ds_engine_free(r1.e);
    ds_engine_free(a.e);
}

/* The call's refusals apply nothing: `fact_ids` longer than the arrays is
   DS_ERR_INVAL with the length needed, and a body that is not an
   ExternalAssert is DS_ERR_PARSE. In both, R holds no fact afterwards. */
static void test_apply_external_assert_refusals_apply_nothing(void)
{
    tier_t a, r;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    static uint8_t body[1024];
    memset(&r, 0, sizeof r);
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(tier_new(&r, "R", false, DS_SLOT_TYPE_FLOAT), "engine R");
    if (bytes == NULL || r.e == NULL || len + 32 > sizeof body) goto done;

    const uint64_t two[2] = { 1, 2 };
    size_t blen = ea_craft(body, bytes, len, two, 2, 0);
    uint64_t ids[1], recorded[1];
    size_t n = 99;
    CHECK(ds_rfcs_apply_external_assert(r.e, body, blen, ids, recorded, 1, &n)
              .status == DS_ERR_INVAL,
          "two fact_ids into arrays of one is DS_ERR_INVAL");
    CHECK(n == 2, "and says two are needed");
    CHECK(fact_count(r.e) == 0, "nothing was delivered");

    static const uint8_t not_one[] = { 0x0bu };   /* field 1, wire 3: malformed */
    n = 99;
    CHECK(ds_rfcs_apply_external_assert(r.e, not_one, sizeof not_one, ids,
                                        recorded, 1, &n).status == DS_ERR_PARSE,
          "a body that is not an ExternalAssert is DS_ERR_PARSE");
    CHECK(n == 0 && fact_count(r.e) == 0, "and applies nothing");
done:
    ds_free(bytes);
    ds_engine_free(r.e);
    ds_engine_free(a.e);
}

/* ---- 18 ------------------------------------------------------------------- */

/* `Ans` and `CallError` with a `corr`; `D` logical; `R`, `Rd` and `Re` refer to
   them. On a receiver `Ans` is a response schema, as the DSC loader marks one
   from a ServiceDef, so an arriving answer supersedes ([LCRS.6.2.4]). A publisher
   has no such mark, and holds two answers of one `corr` to pack: the record no
   publisher's own run could make from a responding schema. */
typedef struct {
    ds_engine_t       *e;
    const ds_schema_t *ans, *err, *d, *r, *rd, *re;
} gone_t;

static bool gone_refers(gone_t *t, const char *name, const ds_schema_t *a,
                        const char *an, const ds_schema_t *b, const char *bn,
                        const ds_schema_t **out)
{
    ds_slot_desc_t s[3] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
        { .name = an,  .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = a,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = bn,  .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = b,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    return ds_engine_register_schema(t->e, name, DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     s, 3, out).status == DS_OK;
}

static bool gone_tier(gone_t *t, const char *run_id, bool receiver)
{
    memset(t, 0, sizeof(*t));
    t->e = engine_new(run_id);
    if (t->e == NULL) return false;
    ds_slot_desc_t as[2] = {
        { .name = "corr", .type = DS_SLOT_TYPE_STRING },
        { .name = "v",    .type = DS_SLOT_TYPE_INT },
    };
    ds_slot_desc_t es[2] = {
        { .name = "corr", .type = DS_SLOT_TYPE_STRING },
        { .name = "code", .type = DS_SLOT_TYPE_STRING },
    };
    ds_slot_desc_t ds[1] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
    };
    if (ds_engine_register_schema(t->e, "Ans", DS_SCHEMA_LIFECYCLE_TTL, TTL_NS,
                                  as, 2, &t->ans).status != DS_OK
            || ds_engine_register_schema(t->e, "CallError", DS_SCHEMA_LIFECYCLE_TTL,
                                         TTL_NS, es, 2, &t->err).status != DS_OK
            || ds_engine_register_schema(t->e, "D", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                         ds, 1, &t->d).status != DS_OK
            || !gone_refers(t, "R", t->ans, "a", t->ans, "b", &t->r)
            || !gone_refers(t, "Rd", t->d, "d", t->ans, "y", &t->rd)
            || !gone_refers(t, "Re", t->ans, "a", t->err, "e", &t->re))
        return false;
    if (receiver) ((ds_schema_t *) t->ans)->call_response = true;
    return true;
}

static ds_result_t gone_ans(gone_t *t, int64_t v, ds_fact_t **out)
{
    ds_slot_value_t s[2] = {
        { .kind = DS_SLOT_STRING, .v.s = "c" },
        { .kind = DS_SLOT_INT,    .v.i = v },
    };
    return ds_engine_assert(t->e, t->ans, s, 2, out);
}

/* A publisher's referrer of `schema`, packed: k 1, slots 1 and 2 referring to `a`
   and `b`. */
static bool gone_pack(gone_t *t, const ds_schema_t *schema, ds_fact_t *a,
                      ds_fact_t *b, uint8_t **bytes, size_t *len)
{
    ds_fact_t *m = NULL;
    ds_slot_value_t s[3] = {
        { .kind = DS_SLOT_INT,      .v.i   = 1 },
        { .kind = DS_SLOT_FACT_REF, .v.ref = a },
        { .kind = DS_SLOT_FACT_REF, .v.ref = b },
    };
    return ds_engine_assert(t->e, schema, s, 3, &m).status == DS_OK && m != NULL
        && ds_fact_external_pack(m, bytes, len).status == DS_OK;
}

/* The received fact holds a slot 1 naming fact id `gone_id`, whose target has
   gone, and a slot 2 with a target. `gone_id` 0 skips the id: an inlined copy's
   id is not the test's to know. */
static void gone_check_referrer(const ds_fact_t *f, uint64_t gone_id,
                                const char *what)
{
    CHECK(f != NULL, what);
    if (f == NULL) return;
    uint64_t named = 0;
    CHECK(ref_of(f, 1) == NULL, "slot 1's read finds the target gone");
    CHECK(ds_fact_get_slot_ref_id(f, 1, &named).status == DS_OK && named != 0,
          "and the slot still names the fact it referred to");
    if (gone_id != 0)
        CHECK(named == gone_id, "the removed fact's own id");
    CHECK(ref_of(f, 2) != NULL, "slot 2's target is live");
}

/* @spec [RFCS.23.7]
   A first copy equal to live answer X, a new answer Y of X's
   `corr`, and the received fact referring to the first. THE PATH: fx_deliver's
   second phase: Y's ds_engine_assert sweeps X (ds_dispatch_supersede_arrival),
   releasing its wrapper as that assert returns, and the referrer's assert reads
   the target through fx_hold_target. Under ASan a read of X's wrapper fails
   here. The recording replays with the same fact_ids ([RFCS.24.2]). */
static void test_rfcs_23_7__a_live_target_superseded_by_the_delivery(void)
{
    gone_t a, c, r;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    static uint8_t            strbuf[1024];
    memset(&cap, 0, sizeof cap);
    memset(&c, 0, sizeof c);
    memset(&r, 0, sizeof r);
    ds_fact_t *ax = NULL, *ay = NULL, *x = NULL;
    uint64_t xid = 0;
    CHECK(gone_tier(&a, "A", false), "the publisher");
    CHECK(gone_ans(&a, 1, &ax).status == DS_OK
              && gone_ans(&a, 2, &ay).status == DS_OK,
          "it holds two answers of one corr");
    CHECK(ax != NULL && ay != NULL && gone_pack(&a, a.r, ax, ay, &bytes, &len),
          "and packs the fact referring to both");
    CHECK(gone_tier(&c, "C", true), "the receiver");
    CHECK(gone_tier(&r, "C", true), "the replaying engine");
    if (bytes == NULL || c.e == NULL || r.e == NULL) goto done;

    CHECK(ds_rfcs_record_to(c.e, &rec, capture_sink, &cap, buf, sizeof buf)
              .status == DS_OK, "the receiver records");
    CHECK(gone_ans(&c, 1, &x).status == DS_OK && x != NULL,
          "the receiver holds the live answer X");
    CHECK(ds_fact_get_id(x, &xid).status == DS_OK, "X's id");

    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "the delivery asserts every node and returns DS_OK");
    CHECK(count_of(c.e, c.ans) == 1, "X is gone, and Y is live");
    gone_check_referrer(only_fact(c.e, c.r), xid, "the received fact is live");
    CHECK(ds_engine_set_stream_callback(c.e, NULL, NULL).status == DS_OK
              && rec.last.status == DS_OK, "recording stops, with no failure");

    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof res);
    CHECK(ds_rfcs_replay(r.e, cap.bytes, cap.len, strbuf, sizeof strbuf,
                         &res).status == DS_OK,
          "the recording replays with no divergence ([RFCS.24.2])");
    CHECK(count_of(r.e, r.ans) == 1 && count_of(r.e, r.r) == 1,
          "and ends with the same facts");
    gone_check_referrer(only_fact(r.e, r.r), 0, "the replayed fact is live");
done:
    ds_free(bytes);
    ds_engine_free(r.e);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* @spec [RFCS.23.7]
   A `CallError` in Y's place: it sweeps the response schemas too. */
static void test_rfcs_23_7__a_call_error_supersedes_a_target(void)
{
    gone_t a, c;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    memset(&c, 0, sizeof c);
    ds_fact_t *ax = NULL, *ae = NULL, *x = NULL;
    uint64_t xid = 0;
    CHECK(gone_tier(&a, "A", false), "the publisher");
    ds_slot_value_t ev[2] = {
        { .kind = DS_SLOT_STRING, .v.s = "c" },
        { .kind = DS_SLOT_STRING, .v.s = "internal.bug" },
    };
    CHECK(gone_ans(&a, 1, &ax).status == DS_OK
              && ds_engine_assert(a.e, a.err, ev, 2, &ae).status == DS_OK,
          "it holds an answer and a CallError of one corr");
    CHECK(ax != NULL && ae != NULL && gone_pack(&a, a.re, ax, ae, &bytes, &len),
          "and packs the fact referring to both");
    CHECK(gone_tier(&c, "C", true), "the receiver");
    if (bytes == NULL || c.e == NULL) goto done;

    CHECK(gone_ans(&c, 1, &x).status == DS_OK && x != NULL
              && ds_fact_get_id(x, &xid).status == DS_OK,
          "the receiver holds the live answer X");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "the delivery returns DS_OK");
    CHECK(count_of(c.e, c.ans) == 0, "X is gone");
    CHECK(count_of(c.e, c.err) == 1, "the CallError is live");
    gone_check_referrer(only_fact(c.e, c.re), xid, "the received fact is live");
done:
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* @spec [RFCS.23.7]
   An inlined copy the delivery asserted is removed too: neither answer is live
   on the receiver, so the first copy is asserted and the second supersedes it.
   THE PATH: `x->asserted`, held as its assert returned. */
static void test_rfcs_23_7__an_inlined_copy_superseded_by_the_delivery(void)
{
    gone_t a, c;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    memset(&c, 0, sizeof c);
    ds_fact_t *ax = NULL, *ay = NULL;
    CHECK(gone_tier(&a, "A", false), "the publisher");
    CHECK(gone_ans(&a, 1, &ax).status == DS_OK
              && gone_ans(&a, 2, &ay).status == DS_OK
              && ax != NULL && ay != NULL
              && gone_pack(&a, a.r, ax, ay, &bytes, &len),
          "it packs a fact referring to two answers of one corr");
    CHECK(gone_tier(&c, "C", true), "the receiver");
    if (bytes == NULL || c.e == NULL) goto done;

    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "the delivery returns DS_OK");
    CHECK(count_of(c.e, c.ans) == 1, "the first copy is gone, the second live");
    gone_check_referrer(only_fact(c.e, c.r), 0, "the received fact is live");
done:
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* @spec [RFCS.23.7]
   The copy equals a live logical D that a rule derived from answer X alone, X is
   not in the record, and a new answer of X's `corr` sweeps X, so its cascade
   removes D. A check that paired the record's own nodes would miss this: nothing
   in the record names X. The rule is built as test_ncbk_2_12 builds one. */
static void test_rfcs_23_7__a_cascade_removes_a_target(void)
{
    gone_t a, c;
    uint8_t *bytes = NULL;
    size_t   len   = 0;
    memset(&c, 0, sizeof c);
    ds_fact_t *ad = NULL, *ay = NULL, *x = NULL;
    uint64_t did = 0;
    CHECK(gone_tier(&a, "A", false), "the publisher");
    ds_slot_value_t dv = { .kind = DS_SLOT_INT, .v.i = 1 };
    CHECK(ds_engine_assert(a.e, a.d, &dv, 1, &ad).status == DS_OK
              && gone_ans(&a, 2, &ay).status == DS_OK
              && ad != NULL && ay != NULL
              && gone_pack(&a, a.rd, ad, ay, &bytes, &len),
          "it packs a fact referring to a D and an answer");
    CHECK(gone_tier(&c, "C", true), "the receiver");
    if (bytes == NULL || c.e == NULL) goto done;

    const ds_rete_schema_t *drs = ds_rete_schema_by_name(c.e->rete_engine, "D");
    CHECK(drs != NULL, "the receiver's D");
    if (drs == NULL) goto done;
    ds_rete_expr_t *v = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    v->var.pattern_index = 0;
    v->var.slot_index    = 1;
    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = v };
    ds_rete_action_t derive = {
        .kind = DS_RETE_ACTION_LOGICAL_ASSERT, .schema_id = drs->id,
        .assigns = &assign, .assign_count = 1
    };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Ans" }};
    ds_beta_atom_t betas[1] = {
        { .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 },
    };
    ds_term_atom_t terms[1] = {
        { .node_id = 3, .parent_beta_id = 2, .rule_name = "derive",
          .actions = &derive, .action_count = 1 },
    };
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    CHECK(ds_rete_load_network(c.e->rete_engine, &net).status == DS_OK,
          "the rule that derives D from an answer");

    CHECK(gone_ans(&c, 1, &x).status == DS_OK, "the receiver holds answer X");
    CHECK(ds_engine_pump(c.e).status == DS_OK, "and pumps");
    const ds_fact_t *d = only_fact(c.e, c.d);
    CHECK(d != NULL && ds_fact_get_id(d, &did).status == DS_OK,
          "premise: the rule derived D from X alone");

    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "the delivery returns DS_OK");
    CHECK(count_of(c.e, c.ans) == 1, "X is gone, and the new answer is live");
    CHECK(count_of(c.e, c.d) == 0, "and X's supersede cascaded into D");
    gone_check_referrer(only_fact(c.e, c.rd), did, "the received fact is live");
done:
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* ---- 19 ------------------------------------------------------------------- */

/* `F` refers to a `U`, `Fn` to a `U` or nothing, and `Fk`'s key is its reference.
   `R`, `Rn` and `Rk` refer to them, so a record of one inlines the copy under
   test. `Num` and the two `Doc`s are NCBK.10.4's refusals. */
typedef struct {
    ds_engine_t       *e;
    const ds_schema_t *u, *f, *fn, *fk, *r, *rn, *rk, *rr, *rrn, *rrk, *num, *doc, *docn;
} nt_t;

/* `Rr`, `Rrn` and `Rrk` refer to one target schema twice. */
static bool nt_refers_twice(nt_t *t, const char *name, const ds_schema_t *target,
                            const ds_schema_t **out)
{
    ds_slot_desc_t s[3] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
        { .name = "a", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = target,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "b", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = target,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    return ds_engine_register_schema(t->e, name, DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     s, 3, out).status == DS_OK;
}

static bool nt_refers(nt_t *t, const char *name, const ds_schema_t *target,
                      bool nullable, const ds_schema_t **out)
{
    ds_slot_desc_t s[2] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
        { .name = "to", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = target,
          .identity_role = DS_IDENTITY_MUTABLE, .nullable = nullable },
    };
    return ds_engine_register_schema(t->e, name, DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     s, 2, out).status == DS_OK;
}

static bool nt_keyed(nt_t *t, const char *name, ds_slot_type_t type, bool nullable,
                     const ds_schema_t **out)
{
    ds_slot_desc_t s[2] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
        { .name = "x", .type = type, .identity_role = DS_IDENTITY_MUTABLE,
          .nullable = nullable },
    };
    return ds_engine_register_schema(t->e, name, DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     s, 2, out).status == DS_OK;
}

static bool nt_tier(nt_t *t, const char *run_id)
{
    memset(t, 0, sizeof(*t));
    t->e = engine_new(run_id);
    if (t->e == NULL) return false;
    ds_slot_desc_t us[1] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
    };
    if (ds_engine_register_schema(t->e, "U", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, us, 1,
                                  &t->u).status != DS_OK)
        return false;
    ds_slot_desc_t ks[2] = {
        { .name = "to", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = t->u,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "v", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_MUTABLE },
    };
    return nt_refers(t, "F", t->u, false, &t->f)
        && nt_refers(t, "Fn", t->u, true, &t->fn)
        && ds_engine_register_schema(t->e, "Fk", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, ks, 2,
                                     &t->fk).status == DS_OK
        && nt_refers(t, "R", t->f, false, &t->r)
        && nt_refers(t, "Rn", t->fn, false, &t->rn)
        && nt_refers(t, "Rk", t->fk, false, &t->rk)
        && nt_refers_twice(t, "Rr", t->f, &t->rr)
        && nt_refers_twice(t, "Rrn", t->fn, &t->rrn)
        && nt_refers_twice(t, "Rrk", t->fk, &t->rrk)
        && nt_keyed(t, "Num", DS_SLOT_TYPE_INT, false, &t->num)
        && nt_keyed(t, "Doc", DS_SLOT_TYPE_JSON, false, &t->doc)
        && nt_keyed(t, "DocN", DS_SLOT_TYPE_JSON, true, &t->docn);
}

/* A fact of `schema`: k 1, referring to `target`. */
static ds_result_t nt_ref(nt_t *t, const ds_schema_t *schema, ds_fact_t *target,
                          ds_fact_t **out)
{
    ds_slot_value_t s[2] = {
        { .kind = DS_SLOT_INT,      .v.i   = 1 },
        { .kind = DS_SLOT_FACT_REF, .v.ref = target },
    };
    return ds_engine_assert(t->e, schema, s, 2, out);
}

static ds_result_t nt_u(nt_t *t, ds_fact_t **out)
{
    ds_slot_value_t k = { .kind = DS_SLOT_INT, .v.i = 1 };
    return ds_engine_assert(t->e, t->u, &k, 1, out);
}

/* A live fact of `schema` holding a reference whose target has gone. */
static bool nt_gone(nt_t *t, const ds_schema_t *schema, ds_fact_t **out)
{
    ds_fact_t *u = NULL;
    return nt_u(t, &u).status == DS_OK && u != NULL
        && nt_ref(t, schema, u, out).status == DS_OK && *out != NULL
        && ds_engine_retract(t->e, u).status == DS_OK;
}

/* `Fk`: its key refers to `target`, with `v` beside it. */
static ds_result_t nt_fk(nt_t *t, ds_fact_t *target, int64_t v, ds_fact_t **out)
{
    ds_slot_value_t s[2] = {
        { .kind = DS_SLOT_FACT_REF, .v.ref = target },
        { .kind = DS_SLOT_INT,      .v.i   = v },
    };
    return ds_engine_assert(t->e, t->fk, s, 2, out);
}

/* A publisher's referrer of `outer`, packed, inlining `inner` as KIND_NULL in the
   slot whose target has gone. */
static bool nt_pack(nt_t *t, const ds_schema_t *outer, const ds_schema_t *inner,
                    uint8_t **bytes, size_t *len)
{
    ds_fact_t *f = NULL, *r = NULL;
    return nt_gone(t, inner, &f)
        && nt_ref(t, outer, f, &r).status == DS_OK && r != NULL
        && ds_fact_external_pack(r, bytes, len).status == DS_OK;
}

static uint64_t nt_id(const ds_fact_t *f)
{
    uint64_t id = 0;
    if (f != NULL) ds_fact_get_id(f, &id);
    return id;
}

/* A run a host makes: `U`, a fact referring to it, the `U` retracted, and an
   outer fact referring to the first. The recorder writes the last as one
   ExternalAssert inlining the first with KIND_NULL ([RFCS.23.4], [RFCS.24.1]).
   THE PATH on replay: fx_field's KIND_NULL arm, then fx_live_equal, where the copy
   equals the live fact whose target has gone, so nothing is asserted for it. */
static void nt_replay(bool nullable)
{
    nt_t c, r;
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    static uint8_t            strbuf[1024];
    memset(&cap, 0, sizeof cap);
    memset(&r, 0, sizeof r);
    CHECK(nt_tier(&c, "C"), "the recorded engine");
    CHECK(nt_tier(&r, "C"), "the replaying engine");
    if (c.e == NULL || r.e == NULL) goto done;
    const ds_schema_t *cinner = nullable ? c.fn : c.f;
    const ds_schema_t *couter = nullable ? c.rn : c.r;
    CHECK(ds_rfcs_record_to(c.e, &rec, capture_sink, &cap, buf, sizeof buf)
              .status == DS_OK, "the engine records");
    ds_fact_t *f = NULL, *o = NULL;
    CHECK(nt_gone(&c, cinner, &f), "a live fact whose target has gone");
    CHECK(nt_ref(&c, couter, f, &o).status == DS_OK && o != NULL,
          "and a host's fact referring to it");
    CHECK(ds_engine_set_stream_callback(c.e, NULL, NULL).status == DS_OK
              && rec.last.status == DS_OK, "recording stops, with no failure");

    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof res);
    CHECK(ds_rfcs_replay(r.e, cap.bytes, cap.len, strbuf, sizeof strbuf,
                         &res).status == DS_OK,
          "the recording replays with no divergence ([RFCS.24.2])");
    const ds_schema_t *rinner = nullable ? r.fn : r.f;
    const ds_schema_t *router = nullable ? r.rn : r.r;
    CHECK(count_of(r.e, rinner) == 1, "there is no second copy");
    CHECK(nt_id(only_fact(r.e, rinner)) == nt_id(f), "the first has its own id");
    CHECK(nt_id(only_fact(r.e, router)) == nt_id(o), "and so has the outer fact");
    CHECK(ref_of(only_fact(r.e, router), 1) == only_fact(r.e, rinner),
          "the outer fact refers to the first");
done:
    ds_engine_free(r.e);
    ds_engine_free(c.e);
}

/* @spec [RFCS.23.7] */
static void test_rfcs_23_7__a_replay_of_a_gone_nested_target(void)
{
    nt_replay(false);
    nt_replay(true);
}

/* `bytes` with the field `name` set to KIND_NULL, re-packed: `*out` is malloc'd. */
static bool with_null_field(const uint8_t *bytes, size_t len, const char *name,
                            uint8_t **out, size_t *out_len)
{
    Ds__V1__FactExternal *fe = ds__v1__fact_external__unpack(NULL, len, bytes);
    if (fe == NULL) return false;
    bool ok = false;
    for (size_t i = 0; i < fe->n_fields; i++) {
        Ds__V1__Arg *f = fe->fields[i];
        if (strcmp(f->name, name) != 0) continue;
        f->kind = DS__V1__KIND__KIND_NULL;
        f->value_case = DS__V1__ARG__VALUE__NOT_SET;
        size_t n = ds__v1__fact_external__get_packed_size(fe);
        *out = malloc(n);
        if (*out != NULL) {
            *out_len = ds__v1__fact_external__pack(fe, *out);
            ok = *out_len == n;
        }
        break;
    }
    ds__v1__fact_external__free_unpacked(fe, NULL);
    return ok;
}

/* @spec [RFCS.23.7] @spec [NCBK.10.4]
   The control: only a fact-reference slot takes KIND_NULL unasked. THE PATH:
   fx_field's KIND_NULL arm, past its schema-slot branch. The record unpatched
   is admitted, so the refusal is the field's. */
static void test_rfcs_23_7__null_elsewhere_stays_refused(void)
{
    nt_t a, c;
    uint8_t *bytes = NULL, *bad = NULL;
    size_t   len = 0, bad_len = 0;
    memset(&c, 0, sizeof c);
    CHECK(nt_tier(&a, "A"), "the publisher");
    CHECK(nt_tier(&c, "C"), "the receiver");
    ds_slot_value_t s[2] = {
        { .kind = DS_SLOT_INT, .v.i = 1 },
        { .kind = DS_SLOT_INT, .v.i = 5 },
    };
    ds_fact_t *n = NULL;
    CHECK(ds_engine_assert(a.e, a.num, s, 2, &n).status == DS_OK && n != NULL
              && ds_fact_external_pack(n, &bytes, &len).status == DS_OK
              && with_null_field(bytes, len, "x", &bad, &bad_len),
          "a Num, and the same with KIND_NULL in its Int slot");
    if (bad == NULL) goto done;
    CHECK(ds_engine_assert_external(c.e, bad, bad_len).status
              == DS_ERR_SLOT_TYPE_MISMATCH,
          "KIND_NULL in a non-nullable Int slot is a mismatch");
    CHECK(fact_count(c.e) == 0, "and nothing is asserted");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "the record unpatched is admitted");
done:
    free(bad);
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* @spec [RFCS.23.7]
   A copy holding KIND_NULL against a live slot that is null and against one whose
   target has gone, the same fact, and against one whose target is live, not the
   same fact: its key is taken, so step 3 refuses. THE PATH: fx_resolve, through
   fx_live_equal and fx_key_taken. With nothing live the copy is asserted, and its
   slot refers to no fact. */
static void test_rfcs_23_7__a_no_target_copy_against_a_live_slot(void)
{
    nt_t a, c;
    uint8_t *to_f = NULL, *to_fn = NULL;
    size_t   f_len = 0, fn_len = 0;
    memset(&c, 0, sizeof c);
    CHECK(nt_tier(&a, "A"), "the publisher");
    CHECK(nt_pack(&a, a.r, a.f, &to_f, &f_len)
              && nt_pack(&a, a.rn, a.fn, &to_fn, &fn_len),
          "it packs an R and an Rn, each inlining a copy with no target");
    if (to_f == NULL || to_fn == NULL) goto done;

    /* A live slot that is null. */
    CHECK(nt_tier(&c, "C"), "the receiver");
    ds_slot_value_t nulled[2] = {
        { .kind = DS_SLOT_INT, .v.i = 1 },
        { .kind = DS_SLOT_NULL },
    };
    ds_fact_t *live = NULL;
    CHECK(ds_engine_assert(c.e, c.fn, nulled, 2, &live).status == DS_OK,
          "a live Fn whose slot is null");
    CHECK(ds_engine_assert_external(c.e, to_fn, fn_len).status == DS_OK,
          "the record is admitted");
    CHECK(count_of(c.e, c.fn) == 1 && ref_of(only_fact(c.e, c.rn), 1) == live,
          "the copy is that fact");
    ds_engine_free(c.e);

    /* A live slot whose target has gone, in either kind of slot. */
    CHECK(nt_tier(&c, "C"), "the receiver");
    CHECK(nt_gone(&c, c.f, &live), "a live F whose target has gone");
    CHECK(ds_engine_assert_external(c.e, to_f, f_len).status == DS_OK,
          "the record is admitted");
    CHECK(count_of(c.e, c.f) == 1 && ref_of(only_fact(c.e, c.r), 1) == live,
          "the copy is that fact");
    ds_engine_free(c.e);

    CHECK(nt_tier(&c, "C"), "the receiver");
    CHECK(nt_gone(&c, c.fn, &live), "a live Fn whose target has gone");
    CHECK(ds_engine_assert_external(c.e, to_fn, fn_len).status == DS_OK,
          "the record is admitted");
    CHECK(count_of(c.e, c.fn) == 1 && ref_of(only_fact(c.e, c.rn), 1) == live,
          "the copy is that fact");
    ds_engine_free(c.e);

    /* A live slot whose target is live. */
    CHECK(nt_tier(&c, "C"), "the receiver");
    ds_fact_t *u = NULL;
    CHECK(nt_u(&c, &u).status == DS_OK
              && nt_ref(&c, c.f, u, &live).status == DS_OK,
          "a live F whose target is live");
    CHECK(ds_engine_assert_external(c.e, to_f, f_len).status
              == DS_ERR_FACT_REF_CONFLICT,
          "the copy is not that fact, and the key is taken");
    CHECK(count_of(c.e, c.r) == 0, "nothing is asserted");
    ds_engine_free(c.e);

    /* Nothing live: the copy is asserted. */
    CHECK(nt_tier(&c, "C"), "the receiver");
    CHECK(ds_engine_assert_external(c.e, to_f, f_len).status == DS_OK,
          "the record is admitted with nothing live");
    const ds_fact_t *copy = only_fact(c.e, c.f);
    uint64_t named = 99;
    CHECK(copy != NULL && ref_of(copy, 1) == NULL
              && ds_fact_get_slot_ref_id(copy, 1, &named).status == DS_OK
              && named == 0,
          "the copy's slot refers to no fact, and names none");
    CHECK(ref_of(only_fact(c.e, c.r), 1) == copy, "and R refers to the copy");
done:
    ds_free(to_f);
    ds_free(to_fn);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* An honest publisher's `Outer`, both slots on one `Inner` whose target has gone,
   so its record carries two identical copies with KIND_NULL. Nothing is live on
   the receiver. */
static void nt_inlined_twice(bool nullable)
{
    nt_t a, c;
    uint8_t *bytes = NULL;
    size_t   len = 0;
    memset(&c, 0, sizeof c);
    CHECK(nt_tier(&a, "A"), "the publisher");
    ds_fact_t *f = NULL, *o = NULL;
    CHECK(nt_gone(&a, nullable ? a.fn : a.f, &f), "one fact whose target has gone");
    ds_slot_value_t s[3] = {
        { .kind = DS_SLOT_INT,      .v.i   = 1 },
        { .kind = DS_SLOT_FACT_REF, .v.ref = f },
        { .kind = DS_SLOT_FACT_REF, .v.ref = f },
    };
    CHECK(ds_engine_assert(a.e, nullable ? a.rrn : a.rr, s, 3, &o).status == DS_OK
              && o != NULL
              && ds_fact_external_pack(o, &bytes, &len).status == DS_OK,
          "and a fact referring to it twice, packed");
    if (bytes == NULL) goto done;

    CHECK(nt_tier(&c, "C"), "the receiver");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "the record is admitted: the second copy is the first, not a key conflict");
    const ds_schema_t *inner = nullable ? c.fn : c.f;
    const ds_schema_t *outer = nullable ? c.rrn : c.rr;
    CHECK(count_of(c.e, inner) == 1, "exactly one copy is asserted");
    const ds_fact_t *copy = only_fact(c.e, inner);
    const ds_fact_t *got  = only_fact(c.e, outer);
    CHECK(copy != NULL && ref_of(copy, 1) == NULL, "its slot refers to no fact");
    CHECK(got != NULL && ref_of(got, 1) == copy && ref_of(got, 2) == copy,
          "and both slots of the received fact refer to it");
done:
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* @spec [RFCS.23.7]
   One no-target copy inlined twice, in a non-nullable slot and a nullable one.
   THE PATH: fx_resolve's search for an equal earlier node, through fx_pair_vals.
   Were the second copy not the first, fx_key_taken's planned arm would find its
   key taken: DS_ERR_FACT_REF_CONFLICT. */
static void test_rfcs_23_7__a_no_target_copy_inlined_twice(void)
{
    nt_inlined_twice(false);
    nt_inlined_twice(true);
}

/* @spec [RFCS.23.7]
   A no-target slot in a key: equal to a live key whose target has gone, in step 1
   and in step 3's identity comparison, and not to a live key whose target is live.
   THE PATH: fx_live_equal, and fx_key_taken's live arm. */
static void test_rfcs_23_7__a_no_target_key(void)
{
    nt_t a, c;
    uint8_t *bytes = NULL;
    size_t   len = 0;
    memset(&c, 0, sizeof c);
    ds_fact_t *u = NULL, *f = NULL, *o = NULL;
    CHECK(nt_tier(&a, "A"), "the publisher");
    CHECK(nt_u(&a, &u).status == DS_OK && nt_fk(&a, u, 1, &f).status == DS_OK
              && ds_engine_retract(a.e, u).status == DS_OK
              && nt_ref(&a, a.rk, f, &o).status == DS_OK && o != NULL
              && ds_fact_external_pack(o, &bytes, &len).status == DS_OK,
          "it packs an Rk inlining an Fk(no target, 1)");
    if (bytes == NULL) goto done;

    CHECK(nt_tier(&c, "C"), "the receiver");
    CHECK(nt_u(&c, &u).status == DS_OK && nt_fk(&c, u, 1, &f).status == DS_OK
              && ds_engine_retract(c.e, u).status == DS_OK,
          "a live Fk(gone, 1)");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "the record is admitted");
    CHECK(count_of(c.e, c.fk) == 1 && ref_of(only_fact(c.e, c.rk), 1) == f,
          "the copy is that fact");
    ds_engine_free(c.e);

    CHECK(nt_tier(&c, "C"), "the receiver");
    CHECK(nt_u(&c, &u).status == DS_OK && nt_fk(&c, u, 2, &f).status == DS_OK
              && ds_engine_retract(c.e, u).status == DS_OK,
          "a live Fk(gone, 2)");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status
              == DS_ERR_FACT_REF_CONFLICT,
          "the key is that fact's, with values that differ");
    CHECK(count_of(c.e, c.rk) == 0, "nothing is asserted");
    ds_engine_free(c.e);

    CHECK(nt_tier(&c, "C"), "the receiver");
    CHECK(nt_u(&c, &u).status == DS_OK && nt_fk(&c, u, 1, &f).status == DS_OK,
          "a live Fk(live, 1)");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "its key is another's");
    CHECK(count_of(c.e, c.fk) == 2, "so the copy is asserted beside it");
done:
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* A publisher's `Rrk`, packed, referring to two `Fk`s whose key targets have both
   gone, with `v1` and `v2`: two copies of one no-target key. */
static bool nt_two_gone_keys(nt_t *t, int64_t v1, int64_t v2, uint8_t **bytes, size_t *len)
{
    ds_slot_value_t k2 = { .kind = DS_SLOT_INT, .v.i = 2 };
    ds_fact_t *u1 = NULL, *u2 = NULL, *f1 = NULL, *f2 = NULL, *o = NULL;
    if (nt_u(t, &u1).status != DS_OK
        || ds_engine_assert(t->e, t->u, &k2, 1, &u2).status != DS_OK
        || nt_fk(t, u1, v1, &f1).status != DS_OK
        || nt_fk(t, u2, v2, &f2).status != DS_OK
        || ds_engine_retract(t->e, u1).status != DS_OK
        || ds_engine_retract(t->e, u2).status != DS_OK)
        return false;
    ds_slot_value_t s[3] = {
        { .kind = DS_SLOT_INT,      .v.i   = 1 },
        { .kind = DS_SLOT_FACT_REF, .v.ref = f1 },
        { .kind = DS_SLOT_FACT_REF, .v.ref = f2 },
    };
    return ds_engine_assert(t->e, t->rrk, s, 3, &o).status == DS_OK && o != NULL
        && ds_fact_external_pack(o, bytes, len).status == DS_OK;
}

/* @spec [RFCS.23.7]
   One record inlining two copies of `Fk` whose key slots are both KIND_NULL: with
   different `v` the key is the earlier copy's, with values that differ, so step 3
   refuses and nothing is asserted. THE CONTROL: with one `v` the second copy is the
   first, so the refusal is the differing value's. THE PATH: fx_key_taken's planned
   arm, where both sides are no-target. */
static void test_rfcs_23_7__two_copies_of_one_no_target_key(void)
{
    nt_t a, c;
    uint8_t *bytes = NULL;
    size_t   len = 0;
    memset(&c, 0, sizeof c);
    CHECK(nt_tier(&a, "A"), "the publisher");
    CHECK(nt_two_gone_keys(&a, 1, 2, &bytes, &len), "it packs copies with v 1 and 2");
    if (bytes == NULL) goto done;
    CHECK(nt_tier(&c, "C"), "the receiver");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_ERR_FACT_REF_CONFLICT,
          "the second copy's key is the first's, with values that differ");
    CHECK(count_of(c.e, c.fk) == 0 && count_of(c.e, c.rrk) == 0, "nothing is asserted");
    ds_free(bytes);
    bytes = NULL;
    ds_engine_free(c.e);
    ds_engine_free(a.e);

    memset(&c, 0, sizeof c);
    CHECK(nt_tier(&a, "A"), "the publisher");
    CHECK(nt_two_gone_keys(&a, 1, 1, &bytes, &len), "it packs copies with v 1 and 1");
    if (bytes == NULL) goto done;
    CHECK(nt_tier(&c, "C"), "the receiver");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "the same record with one v is admitted");
    CHECK(count_of(c.e, c.fk) == 1, "the second copy is the first");
    const ds_fact_t *copy = only_fact(c.e, c.fk);
    const ds_fact_t *got  = only_fact(c.e, c.rrk);
    CHECK(got != NULL && copy != NULL && ref_of(got, 1) == copy && ref_of(got, 2) == copy,
          "and both slots refer to it");
done:
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* @spec [RFCS.23.7]
   The received fact itself holding KIND_NULL, against a live fact whose target has
   gone: "a live fact equal to it makes it a no-op reassertion". THE PATH:
   fx_top_no_target, which gives the assert the id the live slot names, so its own
   comparison finds the two equal. */
static void test_rfcs_23_7__a_received_fact_with_no_target_is_a_no_op(void)
{
    nt_t a, c;
    uint8_t *bytes = NULL;
    size_t   len = 0;
    memset(&c, 0, sizeof c);
    ds_fact_t *f = NULL, *live = NULL;
    CHECK(nt_tier(&a, "A"), "the publisher");
    CHECK(nt_gone(&a, a.f, &f)
              && ds_fact_external_pack(f, &bytes, &len).status == DS_OK,
          "it packs an F whose target has gone");
    CHECK(nt_tier(&c, "C"), "the receiver");
    if (bytes == NULL || c.e == NULL) goto done;
    CHECK(nt_gone(&c, c.f, &live), "a live F whose target has gone");
    uint64_t was = 0, now = 0;
    CHECK(ds_fact_get_slot_ref_id(live, 1, &was).status == DS_OK && was != 0,
          "its slot names the gone fact");
    uint64_t id = nt_id(live);
    CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
          "the record is admitted");
    const ds_fact_t *after = only_fact(c.e, c.f);
    CHECK(nt_id(after) == id, "the live fact stands");
    CHECK(after != NULL && ds_fact_get_slot_ref_id(after, 1, &now).status == DS_OK
              && now == was,
          "and its slot names what it named");
done:
    ds_free(bytes);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* @spec [NCBK.10.4]
   A Json field's document that is null at its root is DS_ERR_SLOT_TYPE_MISMATCH
   in a non-nullable slot and in a `Json?`, and nothing is asserted: a `null` slot
   travels as KIND_NULL. THE PATH: fx_field's KIND_JSON arm. The record
   unpatched is admitted, so the refusal is the document's. */
static void test_ncbk_10_4__a_root_null_json_field_is_refused(void)
{
    nt_t a, c;
    memset(&c, 0, sizeof c);
    CHECK(nt_tier(&a, "A"), "the publisher");
    CHECK(nt_tier(&c, "C"), "the receiver");
    ds_json_t *tree = NULL;
    CHECK(ds_json_new_string("a", 1, &tree).status == DS_OK, "a Json value");
    for (int nullable = 0; tree != NULL && nullable < 2; nullable++) {
        uint8_t *bytes = NULL, *bad = NULL;
        size_t   len = 0, bad_len = 0;
        ds_slot_value_t s[2] = {
            { .kind = DS_SLOT_INT,  .v.i    = 1 },
            { .kind = DS_SLOT_JSON, .v.json = tree },
        };
        ds_fact_t *d = NULL;
        const ds_schema_t *as = nullable ? a.docn : a.doc;
        CHECK(ds_engine_assert(a.e, as, s, 2, &d).status == DS_OK && d != NULL
                  && ds_fact_external_pack(d, &bytes, &len).status == DS_OK
                  && with_json_text(bytes, len, "null", &bad, &bad_len),
              "a Doc, and the same with its text `null`");
        if (bad != NULL) {
            size_t before = fact_count(c.e);
            CHECK(ds_engine_assert_external(c.e, bad, bad_len).status
                      == DS_ERR_SLOT_TYPE_MISMATCH,
                  "a root-null document is a mismatch");
            CHECK(fact_count(c.e) == before, "and nothing is asserted");
            CHECK(ds_engine_assert_external(c.e, bytes, len).status == DS_OK,
                  "the record unpatched is admitted");
        }
        free(bad);
        ds_free(bytes);
    }
    ds_json_free(tree);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* ---- 19 ------------------------------------------------------------------- */

/* `Ref`, a schema `Inner` of the test's shape, and `Holder`, which refers to one
   of each, so a record of a Holder is the Ref's copy, then the Inner's, then
   the Holder: post-order, as the plan walks it. */
typedef struct {
    ds_engine_t       *e;
    const ds_schema_t *ref, *inner, *holder;
} pr_t;

static bool pr_tier(pr_t *t, const char *run_id, const char *inner_name,
                    ds_schema_lifecycle_t lifecycle, uint64_t ttl_ns,
                    const ds_slot_desc_t *slots, uint32_t n)
{
    memset(t, 0, sizeof *t);
    t->e = engine_new(run_id);
    if (t->e == NULL) return false;
    ds_slot_desc_t rs[2] = {
        { .name = "id",   .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
        { .name = "note", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_MUTABLE },
    };
    if (ds_engine_register_schema(t->e, "Ref", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  rs, 2, &t->ref).status != DS_OK
            || ds_engine_register_schema(t->e, inner_name, lifecycle, ttl_ns,
                                         slots, n, &t->inner).status != DS_OK)
        return false;
    ds_slot_desc_t hs[3] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
        { .name = "a", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = t->ref,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "b", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = t->inner,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    return ds_engine_register_schema(t->e, "Holder", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                     0, hs, 3, &t->holder).status == DS_OK;
}

/* A Holder of a Ref and an Inner of these values, packed. */
static bool pr_pack(pr_t *t, const ds_slot_value_t *inner, uint32_t n,
                    uint8_t **bytes, size_t *len)
{
    ds_slot_value_t rv[2] = {
        { .kind = DS_SLOT_STRING, .v.s = "r1" },
        { .kind = DS_SLOT_STRING, .v.s = "hello" },
    };
    ds_fact_t *r = NULL, *i = NULL, *h = NULL;
    if (ds_engine_assert(t->e, t->ref, rv, 2, &r).status != DS_OK
            || ds_engine_assert(t->e, t->inner, inner, n, &i).status != DS_OK
            || r == NULL || i == NULL)
        return false;
    ds_slot_value_t hv[3] = {
        { .kind = DS_SLOT_INT,      .v.i   = 1 },
        { .kind = DS_SLOT_FACT_REF, .v.ref = r },
        { .kind = DS_SLOT_FACT_REF, .v.ref = i },
    };
    return ds_engine_assert(t->e, t->holder, hv, 3, &h).status == DS_OK
        && h != NULL && ds_fact_external_pack(h, bytes, len).status == DS_OK;
}

/* The refusal the three tests share: the status, and nothing else moved. The
   recorder only appends, and the sample is what the first step sets. */
static void pr_expect_refused(pr_t *c, const uint8_t *bytes, size_t len,
                              ds_status_t want, const char *what)
{
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    memset(&cap, 0, sizeof cap);
    CHECK(ds_rfcs_record_to(c->e, &rec, capture_sink, &cap, buf, sizeof buf)
              .status == DS_OK, "the receiver records");
    const size_t before = cap.len;
    CHECK(ds_engine_assert_external(c->e, bytes, len).status == want, what);
    CHECK(fact_count(c->e) == 0, "nothing is asserted, the first copy included");
    CHECK(!c->e->clock.sampled, "no sample is taken ([LTIM.2.8.4])");
    CHECK(cap.len == before,
          "nothing reaches the stream, no BoundsError included ([RFCS.24.1])");
    CHECK(ds_engine_set_stream_callback(c->e, NULL, NULL).status == DS_OK,
          "recording stops");
}

/* @spec [NCBK.10.4]
   The honest route to a value over capacity: `capacity` is outside schema_hash
   ([RFCS.23.3]), so a publisher that declares none sends what the receiver's
   Line cannot hold. A capacity is white-box here, as test_rfcs_replay.c's
   register_line sets it: the public registration takes none. PATH:
   fx_deliver -> fx_plan_judge -> ds_rete_slot_over_capacity, before the sample.
   The Mercury runtime's twin is test_ds.m's check_ncbk_10_4_plan_refusals. */
static void test_ncbk_10_4__a_value_over_capacity_refuses_the_record(void)
{
    static const ds_slot_desc_t LINE[2] = {
        { .name = "k",    .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_KEY },
        { .name = "text", .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_MUTABLE },
    };
    pr_t a, c, ok;
    uint8_t *bytes = NULL;
    size_t   len = 0;
    memset(&c, 0, sizeof c);
    memset(&ok, 0, sizeof ok);
    CHECK(pr_tier(&a, "A", "Line", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, LINE, 2),
          "the publisher, its Line unbounded");
    ds_slot_value_t v[2] = {
        { .kind = DS_SLOT_INT,    .v.i = 1 },
        { .kind = DS_SLOT_STRING, .v.s = "four" },
    };
    CHECK(pr_pack(&a, v, 2, &bytes, &len), "it packs a Holder of a long Line");
    CHECK(pr_tier(&c, "C", "Line", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, LINE, 2)
              && pr_tier(&ok, "K", "Line", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, LINE, 2),
          "the receivers");
    if (bytes == NULL || c.e == NULL || ok.e == NULL) goto done;

    const ds_rete_schema_t *crs = ds_rete_schema_by_name(c.e->rete_engine, "Line");
    const ds_rete_schema_t *krs = ds_rete_schema_by_name(ok.e->rete_engine, "Line");
    CHECK(crs != NULL && krs != NULL, "each receiver's Line is in the network");
    if (crs == NULL || krs == NULL) goto done;
    crs->slots[1].capacity = 3;
    krs->slots[1].capacity = 4;

    pr_expect_refused(&c, bytes, len, DS_ERR_CONTRACT_BREACH,
                      "four codepoints into a capacity of 3 is -710");
    CHECK(ds_engine_assert_external(ok.e, bytes, len).status == DS_OK,
          "the control: a capacity of 4 admits it");
    CHECK(fact_count(ok.e) == 3, "and all three facts are asserted");
done:
    ds_free(bytes);
    ds_engine_free(ok.e);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* `bytes` with the Int field `name` of the first nested fact holding one set to
   `value`. A publisher cannot hold the value, as with_int_field's. */
static bool fe_set_nested_int(Ds__V1__FactExternal *fe, const char *name,
                              int64_t value, bool nested)
{
    for (size_t i = 0; i < fe->n_fields; i++) {
        Ds__V1__Arg *f = fe->fields[i];
        if (nested && strcmp(f->name, name) == 0
                && f->value_case == DS__V1__ARG__VALUE_INT_VALUE) {
            f->int_value = value;
            return true;
        }
        if (f->value_case == DS__V1__ARG__VALUE_FACT
                && fe_set_nested_int(f->fact, name, value, true))
            return true;
    }
    return false;
}

static bool with_nested_int(const uint8_t *bytes, size_t len, const char *name,
                            int64_t value, uint8_t **out, size_t *out_len)
{
    Ds__V1__FactExternal *fe = ds__v1__fact_external__unpack(NULL, len, bytes);
    if (fe == NULL) return false;
    bool ok = fe_set_nested_int(fe, name, value, false);
    if (ok) {
        size_t n = ds__v1__fact_external__get_packed_size(fe);
        *out = malloc(n);
        ok = *out != NULL;
        if (ok) {
            *out_len = ds__v1__fact_external__pack(fe, *out);
            ok = *out_len == n;
        }
    }
    ds__v1__fact_external__free_unpacked(fe, NULL);
    return ok;
}

/* @spec [NCBK.10.4]
   [LTIM.10.9]'s row, past the eighteen hours, in the copy after the Ref. PATH:
   fx_plan_judge -> ds_wm_tz_row_malformed, the check the host's door asks. The
   schema is registered here as test_nfct_2_11_refusal_order.c does; a loaded
   artefact registers the ambient one in the same registry (dsc/loader.c). */
static void test_ncbk_10_4__a_malformed_time_zone_offset_refuses_the_record(void)
{
    static const ds_slot_desc_t TZO[4] = {
        { .name = "zone",        .type = DS_SLOT_TYPE_STRING, .identity_role = DS_IDENTITY_KEY },
        { .name = "valid_from",  .type = DS_SLOT_TYPE_TIME,   .identity_role = DS_IDENTITY_KEY },
        { .name = "valid_until", .type = DS_SLOT_TYPE_TIME,   .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "offset_s",    .type = DS_SLOT_TYPE_INT,    .identity_role = DS_IDENTITY_MUTABLE },
    };
    pr_t a, c, ok;
    uint8_t *bytes = NULL, *bad = NULL;
    size_t   len = 0, bad_len = 0;
    memset(&c, 0, sizeof c);
    memset(&ok, 0, sizeof ok);
    CHECK(pr_tier(&a, "A", "TimeZoneOffset", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, TZO, 4),
          "the publisher");
    ds_slot_value_t v[4] = {
        { .kind = DS_SLOT_STRING, .v.s = "Europe/London" },
        { .kind = DS_SLOT_INT,    .v.i = 0 },
        { .kind = DS_SLOT_INT,    .v.i = 100 },
        { .kind = DS_SLOT_INT,    .v.i = 3600 },
    };
    CHECK(pr_pack(&a, v, 4, &bytes, &len), "it packs a Holder of a good row");
    CHECK(bytes != NULL
              && with_nested_int(bytes, len, "offset_s", 64801, &bad, &bad_len),
          "the record with offset_s past 64800");
    CHECK(pr_tier(&c, "C", "TimeZoneOffset", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, TZO, 4)
              && pr_tier(&ok, "K", "TimeZoneOffset", DS_SCHEMA_LIFECYCLE_LOGICAL, 0, TZO, 4),
          "the receivers");
    if (bad == NULL || c.e == NULL || ok.e == NULL) goto done;

    pr_expect_refused(&c, bad, bad_len, DS_ERR_INVAL,
                      "a malformed TimeZoneOffset is DS_ERR_INVAL");
    CHECK(ds_engine_assert_external(ok.e, bytes, len).status == DS_OK,
          "the control: the record unpatched is admitted");
done:
    free(bad);
    ds_free(bytes);
    ds_engine_free(ok.e);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* @spec [NCBK.10.4]
   @spec [RFCS.6.7]
   A clock a second below the top, and a nested ttl schema of 60 s after a copy
   of a logical schema with no TTL. PATH: fx_deliver's one reading ->
   fx_plan_judge's deadline check. */
static void test_ncbk_10_4__a_ttl_deadline_out_of_range_refuses_the_record(void)
{
    static const ds_slot_desc_t LEASE[1] = {
        { .name = "id", .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_UNSPECIFIED },
    };
    pr_t a, c, ok;
    uint8_t *bytes = NULL;
    size_t   len = 0;
    memset(&c, 0, sizeof c);
    memset(&ok, 0, sizeof ok);
    CHECK(pr_tier(&a, "A", "Lease", DS_SCHEMA_LIFECYCLE_TTL, TTL_NS, LEASE, 1),
          "the publisher");
    ds_slot_value_t v[1] = { { .kind = DS_SLOT_STRING, .v.s = "l1" } };
    CHECK(pr_pack(&a, v, 1, &bytes, &len), "it packs a Holder of a Lease");
    CHECK(pr_tier(&c, "C", "Lease", DS_SCHEMA_LIFECYCLE_TTL, TTL_NS, LEASE, 1)
              && pr_tier(&ok, "K", "Lease", DS_SCHEMA_LIFECYCLE_TTL, TTL_NS, LEASE, 1),
          "the receivers");
    if (bytes == NULL || c.e == NULL || ok.e == NULL) goto done;

    CHECK(ds_engine_clock_set(c.e, (uint64_t) INT64_MAX - 1000000000ull).status
              == DS_OK, "the clock a second below the top");
    pr_expect_refused(&c, bytes, len, DS_ERR_TIME_RANGE,
                      "a deadline past the top is DS_ERR_TIME_RANGE");
    CHECK(ds_engine_assert_external(ok.e, bytes, len).status == DS_OK,
          "the control: at 0 the same record is admitted");
done:
    ds_free(bytes);
    ds_engine_free(ok.e);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* ---- 20 ------------------------------------------------------------------- */

/* A Main and its Ref, with an AlphaNode on Ref whose test names no slot of it
   ([RDSC.4a.9.1]): the Ref's propagation faults ARTEFACT_LIED and halts. */
static bool halting_tier(tier_t *t, const char *run_id)
{
    if (!tier_new(t, run_id, false, DS_SLOT_TYPE_FLOAT)) return false;
    const ds_retp_alpha_test_t bad = {
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 9, .op = DS_RETE_CMP_GT,
        .literal = ds_rete_val_int(42) };
    ds_retp_alpha_test_t tests[1] = { bad };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Ref",
                                 .tests = tests, .test_count = 1 }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1,
                                 .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "r" }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    return ds_rete_load_network(t->e->rete_engine, &net).status == DS_OK;
}

/* @spec [RFCS.24.2]
   @spec [NCBK.10.4]
   The inlined Ref's assert halts, with the Main still to assert. PATH, live:
   fx_deliver's second phase, whose next ds_engine_assert refuses on the latch.
   On replay: fcxt_apply -> fx_deliver, which hands over the ids asserted before
   the halt, so `fact_ids` compares (replay_halted_by), and the re-derived
   EngineError compares when its atom arrives. The Mercury runtime's twin is
   test_ds.m's check_rfcs_24_2_halted_part_way. */
static void test_rfcs_24_2__a_delivery_halted_part_way_replays(void)
{
    tier_t a, c, r;
    uint8_t *bytes = NULL;
    size_t   len = 0;
    static capture_t          cap;
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    static uint8_t            strbuf[1024];
    memset(&cap, 0, sizeof cap);
    memset(&c, 0, sizeof c);
    memset(&r, 0, sizeof r);
    CHECK(publisher(&a, &bytes, &len), "tier A packs its Main");
    CHECK(halting_tier(&c, "C"), "the receiver");
    CHECK(halting_tier(&r, "C"), "the replaying engine");
    if (bytes == NULL || c.e == NULL || r.e == NULL) goto done;

    CHECK(ds_rfcs_record_to(c.e, &rec, capture_sink, &cap, buf, sizeof buf)
              .status == DS_OK, "the receiver records");
    CHECK(ds_engine_assert_external(c.e, bytes, len).status
              == DS_ERR_ENGINE_HALTED,
          "the call reports the halt");
    size_t n = 0;
    CHECK(ds_wm_fact_count(&c.e->wm, &n).status == DS_OK && n == 1,
          "the Ref stands and the Main is not asserted");
    /* The recorder stays installed: ds_engine_set_stream_callback refuses a
       halted engine ([NCBK.2.9]), and no event can follow the halt. */
    CHECK(rec.last.status == DS_OK, "the recording has no failure");
    CHECK(ie_count(cap.bytes, cap.len, DS_ATOM_EXTERNAL_ASSERT) == 1,
          "one ExternalAssert: the engine admitted the delivery");
    CHECK(ie_count(cap.bytes, cap.len, DS_ATOM_ENGINE_ERROR) == 1,
          "and one EngineError");

    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof res);
    CHECK(ds_rfcs_replay(r.e, cap.bytes, cap.len, strbuf, sizeof strbuf,
                         &res).status == DS_OK,
          "the recording replays: no DS_ERR_FS_DIVERGENCE ([RFCS.24.2])");
    bool halted = false;
    CHECK(ds_engine_halted(r.e, &halted, NULL).status == DS_OK && halted,
          "the replay re-derived the halt");
done:
    ds_free(bytes);
    ds_engine_free(r.e);
    ds_engine_free(c.e);
    ds_engine_free(a.e);
}

/* ---- 21 ------------------------------------------------------------------- */

/* A one-slot `name`, in a new engine. */
static bool named_tier(ds_engine_t **e, const char *run_id, const char *name,
                       const ds_schema_t **schema)
{
    static const ds_slot_desc_t SLOT[1] = {
        { .name = "id", .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_KEY },
    };
    *e = engine_new(run_id);
    return *e != NULL
        && ds_engine_register_schema(*e, name, DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     SLOT, 1, schema).status == DS_OK;
}

/* @spec [LIMP.13.3]
   A library's schema and a program's of the same NAME and shape are two schemas:
   a record names its schema by its own name, and `Reply` is not `lib.Reply`.
   PATH: fx_deliver's schema lookup by the record's schema_name, an opaque key.
   The Mercury runtime's twin is test_ds.m's
   check_limp_13_3_a_program_schema_is_not_a_librarys. */
static void test_limp_13_3__a_program_schema_is_not_a_librarys(void)
{
    ds_engine_t *a = NULL, *c = NULL, *k = NULL;
    const ds_schema_t *sent = NULL, *mine = NULL, *same = NULL;
    uint8_t *bytes = NULL;
    size_t   len = 0;
    CHECK(named_tier(&a, "A", "lib.Reply", &sent), "the sender holds lib.Reply");
    CHECK(named_tier(&c, "C", "Reply", &mine), "the receiver declares its own Reply");
    CHECK(named_tier(&k, "K", "lib.Reply", &same), "the control holds lib.Reply");
    ds_slot_value_t v[1] = { { .kind = DS_SLOT_STRING, .v.s = "r1" } };
    ds_fact_t *f = NULL;
    CHECK(sent != NULL && ds_engine_assert(a, sent, v, 1, &f).status == DS_OK
              && f != NULL && ds_fact_external_pack(f, &bytes, &len).status == DS_OK,
          "it packs a lib.Reply");
    if (bytes == NULL || c == NULL || k == NULL) goto done;

    CHECK(ds_engine_assert_external(c, bytes, len).status == DS_ERR_SCHEMA_UNKNOWN,
          "a program's Reply is not lib.Reply: DS_ERR_SCHEMA_UNKNOWN");
    CHECK(fact_count(c) == 0, "and nothing is asserted");
    CHECK(ds_engine_assert_external(k, bytes, len).status == DS_OK,
          "the control: a receiver holding lib.Reply admits the record");
    CHECK(fact_count(k) == 1, "and asserts it");
done:
    ds_free(bytes);
    ds_engine_free(k);
    ds_engine_free(c);
    ds_engine_free(a);
}

/* @spec [NFCT.1.4.2]
   A host finds a schema by its own name and by nothing else: `lib.Reply` is one
   name to the registry, with no part of it a shorter name. pyds's and the JS
   binding's twins reach the name through a compile, with an alias. PATH:
   ds_schema_registry_find's whole-name compare. */
static void test_nfct_1_4_2__a_schema_is_found_by_its_own_name(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *reg = NULL;
    CHECK(named_tier(&e, "A", "lib.Reply", &reg), "lib.Reply is registered");
    if (e == NULL || reg == NULL) goto done;

    const ds_schema_t *found = NULL;
    CHECK(ds_engine_schema_find(e, "lib.Reply", &found).status == DS_OK
              && found == reg, "its own name finds it");
    const char *name = NULL;
    CHECK(ds_schema_get_name(reg, &name).status == DS_OK
              && name != NULL && strcmp(name, "lib.Reply") == 0,
          "and ds_schema_get_name answers it");
    const char *const others[] = { "Reply", "lib", "r.Reply", "lib.reply" };
    for (size_t i = 0; i < sizeof others / sizeof others[0]; i++) {
        found = reg;
        CHECK(ds_engine_schema_find(e, others[i], &found).status == DS_OK
                  && found == NULL, "no other spelling finds it");
    }
done:
    ds_engine_free(e);
}

int main(void)
{
    printf("=== test_assert_external ===\n");
    test_round_trip();
    test_sent_back_resolves_by_equality();
    test_sent_back_ttl_reference_is_not_copied();
    test_an_equal_fact_on_another_tier_is_that_fact();
    test_same_key_different_values_refuses_the_whole_record();
    test_one_fact_inlined_twice_is_one_fact();
    test_nesting_is_at_most_16_deep();
    test_a_record_nested_past_the_bound_is_refused_unread();
    test_refusals_assert_nothing();
    test_a_nul_in_a_text_field_refuses_the_record();
    test_a_received_json_field_has_its_own_text_limit();
    test_a_json_value_is_written_as_one_text();
    test_a_received_zero_has_no_sign();
    test_one_fact_external_is_one_input();
    test_temporal_slots_cross_as_int();
    test_a_date_outside_its_range_refuses_the_record();
    test_a_refused_delivery_records_nothing();
    test_no_ttl_travels();
    test_a_refused_first_external_delivery();
    test_an_initial_domain_fault_follows_the_input();
    test_rfcs_26_1__host_seeds_in_the_prelude_and_not_the_block();
    test_one_recorded_external_assert_binds_its_ids();
    test_one_fact_id_too_many_is_a_divergence();
    test_a_recorded_ttl_sets_the_received_deadline();
    test_apply_external_assert_refusals_apply_nothing();
    test_rfcs_23_7__a_live_target_superseded_by_the_delivery();
    test_rfcs_23_7__a_call_error_supersedes_a_target();
    test_rfcs_23_7__an_inlined_copy_superseded_by_the_delivery();
    test_rfcs_23_7__a_cascade_removes_a_target();
    test_rfcs_23_7__a_replay_of_a_gone_nested_target();
    test_rfcs_23_7__null_elsewhere_stays_refused();
    test_rfcs_23_7__a_no_target_copy_against_a_live_slot();
    test_rfcs_23_7__a_no_target_copy_inlined_twice();
    test_rfcs_23_7__a_no_target_key();
    test_rfcs_23_7__two_copies_of_one_no_target_key();
    test_rfcs_23_7__a_received_fact_with_no_target_is_a_no_op();
    test_ncbk_10_4__a_root_null_json_field_is_refused();
    test_ncbk_10_4__a_value_over_capacity_refuses_the_record();
    test_ncbk_10_4__a_malformed_time_zone_offset_refuses_the_record();
    test_ncbk_10_4__a_ttl_deadline_out_of_range_refuses_the_record();
    test_rfcs_24_2__a_delivery_halted_part_way_replays();
    test_limp_13_3__a_program_schema_is_not_a_librarys();
    test_nfct_1_4_2__a_schema_is_found_by_its_own_name();
    if (g_fails) {
        fprintf(stderr, "test_assert_external: %d FAILURE(S)\n", g_fails);
        return 1;
    }
    printf("=== test_assert_external: ALL PASSED ===\n");
    return 0;
}

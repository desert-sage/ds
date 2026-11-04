/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LFAC.2.5.3]
 * A host identity upsert refused after it retracted the fact it was replacing
 * ([LFAC.2.5.3]): ds_rete_wm_assert_ex retracts the old fact first.
 *   1. An allocation refused after the retract: the old fact and its wrapper
 *      are gone, its FACT_RETRACT is the one record of the call, and the next
 *      assert is wrapped as itself even at the freed address.
 *   2. N_max never refuses a replacement, since only an insert adds a live
 *      fact ([RTCT.7.1]), as Mercury's ds.exec wm_capped decides it; a fresh
 *      insert past the cap is still refused. N_max is advisory ([NRTM.3.1]),
 *      so it is set on the rete engine directly.
 *   3. [NCBK.10.4], which shares the refusing allocator.
 * A refusal by the insert or the network takes the allocation's exit
 * (rete/wm_rete.c, supersede_refused) and cannot be provoked without a defect.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "dispatcher.h"      /* ds_fact_external_pack (RFCS.23) is internal */
#include "engine.h"
#include "rete/engine.h"
#include "rete/fact.h"
#include "rete/val.h"

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

/* A strong ds_* set ([IALC.5]): libc, except that once armed it refuses the
   first request of exactly g_refuse_size bytes, then disarms. The size is the
   rete fact's for the Keyed schema below, so the refusal lands on
   ds_rete_wm_assert_ex's fact allocation; g_refused counts it, and the
   result's detail names the site. */
static size_t g_refuse_size;
static int    g_refused;

static bool refuse(size_t n)
{
    if (g_refuse_size != 0 && n == g_refuse_size) {
        g_refuse_size = 0;
        g_refused++;
        return true;
    }
    return false;
}

void *ds_malloc(size_t n)           { return refuse(n) ? NULL : malloc(n); }
void  ds_free(void *p)              { free(p); }
void *ds_calloc(size_t n, size_t sz)
{
    return (sz != 0 && n > SIZE_MAX / sz) || refuse(n * sz)
         ? NULL : calloc(n, sz);
}
void *ds_realloc(void *p, size_t n) { return refuse(n) ? NULL : realloc(p, n); }
char *ds_strdup(const char *s)      { return refuse(strlen(s) + 1) ? NULL : strdup(s); }
char *ds_strndup(const char *s, size_t n)
{
    return refuse(n + 1) ? NULL : strndup(s, n);
}

#define MAX_EV 16
static const ds_schema_t  *g_keyed = NULL;
static ds_stream_ev_kind_t g_kind[MAX_EV];
static uint64_t            g_id[MAX_EV];
static int                 g_n = 0;

static ds_result_t on_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void)e; (void)u;
    const ds_fact_t *f = NULL;
    if (ev->kind == DS_EV_FACT_ASSERT)       f = ev->p.fact_assert.fact;
    else if (ev->kind == DS_EV_FACT_RETRACT) f = ev->p.fact_retract.fact;
    if (f == NULL || g_n >= MAX_EV) return DS_OK_R;
    const ds_schema_t *sc = NULL;
    if (ds_fact_get_schema(f, &sc).status != DS_OK || sc != g_keyed)
        return DS_OK_R;
    g_kind[g_n] = ev->kind;
    (void)ds_fact_get_id(f, &g_id[g_n]);
    g_n++;
    return DS_OK_R;
}

/* Keyed(id KEY, level MUTABLE): the identity is `id`, so a changed `level`
   is an upsert. */
static const ds_slot_desc_t KEYED_SLOTS[2] = {
    { .name = "id",    .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_KEY },
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_MUTABLE },
};

static ds_engine_t *new_engine(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (e == NULL) return NULL;
    CHECK_OK(ds_engine_register_schema(e, "Keyed", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, KEYED_SLOTS, 2, &g_keyed),
             "register Keyed");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock 0");
    CHECK_OK(ds_engine_set_stream_callback(e, on_event, NULL), "stream cb");
    return e;
}

static ds_result_t assert_keyed(ds_engine_t *e, int64_t id, int64_t level,
                                ds_fact_t **out)
{
    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT; v[0].v.i = id;
    v[1].kind = DS_SLOT_INT; v[1].v.i = level;
    return ds_engine_assert(e, g_keyed, v, 2, out);
}

static uint64_t id_of(const ds_fact_t *f)
{
    uint64_t id = 0;
    CHECK_OK(ds_fact_get_id(f, &id), "fact_get_id");
    return id;
}

static size_t count(ds_engine_t *e)
{
    size_t n = 99;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
    return n;
}

static int64_t level_of(const ds_fact_t *f)
{
    ds_slot_value_t sv;
    if (ds_fact_get_slot(f, 1, NULL, &sv).status != DS_OK
            || sv.kind != DS_SLOT_INT)
        return -1;
    return sv.v.i;
}

static void test_allocation_refused_after_the_retract(void)
{
    ds_engine_t *e = new_engine();
    if (e == NULL) return;

    ds_fact_t *f1 = NULL;
    CHECK_OK(assert_keyed(e, 7, 10, &f1), "assert Keyed(7, 10)");
    CHECK_OK(ds_engine_pump(e), "pump");
    const uint64_t id1 = f1 ? id_of(f1) : 0;
    CHECK(count(e) == 1, "premise: one live Keyed");

    /* The upsert Keyed(7, 20): the rete side retracts Keyed(7, 10), then its
       fact allocation is refused. */
    g_n = 0;
    g_refused = 0;
    g_refuse_size = sizeof(ds_rete_fact_t) + 2 * sizeof(ds_rete_val_t);
    ds_fact_t *f2 = NULL;
    ds_result_t r = assert_keyed(e, 7, 20, &f2);
    g_refuse_size = 0;
    printf("  upsert: status=%d detail=%s refused=%d; %d Keyed event(s)\n",
           r.status, r.detail ? r.detail : "(null)", g_refused, g_n);

    CHECK(g_refused == 1, "premise: exactly one request was refused");
    CHECK(r.status == DS_ERR_OOM && r.detail != NULL
              && strcmp(r.detail, "wm_assert: fact alloc") == 0,
          "premise: the refusal is the rete fact's allocation, after the "
          "retract");
    CHECK(count(e) == 0,
          "the old fact's wrapper left with the old fact");
    ds_fact_t *found = (ds_fact_t *)(uintptr_t)1;
    CHECK(ds_engine_fact_find(e, id1, &found).status == DS_ERR_NOT_FOUND
              && found == NULL,
          "the old fact is not found by its id");
    CHECK(g_n == 1, "one Keyed event: the old fact's withdrawal");
    if (g_n >= 1)
        CHECK(g_kind[0] == DS_EV_FACT_RETRACT && g_id[0] == id1,
              "FACT_RETRACT of the old Keyed (RFCS.6.7)");

    /* The next assert is wrapped as itself. The fact pool is LIFO, so the new
       rete fact may take the freed address; a stale wrapper there would be
       found instead of a fresh one. */
    g_n = 0;
    ds_fact_t *f3 = NULL;
    CHECK_OK(assert_keyed(e, 8, 30, &f3), "assert Keyed(8, 30)");
    CHECK_OK(ds_engine_pump(e), "pump after");
    CHECK(count(e) == 1, "one live Keyed after the next assert");
    CHECK(f3 != NULL && id_of(f3) != id1 && level_of(f3) == 30,
          "the next assert's fact is its own: a fresh id and level 30");
    CHECK(g_n == 1 && g_kind[0] == DS_EV_FACT_ASSERT,
          "and its FACT_ASSERT is recorded");

    CHECK_OK(ds_engine_set_stream_callback(e, NULL, NULL), "stream cb off");
    ds_engine_free(e);
}

static void test_a_replacement_never_breaches_wm_max(void)
{
    ds_engine_t *e = new_engine();
    if (e == NULL) return;

    ds_fact_t *a = NULL, *b = NULL;
    CHECK_OK(assert_keyed(e, 7, 10, &a), "assert Keyed(7, 10)");
    CHECK_OK(assert_keyed(e, 8, 10, &b), "assert Keyed(8, 10)");
    CHECK_OK(ds_engine_pump(e), "pump");
    const uint64_t ida = a ? id_of(a) : 0;
    CHECK(count(e) == 2, "premise: two live Keyed");

    /* Working memory is now over its cap. */
    e->rete_engine->wm_max_facts = 1;

    g_n = 0;
    ds_fact_t *a2 = NULL;
    ds_result_t r = assert_keyed(e, 7, 20, &a2);
    printf("  upsert over the cap: status=%d detail=%s; %d Keyed event(s)\n",
           r.status, r.detail ? r.detail : "(null)", g_n);
    CHECK(r.status == DS_OK,
          "an upsert adds no live fact, so N_max does not refuse it "
          "([RTCT.7.1])");
    CHECK(count(e) == 2, "still two live Keyed");
    CHECK(a2 != NULL && id_of(a2) != ida && level_of(a2) == 20,
          "the replacement holds level 20 under a fresh id");
    CHECK(g_n == 2, "two Keyed events: the assert and the withdrawal");
    if (g_n == 2) {
        CHECK(g_kind[0] == DS_EV_FACT_ASSERT && a2 && g_id[0] == id_of(a2),
              "FACT_ASSERT of the new Keyed first (RFCS.6.7)");
        CHECK(g_kind[1] == DS_EV_FACT_RETRACT && g_id[1] == ida,
              "then FACT_RETRACT of the old one (RFCS.6.7)");
    }

    /* Positive control: an insert past the cap is still refused, and changes
       nothing. */
    ds_fact_t *c = NULL;
    r = assert_keyed(e, 9, 10, &c);
    CHECK(r.status == DS_ERR_WM_FULL, "a fresh insert past the cap is refused");
    CHECK(count(e) == 2, "and working memory is unchanged");

    e->rete_engine->wm_max_facts = 0;
    CHECK_OK(ds_engine_set_stream_callback(e, NULL, NULL), "stream cb off");
    ds_engine_free(e);
}

/* Arms the refusal as the first fact of the delivery reaches the stream, so
   nothing of the plan can take it. */
static ds_result_t arm_at_first_assert(ds_engine_t *e, const ds_stream_ev_t *ev,
                                       void *u)
{
    (void)e;
    if (ev->kind == DS_EV_FACT_ASSERT && *(size_t *)u != 0) {
        g_refuse_size = *(size_t *)u;
        *(size_t *)u = 0;
    }
    return DS_OK_R;
}

/* Keyed and `Holder(k KEY, r -> Keyed MUTABLE, x MUTABLE)`, whose three slots
   give its rete fact an allocation of a size of its own. */
static const ds_schema_t *register_holder(ds_engine_t *e)
{
    const ds_schema_t *keyed = NULL, *holder = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Keyed", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, KEYED_SLOTS, 2, &keyed),
             "register Keyed");
    g_keyed = keyed;
    ds_slot_desc_t hs[3] = {
        { .name = "k", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "r", .type = DS_SLOT_TYPE_SCHEMA, .schema_ref = keyed,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "x", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    CHECK_OK(ds_engine_register_schema(e, "Holder", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, hs, 3, &holder),
             "register Holder");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    return holder;
}

/* @spec [NCBK.10.4]
   Between its first assert and its last, a failed allocation stops a delivery:
   the call returns DS_ERR_OOM, the earlier copy stays live, and the engine runs
   on. PATH: fx_deliver's second phase, the Holder's ds_engine_assert, refused
   at ds_rete_wm_assert_ex's fact allocation after the Keyed copy is asserted.
   libds only: the Mercury runtime has no such failure (MERCURY.md 17.3). */
static void test_ncbk_10_4__a_failed_allocation_leaves_the_facts_asserted(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *a = NULL, *c = NULL;
    uint8_t *bytes = NULL;
    size_t   len = 0;
    CHECK_OK(ds_engine_new(&cfg, &a), "the publisher");
    CHECK_OK(ds_engine_new(&cfg, &c), "the receiver");
    if (a == NULL || c == NULL) goto done;
    const ds_schema_t *ah = register_holder(a);
    ds_fact_t *ak = NULL, *held = NULL;
    CHECK_OK(assert_keyed(a, 7, 10, &ak), "A's Keyed");
    ds_slot_value_t hv[3];
    memset(hv, 0, sizeof hv);
    hv[0].kind = DS_SLOT_INT;      hv[0].v.i   = 1;
    hv[1].kind = DS_SLOT_FACT_REF; hv[1].v.ref = ak;
    hv[2].kind = DS_SLOT_INT;      hv[2].v.i   = 2;
    CHECK_OK(ds_engine_assert(a, ah, hv, 3, &held), "A's Holder");
    if (held == NULL) goto done;
    CHECK_OK(ds_fact_external_pack(held, &bytes, &len), "A packs it");

    (void)register_holder(c);
    size_t arm = sizeof(ds_rete_fact_t) + 3 * sizeof(ds_rete_val_t);
    CHECK_OK(ds_engine_set_stream_callback(c, arm_at_first_assert, &arm),
             "the stream arms the refusal");
    g_refused = 0;
    ds_result_t r = ds_engine_assert_external(c, bytes, len);
    g_refuse_size = 0;
    CHECK(g_refused == 1, "premise: exactly one request was refused");
    CHECK(r.status == DS_ERR_OOM, "the call returns DS_ERR_OOM");
    CHECK(count(c) == 1, "the Keyed copy stays live and the Holder is not in");

    CHECK_OK(ds_engine_set_stream_callback(c, NULL, NULL), "stream cb off");
    ds_fact_t *next = NULL;
    CHECK_OK(assert_keyed(c, 8, 30, &next), "the next assert works");
    CHECK(count(c) == 2, "and is in working memory");
done:
    ds_free(bytes);
    if (c != NULL) ds_engine_free(c);
    if (a != NULL) ds_engine_free(a);
}

int main(void)
{
    test_allocation_refused_after_the_retract();
    test_a_replacement_never_breaches_wm_max();
    test_ncbk_10_4__a_failed_allocation_leaves_the_facts_asserted();
    if (failures) {
        fprintf(stderr, "test_lfac_2_5_3_host_upsert_refused: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_lfac_2_5_3_host_upsert_refused: OK\n");
    return 0;
}

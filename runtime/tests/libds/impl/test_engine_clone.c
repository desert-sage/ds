/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_engine_clone — ds_engine_clone end to end, the [NLFC.8.1] contract at
 * the engine level: the clone reproduces the source's facts
 * (id + value), the two engines are fully independent (a mutation on one never
 * touches the other), and either may be freed first with the other still
 * functional. The divergence check over a RULE-firing stream is the
 * [LDET.2.2b] conformance fixtures, `runtime/LDET.2.2b` and
 * `runtime/LDET.2.2b_free_clone` (`clone_determinism`); this pins the
 * structural clone of schemas + working memory + the DS wrapper layer +
 * free-in-any-order.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "oa.h"
#include "schema.h"
#include "rete/engine.h"
#include "rete/fact.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);    \
        g_fails++;                                                           \
    } } while (0)

static ds_result_t reg_relation(ds_engine_t *e, const char *name,
                                const ds_schema_t **out)
{
    /* key=all → relation: distinct slot values coexist (accumulate). */
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = DS_IDENTITY_KEY };
    return ds_engine_register_schema(e, name, DS_SCHEMA_LIFECYCLE_LOGICAL,
                                     0, &sd, 1, out);
}

static int assert_int(ds_engine_t *e, const ds_schema_t *sc, int64_t v)
{
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = v };
    return ds_engine_assert(e, sc, &sv, 1, NULL).status;
}

static size_t fact_count(ds_engine_t *e)
{
    size_t n = 0;
    ds_engine_fact_count(e, &n);
    return n;
}

/* Does the engine's rete WM hold a fact of `schema_name` with slot[0] == v? */
static bool has_fact(ds_engine_t *e, const char *schema_name, int64_t v)
{
    ds_rete_engine_t *re = e->rete_engine;
    for (uint32_t i = 0; i < oa_len(&re->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **) ds_oa_val_at(&re->wm_map, i);
        if (f && f->schema && f->schema->name &&
            strcmp(f->schema->name, schema_name) == 0 && f->slots[0].i == v)
            return true;
    }
    return false;
}

int main(void)
{
    g_fails = 0;
    ds_engine_config_t cfg = {0};

    ds_engine_t *src = NULL;
    CHECK(ds_engine_new(&cfg, &src).status == DS_OK, "engine_new");
    const ds_schema_t *sc = NULL;
    CHECK(reg_relation(src, "R", &sc).status == DS_OK, "register schema");
    for (int64_t v = 10; v <= 30; v += 10)
        CHECK(assert_int(src, sc, v) == DS_OK, "assert src fact");
    CHECK(fact_count(src) == 3, "src has 3 facts");

    /* ---- Clone ---- */
    ds_engine_t *clone = NULL;
    ds_result_t cr = ds_engine_clone(src, &clone);
    CHECK(cr.status == DS_OK && clone != NULL, "ds_engine_clone ok");
    if (clone == NULL) { printf("test_engine_clone: %d FAILURES\n", g_fails ? g_fails : 1); return 1; }

    /* Clone reproduces every fact (id preserved, values present). */
    CHECK(fact_count(clone) == 3, "clone has 3 facts");
    CHECK(clone->rete_engine->next_fact_id == src->rete_engine->next_fact_id,
          "clone continues fact-id counter verbatim");
    for (int64_t v = 10; v <= 30; v += 10)
        CHECK(has_fact(clone, "R", v), "clone has each source fact");
    /* Independent object graphs. */
    CHECK(clone != src && clone->rete_engine != src->rete_engine, "distinct engines");
    /* The rete engine's fire hooks report to the engine that owns it: the
       clone's firings reach the clone's recorder and stream callback, never
       the source's. */
    CHECK(clone->rete_engine->fire_hook_ctx == clone,
          "clone's fire hooks report to the clone");
    CHECK(src->rete_engine->fire_hook_ctx == src, "src's still report to src");

    /* ---- The clock is part of the state copied ([NLFC.8.1]) ---- */
    {
        ds_engine_t *m = NULL;
        CHECK(ds_engine_new(&cfg, &m).status == DS_OK, "engine_new (mock)");
        CHECK(ds_engine_clock_set_mode(m, DS_CLOCK_MOCK).status == DS_OK, "mock mode");
        CHECK(ds_engine_clock_set(m, 7000000000ULL).status == DS_OK, "mock at 7 s");
        ds_engine_t *mc = NULL;
        CHECK(ds_engine_clone(m, &mc).status == DS_OK && mc != NULL, "clone mock engine");
        if (mc != NULL) {
            uint64_t a = 0, b = 0;
            ds_engine_clock_now(m, &a);
            ds_engine_clock_now(mc, &b);
            CHECK(a == b && b == 7000000000ULL, "clone reads the source's mock clock");
            CHECK(ds_engine_clock_advance(mc, 1000000000ULL).status == DS_OK,
                  "clone stays on the mock clock");
            ds_engine_clock_now(m, &a);
            CHECK(a == 7000000000ULL, "advancing the clone leaves the source's clock");
            ds_engine_free(mc);
        }
        ds_engine_free(m);
    }

    /* ---- A leftover pending status is not "mid-pump" ----
       A pending status left in the slot between pumps does not make the
       engine mid-pump, so the clone is allowed ([NLFC.8.2]). */
    {
        ds_engine_t *p = NULL;
        CHECK(ds_engine_new(&cfg, &p).status == DS_OK, "engine_new (pending)");
        ds_engine_set_pending(p, DS_ERR_R(DS_ERR_ACTION_FAILED,
                                          "a handler failed during the pump"));
        ds_engine_t *pc = NULL;
        ds_result_t pr = ds_engine_clone(p, &pc);
        CHECK(pr.status == DS_OK && pc != NULL,
              "a quiescent engine with a stale pending status clones");
        if (pc != NULL) ds_engine_free(pc);
        ds_engine_free(p);
    }

    /* ---- The clone copies a schema; it does not re-check one ----
       A load builds schemas without ds_schema_new's checks
       (dsc_build_schema), so a schema ds_schema_new would refuse must still
       clone. The state is put here directly, so the case pins the copy and
       not any one refusal. */
    {
        ds_engine_t *t = NULL;
        CHECK(ds_engine_new(&cfg, &t).status == DS_OK, "engine_new (tolerance)");
        ds_slot_desc_t sd[2] = {
            { .name = "k", .type = DS_SLOT_TYPE_INT,
              .identity_role = DS_IDENTITY_KEY },
            { .name = "v", .type = DS_SLOT_TYPE_FLOAT,
              .identity_role = DS_IDENTITY_MUTABLE },
        };
        const ds_schema_t *ts = NULL;
        CHECK(ds_engine_register_schema(t, "Tol", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                        0, sd, 2, &ts).status == DS_OK && ts,
              "register Tol");
        if (ts != NULL) {
            ds_schema_t *tm = (ds_schema_t *) ts;   /* as the load builds it */
            tm->slots[1].has_tolerance = true;
            tm->slots[1].tolerance     = -1.0;
        }
        ds_engine_t *tc = NULL;
        ds_result_t tr = ds_engine_clone(t, &tc);
        CHECK(tr.status == DS_OK && tc != NULL,
              "an engine holding a schema ds_schema_new would refuse clones");
        if (tc != NULL) {
            const ds_schema_t *cts = NULL;
            ds_schema_registry_find(&tc->schemas, "Tol", &cts);
            CHECK(cts != NULL && cts->slots[1].has_tolerance
                      && cts->slots[1].tolerance == -1.0,
                  "the clone's schema is the source's, tolerance and all");
            ds_engine_free(tc);
        }
        ds_engine_free(t);
    }

    /* ---- Independence, both directions ---- */
    CHECK(assert_int(src, sc, 40) == DS_OK, "assert 40 into src");
    CHECK(fact_count(src) == 4, "src now 4");
    CHECK(fact_count(clone) == 3, "clone unaffected by src assert");
    CHECK(!has_fact(clone, "R", 40), "clone does not see src's new fact");

    /* Assert into the clone using ITS OWN schema handle (registries are copies). */
    const ds_schema_t *csc = NULL;
    ds_schema_registry_find(&clone->schemas, "R", &csc);
    CHECK(csc != NULL && csc != sc, "clone owns an independent schema");
    CHECK(assert_int(clone, csc, 50) == DS_OK, "assert 50 into clone");
    CHECK(fact_count(clone) == 4, "clone now 4");
    CHECK(fact_count(src) == 4, "src unaffected by clone assert");
    CHECK(!has_fact(src, "R", 50), "src does not see clone's new fact");

    /* ---- Free-in-any-order: free src, clone still fully functional ---- */
    CHECK(ds_engine_free(src).status == DS_OK, "free src first");
    CHECK(assert_int(clone, csc, 60) == DS_OK, "clone still works after src freed");
    CHECK(fact_count(clone) == 5, "clone now 5 post-src-free");
    CHECK(has_fact(clone, "R", 60), "clone recorded post-free assert");
    CHECK(ds_engine_free(clone).status == DS_OK, "free clone");

    if (g_fails) { printf("test_engine_clone: %d FAILURES\n", g_fails); return 1; }
    printf("test_engine_clone: ALL PASSED\n");
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * NMET.4.4's two metrics, each asserted in name, kind, labels, value and
 * count.
 *
 *   ds.facts.noop_reassert_suppressed_total{schema}
 *     Through the public API: a logical schema keyed on `id`, a fact, the
 *     identical fact again (a no-op, counted once), and a changed one (an
 *     upsert, not counted). Site: rete/wm_rete.c, ds_rete_wm_assert_ex's
 *     no-op return.
 *
 *   ds.calls.arg_error_total{service}
 *     A `call` whose kwarg has no value is not issued ([LNUL.11.1]); the CALL
 *     builtin receives that kwarg's `null` among its name/value operands
 *     (RDSC.4a.9.4). Driven through the builtin's dispatch slot with those
 *     operands, because a compiled program is the only other way to reach it
 *     and this suite links none. Site: engine_rete_adapters.c, bridge_call's
 *     null-kwarg branch.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

#include "engine.h"
#include "fn.h"
#include "rete/eval.h"
#include "rete/val.h"

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

/* Every metric whose name is `watch`, as it arrived. */
typedef struct {
    const char *watch;
    int         n;
    ds_metric_kind_t kind;
    double      value;
    size_t      n_labels;
    char        key[32];
    char        val[32];
} seen_t;

static ds_result_t on_metric(ds_engine_t *e, const ds_metric_t *m, void *user)
{
    (void)e;
    seen_t *s = user;
    if (strcmp(m->name, s->watch) != 0) return DS_OK_R;
    s->n++;
    s->kind     = m->kind;
    s->value    = m->value;
    s->n_labels = m->n_labels;
    s->key[0] = s->val[0] = '\0';
    if (m->n_labels > 0) {
        strncpy(s->key, m->labels[0].key ? m->labels[0].key : "",
                sizeof s->key - 1);
        strncpy(s->val, m->labels[0].value ? m->labels[0].value : "",
                sizeof s->val - 1);
    }
    return DS_OK_R;
}

static void expect_one(const seen_t *s, const char *key, const char *val)
{
    if (s->n != 1)
        fprintf(stderr, "  %s: %d observation(s)\n", s->watch, s->n);
    CHECK(s->n == 1, "emitted exactly once");
    CHECK(s->kind == DS_METRIC_COUNTER, "a counter");
    CHECK(s->value == 1.0, "delta 1.0");
    CHECK(s->n_labels == 1, "one label");
    CHECK(strcmp(s->key, key) == 0, "the label's key");
    CHECK(strcmp(s->val, val) == 0, "the label's value");
}

static const ds_slot_desc_t KEYED_SLOTS[2] = {
    { .name = "id",    .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_KEY },
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_MUTABLE },
};

static void test_noop_reassert_suppressed(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return;
    const ds_schema_t *keyed = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Keyed", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, KEYED_SLOTS, 2, &keyed),
             "register Keyed");
    seen_t s = { .watch = "ds.facts.noop_reassert_suppressed_total" };
    CHECK_OK(ds_engine_set_metric_callback(e, on_metric, &s), "metric cb");

    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT; v[0].v.i = 7;
    v[1].kind = DS_SLOT_INT; v[1].v.i = 10;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, keyed, v, 2, &f), "assert Keyed(7,10)");
    CHECK(s.n == 0, "a first assert is not a no-op");
    uint64_t id1 = 0;
    if (f) CHECK_OK(ds_fact_get_id(f, &id1), "id of the first fact");

    ds_fact_t *same = NULL;
    CHECK_OK(ds_engine_assert(e, keyed, v, 2, &same), "reassert Keyed(7,10)");
    uint64_t id_same = 0;
    if (same) CHECK_OK(ds_fact_get_id(same, &id_same), "id after the no-op");
    CHECK(id_same == id1, "the reassertion was a no-op -- premise");

    /* An upsert supersedes: the wrapper may be reused, so the premise is
       the fact id, which an upsert mints anew ([LFAC.2.5.1], NFCT.6.2). */
    v[1].v.i = 20;
    ds_fact_t *upd = NULL;
    CHECK_OK(ds_engine_assert(e, keyed, v, 2, &upd), "upsert Keyed(7,20)");
    uint64_t id_upd = 0;
    if (upd) CHECK_OK(ds_fact_get_id(upd, &id_upd), "id after the upsert");
    CHECK(id_upd != id1, "the changed reassertion superseded -- premise");

    expect_one(&s, "schema", "Keyed");
    ds_engine_free(e);
}

static void test_call_arg_error(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return;
    seen_t s = { .watch = "ds.calls.arg_error_total" };
    CHECK_OK(ds_engine_set_metric_callback(e, on_metric, &s), "metric cb");

    const ds_fn_slot_t *slot = ds_lookup_fn(DS_FN_CALL);
    CHECK(slot != NULL, "the CALL builtin is registered -- premise");
    if (slot != NULL && e->rete_engine != NULL) {
        ds_rete_val_t args[4] = {
            ds_rete_val_str("weather", 7),
            ds_rete_val_str("c1", 2),
            ds_rete_val_str("city", 4),
            ds_rete_val_null(),             /* a kwarg with no value */
        };
        ds_rete_eval_ctx_t ctx;
        memset(&ctx, 0, sizeof ctx);
        ctx.engine = e->rete_engine;
        ds_rete_val_t out = ds_rete_val_null();
        CHECK_OK(slot->fn(e->rete_engine, &ctx, args, 4, &out),
                 "a kwarg with no value is not an error");
        CHECK(!ctx.faulted, "nor a fault");
    }

    expect_one(&s, "service", "weather");
    ds_engine_free(e);
}

int main(void)
{
    test_noop_reassert_suppressed();
    test_call_arg_error();

    if (failures == 0) {
        printf("OK  test_nmet_4_4_owed_metrics\n");
        return 0;
    }
    fprintf(stderr, "FAILED: %d check(s)\n", failures);
    return 1;
}

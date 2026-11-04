/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The `publish` action (IDSP.4), black-box through libds.h. A `publish` puts
 * nothing in this tier's working memory ([LTIE.4.3]); its stream is one
 * ACTION_PUBLISH inside the firing, and no FACT_ASSERT and no ACTION_EMIT for
 * it (IDSP.4.6). The event's fact is a view, valid for the callback only, with
 * no id, and no lookup finds it (NCBK.2.5). `Counter` is explicit-scoped: a
 * `publish` takes no lifetime modifier ([LTIE.4.9]).
 */
#include "spec_common.h"

/* ============== Probe ============== */

typedef struct {
    int        n_fact_assert;
    int        n_fact_assert_in_fire;
    int        n_action_publish;
    int        n_action_emit;
    int        n_rule_fire_begin;
    int        n_rule_fire_end;
    int        n_other_action;
    int        in_fire;
    uint64_t   last_rfb_seq;
    uint64_t   last_publish_seq;
    uint64_t   last_rfe_seq;
    /* Read from the ACTION_PUBLISH event's fact while the callback runs, the
       only time it is valid ([NCBK.2.5]). `view` is kept as an address only,
       compared and never read after the callback. */
    const void *view;
    int        view_id_ok;
    uint64_t   view_id;
    int        view_n_ok;
    int64_t    view_n;
    size_t     external_len;
} stream_probe_t;

static ds_result_t stream_cb(ds_engine_t          *engine,
                             const ds_stream_ev_t *event,
                             void                 *user)
{
    (void) engine;
    stream_probe_t *s = (stream_probe_t *) user;
    switch (event->kind) {
    case DS_EV_FACT_ASSERT:
        s->n_fact_assert++;
        if (s->in_fire) s->n_fact_assert_in_fire++;
        break;
    case DS_EV_ACTION_PUBLISH: {
        s->n_action_publish++;
        s->last_publish_seq = event->seq;
        const ds_fact_t *f = event->p.action_publish.fact;
        s->view = f;
        s->external_len = event->p.action_publish.external_len;
        if (f != NULL) {
            s->view_id_ok = ds_fact_get_id(f, &s->view_id).status == DS_OK;
            ds_slot_value_t v;
            if (ds_fact_get_slot(f, 0, NULL, &v).status == DS_OK
                    && v.kind == DS_SLOT_INT) {
                s->view_n_ok = 1;
                s->view_n    = v.v.i;
            }
        }
        break;
    }
    case DS_EV_ACTION_EMIT:
        s->n_action_emit++;
        break;
    case DS_EV_RULE_FIRE_BEGIN:
        s->n_rule_fire_begin++;
        s->in_fire = 1;
        s->last_rfb_seq = event->seq;
        break;
    case DS_EV_RULE_FIRE_END:
        s->n_rule_fire_end++;
        s->in_fire = 0;
        s->last_rfe_seq = event->seq;
        break;
    case DS_EV_FACT_RETRACT:
    case DS_EV_RULE_LHS_FACTS:
    /* The clock's tick and the pump's own event are the engine stepping
       ([NCBK.2.3]), not actions. Faults still count. */
    case DS_EV_TICK:
    case DS_EV_PUMP:
        break;
    default:
        s->n_other_action++;
    }
    return DS_OK_R;
}

/* ============== Per-scenario fixture ============== */

#define TRIG_SCHEMA    "schema Trig scope logical:\n    tag: String key\n\n"
#define COUNTER_SCHEMA "schema Counter scope explicit:\n    n: Int\n\n"
#define ECHO_SCHEMA    "schema Echo scope logical:\n    n: Int key\n\n"

static int build_engine(ds_engine_t **out_engine,
                        const ds_schema_t **out_trig,
                        stream_probe_t *sp,
                        const char *ds_src)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    r = spec_load_ds(e, ds_src);
    if (r.status != DS_OK) return spec_fail("spec_load_ds", r);
    const ds_schema_t *trig = NULL;
    r = ds_engine_schema_find(e, "Trig", &trig);
    if (r.status != DS_OK || !trig) return spec_fail("find Trig", r);
    if (sp != NULL) {
        r = ds_engine_set_stream_callback(e, stream_cb, sp);
        if (r.status != DS_OK) return spec_fail("set_stream_cb", r);
    }
    *out_engine = e;
    if (out_trig) *out_trig = trig;
    return 0;
}

static int fire(ds_engine_t *e, const ds_schema_t *trig, const char *tag)
{
    ds_slot_value_t v[] = { { .kind = DS_SLOT_STRING, .v.s = tag } };
    ds_result_t r = ds_engine_assert(e, trig, v, 1, NULL);
    if (r.status != DS_OK) return spec_fail("assert trig", r);
    return 0;
}

static int assert_no_other_actions(const stream_probe_t *sp)
{
    if (sp->n_other_action != 0) {
        fprintf(stderr,
                "FAIL: stream observed %d unexpected action events\n",
                sp->n_other_action);
        return 1;
    }
    return 0;
}

#define ONE_PUBLISH                                                          \
    TRIG_SCHEMA COUNTER_SCHEMA                                               \
    "rule p:\n    Trig t where t.tag == \"x\"\n"                             \
    "->\n    publish Counter n: 42\n"

/* ============== Scenarios ============== */

/* IDSP.4.4 — primary effect: none in working memory ([LTIE.4.3]). After the
   pump the fact count is the Trig alone, and the only FACT_ASSERT is the
   Trig's. A runtime that still asserted the published fact counts 2. */
static int test_idsp_4_4__primary_effect_is_none_in_working_memory(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, ONE_PUBLISH)) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_publish != 1) {
        fprintf(stderr, "FAIL: ACTION_PUBLISH count=%d, want 1\n",
                sp.n_action_publish);
        return 1;
    }
    size_t fc = 0;
    r = ds_engine_fact_count(e, &fc);
    EXPECT_OK("fact_count", r);
    if (fc != 1) {
        fprintf(stderr, "FAIL: fact_count=%zu, want 1 (the Trig)\n", fc);
        return 1;
    }
    if (sp.n_fact_assert != 1) {
        fprintf(stderr, "FAIL: FACT_ASSERT count=%d, want 1 (the Trig's)\n",
                sp.n_fact_assert);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.4.4 — the ACTION_PUBLISH event carries a view of the published fact,
   holding the published value, and its FactExternal ([NCBK.10.1]). */
static int test_idsp_4_4__action_publish_carries_a_view_and_its_encoding(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, ONE_PUBLISH)) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.view == NULL) {
        fprintf(stderr, "FAIL: ACTION_PUBLISH fact ptr is NULL\n"); return 1;
    }
    if (!sp.view_n_ok || sp.view_n != 42) {
        fprintf(stderr, "FAIL: the view's n read %s%lld, want 42\n",
                sp.view_n_ok ? "" : "nothing, ", (long long) sp.view_n);
        return 1;
    }
    if (sp.external_len == 0) {
        fprintf(stderr, "FAIL: ACTION_PUBLISH carries no FactExternal\n");
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* NCBK.2.5 — `action_publish.fact` is a view, valid for the callback only:
   read inside the callback, it has no id (0, which names no fact); and once
   the pump has returned, no lookup finds it. Every live fact is visited, and
   none is the view; looking up the id it gave finds nothing. A runtime that
   handed out a working-memory fact gives it a non-zero id, and the visit
   finds it. */
typedef struct { const void *view; int n_facts; int saw_view; } visit_t;

static ds_result_t visit(const ds_fact_t *fact, void *user)
{
    visit_t *v = (visit_t *) user;
    v->n_facts++;
    if ((const void *) fact == v->view) v->saw_view = 1;
    return DS_OK_R;
}

static int test_ncbk_2_5__publish_fact_is_a_view(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, ONE_PUBLISH)) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_publish != 1 || sp.view == NULL) {
        fprintf(stderr, "FAIL: premise: %d ACTION_PUBLISH, view %p\n",
                sp.n_action_publish, sp.view);
        return 1;
    }
    if (!sp.view_id_ok || sp.view_id != 0) {
        fprintf(stderr, "FAIL: the view's id read %s%llu, want 0\n",
                sp.view_id_ok ? "" : "nothing, ",
                (unsigned long long) sp.view_id);
        return 1;
    }

    EXPECT_OK("detach", ds_engine_set_stream_callback(e, NULL, NULL));
    visit_t v = { .view = sp.view };
    EXPECT_OK("for_each_fact", ds_engine_for_each_fact(e, NULL, visit, &v));
    if (v.n_facts != 1 || v.saw_view) {
        fprintf(stderr, "FAIL: %d live facts (want 1, the Trig), %s\n",
                v.n_facts, v.saw_view ? "and one is the view" : "none the view");
        return 1;
    }
    static int sentinel;
    ds_fact_t *found = (ds_fact_t *) (void *) &sentinel;
    ds_result_t fr = ds_engine_fact_find(e, sp.view_id, &found);
    EXPECT_STATUS("fact_find of the view's id", fr, DS_ERR_NOT_FOUND);
    if (found != NULL) {
        fprintf(stderr, "FAIL: fact_find set *out to %p, want NULL\n",
                (void *) found);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.4.6 — publish is not an emit: ACTION_PUBLISH fires, ACTION_EMIT does
   not. Cross-tier subscribers gate on PUBLISH alone. */
static int test_idsp_4_6__no_action_emit_when_publish(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, ONE_PUBLISH)) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_publish != 1) {
        fprintf(stderr, "FAIL: ACTION_PUBLISH count=%d, want 1\n",
                sp.n_action_publish);
        return 1;
    }
    if (sp.n_action_emit != 0) {
        fprintf(stderr, "FAIL: publish emitted ACTION_EMIT (%d)\n",
                sp.n_action_emit);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.4.5 — emit records ACTION_EMIT, and no ACTION_PUBLISH. */
static int test_idsp_4_5__no_action_publish_when_emit(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp,
            TRIG_SCHEMA ECHO_SCHEMA
            "rule e:\n    Trig t where t.tag == \"x\"\n"
            "->\n    emit Echo logical n: 1\n"))
        return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_emit != 1) {
        fprintf(stderr, "FAIL: ACTION_EMIT count=%d, want 1\n",
                sp.n_action_emit);
        return 1;
    }
    if (sp.n_action_publish != 0) {
        fprintf(stderr, "FAIL: emit emitted ACTION_PUBLISH (%d)\n",
                sp.n_action_publish);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.4.6 — per-firing order by seq: RULE_FIRE_BEGIN < ACTION_PUBLISH <
   RULE_FIRE_END, and no FACT_ASSERT inside the firing. */
static int test_idsp_4_6__per_firing_observable_order(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, ONE_PUBLISH)) return 1;
    if (fire(e, trig, "x")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_rule_fire_begin != 1 || sp.n_action_publish != 1 ||
        sp.n_rule_fire_end != 1) {
        fprintf(stderr, "FAIL: counts rfb=%d pub=%d rfe=%d\n",
                sp.n_rule_fire_begin, sp.n_action_publish, sp.n_rule_fire_end);
        return 1;
    }
    if (!(sp.last_rfb_seq < sp.last_publish_seq)) {
        fprintf(stderr, "FAIL: rfb_seq=%llu not < publish_seq=%llu\n",
                (unsigned long long) sp.last_rfb_seq,
                (unsigned long long) sp.last_publish_seq);
        return 1;
    }
    if (!(sp.last_publish_seq < sp.last_rfe_seq)) {
        fprintf(stderr, "FAIL: publish_seq=%llu not < rfe_seq=%llu\n",
                (unsigned long long) sp.last_publish_seq,
                (unsigned long long) sp.last_rfe_seq);
        return 1;
    }
    if (sp.n_fact_assert_in_fire != 0) {
        fprintf(stderr, "FAIL: %d FACT_ASSERT inside the firing, want 0\n",
                sp.n_fact_assert_in_fire);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.4.4 / IDSP.4.6 — N firings give N ACTION_PUBLISH events and no
   FACT_ASSERT beyond the N Trigs, with no ACTION_EMIT. Three rules, three
   values. */
static int test_idsp_4_4__multi_fire_count(void)
{
    stream_probe_t sp = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp,
            TRIG_SCHEMA COUNTER_SCHEMA
            "rule ma:\n    Trig t where t.tag == \"a\"\n"
            "->\n    publish Counter n: 1\n\n"
            "rule mb:\n    Trig t where t.tag == \"b\"\n"
            "->\n    publish Counter n: 2\n\n"
            "rule mc:\n    Trig t where t.tag == \"c\"\n"
            "->\n    publish Counter n: 3\n"))
        return 1;
    const char *tags[] = { "a", "b", "c" };
    for (int i = 0; i < 3; i++)
        if (fire(e, trig, tags[i])) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_action_publish != 3) {
        fprintf(stderr, "FAIL: ACTION_PUBLISH count=%d, want 3\n",
                sp.n_action_publish);
        return 1;
    }
    if (sp.n_fact_assert != 3) {
        fprintf(stderr, "FAIL: FACT_ASSERT count=%d, want 3 (the Trigs)\n",
                sp.n_fact_assert);
        return 1;
    }
    if (sp.n_action_emit != 0) {
        fprintf(stderr, "FAIL: publish leaked ACTION_EMIT (%d)\n",
                sp.n_action_emit);
        return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_idsp_4_4__primary_effect_is_none_in_working_memory();
    failed |= test_idsp_4_4__action_publish_carries_a_view_and_its_encoding();
    failed |= test_ncbk_2_5__publish_fact_is_a_view();
    failed |= test_idsp_4_6__no_action_emit_when_publish();
    failed |= test_idsp_4_5__no_action_publish_when_emit();
    failed |= test_idsp_4_6__per_firing_observable_order();
    failed |= test_idsp_4_4__multi_fire_count();
    if (!failed) printf("test_publish_spec: OK\n");
    return failed;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A truth-maintenance cascade record ([LFST.7.3.6]) is buffered while the
 * trigger's own record goes out. When the buffer cannot grow, the record is
 * delivered at once, out of the deferred order but not lost; a retracted
 * wrapper is released only after the integrator has seen it ([NFCT.6.2]); and
 * the call reports DS_ERR_OOM ([NCBK.1.5]).
 *
 * The test drives the recorder's seam as the engine does: a public-call scope
 * (ds_api_enter/leave), the deferred scope two deep, and a wrapper detached as
 * the retract bridge detaches it. realloc is wrapped (-Wl,--wrap=realloc;
 * ds_realloc is weak over it) to fail exactly one growth, so the file is vg
 * "no": the wrap collides with valgrind's allocator.
 */
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "recorder.h"
#include "wm.h"

/* Declared by no header: wm_rete_bridge.c declares it `extern` itself, the one
   caller, and this test is the second. */
extern ds_result_t ds_wm_fact_detach(ds_wm_state_t *wm, ds_fact_t *fact);

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

void *__real_realloc(void *p, size_t sz);

static int g_fail_next_realloc = 0;

void *__wrap_realloc(void *p, size_t sz)
{
    if (g_fail_next_realloc) {
        g_fail_next_realloc = 0;
        return NULL;
    }
    return __real_realloc(p, sz);
}

typedef struct {
    int         retracts;
    int         asserts;
    ds_fact_t  *last_retracted;
    int64_t     last_retracted_n;   /* read DURING the callback: the wrapper
                                       must still be valid then */
} seen_t;

static ds_result_t seen_cb(ds_engine_t *engine, const ds_stream_ev_t *ev,
                           void *user)
{
    (void)engine;
    seen_t *s = (seen_t *)user;
    if (ev->kind == DS_EV_FACT_ASSERT)
        s->asserts++;
    if (ev->kind == DS_EV_FACT_RETRACT) {
        s->retracts++;
        s->last_retracted = ev->p.fact_retract.fact;
        ds_slot_value_t v;
        memset(&v, 0, sizeof(v));
        if (ds_fact_get_slot(ev->p.fact_retract.fact, 0, NULL, &v).status == DS_OK)
            s->last_retracted_n = v.v.i;
    }
    return (ds_result_t){ DS_OK, NULL };
}

static const ds_slot_desc_t SLOTS[1] = {
    { .name = "n", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
};

static ds_engine_t *new_engine(const ds_schema_t **sc, seen_t *seen)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e)
        return NULL;
    CHECK_OK(ds_engine_register_schema(e, "Pkt", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, SLOTS, 1, sc),
             "register_schema");
    CHECK_OK(ds_engine_set_stream_callback(e, seen_cb, seen), "stream callback");
    return e;
}

static ds_fact_t *assert_n(ds_engine_t *e, const ds_schema_t *sc, int64_t n)
{
    ds_slot_value_t v;
    memset(&v, 0, sizeof(v));
    v.kind = DS_SLOT_INT;
    v.v.i = n;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, sc, &v, 1, &f), "assert");
    return f;
}

/* A cascade RETRACT whose buffer growth fails: delivered at once, with the
   wrapper still valid while the integrator reads it, and the call reports
   DS_ERR_OOM. */
static void test_unbufferable_cascade_retract_is_delivered(void)
{
    seen_t seen;
    memset(&seen, 0, sizeof(seen));
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc, &seen);
    if (!e)
        return;

    ds_fact_t *f = assert_n(e, sc, 42);
    CHECK(seen.asserts == 1, "the plain assert was delivered");

    ds_api_enter(e);                       /* the public call's scope */
    ds_recorder_defer_enter(e);            /* depth 1: the trigger */
    ds_recorder_defer_enter(e);            /* depth 2: its cascade */
    CHECK(ds_recorder_should_buffer(e), "depth 2 buffers");
    CHECK_OK(ds_wm_fact_detach(&e->wm, f), "detach, as the retract bridge does");

    g_fail_next_realloc = 1;               /* the buffer's first growth fails */
    ds_result_t er = ds_recorder_emit_fact_retract(e, f);
    CHECK(g_fail_next_realloc == 0, "the buffer growth was attempted");
    CHECK_OK(er, "the emit itself does not fail the engine");

    CHECK(seen.retracts == 1,
          "the unbufferable cascade retract was delivered, not dropped");
    CHECK(seen.last_retracted == f, "it names the retracted fact");
    CHECK(seen.last_retracted_n == 42,
          "the wrapper was still valid while the integrator read it");

    ds_recorder_defer_leave(e);
    ds_recorder_defer_leave(e);
    ds_result_t call = ds_api_leave(e, (ds_result_t){ DS_OK, NULL });
    CHECK(call.status == DS_ERR_OOM,
          "the call reports the out-of-memory degradation ([NCBK.1.5])");
    CHECK(seen.retracts == 1, "the flush does not deliver it a second time");

    ds_engine_free(e);
}

/* The same for a cascade ASSERT (no wrapper to release). */
static void test_unbufferable_cascade_assert_is_delivered(void)
{
    seen_t seen;
    memset(&seen, 0, sizeof(seen));
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc, &seen);
    if (!e)
        return;

    ds_fact_t *f = assert_n(e, sc, 7);
    int before = seen.asserts;

    ds_api_enter(e);
    ds_recorder_defer_enter(e);
    ds_recorder_defer_enter(e);
    g_fail_next_realloc = 1;
    CHECK_OK(ds_recorder_emit_fact_assert(e, f), "emit (cascade assert)");
    CHECK(seen.asserts == before + 1,
          "the unbufferable cascade assert was delivered, not dropped");
    ds_recorder_defer_leave(e);
    ds_recorder_defer_leave(e);
    ds_result_t call = ds_api_leave(e, (ds_result_t){ DS_OK, NULL });
    CHECK(call.status == DS_ERR_OOM, "the call reports DS_ERR_OOM");
    CHECK(seen.asserts == before + 1, "delivered exactly once");

    ds_engine_free(e);
}

/* The control: with memory, the cascade record is buffered and flushed after
   the scope closes, and the call is OK. */
static void test_bufferable_cascade_is_deferred(void)
{
    seen_t seen;
    memset(&seen, 0, sizeof(seen));
    const ds_schema_t *sc = NULL;
    ds_engine_t *e = new_engine(&sc, &seen);
    if (!e)
        return;

    ds_fact_t *f = assert_n(e, sc, 9);

    ds_api_enter(e);
    ds_recorder_defer_enter(e);
    ds_recorder_defer_enter(e);
    CHECK_OK(ds_wm_fact_detach(&e->wm, f), "detach (control)");
    CHECK_OK(ds_recorder_emit_fact_retract(e, f), "emit (control)");
    CHECK(seen.retracts == 0, "a bufferable cascade record waits for the flush");
    ds_recorder_defer_leave(e);
    CHECK(seen.retracts == 0, "still waiting at depth 1");
    ds_recorder_defer_leave(e);
    CHECK(seen.retracts == 1, "flushed when the outermost scope closes");
    CHECK(seen.last_retracted_n == 9, "with the wrapper valid at flush");
    CHECK_OK(ds_api_leave(e, (ds_result_t){ DS_OK, NULL }), "the call is OK");

    ds_engine_free(e);
}

int main(void)
{
    test_unbufferable_cascade_retract_is_delivered();
    test_unbufferable_cascade_assert_is_delivered();
    test_bufferable_cascade_is_deferred();

    if (failures) {
        fprintf(stderr, "test_recorder_defer_oom: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_recorder_defer_oom: OK\n");
    return 0;
}

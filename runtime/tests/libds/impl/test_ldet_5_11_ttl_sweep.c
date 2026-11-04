/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LDET.5.11]
 * The facts one pump's TTL sweep expires leave by deadline, and facts that
 * share a deadline leave by working-memory entry.
 *
 * The sweep that expires a host's facts is the DS-layer one (engine.c,
 * ds_engine_sweep_ttl_via_wrappers), over the deadline list, which is newest
 * first. It runs before the rete deadline heap (test_rete_deadline_heap) and
 * is what the stream records. The lockstep pair 124/91_ttl_ties holds the
 * same order against Mercury.
 *
 * The history: a with a 2 s override, then b and c with the schema's 1 s, all
 * at t=0, so b and c tie at 1 s and a falls due at 2 s. One pump at 3 s
 * expires all three. Deadline then entry order is b, c, a. The deadline
 * list's order is c, b, a.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_assert_with_ttl, libds-internal */

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

#define MAX_EV 16
typedef struct {
    int      n;
    uint64_t fact_id[MAX_EV];
} retracts_t;

static ds_result_t retract_cb(ds_engine_t *e, const ds_stream_ev_t *ev,
                              void *user)
{
    (void) e;
    retracts_t *t = (retracts_t *) user;
    if (ev->kind == DS_EV_FACT_RETRACT && t->n < MAX_EV) {
        uint64_t id = 0;
        if (ds_fact_get_id(ev->p.fact_retract.fact, &id).status == DS_OK)
            t->fact_id[t->n++] = id;
    }
    return DS_OK_R;
}

static uint64_t assert_ev(ds_engine_t *e, const ds_schema_t *sc, int64_t v,
                          uint64_t ttl_override)
{
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = v };
    ds_fact_t *f = NULL;
    CHECK(ds_engine_assert_with_ttl(e, sc, &sv, 1, ttl_override, &f).status
              == DS_OK, "assert Ev");
    uint64_t id = 0;
    if (f != NULL) CHECK(ds_fact_get_id(f, &id).status == DS_OK, "fact id");
    return id;
}

static void test_one_sweep_by_deadline_then_entry(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) {
        fprintf(stderr, "FAIL: engine_new\n");
        g_fails++;
        return;
    }
    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_INT };
    const ds_schema_t *ev = NULL;
    CHECK(ds_engine_register_schema(e, "Ev", DS_SCHEMA_LIFECYCLE_TTL,
                                    1000000000ull, &sd, 1, &ev).status == DS_OK,
          "register Ev");
    CHECK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status == DS_OK, "mock");
    CHECK(ds_engine_clock_set(e, 0).status == DS_OK, "clock 0");
    if (ev == NULL) { ds_engine_free(e); return; }

    const uint64_t a = assert_ev(e, ev, 1, 2000000000ull);   /* due at 2 s */
    const uint64_t b = assert_ev(e, ev, 2, 0);               /* due at 1 s */
    const uint64_t c = assert_ev(e, ev, 3, 0);               /* due at 1 s */
    CHECK(a < b && b < c, "precondition: ids follow entry");
    CHECK(ds_engine_pump(e).status == DS_OK, "pump at 0");

    retracts_t t = {0};
    CHECK(ds_engine_set_stream_callback(e, retract_cb, &t).status == DS_OK,
          "attach stream");
    CHECK(ds_engine_clock_advance(e, 3000000000ull).status == DS_OK,
          "advance to 3 s");
    CHECK(ds_engine_pump(e).status == DS_OK, "the pump that sweeps");

    CHECK(t.n == 3, "three expiries");
    if (t.n == 3)
        CHECK(t.fact_id[0] == b && t.fact_id[1] == c && t.fact_id[2] == a,
              "expired by deadline, ties by entry: b, c, a -- not c, b, a");

    ds_engine_free(e);
}

int main(void)
{
    test_one_sweep_by_deadline_then_entry();
    if (g_fails == 0) printf("test_ldet_5_11_ttl_sweep: OK\n");
    return g_fails != 0;
}

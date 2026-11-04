/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LDET.5.11]
 * The correlation supersedure sweep withdraws its victims by working-memory
 * entry order, whatever order the walk visits them in.
 *
 * The sweep (rete/adapters.c, do_retract_corr_sweep) walks working memory in
 * the rete map's dense order and collects every fact of the named schema whose
 * correlation slot equals the key. Dense order is history: a retract
 * swap-removes, moving the last fact into the hole. So the history below makes
 * the dense order differ from entry order, and the test reads the order the
 * FACT_RETRACT events arrive in.
 *
 * The history: Timer a, b, c, d entered in that order, all with corr "x";
 * then a retracted, which moves d into a's slot. The walk then visits d, b,
 * c. In entry order the sweep withdraws b, c, d.
 *
 * The property is the builtin's, so it is called directly (ds_lookup_fn).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "fn.h"
#include "wm.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/intern.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

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
    if (ev->kind == DS_EV_FACT_RETRACT && t->n < MAX_EV)
        t->fact_id[t->n++] = ev->p.fact_retract.fact->fact_id;
    return DS_OK_R;
}

static const char *istr(ds_rete_engine_t *re, const char *s)
{
    const char *p = NULL;
    ds_rete_intern_cstr(re->intern, s, &p);
    return p;
}

static ds_fact_t *assert_timer(ds_engine_t *engine, const ds_schema_t *sc,
                               int64_t id, const char *corr)
{
    ds_slot_value_t v[2] = {
        { .kind = DS_SLOT_INT,    .v.i = id },
        { .kind = DS_SLOT_STRING, .v.s = corr },
    };
    ds_fact_t *f = NULL;
    CHECK(ds_engine_assert(engine, sc, v, 2, &f).status == DS_OK, "assert Timer");
    return f;
}

static void test_sweep_withdraws_in_entry_order(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *engine = NULL;
    if (ds_engine_new(&cfg, &engine).status != DS_OK || engine == NULL) {
        fprintf(stderr, "FAIL: engine_new\n");
        g_fails++;
        return;
    }

    ds_slot_desc_t sd[2] = {
        { .name = "id",   .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "corr", .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    const ds_schema_t *timer = NULL;
    if (ds_engine_register_schema(engine, "Timer", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  0, sd, 2, &timer).status != DS_OK) {
        fprintf(stderr, "FAIL: register_schema Timer\n");
        g_fails++;
        ds_engine_free(engine);
        return;
    }

    ds_fact_t *fa = assert_timer(engine, timer, 1, "x");
    ds_fact_t *fb = assert_timer(engine, timer, 2, "x");
    ds_fact_t *fc = assert_timer(engine, timer, 3, "x");
    ds_fact_t *fd = assert_timer(engine, timer, 4, "x");
    if (!fa || !fb || !fc || !fd) { ds_engine_free(engine); return; }
    const uint64_t id_b = fb->fact_id, id_c = fc->fact_id, id_d = fd->fact_id;
    CHECK(id_b < id_c && id_c < id_d, "precondition: fact ids follow entry");

    CHECK(ds_engine_retract(engine, fa).status == DS_OK, "retract a");

    /* The precondition the test rests on: the walk now meets d first. */
    ds_rete_engine_t *re = engine->rete_engine;
    CHECK(oa_len(&re->wm_map) == 3, "precondition: three facts in the rete map");
    ds_rete_fact_t *first = *(ds_rete_fact_t **) ds_oa_val_at(&re->wm_map, 0);
    CHECK(first == (ds_rete_fact_t *) fd->rete_fact,
          "precondition: the retract moved d to the front of the dense order");

    retracts_t t = {0};
    CHECK(ds_engine_set_stream_callback(engine, retract_cb, &t).status == DS_OK,
          "attach stream");

    const ds_fn_slot_t *slot = ds_lookup_fn(DS_FN_RETRACT_CORR);
    CHECK(slot != NULL, "ds_retract_corr is registered");
    if (slot != NULL) {
        ds_rete_val_t args[3] = {
            ds_rete_val_str(istr(re, "Timer"), 5),
            ds_rete_val_str(istr(re, "corr"),  4),
            ds_rete_val_str(istr(re, "x"),     1),
        };
        ds_rete_eval_ctx_t ctx = { .engine = re };
        ds_rete_val_t out = ds_rete_val_null();
        CHECK(slot->fn(re, &ctx, args, 3, &out).status == DS_OK, "the sweep");
    }

    CHECK(t.n == 3, "three withdrawals");
    if (t.n == 3) {
        CHECK(t.fact_id[0] == id_b && t.fact_id[1] == id_c
              && t.fact_id[2] == id_d,
              "withdrawn in entry order: b, c, d -- not the walk's d, b, c");
    }

    ds_engine_free(engine);
}

int main(void)
{
    test_sweep_withdraws_in_entry_order();
    if (g_fails == 0) printf("test_ldet_5_11_corr_sweep: OK\n");
    return g_fails != 0;
}

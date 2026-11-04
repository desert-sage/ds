/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_fp_mode — [LDET.3.6.1]: the engine computes in round-to-nearest-even
 * whatever rounding mode the integrator's thread holds, and the integrator only
 * ever sees its own mode (formal/tla/fp_mode.tla is the protocol).
 *
 * One rule, Src(id, x) -> Out(id, x / 3.0). 1.0 / 3.0 differs in its last bit
 * between round-to-nearest and round-upward, so the Out value says which mode
 * the engine divided in. Four properties:
 *
 *   1. The caller holds FE_UPWARD and the engine still divides in nearest:
 *      Out.x is RN(1/3), not RU(1/3).
 *   2. A callback runs in the caller's mode: the stream callback reads
 *      FE_UPWARD at every event.
 *   3. A mode a callback sets is the callback's: the sink sets FE_TOWARDZERO
 *      at RULE_FIRE_BEGIN, before the action divides, and the division is
 *      still nearest.
 *   4. The caller's mode is back when the call returns -- after assert and
 *      after pump -- and the sink's FE_TOWARDZERO did not leak out.
 *
 * TEETH: drop ds_fp_establish from ds_api_enter and 1 fails (RU(1/3)); drop
 * the restore in ds_callback_enter and 2 fails; drop the re-establish in
 * ds_callback_leave and 3 fails; drop ds_fp_restore from ds_api_leave and 4
 * fails.
 *
 * vg "no": valgrind does not emulate a non-nearest rounding mode faithfully,
 * which is the whole subject here.
 *
 * Skipped, loudly, where the platform cannot set FE_UPWARD.
 */
#include <fenv.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/val.h"

#if !DS_FP_ENV || !defined(FE_UPWARD) || !defined(FE_TOWARDZERO)
int main(void)
{
    printf("test_fp_mode: SKIPPED -- no floating-point environment to pin\n");
    return 0;
}
#else

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

/* ---- a sink that reads the mode, and may set one --------------------- */

typedef struct {
    int events;          /* events seen */
    int wrong_mode;      /* events at which the mode was not `expect` */
    int expect;          /* the caller's mode, which every callback must see */
    int set_on_begin;    /* a mode to set at RULE_FIRE_BEGIN, or -1 */
} sink_t;

static ds_result_t sink_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    sink_t *s = (sink_t *) user;
    s->events++;
    if (fegetround() != s->expect) s->wrong_mode++;
    if (ev->kind == DS_EV_RULE_FIRE_BEGIN && s->set_on_begin >= 0)
        (void) fesetround(s->set_on_begin);
    return DS_OK_R;
}

/* ---- Src(id, x) -> div_rule -> Out(id, x / 3.0) ----------------------- */

typedef struct {
    ds_engine_t           *engine;
    const ds_schema_t     *src;
    const ds_schema_t     *out;
    ds_rete_expr_t        *id;
    ds_rete_expr_t        *div;
    ds_rete_slot_assign_t  assigns[2];
    ds_rete_action_t       action;
    ds_alfa_atom_t         alfas[1];
    ds_beta_atom_t         betas[1];
    ds_term_atom_t         terms[1];
    ds_rete_network_t      net;
} fixture_t;

static int reg_schema(ds_engine_t *engine, const char *name,
                      const ds_schema_t **out_ds,
                      const ds_rete_schema_t **out_rs)
{
    ds_slot_desc_t sd[2] = {
        { .name = "id", .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "x",  .type = DS_SLOT_TYPE_FLOAT,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    if (ds_engine_register_schema(engine, name, DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  sd, 2, out_ds).status != DS_OK) {
        fprintf(stderr, "FAIL: register_schema %s\n", name);
        return 1;
    }
    *out_rs = ds_rete_schema_by_name(engine->rete_engine, name);
    if (*out_rs == NULL) {
        fprintf(stderr, "FAIL: rete schema lookup %s\n", name);
        return 1;
    }
    return 0;
}

static ds_rete_expr_t *var(uint32_t slot)
{
    ds_rete_expr_t *n = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    n->var.pattern_index = 0;
    n->var.slot_index = slot;
    return n;
}

static int fixture_new(fixture_t *f)
{
    memset(f, 0, sizeof(*f));
    ds_engine_config_t cfg = {0};
    if (ds_engine_new(&cfg, &f->engine).status != DS_OK || !f->engine) {
        fprintf(stderr, "FAIL: engine_new\n");
        return 1;
    }
    const ds_rete_schema_t *src_rs = NULL, *out_rs = NULL;
    if (reg_schema(f->engine, "Src", &f->src, &src_rs)) return 1;
    if (reg_schema(f->engine, "Out", &f->out, &out_rs)) return 1;

    ds_rete_expr_t *three = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_FLOAT);
    three->lit_float = 3.0;
    f->div = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    f->div->binop.op = DS_RETE_BINOP_DIV;
    f->div->binop.left = var(1);
    f->div->binop.right = three;
    f->id = var(0);
    f->assigns[0] = (ds_rete_slot_assign_t) { .slot_index = 0, .expr = f->id };
    f->assigns[1] = (ds_rete_slot_assign_t) { .slot_index = 1, .expr = f->div };
    f->action = (ds_rete_action_t) {
        .kind = DS_RETE_ACTION_ASSERT, .schema_id = out_rs->id,
        .assigns = f->assigns, .assign_count = 2
    };
    f->alfas[0] = (ds_alfa_atom_t) { .node_id = 1, .schema_name = "Src" };
    f->betas[0] = (ds_beta_atom_t) { .node_id = 2, .right_alpha_id = 1,
                                     .left_parent_id = 0 };
    f->terms[0] = (ds_term_atom_t) { .node_id = 3, .parent_beta_id = 2,
                                     .rule_name = "div_rule",
                                     .actions = &f->action, .action_count = 1 };
    f->net = (ds_rete_network_t) { .alfas = f->alfas, .alfa_count = 1,
                                   .betas = f->betas, .beta_count = 1,
                                   .terms = f->terms, .term_count = 1 };
    if (ds_rete_load_network(f->engine->rete_engine, &f->net).status != DS_OK) {
        fprintf(stderr, "FAIL: load_network\n");
        ds_rete_expr_free_tree(f->id);
        ds_rete_expr_free_tree(f->div);
        return 1;
    }
    return 0;
}

static void fixture_free(fixture_t *f)
{
    if (f->engine) ds_engine_free(f->engine);
}

/* ---- reading Out back ------------------------------------------------- */

typedef struct { int n; double x; } out_read_t;

static ds_result_t read_out(const ds_fact_t *fact, void *user)
{
    out_read_t *r = (out_read_t *) user;
    ds_slot_value_t v;
    if (ds_fact_get_slot(fact, 1, NULL, &v).status == DS_OK &&
        v.kind == DS_SLOT_FLOAT) {
        r->x = v.v.f;
        r->n++;
    }
    return DS_OK_R;
}

/* RN(1/3) and RU(1/3), computed here in the mode each names. `volatile` so
   the compiler cannot fold the division at build time, in nearest. */
static double third_in(int mode)
{
    volatile double one = 1.0, three = 3.0;
    int saved = fegetround();
    (void) fesetround(mode);
    double q = one / three;
    (void) fesetround(saved);
    return q;
}

static void run(int sink_sets)
{
    fixture_t f;
    if (fixture_new(&f)) { g_fails++; fixture_free(&f); return; }
    sink_t s = { .expect = FE_UPWARD, .set_on_begin = sink_sets };
    ds_engine_set_stream_callback(f.engine, sink_cb, &s);

    const double rn = third_in(FE_TONEAREST), ru = third_in(FE_UPWARD);
    CHECK(rn != ru, "1/3 tells the two modes apart on this platform");

    (void) fesetround(FE_UPWARD);
    ds_slot_value_t sv[2] = { { .kind = DS_SLOT_INT, .v.i = 1 },
                              { .kind = DS_SLOT_FLOAT, .v.f = 1.0 } };
    ds_fact_t *fact = NULL;
    ds_result_t ra = ds_engine_assert(f.engine, f.src, sv, 2, &fact);
    int after_assert = fegetround();
    ds_result_t rp = ds_engine_pump(f.engine);
    int after_pump = fegetround();
    (void) fesetround(FE_TONEAREST);

    CHECK(ra.status == DS_OK, "assert Src(1, 1.0)");
    CHECK(rp.status == DS_OK, "pump");
    CHECK(after_assert == FE_UPWARD, "4: the caller's mode is back after assert");
    CHECK(after_pump == FE_UPWARD,
          "4: the caller's mode is back after pump, and a callback's did not leak");
    CHECK(s.events > 0, "the sink saw events");
    CHECK(s.wrong_mode == 0, "2: every callback ran in the caller's mode");

    out_read_t r = { 0, 0.0 };
    ds_engine_for_each_fact(f.engine, f.out, read_out, &r);
    CHECK(r.n == 1, "one Out fact");
    if (r.n == 1 && r.x != rn) {
        fprintf(stderr, "  Out.x = %a, RN(1/3) = %a, RU(1/3) = %a\n",
                r.x, rn, ru);
    }
    CHECK(r.n == 1 && r.x == rn,
          sink_sets >= 0
              ? "3: the division after a callback set FE_TOWARDZERO is nearest"
              : "1: the division under a caller's FE_UPWARD is nearest");
    fixture_free(&f);
}

int main(void)
{
    if (fesetround(FE_UPWARD) != 0 || fegetround() != FE_UPWARD) {
        (void) fesetround(FE_TONEAREST);
        printf("test_fp_mode: SKIPPED -- this platform cannot set FE_UPWARD\n");
        return 0;
    }
    (void) fesetround(FE_TONEAREST);

    run(-1);              /* 1, 2, 4 */
    run(FE_TOWARDZERO);   /* 2, 3, 4 */

    if (g_fails) {
        fprintf(stderr, "test_fp_mode: %d failure(s)\n", g_fails);
        return 1;
    }
    printf("test_fp_mode: OK\n");
    return 0;
}
#endif /* DS_FP_ENV */

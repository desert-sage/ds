/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_fault_emission — the evaluator's faults reach the stream.
 *
 *   CLASSIFIED. The cause picks the kind and the provenance flag splits a type
 *   mismatch. A ComputationError carries the TrapKind the table names —
 *   `Float :: Int` out of range is NOT_REPRESENTABLE, not DOMAIN.
 *
 *   ONCE. A site holding an ERR it did not raise forwards it, so one fault is
 *   recorded once.
 *
 *   THE ACTIVATION, NOT THE ACTION ([LERR.1]). A fault in the second of three
 *   actions stops the third.
 *
 * Built as test_action_events.c is — a Rete network loaded directly and
 * pumped — because the compiler refuses most of these shapes.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "ds_alloc.h"
#include "ds_re2.h"
#include "engine.h"
#include "cache.h"
#include "dispatcher.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/token.h"
#include "rete/val.h"
#include "dsc/pbf_reader.h"
#include "rfcs/rfcs.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

/* ---- the stream, with the fault payloads ------------------------------ */

#define MAX_EV 64
typedef struct {
    int      n;
    int      kind[MAX_EV];
    uint32_t node_id[MAX_EV];
    int      detail[MAX_EV];   /* trap kind / engine fault; -1 otherwise */
    int64_t  timetag[MAX_EV];
    int      has_rule[MAX_EV];
    /* What the fault was raised over, copied: borrowed strings live
       only for the callback. "" for an unset field. */
    char     schema[MAX_EV][16];
    char     slot[MAX_EV][16];
    char     actual[MAX_EV][16];
    uint64_t fact_id[MAX_EV];
    /* The fault's rule name ([LERR.9.11]); "(null)" if the event carried NULL,
       which no fault may. */
    char     rule[MAX_EV][24];
    /* An ACTION_EMIT's fact: its schema, and slots 0 and 1 when they are
       Strings -- a fault fact's `kind` and `rule` ([LERR.9.2]). */
    char     emit_schema[MAX_EV][24];
    char     emit_s0[MAX_EV][24];
    char     emit_s1[MAX_EV][24];
} trace_t;

static void copy_rule(char dst[24], const char *src)
{
    snprintf(dst, 24, "%s", src ? src : "(null)");
}

static void copy_name(char dst[16], const char *src)
{
    snprintf(dst, 16, "%s", src ? src : "");
}

static ds_result_t trace_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    trace_t *t = (trace_t *) user;
    if (t->n >= MAX_EV) return DS_OK_R;
    int i = t->n++;
    t->kind[i] = (int) ev->kind;
    t->node_id[i] = 0;
    t->detail[i] = -1;
    t->timetag[i] = 0;
    t->has_rule[i] = 0;
    t->schema[i][0] = t->slot[i][0] = t->actual[i][0] = '\0';
    t->rule[i][0] = '\0';
    t->emit_schema[i][0] = t->emit_s0[i][0] = t->emit_s1[i][0] = '\0';
    t->fact_id[i] = 0;
    switch (ev->kind) {
    case DS_EV_ACTION_EMIT: {
        const ds_fact_t *f = ev->p.action_emit.fact;
        const ds_schema_t *sc = NULL;
        const char *nm = NULL;
        if (f && ds_fact_get_schema(f, &sc).status == DS_OK
            && ds_schema_get_name(sc, &nm).status == DS_OK)
            copy_rule(t->emit_schema[i], nm);
        ds_slot_value_t v;
        const char *sn = NULL;
        if (f && ds_fact_get_slot(f, 0, &sn, &v).status == DS_OK
            && v.kind == DS_SLOT_STRING)
            copy_rule(t->emit_s0[i], v.v.s);
        if (f && ds_fact_get_slot(f, 1, &sn, &v).status == DS_OK
            && v.kind == DS_SLOT_STRING)
            copy_rule(t->emit_s1[i], v.v.s);
        break;
    }
    case DS_EV_TYPE_ERROR:
        t->node_id[i] = ev->p.type_error.node_id;
        copy_name(t->schema[i], ev->p.type_error.schema_name);
        copy_name(t->slot[i],   ev->p.type_error.slot_name);
        copy_name(t->actual[i], ev->p.type_error.actual);
        copy_rule(t->rule[i],   ev->p.type_error.rule_name);
        break;
    case DS_EV_ENGINE_ERROR:
        t->node_id[i] = ev->p.engine_error.node_id;
        t->detail[i]  = (int) ev->p.engine_error.fault;
        copy_rule(t->rule[i], ev->p.engine_error.rule_name);
        break;
    case DS_EV_COMPUTATION_ERROR:
        copy_rule(t->rule[i], ev->p.computation_error.rule_name);
        t->node_id[i]  = ev->p.computation_error.node_id;
        t->detail[i]   = (int) ev->p.computation_error.kind;
        t->timetag[i]  = ev->p.computation_error.timetag;
        t->has_rule[i] = ev->p.computation_error.rule_name != NULL &&
                         strcmp(ev->p.computation_error.rule_name, "r") == 0;
        copy_name(t->schema[i], ev->p.computation_error.schema_name);
        copy_name(t->slot[i],   ev->p.computation_error.slot_name);
        t->fact_id[i] = ev->p.computation_error.fact_id;
        break;
    case DS_EV_BOUNDS_ERROR:
        t->detail[i]   = (int) ev->p.bounds_error.cap;
        t->has_rule[i] = ev->p.bounds_error.rule_name != NULL &&
                         strcmp(ev->p.bounds_error.rule_name, "r") == 0;
        break;
    default:
        break;
    }
    return DS_OK_R;
}

static int first_of(const trace_t *t, int kind)
{
    for (int i = 0; i < t->n; i++) if (t->kind[i] == kind) return i;
    return -1;
}
static int count_of(const trace_t *t, int kind)
{
    int n = 0;
    for (int i = 0; i < t->n; i++) if (t->kind[i] == kind) n++;
    return n;
}
static int faults(const trace_t *t)
{
    return count_of(t, DS_EV_TYPE_ERROR) + count_of(t, DS_EV_ENGINE_ERROR)
         + count_of(t, DS_EV_COMPUTATION_ERROR) + count_of(t, DS_EV_BOUNDS_ERROR);
}

/* ---- expression builders --------------------------------------------- */

static ds_rete_expr_t *var_ref(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = pat; e->var.slot_index = slot; return e;
}
static ds_rete_expr_t *lit_int(int64_t v)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = v; return e;
}
static ds_rete_expr_t *lit_float(double v)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_FLOAT);
    e->lit_float = v; return e;
}
static ds_rete_expr_t *lit_str(const char *s)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    e->lit_str = s; return e;
}
static ds_rete_expr_t *binop(ds_rete_binop_t op, ds_rete_expr_t *l,
                             ds_rete_expr_t *r)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    e->binop.op = op; e->binop.left = l; e->binop.right = r; return e;
}
static ds_rete_expr_t *bind_ref(uint32_t idx)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_BIND_REF);
    e->bind_ref.bind_index = idx; return e;
}
static ds_rete_expr_t *call1(uint32_t op, ds_rete_expr_t *arg)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    e->call.op = op;
    e->call.args = calloc(1, sizeof(*e->call.args));
    e->call.args[0] = arg;
    e->call.arg_count = 1;
    return e;
}

/* ---- a one-rule engine ------------------------------------------------ */

enum { N_OUT = 3 };

typedef struct {
    ds_engine_t            *engine;
    const ds_schema_t      *src_ds;
    const ds_rete_schema_t *out_rs[N_OUT];
    trace_t                 t;
} rig_t;

static int reg_schema_typed(ds_engine_t *engine, const char *name,
                            bool identity, ds_slot_type_t type,
                            const ds_schema_t **out_ds,
                            const ds_rete_schema_t **out_rs)
{
    ds_slot_desc_t sd = { .name = "val", .type = type,
                          .identity_role = identity ? DS_IDENTITY_KEY
                                                    : DS_IDENTITY_MUTABLE };
    if (ds_engine_register_schema(engine, name, DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  0, &sd, 1, out_ds).status != DS_OK)
        return 1;
    *out_rs = ds_rete_schema_by_name(engine->rete_engine, name);
    return *out_rs == NULL;
}

static int reg_schema(ds_engine_t *engine, const char *name, bool identity,
                      const ds_schema_t **out_ds,
                      const ds_rete_schema_t **out_rs)
{
    return reg_schema_typed(engine, name, identity, DS_SLOT_TYPE_INT, out_ds,
                            out_rs);
}

/* Src's one slot: Int, asserted as the `val` rig_fire is given, unless a case
   sets both of these, and then declared `g_src_type` and asserted as
   `*g_src_value`. */
static ds_slot_type_t         g_src_type = DS_SLOT_TYPE_INT;
static const ds_slot_value_t *g_src_value;

/* Src(val) plus three Out schemas; the caller builds the actions. */
static int rig_open(rig_t *g)
{
    memset(g, 0, sizeof(*g));
    ds_engine_config_t cfg = {0};
    if (ds_engine_new(&cfg, &g->engine).status != DS_OK || !g->engine)
        return 1;
    const ds_rete_schema_t *src_rs = NULL;
    const ds_schema_t *ignored = NULL;
    static const char *names[N_OUT] = { "Out0", "Out1", "Out2" };
    if (reg_schema_typed(g->engine, "Src", false, g_src_type, &g->src_ds,
                         &src_rs))
        return 1;
    for (int i = 0; i < N_OUT; i++)
        if (reg_schema(g->engine, names[i], true, &ignored, &g->out_rs[i]))
            return 1;
    return 0;
}

/* Run, when set, between the assert and the pump: what a case arms for the
   pump alone. */
static void (*g_before_pump)(void);

/* The alpha node's tests, when a case sets them; none otherwise. */
static ds_retp_alpha_test_t *g_alpha_tests;
static uint32_t              g_alpha_test_count;

/* Load `Src s [join] -> actions`. Node ids are fixed: alpha 1, beta 2, terminal 3. */
static int rig_load(rig_t *g, ds_rete_action_t *actions, uint32_t n_actions,
                    ds_rete_join_test_t *join, uint32_t n_join,
                    uint32_t bind_count)
{
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src",
                                 .tests = g_alpha_tests,
                                 .test_count = g_alpha_test_count }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1,
                                 .left_parent_id = 0,
                                 .join_tests = join,
                                 .join_test_count = n_join }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "r",
                                 .bind_count = bind_count,
                                 .actions = actions,
                                 .action_count = n_actions }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    return ds_rete_load_network(g->engine->rete_engine, &net).status != DS_OK;
}

/* rig_load, attach `cb`, assert Src(val), pump. */
static int rig_fire_cb(rig_t *g, ds_rete_action_t *actions, uint32_t n_actions,
                       ds_rete_join_test_t *join, uint32_t n_join,
                       uint32_t bind_count, int64_t val,
                       ds_stream_cb_t cb, void *cb_user)
{
    if (rig_load(g, actions, n_actions, join, n_join, bind_count))
        return 1;
    if (ds_engine_set_stream_callback(g->engine, cb, cb_user).status != DS_OK)
        return 1;
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = val };
    if (g_src_value) sv = *g_src_value;
    /* An alpha test's or a join test's EngineError halts the engine during
       the assert, which then reports the halt ([NCBK.2.9]), as the pump does
       below. The pump on the halted engine is refused at entry. */
    ds_status_t as = ds_engine_assert(g->engine, g->src_ds, &sv, 1, NULL).status;
    bool halted = false;
    if (ds_engine_halted(g->engine, &halted, NULL).status != DS_OK)
        return 1;
    if (as != (halted ? DS_ERR_ENGINE_HALTED : DS_OK))
        return 1;
    if (g_before_pump) g_before_pump();
    /* A FAULT DOES NOT FAIL THE PUMP — that is itself one of the claims —
       BUT AN EngineError IS REPORTED BY IT ([NCBK.2.9]): a pump that
       halted the engine returns DS_ERR_ENGINE_HALTED, and any other pump,
       faulted or not, DS_OK. Both are checked: a pump that halted and said
       DS_OK fails the rig, and so does one that said HALTED and did not. */
    ds_status_t s = ds_engine_pump(g->engine).status;
    if (ds_engine_halted(g->engine, &halted, NULL).status != DS_OK)
        return 1;
    return s != (halted ? DS_ERR_ENGINE_HALTED : DS_OK);
}

/* The same, with the plain trace attached. */
static int rig_fire(rig_t *g, ds_rete_action_t *actions, uint32_t n_actions,
                    ds_rete_join_test_t *join, uint32_t n_join,
                    uint32_t bind_count, int64_t val)
{
    return rig_fire_cb(g, actions, n_actions, join, n_join, bind_count, val,
                       trace_cb, &g->t);
}

static ds_rete_action_t assert_out(const rig_t *g, int which,
                                   ds_rete_slot_assign_t *assign,
                                   ds_rete_expr_t *value)
{
    assign->slot_index = 0;
    assign->expr = value;
    ds_rete_action_t a = { .kind = DS_RETE_ACTION_ASSERT,
                           .schema_id = g->out_rs[which]->id,
                           .assigns = assign, .assign_count = 1 };
    return a;
}

/* ---- CLASSIFIED, and THE ACTIVATION ------------------------------------ */

static void test_computation_error_abandons_the_activation(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_slot_assign_t as[3];
    ds_rete_action_t acts[3] = {
        assert_out(&g, 0, &as[0], var_ref(0, 0)),
        assert_out(&g, 1, &as[1], binop(DS_RETE_BINOP_IDIV, var_ref(0, 0),
                                        lit_int(0))),
        assert_out(&g, 2, &as[2], var_ref(0, 0)),
    };
    CHECK(rig_fire(&g, acts, 3, NULL, 0, 0, 7) == 0,
          "load, assert and pump succeed; a fault is not a pump failure");

    int ce = first_of(&g.t, DS_EV_COMPUTATION_ERROR);
    CHECK(ce >= 0, "division by zero emits DS_EV_COMPUTATION_ERROR");
    CHECK(faults(&g.t) == 1, "exactly one fault is recorded");
    if (ce >= 0) {
        CHECK(g.t.detail[ce] == DS_TRAP_DIVIDE_BY_ZERO, "kind DIVIDE_BY_ZERO");
        CHECK(g.t.node_id[ce] == 3, "node_id is the terminal");
        CHECK(g.t.has_rule[ce], "rule_name is the firing rule");
        CHECK(g.t.timetag[ce] != 0, "timetag is the firing activation's");
        /* The offending operand is the divisor, a LITERAL 0, so there
           is no slot to name. */
        CHECK(g.t.schema[ce][0] == '\0' && g.t.slot[ce][0] == '\0'
              && g.t.fact_id[ce] == 0,
              "a literal divisor names no schema, slot or fact");
    }

    /* Action one ran, action two faulted, action three did not run. */
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 1,
          "only the action before the fault emitted");
    int rfb = first_of(&g.t, DS_EV_RULE_FIRE_BEGIN);
    int rfe = first_of(&g.t, DS_EV_RULE_FIRE_END);
    CHECK(rfb >= 0 && rfe > rfb, "the firing bracket still closes");
    CHECK(ce > rfb && ce < rfe, "the fault is recorded inside its firing");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* ---- FAULT FACTS ([LERR.9]) ------------------------------------------- */

/* The built-in `ComputationError`, slots in [LERR.9.2]'s order. The rig's
   hand-built network has no artefact, so it is registered here -- through the
   public API, which has no `explicit` lifecycle and refuses a `logical` schema
   whose slots carry no identity role ([LFAC.1.7.4], require-all). So every slot
   is MUTABLE: a keyless logical schema, one live fact, which is all these two
   cases put in it. An artefact carries the schema as plain explicit
   (`dsc.builtins` says why); the drain does not read the lifecycle. */
static int reg_computation_error(ds_engine_t *engine)
{
    static const ds_slot_desc_t ce[5] = {
        { .name = "kind",   .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "rule",   .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "schema", .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "slot",   .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "node",   .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    ds_result_t r = ds_engine_register_schema(engine, "ComputationError",
                                              DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                              ce, 5, NULL);
    if (r.status != DS_OK)
        fprintf(stderr, "register ComputationError: [%d] %s\n", (int) r.status,
                r.detail ? r.detail : "");
    return r.status != DS_OK;
}

static int emits_of(const trace_t *t, const char *schema)
{
    int n = 0;
    for (int i = 0; i < t->n; i++)
        if (t->kind[i] == DS_EV_ACTION_EMIT
            && strcmp(t->emit_schema[i], schema) == 0)
            n++;
    return n;
}

static int first_emit_of(const trace_t *t, const char *schema)
{
    for (int i = 0; i < t->n; i++)
        if (t->kind[i] == DS_EV_ACTION_EMIT
            && strcmp(t->emit_schema[i], schema) == 0)
            return i;
    return -1;
}

/* [LERR.9.1]: the trap is recorded, then asserted as a fault fact -- after the
   abandoned activation has unwound, so after its RULE_FIRE_END ([LERR.9.7]) --
   recorded as an emit whose `kind` and `rule` are the fault's ([LERR.9.2],
   [LERR.9.11]). */
static void test_lerr_9_1_a_trap_is_asserted_as_a_fault_fact(void)
{
    rig_t g;
    if (rig_open(&g) || reg_computation_error(g.engine)) {
        fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done;
    }
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = {
        assert_out(&g, 0, &as, binop(DS_RETE_BINOP_IDIV, var_ref(0, 0),
                                     lit_int(0))),
    };
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, "pump succeeds");

    int ce  = first_of(&g.t, DS_EV_COMPUTATION_ERROR);
    int rfe = first_of(&g.t, DS_EV_RULE_FIRE_END);
    int fe  = first_emit_of(&g.t, "ComputationError");
    CHECK(ce >= 0, "the trap is recorded");
    CHECK(fe >= 0, "and asserted as a ComputationError fact");
    CHECK(emits_of(&g.t, "ComputationError") == 1, "exactly once");
    if (fe >= 0) {
        CHECK(ce < fe, "the record comes first ([LERR.9.1])");
        CHECK(rfe >= 0 && rfe < fe,
              "and the fact after the abandoned firing unwound ([LERR.9.7])");
        CHECK(strcmp(g.t.emit_s0[fe], "DIVIDE_BY_ZERO") == 0,
              "kind is the TrapKind without TRAP_");
        CHECK(strcmp(g.t.emit_s1[fe], "r") == 0,
              "rule is the activation's rule");
    }

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* [LERR.9.10]: under the pools, a fault fact never takes a slot of the working
   memory the integrator sized. wm_max is 1 and Src fills it; the rule's
   division traps; the fault fact must still be asserted, from the fault-fact
   site the header carries (set here as the loader would). And the cap must
   still hold for an ordinary fact, or excluding everything would pass too. */
static void test_lerr_9_10_a_fault_fact_takes_no_wm_slot(void)
{
    rig_t g;
    const ds_schema_t *other_ds = NULL;
    const ds_rete_schema_t *other_rs = NULL;
    if (rig_open(&g) || reg_computation_error(g.engine)
        || reg_schema(g.engine, "Other", true, &other_ds, &other_rs)) {
        fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done;
    }
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = {
        assert_out(&g, 0, &as, binop(DS_RETE_BINOP_IDIV, var_ref(0, 0),
                                     lit_int(0))),
    };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1,
                                 .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "r", .actions = acts,
                                 .action_count = 1 }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    CHECK(ds_rete_load_network(g.engine->rete_engine, &net).status == DS_OK,
          "the network loads");
    g.engine->rete_engine->fault_fact_sites = 1u;
    /* A pre-sizing artefact arms the pools at load (dsc/loader.c sets
       pending_rt); set_wm_max alone engages nothing ([NRTM.3.1]). No
       artefact of this edition pre-sizes, so the arming is done here as the
       loader would, to keep [LERR.9.10]'s pool under test. */
    g.engine->rete_engine->pending_rt = true;
    CHECK(ds_engine_set_wm_max(g.engine, 1).status == DS_OK,
          "wm_max 1 engages the pools");
    CHECK(ds_engine_set_stream_callback(g.engine, trace_cb, &g.t).status
              == DS_OK, "trace attached");

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 7 };
    CHECK(ds_engine_assert(g.engine, g.src_ds, &sv, 1, NULL).status == DS_OK,
          "Src fills working memory");
    CHECK(ds_engine_pump(g.engine).status == DS_OK, "the pump succeeds");
    CHECK(emits_of(&g.t, "ComputationError") == 1,
          "the fault fact is asserted though working memory is full");

    ds_slot_value_t ov = { .kind = DS_SLOT_INT, .v.i = 1 };
    CHECK(ds_engine_assert(g.engine, other_ds, &ov, 1, NULL).status
              == DS_ERR_WM_FULL,
          "and an ordinary fact past wm_max is still refused");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* [LERR.9.5]: a second fault at the same site, with every slot equal, is a
   suppressed no-op -- recorded on the stream, never asserted again. The
   divisor is a literal, so the second fault names no schema or slot, exactly
   like the first. */
static void test_lerr_9_5_an_identical_fault_is_latched(void)
{
    rig_t g;
    if (rig_open(&g) || reg_computation_error(g.engine)) {
        fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done;
    }
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = {
        assert_out(&g, 0, &as, binop(DS_RETE_BINOP_IDIV, var_ref(0, 0),
                                     lit_int(0))),
    };
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, "first pump succeeds");
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 8 };
    CHECK(ds_engine_assert(g.engine, g.src_ds, &sv, 1, NULL).status == DS_OK,
          "a second Src fact");
    CHECK(ds_engine_pump(g.engine).status == DS_OK, "second pump succeeds");

    CHECK(count_of(&g.t, DS_EV_COMPUTATION_ERROR) == 2,
          "both traps are recorded ([LERR.9.5]: the trace keeps every one)");
    CHECK(emits_of(&g.t, "ComputationError") == 1,
          "and the identical second fault fact is a no-op");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* A DIVISOR READ FROM A SLOT IS NAMED. `100 // s.val` with val 0 is
   a DIVIDE_BY_ZERO whose slot context ([NCBK.2.10], `engine_error.proto`) is
   the fact read, Src, and its slot val. The Src fact is the first the engine
   assigned, so the integrator's fact_id is 1. */
static void test_computation_error_names_its_slot(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = {
        assert_out(&g, 0, &as, binop(DS_RETE_BINOP_IDIV, lit_int(100),
                                     var_ref(0, 0))),
    };
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 0) == 0, "pump succeeds");

    int ce = first_of(&g.t, DS_EV_COMPUTATION_ERROR);
    CHECK(ce >= 0, "100 // 0 emits DS_EV_COMPUTATION_ERROR");
    if (ce >= 0) {
        CHECK(strcmp(g.t.schema[ce], "Src") == 0, "schema is Src");
        CHECK(strcmp(g.t.slot[ce], "val") == 0, "slot is val");
        CHECK(g.t.fact_id[ce] == 1, "fact_id is the Src fact's");
        CHECK(g.t.node_id[ce] == 3, "node_id is the terminal");
    }

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* A JOIN TEST RAISING OVER THE FACT BEING ASSERTED NAMES THAT FACT.
   `100 // s.val > 0` runs while the host's Src(val = 0) propagates, before the
   bridge has minted its wrapper, so the slot read finds a fact with no
   integrator id yet. The fault names the id it takes, 1, as the Mercury
   runtime's does; the recordings gate compares the two. */
static void test_join_fault_names_the_fact_being_asserted(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_join_test_t join[1] = {{
        .expr = binop(DS_RETE_BINOP_GT,
                      binop(DS_RETE_BINOP_IDIV, lit_int(100),
                            var_ref(DS_RETE_VAR_RIGHT_FACT, 0)),
                      lit_int(0)) }};
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, var_ref(0, 0)) };
    CHECK(rig_fire(&g, acts, 1, join, 1, 0, 0) == 0, "pump succeeds");

    int ce = first_of(&g.t, DS_EV_COMPUTATION_ERROR);
    CHECK(ce >= 0, "the join test's 100 // 0 emits DS_EV_COMPUTATION_ERROR");
    if (ce >= 0) {
        CHECK(strcmp(g.t.schema[ce], "Src") == 0, "schema is Src");
        CHECK(strcmp(g.t.slot[ce], "val") == 0, "slot is val");
        CHECK(g.t.fact_id[ce] == 1, "fact_id is the Src fact being asserted");
        CHECK(g.t.node_id[ce] == 2, "node_id is the beta node");
    }

done:
    if (g.engine) ds_engine_free(g.engine);
}

static void test_call_action_fault_is_not_discarded(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[2] = {
        { .kind = DS_RETE_ACTION_CALL,
          .expr = binop(DS_RETE_BINOP_MOD, var_ref(0, 0), lit_int(0)) },
        assert_out(&g, 0, &as, var_ref(0, 0)),
    };
    CHECK(rig_fire(&g, acts, 2, NULL, 0, 0, 7) == 0, "pump succeeds");
    CHECK(count_of(&g.t, DS_EV_COMPUTATION_ERROR) == 1,
          "the CALL action's fault is recorded");
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 0,
          "and the action after it does not run");

done:
    if (g.engine) ds_engine_free(g.engine);
}

static void test_float_to_int_is_not_representable(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = {
        assert_out(&g, 0, &as, call1(DS_FN_FLOAT_TO_INT, lit_float(INFINITY))),
    };
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, "pump succeeds");
    int ce = first_of(&g.t, DS_EV_COMPUTATION_ERROR);
    CHECK(ce >= 0, "a non-finite Float :: Int emits DS_EV_COMPUTATION_ERROR");
    if (ce >= 0)
        CHECK(g.t.detail[ce] == DS_TRAP_NOT_REPRESENTABLE,
              "kind NOT_REPRESENTABLE, not DOMAIN");
    CHECK(faults(&g.t) == 1, "exactly one fault is recorded");
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 0, "nothing is asserted");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* The provenance split, both arms, on the same operation. */
static void provenance_case(bool tainted, int want_kind)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_expr_t *add = binop(DS_RETE_BINOP_ADD, var_ref(0, 0), lit_str("x"));
    add->json_tainted = tainted;
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, add) };
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, "pump succeeds");

    int at = first_of(&g.t, want_kind);
    CHECK(at >= 0, tainted ? "a tainted Int + String emits DS_EV_TYPE_ERROR"
                           : "a clean Int + String emits DS_EV_ENGINE_ERROR");
    CHECK(faults(&g.t) == 1, "exactly one fault is recorded");
    if (at >= 0) {
        CHECK(g.t.node_id[at] == 3, "node_id is the terminal");
        /* [LERR.9.11]: a fault in an activation carries its rule, whichever
           of the two atoms records it. */
        CHECK(strcmp(g.t.rule[at], "r") == 0, "rule_name is the firing rule");
        if (!tainted)
            CHECK(g.t.detail[at] == DS_ENGINE_FAULT_ARTEFACT_LIED,
                  "fault ARTEFACT_LIED");
        /* No operand is null and it is no division, so the offending
           operand is the first, the slot read Src.val, an Int. */
        if (tainted) {
            CHECK(strcmp(g.t.schema[at], "Src") == 0, "schema is Src");
            CHECK(strcmp(g.t.slot[at], "val") == 0, "slot is val");
            CHECK(strcmp(g.t.actual[at], "Int") == 0, "actual is Int");
        }
    }
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 0, "nothing is asserted");

done:
    if (g.engine) ds_engine_free(g.engine);
}

static void test_type_mismatch_splits_on_provenance(void)
{
    provenance_case(true,  DS_EV_TYPE_ERROR);
    provenance_case(false, DS_EV_ENGINE_ERROR);
}

/* ---- THE HALT LATCH ([LERR.1], [NCBK.2.9]) ----------------------------- */

/* Drive a REAL halt. The clean Int + String above raises ARTEFACT_LIED, an
 * EngineError, and the latch is set on the way to the stream. What this drives
 * is the hand-built network through rig_*, not a loaded `.dsc` — the compiler
 * will not emit a clean type mismatch, which is why the impl path is the only
 * way to reach it. A fault has to REACH the latch: setting `halted` by hand
 * would test the guard and not the wiring from the raise site to it.
 *
 * The action storage is the CALLER's, because the loaded network borrows it
 * for the engine's life and the tests below keep calling into that engine. */
static int fire_halt(rig_t *g, ds_rete_slot_assign_t *as, ds_rete_action_t *acts)
{
    if (rig_open(g)) return 1;
    ds_rete_expr_t *add = binop(DS_RETE_BINOP_ADD, var_ref(0, 0), lit_str("x"));
    acts[0] = assert_out(g, 0, as, add);
    if (rig_fire(g, acts, 1, NULL, 0, 0, 7)) return 1;
    return first_of(&g->t, DS_EV_ENGINE_ERROR) < 0;
}

/* [NCBK.2.11]: the latch can be read, before and after the halt, and it names
 * the fault the DS_EV_ENGINE_ERROR carried. The halt is the real one fire_halt
 * drives (ARTEFACT_LIED), so the cause has to travel from the raise site
 * through the recorder's funnel to the accessor. */
static void test_ncbk_2_11__the_latch_is_readable(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; return; }
    bool halted = true;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_PUMP_WCET;
    CHECK(ds_engine_halted(g.engine, &halted, &fault).status == DS_OK,
          "ds_engine_halted answers on a live engine");
    CHECK(halted == false, "not halted before any fault");
    CHECK(fault == DS_ENGINE_FAULT_UNSPECIFIED, "and the fault is UNSPECIFIED");
    CHECK(ds_engine_halted(g.engine, NULL, NULL).status == DS_OK,
          "both out-pointers may be NULL");
    ds_engine_free(g.engine);

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1];
    if (fire_halt(&g, &as, acts)) {
        fprintf(stderr, "FAIL: fire_halt\n"); g_fails++; goto done;
    }
    halted = false;
    fault = DS_ENGINE_FAULT_UNSPECIFIED;
    CHECK(ds_engine_halted(g.engine, &halted, &fault).status == DS_OK,
          "ds_engine_halted still answers after the halt");
    CHECK(halted == true, "halted after the EngineError");
    CHECK(fault == DS_ENGINE_FAULT_ARTEFACT_LIED,
          "the fault is the one the DS_EV_ENGINE_ERROR carried");
    CHECK(ds_engine_pump(g.engine).status == DS_ERR_ENGINE_HALTED,
          "a mutator is refused meanwhile");
    fault = DS_ENGINE_FAULT_UNSPECIFIED;
    CHECK(ds_engine_halted(g.engine, NULL, &fault).status == DS_OK
              && fault == DS_ENGINE_FAULT_ARTEFACT_LIED,
          "a refused call leaves the cause as it was");

done:
    if (g.engine) ds_engine_free(g.engine);
}

static ds_result_t first_fact(const ds_fact_t *fact, void *user)
{
    const ds_fact_t **out = (const ds_fact_t **) user;
    if (*out == NULL) *out = fact;
    return DS_OK_R;
}

/* Everything that would mutate engine state or submit work is refused with
 * DS_ERR_ENGINE_HALTED — one call from each family [NCBK.2.9] names: fact
 * mutation (assert, retract), work (pump), structure (load_dsc, clone,
 * register_schema), the clock, configuration (set_wm_max) and a callback
 * setter. The latch never clears, so a second pump refuses too.
 *
 * THE REFUSAL IS THE LATCH'S ALONE ([NCBK.2.9]: "consults the latch and
 * nothing else"). Working memory after the halt is undefined and its reads are
 * refused (test_ncbk_2_9__reads_refused_after_halt), so nothing here can be
 * proved by comparing it before and after. What proves it instead: retract is
 * handed NULL, which a running engine answers DS_ERR_INVAL, and the halted one
 * answers DS_ERR_ENGINE_HALTED before it looks at the argument. */
/* @spec [IERR.2.3.3] */
static void test_ncbk_2_9__mutating_calls_refused_after_halt(void)
{
    rig_t g;
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1];
    if (fire_halt(&g, &as, acts)) {
        fprintf(stderr, "FAIL: fire_halt\n"); g_fails++; goto done;
    }

    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = 9 };
    CHECK(ds_engine_assert(g.engine, g.src_ds, &sv, 1, NULL).status
              == DS_ERR_ENGINE_HALTED, "assert is refused");
    CHECK(ds_engine_retract(g.engine, NULL).status == DS_ERR_ENGINE_HALTED,
          "retract is refused by the latch, before its argument is checked");
    CHECK(ds_engine_pump(g.engine).status == DS_ERR_ENGINE_HALTED,
          "pump is refused");

    static const uint8_t junk[1] = { 0 };
    CHECK(ds_engine_load_dsc(g.engine, junk, sizeof junk).status
              == DS_ERR_ENGINE_HALTED,
          "load_dsc is refused before it parses anything");
    ds_engine_t *clone = NULL;
    CHECK(ds_engine_clone(g.engine, &clone).status == DS_ERR_ENGINE_HALTED,
          "clone is refused rather than carrying the halt into a new engine");
    CHECK(clone == NULL, "and no engine was produced");
    if (clone != NULL) ds_engine_free(clone);

    CHECK(ds_engine_clock_set(g.engine, 1000).status == DS_ERR_ENGINE_HALTED,
          "the clock cannot be set");
    CHECK(ds_engine_set_wm_max(g.engine, 10).status == DS_ERR_ENGINE_HALTED,
          "configuration is refused");
    CHECK(ds_engine_set_stream_callback(g.engine, NULL, NULL).status
              == DS_ERR_ENGINE_HALTED, "a callback setter is refused");

    CHECK(ds_engine_pump(g.engine).status == DS_ERR_ENGINE_HALTED,
          "and a second pump still refuses: the latch never clears");

    /* LAST, DELIBERATELY. The halt guard answers here, but it is not the only
     * thing standing between this call and an aborted process — see
     * test_register_schema_after_the_first_pump below, which covers the
     * NON-halted engine that reaches the same frozen intern table. Ordering
     * this last keeps a regression loud without costing the evidence the other
     * checks carry. */
    CHECK(ds_engine_register_schema(g.engine, "Late",
                                    DS_SCHEMA_LIFECYCLE_LOGICAL, 0, NULL, 0,
                                    NULL).status == DS_ERR_ENGINE_HALTED,
          "no schema can be registered after the halt");

done:
    /* ds_engine_free stays valid: disposal is not resumption. */
    if (g.engine) ds_engine_free(g.engine);
}

/* A read of engine state is refused after the halt, as a mutation is
 * ([NCBK.2.9]): the state the halt left is undefined
 * ([LERR.1.4.7]), so working memory, schemas and the introspection surface
 * have no answer. One read from each: fact_count, for_each_fact, schema_find,
 * clock_now, mem, rule_meta_count, get_justifiers. The two load-time reports
 * the clause keeps valid still answer -- the provenance a recording of the
 * halted run is filed under ([NDET.2.1]). */
static void test_ncbk_2_9__reads_refused_after_halt(void)
{
    rig_t g;
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1];
    if (fire_halt(&g, &as, acts)) {
        fprintf(stderr, "FAIL: fire_halt\n"); g_fails++; goto done;
    }

    size_t n = 0;
    CHECK(ds_engine_fact_count(g.engine, &n).status == DS_ERR_ENGINE_HALTED,
          "fact_count is refused");
    const ds_fact_t *src_fact = NULL;
    CHECK(ds_engine_for_each_fact(g.engine, g.src_ds, first_fact, &src_fact)
              .status == DS_ERR_ENGINE_HALTED && src_fact == NULL,
          "for_each_fact is refused, and visits nothing");
    const ds_schema_t *found = NULL;
    CHECK(ds_engine_schema_find(g.engine, "Src", &found).status
              == DS_ERR_ENGINE_HALTED, "schema_find is refused");
    uint64_t now_ns = 0;
    CHECK(ds_engine_clock_now(g.engine, &now_ns).status == DS_ERR_ENGINE_HALTED,
          "clock_now is refused");
    ds_engine_mem_t mem;
    CHECK(ds_engine_mem(g.engine, &mem).status == DS_ERR_ENGINE_HALTED,
          "mem is refused");
    size_t n_rules = 0;
    CHECK(ds_engine_rule_meta_count(g.engine, &n_rules).status
              == DS_ERR_ENGINE_HALTED, "rule_meta_count is refused");
    int64_t  *timetags = NULL;
    char    **names    = NULL;
    uint32_t  n_just   = 0;
    CHECK(ds_engine_get_justifiers(g.engine, 1, &timetags, &names, &n_just)
              .status == DS_ERR_ENGINE_HALTED && n_just == 0,
          "get_justifiers is refused");
    for (uint32_t i = 0; i < n_just; i++) ds_free(names[i]);
    ds_free(names);
    ds_free(timetags);

    ds_platform_signature_t sig;
    CHECK(ds_engine_get_platform_signature(g.engine, &sig).status == DS_OK,
          "the platform signature still answers");
    ds_session_header_t hdr;
    CHECK(ds_engine_get_session_header(g.engine, &hdr).status == DS_OK,
          "the session header still answers");
    bool halted = false;
    CHECK(ds_engine_halted(g.engine, &halted, NULL).status == DS_OK && halted,
          "ds_engine_halted still answers");
    CHECK(ds_engine_pump(g.engine).status == DS_ERR_ENGINE_HALTED,
          "and none of them cleared the latch");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* Inside the callback delivering the EngineError, a call on that engine is
 * RE-ENTRY and answers DS_ERR_STATE ([RARC.13.16]) — and that holds for a
 * mutator too, though the latch is already set by the time the event is
 * dispatched. So re-entry is checked BEFORE the halt. Once the pump has
 * returned, the halt is the ordinary one: the read and the mutator both get
 * DS_ERR_ENGINE_HALTED ([NCBK.2.9]). */
typedef struct {
    trace_t     t;
    int         saw_engine_error;
    ds_status_t read_inside;
    ds_status_t pump_inside;
} reentry_probe_t;

static ds_result_t reentry_probe_cb(ds_engine_t *e, const ds_stream_ev_t *ev,
                                    void *user)
{
    reentry_probe_t *p = (reentry_probe_t *) user;
    (void) trace_cb(e, ev, &p->t);
    if (ev->kind == DS_EV_ENGINE_ERROR && !p->saw_engine_error) {
        p->saw_engine_error = 1;
        size_t n = 0;
        p->read_inside = ds_engine_fact_count(e, &n).status;
        p->pump_inside = ds_engine_pump(e).status;
    }
    return DS_OK_R;
}

static void test_ncbk_2_9__read_inside_the_fault_callback_is_reentry(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    reentry_probe_t p;
    memset(&p, 0, sizeof(p));
    p.read_inside = DS_OK;
    p.pump_inside = DS_OK;

    ds_rete_expr_t *add = binop(DS_RETE_BINOP_ADD, var_ref(0, 0), lit_str("x"));
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, add) };
    CHECK(rig_fire_cb(&g, acts, 1, NULL, 0, 0, 7, reentry_probe_cb, &p) == 0,
          "pump succeeds");

    CHECK(p.saw_engine_error, "the callback received the EngineError");
    CHECK(p.read_inside == DS_ERR_STATE,
          "a read inside the fault callback is re-entry: DS_ERR_STATE");
    CHECK(p.pump_inside == DS_ERR_STATE,
          "a mutator inside it is re-entry too, not DS_ERR_ENGINE_HALTED -- "
          "re-entry is checked before the halt");

    size_t n = 0;
    CHECK(ds_engine_fact_count(g.engine, &n).status == DS_ERR_ENGINE_HALTED,
          "once the pump has returned, the read gets the ordinary halt");
    CHECK(ds_engine_pump(g.engine).status == DS_ERR_ENGINE_HALTED,
          "and so does the mutator");

done:
    if (g.engine) ds_engine_free(g.engine);
}

static void test_read_before_bind_is_binding_order(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, bind_ref(0)) };
    CHECK(rig_fire(&g, acts, 1, NULL, 0, /*bind_count*/ 1, 7) == 0,
          "pump succeeds");
    int ee = first_of(&g.t, DS_EV_ENGINE_ERROR);
    CHECK(ee >= 0, "a read before the binding ran emits DS_EV_ENGINE_ERROR");
    if (ee >= 0) {
        CHECK(g.t.detail[ee] == DS_ENGINE_FAULT_BINDING_ORDER,
              "fault BINDING_ORDER");
        /* [LERR.9.11]: an EngineError in an activation carries its rule. */
        CHECK(strcmp(g.t.rule[ee], "r") == 0,
              "an activation's EngineError names the activation's rule");
    }
    CHECK(faults(&g.t) == 1, "exactly one fault is recorded");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* [RARC.5.3.3]: a read of a pattern position the match never bound is an
   EngineError, PATTERN_INDEX -- not a null. Both nodes that read a token
   position, a slot read (VAR) and an entry stamp, are driven; the token has
   one fact and each asks for the sixth. */
static void pattern_index_case(ds_rete_expr_t *read, const char *what)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, read) };
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, "pump succeeds");
    int ee = first_of(&g.t, DS_EV_ENGINE_ERROR);
    CHECK(ee >= 0, what);
    if (ee >= 0) {
        CHECK(g.t.detail[ee] == DS_ENGINE_FAULT_PATTERN_INDEX,
              "fault PATTERN_INDEX");
        CHECK(g.t.node_id[ee] == 3, "node_id is the terminal");
        CHECK(strcmp(g.t.rule[ee], "r") == 0,
              "an activation's EngineError names the activation's rule");
    }
    CHECK(faults(&g.t) == 1, "exactly one fault is recorded");
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 0, "nothing is asserted");
    bool halted = false;
    CHECK(ds_engine_halted(g.engine, &halted, NULL).status == DS_OK && halted,
          "and the engine is halted ([LERR.1.4.7])");

done:
    if (g.engine) ds_engine_free(g.engine);
}

static void test_rarc_5_3_3__a_position_never_bound_is_pattern_index(void)
{
    pattern_index_case(var_ref(5, 0),
                       "a slot read past the token emits DS_EV_ENGINE_ERROR");
    ds_rete_expr_t *stamp = ds_rete_expr_alloc(DS_RETE_EXPR_ENTRY_STAMP);
    stamp->entry_stamp.pattern_index = 5;
    pattern_index_case(stamp,
                       "an entry stamp past the token emits DS_EV_ENGINE_ERROR");
}

/* ---- NO FIXED BUFFER -------------------------------------------------- */

/* A result longer than an internal buffer is not a fault: the whole string is
   produced, nothing is recorded, and the next action runs. */
static void test_long_concatenation_is_not_a_fault(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    static char big[5001];
    memset(big, 'a', 5000);
    big[5000] = '\0';
    /* An interpolated string of two values. */
    ds_rete_expr_t *cat = ds_rete_expr_alloc(DS_RETE_EXPR_INTERP);
    cat->interp.prims = calloc(2, sizeof(*cat->interp.prims));
    cat->interp.prims[0].kind = DS_RETE_FPRIM_VALUE;
    cat->interp.prims[0].value = lit_str(big);
    cat->interp.prims[1].kind = DS_RETE_FPRIM_VALUE;
    cat->interp.prims[1].value = lit_str(big);
    cat->interp.prim_count = 2;

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[2] = {
        { .kind = DS_RETE_ACTION_CALL, .expr = cat },
        assert_out(&g, 0, &as, var_ref(0, 0)),
    };
    CHECK(rig_fire(&g, acts, 2, NULL, 0, 0, 7) == 0, "pump succeeds");
    CHECK(faults(&g.t) == 0, "a 10 000-byte concatenation records no fault");
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 1, "and the next action runs");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* ---- AN ALLOCATION FAILURE IS AN EngineError -------------------------- */

/* A strong ds_* set, overriding libds's weak defaults for this binary
   ([IALC.5]): libc, except that once armed it refuses any single request of
   at least g_refuse_at bytes. Disarmed (0) it is libc exactly, so every other
   case in this file runs on the default allocator. */
static size_t g_refuse_at;
static int    g_refused;
/* Refuse the next ds_malloc request whatever its size: the refraction
   mark's tuple copy is a few bytes, so no size threshold can single it out. */
static bool   g_refuse_next_malloc;

static bool refuse(size_t n)
{
    if (g_refuse_at != 0 && n >= g_refuse_at) { g_refused++; return true; }
    return false;
}

void *ds_malloc(size_t n)
{
    if (g_refuse_next_malloc) {
        g_refuse_next_malloc = false;
        g_refused++;
        return NULL;
    }
    return refuse(n) ? NULL : malloc(n);
}
void  ds_free(void *p)              { free(p); }
/* Refuse the next ds_calloc of exactly this many bytes: the firing
   token's copy is one token-sized calloc, and nothing the pump does before it
   asks for that size. */
static size_t g_refuse_calloc_size;

void *ds_calloc(size_t n, size_t sz)
{
    if (g_refuse_calloc_size != 0 && sz != 0 && n <= SIZE_MAX / sz
            && n * sz == g_refuse_calloc_size) {
        g_refuse_calloc_size = 0;
        g_refused++;
        return NULL;
    }
    return (sz != 0 && n > SIZE_MAX / sz) || refuse(n * sz)
         ? NULL : calloc(n, sz);
}
void *ds_realloc(void *p, size_t n) { return refuse(n) ? NULL : realloc(p, n); }
char *ds_strdup(const char *s)      { return refuse(strlen(s) + 1) ? NULL : strdup(s); }
char *ds_strndup(const char *s, size_t n)
{
    return refuse(n + 1) ? NULL : strndup(s, n);
}

/* Arms the refusal when the firing begins, so the load, the assert and the
   match before it run on libc and only the firing's own allocations meet it. */
static ds_result_t arm_at_fire_cb(ds_engine_t *e, const ds_stream_ev_t *ev,
                                  void *user)
{
    if (ev->kind == DS_EV_RULE_FIRE_BEGIN) g_refuse_at = 8192;
    return trace_cb(e, ev, user);
}

/* A firing whose allocation fails, with no declared cap the limit, is an
   EngineError, ALLOCATION ([LERR.1.4.7]; engine_fault.proto's
   ENGINE_FAULT_ALLOCATION): the engine halts, and the next action does not
   run.

   The allocation that fails is the interpolation's: two 5000-byte values
   outgrow the engine's 4096-byte scratch, and the first heap buffer it asks
   for is 8192 bytes (eval.c, gw_put). Nothing else in the firing asks for 8
   KiB, so the refusal lands there and nowhere else -- g_refused counts it.
   test_long_concatenation_is_not_a_fault above is the same network with the
   refusal off: no fault, and the next action runs. */
static void test_an_allocation_failure_is_engine_fault_allocation(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    static char big[5001];
    memset(big, 'a', 5000);
    big[5000] = '\0';
    ds_rete_expr_t *cat = ds_rete_expr_alloc(DS_RETE_EXPR_INTERP);
    cat->interp.prims = calloc(2, sizeof(*cat->interp.prims));
    cat->interp.prims[0].kind = DS_RETE_FPRIM_VALUE;
    cat->interp.prims[0].value = lit_str(big);
    cat->interp.prims[1].kind = DS_RETE_FPRIM_VALUE;
    cat->interp.prims[1].value = lit_str(big);
    cat->interp.prim_count = 2;

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[2] = {
        { .kind = DS_RETE_ACTION_CALL, .expr = cat },
        assert_out(&g, 0, &as, var_ref(0, 0)),
    };
    g_refused = 0;
    CHECK(rig_fire_cb(&g, acts, 2, NULL, 0, 0, 7, arm_at_fire_cb, &g.t) == 0,
          "the pump returns, reporting the halt it raised ([NCBK.2.9])");
    g_refuse_at = 0;

    CHECK(g_refused == 1, "exactly one request was refused, the interpolation's");
    int ee = first_of(&g.t, DS_EV_ENGINE_ERROR);
    CHECK(ee >= 0, "the refused allocation emits DS_EV_ENGINE_ERROR");
    if (ee >= 0) {
        CHECK(g.t.detail[ee] == DS_ENGINE_FAULT_ALLOCATION, "fault ALLOCATION");
        CHECK(strcmp(g.t.rule[ee], "r") == 0,
              "an activation's EngineError names the activation's rule");
    }
    CHECK(faults(&g.t) == 1, "exactly one fault is recorded");
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 0,
          "the action after the fault does not run");
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    CHECK(ds_engine_halted(g.engine, &halted, &fault).status == DS_OK
              && halted && fault == DS_ENGINE_FAULT_ALLOCATION,
          "and the engine is halted on it ([LERR.1.4.7])");

done:
    g_refuse_at = 0;
    if (g.engine) ds_engine_free(g.engine);
}

/* Arms the one-request refusal when the firing ends. Between that event and
   the refraction mark the pump frees the firing's token and builds the
   tuple on the stack, so the next ds_malloc is the mark's copy of it. */
static ds_result_t arm_at_fire_end_cb(ds_engine_t *e, const ds_stream_ev_t *ev,
                                      void *user)
{
    if (ev->kind == DS_EV_RULE_FIRE_END) g_refuse_next_malloc = true;
    return trace_cb(e, ev, user);
}

/* THE REFRACTION MARK'S ALLOCATION IS THE FIRING'S, and its failure is
   EngineError ALLOCATION ([LERR.1.4.7]). The mark keeps the fired token's
   tuple ([IRET.11.3]); a mark kept on the hash alone would drop a colliding
   activation unfired, depending on the allocator ([LDET.1.1]). The fault is
   recorded for the rule and the tier halts, as for the interpolation's
   allocation above. The firing itself ran to its end. */
static void test_a_refused_refraction_mark_is_engine_fault_allocation(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, var_ref(0, 0)) };
    g_refused = 0;
    CHECK(rig_fire_cb(&g, acts, 1, NULL, 0, 0, 7, arm_at_fire_end_cb, &g.t) == 0,
          "the pump returns, reporting the halt it raised ([NCBK.2.9])");
    g_refuse_next_malloc = false;

    CHECK(g_refused == 1, "exactly one request was refused, the mark's tuple");
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 1,
          "the firing's action ran before the mark");
    int end = first_of(&g.t, DS_EV_RULE_FIRE_END);
    int ee  = first_of(&g.t, DS_EV_ENGINE_ERROR);
    CHECK(ee >= 0, "the refused mark emits DS_EV_ENGINE_ERROR");
    if (ee >= 0) {
        CHECK(ee > end, "after the firing's end, where the mark is");
        CHECK(g.t.detail[ee] == DS_ENGINE_FAULT_ALLOCATION, "fault ALLOCATION");
        CHECK(strcmp(g.t.rule[ee], "r") == 0,
              "the EngineError names the firing's rule");
    }
    CHECK(faults(&g.t) == 1, "exactly one fault is recorded");
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    CHECK(ds_engine_halted(g.engine, &halted, &fault).status == DS_OK
              && halted && fault == DS_ENGINE_FAULT_ALLOCATION,
          "and the engine is halted on it ([LERR.1.4.7])");

done:
    g_refuse_next_malloc = false;
    if (g.engine) ds_engine_free(g.engine);
}

static void arm_token_copy_refusal(void)
{
    g_refuse_calloc_size = sizeof(ds_rete_token_t);
}

/* THE FIRING TOKEN'S COPY IS THE FIRING'S ALLOCATION, and its failure is
   EngineError ALLOCATION ([LERR.1.4.7]). The pump copies the activation's
   token before the firing begins; when the copy fails, the fault is recorded
   for the rule, the tier halts, the activation is abandoned, and the pump
   reports DS_ERR_ENGINE_HALTED ([NCBK.2.9]).

   Armed between the assert and the pump, for the first token-sized calloc.
   That the firing never began, and that the fault names the rule, say the
   refusal landed on the copy and not on some other allocation of that size. */
static void test_a_refused_token_copy_is_engine_fault_allocation(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, var_ref(0, 0)) };
    g_refused = 0;
    g_before_pump = arm_token_copy_refusal;
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0,
          "the pump returns, reporting the halt it raised ([NCBK.2.9])");
    g_before_pump = NULL;
    g_refuse_calloc_size = 0;

    CHECK(g_refused == 1, "exactly one request was refused, the token's copy");
    CHECK(count_of(&g.t, DS_EV_RULE_FIRE_BEGIN) == 0,
          "the firing never began: the copy precedes it");
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 0, "and no action ran");
    int ee = first_of(&g.t, DS_EV_ENGINE_ERROR);
    CHECK(ee >= 0, "the refused copy emits DS_EV_ENGINE_ERROR");
    if (ee >= 0) {
        CHECK(g.t.detail[ee] == DS_ENGINE_FAULT_ALLOCATION, "fault ALLOCATION");
        CHECK(strcmp(g.t.rule[ee], "r") == 0,
              "the EngineError names the activation's rule");
    }
    CHECK(faults(&g.t) == 1, "exactly one fault is recorded");
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    CHECK(ds_engine_halted(g.engine, &halted, &fault).status == DS_OK
              && halted && fault == DS_ENGINE_FAULT_ALLOCATION,
          "and the engine is halted on it ([LERR.1.4.7])");

done:
    g_before_pump = NULL;
    g_refuse_calloc_size = 0;
    if (g.engine) ds_engine_free(g.engine);
}

/* ---- A CAP BREACH IS A STREAM EVENT ([NCBK.2.8]) ---------------------- */

/* A fact a RULE emits into a full working memory: the wm_max refusal is
   recorded inside the firing, not only returned as the pump's status. */
static void test_wm_max_refusal_of_an_emit_is_recorded(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }
    g.engine->rete_engine->wm_max_facts = 1;   /* Src fills it */

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, var_ref(0, 0)) };
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) != 0,
          "the pump still reports the refusal as its status ([RTCT.7.2])");

    int be = first_of(&g.t, DS_EV_BOUNDS_ERROR);
    CHECK(be >= 0, "the refused emit records DS_EV_BOUNDS_ERROR");
    CHECK(count_of(&g.t, DS_EV_BOUNDS_ERROR) == 1, "exactly once");
    if (be >= 0)
        CHECK(g.t.detail[be] == DS_CAP_WM_MAX, "the cap is wm_max");
    int rfb = first_of(&g.t, DS_EV_RULE_FIRE_BEGIN);
    CHECK(rfb >= 0 && be > rfb, "recorded inside the firing that tried the emit");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* The cache caps. ds_cache_set owns no engine, so its callers record the
   breach from what the cache leaves in breach_* -- and must not record one
   for a call that was not refused on a cap. */
static void test_cache_cap_breaches_are_recorded(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }
    CHECK(ds_engine_set_stream_callback(g.engine, trace_cb, &g.t).status == DS_OK,
          "stream callback");

    ds_cache_set_caps(&g.engine->cache, 1, 0);
    CHECK(ds_dispatcher_cache_set(g.engine, "k1", "1", 0).status == DS_OK,
          "the first key fits");
    CHECK(count_of(&g.t, DS_EV_BOUNDS_ERROR) == 0, "and records no breach");
    CHECK(ds_dispatcher_cache_set(g.engine, "k2", "2", 0).status
              == DS_ERR_CONTRACT_BREACH, "a second key breaches cache_cap");
    int be = first_of(&g.t, DS_EV_BOUNDS_ERROR);
    CHECK(be >= 0 && g.t.detail[be] == DS_CAP_CACHE,
          "recorded as DS_EV_BOUNDS_ERROR, cap cache");
    CHECK(ds_dispatcher_cache_set(g.engine, "k1", "3", 0).status == DS_OK,
          "overwriting a live key is not a new key");
    CHECK(count_of(&g.t, DS_EV_BOUNDS_ERROR) == 1,
          "and does not re-record the previous call's breach");

    ds_cache_set_caps(&g.engine->cache, 0, 4);
    CHECK(ds_dispatcher_cache_set(g.engine, "k1", "12345", 0).status
              == DS_ERR_CONTRACT_BREACH, "a value past cache_bytes_cap breaches");
    CHECK(count_of(&g.t, DS_EV_BOUNDS_ERROR) == 2, "recorded");
    CHECK(g.t.detail[g.t.n - 1] == DS_CAP_CACHE_BYTES, "cap cache_bytes");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* ---- ONCE ------------------------------------------------------------- */

static void test_lhs_fault_is_recorded_once(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    /* (s.val + "x") > 0 and true — the fault is three layers down, under a
       comparison, a conjunction and the predicate coercion. */
    ds_rete_expr_t *add = binop(DS_RETE_BINOP_ADD,
                                var_ref(DS_RETE_VAR_RIGHT_FACT, 0), lit_str("x"));
    add->json_tainted = true;
    ds_rete_expr_t *gt = binop(DS_RETE_BINOP_GT, add, lit_int(0));
    ds_rete_expr_t *lit_true = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_BOOL);
    lit_true->lit_bool = true;
    ds_rete_join_test_t join[1] = {{
        .expr = binop(DS_RETE_BINOP_AND, gt, lit_true) }};

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, var_ref(0, 0)) };
    CHECK(rig_fire(&g, acts, 1, join, 1, 0, 7) == 0, "pump succeeds");

    CHECK(count_of(&g.t, DS_EV_TYPE_ERROR) == 1,
          "an LHS fault is recorded exactly once");
    CHECK(faults(&g.t) == 1, "and nothing else is recorded with it");
    int te = first_of(&g.t, DS_EV_TYPE_ERROR);
    if (te >= 0) {
        CHECK(g.t.node_id[te] == 2, "node_id is the beta node");
        /* [LERR.9.11]: no activation exists yet, so the fault is named from
           the node that raised it. The name is synthetic
           ([LLEX.10.6.1]), so no rule can share it. */
        CHECK(strcmp(g.t.rule[te], "$beta_2") == 0,
              "a join-test fault is named $beta_<id>");
    }
    CHECK(count_of(&g.t, DS_EV_RULE_FIRE_BEGIN) == 0,
          "the activation never forms");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* ---- AN INDEX THAT NAMES NOTHING ([RDSC.4a.9.1]) ----------------------- */

/* Exactly one EngineError, `fault`, at `node`, naming `rule`, and the engine
   halted on it. */
static void expect_one_engine_error(const rig_t *g, int fault, uint32_t node,
                                    const char *rule, const char *what)
{
    int ee = first_of(&g->t, DS_EV_ENGINE_ERROR);
    char msg[160];
    snprintf(msg, sizeof msg, "%s: one EngineError, and nothing else", what);
    CHECK(ee >= 0 && faults(&g->t) == 1, msg);
    if (ee >= 0) {
        snprintf(msg, sizeof msg, "%s: fault %d", what, fault);
        CHECK(g->t.detail[ee] == fault, msg);
        snprintf(msg, sizeof msg, "%s: node %u", what, (unsigned) node);
        CHECK(g->t.node_id[ee] == node, msg);
        snprintf(msg, sizeof msg, "%s: named %s", what, rule);
        CHECK(strcmp(g->t.rule[ee], rule) == 0, msg);
    }
    bool halted = false;
    snprintf(msg, sizeof msg, "%s: the tier halted", what);
    CHECK(ds_engine_halted(g->engine, &halted, NULL).status == DS_OK && halted,
          msg);
}

/* [RDSC.4a.9.1], [IRET.6.4]: an AlphaTest whose
   slot names no slot of the fact's schema faults ARTEFACT_LIED, naming
   `$alpha_<id>`, and halts the tier. It is one conjunct of the node's tests:
   beside a test that answers false, FIRST and SECOND, the fact is rejected
   and nothing is raised; beside one that answers true, either side, it
   faults. Src has one slot, `val` = 7, so slot 1 names nothing. PATH:
   `ds_rete_alpha_test_fact`, from the assert's alpha dispatch. The Mercury
   runtime is held to the same cases (test_ds.m,
   test_rdsc_4a_9_1_index_faults). */
/* @spec [RDSC.4a.9.1] */
static void test_rdsc_4a_9_1__alpha_slot_past_the_schema(void)
{
    const ds_retp_alpha_test_t t_bad = {    /* slot 1 > 42: names no slot */
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 1, .op = DS_RETE_CMP_GT,
        .literal = ds_rete_val_int(42) };
    const ds_retp_alpha_test_t t_false = {  /* val > 42: false */
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 0, .op = DS_RETE_CMP_GT,
        .literal = ds_rete_val_int(42) };
    const ds_retp_alpha_test_t t_true = {   /* val < 42: true */
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 0, .op = DS_RETE_CMP_LT,
        .literal = ds_rete_val_int(42) };
    struct {
        const char          *label;
        ds_retp_alpha_test_t tests[2];
        uint32_t             n;
        bool                 faults;
    } cases[] = {
        { "alone",                                   { t_bad },          1, true  },
        { "first, before a test that answers false", { t_bad, t_false }, 2, false },
        { "second, after a test that answers false", { t_false, t_bad }, 2, false },
        { "first, before a test that answers true",  { t_bad, t_true },  2, true  },
        { "second, after a test that answers true",  { t_true, t_bad },  2, true  },
    };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        rig_t g;
        char what[128];
        snprintf(what, sizeof what,
                 "[RDSC.4a.9.1] an AlphaTest slot past the schema, %s",
                 cases[c].label);
        if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto next; }
        g_alpha_tests = cases[c].tests;
        g_alpha_test_count = cases[c].n;
        ds_rete_slot_assign_t as;
        ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, var_ref(0, 0)) };
        CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, what);
        g_alpha_tests = NULL;
        g_alpha_test_count = 0;
        if (cases[c].faults) {
            expect_one_engine_error(&g, DS_ENGINE_FAULT_ARTEFACT_LIED, 1,
                                    "$alpha_1", what);
        } else {
            bool halted = true;
            CHECK(faults(&g.t) == 0, what);
            CHECK(ds_engine_halted(g.engine, &halted, NULL).status == DS_OK
                  && !halted, what);
        }
        CHECK(count_of(&g.t, DS_EV_RULE_FIRE_BEGIN) == 0, what);
    next:
        if (g.engine) ds_engine_free(g.engine);
    }
}

/* [RDSC.4a.6.2]: a REGEX AlphaTest whose subject is not a String faults
   ARTEFACT_LIED, naming `$alpha_<id>`, and halts the tier, held as the slot
   index past the schema is: beside a test that answers false,
   FIRST and SECOND, the fact is rejected and nothing is raised; beside one
   that answers true, either side, it faults. Src's one slot is the Int `val`
   = 7, and the pattern "7" would match its text, so a REGEX arm that read the
   number as a string would admit it. PATH: `ds_rete_alpha_test_fact`'s REGEX
   arm, from the assert's alpha dispatch. The Mercury runtime is held to the
   same cases (test_ds.m, test_rdsc_4a_6_2_regex_subject_faults). */
/* @spec [RDSC.4a.6.2] */
static void test_rdsc_4a_6_2__regex_on_an_int_slot(void)
{
    const ds_retp_alpha_test_t t_bad = {    /* val ~ /7/: val is an Int */
        .kind = DS_RETE_ALPHA_REGEX, .slot_index = 0, .pattern = "7" };
    const ds_retp_alpha_test_t t_false = {  /* val > 42: false */
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 0, .op = DS_RETE_CMP_GT,
        .literal = ds_rete_val_int(42) };
    const ds_retp_alpha_test_t t_true = {   /* val < 42: true */
        .kind = DS_RETE_ALPHA_CMP, .slot_index = 0, .op = DS_RETE_CMP_LT,
        .literal = ds_rete_val_int(42) };
    struct {
        const char          *label;
        ds_retp_alpha_test_t tests[2];
        uint32_t             n;
        bool                 faults;
    } cases[] = {
        { "alone",                                   { t_bad },          1, true  },
        { "first, before a test that answers false", { t_bad, t_false }, 2, false },
        { "second, after a test that answers false", { t_false, t_bad }, 2, false },
        { "first, before a test that answers true",  { t_bad, t_true },  2, true  },
        { "second, after a test that answers true",  { t_true, t_bad },  2, true  },
    };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        rig_t g;
        char what[128];
        snprintf(what, sizeof what,
                 "[RDSC.4a.6.2] a REGEX AlphaTest on an Int slot, %s",
                 cases[c].label);
        if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto next; }
        g_alpha_tests = cases[c].tests;
        g_alpha_test_count = cases[c].n;
        ds_rete_slot_assign_t as;
        ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, lit_int(1)) };
        CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, what);
        g_alpha_tests = NULL;
        g_alpha_test_count = 0;
        if (cases[c].faults) {
            expect_one_engine_error(&g, DS_ENGINE_FAULT_ARTEFACT_LIED, 1,
                                    "$alpha_1", what);
        } else {
            bool halted = true;
            CHECK(faults(&g.t) == 0, what);
            CHECK(ds_engine_halted(g.engine, &halted, NULL).status == DS_OK
                  && !halted, what);
        }
        CHECK(count_of(&g.t, DS_EV_RULE_FIRE_BEGIN) == 0, what);
    next:
        if (g.engine) ds_engine_free(g.engine);
    }
}

/* [RDSC.4a.6.2], [LREG.1.1]: Bytes is not a String. A REGEX AlphaTest on a
   Bytes slot whose octets the pattern would match faults ARTEFACT_LIED. And
   the control, so the fault is not what every REGEX test does: the same
   network over a String slot holding the same text matches, and the rule fires. Src's one slot is
   declared Bytes, then String, for these two alone. */
/* @spec [RDSC.4a.6.2] */
static void test_rdsc_4a_6_2__regex_on_a_bytes_slot(void)
{
    static const uint8_t octets[] = { 'a', 'a', 'b' };
    const ds_slot_value_t as_bytes = { .kind = DS_SLOT_BYTES,
        .v.bytes = { .data = octets, .len = sizeof octets } };
    const ds_slot_value_t as_string = { .kind = DS_SLOT_STRING, .v.s = "aab" };
    ds_retp_alpha_test_t t = {               /* val ~ /a+b/ */
        .kind = DS_RETE_ALPHA_REGEX, .slot_index = 0, .pattern = "a+b" };
    struct {
        const char            *label;
        ds_slot_type_t         type;
        const ds_slot_value_t *value;
        bool                   faults;
    } cases[] = {
        { "on a Bytes slot",             DS_SLOT_TYPE_BYTES,  &as_bytes,  true  },
        { "control: on a String slot",   DS_SLOT_TYPE_STRING, &as_string, false },
    };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        rig_t g;
        char what[128];
        snprintf(what, sizeof what, "[RDSC.4a.6.2] a REGEX AlphaTest %s",
                 cases[c].label);
        g_src_type = cases[c].type;
        g_src_value = cases[c].value;
        if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto next; }
        g_alpha_tests = &t;
        g_alpha_test_count = 1;
        ds_rete_slot_assign_t as;
        ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, lit_int(1)) };
        CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 0) == 0, what);
        g_alpha_tests = NULL;
        g_alpha_test_count = 0;
        if (cases[c].faults) {
            expect_one_engine_error(&g, DS_ENGINE_FAULT_ARTEFACT_LIED, 1,
                                    "$alpha_1", what);
            CHECK(count_of(&g.t, DS_EV_RULE_FIRE_BEGIN) == 0, what);
        } else {
            CHECK(faults(&g.t) == 0, what);
            CHECK(count_of(&g.t, DS_EV_RULE_FIRE_BEGIN) == 1, what);
        }
    next:
        g_src_type = DS_SLOT_TYPE_INT;
        g_src_value = NULL;
        if (g.engine) ds_engine_free(g.engine);
    }
}

/* ---- A RULE'S EMIT ADMITS ONLY THE DECLARED KIND ([RARC.5.2.6]) -------- */

static ds_result_t count_fact(const ds_fact_t *f, void *user)
{
    (void) f;
    (*(int *) user)++;
    return DS_OK_R;
}

/* `r`, on Src, emits Mid with its one slot, declared `mid_type`, assigned
   `value`. When `refused`, the emit is RARC.5.2.7's TypeError: one, naming
   Mid's slot `val`, the value's kind `actual` and the rule `r`; the
   activation is abandoned with nothing emitted, no Mid fact enters, and the
   pump goes on. Otherwise Mid enters and nothing is raised. Node ids: alpha 1
   (Src), beta 2, terminal 3. */
static void emit_into_mid(const char *what, ds_slot_type_t mid_type,
                          ds_rete_expr_t *value, bool refused,
                          const char *actual)
{
    rig_t g;
    const ds_schema_t      *mid_ds = NULL;
    const ds_rete_schema_t *mid_rs = NULL;
    if (rig_open(&g)
        || reg_schema_typed(g.engine, "Mid", false, mid_type, &mid_ds,
                            &mid_rs)) {
        fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done;
    }
    ds_rete_slot_assign_t as = { .slot_index = 0, .expr = value };
    ds_rete_action_t acts[1] = {{ .kind = DS_RETE_ACTION_ASSERT,
                                  .schema_id = mid_rs->id,
                                  .assigns = &as, .assign_count = 1 }};
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, what);
    int mids = 0;
    CHECK(ds_engine_for_each_fact(g.engine, mid_ds, count_fact, &mids).status
          == DS_OK, what);
    if (refused) {
        CHECK(count_of(&g.t, DS_EV_TYPE_ERROR) == 1, what);
        CHECK(faults(&g.t) == 1, what);
        int te = first_of(&g.t, DS_EV_TYPE_ERROR);
        if (te >= 0) {
            CHECK(strcmp(g.t.schema[te], "Mid") == 0, what);
            CHECK(strcmp(g.t.slot[te], "val") == 0, what);
            CHECK(strcmp(g.t.actual[te], actual) == 0, what);
            CHECK(strcmp(g.t.rule[te], "r") == 0, what);
        }
        /* A fault fact is emitted too ([LERR.9.1]), so only Mid's count. */
        int mid_emits = 0;
        for (int i = 0; i < g.t.n; i++)
            if (g.t.kind[i] == DS_EV_ACTION_EMIT
                && strcmp(g.t.emit_schema[i], "Mid") == 0)
                mid_emits++;
        CHECK(mid_emits == 0, what);
        CHECK(mids == 0, what);
        CHECK(g.engine->halted == false, what);
    } else {
        CHECK(faults(&g.t) == 0, what);
        CHECK(mids == 1, what);
    }
done:
    if (g.engine) ds_engine_free(g.engine);
}

/* [RARC.5.2.6]: "There is no implicit conversion", on a rule's emit as at the
   host's door, which refuses a String for a Bytes slot (wm.c). A hand-built
   rule assigns the String literal "aab" to a Bytes slot: a TypeError
   ([RARC.5.2.7]), as the Mercury runtime raises it (`ds.fact.admits_kind`).
   Control: the same literal into a
   String slot enters. PATH: `eval_actions`' `ds_rete_slot_refused`, through
   `rete_slot_kind_admissible`'s BYTES arm. */
/* @spec [RARC.5.2.6] */
static void test_rarc_5_2_6__emit_of_a_string_into_a_bytes_slot(void)
{
    emit_into_mid("[RARC.5.2.6] a String emitted into a Bytes slot is a "
                  "TypeError", DS_SLOT_TYPE_BYTES, lit_str("aab"), true,
                  "String");
    emit_into_mid("[RARC.5.2.6] control: a String into a String slot enters",
                  DS_SLOT_TYPE_STRING, lit_str("aab"), false, NULL);
}

/* [RARC.5.2.6]: the same for an Int literal into a Float slot, which the
   host's door refuses too (wm_validate_assert_values). Control: a Float
   literal into the Float slot enters. PATH: `eval_actions`' `ds_rete_slot_refused`, through
   `rete_slot_kind_admissible`'s FLOAT arm. */
/* @spec [RARC.5.2.6] */
static void test_rarc_5_2_6__emit_of_an_int_into_a_float_slot(void)
{
    emit_into_mid("[RARC.5.2.6] an Int emitted into a Float slot is a "
                  "TypeError", DS_SLOT_TYPE_FLOAT, lit_int(3), true, "Int");
    emit_into_mid("[RARC.5.2.6] control: a Float into a Float slot enters",
                  DS_SLOT_TYPE_FLOAT, lit_float(3.0), false, NULL);
}

/* [RDSC.4a.9.1]: a VarExpr join test reading the candidate's slot 1, past
   Src's one: ARTEFACT_LIED, naming `$beta_2`. PATH: `ds_rete_eval`'s VAR arm,
   from the assert's right activation. */
/* @spec [RDSC.4a.9.1] */
static void test_rdsc_4a_9_1__var_slot_past_the_schema(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }
    ds_rete_join_test_t join[1] = {{
        .expr = binop(DS_RETE_BINOP_EQ, var_ref(DS_RETE_VAR_RIGHT_FACT, 1),
                      lit_int(1)) }};
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, var_ref(0, 0)) };
    CHECK(rig_fire(&g, acts, 1, join, 1, 0, 7) == 0, "the rig runs");
    expect_one_engine_error(&g, DS_ENGINE_FAULT_ARTEFACT_LIED, 2, "$beta_2",
                            "[RDSC.4a.9.1] a VarExpr slot past the schema");
done:
    if (g.engine) ds_engine_free(g.engine);
}

/* [RDSC.4a.9.1]: a SlotAssign to Out0's slot 1, past its one: ARTEFACT_LIED,
   naming the rule, and nothing is emitted. PATH:
   `eval_actions`' assign loop. */
/* @spec [RDSC.4a.9.1] */
static void test_rdsc_4a_9_1__slot_assign_past_the_schema(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[1] = { assert_out(&g, 0, &as, lit_int(1)) };
    as.slot_index = 1;
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, "the rig runs");
    expect_one_engine_error(&g, DS_ENGINE_FAULT_ARTEFACT_LIED, 3, "r",
                            "[RDSC.4a.9.1] a SlotAssign past the schema");
    CHECK(count_of(&g.t, DS_EV_ACTION_EMIT) == 0, "nothing is emitted");
done:
    if (g.engine) ds_engine_free(g.engine);
}

/* [RDSC.4a.9.1], [RARC.5.3.3]: a withdraw of token position 1, past the
   one-fact token: PATTERN_INDEX, naming the rule. PATH:
   `eval_actions`' WITHDRAW arm. */
/* @spec [RDSC.4a.9.1] */
static void test_rdsc_4a_9_1__withdraw_past_the_token(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }
    ds_rete_action_t acts[1] = {{ .kind = DS_RETE_ACTION_WITHDRAW,
                                  .withdraw_pattern_index = 1 }};
    CHECK(rig_fire(&g, acts, 1, NULL, 0, 0, 7) == 0, "the rig runs");
    expect_one_engine_error(&g, DS_ENGINE_FAULT_PATTERN_INDEX, 3, "r",
                            "[RDSC.4a.9.1] a withdraw past the token");
done:
    if (g.engine) ds_engine_free(g.engine);
}

/* The abort path the halt guard only PARTLY covers: a perfectly healthy engine
 * that has simply pumped once. The structural intern set freezes at that
 * transition (ds_engine_pump, at !has_pumped), so a later registration pins a
 * new type name into a frozen table and trips IRET.1.4 Q5's assertion —
 * killing the host process instead of answering ds_result_t, and under
 * -DNDEBUG corrupting the frozen set silently instead.
 *
 * Nothing about that needs a fault, which is why the halted case above is not
 * enough on its own: reaching it requires an EngineError first, and this path
 * needs only an ordinary pump.
 *
 * ⚠ THIS TEST CANNOT FAIL SAFELY. Without the guard it does not report a
 * failure — the process dies here and every later test goes unrun, so a
 * regression shows up as a truncated suite rather than a FAIL line. That is
 * the shape the guard exists to remove, and it is why the check is a status
 * comparison rather than a death-test: a passing run proves a status came
 * back at all. */
static void test_register_schema_after_the_first_pump(void)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; goto done; }

    /* An ordinary pump on an engine with no rules and no faults. It is the
       pump, not the work it does, that arms the freeze. */
    CHECK(ds_engine_pump(g.engine).status == DS_OK, "a plain pump succeeds");
    CHECK(g.engine->halted == false, "and the engine is NOT halted");

    ds_result_t r = ds_engine_register_schema(g.engine, "Late",
                                              DS_SCHEMA_LIFECYCLE_LOGICAL,
                                              0, NULL, 0, NULL);
    CHECK(r.status == DS_ERR_STATE,
          "register_schema after the first pump answers DS_ERR_STATE");

    /* The refusal leaves the engine usable — it is a rejected operation, not a
       fault ([LERR.1]), so nothing latched and the pump still runs. */
    CHECK(g.engine->halted == false, "the refusal did not halt the engine");
    CHECK(ds_engine_pump(g.engine).status == DS_OK,
          "and the engine still pumps afterwards");

done:
    if (g.engine) ds_engine_free(g.engine);
}

/* ---- A REPLAY COMPARES THE FAULTS ([RFCS.3.1], [RFCS.6.7]) ------------- */

/* A vector cannot express an edited recording: its `tamper` edits the artefact
   both engines load. Each case runs one
   rig recording, and replays it, or an edit of it, into a second rig with the
   same network. THE PATH: verify_capture_sink puts the re-derived fault on the
   queue, and replay_apply_atom's fault arm matches the recorded one with
   verify_match; ds_rfcs_replay_finish refuses one left over. */
enum { FR_CLEAN, FR_COMPUTATION, FR_TYPE, FR_ENGINE };

static uint8_t g_fr[8192];
static size_t  g_fr_len;

static ds_result_t fr_sink(const uint8_t *bytes, size_t len, void *user)
{
    (void)user;
    if (g_fr_len + len > sizeof g_fr)
        return (ds_result_t){ DS_ERR_INVAL, "recording overflow" };
    memcpy(g_fr + g_fr_len, bytes, len);
    g_fr_len += len;
    return DS_OK_R;
}

static ds_result_t fr_on_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    return ds_rfcs_recorder_on_event(e, ev, (ds_rfcs_recorder_t *)u);
}

/* The one action of `which`'s rule. */
static ds_rete_action_t fr_action(const rig_t *g, int which,
                                  ds_rete_slot_assign_t *as)
{
    ds_rete_expr_t *value = var_ref(0, 0);
    if (which == FR_COMPUTATION)
        value = binop(DS_RETE_BINOP_IDIV, var_ref(0, 0), lit_int(0));
    if (which == FR_TYPE || which == FR_ENGINE) {
        value = binop(DS_RETE_BINOP_ADD, var_ref(0, 0), lit_str("x"));
        value->json_tainted = which == FR_TYPE;
    }
    return assert_out(g, 0, as, value);
}

/* Record `which`'s run into g_fr. */
static void fr_record(int which)
{
    static ds_rfcs_recorder_t rec;
    static uint8_t            buf[4096];
    static ds_rete_slot_assign_t as;
    static ds_rete_action_t      act;
    rig_t g;
    g_fr_len = 0;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; return; }
    act = fr_action(&g, which, &as);
    CHECK(ds_rfcs_record_begin(g.engine, &rec, fr_sink, NULL, buf, sizeof buf)
              .status == DS_OK, "record_begin");
    CHECK(rig_fire_cb(&g, &act, 1, NULL, 0, 0, 7, fr_on_event, &rec) == 0,
          "the run records");
    CHECK(rec.last.status == DS_OK, "the recorder took every event");
    ds_engine_free(g.engine);
}

/* The status of replaying `len` bytes into a fresh rig running `which`'s rule. */
static ds_status_t fr_replay(int which, const uint8_t *bytes, size_t len)
{
    static uint8_t strbuf[8192];
    static ds_rete_slot_assign_t as;
    static ds_rete_action_t      act;
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; return DS_ERR_INVAL; }
    act = fr_action(&g, which, &as);
    ds_status_t s = DS_ERR_INVAL;
    if (rig_load(&g, &act, 1, NULL, 0, 0) == 0) {
        ds_rfcs_replay_result_t res;
        memset(&res, 0, sizeof res);
        s = ds_rfcs_replay(g.engine, bytes, len, strbuf, sizeof strbuf, &res).status;
    }
    ds_engine_free(g.engine);
    return s;
}

/* g_fr with `atom`'s `field` varint, one byte, one higher, into `out`. False if
   the recording holds no such field to edit. */
static bool fr_altered(uint32_t atom, uint32_t field, uint8_t *out)
{
    ds_rfcs_reader_t rd;
    uint32_t         a = 0;
    const uint8_t   *body = NULL;
    size_t           blen = 0;
    bool             done = false;
    memcpy(out, g_fr, g_fr_len);
    ds_rfcs_reader_init(&rd, out, g_fr_len);
    while (ds_rfcs_next(&rd, &a, &body, &blen, &done).status == DS_OK && !done) {
        if (a != atom) continue;
        size_t pos = 0;
        ds_pbf_field_t f;
        while (ds_pbf_next_field(body, blen, pos, &f) == DS_PBF_OK) {
            if (f.field == field && f.wire == 0 && f.u64 < 127u && f.next == pos + 2u) {
                out[(size_t)(body - out) + pos + 1u]++;
                return true;
            }
            pos = f.next;
        }
    }
    return false;
}

/* g_fr without `atom`, into `out`; its length, 0 if the recording holds none. */
static size_t fr_dropped(uint32_t atom, uint8_t *out)
{
    ds_rfcs_reader_t rd;
    uint32_t         a = 0;
    const uint8_t   *body = NULL;
    size_t           blen = 0;
    bool             done = false;
    bool             dropped = false;
    size_t           n = 0;
    ds_rfcs_reader_init(&rd, g_fr, g_fr_len);
    for (;;) {
        const size_t start = rd.pos;
        if (ds_rfcs_next(&rd, &a, &body, &blen, &done).status != DS_OK || done)
            break;
        if (a == atom) { dropped = true; continue; }
        memcpy(out + n, g_fr + start, rd.pos - start);
        n += rd.pos - start;
    }
    return dropped ? n : 0;
}

/* One fault atom: its recording replays clean, an edit of its `node_id` diverges,
   and the recording without it diverges, the replay's re-derived one left over. */
static void fr_compared(int which, uint32_t atom, uint32_t node_field)
{
    static uint8_t edited[sizeof g_fr];
    fr_record(which);
    CHECK(fr_replay(which, g_fr, g_fr_len) == DS_OK,
          "the recording as written replays with DS_OK");
    CHECK(fr_altered(atom, node_field, edited), "the recording holds the fault");
    CHECK(fr_replay(which, edited, g_fr_len) == DS_ERR_FS_DIVERGENCE,
          "a recorded fault that is not the one re-derived is a divergence");
    size_t n = fr_dropped(atom, edited);
    CHECK(n > 0, "and it can be taken out");
    CHECK(fr_replay(which, edited, n) == DS_ERR_FS_DIVERGENCE,
          "a fault the replay re-derives and the recording lacks is a divergence");
}

/* @spec [RFCS.6.7] [RFCS.3.1] */
static void test_rfcs_6_7__a_replay_re_derives_another_engine_error(void)
{
    fr_compared(FR_ENGINE, DS_ATOM_ENGINE_ERROR, 2);
}

/* @spec [LFST.9.3.1] [RFCS.3.1] */
static void test_lfst_9_3_1__a_fault_atom_is_compared(void)
{
    fr_compared(FR_TYPE, DS_ATOM_TYPE_ERROR, 1);
    fr_compared(FR_COMPUTATION, DS_ATOM_COMPUTATION_ERROR, 7);
}

/* @spec [RFCS.6.7]
   The recording of a run that raised nothing, with an EngineError appended: the
   replay raises none. fr_compared's dropped atom is the reverse. */
static void test_rfcs_6_7__a_recorded_engine_error_the_replay_does_not_raise(void)
{
    uint8_t atom[64];
    size_t  n = 0;
    fr_record(FR_CLEAN);
    CHECK(fr_replay(FR_CLEAN, g_fr, g_fr_len) == DS_OK,
          "the clean run replays with DS_OK");
    CHECK(ds_rfcs_encode_engf(999u, 0u, (uint32_t)DS_ENGINE_FAULT_ARTEFACT_LIED, 3u,
                              "r", atom, sizeof atom, &n).status == DS_OK
              && g_fr_len + n <= sizeof g_fr,
          "an EngineError atom");
    memcpy(g_fr + g_fr_len, atom, n);
    CHECK(fr_replay(FR_CLEAN, g_fr, g_fr_len + n) == DS_ERR_FS_DIVERGENCE,
          "a recorded EngineError the replay does not raise is a divergence");
}

int main(void)
{
    printf("=== test_fault_emission ===\n");
    test_rfcs_6_7__a_replay_re_derives_another_engine_error();
    test_lfst_9_3_1__a_fault_atom_is_compared();
    test_rfcs_6_7__a_recorded_engine_error_the_replay_does_not_raise();
    test_computation_error_abandons_the_activation();
    test_lerr_9_1_a_trap_is_asserted_as_a_fault_fact();
    test_lerr_9_5_an_identical_fault_is_latched();
    test_lerr_9_10_a_fault_fact_takes_no_wm_slot();
    test_computation_error_names_its_slot();
    test_join_fault_names_the_fact_being_asserted();
    test_call_action_fault_is_not_discarded();
    test_float_to_int_is_not_representable();
    test_type_mismatch_splits_on_provenance();
    test_ncbk_2_9__mutating_calls_refused_after_halt();
    test_ncbk_2_9__reads_refused_after_halt();
    test_ncbk_2_9__read_inside_the_fault_callback_is_reentry();
    test_ncbk_2_11__the_latch_is_readable();
    test_register_schema_after_the_first_pump();
    test_read_before_bind_is_binding_order();
    test_rarc_5_3_3__a_position_never_bound_is_pattern_index();
    test_long_concatenation_is_not_a_fault();
    test_an_allocation_failure_is_engine_fault_allocation();
    test_a_refused_refraction_mark_is_engine_fault_allocation();
    test_a_refused_token_copy_is_engine_fault_allocation();
    test_lhs_fault_is_recorded_once();
    test_rdsc_4a_9_1__alpha_slot_past_the_schema();
    /* A REGEX AlphaTest needs a build that links RE2. The MSan lane builds
       `-D re2=stub`, where no pattern compiles by design, so these two can
       only fail there. They are skipped on that build, out loud, and run on
       every other, as test_rete_builtins.c's regex cases are. */
    if (ds_re2_available()) {
        test_rdsc_4a_6_2__regex_on_an_int_slot();
        test_rdsc_4a_6_2__regex_on_a_bytes_slot();
    } else {
        printf("  skip: test_rdsc_4a_6_2__regex_* (this build links no RE2)\n");
    }
    test_rarc_5_2_6__emit_of_a_string_into_a_bytes_slot();
    test_rarc_5_2_6__emit_of_an_int_into_a_float_slot();
    test_rdsc_4a_9_1__var_slot_past_the_schema();
    test_rdsc_4a_9_1__slot_assign_past_the_schema();
    test_rdsc_4a_9_1__withdraw_past_the_token();
    test_wm_max_refusal_of_an_emit_is_recorded();
    test_cache_cap_breaches_are_recorded();
    if (g_fails) {
        fprintf(stderr, "test_fault_emission: %d FAILURE(S)\n", g_fails);
        return 1;
    }
    printf("=== test_fault_emission: ALL PASSED ===\n");
    return 0;
}

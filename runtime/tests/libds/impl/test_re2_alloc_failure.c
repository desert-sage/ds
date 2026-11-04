/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * An allocation that fails inside RE2 is a fault, never an abort and never
 * "no match" (IALC.3.6, IERR.8.7). RE2 and Abseil allocate through C++'s
 * global operator new (IALC.3.5); ds_re2.cc catches std::bad_alloc in every
 * exported function, and the callers raise DS_FAULT_RESOURCE, as for a failed
 * DS_MALLOC: the EngineError ALLOCATION, which halts the tier (LERR.1.4.7).
 *
 * This program defines its own global operator new, which a test binary may
 * and libds may not (IALC.3.5). It is written in C, under the Itanium
 * mangled names, because the impl suite is C; while `g_fail_new` is set it
 * fails by calling libstdc++'s own `std::__throw_bad_alloc()`, so what RE2
 * sees is exactly a failed allocation. Two things follow:
 *   - the frames between the throw and ds_re2.cc's catch include this file's,
 *     so it is built with -fexceptions (the `wrap` column of its ImplTest row);
 *   - the delete operators are defined here too, so every allocation is a
 *     malloc / free pair and a sanitizer sees no mismatched deallocation.
 * The names assume LP64 (`m` is `unsigned long`), which every row this suite
 * runs on is. Not under valgrind: it replaces operator new itself, so the
 * failure could never be injected there.
 *
 * Four sites, each with a control that runs the same network unarmed:
 *   1. the alpha REGEX test, at assert ([RLOW.5.2.2], rete/alpha.c);
 *   2. DS_FN_REGEX_MATCH in a firing (builtins.c, through the load-time cache);
 *   3. DS_FN_REGEX_CAPTURE in a firing (the submatch array, and RE2's state);
 *   4. the load: a pattern whose compile runs out of memory is refused with
 *      DS_ERR_OOM, at the alpha REGEX test and at the builtins' precompile,
 *      and an invalid one with its own code; nothing aborts.
 * Each armed run also checks that a failure was injected (`g_failed`).
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "builtins.h"
#include "engine.h"
#include "rete/action.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/val.h"

/* libstdc++'s `std::__throw_bad_alloc()`: throws a std::bad_alloc, as its own
   operator new does when malloc fails. */
extern void _ZSt17__throw_bad_allocv(void) __attribute__((noreturn));

static volatile int g_fail_new;   /* while set, every operator new fails */
static int          g_failed;     /* how many it failed */

static void *new_or_throw(size_t n)
{
    if (g_fail_new) {
        g_failed++;
        _ZSt17__throw_bad_allocv();
    }
    void *p = malloc(n != 0 ? n : 1);
    if (p == NULL) _ZSt17__throw_bad_allocv();
    return p;
}

void *_Znwm(size_t n);                       /* operator new(size_t)          */
void *_Znam(size_t n);                       /* operator new[](size_t)        */
void  _ZdlPv(void *p);                       /* operator delete(void *)       */
void  _ZdaPv(void *p);                       /* operator delete[](void *)     */
void  _ZdlPvm(void *p, size_t n);            /* sized operator delete         */
void  _ZdaPvm(void *p, size_t n);            /* sized operator delete[]       */

void *_Znwm(size_t n)            { return new_or_throw(n); }
void *_Znam(size_t n)            { return new_or_throw(n); }
void  _ZdlPv(void *p)            { free(p); }
void  _ZdaPv(void *p)            { free(p); }
void  _ZdlPvm(void *p, size_t n) { (void) n; free(p); }
void  _ZdaPvm(void *p, size_t n) { (void) n; free(p); }

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

typedef struct {
    int emits;
    int engine_errors;
    int allocation;     /* of those, ENGINE_FAULT_ALLOCATION */
    int other_faults;   /* TypeError, ComputationError, BoundsError */
    int arm_at_fire;    /* set g_fail_new when a firing begins */
} trace_t;

static ds_result_t trace_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    trace_t *t = (trace_t *) user;
    switch (ev->kind) {
    case DS_EV_RULE_FIRE_BEGIN:
        if (t->arm_at_fire) g_fail_new = 1;
        break;
    case DS_EV_ACTION_EMIT:
        t->emits++;
        break;
    case DS_EV_ENGINE_ERROR:
        t->engine_errors++;
        if (ev->p.engine_error.fault == DS_ENGINE_FAULT_ALLOCATION)
            t->allocation++;
        break;
    case DS_EV_TYPE_ERROR:
    case DS_EV_COMPUTATION_ERROR:
    case DS_EV_BOUNDS_ERROR:
        t->other_faults++;
        break;
    default:
        break;
    }
    return DS_OK_R;
}

/* A one-rule engine: Src(msg: String) -> actions. */
typedef struct {
    ds_engine_t            *engine;
    const ds_schema_t      *src;
    const ds_rete_schema_t *out_rs;
    trace_t                 t;
} rig_t;

static int rig_open(rig_t *g)
{
    memset(g, 0, sizeof(*g));
    ds_engine_config_t cfg = {0};
    if (ds_engine_new(&cfg, &g->engine).status != DS_OK || !g->engine)
        return 1;
    ds_slot_desc_t msg = { .name = "msg", .type = DS_SLOT_TYPE_STRING,
                           .identity_role = DS_IDENTITY_MUTABLE };
    if (ds_engine_register_schema(g->engine, "Src", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  0, &msg, 1, &g->src).status != DS_OK)
        return 1;
    const ds_schema_t *ignored = NULL;
    ds_slot_desc_t val = { .name = "val", .type = DS_SLOT_TYPE_INT,
                           .identity_role = DS_IDENTITY_KEY };
    if (ds_engine_register_schema(g->engine, "Out", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                  0, &val, 1, &ignored).status != DS_OK)
        return 1;
    g->out_rs = ds_rete_schema_by_name(g->engine->rete_engine, "Out");
    return g->out_rs == NULL;
}

static void rig_close(rig_t *g)
{
    g_fail_new = 0;
    if (g->engine) ds_engine_free(g->engine);
    g->engine = NULL;
}

/* Load `Src s [alpha tests] -> actions`, precompile the regex cache as a
   loaded artefact would, and attach the trace. Node ids: alpha 1, beta 2,
   terminal 3. */
static ds_result_t rig_load(rig_t *g, ds_retp_alpha_test_t *tests,
                            uint32_t n_tests, ds_rete_action_t *actions,
                            uint32_t n_actions)
{
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src",
                                 .tests = tests, .test_count = n_tests }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1,
                                 .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "r",
                                 .actions = actions,
                                 .action_count = n_actions }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    ds_result_t r = ds_rete_load_network(g->engine->rete_engine, &net);
    if (r.status != DS_OK) return r;
    /* What dsc/loader.c does for an artefact: the builtins then look their
       pattern up rather than compiling it, so the armed firing reaches the
       MATCH, not a per-call compile. */
    r = ds_rete_regex_precompile(g->engine->rete_engine);
    if (r.status != DS_OK) return r;
    return ds_engine_set_stream_callback(g->engine, trace_cb, &g->t);
}

static ds_result_t assert_src(rig_t *g, const char *msg)
{
    ds_slot_value_t sv = { .kind = DS_SLOT_STRING, .v.s = msg };
    return ds_engine_assert(g->engine, g->src, &sv, 1, NULL);
}

static bool halted_on_allocation(const rig_t *g)
{
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    return ds_engine_halted(g->engine, &halted, &fault).status == DS_OK
        && halted && fault == DS_ENGINE_FAULT_ALLOCATION;
}

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
static ds_rete_expr_t *lit_str(const char *s)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    e->lit_str = s; return e;
}
static ds_rete_expr_t *call(uint32_t op, ds_rete_expr_t **args, uint32_t n)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    e->call.op = op;
    e->call.args = calloc(n, sizeof(*e->call.args));
    for (uint32_t i = 0; i < n; i++) e->call.args[i] = args[i];
    e->call.arg_count = n;
    return e;
}

/* actions[0] evaluates `regex`; actions[1] asserts Out(1), so it runs only if
   the activation survived actions[0]. */
static void two_actions(const rig_t *g, ds_rete_expr_t *regex,
                        ds_rete_slot_assign_t *as, ds_rete_action_t acts[2])
{
    acts[0] = (ds_rete_action_t) { .kind = DS_RETE_ACTION_CALL, .expr = regex };
    as->slot_index = 0;
    as->expr = lit_int(1);
    acts[1] = (ds_rete_action_t) { .kind = DS_RETE_ACTION_ASSERT,
                                   .schema_id = g->out_rs->id,
                                   .assigns = as, .assign_count = 1 };
}

static ds_rete_expr_t *match_expr(void)
{
    ds_rete_expr_t *a[3] = { var_ref(0, 0), lit_str("a+b"), lit_str("") };
    return call((uint32_t) DS_FN_REGEX_MATCH, a, 3);
}

static ds_rete_expr_t *capture_expr(void)
{
    ds_rete_expr_t *a[4] = { var_ref(0, 0), lit_str("x(a+)b"), lit_str(""),
                             lit_int(1) };
    return call((uint32_t) DS_FN_REGEX_CAPTURE, a, 4);
}

static void run_alpha(bool armed)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; return; }

    ds_retp_alpha_test_t t = { .kind = DS_RETE_ALPHA_REGEX, .slot_index = 0,
                               .pattern = "a+b" };
    ds_rete_slot_assign_t as = { .slot_index = 0, .expr = lit_int(1) };
    ds_rete_action_t act = { .kind = DS_RETE_ACTION_ASSERT,
                             .schema_id = g.out_rs->id,
                             .assigns = &as, .assign_count = 1 };
    CHECK(rig_load(&g, &t, 1, &act, 1).status == DS_OK, "the network loads");

    /* Armed across the assert AND the pump, so the check does not depend on
       which of the two propagates the fact to the alpha node. No other
       operator new runs in either: libds is C, and its one C++ unit is the
       shim under test. */
    g_failed = 0;
    g_fail_new = armed;
    (void) assert_src(&g, "xaab");
    (void) ds_engine_pump(g.engine);
    g_fail_new = 0;

    if (armed) {
        CHECK(g_failed > 0, "an allocation inside RE2 was failed");
        CHECK(g.t.allocation == 1,
              "the failed match is the EngineError ALLOCATION, once");
        CHECK(g.t.engine_errors == 1 && g.t.other_faults == 0,
              "and no other fault");
        CHECK(halted_on_allocation(&g), "the engine is halted on it");
        CHECK(g.t.emits == 0, "the rule does not fire");
    } else {
        CHECK(g.t.engine_errors == 0 && g.t.other_faults == 0,
              "control: no fault");
        CHECK(g.t.emits == 1, "control: the pattern matches and the rule fires");
    }
    rig_close(&g);
}

/* @spec [IALC.3.6] */
static void test_alpha_match_out_of_memory(void) { run_alpha(true);  }
static void test_alpha_match_control(void)       { run_alpha(false); }

static void run_builtin(ds_rete_expr_t *(*make)(void), const char *subject,
                        bool armed)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; return; }

    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[2];
    two_actions(&g, make(), &as, acts);
    CHECK(rig_load(&g, NULL, 0, acts, 2).status == DS_OK, "the network loads");
    CHECK(assert_src(&g, subject).status == DS_OK, "the assert succeeds");

    g_failed = 0;
    g.t.arm_at_fire = armed;     /* armed from RULE_FIRE_BEGIN, by the trace */
    ds_result_t pr = ds_engine_pump(g.engine);
    g_fail_new = 0;

    /* The pump returns; nothing aborted. A pump whose firing raised an
       EngineError reports the halt as its status ([NCBK.2.9]). */
    CHECK(pr.status == (armed ? DS_ERR_ENGINE_HALTED : DS_OK),
          armed ? "the pump that halted reports DS_ERR_ENGINE_HALTED"
                : "control: the pump is DS_OK");
    if (armed) {
        CHECK(g_failed > 0, "an allocation inside RE2 was failed");
        CHECK(g.t.allocation == 1,
              "the failure is the EngineError ALLOCATION, once");
        CHECK(g.t.engine_errors == 1 && g.t.other_faults == 0,
              "and no other fault: not ARTEFACT, not a type error");
        CHECK(halted_on_allocation(&g), "the engine is halted on it");
        CHECK(g.t.emits == 0, "the action after the fault does not run");
    } else {
        CHECK(g.t.engine_errors == 0 && g.t.other_faults == 0,
              "control: no fault");
        CHECK(g.t.emits == 1, "control: the activation completes");
    }
    rig_close(&g);
}

/* @spec [IALC.3.6] */
static void test_builtin_match_out_of_memory(void)
{
    run_builtin(match_expr, "xaab", true);
}
static void test_builtin_match_control(void)
{
    run_builtin(match_expr, "xaab", false);
}
/* @spec [IALC.3.6] */
static void test_builtin_capture_out_of_memory(void)
{
    run_builtin(capture_expr, "zxaab", true);
}
static void test_builtin_capture_control(void)
{
    run_builtin(capture_expr, "zxaab", false);
}

/* Two load-time compile sites, the alpha REGEX test (rete/loader.c) and the
   builtins' precompile (builtins.c, ds_rete_regex_precompile): each refuses
   with DS_ERR_OOM when the compile runs out of memory and DS_ERR_DSC_SEMANTIC
   when RE2 rejects the pattern. The rejected case runs unarmed. */
static void run_alpha_load(const char *pattern, bool armed, ds_status_t want)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; return; }

    /* With "a+b" this is the network test_alpha_match_control loads cleanly,
       so a refusal is the compile's and nothing else's. */
    ds_retp_alpha_test_t t = { .kind = DS_RETE_ALPHA_REGEX, .slot_index = 0,
                               .pattern = pattern };
    ds_rete_slot_assign_t as = { .slot_index = 0, .expr = lit_int(1) };
    ds_rete_action_t act = { .kind = DS_RETE_ACTION_ASSERT,
                             .schema_id = g.out_rs->id,
                             .assigns = &as, .assign_count = 1 };
    g_failed = 0;
    g_fail_new = armed;
    ds_result_t r = rig_load(&g, &t, 1, &act, 1);
    g_fail_new = 0;

    if (armed) CHECK(g_failed > 0, "an allocation inside the compile was failed");
    else       CHECK(g_failed == 0, "control: nothing was failed");
    CHECK(r.status == want, "the load is refused with the site's code");
    rig_close(&g);
}

static void run_builtin_load(const char *pattern, bool armed, ds_status_t want)
{
    rig_t g;
    if (rig_open(&g)) { fprintf(stderr, "FAIL: rig_open\n"); g_fails++; return; }

    /* With "a+b" this is the network test_builtin_match_control loads cleanly.
       The network has no alpha REGEX test, so the precompile is the only
       compile the load makes. */
    ds_rete_expr_t *a[3] = { var_ref(0, 0), lit_str(pattern), lit_str("") };
    ds_rete_slot_assign_t as;
    ds_rete_action_t acts[2];
    two_actions(&g, call((uint32_t) DS_FN_REGEX_MATCH, a, 3), &as, acts);
    g_failed = 0;
    g_fail_new = armed;
    ds_result_t r = rig_load(&g, NULL, 0, acts, 2);
    g_fail_new = 0;

    if (armed) CHECK(g_failed > 0, "an allocation inside the compile was failed");
    else       CHECK(g_failed == 0, "control: nothing was failed");
    CHECK(r.status == want, "the load is refused with the site's code");
    rig_close(&g);
}

/* @spec [IALC.3.6] */
static void test_compile_out_of_memory_refuses_the_load(void)
{
    run_alpha_load("a+b", true, DS_ERR_OOM);
}
/* @spec [RDSC.4a.6.1] */
static void test_invalid_alpha_pattern_refuses_the_load(void)
{
    run_alpha_load("a(", false, DS_ERR_DSC_SEMANTIC);
}
/* @spec [IALC.3.6] */
static void test_builtin_compile_out_of_memory_refuses_the_load(void)
{
    run_builtin_load("a+b", true, DS_ERR_OOM);
}
static void test_invalid_builtin_pattern_refuses_the_load(void)
{
    run_builtin_load("a(", false, DS_ERR_DSC_SEMANTIC);
}

int main(void)
{
    printf("=== test_re2_alloc_failure ===\n");
#define RUN(t) do { int _b = g_fails; t(); \
                    printf("  %s: " #t "\n", g_fails == _b ? "pass" : "FAIL"); \
                  } while (0)
    RUN(test_alpha_match_control);
    RUN(test_alpha_match_out_of_memory);
    RUN(test_builtin_match_control);
    RUN(test_builtin_match_out_of_memory);
    RUN(test_builtin_capture_control);
    RUN(test_builtin_capture_out_of_memory);
    RUN(test_compile_out_of_memory_refuses_the_load);
    RUN(test_invalid_alpha_pattern_refuses_the_load);
    RUN(test_builtin_compile_out_of_memory_refuses_the_load);
    RUN(test_invalid_builtin_pattern_refuses_the_load);
#undef RUN
    if (g_fails) {
        fprintf(stderr, "=== test_re2_alloc_failure: %d FAILED ===\n", g_fails);
        return 1;
    }
    printf("=== test_re2_alloc_failure: ALL PASSED ===\n");
    return 0;
}

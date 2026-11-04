/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [IRET.9.6]'s first arm:
 * "An operand is `null` -- `TypeError`. ... The activation is abandoned."
 * The clause names the one route a source program has to it: "a `Json`
 * projection whose leaf is a present JSON `null`".
 *
 * The program: `measure` matches a Doc and emits an Out carrying
 * `abs(d.j.a)`; `go_on` matches a Go and emits a Went. Each case asserts a
 * Doc, pumps, asserts a Go, pumps.
 *
 *   null leaf, j = {"a": null}:
 *     1. exactly one TypeError, named for `measure`, and no EngineError,
 *        ComputationError or BoundsError;
 *     2. `measure` fired and emitted no Out: the activation was abandoned;
 *     3. the engine is not halted;
 *     4. `go_on` fires on the later assert and emits its Went.
 *   control, j = {"a": -2}: no fault at all, and the Out carries 2. The same
 *   rule over a present leaf raises nothing, so the TypeError above is the
 *   leaf's and not the rule's.
 *
 * The path: the projection of `d.j.a` (ds_rete_json_to_val) yields a
 * DS_RETE_VAL_NULL argument for the present JSON `null`; builtins.c's
 * builtin_abs refuses a non-numeric argument through ds_rete_mismatch_cause
 * (rete/eval.h), which returns DS_FAULT_NULL_OPERAND because an argument is
 * null; rete/eval.c's funnel records a TypeError for that cause without
 * consulting `tainted`.
 *
 * `abs`, not `len`: the compiler lowers `len` over a Json path to
 * DS_FN_JSON_LEN, which walks to the leaf itself, so neither of its
 * arguments is null and its TypeError comes from the taint arm. `abs`
 * receives the projected leaf.
 *
 * The order of the first two arms is not pinned: the leaf also derives from
 * a Json slot, so the taint arm gives the same TypeError.
 *
 * Public API only -- no internal headers.
 */
#include "spec_common.h"

#define T0 ((uint64_t) 1000000000)

static const char *const PROGRAM =
    "schema Doc scope logical:\n"
    "    k: Int key\n"
    "    j: Json mutable\n"
    "\n"
    "schema Go scope logical:\n"
    "    k: Int key\n"
    "\n"
    "schema Out scope ttl 1_h:\n"
    "    k: Int\n"
    "    n: Int\n"
    "\n"
    "schema Went scope ttl 1_h:\n"
    "    k: Int\n"
    "\n"
    "rule measure:\n"
    "    Doc d\n"
    "->\n"
    "    emit Out k: d.k n: abs(d.j.a)\n"
    "\n"
    "rule go_on:\n"
    "    Go g\n"
    "->\n"
    "    emit Went k: g.k\n";

typedef struct {
    const ds_schema_t *out;
    const ds_schema_t *went;
    int type_errors;
    int type_errors_of_measure;
    int engine_errors;
    int other_faults;
    int measure_fired;
    int out_emitted;
    int went_emitted;
    int64_t out_n;
} probe_t;

static int named(const char *name, const char *want)
{
    return name != NULL && strcmp(name, want) == 0;
}

static ds_result_t probe_cb(ds_engine_t *e, const ds_stream_ev_t *ev,
                            void *user)
{
    (void) e;
    probe_t *p = (probe_t *) user;
    switch (ev->kind) {
    case DS_EV_TYPE_ERROR:
        p->type_errors++;
        if (named(ev->p.type_error.rule_name, "measure"))
            p->type_errors_of_measure++;
        break;
    case DS_EV_ENGINE_ERROR:
        p->engine_errors++;
        break;
    case DS_EV_COMPUTATION_ERROR:
    case DS_EV_BOUNDS_ERROR:
        p->other_faults++;
        break;
    case DS_EV_RULE_FIRE_BEGIN:
        if (named(ev->p.rule_fire_begin.rule_name, "measure"))
            p->measure_fired++;
        break;
    case DS_EV_ACTION_EMIT: {
        const ds_fact_t *f = ev->p.action_emit.fact;
        const ds_schema_t *s = NULL;
        if (f == NULL || ds_fact_get_schema(f, &s).status != DS_OK) break;
        if (s == p->out) {
            p->out_emitted++;
            ds_slot_value_t v;
            if (ds_fact_get_slot(f, 1, NULL, &v).status == DS_OK
                    && v.kind == DS_SLOT_INT)
                p->out_n = v.v.i;
        } else if (s == p->went) {
            p->went_emitted++;
        }
        break;
    }
    default:
        break;
    }
    return DS_OK_R;
}

/* One case: the Doc's `j` is {"a": <leaf>}, which this takes ownership of.
   Fills `p` and `halted`. */
static int run_case(ds_json_t *leaf, probe_t *p, bool *halted)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    EXPECT_OK("engine_new", r);
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    EXPECT_OK("clock_set_mode", r);
    r = ds_engine_clock_set(e, T0);
    EXPECT_OK("clock_set", r);
    r = spec_load_ds(e, PROGRAM);
    EXPECT_OK("load the program", r);

    const ds_schema_t *doc = NULL, *go = NULL;
    r = ds_engine_schema_find(e, "Doc", &doc);
    if (r.status != DS_OK || doc == NULL) return spec_fail("find Doc", r);
    r = ds_engine_schema_find(e, "Go", &go);
    if (r.status != DS_OK || go == NULL) return spec_fail("find Go", r);
    r = ds_engine_schema_find(e, "Out", &p->out);
    if (r.status != DS_OK || p->out == NULL) return spec_fail("find Out", r);
    r = ds_engine_schema_find(e, "Went", &p->went);
    if (r.status != DS_OK || p->went == NULL) return spec_fail("find Went", r);
    r = ds_engine_set_stream_callback(e, probe_cb, p);
    EXPECT_OK("set_stream_callback", r);

    ds_json_t *obj = NULL;
    r = ds_json_new_object(&obj);
    EXPECT_OK("json_new_object", r);
    r = ds_json_object_set(obj, "a", 1, leaf);
    EXPECT_OK("json_object_set a", r);

    /* The engine deep-clones a Json slot on assert ([NFCT.2.4]), so the tree
       stays ours to free. */
    ds_slot_value_t dv[] = { { .kind = DS_SLOT_INT,  .v.i    = 1 },
                             { .kind = DS_SLOT_JSON, .v.json = obj } };
    r = ds_engine_assert(e, doc, dv, 2, NULL);
    ds_json_free(obj);
    EXPECT_OK("assert Doc", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump: `measure` fires", r);

    ds_slot_value_t gv[] = { { .kind = DS_SLOT_INT, .v.i = 1 } };
    r = ds_engine_assert(e, go, gv, 1, NULL);
    EXPECT_OK("assert Go", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump: `go_on` fires", r);

    r = ds_engine_halted(e, halted, NULL);
    EXPECT_OK("engine_halted", r);
    ds_engine_free(e);
    return 0;
}

/* @spec [IRET.9.6] */
int main(void)
{
    /* The null leaf. */
    ds_json_t *null_leaf = NULL;
    ds_result_t r = ds_json_new_null(&null_leaf);
    EXPECT_OK("json_new_null", r);
    probe_t np = {0};
    bool nhalted = true;
    if (run_case(null_leaf, &np, &nhalted)) return 1;

    if (np.type_errors != 1 || np.type_errors_of_measure != 1) {
        fprintf(stderr, "FAIL: {\"a\": null}: %d TypeError(s), %d named for "
                        "`measure`; want exactly one, `measure`'s\n",
                np.type_errors, np.type_errors_of_measure);
        return 1;
    }
    if (np.engine_errors != 0 || np.other_faults != 0) {
        fprintf(stderr, "FAIL: {\"a\": null}: %d EngineError(s) and %d other "
                        "fault(s); want none -- a null operand is never "
                        "evidence that the artefact lied\n",
                np.engine_errors, np.other_faults);
        return 1;
    }
    if (np.measure_fired != 1 || np.out_emitted != 0) {
        fprintf(stderr, "FAIL: {\"a\": null}: `measure` fired %d time(s) and "
                        "emitted %d Out(s); want 1 and 0 -- the activation "
                        "is abandoned\n", np.measure_fired, np.out_emitted);
        return 1;
    }
    if (nhalted) {
        fprintf(stderr, "FAIL: {\"a\": null}: the engine halted; a TypeError "
                        "abandons the activation and the tier runs on\n");
        return 1;
    }
    if (np.went_emitted != 1) {
        fprintf(stderr, "FAIL: {\"a\": null}: `go_on` emitted %d Went(s) on the "
                        "later assert; want 1\n", np.went_emitted);
        return 1;
    }

    /* The control: a present leaf, the same rule, no fault. */
    ds_json_t *present = NULL;
    r = ds_json_new_int(-2, &present);
    EXPECT_OK("json_new_int", r);
    probe_t cp = {0};
    bool chalted = true;
    if (run_case(present, &cp, &chalted)) return 1;

    if (cp.type_errors != 0 || cp.engine_errors != 0 || cp.other_faults != 0) {
        fprintf(stderr, "FAIL: {\"a\": -2}: %d TypeError(s), %d EngineError(s), "
                        "%d other fault(s); want none\n",
                cp.type_errors, cp.engine_errors, cp.other_faults);
        return 1;
    }
    if (cp.measure_fired != 1 || cp.out_emitted != 1 || cp.out_n != 2) {
        fprintf(stderr, "FAIL: {\"a\": -2}: `measure` fired %d time(s), emitted "
                        "%d Out(s) carrying %lld; want 1, 1 and 2\n",
                cp.measure_fired, cp.out_emitted, (long long) cp.out_n);
        return 1;
    }
    if (chalted || cp.went_emitted != 1) {
        fprintf(stderr, "FAIL: {\"a\": -2}: halted %d, `go_on` emitted %d "
                        "Went(s); want 0 and 1\n", (int) chalted,
                cp.went_emitted);
        return 1;
    }

    printf("test_iret_9_6__null_leaf_is_a_type_error: OK\n");
    return 0;
}

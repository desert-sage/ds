/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NDET.1.3]
 * libds does not change the integrator's floating point, rounding mode
 * included, and its exception flags with it: after a call the integrator holds
 * the mode and the flags it held before, whatever the engine computed.
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_assert and ds_engine_pump, each through
 * ds_api_enter -> ds_fp_establish, the rule's division, and ds_api_leave ->
 * ds_fp_restore, read back through libds.h and <fenv.h>.
 *
 *   1. The integrator holds FE_UPWARD with only FE_INEXACT raised. A rule
 *      divides by 0.0, which raises FE_DIVBYZERO in the engine. After the
 *      assert and after the pump the mode is FE_UPWARD and the flags are
 *      exactly FE_INEXACT: the integrator's flag is kept, and the engine's did
 *      not leak. The division is shown to have run, so the case has teeth.
 *   2. The integrator holds no flag, and a rule with no Float runs. Every flag
 *      is still clear after each call.
 *   3. The integrator holds the default state, FE_TONEAREST and no flag, and
 *      the engine raises one: a first call (a Tick) makes the default known,
 *      then Src(1, 1.0) is asserted and pumped, so the rule divides by 0.0.
 *      THE PATH: ds_fp_establish's early return when fp_saved_is_default, and
 *      on the way out ds_fp_put_back's write of FE_DFL_ENV, which clears the
 *      engine's FE_DIVBYZERO. After each call the mode is FE_TONEAREST and no
 *      flag is raised, and the division is shown to have run (q is +inf). A
 *      guard that compared only the mode, or skipped the write whenever the
 *      saved state was the default, passes 1 and 2 and fails this.
 *
 * Skipped, loudly, where the platform cannot set FE_UPWARD, as test_fp_mode.c
 * is.
 */
#include <fenv.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "spec_common.h"

#if !defined(FE_UPWARD) || !defined(FE_TONEAREST) || !defined(FE_INEXACT) \
    || !defined(FE_DIVBYZERO) || !defined(FE_ALL_EXCEPT)
int main(void)
{
    printf("test_ndet_1_3__a_call_leaves_the_integrators_flags_as_they_were: "
           "SKIPPED -- no floating-point environment to pin\n");
    return 0;
}
#else

static const char *PROGRAM =
    "schema Src scope logical:\n"
    "    id: Int key\n"
    "    x: Float mutable\n"
    "\n"
    "schema Out scope logical:\n"
    "    id: Int key\n"
    "    q: Float mutable\n"
    "\n"
    "schema Tick scope logical:\n"
    "    id: Int key\n"
    "\n"
    "schema Seen scope logical:\n"
    "    id: Int key\n"
    "\n"
    "rule divide:\n"
    "    Src s\n"
    "->\n"
    "    emit Out logical id: s.id q: s.x / 0.0\n"
    "\n"
    "rule ticks:\n"
    "    Tick t\n"
    "->\n"
    "    emit Seen logical id: t.id + 1\n";

static int load(ds_engine_t **e, const ds_schema_t **src, const ds_schema_t **tick)
{
    EXPECT_OK("engine", ds_engine_new(NULL, e));
    EXPECT_OK("load", spec_load_ds(*e, PROGRAM));
    EXPECT_OK("find Src", ds_engine_schema_find(*e, "Src", src));
    EXPECT_OK("find Tick", ds_engine_schema_find(*e, "Tick", tick));
    if (*src == NULL || *tick == NULL) {
        fprintf(stderr, "FAIL: a schema is missing\n");
        return 1;
    }
    return 0;
}

/* The mode and the flags the integrator holds after a call, against what it
   held before. Read before anything else touches the environment. */
static int held(const char *after, int mode, int flags)
{
    int now_mode  = fegetround();
    int now_flags = fetestexcept(FE_ALL_EXCEPT);
    if (now_mode != mode || now_flags != flags) {
        (void) fesetround(FE_TONEAREST);
        (void) feclearexcept(FE_ALL_EXCEPT);
        fprintf(stderr, "FAIL: after %s the mode is %d and the flags 0x%x, "
                        "want mode %d and flags 0x%x\n",
                after, now_mode, now_flags, mode, flags);
        return 1;
    }
    return 0;
}

typedef struct { int n; double q; } out_read_t;

static ds_result_t read_out(const ds_fact_t *fact, void *user)
{
    out_read_t *r = (out_read_t *) user;
    ds_slot_value_t v;
    if (ds_fact_get_slot(fact, 1, NULL, &v).status == DS_OK
        && v.kind == DS_SLOT_FLOAT) {
        r->q = v.v.f;
        r->n++;
    }
    return DS_OK_R;
}

/* 1: the integrator's FE_INEXACT is kept and the engine's FE_DIVBYZERO is not. */
static int test_ndet_1_3__a_call_leaves_the_integrators_flags_as_they_were(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *src = NULL, *tick = NULL;
    if (load(&e, &src, &tick)) return 1;

    ds_slot_value_t sv[2];
    memset(sv, 0, sizeof sv);
    sv[0].kind = DS_SLOT_INT;   sv[0].v.i = 1;
    sv[1].kind = DS_SLOT_FLOAT; sv[1].v.f = 1.0;

    (void) feclearexcept(FE_ALL_EXCEPT);
    (void) fesetround(FE_UPWARD);
    (void) feraiseexcept(FE_INEXACT);
    ds_result_t ra = ds_engine_assert(e, src, sv, 2, NULL);
    if (held("assert", FE_UPWARD, FE_INEXACT)) return 1;
    ds_result_t rp = ds_engine_pump(e);
    if (held("pump", FE_UPWARD, FE_INEXACT)) return 1;
    (void) fesetround(FE_TONEAREST);
    (void) feclearexcept(FE_ALL_EXCEPT);

    EXPECT_OK("assert Src(1, 1.0)", ra);
    EXPECT_OK("pump", rp);
    const ds_schema_t *out = NULL;
    EXPECT_OK("find Out", ds_engine_schema_find(e, "Out", &out));
    out_read_t r = { 0, 0.0 };
    EXPECT_OK("read Out", ds_engine_for_each_fact(e, out, read_out, &r));
    if (r.n != 1 || !isinf(r.q) || r.q < 0.0) {
        fprintf(stderr, "FAIL: the division did not run: %d Out fact(s), q %g\n",
                r.n, r.q);
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

/* 2: a call over no Float leaves an integrator holding no flag with none. */
static int test_ndet_1_3__no_flag_held_is_no_flag_after(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *src = NULL, *tick = NULL;
    if (load(&e, &src, &tick)) return 1;

    ds_slot_value_t sv[1];
    memset(sv, 0, sizeof sv);
    sv[0].kind = DS_SLOT_INT; sv[0].v.i = 1;

    (void) feclearexcept(FE_ALL_EXCEPT);
    ds_result_t ra = ds_engine_assert(e, tick, sv, 1, NULL);
    if (held("assert", FE_TONEAREST, 0)) return 1;
    ds_result_t rp = ds_engine_pump(e);
    if (held("pump", FE_TONEAREST, 0)) return 1;

    EXPECT_OK("assert Tick(1)", ra);
    EXPECT_OK("pump", rp);
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

/* 3: the default state, and the engine's FE_DIVBYZERO cleared on the way out. */
static int test_ndet_1_3__the_default_state_with_a_flag_raised(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *src = NULL, *tick = NULL;
    if (load(&e, &src, &tick)) return 1;

    ds_slot_value_t tv[1];
    memset(tv, 0, sizeof tv);
    tv[0].kind = DS_SLOT_INT; tv[0].v.i = 1;
    ds_slot_value_t sv[2];
    memset(sv, 0, sizeof sv);
    sv[0].kind = DS_SLOT_INT;   sv[0].v.i = 1;
    sv[1].kind = DS_SLOT_FLOAT; sv[1].v.f = 1.0;

    (void) fesetround(FE_TONEAREST);
    (void) feclearexcept(FE_ALL_EXCEPT);
    ds_result_t rt = ds_engine_assert(e, tick, tv, 1, NULL);
    if (held("the first call", FE_TONEAREST, 0)) return 1;
    ds_result_t ra = ds_engine_assert(e, src, sv, 2, NULL);
    if (held("assert", FE_TONEAREST, 0)) return 1;
    ds_result_t rp = ds_engine_pump(e);
    if (held("the dividing pump", FE_TONEAREST, 0)) return 1;

    EXPECT_OK("assert Tick(1)", rt);
    EXPECT_OK("assert Src(1, 1.0)", ra);
    EXPECT_OK("pump", rp);
    const ds_schema_t *out = NULL;
    EXPECT_OK("find Out", ds_engine_schema_find(e, "Out", &out));
    out_read_t r = { 0, 0.0 };
    EXPECT_OK("read Out", ds_engine_for_each_fact(e, out, read_out, &r));
    if (r.n != 1 || !isinf(r.q) || r.q < 0.0) {
        fprintf(stderr, "FAIL: the division did not run: %d Out fact(s), q %g\n",
                r.n, r.q);
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

int main(void)
{
    if (fesetround(FE_UPWARD) != 0 || fegetround() != FE_UPWARD) {
        (void) fesetround(FE_TONEAREST);
        printf("test_ndet_1_3__a_call_leaves_the_integrators_flags_as_they_were: "
               "SKIPPED -- this platform cannot set FE_UPWARD\n");
        return 0;
    }
    (void) fesetround(FE_TONEAREST);

    if (test_ndet_1_3__a_call_leaves_the_integrators_flags_as_they_were()) return 1;
    if (test_ndet_1_3__no_flag_held_is_no_flag_after()) return 1;
    if (test_ndet_1_3__the_default_state_with_a_flag_raised()) return 1;
    printf("test_ndet_1_3__a_call_leaves_the_integrators_flags_as_they_were: OK\n");
    return 0;
}
#endif

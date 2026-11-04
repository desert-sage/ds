/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.10.2]
 * "Once ds_engine_load_dsc has succeeded, ds_engine_set_admission must return
 * DS_ERR_STATE and leave the policy as it was ... On an engine a failed load
 * spent, it is refused with DS_ERR_ENGINE_HALTED".
 *
 * THE PATH: dsc/loader.c's ds_engine_set_admission, its halt guard and then the
 * test of whether the engine holds an artefact ([STYL.5.10.8]).
 *
 *   before any load  DS_OK, and the policy the call set judges the load: a
 *                    `call` program under FALSE_ONLY is refused, and under
 *                    TRUE_ONLY it loads. So the call does set a policy.
 *   after a load     DS_ERR_STATE, for every policy, the one that would refuse
 *                    the program it holds and the one that admits it. Nothing
 *                    public reads a policy back, and an engine takes one load,
 *                    so "left as it was" has no other observable: the status
 *                    is the whole check, and the refusal returns before the
 *                    write.
 *   after a failed   DS_ERR_ENGINE_HALTED, and ds_engine_halted reports true
 *   load             with DS_ENGINE_FAULT_UNSPECIFIED ([NCBK.2.11]).
 */
#include "spec_common.h"

#include <stdbool.h>

static const char *PROGRAM =
    "schema Trig scope logical:\n"
    "    k: Int key\n"
    "\n"
    "service svc.ping:\n"
    "    kwarg k: Int\n"
    "    no response\n"
    "\n"
    "rule ping:\n"
    "    Trig t\n"
    "->\n"
    "    call svc.ping k: t.k nocooldown\n";

static int test_before_any_load_the_policy_is_set_and_judges(void)
{
    ds_engine_t *e = NULL;
    EXPECT_OK("engine_new", ds_engine_new(NULL, &e));
    EXPECT_OK("set_admission before any load: FALSE_ONLY",
              ds_engine_set_admission(e, DS_CAPABILITY_CALL, DS_ADMIT_FALSE_ONLY));
    EXPECT_STATUS("the policy set before the load refuses it",
                  spec_load_ds(e, PROGRAM), DS_ERR_BND_DIALECT_MISMATCH);
    EXPECT_OK("free", ds_engine_free(e));

    e = NULL;
    EXPECT_OK("engine_new", ds_engine_new(NULL, &e));
    EXPECT_OK("set_admission before any load: TRUE_ONLY",
              ds_engine_set_admission(e, DS_CAPABILITY_CALL, DS_ADMIT_TRUE_ONLY));
    EXPECT_OK("the policy set before the load admits it", spec_load_ds(e, PROGRAM));
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

static int test_after_a_load_it_is_refused(void)
{
    ds_engine_t *e = NULL;
    EXPECT_OK("engine_new", ds_engine_new(NULL, &e));
    EXPECT_OK("load", spec_load_ds(e, PROGRAM));
    EXPECT_STATUS("after a load, a policy that would refuse what it holds",
                  ds_engine_set_admission(e, DS_CAPABILITY_CALL, DS_ADMIT_FALSE_ONLY),
                  DS_ERR_STATE);
    EXPECT_STATUS("after a load, a policy that admits what it holds",
                  ds_engine_set_admission(e, DS_CAPABILITY_CALL, DS_ADMIT_TRUE_ONLY),
                  DS_ERR_STATE);
    EXPECT_STATUS("after a load, the default policy",
                  ds_engine_set_admission(e, DS_CAPABILITY_CALL, DS_ADMIT_EITHER),
                  DS_ERR_STATE);

    bool halted = true;
    EXPECT_OK("halted", ds_engine_halted(e, &halted, NULL));
    if (halted) {
        fprintf(stderr, "FAIL: a refused policy halted the engine\n");
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

static int test_after_a_failed_load_it_is_halted(void)
{
    static const uint8_t NOT_AN_ARTEFACT[] = { 0xff, 0xff, 0xff, 0xff };

    ds_engine_t *e = NULL;
    EXPECT_OK("engine_new", ds_engine_new(NULL, &e));
    ds_result_t load = ds_engine_load_dsc(e, NOT_AN_ARTEFACT, sizeof NOT_AN_ARTEFACT);
    if (load.status == DS_OK) {
        fprintf(stderr, "FAIL: premise: those bytes load\n");
        return 1;
    }
    EXPECT_STATUS("after a failed load",
                  ds_engine_set_admission(e, DS_CAPABILITY_CALL, DS_ADMIT_EITHER),
                  DS_ERR_ENGINE_HALTED);

    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_ARTEFACT_LIED;
    EXPECT_OK("halted", ds_engine_halted(e, &halted, &fault));
    if (!halted || fault != DS_ENGINE_FAULT_UNSPECIFIED) {
        fprintf(stderr, "FAIL: a spent engine reads halted=%d fault=%d\n",
                (int) halted, (int) fault);
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

int main(void)
{
    if (test_before_any_load_the_policy_is_set_and_judges()) return 1;
    if (test_after_a_load_it_is_refused()) return 1;
    if (test_after_a_failed_load_it_is_halted()) return 1;
    printf("test_nlfc_10_2__admission_after_load_is_refused: OK\n");
    return 0;
}

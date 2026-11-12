/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.2.5]
 * On a halted engine ([NCBK.2.9]), ds_engine_next_deadline_ns returns
 * DS_ERR_ENGINE_HALTED.
 *
 *   (a) The control: a fresh engine on the mock clock answers DS_OK, none.
 *   (b) A failed load spends the engine ([NFCT.1.1]): junk bytes are refused,
 *       and ds_engine_halted reports the engine halted.
 *   (c) The call: DS_ERR_ENGINE_HALTED.
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_next_deadline_ns (engine.c), through
 * DS_ENGINE_REFUSE_IF_HALTED.
 */
#include "spec_deadline.h"

int main(void)
{
    static const uint8_t junk[] = { 0x00, 0x01, 0x02, 0x03 };
    ds_engine_t *e = NULL;
    EXPECT_OK("engine", ds_engine_new(NULL, &e));
    EXPECT_OK("mock clock", ds_engine_clock_set_mode(e, DS_CLOCK_MOCK));
    if (dl_expect("(a) the control, a fresh engine", e, false, 0)) return 1;

    if (ds_engine_load_dsc(e, junk, sizeof junk).status == DS_OK)
        return dl_fail("(b)", "premise: junk bytes loaded");
    bool halted = false;
    EXPECT_OK("ds_engine_halted", ds_engine_halted(e, &halted, NULL));
    if (!halted) return dl_fail("(b)", "premise: the failed load did not halt");

    uint64_t ns = 0;
    bool has = false;
    EXPECT_STATUS("(c) on the halted engine",
                  ds_engine_next_deadline_ns(e, &ns, &has),
                  DS_ERR_ENGINE_HALTED);

    ds_engine_free(e);
    printf("test_nlfc_2_5__refused_when_halted: OK\n");
    return 0;
}

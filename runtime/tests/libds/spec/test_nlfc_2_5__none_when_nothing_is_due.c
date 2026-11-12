/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.2.5]
 * ds_engine_next_deadline_ns "must report ... that the engine holds none"
 * when it holds no deadline: DS_OK, *out_has false and *out_ns 0 (libds.h).
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_next_deadline_ns (engine.c) over
 * ds_rete_wm_next_deadline and ds_cache_next_deadline, read through libds.h.
 *
 *   (a) The program loaded, nothing asserted: none.
 *   (b) A `Drop` fact asserted and pumped: a live fact with no TTL, whose rule
 *       deletes a cache entry that does not exist, arms nothing: still none.
 *
 * Each call starts with *out_has true and *out_ns nonzero, so a call that
 * writes neither fails.
 */
#include "spec_deadline.h"

int main(void)
{
    ds_engine_t *e = NULL;
    if (dl_engine(&e, dl_program())) return 1;
    if (dl_expect("(a) loaded, nothing asserted", e, false, 0)) return 1;

    if (dl_assert(e, "Drop", 1, NULL)) return 1;
    EXPECT_OK("pump", ds_engine_pump(e));
    if (dl_expect("(b) a fact with no TTL, pumped", e, false, 0)) return 1;

    EXPECT_OK("free", ds_engine_free(e));
    printf("test_nlfc_2_5__none_when_nothing_is_due: OK\n");
    return 0;
}

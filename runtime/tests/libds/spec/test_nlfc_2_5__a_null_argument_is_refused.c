/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.2.5]
 * "A NULL argument is `DS_ERR_INVAL`." Each of the three arguments NULL in
 * turn, the other two valid, on a loaded engine holding a deadline (the cache
 * entry's 10 s):
 *
 *   (a) engine NULL    DS_ERR_INVAL
 *   (b) out_ns NULL    DS_ERR_INVAL
 *   (c) out_has NULL   DS_ERR_INVAL
 *
 * The control: the same engine with all three valid answers DS_OK and 10 s,
 * so each refusal is the NULL's. No binding can pass a NULL, so this is the
 * only test of the sentence.
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_next_deadline_ns's argument checks
 * (engine.c).
 */
#include "spec_deadline.h"

int main(void)
{
    ds_engine_t *e = NULL;
    if (dl_engine(&e, dl_program())) return 1;
    if (dl_assert(e, "Write", 1, NULL)) return 1;
    EXPECT_OK("pump", ds_engine_pump(e));
    if (dl_expect("the control", e, true, 10 * DL_SEC)) return 1;

    uint64_t ns = 0;
    bool has = false;
    EXPECT_STATUS("(a) engine NULL", ds_engine_next_deadline_ns(NULL, &ns, &has),
                  DS_ERR_INVAL);
    EXPECT_STATUS("(b) out_ns NULL", ds_engine_next_deadline_ns(e, NULL, &has),
                  DS_ERR_INVAL);
    EXPECT_STATUS("(c) out_has NULL", ds_engine_next_deadline_ns(e, &ns, NULL),
                  DS_ERR_INVAL);

    EXPECT_OK("free", ds_engine_free(e));
    printf("test_nlfc_2_5__a_null_argument_is_refused: OK\n");
    return 0;
}

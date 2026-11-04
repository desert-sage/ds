/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* core_math_unreachable — where CORE-MATH's worst-case branches go.
 *
 * `pow` and `atan2` end in a branch upstream holds unreachable, which prints and
 * calls `exit(1)`. libds.build compiles those files with
 * `-Dprintf=ds_cm_unreachable_report` and `-Dexit=ds_cm_unreachable_exit`, so no
 * printf-family symbol enters libds.a ([IARC.1.16]). `__builtin_trap` references no
 * symbol, so the microcontroller allowlists need no `abort`.
 *
 * No name here contains "printf": the release's printf check refuses any such
 * symbol. */
#include "core_math.h"

int ds_cm_unreachable_report(const char *text, ...)
{
    (void)text;
    return 0;
}

void ds_cm_unreachable_exit(int status)
{
    (void)status;
    __builtin_trap();
}

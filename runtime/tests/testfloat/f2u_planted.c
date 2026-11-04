/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* The float-to-unsigned census's negative fixture: one floating-to-unsigned
 * conversion, declared nowhere, which every census run must refuse. It is
 * compiled with the archive's own C flags and is in no archive. */
#include <stdint.h>

uint32_t ds_f2u_planted(double d);

uint32_t ds_f2u_planted(double d)
{
    return (uint32_t) d;
}

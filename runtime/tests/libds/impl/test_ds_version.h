/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * The DS version the LINKED libds carries — asked of the library, never
 * compiled in ([LDET.1.10]).
 *
 * Not `DS_LIBDS_VERSION`: `libds.build` stamps that macro into libds.a, but a
 * test TU is compiled without it and reads the "0.0.0+dev" fallback, so an
 * artefact stamped with it would be refused with DS_ERR_DSC_VERSION.
 * `ds_engine_get_platform_signature` reports the string libds was compiled
 * with, the one the loader compares an artefact against.
 */
#ifndef DS_TEST_DS_VERSION_H
#define DS_TEST_DS_VERSION_H

#include <string.h>

#include "libds.h"

/* Cached: a build constant, and the engine exists only to be asked. Returns ""
   if the engine cannot be created, which fails the caller's assertion loudly
   rather than silently stamping something plausible. */
static const char *ds_test_accepted_version(void)
{
    static char cached[64];
    if (cached[0] != '\0') return cached;
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK || e == NULL) return "";
    ds_platform_signature_t sig;
    if (ds_engine_get_platform_signature(e, &sig).status == DS_OK
            && sig.libds_version != NULL) {
        strncpy(cached, sig.libds_version, sizeof(cached) - 1);
        cached[sizeof(cached) - 1] = '\0';
    }
    ds_engine_free(e);
    return cached;
}

#endif /* DS_TEST_DS_VERSION_H */

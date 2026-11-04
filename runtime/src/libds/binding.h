/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * binding.h — the dialect-binding comparison ([RBND.6.1]), which every load
 * path that checks a dialect binding calls ([RBND.6.3]). The RT-config
 * comparison, the other of the two, has no consumer while realtime is refused,
 * so it is not here.
 */
#ifndef DS_LIBDS_BINDING_H
#define DS_LIBDS_BINDING_H

#include <stddef.h>
#include <stdint.h>

#include "libds.h"

struct ds_engine;

/* The most `capabilities` a DSC header or a stream header may carry: a buffer
   guard no well-formed list reaches. A header past it is refused, not
   truncated. */
#define DS_BINDING_CAPABILITIES_MAX 64u

/* [RBND.1.3]: true when `caps` is strictly ascending and every entry a live
   member of proto/capabilities.proto#Capability other than
   CAPABILITY_UNSPECIFIED. The empty list is well-formed. Defined in
   dsc/loader.c. */
bool ds_binding_capabilities_well_formed(const uint32_t *caps, size_t n);

/* A dialect-binding tuple ([RBND.1.3]), borrowed. `capabilities` are in the
   artefact's order, and compared in that order, not as a set. */
typedef struct ds_dialect_tuple {
    const uint8_t  *dsc_sha256;
    size_t          dsc_sha256_len;
    const uint32_t *capabilities;
    size_t          n_capabilities;
    const uint8_t  *dialect_def_sha256;
    size_t          dialect_def_sha256_len;
} ds_dialect_tuple_t;

/* [RBND.5.1], [RBND.6.2]: compare `recorded` (the secondary artefact's tuple)
   with `loaded` (the DSC's), first mismatch wins. The detail ([RBND.5.2]) lives
   in `engine`'s detail buffer until that engine's next detail. */
ds_result_t ds_binding_compare_dialect(struct ds_engine         *engine,
                                       const ds_dialect_tuple_t *recorded,
                                       const ds_dialect_tuple_t *loaded);

#endif /* DS_LIBDS_BINDING_H */

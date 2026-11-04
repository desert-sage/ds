/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * dsc/loader.h — internal DSC artefact loader ([RDSC]), behind ds_engine_load_dsc.
 */
#ifndef LIBDS2_INTERNAL_DSC_LOADER_H
#define LIBDS2_INTERNAL_DSC_LOADER_H

#include <stddef.h>
#include <stdint.h>

#include "libds.h"
#include "binding.h"

struct ds_engine;

/* The loaded artefact's dialect-binding tuple ([RBND.1.3]), as its header carries
   it. */
typedef struct ds_dsc_binding {
    uint8_t  dsc_sha256[32];
    uint8_t  dialect_def_sha256[32];
    uint32_t capabilities[DS_BINDING_CAPABILITIES_MAX];
    size_t   n_capabilities;
} ds_dsc_binding_t;

/*
 * Load a .dsc byte stream into the engine. `data` is borrowed. The caller has
 * checked its arguments, and sets the halt latch on any error this returns
 * ([RDSC.9.8]). On success, `out_binding` receives the header's tuple.
 */
ds_result_t ds_dsc_load(struct ds_engine *engine,
                        const uint8_t    *data,
                        size_t            len,
                        ds_dsc_binding_t *out_binding);

#endif /* LIBDS2_INTERNAL_DSC_LOADER_H */

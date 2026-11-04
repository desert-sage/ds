/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/builtin_backends.h — register the backends libds ships ([NSBK.2.3]).
 *
 * Not in `include/internal/`, which ships in every libds tarball: registration
 * stays off the integrator surface.
 */
#ifndef DS_SERIES_BUILTIN_BACKENDS_H
#define DS_SERIES_BUILTIN_BACKENDS_H

#include "libds.h"

/* All seven. Returns the first non-OK status and stops. */
ds_result_t ds_series_register_builtin_backends(ds_engine_t *engine);

#endif /* DS_SERIES_BUILTIN_BACKENDS_H */

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* builtins.h — DS built-in function registration. */
#ifndef LIBDS2_BUILTINS_H
#define LIBDS2_BUILTINS_H

#include "libds.h"

struct ds_rete_engine;

/* Call once after ds_rete_engine_create, before loading any rules. */
ds_result_t ds_register_builtins(struct ds_rete_engine *engine);

/*
 * Compile every regex the loaded network names, and size the cache once to hold
 * them. Call after the network is built and before the first pump. After it, a
 * cache miss is a defect.
 *
 * DS_ERR_DSC_SEMANTIC if RE2 rejects a pattern, DS_ERR_OOM out of memory. An
 * artefact that names no patterns leaves the cache absent.
 */
ds_result_t ds_rete_regex_precompile(struct ds_rete_engine *engine);

#endif /* LIBDS2_BUILTINS_H */

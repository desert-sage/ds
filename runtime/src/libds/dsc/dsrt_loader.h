/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* dsrt_loader — RealtimeContract atom handler ([RTCT.6.5], [RDSC.16.3.3]). */
#ifndef LIBDS_DSC_DSRT_LOADER_H
#define LIBDS_DSC_DSRT_LOADER_H

#include <stddef.h>
#include <stdint.h>

#include "libds.h"

struct ds_engine;

/* Decode a RealtimeContract atom body and store the contract on
 * engine->rete_engine. DS_ERR_CONTRACT_INVALID on a malformed proto, or an
 * rt_config_sha256 that disagrees with the canonical recomputation.
 */
ds_result_t ds_dsrt_handle_atom(struct ds_engine *engine,
                                const uint8_t    *body,
                                size_t            body_len);

/* The loaded contract's canonical [RBND.4b] serialization into `out_buf`. Returns
 * its length, excluding the NUL; 0 when no contract is loaded.
 */
size_t ds_dsrt_canonical_bytes(const struct ds_engine *engine,
                                char                   *out_buf,
                                size_t                  buf_cap);

/* The body of [NRTM.6.3]'s ds_contract_dump_canonical, in a buffer freed with
 * ds_free. No public entry point declares it while realtime is out of the edition
 * ([NRTM.9.1]). */
ds_result_t ds_contract_dump_canonical_body(const struct ds_engine *engine,
                                            char                  **out_buf,
                                            size_t                 *out_len);

/* [RTCT.7.1]: the contract's per-node capacities onto the owned nodes, at the end
 * of a load. */
ds_result_t ds_dsrt_apply_node_caps(struct ds_engine *engine);

#endif  /* LIBDS_DSC_DSRT_LOADER_H */

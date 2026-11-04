/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/dispatch.h — alpha dispatch table, indexed by schema id (IRET.1.7,
 * IRET.6.4).
 */
#ifndef LIBDS2_INTERNAL_RETE_DISPATCH_H
#define LIBDS2_INTERNAL_RETE_DISPATCH_H

#include <stdint.h>

#include "libds.h"
#include "rete/engine.h"
#include "rete/alpha.h"
#include "rete/fact.h"

/* The node pointer is borrowed; it must outlive the engine. */
ds_result_t ds_rete_dispatch_add(ds_rete_engine_t     *engine,
                                  uint16_t              schema_id,
                                  ds_rete_alpha_node_t *node);

/* DS_OK even if no node admitted the fact. A failure leaves the fact in no alpha
 * memory. */
ds_result_t ds_rete_dispatch_assert(ds_rete_engine_t *engine,
                                     ds_rete_fact_t   *fact);

ds_result_t ds_rete_dispatch_retract(ds_rete_engine_t *engine,
                                      ds_rete_fact_t   *fact);

#endif /* LIBDS2_INTERNAL_RETE_DISPATCH_H */

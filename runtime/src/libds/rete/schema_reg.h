/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/schema_reg.h — schema registry operations (IRET.5). Schema objects are
 * owned by the engine.
 */
#ifndef LIBDS2_INTERNAL_RETE_SCHEMA_REG_H
#define LIBDS2_INTERNAL_RETE_SCHEMA_REG_H

#include <stdint.h>

#include "libds.h"
#include "rete/engine.h"
#include "rete/schema.h"

/* The declaration-side mapping. slot_to_rete_val (wm_rete_bridge.c) is the
 * value-side one, and they must agree row for row (test_slot_type_mapping). */
ds_rete_val_kind_t ds_rete_val_kind_for_slot_type(ds_slot_type_t type);

/* Assigns the next compact schema id, and copies the slot descriptors. DS_ERR_STATE
 * if the name is already registered. *out is engine-owned. */
ds_result_t ds_rete_schema_register(ds_rete_engine_t    *engine,
                                     const char          *name,
                                     ds_rete_scope_t      scope,
                                     int64_t              default_ttl_ns,
                                     ds_rete_slot_desc_t *slots,
                                     uint16_t             slot_count,
                                     ds_rete_schema_t   **out);

const ds_rete_schema_t *ds_rete_schema_by_id(const ds_rete_engine_t *engine,
                                              uint16_t                id);

const ds_rete_schema_t *ds_rete_schema_by_name(const ds_rete_engine_t *engine,
                                                const char             *name);

/* `name` need not be followed by a NUL. */
const ds_rete_schema_t *ds_rete_schema_by_name_n(const ds_rete_engine_t *engine,
                                                  const char             *name,
                                                  size_t                  len);

#endif /* LIBDS2_INTERNAL_RETE_SCHEMA_REG_H */

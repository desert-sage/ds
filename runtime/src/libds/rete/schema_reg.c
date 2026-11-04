/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/schema_reg.c — schema registry (IRET.5).
 */
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"

#include "rete/alpha.h"
#include "rete/clone.h"
#include "rete/engine.h"
#include "rete/intern.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/wm_rete.h"

#define NAME_MAP_MAX_LOAD 70u

static uint32_t hash_ptr(const void *p)
{
    uintptr_t v = (uintptr_t)p;
    v = (v >> 3) * 2654435761u;
    return (uint32_t)v;
}

static ds_result_t name_map_grow(ds_rete_engine_t *e)
{
    size_t            new_cap = e->schema_name_cap * 2;
    ds_rete_schema_t **nm     = DS_CALLOC(new_cap, sizeof(*nm));
    if (!nm) return DS_ERR_R(DS_ERR_OOM, "schema name map grow");

    for (size_t i = 0; i < e->schema_name_cap; i++) {
        ds_rete_schema_t *s = e->schema_name_map[i];
        if (!s) continue;
        uint32_t h = hash_ptr(s->name);
        size_t   j = h & (new_cap - 1);
        while (nm[j]) j = (j + 1) & (new_cap - 1);
        nm[j] = s;
    }
    DS_FREE(e->schema_name_map);
    e->schema_name_map = nm;
    e->schema_name_cap = new_cap;
    return DS_OK_R;
}

static ds_result_t name_map_insert(ds_rete_engine_t *e,
                                   ds_rete_schema_t *schema)
{
    if (e->schema_name_n * 100u / e->schema_name_cap >= NAME_MAP_MAX_LOAD) {
        ds_result_t r = name_map_grow(e);
        if (r.status != DS_OK) return r;
    }
    uint32_t h = hash_ptr(schema->name);
    size_t   i = h & (e->schema_name_cap - 1);
    while (e->schema_name_map[i]) i = (i + 1) & (e->schema_name_cap - 1);
    e->schema_name_map[i] = schema;
    e->schema_name_n++;
    return DS_OK_R;
}

static const ds_rete_schema_t *name_map_lookup(const ds_rete_engine_t *e,
                                                const char             *name)
{
    if (e->schema_name_n == 0) return NULL;
    uint32_t h = hash_ptr(name);
    size_t   i = h & (e->schema_name_cap - 1);
    while (e->schema_name_map[i]) {
        if (e->schema_name_map[i]->name == name)
            return e->schema_name_map[i];
        i = (i + 1) & (e->schema_name_cap - 1);
    }
    return NULL;
}

#define BY_ID_INIT_CAP 16u

static ds_result_t by_id_ensure(ds_rete_engine_t *e, size_t need)
{
    if (need <= e->schema_cap) return DS_OK_R;
    size_t new_cap = e->schema_cap ? e->schema_cap * 2 : BY_ID_INIT_CAP;
    while (new_cap < need) new_cap *= 2;

    ds_rete_schema_t **nb = DS_REALLOC(e->schemas_by_id,
                                    new_cap * sizeof(*nb));
    if (!nb) return DS_ERR_R(DS_ERR_OOM, "schema by-id array");
    memset(nb + e->schema_cap, 0,
           (new_cap - e->schema_cap) * sizeof(*nb));
    e->schemas_by_id = nb;

    ds_rete_dispatch_entry_t *nd = DS_REALLOC(e->alpha_dispatch,
                                           new_cap * sizeof(*nd));
    if (!nd) return DS_ERR_R(DS_ERR_OOM, "alpha dispatch array");
    memset(nd + e->schema_cap, 0,
           (new_cap - e->schema_cap) * sizeof(*nd));
    e->alpha_dispatch = nd;

    e->schema_cap = new_cap;
    return DS_OK_R;
}

ds_rete_val_kind_t ds_rete_val_kind_for_slot_type(ds_slot_type_t type)
{
    switch (type) {
    case DS_SLOT_TYPE_INT:    return DS_RETE_VAL_INT;
    /* RDSC.5.5.8: a now() stored there arrives as TIME, admitted beside INT. */
    case DS_SLOT_TYPE_TIME:     return DS_RETE_VAL_INT;
    case DS_SLOT_TYPE_DATE:     return DS_RETE_VAL_INT;
    case DS_SLOT_TYPE_DURATION: return DS_RETE_VAL_INT;
    case DS_SLOT_TYPE_FLOAT:  return DS_RETE_VAL_FLOAT;
    case DS_SLOT_TYPE_STRING: return DS_RETE_VAL_STR;
    case DS_SLOT_TYPE_BOOL:   return DS_RETE_VAL_BOOL;
    case DS_SLOT_TYPE_JSON:   return DS_RETE_VAL_JSON;
    case DS_SLOT_TYPE_BYTES:  return DS_RETE_VAL_BYTES;
    case DS_SLOT_TYPE_SCHEMA: return DS_RETE_VAL_FACT_REF;
    }
    /* Outside the switch, so -Wswitch names a new ds_slot_type_t. */
    return DS_RETE_VAL_STR;
}

ds_result_t ds_rete_schema_register(ds_rete_engine_t    *engine,
                                     const char          *name,
                                     ds_rete_scope_t      scope,
                                     int64_t              default_ttl_ns,
                                     ds_rete_slot_desc_t *slots,
                                     uint16_t             slot_count,
                                     ds_rete_schema_t   **out)
{
    if (!engine || !name)
        return DS_ERR_R(DS_ERR_INVAL, "schema_register: NULL arg");
    if (slot_count > 0 && !slots)
        return DS_ERR_R(DS_ERR_INVAL, "schema_register: NULL slots");
    if (engine->schema_count >= UINT16_MAX)
        return DS_ERR_R(DS_ERR_OVERFLOW, "schema_register: too many schemas");

    const char *iname;
    ds_result_t r = ds_rete_intern_cstr(engine->intern, name, &iname);
    if (r.status != DS_OK) return r;

    if (name_map_lookup(engine, iname))
        return DS_ERR_R(DS_ERR_STATE, "schema already registered");

    ds_rete_schema_t *s = DS_CALLOC(1, sizeof(*s));
    if (!s) return DS_ERR_R(DS_ERR_OOM, "schema alloc");

    if (slot_count > 0) {
        s->slots = DS_CALLOC(slot_count, sizeof(ds_rete_slot_desc_t));
        if (!s->slots) { DS_FREE(s); return DS_ERR_R(DS_ERR_OOM, "slot alloc"); }
        for (uint16_t i = 0; i < slot_count; i++) {
            s->slots[i] = slots[i];
            const char *isl;
            r = ds_rete_intern_cstr(engine->intern, slots[i].name, &isl);
            if (r.status != DS_OK) {
                DS_FREE(s->slots); DS_FREE(s); return r;
            }
            s->slots[i].name  = isl;
            s->slots[i].index = i;
        }
    }

    s->name           = iname;
    s->id             = (uint16_t)engine->schema_count;
    s->slot_count     = slot_count;
    s->scope          = scope;
    s->default_ttl_ns = default_ttl_ns;
    /* [LERR.9.4], [LERR.9.10]: by name, whose facts never count against
       working-memory capacity. */
    s->fault_fact = strcmp(iname, "ComputationError") == 0
                 || strcmp(iname, "TypeError") == 0;
    /* [LTIM.10.6]: the slot count keeps a hand-built schema of the name and
       another shape from being read as zone rows. */
    s->tz_offset = strcmp(iname, "TimeZoneOffset") == 0 && slot_count == 4;

    /* LFAC.1.7: the identity key tuple, in declaration order. */
    s->id_key_count = 0;
    s->id_key_slots = NULL;
    uint16_t nkey = 0, nmarked = 0;
    for (uint16_t i = 0; i < slot_count; i++) {
        if (s->slots[i].is_key)    nkey++;
        if (s->slots[i].is_marked) nmarked++;
    }
    if (nkey > 0) {
        s->id_key_slots = DS_CALLOC(nkey, sizeof(*s->id_key_slots));
        if (!s->id_key_slots) {
            DS_FREE(s->slots); DS_FREE(s);
            return DS_ERR_R(DS_ERR_OOM, "id_key_slots alloc");
        }
        uint16_t k = 0;
        for (uint16_t i = 0; i < slot_count; i++)
            if (s->slots[i].is_key) s->id_key_slots[k++] = i;
        s->id_key_count = nkey;
    }
    /* Not gated on LOGICAL scope: the compiler emits it for plain `explicit`
       schemas too, whose slots carry no role markers and whose facts accumulate. */
    s->id_dedup = (nmarked > 0) || (nkey > 0) ||
                  scope == DS_RETE_SCOPE_AMBIENT;

    ds_rete_schema_id_map_init(s);

    r = by_id_ensure(engine, engine->schema_count + 1);
    if (r.status != DS_OK) {
        DS_FREE(s->slots); DS_FREE(s); return r;
    }
    engine->schemas_by_id[engine->schema_count] = s;
    engine->schema_count++;

    r = name_map_insert(engine, s);
    if (r.status != DS_OK) {
        engine->schema_count--;
        engine->schemas_by_id[engine->schema_count] = NULL;
        DS_FREE(s->slots); DS_FREE(s);
        return r;
    }

    if (out) *out = s;
    return DS_OK_R;
}

const ds_rete_schema_t *ds_rete_schema_by_id(const ds_rete_engine_t *engine,
                                              uint16_t                id)
{
    if (!engine || id >= engine->schema_count) return NULL;
    return engine->schemas_by_id[id];
}

const ds_rete_schema_t *ds_rete_schema_by_name(const ds_rete_engine_t *engine,
                                                const char             *name)
{
    if (!engine || !name) return NULL;
    return ds_rete_schema_by_name_n(engine, name, strlen(name));
}

const ds_rete_schema_t *ds_rete_schema_by_name_n(const ds_rete_engine_t *engine,
                                                  const char             *name,
                                                  size_t                  len)
{
    if (!engine || !name) return NULL;
    const char *iname;
    ds_result_t r = ds_rete_intern(
        (ds_rete_intern_t *)engine->intern, name, len, &iname);
    if (r.status != DS_OK) return NULL;
    return name_map_lookup(engine, iname);
}

ds_result_t ds_rete_schemas_clone(ds_rete_clone_ctx_t *cx,
                                  const ds_rete_engine_t *src,
                                  ds_rete_engine_t *dst)
{
    (void) cx;
    for (size_t i = 0; i < src->schema_count; i++) {
        const ds_rete_schema_t *s = src->schemas_by_id[i];
        ds_rete_schema_t *out = NULL;
        ds_result_t r = ds_rete_schema_register(
            dst, s->name, s->scope, s->default_ttl_ns,
            (ds_rete_slot_desc_t *) s->slots, s->slot_count, &out);
        if (r.status != DS_OK) return r;
    }
    return DS_OK_R;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * schema.c — schema types and the per-engine registry.
 */
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"
#include "ds_text.h"

#include "engine.h"
#include "schema.h"
#include "telemetry.h"


#define SCHEMA_REG_INITIAL_CAP 8

/* ds_schema_new with none of its checks, for the clone: what it copies came from a
   load, which trusts the artefact ([RDSC.9.9]) and may not meet those rules. */
static ds_result_t schema_alloc(const char            *type_name,
                                ds_schema_lifecycle_t  lifecycle,
                                uint64_t               ttl_ns,
                                const ds_slot_desc_t  *slots,
                                uint32_t               n_slots,
                                struct ds_schema     **out)
{
    struct ds_schema *s = DS_CALLOC(1, sizeof(*s));
    if (s == NULL) {
        return DS_ERR_R(DS_ERR_OOM, "schema allocation failed");
    }

    if (n_slots > 0) {
        s->slots = DS_CALLOC(n_slots, sizeof(*s->slots));
        if (s->slots == NULL) {
            DS_FREE(s);
            return DS_ERR_R(DS_ERR_OOM, "schema slots allocation failed");
        }
        memcpy(s->slots, slots, (size_t) n_slots * sizeof(*slots));
    }

    s->type_name = type_name;
    s->lifecycle = lifecycle;
    s->ttl_ns    = ttl_ns;
    s->n_slots   = n_slots;

    *out = s;
    return DS_OK_R;
}

ds_result_t ds_schema_new(const char            *type_name,
                          ds_schema_lifecycle_t  lifecycle,
                          uint64_t               ttl_ns,
                          const ds_slot_desc_t  *slots,
                          uint32_t               n_slots,
                          struct ds_schema     **out)
{
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = NULL;

    if (type_name == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "type_name must not be null");
    }
    if (lifecycle != DS_SCHEMA_LIFECYCLE_LOGICAL &&
        lifecycle != DS_SCHEMA_LIFECYCLE_TTL) {
        return DS_ERR_R(DS_ERR_INVAL, "invalid schema lifecycle");
    }
    if (lifecycle == DS_SCHEMA_LIFECYCLE_TTL && ttl_ns == 0) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "TTL schema requires ttl_ns > 0");
    }
    if (lifecycle == DS_SCHEMA_LIFECYCLE_LOGICAL && ttl_ns != 0) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "LOGICAL schema must have ttl_ns == 0");
    }
    if (n_slots > 0 && slots == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "slots is null but n_slots > 0");
    }

    if (n_slots > (1u << 20)) {
        return DS_ERR_R(DS_ERR_INVAL, "n_slots exceeds 1M ceiling");
    }

    for (uint32_t i = 0; i < n_slots; i++) {
        const ds_slot_desc_t *sd = &slots[i];
        if (sd->name == NULL) {
            return DS_ERR_R(DS_ERR_INVAL, "slot name must not be null");
        }
        switch (sd->type) {
        case DS_SLOT_TYPE_INT:
        case DS_SLOT_TYPE_FLOAT:
        case DS_SLOT_TYPE_STRING:
        case DS_SLOT_TYPE_BOOL:
        case DS_SLOT_TYPE_JSON:
        case DS_SLOT_TYPE_BYTES:
        case DS_SLOT_TYPE_TIME:
        case DS_SLOT_TYPE_DATE:
        case DS_SLOT_TYPE_DURATION:
            if (sd->schema_ref != NULL) {
                return DS_ERR_R(DS_ERR_INVAL,
                                "schema_ref non-null on non-schema slot");
            }
            break;
        case DS_SLOT_TYPE_SCHEMA:
            if (sd->schema_ref == NULL) {
                return DS_ERR_R(DS_ERR_INVAL,
                                "schema_ref must be non-null on schema slot");
            }
            break;
        default:
            return DS_ERR_R(DS_ERR_INVAL, "unknown slot type");
        }
        if (sd->has_tolerance) {
            if (sd->type != DS_SLOT_TYPE_INT && sd->type != DS_SLOT_TYPE_FLOAT) {
                return DS_ERR_R(DS_ERR_INVAL,
                                "tolerance only legal on numeric slots");
            }
            if (sd->tolerance < 0.0) {
                return DS_ERR_R(DS_ERR_INVAL,
                                "tolerance must be non-negative");
            }
            if (lifecycle != DS_SCHEMA_LIFECYCLE_LOGICAL) {
                return DS_ERR_R(DS_ERR_INVAL,
                                "tolerance only legal on logical-schema slots");
            }
            /* [NFCT.1.4.4]. Last, so a ttl schema's tolerance is refused above,
               where its slots carry no role. */
            if (sd->identity_role != DS_IDENTITY_MUTABLE) {
                return DS_ERR_R(DS_ERR_INVAL,
                                "tolerance only legal on a MUTABLE slot "
                                "(NFCT.1.4.4)");
            }
        }
    }

    return schema_alloc(type_name, lifecycle, ttl_ns, slots, n_slots, out);
}

ds_result_t ds_schema_free(struct ds_schema *schema)
{
    if (schema == NULL) {
        return DS_OK_R;
    }
    DS_FREE(schema->slots);
    DS_FREE(schema->src_file);
    DS_FREE(schema->proto_source);
    for (size_t i = 0; i < schema->n_owned_strings; i++) {
        DS_FREE(schema->owned_strings[i]);
    }
    DS_FREE(schema->owned_strings);
    DS_FREE(schema);
    return DS_OK_R;
}

ds_result_t ds_schema_take_string(struct ds_schema *schema, char *s)
{
    if (schema == NULL || s == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds_schema_take_string: NULL arg");
    }
    size_t cap = schema->n_owned_strings;
    char **na = DS_REALLOC(schema->owned_strings,
                        (cap + 1) * sizeof(*na));
    if (na == NULL) {
        return DS_ERR_R(DS_ERR_OOM,
                        "ds_schema_take_string: realloc failed");
    }
    na[cap] = s;
    schema->owned_strings   = na;
    schema->n_owned_strings = cap + 1;
    return DS_OK_R;
}

static uint32_t sreg_hash(const char *s)
{
    uint32_t h = 2166136261u;
    for (; *s; s++) { h ^= (uint8_t)*s; h *= 16777619u; }
    return h;
}

#define SREG_MAP_MAX_LOAD 70u

/* [RDSC.9.8]. The new table is built before the old one is freed, so DS_ERR_OOM leaves
   the index as it was. */
static ds_result_t schema_reg_map_rebuild(ds_schema_registry_t *reg)
{
    size_t n   = reg->n_schemas;
    size_t cap = 8;
    while (cap * SREG_MAP_MAX_LOAD / 100 < n) cap <<= 1;

    struct ds_sreg_map_entry *map = DS_CALLOC(cap, sizeof(*map));
    if (map == NULL)
        return DS_ERR_R(DS_ERR_OOM,
                        "schema registry: the name index could not be built");

    for (size_t i = 0; i < n; i++) {
        const char *nm = reg->schemas[i]->type_name;
        uint32_t h = sreg_hash(nm) & (uint32_t)(cap - 1);
        while (map[h].name)
            h = (h + 1) & (uint32_t)(cap - 1);
        map[h].name   = nm;
        map[h].schema = reg->schemas[i];
    }
    DS_FREE(reg->name_map);
    reg->name_map     = map;
    reg->name_map_cap = cap;
    return DS_OK_R;
}

ds_result_t ds_schema_registry_init(ds_schema_registry_t *reg,
                                    struct ds_engine     *engine)
{
    if (reg == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "reg must not be null");
    }
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    reg->engine = engine;
    reg->schemas = DS_CALLOC(SCHEMA_REG_INITIAL_CAP, sizeof(*reg->schemas));
    if (reg->schemas == NULL) {
        return DS_ERR_R(DS_ERR_OOM, "schema registry allocation failed");
    }
    reg->n_schemas   = 0;
    reg->cap_schemas = SCHEMA_REG_INITIAL_CAP;
    return DS_OK_R;
}

ds_result_t ds_schema_registry_destroy(ds_schema_registry_t *reg)
{
    if (reg == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "reg must not be null");
    }
    for (size_t i = 0; i < reg->n_schemas; i++) {
        ds_schema_free(reg->schemas[i]);
    }
    DS_FREE(reg->schemas);
    reg->schemas     = NULL;
    reg->n_schemas   = 0;
    reg->cap_schemas = 0;
    DS_FREE(reg->name_map);
    reg->name_map     = NULL;
    reg->name_map_cap = 0;
    return DS_OK_R;
}

static ds_result_t registry_reserve_one(ds_schema_registry_t *reg)
{
    if (reg->n_schemas < reg->cap_schemas) {
        return DS_OK_R;
    }
    size_t new_cap = reg->cap_schemas > 0 ? reg->cap_schemas * 2 : 4;
    struct ds_schema **new_arr = DS_REALLOC(reg->schemas, new_cap * sizeof(*new_arr));
    if (new_arr == NULL) {
        return DS_ERR_R(DS_ERR_OOM, "schema registry growth failed");
    }
    memset(new_arr + reg->cap_schemas, 0,
           (new_cap - reg->cap_schemas) * sizeof(*new_arr));
    reg->schemas     = new_arr;
    reg->cap_schemas = new_cap;
    return DS_OK_R;
}

ds_result_t ds_schema_registry_add(ds_schema_registry_t *reg,
                                   struct ds_schema     *schema)
{
    if (reg == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "reg must not be null");
    }
    if (schema == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "schema must not be null");
    }

    /* strcmp: strings may not be interned yet. A registry with no map holds no schema. */
    if (reg->name_map && reg->name_map_cap) {
        uint32_t cap = (uint32_t)reg->name_map_cap;
        uint32_t h   = sreg_hash(schema->type_name) & (cap - 1);
        for (;;) {
            const struct ds_sreg_map_entry *e = &reg->name_map[h];
            if (!e->name) break;
            if (strcmp(e->name, schema->type_name) == 0) {
                ds_log_event_t ev = {
                    .level = DS_LOG_WARNING,
                    .category = "schema",
                    .message = "duplicate schema registration attempt rejected",
                };
                ds_telemetry_emit_log(reg->engine, &ev);
                return DS_ERR_R(DS_ERR_STATE,
                                "schema type_name already registered");
            }
            h = (h + 1) & (cap - 1);
        }
    }

    ds_result_t r = registry_reserve_one(reg);
    if (r.status != DS_OK) return r;

    reg->schemas[reg->n_schemas++] = schema;

    /* name_map and name_map_cap are set together, but the analyser cannot see an
       invariant across two fields: the division needs one tested, name_map[h] the other. */
    if (!reg->name_map || !reg->name_map_cap ||
        reg->n_schemas * 100u / reg->name_map_cap >= SREG_MAP_MAX_LOAD) {
        r = schema_reg_map_rebuild(reg);
        if (r.status != DS_OK) {
            /* [RDSC.9.8]: undone, and the caller still owns the schema. */
            reg->schemas[--reg->n_schemas] = NULL;
            return r;
        }
    } else {
        uint32_t cap = (uint32_t)reg->name_map_cap;
        uint32_t h   = sreg_hash(schema->type_name) & (cap - 1);
        while (reg->name_map[h].name)
            h = (h + 1) & (cap - 1);
        reg->name_map[h].name   = schema->type_name;
        reg->name_map[h].schema = schema;
    }
    schema->engine = reg->engine;
    return DS_OK_R;
}

ds_result_t ds_schema_registry_find(const ds_schema_registry_t *reg,
                                    const char                  *type_name,
                                    const struct ds_schema    **out)
{
    if (reg == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "reg must not be null");
    }
    if (type_name == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "type_name must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }

    *out = NULL;
    if (reg->name_map == NULL || reg->name_map_cap == 0) return DS_OK_R;
    uint32_t cap = (uint32_t)reg->name_map_cap;
    uint32_t h   = sreg_hash(type_name) & (cap - 1);
    for (;;) {
        const struct ds_sreg_map_entry *e = &reg->name_map[h];
        if (!e->name) return DS_OK_R;
        if (strcmp(e->name, type_name) == 0) { *out = e->schema; return DS_OK_R; }
        h = (h + 1) & (cap - 1);
    }
}

ds_result_t ds_schema_registry_count(const ds_schema_registry_t *reg,
                                     size_t                      *out)
{
    if (reg == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "reg must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = reg->n_schemas;
    return DS_OK_R;
}

ds_result_t ds_schema_registry_at(const ds_schema_registry_t *reg,
                                  size_t                       index,
                                  const struct ds_schema    **out)
{
    if (reg == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "reg must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    if (index >= reg->n_schemas) {
        *out = NULL;
        return DS_ERR_R(DS_ERR_NOT_FOUND, "schema index out of range");
    }
    *out = reg->schemas[index];
    return DS_OK_R;
}

ds_result_t ds_engine_schema_count(ds_engine_t *engine, size_t *out)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    return ds_schema_registry_count(&engine->schemas, out);
}

ds_result_t ds_engine_schema_find(ds_engine_t       *engine,
                                  const char         *type_name,
                                  const ds_schema_t **out)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    return ds_schema_registry_find(&engine->schemas, type_name, out);
}

#define ARG_NULL_CHECK(p) do { \
    if ((p) == NULL) return DS_ERR_R(DS_ERR_INVAL, "NULL arg"); \
} while (0)

/* [NCBK.2.9]. A NULL schema names no engine; its `_unchecked` body refuses it. */
#define DS_SCHEMA_HANDLE_GUARD(schema)                                      \
    do {                                                                    \
        if ((schema) != NULL) DS_HANDLE_REFUSE_IF_HALTED((schema)->engine); \
    } while (0)

ds_result_t ds_schema_get_name_unchecked(const ds_schema_t  *schema,
                                          const char        **out)
{
    ARG_NULL_CHECK(schema); ARG_NULL_CHECK(out);
    *out = schema->type_name;
    return DS_OK_R;
}

ds_result_t ds_schema_get_lifecycle_unchecked(const ds_schema_t      *schema,
                                               ds_schema_lifecycle_t *out)
{
    ARG_NULL_CHECK(schema); ARG_NULL_CHECK(out);
    *out = schema->internal ? DS_SCHEMA_LIFECYCLE_INTERNAL : schema->lifecycle;
    return DS_OK_R;
}

ds_result_t ds_schema_get_ttl_ns_unchecked(const ds_schema_t *schema,
                                            uint64_t          *out)
{
    ARG_NULL_CHECK(schema); ARG_NULL_CHECK(out);
    *out = schema->ttl_ns;
    return DS_OK_R;
}

ds_result_t ds_schema_get_slot_count_unchecked(const ds_schema_t *schema,
                                                uint32_t          *out)
{
    ARG_NULL_CHECK(schema); ARG_NULL_CHECK(out);
    *out = schema->n_slots;
    return DS_OK_R;
}

ds_result_t ds_schema_get_slot_unchecked(const ds_schema_t *schema,
                                          uint32_t           idx,
                                          ds_slot_desc_t    *out)
{
    ARG_NULL_CHECK(schema); ARG_NULL_CHECK(out);
    if (idx >= schema->n_slots) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "slot index out of range");
    }
    *out = schema->slots[idx];
    return DS_OK_R;
}

ds_result_t ds_schema_get_source_unchecked(const ds_schema_t  *schema,
                                            const char        **out_file,
                                            uint32_t           *out_line,
                                            uint32_t           *out_col)
{
    ARG_NULL_CHECK(schema);
    if (out_file != NULL) *out_file = schema->src_file;
    if (out_line != NULL) *out_line = schema->src_line;
    if (out_col  != NULL) *out_col  = schema->src_col;
    return DS_OK_R;
}

ds_result_t ds_schema_get_proto_source_unchecked(const ds_schema_t  *schema,
                                                  const char        **out_text,
                                                  size_t             *out_len)
{
    ARG_NULL_CHECK(schema);
    if (out_text != NULL) *out_text = schema->proto_source;
    if (out_len  != NULL) *out_len  = schema->proto_source_len;
    return DS_OK_R;
}

ds_result_t ds_schema_get_name(const ds_schema_t  *schema, const char **out)
{
    DS_SCHEMA_HANDLE_GUARD(schema);
    return ds_schema_get_name_unchecked(schema, out);
}

ds_result_t ds_schema_get_lifecycle(const ds_schema_t      *schema,
                                     ds_schema_lifecycle_t *out)
{
    DS_SCHEMA_HANDLE_GUARD(schema);
    return ds_schema_get_lifecycle_unchecked(schema, out);
}

ds_result_t ds_schema_get_ttl_ns(const ds_schema_t *schema, uint64_t *out)
{
    DS_SCHEMA_HANDLE_GUARD(schema);
    return ds_schema_get_ttl_ns_unchecked(schema, out);
}

ds_result_t ds_schema_get_slot_count(const ds_schema_t *schema, uint32_t *out)
{
    DS_SCHEMA_HANDLE_GUARD(schema);
    return ds_schema_get_slot_count_unchecked(schema, out);
}

ds_result_t ds_schema_get_slot(const ds_schema_t *schema, uint32_t idx,
                                ds_slot_desc_t *out)
{
    DS_SCHEMA_HANDLE_GUARD(schema);
    return ds_schema_get_slot_unchecked(schema, idx, out);
}

ds_result_t ds_schema_get_source(const ds_schema_t  *schema,
                                  const char        **out_file,
                                  uint32_t           *out_line,
                                  uint32_t           *out_col)
{
    DS_SCHEMA_HANDLE_GUARD(schema);
    return ds_schema_get_source_unchecked(schema, out_file, out_line, out_col);
}

ds_result_t ds_schema_get_proto_source(const ds_schema_t  *schema,
                                        const char        **out_text,
                                        size_t             *out_len)
{
    DS_SCHEMA_HANDLE_GUARD(schema);
    return ds_schema_get_proto_source_unchecked(schema, out_text, out_len);
}

ds_result_t ds_engine_schema_at(ds_engine_t       *engine,
                                 size_t              index,
                                 const ds_schema_t **out)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    return ds_schema_registry_at(&engine->schemas, index, out);
}

/* Defined in engine_rete_adapters.c, which sees the whole ds_engine. */
ds_result_t ds_engine_register_schema_in_rete(ds_engine_t           *engine,
                                               const char            *type_name,
                                               ds_schema_lifecycle_t  lifecycle,
                                               uint64_t               ttl_ns,
                                               const ds_slot_desc_t  *slots,
                                               uint32_t               n_slots);

static const char *sched_dup_owned(ds_schema_t *s, const char *src, bool *oom);

/* From rete/engine.h, whose includes need the libds directory on the include path,
   which schema.c is compiled without. */
struct ds_rete_engine;
ds_text_t   ds_rete_engine_detail(struct ds_rete_engine *engine);
const char *ds_rete_engine_detail_text(const ds_text_t *t, const char *fallback);

/* [NFCT.1.4.3], [LFAC.9.1], [RDSC.5.5.7]. */
static ds_result_t nfct_1_4_3_engine_role(ds_engine_t           *engine,
                                          ds_schema_lifecycle_t  lifecycle,
                                          const ds_slot_desc_t  *slots,
                                          uint32_t               n_slots)
{
    for (uint32_t i = 0; slots != NULL && i < n_slots; i++) {
        const ds_slot_desc_t *sd = &slots[i];
        if (sd->name == NULL) continue;     /* ds_schema_new refuses it */
        const bool is_ts = strcmp(sd->name, "ts") == 0;
        const char *why = NULL;
        if (sd->identity_role == DS_IDENTITY_ENGINE) {
            if (!is_ts)
                why = "DS_IDENTITY_ENGINE belongs to the slot named `ts` alone";
            else if (lifecycle != DS_SCHEMA_LIFECYCLE_LOGICAL)
                why = "DS_IDENTITY_ENGINE is legal only on a logical schema";
            else if (sd->type != DS_SLOT_TYPE_TIME || sd->nullable)
                why = "DS_IDENTITY_ENGINE needs `ts` to be a non-nullable "
                      "DS_SLOT_TYPE_TIME";
        } else if (is_ts && lifecycle == DS_SCHEMA_LIFECYCLE_LOGICAL &&
                   (sd->identity_role == DS_IDENTITY_KEY ||
                    sd->identity_role == DS_IDENTITY_MUTABLE)) {
            why = "`ts` of a logical schema takes DS_IDENTITY_ENGINE, not "
                  "DS_IDENTITY_KEY or DS_IDENTITY_MUTABLE";
        }
        if (why != NULL) {
            ds_text_t d = ds_rete_engine_detail(engine->rete_engine);
            ds_text_str(&d, "register_schema: slot `");
            ds_text_str(&d, sd->name);
            ds_text_str(&d, "`: ");
            ds_text_str(&d, why);
            ds_text_str(&d, " ([NFCT.1.4.3])");
            return DS_ERR_R(DS_ERR_INVAL,
                            ds_rete_engine_detail_text(&d,
                                "register_schema: DS_IDENTITY_ENGINE belongs "
                                "to a logical schema's non-nullable Time `ts` "
                                "alone ([NFCT.1.4.3])"));
        }
    }
    return DS_OK_R;
}

/* Declared in engine.h, for libds's own unit tests: a schema reaches an integrator's
   engine only from an artefact ([NFCT.1.1]). */
ds_result_t ds_engine_register_schema(ds_engine_t           *engine,
                                       const char            *type_name,
                                       ds_schema_lifecycle_t  lifecycle,
                                       uint64_t               ttl_ns,
                                       const ds_slot_desc_t  *slots,
                                       uint32_t               n_slots,
                                       const ds_schema_t    **out_schema)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (out_schema != NULL) *out_schema = NULL;

    /* The structural intern set freezes at the first pump, and registering pins names
       in it: past that, the intern refuses a new one ([IERR.1.7]). */
    if (engine->has_pumped) {
        return DS_ERR_R(DS_ERR_STATE,
                        "register_schema: not permitted after the first pump "
                        "(the structural intern set is frozen)");
    }

    /* [NFCT.1.1]. A host assert or retract emits an event before any pump, and a pump
       may dispatch none, so neither guard covers the other. */
    if (engine->next_seq > 0) {
        return DS_ERR_R(DS_ERR_STATE,
                        "register_schema: not permitted after the engine's "
                        "first stream event (NFCT.1.1)");
    }

    if (lifecycle == DS_SCHEMA_LIFECYCLE_LOGICAL && slots != NULL) {
        for (uint32_t i = 0; i < n_slots; i++) {
            if (slots[i].identity_role == DS_IDENTITY_UNSPECIFIED) {
                return DS_ERR_R(DS_ERR_INVAL,
                    "register_schema: every slot of a logical schema must set "
                    "identity_role -- DS_IDENTITY_KEY or DS_IDENTITY_MUTABLE, "
                    "and DS_IDENTITY_ENGINE on `ts` -- per LFAC.1.7 require-all "
                    "and LFAC.9.1");
            }
        }
    }

    ds_result_t role_r = nfct_1_4_3_engine_role(engine, lifecycle, slots, n_slots);
    if (role_r.status != DS_OK) return role_r;

    ds_schema_t *s = NULL;
    ds_result_t r = ds_schema_new(type_name, lifecycle, ttl_ns,
                                   slots, n_slots, &s);
    if (r.status != DS_OK) return r;

    /* [NFCT.1.2], [NFCT.1.4.1]: the caller may free its strings when this returns. */
    bool oom = false;
    s->type_name = sched_dup_owned(s, type_name, &oom);
    for (uint32_t i = 0; i < s->n_slots && !oom; i++) {
        s->slots[i].name      = sched_dup_owned(s, slots[i].name, &oom);
        s->slots[i].docstring = sched_dup_owned(s, slots[i].docstring, &oom);
    }
    if (oom) {
        ds_schema_free(s);
        return DS_ERR_R(DS_ERR_OOM, "register_schema: copying the names failed");
    }

    r = ds_schema_registry_add(&engine->schemas, s);
    if (r.status != DS_OK) {
        ds_schema_free(s);
        return r;
    }

    (void)ds_engine_register_schema_in_rete(engine, s->type_name, lifecycle,
                                            ttl_ns, s->slots, s->n_slots);

    if (out_schema != NULL) *out_schema = s;
    return DS_OK_R;
}

static const char *sched_dup_owned(ds_schema_t *s, const char *src, bool *oom)
{
    if (src == NULL) return NULL;
    char *d = DS_STRDUP(src);
    if (d == NULL) { *oom = true; return NULL; }
    if (ds_schema_take_string(s, d).status != DS_OK) { DS_FREE(d); *oom = true; return NULL; }
    return d;
}

ds_result_t ds_schema_registry_clone(const ds_schema_registry_t *src,
                                     ds_schema_registry_t       *dst)
{
    for (size_t i = 0; i < src->n_schemas; i++) {
        const ds_schema_t *ss = src->schemas[i];
        ds_schema_t *cs = NULL;
        ds_result_t r = schema_alloc(ss->type_name, ss->lifecycle, ss->ttl_ns,
                                     ss->slots, ss->n_slots, &cs);
        if (r.status != DS_OK) return r;

        bool oom = false;
        cs->type_name = sched_dup_owned(cs, ss->type_name, &oom);
        for (uint32_t j = 0; j < cs->n_slots && !oom; j++) {
            cs->slots[j].name      = sched_dup_owned(cs, ss->slots[j].name, &oom);
            cs->slots[j].docstring = sched_dup_owned(cs, ss->slots[j].docstring, &oom);
            /* schema_ref is remapped below, once every target is registered. */
        }
        if (!oom && ss->src_file) {
            cs->src_file = DS_STRDUP(ss->src_file);
            if (!cs->src_file) oom = true;
        }
        cs->src_line = ss->src_line;
        cs->src_col  = ss->src_col;
        cs->internal = ss->internal;
        cs->call_response = ss->call_response;
        if (!oom && ss->proto_source && ss->proto_source_len > 0) {
            cs->proto_source = DS_MALLOC(ss->proto_source_len + 1);
            if (!cs->proto_source) oom = true;
            else {
                memcpy(cs->proto_source, ss->proto_source, ss->proto_source_len);
                cs->proto_source[ss->proto_source_len] = '\0';
                cs->proto_source_len = ss->proto_source_len;
            }
        }
        if (oom) { ds_schema_free(cs); return DS_ERR_R(DS_ERR_OOM, "schema_registry_clone: dup"); }

        r = ds_schema_registry_add(dst, cs);
        if (r.status != DS_OK) { ds_schema_free(cs); return r; }
    }

    for (size_t i = 0; i < src->n_schemas; i++) {
        const ds_schema_t *ss = src->schemas[i];
        const ds_schema_t *cs = NULL;
        ds_schema_registry_find(dst, ss->type_name, &cs);
        if (cs == NULL) continue;
        ds_schema_t *csm = (ds_schema_t *) cs;
        for (uint32_t j = 0; j < ss->n_slots; j++) {
            if (ss->slots[j].type == DS_SLOT_TYPE_SCHEMA && ss->slots[j].schema_ref) {
                const ds_schema_t *tgt = NULL;
                ds_schema_registry_find(dst, ss->slots[j].schema_ref->type_name, &tgt);
                csm->slots[j].schema_ref = tgt;
            }
        }
    }
    return DS_OK_R;
}

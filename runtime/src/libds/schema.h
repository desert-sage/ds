/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * schema.h — internal schema types and the engine's registry ([IDAT.5]).
 */
#ifndef LIBDS2_INTERNAL_SCHEMA_H
#define LIBDS2_INTERNAL_SCHEMA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"

struct ds_schema;

struct ds_schema {
    const char            *type_name;  /* borrow; typically interned */
    ds_schema_lifecycle_t  lifecycle;
    bool                   internal;   /* [LSCP.2.6.2]: reported as
                                          DS_SCHEMA_LIFECYCLE_INTERNAL, never
                                          stored in `lifecycle`, which wm.c
                                          reads */
    bool                   call_response; /* a `service`'s `response`
                                          ([LADP.8.4.2]). A host assert of one
                                          supersedes the live answers with its
                                          `corr` ([LCRS.6.2.4]) */
    uint64_t               ttl_ns;     /* 0 for LOGICAL */
    uint32_t               n_slots;
    ds_slot_desc_t        *slots;      /* owned; copy of the caller's array */
    /* From the DSC loader; NULL and 0 for a schema registered programmatically.
       src_file is owned. */
    char                  *src_file;
    uint32_t               src_line;
    uint32_t               src_col;
    char                  *proto_source;   /* owned; NULL when absent */
    size_t                 proto_source_len;
    /* The names a load, a registration or a clone copied in. */
    char                 **owned_strings;
    size_t                 n_owned_strings;
    /* Threaded via ds_fact.schema_prev/next. */
    struct ds_fact        *fact_list_head;
    /* Non-owning: the schema is freed with its engine. NULL for a schema in no
       registry. The public accessors read its halt latch ([NCBK.2.9]). */
    struct ds_engine      *engine;
};

/* On success the schema owns s. */
ds_result_t ds_schema_take_string(struct ds_schema *schema, char *s);

/*
 * The slot array is copied. The slot string pointers (name, docstring) are not:
 * they must live as long as the schema.
 *
 * `ttl_ns` is > 0 for DS_SCHEMA_LIFECYCLE_TTL and 0 for LOGICAL, else DS_ERR_INVAL.
 *
 * *out is owning: transfer it with ds_schema_registry_add, or ds_schema_free it.
 */
ds_result_t ds_schema_new(const char            *type_name,
                          ds_schema_lifecycle_t  lifecycle,
                          uint64_t               ttl_ns,
                          const ds_slot_desc_t  *slots,
                          uint32_t               n_slots,
                          struct ds_schema     **out);

/* Safe on NULL. */
ds_result_t ds_schema_free(struct ds_schema *schema);

typedef struct ds_schema_registry {
    struct ds_engine  *engine;      /* non-owning */
    struct ds_schema **schemas;     /* owned; entries are owning ptrs */
    size_t             n_schemas;
    size_t             cap_schemas;
    /* Open-addressing FNV-1a, power-of-two cap. */
    struct ds_sreg_map_entry {
        const char       *name; /* NULL = empty slot */
        struct ds_schema *schema;
    }                 *name_map;
    size_t             name_map_cap;
} ds_schema_registry_t;

ds_result_t ds_schema_registry_init(ds_schema_registry_t *reg,
                                    struct ds_engine     *engine);

ds_result_t ds_schema_registry_destroy(ds_schema_registry_t *reg);

/* Takes ownership on success. DS_ERR_STATE for a type_name already registered,
   and the caller keeps ownership. */
ds_result_t ds_schema_registry_add(ds_schema_registry_t *reg,
                                   struct ds_schema     *schema);

/* DS_OK either way: *out is borrowed, or NULL if not registered. */
ds_result_t ds_schema_registry_find(const ds_schema_registry_t *reg,
                                    const char                  *type_name,
                                    const struct ds_schema    **out);

ds_result_t ds_schema_registry_count(const ds_schema_registry_t *reg,
                                     size_t                      *out);

ds_result_t ds_schema_registry_at(const ds_schema_registry_t *reg,
                                  size_t                       index,
                                  const struct ds_schema    **out);

/* dst is freshly initialised and empty. No pointer is shared with src, so the two
   engines free in any order ([NLFC.8.1]). */
ds_result_t ds_schema_registry_clone(const ds_schema_registry_t *src,
                                     ds_schema_registry_t       *dst);

/* For libds's own reads: each is its public namesake less the halt-latch check
   ([NCBK.2.9]). */
ds_result_t ds_schema_get_name_unchecked(const struct ds_schema *schema,
                                          const char            **out);
ds_result_t ds_schema_get_lifecycle_unchecked(const struct ds_schema *schema,
                                               ds_schema_lifecycle_t  *out);
ds_result_t ds_schema_get_ttl_ns_unchecked(const struct ds_schema *schema,
                                            uint64_t               *out);
ds_result_t ds_schema_get_slot_count_unchecked(const struct ds_schema *schema,
                                                uint32_t               *out);
ds_result_t ds_schema_get_slot_unchecked(const struct ds_schema *schema,
                                          uint32_t                idx,
                                          ds_slot_desc_t         *out);
ds_result_t ds_schema_get_source_unchecked(const struct ds_schema *schema,
                                            const char            **out_file,
                                            uint32_t               *out_line,
                                            uint32_t               *out_col);
ds_result_t ds_schema_get_proto_source_unchecked(
    const struct ds_schema *schema, const char **out_text, size_t *out_len);

#endif /* LIBDS2_INTERNAL_SCHEMA_H */

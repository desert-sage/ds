/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * dsc/loader.c — loader for the .dsc compiled-artefact format.
 *
 * Two passes: the atom walk decodes every atom into a transient accumulator, and the
 * apply (dsc_apply) checks [RDSC.8.7]'s names, registers the schemas, loads the
 * network and takes the `initial` items ([LGRA.24.3]). Both commit to the engine as
 * they go: a failed load spends the engine ([RDSC.9.8]), so nothing undoes a partial
 * apply.
 *
 * Atom bodies are stored uncompressed ([RDSC.4.5]).
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


#include "libds.h"
#include "ds_alloc.h"
#include "ds_pb_alloc.h"

#include "engine.h"
#include "schema.h"
#include "telemetry.h"

#include "loader.h"
#include "version_series.h"
#include "pbf_reader.h"
#include "rete_loader.h"
#include "dsrt_loader.h"
#include "sha256.h"
#include "rete/alpha.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/fault_fact.h"
#include "rete/schema_reg.h"
#include "builtins.h"
#include "ds_re2.h"
#include "rete/val.h"
#include "header.pb-c.h"
#include "capabilities.pb-c.h"
#include "common.pb-c.h"
#include "schema_ttl.pb-c.h"
#include "schema_logical.pb-c.h"
#include "slot.pb-c.h"
#include "hydration.pb-c.h"
#include "schema_source.pb-c.h"
#include "schema_def.pb-c.h"
#include "rule_cooldown.pb-c.h"
#include "rule_debug_name.pb-c.h"
#include "rule_source.pb-c.h"
#include "ds_source.pb-c.h"
#include "line_span.pb-c.h"
#include "series_backend_welford_ewma.pb-c.h"
#include "series_backend_ring_buffer.pb-c.h"
#include "series_backend_monotonic_deque.pb-c.h"
#include "series_backend_fifo_deque.pb-c.h"
#include "series_backend_reservoir.pb-c.h"
#include "series_backend_interval_pulse.pb-c.h"
#include "series_backend_numeric_integral.pb-c.h"

/* [RDSC.9.5]: the walk adds the offset (ds_dsc_decode_at_offset). */
#define RDSC_9_5_REPEATED(atom) \
    "dsc: " atom " body holds a message field that is not repeated more " \
    "than once"

#define RDSC_9_12_BAD_STRING(atom) \
    "dsc: " atom " body holds a string field that is not well-formed UTF-8 " \
    "or holds U+0000 (RDSC.9.12)"

/* Per-slot accumulator. schema_ref_name is resolved at apply time. */
typedef struct {
    char            *slot_name;
    ds_slot_type_t   type;
    char            *schema_ref_name;   /* non-NULL iff type==SCHEMA */
    bool             hydration_eligible;
    bool             sampled;
    bool             retained;
    ds_identity_role_t identity_role;
    double           tolerance;       /* 0.0: exact */
    bool             nullable;
    uint32_t         capacity;        /* [LSTR.11.1]; 0 = none */
    /* [RDSC.5.5.9]: the Slot's conversions, detached from its unpacked body
       once judged; both or neither. Decoded onto the rete schema at apply. */
    Ds__V1__Expr    *to_stored;
    Ds__V1__Expr    *from_stored;
} dsc_slot_acc_t;

/* Per-schema accumulator, keyed by (module_id, name). A conforming compiler writes
   one schema_group per name ([RDSC.7.2.1]); the apply phase's highest module_id per
   name keeps a non-conforming artefact's load well defined. */
typedef struct {
    uint32_t        module_id;
    char           *name;
    bool            has_sttl;
    uint64_t        ttl_ns;
    bool            has_slog;
    /* [RDSC.5.4.5]: one of the three whenever has_slog. */
    Ds__V1__SchemaLifecycle lifecycle;
    /* [LSCP.2.5]: registered with the Rete engine only. */
    bool            is_ambient;
    dsc_slot_acc_t *slots;
    size_t          n_slots, cap_slots;
    bool            has_srcs;
    char           *src_file;
    uint32_t        src_line, src_col;
    bool            has_sdef;
    char           *proto_text;
    size_t          proto_text_len;
} dsc_schema_acc_t;

/* Per-rule accumulator. A second atom of one kind for one rule replaces the first. */
typedef struct {
    uint32_t  module_id;
    char     *rule_name;
    bool      has_cool;
    uint64_t  cool_window_ns;
    bool      has_srcr;
    char     *src_file;
    uint32_t  src_line, src_col;
    bool      has_dnam;
    char     *debug_name_template;  /* owned; set iff has_dnam */
} dsc_rule_acc_t;

/* Top-level loader state. Each source file has its own module group ([RDSC.8.1],
   [RDSC.8.6]). */
typedef struct {
    bool              saw_dsco;
    bool              saw_capb;

    /* [RDSC.3.6]: borrowed for the self-hash check. The header's tuple is kept for
       the session header ([RBND.3.1]). */
    const uint8_t    *data;
    size_t            len;
    uint8_t           header_sha256[32];
    uint8_t           header_def_sha256[32];
    uint32_t          header_caps[DS_BINDING_CAPABILITIES_MAX];
    size_t            n_header_caps;

    dsc_schema_acc_t *schemas;
    size_t            n_schemas, cap_schemas;
    dsc_rule_acc_t   *rules;
    size_t            n_rules, cap_rules;

    /* Series backend atoms ([RDSC.5a]). */
    struct {
        uint32_t atom_field;
        uint32_t module_id;
        char    *schema_name;
        char    *slot_name;
        char    *identity_slot_name;  /* "" for `by: none` */
        uint64_t window_ns;
        uint64_t persist_ns;
        uint32_t element_type;        /* SeriesBackendRingBuffer only */
        uint32_t max_samples;         /* SeriesBackendRingBuffer only */
        uint32_t time_model;          /* SeriesBackendNumericIntegral only */
        uint32_t gap_policy;          /* SeriesBackendNumericIntegral only */
        uint32_t null_policy;
    } *series_decls;
    size_t n_series_decls, cap_series_decls;

    /* Network atoms ([RDSC.4a]), raw bodies decoded in the apply phase. */
    struct {
        uint8_t *body;
        size_t   len;
        size_t   offset;   /* the frame's start */
    } *alfa_atoms, *beta_atoms, *term_atoms;
    size_t n_alfa_atoms, n_beta_atoms, n_term_atoms;
    size_t cap_alfa_atoms, cap_beta_atoms, cap_term_atoms;

    /* Source preservation ([RDSC.14]). */
    struct {
        uint32_t module_id;
        char    *file;
        char    *text;
        size_t   text_len;
    } *ds_sources;
    size_t n_ds_sources, cap_ds_sources;
    struct {
        uint32_t node_id;
        uint32_t ds_line;
        uint32_t ds_col;
        char    *ds_file;
        uint32_t module_id;
    } *line_spans;
    size_t n_line_spans, cap_line_spans;

    /* [LCRS.6.2.4]: the apply phase marks each named schema `call_response`. */
    char  **responses;
    size_t  n_responses, cap_responses;

    /* [LCRS.6.2.1]: each service with its `response`, "" for `no response`. */
    struct ds_call_service *services;
    size_t n_services, cap_services;

    /* [LGRA.24]: raw, in artefact order, checked after everything else has loaded. */
    struct dsc_initial *initial;
    size_t n_initial, cap_initial;
} dsc_load_state_t;

static void dsc_initial_free(struct dsc_initial *items, size_t n);

static void dsc_slot_acc_dispose(dsc_slot_acc_t *s)
{
    DS_FREE(s->slot_name);
    DS_FREE(s->schema_ref_name);
    s->slot_name = NULL;
    s->schema_ref_name = NULL;
    if (s->to_stored != NULL)
        ds__v1__expr__free_unpacked(s->to_stored, &ds_pb_allocator);
    if (s->from_stored != NULL)
        ds__v1__expr__free_unpacked(s->from_stored, &ds_pb_allocator);
    s->to_stored = s->from_stored = NULL;
}

/* [RDSC.5.5.9]: the conversion trees of a slot-descriptor array the rete
   engine did not take. */
static void dsc_rslots_free_conversions(ds_rete_slot_desc_t *rslots, size_t n)
{
    for (size_t s = 0; s < n; s++) {
        ds_rete_expr_free_tree(rslots[s].to_stored);
        ds_rete_expr_free_tree(rslots[s].from_stored);
        rslots[s].to_stored = rslots[s].from_stored = NULL;
    }
}

static void dsc_schema_acc_dispose(dsc_schema_acc_t *a)
{
    DS_FREE(a->name);
    a->name = NULL;
    for (size_t i = 0; i < a->n_slots; i++) {
        dsc_slot_acc_dispose(&a->slots[i]);
    }
    DS_FREE(a->slots);
    a->slots = NULL;
    a->n_slots = a->cap_slots = 0;
    DS_FREE(a->src_file);
    a->src_file = NULL;
    DS_FREE(a->proto_text);
    a->proto_text = NULL;
    a->proto_text_len = 0;
}

static void dsc_rule_acc_dispose(dsc_rule_acc_t *r)
{
    DS_FREE(r->rule_name);
    DS_FREE(r->src_file);
    DS_FREE(r->debug_name_template);
    r->rule_name = r->src_file = r->debug_name_template = NULL;
}

/* [RDSC.9.4]: an atom the loader steps over, logged at info by name and offset. */
static void log_skipped_atom(struct ds_engine *engine, uint32_t field,
                             const char *name, size_t pos, const char *why)
{
    char msg[192];
    ds_text_t t = ds_text(msg, sizeof msg);
    ds_text_str(&t, "skipping atom ");
    ds_text_u64(&t, field);
    ds_text_str(&t, " (");
    ds_text_str(&t, name);
    ds_text_str(&t, ") at byte offset ");
    ds_text_u64(&t, (uint64_t)pos);
    ds_text_str(&t, why);
    ds_log_event_t ev = {
        .level    = DS_LOG_INFO,
        .category = "dsc-load",
        .message  = msg,
    };
    ds_telemetry_emit_log(engine, &ev);
}

static void dsc_load_state_dispose(dsc_load_state_t *s)
{
    if (s == NULL) return;
    for (size_t i = 0; i < s->n_schemas; i++) {
        dsc_schema_acc_dispose(&s->schemas[i]);
    }
    DS_FREE(s->schemas);
    s->schemas = NULL;
    s->n_schemas = s->cap_schemas = 0;
    for (size_t i = 0; i < s->n_rules; i++) {
        dsc_rule_acc_dispose(&s->rules[i]);
    }
    DS_FREE(s->rules);
    s->rules = NULL;
    s->n_rules = s->cap_rules = 0;
    for (size_t i = 0; i < s->n_series_decls; i++) {
        DS_FREE(s->series_decls[i].schema_name);
        DS_FREE(s->series_decls[i].slot_name);
        DS_FREE(s->series_decls[i].identity_slot_name);
    }
    DS_FREE(s->series_decls);
    s->series_decls = NULL;
    s->n_series_decls = s->cap_series_decls = 0;
    for (size_t i = 0; i < s->n_alfa_atoms; i++) DS_FREE(s->alfa_atoms[i].body);
    DS_FREE(s->alfa_atoms); s->alfa_atoms = NULL; s->n_alfa_atoms = s->cap_alfa_atoms = 0;
    for (size_t i = 0; i < s->n_beta_atoms; i++) DS_FREE(s->beta_atoms[i].body);
    DS_FREE(s->beta_atoms); s->beta_atoms = NULL; s->n_beta_atoms = s->cap_beta_atoms = 0;
    for (size_t i = 0; i < s->n_term_atoms; i++) DS_FREE(s->term_atoms[i].body);
    DS_FREE(s->term_atoms); s->term_atoms = NULL; s->n_term_atoms = s->cap_term_atoms = 0;
    for (size_t i = 0; i < s->n_ds_sources; i++) {
        DS_FREE(s->ds_sources[i].file);
        DS_FREE(s->ds_sources[i].text);
    }
    DS_FREE(s->ds_sources);
    s->ds_sources = NULL;
    s->n_ds_sources = s->cap_ds_sources = 0;
    for (size_t i = 0; i < s->n_line_spans; i++) {
        DS_FREE(s->line_spans[i].ds_file);
    }
    DS_FREE(s->line_spans);
    s->line_spans = NULL;
    s->n_line_spans = s->cap_line_spans = 0;
    for (size_t i = 0; i < s->n_responses; i++) DS_FREE(s->responses[i]);
    DS_FREE(s->responses);
    s->responses = NULL;
    s->n_responses = s->cap_responses = 0;
    for (size_t i = 0; i < s->n_services; i++)
        ds_call_service_dispose(&s->services[i]);
    DS_FREE(s->services);
    s->services = NULL;
    s->n_services = s->cap_services = 0;
    dsc_initial_free(s->initial, s->n_initial);
    s->initial = NULL;
    s->n_initial = s->cap_initial = 0;
}

/* NULL only on OOM. The array can grow, so do not retain the pointer across other
   state mutations. */
static dsc_schema_acc_t *dsc_state_get_schema(dsc_load_state_t *s,
                                              uint32_t module_id,
                                              const char *name)
{
    for (size_t i = 0; i < s->n_schemas; i++) {
        if (s->schemas[i].module_id == module_id &&
            strcmp(s->schemas[i].name, name) == 0) return &s->schemas[i];
    }
    if (s->n_schemas == s->cap_schemas) {
        size_t new_cap = s->cap_schemas == 0 ? 4 : s->cap_schemas * 2;
        dsc_schema_acc_t *na = DS_REALLOC(s->schemas,
                                       new_cap * sizeof(*na));
        if (na == NULL) return NULL;
        memset(na + s->cap_schemas, 0,
               (new_cap - s->cap_schemas) * sizeof(*na));
        s->schemas = na;
        s->cap_schemas = new_cap;
    }
    dsc_schema_acc_t *a = &s->schemas[s->n_schemas++];
    a->module_id = module_id;
    a->name    = DS_STRDUP(name);
    if (a->name == NULL) {
        s->n_schemas--;
        return NULL;
    }
    return a;
}

static dsc_slot_acc_t *dsc_schema_find_slot(dsc_schema_acc_t *a,
                                             const char *name)
{
    for (size_t i = 0; i < a->n_slots; i++) {
        if (strcmp(a->slots[i].slot_name, name) == 0) return &a->slots[i];
    }
    return NULL;
}

/* ---- Schema-atom handlers (SchemaTtl / SchemaLogical / Slot / Hydration / SchemaSource / SchemaDef) ---- */

static ds_result_t handle_sttl(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__SchemaTtl *m =
        ds__v1__schema_ttl__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SchemaTtl body protobuf decode failed");
    }
    /* A `.dsc` is trusted input ([RDSC.9.9]): an empty name, a zero `ttl_ns` and a
       second SchemaTtl are the compiler's to prevent. A second one's TTL replaces
       the first's. */
    dsc_schema_acc_t *a = dsc_state_get_schema(st, m->module_id, m->schema_name);
    if (a == NULL) {
        ds__v1__schema_ttl__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: SchemaTtl accumulator allocation failed");
    }
    a->has_sttl = true;
    a->ttl_ns   = m->ttl_ns;
    ds__v1__schema_ttl__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

static ds_result_t handle_slog(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__SchemaLogical *m =
        ds__v1__schema_logical__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SchemaLogical body protobuf decode failed");
    }
    dsc_schema_acc_t *a = dsc_state_get_schema(st, m->module_id, m->schema_name);
    if (a == NULL) {
        ds__v1__schema_logical__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: SchemaLogical accumulator allocation failed");
    }
    /* [RDSC.5.4.5] */
    switch (m->lifecycle) {
    case DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_EXPLICIT:
    case DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_LOGICAL:
    case DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_ACTIVATION:
        break;
    case DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_UNSPECIFIED:
    default:
        ds__v1__schema_logical__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: SchemaLogical.lifecycle unspecified or unknown (RDSC.5.4.5)");
    }
    a->has_slog  = true;
    a->lifecycle = m->lifecycle;
    if (m->ambient) a->is_ambient = true;
    ds__v1__schema_logical__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

static ds_result_t slot_kind_to_type(Ds__V1__SlotKind k,
                                      ds_slot_type_t *out)
{
    switch (k) {
    case DS__V1__SLOT_KIND__SLOT_KIND_INT:    *out = DS_SLOT_TYPE_INT;    return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_FLOAT:  *out = DS_SLOT_TYPE_FLOAT;  return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_STRING: *out = DS_SLOT_TYPE_STRING; return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_BOOL:   *out = DS_SLOT_TYPE_BOOL;   return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_JSON:   *out = DS_SLOT_TYPE_JSON;   return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_BYTES:  *out = DS_SLOT_TYPE_BYTES;  return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_SCHEMA: *out = DS_SLOT_TYPE_SCHEMA; return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_TIME:     *out = DS_SLOT_TYPE_TIME;     return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_DATE:     *out = DS_SLOT_TYPE_DATE;     return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_DURATION: *out = DS_SLOT_TYPE_DURATION; return DS_OK_R;
    case DS__V1__SLOT_KIND__SLOT_KIND_UNSPECIFIED:
    default:
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: Slot.kind unspecified or unknown (RDSC.5.5.4)");
    }
}

static ds_result_t handle_slot(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__Slot *m =
        ds__v1__slot__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: Slot body protobuf decode failed");
    }
    ds_slot_type_t t;
    ds_result_t r = slot_kind_to_type(m->kind, &t);
    if (r.status != DS_OK) {
        ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
        return r;
    }

    /* [RDSC.5.5.5]: a SCHEMA slot needs its reference; on any other kind it is
       ignored ([NFCT.1.4.1]). */
    bool has_ref = t == DS_SLOT_TYPE_SCHEMA
                && m->schema_ref != NULL && m->schema_ref[0] != '\0';
    if (t == DS_SLOT_TYPE_SCHEMA && !has_ref) {
        ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: Slot.schema_ref required for SCHEMA kind (RDSC.5.5.5)");
    }
    /* [RDSC.9.10] */
    if (rdsc_9_10_nan(m->tolerance)) {
        ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: Slot.tolerance is a NaN (RDSC.9.10)");
    }
    /* [RDSC.9.11]: -0.0 is not less than zero, and is exact. */
    if (m->tolerance < 0.0) {
        ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: Slot.tolerance is less than zero (RDSC.9.11)");
    }
    /* [RDSC.5.5.9]: both conversions or neither, each decoded here with no
       engine, so a refusal is this atom's, at its offset, as Mercury's is:
       `to_stored` first. */
    if ((m->to_stored == NULL) != (m->from_stored == NULL)) {
        ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: a Slot carries one unit conversion and not the "
                        "other (RDSC.5.5.9)");
    }
    if (m->to_stored != NULL) {
        const Ds__V1__Expr *conv[2] = { m->to_stored, m->from_stored };
        for (int c = 0; c < 2; c++) {
            ds_rete_expr_t *probe = NULL;
            r = ds_dsc_slot_conversion(NULL, conv[c], &probe);
            ds_rete_expr_free_tree(probe);
            if (r.status != DS_OK) {
                ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
                return r;
            }
        }
    }

    dsc_schema_acc_t *a = dsc_state_get_schema(st, m->module_id, m->schema_name);
    if (a == NULL) {
        ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: Slot accumulator allocation failed");
    }
    /* A second Slot of one name is appended, and a lookup finds the first. */
    if (a->n_slots == a->cap_slots) {
        size_t new_cap = a->cap_slots == 0 ? 4 : a->cap_slots * 2;
        dsc_slot_acc_t *ns = DS_REALLOC(a->slots, new_cap * sizeof(*ns));
        if (ns == NULL) {
            ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
            return DS_ERR_R(DS_ERR_OOM, "dsc: slot list growth failed");
        }
        memset(ns + a->cap_slots, 0,
               (new_cap - a->cap_slots) * sizeof(*ns));
        a->slots = ns;
        a->cap_slots = new_cap;
    }
    dsc_slot_acc_t *s = &a->slots[a->n_slots++];
    s->slot_name = DS_STRDUP(m->slot_name);
    if (s->slot_name == NULL) {
        a->n_slots--;
        ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: slot name strdup failed");
    }
    s->type = t;
    if (has_ref) {
        s->schema_ref_name = DS_STRDUP(m->schema_ref);
        if (s->schema_ref_name == NULL) {
            DS_FREE(s->slot_name);
            a->n_slots--;
            ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
            return DS_ERR_R(DS_ERR_OOM, "dsc: schema_ref strdup failed");
        }
    }
    s->hydration_eligible = false;
    s->sampled      = m->sampled;
    s->retained     = m->retained;
    s->tolerance    = m->tolerance;
    s->nullable     = m->nullable;
    s->capacity     = m->capacity;
    switch (m->identity_role) {
    case DS__V1__IDENTITY_ROLE__IDENTITY_ROLE_KEY:
        s->identity_role = DS_IDENTITY_KEY;     break;
    case DS__V1__IDENTITY_ROLE__IDENTITY_ROLE_MUTABLE:
        s->identity_role = DS_IDENTITY_MUTABLE; break;
    /* [LFAC.9.1] */
    case DS__V1__IDENTITY_ROLE__IDENTITY_ROLE_ENGINE:
        s->identity_role = DS_IDENTITY_ENGINE;  break;
    default:
        s->identity_role = DS_IDENTITY_UNSPECIFIED; break;
    }
    s->to_stored   = m->to_stored;      /* [RDSC.5.5.9], detached */
    s->from_stored = m->from_stored;
    m->to_stored   = NULL;
    m->from_stored = NULL;
    ds__v1__slot__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

static ds_result_t handle_hydr(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__Hydration *m =
        ds__v1__hydration__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: Hydration body protobuf decode failed");
    }
    dsc_schema_acc_t *a = dsc_state_get_schema(st, m->module_id, m->schema_name);
    if (a == NULL) {
        ds__v1__hydration__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: Hydration accumulator allocation failed");
    }
    dsc_slot_acc_t *s = dsc_schema_find_slot(a, m->slot_name);
    if (s == NULL) {
        ds__v1__hydration__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_DANGLING,
                        "dsc: Hydration references unknown slot (RDSC.5.6.4)");
    }
    s->hydration_eligible = true;
    ds__v1__hydration__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

static ds_result_t handle_srcs(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__SchemaSource *m =
        ds__v1__schema_source__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SchemaSource body protobuf decode failed");
    }
    dsc_schema_acc_t *a = dsc_state_get_schema(st, m->module_id, m->schema_name);
    if (a == NULL) {
        ds__v1__schema_source__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: SchemaSource accumulator allocation failed");
    }
    /* src_file comes from DsSource[module_id].file at apply time. */
    a->has_srcs = true;
    a->src_file = NULL;
    a->src_line = m->line;
    a->src_col  = m->col;
    ds__v1__schema_source__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

static ds_result_t handle_sdef(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__SchemaDef *m =
        ds__v1__schema_def__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SchemaDef body protobuf decode failed");
    }
    dsc_schema_acc_t *a = dsc_state_get_schema(st, m->module_id, m->schema_name);
    if (a == NULL) {
        ds__v1__schema_def__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: SchemaDef accumulator allocation failed");
    }

    const uint8_t *raw     = m->proto_source.data;
    size_t         raw_len = m->proto_source.len;
    if (m->compression == DS__V1__COMPRESSION__COMPRESSION_NONE) {
        char *copy = DS_MALLOC(raw_len + 1);
        if (copy == NULL) {
            ds__v1__schema_def__free_unpacked(m, &ds_pb_allocator);
            return DS_ERR_R(DS_ERR_OOM, "dsc: SchemaDef copy allocation failed");
        }
        if (raw_len > 0) memcpy(copy, raw, raw_len);
        copy[raw_len] = '\0';
        DS_FREE(a->proto_text);   /* a second SchemaDef's text replaces the first's */
        a->proto_text     = copy;
        a->proto_text_len = raw_len;
    } else {
        ds__v1__schema_def__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_DECOMPRESS,
                        "dsc: no decompressor — COMPRESSION_ZLIB retired (RDSC.4.5.1)");
    }
    a->has_sdef = true;
    ds__v1__schema_def__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

/* ---- Rule-atom helpers + handlers (RuleCooldown / RuleSource) ---- */

static dsc_rule_acc_t *dsc_state_get_rule(dsc_load_state_t *s,
                                           uint32_t module_id,
                                           const char *name)
{
    for (size_t i = 0; i < s->n_rules; i++) {
        if (s->rules[i].module_id == module_id &&
            strcmp(s->rules[i].rule_name, name) == 0) return &s->rules[i];
    }
    if (s->n_rules == s->cap_rules) {
        size_t new_cap = s->cap_rules == 0 ? 4 : s->cap_rules * 2;
        dsc_rule_acc_t *na = DS_REALLOC(s->rules, new_cap * sizeof(*na));
        if (na == NULL) return NULL;
        memset(na + s->cap_rules, 0,
               (new_cap - s->cap_rules) * sizeof(*na));
        s->rules = na;
        s->cap_rules = new_cap;
    }
    dsc_rule_acc_t *a = &s->rules[s->n_rules++];
    a->module_id = module_id;
    a->rule_name = DS_STRDUP(name);
    if (a->rule_name == NULL) {
        s->n_rules--;
        return NULL;
    }
    return a;
}


static ds_result_t handle_cool(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__RuleCooldown *m =
        ds__v1__rule_cooldown__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) return DS_ERR_R(DS_ERR_DSC_DECODE,
                                   "dsc: RuleCooldown body protobuf decode failed");
    dsc_rule_acc_t *r = dsc_state_get_rule(st, m->module_id, m->rule_name);
    if (r == NULL) {
        ds__v1__rule_cooldown__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: RuleCooldown accumulator alloc failed");
    }
    r->has_cool       = true;
    r->cool_window_ns = m->window_ns;
    ds__v1__rule_cooldown__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

/* [RDSC.9.12] for the hand walks. */
static bool rdsc_9_12_text_ok(const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if (p[i] == 0u) return false;
    return ds_utf8_well_formed((const char *) p, n) != 0;
}

static char *dup_bytes(const uint8_t *p, size_t n)
{
    char *s = DS_MALLOC(n + 1);
    if (s == NULL) return NULL;
    if (n > 0) memcpy(s, p, n);
    s[n] = '\0';
    return s;
}

/* ---- ServiceDef handler — a service's declaration ([LCRS.6.2.4], [NDBG.2.4]) ----
 *
 * `name` (1) and `response` (3) drive the call path; the kwargs (2) and `no_response`
 * (5) are kept for [NDBG.2.4]'s view. `hydration` (4) does not bind in this edition,
 * and a second one is refused all the same ([RDSC.9.5]).
 *
 * Walked with `ds_pbf_next_field`: the generated decoder is not on this file's include
 * path. Proto3 semantics hold.
 */

/* [NDBG.2.4]: one ServiceKwarg, into `out` with its three strings owned. An absent
 * string is "". */
static ds_result_t svcd_kwarg(const uint8_t *body, size_t body_len,
                              ds_service_kwarg_view_t *out)
{
    const uint8_t *typ = NULL, *nm = NULL, *dv = NULL;
    size_t typ_len = 0, nm_len = 0, dv_len = 0;
    bool   required = false, literal = false, has_default = false;
    size_t pos = 0;
    for (;;) {
        ds_pbf_field_t f;
        ds_pbf_step_t s = ds_pbf_next_field(body, body_len, pos, &f);
        if (s == DS_PBF_EOF) {
            if (pos != body_len)
                return DS_ERR_R(DS_ERR_DSC_DECODE,
                                "dsc: ServiceKwarg body truncated");
            break;
        }
        if (s != DS_PBF_OK)
            return DS_ERR_R(DS_ERR_DSC_DECODE, "dsc: ServiceKwarg body malformed");
        if (f.field == 1u || f.field == 2u || f.field == 6u) {
            if (f.wire != 2u)
                return DS_ERR_R(DS_ERR_DSC_DECODE,
                                "dsc: a ServiceKwarg string field is not a string");
            /* `default_value` whatever `has_default` says. */
            if (!rdsc_9_12_text_ok(f.val, f.val_len))
                return DS_ERR_R(DS_ERR_DSC_DECODE,
                                RDSC_9_12_BAD_STRING("ServiceDef"));
            if (f.field == 1u)      { typ = f.val; typ_len = f.val_len; }
            else if (f.field == 2u) { nm = f.val;  nm_len = f.val_len; }
            else                    { dv = f.val;  dv_len = f.val_len; }
        } else if (f.field >= 3u && f.field <= 5u) {
            if (f.wire != 0u)
                return DS_ERR_R(DS_ERR_DSC_DECODE,
                                "dsc: a ServiceKwarg flag is not a varint");
            if (f.field == 3u)      required    = f.u64 != 0;
            else if (f.field == 4u) literal     = f.u64 != 0;
            else                    has_default = f.u64 != 0;
        }
        pos = f.next;
    }
    /* [RDSC.6a.2.4]: a text beside a false flag is ignored, not refused. */
    if (!has_default) { dv = NULL; dv_len = 0; }
    char *n = dup_bytes(nm, nm != NULL ? nm_len : 0);
    char *t = dup_bytes(typ, typ != NULL ? typ_len : 0);
    char *d = dup_bytes(dv, dv != NULL ? dv_len : 0);
    if (n == NULL || t == NULL || d == NULL) {
        DS_FREE(n); DS_FREE(t); DS_FREE(d);
        return DS_ERR_R(DS_ERR_OOM, "dsc: ServiceKwarg strings");
    }
    out->name         = n;
    out->ds_type      = t;
    out->required     = required;
    out->is_literal   = literal;
    out->has_default  = has_default;
    out->default_text = d;
    return DS_OK_R;
}

static ds_result_t handle_svcd(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    const uint8_t *resp = NULL;
    size_t         resp_len = 0;
    const uint8_t *svc = NULL;
    size_t         svc_len = 0;
    bool           no_response = false;
    bool           saw_hydration = false;
    /* A scratch entry, so one release covers every way out. */
    struct ds_call_service e;
    memset(&e, 0, sizeof e);
    uint32_t cap_kwargs = 0;
    ds_result_t r = DS_OK_R;
    size_t pos = 0;
    for (;;) {
        ds_pbf_field_t f;
        ds_pbf_step_t s = ds_pbf_next_field(body, body_len, pos, &f);
        if (s == DS_PBF_EOF) {
            /* The frame's length bounds the body, so a short read does not parse. */
            if (pos != body_len) {
                r = DS_ERR_R(DS_ERR_DSC_DECODE, "dsc: ServiceDef body truncated");
                goto fail;
            }
            break;
        }
        if (s != DS_PBF_OK) {
            r = DS_ERR_R(DS_ERR_DSC_DECODE, "dsc: ServiceDef body malformed");
            goto fail;
        }
        if (f.field == 3u) {
            if (f.wire != 2u) {
                r = DS_ERR_R(DS_ERR_DSC_DECODE,
                             "dsc: ServiceDef.response is not a string");
                goto fail;
            }
            if (!rdsc_9_12_text_ok(f.val, f.val_len)) {
                r = DS_ERR_R(DS_ERR_DSC_DECODE,
                             RDSC_9_12_BAD_STRING("ServiceDef"));
                goto fail;
            }
            resp = f.val;
            resp_len = f.val_len;
        } else if (f.field == 1u) {
            if (f.wire != 2u) {
                r = DS_ERR_R(DS_ERR_DSC_DECODE,
                             "dsc: ServiceDef.name is not a string");
                goto fail;
            }
            if (!rdsc_9_12_text_ok(f.val, f.val_len)) {
                r = DS_ERR_R(DS_ERR_DSC_DECODE,
                             RDSC_9_12_BAD_STRING("ServiceDef"));
                goto fail;
            }
            svc = f.val;
            svc_len = f.val_len;
        } else if (f.field == 5u) {
            if (f.wire != 0u) {
                r = DS_ERR_R(DS_ERR_DSC_DECODE,
                             "dsc: ServiceDef.no_response is not a varint");
                goto fail;
            }
            no_response = f.u64 != 0;
        } else if (f.field == 4u && f.wire == 2u) {
            if (saw_hydration) {
                r = DS_ERR_R(DS_ERR_DSC_DECODE,
                             RDSC_9_5_REPEATED("ServiceDef"));
                goto fail;
            }
            saw_hydration = true;
        } else if (f.field == 2u) {
            if (f.wire != 2u) {
                r = DS_ERR_R(DS_ERR_DSC_DECODE,
                             "dsc: ServiceDef.kwargs is not a message");
                goto fail;
            }
            if (e.n_kwargs == cap_kwargs) {
                uint32_t nc = cap_kwargs ? cap_kwargs * 2u : 4u;
                ds_service_kwarg_view_t *nv =
                    DS_REALLOC(e.kwargs, nc * sizeof(*nv));
                if (nv == NULL) {
                    r = DS_ERR_R(DS_ERR_OOM, "dsc: ServiceDef kwarg list");
                    goto fail;
                }
                e.kwargs = nv;
                cap_kwargs = nc;
            }
            r = svcd_kwarg(f.val, f.val_len, &e.kwargs[e.n_kwargs]);
            if (r.status != DS_OK) goto fail;
            e.n_kwargs++;
        }
        pos = f.next;
    }

    /* Whatever its response: a `no response` service's call still sweeps CallError
       ([LCRS.6.2.1]). No call can name a service with no name. */
    if (svc != NULL && svc_len > 0) {
        if (st->n_services == st->cap_services) {
            size_t nc = st->cap_services ? st->cap_services * 2 : 4;
            struct ds_call_service *nv =
                DS_REALLOC(st->services, nc * sizeof(*nv));
            if (nv == NULL) {
                r = DS_ERR_R(DS_ERR_OOM, "dsc: ServiceDef service list");
                goto fail;
            }
            st->services = nv;
            st->cap_services = nc;
        }
        e.name     = dup_bytes(svc, svc_len);
        e.response = dup_bytes(resp, resp != NULL ? resp_len : 0);
        if (e.name == NULL || e.response == NULL) {
            r = DS_ERR_R(DS_ERR_OOM, "dsc: ServiceDef service name");
            goto fail;
        }
        e.no_response = no_response;
        st->services[st->n_services++] = e;
    } else {
        ds_call_service_dispose(&e);
    }

    if (resp == NULL || resp_len == 0) return DS_OK_R;   /* `no response` */

    if (st->n_responses == st->cap_responses) {
        size_t nc = st->cap_responses ? st->cap_responses * 2 : 4;
        char **nv = DS_REALLOC(st->responses, nc * sizeof(*nv));
        if (nv == NULL)
            return DS_ERR_R(DS_ERR_OOM, "dsc: ServiceDef response list");
        st->responses = nv;
        st->cap_responses = nc;
    }
    char *name = DS_MALLOC(resp_len + 1);
    if (name == NULL) return DS_ERR_R(DS_ERR_OOM, "dsc: ServiceDef response name");
    memcpy(name, resp, resp_len);
    name[resp_len] = '\0';
    st->responses[st->n_responses++] = name;
    return DS_OK_R;

fail:
    ds_call_service_dispose(&e);
    return r;
}

/* ---- InitialFact / InitialCacheSeed — a ruleset's `initial:` block ([LGRA.24], initial.proto) ----
 *
 * Walked with ds_pbf_next_field. Whether an item fits the program is not asked at
 * load: one that does not is dropped where it is applied (lgra_24_3_item).
 *
 * A NaN is judged on what the decoded atom holds ([RDSC.9.10]), once the body has
 * decoded: one a later member of its oneof replaces is not refused.
 */

/* One `TestSlotLiteral` (proto/test_scenario.proto). `kind` is the field number that
   set the `value` oneof: `i_val` 2, `f_val` 3, `s_val` 4, `b_val` 5, `d_val` 6,
   `j_val` 7, or 0 for none. The last member wins. */
typedef struct {
    char    *name;    /* owned; "" when absent */
    uint32_t kind;
    uint64_t u64;     /* i_val, b_val, d_val as read; f_val's bits */
    char    *text;    /* s_val, j_val; owned, else NULL */
} dsc_literal_t;

struct dsc_initial {
    bool           is_seed;     /* InitialCacheSeed, else InitialFact */
    uint32_t       module_id;
    uint32_t       order;       /* source_order */
    size_t         arrival;     /* the tie-break that makes qsort stable */
    char          *name;        /* InitialFact schema_name, InitialCacheSeed key; owned */
    dsc_literal_t *lits;        /* InitialFact's slots, InitialCacheSeed's one value */
    size_t         n_lits, cap_lits;
};

static void dsc_initial_free(struct dsc_initial *items, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        DS_FREE(items[i].name);
        for (size_t j = 0; j < items[i].n_lits; j++) {
            DS_FREE(items[i].lits[j].name);
            DS_FREE(items[i].lits[j].text);
        }
        DS_FREE(items[i].lits);
    }
    DS_FREE(items);
}

#define INITIAL_DECODE \
    DS_ERR_R(DS_ERR_DSC_DECODE, \
             "dsc: InitialFact / InitialCacheSeed body malformed (LGRA.24)")

static ds_result_t initial_text(const ds_pbf_field_t *f, char **out)
{
    if (f->wire != 2u || !rdsc_9_12_text_ok(f->val, f->val_len))
        return INITIAL_DECODE;
    char *s = dup_bytes(f->val, f->val_len);
    if (s == NULL) return DS_ERR_R(DS_ERR_OOM, "dsc: an `initial:` item's text");
    DS_FREE(*out);
    *out = s;
    return DS_OK_R;
}

static ds_result_t initial_literal(const uint8_t *body, size_t len,
                                   dsc_literal_t *lit)
{
    size_t pos = 0;
    for (;;) {
        ds_pbf_field_t f;
        ds_pbf_step_t  s = ds_pbf_next_field(body, len, pos, &f);
        if (s == DS_PBF_EOF) {
            if (pos != len) return INITIAL_DECODE;
            break;
        }
        if (s != DS_PBF_OK) return INITIAL_DECODE;
        ds_result_t r = DS_OK_R;
        switch (f.field) {
        case 1u:
            r = initial_text(&f, &lit->name);
            break;
        case 2u: case 5u: case 6u:
            if (f.wire != 0u) return INITIAL_DECODE;
            DS_FREE(lit->text);
            lit->text = NULL;
            lit->kind = f.field;
            lit->u64  = f.u64;
            break;
        case 3u:
            if (f.wire != 1u) return INITIAL_DECODE;
            DS_FREE(lit->text);
            lit->text = NULL;
            lit->kind = f.field;
            lit->u64  = f.u64;
            break;
        case 4u: case 7u:
            r = initial_text(&f, &lit->text);
            if (r.status == DS_OK) lit->kind = f.field;
            break;
        default:
            break;
        }
        if (r.status != DS_OK) return r;
        pos = f.next;
    }
    if (lit->kind == 0u) return INITIAL_DECODE;
    if (lit->name == NULL) {
        lit->name = dup_bytes(NULL, 0);
        if (lit->name == NULL)
            return DS_ERR_R(DS_ERR_OOM, "dsc: an `initial:` item's text");
    }
    return DS_OK_R;
}

static bool rdsc_9_10_held_nan(const dsc_literal_t *lit)
{
    return lit->kind == 3u && rdsc_9_10_nan_bits(lit->u64);
}

/* InitialFact: `module_id` 1, `schema_name` 2, `slots` 3 (repeated), `source_order` 4.
   InitialCacheSeed: `module_id` 1, `key` 2, `value` 3, `source_order` 4. */
static ds_result_t handle_initial(dsc_load_state_t *st, bool is_seed,
                                  const uint8_t *body, size_t body_len)
{
    if (st->n_initial == st->cap_initial) {
        size_t nc = st->cap_initial ? st->cap_initial * 2 : 8;
        struct dsc_initial *nv = DS_REALLOC(st->initial, nc * sizeof(*nv));
        if (nv == NULL) return DS_ERR_R(DS_ERR_OOM, "dsc: `initial:` items");
        st->initial = nv;
        st->cap_initial = nc;
    }
    struct dsc_initial *it = &st->initial[st->n_initial];
    memset(it, 0, sizeof *it);
    it->is_seed = is_seed;
    it->arrival = st->n_initial;
    st->n_initial++;          /* now, so a refusal's dispose frees it */

    size_t pos = 0;
    for (;;) {
        ds_pbf_field_t f;
        ds_pbf_step_t  s = ds_pbf_next_field(body, body_len, pos, &f);
        if (s == DS_PBF_EOF) {
            if (pos != body_len) return INITIAL_DECODE;
            break;
        }
        if (s != DS_PBF_OK) return INITIAL_DECODE;
        ds_result_t r = DS_OK_R;
        if (f.field == 1u || f.field == 4u) {
            if (f.wire != 0u) return INITIAL_DECODE;
            if (f.field == 1u) it->module_id = (uint32_t)f.u64;
            else               it->order   = (uint32_t)f.u64;
        } else if (f.field == 2u) {
            r = initial_text(&f, &it->name);
        } else if (f.field == 3u) {
            if (f.wire != 2u) return INITIAL_DECODE;
            /* [RDSC.9.5]: a seed's `value` is singular. */
            if (is_seed && it->n_lits == 1)
                return DS_ERR_R(DS_ERR_DSC_DECODE,
                                RDSC_9_5_REPEATED("InitialCacheSeed"));
            if (it->n_lits == it->cap_lits) {
                size_t nc = it->cap_lits ? it->cap_lits * 2 : 4;
                dsc_literal_t *nv = DS_REALLOC(it->lits, nc * sizeof(*nv));
                if (nv == NULL)
                    return DS_ERR_R(DS_ERR_OOM, "dsc: an `initial:` item's slots");
                it->lits = nv;
                it->cap_lits = nc;
            }
            dsc_literal_t *lit = &it->lits[it->n_lits++];
            memset(lit, 0, sizeof *lit);
            r = initial_literal(f.val, f.val_len, lit);
        }
        if (r.status != DS_OK) return r;
        pos = f.next;
    }
    if (is_seed && it->n_lits == 0) return INITIAL_DECODE;
    for (size_t j = 0; j < it->n_lits; j++)
        if (rdsc_9_10_held_nan(&it->lits[j]))
            return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                            "dsc: TestSlotLiteral.f_val is a NaN (RDSC.9.10)");
    if (it->name == NULL) {
        it->name = dup_bytes(NULL, 0);
        if (it->name == NULL)
            return DS_ERR_R(DS_ERR_OOM, "dsc: an `initial:` item's text");
    }
    return DS_OK_R;
}

static ds_result_t initial_json_text(const char *text, ds_json_t **out)
{
    *out = NULL;
    return ds_json_parse(text, strlen(text), out);
}

static const dsc_literal_t *initial_slot_literal(const struct dsc_initial *it,
                                                 const char *slot_name)
{
    for (size_t j = 0; j < it->n_lits; j++)
        if (strcmp(it->lits[j].name, slot_name) == 0) return &it->lits[j];
    return NULL;
}

/* [LGRA.24.3]'s order: `module_id` ([RDSC.8.1.1]), `source_order`, then arrival. */
static int initial_cmp(const void *a, const void *b)
{
    const struct dsc_initial *x = a, *y = b;
    if (x->module_id != y->module_id) return x->module_id < y->module_id ? -1 : 1;
    if (x->order   != y->order)   return x->order   < y->order   ? -1 : 1;
    if (x->arrival != y->arrival) return x->arrival < y->arrival ? -1 : 1;
    return 0;
}

/* A Json literal's tree is the caller's to free. */
static ds_result_t initial_slot_value(const dsc_literal_t *lit,
                                      ds_slot_value_t *out)
{
    memset(out, 0, sizeof *out);
    switch (lit->kind) {
    case 2u: case 6u:
        out->kind = DS_SLOT_INT;
        out->v.i  = (int64_t)lit->u64;
        return DS_OK_R;
    case 3u:
        out->kind = DS_SLOT_FLOAT;
        memcpy(&out->v.f, &lit->u64, sizeof out->v.f);
        return DS_OK_R;
    case 4u:
        out->kind = DS_SLOT_STRING;
        out->v.s  = lit->text;
        return DS_OK_R;
    case 5u:
        out->kind = DS_SLOT_BOOL;
        out->v.b  = lit->u64 != 0u;
        return DS_OK_R;
    default: {
        ds_json_t  *tree = NULL;
        ds_result_t r    = initial_json_text(lit->text, &tree);
        if (r.status != DS_OK) return r;
        out->kind   = DS_SLOT_JSON;
        out->v.json = tree;
        return DS_OK_R;
    }
    }
}

static ds_result_t initial_seed_json(const dsc_literal_t *lit, ds_json_t **out)
{
    *out = NULL;
    switch (lit->kind) {
    case 2u: case 6u: return ds_json_new_int((int64_t)lit->u64, out);
    case 3u: {
        double d;
        memcpy(&d, &lit->u64, sizeof d);
        return ds_json_new_float(d, out);
    }
    case 4u: return ds_json_new_string(lit->text, strlen(lit->text), out);
    case 5u: return ds_json_new_bool(lit->u64 != 0u, out);
    default:
        return initial_json_text(lit->text, out);
    }
}

/* [LTIM.2.8.3]: the schema declares `ts`, and the wall clock has no value for it. */
static bool ltim_2_8_3_unset_wall_ts(ds_engine_t *engine,
                                     const ds_schema_t *schema)
{
    bool has_ts = false;
    for (uint32_t i = 0; i < schema->n_slots && !has_ts; i++)
        has_ts = strcmp(schema->slots[i].name, "ts") == 0;
    if (!has_ts) return false;
    int64_t wall = 0;
    bool    wall_set = false;
    return ds_clock_wall_ns(&engine->clock, &wall, &wall_set).status != DS_OK
        || !wall_set;
}

/* [LTIM.2.8.3]: a ComputationError of kind DOMAIN, and the engine continues. The
   block applies before the step's input is consumed, so the recorder records it
   after the step's next record ([LGRA.24.3]). Its site is none ([LERR.9.11],
   [LERR.9.12]). */
static void ltim_2_8_3_block_fault(ds_engine_t *engine)
{
    ds_recorder_block_fault(engine, ds_rete_fault_rule_engine);
    if (engine->rete_engine != NULL) {
        const ds_rete_fault_fact_t ff = {
            .type_error = false, .what = "DOMAIN",
            .rule = ds_rete_fault_rule_engine,
            .schema = NULL, .slot = NULL, .node = 0,
        };
        ds_rete_fault_fact_enqueue(engine->rete_engine, &ff);
    }
}

/* One item, nested inside the step's own public entry, so neither path samples the
   clock ([LTIM.2.8.4]).

   The result is not read, but for OOM: a `.dsc` is trusted input ([RDSC.9.9]), and an
   item that does not fit is refused by the path it takes, and not placed. */
static ds_result_t lgra_24_3_item(ds_engine_t *engine,
                                  const struct dsc_initial *it)
{
    ds_result_t r;
    if (it->is_seed) {
        ds_json_t *v = NULL;
        r = initial_seed_json(&it->lits[0], &v);
        /* Not ds_engine_cache_seed, the host's, refused after the first stream
           event ([NLFC.9.1]). */
        if (r.status == DS_OK)
            r = ds_engine_cache_seed_initial(engine, it->name, v, 0);
        ds_json_free(v);
        return r.status == DS_ERR_OOM ? r : DS_OK_R;
    }
    const ds_schema_t *schema = NULL;
    if (ds_engine_schema_find(engine, it->name, &schema).status != DS_OK
            || schema == NULL)
        return DS_OK_R;
    if (ltim_2_8_3_unset_wall_ts(engine, schema)) {
        ltim_2_8_3_block_fault(engine);
        return DS_OK_R;
    }
    const uint32_t   n    = schema->n_slots;
    ds_slot_value_t *vals = DS_CALLOC(n ? n : 1u, sizeof *vals);
    if (vals == NULL) return DS_ERR_R(DS_ERR_OOM, "dsc: an `initial:` fact");
    r = DS_OK_R;
    for (uint32_t i = 0; i < n && r.status == DS_OK; i++) {
        const dsc_literal_t *lit = initial_slot_literal(it, schema->slots[i].name);
        int64_t  wall = 0;
        bool     wall_set = false;
        if (lit != NULL) {
            r = initial_slot_value(lit, &vals[i]);
        } else if (strcmp(schema->slots[i].name, "ts") == 0
                   && ds_clock_wall_ns(&engine->clock, &wall, &wall_set)
                          .status == DS_OK
                   && wall_set) {
            vals[i].kind = DS_SLOT_INT;
            vals[i].v.i  = wall;
        } else {
            vals[i].kind = DS_SLOT_NULL;   /* the assert judges a non-nullable one */
        }
    }
    if (r.status == DS_OK) r = ds_engine_assert(engine, schema, vals, n, NULL);
    for (uint32_t i = 0; i < n; i++)
        if (vals[i].kind == DS_SLOT_JSON) ds_json_free(vals[i].v.json);
    DS_FREE(vals);
    return r.status == DS_ERR_OOM ? r : DS_OK_R;
}

/* [LGRA.24.3] at load: sorted and handed to the engine, pending until the first step.
   Takes the items (*items is NULL after). */
static ds_result_t lgra_24_3_load(ds_engine_t *engine,
                                  struct dsc_initial **items, size_t *n)
{
    if (*n > 1) qsort(*items, *n, sizeof **items, initial_cmp);
    ds_engine_initial_free(engine);
    engine->initial   = *items;
    engine->n_initial = *n;
    *items = NULL;
    *n     = 0;
    return DS_OK_R;
}

/* [LGRA.24.3], [NLFC.9.3]: the first step's plan, before any item is placed.

   A key the cache holds as the step begins is one the host seeded, and its item is
   skipped. ds_oa_get ignores deadlines. An importer's item still overwrites its
   library's for a key the host left alone.

   A bounds refusal refuses the step. Items are counted in order against the cache the
   block would build, as ds_cache_set counts a write. A plan, because a fact placed
   before a refused seed could not be taken back. */
typedef struct {
    bool          refused;
    ds_cap_name_t cap;
    uint64_t      limit;
    uint64_t      observed;
} lgra_24_3_breach_t;

static ds_result_t lgra_24_3_plan(ds_engine_t                *engine,
                                  const struct dsc_initial   *items,
                                  size_t                      n,
                                  bool                       *skip,
                                  lgra_24_3_breach_t         *breach)
{
    breach->refused = false;
    ds_cache_t *c = &engine->cache;
    /* The block's own placements so far. The keys are the items'. */
    const char **keys  = DS_CALLOC(n ? n : 1u, sizeof *keys);
    size_t      *bytes = DS_CALLOC(n ? n : 1u, sizeof *bytes);
    if (keys == NULL || bytes == NULL) {
        DS_FREE(keys);
        DS_FREE(bytes);
        return DS_ERR_R(DS_ERR_OOM, "dsc: the `initial` block's bounds check");
    }
    size_t   nk    = 0;
    uint64_t live  = (uint64_t) oa_len(&c->map);
    uint64_t total = (uint64_t) c->total_value_bytes;
    ds_result_t r  = DS_OK_R;
    for (size_t i = 0; i < n && r.status == DS_OK; i++) {
        const struct dsc_initial *it = &items[i];
        skip[i] = false;
        if (!it->is_seed) continue;
        const char *key = it->name;
        if (ds_oa_get(&c->map, &key) != NULL) {
            skip[i] = true;
            continue;
        }
        ds_json_t *v = NULL;
        char      *text = NULL;
        size_t     tlen = 0;
        r = initial_seed_json(&it->lits[0], &v);
        if (r.status == DS_OK) r = ds_json_serialize(v, &text, &tlen);
        ds_json_free(v);
        if (r.status != DS_OK) break;
        const size_t vbytes = strlen(text);       /* ds_cache_set's count */
        ds_free(text);

        size_t j = 0;
        while (j < nk && strcmp(keys[j], key) != 0) j++;
        const bool placed = j < nk;
        if (c->cap_keys != 0 && !placed && live + 1u > c->cap_keys) {
            breach->refused  = true;
            breach->cap      = DS_CAP_CACHE;
            breach->limit    = c->cap_keys;
            breach->observed = live + 1u;
            break;
        }
        const uint64_t new_total = total + vbytes - (placed ? bytes[j] : 0u);
        if (c->cap_bytes != 0 && new_total > c->cap_bytes) {
            breach->refused  = true;
            breach->cap      = DS_CAP_CACHE_BYTES;
            breach->limit    = c->cap_bytes;
            breach->observed = new_total;
            break;
        }
        if (!placed) {
            keys[nk] = key;
            nk++;
            live++;
        }
        bytes[j] = vbytes;
        total    = new_total;
    }
    DS_FREE(keys);
    DS_FREE(bytes);
    return r;
}

/* [LGRA.24.3] at the first step: every pending item, in order, under the step's
   sample. A bounds refusal places nothing and leaves every item pending.

   A refused step is recorded here, as a refused assert is ([RFCS.6.7]):
   - a pump's input is its boundary ([RFCS.22]), so this records the PUMP;
   - a host assert's input is the arriving FactAssert, which the BoundsError writes
     first (recorder_emit_refused_input);
   - an external delivery leaves no input pending, so only the step's TICK is recorded
     ([RFCS.24.1], [RFCS.24.2]).

   Applying the block records nothing in a fact stream: the recorder is muted for the
   span, and a replay applies the block at its own first step. */
ds_result_t ds_engine_initial_apply(struct ds_engine *engine,
                                    ds_clock_step_t   step)
{
    struct dsc_initial *items = engine->initial;
    const size_t        n     = engine->n_initial;
    bool *skip = DS_CALLOC(n ? n : 1u, sizeof *skip);
    if (skip == NULL)
        return DS_ERR_R(DS_ERR_OOM, "dsc: the `initial` block's plan");
    lgra_24_3_breach_t breach;
    ds_result_t r = lgra_24_3_plan(engine, items, n, skip, &breach);
    if (r.status != DS_OK) {
        DS_FREE(skip);
        return r;
    }
    if (breach.refused) {
        DS_FREE(skip);
        bool record = step == DS_CLOCK_STEP_PUMP
                    ? ds_recorder_emit_pump(engine).status == DS_OK
                    : engine->recorder.input_pending;
        if (record)
            (void) ds_recorder_emit_bounds_error(engine, breach.cap,
                                                 breach.limit,
                                                 breach.observed, NULL, 0);
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        breach.cap == DS_CAP_CACHE
                        ? "initial: a cache item would exceed cache_cap "
                          "(live keys); the step is refused (LGRA.24.3)"
                        : "initial: a cache item would exceed cache_bytes_cap; "
                          "the step is refused (LGRA.24.3)");
    }
    engine->initial   = NULL;
    engine->n_initial = 0;
    engine->recorder.muted = true;
    for (size_t i = 0; i < n && r.status == DS_OK; i++)
        if (!skip[i]) r = lgra_24_3_item(engine, &items[i]);
    engine->recorder.muted = false;
    DS_FREE(skip);
    dsc_initial_free(items, n);
    return r;
}

void ds_engine_initial_free(struct ds_engine *engine)
{
    dsc_initial_free(engine->initial, engine->n_initial);
    engine->initial   = NULL;
    engine->n_initial = 0;
}

ds_result_t ds_engine_initial_clone(struct ds_engine       *dst,
                                    const struct ds_engine *src)
{
    dst->initial   = NULL;
    dst->n_initial = 0;
    if (src->n_initial == 0) return DS_OK_R;
    struct dsc_initial *v = DS_CALLOC(src->n_initial, sizeof *v);
    if (v == NULL) return DS_ERR_R(DS_ERR_OOM, "clone: `initial` items");
    /* At once, so a failure part-way leaves what the engine's teardown frees. */
    dst->initial   = v;
    dst->n_initial = src->n_initial;
    for (size_t i = 0; i < src->n_initial; i++) {
        const struct dsc_initial *s = &src->initial[i];
        v[i].is_seed = s->is_seed;
        v[i].module_id = s->module_id;
        v[i].order   = s->order;
        v[i].arrival = s->arrival;
        v[i].name    = DS_STRDUP(s->name);
        if (v[i].name == NULL) return DS_ERR_R(DS_ERR_OOM, "clone: `initial` name");
        if (s->n_lits == 0) continue;
        v[i].lits = DS_CALLOC(s->n_lits, sizeof *v[i].lits);
        if (v[i].lits == NULL)
            return DS_ERR_R(DS_ERR_OOM, "clone: `initial` slots");
        v[i].cap_lits = s->n_lits;
        for (size_t j = 0; j < s->n_lits; j++) {
            dsc_literal_t *d = &v[i].lits[j];
            d->kind = s->lits[j].kind;
            d->u64  = s->lits[j].u64;
            v[i].n_lits = j + 1;
            d->name = DS_STRDUP(s->lits[j].name);
            if (d->name == NULL)
                return DS_ERR_R(DS_ERR_OOM, "clone: `initial` slot name");
            if (s->lits[j].text != NULL) {
                d->text = DS_STRDUP(s->lits[j].text);
                if (d->text == NULL)
                    return DS_ERR_R(DS_ERR_OOM, "clone: `initial` text");
            }
        }
    }
    return DS_OK_R;
}

static ds_result_t handle_srcr(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__RuleSource *m =
        ds__v1__rule_source__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) return DS_ERR_R(DS_ERR_DSC_DECODE,
                                   "dsc: RuleSource body protobuf decode failed");
    dsc_rule_acc_t *r = dsc_state_get_rule(st, m->module_id, m->rule_name);
    if (r == NULL) {
        ds__v1__rule_source__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: RuleSource accumulator alloc failed");
    }
    /* src_file comes from DsSource[module_id].file at apply time. */
    r->src_file = NULL;
    r->src_line = m->line;
    r->src_col  = m->col;
    r->has_srcr = true;
    ds__v1__rule_source__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

/* ---- RuleDebugName handler — debug display-name template (RDSC.6.8) ---- */

static ds_result_t handle_dnam(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__RuleDebugName *m =
        ds__v1__rule_debug_name__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) return DS_ERR_R(DS_ERR_DSC_DECODE,
                                   "dsc: RuleDebugName body protobuf decode failed");
    /* Before the template: an empty one still names a rule ([RDSC.8.7]). */
    dsc_rule_acc_t *r = dsc_state_get_rule(st, m->module_id, m->rule_name);
    if (r == NULL) {
        ds__v1__rule_debug_name__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: RuleDebugName accumulator alloc failed");
    }
    if (m->name_template == NULL || m->name_template[0] == '\0') {
        ds__v1__rule_debug_name__free_unpacked(m, &ds_pb_allocator);
        return DS_OK_R;
    }
    DS_FREE(r->debug_name_template);
    r->debug_name_template = DS_STRDUP(m->name_template);
    if (r->debug_name_template == NULL) {
        ds__v1__rule_debug_name__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: RuleDebugName template strdup failed");
    }
    r->has_dnam = true;
    ds__v1__rule_debug_name__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

/* ---- Native Rete atom handlers (AlphaNode / BetaNode / TerminalNode) [RDSC.4a] ---- */

#define RETE_APPEND(st, field, body, body_len, at, r_out) do { \
    if ((st)->n_##field##_atoms == (st)->cap_##field##_atoms) { \
        size_t _nc = (st)->cap_##field##_atoms ? (st)->cap_##field##_atoms * 2 : 4; \
        __typeof__((st)->field##_atoms) _na = DS_REALLOC((st)->field##_atoms, _nc * sizeof(*_na)); \
        if (!_na) { (r_out) = DS_ERR_R(DS_ERR_OOM, "dsc: " #field " atom grow"); break; } \
        (st)->field##_atoms = _na; (st)->cap_##field##_atoms = _nc; \
    } \
    uint8_t *_copy = DS_MALLOC((body_len) ? (body_len) : 1); \
    if (!_copy) { (r_out) = DS_ERR_R(DS_ERR_OOM, "dsc: " #field " atom copy"); break; } \
    memcpy(_copy, (body), (body_len)); \
    (st)->field##_atoms[(st)->n_##field##_atoms].body = _copy; \
    (st)->field##_atoms[(st)->n_##field##_atoms].len  = (body_len); \
    (st)->field##_atoms[(st)->n_##field##_atoms].offset = (at); \
    (st)->n_##field##_atoms++; \
    (r_out) = DS_OK_R; \
} while (0)

/* ---- Source-preservation atom handlers (DsSource / LineSpan) ---- */

static ds_result_t handle_dsrc(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__DsSource *m =
        ds__v1__ds_source__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) return DS_ERR_R(DS_ERR_DSC_DECODE,
                                   "dsc: DsSource body protobuf decode failed");
    /* A second DsSource for one module_id is appended; a lookup finds the first. */
    char  *text     = NULL;
    size_t text_len = 0;
    if (m->compression == DS__V1__COMPRESSION__COMPRESSION_NONE) {
        text_len = m->data.len;
        text = DS_MALLOC(text_len + 1);
        if (text == NULL) {
            ds__v1__ds_source__free_unpacked(m, &ds_pb_allocator);
            return DS_ERR_R(DS_ERR_OOM, "dsc: DsSource text alloc failed");
        }
        if (text_len > 0) memcpy(text, m->data.data, text_len);
        text[text_len] = '\0';
    } else {
        ds__v1__ds_source__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_DECOMPRESS,
                        "dsc: no decompressor — COMPRESSION_ZLIB retired (RDSC.4.5.1)");
    }
    if (st->n_ds_sources == st->cap_ds_sources) {
        size_t new_cap = st->cap_ds_sources == 0 ? 2 : st->cap_ds_sources * 2;
        void *na = DS_REALLOC(st->ds_sources,
                           new_cap * sizeof(*st->ds_sources));
        if (na == NULL) {
            DS_FREE(text);
            ds__v1__ds_source__free_unpacked(m, &ds_pb_allocator);
            return DS_ERR_R(DS_ERR_OOM, "dsc: ds_sources growth failed");
        }
        st->ds_sources = na;
        memset((char *) st->ds_sources + st->cap_ds_sources * sizeof(*st->ds_sources),
               0, (new_cap - st->cap_ds_sources) * sizeof(*st->ds_sources));
        st->cap_ds_sources = new_cap;
    }
    char *file_copy = DS_STRDUP(m->file);
    if (file_copy == NULL) {
        DS_FREE(text);
        ds__v1__ds_source__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_OOM, "dsc: DsSource.file strdup failed");
    }
    st->ds_sources[st->n_ds_sources].module_id = m->module_id;
    st->ds_sources[st->n_ds_sources].file      = file_copy;
    st->ds_sources[st->n_ds_sources].text      = text;
    st->ds_sources[st->n_ds_sources].text_len  = text_len;
    st->n_ds_sources++;
    ds__v1__ds_source__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}

/* ---- Series backend-atom handlers ([RDSC.5a]) ---- */

static ds_result_t dsc_state_alloc_series(dsc_load_state_t *st,
                                          size_t *out_idx)
{
    if (st->n_series_decls == st->cap_series_decls) {
        size_t new_cap = st->cap_series_decls == 0
                       ? 4 : st->cap_series_decls * 2;
        void *na = DS_REALLOC(st->series_decls,
                           new_cap * sizeof(*st->series_decls));
        if (na == NULL) {
            return DS_ERR_R(
                DS_ERR_OOM,
                "dsc: series-decl accumulator allocation failed");
        }
        st->series_decls = na;
        memset(
            (uint8_t *) st->series_decls
                + st->cap_series_decls * sizeof(*st->series_decls),
            0,
            (new_cap - st->cap_series_decls)
                * sizeof(*st->series_decls));
        st->cap_series_decls = new_cap;
    }
    *out_idx = st->n_series_decls++;
    return DS_OK_R;
}

static ds_result_t handle_sbwe(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__SeriesBackendWelfordEwma *m =
        ds__v1__series_backend_welford_ewma__unpack(
            &ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SeriesBackendWelfordEwma body protobuf decode failed");
    }
    size_t idx;
    ds_result_t r = dsc_state_alloc_series(st, &idx);
    if (r.status != DS_OK) {
        ds__v1__series_backend_welford_ewma__free_unpacked(m, &ds_pb_allocator);
        return r;
    }
    st->series_decls[idx].atom_field = DS_ATOM_SERIES_BACKEND_WELFORD_EWMA;
    st->series_decls[idx].module_id    = m->module_id;
    st->series_decls[idx].schema_name  = DS_STRDUP(m->schema_name);
    st->series_decls[idx].slot_name    = DS_STRDUP(m->slot_name);
    st->series_decls[idx].identity_slot_name =
        DS_STRDUP(m->identity_slot_name ? m->identity_slot_name : "");
    st->series_decls[idx].null_policy  = (uint32_t) m->null_policy;
    st->series_decls[idx].window_ns    = m->window_ns;
    st->series_decls[idx].persist_ns   = m->persist_ns;
    ds__v1__series_backend_welford_ewma__free_unpacked(m, &ds_pb_allocator);
    if (st->series_decls[idx].schema_name == NULL
        || st->series_decls[idx].slot_name == NULL
        || st->series_decls[idx].identity_slot_name == NULL) {
        return DS_ERR_R(DS_ERR_OOM,
                        "dsc: SeriesBackendWelfordEwma name strdup failed");
    }
    return DS_OK_R;
}

static ds_result_t handle_sbrb(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__SeriesBackendRingBuffer *m =
        ds__v1__series_backend_ring_buffer__unpack(
            &ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SeriesBackendRingBuffer body protobuf decode failed");
    }
    /* No bound at all: the buffer would grow without one. */
    if (m->window_ns == 0 && m->max_samples == 0) {
        ds__v1__series_backend_ring_buffer__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(
            DS_ERR_DSC_SEMANTIC,
            "dsc: SeriesBackendRingBuffer has neither window_ns nor max_samples set "
            "(LGRA.13.5: ring_buffer requires `window:` or "
            "`sample N`)");
    }
    size_t idx;
    ds_result_t r = dsc_state_alloc_series(st, &idx);
    if (r.status != DS_OK) {
        ds__v1__series_backend_ring_buffer__free_unpacked(m, &ds_pb_allocator);
        return r;
    }
    st->series_decls[idx].atom_field = DS_ATOM_SERIES_BACKEND_RING_BUFFER;
    st->series_decls[idx].module_id    = m->module_id;
    st->series_decls[idx].schema_name  = DS_STRDUP(m->schema_name);
    st->series_decls[idx].slot_name    = DS_STRDUP(m->slot_name);
    st->series_decls[idx].identity_slot_name =
        DS_STRDUP(m->identity_slot_name ? m->identity_slot_name : "");
    st->series_decls[idx].null_policy  = (uint32_t) m->null_policy;
    st->series_decls[idx].window_ns    = m->window_ns;
    st->series_decls[idx].persist_ns   = m->persist_ns;
    st->series_decls[idx].element_type = (uint32_t) m->element_type;
    st->series_decls[idx].max_samples  = m->max_samples;
    ds__v1__series_backend_ring_buffer__free_unpacked(m, &ds_pb_allocator);
    if (st->series_decls[idx].schema_name == NULL
        || st->series_decls[idx].slot_name == NULL
        || st->series_decls[idx].identity_slot_name == NULL) {
        return DS_ERR_R(DS_ERR_OOM,
                        "dsc: SeriesBackendRingBuffer name strdup failed");
    }
    return DS_OK_R;
}

/* [LSIG.2.2]: Bool slot, sliding only. */
static ds_result_t handle_sbip(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__SeriesBackendIntervalPulse *m =
        ds__v1__series_backend_interval_pulse__unpack(
            &ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SeriesBackendIntervalPulse body protobuf decode failed");
    }
    /* `active_fraction` divides by it. */
    if (m->window_ns == 0) {
        ds__v1__series_backend_interval_pulse__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: SeriesBackendIntervalPulse.window_ns is 0 — active_fraction is "
                        "sliding only (LSIG.1.3.3)");
    }
    size_t idx;
    ds_result_t r = dsc_state_alloc_series(st, &idx);
    if (r.status != DS_OK) {
        ds__v1__series_backend_interval_pulse__free_unpacked(m, &ds_pb_allocator);
        return r;
    }
    st->series_decls[idx].atom_field = DS_ATOM_SERIES_BACKEND_INTERVAL_PULSE;
    st->series_decls[idx].module_id    = m->module_id;
    st->series_decls[idx].schema_name  = DS_STRDUP(m->schema_name);
    st->series_decls[idx].slot_name    = DS_STRDUP(m->slot_name);
    st->series_decls[idx].identity_slot_name =
        DS_STRDUP(m->identity_slot_name ? m->identity_slot_name : "");
    st->series_decls[idx].null_policy  = (uint32_t) m->null_policy;
    st->series_decls[idx].window_ns    = m->window_ns;
    st->series_decls[idx].persist_ns   = m->persist_ns;
    st->series_decls[idx].element_type = (uint32_t) DS_SERIES_ELEMENT_BOOL;
    st->series_decls[idx].max_samples  = m->max_samples;
    ds__v1__series_backend_interval_pulse__free_unpacked(m, &ds_pb_allocator);
    if (st->series_decls[idx].schema_name == NULL
        || st->series_decls[idx].slot_name == NULL
        || st->series_decls[idx].identity_slot_name == NULL) {
        return DS_ERR_R(DS_ERR_OOM, "dsc: SeriesBackendIntervalPulse name strdup failed");
    }
    return DS_OK_R;
}

/* [LSIG.2.3]: window_ns is 0 for all_time. */
static ds_result_t handle_sbni(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__SeriesBackendNumericIntegral *m =
        ds__v1__series_backend_numeric_integral__unpack(
            &ds_pb_allocator, body_len, body);
    if (m == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SeriesBackendNumericIntegral body protobuf decode failed");
    }
    size_t idx;
    ds_result_t r = dsc_state_alloc_series(st, &idx);
    if (r.status != DS_OK) {
        ds__v1__series_backend_numeric_integral__free_unpacked(m, &ds_pb_allocator);
        return r;
    }
    st->series_decls[idx].atom_field = DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL;
    st->series_decls[idx].module_id    = m->module_id;
    st->series_decls[idx].schema_name  = DS_STRDUP(m->schema_name);
    st->series_decls[idx].slot_name    = DS_STRDUP(m->slot_name);
    st->series_decls[idx].identity_slot_name =
        DS_STRDUP(m->identity_slot_name ? m->identity_slot_name : "");
    st->series_decls[idx].null_policy  = (uint32_t) m->null_policy;
    st->series_decls[idx].window_ns    = m->window_ns;
    st->series_decls[idx].persist_ns   = m->persist_ns;
    st->series_decls[idx].element_type = (uint32_t) m->element_type;
    st->series_decls[idx].max_samples  = m->max_samples;
    st->series_decls[idx].time_model   = (uint32_t) m->time_model;
    st->series_decls[idx].gap_policy   = (uint32_t) m->gap_policy;
    ds__v1__series_backend_numeric_integral__free_unpacked(m, &ds_pb_allocator);
    if (st->series_decls[idx].schema_name == NULL
        || st->series_decls[idx].slot_name == NULL
        || st->series_decls[idx].identity_slot_name == NULL) {
        return DS_ERR_R(DS_ERR_OOM, "dsc: SeriesBackendNumericIntegral name strdup failed");
    }
    return DS_OK_R;
}

static ds_result_t handle_sbmd(dsc_load_state_t *st,
                                const uint8_t    *body,
                                size_t            body_len)
{
    Ds__V1__SeriesBackendMonotonicDeque *m =
        ds__v1__series_backend_monotonic_deque__unpack(
            &ds_pb_allocator, body_len, body);
    if (m == NULL)
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SeriesBackendMonotonicDeque body protobuf decode failed");
    size_t idx;
    ds_result_t r = dsc_state_alloc_series(st, &idx);
    if (r.status != DS_OK) {
        ds__v1__series_backend_monotonic_deque__free_unpacked(m, &ds_pb_allocator);
        return r;
    }
    st->series_decls[idx].atom_field = DS_ATOM_SERIES_BACKEND_MONOTONIC_DEQUE;
    st->series_decls[idx].module_id    = m->module_id;
    st->series_decls[idx].schema_name =
        DS_STRDUP(m->schema_name);
    st->series_decls[idx].slot_name =
        DS_STRDUP(m->slot_name);
    st->series_decls[idx].identity_slot_name =
        DS_STRDUP(m->identity_slot_name ? m->identity_slot_name : "");
    st->series_decls[idx].null_policy  = (uint32_t) m->null_policy;
    st->series_decls[idx].window_ns   = m->window_ns;
    st->series_decls[idx].persist_ns  = m->persist_ns;
    st->series_decls[idx].max_samples = m->max_samples;
    ds__v1__series_backend_monotonic_deque__free_unpacked(m, &ds_pb_allocator);
    if (st->series_decls[idx].schema_name == NULL
        || st->series_decls[idx].slot_name == NULL
        || st->series_decls[idx].identity_slot_name == NULL)
        return DS_ERR_R(DS_ERR_OOM, "dsc: SeriesBackendMonotonicDeque name strdup failed");
    return DS_OK_R;
}

static ds_result_t handle_sbfd(dsc_load_state_t *st,
                                const uint8_t    *body,
                                size_t            body_len)
{
    Ds__V1__SeriesBackendFifoDeque *m =
        ds__v1__series_backend_fifo_deque__unpack(
            &ds_pb_allocator, body_len, body);
    if (m == NULL)
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SeriesBackendFifoDeque body protobuf decode failed");
    size_t idx;
    ds_result_t r = dsc_state_alloc_series(st, &idx);
    if (r.status != DS_OK) {
        ds__v1__series_backend_fifo_deque__free_unpacked(m, &ds_pb_allocator);
        return r;
    }
    st->series_decls[idx].atom_field   = DS_ATOM_SERIES_BACKEND_FIFO_DEQUE;
    st->series_decls[idx].module_id    = m->module_id;
    st->series_decls[idx].schema_name =
        DS_STRDUP(m->schema_name);
    st->series_decls[idx].slot_name =
        DS_STRDUP(m->slot_name);
    st->series_decls[idx].identity_slot_name =
        DS_STRDUP(m->identity_slot_name ? m->identity_slot_name : "");
    st->series_decls[idx].element_type =
        (ds_series_element_type_t) m->element_type;
    st->series_decls[idx].null_policy  = (uint32_t) m->null_policy;
    st->series_decls[idx].window_ns    = m->window_ns;
    st->series_decls[idx].persist_ns   = m->persist_ns;
    st->series_decls[idx].max_samples  = m->max_samples;
    ds__v1__series_backend_fifo_deque__free_unpacked(m, &ds_pb_allocator);
    if (st->series_decls[idx].schema_name == NULL
        || st->series_decls[idx].slot_name == NULL
        || st->series_decls[idx].identity_slot_name == NULL)
        return DS_ERR_R(DS_ERR_OOM, "dsc: SeriesBackendFifoDeque name strdup failed");
    return DS_OK_R;
}

static ds_result_t handle_sbrs(dsc_load_state_t *st,
                                const uint8_t    *body,
                                size_t            body_len)
{
    Ds__V1__SeriesBackendReservoir *m =
        ds__v1__series_backend_reservoir__unpack(
            &ds_pb_allocator, body_len, body);
    if (m == NULL)
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: SeriesBackendReservoir body protobuf decode failed");
    size_t idx;
    ds_result_t r = dsc_state_alloc_series(st, &idx);
    if (r.status != DS_OK) {
        ds__v1__series_backend_reservoir__free_unpacked(m, &ds_pb_allocator);
        return r;
    }
    st->series_decls[idx].atom_field   = DS_ATOM_SERIES_BACKEND_RESERVOIR;
    st->series_decls[idx].module_id    = m->module_id;
    st->series_decls[idx].schema_name =
        DS_STRDUP(m->schema_name);
    st->series_decls[idx].slot_name =
        DS_STRDUP(m->slot_name);
    st->series_decls[idx].identity_slot_name =
        DS_STRDUP(m->identity_slot_name ? m->identity_slot_name : "");
    st->series_decls[idx].null_policy  = (uint32_t) m->null_policy;
    st->series_decls[idx].window_ns    = m->window_ns;
    st->series_decls[idx].persist_ns   = m->persist_ns;
    st->series_decls[idx].max_samples  = m->max_samples;
    ds__v1__series_backend_reservoir__free_unpacked(m, &ds_pb_allocator);
    if (st->series_decls[idx].schema_name == NULL
        || st->series_decls[idx].slot_name == NULL
        || st->series_decls[idx].identity_slot_name == NULL)
        return DS_ERR_R(DS_ERR_OOM, "dsc: SeriesBackendReservoir name strdup failed");
    return DS_OK_R;
}

static ds_result_t handle_line(dsc_load_state_t *st,
                                const uint8_t *body, size_t body_len)
{
    Ds__V1__LineSpan *m =
        ds__v1__line_span__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL) return DS_ERR_R(DS_ERR_DSC_DECODE,
                                   "dsc: LineSpan body protobuf decode failed");
    /* ds_file comes from DsSource[module_id].file. A span for node 0 names no node. */
    if (st->n_line_spans == st->cap_line_spans) {
        size_t new_cap = st->cap_line_spans == 0 ? 4 : st->cap_line_spans * 2;
        void *na = DS_REALLOC(st->line_spans,
                           new_cap * sizeof(*st->line_spans));
        if (na == NULL) {
            ds__v1__line_span__free_unpacked(m, &ds_pb_allocator);
            return DS_ERR_R(DS_ERR_OOM, "dsc: line_spans growth failed");
        }
        st->line_spans = na;
        memset((char *) st->line_spans + st->cap_line_spans * sizeof(*st->line_spans),
               0, (new_cap - st->cap_line_spans) * sizeof(*st->line_spans));
        st->cap_line_spans = new_cap;
    }
    st->line_spans[st->n_line_spans].node_id = m->node_id;
    st->line_spans[st->n_line_spans].ds_line = m->ds_line;
    st->line_spans[st->n_line_spans].ds_col  = m->ds_col;
    st->line_spans[st->n_line_spans].ds_file = NULL;
    st->line_spans[st->n_line_spans].module_id = m->module_id;
    st->n_line_spans++;
    ds__v1__line_span__free_unpacked(m, &ds_pb_allocator);
    return DS_OK_R;
}


/* [LCAP.1]'s registry. 12 and 17 to 19 are `reserved` in proto/capabilities.proto. */
static bool capability_known(int cap)
{
    return cap > DS_CAPABILITY_UNSPECIFIED
        && cap <= DS_CAPABILITY_STORAGE_HYDRATE_SAMPLES
        && cap != 12
        && !(cap >= 17 && cap <= 19);
}

/* [NLFC.10.1], [RDSC.16.2.7]. Every capability is built in but `regex`, which a build
 * linking the RE2 stub lacks. */
static bool build_has_capability(int cap)
{
    if (!capability_known(cap))
        return false;
    if (cap == DS_CAPABILITY_REGEX)
        return ds_re2_available();
    return true;
}

size_t ds_build_capabilities(ds_capability_t *out, size_t out_cap)
{
    size_t n = 0;
    for (int c = DS_CAPABILITY_REALTIME;
         c <= DS_CAPABILITY_STORAGE_HYDRATE_SAMPLES; c++) {
        if (!build_has_capability(c)) continue;
        if (out != NULL && n < out_cap) out[n] = (ds_capability_t) c;
        n++;
    }
    return n;
}

ds_result_t ds_engine_set_admission(ds_engine_t     *engine,
                                    ds_capability_t  cap,
                                    ds_admission_t   admit)
{
    if (engine == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    /* [NLFC.10.2], [NFCT.1.1] */
    if (engine->dsc_hash_valid)
        return DS_ERR_R(DS_ERR_STATE,
                        "ds_engine_set_admission: the engine already holds an "
                        "artefact, which its policy has judged (NLFC.10.2)");
    if (!capability_known((int) cap))
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds_engine_set_admission: not a capability (LCAP.1)");
    if (admit != DS_ADMIT_EITHER && admit != DS_ADMIT_TRUE_ONLY
        && admit != DS_ADMIT_FALSE_ONLY)
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds_engine_set_admission: not a ds_admission_t");
    engine->admission[cap] = (uint8_t) admit;
    return DS_OK_R;
}

/* [RDSC.16.2.3] */
static bool capb_list_well_formed(const Ds__V1__Capability *v, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if ((int) v[i] == DS_CAPABILITY_UNSPECIFIED) return false;
        if (i > 0 && (int) v[i] <= (int) v[i - 1]) return false;
    }
    return true;
}

static bool capb_list_has(const Ds__V1__Capability *v, size_t n, int cap)
{
    for (size_t i = 0; i < n; i++)
        if ((int) v[i] == cap) return true;
    return false;
}

/* The CapabilityInfo atom ([RDSC.16.2]). The build's capabilities come before the
 * shape ([RDSC.16.2.7]): a capability added after this build is well-formed for its
 * producer, and this build cannot run it. */
static ds_result_t handle_capb(struct ds_engine  *engine,
                                dsc_load_state_t  *st,
                                const uint8_t     *body,
                                size_t             body_len)
{
    /* A second CapabilityInfo's settings are the ones the engine keeps. */
    st->saw_capb = true;

    Ds__V1__CapabilityInfo *m =
        ds__v1__capability_info__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL)
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: CapabilityInfo body protobuf decode failed (RDSC.16.2.2)");

    int lacking = 0;
    for (size_t i = 0; i < m->n_requires; i++) {
        int c = (int) m->requires[i];
        if (!build_has_capability(c) && (lacking == 0 || c < lacking))
            lacking = c;
    }
    if (lacking != 0) {
        ds__v1__capability_info__free_unpacked(m, &ds_pb_allocator);
        ds_text_t d = ds_rete_engine_detail(engine->rete_engine);
        ds_text_str(&d, "dsc: this build lacks capability ");
        ds_text_i64(&d, lacking);
        ds_text_str(&d, " (proto/capabilities.proto#Capability), which the "
                        "artefact requires (RDSC.16.2.7)");
        return DS_ERR_R(DS_ERR_DSC_CAPABILITY_ABSENT,
                        ds_rete_engine_detail_text(&d,
                            "dsc: this build lacks a capability the artefact "
                            "requires (RDSC.16.2.7)"));
    }

    bool ok = capb_list_well_formed(m->enabled, m->n_enabled)
           && capb_list_well_formed(m->requires, m->n_requires);
    for (size_t i = 0; ok && i < m->n_requires; i++)
        ok = capb_list_has(m->enabled, m->n_enabled, (int) m->requires[i]);
    if (!ok) {
        ds__v1__capability_info__free_unpacked(m, &ds_pb_allocator);
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: CapabilityInfo lists out of order, repeated, unspecified, "
                        "or requiring what is not enabled (RDSC.16.2.3)");
    }

#define CAPB_ON(c) capb_list_has(m->enabled, m->n_enabled, (c))
    /* [NLFC.10.2]: after the build's capabilities and the shape, before any binding
       ([RDSC.16.2.9]). */
    for (int c = DS_CAPABILITY_REALTIME;
         c <= DS_CAPABILITY_STORAGE_HYDRATE_SAMPLES; c++) {
        bool on = CAPB_ON(c);
        uint8_t admit = engine->admission[c];
        if ((admit == DS_ADMIT_TRUE_ONLY && !on)
            || (admit == DS_ADMIT_FALSE_ONLY && on)) {
            ds__v1__capability_info__free_unpacked(m, &ds_pb_allocator);
            ds_text_t d = ds_rete_engine_detail(engine->rete_engine);
            ds_text_str(&d, "dsc: the integration does not admit capability ");
            ds_text_i64(&d, c);
            ds_text_str(&d, on ? " set true" : " set false");
            ds_text_str(&d, " (NLFC.10.2)");
            return DS_ERR_R(DS_ERR_BND_DIALECT_MISMATCH,
                            ds_rete_engine_detail_text(&d,
                                "dsc: the integration does not admit this "
                                "artefact's settings (NLFC.10.2)"));
        }
    }
    bool cap_nological   = !CAPB_ON(DS_CAPABILITY_LOGICAL);
    bool cap_nolinscan   = !CAPB_ON(DS_CAPABILITY_LINEAR_SCAN);
    bool cap_dynamic_ttl =  CAPB_ON(DS_CAPABILITY_DYNAMIC_TTL);
    bool cap_realtime    =  CAPB_ON(DS_CAPABILITY_REALTIME);
    bool cap_constspace  =  CAPB_ON(DS_CAPABILITY_CONSTSPACE);
#undef CAPB_ON
    ds__v1__capability_info__free_unpacked(m, &ds_pb_allocator);

    ds_engine_apply_cap_flags(engine,
                              cap_nological, cap_nolinscan,
                              cap_dynamic_ttl, cap_realtime,
                              cap_constspace);

    /* [LCSP.6.2]: pending_rt arms set_wm_max to switch on the slab-pool allocator
     * when the integrator supplies N_max. */
    if (cap_constspace && engine->rete_engine &&
        !engine->rete_engine->rt_mode) {
        engine->rete_engine->pending_rt = true;
    }
    return DS_OK_R;
}

static ds_result_t handle_dsrt(struct ds_engine *engine,
                                const uint8_t    *body,
                                size_t            body_len)
{
    return ds_dsrt_handle_atom(engine, body, body_len);
}

/* [RDSC.3.6]: the SHA-256 of the artefact with this field's 32 bytes zeroed in place.
 * A compatibility check, not a defence: a .dsc is trusted input. The verified field is
 * the session's hash ([RBND.3.1]).
 *
 * Located by walking the raw body, so the zeroed range is where the bytes sit. */
static ds_result_t dsc_verify_self_hash(dsc_load_state_t *st,
                                        const uint8_t    *body,
                                        size_t            body_len)
{
    const uint8_t *field = NULL;
    bool           field_ok = false;
    size_t         occurrences = 0;
    size_t         pos = 0;

    while (pos < body_len) {
        ds_pbf_field_t f;
        if (ds_pbf_next_field(body, body_len, pos, &f) != DS_PBF_OK) {
            return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                            "dsc: DscHeader body is not a well-formed message (RDSC.3.6)");
        }
        if (f.field == 7u && ++occurrences == 1u) {
            field    = f.val;
            field_ok = f.wire == 2u && f.val_len == 32u;
        }
        pos = f.next;
    }
    /* [RDSC.9.5] */
    if (occurrences > 1u) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: DscHeader body holds dsc_sha256 more than once");
    }
    if (occurrences == 0u) {
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: header carries no dsc_sha256 (RDSC.3.6)");
    }
    if (!field_ok || field == NULL) {
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: dsc_sha256 is not 32 bytes (RDSC.3.6)");
    }

    const size_t   off = (size_t)(field - st->data);
    const uint8_t  zeros[32] = {0};
    ds_sha256_ctx_t sealed;
    uint8_t         sealed_digest[32];

    ds_sha256_init(&sealed);
    ds_sha256_update(&sealed, st->data, off);
    ds_sha256_update(&sealed, zeros, sizeof zeros);
    ds_sha256_update(&sealed, st->data + off + 32u, st->len - off - 32u);
    ds_sha256_final(&sealed, sealed_digest);

    if (memcmp(sealed_digest, field, 32u) != 0) {
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: dsc_sha256 does not match the artefact — it changed "
                        "after the compiler sealed it (RDSC.3.6)");
    }
    memcpy(st->header_sha256, field, 32u);
    return DS_OK_R;
}

/* A member is what protoc generated into the enum's descriptor. */
bool ds_binding_capabilities_well_formed(const uint32_t *caps, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        const uint32_t c = caps[i];
        if (c == 0u || c > (uint32_t) INT32_MAX ||
            protobuf_c_enum_descriptor_get_value(&ds__v1__capability__descriptor,
                                                 (int) c) == NULL)
            return false;
        if (i > 0 && c <= caps[i - 1])
            return false;
    }
    return true;
}

/* [RDSC.3], [RDSC.10] */
static ds_result_t handle_dsco(struct ds_engine *engine,
                                dsc_load_state_t *st,
                                const uint8_t    *body,
                                size_t            body_len)
{
    /* [RDSC.9.12]: `compiler_version` is judged before the version gate, which would
       refuse an ill-formed one as another release. */
    if (ds_pb_rdsc_11_4_judge(&ds__v1__dsc_header__descriptor, NULL, 0u, body,
                              body_len) == DS_PB_JUDGE_BAD_STRING)
        return DS_ERR_R(DS_ERR_DSC_DECODE, RDSC_9_12_BAD_STRING("DscHeader"));
    Ds__V1__DscHeader *h =
        ds__v1__dsc_header__unpack(&ds_pb_allocator, body_len, body);
    if (h == NULL) {
        return DS_ERR_R(DS_ERR_DSC_DECODE,
                        "dsc: DscHeader body protobuf decode failed");
    }
    /* [LDET.1.10]: a runtime reads its own minor series and nothing else. */
    bool version_ok =
        ds_version_series_match(h->compiler_version, ds_libds_version);
    char version_seen[64];
    version_seen[0] = '\0';
    if (h->compiler_version != NULL) {
        strncpy(version_seen, h->compiler_version, sizeof(version_seen) - 1);
        version_seen[sizeof(version_seen) - 1] = '\0';
    }
    /* [RDSC.3.10] */
    const uint32_t fault_fact_sites = h->fault_fact_sites;
    /* [RDSC.3.7]: the length only. */
    const size_t def_sha_len = h->dialect_def_sha256.len;
    /* [RBND.1.3]: kept as written, for the session header. A single-artefact load
       compares nothing ([RBND.5.4]). */
    const size_t n_header_caps = h->n_capabilities;
    if (def_sha_len == 32u)
        memcpy(st->header_def_sha256, h->dialect_def_sha256.data, 32u);
    for (size_t i = 0; i < n_header_caps && i < DS_BINDING_CAPABILITIES_MAX; i++)
        st->header_caps[i] = (uint32_t) h->capabilities[i];
    st->n_header_caps = n_header_caps;
    ds__v1__dsc_header__free_unpacked(h, &ds_pb_allocator);
    if (!version_ok) {
        /* Both versions, which also tells another release from a build whose two
           halves disagree. */
        ds_text_t d = ds_rete_engine_detail(engine->rete_engine);
        ds_text_str(&d, "dsc: artefact was compiled by DS ");
        ds_text_str(&d, version_seen[0] ? version_seen : "(unstamped)");
        ds_text_str(&d, "; this runtime is ");
        ds_text_str(&d, ds_libds_version);
        ds_text_str(&d, ", and reads only its own <major>.<minor>. series "
                        "([LDET.1.10]). Rebuild the artefact against the release "
                        "you are running — or, if these should be the same build, "
                        "one half of it was not stamped.");
        return DS_ERR_R(DS_ERR_DSC_VERSION, ds_rete_engine_detail_text(&d,
                 "dsc: artefact was compiled by another DS series ([LDET.1.10])"));
    }
    /* After the version ([RDSC.9.2]), before any later atom. */
    if (def_sha_len != 32u) {
        return DS_ERR_R(DS_ERR_BND_INCOMPLETE,
                        "dsc: dialect_def_sha256 is not 32 bytes ([RDSC.3.7])");
    }
    if (n_header_caps > DS_BINDING_CAPABILITIES_MAX) {
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: the header carries more capabilities than any "
                        "header may (RBND.1.3)");
    }
    if (!ds_binding_capabilities_well_formed(st->header_caps, n_header_caps)) {
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: the header's capabilities are not strictly "
                        "ascending over Capability's members (RBND.1.3)");
    }
    /* After every field check: a header wrong in both is refused for the field. */
    {
        ds_result_t hr = dsc_verify_self_hash(st, body, body_len);
        if (hr.status != DS_OK) return hr;
    }
    if (engine->rete_engine != NULL)
        engine->rete_engine->fault_fact_sites = fault_fact_sites;
    st->saw_dsco = true;
    return DS_OK_R;
}


static const struct ds_schema *dsc_find_built_schema(
    struct ds_schema *const *built, size_t n_built, const char *name)
{
    for (size_t i = 0; i < n_built; i++) {
        if (strcmp(built[i]->type_name, name) == 0) return built[i];
    }
    return NULL;
}

/* NULL when no DsSource matches: DsSource is optional ([RDSC.14]). */
static const char *dsc_lookup_dsrc_file(const dsc_load_state_t *st,
                                         uint32_t module_id)
{
    for (size_t i = 0; i < st->n_ds_sources; i++) {
        if (st->ds_sources[i].module_id == module_id) {
            return st->ds_sources[i].file;
        }
    }
    return NULL;
}

/* SCHEMA-typed slots' schema_ref stay NULL; the caller patches them after all schemas
   are built. */
static ds_result_t dsc_build_schema(const dsc_schema_acc_t *a,
                                     const dsc_load_state_t *st,
                                     struct ds_schema      **out)
{
    *out = NULL;

    /* [LFAC.1.1]. With both, SchemaTtl wins, as it does in `dsc_apply`. */
    ds_schema_lifecycle_t lc;
    uint64_t              ttl_ns;
    if (a->has_sttl) {
        lc = DS_SCHEMA_LIFECYCLE_TTL;
        ttl_ns = a->ttl_ns;
    } else if (a->has_slog) {
        lc = DS_SCHEMA_LIFECYCLE_LOGICAL;
        ttl_ns = 0;
    } else {
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: schema has no SchemaTtl or SchemaLogical (LFAC.1.1)");
    }

    struct ds_schema *s = DS_CALLOC(1, sizeof(*s));
    if (s == NULL) {
        return DS_ERR_R(DS_ERR_OOM, "dsc: schema alloc failed");
    }
    char *type_copy = DS_STRDUP(a->name);
    if (type_copy == NULL) {
        DS_FREE(s);
        return DS_ERR_R(DS_ERR_OOM, "dsc: type_name strdup failed");
    }
    ds_result_t rr = ds_schema_take_string(s, type_copy);
    if (rr.status != DS_OK) {
        DS_FREE(type_copy);
        DS_FREE(s);
        return rr;
    }
    s->type_name = type_copy;
    s->lifecycle = lc;
    s->ttl_ns    = ttl_ns;
    /* Their names are reserved ([LERR.9.4]); [NDBG.2.2]. */
    s->internal  = strcmp(type_copy, "ComputationError") == 0
                || strcmp(type_copy, "TypeError") == 0;

    if (a->n_slots > 0) {
        s->slots = DS_CALLOC(a->n_slots, sizeof(*s->slots));
        if (s->slots == NULL) {
            ds_schema_free(s);
            return DS_ERR_R(DS_ERR_OOM, "dsc: schema slots alloc failed");
        }
    }
    s->n_slots = (uint32_t) a->n_slots;
    for (size_t i = 0; i < a->n_slots; i++) {
        char *name_copy = DS_STRDUP(a->slots[i].slot_name);
        if (name_copy == NULL) {
            ds_schema_free(s);
            return DS_ERR_R(DS_ERR_OOM, "dsc: slot name strdup failed");
        }
        rr = ds_schema_take_string(s, name_copy);
        if (rr.status != DS_OK) {
            DS_FREE(name_copy);
            ds_schema_free(s);
            return rr;
        }
        s->slots[i].name               = name_copy;
        s->slots[i].type               = a->slots[i].type;
        s->slots[i].schema_ref         = NULL;
        s->slots[i].sampled            = a->slots[i].sampled;
        s->slots[i].retained           = a->slots[i].retained;
        s->slots[i].has_tolerance      = (a->slots[i].tolerance != 0.0);
        s->slots[i].tolerance          = a->slots[i].tolerance;
        s->slots[i].docstring          = NULL;
        s->slots[i].hydration_eligible = a->slots[i].hydration_eligible;
        s->slots[i].identity_role      = a->slots[i].identity_role;
        s->slots[i].nullable           = a->slots[i].nullable;
    }

    /* [RDSC.5.7]: absent DsSource leaves src_file NULL. */
    if (a->has_srcs) {
        const char *display = dsc_lookup_dsrc_file(st, a->module_id);
        if (display != NULL) {
            s->src_file = DS_STRDUP(display);
            if (s->src_file == NULL) {
                ds_schema_free(s);
                return DS_ERR_R(DS_ERR_OOM, "dsc: src_file strdup failed");
            }
        }
        s->src_line = a->src_line;
        s->src_col  = a->src_col;
    }

    /* Generated .proto (RDSC.5.8). Optional. */
    if (a->has_sdef && a->proto_text != NULL) {
        s->proto_source = DS_MALLOC(a->proto_text_len + 1);
        if (s->proto_source == NULL) {
            ds_schema_free(s);
            return DS_ERR_R(DS_ERR_OOM, "dsc: proto_source alloc failed");
        }
        if (a->proto_text_len > 0) {
            memcpy(s->proto_source, a->proto_text, a->proto_text_len);
        }
        s->proto_source[a->proto_text_len] = '\0';
        s->proto_source_len = a->proto_text_len;
    }

    *out = s;
    return DS_OK_R;
}


/* Whether `idx` is the highest module_id entry for its name. */
static bool dsc_schema_acc_is_active(const dsc_load_state_t *st, size_t idx)
{
    const dsc_schema_acc_t *me = &st->schemas[idx];
    for (size_t i = 0; i < st->n_schemas; i++) {
        if (i == idx) continue;
        if (strcmp(st->schemas[i].name, me->name) != 0) continue;
        if (st->schemas[i].module_id > me->module_id) return false;
    }
    return true;
}

/* [LSER.16.2]: whether a series' slot is Int-represented, from the Slot atoms: a
 * SeriesBackendWelfordEwma atom carries no element_type. The read adapters narrow by
 * it. */
static bool dsc_series_slot_is_int(const dsc_load_state_t *st,
                                   const char *schema_name,
                                   const char *slot_name)
{
    if (schema_name == NULL || slot_name == NULL) return false;
    for (size_t i = 0; i < st->n_schemas; i++) {
        if (strcmp(st->schemas[i].name, schema_name) != 0) continue;
        if (!dsc_schema_acc_is_active(st, i)) continue;
        const dsc_schema_acc_t *a = &st->schemas[i];
        for (size_t s = 0; s < a->n_slots; s++) {
            if (strcmp(a->slots[s].slot_name, slot_name) != 0) continue;
            /* [RDSC.5.5.8] */
            return a->slots[s].type == DS_SLOT_TYPE_INT
                || a->slots[s].type == DS_SLOT_TYPE_TIME
                || a->slots[s].type == DS_SLOT_TYPE_DATE
                || a->slots[s].type == DS_SLOT_TYPE_DURATION;
        }
        return false;
    }
    return false;
}

static bool dsc_rule_acc_is_active(const dsc_load_state_t *st, size_t idx)
{
    const dsc_rule_acc_t *me = &st->rules[idx];
    for (size_t i = 0; i < st->n_rules; i++) {
        if (i == idx) continue;
        if (strcmp(st->rules[i].rule_name, me->rule_name) != 0) continue;
        if (st->rules[i].module_id > me->module_id) return false;
    }
    return true;
}

/* [RDSC.8.7]: every AlphaNode names a schema that a schema_group in this artefact
   registers. The artefact alone decides, so not rete/loader.c's lookup in the
   engine's registry. */
static ds_result_t rdsc_8_7_alpha_schemas(struct ds_engine       *engine,
                                          const dsc_load_state_t *st)
{
    for (size_t i = 0; i < st->n_alfa_atoms; i++) {
        uint32_t node_id = 0;
        char    *name    = NULL;
        ds_result_t nr = ds_dsc_alfa_schema_name(st->alfa_atoms[i].body,
                                              st->alfa_atoms[i].len,
                                              &node_id, &name);
        if (nr.status != DS_OK) return nr;
        bool declared = false;
        for (size_t k = 0; k < st->n_schemas && !declared; k++) {
            const dsc_schema_acc_t *a = &st->schemas[k];
            declared = (a->has_slog || a->has_sttl)
                       && strcmp(a->name, name) == 0;
        }
        if (!declared) {
            ds_text_t d = ds_rete_engine_detail(engine->rete_engine);
            ds_text_str(&d, "dsc: AlphaNode ");
            ds_text_u64(&d, node_id);
            ds_text_str(&d, " names schema '");
            ds_text_str(&d, name);
            ds_text_str(&d, "', which no schema group in the artefact "
                            "declares (RDSC.8.7)");
            DS_FREE(name);
            return DS_ERR_R(DS_ERR_DSC_DANGLING,
                            ds_rete_engine_detail_text(&d,
                                "dsc: an AlphaNode names a schema no schema "
                                "group in the artefact declares (RDSC.8.7)"));
        }
        DS_FREE(name);
    }
    return DS_OK_R;
}

/* [RDSC.8.7]: a rule_group's atoms name a rule that a TerminalNode in this artefact
   realizes ([RDSC.8.3]). Every accumulator is held to it, since the clause is about
   atoms. */
static ds_result_t rdsc_8_7_rule_groups(struct ds_engine       *engine,
                                        const dsc_load_state_t *st)
{
    if (st->n_rules == 0) return DS_OK_R;
    char      **realized   = NULL;
    size_t      n_realized = 0;
    ds_result_t r          = DS_OK_R;
    if (st->n_term_atoms > 0) {
        realized = DS_CALLOC(st->n_term_atoms, sizeof(*realized));
        if (realized == NULL)
            return DS_ERR_R(DS_ERR_OOM, "dsc: rule-group check alloc");
    }
    for (size_t i = 0; i < st->n_term_atoms; i++) {
        char *name = NULL;
        ds_result_t nr = ds_dsc_term_rule_name(st->term_atoms[i].body,
                                               st->term_atoms[i].len, &name);
        if (nr.status != DS_OK) { r = nr; goto done; }
        realized[n_realized++] = name;
    }
    for (size_t k = 0; k < st->n_rules; k++) {
        const char *rule = st->rules[k].rule_name;
        bool found = false;
        for (size_t i = 0; i < n_realized && !found; i++)
            found = strcmp(realized[i], rule) == 0;
        if (!found) {
            ds_text_t d = ds_rete_engine_detail(engine->rete_engine);
            ds_text_str(&d, "dsc: a rule_group atom names rule '");
            ds_text_str(&d, rule);
            ds_text_str(&d, "', which no TerminalNode in the artefact "
                            "realizes (RDSC.8.7)");
            r = DS_ERR_R(DS_ERR_DSC_DANGLING,
                         ds_rete_engine_detail_text(&d,
                             "dsc: a rule_group atom names a rule no "
                             "TerminalNode in the artefact realizes "
                             "(RDSC.8.7)"));
            goto done;
        }
    }
done:
    for (size_t i = 0; i < n_realized; i++) DS_FREE(realized[i]);
    DS_FREE(realized);
    return r;
}

static ds_result_t dsc_apply(struct ds_engine *engine,
                              dsc_load_state_t *st)
{
    {
        ds_result_t dr = rdsc_8_7_alpha_schemas(engine, st);
        if (dr.status != DS_OK) return dr;
        dr = rdsc_8_7_rule_groups(engine, st);
        if (dr.status != DS_OK) return dr;
    }

    size_t *active_schema_idx = NULL;
    size_t  n_active_schemas  = 0;
    if (st->n_schemas > 0) {
        active_schema_idx = DS_MALLOC(st->n_schemas * sizeof(*active_schema_idx));
        if (active_schema_idx == NULL) {
            return DS_ERR_R(DS_ERR_OOM, "dsc: active-schema index alloc");
        }
        for (size_t i = 0; i < st->n_schemas; i++) {
            if (!dsc_schema_acc_is_active(st, i)) continue;
            /* An ambient schema a host registered first stays the host's. */
            if (st->schemas[i].is_ambient) {
                const struct ds_schema *existing = NULL;
                ds_result_t fr = ds_schema_registry_find(
                    &engine->schemas, st->schemas[i].name, &existing);
                if (fr.status != DS_OK) {
                    DS_FREE(active_schema_idx);
                    return fr;
                }
                if (existing != NULL) continue;
            }
            active_schema_idx[n_active_schemas++] = i;
        }
    }

    struct ds_schema **built = NULL;
    if (n_active_schemas > 0) {
        built = DS_CALLOC(n_active_schemas, sizeof(*built));
        if (built == NULL) {
            DS_FREE(active_schema_idx);
            return DS_ERR_R(DS_ERR_OOM, "dsc: built-array alloc failed");
        }
    }
    size_t n_built = 0;
    for (size_t k = 0; k < n_active_schemas; k++) {
        ds_result_t br = dsc_build_schema(
            &st->schemas[active_schema_idx[k]], st, &built[k]);
        if (br.status != DS_OK) {
            for (size_t j = 0; j < n_built; j++) ds_schema_free(built[j]);
            DS_FREE(built);
            DS_FREE(active_schema_idx);
            return br;
        }
        n_built++;
    }

    for (size_t k = 0; k < n_active_schemas; k++) {
        const dsc_schema_acc_t *src = &st->schemas[active_schema_idx[k]];
        for (size_t s = 0; s < src->n_slots; s++) {
            const dsc_slot_acc_t *acc = &src->slots[s];
            if (acc->type != DS_SLOT_TYPE_SCHEMA) continue;
            const struct ds_schema *target =
                dsc_find_built_schema(built, n_built, acc->schema_ref_name);
            if (target == NULL) {
                ds_result_t fr = ds_schema_registry_find(
                    &engine->schemas, acc->schema_ref_name, &target);
                if (fr.status != DS_OK) {
                    for (size_t j = 0; j < n_built; j++) ds_schema_free(built[j]);
                    DS_FREE(built);
                    DS_FREE(active_schema_idx);
                    return fr;
                }
            }
            if (target == NULL) {
                for (size_t j = 0; j < n_built; j++) ds_schema_free(built[j]);
                DS_FREE(built);
                DS_FREE(active_schema_idx);
                return DS_ERR_R(DS_ERR_DSC_DANGLING,
                                "dsc: Slot.schema_ref names unknown schema");
            }
            built[k]->slots[s].schema_ref = target;
        }
    }
    DS_FREE(active_schema_idx);

    /* In the artefact's order, which a recording announces them in ([RFCS.5.1]).
       A synthetic schema ([LLEX.10.6.1]) goes only to the Rete registry below, so
       it stays invisible to fact_count and iteration. */
    for (size_t k = 0; k < n_built; k++) {
        if (ds_rete_name_is_synthetic(built[k]->type_name)) {
            ds_schema_free(built[k]);
            built[k] = NULL;
            continue;
        }
        ds_result_t ar = ds_schema_registry_add(&engine->schemas, built[k]);
        if (ar.status != DS_OK) {
            for (size_t j = k; j < n_built; j++) {
                if (built[j]) ds_schema_free(built[j]);
            }
            DS_FREE(built);
            return ar;
        }
    }
    DS_FREE(built);

    /* [LCRS.6.2.4] */
    for (size_t i = 0; i < st->n_responses; i++) {
        const struct ds_schema *rs = NULL;
        ds_result_t fr = ds_schema_registry_find(
            &engine->schemas, st->responses[i], &rs);
        if (fr.status == DS_OK && rs != NULL)
            ((struct ds_schema *)rs)->call_response = true;
    }

    /* Indices first: the move below NULLs the rule_name the active check reads. */
    size_t *active_rule_idx = NULL;
    size_t  n_active_rules  = 0;
    if (st->n_rules > 0) {
        active_rule_idx = DS_MALLOC(st->n_rules * sizeof(*active_rule_idx));
        if (active_rule_idx == NULL) {
            return DS_ERR_R(DS_ERR_OOM, "dsc: active-rule index alloc");
        }
        for (size_t i = 0; i < st->n_rules; i++) {
            if (dsc_rule_acc_is_active(st, i)) {
                active_rule_idx[n_active_rules++] = i;
            }
        }
    }
    for (size_t k = 0; k < n_active_rules; k++) {
        dsc_rule_acc_t *acc = &st->rules[active_rule_idx[k]];
        if (engine->n_rule_metas == engine->cap_rule_metas) {
            size_t new_cap = engine->cap_rule_metas == 0
                                ? 4 : engine->cap_rule_metas * 2;
            struct ds_rule_meta *na =
                DS_REALLOC(engine->rule_metas, new_cap * sizeof(*na));
            if (na == NULL) {
                DS_FREE(active_rule_idx);
                return DS_ERR_R(DS_ERR_OOM,
                                "dsc: rule_metas growth failed");
            }
            memset(na + engine->cap_rule_metas, 0,
                   (new_cap - engine->cap_rule_metas) * sizeof(*na));
            engine->rule_metas     = na;
            engine->cap_rule_metas = new_cap;
        }
        struct ds_rule_meta *m = &engine->rule_metas[engine->n_rule_metas++];
        m->rule_name      = acc->rule_name;      acc->rule_name      = NULL;
        m->has_cool       = acc->has_cool;
        m->cool_window_ns = acc->cool_window_ns;
        m->has_srcr       = acc->has_srcr;
        m->src_line       = acc->src_line;
        m->src_col        = acc->src_col;
        m->has_dnam       = acc->has_dnam;
        m->debug_name_template = acc->debug_name_template;
        acc->debug_name_template = NULL;
        if (acc->has_srcr) {
            const char *display = dsc_lookup_dsrc_file(st, acc->module_id);
            if (display != NULL) {
                m->src_file = DS_STRDUP(display);
                if (m->src_file == NULL) {
                    DS_FREE(active_rule_idx);
                    return DS_ERR_R(DS_ERR_OOM,
                                    "dsc: rule src_file strdup failed");
                }
            } else {
                m->src_file = NULL;
            }
        } else {
            m->src_file = NULL;
        }
    }
    DS_FREE(active_rule_idx);


    /* Before the ds_sources move, which NULLs the file each span looks up. */
    if (st->n_line_spans > 0) {
        engine->line_spans = DS_MALLOC(st->n_line_spans *
                                    sizeof(*engine->line_spans));
        if (engine->line_spans == NULL) {
            return DS_ERR_R(DS_ERR_OOM, "dsc: engine line_spans alloc failed");
        }
        engine->cap_line_spans = st->n_line_spans;
        /* Counted as filled, so ds_engine_free releases what a failed copy leaves. */
        for (size_t i = 0; i < st->n_line_spans; i++) {
            engine->line_spans[i].node_id = st->line_spans[i].node_id;
            engine->line_spans[i].ds_line = st->line_spans[i].ds_line;
            engine->line_spans[i].ds_col  = st->line_spans[i].ds_col;
            engine->line_spans[i].module_id = st->line_spans[i].module_id;
            engine->line_spans[i].ds_file = NULL;
            engine->n_line_spans = i + 1;
            const char *display = dsc_lookup_dsrc_file(
                st, st->line_spans[i].module_id);
            if (display != NULL) {
                engine->line_spans[i].ds_file = DS_STRDUP(display);
                if (engine->line_spans[i].ds_file == NULL) {
                    return DS_ERR_R(DS_ERR_OOM,
                                    "dsc: line_span ds_file strdup failed");
                }
            }
        }
    }
    if (st->n_ds_sources > 0) {
        engine->ds_sources = DS_MALLOC(st->n_ds_sources *
                                    sizeof(*engine->ds_sources));
        if (engine->ds_sources == NULL) {
            return DS_ERR_R(DS_ERR_OOM, "dsc: engine ds_sources alloc failed");
        }
        engine->cap_ds_sources = st->n_ds_sources;
        for (size_t i = 0; i < st->n_ds_sources; i++) {
            engine->ds_sources[i].module_id = st->ds_sources[i].module_id;
            engine->ds_sources[i].file      = st->ds_sources[i].file;
            engine->ds_sources[i].text      = st->ds_sources[i].text;
            engine->ds_sources[i].text_len  = st->ds_sources[i].text_len;
            st->ds_sources[i].file = NULL;
            st->ds_sources[i].text = NULL;
        }
        engine->n_ds_sources = st->n_ds_sources;
    }

    if (st->n_series_decls > 0) {
        engine->series_decls = DS_MALLOC(
            st->n_series_decls * sizeof(*engine->series_decls));
        if (engine->series_decls == NULL) {
            return DS_ERR_R(
                DS_ERR_OOM,
                "dsc: engine series_decls alloc failed");
        }
        engine->cap_series_decls = st->n_series_decls;
        for (size_t i = 0; i < st->n_series_decls; i++) {
            engine->series_decls[i].atom_field =
                st->series_decls[i].atom_field;
            engine->series_decls[i].module_id =
                st->series_decls[i].module_id;
            engine->series_decls[i].schema_name =
                st->series_decls[i].schema_name;
            engine->series_decls[i].slot_name =
                st->series_decls[i].slot_name;
            engine->series_decls[i].identity_slot_name =
                st->series_decls[i].identity_slot_name;
            engine->series_decls[i].window_ns =
                st->series_decls[i].window_ns;
            engine->series_decls[i].persist_ns =
                st->series_decls[i].persist_ns;
            engine->series_decls[i].element_type =
                st->series_decls[i].element_type;
            engine->series_decls[i].max_samples =
                st->series_decls[i].max_samples;
            engine->series_decls[i].time_model =
                st->series_decls[i].time_model;
            engine->series_decls[i].gap_policy =
                st->series_decls[i].gap_policy;
            engine->series_decls[i].null_policy =
                st->series_decls[i].null_policy;
            /* [LSER.16.2]: here, since the engine keeps no schema accumulator. */
            engine->series_decls[i].slot_is_int = dsc_series_slot_is_int(
                st, st->series_decls[i].schema_name,
                st->series_decls[i].slot_name);
            st->series_decls[i].schema_name = NULL;
            st->series_decls[i].slot_name = NULL;
            st->series_decls[i].identity_slot_name = NULL;
        }
        /* [LSER.8.5.1]: one sample per fact for each (schema, slot, identity slot),
           whatever the number of slots. The loader refused a NULL name above. */
        for (size_t i = 0; i < st->n_series_decls; i++) {
            const struct ds_series_decl_record *d = &engine->series_decls[i];
            bool repeat = false;
            for (size_t j = 0; j < i && !repeat; j++) {
                const struct ds_series_decl_record *p = &engine->series_decls[j];
                repeat = strcmp(p->schema_name, d->schema_name) == 0
                         && strcmp(p->slot_name, d->slot_name) == 0
                         && strcmp(p->identity_slot_name,
                                   d->identity_slot_name) == 0;
            }
            engine->series_decls[i].group_repeat = repeat;
        }
        engine->n_series_decls = st->n_series_decls;
    }

    /* [LCRS.6.2.1] */
    if (st->n_services > 0) {
        engine->call_services   = st->services;
        engine->n_call_services = st->n_services;
        st->services = NULL;
        st->n_services = st->cap_services = 0;
    }

    if (engine->rete_engine) {

        for (size_t i = 0; i < st->n_schemas; i++) {
            if (!dsc_schema_acc_is_active(st, i)) continue;
            const dsc_schema_acc_t *a = &st->schemas[i];

            ds_rete_slot_desc_t *rslots = NULL;
            if (a->n_slots > 0) {
                rslots = DS_CALLOC(a->n_slots, sizeof(*rslots));
                if (!rslots) return DS_ERR_R(DS_ERR_OOM, "dsc: rete slot desc alloc");
                for (size_t s = 0; s < a->n_slots; s++) {
                    rslots[s].name        = a->slots[s].slot_name;
                    rslots[s].sampled     = a->slots[s].sampled;
                    rslots[s].retained    = a->slots[s].retained;
                    rslots[s].tolerance   = a->slots[s].tolerance;
                    rslots[s].is_key      =
                        (a->slots[s].identity_role == DS_IDENTITY_KEY);
                    rslots[s].is_marked   =
                        (a->slots[s].identity_role != DS_IDENTITY_UNSPECIFIED);
                    rslots[s].is_engine   =
                        (a->slots[s].identity_role == DS_IDENTITY_ENGINE);
                    rslots[s].nullable    = a->slots[s].nullable;
                    rslots[s].capacity    = a->slots[s].capacity;  /* LSTR.11.3 */
                    rslots[s].duration    =
                        (a->slots[s].type == DS_SLOT_TYPE_DURATION); /* NFCT.2.3 */
                    rslots[s].time        =
                        (a->slots[s].type == DS_SLOT_TYPE_TIME);  /* LTIM.1.1.3 */
                    rslots[s].type =
                        ds_rete_val_kind_for_slot_type(a->slots[s].type);
                }
                /* [RDSC.5.5.9]: handle_slot decoded each conversion already,
                   so only an allocation can fail here. */
                ds_result_t cr = DS_OK_R;
                for (size_t s = 0; s < a->n_slots && cr.status == DS_OK; s++) {
                    if (a->slots[s].to_stored == NULL) continue;
                    cr = ds_dsc_slot_conversion(engine->rete_engine,
                                                a->slots[s].to_stored,
                                                &rslots[s].to_stored);
                    if (cr.status == DS_OK)
                        cr = ds_dsc_slot_conversion(engine->rete_engine,
                                                    a->slots[s].from_stored,
                                                    &rslots[s].from_stored);
                }
                if (cr.status != DS_OK) {
                    dsc_rslots_free_conversions(rslots, a->n_slots);
                    DS_FREE(rslots);
                    return cr;
                }
            }
            /* [RDSC.5.4.5]: the atom's lifecycle decides the scope, and the slots'
               roles key the identity. */
            ds_rete_scope_t scope;
            if (a->has_sttl) {
                scope = DS_RETE_SCOPE_TTL;
            } else if (a->is_ambient) {
                scope = DS_RETE_SCOPE_AMBIENT;
            } else {
                switch (a->lifecycle) {
                case DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_LOGICAL:
                    scope = DS_RETE_SCOPE_LOGICAL; break;
                case DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_ACTIVATION:
                    scope = DS_RETE_SCOPE_ACTIVATION; break;
                case DS__V1__SCHEMA_LIFECYCLE__SCHEMA_LIFECYCLE_EXPLICIT:
                default:
                    scope = DS_RETE_SCOPE_PLAIN; break;
                }
            }
            ds_rete_schema_t *out_schema = NULL;
            ds_result_t rr = ds_rete_schema_register(engine->rete_engine,
                                                      a->name, scope,
                                                      a->has_sttl ? (int64_t)a->ttl_ns : 0,
                                                      rslots, (uint16_t)a->n_slots,
                                                      &out_schema);
            /* A registered schema owns its conversions; a refused one does
               not, and they go with the array. */
            if (rr.status != DS_OK && rslots != NULL)
                dsc_rslots_free_conversions(rslots, a->n_slots);
            DS_FREE(rslots);
            if (rr.status != DS_OK && rr.status != DS_ERR_STATE)
                return rr;
        }

        if (st->n_alfa_atoms == 0 && st->n_beta_atoms == 0
            && st->n_term_atoms == 0) {
            return DS_OK_R;
        }

        dsc_rete_atom_t *alfa_blobs = NULL, *beta_blobs = NULL, *term_blobs = NULL;
        if (st->n_alfa_atoms) {
            alfa_blobs = DS_CALLOC(st->n_alfa_atoms, sizeof(*alfa_blobs));
            if (!alfa_blobs) { return DS_ERR_R(DS_ERR_OOM, "dsc: alfa_blobs"); }
            for (size_t i = 0; i < st->n_alfa_atoms; i++) {
                alfa_blobs[i].body = st->alfa_atoms[i].body;
                alfa_blobs[i].len  = st->alfa_atoms[i].len;
                alfa_blobs[i].offset = st->alfa_atoms[i].offset;
            }
        }
        if (st->n_beta_atoms) {
            beta_blobs = DS_CALLOC(st->n_beta_atoms, sizeof(*beta_blobs));
            if (!beta_blobs) { DS_FREE(alfa_blobs); return DS_ERR_R(DS_ERR_OOM, "dsc: beta_blobs"); }
            for (size_t i = 0; i < st->n_beta_atoms; i++) {
                beta_blobs[i].body = st->beta_atoms[i].body;
                beta_blobs[i].len  = st->beta_atoms[i].len;
                beta_blobs[i].offset = st->beta_atoms[i].offset;
            }
        }
        if (st->n_term_atoms) {
            term_blobs = DS_CALLOC(st->n_term_atoms, sizeof(*term_blobs));
            if (!term_blobs) { DS_FREE(beta_blobs); DS_FREE(alfa_blobs); return DS_ERR_R(DS_ERR_OOM, "dsc: term_blobs"); }
            for (size_t i = 0; i < st->n_term_atoms; i++) {
                term_blobs[i].body = st->term_atoms[i].body;
                term_blobs[i].len  = st->term_atoms[i].len;
                term_blobs[i].offset = st->term_atoms[i].offset;
            }
        }

        ds_result_t nr = ds_dsc_apply_rete_network(
            engine->rete_engine,
            alfa_blobs, (uint32_t)st->n_alfa_atoms,
            beta_blobs, (uint32_t)st->n_beta_atoms,
            term_blobs, (uint32_t)st->n_term_atoms);

        DS_FREE(term_blobs); DS_FREE(beta_blobs); DS_FREE(alfa_blobs);
        if (nr.status != DS_OK) return nr;
    }

    /* [RDSC.9.8]: a failure to build this index fails the load, though a lookup
       could survive by scanning. */
    ds_result_t mr = ds_engine_rule_meta_map_rebuild(engine);
    if (mr.status != DS_OK) return mr;

    /* Last: it walks the finished network. A rejected pattern fails the load. */
    if (engine->rete_engine) {
        ds_result_t rr = ds_rete_regex_precompile(engine->rete_engine);
        if (rr.status != DS_OK) return rr;
    }

    return DS_OK_R;
}

/* [RDSC.9.5], [RDSC.9.12]: the descriptor each atom this file's handlers unpack is
   judged by, with *detail and *bad_string the refusals naming it; NULL for the
   rest. Other atoms are judged where they are decoded, or skipped unread. */
#define RDSC_9_5_NAMES(atom) \
    (*detail = RDSC_9_5_REPEATED(atom), *bad_string = RDSC_9_12_BAD_STRING(atom))

static const ProtobufCMessageDescriptor *rdsc_9_5_unpacked(uint32_t field,
                                                           const char **detail,
                                                           const char **bad_string)
{
    switch (field) {
    case DS_ATOM_SCHEMA_TTL:
        RDSC_9_5_NAMES("SchemaTtl");
        return &ds__v1__schema_ttl__descriptor;
    case DS_ATOM_SCHEMA_LOGICAL:
        RDSC_9_5_NAMES("SchemaLogical");
        return &ds__v1__schema_logical__descriptor;
    case DS_ATOM_SLOT:
        RDSC_9_5_NAMES("Slot");
        return &ds__v1__slot__descriptor;
    case DS_ATOM_HYDRATION:
        RDSC_9_5_NAMES("Hydration");
        return &ds__v1__hydration__descriptor;
    case DS_ATOM_SCHEMA_SOURCE:
        RDSC_9_5_NAMES("SchemaSource");
        return &ds__v1__schema_source__descriptor;
    case DS_ATOM_RULE_COOLDOWN:
        RDSC_9_5_NAMES("RuleCooldown");
        return &ds__v1__rule_cooldown__descriptor;
    case DS_ATOM_RULE_SOURCE:
        RDSC_9_5_NAMES("RuleSource");
        return &ds__v1__rule_source__descriptor;
    case DS_ATOM_RULE_DEBUG_NAME:
        RDSC_9_5_NAMES("RuleDebugName");
        return &ds__v1__rule_debug_name__descriptor;
    case DS_ATOM_CAPABILITY_INFO:
        RDSC_9_5_NAMES("CapabilityInfo");
        return &ds__v1__capability_info__descriptor;
    case DS_ATOM_LINE_SPAN:
        RDSC_9_5_NAMES("LineSpan");
        return &ds__v1__line_span__descriptor;
#ifndef DS_MICRO
    case DS_ATOM_SCHEMA_DEF:
        RDSC_9_5_NAMES("SchemaDef");
        return &ds__v1__schema_def__descriptor;
    case DS_ATOM_DS_SOURCE:
        RDSC_9_5_NAMES("DsSource");
        return &ds__v1__ds_source__descriptor;
#endif
    case DS_ATOM_SERIES_BACKEND_WELFORD_EWMA:
        RDSC_9_5_NAMES("SeriesBackendWelfordEwma");
        return &ds__v1__series_backend_welford_ewma__descriptor;
    case DS_ATOM_SERIES_BACKEND_RING_BUFFER:
        RDSC_9_5_NAMES("SeriesBackendRingBuffer");
        return &ds__v1__series_backend_ring_buffer__descriptor;
    case DS_ATOM_SERIES_BACKEND_MONOTONIC_DEQUE:
        RDSC_9_5_NAMES("SeriesBackendMonotonicDeque");
        return &ds__v1__series_backend_monotonic_deque__descriptor;
    case DS_ATOM_SERIES_BACKEND_FIFO_DEQUE:
        RDSC_9_5_NAMES("SeriesBackendFifoDeque");
        return &ds__v1__series_backend_fifo_deque__descriptor;
    case DS_ATOM_SERIES_BACKEND_RESERVOIR:
        RDSC_9_5_NAMES("SeriesBackendReservoir");
        return &ds__v1__series_backend_reservoir__descriptor;
    case DS_ATOM_SERIES_BACKEND_INTERVAL_PULSE:
        RDSC_9_5_NAMES("SeriesBackendIntervalPulse");
        return &ds__v1__series_backend_interval_pulse__descriptor;
    case DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL:
        RDSC_9_5_NAMES("SeriesBackendNumericIntegral");
        return &ds__v1__series_backend_numeric_integral__descriptor;
    default:
        return NULL;
    }
}

/* [RDSC.9.12]: DsSource's `data` and SchemaDef's `proto_source`, field 3 of each,
   judged as strings under COMPRESSION_NONE only: handle_dsrc and handle_sdef refuse
   any other compression ([RDSC.4.5.1]). The last occurrence of a field is its value.
   True for any other atom. */
static bool rdsc_9_12_text_bytes_ok(uint32_t field, const uint8_t *body,
                                    size_t len)
{
#ifdef DS_MICRO
    (void) field; (void) body; (void) len;
    return true;
#else
    if (field != DS_ATOM_DS_SOURCE && field != DS_ATOM_SCHEMA_DEF) return true;
    uint64_t compression = 0u;               /* absent: COMPRESSION_UNSPECIFIED */
    const uint8_t *text = NULL;
    size_t text_len = 0;
    size_t pos = 0;
    for (;;) {
        ds_pbf_field_t f;
        if (ds_pbf_next_field(body, len, pos, &f) != DS_PBF_OK) break;
        if (f.field == 2u && f.wire == 0u) {
            compression = f.u64;
        } else if (f.field == 3u && f.wire == 2u) {
            text = f.val;
            text_len = f.val_len;
        }
        pos = f.next;
    }
    if (compression != (uint64_t) DS__V1__COMPRESSION__COMPRESSION_NONE
        || text == NULL)
        return true;
    return rdsc_9_12_text_ok(text, text_len);
#endif
}

/* [RDSC.11.4]'s judge, before the unpack: true, with *out the refusal. A body that
   does not frame is left to the unpack. */
static bool rdsc_9_5_pre_unpack(uint32_t field, const uint8_t *body,
                                size_t len, ds_result_t *out)
{
    const char *repeated = NULL, *bad_string = NULL;   /* string literals */
    const ProtobufCMessageDescriptor *desc =
        rdsc_9_5_unpacked(field, &repeated, &bad_string);
    if (desc == NULL) return false;
    /* [RDSC.11.3]: a Slot's conversions are Exprs ([RDSC.5.5.9]), bounded
       here because protobuf-c's unpack has no recursion bound. */
    const ProtobufCMessageDescriptor *nested =
        field == DS_ATOM_SLOT ? &ds__v1__expr__descriptor : NULL;
    switch (ds_pb_rdsc_11_4_judge(desc, nested, nested != NULL ? 48u : 0u,
                                  body, len)) {
    case DS_PB_JUDGE_REPEATED:
        *out = DS_ERR_R(DS_ERR_DSC_DECODE, repeated);
        return true;
    case DS_PB_JUDGE_BAD_STRING:
        *out = DS_ERR_R(DS_ERR_DSC_DECODE, bad_string);
        return true;
    case DS_PB_JUDGE_TOO_DEEP:
        *out = DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: a Slot conversion's Expr is nested deeper than "
                        "48 (RDSC.11.3)");
        return true;
    case DS_PB_JUDGE_DECODES:
        if (!rdsc_9_12_text_bytes_ok(field, body, len)) {
            *out = DS_ERR_R(DS_ERR_DSC_DECODE, bad_string);
            return true;
        }
        return false;
    default:
        return false;
    }
}

ds_result_t ds_dsc_load(struct ds_engine *engine,
                        const uint8_t    *data,
                        size_t            len,
                        ds_dsc_binding_t *out_binding)
{
    /* Everything from here is a refusal of the artefact, and spends the engine
       ([RDSC.9.8]). [RFCS.19.4]: the first atom's field number is the container's
       type. */
    {
        ds_pbf_atom_t first;
        switch (ds_pbf_next_atom(data, len, 0, &first)) {
        case DS_PBF_OK:
            if (first.field != DS_ATOM_DSC_HEADER) {
                return DS_ERR_R(DS_ERR_DSC_BAD_MAGIC,
                                "dsc: first atom is not DscHeader (RDSC.1.4)");
            }
            break;
        case DS_PBF_EOF:
            return DS_ERR_R(DS_ERR_DSC_TRUNCATED,
                            "dsc: no complete first atom (RDSC.9.7)");
        case DS_PBF_MALFORMED:
        default:
            /* [RDSC.11.1] */
            if (first.short_body) {
                return DS_ERR_R(DS_ERR_DSC_DECODE,
                                "dsc: the first atom's body ends inside its "
                                "frame (RDSC.11.1)");
            }
            return DS_ERR_R(DS_ERR_DSC_BAD_MAGIC,
                            "dsc: not a valid container (RDSC.11.1)");
        }
    }

    dsc_load_state_t st = {0};
    st.data = data;
    st.len  = len;
    size_t pos = 0;

    /* [RDSC.9.3] */
    while (pos < len) {
        ds_pbf_atom_t  atom;
        uint32_t       blen;
        const uint8_t *body;

        /* [RDSC.11.1]: no padding; every byte after an atom begins a frame. */
        switch (ds_pbf_next_atom(data, len, pos, &atom)) {
        case DS_PBF_OK:
            break;
        case DS_PBF_EOF:
            /* [RDSC.9.7]: ds_pbf_next_atom reports a partial trailing atom as EOF
               for a stream's sake ([RFCS.19.2]); here it is a truncated bundle. */
            dsc_load_state_dispose(&st);
            return DS_ERR_R(DS_ERR_DSC_TRUNCATED,
                            "dsc: truncated trailing atom — a rule bundle is "
                            "not appended to while read (RDSC.9.7)");
        case DS_PBF_MALFORMED:
        default:
            /* [RDSC.11.1] */
            dsc_load_state_dispose(&st);
            return atom.short_body
                ? DS_ERR_R(DS_ERR_DSC_DECODE,
                           "dsc: an atom's body ends inside its frame "
                           "(RDSC.11.1)")
                : DS_ERR_R(DS_ERR_DSC_DECODE,
                           "dsc: malformed atom frame (RDSC.11.1)");
        }

        /* [RFCS.19.3], [RDSC.11.1]: a number with no registry entry is no member of
           `Atom`'s oneof, so the frame is malformed. A first frame never reaches
           here: it must be a DscHeader. */
        if (ds_pbf_lookup(atom.field) == NULL) {
            dsc_load_state_dispose(&st);
            return DS_ERR_R(DS_ERR_DSC_DECODE,
                            "dsc: an atom's field number names no atom "
                            "(RDSC.11.1, RFCS.19.3)");
        }
        blen  = (uint32_t)atom.body_len;
        body  = atom.body;

        ds_result_t r;
        if (atom.field == DS_ATOM_DSC_HEADER) {
            r = handle_dsco(engine, &st, body, blen);
        } else if (!st.saw_dsco) {
            dsc_load_state_dispose(&st);
            return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                            "dsc: atom precedes DscHeader (RDSC.9.2)");
        } else if (rdsc_9_5_pre_unpack(atom.field, body, blen, &r)) {
            /* r is the refusal. */
        } else if (atom.field == DS_ATOM_SCHEMA_TTL) {
            r = handle_sttl(&st, body, blen);
        } else if (atom.field == DS_ATOM_SCHEMA_LOGICAL) {
            r = handle_slog(&st, body, blen);
        } else if (atom.field == DS_ATOM_SLOT) {
            r = handle_slot(&st, body, blen);
        } else if (atom.field == DS_ATOM_HYDRATION) {
            r = handle_hydr(&st, body, blen);
        } else if (atom.field == DS_ATOM_SCHEMA_SOURCE) {
            r = handle_srcs(&st, body, blen);
        } else if (atom.field == DS_ATOM_SCHEMA_DEF) {
#ifdef DS_MICRO
            r = DS_OK_R;
#else
            r = handle_sdef(&st, body, blen);
#endif
        } else if (atom.field == DS_ATOM_SERVICE_DEF) {
            r = handle_svcd(&st, body, blen);
        } else if (atom.field == DS_ATOM_INITIAL_FACT) {
            r = handle_initial(&st, false, body, blen);
        } else if (atom.field == DS_ATOM_INITIAL_CACHE_SEED) {
            r = handle_initial(&st, true, body, blen);
        } else if (atom.field == DS_ATOM_RULE_COOLDOWN) {
            r = handle_cool(&st, body, blen);
        } else if (atom.field == DS_ATOM_RULE_SOURCE) {
            r = handle_srcr(&st, body, blen);
        } else if (atom.field == DS_ATOM_RULE_DEBUG_NAME) {
            r = handle_dnam(&st, body, blen);
        } else if (atom.field == DS_ATOM_CAPABILITY_INFO) {
            r = handle_capb(engine, &st, body, blen);
        } else if (atom.field == DS_ATOM_REALTIME_CONTRACT) {
            r = handle_dsrt(engine, body, blen);
        } else if (atom.field == DS_ATOM_DS_SOURCE) {
#ifdef DS_MICRO
            r = DS_OK_R;
#else
            r = handle_dsrc(&st, body, blen);
#endif
        } else if (atom.field == DS_ATOM_LINE_SPAN) {
            r = handle_line(&st, body, blen);
        } else if (atom.field == DS_ATOM_DOC_STRING) {
            /* [RDSC.9.4], [RDSC.14.4.4] */
            log_skipped_atom(engine, atom.field, "DocString", pos,
                             ": tooling metadata (RDSC.14.4.4)");
            r = DS_OK_R;
        } else if (atom.field == DS_ATOM_DIALECT_INFO) {
            /* [RDSC.15.1]: informational; the engine executes under CapabilityInfo. */
            r = DS_OK_R;
        } else if (atom.field == DS_ATOM_SERIES_BACKEND_WELFORD_EWMA) {
            r = handle_sbwe(&st, body, blen);
        } else if (atom.field == DS_ATOM_SERIES_BACKEND_RING_BUFFER) {
            r = handle_sbrb(&st, body, blen);
        } else if (atom.field == DS_ATOM_SERIES_BACKEND_MONOTONIC_DEQUE) {
            r = handle_sbmd(&st, body, blen);
        } else if (atom.field == DS_ATOM_SERIES_BACKEND_FIFO_DEQUE) {
            r = handle_sbfd(&st, body, blen);
        } else if (atom.field == DS_ATOM_SERIES_BACKEND_RESERVOIR) {
            r = handle_sbrs(&st, body, blen);
        } else if (atom.field == DS_ATOM_SERIES_BACKEND_INTERVAL_PULSE) {
            r = handle_sbip(&st, body, blen);
        } else if (atom.field == DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL) {
            r = handle_sbni(&st, body, blen);
        } else if (atom.field == DS_ATOM_ALPHA_NODE) {
            r = ds_dsc_rete_body_decodes(DSC_RETE_ALPHA, body, blen);
            if (r.status == DS_OK) RETE_APPEND(&st, alfa, body, blen, pos, r);
        } else if (atom.field == DS_ATOM_BETA_NODE) {
            r = ds_dsc_rete_body_decodes(DSC_RETE_BETA, body, blen);
            if (r.status == DS_OK) RETE_APPEND(&st, beta, body, blen, pos, r);
        } else if (atom.field == DS_ATOM_TERMINAL_NODE) {
            r = ds_dsc_rete_body_decodes(DSC_RETE_TERMINAL, body, blen);
            if (r.status == DS_OK) RETE_APPEND(&st, term, body, blen, pos, r);
        } else if (atom.field == DS_ATOM_COMPILED_CODE) {
            /* [RDSC.4c.3]: skipped undecoded, whatever its `arch`. */
            log_skipped_atom(engine, atom.field, "CompiledCode", pos,
                             ": this edition runs no compiled code (RDSC.4c.3)");
            r = DS_OK_R;
        } else {
            /* [RDSC.9.4]: a registry atom this loader does not read, the test and
               oracle atoms among them ([RDSC.7.6]). Every number reaching here
               has an entry: one with none was refused above. */
            log_skipped_atom(engine, atom.field,
                             ds_pbf_lookup(atom.field)->message, pos,
                             ": this loader does not read it (RDSC.9.4)");
            r = DS_OK_R;
        }
        /* [RDSC.9.5]: a handler's decode refusal gains the frame's offset here. */
        r = ds_dsc_decode_at_offset(engine->rete_engine, r, pos, body, blen);
        if (r.status != DS_OK) {
            dsc_load_state_dispose(&st);
            return r;
        }
        pos = atom.next;
    }

    if (!st.saw_dsco) {
        dsc_load_state_dispose(&st);
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: missing DscHeader atom (RDSC.7.2)");
    }
    if (!st.saw_capb) {
        dsc_load_state_dispose(&st);
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "dsc: missing CapabilityInfo atom (RDSC.16.2.4)");
    }
    ds_result_t ar = dsc_apply(engine, &st);
    /* [LGRA.24.3]: the `initial:` items outlive the state. */
    struct dsc_initial *initial   = st.initial;
    size_t              n_initial = st.n_initial;
    st.initial = NULL;
    st.n_initial = st.cap_initial = 0;
    dsc_load_state_dispose(&st);
    if (ar.status == DS_OK) {
        /* [RTCT.6.5]: +realtime iff a RealtimeContract atom. */
        if (engine->rete_engine) {
            bool cap_rt        = engine->rete_engine->cap_realtime;
            bool has_contract  = engine->rete_engine->has_contract;
            if (cap_rt && !has_contract) {
                ar = (ds_result_t){
                    DS_ERR_CONTRACT_MISSING,
                    "+realtime DSC missing RealtimeContract atom (see RTCT.6.3)"
                };
            } else if (!cap_rt && has_contract) {
                ar = (ds_result_t){
                    DS_ERR_CONTRACT_INVALID,
                    "RealtimeContract atom present but +realtime not declared in CapabilityInfo"
                };
            }
        }
    }
    if (ar.status == DS_OK) {
        if (engine->rete_engine && engine->rete_engine->has_contract)
            ar = ds_dsrt_apply_node_caps(engine);
    }
    /* [RDSC.16.2.8]: `requires` is trusted, never compared with what the content
       uses. */
    if (ar.status == DS_OK) ar = lgra_24_3_load(engine, &initial, &n_initial);
    dsc_initial_free(initial, n_initial);
    if (ar.status == DS_OK) {
        memcpy(out_binding->dsc_sha256, st.header_sha256, 32u);
        memcpy(out_binding->dialect_def_sha256, st.header_def_sha256, 32u);
        memcpy(out_binding->capabilities, st.header_caps,
               st.n_header_caps * sizeof st.header_caps[0]);
        out_binding->n_capabilities = st.n_header_caps;
    }
    return ar;
}

/* `*spend` comes back true for a load that failed once it had begun reading. */
static ds_result_t engine_load_dsc_body(ds_engine_t   *engine,
                                        const uint8_t *data,
                                        size_t         len,
                                        bool          *spend)
{
    *spend = false;
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (engine != NULL && engine->next_seq > 0) {
        return DS_ERR_R(DS_ERR_STATE,
                        "load_dsc: not permitted after the engine's first "
                        "stream event (NFCT.1.1)");
    }
    if (engine != NULL && engine->dsc_hash_valid) {
        return DS_ERR_R(DS_ERR_STATE,
                        "load_dsc: the engine already holds an artefact; an "
                        "engine holds one (NFCT.1.1)");
    }
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    if (data == NULL && len > 0) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "data must not be null when len > 0");
    }
    ds_dsc_binding_t binding;
    ds_result_t r = ds_dsc_load(engine, data, len, &binding);

    if (r.status != DS_OK) {
        *spend = true;
        return r;
    }

    /* [RBND.3.1]. Only on success: a spent engine's session header carries no tuple. */
    memcpy(engine->dsc_hash, binding.dsc_sha256, sizeof engine->dsc_hash);
    memcpy(engine->dsc_def_sha256, binding.dialect_def_sha256,
           sizeof engine->dsc_def_sha256);
    memcpy(engine->dsc_capabilities, binding.capabilities,
           binding.n_capabilities * sizeof binding.capabilities[0]);
    engine->n_dsc_capabilities = binding.n_capabilities;
    engine->dsc_hash_valid = true;
    return r;
}

/* [RDSC.9.8]: a load that failed once it had begun reading spends the engine, with
   no EngineError ([NCBK.2.11]). The latch is set after ds_api_leave, which would
   otherwise replace the load's own status with DS_ERR_ENGINE_HALTED. */
ds_result_t ds_engine_load_dsc(ds_engine_t   *engine,
                                const uint8_t *data,
                                size_t         len)
{
    bool spend = false;
    ds_api_enter(engine);
    ds_result_t r = ds_api_leave(engine,
                                 engine_load_dsc_body(engine, data, len, &spend));
    if (spend) {
        engine->halt_fault = DS_ENGINE_FAULT_UNSPECIFIED;
        engine->halted     = true;
    }
    return r;
}

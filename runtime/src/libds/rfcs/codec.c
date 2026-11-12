/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rfcs/codec.c — the RFCS fact-stream codec.
 *
 * The frame prefix's width depends on the field number and the body length, so it is
 * never a constant here: the offset comes from the framer that wrote it or the parse that
 * read it.
 */
#include <stdlib.h>
#include <string.h>

#include "rfcs.h"
#include "version_series.h"

#include "stream_header.pb-c.h"
#include "fact_assert.pb-c.h"
#include "fact_retract.pb-c.h"
#include "fact_emit.pb-c.h"
#include "fact_publish.pb-c.h"
#include "fact_withdraw.pb-c.h"
#include "call_issued.pb-c.h"
#include "fact_external.pb-c.h"
#include "engine_error.pb-c.h"       /* ComputationError */
#include "type_error.pb-c.h"
#include "bounds_error.pb-c.h"
#include "engine_fault.pb-c.h"       /* EngineError */
#include "cache_seed.pb-c.h"
#include "cache.h"
#include "schema.h"
#include "date_range.h"
#include "ds_text.h"
#include "internal/json.h"
#include "wm.h"
#include "engine.h"
#include "dispatcher.h"
#include "rete/intern.h"
#include "rete/schema_reg.h"
#include "rete/wm_rete.h"
#include "schema_def.pb-c.h"
#include "slot.pb-c.h"
#include "dsc/pbf_reader.h"
#include "dsc/pbf_writer.h"
#include "dsc/ds_pb_alloc.h"
#include "ds_alloc.h"
#include "sha256.h"
#include "binding.h"
#include "rete/engine.h"
#include "oa.h"

#define RFCS_OK            ((ds_result_t){ DS_OK, NULL })
#define RFCS_ERR(st, msg)  ((ds_result_t){ (st), (msg) })

size_t ds_rfcs_atom_prefix_size(uint32_t atom, size_t body_len)
{
    return ds_pbf_lookup(atom) ? ds_pbf_prefix_size(atom, body_len) : 0u;
}

size_t ds_rfcs_atom_framed_size(uint32_t atom, size_t body_len)
{
    return ds_pbf_lookup(atom) ? ds_pbf_framed_size(atom, body_len) : 0u;
}

ds_result_t ds_rfcs_pack_atom(uint32_t atom,
                              const uint8_t *body, size_t body_len,
                              uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_pack_atom: NULL arg");
    if (body_len > 0xFFFFFFFFu)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_pack_atom: body exceeds u32 length");

    uint32_t field = atom;
    if (!ds_pbf_lookup(field))
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_pack_atom: not an allocated field number");

    size_t total = ds_pbf_framed_size(field, body_len);
    if (!out || out_cap < total) {
        *out_len = total;
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_pack_atom: output buffer too small");
    }
    if (!ds_pbf_frame_atom(field, body, body_len, out, out_cap, out_len))
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_pack_atom: frame failed");
    return RFCS_OK;
}

/* Writes the prefix of a body not packed yet, and hands back the offset to pack it at. */
static ds_result_t frame_into(uint32_t field, size_t body_size,
                              uint8_t *out, size_t out_cap,
                              size_t *out_len, size_t *out_body_off)
{
    if (!ds_pbf_write_prefix(field, body_size, out, out_cap,
                             out_body_off, out_len))
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs encode: output buffer too small");
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_header(const ds_session_header_t *hdr,
                                  uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!hdr || !out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_header: NULL arg");

    Ds__V1__StreamHeader msg = DS__V1__STREAM_HEADER__INIT;
    /* [LDET.1.10]. */
    msg.ds_version = (char *)(hdr->ds_version ? hdr->ds_version : "");
    msg.session_id = (char *)(hdr->session_id ? hdr->session_id : "");
    msg.tier_id = (char *)(hdr->tier_id ? hdr->tier_id : "");
    if (hdr->dsc_hash && hdr->dsc_hash_len) {
        msg.dsc_hash.len = hdr->dsc_hash_len;
        msg.dsc_hash.data = (uint8_t *)hdr->dsc_hash;
    }
    /* [RBND.2], [RBND.3.1]. */
    Ds__V1__Capability caps[DS_BINDING_CAPABILITIES_MAX];
    if (hdr->n_capabilities > DS_BINDING_CAPABILITIES_MAX ||
        (hdr->n_capabilities > 0 && hdr->capabilities == NULL))
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_encode_header: capabilities NULL, or more "
                        "than any header may carry");
    for (size_t i = 0; i < hdr->n_capabilities; i++)
        caps[i] = (Ds__V1__Capability) hdr->capabilities[i];
    msg.n_capabilities = hdr->n_capabilities;
    msg.capabilities   = caps;
    if (hdr->dialect_def_sha256 && hdr->dialect_def_sha256_len) {
        msg.dialect_def_sha256.len  = hdr->dialect_def_sha256_len;
        msg.dialect_def_sha256.data = (uint8_t *)hdr->dialect_def_sha256;
    }

    size_t body = ds__v1__stream_header__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_STREAM_HEADER, body, out, out_cap, out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__stream_header__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_clka(uint64_t seq, int64_t clock_ns,
                                bool wall_set, int64_t wall_ns,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_clka: NULL out_len");

    Ds__V1__ClockAdvance msg = DS__V1__CLOCK_ADVANCE__INIT;
    msg.seq = seq;
    msg.clock_ns = clock_ns;
    /* [RFCS.10.1]: an unset clock and the epoch are different records. */
    msg.has_wall = wall_set;
    if (wall_set) msg.wall_ns = wall_ns;

    size_t body = ds__v1__clock_advance__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_CLOCK_ADVANCE, body, out, out_cap, out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__clock_advance__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_rfra(uint64_t seq, int64_t clock_ns,
                                const char *rule_name, int64_t timetag,
                                bool end,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_rfra: NULL out_len");

    Ds__V1__RuleFireAnnotation msg = DS__V1__RULE_FIRE_ANNOTATION__INIT;
    msg.seq = seq;
    msg.clock_ns = clock_ns;
    msg.rule_name = (char *)(rule_name ? rule_name : "");
    msg.timetag = timetag;
    msg.end = end ? 1 : 0;

    size_t body = ds__v1__rule_fire_annotation__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_RULE_FIRE_ANNOTATION, body, out, out_cap, out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__rule_fire_annotation__pack(&msg, out + body_off);
    return RFCS_OK;
}

/* ---- FactExternal: a fact that leaves the engine ([RFCS.23]) ---- *
 *
 * Every node, string and json text the tree points at is on one owned list, so a failure
 * part-way frees exactly what it made.
 */

typedef struct fe_owned {
    void   **p;
    size_t   n, cap;
} fe_owned_t;

static bool fe_own(fe_owned_t *o, void *p)
{
    if (p == NULL) return false;
    if (o->n == o->cap) {
        size_t ncap = o->cap ? o->cap * 2u : 16u;
        void **np = DS_REALLOC(o->p, ncap * sizeof(*np));
        if (np == NULL) { DS_FREE(p); return false; }
        o->p = np;
        o->cap = ncap;
    }
    o->p[o->n++] = p;
    return true;
}

static void *fe_calloc(fe_owned_t *o, size_t n, size_t sz)
{
    void *p = DS_CALLOC(n > 0 ? n : 1, sz);
    return fe_own(o, p) ? p : NULL;
}

static void fe_owned_free(fe_owned_t *o)
{
    for (size_t i = 0; i < o->n; i++) DS_FREE(o->p[i]);
    DS_FREE(o->p);
    o->p = NULL;
    o->n = o->cap = 0;
}

/* A `Kind` is a representation, not a declared type ([RFCS.23.2]). A switch, so a slot type
   added without a kind is noticed. */
static bool fe_slot_kind(ds_slot_type_t t, Ds__V1__Kind *out)
{
    switch (t) {
    case DS_SLOT_TYPE_INT:      *out = DS__V1__KIND__KIND_INT;      return true;
    case DS_SLOT_TYPE_TIME:     *out = DS__V1__KIND__KIND_INT;      return true;
    case DS_SLOT_TYPE_DATE:     *out = DS__V1__KIND__KIND_INT;      return true;
    case DS_SLOT_TYPE_DURATION: *out = DS__V1__KIND__KIND_INT;      return true;
    case DS_SLOT_TYPE_FLOAT:    *out = DS__V1__KIND__KIND_FLOAT;    return true;
    case DS_SLOT_TYPE_STRING:   *out = DS__V1__KIND__KIND_STRING;   return true;
    case DS_SLOT_TYPE_BOOL:     *out = DS__V1__KIND__KIND_BOOL;     return true;
    case DS_SLOT_TYPE_JSON:     *out = DS__V1__KIND__KIND_JSON;     return true;
    case DS_SLOT_TYPE_SCHEMA:   *out = DS__V1__KIND__KIND_FACT_REF; return true;
    case DS_SLOT_TYPE_BYTES:    *out = DS__V1__KIND__KIND_BYTES;    return true;
    }
    return false;
}

/* [RFCS.23.3]: so a temporal slot hashes apart from an Int slot of the same name. */
static Ds__V1__SlotKind fe_temporal_kind(ds_slot_type_t t)
{
    switch (t) {
    case DS_SLOT_TYPE_TIME:     return DS__V1__SLOT_KIND__SLOT_KIND_TIME;
    case DS_SLOT_TYPE_DATE:     return DS__V1__SLOT_KIND__SLOT_KIND_DATE;
    case DS_SLOT_TYPE_DURATION: return DS__V1__SLOT_KIND__SLOT_KIND_DURATION;
    case DS_SLOT_TYPE_INT:
    case DS_SLOT_TYPE_FLOAT:
    case DS_SLOT_TYPE_STRING:
    case DS_SLOT_TYPE_BOOL:
    case DS_SLOT_TYPE_JSON:
    case DS_SLOT_TYPE_SCHEMA:
    case DS_SLOT_TYPE_BYTES:
        break;
    }
    return DS__V1__SLOT_KIND__SLOT_KIND_UNSPECIFIED;
}

/* [RFCS.23.3]: slots in byte order of slot name; strcmp compares as unsigned char. */
static ds_result_t fe_schema_hash(const ds_schema_t *s, fe_owned_t *o,
                                  uint8_t out[DS_SHA256_DIGEST_LEN])
{
    uint32_t n = s->n_slots;
    uint32_t order[n > 0 ? n : 1];
    for (uint32_t i = 0; i < n; i++) {
        uint32_t j = i;
        while (j > 0 && strcmp(s->slots[order[j - 1]].name, s->slots[i].name) > 0) {
            order[j] = order[j - 1];
            j--;
        }
        order[j] = i;
    }

    Ds__V1__SlotShape  *shapes = fe_calloc(o, n, sizeof(*shapes));
    Ds__V1__SlotShape **sp     = fe_calloc(o, n, sizeof(*sp));
    if (shapes == NULL || sp == NULL)
        return RFCS_ERR(DS_ERR_OOM, "FactExternal: schema shape");
    for (uint32_t k = 0; k < n; k++) {
        const ds_slot_desc_t *d = &s->slots[order[k]];
        Ds__V1__SlotShape *ss = &shapes[k];
        ds__v1__slot_shape__init(ss);
        ss->name = (char *)d->name;
        if (!fe_slot_kind(d->type, &ss->kind))
            return RFCS_ERR(DS_ERR_INVAL, "FactExternal: a slot of no kind");
        ss->nullable = d->nullable ? 1 : 0;
        ss->ref_schema = (char *)((d->type == DS_SLOT_TYPE_SCHEMA && d->schema_ref)
                                  ? d->schema_ref->type_name : "");
        ss->temporal_kind = fe_temporal_kind(d->type);
        sp[k] = ss;
    }
    Ds__V1__SchemaShape shape = DS__V1__SCHEMA_SHAPE__INIT;
    shape.schema  = (char *)s->type_name;
    shape.n_slots = n;
    shape.slots   = n > 0 ? sp : NULL;

    size_t len = ds__v1__schema_shape__get_packed_size(&shape);
    uint8_t *buf = fe_calloc(o, len, 1);
    if (buf == NULL) return RFCS_ERR(DS_ERR_OOM, "FactExternal: schema shape");
    ds__v1__schema_shape__pack(&shape, buf);
    ds_sha256(buf, len, out);
    return RFCS_OK;
}

/* A fact-reference slot inlines its live target ([RFCS.23.4]), which predates the referrer,
   so the recursion ends; one whose target has gone is KIND_NULL. No `event_id` ([RFCS.23.5]).

   A fact with no assert seq never entered: the seq marks that `asserted_at` was stamped. */
static ds_result_t fe_build(const ds_fact_t *fact, fe_owned_t *o,
                            Ds__V1__FactExternal **out)
{
    const ds_schema_t *s = fact->schema;
    if (s == NULL)
        return RFCS_ERR(DS_ERR_INVAL, "FactExternal: a fact with no schema");
    /* A `publish`'s view has no FactAssert and needs none: it never entered
       working memory, and `asserted_at` is the instant of the `publish`
       ([RFCS.23.5], ds_wm_publish_view). */
    if (!fact->assert_seq_set && !fact->publish_view)
        return RFCS_ERR(DS_ERR_INVAL,
                        "FactExternal: a fact whose FactAssert has no seq yet");

    Ds__V1__FactExternal *fe = fe_calloc(o, 1, sizeof(*fe));
    uint8_t *hash = fe_calloc(o, DS_SHA256_DIGEST_LEN, 1);
    if (fe == NULL || hash == NULL)
        return RFCS_ERR(DS_ERR_OOM, "FactExternal: node");
    ds__v1__fact_external__init(fe);
    fe->schema = (char *)s->type_name;
    ds_result_t r = fe_schema_hash(s, o, hash);
    if (r.status != DS_OK) return r;
    fe->schema_hash.data = hash;
    fe->schema_hash.len  = DS_SHA256_DIGEST_LEN;

    uint32_t n = fact->n_slots;
    Ds__V1__Arg  *args = fe_calloc(o, n, sizeof(*args));
    Ds__V1__Arg **ap   = fe_calloc(o, n, sizeof(*ap));
    if (args == NULL || ap == NULL)
        return RFCS_ERR(DS_ERR_OOM, "FactExternal: fields");
    for (uint32_t i = 0; i < n; i++) {
        const char      *name = NULL;
        ds_slot_value_t  v;
        r = ds_fact_get_slot(fact, i, &name, &v);
        if (r.status != DS_OK) return r;
        Ds__V1__Arg *a = &args[i];
        ds__v1__arg__init(a);
        a->name = (char *)(name ? name : "");
        switch (v.kind) {
        case DS_SLOT_INT:
            a->kind = DS__V1__KIND__KIND_INT;
            a->value_case = DS__V1__ARG__VALUE_INT_VALUE;
            a->int_value = v.v.i;
            break;
        case DS_SLOT_FLOAT:
            a->kind = DS__V1__KIND__KIND_FLOAT;
            a->value_case = DS__V1__ARG__VALUE_FLOAT_VALUE;
            a->float_value = v.v.f;
            break;
        case DS_SLOT_STRING:
            a->kind = DS__V1__KIND__KIND_STRING;
            a->value_case = DS__V1__ARG__VALUE_STRING_VALUE;
            a->string_value = (char *)(v.v.s ? v.v.s : "");
            break;
        case DS_SLOT_BOOL:
            a->kind = DS__V1__KIND__KIND_BOOL;
            a->value_case = DS__V1__ARG__VALUE_BOOL_VALUE;
            a->bool_value = v.v.b ? 1 : 0;
            break;
        case DS_SLOT_JSON: {
            char  *text = NULL;
            size_t len  = 0;
            r = ds_json_serialize(v.v.json, &text, &len);
            if (r.status != DS_OK) return r;
            if (!fe_own(o, text)) return RFCS_ERR(DS_ERR_OOM, "FactExternal: json");
            a->kind = DS__V1__KIND__KIND_JSON;
            a->value_case = DS__V1__ARG__VALUE_JSON_VALUE;
            a->json_value = text;
            break;
        }
        case DS_SLOT_BYTES:
            a->kind = DS__V1__KIND__KIND_BYTES;
            a->value_case = DS__V1__ARG__VALUE_BYTES_VALUE;
            a->bytes_value.data = (uint8_t *)v.v.bytes.data;
            a->bytes_value.len  = v.v.bytes.len;
            break;
        case DS_SLOT_NULL:
            a->kind = DS__V1__KIND__KIND_NULL;
            a->value_case = DS__V1__ARG__VALUE__NOT_SET;
            break;
        case DS_SLOT_FACT_REF:
            if (v.v.ref == NULL) {
                a->kind = DS__V1__KIND__KIND_NULL;
                a->value_case = DS__V1__ARG__VALUE__NOT_SET;
            } else {
                Ds__V1__FactExternal *inner = NULL;
                r = fe_build(v.v.ref, o, &inner);
                if (r.status != DS_OK) return r;
                a->kind = DS__V1__KIND__KIND_FACT_REF;
                a->value_case = DS__V1__ARG__VALUE_FACT;
                a->fact = inner;
            }
            break;
        }
        ap[i] = a;
    }
    fe->n_fields = n;
    fe->fields   = n > 0 ? ap : NULL;

    /* [RFCS.23.5]. */
    fe->has_asserted_at = fact->asserted_wall_set ? 1 : 0;
    fe->asserted_at     = fact->asserted_wall_set ? fact->asserted_wall_ns : 0;

    *out = fe;
    return RFCS_OK;
}

ds_result_t ds_fact_external_pack(const ds_fact_t *fact,
                                  uint8_t **out, size_t *out_len)
{
    if (fact == NULL || out == NULL || out_len == NULL)
        return RFCS_ERR(DS_ERR_INVAL, "ds_fact_external_pack: NULL arg");
    *out = NULL;
    *out_len = 0;
    fe_owned_t o = { 0 };
    Ds__V1__FactExternal *fe = NULL;
    ds_result_t r = fe_build(fact, &o, &fe);
    if (r.status == DS_OK) {
        size_t len = ds__v1__fact_external__get_packed_size(fe);
        uint8_t *buf = DS_MALLOC(len > 0 ? len : 1);
        if (buf == NULL) {
            r = RFCS_ERR(DS_ERR_OOM, "ds_fact_external_pack: buffer");
        } else {
            ds__v1__fact_external__pack(fe, buf);
            *out = buf;
            *out_len = len;
        }
    }
    fe_owned_free(&o);
    return r;
}

/* ---- Receiving a FactExternal: ds_engine_assert_external ([NCBK.10.4]) ---- *
 *
 * Two phases. [RFCS.23.7] refuses the whole record on a conflict at any depth, so the first
 * decodes, checks and resolves every node and asserts nothing. The plan is post-order,
 * [RFCS.23.7]'s "innermost first", and the second phase walks it.
 *
 * One FactExternal is one input: the call samples both clocks once, after the first phase
 * admits the record ([LTIM.2.8.4], [LTIM.2.8.6]). This call is the outermost public entry, so
 * each ds_engine_assert inside it runs nested and shares that sample.
 *
 * Only an OOM or a halt ([LERR.1.4.7]) can stop the second phase ([NCBK.10.4]). Either leaves
 * the facts already asserted in place. */

/* ---- Recording a delivery: one ExternalAssert ([RFCS.24]) ---- *
 *
 * The engine's stream is unchanged, one FactAssert event per fact ([RFCS.24.3]); only the
 * recording differs. While a delivery is open the recorder writes no atom for its FactAsserts
 * and holds every other atom it frames. Closing writes the ExternalAssert, then the held atoms
 * in order, so a sink sees it before everything the input caused.
 *
 * A direct host assert of a fact holding a reference needs no delivery: its one FactAssert is
 * the whole input. */
typedef struct rfcs_delivery {
    const uint8_t      *fact;       /* the FactExternal bytes, as the host passed them */
    size_t              fact_len;
    ds_rfcs_recorder_t *rec;        /* the recorder that saw it; NULL if none */
    bool                started;    /* its first FactAssert has been seen */
    uint64_t            seq;        /* that event's seq */
    uint64_t            clock_ns;   /* and its clock: the input's one sample */
    uint64_t            ttl_ns;     /* the received fact's window, as FactAssert records it */
    uint64_t           *ids;        /* fact_ids, in event order */
    size_t              n_ids, cap_ids;
    uint8_t            *held;       /* atoms framed while open, in order */
    size_t              held_len, held_cap;
    ds_result_t         err;        /* the first failure while holding */
} rfcs_delivery_t;

static void        rfcs_delivery_open(ds_engine_t *engine, rfcs_delivery_t *dl,
                                      const uint8_t *fact, size_t fact_len);
static ds_result_t rfcs_delivery_close(ds_engine_t *engine, rfcs_delivery_t *dl);

#define FX_MAX_DEPTH 16u   /* [RFCS.23.4], with the record's own fact at depth 0 */

typedef struct fx_node {
    const Ds__V1__FactExternal *fe;
    const ds_schema_t          *schema;
    ds_slot_value_t            *values;   /* the schema's declaration order */
    int32_t                    *ref;      /* per slot: the target node, or -1 */
    ds_fact_t                  *live;     /* [RFCS.23.7] 1: equal to this live fact */
    int32_t                     same_as;  /* equal to an earlier node of this record, or -1 */
    ds_fact_t                  *asserted; /* once the second phase asserts it */
    ds_fact_t                   target;   /* what a referrer reads: see fx_hold_target */
    bool                        has_target;
} fx_node_t;

/* [RFCS.23.7], [RDSC.9.9]: one of the delivery's own asserts can remove the fact a reference
   resolved to, releasing its wrapper, so a referrer asserted after it reads this instead.
   `rete_fact` is only tested against NULL, never followed. */
static void fx_hold_target(fx_node_t *x, const ds_fact_t *f)
{
    memset(&x->target, 0, sizeof x->target);
    x->target.schema    = f->schema;
    x->target.rete_fact = f->rete_fact;
    x->target.rete_id   = f->rete_id;
    x->target.fact_id   = f->fact_id;
    x->has_target       = true;
}

typedef struct fx_plan {
    ds_engine_t *engine;
    fx_node_t   *nodes;
    uint32_t     n, cap;
    fe_owned_t   owned;    /* the per-node arrays */
    ds_json_t  **json;     /* trees parsed from Json fields; freed at the end */
    uint32_t     n_json, cap_json;
} fx_plan_t;

static void fx_plan_free(fx_plan_t *p)
{
    for (uint32_t i = 0; i < p->n_json; i++) ds_json_free(p->json[i]);
    DS_FREE(p->json);
    DS_FREE(p->nodes);
    fe_owned_free(&p->owned);
}

/* The node a reference resolves to: through `same_as` to the first node that
   stands for that fact. */
static int32_t fx_canon(const fx_plan_t *p, int32_t i)
{
    while (i >= 0 && p->nodes[i].same_as >= 0) i = p->nodes[i].same_as;
    return i;
}

/* [RFCS.23.7]: KIND_NULL in a fact-reference slot is a reference with no target. */
static bool fx_no_target(const fx_node_t *x, uint32_t i)
{
    return x->schema->slots[i].type == DS_SLOT_TYPE_SCHEMA && x->ref[i] < 0;
}

/* What such a slot equals on a live fact: a slot that is null, or whose target
   has gone. */
static bool fx_live_slot_no_target(const ds_fact_t *f, uint32_t i)
{
    return f->slots[i].kind == DS_SLOT_NULL
        || ds_wm_fact_ref_resolve(f, i) == NULL;
}

/* As `idkey_equal` (rete/wm_rete.c), or a copy this check let through would be upserted over
   the live fact it said it does not meet. `ra` and `rb` are the target nodes of a planned
   fact-ref value, -1 for a live fact's. */
static bool fx_key_val_eq(const fx_plan_t *p,
                          const ds_slot_value_t *a, int32_t ra,
                          const ds_slot_value_t *b, int32_t rb)
{
    if (a->kind != b->kind) return false;
    switch (a->kind) {
    case DS_SLOT_INT:    return a->v.i == b->v.i;
    case DS_SLOT_FLOAT:  return a->v.f == b->v.f;
    case DS_SLOT_STRING: return strcmp(a->v.s ? a->v.s : "", b->v.s ? b->v.s : "") == 0;
    case DS_SLOT_BOOL:   return a->v.b == b->v.b;
    case DS_SLOT_NULL:   return true;
    case DS_SLOT_FACT_REF: {
        /* A planned value names a node: a live fact, or one this record has not asserted
           yet, which no live fact can refer to. */
        uint64_t ia = 0, ib = 0;
        if (ra >= 0) {
            const fx_node_t *n = &p->nodes[fx_canon(p, ra)];
            if (n->live == NULL) {
                if (rb < 0) return false;
                return fx_canon(p, ra) == fx_canon(p, rb);
            }
            ia = n->live->fact_id;
        } else {
            ia = ds_wm_slot_ref_id(a);
        }
        if (rb >= 0) {
            const fx_node_t *n = &p->nodes[fx_canon(p, rb)];
            if (n->live == NULL) return false;
            ib = n->live->fact_id;
        } else {
            ib = ds_wm_slot_ref_id(b);
        }
        return ia != 0 && ia == ib;
    }
    case DS_SLOT_JSON:
    case DS_SLOT_BYTES:
        return false;
    }
    return false;
}

/* [RFCS.23.7] 2-3. Only a `logical` schema has a key ([LFAC.1.7]); a key of no slots is the
   singleton, which every fact of the schema shares. */
static bool fx_key_taken(const fx_plan_t *p, uint32_t idx)
{
    const fx_node_t   *x = &p->nodes[idx];
    const ds_schema_t *s = x->schema;
    if (s->lifecycle != DS_SCHEMA_LIFECYCLE_LOGICAL) return false;

    for (const ds_fact_t *f = s->fact_list_head; f != NULL; f = f->schema_next) {
        bool eq = true;
        for (uint32_t i = 0; eq && i < s->n_slots; i++) {
            if (s->slots[i].identity_role != DS_IDENTITY_KEY) continue;
            eq = fx_no_target(x, i)
                ? fx_live_slot_no_target(f, i)
                : fx_key_val_eq(p, &x->values[i], x->ref[i], &f->slots[i], -1);
        }
        if (eq) return true;
    }
    for (uint32_t k = 0; k < idx; k++) {
        const fx_node_t *y = &p->nodes[k];
        if (y->schema != s || y->live != NULL || y->same_as >= 0) continue;
        bool eq = true;
        for (uint32_t i = 0; eq && i < s->n_slots; i++) {
            if (s->slots[i].identity_role != DS_IDENTITY_KEY) continue;
            eq = fx_no_target(x, i) || fx_no_target(y, i)
                ? fx_no_target(x, i) && fx_no_target(y, i)
                : fx_key_val_eq(p, &x->values[i], x->ref[i], &y->values[i], y->ref[i]);
        }
        if (eq) return true;
    }
    return false;
}

/* [RFCS.23.7]'s "equal" is ds_rete_slots_equal itself ([LFAC.2.5.1], [LFAC.2.5.4]); this builds
 * the values it compares. Strings are looked up, never interned: one the table does not hold
 * is held by no live fact, and interning it would leave a count-0 entry for a refused record. */
static bool fx_live_vals(const fx_plan_t *p, const fx_node_t *x,
                         ds_rete_val_t *out)
{
    const ds_rete_intern_t *in = p->engine->rete_engine->intern;
    for (uint32_t i = 0; i < x->schema->n_slots; i++) {
        const ds_slot_value_t *v = &x->values[i];
        switch (v->kind) {
        case DS_SLOT_NULL:  out[i] = ds_rete_val_null();       break;
        case DS_SLOT_INT:   out[i] = ds_rete_val_int(v->v.i);   break;
        case DS_SLOT_FLOAT: out[i] = ds_rete_val_float(v->v.f); break;
        case DS_SLOT_BOOL:  out[i] = ds_rete_val_bool(v->v.b);  break;
        case DS_SLOT_STRING: {
            const char *s  = v->v.s ? v->v.s : "";
            const char *ip = NULL;
            size_t      n  = strlen(s);
            if (ds_rete_intern_find(in, s, n, &ip).status != DS_OK || ip == NULL)
                return false;
            out[i] = ds_rete_val_str(ip, (uint32_t) n);
            break;
        }
        case DS_SLOT_BYTES: {
            const char *b  = (const char *)(v->v.bytes.data ? v->v.bytes.data
                                                            : (const uint8_t *)"");
            const char *ip = NULL;
            if (ds_rete_intern_find(in, b, v->v.bytes.len, &ip).status != DS_OK
                    || ip == NULL)
                return false;
            out[i] = ds_rete_val_bytes(ip, (uint32_t) v->v.bytes.len);
            break;
        }
        case DS_SLOT_JSON:
            out[i].kind = DS_RETE_VAL_JSON;
            out[i].json = v->v.json;
            break;
        case DS_SLOT_FACT_REF: {
            out[i].kind        = DS_RETE_VAL_FACT_REF;
            out[i].fact_ref_id = 0u;           /* no target: fx_live_equal */
            if (x->ref[i] < 0) break;
            const fx_node_t *t = &p->nodes[fx_canon(p, x->ref[i])];
            if (t->live == NULL) return false;
            out[i].fact_ref_id = t->live->rete_id;
            break;
        }
        }
    }
    return true;
}

/* The earliest-asserted live fact the copy is equal to, or NULL. A no-target slot takes the
   live slot's own value where that slot is null or its target has gone ([RFCS.23.7]). `vc` is
   scratch, one value per slot. */
static ds_fact_t *fx_live_equal(const ds_rete_schema_t *rs, const fx_node_t *x,
                                const ds_rete_val_t *vx, ds_rete_val_t *vc)
{
    ds_fact_t *best = NULL;
    for (ds_fact_t *f = x->schema->fact_list_head; f != NULL; f = f->schema_next) {
        const ds_rete_fact_t *rf = f->rete_fact;
        if (rf == NULL) continue;
        for (uint32_t i = 0; i < x->schema->n_slots; i++)
            vc[i] = fx_no_target(x, i) && fx_live_slot_no_target(f, i)
                ? rf->slots[i] : vx[i];
        if (!ds_rete_slots_equal(rs, rf->slots, vc)) continue;
        if (best == NULL || f->fact_id < best->fact_id) best = f;
    }
    return best;
}

/* Against an earlier copy in this record, neither interned: each String takes one pointer per
 * content, and each reference one id per fact it resolves to. */
static void fx_pair_vals(const fx_plan_t *p, const fx_node_t *x,
                         const fx_node_t *y, ds_rete_val_t *vx,
                         ds_rete_val_t *vy)
{
    for (uint32_t i = 0; i < x->schema->n_slots; i++) {
        const ds_slot_value_t *a[2] = { &x->values[i], &y->values[i] };
        ds_rete_val_t         *o[2] = { &vx[i], &vy[i] };
        for (int s = 0; s < 2; s++) {
            const ds_slot_value_t *v = a[s];
            switch (v->kind) {
            case DS_SLOT_NULL:  *o[s] = ds_rete_val_null();       break;
            case DS_SLOT_INT:   *o[s] = ds_rete_val_int(v->v.i);   break;
            case DS_SLOT_FLOAT: *o[s] = ds_rete_val_float(v->v.f); break;
            case DS_SLOT_BOOL:  *o[s] = ds_rete_val_bool(v->v.b);  break;
            case DS_SLOT_STRING: {
                const char *str = v->v.s ? v->v.s : "";
                *o[s] = ds_rete_val_str(str, (uint32_t) strlen(str));
                break;
            }
            case DS_SLOT_BYTES:
                *o[s] = ds_rete_val_bytes((const char *) v->v.bytes.data,
                                          (uint32_t) v->v.bytes.len);
                break;
            case DS_SLOT_JSON:
                o[s]->kind = DS_RETE_VAL_JSON;
                o[s]->json = v->v.json;
                break;
            case DS_SLOT_FACT_REF:
                o[s]->kind        = DS_RETE_VAL_FACT_REF;
                o[s]->fact_ref_id = 1u;
                break;
            }
        }
        if (vx[i].kind == DS_RETE_VAL_STR && vy[i].kind == DS_RETE_VAL_STR
                && vx[i].s.len == vy[i].s.len
                && memcmp(vx[i].s.ptr, vy[i].s.ptr, vx[i].s.len) == 0) {
            vy[i].s.ptr = vx[i].s.ptr;
        }
        if (vx[i].kind == DS_RETE_VAL_FACT_REF && vy[i].kind == DS_RETE_VAL_FACT_REF) {
            /* Two references with no target are equal ([RFCS.23.7]), and one
               with no target differs from one that has a node. */
            bool same = x->ref[i] == y->ref[i];
            if (x->ref[i] >= 0 && y->ref[i] >= 0) {
                const int32_t    ca = fx_canon(p, x->ref[i]);
                const int32_t    cb = fx_canon(p, y->ref[i]);
                const fx_node_t *ta = &p->nodes[ca];
                const fx_node_t *tb = &p->nodes[cb];
                same = (ta->live != NULL || tb->live != NULL)
                         ? ta->live == tb->live : ca == cb;
            }
            vy[i].fact_ref_id = same ? 1u : 2u;
        }
    }
}

/* [RFCS.23.7] for one nested node, in its order:
   1. a live fact equal to the copy is the same fact. Of several, the lowest fact id: the
      clause does not say which. An earlier copy in this record counts as live, after every
      fact that is live already;
   2. otherwise, with no live fact holding its identity key, the copy is asserted;
   3. otherwise the record is refused. */
static ds_result_t fx_resolve(fx_plan_t *p, uint32_t idx)
{
    fx_node_t *x = &p->nodes[idx];
    const ds_rete_schema_t *rs =
        ds_rete_schema_by_name(p->engine->rete_engine, x->schema->type_name);
    if (rs == NULL)
        return RFCS_ERR(DS_ERR_SCHEMA_UNKNOWN,
                        "ds_engine_assert_external: the schema is registered "
                        "with the engine but not with its Rete network");

    const uint32_t n = x->schema->n_slots;
    ds_rete_val_t  vx[n > 0 ? n : 1];
    ds_rete_val_t  vy[n > 0 ? n : 1];

    if (fx_live_vals(p, x, vx)) {
        ds_fact_t *best = fx_live_equal(rs, x, vx, vy);
        if (best != NULL) { x->live = best; return RFCS_OK; }
    }
    for (uint32_t k = 0; k < idx; k++) {
        const fx_node_t *y = &p->nodes[k];
        if (y->schema != x->schema || y->live != NULL || y->same_as >= 0) continue;
        fx_pair_vals(p, x, y, vx, vy);
        if (ds_rete_slots_equal(rs, vx, vy)) {
            x->same_as = (int32_t) k;
            return RFCS_OK;
        }
    }
    if (fx_key_taken(p, idx))
        return RFCS_ERR(DS_ERR_FACT_REF_CONFLICT,
                        "ds_engine_assert_external: a nested reference meets a "
                        "live fact with the same key and different values "
                        "([RFCS.23.7])");
    return RFCS_OK;
}

/* The received fact is an ordinary assert, and a live fact equal to it makes it
   a no-op ([RFCS.23.7]). That assert's comparison reads ids, so a no-target slot
   of the received fact takes the id the equal live fact's slot names, and the
   assert finds the two equal. */
static ds_result_t fx_top_no_target(fx_plan_t *p, uint32_t idx)
{
    fx_node_t *x = &p->nodes[idx];
    const uint32_t n = x->schema->n_slots;
    bool any = false;
    for (uint32_t i = 0; i < n; i++)
        if (fx_no_target(x, i)) any = true;
    const ds_rete_schema_t *rs = any
        ? ds_rete_schema_by_name(p->engine->rete_engine, x->schema->type_name)
        : NULL;
    if (rs == NULL) return RFCS_OK;

    ds_rete_val_t vx[n > 0 ? n : 1];
    ds_rete_val_t vc[n > 0 ? n : 1];
    if (!fx_live_vals(p, x, vx)) return RFCS_OK;
    const ds_fact_t *best = fx_live_equal(rs, x, vx, vc);
    if (best == NULL) return RFCS_OK;
    const ds_rete_fact_t *rf = best->rete_fact;
    for (uint32_t i = 0; i < n; i++) {
        if (!fx_no_target(x, i) || best->slots[i].kind != DS_SLOT_FACT_REF)
            continue;
        ds_fact_t *t = fe_calloc(&p->owned, 1, sizeof(*t));
        if (t == NULL)
            return RFCS_ERR(DS_ERR_OOM, "ds_engine_assert_external: plan");
        t->schema    = x->schema->slots[i].schema_ref;
        t->rete_fact = best->rete_fact;        /* tested, never followed */
        t->rete_id   = rf->slots[i].fact_ref_id;
        t->fact_id   = ds_wm_slot_ref_id(&best->slots[i]);
        x->values[i].kind  = DS_SLOT_FACT_REF;
        x->values[i].v.ref = t;
    }
    return RFCS_OK;
}

static ds_result_t fx_plan_node(fx_plan_t *p, const Ds__V1__FactExternal *fe,
                                unsigned depth, bool top, int32_t *out);

/* A record is refused here for exactly what a host assert would refuse, with its status. A
   field whose `oneof` member is not the one its kind names is DS_ERR_PARSE. */
static ds_result_t fx_field(fx_plan_t *p, const ds_slot_desc_t *d,
                            const Ds__V1__Arg *a, unsigned depth,
                            ds_slot_value_t *v, int32_t *ref)
{
#define FX_WANT(slot_type, member)                                            \
    do {                                                                      \
        if (d->type != (slot_type))                                           \
            return RFCS_ERR(DS_ERR_SLOT_TYPE_MISMATCH,                        \
                "ds_engine_assert_external: a field of a kind its slot does " \
                "not take");                                                  \
        if (a->value_case != (member))                                        \
            return RFCS_ERR(DS_ERR_PARSE,                                     \
                "ds_engine_assert_external: a field whose value is not the "  \
                "one its kind names");                                        \
    } while (0)

    *ref = -1;
    switch (a->kind) {
    case DS__V1__KIND__KIND_NULL:
        if (a->value_case != DS__V1__ARG__VALUE__NOT_SET)
            return RFCS_ERR(DS_ERR_PARSE,
                "ds_engine_assert_external: a KIND_NULL field carrying a value");
        /* [RFCS.23.7]: a non-nullable one reaches the assert as a target with no ids,
           which wm_validate_assert_values admits and a NULL `v.ref` it does not. */
        if (d->type == DS_SLOT_TYPE_SCHEMA && !d->nullable) {
            ds_fact_t *t = fe_calloc(&p->owned, 1, sizeof(*t));
            if (t == NULL)
                return RFCS_ERR(DS_ERR_OOM, "ds_engine_assert_external: plan");
            t->schema = d->schema_ref;
            v->kind   = DS_SLOT_FACT_REF;
            v->v.ref  = t;
            return RFCS_OK;
        }
        if (!d->nullable)
            return RFCS_ERR(DS_ERR_SLOT_TYPE_MISMATCH,
                "ds_engine_assert_external: null in a non-nullable slot "
                "([LNUL.3.1])");
        v->kind = DS_SLOT_NULL;
        return RFCS_OK;
    case DS__V1__KIND__KIND_INT:
        /* [RFCS.23.2]: the hash has already said the writer declared the same type. */
        if (d->type != DS_SLOT_TYPE_INT && d->type != DS_SLOT_TYPE_TIME
                && d->type != DS_SLOT_TYPE_DATE && d->type != DS_SLOT_TYPE_DURATION)
            return RFCS_ERR(DS_ERR_SLOT_TYPE_MISMATCH,
                "ds_engine_assert_external: a field of a kind its slot does "
                "not take");
        if (a->value_case != DS__V1__ARG__VALUE_INT_VALUE)
            return RFCS_ERR(DS_ERR_PARSE,
                "ds_engine_assert_external: a field whose value is not the "
                "one its kind names");
        /* [LTIM.1.2.2], here in the plan, so the record is refused whole. */
        if (d->type == DS_SLOT_TYPE_DATE && !ds_date_days_in_range(a->int_value))
            return RFCS_ERR(DS_ERR_TIME_RANGE,
                "ds_engine_assert_external: a Date outside the Date range "
                "([LTIM.1.2.2])");
        v->kind = DS_SLOT_INT;
        v->v.i  = a->int_value;
        return RFCS_OK;
    case DS__V1__KIND__KIND_FLOAT:
        FX_WANT(DS_SLOT_TYPE_FLOAT, DS__V1__ARG__VALUE_FLOAT_VALUE);
        if (a->float_value != a->float_value)
            return RFCS_ERR(DS_ERR_NAN_REJECTED,
                "ds_engine_assert_external: a NaN Float ([LEXP.4.2])");
        v->kind = DS_SLOT_FLOAT;
        v->v.f  = a->float_value;
        return RFCS_OK;
    case DS__V1__KIND__KIND_STRING:
        FX_WANT(DS_SLOT_TYPE_STRING, DS__V1__ARG__VALUE_STRING_VALUE);
        v->kind = DS_SLOT_STRING;
        v->v.s  = a->string_value ? a->string_value : "";
        return RFCS_OK;
    case DS__V1__KIND__KIND_BOOL:
        FX_WANT(DS_SLOT_TYPE_BOOL, DS__V1__ARG__VALUE_BOOL_VALUE);
        v->kind = DS_SLOT_BOOL;
        v->v.b  = a->bool_value != 0;
        return RFCS_OK;
    case DS__V1__KIND__KIND_JSON: {
        FX_WANT(DS_SLOT_TYPE_JSON, DS__V1__ARG__VALUE_JSON_VALUE);
        /* [LGRA.5.8.6]: its own text limit, so a value another engine holds always
           arrives. The tree limits hold as for any parse. */
        const char *text = a->json_value ? a->json_value : "";
        ds_json_t  *tree = NULL;
        ds_result_t r = ds_json_parse_capped(text, strlen(text), &tree, NULL,
                                             DS_JSON_MAX_FX_TEXT_BYTES);
        if (r.status != DS_OK) return r;
        if (p->n_json == p->cap_json) {
            uint32_t ncap = p->cap_json ? p->cap_json * 2u : 8u;
            ds_json_t **nj = DS_REALLOC(p->json, ncap * sizeof(*nj));
            if (nj == NULL) {
                ds_json_free(tree);
                return RFCS_ERR(DS_ERR_OOM, "ds_engine_assert_external: json");
            }
            p->json = nj;
            p->cap_json = ncap;
        }
        p->json[p->n_json++] = tree;
        /* [LNUL.3.4]: the writer sends a null slot as KIND_NULL. */
        ds_json_kind_t root;
        if (ds_json_get_kind(tree, &root).status == DS_OK && root == DS_JSON_NULL)
            return RFCS_ERR(DS_ERR_SLOT_TYPE_MISMATCH,
                "ds_engine_assert_external: a root-null Json document "
                "([LNUL.3.4])");
        v->kind   = DS_SLOT_JSON;
        v->v.json = tree;
        return RFCS_OK;
    }
    case DS__V1__KIND__KIND_BYTES:
        FX_WANT(DS_SLOT_TYPE_BYTES, DS__V1__ARG__VALUE_BYTES_VALUE);
        v->kind = DS_SLOT_BYTES;
        v->v.bytes.data = a->bytes_value.data;
        v->v.bytes.len  = a->bytes_value.len;
        return RFCS_OK;
    case DS__V1__KIND__KIND_FACT_REF: {
        FX_WANT(DS_SLOT_TYPE_SCHEMA, DS__V1__ARG__VALUE_FACT);
        if (a->fact == NULL)
            return RFCS_ERR(DS_ERR_PARSE,
                "ds_engine_assert_external: a KIND_FACT_REF field with no fact");
        int32_t c = -1;
        ds_result_t r = fx_plan_node(p, a->fact, depth + 1u, false, &c);
        if (r.status != DS_OK) return r;
        if (d->schema_ref != NULL && p->nodes[c].schema != d->schema_ref)
            return RFCS_ERR(DS_ERR_SLOT_TYPE_MISMATCH,
                "ds_engine_assert_external: a referenced fact of a schema its "
                "slot does not name");
        v->kind  = DS_SLOT_FACT_REF;
        v->v.ref = NULL;               /* filled once the target exists */
        *ref     = c;
        return RFCS_OK;
    }
    case DS__V1__KIND__KIND_ENCODED_FACT:   /* a call argument's kind ([RFCS.23.2]) */
    default:
        break;
    }
#undef FX_WANT
    return RFCS_ERR(DS_ERR_PARSE,
        "ds_engine_assert_external: a field of no slot-value kind ([RFCS.23.2])");
}

/* One FactExternal as a plan node, its references first. */
static ds_result_t fx_plan_node(fx_plan_t *p, const Ds__V1__FactExternal *fe,
                                unsigned depth, bool top, int32_t *out)
{
    if (depth > FX_MAX_DEPTH)
        return RFCS_ERR(DS_ERR_PARSE,
            "ds_engine_assert_external: fact references nested too deep");
    if (fe->schema == NULL || fe->schema[0] == '\0')
        return RFCS_ERR(DS_ERR_PARSE,
            "ds_engine_assert_external: a FactExternal naming no schema");

    const ds_schema_t *s = NULL;
    ds_result_t r = ds_schema_registry_find(&p->engine->schemas, fe->schema, &s);
    if (r.status != DS_OK) return r;
    if (s == NULL)
        return RFCS_ERR(DS_ERR_SCHEMA_UNKNOWN,
            "ds_engine_assert_external: a schema this program does not declare");

    uint8_t h[DS_SHA256_DIGEST_LEN];
    r = fe_schema_hash(s, &p->owned, h);
    if (r.status != DS_OK) return r;
    if (fe->schema_hash.len != DS_SHA256_DIGEST_LEN
            || memcmp(fe->schema_hash.data, h, DS_SHA256_DIGEST_LEN) != 0)
        return RFCS_ERR(DS_ERR_SCHEMA_HASH_MISMATCH,
            "ds_engine_assert_external: its schema_hash differs from this "
            "program's schema of that name ([RFCS.23.3])");

    /* [RFCS.23.1]: each slot takes the one field of its name; otherwise the record is
       malformed, whatever its hash claims. */
    uint32_t n = s->n_slots;
    if (fe->n_fields != n)
        return RFCS_ERR(DS_ERR_PARSE,
            "ds_engine_assert_external: a field count that is not its schema's");
    ds_slot_value_t *vals = fe_calloc(&p->owned, n, sizeof(*vals));
    int32_t         *ref  = fe_calloc(&p->owned, n, sizeof(*ref));
    if (vals == NULL || ref == NULL)
        return RFCS_ERR(DS_ERR_OOM, "ds_engine_assert_external: plan");
    for (uint32_t i = 0; i < n; i++) {
        const Ds__V1__Arg *a = NULL;
        for (size_t j = 0; j < fe->n_fields; j++) {
            const Ds__V1__Arg *f = fe->fields[j];
            if (f == NULL || f->name == NULL || strcmp(f->name, s->slots[i].name) != 0)
                continue;
            if (a != NULL)
                return RFCS_ERR(DS_ERR_PARSE,
                    "ds_engine_assert_external: two fields for one slot");
            a = f;
        }
        if (a == NULL)
            return RFCS_ERR(DS_ERR_PARSE,
                "ds_engine_assert_external: a slot with no field");
        r = fx_field(p, &s->slots[i], a, depth, &vals[i], &ref[i]);
        if (r.status != DS_OK) return r;
    }

    if (p->n == p->cap) {
        uint32_t ncap = p->cap ? p->cap * 2u : 8u;
        fx_node_t *nn = DS_REALLOC(p->nodes, ncap * sizeof(*nn));
        if (nn == NULL) return RFCS_ERR(DS_ERR_OOM, "ds_engine_assert_external: plan");
        p->nodes = nn;
        p->cap   = ncap;
    }
    uint32_t idx = p->n++;
    p->nodes[idx] = (fx_node_t){ .fe = fe, .schema = s, .values = vals,
                                 .ref = ref, .live = NULL, .same_as = -1,
                                 .asserted = NULL, .has_target = false };
    /* The record's own fact is asserted, as a host's assert is ([RFCS.23.7]
       "asserts it"): steps 1-3 are for the references it carries. */
    r = top ? fx_top_no_target(p, idx) : fx_resolve(p, idx);
    if (r.status != DS_OK) return r;
    *out = (int32_t) idx;
    return RFCS_OK;
}

static bool fx_has_nul(const uint8_t *v, size_t n)
{
    for (size_t i = 0; i < n; i++)          /* not memchr: the picolibc rows */
        if (v[i] == 0u) return true;
    return false;
}

/* Walked raw, before protobuf-c, whose `string` decode drops the length and whose unpack has
 * no recursion limit. Refuses as DS_ERR_PARSE: a text field holding U+0000 ([LSTR.1.5]) or not
 * well-formed UTF-8, and nesting past FX_MAX_DEPTH ([NCBK.10.4]). The text fields are every
 * `string` of fact_external.proto: FactExternal's `schema` (1), Arg's `name` (1),
 * `string_value` (5) and `json_value` (7), through `fields` (3) and a nested `fact` (9).
 * Anything else malformed is left to the unpack and the plan. */
static ds_result_t fx_scan_nul(const uint8_t *msg, size_t len, bool is_fact,
                               unsigned depth)
{
    if (is_fact && depth > FX_MAX_DEPTH)
        return RFCS_ERR(DS_ERR_PARSE,
            "ds_engine_assert_external: fact references nested too deep");
    size_t pos = 0;
    for (;;) {
        ds_pbf_field_t f;
        if (ds_pbf_next_field(msg, len, pos, &f) != DS_PBF_OK) break;
        if (f.wire == 2u) {
            const bool text = is_fact
                ? f.field == 1u
                : (f.field == 1u || f.field == 5u || f.field == 7u);
            if (text && fx_has_nul(f.val, f.val_len))
                return RFCS_ERR(DS_ERR_PARSE,
                    "ds_engine_assert_external: a text field holding U+0000 "
                    "([LSTR.1.5])");
            if (text && !ds_utf8_well_formed((const char *) f.val, f.val_len))
                return RFCS_ERR(DS_ERR_PARSE,
                    "ds_engine_assert_external: a text field that is not "
                    "well-formed UTF-8 ([NCBK.10.4])");
            ds_result_t r = RFCS_OK;
            if (is_fact && f.field == 3u)
                r = fx_scan_nul(f.val, f.val_len, false, depth);
            else if (!is_fact && f.field == 9u)
                r = fx_scan_nul(f.val, f.val_len, true, depth + 1u);
            if (r.status != DS_OK) return r;
        }
        pos = f.next;
    }
    return RFCS_OK;
}

/* [NCBK.10.4]: what the second phase's door would refuse, in its order, so the record is
   refused whole, before the call's sample. `now_ns` is the value that sample will hold. A
   capacity refusal raises no BoundsError ([RFCS.24.1]). */
static ds_result_t fx_plan_judge(const fx_plan_t *p, int32_t top,
                                 uint64_t ttl_ns, uint64_t now_ns)
{
    for (uint32_t i = 0; i < p->n; i++) {
        const fx_node_t *x = &p->nodes[i];
        if (x->live != NULL || x->same_as >= 0) continue;
        const ds_schema_t *s = x->schema;
        const char *why = ds_wm_tz_row_malformed(s, x->values, s->n_slots);
        if (why != NULL) return RFCS_ERR(DS_ERR_INVAL, why);
        const uint64_t window = ((int32_t)i == top && ttl_ns != 0)
            ? ttl_ns
            : (s->lifecycle == DS_SCHEMA_LIFECYCLE_TTL ? s->ttl_ns : 0);
        if (window != 0 && window > (uint64_t)INT64_MAX - now_ns)
            return RFCS_ERR(DS_ERR_TIME_RANGE,
                "ds_engine_assert_external: a fact's TTL deadline is outside "
                "the Time range ([RFCS.6.7])");
        const ds_rete_schema_t *rs =
            ds_rete_schema_by_name(p->engine->rete_engine, s->type_name);
        if (rs == NULL) continue;
        for (uint32_t k = 0; k < s->n_slots && k < rs->slot_count; k++)
            if (x->values[k].kind == DS_SLOT_STRING
                    && ds_rete_slot_over_capacity(rs, (uint16_t)k,
                                                  x->values[k].v.s,
                                                  strlen(x->values[k].v.s)))
                return RFCS_ERR(DS_ERR_CONTRACT_BREACH,
                    "ds_engine_assert_external: a String longer than its "
                    "slot's capacity ([LSTR.11.3])");
    }
    return RFCS_OK;
}

/* For ds_engine_assert_external and the replayer ([RFCS.24.2]). `ttl_ns` 0 is the schema's
   default. `out_rete` and `out_ids`, each when not NULL, receive the ids of every fact asserted
   in [RFCS.24.3]'s order, for the caller to free, on DS_OK and on a halt the delivery raised. */
static ds_result_t fx_deliver(ds_engine_t   *engine,
                              const uint8_t *bytes,
                              size_t         len,
                              uint64_t       ttl_ns,
                              uint32_t     **out_rete,
                              uint64_t     **out_ids,
                              size_t        *out_n)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (bytes == NULL && len > 0)
        return RFCS_ERR(DS_ERR_INVAL, "ds_engine_assert_external: NULL bytes");

    {
        ds_result_t nr = fx_scan_nul(bytes, len, true, 0u);
        if (nr.status != DS_OK) return nr;
    }

    Ds__V1__FactExternal *fe =
        ds__v1__fact_external__unpack(&ds_pb_allocator, len, bytes);
    if (fe == NULL)
        return RFCS_ERR(DS_ERR_PARSE,
            "ds_engine_assert_external: the bytes are not a FactExternal");

    fx_plan_t p = { .engine = engine };
    int32_t   top = -1;
    ds_result_t r = fx_plan_node(&p, fe, 0u, true, &top);

    /* One read: the plan judges the value the step below holds. */
    ds_clock_reading_t reading = { 0 };
    if (r.status == DS_OK) {
        uint64_t now_ns = 0;
        if (engine->api_depth == 1) {
            ds_clock_read(&engine->clock, &reading);
            now_ns = reading.mono_ns;
        } else {
            r = ds_clock_now_ns(&engine->clock, &now_ns);
        }
        if (r.status == DS_OK) r = fx_plan_judge(&p, top, ttl_ns, now_ns);
    }

    /* [RFCS.23.7], [LTIM.2.8.5]: the call's one sample. [LGRA.24.3]: if the `initial` block
       refuses this first step, only its TICK is recorded: an ExternalAssert names a delivery
       the engine admitted ([RFCS.24.1]). */
    if (r.status == DS_OK && engine->api_depth == 1)
        r = ds_engine_clock_step_at(engine, DS_CLOCK_STEP_INPUT, &reading);

    /* [RFCS.24.1]: after the TICK, which a recording carries ahead of the input. */
    rfcs_delivery_t dl;
    bool opened = false;
    if (r.status == DS_OK && engine->rfcs_delivery == NULL) {
        rfcs_delivery_open(engine, &dl, bytes, len);
        opened = true;
    }

    uint32_t *rete = NULL;
    uint64_t *ids = NULL;
    size_t    n_rete = 0;
    if (r.status == DS_OK && out_rete != NULL) {
        rete = DS_CALLOC(p.n > 0 ? p.n : 1u, sizeof(*rete));
        if (rete == NULL)
            r = RFCS_ERR(DS_ERR_OOM, "ds_engine_assert_external: fact ids");
    }
    if (r.status == DS_OK && out_ids != NULL) {
        ids = DS_CALLOC(p.n > 0 ? p.n : 1u, sizeof(*ids));
        if (ids == NULL)
            r = RFCS_ERR(DS_ERR_OOM, "ds_engine_assert_external: fact ids");
    }

    /* The live targets, before anything is asserted ([RFCS.23.7]). */
    for (uint32_t i = 0; r.status == DS_OK && i < p.n; i++)
        if (p.nodes[i].live != NULL)
            fx_hold_target(&p.nodes[i], p.nodes[i].live);

    /* The second phase: a target precedes its referrer in the plan, so it has been held by the
       time the referrer needs it. */
    for (uint32_t i = 0; r.status == DS_OK && i < p.n; i++) {
        fx_node_t *x = &p.nodes[i];
        if (x->live != NULL || x->same_as >= 0) continue;
        for (uint32_t k = 0; k < x->schema->n_slots; k++) {
            if (x->ref[k] < 0) continue;
            fx_node_t *t = &p.nodes[fx_canon(&p, x->ref[k])];
            x->values[k].v.ref = t->has_target ? &t->target : NULL;
        }
        if ((int32_t)i == top && ttl_ns != 0)
            r = ds_engine_assert_with_ttl(engine, x->schema, x->values,
                                          x->schema->n_slots, ttl_ns,
                                          &x->asserted);
        else
            r = ds_engine_assert(engine, x->schema, x->values,
                                 x->schema->n_slots, &x->asserted);
        if (r.status == DS_OK && x->asserted != NULL) {
            fx_hold_target(x, x->asserted);
            if (rete != NULL) rete[n_rete] = x->asserted->rete_id;
            if (ids != NULL)  ids[n_rete]  = x->asserted->fact_id;
            n_rete++;
        }
    }

    if (opened) {
        ds_result_t cr = rfcs_delivery_close(engine, &dl);
        (void)cr;   /* already the stream status ([NCBK.1.5]); see close */
    }

    /* The entry check refused an engine already halted, so a halt here is the delivery's own. */
    if ((r.status == DS_OK || r.status == DS_ERR_ENGINE_HALTED)
            && (out_rete != NULL || out_ids != NULL)) {
        if (out_rete != NULL) *out_rete = rete;
        if (out_ids != NULL)  *out_ids  = ids;
        *out_n = n_rete;
    } else {
        DS_FREE(rete);
        DS_FREE(ids);
    }
    fx_plan_free(&p);
    ds__v1__fact_external__free_unpacked(fe, &ds_pb_allocator);
    return r;
}

ds_result_t ds_engine_assert_external(ds_engine_t   *engine,
                                      const uint8_t *bytes,
                                      size_t         len)
{
    if (engine == NULL)
        return RFCS_ERR(DS_ERR_INVAL, "ds_engine_assert_external: NULL engine");
    ds_api_enter(engine);
    return ds_api_leave(engine,
                        fx_deliver(engine, bytes, len, 0u, NULL, NULL, NULL));
}

/* [RFCS.23.2]. The caller frees `*json_owned` and `*fact_owned` after packing. */
static ds_result_t call_arg_to_pb(const ds_arg_t *a, Ds__V1__Arg *pb,
                                  char **json_owned,
                                  Ds__V1__FactExternal **fact_owned)
{
    *json_owned = NULL;
    *fact_owned = NULL;
    ds__v1__arg__init(pb);
    pb->name = (char *)(a->name ? a->name : "");
    switch (a->value.kind) {
    case DS_ARG_INT:
        pb->kind = DS__V1__KIND__KIND_INT;
        pb->value_case = DS__V1__ARG__VALUE_INT_VALUE;
        pb->int_value = a->value.v.i;
        return RFCS_OK;
    case DS_ARG_FLOAT:
        pb->kind = DS__V1__KIND__KIND_FLOAT;
        pb->value_case = DS__V1__ARG__VALUE_FLOAT_VALUE;
        pb->float_value = a->value.v.f;
        return RFCS_OK;
    case DS_ARG_STRING:
        pb->kind = DS__V1__KIND__KIND_STRING;
        pb->value_case = DS__V1__ARG__VALUE_STRING_VALUE;
        pb->string_value = (char *)(a->value.v.s ? a->value.v.s : "");
        return RFCS_OK;
    case DS_ARG_BOOL:
        pb->kind = DS__V1__KIND__KIND_BOOL;
        pb->value_case = DS__V1__ARG__VALUE_BOOL_VALUE;
        pb->bool_value = a->value.v.b ? 1 : 0;
        return RFCS_OK;
    case DS_ARG_JSON: {
        size_t len = 0;
        ds_result_t r = ds_json_serialize(a->value.v.json, json_owned, &len);
        if (r.status != DS_OK) return r;
        pb->kind = DS__V1__KIND__KIND_JSON;
        pb->value_case = DS__V1__ARG__VALUE_JSON_VALUE;
        pb->json_value = *json_owned;
        return RFCS_OK;
    }
    case DS_ARG_BYTES:
        pb->kind = DS__V1__KIND__KIND_BYTES;
        pb->value_case = DS__V1__ARG__VALUE_BYTES_VALUE;
        pb->bytes_value.data = (uint8_t *)a->value.v.bytes.data;
        pb->bytes_value.len  = a->value.v.bytes.len;
        return RFCS_OK;
    case DS_ARG_NULL:
        pb->kind = DS__V1__KIND__KIND_NULL;
        pb->value_case = DS__V1__ARG__VALUE__NOT_SET;
        return RFCS_OK;
    case DS_ARG_ENCODED_FACT: {
        Ds__V1__FactExternal *fe = ds__v1__fact_external__unpack(
            &ds_pb_allocator, a->value.v.fact.bytes.len, a->value.v.fact.bytes.data);
        if (fe == NULL)
            return RFCS_ERR(DS_ERR_PARSE,
                            "ds_rfcs_encode_call: a fact argument's FactExternal "
                            "does not decode");
        *fact_owned = fe;
        pb->kind = DS__V1__KIND__KIND_ENCODED_FACT;
        pb->value_case = DS__V1__ARG__VALUE_FACT;
        pb->fact = fe;
        return RFCS_OK;
    }
    }
    return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_call: an argument of no kind");
}

ds_result_t ds_rfcs_encode_call(uint64_t seq, int64_t clock_ns,
                                int64_t timetag, const char *rule_name,
                                const char *service, const char *correlation,
                                const ds_arg_t *args, uint32_t arg_count,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_call: NULL out_len");
    if (arg_count > 0 && !args)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_call: NULL args");

    Ds__V1__CallIssued msg = DS__V1__CALL_ISSUED__INIT;
    msg.seq = seq;
    msg.clock_ns = (uint64_t)clock_ns;
    msg.timetag = timetag;
    msg.rule_name = (char *)(rule_name ? rule_name : "");
    msg.service = (char *)(service ? service : "");
    msg.correlation = (char *)(correlation ? correlation : "");

    uint32_t     n = arg_count;
    Ds__V1__Arg  pb[n > 0 ? n : 1];
    Ds__V1__Arg *pp[n > 0 ? n : 1];
    char        *json[n > 0 ? n : 1];
    Ds__V1__FactExternal *facts[n > 0 ? n : 1];
    ds_result_t  r = RFCS_OK;
    uint32_t     built = 0;
    for (; built < n; built++) {
        r = call_arg_to_pb(&args[built], &pb[built], &json[built], &facts[built]);
        if (r.status != DS_OK) break;
        pp[built] = &pb[built];
    }
    if (r.status == DS_OK) {
        msg.n_args = n;
        msg.args   = n > 0 ? pp : NULL;
        size_t body = ds__v1__call_issued__get_packed_size(&msg);
        size_t body_off = 0;
        r = frame_into(DS_ATOM_CALL_ISSUED, body, out, out_cap, out_len, &body_off);
        if (r.status == DS_OK)
            ds__v1__call_issued__pack(&msg, out + body_off);
    }
    /* The arg that failed set its owned pointers NULL before failing, so
       `built` plus that one covers everything made. */
    uint32_t made = built < n ? built + 1 : built;
    for (uint32_t i = 0; i < made; i++) {
        ds_free(json[i]);
        if (facts[i] != NULL)
            ds__v1__fact_external__free_unpacked(facts[i], &ds_pb_allocator);
    }
    return r.status == DS_OK ? RFCS_OK : r;
}

/* The four fault atoms: the bodies do not share a field layout. */

ds_result_t ds_rfcs_encode_eerr(uint64_t seq, uint64_t clock_ns,
                                uint32_t trap_kind, const char *rule_name,
                                int64_t timetag, const char *schema_name,
                                const char *slot_name, uint64_t fact_id,
                                uint32_t node_id,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_eerr: NULL out_len");

    Ds__V1__ComputationError msg = DS__V1__COMPUTATION_ERROR__INIT;
    msg.kind        = (Ds__V1__TrapKind) trap_kind;
    msg.rule_name   = (char *)(rule_name ? rule_name : "");
    msg.timetag     = timetag;
    msg.schema_name = (char *)(schema_name ? schema_name : "");
    msg.slot_name   = (char *)(slot_name ? slot_name : "");
    msg.fact_id     = fact_id;
    msg.node_id     = node_id;
    /* A constant: a ComputationError leaves the engine intact, whatever its TrapKind. */
    msg.recoverable = true;
    msg.clock_ns    = clock_ns;
    msg.seq         = seq;

    size_t body = ds__v1__computation_error__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_COMPUTATION_ERROR, body, out, out_cap,
                               out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__computation_error__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_type(uint64_t seq, uint64_t clock_ns,
                                uint32_t node_id, const char *schema_name,
                                const char *slot_name, const char *actual,
                                const char *rule_name,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_type: NULL out_len");

    Ds__V1__TypeError msg = DS__V1__TYPE_ERROR__INIT;
    msg.node_id     = node_id;
    msg.schema_name = (char *)(schema_name ? schema_name : "");
    msg.slot_name   = (char *)(slot_name ? slot_name : "");
    msg.actual      = (char *)(actual ? actual : "");
    msg.rule_name   = (char *)(rule_name ? rule_name : "");   /* [LERR.9.11] */
    msg.clock_ns    = clock_ns;
    msg.seq         = seq;

    size_t body = ds__v1__type_error__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_TYPE_ERROR, body, out, out_cap,
                               out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__type_error__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_bnds(uint64_t seq, uint64_t clock_ns,
                                uint32_t cap, uint64_t limit, uint64_t observed,
                                const char *rule_name, int64_t timetag,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_bnds: NULL out_len");

    Ds__V1__BoundsError msg = DS__V1__BOUNDS_ERROR__INIT;
    msg.cap       = (Ds__V1__CapName) cap;
    msg.limit     = limit;
    msg.observed  = observed;
    msg.rule_name = (char *)(rule_name ? rule_name : "");
    msg.timetag   = timetag;
    msg.clock_ns  = clock_ns;
    msg.seq       = seq;

    size_t body = ds__v1__bounds_error__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_BOUNDS_ERROR, body, out, out_cap,
                               out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__bounds_error__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_engf(uint64_t seq, uint64_t clock_ns,
                                uint32_t fault, uint32_t node_id,
                                const char *rule_name,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_engf: NULL out_len");

    Ds__V1__EngineError msg = DS__V1__ENGINE_ERROR__INIT;
    msg.fault     = (Ds__V1__EngineFault) fault;
    msg.node_id   = node_id;
    msg.rule_name = (char *)(rule_name ? rule_name : "");   /* [LERR.9.11] */
    msg.clock_ns = clock_ns;
    msg.seq      = seq;

    size_t body = ds__v1__engine_error__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_ENGINE_ERROR, body, out, out_cap,
                               out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__engine_error__pack(&msg, out + body_off);
    return RFCS_OK;
}

/* ---- decoders ---- */

/* The string at `field`, as a view into the body ("" when absent); the last
   occurrence wins. Called only on a body the generated unpacker has accepted,
   so the walk ending early is the end of the body. */
static ds_rfcs_str_t body_str(const uint8_t *body, size_t len, uint32_t field)
{
    ds_rfcs_str_t s = { "", 0 };
    size_t pos = 0;
    for (;;) {
        ds_pbf_field_t f;
        if (ds_pbf_next_field(body, len, pos, &f) != DS_PBF_OK) break;
        if (f.field == field && f.wire == 2u) {
            s.ptr = f.val_len ? (const char *)f.val : "";
            s.len = f.val_len;
        }
        pos = f.next;
    }
    return s;
}

ds_result_t ds_rfcs_decode_header(const uint8_t *body, size_t body_len,
                                  ds_rfcs_header_t *out)
{
    if (!out)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_decode_header: NULL out");

    Ds__V1__StreamHeader *m =
        ds__v1__stream_header__unpack(&ds_pb_allocator, body_len, body);
    if (!m)
        return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_header: malformed StreamHeader");

    memset(out, 0, sizeof(*out));
    /* [LDET.1.10]: absent leaves the buffer NUL, which
       ds_version_series_match rejects. */
    if (m->ds_version) {
        strncpy(out->ds_version, m->ds_version, sizeof(out->ds_version) - 1);
    }
    /* Uncut: a replay given the run id reproduces every `event_id` ([RFCS.4.3]). */
    out->session_id = body_str(body, body_len, 5);
    out->tier_id    = body_str(body, body_len, 6);
    if (m->dsc_hash.len) {
        size_t n = m->dsc_hash.len < sizeof(out->dsc_hash)
                       ? m->dsc_hash.len
                       : sizeof(out->dsc_hash);
        memcpy(out->dsc_hash, m->dsc_hash.data, n);
        out->dsc_hash_len = n;
    }
    /* [RBND.1.3]: kept as written. Refused rather than cut or repaired, since
       a changed list would compare as another tuple. */
    if (m->n_capabilities > DS_BINDING_CAPABILITIES_MAX) {
        ds__v1__stream_header__free_unpacked(m, &ds_pb_allocator);
        return RFCS_ERR(DS_ERR_PARSE,
                        "ds_rfcs_decode_header: more capabilities than a "
                        "header may carry (RBND.1.3)");
    }
    for (size_t i = 0; i < m->n_capabilities; i++)
        out->capabilities[i] = (uint32_t) m->capabilities[i];
    out->n_capabilities = m->n_capabilities;
    if (!ds_binding_capabilities_well_formed(out->capabilities,
                                             out->n_capabilities)) {
        ds__v1__stream_header__free_unpacked(m, &ds_pb_allocator);
        return RFCS_ERR(DS_ERR_PARSE,
                        "ds_rfcs_decode_header: the capabilities are not "
                        "strictly ascending over Capability's members "
                        "(RBND.1.3)");
    }
    if (m->dialect_def_sha256.len) {
        size_t n = m->dialect_def_sha256.len < sizeof(out->dialect_def_sha256)
                       ? m->dialect_def_sha256.len
                       : sizeof(out->dialect_def_sha256);
        memcpy(out->dialect_def_sha256, m->dialect_def_sha256.data, n);
        out->dialect_def_sha256_len = m->dialect_def_sha256.len;
    }
    ds__v1__stream_header__free_unpacked(m, &ds_pb_allocator);
    return RFCS_OK;
}

/* The two buffers that hold the tuple's capabilities are sized by
   DS_BINDING_CAPABILITIES_MAX's value, written out because rfcs.h ships
   without binding.h. They must agree with it. */
typedef char rfcs_header_caps_bound_[
    (sizeof(((ds_rfcs_header_t *)0)->capabilities) / sizeof(uint32_t)
     == DS_BINDING_CAPABILITIES_MAX) ? 1 : -1];
typedef char engine_caps_bound_[
    (sizeof(((ds_engine_t *)0)->dsc_capabilities) / sizeof(uint32_t)
     == DS_BINDING_CAPABILITIES_MAX) ? 1 : -1];

/* ---- the dialect-binding comparison ([RBND.6.1]) ----------------------------
 *
 * Declared in binding.h. Here because the detail names capabilities from the
 * generated enum, which this unit compiles against. */

static bool bnd_bytes_eq(const uint8_t *a, size_t na, const uint8_t *b, size_t nb)
{
    return na == nb && (na == 0 || memcmp(a, b, na) == 0);
}

/* [RBND.5.2]: the first eight bytes, or all of a shorter field. */
static void bnd_short_hex(ds_text_t *d, const uint8_t *b, size_t n)
{
    for (size_t i = 0; i < n && i < 8; i++)
        ds_text_hex(d, b[i], 2);
}

static bool bnd_has(const uint32_t *xs, size_t n, uint32_t x)
{
    for (size_t i = 0; i < n; i++)
        if (xs[i] == x) return true;
    return false;
}

/* The capabilities of `xs` that `ys` does not hold, comma-separated, or
   "(none)". A name is the enum member's without `CAPABILITY_`, in lower case
   ([LCAP.1]); 0 and a number no member names are written as the number. */
static void bnd_cap_names(ds_text_t *d, const uint32_t *xs, size_t nx,
                          const uint32_t *ys, size_t ny)
{
    static const char prefix[] = "CAPABILITY_";
    bool any = false;
    for (size_t i = 0; i < nx; i++) {
        if (bnd_has(ys, ny, xs[i])) continue;
        if (any) ds_text_char(d, ',');
        any = true;
        const ProtobufCEnumValue *v = xs[i] == 0 || xs[i] > (uint32_t) INT32_MAX
            ? NULL
            : protobuf_c_enum_descriptor_get_value(&ds__v1__capability__descriptor,
                                                   (int) xs[i]);
        if (v == NULL || strncmp(v->name, prefix, sizeof prefix - 1) != 0) {
            ds_text_u64(d, xs[i]);
            continue;
        }
        for (const char *c = v->name + sizeof prefix - 1; *c; c++)
            ds_text_char(d, (*c >= 'A' && *c <= 'Z') ? (char)(*c - 'A' + 'a') : *c);
    }
    if (!any) ds_text_str(d, "(none)");
}

ds_result_t ds_binding_compare_dialect(struct ds_engine         *engine,
                                       const ds_dialect_tuple_t *rec,
                                       const ds_dialect_tuple_t *loaded)
{
    ds_rete_engine_t *re = engine != NULL ? engine->rete_engine : NULL;
    if (!bnd_bytes_eq(rec->dsc_sha256, rec->dsc_sha256_len,
                      loaded->dsc_sha256, loaded->dsc_sha256_len)) {
        ds_text_t d = ds_rete_engine_detail(re);
        ds_text_str(&d, "dsc_sha256: ");
        bnd_short_hex(&d, rec->dsc_sha256, rec->dsc_sha256_len);
        ds_text_str(&d, " vs ");
        bnd_short_hex(&d, loaded->dsc_sha256, loaded->dsc_sha256_len);
        return RFCS_ERR(DS_ERR_BND_DSC_MISMATCH,
                        ds_rete_engine_detail_text(&d,
                            "dsc_sha256 differs (RBND.5.2)"));
    }
    /* As a sequence: sorting first would accept a writer that did not write
       them ascending ([RBND.1.3]). */
    bool caps_eq = rec->n_capabilities == loaded->n_capabilities;
    for (size_t i = 0; caps_eq && i < rec->n_capabilities; i++)
        caps_eq = rec->capabilities[i] == loaded->capabilities[i];
    if (!caps_eq) {
        ds_text_t d = ds_rete_engine_detail(re);
        ds_text_str(&d, "capabilities: in one and not the other: ");
        bnd_cap_names(&d, rec->capabilities, rec->n_capabilities,
                      loaded->capabilities, loaded->n_capabilities);
        ds_text_str(&d, " vs ");
        bnd_cap_names(&d, loaded->capabilities, loaded->n_capabilities,
                      rec->capabilities, rec->n_capabilities);
        return RFCS_ERR(DS_ERR_BND_DIALECT_MISMATCH,
                        ds_rete_engine_detail_text(&d,
                            "capabilities differ (RBND.5.2)"));
    }
    if (!bnd_bytes_eq(rec->dialect_def_sha256, rec->dialect_def_sha256_len,
                      loaded->dialect_def_sha256,
                      loaded->dialect_def_sha256_len)) {
        ds_text_t d = ds_rete_engine_detail(re);
        ds_text_str(&d, "dialect_def_sha256: ");
        bnd_short_hex(&d, rec->dialect_def_sha256, rec->dialect_def_sha256_len);
        ds_text_str(&d, " vs ");
        bnd_short_hex(&d, loaded->dialect_def_sha256,
                      loaded->dialect_def_sha256_len);
        return RFCS_ERR(DS_ERR_BND_DIALECT_MISMATCH,
                        ds_rete_engine_detail_text(&d,
                            "dialect_def_sha256 differs (RBND.5.2)"));
    }
    return RFCS_OK;
}

ds_result_t ds_rfcs_decode_clka(const uint8_t *body, size_t body_len,
                                ds_rfcs_clka_t *out)
{
    if (!out)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_decode_clka: NULL out");

    Ds__V1__ClockAdvance *m =
        ds__v1__clock_advance__unpack(&ds_pb_allocator, body_len, body);
    if (!m)
        return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_clka: malformed ClockAdvance");

    out->seq = m->seq;
    out->clock_ns = m->clock_ns;
    out->has_wall = m->has_wall;
    out->wall_ns = m->has_wall ? m->wall_ns : 0;
    ds__v1__clock_advance__free_unpacked(m, &ds_pb_allocator);
    return RFCS_OK;
}

ds_result_t ds_rfcs_decode_rfra(const uint8_t *body, size_t body_len,
                                ds_rfcs_rfra_t *out)
{
    if (!out)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_decode_rfra: NULL out");

    Ds__V1__RuleFireAnnotation *m =
        ds__v1__rule_fire_annotation__unpack(&ds_pb_allocator, body_len, body);
    if (!m)
        return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_rfra: malformed RuleFireAnnotation");

    memset(out, 0, sizeof(*out));
    out->seq = m->seq;
    out->clock_ns = m->clock_ns;
    out->timetag = m->timetag;
    out->end = m->end ? true : false;
    if (m->rule_name) {
        strncpy(out->rule_name, m->rule_name, sizeof(out->rule_name) - 1);
    }
    ds__v1__rule_fire_annotation__free_unpacked(m, &ds_pb_allocator);
    return RFCS_OK;
}

/* ---- fact-body codec (RFCS.6.3) ---- */

/* A minimal proto3 writer. With buf == NULL it is a size-only pass: every
   append advances `pos` but writes nothing, so after a pass `pos` is the
   exact encoded size. With buf != NULL it writes (bounds-checked against
   cap) and advances. */
typedef struct {
    uint8_t *buf;
    size_t   pos;
    size_t   cap;
} pbw_t;

static void pbw_byte(pbw_t *w, uint8_t b)
{
    if (w->buf && w->pos < w->cap)
        w->buf[w->pos] = b;
    w->pos++;
}

static void pbw_raw(pbw_t *w, const uint8_t *p, size_t n)
{
    if (w->buf) {
        for (size_t i = 0; i < n && w->pos + i < w->cap; i++)
            w->buf[w->pos + i] = p[i];
    }
    w->pos += n;
}

static void pbw_varint(pbw_t *w, uint64_t v)
{
    do {
        uint8_t b = (uint8_t)(v & 0x7Fu);
        v >>= 7;
        if (v)
            b |= 0x80u;
        pbw_byte(w, b);
    } while (v);
}

static void pbw_tag(pbw_t *w, uint32_t field, uint32_t wire)
{
    pbw_varint(w, ((uint64_t)field << 3) | wire);
}

static void pbw_fixed64(pbw_t *w, uint64_t bits)
{
    for (int i = 0; i < 8; i++)
        pbw_byte(w, (uint8_t)((bits >> (8 * i)) & 0xFFu));
}

static void pbw_lendelim(pbw_t *w, const uint8_t *data, size_t len)
{
    pbw_varint(w, (uint64_t)len);
    pbw_raw(w, data, len);
}

ds_result_t ds_rfcs_encode_pump(uint64_t seq, int64_t clock_ns,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_pump: NULL out_len");

    /* By hand: the message's generated C lives in reader/, which rfcs/ does
       not build against. */
    uint8_t body[2 * 11];
    pbw_t w = { NULL, 0, 0 };
    for (int pass = 0; pass < 2; pass++) {
        w.pos = 0;
        if (seq) { pbw_tag(&w, 1, 0); pbw_varint(&w, seq); }
        if (clock_ns) { pbw_tag(&w, 2, 0); pbw_varint(&w, (uint64_t)clock_ns); }
        if (pass == 0) { w.buf = body; w.cap = sizeof body; }
    }

    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_PUMP_BOUNDARY, w.pos, out, out_cap, out_len,
                               &body_off);
    if (r.status != DS_OK)
        return r;
    memcpy(out + body_off, body, w.pos);
    return RFCS_OK;
}

/* By hand, since `fact` is the FactExternal bytes as the host passed them
   (RFCS.24.1) and not re-packed from a parsed tree. */
static ds_result_t encode_fcxt(const uint8_t *fact, size_t fact_len,
                               const uint64_t *ids, size_t n_ids,
                               uint64_t ttl_ns, uint64_t clock_ns, uint64_t seq,
                               uint8_t *out, size_t out_cap, size_t *out_len)
{
    size_t ids_len = 0;
    {
        pbw_t s = { NULL, 0, 0 };
        for (size_t i = 0; i < n_ids; i++) pbw_varint(&s, ids[i]);
        ids_len = s.pos;
    }
    pbw_t w = { NULL, 0, 0 };
    size_t body_off = 0;
    for (int pass = 0; pass < 2; pass++) {
        w.pos = 0;
        if (fact_len > 0) { pbw_tag(&w, 1, 2); pbw_lendelim(&w, fact, fact_len); }
        if (n_ids > 0) {
            pbw_tag(&w, 2, 2);
            pbw_varint(&w, (uint64_t)ids_len);
            for (size_t i = 0; i < n_ids; i++) pbw_varint(&w, ids[i]);
        }
        if (ttl_ns)   { pbw_tag(&w, 3, 0); pbw_varint(&w, ttl_ns); }
        if (clock_ns) { pbw_tag(&w, 4, 0); pbw_varint(&w, clock_ns); }
        if (seq)      { pbw_tag(&w, 5, 0); pbw_varint(&w, seq); }
        if (pass == 0) {
            ds_result_t r = frame_into(DS_ATOM_EXTERNAL_ASSERT, w.pos, out, out_cap,
                                       out_len, &body_off);
            if (r.status != DS_OK)
                return r;
            w.buf = out + body_off;
            w.cap = w.pos;
        }
    }
    return RFCS_OK;
}

/* The decoded ExternalAssert a replayer delivers. `fact` and `ids` point
   into, or are owned beside, the atom body: `ids` is the caller's to free. */
typedef struct {
    const uint8_t *fact;
    size_t         fact_len;
    uint64_t      *ids;
    size_t         n_ids;
    uint64_t       ttl_ns;
    uint64_t       clock_ns;
    uint64_t       seq;
} fcxt_body_t;

static bool read_varint(const uint8_t *buf, size_t len, size_t *pos,
                        uint64_t *out);

/* `fact_ids` is read packed or one varint per field. A wire type the field
   does not take is malformed. */
static ds_result_t decode_fcxt(const uint8_t *body, size_t len, fcxt_body_t *out)
{
    memset(out, 0, sizeof(*out));
    size_t cap = 0;
    size_t pos = 0;
    for (;;) {
        ds_pbf_field_t f;
        ds_pbf_step_t st = ds_pbf_next_field(body, len, pos, &f);
        if (st == DS_PBF_EOF && pos == len) break;
        if (st != DS_PBF_OK) goto malformed;
        pos = f.next;
        if (f.field == 1u) {
            if (f.wire != 2u) goto malformed;
            out->fact = f.val;
            out->fact_len = f.val_len;
        } else if (f.field == 2u) {
            if (f.wire == 0u) {
                if (out->n_ids == cap) {
                    size_t ncap = cap ? cap * 2u : 8u;
                    uint64_t *n = DS_REALLOC(out->ids, ncap * sizeof(*n));
                    if (n == NULL) goto oom;
                    out->ids = n;
                    cap = ncap;
                }
                out->ids[out->n_ids++] = f.u64;
            } else if (f.wire == 2u) {
                size_t q = 0;
                while (q < f.val_len) {
                    uint64_t v = 0;
                    if (!read_varint(f.val, f.val_len, &q, &v)) goto malformed;
                    if (out->n_ids == cap) {
                        size_t ncap = cap ? cap * 2u : 8u;
                        uint64_t *n = DS_REALLOC(out->ids, ncap * sizeof(*n));
                        if (n == NULL) goto oom;
                        out->ids = n;
                        cap = ncap;
                    }
                    out->ids[out->n_ids++] = v;
                }
            } else {
                goto malformed;
            }
        } else if (f.field >= 3u && f.field <= 5u) {
            if (f.wire != 0u) goto malformed;
            if (f.field == 3u) out->ttl_ns = f.u64;
            else if (f.field == 4u) out->clock_ns = f.u64;
            else out->seq = f.u64;
        }
        /* any other field is skipped */
    }
    if (out->fact == NULL)
        goto malformed;
    return RFCS_OK;
malformed:
    DS_FREE(out->ids);
    out->ids = NULL;
    return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_replay: malformed ExternalAssert body");
oom:
    DS_FREE(out->ids);
    out->ids = NULL;
    return RFCS_ERR(DS_ERR_OOM, "ds_rfcs_replay: ExternalAssert fact_ids");
}

/* Emit every slot of `fact` as proto3 fields (1..N). [RFCS.6.3]: a nullable
   slot's field is `optional`, written for every value, zero included, and
   omitted for `null`; a non-nullable field omits a zero.

   Reads unchecked ([NCBK.2.9]): ds_rfcs_encode_fact_body, which takes a
   caller's handle, carries the guard. */
static ds_result_t emit_fact_fields(const ds_fact_t *fact, pbw_t *w)
{
    uint32_t count = 0;
    ds_result_t r = ds_fact_get_slot_count_unchecked(fact, &count);
    if (r.status != DS_OK)
        return r;
    const ds_schema_t *schema = NULL;
    r = ds_fact_get_schema_unchecked(fact, &schema);
    if (r.status != DS_OK)
        return r;

    for (uint32_t i = 0; i < count; i++) {
        ds_slot_value_t val;
        r = ds_fact_get_slot_unchecked(fact, i, NULL, &val);
        if (r.status != DS_OK)
            return r;
        ds_slot_desc_t desc;
        r = ds_schema_get_slot_unchecked(schema, i, &desc);
        if (r.status != DS_OK)
            return r;
        uint32_t field = i + 1;
        bool present = desc.nullable;   /* write a zero too */

        switch (val.kind) {
        case DS_SLOT_INT:
            if (present || val.v.i != 0) {
                pbw_tag(w, field, 0);
                pbw_varint(w, (uint64_t)val.v.i);
            }
            break;
        case DS_SLOT_BOOL:
            if (present || val.v.b) {
                pbw_tag(w, field, 0);
                pbw_varint(w, val.v.b ? 1 : 0);
            }
            break;
        case DS_SLOT_FLOAT: {
            /* The bits, not the value: -0.0 is not the proto3 default
               ([LDET.1.5]). */
            uint64_t bits;
            memcpy(&bits, &val.v.f, sizeof(bits));
            if (present || bits != 0) {
                pbw_tag(w, field, 1);
                pbw_fixed64(w, bits);
            }
            break;
        }
        case DS_SLOT_STRING: {
            const char *s = val.v.s ? val.v.s : "";
            size_t n = strlen(s);
            if (present || n) {
                pbw_tag(w, field, 2);
                pbw_lendelim(w, (const uint8_t *)s, n);
            }
            break;
        }
        case DS_SLOT_BYTES:
            if (present || val.v.bytes.len) {
                pbw_tag(w, field, 2);
                pbw_lendelim(w, val.v.bytes.data, val.v.bytes.len);
            }
            break;
        case DS_SLOT_JSON:
            /* The canonical ds_json_serialize text. A NULL tree is absent; a
               present one serializes non-empty (json null is "null"). */
            if (val.v.json != NULL) {
                char *txt = NULL;
                size_t tlen = 0;
                ds_result_t jr = ds_json_serialize(val.v.json, &txt, &tlen);
                if (jr.status != DS_OK)
                    return jr;
                if (tlen) {
                    pbw_tag(w, field, 2);
                    pbw_lendelim(w, (const uint8_t *)txt, tlen);
                }
                ds_free(txt);
            }
            break;
        case DS_SLOT_NULL:
            /* [RFCS.6.3]: `null` is the absent `optional` field. In a slot
               that is not nullable, omitting it would replay as the type's
               zero. */
            if (!present)
                return RFCS_ERR(DS_ERR_INVAL,
                                "ds_rfcs fact body: a null in a non-nullable slot "
                                "has no encoding ([RFCS.6.3])");
            break;
        case DS_SLOT_FACT_REF: {
            /* RFCS.6.3: the referenced fact's `fact_id`, read from the slot
               because `val.v.ref` is NULL once the target has left working
               memory. Id 0 is no target, written as a null is. A replay writes
               its own fact's id, not one mapped back through its id map
               (RFCS.6a.3).

               Only a slot declared a reference carries a handle: a fact-ref
               value in another slot, what a `cached()` miss leaves in an `Int`
               slot, is refused. A recording tool matches the message's
               "fact-ref slot does not cross tiers". */
            if (desc.type != DS_SLOT_TYPE_SCHEMA)
                return RFCS_ERR(DS_ERR_INVAL,
                                "ds_rfcs fact body: fact-ref slot does not cross "
                                "tiers -- a reference in a slot not declared one");
            uint64_t ref_id = 0;
            r = ds_fact_get_slot_ref_id_unchecked(fact, i, &ref_id);
            if (r.status != DS_OK)
                return r;
            if (ref_id == 0) {
                if (!present)
                    return RFCS_ERR(DS_ERR_INVAL,
                                    "ds_rfcs fact body: a null in a non-nullable "
                                    "slot has no encoding ([RFCS.6.3])");
                break;
            }
            pbw_tag(w, field, 0);
            pbw_varint(w, ref_id);
            break;
        }
        default:
            return RFCS_ERR(DS_ERR_INVAL,
                            "ds_rfcs fact body: a slot kind with no encoding");
        }
    }
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_fact_body(const ds_fact_t *fact,
                                     uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!fact || !out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_fact_body: NULL arg");
    /* A caller's handle, read as ds_fact_get_* reads it ([NCBK.2.9]). */
    DS_HANDLE_REFUSE_IF_HALTED(fact->engine);

    pbw_t sz = { NULL, 0, 0 };
    ds_result_t r = emit_fact_fields(fact, &sz);
    if (r.status != DS_OK)
        return r;
    size_t body = sz.pos;

    if (!out || out_cap < body) {
        *out_len = body;
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_fact_body: output buffer too small");
    }
    pbw_t wr = { out, 0, body };
    r = emit_fact_fields(fact, &wr);
    if (r.status != DS_OK)
        return r;
    *out_len = body;
    return RFCS_OK;
}

/* The recorder's fact-body scratch: on the stack, or one allocation for a body
   the size pass finds larger. */
typedef struct {
    uint8_t        stack[2048];
    uint8_t       *heap;
    const uint8_t *data;
    size_t         len;
} rec_body_t;

static void rec_body_free(rec_body_t *b)
{
    if (b->heap)
        DS_FREE(b->heap);
    b->heap = NULL;
}

static ds_result_t rec_body_encode(const ds_fact_t *fact, rec_body_t *b)
{
    b->heap = NULL;
    b->data = NULL;
    b->len = 0;

    pbw_t sz = { NULL, 0, 0 };
    ds_result_t r = emit_fact_fields(fact, &sz);
    if (r.status != DS_OK)
        return r;

    uint8_t *dst = b->stack;
    if (sz.pos > sizeof(b->stack)) {
        b->heap = DS_MALLOC(sz.pos);
        if (!b->heap)
            return RFCS_ERR(DS_ERR_OOM, "rfcs: no memory for a fact body");
        dst = b->heap;
    }
    pbw_t wr = { dst, 0, sz.pos };
    r = emit_fact_fields(fact, &wr);
    if (r.status != DS_OK) {
        rec_body_free(b);
        return r;
    }
    b->data = dst;
    b->len = sz.pos;
    return RFCS_OK;
}

static bool read_varint(const uint8_t *buf, size_t len, size_t *pos, uint64_t *out)
{
    uint64_t v = 0;
    int shift = 0;
    size_t p = *pos;
    while (p < len) {
        uint8_t b = buf[p++];
        v |= (uint64_t)(b & 0x7Fu) << shift;
        if (!(b & 0x80u)) {
            *pos = p;
            *out = v;
            return true;
        }
        shift += 7;
        if (shift >= 64)
            return false; /* malformed: varint too long */
    }
    return false; /* truncated */
}

/* [LTIM.2.8.5]: the field number of `seq` in an event atom's body; 0 for an
   atom that is not an event. */
static uint32_t event_seq_field(uint32_t atom)
{
    switch (atom) {
    case DS_ATOM_FACT_ASSERT: case DS_ATOM_FACT_EMIT: return 7;
    case DS_ATOM_FACT_RETRACT:                    return 2;
    case DS_ATOM_CLOCK_ADVANCE: case DS_ATOM_PUMP_BOUNDARY:
    case DS_ATOM_RULE_FIRE_ANNOTATION:                    return 1;
    case DS_ATOM_CALL_ISSUED: case DS_ATOM_TYPE_ERROR: return 6;
    case DS_ATOM_FACT_WITHDRAW: case DS_ATOM_ENGINE_ERROR:
    case DS_ATOM_FACT_PUBLISH:                         return 4;
    case DS_ATOM_COMPUTATION_ERROR:                    return 10;
    case DS_ATOM_BOUNDS_ERROR:                    return 7;
    default:                              return 0;
    }
}

/* The varint at `field` in a protobuf body, 0 when absent (proto3 omits a 0).
   False on a malformed body. */
static bool body_varint(const uint8_t *body, size_t len, uint32_t field,
                        uint64_t *out)
{
    size_t pos = 0;
    *out = 0;
    while (pos < len) {
        uint64_t tag = 0, v = 0;
        if (!read_varint(body, len, &pos, &tag))
            return false;
        switch (tag & 7u) {
        case 0:
            if (!read_varint(body, len, &pos, &v))
                return false;
            if ((tag >> 3) == field)
                *out = v;
            break;
        case 1:
            if (len - pos < 8) return false;
            pos += 8;
            break;
        case 2:
            if (!read_varint(body, len, &pos, &v) || v > len - pos)
                return false;
            pos += (size_t)v;
            break;
        case 5:
            if (len - pos < 4) return false;
            pos += 4;
            break;
        default:
            return false;
        }
    }
    return true;
}

static void free_owned_json(ds_slot_value_t *values, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) {
        if (values[i].kind == DS_SLOT_JSON && values[i].v.json != NULL) {
            ds_json_free(values[i].v.json);
            values[i].v.json = NULL;
        }
    }
}

ds_result_t ds_rfcs_decode_fact_body(const ds_schema_t *schema,
                                     const uint8_t *body, size_t body_len,
                                     ds_slot_value_t *values, uint32_t values_cap,
                                     char *scratch, size_t scratch_cap,
                                     uint32_t *out_n)
{
    return ds_rfcs_decode_fact_body_resolving(schema, body, body_len, values,
                                              values_cap, scratch, scratch_cap,
                                              NULL, NULL, out_n);
}

/* Slot `i`'s declared type and nullability, from an engine's schema or the
   stream's own Slot announcement ([RFCS.5.1]). */
typedef ds_result_t (*body_slot_fn)(const void *src, uint32_t i,
                                    ds_slot_type_t *type, bool *nullable);

static ds_result_t schema_body_slot(const void *src, uint32_t i,
                                    ds_slot_type_t *type, bool *nullable)
{
    ds_slot_desc_t d;
    ds_result_t r = ds_schema_get_slot((const ds_schema_t *)src, i, &d);
    if (r.status != DS_OK)
        return r;
    *type = d.type;
    *nullable = d.nullable;
    return RFCS_OK;
}

/* `dsc/loader.c`'s `slot_kind_to_type`, for a reader that has no loader. */
static ds_result_t announced_body_slot(const void *src, uint32_t i,
                                       ds_slot_type_t *type, bool *nullable)
{
    const ds_rfcs_announced_slot_t *s = &((const ds_rfcs_announced_slot_t *)src)[i];
    *nullable = s->nullable;
    switch (s->kind) {
    case DS__V1__SLOT_KIND__SLOT_KIND_INT:      *type = DS_SLOT_TYPE_INT;      break;
    case DS__V1__SLOT_KIND__SLOT_KIND_FLOAT:    *type = DS_SLOT_TYPE_FLOAT;    break;
    case DS__V1__SLOT_KIND__SLOT_KIND_STRING:   *type = DS_SLOT_TYPE_STRING;   break;
    case DS__V1__SLOT_KIND__SLOT_KIND_BOOL:     *type = DS_SLOT_TYPE_BOOL;     break;
    case DS__V1__SLOT_KIND__SLOT_KIND_JSON:     *type = DS_SLOT_TYPE_JSON;     break;
    case DS__V1__SLOT_KIND__SLOT_KIND_SCHEMA:   *type = DS_SLOT_TYPE_SCHEMA;   break;
    case DS__V1__SLOT_KIND__SLOT_KIND_BYTES:    *type = DS_SLOT_TYPE_BYTES;    break;
    case DS__V1__SLOT_KIND__SLOT_KIND_TIME:     *type = DS_SLOT_TYPE_TIME;     break;
    case DS__V1__SLOT_KIND__SLOT_KIND_DATE:     *type = DS_SLOT_TYPE_DATE;     break;
    case DS__V1__SLOT_KIND__SLOT_KIND_DURATION: *type = DS_SLOT_TYPE_DURATION; break;
    default:
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_decode_announced_fact_body: a Slot announces "
                        "a kind no slot type has");
    }
    return RFCS_OK;
}

static ds_result_t decode_body(body_slot_fn slot_at, const void *src,
                               uint32_t n,
                               const uint8_t *body, size_t body_len,
                               ds_slot_value_t *values, uint32_t values_cap,
                               char *scratch, size_t scratch_cap,
                               ds_rfcs_handle_fn resolve, void *resolve_user,
                               uint64_t *handles, uint32_t *out_n);

ds_result_t ds_rfcs_decode_announced_fact_body(
    const ds_rfcs_announced_slot_t *slots, uint32_t n_slots,
    const uint8_t *body, size_t body_len,
    ds_slot_value_t *values, uint32_t values_cap,
    char *scratch, size_t scratch_cap, uint32_t *out_n)
{
    if ((!slots && n_slots > 0) || !values || !out_n)
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_decode_announced_fact_body: NULL arg");
    return decode_body(announced_body_slot, slots, n_slots, body, body_len,
                       values, values_cap, scratch, scratch_cap, NULL, NULL,
                       NULL, out_n);
}

ds_result_t ds_rfcs_decode_announced_fact_body_handles(
    const ds_rfcs_announced_slot_t *slots, uint32_t n_slots,
    const uint8_t *body, size_t body_len,
    ds_slot_value_t *values, uint64_t *handles, uint32_t values_cap,
    char *scratch, size_t scratch_cap, uint32_t *out_n)
{
    if ((!slots && n_slots > 0) || !values || !handles || !out_n)
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_decode_announced_fact_body_handles: NULL arg");
    return decode_body(announced_body_slot, slots, n_slots, body, body_len,
                       values, values_cap, scratch, scratch_cap, NULL, NULL,
                       handles, out_n);
}

ds_result_t ds_rfcs_decode_fact_body_resolving(const ds_schema_t *schema,
                                               const uint8_t *body,
                                               size_t body_len,
                                               ds_slot_value_t *values,
                                               uint32_t values_cap,
                                               char *scratch, size_t scratch_cap,
                                               ds_rfcs_handle_fn resolve,
                                               void *resolve_user,
                                               uint32_t *out_n)
{
    if (!schema || !values || !out_n)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_decode_fact_body: NULL arg");

    uint32_t n = 0;
    ds_result_t r = ds_schema_get_slot_count(schema, &n);
    if (r.status != DS_OK)
        return r;
    return decode_body(schema_body_slot, schema, n, body, body_len, values,
                       values_cap, scratch, scratch_cap, resolve, resolve_user,
                       NULL, out_n);
}

/* A fact-ref slot's handle goes to `resolve`, which turns it into the fact it
   names, to `handles`, which keeps it as recorded, or to both. With neither, a
   schema with a fact-ref slot is refused. */
static ds_result_t decode_body(body_slot_fn slot_at, const void *src,
                               uint32_t n,
                               const uint8_t *body, size_t body_len,
                               ds_slot_value_t *values, uint32_t values_cap,
                               char *scratch, size_t scratch_cap,
                               ds_rfcs_handle_fn resolve, void *resolve_user,
                               uint64_t *handles, uint32_t *out_n)
{
    ds_result_t r = RFCS_OK;
    if (values_cap < n)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_decode_fact_body: values array too small");

    /* The seed gives every slot its type's zero, because the read loop dispatches
       on that kind; `state` remembers which slots are nullable and which fields
       arrived. */
    enum { NB_NULLABLE = 1, NB_SEEN = 2 };
    uint8_t  state_stack[64];
    uint8_t *state = state_stack;
    if (n > sizeof(state_stack)) {
        state = DS_MALLOC(n);
        if (!state)
            return RFCS_ERR(DS_ERR_OOM, "ds_rfcs_decode_fact_body: OOM");
    }
    if (n)
        memset(state, 0, n);

    /* Seed every slot with its proto3 default for the schema-declared type. */
    static const char empty[] = "";
    for (uint32_t i = 0; i < n; i++) {
        ds_slot_type_t type;
        bool nullable = false;
        r = slot_at(src, i, &type, &nullable);
        if (r.status != DS_OK)
            goto done;
        if (nullable)
            state[i] |= NB_NULLABLE;
        memset(&values[i], 0, sizeof(values[i]));
        if (handles)
            handles[i] = 0;
        switch (type) {
        case DS_SLOT_TYPE_INT:
        /* RDSC.5.5.8 — Int-represented; the wire value is the same varint. */
        case DS_SLOT_TYPE_TIME:
        case DS_SLOT_TYPE_DATE:
        case DS_SLOT_TYPE_DURATION:
            values[i].kind = DS_SLOT_INT;
            break;
        case DS_SLOT_TYPE_FLOAT:
            values[i].kind = DS_SLOT_FLOAT;
            break;
        case DS_SLOT_TYPE_BOOL:
            values[i].kind = DS_SLOT_BOOL;
            break;
        case DS_SLOT_TYPE_STRING:
            values[i].kind = DS_SLOT_STRING;
            values[i].v.s = empty;
            break;
        case DS_SLOT_TYPE_BYTES:
            values[i].kind = DS_SLOT_BYTES;
            values[i].v.bytes.data = (const uint8_t *)empty;
            values[i].v.bytes.len = 0;
            break;
        case DS_SLOT_TYPE_JSON:
            /* "No tree yet", which a non-nullable slot may not keep. */
            values[i].kind = DS_SLOT_JSON;
            values[i].v.json = NULL;
            break;
        case DS_SLOT_TYPE_SCHEMA:
            /* "No target", which a non-nullable slot may not keep. */
            if (resolve == NULL && handles == NULL) {
                r = RFCS_ERR(DS_ERR_INVAL,
                             "ds_rfcs_decode_fact_body: a fact-ref slot's handle "
                             "names a fact only within its stream (RFCS.4); "
                             "decode it with ds_rfcs_decode_fact_body_resolving");
                goto done;
            }
            values[i].kind  = DS_SLOT_FACT_REF;
            values[i].v.ref = NULL;
            break;
        default:
            r = RFCS_ERR(DS_ERR_INVAL,
                         "ds_rfcs_decode_fact_body: unknown slot type");
            goto done;
        }
    }

    size_t pos = 0;
    size_t scratch_used = 0;
    while (pos < body_len) {
        uint64_t tag;
        if (!read_varint(body, body_len, &pos, &tag)) {
            r = RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fact_body: bad field tag");
            goto fail;
        }
        uint32_t field = (uint32_t)(tag >> 3);
        uint32_t wire = (uint32_t)(tag & 7u);
        uint32_t idx = (field >= 1) ? field - 1 : 0xFFFFFFFFu;
        if (idx < n)
            state[idx] |= NB_SEEN;

        if (wire == 0) { /* varint: Int / Bool */
            uint64_t v;
            if (!read_varint(body, body_len, &pos, &v)) {
                r = RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fact_body: truncated varint");
                goto fail;
            }
            if (idx < n) {
                if (values[idx].kind == DS_SLOT_BOOL)
                    values[idx].v.b = (v != 0);
                else if (values[idx].kind == DS_SLOT_INT)
                    values[idx].v.i = (int64_t)v;
                else if (values[idx].kind == DS_SLOT_FACT_REF) {
                    ds_fact_t *target = NULL;
                    if (v == 0) {
                        r = RFCS_ERR(DS_ERR_PARSE,
                                     "ds_rfcs_decode_fact_body: a fact-ref "
                                     "handle of 0 names no record (RFCS.6.3)");
                        goto fail;
                    }
                    if (resolve) {
                        r = resolve(resolve_user, v, &target);
                        if (r.status != DS_OK)
                            goto fail;
                    }
                    values[idx].v.ref = target;
                    if (handles)
                        handles[idx] = v;
                }
            }
        } else if (wire == 1) { /* fixed64: Float */
            if (pos + 8 > body_len) {
                r = RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fact_body: truncated fixed64");
                goto fail;
            }
            uint64_t bits = 0;
            for (int k = 0; k < 8; k++)
                bits |= (uint64_t)body[pos + k] << (8 * k);
            pos += 8;
            if (idx < n && values[idx].kind == DS_SLOT_FLOAT)
                memcpy(&values[idx].v.f, &bits, sizeof(double));
        } else if (wire == 2) { /* len-delimited: String / Bytes / Json */
            uint64_t len;
            if (!read_varint(body, body_len, &pos, &len)) {
                r = RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fact_body: truncated length");
                goto fail;
            }
            /* Not `pos + len > body_len`: a length near 2^64 wraps the sum. */
            if (len > body_len - pos) {
                r = RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fact_body: truncated len-delim body");
                goto fail;
            }
            const uint8_t *data = body + pos;
            pos += len;
            if (idx < n) {
                if (values[idx].kind == DS_SLOT_STRING) {
                    /* A loop, not memchr: the microcontroller rows link libds
                       closed-world, and memchr is not on their allow lists
                       (runtime/docker/mcu_allow/). */
                    bool has_nul = false;
                    for (uint64_t k = 0; k < len; k++)
                        if (data[k] == 0) { has_nul = true; break; }
                    if (has_nul) {
                        r = RFCS_ERR(DS_ERR_PARSE,
                                     "ds_rfcs_decode_fact_body: a String slot "
                                     "holds U+0000 (LSTR.1.5)");
                        goto fail;
                    }
                    /* [LSTR.8.5] does not reach a recorded stream. */
                    if (!ds_utf8_well_formed((const char *)data, (size_t)len)) {
                        r = RFCS_ERR(DS_ERR_PARSE,
                                     "ds_rfcs_decode_fact_body: a String slot "
                                     "is not well-formed UTF-8");
                        goto fail;
                    }
                    if (scratch_used + len + 1 > scratch_cap) {
                        r = RFCS_ERR(DS_ERR_INVAL,
                                     "ds_rfcs_decode_fact_body: scratch buffer too small");
                        goto fail;
                    }
                    memcpy(scratch + scratch_used, data, len);
                    scratch[scratch_used + len] = '\0';
                    values[idx].v.s = scratch + scratch_used;
                    scratch_used += len + 1;
                } else if (values[idx].kind == DS_SLOT_BYTES) {
                    values[idx].v.bytes.data = data;
                    values[idx].v.bytes.len = (size_t)len;
                } else if (values[idx].kind == DS_SLOT_JSON) {
                    /* An owned tree the caller frees. Tree limits apply
                       ([LGRA.5.8.6]); the text limit does not, since a value
                       within them can serialize longer (internal/json.h). */
                    if (!ds_utf8_well_formed((const char *)data, (size_t)len)) {
                        r = RFCS_ERR(DS_ERR_PARSE,
                                     "ds_rfcs_decode_fact_body: a Json slot's "
                                     "text is not well-formed UTF-8");
                        goto fail;
                    }
                    ds_json_t *tree = NULL;
                    ds_result_t jr = ds_json_parse_limited((const char *)data,
                                                           (size_t)len, &tree,
                                                           NULL, false);
                    if (jr.status != DS_OK) { r = jr; goto fail; }
                    if (values[idx].v.json != NULL) /* repeated field: last wins */
                        ds_json_free(values[idx].v.json);
                    values[idx].v.json = tree;
                }
            }
        } else {
            r = RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fact_body: unsupported wire type");
            goto fail;
        }
    }

    /* [RFCS.6.3]: an absent nullable field is `null`. An absent non-nullable
       fact-ref field names nothing, and a Json slot left with no tree has no
       zero: both are malformed. A Json document `null` at its root is `null`
       ([LNUL.3.4]). After the read, so a repeated field's last value is the one
       judged. */
    for (uint32_t i = 0; i < n; i++) {
        ds_json_kind_t root;
        if ((state[i] & NB_NULLABLE) && !(state[i] & NB_SEEN)) {
            memset(&values[i], 0, sizeof(values[i]));
            values[i].kind = DS_SLOT_NULL;
        } else if (values[i].kind == DS_SLOT_JSON && values[i].v.json != NULL
                   && ds_json_get_kind(values[i].v.json, &root).status == DS_OK
                   && root == DS_JSON_NULL) {
            if (!(state[i] & NB_NULLABLE)) {
                r = RFCS_ERR(DS_ERR_PARSE,
                             "ds_rfcs_decode_fact_body: a non-nullable Json slot's "
                             "document is null at its root (RFCS.6.3)");
                goto fail;
            }
            ds_json_free(values[i].v.json);
            memset(&values[i], 0, sizeof(values[i]));
            values[i].kind = DS_SLOT_NULL;
        } else if (values[i].kind == DS_SLOT_FACT_REF && !(state[i] & NB_SEEN)) {
            r = RFCS_ERR(DS_ERR_PARSE,
                         "ds_rfcs_decode_fact_body: a non-nullable fact-ref "
                         "slot's handle is absent (RFCS.6.3)");
            goto fail;
        } else if (values[i].kind == DS_SLOT_JSON && values[i].v.json == NULL) {
            r = RFCS_ERR(DS_ERR_PARSE,
                         "ds_rfcs_decode_fact_body: a non-nullable Json slot's "
                         "field is absent (RFCS.6.3)");
            goto fail;
        }
    }

    *out_n = n;
    r = RFCS_OK;
    goto done;

fail:
    free_owned_json(values, n);
done:
    if (state != state_stack)
        DS_FREE(state);
    return r;
}

/* ---- fact atoms FactAssert / FactRetract ---- */

/* [LFST.5.6]. NULL and "" hash alike, as [NLFC.1.2] makes them the same id. */
void ds_rfcs_gen_event_id(const char *run_id, const char *tier_id,
                          uint64_t seq, char out[DS_RFCS_EVENT_ID_LEN])
{
    static const char PREFIX[] = "ds.rfcs.event_id.v1\x1f";  /* namespace + separator */
    static const uint8_t SEP = 0x1f;
    if (!run_id)  run_id  = "";
    if (!tier_id) tier_id = "";

    uint8_t seqb[8];
    for (int i = 0; i < 8; i++)
        seqb[i] = (uint8_t)(seq >> (56 - 8 * i));   /* big-endian */

    ds_sha256_ctx_t ctx;
    ds_sha256_init(&ctx);
    ds_sha256_update(&ctx, (const uint8_t *)PREFIX, sizeof(PREFIX) - 1);
    ds_sha256_update(&ctx, (const uint8_t *)run_id, strlen(run_id));
    ds_sha256_update(&ctx, &SEP, 1);
    ds_sha256_update(&ctx, (const uint8_t *)tier_id, strlen(tier_id));
    ds_sha256_update(&ctx, &SEP, 1);
    ds_sha256_update(&ctx, seqb, 8);
    uint8_t h[DS_SHA256_DIGEST_LEN];
    ds_sha256_final(&ctx, h);

    /* First 16 bytes -> UUID; RFC 9562 version 8 (custom) + RFC 4122 variant. */
    h[6] = (uint8_t)((h[6] & 0x0F) | 0x80);
    h[8] = (uint8_t)((h[8] & 0x3F) | 0x80);
    static const char hex[] = "0123456789abcdef";
    char *p = out;
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) *p++ = '-';
        *p++ = hex[h[i] >> 4];
        *p++ = hex[h[i] & 0x0F];
    }
    *p = '\0';
}

ds_result_t ds_rfcs_encode_fcem(uint64_t fact_id, const char *schema_name,
                                const uint8_t *fact_body, size_t fact_body_len,
                                uint64_t ttl_ns,
                                uint64_t clock_ns, uint64_t seq,
                                const char *event_id,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_fcem: NULL out_len");

    Ds__V1__FactAssert msg = DS__V1__FACT_ASSERT__INIT;
    msg.fact_id = fact_id;
    msg.schema_name = (char *)(schema_name ? schema_name : "");
    if (fact_body && fact_body_len) {
        msg.fact.len = fact_body_len;
        msg.fact.data = (uint8_t *)fact_body;
    }
    msg.ttl_ns = (int64_t)ttl_ns;
    msg.clock_ns = clock_ns;
    msg.seq = seq;
    msg.event_id = (char *)(event_id ? event_id : "");

    size_t body = ds__v1__fact_assert__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_FACT_ASSERT, body, out, out_cap, out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__fact_assert__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_femt(uint64_t fact_id, const char *schema_name,
                                const uint8_t *fact_body, size_t fact_body_len,
                                uint64_t ttl_ns,
                                const char *rule_name,
                                uint64_t clock_ns, uint64_t seq,
                                const char *event_id,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_femt: NULL out_len");
    /* [RFCS.6a]: an unattributed FactEmit is malformed. */
    if (rule_name == NULL || rule_name[0] == '\0')
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_encode_femt: rule_name must not be empty");

    Ds__V1__FactEmit msg = DS__V1__FACT_EMIT__INIT;
    msg.fact_id = fact_id;
    msg.schema_name = (char *)(schema_name ? schema_name : "");
    if (fact_body && fact_body_len) {
        msg.fact.len = fact_body_len;
        msg.fact.data = (uint8_t *)fact_body;
    }
    msg.ttl_ns = (int64_t)ttl_ns;
    msg.rule_name = (char *)rule_name;
    msg.clock_ns = clock_ns;
    msg.seq = seq;
    msg.event_id = (char *)(event_id ? event_id : "");

    size_t body = ds__v1__fact_emit__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_FACT_EMIT, body, out, out_cap, out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__fact_emit__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_fpub(const char *schema_name, const char *rule_name,
                                uint64_t clock_ns, uint64_t seq,
                                int64_t timetag,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_fpub: NULL out_len");
    /* fact_publish.proto: "the publishing rule; never \"\" on this atom". A
       `publish` runs only in a firing, so there is always a rule to name. */
    if (rule_name == NULL || rule_name[0] == '\0')
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_encode_fpub: rule_name must not be empty");

    Ds__V1__FactPublish msg = DS__V1__FACT_PUBLISH__INIT;
    msg.schema_name = (char *)(schema_name ? schema_name : "");
    msg.rule_name   = (char *)rule_name;
    msg.clock_ns    = clock_ns;
    msg.seq         = seq;
    msg.timetag     = (uint64_t)timetag;

    size_t body = ds__v1__fact_publish__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_FACT_PUBLISH, body, out, out_cap,
                               out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__fact_publish__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_fcrt(uint64_t fact_id, uint64_t seq,
                                uint64_t clock_ns,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_fcrt: NULL out_len");

    Ds__V1__FactRetract msg = DS__V1__FACT_RETRACT__INIT;
    msg.fact_id  = fact_id;
    msg.seq      = seq;
    msg.clock_ns = clock_ns;

    size_t body = ds__v1__fact_retract__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_FACT_RETRACT, body, out, out_cap, out_len, &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__fact_retract__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_schema_def(const char *schema_name,
                                      uint8_t *out, size_t out_cap,
                                      size_t *out_len)
{
    if (!schema_name || !schema_name[0] || !out_len)
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_encode_schema_def: NULL or empty arg");

    /* The fields rfcs_announce_schemas writes for a schema with no compiler
       text, so a hand-built announcement is a recorder's byte for byte. */
    Ds__V1__SchemaDef msg = DS__V1__SCHEMA_DEF__INIT;
    msg.schema_name = (char *)schema_name;
    msg.compression = DS__V1__COMPRESSION__COMPRESSION_NONE;

    size_t body = ds__v1__schema_def__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_SCHEMA_DEF, body, out, out_cap, out_len,
                               &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__schema_def__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_encode_fwth(uint64_t fact_id, uint32_t cause,
                                uint64_t clock_ns, uint64_t seq,
                                uint8_t *out, size_t out_cap, size_t *out_len)
{
    if (!out_len)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_encode_fwth: NULL out_len");
    if (cause == DS_FWTH_CAUSE_UNSPECIFIED)
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_encode_fwth: cause is UNSPECIFIED — set it at "
                        "the originating retract site ([RFCS.7a])");

    Ds__V1__FactWithdraw msg = DS__V1__FACT_WITHDRAW__INIT;
    msg.fact_id  = fact_id;
    msg.cause    = (Ds__V1__FactWithdraw__Cause)cause;
    msg.clock_ns = clock_ns;
    msg.seq      = seq;

    size_t body = ds__v1__fact_withdraw__get_packed_size(&msg);
    size_t body_off = 0;
    ds_result_t r = frame_into(DS_ATOM_FACT_WITHDRAW, body, out, out_cap, out_len,
                               &body_off);
    if (r.status != DS_OK)
        return r;
    ds__v1__fact_withdraw__pack(&msg, out + body_off);
    return RFCS_OK;
}

ds_result_t ds_rfcs_decode_fwth(const uint8_t *body, size_t body_len,
                                ds_rfcs_fwth_t *out)
{
    if (!body || !out)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_decode_fwth: NULL arg");
    Ds__V1__FactWithdraw *m =
        ds__v1__fact_withdraw__unpack(&ds_pb_allocator, body_len, body);
    if (m == NULL)
        return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fwth: bad FactWithdraw body");
    out->fact_id  = m->fact_id;
    /* [RFCS.7a.2]: the number, whether the enum holds it or not. */
    out->cause    = (uint32_t)m->cause;
    out->clock_ns = m->clock_ns;
    out->seq      = m->seq;
    ds__v1__fact_withdraw__free_unpacked(m, &ds_pb_allocator);
    return RFCS_OK;
}

/* Hand-parse the FactAssert proto3 body (any field order) so the inner fact body
   can be returned as a view into `body` rather than an alloc-then-free. */
ds_result_t ds_rfcs_decode_fcem(const uint8_t *body, size_t body_len,
                                ds_rfcs_fcem_t *out)
{
    if (!out)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_decode_fcem: NULL out");
    memset(out, 0, sizeof(*out));
    out->schema_name = (ds_rfcs_str_t){ "", 0 };
    out->event_id    = (ds_rfcs_str_t){ "", 0 };

    size_t pos = 0;
    while (pos < body_len) {
        uint64_t tag;
        if (!read_varint(body, body_len, &pos, &tag))
            return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcem: bad tag");
        uint32_t field = (uint32_t)(tag >> 3);
        uint32_t wire = (uint32_t)(tag & 7u);

        if (wire == 0) {
            uint64_t v;
            if (!read_varint(body, body_len, &pos, &v))
                return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcem: truncated varint");
            switch (field) {
            case 1: out->fact_id = v; break;
            case 4: out->ttl_ns  = v; break;
            case 6: out->clock_ns = v; break;
            case 7: out->seq = v; break;
            default: break;
            }
        } else if (wire == 2) {
            uint64_t len;
            if (!read_varint(body, body_len, &pos, &len))
                return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcem: truncated length");
            if (len > body_len - pos)      /* not the sum, which wraps */
                return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcem: truncated body");
            const uint8_t *data = body + pos;
            pos += len;
            const ds_rfcs_str_t s = { len ? (const char *)data : "",
                                      (size_t)len };
            if (field == 2) { /* schema_name */
                out->schema_name = s;
            } else if (field == 3) { /* fact body — view into `body` */
                out->fact = data;
                out->fact_len = (size_t)len;
            } else if (field == 8) { /* event_id — cross-tier correlation UUID */
                out->event_id = s;
            }
        } else if (wire == 1) {
            if (pos + 8 > body_len)
                return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcem: truncated fixed64");
            pos += 8; /* FactAssert has no fixed64 fields; skip defensively */
        } else {
            return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcem: unsupported wire type");
        }
    }
    return RFCS_OK;
}

/* A FactEmit envelope, into the struct FactAssert decodes into: `rule_name`
   does not change the fact. Over the generated unpacker, so a field the two
   messages stop sharing fails to compile. */
ds_result_t ds_rfcs_decode_femt(const uint8_t *body, size_t body_len,
                                ds_rfcs_fcem_t *out)
{
    if (!out)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_decode_femt: NULL out");
    memset(out, 0, sizeof(*out));

    Ds__V1__FactEmit *msg =
        ds__v1__fact_emit__unpack(&ds_pb_allocator, body_len, body);
    if (!msg)
        return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_femt: bad FactEmit body");

    out->fact_id  = msg->fact_id;
    out->ttl_ns   = (uint64_t)msg->ttl_ns;
    out->clock_ns = msg->clock_ns;
    out->seq      = msg->seq;
    out->schema_name = body_str(body, body_len, 2);
    out->event_id    = body_str(body, body_len, 8);
    /* A view into `body`: protobuf-c's copy is about to be freed. */
    if (msg->fact.len) {
        size_t pos = 0;
        while (pos < body_len) {
            uint64_t tag;
            if (!read_varint(body, body_len, &pos, &tag)) break;
            uint32_t field = (uint32_t)(tag >> 3);
            uint32_t wire  = (uint32_t)(tag & 7u);
            if (wire == 2) {
                uint64_t len;
                if (!read_varint(body, body_len, &pos, &len)) break;
                if (len > body_len - pos) break;   /* not the sum */
                if (field == 3) {           /* fact */
                    out->fact     = body + pos;
                    out->fact_len = (size_t)len;
                    break;
                }
                pos += len;
            } else if (wire == 0) {
                uint64_t v;
                if (!read_varint(body, body_len, &pos, &v)) break;
            } else {
                break;                       /* not a wire type this message uses */
            }
        }
    }
    ds__v1__fact_emit__free_unpacked(msg, &ds_pb_allocator);
    return RFCS_OK;
}

ds_result_t ds_rfcs_decode_fcrt(const uint8_t *body, size_t body_len,
                                ds_rfcs_fcrt_t *out)
{
    if (!out)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_decode_fcrt: NULL out");
    memset(out, 0, sizeof *out);

    size_t pos = 0;
    while (pos < body_len) {
        uint64_t tag;
        if (!read_varint(body, body_len, &pos, &tag))
            return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcrt: bad tag");
        uint32_t field = (uint32_t)(tag >> 3);
        uint32_t wire = (uint32_t)(tag & 7u);
        if (wire == 0) {
            uint64_t v;
            if (!read_varint(body, body_len, &pos, &v))
                return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcrt: truncated varint");
            if (field == 1)
                out->fact_id = v;
            else if (field == 2)
                out->seq = v;
            else if (field == 3)
                out->clock_ns = v;
        } else if (wire == 2) {
            uint64_t len;
            if (!read_varint(body, body_len, &pos, &len))
                return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcrt: truncated length");
            if (len > body_len - pos)      /* not the sum, which wraps */
                return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcrt: truncated body");
            pos += len;
        } else if (wire == 1) {
            if (pos + 8 > body_len)
                return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcrt: truncated fixed64");
            pos += 8;
        } else {
            return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_decode_fcrt: unsupported wire type");
        }
    }
    return RFCS_OK;
}

/* ---- recorder ---- */

static ds_result_t rfcs_hold_append(rfcs_delivery_t *dl, const uint8_t *p,
                                    size_t n)
{
    if (dl->held_len + n > dl->held_cap) {
        size_t ncap = dl->held_cap ? dl->held_cap : 256u;
        while (ncap < dl->held_len + n) ncap *= 2u;
        uint8_t *nb = DS_REALLOC(dl->held, ncap);
        if (nb == NULL)
            return RFCS_ERR(DS_ERR_OOM,
                            "recorder: an atom held for an ExternalAssert delivery");
        dl->held = nb;
        dl->held_cap = ncap;
    }
    memcpy(dl->held + dl->held_len, p, n);
    dl->held_len += n;
    return RFCS_OK;
}

static ds_result_t rec_sink(ds_rfcs_recorder_t *rec, size_t n)
{
    /* RFCS.24.1: inside a delivery the atom waits for its ExternalAssert. */
    if (rec->hold != NULL)
        return rfcs_hold_append((rfcs_delivery_t *)rec->hold, rec->buf, n);
    return rec->sink(rec->buf, n, rec->sink_user);
}

/* The recorder's reads, to the end of ds_rfcs_recorder_on_event, take the
   `_unchecked` accessors ([NCBK.2.9]): a record is written while its event is
   delivered, inside the window the handle guard leaves open.

   Whether a fact holds a non-null fact reference, which a fact body cannot
   carry (RFCS.24.1). */
static bool fact_holds_ref(const ds_fact_t *fact)
{
    uint32_t n = 0;
    if (ds_fact_get_slot_count_unchecked(fact, &n).status != DS_OK) return false;
    for (uint32_t i = 0; i < n; i++) {
        const char      *name = NULL;
        ds_slot_value_t  v;
        if (ds_fact_get_slot_unchecked(fact, i, &name, &v).status != DS_OK)
            continue;
        if (v.kind == DS_SLOT_FACT_REF && v.v.ref != NULL) return true;
    }
    return false;
}

/* The window, not the deadline; 0 when the fact has none. */
static uint64_t fact_ttl_window(const ds_fact_t *fact)
{
    uint64_t deadline = 0, asserted = 0;
    ds_fact_get_ttl_deadline_ns_unchecked(fact, &deadline);
    if (!deadline) return 0;
    ds_fact_get_asserted_ns_unchecked(fact, &asserted);
    return deadline > asserted ? deadline - asserted : 0;
}

static ds_result_t rfcs_write_prelude(ds_engine_t *engine,
                                      ds_rfcs_recorder_t *rec, bool seeds);

/* A failure is this event's return value, and recording continues, so a lost
   event shows as a `seq` gap ([RFCS.21.1], [NCBK.1.5]) and not as a tail that
   ends early. `rec->last` keeps the first failure. */
ds_result_t ds_rfcs_recorder_on_event(ds_engine_t *engine,
                                      const ds_stream_ev_t *ev,
                                      ds_rfcs_recorder_t *rec)
{
    if (!rec || !ev)
        return RFCS_OK;

    /* [RFCS.5.1]: the first event is the first point the schema set is final
       ([NFCT.1.1]). Not retried on failure, which could write half a prelude
       twice. */
    if (rec->prelude_pending && engine != NULL) {
        rec->prelude_pending = false;
        /* [RFCS.26.1]: with the host's cache seeds, which the first event ends
           ([NLFC.9.2]). */
        ds_result_t pr = rfcs_write_prelude(engine, rec, true);
        if (pr.status != DS_OK) {
            if (rec->last.status == DS_OK)
                rec->last = pr;
            return pr;
        }
    }

    size_t n = 0;
    ds_result_t r = RFCS_OK;

    /* RFCS.24.1: an open delivery's atoms are held until its ExternalAssert is
       written (rfcs_delivery_close), by the first recorder to see it. */
    rfcs_delivery_t *dl = engine ? (rfcs_delivery_t *)engine->rfcs_delivery
                                 : NULL;
    if (dl != NULL) {
        if (dl->rec == NULL) dl->rec = rec;
        if (dl->rec == rec) rec->hold = dl;
    }

    switch (ev->kind) {
    case DS_EV_FACT_ASSERT: {
        const ds_fact_t *fact = ev->p.fact_assert.fact;
        /* A rule-emitted fact gets a FactEmit from the ACTION_EMIT that
           follows ([RFCS.6a]). A host reassert equal to one
           has no FactEmit to follow it, so it is recorded here ([RFCS.6.7]). */
        if (fact != NULL && fact->rule_emitted
                && !(engine != NULL && engine->wm.assert_from_host))
            break;
        uint64_t fid = 0;
        ds_fact_get_id_unchecked(fact, &fid);

        /* RFCS.24.3: a delivery's fact is listed in its ExternalAssert and gets
           no atom of its own. The first gives the seq and clock; the last, the
           received fact, the TTL window. */
        if (rec->hold != NULL) {
            if (!dl->started) {
                dl->started  = true;
                dl->seq      = ev->seq;
                dl->clock_ns = ev->clock_ns;
            }
            if (dl->n_ids == dl->cap_ids) {
                size_t ncap = dl->cap_ids ? dl->cap_ids * 2u : 8u;
                uint64_t *ni = DS_REALLOC(dl->ids, ncap * sizeof(*ni));
                if (ni == NULL) {
                    r = RFCS_ERR(DS_ERR_OOM, "recorder: an ExternalAssert's fact_ids");
                    break;
                }
                dl->ids = ni;
                dl->cap_ids = ncap;
            }
            dl->ids[dl->n_ids++] = fid;
            dl->ttl_ns = fact_ttl_window(fact);
            break;
        }

        /* RFCS.24.1: a direct host assert of a fact holding a reference is one
           ExternalAssert, with each referenced live fact inlined. */
        if (fact != NULL && fact_holds_ref(fact)) {
            uint8_t *fe = NULL;
            size_t   fe_len = 0;
            r = ds_fact_external_pack(fact, &fe, &fe_len);
            if (r.status != DS_OK)
                break;
            r = encode_fcxt(fe, fe_len, &fid, 1u, fact_ttl_window(fact),
                            ev->clock_ns, ev->seq,
                            rec->buf, rec->buf_cap, &n);
            DS_FREE(fe);
            if (r.status == DS_OK)
                r = rec_sink(rec, n);
            break;
        }
        const ds_schema_t *sc = NULL;
        ds_fact_get_schema_unchecked(fact, &sc);
        const char *name = "";
        ds_schema_get_name_unchecked(sc, &name);

        rec_body_t body;
        r = rec_body_encode(fact, &body);
        if (r.status != DS_OK)
            break;
        /* The internal fill: inside the stream callback
           ds_engine_get_session_header answers DS_ERR_STATE ([RARC.13.16]). */
        ds_session_header_t hdr;
        char eid[DS_RFCS_EVENT_ID_LEN] = "";
        ds_engine_session_header_fill(engine, &hdr);
        ds_rfcs_gen_event_id(hdr.session_id, hdr.tier_id, ev->seq, eid);
        /* The window, which is what a replay hands to
           ds_engine_assert_with_ttl. */
        uint64_t deadline = 0, asserted = 0, ttl_ns = 0;
        ds_fact_get_ttl_deadline_ns_unchecked(fact, &deadline);
        if (deadline) {
            ds_fact_get_asserted_ns_unchecked(fact, &asserted);
            ttl_ns = deadline > asserted ? deadline - asserted : 0;
        }
        r = ds_rfcs_encode_fcem(fid, name, body.data, body.len, ttl_ns,
                                ev->clock_ns, ev->seq,
                                eid, rec->buf, rec->buf_cap, &n);
        rec_body_free(&body);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    }
    case DS_EV_FACT_RETRACT: {
        const ds_fact_t *fact = ev->p.fact_retract.fact;
        uint64_t fid = 0;
        ds_fact_get_id_unchecked(fact, &fid);
        /* [RFCS.7a]: FactRetract is a withdrawal the integrator asked for,
           FactWithdraw the engine taking a fact back. The test is who withdrew,
           not who asserted: wm.retract_cause is unset on the integrator's path. */
        const uint8_t cause = engine ? engine->wm.retract_cause
                                     : DS_FWTH_CAUSE_UNSPECIFIED;
        if (cause != DS_FWTH_CAUSE_UNSPECIFIED) {
            r = ds_rfcs_encode_fwth(fid, cause, ev->clock_ns, ev->seq,
                                    rec->buf, rec->buf_cap, &n);
        } else {
            r = ds_rfcs_encode_fcrt(fid, ev->seq, ev->clock_ns,
                                    rec->buf, rec->buf_cap, &n);
        }
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    }
    case DS_EV_TICK:
        r = ds_rfcs_encode_clka(ev->seq, (int64_t)ev->clock_ns,
                                ev->p.tick.wall_set, ev->p.tick.wall_ns,
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    case DS_EV_PUMP:
        r = ds_rfcs_encode_pump(ev->seq, (int64_t)ev->clock_ns,
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    case DS_EV_RULE_FIRE_BEGIN:
        r = ds_rfcs_encode_rfra(ev->seq, (int64_t)ev->clock_ns,
                                ev->p.rule_fire_begin.rule_name,
                                ev->p.rule_fire_begin.timetag, false,
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    case DS_EV_RULE_FIRE_END:
        r = ds_rfcs_encode_rfra(ev->seq, (int64_t)ev->clock_ns,
                                ev->p.rule_fire_end.rule_name,
                                ev->p.rule_fire_end.timetag, true,
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    case DS_EV_ACTION_PUBLISH: {
        /* [RFCS.27.1]: the schema, the rule, the timetag, the clock and the
           seq, and no value or handle. The fact is in no working memory
           ([LTIE.4.3]) and is a view for the callback only ([NCBK.2.5]); its
           FactExternal is in no atom ([RFCS.27.2]). */
        const ds_fact_t *fact = ev->p.action_publish.fact;
        if (fact == NULL)
            break;
        const char *rule = ds_engine_current_fire_rule(engine);
        if (rule == NULL || rule[0] == '\0') {
            r = RFCS_ERR(DS_ERR_INTERNAL,
                         "ACTION_PUBLISH outside a rule fire — no rule to attribute");
            break;
        }
        const ds_schema_t *sc = NULL;
        ds_fact_get_schema_unchecked(fact, &sc);
        const char *name = "";
        ds_schema_get_name_unchecked(sc, &name);
        r = ds_rfcs_encode_fpub(name, rule, ev->clock_ns, ev->seq,
                                ds_engine_current_fire_timetag(engine),
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    }
    case DS_EV_ACTION_EMIT: {
        /* [RFCS.6a]. The rule comes from the engine, which holds it for the
           firing. */
        const ds_fact_t *fact = ev->p.action_emit.fact;
        if (fact == NULL)
            break;
        const char *rule = ds_engine_current_fire_rule(engine);
        if (rule == NULL || rule[0] == '\0') {
            r = RFCS_ERR(DS_ERR_INTERNAL,
                         "ACTION_EMIT outside a rule fire — no rule to attribute");
            break;
        }

        uint64_t fid = 0;
        ds_fact_get_id_unchecked(fact, &fid);
        const ds_schema_t *sc = NULL;
        ds_fact_get_schema_unchecked(fact, &sc);
        const char *name = "";
        ds_schema_get_name_unchecked(sc, &name);

        rec_body_t body;
        r = rec_body_encode(fact, &body);
        if (r.status != DS_OK)
            break;
        /* [LDTL.4.1] computes a TTL override at firing time, so it is
           recoverable from nowhere else. */
        uint64_t deadline = 0, asserted = 0, ttl_ns = 0;
        ds_fact_get_ttl_deadline_ns_unchecked(fact, &deadline);
        if (deadline) {
            ds_fact_get_asserted_ns_unchecked(fact, &asserted);
            ttl_ns = deadline > asserted ? deadline - asserted : 0;
        }
        ds_session_header_t hdr;
        char eid[DS_RFCS_EVENT_ID_LEN] = "";
        ds_engine_session_header_fill(engine, &hdr);  /* internal: see FactAssert arm */
        ds_rfcs_gen_event_id(hdr.session_id, hdr.tier_id, ev->seq, eid);

        r = ds_rfcs_encode_femt(fid, name, body.data, body.len, ttl_ns, rule,
                                ev->clock_ns, ev->seq, eid,
                                rec->buf, rec->buf_cap, &n);
        rec_body_free(&body);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    }
    case DS_EV_ACTION_CALL:
        /* Being inside the recorder is the [RFCS.15.6] capability gate: a target
           that does not persist streams never installs this sink. */
        r = ds_rfcs_encode_call(ev->seq, (int64_t)ev->clock_ns,
                                ev->p.action_call.timetag,
                                ev->p.action_call.rule_name,
                                ev->p.action_call.service,
                                ev->p.action_call.correlation,
                                ev->p.action_call.args,
                                ev->p.action_call.arg_count,
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;

    case DS_EV_COMPUTATION_ERROR:
        r = ds_rfcs_encode_eerr(ev->seq, ev->clock_ns,
                                (uint32_t)ev->p.computation_error.kind,
                                ev->p.computation_error.rule_name,
                                ev->p.computation_error.timetag,
                                ev->p.computation_error.schema_name,
                                ev->p.computation_error.slot_name,
                                ev->p.computation_error.fact_id,
                                ev->p.computation_error.node_id,
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    case DS_EV_TYPE_ERROR:
        r = ds_rfcs_encode_type(ev->seq, ev->clock_ns,
                                ev->p.type_error.node_id,
                                ev->p.type_error.schema_name,
                                ev->p.type_error.slot_name,
                                ev->p.type_error.actual,
                                ev->p.type_error.rule_name,
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    case DS_EV_BOUNDS_ERROR:
        r = ds_rfcs_encode_bnds(ev->seq, ev->clock_ns,
                                (uint32_t)ev->p.bounds_error.cap,
                                ev->p.bounds_error.limit,
                                ev->p.bounds_error.observed,
                                ev->p.bounds_error.rule_name,
                                ev->p.bounds_error.timetag,
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    case DS_EV_ENGINE_ERROR:
        /* `recorder_emit_fault` sets the halt latch before dispatching, and this
           arm still runs on the pump that stops the tier. */
        r = ds_rfcs_encode_engf(ev->seq, ev->clock_ns,
                                (uint32_t)ev->p.engine_error.fault,
                                ev->p.engine_error.node_id,
                                ev->p.engine_error.rule_name,
                                rec->buf, rec->buf_cap, &n);
        if (r.status == DS_OK)
            r = rec_sink(rec, n);
        break;
    default:
        break; /* event kind not part of the RFCS atom set — skip */
    }
    rec->hold = NULL;
    if (r.status != DS_OK && rec->last.status == DS_OK)
        rec->last = r;
    return r;
}

static void rfcs_delivery_open(ds_engine_t *engine, rfcs_delivery_t *dl,
                               const uint8_t *fact, size_t fact_len)
{
    memset(dl, 0, sizeof(*dl));
    dl->fact     = fact;
    dl->fact_len = fact_len;
    dl->err      = RFCS_OK;
    engine->rfcs_delivery = dl;
}

/* The ExternalAssert, then every atom held behind it. A failure becomes the
   public call's status ([NCBK.1.5]) and the recorder's `last`. A delivery whose
   first assert never happened writes no ExternalAssert. */
static ds_result_t rfcs_delivery_close(ds_engine_t *engine, rfcs_delivery_t *dl)
{
    engine->rfcs_delivery = NULL;
    ds_result_t r = RFCS_OK;
    ds_rfcs_recorder_t *rec = dl->rec;
    if (rec != NULL) {
        if (dl->started) {
            size_t n = 0;
            r = encode_fcxt(dl->fact, dl->fact_len, dl->ids, dl->n_ids,
                            dl->ttl_ns, dl->clock_ns, dl->seq,
                            rec->buf, rec->buf_cap, &n);
            if (r.status == DS_OK)
                r = rec->sink(rec->buf, n, rec->sink_user);
        }
        /* One atom per sink call: verify mode's capture sink reads only the
           first atom of what it is handed. */
        size_t pos = 0;
        while (pos < dl->held_len) {
            ds_pbf_atom_t a;
            if (ds_pbf_next_atom(dl->held, dl->held_len, pos, &a) != DS_PBF_OK) {
                if (r.status == DS_OK)
                    r = RFCS_ERR(DS_ERR_INTERNAL,
                                 "recorder: a held atom does not frame");
                break;
            }
            ds_result_t hr = rec->sink(dl->held + pos, a.next - pos,
                                       rec->sink_user);
            if (r.status == DS_OK) r = hr;
            pos = a.next;
        }
        if (r.status != DS_OK && rec->last.status == DS_OK)
            rec->last = r;
        if (r.status != DS_OK && engine->stream_status.status == DS_OK)
            engine->stream_status = r;
    }
    DS_FREE(dl->ids);
    DS_FREE(dl->held);
    dl->ids  = NULL;
    dl->held = NULL;
    return r;
}

static ds_result_t rfcs_trampoline(ds_engine_t *engine,
                                   const ds_stream_ev_t *ev, void *user)
{
    return ds_rfcs_recorder_on_event(engine, ev, (ds_rfcs_recorder_t *)user);
}

/* The inverse of the map in dsc/loader.c. */
static Ds__V1__SlotKind rfcs_slot_kind(ds_slot_type_t t)
{
    switch (t) {
    case DS_SLOT_TYPE_STRING: return DS__V1__SLOT_KIND__SLOT_KIND_STRING;
    case DS_SLOT_TYPE_INT:    return DS__V1__SLOT_KIND__SLOT_KIND_INT;
    case DS_SLOT_TYPE_FLOAT:  return DS__V1__SLOT_KIND__SLOT_KIND_FLOAT;
    case DS_SLOT_TYPE_BOOL:   return DS__V1__SLOT_KIND__SLOT_KIND_BOOL;
    case DS_SLOT_TYPE_JSON:   return DS__V1__SLOT_KIND__SLOT_KIND_JSON;
    case DS_SLOT_TYPE_BYTES:  return DS__V1__SLOT_KIND__SLOT_KIND_BYTES;
    case DS_SLOT_TYPE_SCHEMA: return DS__V1__SLOT_KIND__SLOT_KIND_SCHEMA;
    case DS_SLOT_TYPE_TIME:     return DS__V1__SLOT_KIND__SLOT_KIND_TIME;
    case DS_SLOT_TYPE_DATE:     return DS__V1__SLOT_KIND__SLOT_KIND_DATE;
    case DS_SLOT_TYPE_DURATION: return DS__V1__SLOT_KIND__SLOT_KIND_DURATION;
    }
    /* Outside the switch, so the compiler warns of a slot type it lacks. */
    return DS__V1__SLOT_KIND__SLOT_KIND_UNSPECIFIED;
}

/* `SchemaDef` + one `Slot` per slot, for every registered schema. proto_source
   is NULL for a schema registered programmatically, whose SchemaDef has none. */
static ds_result_t rfcs_announce_schemas(ds_engine_t *engine,
                                         ds_rfcs_sink_fn sink, void *sink_user,
                                         uint8_t *buf, size_t buf_cap)
{
    /* The registry itself: inside the stream callback ds_engine_schema_count
       and _at refuse a re-entered call ([RARC.13.16]). */
    size_t n_schemas = 0;
    ds_result_t r = ds_schema_registry_count(&engine->schemas, &n_schemas);
    if (r.status != DS_OK) return r;

    for (size_t i = 0; i < n_schemas; i++) {
        const ds_schema_t *sc = NULL;
        r = ds_schema_registry_at(&engine->schemas, i, &sc);
        if (r.status != DS_OK) return r;
        if (sc == NULL || sc->type_name == NULL) continue;

        Ds__V1__SchemaDef sd = DS__V1__SCHEMA_DEF__INIT;
        sd.schema_name = (char *)sc->type_name;
        sd.compression = DS__V1__COMPRESSION__COMPRESSION_NONE;
        sd.proto_source.data = (uint8_t *)sc->proto_source;
        sd.proto_source.len  = sc->proto_source ? sc->proto_source_len : 0;

        size_t body = ds__v1__schema_def__get_packed_size(&sd);
        size_t n = 0, off = 0;
        r = frame_into(DS_ATOM_SCHEMA_DEF, body, buf, buf_cap, &n, &off);
        if (r.status != DS_OK)
            return RFCS_ERR(DS_ERR_OOM, "rfcs: SchemaDef exceeds record buffer");
        ds__v1__schema_def__pack(&sd, buf + off);
        r = sink(buf, n, sink_user);
        if (r.status != DS_OK) return r;

        /* `capacity` lives on the Rete schema: ds_slot_desc_t is public and
           carries none. */
        const ds_rete_schema_t *rs = engine->rete_engine
            ? ds_rete_schema_by_name(engine->rete_engine, sc->type_name)
            : NULL;

        for (uint32_t s = 0; s < sc->n_slots; s++) {
            const ds_slot_desc_t *sl = &sc->slots[s];
            Ds__V1__Slot sm = DS__V1__SLOT__INIT;
            sm.schema_name = (char *)sc->type_name;
            sm.slot_name   = (char *)(sl->name ? sl->name : "");
            sm.kind        = rfcs_slot_kind(sl->type);
            sm.schema_ref  = (char *)(
                (sl->type == DS_SLOT_TYPE_SCHEMA && sl->schema_ref
                 && sl->schema_ref->type_name)
                ? sl->schema_ref->type_name : "");
            sm.sampled     = sl->sampled;
            sm.retained    = sl->retained;
            /* ds_identity_role_t's values are the proto enum's ([RDSC.5.5.7]). */
            sm.tolerance     = sl->has_tolerance ? sl->tolerance : 0.0;
            sm.identity_role = (Ds__V1__IdentityRole) sl->identity_role;
            sm.capacity      = (rs != NULL && s < rs->slot_count)
                             ? rs->slots[s].capacity : 0;
            sm.nullable    = sl->nullable;

            size_t sbody = ds__v1__slot__get_packed_size(&sm);
            size_t sn = 0, soff = 0;
            r = frame_into(DS_ATOM_SLOT, sbody, buf, buf_cap, &sn, &soff);
            if (r.status != DS_OK)
                return RFCS_ERR(DS_ERR_OOM,
                                "rfcs: Slot exceeds record buffer");
            ds__v1__slot__pack(&sm, buf + soff);
            r = sink(buf, sn, sink_user);
            if (r.status != DS_OK) return r;
        }
    }
    return RFCS_OK;
}

/* By the key's UTF-8 bytes ([RFCS.26.1]): strcmp compares as unsigned char. */
static int seed_entry_cmp(const void *a, const void *b)
{
    const ds_cache_entry_t *ea = *(const ds_cache_entry_t *const *) a;
    const ds_cache_entry_t *eb = *(const ds_cache_entry_t *const *) b;
    return strcmp(ea->key, eb->key);
}

/* [RFCS.26.1]: one CacheSeed for each entry the cache holds as the header is
   written. Every entry is a host seed: the header waits for the first event,
   the first step's TICK, which comes before `initial:` is applied ([LGRA.24.3]),
   and a host seed is the only write before an event ([NLFC.9.1]). An entry past
   its deadline is still written: the replay sweeps it at the same pump. */
static ds_result_t rfcs_announce_seeds(ds_engine_t *engine,
                                       ds_rfcs_sink_fn sink, void *sink_user,
                                       uint8_t *buf, size_t buf_cap)
{
    uint32_t n = ds_cache_key_count(&engine->cache);
    if (n == 0)
        return RFCS_OK;
    const ds_cache_entry_t **ents = DS_MALLOC((size_t) n * sizeof(*ents));
    if (ents == NULL)
        return RFCS_ERR(DS_ERR_OOM, "rfcs: CacheSeed order");
    for (uint32_t i = 0; i < n; i++)
        ents[i] = ds_cache_entry_at(&engine->cache, i);
    qsort(ents, n, sizeof(*ents), seed_entry_cmp);

    ds_result_t r = RFCS_OK;
    for (uint32_t i = 0; i < n && r.status == DS_OK; i++) {
        Ds__V1__CacheSeed cs = DS__V1__CACHE_SEED__INIT;
        cs.key         = ents[i]->key;
        cs.value_json  = ents[i]->value_json;
        cs.deadline_ns = ents[i]->ttl_deadline_ns;
        size_t body = ds__v1__cache_seed__get_packed_size(&cs);
        size_t len = 0, off = 0;
        r = frame_into(DS_ATOM_CACHE_SEED, body, buf, buf_cap, &len, &off);
        if (r.status != DS_OK) {
            r = RFCS_ERR(DS_ERR_OOM, "rfcs: CacheSeed exceeds record buffer");
            break;
        }
        ds__v1__cache_seed__pack(&cs, buf + off);
        r = sink(buf, len, sink_user);
    }
    DS_FREE(ents);
    return r;
}

/* The StreamHeader, then every registered schema's announcement ([RFCS.5.1]),
   once, before any event atom. Straight to the sink, never held: the prelude
   precedes a delivery's ExternalAssert. The internal fill, as for a FactAssert's
   event_id. */
static ds_result_t rfcs_write_prelude(ds_engine_t *engine,
                                      ds_rfcs_recorder_t *rec, bool seeds)
{
    ds_session_header_t hdr;
    ds_engine_session_header_fill(engine, &hdr);
    size_t n = 0;
    ds_result_t r = ds_rfcs_encode_header(&hdr, rec->buf, rec->buf_cap, &n);
    if (r.status != DS_OK)
        return r;
    r = rec->sink(rec->buf, n, rec->sink_user);
    if (r.status != DS_OK)
        return r;
    r = rfcs_announce_schemas(engine, rec->sink, rec->sink_user,
                              rec->buf, rec->buf_cap);
    if (r.status != DS_OK || !seeds)
        return r;
    return rfcs_announce_seeds(engine, rec->sink, rec->sink_user,
                               rec->buf, rec->buf_cap);
}

ds_result_t ds_rfcs_record_begin(ds_engine_t *engine, ds_rfcs_recorder_t *rec,
                                 ds_rfcs_sink_fn sink, void *sink_user,
                                 uint8_t *buf, size_t buf_cap)
{
    if (!engine || !rec || !sink || !buf)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_record_begin: NULL arg");

    rec->sink = sink;
    rec->sink_user = sink_user;
    rec->buf = buf;
    rec->buf_cap = buf_cap;
    rec->last = RFCS_OK;
    rec->hold = NULL;

    /* [RFCS.5.1]: the prelude waits for the first event, when the schema set is
       final ([NFCT.1.1]). [RFCS.26.1]: a recorder attached after one writes no
       CacheSeed, since the cache holds what rules wrote. */
    if (engine->next_seq > 0) {
        rec->prelude_pending = false;
        return rfcs_write_prelude(engine, rec, false);
    }
    rec->prelude_pending = true;
    return RFCS_OK;
}

ds_result_t ds_rfcs_record_to(ds_engine_t *engine, ds_rfcs_recorder_t *rec,
                              ds_rfcs_sink_fn sink, void *sink_user,
                              uint8_t *buf, size_t buf_cap)
{
    if (!engine || !rec || !sink || !buf)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_record_to: NULL arg");
    ds_result_t r = ds_rfcs_record_begin(engine, rec, sink, sink_user,
                                         buf, buf_cap);
    if (r.status != DS_OK)
        return r;
    return ds_engine_set_stream_callback(engine, rfcs_trampoline, rec);
}

/* ---- replayer ---- */

/* A recorded fact_id to the fact the replay's assert made. */
typedef struct {
    uint64_t orig_id;
    /* Not a ds_fact_t *: a pump's TTL sweep frees facts. Rete ids are never
       reused, so ds_engine_fact_by_rete_id can answer "gone". */
    uint32_t rete_id;
    bool     live;   /* false once retracted */
} rfcs_idmap_ent;

typedef struct {
    rfcs_idmap_ent *ents;
    size_t          n;
    size_t          cap;
} rfcs_idmap;

/* At most one live entry per orig_id: with two, idmap_forget would leave
   idmap_get the older. A no-op reassertion records a FactAssert with the live
   fact's id ([RFCS.6.7]), so a put over a live id replaces it. */
static ds_result_t idmap_put(rfcs_idmap *m, uint64_t orig, uint32_t rete_id)
{
    for (size_t i = m->n; i-- > 0;)
        if (m->ents[i].orig_id == orig && m->ents[i].live) {
            m->ents[i].rete_id = rete_id;
            return RFCS_OK;
        }
    if (m->n == m->cap) {
        size_t ncap = m->cap ? m->cap * 2 : 16;
        rfcs_idmap_ent *ne = DS_REALLOC(m->ents, ncap * sizeof(*ne));
        if (!ne)
            return RFCS_ERR(DS_ERR_OOM, "ds_rfcs_replay: id map allocation failed");
        m->ents = ne;
        m->cap = ncap;
    }
    m->ents[m->n].orig_id = orig;
    m->ents[m->n].rete_id = rete_id;
    m->ents[m->n].live    = true;
    m->n++;
    return RFCS_OK;
}

/* False means the stream never gave that fact_id, or retracted it. It does not
   mean the fact is gone: a fact swept since still has a live entry, and only
   ds_engine_fact_by_rete_id can tell. */
static bool idmap_get(rfcs_idmap *m, uint64_t orig, uint32_t *out_rete_id)
{
    for (size_t i = m->n; i-- > 0;)
        if (m->ents[i].orig_id == orig && m->ents[i].live) {
            *out_rete_id = m->ents[i].rete_id;
            return true;
        }
    return false;
}

static void idmap_forget(rfcs_idmap *m, uint64_t orig)
{
    for (size_t i = m->n; i-- > 0;)
        if (m->ents[i].orig_id == orig && m->ents[i].live) {
            m->ents[i].live = false;
            return;
        }
}

/* RFCS.6.3: a handle the map never held is malformed input. One it holds may
   name a fact since gone, which is `*out` NULL. */
typedef struct {
    ds_engine_t *engine;
    rfcs_idmap  *map;
} replay_resolver_t;

static ds_result_t replay_resolve_handle(void *user, uint64_t handle,
                                         ds_fact_t **out)
{
    replay_resolver_t *rr = (replay_resolver_t *)user;
    uint32_t rid = 0;
    *out = NULL;
    if (!idmap_get(rr->map, handle, &rid))
        return RFCS_ERR(DS_ERR_PARSE,
                        "ds_rfcs_replay: a fact-ref handle names no earlier "
                        "record of the stream (RFCS.6.3)");
    return ds_engine_fact_by_rete_id(rr->engine, rid, out);
}

/* Verify a stream StreamHeader header against the engine's live session header.
   *ok is set true only when a positive dsc_hash match was made. */
static ds_result_t replay_verify_header(ds_engine_t *engine,
                                        const uint8_t *body, size_t blen,
                                        bool *ok)
{
    *ok = false;

    ds_rfcs_header_t shdr;
    ds_result_t r = ds_rfcs_decode_header(body, blen, &shdr);
    if (r.status != DS_OK)
        return r;

    ds_session_header_t ehdr;
    r = ds_engine_get_session_header(engine, &ehdr);
    if (r.status != DS_OK)
        return r;

    /* No identity is adopted from the trace: a replay given other ids than the
       header names diverges on event_id ([RFCS.4.3], [RFCS.4.4]). */

    /* [LDET.1.10]: refuses both directions across a minor bump ([RARC.4.1]). */
    if (!ds_version_series_match(shdr.ds_version, ehdr.ds_version))
        return RFCS_ERR(DS_ERR_FS_VERSION,
                        "ds_rfcs_replay: stream was written by a different DS "
                        "minor series than this runtime — replay it with the "
                        "release that recorded it ([LDET.1.10] / [RARC.4.2])");

    /* [RBND.2.1], [RBND.5.1]: one hash without the other is incomplete, whether
       or not this engine has a DSC. Neither replays without a binding check.
       With both and a DSC loaded, the whole tuple must equal the DSC's
       ([RBND.1.5]); an engine with no DSC has nothing to compare ([RBND.5.4]). */
    bool s_hash = shdr.dsc_hash_len == 32;
    bool s_def  = shdr.dialect_def_sha256_len == 32;
    if (s_hash && !s_def)
        return RFCS_ERR(DS_ERR_BND_INCOMPLETE,
                        "ds_rfcs_replay: the StreamHeader carries a dsc_hash "
                        "and no 32-byte dialect_def_sha256 (RBND.2.1)");
    if (s_def && !s_hash)
        return RFCS_ERR(DS_ERR_BND_INCOMPLETE,
                        "ds_rfcs_replay: the StreamHeader carries a "
                        "dialect_def_sha256 and no 32-byte dsc_hash (RBND.2.1)");
    if (s_hash && ehdr.dsc_hash_len == 32 && ehdr.dsc_hash != NULL) {
        ds_dialect_tuple_t rec = {
            shdr.dsc_hash, shdr.dsc_hash_len,
            shdr.capabilities, shdr.n_capabilities,
            shdr.dialect_def_sha256, shdr.dialect_def_sha256_len,
        };
        ds_dialect_tuple_t loaded = {
            ehdr.dsc_hash, ehdr.dsc_hash_len,
            ehdr.capabilities, ehdr.n_capabilities,
            ehdr.dialect_def_sha256, ehdr.dialect_def_sha256_len,
        };
        r = ds_binding_compare_dialect(engine, &rec, &loaded);
        if (r.status != DS_OK)
            return r;
        *ok = true;
    }
    return RFCS_OK;
}

/* ---- verify-mode compare capture [LFST.9.3.1] ---------------
 *
 * A verify replay installs a recorder, and this sink buffers the compare atoms
 * it re-derives. The walk pops each recorded atom's twin (FIFO) and byte-compares
 * it, its timetag by pairing (tt_pair). The queue drains per inject-cascade, so
 * peak occupancy is the in-flight window, not the whole stream. */
#define DS_RFCS_VERIFY_BUF_CAP (1u << 20)  /* recorder scratch: largest single atom */

typedef struct { uint32_t atom; uint8_t *body; size_t len; } cap_ent;
typedef struct {
    cap_ent    *ents;
    size_t      head, count, cap;
    ds_result_t err;              /* sticky allocation failure from the sink */
    oa_t        tt_fwd;           /* recorded timetag -> re-derived (tt_pair) */
    oa_t        tt_back;          /* re-derived timetag -> recorded */
} cap_q;

static ds_result_t cap_push(cap_q *q, uint32_t atom,
                            const uint8_t *body, size_t len)
{
    if (q->count == q->cap) {
        size_t   nc = q->cap ? q->cap * 2 : 16;
        cap_ent *nb = DS_MALLOC(nc * sizeof(*nb));
        if (!nb)
            return (q->err = RFCS_ERR(DS_ERR_OOM, "verify capture: OOM"));
        for (size_t i = 0; i < q->count; i++)
            nb[i] = q->ents[(q->head + i) % q->cap];
        DS_FREE(q->ents);
        q->ents = nb; q->cap = nc; q->head = 0;
    }
    uint8_t *copy = DS_MALLOC(len ? len : 1);
    if (!copy)
        return (q->err = RFCS_ERR(DS_ERR_OOM, "verify capture: OOM"));
    memcpy(copy, body, len);
    size_t tail = (q->head + q->count) % q->cap;
    q->ents[tail].atom = atom;
    q->ents[tail].body = copy;
    q->ents[tail].len  = len;
    q->count++;
    return RFCS_OK;
}

static void cap_free(cap_q *q)
{
    for (size_t i = 0; i < q->count; i++)
        DS_FREE(q->ents[(q->head + i) % q->cap].body);
    DS_FREE(q->ents);
    q->ents = NULL; q->head = q->count = q->cap = 0;
    ds_oa_free(&q->tt_fwd);
    ds_oa_free(&q->tt_back);
}

/* `timetag` is compared as an identity, not a value ([RFCS.11.2], [LFST.9.3.6]):
   [LDET.5.5] fixes the order timetags ascend in, not their origin or step. Each
   recorded timetag pairs with the re-derived one the first time either occurs,
   and every later compare atom must agree in both directions. An absent timetag
   (0) is not paired: both sides must be absent together. */
static uint32_t timetag_field(uint32_t atom)
{
    switch (atom) {
    case DS_ATOM_RULE_FIRE_ANNOTATION: return 6;
    case DS_ATOM_CALL_ISSUED:          return 8;
    case DS_ATOM_BOUNDS_ERROR:         return 5;
    case DS_ATOM_COMPUTATION_ERROR:    return 3;
    case DS_ATOM_FACT_PUBLISH:         return 5;
    default:                           return 0;
    }
}

static uint64_t tt_hash(const void *key, void *ctx)
{
    (void)ctx;
    int64_t v;
    memcpy(&v, key, sizeof v);
    return (uint64_t)v;
}

static bool tt_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return memcmp(a, b, sizeof(int64_t)) == 0;
}

static void tt_init(cap_q *q)
{
    ds_oa_init(&q->tt_fwd, sizeof(int64_t), sizeof(int64_t), 0,
            tt_hash, tt_eq, NULL, NULL);
    ds_oa_init(&q->tt_back, sizeof(int64_t), sizeof(int64_t), 0,
            tt_hash, tt_eq, NULL, NULL);
}

static ds_result_t tt_pair(cap_q *q, int64_t recorded, int64_t rederived)
{
    if (recorded == 0 || rederived == 0) {
        if (recorded == rederived)
            return RFCS_OK;
        return RFCS_ERR(DS_ERR_FS_DIVERGENCE,
            "verify: one side of a compare atom carries a timetag and the "
            "other none ([LFST.9.3.6] Divergence at this seq)");
    }
    const int64_t *fwd  = ds_oa_get(&q->tt_fwd, &recorded);
    const int64_t *back = ds_oa_get(&q->tt_back, &rederived);
    if (fwd == NULL && back == NULL) {
        void *slot;
        ds_result_t r = ds_oa_put(&q->tt_fwd, &recorded, &slot, NULL);
        if (r.status != DS_OK)
            return r;
        memcpy(slot, &rederived, sizeof rederived);
        r = ds_oa_put(&q->tt_back, &rederived, &slot, NULL);
        if (r.status != DS_OK)
            return r;
        memcpy(slot, &recorded, sizeof recorded);
        return RFCS_OK;
    }
    if (fwd != NULL && back != NULL && *fwd == rederived && *back == recorded)
        return RFCS_OK;
    return RFCS_ERR(DS_ERR_FS_DIVERGENCE,
        "verify: a timetag breaks the pairing an earlier atom made "
        "([LFST.9.3.6] Divergence at this seq)");
}

/* The next field of `m` other than `skip`, as the byte span [start, end).
   A `skip` varint met on the way is written to `*skipped`. 1 when a field is
   found, 0 at the end of the body, -1 on a malformed one. */
static int next_kept_field(const uint8_t *m, size_t len, size_t *pos,
                           uint32_t skip, uint64_t *skipped,
                           size_t *start, size_t *end)
{
    while (*pos < len) {
        ds_pbf_field_t f;
        if (ds_pbf_next_field(m, len, *pos, &f) != DS_PBF_OK)
            return -1;
        size_t s = *pos;
        *pos = f.next;
        if (f.field == skip && f.wire == 0) {
            *skipped = f.u64;
            continue;
        }
        *start = s;
        *end   = f.next;
        return 1;
    }
    return 0;
}

/* Two bodies byte-equal field by field apart from `skip`, whose varint is
   read from each (0 when absent). Both come from one encoder, which writes
   fields in number order, so field order is not a difference to forgive. */
static bool body_equal_but(const uint8_t *a, size_t alen,
                           const uint8_t *b, size_t blen, uint32_t skip,
                           uint64_t *va, uint64_t *vb)
{
    size_t pa = 0, pb = 0;
    *va = *vb = 0;
    for (;;) {
        size_t sa = 0, ea = 0, sb = 0, eb = 0;
        int ka = next_kept_field(a, alen, &pa, skip, va, &sa, &ea);
        int kb = next_kept_field(b, blen, &pb, skip, vb, &sb, &eb);
        if (ka < 0 || kb < 0 || ka != kb)
            return false;
        if (ka == 0)
            return true;
        if (ea - sa != eb - sb || memcmp(a + sa, b + sb, ea - sa) != 0)
            return false;
    }
}

/* [LFST.9.2.1]: the one BoundsError a replay cannot re-derive. A
   `pump_wcet_ns` breach is observed elapsed time, so it is left uncompared on
   both sides; every other cap is a function of what the engine was given. */
static bool bnds_uncompared(const uint8_t *body, size_t len)
{
    uint64_t cap = 0;
    return body_varint(body, len, 1, &cap)
           && cap == (uint64_t)DS_CAP_PUMP_WCET_NS;
}

/* Sink installed on the replay engine — buffers only compare-class atoms. */
static ds_result_t verify_capture_sink(const uint8_t *bytes, size_t len,
                                       void *user)
{
    cap_q *q = (cap_q *)user;
    ds_pbf_atom_t a;

    if (ds_pbf_next_atom(bytes, len, 0, &a) != DS_PBF_OK)
        return RFCS_OK;
    if (a.field == DS_ATOM_BOUNDS_ERROR) {
        if (bnds_uncompared(a.body, a.body_len))
            return RFCS_OK;
        return cap_push(q, a.field, a.body, a.body_len);
    }
    if (a.field != DS_ATOM_RULE_FIRE_ANNOTATION && a.field != DS_ATOM_CALL_ISSUED &&
        a.field != DS_ATOM_FACT_EMIT && a.field != DS_ATOM_FACT_WITHDRAW &&
        a.field != DS_ATOM_ENGINE_ERROR && a.field != DS_ATOM_TYPE_ERROR &&
        a.field != DS_ATOM_COMPUTATION_ERROR && a.field != DS_ATOM_FACT_PUBLISH)
        return RFCS_OK;                       /* inject / structural — not compared */
    return cap_push(q, a.field, a.body, a.body_len);
}

/* Match one recorded compare atom against the next re-derived one (fail-fast). */
static ds_result_t verify_match(cap_q *q, uint32_t atom,
                                const uint8_t *body, size_t blen)
{
    if (q->err.status != DS_OK)
        return q->err;
    if (q->count == 0)
        return RFCS_ERR(DS_ERR_FS_DIVERGENCE,
            "verify: recorded compare atom has no re-derived counterpart "
            "(replay produced fewer fires/calls/emits/withdrawals than recorded)");
    cap_ent *e = &q->ents[q->head];
    if (e->atom != atom)
        return RFCS_ERR(DS_ERR_FS_DIVERGENCE,
            "verify: compare-atom kind mismatch at this seq "
            "(replay fired a different rule/effect than recorded)");
    uint32_t tf = timetag_field(atom);
    if (tf != 0) {
        uint64_t rec_tt = 0, new_tt = 0;
        if (!body_equal_but(body, blen, e->body, e->len, tf, &rec_tt, &new_tt))
            return RFCS_ERR(DS_ERR_FS_DIVERGENCE,
                "verify: re-derived compare atom differs byte-for-byte "
                "outside its timetag ([LFST.9.3.1] Divergence at this seq)");
        ds_result_t r = tt_pair(q, (int64_t)rec_tt, (int64_t)new_tt);
        if (r.status != DS_OK)
            return r;
    } else if (e->len != blen || memcmp(e->body, body, blen) != 0) {
        return RFCS_ERR(DS_ERR_FS_DIVERGENCE,
            "verify: re-derived compare atom differs byte-for-byte "
            "([LFST.9.3.1] Divergence at this seq)");
    }
    DS_FREE(e->body);
    q->head = (q->head + 1) % q->cap;
    q->count--;
    return RFCS_OK;
}

/* The replay ([LFST.9.6]): deliver each inject-class atom, pump, and
   byte-compare each re-derived compare-class atom against the recorded one
   ([LFST.9.3.1]).

   `arena` is per-atom String decode scratch: the engine copies strings at
   assert. `acc` re-assembles an atom straddling a chunk boundary. */
struct ds_rfcs_replay_ctx {
    ds_engine_t            *engine;
    ds_rfcs_replay_result_t res;
    rfcs_idmap              map;
    bool                    mock_enabled;
    cap_q                   cap;          /* the compare sink writes here */
    ds_rfcs_recorder_t      vrec;
    uint8_t                *vbuf;
    uint8_t                *arena;
    size_t                  arena_cap;
    uint8_t                *acc;
    size_t                  acc_len, acc_cap;
    uint32_t                max_atom;
    bool                    seen_event;   /* LTIM.2.8.5 — see replay_apply_atom */
    ds_result_t             err;          /* sticky: the first failure wins */
    /* [RFCS.5.3]: the reader's descriptor pool, by name. */
    char                  **announced;
    size_t                  n_announced, cap_announced;
};

/* The pool's copy of `name`, NUL-terminated as the decoded view is not, or NULL. */
static const char *replay_announced(const ds_rfcs_replay_ctx_t *ctx,
                                    ds_rfcs_str_t name)
{
    for (size_t i = 0; i < ctx->n_announced; i++)
        if (ds_rfcs_str_eq(name, ctx->announced[i]))
            return ctx->announced[i];
    return NULL;
}

/* A body that does not unpack, or names no schema, is malformed ([RFCS.19.3]). */
static ds_result_t replay_announce(ds_rfcs_replay_ctx_t *ctx,
                                   const uint8_t *body, size_t blen)
{
    Ds__V1__SchemaDef *sd =
        ds__v1__schema_def__unpack(&ds_pb_allocator, blen, body);
    if (sd == NULL || sd->schema_name == NULL || sd->schema_name[0] == '\0') {
        if (sd != NULL)
            ds__v1__schema_def__free_unpacked(sd, &ds_pb_allocator);
        return RFCS_ERR(DS_ERR_PARSE,
                        "ds_rfcs_replay: malformed SchemaDef body");
    }
    ds_result_t r = RFCS_OK;
    const ds_rfcs_str_t named = { sd->schema_name, strlen(sd->schema_name) };
    if (replay_announced(ctx, named) == NULL) {
        if (ctx->n_announced == ctx->cap_announced) {
            size_t cap = ctx->cap_announced ? 2 * ctx->cap_announced : 8;
            char **grown = DS_REALLOC(ctx->announced, cap * sizeof(*grown));
            if (grown == NULL) {
                r = RFCS_ERR(DS_ERR_OOM, "ds_rfcs_replay: schema pool");
                goto done;
            }
            ctx->announced     = grown;
            ctx->cap_announced = cap;
        }
        char *name = DS_STRDUP(sd->schema_name);
        if (name == NULL) {
            r = RFCS_ERR(DS_ERR_OOM, "ds_rfcs_replay: schema pool");
            goto done;
        }
        ctx->announced[ctx->n_announced++] = name;
    }
done:
    ds__v1__schema_def__free_unpacked(sd, &ds_pb_allocator);
    return r;
}

/* [NCBK.2.9], [RFCS.6.7]: when the engine was running as the input went in, the
   halt is the recorded run's own, reproduced, and the re-derived EngineError is
   compared when its atom arrives. An input that met an engine already halted
   was refused, and stays an error. */
static bool replay_halted_by(const ds_result_t r, bool halted_before)
{
    return r.status == DS_ERR_ENGINE_HALTED && !halted_before;
}

/* RFCS.24.2: one decoded ExternalAssert, delivered as RFCS.23.7 receives a
   FactExternal. Through ds_api_enter / leave, as a host's call: the delivery
   samples the clocks only as the outermost call. No pump: the PumpBoundary atom
   says where.

   On DS_OK, `*out_rete` and `*out_ids` (each when not NULL) hold each asserted
   fact's ids, in `fact_ids`'s order; the caller frees them. */
static ds_result_t fcxt_apply(ds_engine_t *engine, const fcxt_body_t *fx,
                              uint32_t **out_rete, uint64_t **out_ids)
{
    uint32_t *rete = NULL;
    uint64_t *ids = NULL;
    size_t    n = 0;
    const bool halted_before = engine->halted;
    ds_api_enter(engine);
    ds_result_t r = ds_api_leave(engine,
                                 fx_deliver(engine, fx->fact, fx->fact_len,
                                            fx->ttl_ns, &rete, &ids, &n));
    if (replay_halted_by(r, halted_before))
        r = RFCS_OK;   /* delivered; an assert's propagation halted */
    if (r.status != DS_OK) {
        r = RFCS_ERR(DS_ERR_FS_DIVERGENCE,
                     "ds_rfcs_replay: an ExternalAssert delivery was refused on "
                     "replay (RFCS.24.2)");
    } else if (n != fx->n_ids) {
        r = RFCS_ERR(DS_ERR_FS_DIVERGENCE,
                     "ds_rfcs_replay: an ExternalAssert delivery asserted a "
                     "different number of facts than its fact_ids "
                     "(RFCS.24.2)");
    }
    /* fx_deliver hands both arrays over on DS_OK and on its own halt, and
       ds_api_leave can still turn DS_OK into an error, so they are freed
       here on every path that does not hand them on. */
    if (r.status == DS_OK && out_rete != NULL) { *out_rete = rete; rete = NULL; }
    if (r.status == DS_OK && out_ids != NULL)  { *out_ids  = ids;  ids  = NULL; }
    DS_FREE(rete);
    DS_FREE(ids);
    return r;
}

ds_result_t ds_rfcs_apply_external_assert(ds_engine_t   *engine,
                                          const uint8_t *body, size_t len,
                                          uint64_t      *out_fact_ids,
                                          uint64_t      *out_recorded_ids,
                                          size_t         cap,
                                          size_t        *out_n)
{
    if (engine == NULL || out_n == NULL)
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_apply_external_assert: NULL engine or out_n");
    *out_n = 0;
    /* Before fcxt_apply, which would read the refusal as a divergence. */
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if ((body == NULL && len > 0)
            || (cap > 0 && (out_fact_ids == NULL || out_recorded_ids == NULL)))
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_apply_external_assert: NULL body or id array");

    fcxt_body_t fx;
    ds_result_t r = decode_fcxt(body, len, &fx);
    if (r.status != DS_OK)
        return r;
    /* Sized before anything is delivered, so a short array refuses a call
       that has done nothing, and says what it needs. */
    if (fx.n_ids > cap) {
        *out_n = fx.n_ids;
        DS_FREE(fx.ids);
        return RFCS_ERR(DS_ERR_INVAL,
                        "ds_rfcs_apply_external_assert: the id arrays are "
                        "shorter than the record's fact_ids");
    }

    uint64_t *ids = NULL;
    r = fcxt_apply(engine, &fx, NULL, &ids);
    if (r.status == DS_OK) {
        for (size_t i = 0; i < fx.n_ids; i++) {
            out_fact_ids[i]     = ids[i];
            out_recorded_ids[i] = fx.ids[i];
        }
        *out_n = fx.n_ids;
    }
    DS_FREE(ids);
    DS_FREE(fx.ids);
    return r;
}

/* res / map / mock_enabled are copied in and written back at `out`. cap is not:
   the verify recorder's sink writes into ctx->cap during ds_engine_pump. */
static ds_result_t replay_apply_atom(ds_rfcs_replay_ctx_t *ctx,
                                     uint32_t atom,
                                     const uint8_t *body, size_t blen)
{
    ds_engine_t *engine     = ctx->engine;
    uint8_t     *strbuf     = ctx->arena;
    const size_t strbuf_cap = ctx->arena_cap;
    size_t       str_used   = 0;   /* per-atom scratch — see the struct note */

    ds_rfcs_replay_result_t res          = ctx->res;
    rfcs_idmap              map          = ctx->map;
    bool                    mock_enabled = ctx->mock_enabled;
    ds_result_t             r            = RFCS_OK;

    /* [LTIM.2.8.5], [LFST.5.3]: a stream's first event has seq 0. */
    if (!ctx->seen_event) {
        uint32_t field = event_seq_field(atom);
        if (field != 0) {
            uint64_t seq = 0;
            ctx->seen_event = true;
            if (!body_varint(body, blen, field, &seq))
                return RFCS_ERR(DS_ERR_PARSE,
                                "ds_rfcs_replay: malformed event atom body");
            if (seq != 0)
                return RFCS_ERR(DS_ERR_FS_RECORDING_INCOMPLETE,
                                "ds_rfcs_replay: the recording's first event "
                                "has a seq other than 0 -- the stream callback "
                                "was attached after the engine's first input "
                                "or sample ([LTIM.2.8.5])");
        }
    }

    {
        if (atom == DS_ATOM_STREAM_HEADER) {
            bool ok = false;
            r = replay_verify_header(engine, body, blen, &ok);
            if (r.status != DS_OK)
                goto out;
            res.header_verified = res.header_verified || ok;

        } else if (atom == DS_ATOM_FACT_ASSERT) {
            ds_rfcs_fcem_t fc;
            r = ds_rfcs_decode_fcem(body, blen, &fc);
            if (r.status != DS_OK)
                goto out;

            /* [RFCS.5.4]'s first case, asked of the stream: the engine holds the
               artefact's schemas whether or not the stream announced them. */
            const char *schema_name = replay_announced(ctx, fc.schema_name);
            if (schema_name == NULL) {
                r = RFCS_ERR(DS_ERR_SCHEMA_UNKNOWN,
                             "ds_rfcs_replay: fact atom names a schema no SchemaDef announced (RFCS.5.3, RFCS.5.4)");
                goto out;
            }

            const ds_schema_t *sc = NULL;
            r = ds_engine_schema_find(engine, schema_name, &sc);
            if (r.status != DS_OK)
                goto out;
            if (!sc) {
                r = RFCS_ERR(DS_ERR_SCHEMA_UNKNOWN,
                             "ds_rfcs_replay: fact atom names an unregistered schema (RFCS.5.4)");
                goto out;
            }

            ds_slot_value_t vals[DS_RFCS_REPLAY_MAX_SLOTS];
            uint32_t nv = 0;
            replay_resolver_t rr = { engine, &map };
            r = ds_rfcs_decode_fact_body_resolving(sc, fc.fact, fc.fact_len,
                                                   vals,
                                                   DS_RFCS_REPLAY_MAX_SLOTS,
                                                   (char *)strbuf + str_used,
                                                   strbuf_cap - str_used,
                                                   replay_resolve_handle, &rr,
                                                   &nv);
            if (r.status != DS_OK)
                goto out;
            /* [RFCS.7.4]. A window of 0 is exactly ds_engine_assert. */
            ds_fact_t *newfact = NULL;
            const bool halted_before = engine->halted;
            r = ds_engine_assert_with_ttl(engine, sc, vals, nv, fc.ttl_ns,
                                          &newfact);
            if (replay_halted_by(r, halted_before))
                r = RFCS_OK;   /* the fact is in; its propagation halted */
            /* The engine deep-clones Json slots (wm_rete_bridge.c). */
            free_owned_json(vals, nv);
            if (r.status == DS_ERR_CONTRACT_BREACH
                    || r.status == DS_ERR_WM_FULL) {
                /* [RFCS.6.7]: a bound refused the input again, and the re-derived
                   BoundsError is compared when its atom arrives. Nothing entered
                   working memory, so nothing goes in the id map. */
                r = RFCS_OK;
                res.asserts++;
            } else {
                if (r.status != DS_OK)
                    goto out;
                r = idmap_put(&map, fc.fact_id,
                              newfact ? newfact->rete_id : 0u);
                if (r.status != DS_OK)
                    goto out;
                res.asserts++;
            }
            /* No pump: the PumpBoundary atom says where ([RFCS.22]). */

        } else if (atom == DS_ATOM_PUMP_BOUNDARY) {
            /* [RFCS.22]: the body is not consulted, since the ClockAdvance before
               it set the clock, and a PUMP is never compared ([RFCS.17.5]). */
            const bool halted_before = engine->halted;
            r = ds_engine_pump(engine);
            if (replay_halted_by(r, halted_before)) {
                r = RFCS_OK;   /* the recorded pump halted the tier too */
            } else if (r.status == DS_ERR_CONTRACT_BREACH) {
                /* RFCS.6.7: a bound refused a rule's work, and the recorded run
                   went on. The re-derived BoundsError decides, when its atom
                   arrives. */
                r = RFCS_OK;
            } else if (r.status == DS_ERR_NAN_REJECTED
                       || r.status == DS_ERR_SERIES_NO_BACKING) {
                /* [RFCS.6.7]: a one-shot report no atom records. The compare of
                   what the firing did decides. */
                r = RFCS_OK;
            } else if (r.status != DS_OK) {
                goto out;
            }

        } else if (atom == DS_ATOM_FACT_RETRACT) {
            ds_rfcs_fcrt_t fr;
            r = ds_rfcs_decode_fcrt(body, blen, &fr);
            if (r.status != DS_OK)
                goto out;
            const uint64_t fid = fr.fact_id;
            uint32_t rid = 0;
            if (!idmap_get(&map, fid, &rid)) {
                r = RFCS_ERR(DS_ERR_FS_UNKNOWN_FACT_ID,
                             "ds_rfcs_replay: FactRetract references an unknown fact_id (RFCS.7.3)");
                goto out;
            }
            /* A swept fact surfaces here as NULL. */
            ds_fact_t *f = NULL;
            r = ds_engine_fact_by_rete_id(engine, rid, &f);
            if (r.status != DS_OK)
                goto out;
            if (f != NULL) {
                const bool halted_before = engine->halted;
                r = ds_engine_retract(engine, f);
                if (replay_halted_by(r, halted_before))
                    r = RFCS_OK;   /* the retraction's cascade halted */
                if (r.status != DS_OK)
                    goto out;
            }
            /* f == NULL: the engine already retracted it, by TTL sweep or
               cascade, during a pump this replay drove. The atom still counts. */
            idmap_forget(&map, fid);
            res.retracts++;

        } else if (atom == DS_ATOM_CLOCK_ADVANCE) {
            ds_rfcs_clka_t ck;
            r = ds_rfcs_decode_clka(body, blen, &ck);
            if (r.status != DS_OK)
                goto out;
            if (!mock_enabled) {
                r = ds_engine_clock_set_mode(engine, DS_CLOCK_MOCK);
                if (r.status != DS_OK)
                    goto out;
                mock_enabled = true;
            }
            /* [RFCS.10.5]: unset without has_wall, so a run whose now() faulted
               replays to the same fault. Setting is not a sample ([NTST.3.3]). */
            r = ds_engine_clock_set(engine, (uint64_t)ck.clock_ns);
            if (r.status != DS_OK)
                goto out;
            if (ck.has_wall)
                r = ds_engine_wall_clock_set(engine, ck.wall_ns);
            else
                r = ds_clock_wall_unset(&engine->clock);
            if (r.status != DS_OK)
                goto out;
            res.clocks++;
            /* No pump: the next input or PumpBoundary atom samples these clocks
               ([LTIM.2.8.5]). */

        } else if (atom == DS_ATOM_RULE_FIRE_ANNOTATION) {
            r = verify_match(&ctx->cap, atom, body, blen);
            if (r.status != DS_OK)
                goto out;
            res.rule_fires++;

        } else if (atom == DS_ATOM_CALL_ISSUED) {
            r = verify_match(&ctx->cap, atom, body, blen);
            if (r.status != DS_OK)
                goto out;
            res.calls++;

        } else if (atom == DS_ATOM_FACT_EMIT) {
            /* [RFCS.6a]: compare, never inject: the replay's own pump re-derives
               this fact. */
            r = verify_match(&ctx->cap, atom, body, blen);
            if (r.status != DS_OK)
                goto out;
            /* RFCS.6.3: a later record may name this fact by its handle. The
               compare just passed, so the replay's own fact has the recorded id. */
            {
                ds_rfcs_fcem_t fe;
                r = ds_rfcs_decode_femt(body, blen, &fe);
                if (r.status != DS_OK)
                    goto out;
                ds_fact_t *own = ds_wm_fact_by_id(&engine->wm, fe.fact_id);
                if (own != NULL) {
                    r = idmap_put(&map, fe.fact_id, own->rete_id);
                    if (r.status != DS_OK)
                        goto out;
                }
            }
            res.asserts++;

        } else if (atom == DS_ATOM_FACT_PUBLISH) {
            /* A rule's `publish` ran ([RFCS.27.2]): compare, never deliver.
               The body holds no value, so a match shows the same rule
               published the same schema at the same point, and nothing of
               the values. */
            r = verify_match(&ctx->cap, atom, body, blen);
            if (r.status != DS_OK)
                goto out;
            res.publishes++;

        } else if (atom == DS_ATOM_FACT_WITHDRAW) {
            /* [RFCS.7a.3]: compare, never apply. */
            r = verify_match(&ctx->cap, atom, body, blen);
            if (r.status != DS_OK)
                goto out;
            res.withdrawals++;

        } else if (atom == DS_ATOM_BOUNDS_ERROR) {
            if (bnds_uncompared(body, blen)) {
                res.skipped++;
            } else {
                r = verify_match(&ctx->cap, atom, body, blen);
                if (r.status != DS_OK)
                    goto out;
            }

        } else if (atom == DS_ATOM_ENGINE_ERROR || atom == DS_ATOM_TYPE_ERROR
                   || atom == DS_ATOM_COMPUTATION_ERROR) {
            r = verify_match(&ctx->cap, atom, body, blen);
            if (r.status != DS_OK)
                goto out;

        } else if (atom == DS_ATOM_EXTERNAL_ASSERT) {
            /* RFCS.24.2: each fact the delivery asserts is bound, in order, to its
               recorded handle, so a later FactRetract resolves. */
            fcxt_body_t fx;
            r = decode_fcxt(body, blen, &fx);
            if (r.status != DS_OK)
                goto out;
            uint32_t *rete = NULL;
            r = fcxt_apply(engine, &fx, &rete, NULL);
            if (r.status != DS_OK) {
                DS_FREE(fx.ids);
                goto out;
            }
            for (size_t i = 0; r.status == DS_OK && i < fx.n_ids; i++)
                r = idmap_put(&map, fx.ids[i], rete[i]);
            DS_FREE(rete);
            const size_t n_rete = fx.n_ids;
            DS_FREE(fx.ids);
            if (r.status != DS_OK)
                goto out;
            res.asserts += n_rete;
            /* No pump, as for a FactAssert. */

        } else if (atom == DS_ATOM_CACHE_SEED) {
            /* [RFCS.26.2]: as a host seed writes the cache, with no cache event
               and no write-through. A seed after an event, or one this engine
               refuses, is a replay that has not reproduced the run. */
            if (ctx->seen_event) {
                r = RFCS_ERR(DS_ERR_FS_DIVERGENCE,
                             "ds_rfcs_replay: a CacheSeed after an event atom "
                             "(RFCS.26.2)");
                goto out;
            }
            Ds__V1__CacheSeed *cs =
                ds__v1__cache_seed__unpack(&ds_pb_allocator, blen, body);
            if (cs == NULL) {
                r = RFCS_ERR(DS_ERR_PARSE,
                             "ds_rfcs_replay: malformed CacheSeed body");
                goto out;
            }
            ds_result_t sr = ds_engine_cache_seed_replay(
                engine, cs->key, cs->value_json, strlen(cs->value_json),
                cs->deadline_ns);
            ds__v1__cache_seed__free_unpacked(cs, &ds_pb_allocator);
            if (sr.status != DS_OK) {
                r = RFCS_ERR(DS_ERR_FS_DIVERGENCE,
                             "ds_rfcs_replay: a recorded CacheSeed was refused "
                             "on replay (RFCS.26.2)");
                goto out;
            }

        } else if (atom == DS_ATOM_SCHEMA_DEF) {
            /* [RFCS.5.3]. Counted as skipped: nothing reaches the engine. */
            r = replay_announce(ctx, body, blen);
            if (r.status != DS_OK)
                goto out;
            res.skipped++;

        } else {
            res.skipped++; /* Slot / any other allocated atom */
        }
    }

out:
    ctx->res          = res;
    ctx->map          = map;
    ctx->mock_enabled = mock_enabled;
    return r;
}

/* ---- chunked replay driver ---- */

static void replay_ctx_free(ds_rfcs_replay_ctx_t *ctx)
{
    if (ctx == NULL) return;
    for (size_t i = 0; i < ctx->n_announced; i++)
        DS_FREE(ctx->announced[i]);
    DS_FREE(ctx->announced);
    cap_free(&ctx->cap);
    DS_FREE(ctx->vbuf);
    DS_FREE(ctx->map.ents);
    DS_FREE(ctx->arena);
    DS_FREE(ctx->acc);
    DS_FREE(ctx);
}

ds_result_t ds_rfcs_replay_begin(ds_engine_t *engine,
                                 const ds_rfcs_replay_opts_t *opts,
                                 ds_rfcs_replay_ctx_t **out_ctx)
{
    if (engine == NULL || out_ctx == NULL)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_replay_begin: NULL arg");
    *out_ctx = NULL;

    ds_rfcs_replay_ctx_t *ctx = DS_CALLOC(1, sizeof(*ctx));
    if (ctx == NULL)
        return RFCS_ERR(DS_ERR_OOM, "ds_rfcs_replay_begin: ctx");

    ctx->engine   = engine;
    ctx->max_atom = (opts && opts->max_atom_bytes)
                    ? opts->max_atom_bytes : DS_RFCS_VERIFY_BUF_CAP;
    ctx->err      = RFCS_OK;
    tt_init(&ctx->cap);

    /* One atom's worth of String scratch. ds_rfcs_decode_fact_body needs
       body_len + one NUL per slot, and a body cannot exceed max_atom. */
    ctx->arena_cap = (size_t)ctx->max_atom + DS_RFCS_REPLAY_MAX_SLOTS;
    ctx->arena     = DS_MALLOC(ctx->arena_cap);
    ctx->acc_cap   = (size_t)ctx->max_atom + DS_RFCS_ATOM_PREFIX_MAX;
    ctx->acc       = DS_MALLOC(ctx->acc_cap);
    if (ctx->arena == NULL || ctx->acc == NULL) {
        replay_ctx_free(ctx);
        return RFCS_ERR(DS_ERR_OOM, "ds_rfcs_replay_begin: buffers");
    }

    /* [LFST.9.6]: captures every re-derived compare atom. */
    {
        ctx->vbuf = DS_MALLOC(DS_RFCS_VERIFY_BUF_CAP);
        if (ctx->vbuf == NULL) {
            replay_ctx_free(ctx);
            return RFCS_ERR(DS_ERR_OOM, "ds_rfcs_replay: verify capture buffer OOM");
        }
        ds_result_t r = ds_rfcs_record_to(engine, &ctx->vrec,
                                          verify_capture_sink, &ctx->cap,
                                          ctx->vbuf, DS_RFCS_VERIFY_BUF_CAP);
        if (r.status != DS_OK) {
            replay_ctx_free(ctx);
            return r;
        }
    }

    /* [NDET.8.2]: no effect callback until ds_rfcs_replay_finish. Entered last,
       so a begin that fails has nothing to leave. */
    ds_dispatcher_replay_enter(engine);

    *out_ctx = ctx;
    return RFCS_OK;
}

/*
 * The inner frame's own overhead: tag varint (<=2, field <= 2047) + length
 * varint (<=5, a 32-bit length). So a body is at least outer_len - 7 bytes.
 */
#define RFCS_INNER_PREFIX_MAX 7u

/*
 * Is the atom this prefix declares already over budget? To `ds_pbf_next_atom` a
 * frame whose body has not arrived is EOF ([RFCS.19.2]), so this reads the outer
 * length varint itself.
 *
 * False also means "cannot tell yet": the check runs again on every top-up.
 */
static bool rfcs_declared_over_budget(const uint8_t *buf, size_t len,
                                      uint32_t max_atom)
{
    uint64_t v = 0;
    unsigned shift = 0;
    size_t   i;

    if (len < 2 || buf[0] != 0x0Au)
        return false;
    for (i = 1; i < len; i++) {
        v |= (uint64_t)(buf[i] & 0x7Fu) << shift;
        if (!(buf[i] & 0x80u))
            return v > (uint64_t)max_atom + RFCS_INNER_PREFIX_MAX;
        shift += 7;
        if (shift > 63)
            return false;                     /* malformed; the parser says so */
    }
    return false;                             /* varint still incomplete */
}

/* A field number with no registry entry is no member of Atom's `body` oneof, so
   the Atom it frames has its oneof unset, and [RFCS.19.3] refuses it. A reader
   never meets such a number in a container of its own series ([LDET.1.10]). */
#define RFCS_UNKNOWN_ATOM_DETAIL \
    "rfcs: an atom's field number names no atom (RFCS.19.3)"

/* Apply every whole atom in buf[0..len); *consumed is how far we got. */
static ds_result_t replay_drain(ds_rfcs_replay_ctx_t *ctx,
                                const uint8_t *buf, size_t len,
                                size_t *consumed)
{
    size_t pos = 0;
    for (;;) {
        ds_pbf_atom_t a;

        /* EOF: this chunk ends mid-atom, and the caller stashes the remainder. */
        ds_pbf_step_t step = ds_pbf_next_atom(buf, len, pos, &a);
        if (step == DS_PBF_EOF) {
            if (rfcs_declared_over_budget(buf + pos, len - pos, ctx->max_atom)) {
                *consumed = pos;
                return RFCS_ERR(DS_ERR_PARSE,
                                "ds_rfcs_replay_feed: atom exceeds max_atom_bytes");
            }
            break;
        }
        if (step != DS_PBF_OK) {
            *consumed = pos;
            return RFCS_ERR(DS_ERR_PARSE,
                            "ds_rfcs_replay_feed: malformed atom frame");
        }
        if (a.body_len > ctx->max_atom) {
            *consumed = pos;
            return RFCS_ERR(DS_ERR_PARSE,
                            "ds_rfcs_replay_feed: atom exceeds max_atom_bytes");
        }
        if (ds_pbf_lookup(a.field) == NULL) {
            *consumed = pos;
            return RFCS_ERR(DS_ERR_PARSE, RFCS_UNKNOWN_ATOM_DETAIL);
        }
        ds_result_t r = replay_apply_atom(ctx, a.field, a.body, a.body_len);
        pos = a.next;
        if (r.status != DS_OK) { *consumed = pos; return r; }
    }
    *consumed = pos;
    return RFCS_OK;
}

ds_result_t ds_rfcs_replay_feed(ds_rfcs_replay_ctx_t *ctx,
                                const uint8_t *chunk, size_t len)
{
    if (ctx == NULL || (chunk == NULL && len > 0))
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_replay_feed: NULL arg");
    if (ctx->err.status != DS_OK) return ctx->err;   /* sticky */

    size_t off = 0;
    ds_result_t r = RFCS_OK;

    /* Phase 1: top up the atom held over from a previous chunk. The prefix is a
       run of varints, so the accumulator fills greedily and asks the parser
       after each top-up, which can over-read into the next atom. */
    while (ctx->acc_len > 0) {
        ds_pbf_atom_t a;
        ds_pbf_step_t step = ds_pbf_next_atom(ctx->acc, ctx->acc_len, 0, &a);

        if (step == DS_PBF_MALFORMED) {
            r = RFCS_ERR(DS_ERR_PARSE,
                         "ds_rfcs_replay_feed: malformed atom frame");
            goto fail;
        }
        if (step == DS_PBF_OK) {
            if (a.body_len > ctx->max_atom) {
                r = RFCS_ERR(DS_ERR_PARSE,
                             "ds_rfcs_replay_feed: atom exceeds max_atom_bytes");
                goto fail;
            }
            if (ds_pbf_lookup(a.field) == NULL) {
                r = RFCS_ERR(DS_ERR_PARSE, RFCS_UNKNOWN_ATOM_DETAIL);
                goto fail;
            }
            r = replay_apply_atom(ctx, a.field, a.body, a.body_len);
            size_t rest = ctx->acc_len - a.next;
            if (rest) memmove(ctx->acc, ctx->acc + a.next, rest);
            ctx->acc_len = rest;
            if (r.status != DS_OK) goto fail;
            continue;                        /* acc may hold another whole atom */
        }

        if (rfcs_declared_over_budget(ctx->acc, ctx->acc_len, ctx->max_atom)) {
            r = RFCS_ERR(DS_ERR_PARSE,
                         "ds_rfcs_replay_feed: atom exceeds max_atom_bytes");
            goto fail;
        }
        if (off == len) return RFCS_OK;      /* wait for the next chunk */
        size_t room = ctx->acc_cap - ctx->acc_len;
        if (room == 0) {
            r = RFCS_ERR(DS_ERR_PARSE,
                         "ds_rfcs_replay_feed: atom exceeds max_atom_bytes");
            goto fail;
        }
        size_t take = len - off;
        if (take > room) take = room;
        memcpy(ctx->acc + ctx->acc_len, chunk + off, take);
        ctx->acc_len += take;
        off          += take;
    }

    /* Phase 2: whole atoms straight out of the caller's chunk, with no copy. */
    size_t used = 0;
    r = replay_drain(ctx, chunk + off, len - off, &used);
    off += used;
    if (r.status != DS_OK) goto fail;

    /* Phase 3: stash the trailing partial. */
    if (off < len) {
        size_t rest = len - off;
        if (rest > ctx->acc_cap) {   /* unreachable: drain bounds the remainder */
            r = RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_replay_feed: partial atom too large");
            goto fail;
        }
        memcpy(ctx->acc, chunk + off, rest);
        ctx->acc_len = rest;
    }
    return RFCS_OK;

fail:
    ctx->err = r;
    return r;
}

ds_result_t ds_rfcs_replay_finish(ds_rfcs_replay_ctx_t *ctx,
                                  ds_rfcs_replay_result_t *out)
{
    if (ctx == NULL)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_replay_finish: NULL ctx");

    ds_result_t r = ctx->err;

    /* [RFCS.19.2]: reported, not refused: this path cannot tell a recording
       still being written from one a crash cut off ([RFCS.19.8]). */
    if (r.status == DS_OK)
        ctx->res.tail_bytes = ctx->acc_len;

    if (r.status == DS_OK) {
        if (ctx->cap.count != 0)
            r = RFCS_ERR(DS_ERR_FS_DIVERGENCE,
                "verify: replay produced more compare atoms "
                "(fires/calls/emits/withdrawals) than recorded");
        else if (ctx->cap.err.status != DS_OK)
            r = ctx->cap.err;
    }

    /* Not through ds_engine_set_stream_callback, which refuses a halted engine
       ([NCBK.2.9]): the recorder is in `ctx`, freed below. */
    ctx->engine->recorder.stream_cb   = NULL;
    ctx->engine->recorder.stream_user = NULL;
    if (r.status == DS_OK && ctx->vrec.last.status != DS_OK)
        r = ctx->vrec.last;

    ds_dispatcher_replay_leave(ctx->engine);

    if (out) *out = ctx->res;
    replay_ctx_free(ctx);
    return r;
}

/* Whole-buffer form: begin, one feed, finish. `strbuf` and `strbuf_cap` are
   unused, and still validated. */
ds_result_t ds_rfcs_replay(ds_engine_t *engine,
                           const uint8_t *stream, size_t len,
                           uint8_t *strbuf, size_t strbuf_cap,
                           ds_rfcs_replay_result_t *out)
{
    if (!engine || !stream || (!strbuf && strbuf_cap))
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_replay: NULL arg");

    ds_rfcs_replay_ctx_t *ctx = NULL;
    ds_result_t r = ds_rfcs_replay_begin(engine, NULL, &ctx);
    if (r.status != DS_OK) return r;

    (void)ds_rfcs_replay_feed(ctx, stream, len);

    /* The caller supplied the whole extent ([RFCS.19.2]). Sticky, so finish
       reports it ahead of the verify compare. */
    if (ctx->err.status == DS_OK && ctx->acc_len != 0)
        ctx->err = RFCS_ERR(DS_ERR_PARSE,
                            "ds_rfcs_replay: stream ends mid-atom (truncated)");
    return ds_rfcs_replay_finish(ctx, out);   /* returns the sticky error */
}

/* ---- reader ---- */

void ds_rfcs_reader_init(ds_rfcs_reader_t *r, const uint8_t *stream, size_t len)
{
    if (!r)
        return;
    r->stream = stream;
    r->len = len;
    r->pos = 0;
}

const char *ds_rfcs_message_name(uint32_t atom)
{
    const ds_atom_reg_entry_t *e = ds_pbf_lookup(atom);
    return e ? e->message : NULL;
}

ds_result_t ds_rfcs_reader_extend(ds_rfcs_reader_t *r,
                                  const uint8_t *stream, size_t len)
{
    if (!r || (!stream && len > 0) || len < r->pos)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_reader_extend: bad arg");
    r->stream = stream;
    r->len = len;
    return RFCS_OK;
}

/* One step of either reader; they differ only in what a partial trailing atom
   is. `r->pos` moves only past a complete atom it returns: on INCOMPLETE and
   on an error it names the refused atom's first byte. */
static ds_result_t rfcs_read_step(ds_rfcs_reader_t *r, bool incremental,
                                  uint32_t *out_atom,
                                  const uint8_t **out_body, size_t *out_body_len,
                                  ds_rfcs_step_t *out_step)
{
    ds_pbf_atom_t a;

    if (r->pos >= r->len) {
        *out_step = DS_RFCS_STEP_END;
        return RFCS_OK;
    }

    switch (ds_pbf_next_atom(r->stream, r->len, r->pos, &a)) {
    case DS_PBF_OK:
        break;
    case DS_PBF_EOF:
        /* `ds_pbf_next_atom` answers EOF for a short prefix or a body that
           runs past the buffer: bytes that more bytes can complete. */
        if (incremental) {
            *out_step = DS_RFCS_STEP_INCOMPLETE;
            return RFCS_OK;
        }
        return RFCS_ERR(DS_ERR_PARSE, "ds_rfcs_next: truncated atom");
    case DS_PBF_MALFORMED:
    default:
        return RFCS_ERR(DS_ERR_PARSE, incremental
                        ? "ds_rfcs_next_incremental: malformed atom frame"
                        : "ds_rfcs_next: malformed atom frame");
    }

    if (ds_pbf_lookup(a.field) == NULL)
        return RFCS_ERR(DS_ERR_PARSE, RFCS_UNKNOWN_ATOM_DETAIL);

    *out_atom = a.field;
    *out_body = a.body;
    *out_body_len = a.body_len;
    r->pos = a.next;
    *out_step = DS_RFCS_STEP_ATOM;
    return RFCS_OK;
}

ds_result_t ds_rfcs_next(ds_rfcs_reader_t *r,
                         uint32_t *out_atom,
                         const uint8_t **out_body, size_t *out_body_len,
                         bool *out_done)
{
    if (!r || !out_atom || !out_body || !out_body_len || !out_done)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_next: NULL arg");

    /* Strict, unlike [RFCS.19.2]'s stream reader: the caller supplied the whole
       extent, so a short tail is DS_ERR_PARSE. */
    ds_rfcs_step_t step = DS_RFCS_STEP_END;
    ds_result_t res = rfcs_read_step(r, false, out_atom, out_body,
                                     out_body_len, &step);
    if (res.status != DS_OK)
        return res;
    *out_done = step == DS_RFCS_STEP_END;
    return RFCS_OK;
}

ds_result_t ds_rfcs_next_incremental(ds_rfcs_reader_t *r,
                                     uint32_t *out_atom,
                                     const uint8_t **out_body,
                                     size_t *out_body_len,
                                     ds_rfcs_step_t *out_step)
{
    if (!r || !out_atom || !out_body || !out_body_len || !out_step)
        return RFCS_ERR(DS_ERR_INVAL, "ds_rfcs_next_incremental: NULL arg");
    return rfcs_read_step(r, true, out_atom, out_body, out_body_len, out_step);
}

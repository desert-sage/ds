/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The generic atom reader: `ds_rfcs_visit_atom`, whose contract is in rfcs/rfcs.h.
 *
 * It walks the descriptor's field table, so an atom added to proto/atom.proto is read
 * with no edit here. It unpacks through protobuf-c, which allocates, so it is not for
 * a live realtime engine; it is its own archive member, so an engine link never pulls
 * it.
 *
 * [RDSC.9.9]: ExternalAssert and CallIssued recurse through Arg.fact ->
 * FactExternal.fields -> Arg, and protobuf-c's unpack has no recursion limit, so
 * `nests_too_deep` walks the raw body before the unpack.
 */
#include <string.h>

#include <protobuf-c/protobuf-c.h>

#include "rfcs/rfcs.h"
#include "dsc/pbf_reader.h"
#include "dsc/ds_pb_alloc.h"
#include "atom_descriptors.h"

typedef struct {
    ds_rfcs_field_fn   fn;
    ds_rfcs_unknown_fn on_unknown;   /* NULL: unknown fields are not reported */
    void              *ctx;
    bool               stopped;      /* a visitor returned false */
} walk_t;

static bool emit(walk_t *w, const ds_rfcs_field_t *f)
{
    if (w->stopped)
        return false;
    if (!w->fn(w->ctx, f))
        w->stopped = true;
    return !w->stopped;
}

/* An enum is stored as its C enum type, which is int-sized. */
static size_t element_size(ProtobufCType t)
{
    switch (t) {
    case PROTOBUF_C_TYPE_INT32:
    case PROTOBUF_C_TYPE_SINT32:
    case PROTOBUF_C_TYPE_SFIXED32: return sizeof(int32_t);
    case PROTOBUF_C_TYPE_UINT32:
    case PROTOBUF_C_TYPE_FIXED32:  return sizeof(uint32_t);
    case PROTOBUF_C_TYPE_INT64:
    case PROTOBUF_C_TYPE_SINT64:
    case PROTOBUF_C_TYPE_SFIXED64: return sizeof(int64_t);
    case PROTOBUF_C_TYPE_UINT64:
    case PROTOBUF_C_TYPE_FIXED64:  return sizeof(uint64_t);
    case PROTOBUF_C_TYPE_FLOAT:    return sizeof(float);
    case PROTOBUF_C_TYPE_DOUBLE:   return sizeof(double);
    case PROTOBUF_C_TYPE_BOOL:     return sizeof(protobuf_c_boolean);
    case PROTOBUF_C_TYPE_ENUM:     return sizeof(int);
    case PROTOBUF_C_TYPE_STRING:   return sizeof(char *);
    case PROTOBUF_C_TYPE_BYTES:    return sizeof(ProtobufCBinaryData);
    case PROTOBUF_C_TYPE_MESSAGE:  return sizeof(ProtobufCMessage *);
    }
    return 0;
}

static ds_result_t visit_message(walk_t *w, const ProtobufCMessage *msg,
                                 const char *name, uint32_t number,
                                 int32_t index, uint32_t depth);

static ds_result_t visit_value(walk_t *w, const ProtobufCFieldDescriptor *fd,
                               const void *p, int32_t index, uint32_t depth)
{
    ds_rfcs_field_t f;
    memset(&f, 0, sizeof(f));
    f.name   = fd->name;
    f.number = fd->id;
    f.index  = index;
    f.depth  = depth;

    switch (fd->type) {
    case PROTOBUF_C_TYPE_INT32:
    case PROTOBUF_C_TYPE_SINT32:
    case PROTOBUF_C_TYPE_SFIXED32: {
        int32_t v; memcpy(&v, p, sizeof(v));
        f.kind = DS_RFCS_FIELD_INT; f.v.i = v;
        break;
    }
    case PROTOBUF_C_TYPE_INT64:
    case PROTOBUF_C_TYPE_SINT64:
    case PROTOBUF_C_TYPE_SFIXED64: {
        int64_t v; memcpy(&v, p, sizeof(v));
        f.kind = DS_RFCS_FIELD_INT; f.v.i = v;
        break;
    }
    case PROTOBUF_C_TYPE_UINT32:
    case PROTOBUF_C_TYPE_FIXED32: {
        uint32_t v; memcpy(&v, p, sizeof(v));
        f.kind = DS_RFCS_FIELD_UINT; f.v.u = v;
        break;
    }
    case PROTOBUF_C_TYPE_UINT64:
    case PROTOBUF_C_TYPE_FIXED64: {
        uint64_t v; memcpy(&v, p, sizeof(v));
        f.kind = DS_RFCS_FIELD_UINT; f.v.u = v;
        break;
    }
    case PROTOBUF_C_TYPE_FLOAT: {
        float v; memcpy(&v, p, sizeof(v));
        f.kind = DS_RFCS_FIELD_DOUBLE; f.v.d = (double)v;
        break;
    }
    case PROTOBUF_C_TYPE_DOUBLE: {
        double v; memcpy(&v, p, sizeof(v));
        f.kind = DS_RFCS_FIELD_DOUBLE; f.v.d = v;
        break;
    }
    case PROTOBUF_C_TYPE_BOOL: {
        protobuf_c_boolean v; memcpy(&v, p, sizeof(v));
        f.kind = DS_RFCS_FIELD_BOOL; f.v.b = v != 0;
        break;
    }
    case PROTOBUF_C_TYPE_ENUM: {
        int v; memcpy(&v, p, sizeof(v));
        const ProtobufCEnumValue *ev = protobuf_c_enum_descriptor_get_value(
            (const ProtobufCEnumDescriptor *)fd->descriptor, v);
        f.kind = DS_RFCS_FIELD_ENUM;
        f.v.e.number = (int32_t)v;
        f.v.e.name   = ev ? ev->name : NULL;
        break;
    }
    case PROTOBUF_C_TYPE_STRING: {
        const char *s; memcpy(&s, p, sizeof(s));
        f.kind = DS_RFCS_FIELD_STRING;
        f.v.s.p   = (const uint8_t *)(s ? s : "");
        f.v.s.len = s ? strlen(s) : 0;
        break;
    }
    case PROTOBUF_C_TYPE_BYTES: {
        ProtobufCBinaryData b; memcpy(&b, p, sizeof(b));
        f.kind = DS_RFCS_FIELD_BYTES;
        f.v.s.p   = b.data;
        f.v.s.len = b.len;
        break;
    }
    case PROTOBUF_C_TYPE_MESSAGE: {
        const ProtobufCMessage *sub; memcpy(&sub, p, sizeof(sub));
        if (!sub)
            return DS_OK_R;
        return visit_message(w, sub, fd->name, fd->id, index, depth + 1);
    }
    default:
        return DS_ERR_R(DS_ERR_PARSE, "ds_rfcs_visit_atom: unknown field type");
    }
    emit(w, &f);
    return DS_OK_R;
}

static ds_result_t visit_message(walk_t *w, const ProtobufCMessage *msg,
                                 const char *name, uint32_t number,
                                 int32_t index, uint32_t depth)
{
    if (depth > DS_RFCS_VISIT_MAX_DEPTH)
        return DS_ERR_R(DS_ERR_PARSE,
                        "ds_rfcs_visit_atom: nesting exceeds DS_RFCS_VISIT_MAX_DEPTH");

    const ProtobufCMessageDescriptor *desc = msg->descriptor;
    const char *base = (const char *)msg;

    ds_rfcs_field_t f;
    memset(&f, 0, sizeof(f));
    f.kind    = DS_RFCS_FIELD_ENTER;
    f.name    = name;
    f.number  = number;
    f.index   = index;
    f.depth   = depth;
    /* protobuf-c's `name` is package-qualified (ds.v1.FactAssert). */
    f.message = desc->short_name;
    if (!emit(w, &f))
        return DS_OK_R;

    for (unsigned i = 0; i < desc->n_fields && !w->stopped; i++) {
        const ProtobufCFieldDescriptor *fd = &desc->fields[i];
        const char *at = base + fd->offset;
        ds_result_t r = DS_OK_R;

        if (fd->label == PROTOBUF_C_LABEL_REPEATED) {
            size_t n; memcpy(&n, base + fd->quantifier_offset, sizeof(n));
            const char *arr; memcpy(&arr, at, sizeof(arr));
            size_t sz = element_size(fd->type);
            for (size_t j = 0; j < n && r.status == DS_OK && !w->stopped; j++)
                r = visit_value(w, fd, arr + j * sz, (int32_t)j, depth);
        } else if (fd->flags & PROTOBUF_C_FIELD_FLAG_ONEOF) {
            uint32_t which; memcpy(&which, base + fd->quantifier_offset, sizeof(which));
            if (which == fd->id)
                r = visit_value(w, fd, at, -1, depth);
        } else if (fd->label == PROTOBUF_C_LABEL_OPTIONAL &&
                   fd->type != PROTOBUF_C_TYPE_MESSAGE &&
                   fd->type != PROTOBUF_C_TYPE_STRING) {
            /* Explicit presence: a `has_` flag beside the value. */
            protobuf_c_boolean has;
            memcpy(&has, base + fd->quantifier_offset, sizeof(has));
            if (has)
                r = visit_value(w, fd, at, -1, depth);
        } else {
            r = visit_value(w, fd, at, -1, depth);
        }
        if (r.status != DS_OK)
            return r;
    }

    /* [RTIM.14.9]: inside this message, before its LEAVE. */
    for (size_t i = 0; w->on_unknown && i < msg->n_unknown_fields && !w->stopped; i++) {
        const ProtobufCMessageUnknownField *u = &msg->unknown_fields[i];
        ds_rfcs_unknown_field_t uf;
        uf.number  = u->tag;
        uf.wire    = (uint32_t)u->wire_type;
        uf.depth   = depth;
        uf.message = desc->short_name;
        uf.p       = u->data;
        uf.len     = u->len;
        if (!w->on_unknown(w->ctx, &uf))
            w->stopped = true;
    }

    if (!w->stopped) {
        f.kind = DS_RFCS_FIELD_LEAVE;
        emit(w, &f);
    }
    return DS_OK_R;
}

/* Depth counts as `visit_message` counts it. NEST_UNFRAMED: the bytes do not frame as
   protobuf fields, so the body is refused rather than handed to an unpack that might
   recurse into it. A field the descriptor does not name is one protobuf-c does not
   recurse into. */
typedef enum { NEST_OK, NEST_DEEP, NEST_UNFRAMED } nest_t;

static nest_t nests_too_deep(const ProtobufCMessageDescriptor *desc,
                             const uint8_t *msg, size_t len, uint32_t depth)
{
    if (depth > DS_RFCS_VISIT_MAX_DEPTH)
        return NEST_DEEP;
    size_t pos = 0;
    while (pos < len) {
        ds_pbf_field_t f;
        if (ds_pbf_next_field(msg, len, pos, &f) != DS_PBF_OK)
            return NEST_UNFRAMED;
        if (f.wire == 2u) {
            const ProtobufCFieldDescriptor *fd =
                protobuf_c_message_descriptor_get_field(desc, f.field);
            if (fd != NULL && fd->type == PROTOBUF_C_TYPE_MESSAGE) {
                nest_t n = nests_too_deep(
                    (const ProtobufCMessageDescriptor *)fd->descriptor,
                    f.val, f.val_len, depth + 1u);
                if (n != NEST_OK)
                    return n;
            }
        }
        pos = f.next;
    }
    return NEST_OK;
}

ds_result_t ds_rfcs_visit_atom(uint32_t atom,
                               const uint8_t *body, size_t len,
                               ds_rfcs_field_fn fn, void *ctx)
{
    return ds_rfcs_visit_atom_with_unknown(atom, body, len, fn, NULL, ctx);
}

ds_result_t ds_rfcs_visit_atom_with_unknown(uint32_t atom,
                                            const uint8_t *body, size_t len,
                                            ds_rfcs_field_fn fn,
                                            ds_rfcs_unknown_fn on_unknown,
                                            void *ctx)
{
    static const uint8_t empty[1] = { 0 };

    if (!fn || (!body && len > 0))
        return DS_ERR_R(DS_ERR_INVAL, "ds_rfcs_visit_atom: NULL arg");

    const ds_atom_reg_entry_t *e = ds_pbf_lookup(atom);
    if (!e)
        return DS_ERR_R(DS_ERR_NOT_FOUND,
                        "ds_rfcs_visit_atom: no registry entry for this field number");
    const ProtobufCMessageDescriptor *desc =
        ds_atom_descriptors[e - ds_atom_registry];

    switch (nests_too_deep(desc, body ? body : empty, len, 0u)) {
    case NEST_OK:
        break;
    case NEST_DEEP:
        return DS_ERR_R(DS_ERR_PARSE,
                        "ds_rfcs_visit_atom: nesting exceeds DS_RFCS_VISIT_MAX_DEPTH");
    case NEST_UNFRAMED:
        return DS_ERR_R(DS_ERR_PARSE,
                        "ds_rfcs_visit_atom: the body does not unpack as its message");
    }

    ProtobufCMessage *msg = protobuf_c_message_unpack(
        desc, &ds_pb_allocator, len, body ? body : empty);
    if (!msg)
        return DS_ERR_R(DS_ERR_PARSE,
                        "ds_rfcs_visit_atom: the body does not unpack as its message");

    walk_t w = { fn, on_unknown, ctx, false };
    ds_result_t r = visit_message(&w, msg, NULL, 0, -1, 0);
    protobuf_c_message_free_unpacked(msg, &ds_pb_allocator);
    return r;
}

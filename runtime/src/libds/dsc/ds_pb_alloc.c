/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * dsc/ds_pb_alloc.c — the libds protobuf-c allocator ([IALC.3.1]). No hand-written
 * call site passes a NULL allocator ([IALC.9.2]).
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ds_alloc.h"
#include "ds_pb_alloc.h"
#include "ds_text.h"

static void *ds_pb_alloc(void *allocator_data, size_t size)
{
    (void) allocator_data;
    return DS_MALLOC(size);
}

static void ds_pb_free(void *allocator_data, void *pointer)
{
    (void) allocator_data;
    DS_FREE(pointer);
}

/* Not `const`: the generated entry points take a `ProtobufCAllocator *`.
   protobuf-c never writes it. */
ProtobufCAllocator ds_pb_allocator = {
    ds_pb_alloc,
    ds_pb_free,
    NULL,
};

/* ---- [RDSC.11.4]: a body judged before it is unpacked ---- */

/* False when the bytes end first, past ten bytes, or a tenth byte past bit 63. */
static bool rdsc_9_5_varint(const uint8_t *p, size_t len, size_t *pos,
                            uint64_t *out)
{
    uint64_t acc = 0;
    for (unsigned group = 0; group < 10u; group++) {
        if (*pos >= len) return false;
        const uint8_t b = p[(*pos)++];
        if (group == 9u && (b & 0x7Fu) > 1u) return false;
        acc |= (uint64_t)(b & 0x7Fu) << (7u * group);
        if ((b & 0x80u) == 0) {
            *out = acc;
            return true;
        }
    }
    return false;
}

/* A bound on the walk's own recursion, for a caller that bounds no nested
   message. A subtree past it is not read. */
#define PB_MAX_NESTING 512u

/* No DS message has this many fields; one that did is refused. */
#define PB_MAX_FIELDS 256u

typedef struct {
    const ProtobufCMessageDescriptor *nested;   /* Expr, or NULL for no bound */
    int                               limit;
    bool                              too_deep; /* a subtree was not read */
} pb_judge_ctx_t;

/* The wire type protobuf-c's unpack takes a known field's value in. */
static unsigned pb_wire_type(ProtobufCType t)
{
    switch (t) {
    case PROTOBUF_C_TYPE_SFIXED64:
    case PROTOBUF_C_TYPE_FIXED64:
    case PROTOBUF_C_TYPE_DOUBLE:   return 1u;
    case PROTOBUF_C_TYPE_SFIXED32:
    case PROTOBUF_C_TYPE_FIXED32:
    case PROTOBUF_C_TYPE_FLOAT:    return 5u;
    case PROTOBUF_C_TYPE_STRING:
    case PROTOBUF_C_TYPE_BYTES:
    case PROTOBUF_C_TYPE_MESSAGE:  return 2u;
    default:                       return 0u;
    }
}

static bool pb_packed_ok(ProtobufCType t, const uint8_t *p, size_t n)
{
    switch (pb_wire_type(t)) {
    case 0u: {
        size_t   pos = 0;
        uint64_t v   = 0;
        while (pos < n)
            if (!rdsc_9_5_varint(p, n, &pos, &v)) return false;
        return true;
    }
    case 1u: return n % 8u == 0u;
    case 5u: return n % 4u == 0u;
    default: return false;
    }
}

/* [RDSC.9.12], [LSTR.1.1] */
static bool pb_string_ok(const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if (p[i] == 0u) return false;
    return ds_utf8_well_formed((const char *) p, n) != 0;
}

/* `expr_depth` is the depth of the nearest enclosing bounded message, -1
   outside every one, so the outermost Expr is depth 0 ([RDSC.11.3]). */
static ds_pb_judge_t pb_walk(const ProtobufCMessageDescriptor *desc,
                             const uint8_t *p, size_t len, int expr_depth,
                             unsigned nesting, pb_judge_ctx_t *ctx)
{
    /* Bit i: the message field at desc->fields[i] has occurred once. */
    uint64_t seen[PB_MAX_FIELDS / 64u] = { 0 };
    size_t   pos = 0;

    while (pos < len) {
        uint64_t       key = 0, n = 0;
        const uint8_t *val = NULL;
        if (!rdsc_9_5_varint(p, len, &pos, &key)) return DS_PB_JUDGE_UNDECODABLE;
        const unsigned wt = (unsigned)(key & 7u);
        if ((key >> 3) > UINT32_MAX) return DS_PB_JUDGE_UNDECODABLE;
        switch (wt) {
        case 0u:
            if (!rdsc_9_5_varint(p, len, &pos, &n)) return DS_PB_JUDGE_UNDECODABLE;
            break;
        case 1u:
            if (len - pos < 8u) return DS_PB_JUDGE_UNDECODABLE;
            pos += 8u;
            break;
        case 5u:
            if (len - pos < 4u) return DS_PB_JUDGE_UNDECODABLE;
            pos += 4u;
            break;
        case 2u:
            if (!rdsc_9_5_varint(p, len, &pos, &n) || n > 0x7FFFFFFFu
                    || n > (uint64_t)(len - pos))
                return DS_PB_JUDGE_UNDECODABLE;
            val  = p + pos;
            pos += (size_t)n;
            break;
        default:
            return DS_PB_JUDGE_UNDECODABLE;
        }

        const ProtobufCFieldDescriptor *fd =
            protobuf_c_message_descriptor_get_field(desc, (unsigned)(key >> 3));
        if (fd == NULL) continue;
        const unsigned want = pb_wire_type(fd->type);
        if (wt != want) {
            if (fd->label == PROTOBUF_C_LABEL_REPEATED && wt == 2u && want != 2u
                    && pb_packed_ok(fd->type, val, (size_t)n))
                continue;
            return DS_PB_JUDGE_UNDECODABLE;
        }
        if (fd->type == PROTOBUF_C_TYPE_STRING) {
            if (!pb_string_ok(val, (size_t)n)) return DS_PB_JUDGE_BAD_STRING;
            continue;
        }
        if (fd->type != PROTOBUF_C_TYPE_MESSAGE) continue;

        /* [RDSC.9.5]: from the tags alone, so for an Expr past the limit too. */
        if (fd->label != PROTOBUF_C_LABEL_REPEATED) {
            const size_t i = (size_t)(fd - desc->fields);
            if (i >= PB_MAX_FIELDS) return DS_PB_JUDGE_REPEATED;
            const uint64_t bit = (uint64_t)1 << (i % 64u);
            if ((seen[i / 64u] & bit) != 0u) return DS_PB_JUDGE_REPEATED;
            seen[i / 64u] |= bit;
        }

        const ProtobufCMessageDescriptor *sub =
            (const ProtobufCMessageDescriptor *)fd->descriptor;
        int depth = expr_depth;
        if (ctx->nested != NULL && sub == ctx->nested) {
            depth = expr_depth + 1;
            if (depth > ctx->limit) {
                ctx->too_deep = true;
                continue;
            }
        }
        if (nesting >= PB_MAX_NESTING) {
            ctx->too_deep = true;
            continue;
        }
        const ds_pb_judge_t r =
            pb_walk(sub, val, (size_t)n, depth, nesting + 1u, ctx);
        if (r != DS_PB_JUDGE_DECODES) return r;
    }
    return DS_PB_JUDGE_DECODES;
}

ds_pb_judge_t ds_pb_rdsc_11_4_judge(const ProtobufCMessageDescriptor *desc,
                                    const ProtobufCMessageDescriptor *nested,
                                    unsigned limit,
                                    const uint8_t *body, size_t len)
{
    if (desc == NULL || (body == NULL && len > 0))
        return DS_PB_JUDGE_UNDECODABLE;
    pb_judge_ctx_t ctx = { nested, (int) limit, false };
    const ds_pb_judge_t r = pb_walk(desc, body, len, -1, 0u, &ctx);
    if (r != DS_PB_JUDGE_DECODES) return r;
    return ctx.too_deep ? DS_PB_JUDGE_TOO_DEEP : DS_PB_JUDGE_DECODES;
}

bool ds_pb_rdsc_9_5_repeats(const ProtobufCMessageDescriptor *desc,
                            const uint8_t *body, size_t len)
{
    return ds_pb_rdsc_11_4_judge(desc, NULL, 0u, body, len)
        == DS_PB_JUDGE_REPEATED;
}

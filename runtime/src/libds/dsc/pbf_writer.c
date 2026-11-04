/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
#include "pbf_writer.h"

#include <string.h>

#define WIRE_LEN 2u

/* `repeated Atom atoms = 1`: (1 << 3) | 2. */
#define OUTER_TAG 0x0Au

static size_t varint_size(uint64_t v)
{
    size_t n = 1;
    while (v >= 0x80u) {
        v >>= 7;
        n++;
    }
    return n;
}

static size_t write_varint(uint8_t *out, uint64_t v)
{
    size_t i = 0;
    do {
        uint8_t b = (uint8_t)(v & 0x7Fu);
        v >>= 7;
        out[i++] = (uint8_t)(b | (v ? 0x80u : 0u));
    } while (v);
    return i;
}

static size_t inner_size(uint32_t field, size_t body_size)
{
    return varint_size(((uint64_t)field << 3) | WIRE_LEN)
         + varint_size((uint64_t)body_size)
         + body_size;
}

size_t ds_pbf_prefix_size(uint32_t field, size_t body_size)
{
    size_t inner;
    if (ds_pbf_lookup(field) == NULL) {
        return 0;
    }
    inner = inner_size(field, body_size);
    return 1u + varint_size((uint64_t)inner) + (inner - body_size);
}

size_t ds_pbf_framed_size(uint32_t field, size_t body_size)
{
    size_t prefix = ds_pbf_prefix_size(field, body_size);
    return (prefix == 0) ? 0 : prefix + body_size;
}

bool ds_pbf_write_prefix(uint32_t field, size_t body_size,
                         uint8_t *out, size_t out_cap,
                         size_t *prefix_len, size_t *total_len)
{
    size_t prefix = ds_pbf_prefix_size(field, body_size);
    size_t inner;
    size_t i;

    if (prefix == 0) {
        if (prefix_len) *prefix_len = 0;
        if (total_len)  *total_len = 0;
        return false;
    }

    if (prefix_len) *prefix_len = prefix;
    if (total_len)  *total_len = prefix + body_size;

    if (out == NULL || out_cap < prefix + body_size) {
        return false;
    }

    inner = inner_size(field, body_size);
    i = 0;
    out[i++] = OUTER_TAG;
    i += write_varint(out + i, (uint64_t)inner);
    i += write_varint(out + i, ((uint64_t)field << 3) | WIRE_LEN);
    i += write_varint(out + i, (uint64_t)body_size);
    return i == prefix;
}

bool ds_pbf_frame_atom(uint32_t field, const uint8_t *body, size_t body_len,
                       uint8_t *out, size_t out_cap, size_t *total_len)
{
    size_t prefix = 0;
    if (!ds_pbf_write_prefix(field, body_len, out, out_cap, &prefix, total_len)) {
        return false;
    }
    if (body_len != 0) {
        if (body == NULL) {
            return false;
        }
        memcpy(out + prefix, body, body_len);
    }
    return true;
}

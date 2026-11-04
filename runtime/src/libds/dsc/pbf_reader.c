/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The protobuf-native atom reader. Hand-parsed ([RFCS.18.8]): a number's band
 * decides, where protobuf would keep an unknown atom in the inject band.
 */
#include "pbf_reader.h"

/* ------------------------------------------------------------------ */
/*  varint                                                             */
/* ------------------------------------------------------------------ */

/*
 * The bytes consumed, or 0 ([RDSC.11.1]): a buffer that ended mid-varint is a short
 * read ([RFCS.19.2]); ten continuing bytes, or a tenth past bit 63, sets `*overlong`.
 */
static size_t read_varint(const uint8_t *buf, size_t len, size_t pos,
                          uint64_t *out, bool *overlong)
{
    uint64_t v = 0;
    unsigned shift = 0;
    size_t   i = pos;

    *overlong = false;
    while (i < len) {
        uint8_t b = buf[i++];
        if (shift == 63u && (b & 0x7Fu) > 1u) {
            *overlong = true;
            return 0;
        }
        v |= (uint64_t)(b & 0x7Fu) << shift;
        if ((b & 0x80u) == 0) {
            *out = v;
            return i - pos;
        }
        shift += 7u;
        if (shift >= 70u) {
            *overlong = true;
            return 0;
        }
    }
    return 0;
}

static ds_pbf_step_t unread_varint(bool overlong)
{
    return overlong ? DS_PBF_MALFORMED : DS_PBF_EOF;
}

/* ------------------------------------------------------------------ */
/*  Framing                                                            */
/* ------------------------------------------------------------------ */

#define WIRE_VARINT  0u
#define WIRE_64BIT   1u
#define WIRE_LEN     2u
#define WIRE_SGROUP  3u
#define WIRE_EGROUP  4u
#define WIRE_32BIT   5u

ds_pbf_step_t ds_pbf_next_field(const uint8_t *msg, size_t len, size_t pos,
                                ds_pbf_field_t *out)
{
    uint64_t key = 0;
    size_t   n;
    bool     overlong = false;

    if (msg == NULL || out == NULL || pos >= len) {
        return DS_PBF_EOF;
    }
    n = read_varint(msg, len, pos, &key, &overlong);
    if (n == 0) {
        return unread_varint(overlong);
    }
    pos += n;

    /* Narrowing would alias it onto a real field. */
    if ((key >> 3) > (uint64_t)UINT32_MAX) {
        return DS_PBF_MALFORMED;
    }
    out->field   = (uint32_t)(key >> 3);
    out->wire    = (uint32_t)(key & 0x7u);
    out->val     = NULL;
    out->val_len = 0;
    out->u64     = 0;

    /* Not a field, and a run of 0x00 would otherwise scan as empty varints. */
    if (out->field == 0u) {
        return DS_PBF_MALFORMED;
    }

    switch (out->wire) {
    case WIRE_LEN: {
        uint64_t vlen = 0;
        n = read_varint(msg, len, pos, &vlen, &overlong);
        if (n == 0) {
            return unread_varint(overlong);
        }
        pos += n;
        /* Against the remaining bytes: `pos + vlen` could wrap. */
        if (vlen > (uint64_t)(len - pos)) {
            return DS_PBF_EOF;
        }
        out->val     = msg + pos;
        out->val_len = (size_t)vlen;
        out->next    = pos + (size_t)vlen;
        return DS_PBF_OK;
    }
    case WIRE_VARINT: {
        uint64_t v = 0;
        n = read_varint(msg, len, pos, &v, &overlong);
        if (n == 0) {
            return unread_varint(overlong);
        }
        out->u64  = v;
        out->next = pos + n;
        return DS_PBF_OK;
    }
    case WIRE_64BIT:
        if ((len - pos) < 8u) {
            return DS_PBF_EOF;
        }
        for (unsigned i = 0; i < 8u; i++)
            out->u64 |= (uint64_t)msg[pos + i] << (8u * i);
        out->next = pos + 8u;
        return DS_PBF_OK;
    case WIRE_32BIT:
        if ((len - pos) < 4u) {
            return DS_PBF_EOF;
        }
        for (unsigned i = 0; i < 4u; i++)
            out->u64 |= (uint64_t)msg[pos + i] << (8u * i);
        out->next = pos + 4u;
        return DS_PBF_OK;
    case WIRE_SGROUP:
    case WIRE_EGROUP:
    default:
        return DS_PBF_MALFORMED;
    }
}

/* After a complete frame's Atom yielded EOF ([RDSC.11.1]): a field that ran past the
   frame, a body that ends early, rather than a tag saying it is no sub-message. */
static bool inner_runs_short(const uint8_t *atom, size_t atom_len)
{
    uint64_t key = 0;
    bool     overlong = false;

    if (read_varint(atom, atom_len, 0, &key, &overlong) == 0) {
        return !overlong;
    }
    return (key & 0x7u) == WIRE_LEN;
}

ds_pbf_step_t ds_pbf_next_atom(const uint8_t *data, size_t len, size_t pos,
                               ds_pbf_atom_t *out)
{
    ds_pbf_field_t outer;
    ds_pbf_field_t inner;
    ds_pbf_step_t  st;

    if (out == NULL) {
        return DS_PBF_MALFORMED;
    }
    out->short_body = false;
    /* [RDSC.11.1]: judged before any varint is read, so a trailing 0xFF is
       malformed rather than a varint still arriving. */
    if (data != NULL && pos < len && data[pos] != 0x0Au) {
        return DS_PBF_MALFORMED;
    }
    st = ds_pbf_next_field(data, len, pos, &outer);
    if (st != DS_PBF_OK) {
        return st;
    }
    /* [RFCS.19.1]: `repeated Atom atoms = 1`. */
    if (outer.field != 1u || outer.wire != WIRE_LEN) {
        return DS_PBF_MALFORMED;
    }

    out->atom     = outer.val;
    out->atom_len = outer.val_len;
    out->next     = outer.next;

    /* The frame is complete, so a short or bad inner message is malformed, not
       truncation. An empty Atom has no identity ([RFCS.19.3]). */
    if (outer.val_len == 0) {
        return DS_PBF_MALFORMED;
    }
    st = ds_pbf_next_field(outer.val, outer.val_len, 0, &inner);
    if (st == DS_PBF_EOF) {
        out->short_body = inner_runs_short(outer.val, outer.val_len);
        return DS_PBF_MALFORMED;
    }
    if (st != DS_PBF_OK) {
        return st;
    }
    /* Every registry body is a sub-message ([RFCS.16.1]). */
    if (inner.wire != WIRE_LEN) {
        return DS_PBF_MALFORMED;
    }

    out->field    = inner.field;
    out->body     = inner.val;
    out->body_len = inner.val_len;
    return DS_PBF_OK;
}

ds_pbf_container_t ds_pbf_container_of(const uint8_t *data, size_t len)
{
    ds_pbf_atom_t first;

    if (ds_pbf_next_atom(data, len, 0, &first) != DS_PBF_OK) {
        return DS_PBF_CONTAINER_UNKNOWN;
    }
    if (first.field == DS_ATOM_STREAM_HEADER) {
        return DS_PBF_CONTAINER_STREAM;
    }
    if (first.field == DS_ATOM_DSC_HEADER) {
        return DS_PBF_CONTAINER_DSC;
    }
    return DS_PBF_CONTAINER_UNKNOWN;
}

/* ------------------------------------------------------------------ */
/*  Band adjudication                                                  */
/* ------------------------------------------------------------------ */

ds_atom_band_t ds_pbf_band(uint32_t field)
{
    /* [RFCS.16.2]: from the number alone. */
    if (field >= DS_ATOM_BAND_INJECT_LO && field <= DS_ATOM_BAND_INJECT_HI) {
        return DS_ATOM_BAND_INJECT;
    }
    if (field >= DS_ATOM_BAND_REJECT_LO && field <= DS_ATOM_BAND_REJECT_HI) {
        return DS_ATOM_BAND_REJECT;
    }
    if (field >= DS_ATOM_BAND_SKIP_LO && field <= DS_ATOM_BAND_SKIP_HI) {
        return DS_ATOM_BAND_SKIP;
    }
    /* [RFCS.16.5]: above 2047 or zero. */
    return DS_ATOM_BAND_NONE;
}

const ds_atom_reg_entry_t *ds_pbf_lookup(uint32_t field)
{
    size_t lo = 0;
    size_t hi = DS_ATOM_REGISTRY_COUNT;

    while (lo < hi) {
        size_t   mid = lo + (hi - lo) / 2u;
        uint32_t n   = ds_atom_registry[mid].number;
        if (n == field) {
            return &ds_atom_registry[mid];
        }
        if (n < field) {
            lo = mid + 1u;
        } else {
            hi = mid;
        }
    }
    return NULL;
}

ds_pbf_disposition_t ds_pbf_disposition(uint32_t field)
{
    if (ds_pbf_lookup(field) != NULL) {
        return DS_PBF_DISP_SKIP;
    }
    switch (ds_pbf_band(field)) {
    case DS_ATOM_BAND_INJECT: return DS_PBF_DISP_REJECT_INJECT;
    case DS_ATOM_BAND_REJECT: return DS_PBF_DISP_REJECT_VERSION;
    case DS_ATOM_BAND_SKIP:   return DS_PBF_DISP_SKIP;
    case DS_ATOM_BAND_NONE:
    default:                  return DS_PBF_DISP_MALFORMED;
    }
}

/* reject-inject, a dropped input, outranks reject-version. Not the enum's order. */
static int severity(ds_pbf_disposition_t d)
{
    switch (d) {
    case DS_PBF_DISP_SKIP:           return 0;
    case DS_PBF_DISP_REJECT_VERSION: return 1;
    case DS_PBF_DISP_REJECT_INJECT:  return 2;
    case DS_PBF_DISP_MALFORMED:      return 3;
    default:                         return 3;
    }
}

static ds_pbf_disposition_t worse(ds_pbf_disposition_t a, ds_pbf_disposition_t b)
{
    return (severity(a) >= severity(b)) ? a : b;
}

ds_pbf_disposition_t ds_pbf_atom_backstop(const uint8_t *atom, size_t atom_len)
{
    ds_pbf_disposition_t acc = DS_PBF_DISP_SKIP;
    size_t               pos = 0;

    if (atom == NULL) {
        return DS_PBF_DISP_MALFORMED;
    }
    for (;;) {
        ds_pbf_field_t f;
        ds_pbf_step_t  st = ds_pbf_next_field(atom, atom_len, pos, &f);
        if (st == DS_PBF_EOF) {
            return acc;
        }
        if (st != DS_PBF_OK) {
            return DS_PBF_DISP_MALFORMED;
        }
        acc = worse(acc, ds_pbf_disposition(f.field));
        pos = f.next;
    }
}

/* ------------------------------------------------------------------ */
/*  Container legality and replay class                                */
/* ------------------------------------------------------------------ */

bool ds_pbf_legal_in(uint32_t field, ds_pbf_container_t container)
{
    const ds_atom_reg_entry_t *e = ds_pbf_lookup(field);
    if (e == NULL) {
        return false;
    }
    switch (container) {
    case DS_PBF_CONTAINER_DSC:    return (e->legality & DS_ATOM_LEGAL_DSC) != 0u;
    case DS_PBF_CONTAINER_STREAM: return (e->legality & DS_ATOM_LEGAL_STREAM) != 0u;
    case DS_PBF_CONTAINER_UNKNOWN:
    default:                      return false;
    }
}

ds_atom_class_t ds_pbf_stream_class(uint32_t field)
{
    const ds_atom_reg_entry_t *e = ds_pbf_lookup(field);
    return (e == NULL) ? DS_ATOM_CLASS_NONE : (ds_atom_class_t)e->klass;
}

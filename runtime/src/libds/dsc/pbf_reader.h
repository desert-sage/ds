/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The protobuf-native atom reader ([RFCS.16]-[RFCS.19]).
 *
 * Self-contained: it includes nothing from libds, so its test compiles it directly
 * with `cc`. A pure parser speaks dispositions, and the caller maps them to codes.
 */
#ifndef DS_DSC_PBF_READER_H
#define DS_DSC_PBF_READER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "atom_registry.h"

/* ------------------------------------------------------------------ */
/*  Step results                                                       */
/* ------------------------------------------------------------------ */

/*
 * [RFCS.19.2]: DS_PBF_EOF is a clean end or a partial trailing atom, since a
 * recording is appended to while it is written. DS_PBF_MALFORMED is bytes that cannot
 * be a container however many more arrive ([RDSC.11.1]).
 */
typedef enum {
    DS_PBF_OK        = 0,
    DS_PBF_EOF       = 1,
    DS_PBF_MALFORMED = 2
} ds_pbf_step_t;

/*
 * What a reader must do with a field number it has no table entry for
 * ([RFCS.16.2], [RFCS.16.3]), from the number's band alone.
 *
 *   DS_PBF_DISP_SKIP           -> DS_OK, log info ([RDSC.9.4])
 *   DS_PBF_DISP_REJECT_INJECT  -> DS_ERR_FS_UNKNOWN_INJECT
 *   DS_PBF_DISP_REJECT_VERSION -> DS_ERR_DSC_VERSION
 *   DS_PBF_DISP_MALFORMED      -> a malformed frame ([RDSC.11.1]):
 *                                 DS_ERR_DSC_DECODE after the first,
 *                                 DS_ERR_DSC_BAD_MAGIC as the first
 */
typedef enum {
    DS_PBF_DISP_SKIP           = 0,
    DS_PBF_DISP_REJECT_INJECT  = 1,
    DS_PBF_DISP_REJECT_VERSION = 2,
    DS_PBF_DISP_MALFORMED      = 3   /* outside 1..2047 */
} ds_pbf_disposition_t;

/* ------------------------------------------------------------------ */
/*  Framing                                                            */
/* ------------------------------------------------------------------ */

/* `val`/`val_len` are set only for wire type 2. `u64` is the other wire types' value:
   the varint as read, or the fixed value little-endian. */
typedef struct {
    uint32_t       field;     /* key >> 3 */
    uint32_t       wire;      /* key & 7 */
    const uint8_t *val;       /* length-delimited payload, or NULL */
    size_t         val_len;
    size_t         next;      /* offset just past this field */
    uint64_t       u64;
} ds_pbf_field_t;

/* One framed atom ([RFCS.19.1]):
 *
 *     outer:  0x0A varint(len)          the container's `repeated Atom atoms = 1`
 *     inner:  tag(N) varint(len) body   N is the atom's oneof field number
 *
 * `atom`/`atom_len` are the whole inner `Atom`, for [RFCS.18.8]'s backstop.
 */
typedef struct {
    uint32_t       field;
    const uint8_t *body;
    size_t         body_len;
    const uint8_t *atom;      /* the whole inner Atom message */
    size_t         atom_len;
    size_t         next;      /* offset of the following outer frame */
    bool           short_body; /* with DS_PBF_MALFORMED alone: the frame is
                                  complete and its Atom's field runs past it, a
                                  body that ends early ([RDSC.11.1]) */
} ds_pbf_atom_t;

/* Which container this is, from its first atom's field number ([RFCS.19.4]). */
typedef enum {
    DS_PBF_CONTAINER_UNKNOWN = 0,
    DS_PBF_CONTAINER_STREAM  = 1,
    DS_PBF_CONTAINER_DSC     = 2
} ds_pbf_container_t;

ds_pbf_step_t ds_pbf_next_field(const uint8_t *msg, size_t len, size_t pos,
                                ds_pbf_field_t *out);

ds_pbf_step_t ds_pbf_next_atom(const uint8_t *data, size_t len, size_t pos,
                               ds_pbf_atom_t *out);

ds_pbf_container_t ds_pbf_container_of(const uint8_t *data, size_t len);

/* ------------------------------------------------------------------ */
/*  Band adjudication                                                  */
/* ------------------------------------------------------------------ */

ds_atom_band_t ds_pbf_band(uint32_t field);

/* NULL if this reader has no entry for the field. */
const ds_atom_reg_entry_t *ds_pbf_lookup(uint32_t field);

/* DS_PBF_DISP_SKIP for anything this reader knows, otherwise its band's blind
   disposition ([RFCS.16.3]). Not a dispatch decision: ask `ds_pbf_lookup` first. */
ds_pbf_disposition_t ds_pbf_disposition(uint32_t field);

/* [RFCS.18.8]: the worst disposition over every field in one inner `Atom`, since a
 * second, unknown field in the inject band is a dropped input. MALFORMED if the
 * message does not parse.
 */
ds_pbf_disposition_t ds_pbf_atom_backstop(const uint8_t *atom, size_t atom_len);

/* ------------------------------------------------------------------ */
/*  Container legality and replay class                                */
/* ------------------------------------------------------------------ */

/* [RFCS.17.3]. An unknown atom cannot make this diagnosis; its band governs. */
bool ds_pbf_legal_in(uint32_t field, ds_pbf_container_t container);

/* [RFCS.17.5], [RFCS.3.4]. DS_ATOM_CLASS_NONE for an atom that is not stream-legal or
   not known. */
ds_atom_class_t ds_pbf_stream_class(uint32_t field);

#endif /* DS_DSC_PBF_READER_H */

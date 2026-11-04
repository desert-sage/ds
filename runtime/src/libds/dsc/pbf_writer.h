/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The writer-side framing, the inverse of `pbf_reader.h`, and self-contained as it
 * is.
 *
 * The prefix is not fixed width, so a caller asks its size before it packs the body
 * in place.
 */
#ifndef DS_DSC_PBF_WRITER_H
#define DS_DSC_PBF_WRITER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "pbf_reader.h"

/* The two-level frame prefix's size. 0 if `field` is not an allocated atom. */
size_t ds_pbf_prefix_size(uint32_t field, size_t body_size);

/* prefix + body. 0 if `field` is not allocated. */
size_t ds_pbf_framed_size(uint32_t field, size_t body_size);

/*
 * `*prefix_len` and `*total_len` are set whenever the field is allocated, so a caller
 * can size a buffer from a failed call.
 *
 * False if `field` is unallocated, `out` is NULL, or `out_cap` is too small for prefix
 * + body. The body counts: a truncated atom is EOF to a reader ([RFCS.19.2]).
 */
bool ds_pbf_write_prefix(uint32_t field, size_t body_size,
                         uint8_t *out, size_t out_cap,
                         size_t *prefix_len, size_t *total_len);

/* For a caller already holding the packed body. */
bool ds_pbf_frame_atom(uint32_t field, const uint8_t *body, size_t body_len,
                       uint8_t *out, size_t out_cap, size_t *total_len);

#endif /* DS_DSC_PBF_WRITER_H */

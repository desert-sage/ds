/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * GENERATED — do not edit; regenerate it. A drift check fails if this
 * file and its source have drifted apart.
 *
 * Source: specs/conformance/PBF_FRAMING_VECTORS.json — the one
 * home for the format_major 3 byte vectors ([F.*], ratified 2026-08-04).
 * The Python harness reads that file directly; this rendering exists so
 * the C tests need no JSON parser.
 *
 * These are CONFORMANCE vectors, not unit fixtures. They say what any
 * implementation must do, so a test that walks them is checking the
 * contract rather than adding coverage of ours.
 */
#ifndef DS_PBF_VECTORS_H
#define DS_PBF_VECTORS_H

#include "pbf_reader.h"

/* ---- encode ([RFCS.19.1], [RFCS.16.1]) ---------------------------- */
/*
 * framed = prefix ++ body. `prefix` is everything before the body, which
 * is exactly what `ds_pbf_prefix_size` returns and why it is a separate
 * quantity: a major-3 prefix is variable-width, so a caller must be able
 * to ask its size before packing.
 *
 * `is_fill` rows carry no literal body — `body_len` bytes of `fill`. The
 * length-varint boundary cases run to 16 KB and the body's CONTENT never
 * reaches the prefix; only its length does.
 */
typedef struct {
    const char    *name;
    uint32_t       field;
    const char    *atom;       /* the body message, e.g. "FactAssert" */
    const uint8_t *prefix;
    size_t         prefix_len;
    const uint8_t *body;       /* NULL when is_fill */
    size_t         body_len;
    int            is_fill;
    uint8_t        fill;
} ds_pbf_vec_encode_t;

static const uint8_t vec_prefix_fact_assert_empty[] = { 0x0A, 0x02, 0x0A, 0x00 };
static const uint8_t vec_prefix_fact_retract_empty[] = { 0x0A, 0x02, 0x12, 0x00 };
static const uint8_t vec_prefix_clock_advance_empty[] = { 0x0A, 0x02, 0x1A, 0x00 };
static const uint8_t vec_prefix_realtime_contract_empty[] = { 0x0A, 0x03, 0x82, 0x08, 0x00 };
static const uint8_t vec_prefix_series_backend_interval_pulse_empty[] = { 0x0A, 0x03, 0x8A, 0x08, 0x00 };
static const uint8_t vec_prefix_schema_def_empty[] = { 0x0A, 0x03, 0x82, 0x10, 0x00 };
static const uint8_t vec_prefix_stream_header_empty[] = { 0x0A, 0x03, 0x92, 0x10, 0x00 };
static const uint8_t vec_prefix_dsc_header_empty[] = { 0x0A, 0x03, 0xBA, 0x10, 0x00 };
static const uint8_t vec_prefix_alpha_node_empty[] = { 0x0A, 0x03, 0xE2, 0x10, 0x00 };
static const uint8_t vec_prefix_computation_error_empty[] = { 0x0A, 0x03, 0xAA, 0x14, 0x00 };
static const uint8_t vec_prefix_dsc_header_format_major_3[] = { 0x0A, 0x05, 0xBA, 0x10, 0x02 };
static const uint8_t vec_body_dsc_header_format_major_3[] = { 0x08, 0x03 };
static const uint8_t vec_prefix_ds_source_body_1[] = { 0x0A, 0x04, 0xDA, 0x10, 0x01 };
static const uint8_t vec_prefix_ds_source_body_126[] = { 0x0A, 0x81, 0x01, 0xDA, 0x10, 0x7E };
static const uint8_t vec_prefix_ds_source_body_127[] = { 0x0A, 0x82, 0x01, 0xDA, 0x10, 0x7F };
static const uint8_t vec_prefix_ds_source_body_128[] = { 0x0A, 0x84, 0x01, 0xDA, 0x10, 0x80, 0x01 };
static const uint8_t vec_prefix_ds_source_body_16383[] = { 0x0A, 0x83, 0x80, 0x01, 0xDA, 0x10, 0xFF, 0x7F };
static const uint8_t vec_prefix_ds_source_body_16384[] = { 0x0A, 0x85, 0x80, 0x01, 0xDA, 0x10, 0x80, 0x80, 0x01 };

#define DS_PBF_VEC_ENCODE_COUNT 17
static const ds_pbf_vec_encode_t ds_pbf_vec_encode[DS_PBF_VEC_ENCODE_COUNT] = {
    { "fact_assert_empty", 1u, "FactAssert",
      vec_prefix_fact_assert_empty, sizeof vec_prefix_fact_assert_empty,
      NULL, 0u, 0, 0x00 },
    { "fact_retract_empty", 2u, "FactRetract",
      vec_prefix_fact_retract_empty, sizeof vec_prefix_fact_retract_empty,
      NULL, 0u, 0, 0x00 },
    { "clock_advance_empty", 3u, "ClockAdvance",
      vec_prefix_clock_advance_empty, sizeof vec_prefix_clock_advance_empty,
      NULL, 0u, 0, 0x00 },
    { "realtime_contract_empty", 128u, "RealtimeContract",
      vec_prefix_realtime_contract_empty, sizeof vec_prefix_realtime_contract_empty,
      NULL, 0u, 0, 0x00 },
    { "series_backend_interval_pulse_empty", 129u, "SeriesBackendIntervalPulse",
      vec_prefix_series_backend_interval_pulse_empty, sizeof vec_prefix_series_backend_interval_pulse_empty,
      NULL, 0u, 0, 0x00 },
    { "schema_def_empty", 256u, "SchemaDef",
      vec_prefix_schema_def_empty, sizeof vec_prefix_schema_def_empty,
      NULL, 0u, 0, 0x00 },
    { "stream_header_empty", 258u, "StreamHeader",
      vec_prefix_stream_header_empty, sizeof vec_prefix_stream_header_empty,
      NULL, 0u, 0, 0x00 },
    { "dsc_header_empty", 263u, "DscHeader",
      vec_prefix_dsc_header_empty, sizeof vec_prefix_dsc_header_empty,
      NULL, 0u, 0, 0x00 },
    { "alpha_node_empty", 268u, "AlphaNode",
      vec_prefix_alpha_node_empty, sizeof vec_prefix_alpha_node_empty,
      NULL, 0u, 0, 0x00 },
    { "computation_error_empty", 325u, "ComputationError",
      vec_prefix_computation_error_empty, sizeof vec_prefix_computation_error_empty,
      NULL, 0u, 0, 0x00 },
    { "dsc_header_format_major_3", 263u, "DscHeader",
      vec_prefix_dsc_header_format_major_3, sizeof vec_prefix_dsc_header_format_major_3,
      vec_body_dsc_header_format_major_3, 2u, 0, 0x00 },
    { "ds_source_body_1", 267u, "DsSource",
      vec_prefix_ds_source_body_1, sizeof vec_prefix_ds_source_body_1,
      NULL, 1u, 1, 0xA5 },
    { "ds_source_body_126", 267u, "DsSource",
      vec_prefix_ds_source_body_126, sizeof vec_prefix_ds_source_body_126,
      NULL, 126u, 1, 0xA5 },
    { "ds_source_body_127", 267u, "DsSource",
      vec_prefix_ds_source_body_127, sizeof vec_prefix_ds_source_body_127,
      NULL, 127u, 1, 0xA5 },
    { "ds_source_body_128", 267u, "DsSource",
      vec_prefix_ds_source_body_128, sizeof vec_prefix_ds_source_body_128,
      NULL, 128u, 1, 0xA5 },
    { "ds_source_body_16383", 267u, "DsSource",
      vec_prefix_ds_source_body_16383, sizeof vec_prefix_ds_source_body_16383,
      NULL, 16383u, 1, 0xA5 },
    { "ds_source_body_16384", 267u, "DsSource",
      vec_prefix_ds_source_body_16384, sizeof vec_prefix_ds_source_body_16384,
      NULL, 16384u, 1, 0xA5 },
};

/* ---- decode ([RFCS.19.1/19.2/19.3/19.4/19.8]) --------------------- */
/*
 * One container per row, with every verdict a reader owes about it.
 * `terminal` is the step result AFTER the last listed atom — the
 * distinction [RFCS.19.2] exists to make, between a half-written tail
 * (EOF, and every live recording has one) and bytes no further append
 * can rescue (MALFORMED).
 */
typedef struct {
    uint32_t field;
    size_t   body_len;
    size_t   next;
} ds_pbf_vec_atom_t;

typedef struct {
    const char              *name;
    const uint8_t           *data;
    size_t                   len;
    ds_pbf_container_t       container;
    ds_pbf_step_t            terminal;
    const ds_pbf_vec_atom_t *atoms;
    size_t                   atom_count;
} ds_pbf_vec_decode_t;

static const uint8_t vec_data_dsc_header_only[] = { 0x0A, 0x03, 0xBA, 0x10, 0x00 };
static const ds_pbf_vec_atom_t vec_atoms_dsc_header_only[] = { { 263u, 0u, 5u } };
static const uint8_t vec_data_stream_header_then_inject[] = { 0x0A, 0x03, 0x92, 0x10, 0x00, 0x0A, 0x02, 0x1A, 0x00 };
static const ds_pbf_vec_atom_t vec_atoms_stream_header_then_inject[] = { { 258u, 0u, 5u }, { 3u, 0u, 9u } };
static const uint8_t vec_data_two_atoms_dsc[] = { 0x0A, 0x03, 0xBA, 0x10, 0x00, 0x0A, 0x03, 0xE2, 0x10, 0x00 };
static const ds_pbf_vec_atom_t vec_atoms_two_atoms_dsc[] = { { 263u, 0u, 5u }, { 268u, 0u, 10u } };
static const uint8_t vec_data_dsc_header_with_body[] = { 0x0A, 0x05, 0xBA, 0x10, 0x02, 0x08, 0x03 };
static const ds_pbf_vec_atom_t vec_atoms_dsc_header_with_body[] = { { 263u, 2u, 7u } };
static const uint8_t vec_data_truncated_outer_length[] = { 0x0A, 0x03, 0xBA, 0x10, 0x00, 0x0A };
static const ds_pbf_vec_atom_t vec_atoms_truncated_outer_length[] = { { 263u, 0u, 5u } };
static const uint8_t vec_data_truncated_inner_body[] = { 0x0A, 0x05, 0xBA, 0x10, 0x02, 0x08 };
static const uint8_t vec_data_truncated_mid_length_varint[] = { 0x0A, 0x03, 0xBA, 0x10, 0x00, 0x0A, 0x82 };
static const ds_pbf_vec_atom_t vec_atoms_truncated_mid_length_varint[] = { { 263u, 0u, 5u } };
static const uint8_t vec_data_empty_atom_is_malformed[] = { 0x0A, 0x00 };
static const uint8_t vec_data_group_wire_type_is_malformed[] = { 0x0A, 0x02, 0xBB, 0x10 };
static const uint8_t vec_data_field_zero_is_malformed[] = { 0x0A, 0x02, 0x02, 0x00 };
static const uint8_t vec_data_legacy_magic_container[] = { 0x44, 0x53, 0x43, 0x4F, 0x00, 0x00, 0x00, 0x00 };
static const uint8_t vec_data_foreign_bytes[] = { 0xFF, 0x00 };

#define DS_PBF_VEC_DECODE_COUNT 13
static const ds_pbf_vec_decode_t ds_pbf_vec_decode[DS_PBF_VEC_DECODE_COUNT] = {
    { "empty", NULL, 0u,
      DS_PBF_CONTAINER_UNKNOWN, DS_PBF_EOF,
      NULL, 0u },
    { "dsc_header_only", vec_data_dsc_header_only, sizeof vec_data_dsc_header_only,
      DS_PBF_CONTAINER_DSC, DS_PBF_EOF,
      vec_atoms_dsc_header_only, 1u },
    { "stream_header_then_inject", vec_data_stream_header_then_inject, sizeof vec_data_stream_header_then_inject,
      DS_PBF_CONTAINER_STREAM, DS_PBF_EOF,
      vec_atoms_stream_header_then_inject, 2u },
    { "two_atoms_dsc", vec_data_two_atoms_dsc, sizeof vec_data_two_atoms_dsc,
      DS_PBF_CONTAINER_DSC, DS_PBF_EOF,
      vec_atoms_two_atoms_dsc, 2u },
    { "dsc_header_with_body", vec_data_dsc_header_with_body, sizeof vec_data_dsc_header_with_body,
      DS_PBF_CONTAINER_DSC, DS_PBF_EOF,
      vec_atoms_dsc_header_with_body, 1u },
    { "truncated_outer_length", vec_data_truncated_outer_length, sizeof vec_data_truncated_outer_length,
      DS_PBF_CONTAINER_DSC, DS_PBF_EOF,
      vec_atoms_truncated_outer_length, 1u },
    { "truncated_inner_body", vec_data_truncated_inner_body, sizeof vec_data_truncated_inner_body,
      DS_PBF_CONTAINER_UNKNOWN, DS_PBF_EOF,
      NULL, 0u },
    { "truncated_mid_length_varint", vec_data_truncated_mid_length_varint, sizeof vec_data_truncated_mid_length_varint,
      DS_PBF_CONTAINER_DSC, DS_PBF_EOF,
      vec_atoms_truncated_mid_length_varint, 1u },
    { "empty_atom_is_malformed", vec_data_empty_atom_is_malformed, sizeof vec_data_empty_atom_is_malformed,
      DS_PBF_CONTAINER_UNKNOWN, DS_PBF_MALFORMED,
      NULL, 0u },
    { "group_wire_type_is_malformed", vec_data_group_wire_type_is_malformed, sizeof vec_data_group_wire_type_is_malformed,
      DS_PBF_CONTAINER_UNKNOWN, DS_PBF_MALFORMED,
      NULL, 0u },
    { "field_zero_is_malformed", vec_data_field_zero_is_malformed, sizeof vec_data_field_zero_is_malformed,
      DS_PBF_CONTAINER_UNKNOWN, DS_PBF_MALFORMED,
      NULL, 0u },
    { "legacy_magic_container", vec_data_legacy_magic_container, sizeof vec_data_legacy_magic_container,
      DS_PBF_CONTAINER_UNKNOWN, DS_PBF_MALFORMED,
      NULL, 0u },
    { "foreign_bytes", vec_data_foreign_bytes, sizeof vec_data_foreign_bytes,
      DS_PBF_CONTAINER_UNKNOWN, DS_PBF_MALFORMED,
      NULL, 0u },
};

/* No `version` group ([LDET.1.10]): it drove the struck inject-set
 * counter. A stream carries no version of its own, and acceptance is a
 * minor-series prefix on StreamHeader.ds_version. */

#endif /* DS_PBF_VECTORS_H */

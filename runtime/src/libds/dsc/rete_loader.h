/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * dsc/rete_loader.h — DSC to DS Rete network bridge ([RDSC.4a]).
 */
#ifndef LIBDS2_INTERNAL_DSC_RETE_LOADER_H
#define LIBDS2_INTERNAL_DSC_RETE_LOADER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "libds.h"

struct ds_rete_engine;

/* [RDSC.9.10]: a NaN of any payload, read from the bits, so no floating-point
 * operation touches a signalling one. */
static inline bool rdsc_9_10_nan_bits(uint64_t bits)
{
    return ((bits >> 52) & 0x7FFu) == 0x7FFu
        && (bits & 0xFFFFFFFFFFFFFull) != 0u;
}

static inline bool rdsc_9_10_nan(double d)
{
    uint64_t bits;
    memcpy(&bits, &d, sizeof bits);
    return rdsc_9_10_nan_bits(bits);
}

/* Raw atom body blob accumulated during the DSC walk. */
typedef struct {
    const uint8_t *body;
    size_t         len;
    size_t         offset;  /* where the atom's frame begins in the artefact */
} dsc_rete_atom_t;

/*
 * [RDSC.9.5]: a DS_ERR_DSC_DECODE result gains " at offset <N>", and ": <reason>", the
 * first wire error in `body`'s top-level fields, since protobuf-c gives none. Any
 * other result is returned unchanged.
 */
ds_result_t ds_dsc_decode_at_offset(struct ds_rete_engine *re, ds_result_t r,
                                 size_t offset,
                                 const uint8_t *body, size_t len);

/*
 * One AlphaNode body's node_id and schema_name, for [RDSC.8.7]'s check. *out_name is a
 * DS_STRDUP the caller DS_FREEs, "" when the field is absent.
 */
ds_result_t ds_dsc_alfa_schema_name(const uint8_t *body, size_t len,
                                 uint32_t *out_node_id, char **out_name);

/* One TerminalNode body's rule_name, on the same contract. */
ds_result_t ds_dsc_term_rule_name(const uint8_t *body, size_t len,
                                  char **out_name);

typedef enum {
    DSC_RETE_ALPHA,
    DSC_RETE_BETA,
    DSC_RETE_TERMINAL
} dsc_rete_kind_t;

/*
 * One network atom's body decoded in full ([RDSC.8.7]), asked by the walk as the atom
 * arrives: the apply phase's decoder with no engine, so nothing is interned and an
 * action's schema is not resolved.
 */
ds_result_t ds_dsc_rete_body_decodes(dsc_rete_kind_t kind,
                                  const uint8_t *body, size_t len);

typedef struct {
    const char *name;
    int         is_logical; /* 1 = SchemaLogical, 0 = SchemaTtl */
    int64_t     ttl_ns;
    struct {
        const char *name;
        int         val_kind; /* ds_rete_val_kind_t */
        double      tolerance;
        int         sampled;
        int         retained;
    } *slots;
    uint32_t slot_count;
} dsc_rete_schema_desc_t;

/* Decode the network atoms and load them into `re`, where schemas are already
 * registered. */
ds_result_t ds_dsc_apply_rete_network(
    struct ds_rete_engine    *re,
    const dsc_rete_atom_t    *alfas,   uint32_t n_alfas,
    const dsc_rete_atom_t    *betas,   uint32_t n_betas,
    const dsc_rete_atom_t    *terms,   uint32_t n_terms);

#endif /* LIBDS2_INTERNAL_DSC_RETE_LOADER_H */

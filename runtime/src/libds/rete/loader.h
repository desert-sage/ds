/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/loader.h — Rete network loader (IRET.15, RDSC.4a).
 *
 * A node_id is unique across the AlphaNode, BetaNode and TerminalNode atoms of a
 * bundle. Schemas are registered before ds_rete_load_network. The engine owns
 * every node it creates (IRET.20). Expression trees in join tests, actions and
 * the fire guard move into their node, and the loader NULLs each source.
 */
#ifndef LIBDS2_INTERNAL_RETE_LOADER_H
#define LIBDS2_INTERNAL_RETE_LOADER_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "rete/action.h"
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/val.h"

struct ds_rete_engine;

/* ---- Alpha test input ---------------------------------------------- */

typedef struct {
    ds_rete_alpha_test_kind_t kind;
    uint8_t                   slot_index; /* 0..254 ([RDSC.4a.9.1]) */
    ds_rete_cmp_op_t          op;        /* EQ / CMP */
    ds_rete_val_t             literal;   /* EQ / CMP */
    const char               *pattern;  /* REGEX; loader compiles */
} ds_retp_alpha_test_t;

/* ---- AlphaNode atom input ----------------------------------------------- */

typedef struct {
    uint32_t              node_id;       /* globally unique; 0 = invalid */
    const char           *schema_name;
    ds_retp_alpha_test_t *tests;        /* borrowed */
    uint32_t              test_count;
} ds_alfa_atom_t;

/* ---- BetaNode atom input ----------------------------------------------- */

typedef struct {
    uint32_t              node_id;
    uint32_t              right_alpha_id; /* → AlphaNode node_id */
    uint32_t              left_parent_id; /* → BetaNode node_id; 0 = WM root */
    ds_rete_join_test_t  *join_tests;     /* borrowed; the exprs move */
    uint32_t              join_test_count;
    bool                  is_negative;
} ds_beta_atom_t;

/* ---- TerminalNode atom input ----------------------------------------------- */

typedef struct {
    uint32_t              node_id;
    uint32_t              parent_beta_id; /* → BetaNode node_id */
    const char           *rule_name;      /* the rule atoms name it */
    uint32_t              bind_count;
    ds_rete_action_t     *actions;        /* borrowed; the exprs move */
    uint32_t              action_count;
    struct ds_rete_expr  *fire_guard;     /* [RDSC.4a.8.2.1]; NULL when none; moves */
} ds_term_atom_t;

/* ---- Network input -------------------------------------------------- */

typedef struct {
    const ds_alfa_atom_t *alfas;
    uint32_t              alfa_count;
    const ds_beta_atom_t *betas;
    uint32_t              beta_count;
    const ds_term_atom_t *terms;
    uint32_t              term_count;
} ds_rete_network_t;

/* ---- Loader API ----------------------------------------------------- */

/*
 * DS_ERR_RETP_INDEX_OOB for a node_id reference that resolves to no node of its
 * kind; DS_ERR_RETP_INVALID for a node_id 0 or repeated, or a REGEX test with no
 * pattern; DS_ERR_DSC_SEMANTIC for a REGEX that does not compile
 * ([RDSC.4a.6.1]); DS_ERR_SCHEMA_UNKNOWN for an unregistered schema.
 */
ds_result_t ds_rete_load_network(struct ds_rete_engine      *engine,
                                  const ds_rete_network_t    *network);

ds_result_t ds_rete_load(struct ds_rete_engine *engine,
                          const uint8_t         *atom_bytes,
                          size_t                 len);

#endif /* LIBDS2_INTERNAL_RETE_LOADER_H */

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/alpha.h — alpha network: nodes, tests, and per-node fact memory
 * (IRET.6).
 */
#ifndef LIBDS2_INTERNAL_RETE_ALPHA_H
#define LIBDS2_INTERNAL_RETE_ALPHA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libds.h"
#include "oa.h"
#include "rete/fact.h"
#include "rete/schema.h"
#include "rete/val.h"

struct ds_rete_beta_node;
struct ds_rete_eval_ctx;

/* ---- Alpha test (IRET.6.2) ---------------------------------------- */

typedef enum {
    DS_RETE_ALPHA_EQ    = 0,  /* slot[i] == literal */
    DS_RETE_ALPHA_CMP   = 1,  /* slot[i] <op> literal */
    DS_RETE_ALPHA_REGEX = 2,  /* regex_match(slot[i], compiled_regex) */
} ds_rete_alpha_test_kind_t;

typedef enum {
    DS_RETE_CMP_EQ  = 0,
    DS_RETE_CMP_NEQ = 1,
    DS_RETE_CMP_LT  = 2,
    DS_RETE_CMP_GT  = 3,
    DS_RETE_CMP_LTE = 4,
    DS_RETE_CMP_GTE = 5,
} ds_rete_cmp_op_t;

typedef struct {
    ds_rete_alpha_test_kind_t kind;
    uint8_t                   slot_index;  /* 0..254, no marker ([RDSC.4a.9.1]) */
    ds_rete_cmp_op_t          op;          /* for EQ and CMP */
    ds_rete_val_t             literal;     /* for EQ and CMP */
    void                     *compiled_re; /* for REGEX; engine-owned */
    /* The REGEX source pattern, interned: a clone recompiles from it, since the
       node destructor frees `compiled_re`. */
    const char               *pattern;
} ds_rete_alpha_test_t;

/* ---- Alpha memory — hash set of ds_rete_fact_t* (IRET.6.5) -------- */

typedef struct {
    /* Matched facts: key fact->id, value ds_rete_fact_t*. The dense order feeds
       timetag assignment ([IRET.28.10]). oa matches by the stored id, so a stale
       slab-reused pointer cannot false-match a live one. */
    oa_t             map;
} ds_rete_alpha_mem_t;

/* ---- Alpha node (IRET.6.1) ---------------------------------------- */

/* When non-NULL, replaces the interpreter for this node's test. */
typedef bool (*ds_alpha_test_fn)(const struct ds_rete_fact *fact);

/* ---- A matching-time fault's rule name ([LERR.9.11]) --------------- */

/*
 * Stored on the node, not formatted at the raise: a truth-maintenance cascade
 * buffers a fault event by shallow copy (recorder.c, `recorder_defer_push`), so
 * every string it carries must live as long as the engine.
 */
#define DS_RETE_FAULT_RULE_CAP 24u
extern const char ds_rete_fault_rule_engine[];   /* "$engine" */
void ds_rete_fault_rule_name(char out[DS_RETE_FAULT_RULE_CAP], bool alpha,
                             uint32_t node_id);

typedef struct ds_rete_alpha_node {
    uint16_t                    schema_id;
    ds_rete_alpha_test_t       *tests;           /* array; owned */
    uint32_t                    test_count;
    ds_rete_alpha_mem_t         memory;
    struct ds_rete_beta_node  **beta_outputs;    /* array; owned (ptrs borrowed) */
    uint32_t                    beta_output_count;
    uint32_t                    node_id;   /* 0 when not loaded from a DSC */
    char                        fault_rule[DS_RETE_FAULT_RULE_CAP];
    /* A node a fault handler's patterns use ([LERR.9.6]): a fault raised here
     * is recorded and never asserted as a fault fact. */
    bool                        fault_handler;
    ds_alpha_test_fn            alpha_fn;
    uint32_t                    contract_capacity;   /* 0 = no cap */
} ds_rete_alpha_node_t;

/* ---- API ----------------------------------------------------------- */

/* destroy leaves the beta nodes, which the engine owns. */
ds_result_t ds_rete_alpha_node_create(uint16_t               schema_id,
                                       ds_rete_alpha_test_t  *tests,
                                       uint32_t               test_count,
                                       ds_rete_alpha_node_t **out);
void        ds_rete_alpha_node_destroy(ds_rete_alpha_node_t *node);

ds_result_t ds_rete_alpha_add_beta_output(ds_rete_alpha_node_t *alpha,
                                           struct ds_rete_beta_node *beta);

/*
 * True when the fact passes every test (IRET.6.4). `ctx` is the error channel, and
 * NULL does not raise: ds_engine_rete_match_trace is a read-only query ([NDBG]). A
 * literal of the wrong kind fails its test. A slot past the schema, or a REGEX
 * subject that is not a String, raises DS_FAULT_ARTEFACT if no other test answers
 * false ([RDSC.4a.9.1], [RDSC.4a.6.2]).
 */
bool ds_rete_alpha_test_fact(const ds_rete_alpha_node_t *node,
                              const ds_rete_fact_t       *fact,
                              struct ds_rete_eval_ctx    *ctx);

/*
 * (IRET.6.5). insert is DS_ERR_STATE if the fact is present, which dispatch.c tests
 * for; remove is DS_ERR_NOT_FOUND if absent.
 */
ds_result_t ds_rete_alpha_mem_insert(ds_rete_alpha_mem_t *mem,
                                      ds_rete_fact_t      *fact);
ds_result_t ds_rete_alpha_mem_remove(ds_rete_alpha_mem_t *mem,
                                      ds_rete_fact_t      *fact);
bool        ds_rete_alpha_mem_contains(const ds_rete_alpha_mem_t *mem,
                                        const ds_rete_fact_t      *fact);

ds_result_t ds_rete_alpha_mem_presz(ds_rete_alpha_mem_t *mem, size_t cap);

/* Stops early if visitor returns non-zero. */
int ds_rete_alpha_mem_for_each(const ds_rete_alpha_mem_t *mem,
                                int (*visitor)(ds_rete_fact_t *fact,
                                               void           *ctx),
                                void *ctx);

#endif /* LIBDS2_INTERNAL_RETE_ALPHA_H */

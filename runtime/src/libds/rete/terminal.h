/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/terminal.h — terminal node and rule-fire interface (IRET.8).
 *
 * Refraction (IRET.11.3) uses a per-terminal open-addressing hash set; entries
 * from old generations read as absent without a clear.
 */
#ifndef LIBDS2_INTERNAL_RETE_TERMINAL_H
#define LIBDS2_INTERNAL_RETE_TERMINAL_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "oa.h"
#include "rete/action.h"
#include "rete/agenda.h"
#include "rete/token.h"

struct ds_rete_engine;
struct ds_engine;
struct ds_dispatch_t;

/* ---- Refraction entry (IRET.11.3) --------------------------------- */

typedef struct {
    uint32_t  token_hash;
    uint64_t  generation;  /* matches engine->cycle_generation when live */
    uint32_t *fact_ids;    /* the matched token's; heap-owned; NULL when count == 0 */
    uint32_t  fact_count;
} ds_rete_refract_entry_t;

/* ---- Terminal node (IRET.8) --------------------------------------- */

typedef struct ds_rete_terminal {
    const char   *rule_name; /* interned */
    /* [LDET.5.4]: the firing order's outer key, unique per rule, from the order
     * of terminals in the artefact, which is source order ([RLOW.14.3]). */
    uint32_t      ordinal;
    /* From the TerminalNode atom. 0 when not loaded from a DSC. */
    uint32_t      node_id;
    /* [LERR.9.6]: a fault in its activation is never asserted as a fault fact. */
    bool          fault_handler;
    /* [RTCT.7.1]; contract_capacity == 0 means no cap. */
    uint32_t      contract_capacity;
    uint32_t      live_activations;

    /* IRET.10 */
    ds_rete_action_t *actions;
    uint32_t          action_count;
    uint32_t          bind_count;   /* IRET.9.4 */

    /* Owned; NULL when the rule has none ([RDSC.4a.8.2.1]). */
    struct ds_rete_expr *fire_guard;

    /* Fallback hook when action_count == 0. */
    void (*fire_fn)(const char *rule_name, ds_rete_token_t *token,
                    void *ctx);
    void          *fire_ctx;

    /* Takes priority over the actions. */
    void (*rhs_fn)(struct ds_engine      *engine,
                   ds_rete_token_t       *token,
                   const struct ds_dispatch_t *dispatch);

    /* Pending and fired. */
    ds_rete_activation_t *activations;

    /* token* (->hash / tokens_equal) -> activation*. */
    oa_t                     act_map;

    ds_rete_refract_entry_t *refract;
    uint32_t                 refract_cap;
    uint32_t                 refract_n; /* live entries in current generation */

    /* Edge-once for a clock-driven now()/dwell re-eval ([LTIM.2.5.1]): the fact_id
     * of each match whose matured guard has fired. Survives ticks, unlike
     * `refract`. A set, since every retraction clears its id and [LNLS.4.7] makes
     * that O(1) amortized. Only membership is read. */
    oa_t                     oneshot;
} ds_rete_terminal_t;

bool ds_rete_terminal_oneshot_fired(const ds_rete_terminal_t *terminal,
                                    uint32_t fact_id);
ds_result_t ds_rete_terminal_oneshot_mark(ds_rete_terminal_t *terminal,
                                          uint32_t fact_id);
void ds_rete_terminal_oneshot_clear(ds_rete_terminal_t *terminal,
                                    uint32_t fact_id);

ds_result_t ds_rete_terminal_create(const char             *rule_name,
                                     uint32_t                ordinal,
                                     ds_rete_terminal_t    **out);

void ds_rete_terminal_destroy(ds_rete_terminal_t *terminal);

ds_result_t ds_rete_terminal_add_action(ds_rete_terminal_t     *terminal,
                                         const ds_rete_action_t *action);

/* ---- Activation paths (IRET.8.1) ---------------------------------- */

ds_result_t ds_rete_terminal_left_activate(ds_rete_terminal_t    *terminal,
                                            ds_rete_token_t       *token,
                                            struct ds_rete_engine *engine);

ds_result_t ds_rete_terminal_left_retract(ds_rete_terminal_t    *terminal,
                                           ds_rete_token_t       *token,
                                           struct ds_rete_engine *engine);

/* Evict a popped activation from both the act_map and the activation list, and
 * free it. */
void ds_rete_terminal_discard_activation(ds_rete_terminal_t   *terminal,
                                         ds_rete_activation_t  *act);

/*
 * The activation keyed `timetag` has ended while its token stands: its guard's
 * condition closed ([LTIM.2.5.1], [LLOG.3.11.1]). Withdraw what it justified
 * ([IRET.12.2]). The cascade may free the activation.
 */
void ds_rete_terminal_end_justification(struct ds_rete_engine *engine,
                                        int64_t                timetag);

/*
 * [LLOG.15.1], [IRET.12.2]: justify a `logical` fact by the firing activation.
 * Once an action of the firing has ended it (`firing_act_freed`), nothing is
 * entered, and *retract_out says the fact is new (`made`) with no other
 * justification: the caller retracts it with
 * ds_rete_terminal_retract_unjustified, after the emit's own records. The Mercury
 * runtime decides the same in `ds.tms.resolve_deferred`.
 */
ds_result_t ds_rete_terminal_justify(struct ds_rete_engine *engine,
                                     int64_t                timetag,
                                     const char            *rule_name,
                                     struct ds_rete_fact   *fact,
                                     bool                   made,
                                     bool                  *retract_out);

/* With DS_FWTH_CAUSE_JUSTIFIER_ENDED. */
void ds_rete_terminal_retract_unjustified(struct ds_rete_engine *engine,
                                          struct ds_rete_fact   *fact);

/* ---- The tick's turnover ([IRET.19.5]) ----------------------------- */

/* One fired activation the tick's retraction removed. Its non-tick facts are what
 * the successor's token must carry to be the same match. */
typedef struct ds_rete_tick_carry {
    ds_rete_terminal_t *terminal;
    int64_t             timetag;     /* its key in the TMS table */
    uint32_t           *fact_ids;    /* in order; owned */
    uint32_t            fact_count;
} ds_rete_tick_carry_t;

/* [RDSC.4a.8.2.1] */
bool ds_rete_terminal_has_condition(const ds_rete_terminal_t *terminal);

/* After the fresh tick is asserted: withdraw the justification of every carried
 * activation no token claimed ([IRET.12.2]). */
void ds_rete_engine_tick_flush(struct ds_rete_engine *engine);

void ds_rete_tick_carry_free(struct ds_rete_engine *engine);

/* ---- Refraction helpers (IRET.11.3) ------------------------------- */

/* fact_ids/fact_count are the token's whole tuple, the identity ([IRET.11.3]).
 * NULL/0 is a hash-only check, as RT mode's. */
bool ds_rete_terminal_is_refracted(const ds_rete_terminal_t *terminal,
                                    uint32_t                  token_hash,
                                    uint64_t                  generation,
                                    const uint32_t           *fact_ids,
                                    uint32_t                  fact_count);

/* On DS_ERR_OOM nothing is stored: an entry without its tuple would match every
 * colliding token. */
ds_result_t ds_rete_terminal_mark_refracted(ds_rete_terminal_t *terminal,
                                             uint32_t            token_hash,
                                             uint64_t            generation,
                                             const uint32_t     *fact_ids,
                                             uint32_t            fact_count);

ds_result_t ds_rete_terminal_presz_refract(ds_rete_terminal_t *terminal,
                                            uint32_t            cap);

#endif /* LIBDS2_INTERNAL_RETE_TERMINAL_H */

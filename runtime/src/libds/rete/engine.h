/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/engine.h — DS Rete engine lifecycle and top-level state (IRET.18).
 */
#ifndef LIBDS2_INTERNAL_RETE_ENGINE_H
#define LIBDS2_INTERNAL_RETE_ENGINE_H

#include <sys/types.h>
#include <stdint.h>

#include "ds_re2.h"
#include "ds_text.h"
#include "libds.h"
#include "oa.h"

#include "fn.h"
#include "rete/adapters.h"
#include "rete/agenda.h"
#include "rete/intern.h"
#include "rete/arena.h"
#include "rete/pool.h"
#include "rete/schema.h"
#include "rete/tms.h"

/* [LLEX.10.6.1]: a name the compiler or the engine makes for itself starts with
   `$`, which is no NAME character ([LLEX.10]). */
#define DS_RETE_CLOCK_TICK_NAME "$ClockTick"     /* [IRET.19.5] */
#define DS_RETE_TIMER_PREFIX    "$Timer_"        /* [LTAC.3.2] */
#define DS_RETE_TIMER_PREFIX_LEN 7u

static inline int ds_rete_name_is_synthetic(const char *name)
{
    return name != NULL && name[0] == '$';
}

struct ds_rete_alpha_node;
struct ds_rete_beta_node;
struct ds_rete_terminal;
struct ds_rete_fact;

/* ---- Per-schema alpha dispatch entry (IRET.1.7) ---- */

typedef struct {
    struct ds_rete_alpha_node **nodes;
    uint32_t                   count;
    uint32_t                   cap;
} ds_rete_dispatch_entry_t;

/* ---- Realtime contract (RTCT.6) ---- */

typedef struct ds_rete_contract_node_cap {
    uint32_t node_id;
    uint8_t  kind;    /* DS_RETE_CONTRACT_KIND_* */
    uint32_t capacity;
} ds_rete_contract_node_cap_t;

typedef struct ds_rete_contract_series_cap {
    uint32_t series_id;
    uint32_t capacity;
} ds_rete_contract_series_cap_t;

#define DS_RETE_CONTRACT_KIND_ALPHA  0u
#define DS_RETE_CONTRACT_KIND_BETA   1u
#define DS_RETE_CONTRACT_KIND_TERM   2u

/* ---- Per-engine state (IRET.18.1) ---- */

typedef struct ds_rete_engine {
    ds_rete_intern_t *intern;

    /* Parallel arrays of length schema_cap (IRET.5, IRET.1.7). */
    ds_rete_schema_t        **schemas_by_id;
    ds_rete_dispatch_entry_t *alpha_dispatch;
    size_t                    schema_cap;
    size_t                    schema_count;
    ds_rete_schema_t         **schema_name_map;
    size_t                    schema_name_cap;
    size_t                    schema_name_n;

    /* Working memory (IRET.19): fact->id (monotonic, never reused) ->
       ds_rete_fact_t*. */
    oa_t                 wm_map;

    /* [LTIM.2.8]: clock_fn is the MONOTONIC clock, wall_fn the WALL clock (UTC
       ns, false while it has no value). Under a DS engine both return its held
       sample ([LTIM.2.8.4]). */
    int64_t (*clock_fn)(void *ctx);
    bool    (*wall_fn)(void *ctx, int64_t *out_utc_ns);
    void    *clock_ctx;

    /* [LTIM.10.7]: each zone's live `TimeZoneOffset` facts by `valid_from`. NULL
       until the first such fact. */
    struct ds_rete_tz_index *tz_index;

    /* IRET.1.13 */
    void (*before_fire)(const char *rule_name, void *ctx);
    void (*after_fire)(const char *rule_name, void *ctx);
    void *fire_hook_ctx;

    uint32_t next_fact_id;
    uint64_t next_gensym;
    int64_t next_timetag;

    /* [LDET.5.5] The nesting depth of the working-memory event in progress, and
       the beta nodes holding the matches it completed, ascending by node_id. */
    uint32_t                  event_depth;
    struct ds_rete_beta_node *completion_nodes;

    /* [LERR.1.4.12] Faults the join tests of the outermost event raised, held
       until its propagation has completed (rete/beta.c). `match_trap_ids` holds
       each pair's token fact ids back to back. `match_trap_hold` is set from the
       outermost event's start until its completions have flushed. */
    struct ds_rete_match_trap *match_traps;
    uint32_t                   match_trap_n;
    uint32_t                   match_trap_cap;
    uint32_t                  *match_trap_ids;
    uint32_t                   match_trap_ids_n;
    uint32_t                   match_trap_ids_cap;
    bool                       match_trap_hold;

    ds_rete_agenda_t agenda;

    /* Refraction cycle generation (IRET.11.3.2): advanced on every
       working-memory assert and retract and once per pump; old-generation
       refraction entries read as absent. An activation's `fired` flag, not this,
       keeps it from firing again, and the one-shot keeps a time-dependent rule
       from re-firing on each tick ([LTIM.2.5.1]). */
    uint64_t cycle_generation;

    ds_tms_table_t tms;

    /* Set from before_fire through after_fire, for the bridge callbacks. */
    struct ds_rete_token *current_fire_token;

    /* Set and cleared with current_fire_token. Engine-lifetime interned. */
    const char *current_fire_rule;

    /* Whether this firing's rate gate suppressed its actions
       ([RDSC.4a.8.2.3]): a suppressed firing arms no cooldown window
       ([LCDB.3.2.1]), so it emits no TIMER_ARMED ([NCBK.2.6]). */
    bool current_fire_gate_denied;

    /* The activation ds_rete_run is firing, and whether it was freed while it
       fired: an action that retracts one of its token's facts reaches
       ds_rete_terminal_left_retract, which frees it. ds_rete_run then touches
       nothing of it. */
    ds_rete_activation_t *firing_act;
    bool                  firing_act_freed;

    /* [LERR.9] fault facts -- rete/fault_fact.h. The queue the fault funnel
       fills and the drain empties before each agenda selection; the latch
       table, one live fault fact per (schema, node, rule) site. */
    struct ds_rete_fault_fact  *fault_queue;
    uint32_t                    fault_queue_n;
    uint32_t                    fault_queue_cap;
    struct ds_rete_fault_latch *fault_latch;
    uint32_t                    fault_latch_n;
    uint32_t                    fault_latch_cap;
    bool                        fault_draining;
    /* RDSC.3.10: `DscHeader.fault_fact_sites`. Under `realtime` or `constspace`
       the fault-fact pool is this many slots ([LERR.9.10]). */
    uint32_t                    fault_fact_sites;
    /* The live facts of the two fault schemas, which never count against
       `wm_max` ([LERR.9.10]). */
    uint32_t                    fault_fact_live;

    ds_rete_adapter_config_t adapter;

    /* IRET.20. Test harness nodes are not listed here and stay caller-owned. */
    struct ds_rete_alpha_node **owned_alphas;
    uint32_t                   owned_alpha_count;
    struct ds_rete_beta_node  **owned_betas;
    uint32_t                   owned_beta_count;
    struct ds_rete_terminal   **owned_terminals;
    uint32_t                   owned_terminal_count;

    /* The owning ds_engine_t, for adapters: the op dispatch passes only the rete
       engine. NULL when the rete engine runs standalone. */
    void *ds_engine_back;
    /* [LERR.1.4.7]: an EngineError stops the work in progress, even inside a
     * fact change. Set where one is raised (eval.c's `fault_at`) and never
     * cleared; the rete tree cannot see the DS engine's struct, so keeps its own
     * copy. From then on nothing is selected, propagated, cascaded, swept or
     * upserted, and nothing leaves working memory, since tokens the cut left may
     * still point at it. Each stop leaves what it leaves owned by a structure
     * ds_engine_free releases. Every read of the state is refused ([NCBK.2.9]). */
    bool halted;
    /* The DS engine's dispatch table. NULL when standalone. */
    void *ds_dispatch_table_ptr;

    /* Compiled regexes by (interned pattern pointer, DS_RE2_* flags). Patterns
       are compile-time literals (LREG.5.5). */
    struct ds_regex_cache_entry {
        const char *pat;    /* interned pointer; NULL = empty slot */
        unsigned    flags;
        ds_re2_t   *compiled;
    } *regex_cache;
    uint32_t regex_cache_cap;

    /* Deadline min-heap for TTL expiry, under +dynamic_ttl only. Otherwise each
     * schema keeps a FIFO queue in assertion order, and the tick merges the
     * queues' fronts ([LDTL.3.1], [LDTL.4.2]). */
    struct ds_rete_fact **deadline_heap_items;
    uint32_t              deadline_heap_count;
    uint32_t              deadline_heap_cap;

    /* LFAC.1.2o: per-assert TTL override (ns), set around one ds_rete_wm_assert.
     * The single-threaded pump (IARC.1.10) means no other path observes it. */
    int64_t               pending_ttl_override_ns;

    /* RFCS.6a.4: the supersede the last rule emit's assert made. Cleared by
     * ds_rete_wm_wrap_emitted_fact, which records it, or by
     * ds_rete_wm_settle_supersede on an error exit. `supersede_old` is freed by
     * then: an opaque key into the wrapper table, never dereferenced.
     * `supersede_old_id` is for the activation facts waiting on it ([LSCP.3.1]
     * step 7). */
    struct ds_rete_fact  *supersede_old;
    struct ds_rete_fact  *supersede_new;
    uint32_t              supersede_old_id;

    /* Hard real-time mode.
     * wm_max_facts:    N_max; 0 = unlimited (must be non-zero in rt_mode).
     * cached_clock_ns: updated once per pump cycle; EXPR_NOW reads this.
     * cached_clock_valid: occupancy, since 0 is a legitimate reading
     *                  ([IRET.25.4.1]).
     * max_token_depth: max facts[] length in any token; 0 = 16.
     * token_pool_cap:  0 = wm_max_facts × 8.
     * token_budget:    token allocations left this pump cycle; 0 = unlimited. */
    bool     rt_mode;
    uint32_t wm_max_facts;
    int64_t  cached_clock_ns;
    bool     cached_clock_valid;
    bool     pools_ready;
    /* Set by ds_rete_go_live(); never reset. */
    bool     live;
    uint32_t max_token_depth;
    uint32_t token_pool_cap;
    uint32_t token_budget;
    /* When non-zero, replaces _presz_cap(N) in ds_rete_engine_presz_rt_tables. */
    uint32_t presz_cap_override;
    uint32_t presz_diag_step;   /* diagnostic: incremented at each presz step */
    /* Minimum max_fires in RT mode; 0 = not enforced. */
    uint32_t max_fires_rt;
    /* eval_actions' bind frame in RT mode, sized to the largest bind_count. NULL
       otherwise: a stack buffer is used. */
    ds_rete_val_t *bind_frame_scratch;
    uint32_t       bind_frame_scratch_cap;
    ds_rete_pool_t fact_pool;
    ds_rete_pool_t token_pool;
    ds_rete_pool_t act_pool;

    /* The ClockTick cycled at the start of each pump: the schema, and the tick
     * currently asserted. NULL when no $ClockTick schema is registered. */
    const ds_rete_schema_t  *clock_tick_schema;
    struct ds_rete_fact     *clock_tick_fact;

    /* True only while ds_rete_engine_tick_clock retracts the previous tick: a
     * token that leaves then is the same match carried across it ([IRET.19.5]),
     * so its edge-once mark survives ([LTIM.2.5.1], [IRET.11.3.2]). */
    bool                     retracting_tick;

    /* The fired activations the tick's retraction removed, held until the fresh
     * tick is asserted ([IRET.19.5], [IRET.12.2]). One whose token re-forms takes
     * the justification over; one whose token does not has ended, and
     * ds_rete_engine_tick_flush withdraws it. */
    struct ds_rete_tick_carry *tick_carry;
    uint32_t                   tick_carry_n;
    uint32_t                   tick_carry_cap;

    /* Max right-facts per join-key value. 1 under +nolinscan; 0 = unknown. */
    uint32_t max_join_fanout;
    uint32_t max_bind_count_hint;
    uint32_t wm_hint;
    bool     pending_rt;
    /* The RealtimeContract atom, decoded once. Cap checks no-op when
     * !has_contract. */
    bool      has_contract;
    uint32_t  contract_wm_max;
    uint32_t  contract_agenda_cap;
    uint32_t  contract_max_fires_per_pump;
    uint32_t  contract_token_pool_cap;
    uint32_t  contract_intern_cap;
    uint32_t  contract_intern_bytes_cap;
    uint64_t  contract_pump_wcet_ns;
    uint32_t  contract_cache_cap;        /* max live cache keys (0 = unbounded) */
    uint64_t  contract_cache_bytes_cap;  /* max cache value bytes (0 = unbounded) */
    uint8_t   contract_rt_config_sha256[32];

    /* Ascending node_id. */
    struct ds_rete_contract_node_cap   *contract_nodes;
    uint32_t                            contract_n_nodes;

    struct ds_rete_contract_series_cap *contract_series;
    uint32_t                            contract_n_series;

    /* The compact node-cap encoding, expanded at end of load
     * (ds_dsrt_apply_node_caps): it carries no per-node `kind`, and the
     * RealtimeContract atom precedes the node atoms (RDSC.16.3.5). */
    bool      contract_compact_pending;
    uint32_t  contract_compact_node_count;
    uint32_t  contract_compact_default;
    /* Sparse overrides: `kind` is unused. */
    struct ds_rete_contract_node_cap   *contract_compact_overrides;
    uint32_t                            contract_compact_n_overrides;
    uint32_t                           *contract_compact_packed;  /* node_count caps, or NULL */
    uint32_t                            contract_compact_n_packed;

    /* The previous pump's elapsed time is checked on the next ds_rete_run: the
     * engine cannot interrupt a pump. */
    uint64_t  last_pump_elapsed_ns;
    bool      last_pump_breached;

    /* LCAP.1: set by the CapabilityInfo atom's loader. */
    bool cap_nological;   /* +nological: TMS absent; no logical lifecycle */
    bool cap_nolinscan;   /* +nolinscan: O(1) joins enforced by compiler */
    bool cap_dynamic_ttl; /* +dynamic_ttl: per-emit TTL override; heap active */
    bool cap_realtime;    /* +realtime: INIT/LIVE lifecycle; go_live required */
    bool cap_constspace;  /* +constspace: bounded-memory only; no WCET (LCSP) */

    /* The build buffer eval_str_cat assembles into. */
    char     *str_cat_scratch;
    size_t    str_cat_scratch_cap;

    /* Bump arena for transient computed strings, copied into a counted intern
     * entry only if emitted into a fact slot. Reset at pump entry. */
    ds_rete_arena_t comp_arena;

    /* comp_arena's sibling for Json: a tree parsed from a String's text, which a
     * path's value borrows into. */
    struct ds_json **transient_json;
    uint32_t         transient_json_n;
    uint32_t         transient_json_cap;

    /* A formatted ds_result_t detail for the load path ([IARC.1.10],
     * [IERR.4.1.1]). Not for a detail that can reach engine.h's pending_detail,
     * which is read after further calls: this buffer would be overwritten under
     * it. */
    char detail_scratch[256];

} ds_rete_engine_t;

/* ---- Lifecycle (IRET.18.1) ---- */

ds_result_t ds_rete_engine_create(ds_rete_engine_t **out);
ds_result_t ds_rete_engine_destroy(ds_rete_engine_t *engine);

/* A ds_text writer over engine->detail_scratch, or one of capacity 0 when there
 * is no engine. Load path only. */
ds_text_t ds_rete_engine_detail(ds_rete_engine_t *engine);

/* `fallback` when there was no engine to hold the detail. */
const char *ds_rete_engine_detail_text(const ds_text_t *t, const char *fallback);

/* ---- RT mode ---- */

/* Must be called before loading a DSC or asserting any facts. */
ds_result_t ds_rete_engine_set_rt_mode(ds_rete_engine_t *engine, bool enabled);

/* N_max, the maximum live facts in WM; 0 = unlimited. An identity update does
 * not count against it. Must be called before asserting any facts. */
ds_result_t ds_rete_engine_set_wm_max(ds_rete_engine_t *engine,
                                       uint32_t          max_facts);

/* 0 = 16. Must be >= the deepest LHS, and set before init_rt_pools. */
ds_result_t ds_rete_engine_set_token_depth(ds_rete_engine_t *engine,
                                            uint32_t          depth);

/* 0 = wm_max_facts × 8. Must be set before init_rt_pools. */
ds_result_t ds_rete_engine_set_token_pool_cap(ds_rete_engine_t *engine,
                                               uint32_t          cap);

ds_result_t ds_rete_engine_mem(const ds_rete_engine_t *engine,
                               ds_engine_mem_t        *out);

/* In rt_mode, ds_rete_run returns DS_ERR_RT_UNSAFE if max_fires == 0 or
 * max_fires < min_fires. 0 = not enforced. */
ds_result_t ds_rete_engine_set_max_fires_rt(ds_rete_engine_t *engine,
                                             uint32_t          min_fires);

/* Must be called after all schemas are registered and before any facts are
 * asserted. Requires rt_mode and wm_max_facts > 0. */
ds_result_t ds_rete_engine_init_rt_pools(ds_rete_engine_t *engine);

/* Pre-size all hash tables so none can grow during a pump cycle. Must be called
 * after init_rt_pools and after DSC load. */
ds_result_t ds_rete_engine_presz_rt_tables(ds_rete_engine_t *engine);

/* One-way transition from INIT to LIVE. DS_ERR_RT_PRECOND if a pre-condition is
 * not satisfied, DS_ERR_RT_LIVE if already LIVE. */
ds_result_t ds_rete_go_live(ds_rete_engine_t *engine);

void ds_rete_refresh_clock_cache(ds_rete_engine_t *engine);

/* Hand `tree` to the engine until the next pump. On DS_ERR_OOM the tree is still
 * the caller's. */
ds_result_t ds_rete_transient_json_keep(ds_rete_engine_t *engine,
                                        struct ds_json *tree);

void ds_rete_transient_json_free(ds_rete_engine_t *engine);

/*
 * Records a declared-cap breach on the stream as DS_EV_BOUNDS_ERROR. It does not
 * replace the status: the caller still returns DS_ERR_CONTRACT_BREACH.
 * `rule_name` NULL / `timetag` 0 where there is no activation context. No-op on
 * a standalone rete engine.
 */
void ds_rete_emit_breach(ds_rete_engine_t *engine,
                          ds_cap_name_t     cap,
                          uint64_t          limit,
                          uint64_t          observed,
                          const char       *rule_name,
                          int64_t           timetag);

/* ---- Clock (IRET.14) ---- */

/* fn must not be NULL. The default source is clock_gettime(CLOCK_MONOTONIC). */
ds_result_t ds_rete_set_clock(ds_rete_engine_t *engine,
                               int64_t (*fn)(void *ctx),
                               void             *ctx);

int64_t ds_rete_now_ns(ds_rete_engine_t *engine);

/* [LTIM.2.8.3]. fn must not be NULL; it is called with the clock_ctx
 * ds_rete_set_clock installed. The default source is
 * clock_gettime(CLOCK_REALTIME) on a hosted build and "no value" on a
 * microcontroller. */
ds_result_t ds_rete_set_wall_clock(ds_rete_engine_t *engine,
                                    bool (*fn)(void *ctx, int64_t *out_utc_ns));

/* False while the wall clock has no value. */
bool ds_rete_wall_ns(ds_rete_engine_t *engine, int64_t *out_utc_ns);

/* ---- Fire hooks (IRET.1.13) ---- */

ds_result_t ds_rete_set_before_fire(ds_rete_engine_t *engine,
                                     void (*hook)(const char *rule_name,
                                                  void       *ctx),
                                     void             *ctx);
ds_result_t ds_rete_set_after_fire(ds_rete_engine_t *engine,
                                    void (*hook)(const char *rule_name,
                                                 void       *ctx),
                                    void             *ctx);

/* ---- Firing loop (IRET.11.4) -------------------------------------- */

/*
 * ds_rete_run — drain the agenda up to max_fires activations.
 *
 * Each activation is checked for refraction before firing.  If
 * refracted, it is discarded and the next activation is tried.
 * After firing, the token hash is recorded in the terminal's
 * refraction set (IRET.11.3).
 *
 * max_fires == 0 means unlimited (run until the agenda is empty).
 * fires_out may be NULL.
 *
 * Returns DS_OK when the agenda drains, DS_ERR_BUDGET_EXCEEDED when
 * max_fires > 0 and the agenda is not yet empty.
 */
ds_result_t ds_rete_run(ds_rete_engine_t *engine,
                         uint32_t          max_fires,
                         uint32_t         *fires_out);

#endif /* LIBDS2_INTERNAL_RETE_ENGINE_H */

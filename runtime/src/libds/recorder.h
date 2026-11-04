/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * recorder.h — stream-event dispatch ([IARC.3.6.1]): nothing is appended, traced or
 * kept here. The recorder assigns seq, timestamps with the engine clock, and
 * dispatches to the integrator's callback.
 */
#ifndef LIBDS2_INTERNAL_RECORDER_H
#define LIBDS2_INTERNAL_RECORDER_H

#include "libds.h"

struct ds_engine;
struct ds_fact;
struct ds_schema;

/* [LFST.7.3.6]. release_after is a cascade retract's detached wrapper, released after
   the dispatch; NULL for an assert, whose fact stays live. */
typedef struct ds_recorder_defer_entry {
    ds_stream_ev_t  ev;
    struct ds_fact *release_after;
    /* engine->wm's values when the record was buffered, reinstated around its dispatch:
       the originating site restores them long before the flush. */
    uint8_t         retract_cause;
    const char     *retract_reason;
    bool            assert_from_host;
} ds_recorder_defer_entry_t;

typedef struct ds_recorder_state {
    ds_stream_cb_t  stream_cb;
    void           *stream_user;
    /* defer_depth 1 is the external event's own record, emitted immediately; 2 and up
       is a truth-maintenance cascade it triggered, flushed when depth returns to 0. */
    int32_t                     defer_depth;
    ds_recorder_defer_entry_t  *defer_buf;
    uint32_t                    defer_n;
    uint32_t                    defer_cap;
    /* [RFCS.6.7]: the host assert in flight. A bound that refuses it is recorded from
       inside the network, before any wrapper exists, and its FactAssert goes ahead of
       the BoundsError. Borrowed for the bridge call only. */
    const struct ds_schema     *input_schema;
    const ds_slot_value_t      *input_values;
    uint32_t                    input_n;
    bool                        input_pending;
    /* [RFCS.6.7]: the depth-1 faults a host assert's own propagation raises, held until
       the bridge has recorded the assert. Deeper ones go to defer_buf. */
    int32_t                     hold_depth;
    ds_recorder_defer_entry_t  *hold_buf;
    uint32_t                    hold_n;
    uint32_t                    hold_cap;
    /* [LGRA.24.3]: true while the DSC loader applies `initial:`. No record reaches the
       sink and no `seq` is spent. */
    bool                        muted;
    /* [LGRA.24.3], [LTIM.2.8.3]: the DOMAIN ComputationErrors the `initial` block raised,
       recorded after the step's next record, or as the host call returns on a step that
       records no input. */
    uint32_t                    block_faults_pending;
    const char                 *block_fault_rule;  /* [LERR.9.11] */
    /* [LERR.1.4.7]: set when the EngineError is dispatched, not when it is raised: it
       may be held or deferred, and what those orders put ahead of it is still recorded. */
    bool                        closed;
} ds_recorder_state_t;

ds_result_t ds_recorder_init(ds_recorder_state_t *r);
ds_result_t ds_recorder_destroy(ds_recorder_state_t *r);

/* [LFST.7.3.6]. The outermost leave flushes in propagation order. */
void ds_recorder_defer_enter(struct ds_engine *engine);
ds_result_t ds_recorder_defer_leave(struct ds_engine *engine);
bool ds_recorder_should_buffer(const struct ds_engine *engine);

/* [RFCS.6.7]: bracket a host assert's hand-off to the network. `values` is borrowed
   until ds_recorder_input_end. */
void ds_recorder_input_begin(struct ds_engine       *engine,
                             const struct ds_schema *schema,
                             const ds_slot_value_t  *values,
                             uint32_t                n_values);
void ds_recorder_input_end(struct ds_engine *engine);

/* [LERR.1.4.7], [RFCS.6.7]: a host upsert the halt cut after its old fact's retract
   arrived still records its FactAssert. A no-op outside input_begin and input_end, and
   once per input. */
void ds_recorder_emit_cut_input(struct ds_engine *engine);

/* [RFCS.6.7]: bracket a host assert from the hand-off to the input's last record. The
   outermost release dispatches the held faults in the order they were raised. */
void ds_recorder_hold_faults(struct ds_engine *engine);
ds_result_t ds_recorder_release_faults(struct ds_engine *engine);

/* The id the host assert in flight will take, when its schema is `schema_name`; 0
   otherwise. */
uint64_t ds_recorder_input_fact_id(const struct ds_engine *engine,
                                   const char             *schema_name);

/* [LGRA.24.3], [LTIM.2.8.3]: its site is none ([LERR.9.12]), and `rule_name` is the
   engine's fault rule ([LERR.9.11]). */
void ds_recorder_block_fault(struct ds_engine *engine, const char *rule_name);

ds_result_t ds_recorder_emit_fact_assert(struct ds_engine *engine,
                                          struct ds_fact   *fact);

ds_result_t ds_recorder_emit_fact_retract(struct ds_engine *engine,
                                           struct ds_fact   *fact);

/* timetag is the activation's creation_timetag, the CallIssued↔RuleFireAnnotation join
   key ([RFCS.15]). */
ds_result_t ds_recorder_emit_rule_fire_begin(struct ds_engine *engine,
                                              const char       *rule_name,
                                              int64_t           timetag);

ds_result_t ds_recorder_emit_rule_fire_end(struct ds_engine *engine,
                                            const char       *rule_name,
                                            int64_t           timetag);

/* `external` is the fact's FactExternal encoding ([NCBK.10.1], [RFCS.23.1]), borrowed for
   the callback's duration; NULL when the fact could not be encoded. */
ds_result_t ds_recorder_emit_action_publish(struct ds_engine *engine,
                                             struct ds_fact   *fact,
                                             const uint8_t    *external,
                                             size_t            external_len);

ds_result_t ds_recorder_emit_action_emit(struct ds_engine *engine,
                                          struct ds_fact   *fact);

/* Before the typed log callback runs ([IDSP.1.4]). */
ds_result_t ds_recorder_emit_action_log(struct ds_engine *engine,
                                         ds_log_level_t   level,
                                         const char      *category,
                                         const char      *message);

/* After the engine applies the write to its own cache and before the integrator's hook
   runs, whatever the hook returns ([IDSP.7.6], [IDSP.1.4]). value is borrowed for the
   callback's duration. */
ds_result_t ds_recorder_emit_action_cache_set(struct ds_engine *engine,
                                               const char       *key,
                                               const ds_json_t  *value,
                                               uint64_t          ttl_ns);

ds_result_t ds_recorder_emit_action_cache_delete(struct ds_engine *engine,
                                                  const char      *key);

/* [NCBK.6.9]: the arguments, sorted by name, borrowed for the callback's duration.
   `correlation` is the `as` or the generated value ([LCRS.3.1]). */
ds_result_t ds_recorder_emit_action_call(struct ds_engine *engine,
                                          const char       *service,
                                          const char       *correlation,
                                          const ds_arg_t   *args,
                                          uint32_t          arg_count,
                                          int64_t           timetag,
                                          const char       *rule_name);

/* [LTIM.2.8.5]: an observed clock sample, never a mock mutation ([NTST.3.3]). */
ds_result_t ds_recorder_emit_tick(struct ds_engine *engine);

/* [RFCS.22]: after its sample's TICK and before anything the pump does. */
ds_result_t ds_recorder_emit_pump(struct ds_engine *engine);

/* Immediately before rule_fire_begin, with the same timetag ([NCBK.2.12]). facts[] is
   borrowed for the callback's duration. */
ds_result_t ds_recorder_emit_rule_lhs_facts(struct ds_engine *engine,
                                              const char       *rule_name,
                                              int64_t           timetag,
                                              struct ds_fact  **facts,
                                              uint32_t          fact_count);

/* timetag is the arming firing's ([NCBK.2.12]). */
ds_result_t ds_recorder_emit_timer_armed(struct ds_engine *engine,
                                           const char       *rule_name,
                                           int64_t           timetag,
                                           const char       *kind,
                                           uint64_t          window_ns,
                                           uint64_t          fire_at_ns);

/* `rule_name` is NULL and `timetag` 0 where there is no activation context: an
   `intern_cap` breach during load has none. */
ds_result_t ds_recorder_emit_bounds_error(struct ds_engine *engine,
                                            ds_cap_name_t     cap,
                                            uint64_t          limit,
                                            uint64_t          observed,
                                            const char       *rule_name,
                                            int64_t           timetag);

/* [NCBK.2.8]. schema_name, slot_name and actual may be NULL where the raising site does
   not hold them. `rule_name` ([LERR.9.11]) is never NULL. */
ds_result_t ds_recorder_emit_type_error(struct ds_engine *engine,
                                          uint32_t          node_id,
                                          const char       *rule_name,
                                          const char       *schema_name,
                                          const char       *slot_name,
                                          const char       *actual);

/* [LERR.1.4.9]. `rule_name` ([LERR.9.11]) is never NULL; `timetag` is 0 outside a firing
   (a join test). */
ds_result_t ds_recorder_emit_computation_error(struct ds_engine *engine,
                                                 ds_trap_kind_t    kind,
                                                 const char       *rule_name,
                                                 int64_t           timetag,
                                                 const char       *schema_name,
                                                 const char       *slot_name,
                                                 uint64_t          fact_id,
                                                 uint32_t          node_id);

/* [NCBK.2.9]. `node_id` 0 for a fault with no node site, whose `rule_name` is then
   `$engine` ([LERR.9.11]); `rule_name` is never NULL. */
ds_result_t ds_recorder_emit_engine_error(struct ds_engine  *engine,
                                            ds_engine_fault_t  fault,
                                            uint32_t           node_id,
                                            const char        *rule_name);

#endif /* LIBDS2_INTERNAL_RECORDER_H */

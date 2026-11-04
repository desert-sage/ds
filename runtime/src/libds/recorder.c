/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * recorder.c — stream-event single-writer dispatch.
 */
#include <stddef.h>
#include <string.h>

#include "libds.h"

#include "clock.h"
#include "ds_alloc.h"
#include "ds_event_names.h"
#include "engine.h"
#include "recorder.h"
#include "rete/fault_fact.h"
#include "schema.h"
#include "telemetry.h"
#include "wm.h"

ds_result_t ds_recorder_init(ds_recorder_state_t *r)
{
    if (r == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "recorder state must not be null");
    }
    r->stream_cb   = NULL;
    r->stream_user = NULL;
    r->defer_depth = 0;
    r->defer_buf   = NULL;
    r->defer_n     = 0;
    r->defer_cap   = 0;
    r->input_schema  = NULL;
    r->input_values  = NULL;
    r->input_n       = 0;
    r->input_pending = false;
    r->hold_depth    = 0;
    r->hold_buf      = NULL;
    r->hold_n        = 0;
    r->hold_cap      = 0;
    r->block_faults_pending = 0;
    r->block_fault_rule     = NULL;
    r->closed               = false;
    return DS_OK_R;
}

ds_result_t ds_recorder_destroy(ds_recorder_state_t *r)
{
    if (r == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "recorder state must not be null");
    }
    r->stream_cb   = NULL;
    r->stream_user = NULL;
    DS_FREE(r->defer_buf);
    r->defer_buf   = NULL;
    r->defer_n     = 0;
    r->defer_cap   = 0;
    r->defer_depth = 0;
    DS_FREE(r->hold_buf);
    r->hold_buf    = NULL;
    r->hold_n      = 0;
    r->hold_cap    = 0;
    r->hold_depth  = 0;
    return DS_OK_R;
}

static ds_result_t recorder_dispatch(struct ds_engine *engine,
                                      ds_stream_ev_t   *ev);

/* [LFST.7.3.6]. On OOM the record is delivered now, ahead of its trigger's, and
   DS_ERR_OOM becomes the call's status ([NCBK.1.5]): the order degrades and nothing is
   lost. */
static void recorder_defer_push(struct ds_engine *engine,
                                 const ds_stream_ev_t *ev,
                                 struct ds_fact *release_after)
{
    ds_recorder_state_t *rec = &engine->recorder;
    if (rec->defer_n == rec->defer_cap) {
        uint32_t ncap = rec->defer_cap ? rec->defer_cap * 2u : 8u;
        ds_recorder_defer_entry_t *nb =
            DS_REALLOC(rec->defer_buf, ncap * sizeof(*nb));
        if (nb == NULL) {
            if (engine->stream_status.status == DS_OK)
                engine->stream_status = DS_ERR_R(DS_ERR_OOM,
                    "stream: a truth-maintenance cascade record could not be "
                    "buffered, and was delivered ahead of its trigger's");
            ds_stream_ev_t now = *ev;
            (void)recorder_dispatch(engine, &now);  /* always OK: [NCBK.1.5] */
            if (release_after != NULL)
                ds_wm_fact_release_detached(&engine->wm, release_after);
            return;
        }
        rec->defer_buf = nb;
        rec->defer_cap = ncap;
    }
    rec->defer_buf[rec->defer_n].ev            = *ev;
    rec->defer_buf[rec->defer_n].release_after = release_after;
    rec->defer_buf[rec->defer_n].retract_cause  = engine->wm.retract_cause;
    rec->defer_buf[rec->defer_n].retract_reason = engine->wm.retract_reason;
    rec->defer_buf[rec->defer_n].assert_from_host = engine->wm.assert_from_host;
    rec->defer_n++;
}

bool ds_recorder_should_buffer(const struct ds_engine *engine)
{
    return engine != NULL && engine->recorder.defer_depth >= 2;
}

void ds_recorder_input_begin(struct ds_engine       *engine,
                             const struct ds_schema *schema,
                             const ds_slot_value_t  *values,
                             uint32_t                n_values)
{
    if (engine == NULL) return;
    ds_recorder_state_t *rec = &engine->recorder;
    rec->input_schema  = schema;
    rec->input_values  = values;
    rec->input_n       = n_values;
    rec->input_pending = true;
}

void ds_recorder_input_end(struct ds_engine *engine)
{
    if (engine == NULL) return;
    ds_recorder_state_t *rec = &engine->recorder;
    rec->input_schema  = NULL;
    rec->input_values  = NULL;
    rec->input_n       = 0;
    rec->input_pending = false;
}

/* [RFCS.6.7]. Before the bridge has minted a wrapper, so the record is written from a
   fact view: what a wrapper would have held, valid for the stream callback and never in
   working memory ([NFCT.5.1]). Dispatched, never buffered: the BoundsError that follows
   is dispatched immediately. */
static void recorder_emit_refused_input(struct ds_engine *engine)
{
    ds_recorder_state_t *rec = &engine->recorder;
    if (!rec->input_pending) return;
    rec->input_pending = false;
    const ds_schema_t *schema = rec->input_schema;
    if (schema == NULL) return;

    const uint32_t n_slots = schema->n_slots;
    ds_fact_t *view = DS_CALLOC(1, sizeof(ds_fact_t)
                                   + (size_t)n_slots * sizeof(ds_slot_value_t));
    if (view == NULL) {
        /* [NCBK.1.5]: the record is lost and the call says so. */
        if (engine->stream_status.status == DS_OK)
            engine->stream_status = DS_ERR_R(DS_ERR_OOM,
                "stream: a refused assert's FactAssert could not be recorded");
        return;
    }
    view->schema  = schema;
    view->engine  = engine;
    view->n_slots = n_slots;
    view->fact_id = engine->next_fact_id++;
    if (ds_clock_now_ns(&engine->clock, &view->asserted_ns).status != DS_OK)
        view->asserted_ns = 0;
    bool wall_set = false;
    if (ds_clock_wall_ns(&engine->clock, &view->asserted_wall_ns, &wall_set)
            .status != DS_OK)
        wall_set = false;
    view->asserted_wall_set = wall_set;
    if (!wall_set) view->asserted_wall_ns = 0;
    /* As ds_wm_fact_new computes it. */
    if (engine->wm.ttl_override_ns != 0)
        view->ttl_deadline_ns = view->asserted_ns + engine->wm.ttl_override_ns;
    else if (schema->lifecycle == DS_SCHEMA_LIFECYCLE_TTL)
        view->ttl_deadline_ns = view->asserted_ns + schema->ttl_ns;
    for (uint32_t i = 0; i < rec->input_n && i < n_slots; i++) {
        view->slots[i] = rec->input_values[i];
        /* A fact-ref is held by id, as the bridge holds it. */
        if (view->slots[i].kind == DS_SLOT_FACT_REF)
            view->slots[i] = ds_wm_slot_of_ref_id(
                rec->input_values[i].v.ref
                    ? rec->input_values[i].v.ref->fact_id : 0u);
    }

    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_FACT_ASSERT;
    ev.p.fact_assert.fact = view;
    (void)recorder_dispatch(engine, &ev);
    DS_FREE(view);
}

void ds_recorder_emit_cut_input(struct ds_engine *engine)
{
    if (engine == NULL) return;
    recorder_emit_refused_input(engine);
}

/* For a fault a join test raises inside the hand-off: the rete fact it reads has no
   wrapper yet, and nothing mints a wrapper before the input's, so its id is the next. */
uint64_t ds_recorder_input_fact_id(const struct ds_engine *engine,
                                   const char             *schema_name)
{
    if (engine == NULL || schema_name == NULL) return 0;
    const ds_schema_t *schema = engine->recorder.input_schema;
    if (schema == NULL || schema->type_name == NULL) return 0;
    if (strcmp(schema->type_name, schema_name) != 0) return 0;
    return engine->next_fact_id;
}

void ds_recorder_hold_faults(struct ds_engine *engine)
{
    if (engine != NULL) engine->recorder.hold_depth++;
}

/* [RFCS.6.7]. On OOM it is delivered now, as a cascade record is (recorder_defer_push). */
static void recorder_hold_push(struct ds_engine *engine,
                               const ds_stream_ev_t *ev)
{
    ds_recorder_state_t *rec = &engine->recorder;
    if (rec->hold_n == rec->hold_cap) {
        uint32_t ncap = rec->hold_cap ? rec->hold_cap * 2u : 4u;
        ds_recorder_defer_entry_t *nb =
            DS_REALLOC(rec->hold_buf, ncap * sizeof(*nb));
        if (nb == NULL) {
            if (engine->stream_status.status == DS_OK)
                engine->stream_status = DS_ERR_R(DS_ERR_OOM,
                    "stream: a fault raised by a host assert could not be "
                    "held, and was delivered ahead of the assert's record");
            ds_stream_ev_t now = *ev;
            (void)recorder_dispatch(engine, &now);  /* always OK: [NCBK.1.5] */
            return;
        }
        rec->hold_buf = nb;
        rec->hold_cap = ncap;
    }
    rec->hold_buf[rec->hold_n].ev             = *ev;
    rec->hold_buf[rec->hold_n].release_after  = NULL;
    rec->hold_buf[rec->hold_n].retract_cause  = 0;
    rec->hold_buf[rec->hold_n].retract_reason = NULL;
    rec->hold_buf[rec->hold_n].assert_from_host = false;
    rec->hold_n++;
}

ds_result_t ds_recorder_release_faults(struct ds_engine *engine)
{
    if (engine == NULL) return DS_OK_R;
    ds_recorder_state_t *rec = &engine->recorder;
    if (rec->hold_depth > 0) rec->hold_depth--;
    if (rec->hold_depth != 0) return DS_OK_R;

    /* Moved out first, so a stream callback that drives the engine accumulates into a
       fresh buffer. */
    ds_recorder_defer_entry_t *buf = rec->hold_buf;
    uint32_t n = rec->hold_n;
    rec->hold_buf = NULL;
    rec->hold_n   = 0;
    rec->hold_cap = 0;

    ds_result_t first_err = DS_OK_R;
    for (uint32_t i = 0; i < n; i++) {
        ds_result_t r = recorder_dispatch(engine, &buf[i].ev);
        if (r.status != DS_OK && first_err.status == DS_OK) first_err = r;
    }
    DS_FREE(buf);
    return first_err;
}

void ds_recorder_defer_enter(struct ds_engine *engine)
{
    if (engine != NULL) engine->recorder.defer_depth++;
}

ds_result_t ds_recorder_defer_leave(struct ds_engine *engine)
{
    if (engine == NULL) return DS_OK_R;
    ds_recorder_state_t *rec = &engine->recorder;
    if (rec->defer_depth > 0) rec->defer_depth--;
    if (rec->defer_depth != 0) return DS_OK_R;

    /* Moved out first, so a stream callback that drives the engine accumulates into a
       fresh buffer. */
    ds_recorder_defer_entry_t *buf = rec->defer_buf;
    uint32_t n = rec->defer_n;
    rec->defer_buf = NULL;
    rec->defer_n   = 0;
    rec->defer_cap = 0;

    ds_result_t first_err = DS_OK_R;
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t     prev_cause  = engine->wm.retract_cause;
        const char *const prev_reason = engine->wm.retract_reason;
        const bool        prev_host   = engine->wm.assert_from_host;
        engine->wm.retract_cause    = buf[i].retract_cause;
        engine->wm.retract_reason   = buf[i].retract_reason;
        engine->wm.assert_from_host = buf[i].assert_from_host;
        ds_result_t r = recorder_dispatch(engine, &buf[i].ev);
        engine->wm.retract_cause    = prev_cause;
        engine->wm.retract_reason   = prev_reason;
        engine->wm.assert_from_host = prev_host;
        if (r.status != DS_OK && first_err.status == DS_OK) first_err = r;
        if (buf[i].release_after != NULL)
            ds_wm_fact_release_detached(&engine->wm, buf[i].release_after);
    }
    DS_FREE(buf);
    return first_err;
}

static ds_result_t recorder_dispatch_one(struct ds_engine *engine,
                                          ds_stream_ev_t   *ev);

void ds_recorder_block_fault(struct ds_engine *engine, const char *rule_name)
{
    if (engine == NULL) return;
    engine->recorder.block_faults_pending++;
    engine->recorder.block_fault_rule = rule_name;
}

/* [LGRA.24.3], [LTIM.2.8.3]. Never held or buffered: they come ahead of whatever the
   input's propagation raised ([RFCS.6.7]). The count is cleared first, since each is a
   record too. */
static void recorder_flush_block_faults(struct ds_engine *engine)
{
    const uint32_t n = engine->recorder.block_faults_pending;
    engine->recorder.block_faults_pending = 0;
    for (uint32_t i = 0; i < n; i++) {
        ds_stream_ev_t ev = {0};
        ev.kind = DS_EV_COMPUTATION_ERROR;
        ev.p.computation_error.kind        = DS_TRAP_DOMAIN;
        ev.p.computation_error.rule_name   = engine->recorder.block_fault_rule;
        ev.p.computation_error.timetag     = 0;
        ev.p.computation_error.schema_name = NULL;
        ev.p.computation_error.slot_name   = NULL;
        ev.p.computation_error.fact_id     = 0;
        ev.p.computation_error.node_id     = 0;
        (void)recorder_dispatch_one(engine, &ev);
    }
}

/* Every record goes out here. [LGRA.24.3]: the `initial` block's faults go out right
   after the step's next record, its input. */
static ds_result_t recorder_dispatch(struct ds_engine *engine,
                                      ds_stream_ev_t   *ev)
{
    if (engine->recorder.muted) return DS_OK_R;
    ds_result_t r = recorder_dispatch_one(engine, ev);
    if (engine->recorder.block_faults_pending > 0)
        recorder_flush_block_faults(engine);
    return r;
}

static ds_result_t recorder_dispatch_one(struct ds_engine *engine,
                                          ds_stream_ev_t   *ev)
{
    /* [LERR.1.4.7]. */
    if (engine->recorder.closed) return DS_OK_R;
    if (ev->kind == DS_EV_ENGINE_ERROR) engine->recorder.closed = true;
    ev->seq = engine->next_seq++;

    /* [LFST.5.6]: a fact's event_id derives from the seq of its first FactAssert. Here,
       so a cascade assert flushed from the defer buffer gets the seq it carries. */
    if (ev->kind == DS_EV_FACT_ASSERT && ev->p.fact_assert.fact != NULL
            && !ev->p.fact_assert.fact->assert_seq_set) {
        ev->p.fact_assert.fact->assert_seq     = ev->seq;
        ev->p.fact_assert.fact->assert_seq_set = true;
    }

    ds_result_t r = ds_clock_now_ns(&engine->clock, &ev->clock_ns);
    if (r.status != DS_OK) {
        return r;
    }

    ds_metric_label_t lbl = { .key = "kind", .value = ds_event_kind_name(ev->kind) };
    ds_metric_t m = {
        .name = "ds.recorder.events_emitted_total",
        .kind = DS_METRIC_COUNTER, .value = 1.0,
        .labels = &lbl, .n_labels = 1,
    };
    ds_telemetry_emit_metric(engine, &m);

    ds_stream_cb_t  cb   = engine->recorder.stream_cb;
    void           *user = engine->recorder.stream_user;
    if (cb == NULL) {
        return DS_OK_R;
    }
    ds_callback_enter(engine);   /* [RARC.13.16], [LDET.3.6.1] — integrator code from here */
    ds_result_t cr = cb(engine, ev, user);
    ds_callback_leave(engine);
    /* [NCBK.1.5], [NCBK.2.1]: kept, never acted on. The outermost public call reports it. */
    if (cr.status != DS_OK && engine->stream_status.status == DS_OK) {
        engine->stream_status = cr;
    }
    return DS_OK_R;
}

/* The outermost call owns the engine's floating point ([LDET.3.6.1]). */
void ds_api_enter(struct ds_engine *engine)
{
    if (engine == NULL) return;
    if (engine->api_depth++ == 0) {
        engine->stream_status = DS_OK_R;
        engine->halted_at_entry = engine->halted;
        ds_fp_establish(engine);
    }
}

ds_result_t ds_api_leave(struct ds_engine *engine, ds_result_t r)
{
    if (engine == NULL) return r;
    bool outermost = engine->api_depth == 1;
    /* [LGRA.24.3]: a first step that recorded nothing after its TICK records the block's
       faults here, ahead of the fault facts the drain asserts for them.

       [LERR.9.7]: for a host call, "when the current propagation has completed" is here.
       Before the environment is restored below: the drain propagates, in the engine's
       rounding mode ([LDET.3.6.1]). */
    if (outermost && engine->recorder.block_faults_pending > 0
            && !engine->recorder.muted)
        recorder_flush_block_faults(engine);
    if (outermost && !engine->halted && engine->rete_engine != NULL)
        (void)ds_rete_fault_fact_drain(engine->rete_engine);
    if (engine->api_depth > 0) engine->api_depth--;
    if (engine->api_depth != 0) return r;
    if (outermost) ds_fp_restore(engine);
    ds_result_t s = engine->stream_status;
    engine->stream_status = DS_OK_R;
    /* [NCBK.2.9]: the call that raised the EngineError reports the halt, ahead of any
       status it would have returned. */
    if (engine->halted && !engine->halted_at_entry
            && r.status != DS_ERR_CONTRACT_WCET_HALT)
        return DS_ERR_R(DS_ERR_ENGINE_HALTED,
                        "engine halted by an EngineError during this call; "
                        "state is no longer trustworthy");
    return r.status != DS_OK ? r : s;
}

ds_result_t ds_recorder_emit_fact_assert(struct ds_engine *engine,
                                          struct ds_fact   *fact)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_FACT_ASSERT;
    ev.p.fact_assert.fact = fact;
    if (ds_recorder_should_buffer(engine)) {
        recorder_defer_push(engine, &ev, NULL);
        return DS_OK_R;
    }
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_fact_retract(struct ds_engine *engine,
                                           struct ds_fact   *fact)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_FACT_RETRACT;
    ev.p.fact_retract.fact = fact;
    /* The caller (ds_rete_wm_retract_bridge) detached the wrapper instead of freeing it,
       transferring ownership here: every buffered retract is paired with a detach. */
    if (ds_recorder_should_buffer(engine)) {
        recorder_defer_push(engine, &ev, fact);
        return DS_OK_R;
    }
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_rule_fire_begin(struct ds_engine *engine,
                                              const char       *rule_name,
                                              int64_t           timetag)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_RULE_FIRE_BEGIN;
    ev.p.rule_fire_begin.rule_name = rule_name;
    ev.p.rule_fire_begin.timetag = timetag;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_rule_fire_end(struct ds_engine *engine,
                                            const char       *rule_name,
                                            int64_t           timetag)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_RULE_FIRE_END;
    ev.p.rule_fire_end.rule_name = rule_name;
    ev.p.rule_fire_end.timetag = timetag;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_action_publish(struct ds_engine *engine,
                                             struct ds_fact   *fact,
                                             const uint8_t    *external,
                                             size_t            external_len)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_ACTION_PUBLISH;
    ev.p.action_publish.fact = fact;
    ev.p.action_publish.external     = external;
    ev.p.action_publish.external_len = external != NULL ? external_len : 0;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_action_emit(struct ds_engine *engine,
                                          struct ds_fact   *fact)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_ACTION_EMIT;
    ev.p.action_emit.fact = fact;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_action_log(struct ds_engine *engine,
                                         ds_log_level_t   level,
                                         const char      *category,
                                         const char      *message)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_ACTION_LOG;
    ev.p.action_log.level    = level;
    ev.p.action_log.category = category;
    ev.p.action_log.message  = message;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_action_cache_set(struct ds_engine *engine,
                                               const char       *key,
                                               const ds_json_t  *value,
                                               uint64_t          ttl_ns)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_ACTION_CACHE_SET;
    ev.p.action_cache_set.key    = key;
    ev.p.action_cache_set.value  = value;
    ev.p.action_cache_set.ttl_ns = ttl_ns;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_action_cache_delete(struct ds_engine *engine,
                                                  const char      *key)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_ACTION_CACHE_DELETE;
    ev.p.action_cache_delete.key = key;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_action_call(struct ds_engine *engine,
                                          const char       *service,
                                          const char       *correlation,
                                          const ds_arg_t   *args,
                                          uint32_t          arg_count,
                                          int64_t           timetag,
                                          const char       *rule_name)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_ACTION_CALL;
    ev.p.action_call.service     = service;
    ev.p.action_call.correlation = correlation;
    ev.p.action_call.args        = args;
    ev.p.action_call.arg_count   = arg_count;
    ev.p.action_call.timetag     = timetag;
    ev.p.action_call.rule_name   = rule_name;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_tick(struct ds_engine *engine)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_TICK;
    /* [RFCS.10.3]: the wall sample rides in the payload. */
    ds_result_t r = ds_clock_wall_ns(&engine->clock, &ev.p.tick.wall_ns,
                                     &ev.p.tick.wall_set);
    if (r.status != DS_OK) return r;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_pump(struct ds_engine *engine)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_PUMP;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_bounds_error(struct ds_engine *engine,
                                            ds_cap_name_t     cap,
                                            uint64_t          limit,
                                            uint64_t          observed,
                                            const char       *rule_name,
                                            int64_t           timetag)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    /* [RFCS.6.7]: a no-op when no host assert is in flight. */
    recorder_emit_refused_input(engine);
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_BOUNDS_ERROR;
    ev.p.bounds_error.cap       = cap;
    ev.p.bounds_error.limit     = limit;
    ev.p.bounds_error.observed  = observed;
    ev.p.bounds_error.rule_name = rule_name;
    ev.p.bounds_error.timetag   = timetag;
    return recorder_dispatch(engine, &ev);
}

/* Buffered like a cascade fact record ([LFST.7.3.6]): a join test can run inside a
   truth-maintenance cascade. */
static ds_result_t recorder_emit_fault(struct ds_engine *engine,
                                        ds_stream_ev_t   *ev)
{
    /* The latch, set before the event goes anywhere: a buffered event and a dispatched
       one both mean engine state is no longer trustworthy. */
    if (engine != NULL && ev->kind == DS_EV_ENGINE_ERROR) {
        /* The first fault is the cause. */
        if (!engine->halted) {
            engine->halt_fault = ev->p.engine_error.fault;
        }
        engine->halted = true;
    }
    if (ds_recorder_should_buffer(engine)) {
        recorder_defer_push(engine, ev, NULL);
        return DS_OK_R;
    }
    /* [RFCS.6.7]. */
    if (engine != NULL && engine->recorder.hold_depth > 0) {
        recorder_hold_push(engine, ev);
        return DS_OK_R;
    }
    return recorder_dispatch(engine, ev);
}

ds_result_t ds_recorder_emit_type_error(struct ds_engine *engine,
                                          uint32_t          node_id,
                                          const char       *rule_name,
                                          const char       *schema_name,
                                          const char       *slot_name,
                                          const char       *actual)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_TYPE_ERROR;
    ev.p.type_error.node_id     = node_id;
    ev.p.type_error.schema_name = schema_name;
    ev.p.type_error.slot_name   = slot_name;
    ev.p.type_error.actual      = actual;
    ev.p.type_error.rule_name   = rule_name;
    return recorder_emit_fault(engine, &ev);
}

ds_result_t ds_recorder_emit_computation_error(struct ds_engine *engine,
                                                 ds_trap_kind_t    kind,
                                                 const char       *rule_name,
                                                 int64_t           timetag,
                                                 const char       *schema_name,
                                                 const char       *slot_name,
                                                 uint64_t          fact_id,
                                                 uint32_t          node_id)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_COMPUTATION_ERROR;
    ev.p.computation_error.kind        = kind;
    ev.p.computation_error.rule_name   = rule_name;
    ev.p.computation_error.timetag     = timetag;
    ev.p.computation_error.schema_name = schema_name;
    ev.p.computation_error.slot_name   = slot_name;
    ev.p.computation_error.fact_id     = fact_id;
    ev.p.computation_error.node_id     = node_id;
    return recorder_emit_fault(engine, &ev);
}

ds_result_t ds_recorder_emit_engine_error(struct ds_engine  *engine,
                                            ds_engine_fault_t  fault,
                                            uint32_t           node_id,
                                            const char        *rule_name)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_ENGINE_ERROR;
    ev.p.engine_error.fault     = fault;
    ev.p.engine_error.node_id   = node_id;
    ev.p.engine_error.rule_name = rule_name;
    return recorder_emit_fault(engine, &ev);
}

ds_result_t ds_recorder_emit_rule_lhs_facts(struct ds_engine *engine,
                                              const char       *rule_name,
                                              int64_t           timetag,
                                              struct ds_fact  **facts,
                                              uint32_t          fact_count)
{
    if (engine == NULL || fact_count == 0) return DS_OK_R;
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_RULE_LHS_FACTS;
    ev.p.rule_lhs_facts.rule_name   = rule_name;
    ev.p.rule_lhs_facts.facts       = facts;
    ev.p.rule_lhs_facts.fact_count  = fact_count;
    ev.p.rule_lhs_facts.timetag     = timetag;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_recorder_emit_timer_armed(struct ds_engine *engine,
                                           const char       *rule_name,
                                           int64_t           timetag,
                                           const char       *kind,
                                           uint64_t          window_ns,
                                           uint64_t          fire_at_ns)
{
    if (engine == NULL) return DS_OK_R;
    ds_stream_ev_t ev = {0};
    ev.kind = DS_EV_TIMER_ARMED;
    ev.p.timer_armed.rule_name = rule_name;
    ev.p.timer_armed.kind      = kind;
    ev.p.timer_armed.window_ns = window_ns;
    ev.p.timer_armed.fire_at_ns = fire_at_ns;
    ev.p.timer_armed.timetag   = timetag;
    return recorder_dispatch(engine, &ev);
}

ds_result_t ds_engine_set_stream_callback(ds_engine_t    *engine,
                                          ds_stream_cb_t  cb,
                                          void           *user)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    engine->recorder.stream_cb   = cb;
    engine->recorder.stream_user = user;
    return DS_OK_R;
}

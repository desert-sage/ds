/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * dispatcher.c — action-verb dispatch.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "libds.h"
#include "internal/json.h"

#include "clock.h"
#include "dispatcher.h"
#include "engine.h"
#include "float_fmt.h"
#include "recorder.h"
#include "schema.h"
#include "telemetry.h"

#include "rete/adapters.h"
#include "rete/engine.h"
#include "rete/fact.h"
#include "rete/intern.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/tms.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"


ds_result_t ds_dispatcher_init(ds_dispatcher_state_t *d,
                                struct ds_engine      *engine)
{
    if (d == NULL || engine == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "dispatcher_init: null arg");
    memset(d, 0, sizeof(*d));
    d->engine = engine;
    return DS_OK_R;
}

ds_result_t ds_dispatcher_destroy(ds_dispatcher_state_t *d)
{
    if (d == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "dispatcher_destroy: null arg");
    memset(d, 0, sizeof(*d));
    return DS_OK_R;
}


ds_result_t ds_engine_set_call_callback(ds_engine_t  *engine,
                                         ds_call_cb_t  cb,
                                         void         *user)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    engine->dispatcher.call_cb   = cb;
    engine->dispatcher.call_user = user;
    return DS_OK_R;
}

ds_result_t ds_engine_cache_callbacks(ds_engine_t          *engine,
                                       uint32_t              abi_version,
                                       ds_cache_set_cb_t    set_cb,
                                       ds_cache_delete_cb_t delete_cb,
                                       void                *user)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    /* [ISBK.1.7]: covers a binary compiled against another header. */
    if (abi_version != DS_CACHE_CB_ABI_VERSION) {
        return DS_ERR_R(DS_ERR_BACKEND_ABI_VERSION,
                        "cache callbacks: ABI version mismatch — rebuild "
                        "against this libds (DS_CACHE_CB_ABI_VERSION)");
    }
    engine->dispatcher.cache_set_cb    = set_cb;
    engine->dispatcher.cache_delete_cb = delete_cb;
    engine->dispatcher.cache_user      = user;
    return DS_OK_R;
}

ds_result_t ds_dispatcher_notify_cache_removal(struct ds_engine *engine,
                                                const char       *key,
                                                ds_cache_removal_reason_t reason)
{
    if (engine == NULL || key == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "notify_cache_removal: null");
    if (engine->dispatcher.replay_depth > 0) return DS_OK_R;
    ds_cache_delete_cb_t cb = engine->dispatcher.cache_delete_cb;
    if (cb == NULL) return DS_OK_R;
    ds_cache_removal_t removal = { .key = key, .reason = reason };
    ds_callback_enter(engine);   /* [RARC.13.16], [LDET.3.6.1] */
    ds_result_t r = cb(engine, &removal, engine->dispatcher.cache_user);
    ds_callback_leave(engine);
    return r;
}

ds_result_t ds_dispatcher_notify_cache_set(struct ds_engine *engine,
                                           const char       *key,
                                           const ds_json_t  *tree,
                                           uint64_t          ttl_ns)
{
    if (engine == NULL || key == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "notify_cache_set: null");
    if (engine->dispatcher.replay_depth > 0) return DS_OK_R;
    ds_cache_set_cb_t cb = engine->dispatcher.cache_set_cb;
    if (cb == NULL) return DS_OK_R;
    const ds_cache_write_t write = { .key = key, .value = tree, .ttl_ns = ttl_ns };
    ds_callback_enter(engine);   /* [RARC.13.16], [LDET.3.6.1] */
    ds_result_t r = cb(engine, &write, engine->dispatcher.cache_user);
    ds_callback_leave(engine);
    return r;
}

void ds_dispatcher_replay_enter(struct ds_engine *engine)
{
    if (engine != NULL) engine->dispatcher.replay_depth++;
}

void ds_dispatcher_replay_leave(struct ds_engine *engine)
{
    if (engine != NULL && engine->dispatcher.replay_depth > 0)
        engine->dispatcher.replay_depth--;
}


/* ===========================================================
 * AOT direct-call entry points ([IDSP.14], [RAOT.6]).
 * ===========================================================
 */

#include "engine.h"

ds_result_t ds_dispatcher_log(struct ds_engine *engine,
                               ds_log_level_t    level,
                               const char       *rule_name,
                               const char       *message)
{
    if (!engine || !message) return DS_OK_R;
    /* [IDSP.2.5]: this entry point is a raw C call, with no compiler in between. */
    if (level < DS_LOG_DEBUG || level > DS_LOG_CRITICAL)
        return DS_ERR_R(DS_ERR_INVAL, "dispatcher_log: level out of range");
    const char *cat = rule_name ? rule_name : "";
    ds_recorder_emit_action_log(engine, level, cat, message);
    ds_log_event_t ev = { .level = level, .category = cat, .message = message };
    return ds_telemetry_emit_log(engine, &ev);
}

/* The canonical formatter ([LDET.3.2.7]), as the interpreted display path uses. */
void ds_dispatcher_fmt_float(char *buf, size_t cap, double v)
{
    if (!buf || cap == 0) return;
    ds_fmt_float(buf, cap, v);
}

/* ---- AOT assert surface --------------------------------------------
 *
 * Slots 0 and 1, for a compiled RHS's `emit` and `publish`, which has already
 * evaluated every slot. They mirror eval_actions (rete/engine.c) and
 * adapter_ds_publish (rete/adapters.c), which asserts nothing ([LTIE.4.3]).
 */

/* Intern String/Bytes slot values, assert, and return the new fact. A slot value may
   point into the per-pump arena, reset on the next pump. */
static ds_result_t aot_assert(struct ds_rete_engine   *re,
                               const char              *schema_name,
                               struct ds_rete_val      *slots,
                               uint32_t                 slot_count,
                               const ds_rete_schema_t **out_schema,
                               struct ds_rete_fact    **out_fact)
{
    /* Look up, not intern: a pinned insert after the structural set is frozen
       aborts ([IRET.1.4]), and a name absent from the table is an unknown schema. */
    const char *iname = NULL;
    ds_result_t r = ds_rete_intern_find(re->intern, schema_name,
                                        strlen(schema_name), &iname);
    if (r.status != DS_OK) return r;

    const ds_rete_schema_t *schema =
        (iname != NULL) ? ds_rete_schema_by_name(re, iname) : NULL;
    if (schema == NULL)
        return DS_ERR_R(DS_ERR_SCHEMA_UNKNOWN,
                        "aot assert: unknown schema");

    if (slot_count != (uint32_t)schema->slot_count)
        return DS_ERR_R(DS_ERR_INVAL,
                        "aot assert: slot count disagrees with schema");

    for (uint32_t i = 0; i < slot_count; i++) {
        const char *ip = NULL;
        if (slots[i].kind == DS_RETE_VAL_STR && slots[i].s.ptr != NULL) {
            if (ds_rete_intern_value(re->intern, slots[i].s.ptr,
                                     slots[i].s.len, &ip).status == DS_OK)
                slots[i] = ds_rete_val_str(ip, slots[i].s.len);
        } else if (slots[i].kind == DS_RETE_VAL_BYTES && slots[i].s.ptr != NULL) {
            if (ds_rete_intern_value(re->intern, slots[i].s.ptr,
                                     slots[i].s.len, &ip).status == DS_OK)
                slots[i] = ds_rete_val_bytes(ip, slots[i].s.len);
        }
    }

    if (out_schema) *out_schema = schema;
    return ds_rete_wm_assert(re, schema->id, slots, out_fact);
}

/* The firing activation's identity, which rete/engine.c publishes for the duration
   of the fire. (0, NULL) outside one. */
static void aot_fire_identity(struct ds_rete_engine *re,
                               int64_t               *out_timetag,
                               const char           **out_rule)
{
    *out_timetag = 0;
    *out_rule    = NULL;
    if (re == NULL) return;
    if (re->current_fire_token != NULL)
        *out_timetag = re->current_fire_token->creation_timetag;
    *out_rule = re->current_fire_rule;
}

/* The local TMS justifier ([LLOG.15.1]). `justifier` NULL is the firing token.
   *unjustified is for a new fact nothing holds once the firing's own match has
   ended, which the caller retracts after its records. */
static ds_result_t aot_justify(struct ds_rete_engine *re,
                                struct ds_rete_fact   *fact,
                                struct ds_rete_token  *justifier,
                                bool                   made,
                                bool                  *unjustified)
{
    *unjustified = false;
    if (fact == NULL) return DS_OK_R;
    struct ds_rete_token *tok = justifier ? justifier : re->current_fire_token;
    if (tok == NULL || re->current_fire_rule == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "aot assert: logical assert outside a rule fire");
    }
    return ds_rete_terminal_justify(re, tok->creation_timetag,
                                    re->current_fire_rule, fact, made,
                                    unjustified);
}

ds_result_t ds_dispatcher_wm_assert(struct ds_engine    *engine,
                                     const char           *schema_name,
                                     struct ds_rete_val   *slots,
                                     uint32_t              slot_count,
                                     bool                  is_logical,
                                     struct ds_rete_token *justifier)
{
    if (!engine || !schema_name || (slot_count > 0 && !slots))
        return DS_ERR_R(DS_ERR_INVAL, "dispatcher_wm_assert: null");
    struct ds_rete_engine *re = engine->rete_engine;
    if (!re)
        return DS_ERR_R(DS_ERR_INVAL, "dispatcher_wm_assert: no rete engine");

    struct ds_rete_fact *fact = NULL;
    const uint32_t first_new_id = re->next_fact_id;
    ds_result_t r = aot_assert(re, schema_name, slots, slot_count, NULL, &fact);
    if (r.status != DS_OK) return r;

    bool unjustified = false;
    if (is_logical) {
        r = aot_justify(re, fact, justifier,
                        fact != NULL && fact->id >= first_new_id,
                        &unjustified);
        if (r.status != DS_OK) {
            /* [RFCS.6a.4]: emit_cb is not reached, so a fact this assert
               superseded is recorded as withdrawn here. */
            ds_rete_wm_settle_supersede(re);
            return r;
        }
    }

    if (fact && re->adapter.emit_cb)
        re->adapter.emit_cb(re, fact, re->adapter.emit_user);
    if (fact && re->adapter.emit_action_cb)
        re->adapter.emit_action_cb(re, fact, re->adapter.emit_action_user);
    if (unjustified) ds_rete_terminal_retract_unjustified(re, fact);

    return DS_OK_R;
}

ds_result_t ds_dispatcher_publish(struct ds_engine   *engine,
                                   const char          *schema_name,
                                   struct ds_rete_val  *slots,
                                   uint32_t             slot_count,
                                   bool                 is_logical,
                                   int64_t              retain_ns)
{
    if (!engine || !schema_name || (slot_count > 0 && !slots))
        return DS_ERR_R(DS_ERR_INVAL, "dispatcher_publish: null");
    struct ds_rete_engine *re = engine->rete_engine;
    if (!re)
        return DS_ERR_R(DS_ERR_INVAL, "dispatcher_publish: no rete engine");

    /* [LTIE.4.3], [LTIE.4.9]: a `publish` asserts nothing and takes no
       lifetime, so `is_logical` and `retain_ns`, the dispatch table's fixed
       shape, are not read. */
    (void)is_logical;
    (void)retain_ns;

    /* Looked up, not interned, for aot_assert's reason (AOTINTERN1). */
    const char *iname = NULL;
    ds_result_t r = ds_rete_intern_find(re->intern, schema_name,
                                        strlen(schema_name), &iname);
    if (r.status != DS_OK) return r;
    const ds_rete_schema_t *schema =
        (iname != NULL) ? ds_rete_schema_by_name(re, iname) : NULL;
    if (schema == NULL)
        return DS_ERR_R(DS_ERR_SCHEMA_UNKNOWN, "aot publish: unknown schema");
    if (slot_count != (uint32_t)schema->slot_count)
        return DS_ERR_R(DS_ERR_INVAL,
                        "aot publish: slot count disagrees with schema");

    /* Judged and sent as the interpreted `publish` is, with no eval context:
       a compiled RHS has no activation to abandon. */
    return ds_rete_publish_values(re, NULL, schema, slots);
}

/* ---- The arrival supersede ([LCRS.6.2.4]) --------------------------
 *
 *   a fact of a response schema T, `corr` K  ->  T's live K, then CallError's;
 *   a CallError, `corr` K                    ->  CallError's live K, then every
 *                                                response schema's, in
 *                                                registration order.
 *
 * An empty `corr` supersedes nothing. The engine keeps no pending-call state.
 */
static const ds_slot_value_t *answer_corr(const ds_schema_t     *schema,
                                          const ds_slot_value_t *values,
                                          uint32_t               n_values)
{
    for (uint32_t i = 0; i < n_values && i < schema->n_slots; i++) {
        if (schema->slots[i].name != NULL
            && strcmp(schema->slots[i].name, "corr") == 0)
            return &values[i];
    }
    return NULL;
}

ds_result_t ds_dispatch_supersede_arrival(struct ds_engine      *engine,
                                          const ds_schema_t     *schema,
                                          const ds_slot_value_t *values,
                                          uint32_t               n_values)
{
    if (engine == NULL || schema == NULL || schema->type_name == NULL)
        return DS_OK_R;
    const bool is_error = strcmp(schema->type_name, "CallError") == 0;
    if (!is_error && !schema->call_response) return DS_OK_R;
    if (engine->rete_engine == NULL) return DS_OK_R;

    const ds_slot_value_t *cv = answer_corr(schema, values, n_values);
    if (cv == NULL || cv->kind != DS_SLOT_STRING || cv->v.s == NULL
        || cv->v.s[0] == '\0')
        return DS_OK_R;
    const ds_rete_val_t key =
        ds_rete_val_str(cv->v.s, (uint32_t)strlen(cv->v.s));

    struct ds_rete_engine *re = engine->rete_engine;
    ds_result_t r;
    if (!is_error) {
        r = ds_rete_retract_corr_sweep(re, schema->type_name, "corr", &key);
        if (r.status != DS_OK) return r;
        return ds_rete_retract_corr_sweep(re, "CallError", "corr", &key);
    }
    r = ds_rete_retract_corr_sweep(re, "CallError", "corr", &key);
    if (r.status != DS_OK) return r;
    for (size_t i = 0; i < engine->schemas.n_schemas; i++) {
        const ds_schema_t *s = engine->schemas.schemas[i];
        if (s == NULL || !s->call_response || s->type_name == NULL) continue;
        r = ds_rete_retract_corr_sweep(re, s->type_name, "corr", &key);
        if (r.status != DS_OK) return r;
    }
    return DS_OK_R;
}

/* ---- A call's own supersede ([LCRS.6.2.1]) --------------------------
 *
 * The response schema's live facts with the call's correlation, then CallError's.
 * Only for a call that is issued. A `no response` service sweeps CallError alone.
 */
static ds_result_t lcrs_6_2_1_call_supersede(struct ds_engine *engine,
                                             const char       *service,
                                             const char       *correlation)
{
    struct ds_rete_engine *re = engine->rete_engine;
    if (re == NULL) return DS_OK_R;
    const ds_rete_val_t key =
        ds_rete_val_str(correlation, (uint32_t)strlen(correlation));

    /* Of two ServiceDefs for one service, the later wins. */
    const char *response = NULL;
    for (size_t i = 0; i < engine->n_call_services; i++)
        if (strcmp(engine->call_services[i].name, service) == 0)
            response = engine->call_services[i].response;

    if (response != NULL && response[0] != '\0') {
        ds_result_t r = ds_rete_retract_corr_sweep(re, response, "corr", &key);
        if (r.status != DS_OK) return r;
    }
    return ds_rete_retract_corr_sweep(re, "CallError", "corr", &key);
}

/* [IDSP.1.4], [IDSP.6.5]: the event precedes the callback. The arguments arrive
   sorted by name ([RLOW.7.3.1]). */
ds_result_t ds_dispatcher_call_typed(struct ds_engine *engine,
                                      const char       *service,
                                      const char       *correlation,
                                      const ds_arg_t   *args,
                                      uint32_t          arg_count,
                                      int64_t           timetag,
                                      const char       *rule_name)
{
    if (!engine || !service || (arg_count > 0 && !args))
        return DS_ERR_R(DS_ERR_INVAL, "dispatcher_call: null");

    /* [LCRS.3.1]: a shape the compiler does not write. */
    if (!correlation)
        return DS_ERR_R(DS_ERR_INVAL,
                        "dispatcher_call: a call with no correlation ([LCRS.3.1])");

    for (uint32_t i = 0; i < arg_count; i++) {
        if (args[i].value.kind == DS_ARG_FLOAT
            && args[i].value.v.f != args[i].value.v.f)
            return DS_ERR_R(DS_ERR_NAN_REJECTED,
                            "dispatcher_call: a NaN Float argument refuses the call");
    }

    ds_result_t sr = lcrs_6_2_1_call_supersede(engine, service, correlation);
    if (sr.status != DS_OK) return sr;

    ds_recorder_emit_action_call(engine, service, correlation, args, arg_count,
                                 timetag, rule_name);

    /* [NDET.8.2], [IDSP.6.4]: a replay hands the re-derived call to nobody. */
    if (engine->dispatcher.replay_depth > 0) return DS_OK_R;

    ds_result_t r = DS_OK_R;
    ds_call_cb_t cb = engine->dispatcher.call_cb;
    if (!cb) {
        r = DS_ERR_R(DS_ERR_STORAGE_UNAVAILABLE, "dispatcher_call: no call callback");
    } else {
        ds_call_request_t req = {
            .service   = service, .correlation = correlation,
            .args      = args,    .arg_count   = arg_count,
            .timetag   = timetag, .rule_name   = rule_name,
        };
        ds_callback_enter(engine);   /* [RARC.13.16], [LDET.3.6.1] */
        r = cb(engine, &req, engine->dispatcher.call_user);
        ds_callback_leave(engine);
    }
    return r;
}

ds_result_t ds_dispatcher_call(struct ds_engine *engine,
                                const char       *service,
                                const char       *correlation,
                                const ds_arg_t   *args,
                                uint32_t          arg_count,
                                uint64_t          cooldown_ns)
{
    /* The cooldown is the compiler's IfExpr around the call ([IRET.25.5.1]). The
       parameter stays in the frozen slot table ([IDSP.14]). */
    (void)cooldown_ns;
    if (!engine || !service) return DS_ERR_R(DS_ERR_INVAL, "dispatcher_call: null");
    int64_t     timetag   = 0;
    const char *rule_name = NULL;
    aot_fire_identity(engine->rete_engine, &timetag, &rule_name);

    return ds_dispatcher_call_typed(engine, service, correlation, args,
                                    arg_count, timetag, rule_name);
}

/* [LSTO.4.7.2]: validate, mutate engine->cache, record, then mirror to the hook. A
 * refused write leaves the cache untouched; a hook failure propagates with no
 * rollback. */
ds_result_t ds_dispatcher_cache_set(struct ds_engine *engine,
                                     const char       *key,
                                     const char       *value_json,
                                     int64_t           ttl_ns)
{
    if (!engine || !key) return DS_ERR_R(DS_ERR_INVAL, "dispatcher_cache_set: null");

    /* [IDSP.7.10] */
    if (ttl_ns < 0)
        return DS_ERR_R(DS_ERR_INVAL, "dispatcher_cache_set: negative ttl");

    /* NULL or empty is a legal erase-shaped write, and not JSON. */
    ds_json_t *tree = NULL;
    if (value_json && value_json[0]) {
        /* The engine's own serialization: tree limits, no text limit. */
        ds_result_t jr = ds_json_parse_limited(value_json, strlen(value_json),
                                               &tree, NULL, false);
        if (jr.status != DS_OK) {
            if (tree) ds_json_free(tree);
            return DS_ERR_R(DS_ERR_INVAL,
                            "dispatcher_cache_set: value is not valid JSON");
        }
    }

    uint64_t now_ns = 0;
    ds_clock_now_ns(&engine->clock, &now_ns);
    uint64_t ttl_u = (uint64_t)ttl_ns;

    ds_result_t r = ds_cache_set(&engine->cache, key, value_json, ttl_u, now_ns);
    if (r.status != DS_OK) {
        /* [NCBK.2.8] */
        if (engine->cache.breach_cap != DS_CAP_UNSPECIFIED)
            (void)ds_recorder_emit_bounds_error(engine, engine->cache.breach_cap,
                                                engine->cache.breach_limit,
                                                engine->cache.breach_observed,
                                                ds_engine_current_fire_rule(engine), 0);
        if (tree) ds_json_free(tree);
        return r;
    }

    ds_recorder_emit_action_cache_set(engine, key, tree, ttl_u);

    ds_result_t ret = ds_dispatcher_notify_cache_set(engine, key, tree, ttl_u);
    if (tree) ds_json_free(tree);
    return ret;
}

ds_result_t ds_dispatcher_cache_delete(struct ds_engine *engine,
                                        const char       *key)
{
    if (!engine || !key) return DS_ERR_R(DS_ERR_INVAL, "dispatcher_cache_delete: null");

    ds_cache_delete(&engine->cache, key);
    ds_recorder_emit_action_cache_delete(engine, key);

    return ds_dispatcher_notify_cache_removal(engine, key,
                                              DS_CACHE_REMOVED_DELETE);
}

void ds_dispatcher_init_dispatch_table(struct ds_engine *engine)
{
    engine->dispatch_table.wm_assert    = ds_dispatcher_wm_assert;
    engine->dispatch_table.publish      = ds_dispatcher_publish;
    engine->dispatch_table.call         = ds_dispatcher_call;
    engine->dispatch_table.cache_set    = ds_dispatcher_cache_set;
    engine->dispatch_table.cache_delete = ds_dispatcher_cache_delete;
    engine->dispatch_table.reserved5    = NULL;
    engine->dispatch_table.log          = ds_dispatcher_log;
    engine->dispatch_table.fmt_float    = ds_dispatcher_fmt_float;
}

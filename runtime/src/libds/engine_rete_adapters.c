/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * engine_rete_adapters.c — bridge between the DS Rete adapter callbacks and the DS
 * engine's dispatcher, telemetry and recorder. Every bridge's `user` is the
 * ds_engine_t *, and each reads dispatcher state at call time, so it sees callbacks
 * registered after engine creation.
 */
#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "internal/json.h"   /* ds_json_parse_limited ([LGRA.5.8.6]) */
#include "ds_alloc.h"
#include "ds_text.h"
#include "engine.h"
#include "schema.h"
#include "dispatcher.h"
#include "recorder.h"
#include "telemetry.h"
#include "clock.h"
#include "rete/adapters.h"
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/terminal.h"
#include "rete/tms.h"
#include "rete/token.h"
#include "rete/eval.h"
#include "rete/val.h"
#include "rete/wm_rete.h"
#include "rete/schema_reg.h"
#include "rete/intern.h"
#include "wm.h"
#include "rfcs/rfcs.h"   /* DS_FWTH_CAUSE_* */
#include "fn.h"
#include "series/state.h"
#include "series/dispatch.h"
#include "rete/fact.h"

/* ---- log bridge --------------------------------------------------- */

static ds_result_t bridge_log(struct ds_rete_engine      *re,
                               const ds_rete_log_event_t  *ev,
                               void                       *user)
{
    (void)re;
    ds_engine_t *engine = (ds_engine_t *)user;

    ds_recorder_emit_action_log(engine,
                                 ev->level,
                                 ev->category ? ev->category : "",
                                 ev->message  ? ev->message  : "");

    ds_log_event_t ds_ev = {
        .level    = ev->level,
        .category = ev->category,
        .message  = ev->message,
    };
    return ds_telemetry_emit_log(engine, &ds_ev);
}

/* An essential verb's failure surfaces from ds_engine_pump: the rete eval path
   discards a CALL action's result. `log` does not stash. */
static ds_result_t essential_fail(ds_engine_t *engine, ds_result_t r)
{
    ds_engine_set_pending(engine, r);
    return r;
}

/* ---- call bridge --------------------------------------------------- */

/* [NCBK.6.10]: the kind is the value's representation, not its declared type: a Time
   crosses as its utc_ns Int. A fact crosses as its FactExternal ([RFCS.23.1]), packed
   into `*owned`, which the caller frees once the call has returned.

   The fact is live: [LGRA.10.1.3] and [LCYC.3.1.1] refuse every way the firing's
   earlier actions could remove it, so the refusal below is a guard, for an artefact
   the compiler did not write. */
static ds_result_t call_arg_value(ds_engine_t *engine, const ds_rete_val_t *v,
                                  ds_arg_value_t *out, uint8_t **owned)
{
    *owned = NULL;
    switch (v->kind) {
    case DS_RETE_VAL_INT:
        out->kind = DS_ARG_INT;    out->v.i = v->i;            return DS_OK_R;
    case DS_RETE_VAL_FLOAT:
        out->kind = DS_ARG_FLOAT;  out->v.f = v->f;            return DS_OK_R;
    case DS_RETE_VAL_STR:
        out->kind = DS_ARG_STRING; out->v.s = v->s.ptr;        return DS_OK_R;
    case DS_RETE_VAL_BOOL:
        out->kind = DS_ARG_BOOL;   out->v.b = v->b;            return DS_OK_R;
    case DS_RETE_VAL_JSON:
    case DS_RETE_VAL_JSON_BORROW:
        out->kind = DS_ARG_JSON;   out->v.json = v->json;      return DS_OK_R;
    case DS_RETE_VAL_BYTES:
        out->kind = DS_ARG_BYTES;
        out->v.bytes.data = (const uint8_t *)v->s.ptr;
        out->v.bytes.len  = v->s.len;
        return DS_OK_R;
    case DS_RETE_VAL_TIME:
        out->kind = DS_ARG_INT;    out->v.i = v->time.utc_ns;  return DS_OK_R;
    case DS_RETE_VAL_FACT_REF: {
        ds_fact_t *f = NULL;
        ds_result_t fr = ds_engine_fact_by_rete_id(engine, v->fact_ref_id, &f);
        if (fr.status != DS_OK) return fr;
        if (f == NULL || f->schema == NULL)
            return DS_ERR_R(DS_ERR_INVAL,
                            "ds-call: a fact argument that is not in working memory");
        size_t len = 0;
        fr = ds_fact_external_pack(f, owned, &len);
        if (fr.status != DS_OK) return fr;
        out->kind = DS_ARG_ENCODED_FACT;
        out->v.fact.bytes.data      = *owned;
        out->v.fact.bytes.len       = len;
        out->v.fact.schema          = f->schema->type_name;
        out->v.fact.asserted_at_set = f->asserted_wall_set;
        out->v.fact.asserted_at     = f->asserted_wall_set ? f->asserted_wall_ns : 0;
        return DS_OK_R;
    }
    case DS_RETE_VAL_NULL:      /* bridge_call stops before it gets here */
    case DS_RETE_VAL_RATIO:
    case DS_RETE_VAL_UNBOUND:
        break;
    }
    return DS_ERR_R(DS_ERR_INVAL, "ds-call: an argument of no call-argument kind");
}

static ds_result_t bridge_call(struct ds_rete_engine         *re,
                                const ds_rete_call_request_t  *req,
                                void                          *user)
{
    (void)re;
    ds_engine_t *engine = (ds_engine_t *)user;

    /* The kwargs: name, value, name, value ... ([RLOW.7.3.1]), whole pairs, since
       `adapter_ds_call` raises on an odd count ([RDSC.4a.9.3]). A VLA, so the pump
       allocates nothing for a call but a fact argument's bytes. */
    uint32_t n = req->operand_count / 2;

    /* [LNUL.11.1]: a kwarg with no value prevents the call: no event, no callback,
       no pump status. Counted once per call not issued ([NMET.4.1]). */
    for (uint32_t i = 0; i < n; i++)
        if (req->operands[2 * i + 1].kind == DS_RETE_VAL_NULL) {
            ds_metric_label_t labels[1] = {
                { .key = "service",
                  .value = req->service ? req->service : "" } };
            ds_metric_t m = {
                .name   = "ds.calls.arg_error_total",
                .kind   = DS_METRIC_COUNTER, .value = 1.0,
                .labels = labels, .n_labels = 1,
            };
            (void)ds_telemetry_emit_metric(engine, &m);
            return DS_OK_R;
        }

    ds_arg_t args[n > 0 ? n : 1];
    uint8_t *owned[n > 0 ? n : 1];
    /* For gcc's -Wmaybe-uninitialized when n == 0. */
    memset(args, 0, sizeof args);
    ds_result_t ar = DS_OK_R;
    uint32_t typed = 0;
    for (; typed < n; typed++) {
        const ds_rete_val_t *name = &req->operands[2 * typed];
        owned[typed] = NULL;
        if (name->kind != DS_RETE_VAL_STR) {
            ar = DS_ERR_R(DS_ERR_INVAL, "ds-call: a kwarg name is not a string");
            break;
        }
        args[typed].name = name->s.ptr;
        ar = call_arg_value(engine, &req->operands[2 * typed + 1],
                            &args[typed].value, &owned[typed]);
        if (ar.status != DS_OK) break;
    }
    if (ar.status != DS_OK) {
        for (uint32_t i = 0; i <= typed && i < n; i++) DS_FREE(owned[i]);
        return essential_fail(engine, ar);
    }

    ds_result_t r = ds_dispatcher_call_typed(engine, req->service,
                                             req->correlation, args, n,
                                             req->timetag, req->rule_name);
    for (uint32_t i = 0; i < n; i++) DS_FREE(owned[i]);
    return r.status == DS_OK ? DS_OK_R : essential_fail(engine, r);
}

/* ---- cache bridges ------------------------------------------------- */

/* [IDSP.7], [NCBK.2.4]: an engine-local read, with no callback and not a recorded
   output. A hit is a heap copy the adapter owns; a miss is NULL. */
static ds_result_t bridge_cache_get(struct ds_rete_engine *re,
                                     const char            *key,
                                     char                 **out_json,
                                     void                  *user)
{
    (void)re;
    ds_engine_t *engine = (ds_engine_t *)user;
    uint64_t now_ns = 0;
    ds_clock_now_ns(&engine->clock, &now_ns);

    const char *val = NULL;
    bool expired = false;
    if (ds_cache_get(&engine->cache, key, now_ns, &val, &expired) && val != NULL) {
        char *copy = DS_STRDUP(val);
        if (copy == NULL) {
            *out_json = NULL;
            ds_result_t oom = DS_ERR_R(DS_ERR_OOM, "cache: get value copy failed");
            ds_engine_set_pending(engine, oom);
            return oom;
        }
        *out_json = copy;
    } else {
        *out_json = NULL;
    }
    /* [NSTG.2.4.2]: the read's answer stands, so a failed notification is stashed. */
    if (expired) {
        ds_result_t nr = ds_dispatcher_notify_cache_removal(
                             engine, key, DS_CACHE_REMOVED_TTL);
        if (nr.status != DS_OK) ds_engine_set_pending(engine, nr);
    }
    return DS_OK_R;
}

/* [LSTO.4.7.2], [NCBK.7.5], [IDSP.7.9]: the cache, then the record ([RFCS.15.7]), then
   the optional hook. A hook's failure propagates, with no rollback. */
static ds_result_t bridge_cache_set(struct ds_rete_engine *re,
                                     const char            *key,
                                     const char            *value_json,
                                     uint64_t               ttl_ns,
                                     void                  *user)
{
    ds_engine_t *engine = (ds_engine_t *)user;
    uint64_t now_ns = 0;
    ds_clock_now_ns(&engine->clock, &now_ns);

    ds_result_t r = ds_cache_set(&engine->cache, key, value_json, ttl_ns, now_ns);
    if (r.status != DS_OK) {
        /* [NCBK.2.8]: a cap breach is a fault, recorded inside the firing. */
        if (engine->cache.breach_cap != DS_CAP_UNSPECIFIED)
            (void)ds_recorder_emit_bounds_error(engine, engine->cache.breach_cap,
                                                engine->cache.breach_limit,
                                                engine->cache.breach_observed,
                                                re ? re->current_fire_rule : NULL, 0);
        ds_engine_set_pending(engine, r);
        return r;
    }

    /* The engine's own serialization, so no text limit applies. */
    ds_json_t *tree = NULL;
    if (value_json && value_json[0])
        ds_json_parse_limited(value_json, strlen(value_json), &tree, NULL, false);
    ds_recorder_emit_action_cache_set(engine, key, tree, ttl_ns);

    ds_result_t ret = ds_dispatcher_notify_cache_set(engine, key, tree, ttl_ns);
    if (ret.status != DS_OK)
        ds_engine_set_pending(engine, ret);
    if (tree) ds_json_free(tree);
    return ret;
}

/* As bridge_cache_set. */
static ds_result_t bridge_cache_delete(struct ds_rete_engine *re,
                                        const char            *key,
                                        void                  *user)
{
    (void)re;
    ds_engine_t *engine = (ds_engine_t *)user;

    ds_cache_delete(&engine->cache, key);
    ds_recorder_emit_action_cache_delete(engine, key);

    ds_result_t ret = ds_dispatcher_notify_cache_removal(
                          engine, key, DS_CACHE_REMOVED_DELETE);
    if (ret.status != DS_OK)
        ds_engine_set_pending(engine, ret);
    return ret;
}

/* ---- publish bridge ----------------------------------------------- */

/* Defined in wm_rete_bridge.c: a `publish`'s fact view ([NCBK.2.5]). */
extern ds_result_t ds_wm_publish_view(struct ds_engine       *engine,
                                      const ds_rete_schema_t *rschema,
                                      const ds_rete_val_t    *slots,
                                      ds_fact_t             **out);

/* A `publish` whose values ds_rete_publish_values has judged ([LTIE.4.8]).
   Nothing enters working memory ([LTIE.4.3]). A `String` over its `capacity`
   is refused first ([LSTR.11.3]) and nothing is sent. The event carries a
   view, valid for the callback only ([NCBK.2.5]), and its FactExternal
   ([NCBK.10.1]), freed once the event is dispatched; a view that does not
   encode is still published, with no encoding. A view that cannot be built is
   DS_ERR_OOM ([NERR.4]) and no event. */
static ds_result_t bridge_publish(struct ds_rete_engine  *re,
                                   const ds_rete_schema_t *schema,
                                   const ds_rete_val_t    *slots,
                                   void                   *user)
{
    ds_engine_t *engine = (ds_engine_t *)user;
    ds_result_t cr = ds_rete_capacity_refused(re, schema, slots);
    if (cr.status != DS_OK) {
        ds_engine_set_pending(engine, cr);
        return cr;
    }
    ds_fact_t *view = NULL;
    ds_result_t vr = ds_wm_publish_view(engine, schema, slots, &view);
    if (vr.status != DS_OK) {
        ds_engine_set_pending(engine, vr);
        return DS_OK_R;
    }
    uint8_t *external = NULL;
    size_t   external_len = 0;
    if (ds_fact_external_pack(view, &external, &external_len).status != DS_OK)
        external = NULL;
    ds_recorder_emit_action_publish(engine, view, external, external_len);
    DS_FREE(external);
    DS_FREE(view);
    return DS_OK_R;
}

/* ---- emit bridge -------------------------------------------------- */

extern ds_result_t ds_rete_wm_wrap_emitted_fact(
    struct ds_engine    *engine,
    struct ds_rete_fact *rete_fact);

static ds_result_t bridge_emit(struct ds_rete_engine *re,
                                struct ds_rete_fact   *fact,
                                void                  *user)
{
    ds_engine_t *engine = (ds_engine_t *)user;
    if (!engine || !fact) return DS_OK_R;
    /* Before the wrap, which returns early for a synthetic schema. */
    ds_engine_act_note_emitted(engine, re, fact);
    /* A rule's `emit`; a `publish` never reaches here ([LTIE.4.3]).
       ACTION_EMIT fires from bridge_emit_action ([IDSP.4.5]). */
    return ds_rete_wm_wrap_emitted_fact(engine, fact);
}

/* ---- `scope activation` bookkeeping ([LSCP.2.4.1], [LSCP.3.1]) ---- */

ds_result_t ds_engine_retract_rete_fact(struct ds_rete_engine *re,
                                         struct ds_rete_fact   *rfact,
                                         uint8_t                cause);

static bool act_push(uint32_t **arr, size_t *n, size_t *cap, uint32_t v)
{
    if (*n == *cap) {
        size_t ncap = *cap ? *cap * 2 : 8;
        uint32_t *na = DS_REALLOC(*arr, ncap * sizeof(**arr));
        if (!na) return false;
        *arr = na;
        *cap = ncap;
    }
    (*arr)[(*n)++] = v;
    return true;
}

/* A fact into an ACTIVATION schema is pending, retracted when the activation
   completes. One into a synthetic schema ([LTAC.3.2], [LCCO.5.2]) is a completion path
   the pending facts wait on. */
void ds_engine_act_note_emitted(ds_engine_t *engine, struct ds_rete_engine *re,
                                struct ds_rete_fact *fact)
{
    if (!engine || !re || !fact || !fact->schema) return;
    if (re->current_fire_token == NULL) return;
    const ds_rete_schema_t *sc = fact->schema;
    if (sc->scope == DS_RETE_SCOPE_ACTIVATION) {
        (void)act_push(&engine->act_pending, &engine->n_act_pending,
                       &engine->cap_act_pending, fact->id);
    } else if (ds_rete_name_is_synthetic(sc->name)) {
        (void)act_push(&engine->act_tokens, &engine->n_act_tokens,
                       &engine->cap_act_tokens, fact->id);
    }
}

/* [LSCP.3.1]: the synchronous end of the RHS, before RULE_FIRE_END. With no token fact
   the pending facts go now ([LSCP.3.2]); otherwise they wait on each token. */
void ds_engine_act_complete(ds_engine_t *engine, struct ds_rete_engine *re)
{
    if (!engine || !re) return;
    if (engine->n_act_tokens == 0) {
        for (size_t i = 0; i < engine->n_act_pending; i++) {
            ds_rete_fact_t *f = ds_rete_wm_find_by_id(re, engine->act_pending[i]);
            if (f != NULL)
                (void)ds_engine_retract_rete_fact(
                    re, f, DS_FWTH_CAUSE_ACTIVATION_COMPLETED);
        }
    } else {
        for (size_t t = 0; t < engine->n_act_tokens; t++) {
            for (size_t i = 0; i < engine->n_act_pending; i++) {
                if (engine->n_act_attach == engine->cap_act_attach) {
                    size_t ncap = engine->cap_act_attach ? engine->cap_act_attach * 2 : 8;
                    struct ds_act_attach *na = DS_REALLOC(
                        engine->act_attach, ncap * sizeof(*na));
                    if (!na) goto done;      /* the facts outlive the activation */
                    engine->act_attach     = na;
                    engine->cap_act_attach = ncap;
                }
                engine->act_attach[engine->n_act_attach].token_id = engine->act_tokens[t];
                engine->act_attach[engine->n_act_attach].fact_id  = engine->act_pending[i];
                engine->n_act_attach++;
            }
        }
    }
done:
    engine->n_act_pending = 0;
    engine->n_act_tokens  = 0;
}

/* [LSCP.3.1]: a token fact has left working memory, for any cause. */
void ds_engine_act_discharge(ds_engine_t *engine, struct ds_rete_engine *re,
                             uint32_t token_id)
{
    if (!engine || !re || engine->n_act_attach == 0) return;
    size_t w = 0;
    for (size_t i = 0; i < engine->n_act_attach; i++) {
        struct ds_act_attach p = engine->act_attach[i];
        if (p.token_id != token_id) {
            engine->act_attach[w++] = p;
            continue;
        }
        ds_rete_fact_t *f = ds_rete_wm_find_by_id(re, p.fact_id);
        if (f != NULL)
            (void)ds_engine_retract_rete_fact(
                re, f, DS_FWTH_CAUSE_ACTIVATION_COMPLETED);
    }
    engine->n_act_attach = w;
}

/* After bridge_emit's wrap. `publish` fires publish_cb instead. */
static ds_result_t bridge_emit_action(struct ds_rete_engine *re,
                                       struct ds_rete_fact   *fact,
                                       void                  *user)
{
    (void)re;
    ds_engine_t *engine = (ds_engine_t *)user;
    if (!engine || !fact) return DS_OK_R;
    ds_fact_t *ds_fact = NULL;
    ds_wm_fact_lookup(&engine->wm, (void *)fact, &ds_fact);
    if (ds_fact != NULL)
        ds_recorder_emit_action_emit(engine, ds_fact);
    return DS_OK_R;
}

/* ---- series read adapters ----------------------------------------- */

/* The identity-value key; absorb and read render it alike so row keys align. */
static const char *
val_stringify_identity(const ds_rete_val_t *v, char *buf, size_t bufn)
{
    switch (v->kind) {
    case DS_RETE_VAL_STR:
    case DS_RETE_VAL_BYTES:
        return v->s.ptr ? v->s.ptr : "";
    case DS_RETE_VAL_INT: {
        ds_text_t t = ds_text(buf, bufn);
        ds_text_i64(&t, v->i);
        return buf;
    }
    case DS_RETE_VAL_FLOAT: {
        /* [LDET.3.2.7]: it round-trips, so distinct values key distinct rows. */
        ds_text_t t = ds_text(buf, bufn);
        ds_text_float(&t, v->f);
        return buf;
    }
    case DS_RETE_VAL_BOOL:
        return v->b ? "TRUE" : "FALSE";
    case DS_RETE_VAL_TIME: {
        ds_text_t t = ds_text(buf, bufn);
        ds_text_i64(&t, v->time.utc_ns);
        return buf;
    }
    default: {
        ds_text_t t = ds_text(buf, bufn);
        ds_text_str(&t, "<kind=");
        ds_text_i64(&t, (int64_t)v->kind);
        ds_text_char(&t, '>');
        return buf;
    }
    }
}

/* [LSER.16.2], [LSER.16.9]: the aggregations that return the slot's type. */
static bool series_agg_preserves_slot_type(ds_series_agg_kind_t agg)
{
    switch (agg) {
    case DS_SERIES_AGG_SUM:
    case DS_SERIES_AGG_MIN:
    case DS_SERIES_AGG_MAX:
    case DS_SERIES_AGG_FIRST:
    case DS_SERIES_AGG_LAST:
        return true;
    default:
        return false;
    }
}

/* The first decl for the pair: all of them describe the same slot. */
static bool series_slot_is_int(const ds_engine_t *engine,
                               const char        *schema_name,
                               const char        *slot_name)
{
    for (size_t i = 0; i < engine->n_series_decls; i++) {
        const struct ds_series_decl_record *d = &engine->series_decls[i];
        if (d->schema_name == NULL || d->slot_name == NULL) continue;
        if (strcmp(d->schema_name, schema_name) != 0) continue;
        if (strcmp(d->slot_name, slot_name) != 0) continue;
        return d->slot_is_int;
    }
    return false;
}

/* The answer is integral but for a sum past double's exact-integer range, which
   `llround` puts on the nearest. */
static ds_rete_val_t series_narrow_to_slot_type(ds_rete_val_t v)
{
    if (v.kind == DS_RETE_VAL_FLOAT)
        return ds_rete_val_int((int64_t) llround(v.f));
    return v;
}

/* [LSER.19.8], [LSIG.8.1]: the value a cold read answers. An arm must return a value
   of the aggregation's declared type: an ill-typed compare on an untainted operand
   faults ARTEFACT_LIED and halts the tier. */
static ds_rete_val_t series_zero_default(ds_series_agg_kind_t agg)
{
    switch (agg) {
    case DS_SERIES_AGG_COUNT:
    case DS_SERIES_AGG_COUNT_DISTINCT:
    case DS_SERIES_AGG_COUNT_OF:
        return ds_rete_val_int(0);
    case DS_SERIES_AGG_CONTAINS:
        return ds_rete_val_bool(false);
    case DS_SERIES_AGG_SUM:
        /* The caller narrows it over an Int-declared slot ([LSER.16.2]). */
        return ds_rete_val_float(0.0);
    case DS_SERIES_AGG_ACTIVE_FRACTION:
    case DS_SERIES_AGG_ONSET_RATE:
    case DS_SERIES_AGG_INTEGRAL:
        return ds_rete_val_float(0.0);
    default:
        return ds_rete_val_null();
    }
}

static ds_rete_val_t slot_value_to_rete_val(const ds_slot_value_t *sv)
{
    switch (sv->kind) {
    case DS_SLOT_FLOAT:  return ds_rete_val_float(sv->v.f);
    case DS_SLOT_INT:    return ds_rete_val_int(sv->v.i);
    case DS_SLOT_BOOL:   return ds_rete_val_bool(sv->v.b);
    case DS_SLOT_STRING: {
        const char *s = sv->v.s ? sv->v.s : "";
        return ds_rete_val_str(s, (uint32_t)strlen(s));
    }
    /* [LNUL.9.1] */
    case DS_SLOT_NULL:
        return ds_rete_val_null();
    default:
        return ds_rete_val_float(0.0);
    }
}

/* A row can carry several backend instances. An unbounded query (window_ns == 0)
   wants SeriesBackendWelfordEwma; a bounded one wants an exact windowed backend, and
   falls back to SeriesBackendWelfordEwma only when nothing else serves the agg.
   `need_value` restricts to query_with_value. */
static bool series_pick_backend_slot(const ds_engine_t           *engine,
                                     const ds_series_state_row_t *row,
                                     ds_series_agg_kind_t          agg,
                                     uint64_t                      window_ns,
                                     bool                          need_value,
                                     size_t                       *out_slot)
{
    uint64_t agg_bit       = DS_SERIES_AGG_BIT(agg);
    bool     want_unbounded = (window_ns == 0);
    bool     have_fallback  = false;
    size_t   fallback       = 0;

    for (size_t s = 0;
         s < engine->n_backend_slots && s < row->n_slots;
         s++) {
        const ds_series_backend_vtable_t *vt =
            engine->backend_slots[s].vtable;
        if (vt == NULL) continue;
        if ((vt->supported_aggs & agg_bit) == 0) continue;
        if (row->backend_state[s] == NULL) continue;
        if (need_value && vt->query_with_value == NULL) continue;

        bool is_unbounded = (vt->atom_field == DS_ATOM_SERIES_BACKEND_WELFORD_EWMA);
        if (is_unbounded == want_unbounded) {
            *out_slot = s;
            return true;
        }
        if (!have_fallback) { fallback = s; have_fallback = true; }
    }
    if (have_fallback) { *out_slot = fallback; return true; }
    return false;
}

/* `query_at` as of the step's held sample ([LTIM.2.8.4]), so `gap hold` accrues
 * between assertions ([LSIG.3.1]). Clamped to the row's last absorb, which is its
 * precondition: a replayed or externally-timestamped stream can put a fact ahead of
 * the clock. */
static ds_result_t series_query_as_of_now(
    ds_engine_t                      *engine,
    const ds_series_backend_vtable_t *vt,
    const ds_series_state_row_t      *row,
    void                             *st,
    ds_series_agg_kind_t              agg,
    uint64_t                          window_ns,
    ds_slot_value_t                  *out)
{
    uint64_t now_ns = 0;
    if (vt->query_at == NULL
        || ds_clock_now_ns(&engine->clock, &now_ns).status != DS_OK) {
        return vt->query(st, agg, window_ns, out);
    }
    if (row->has_absorbed && now_ns < row->last_absorbed_ts_ns)
        now_ns = row->last_absorbed_ts_ns;
    return vt->query_at(st, agg, window_ns, now_ns, out);
}

/* On a miss: false means no backend declared on this (schema, slot) serves the agg, a
 * compiler defect. True means this row's instance is not allocated yet ([LSER.9.1.1]).
 * The row cannot tell them apart, so this asks the decls. */
static bool series_agg_is_declared(const ds_engine_t    *engine,
                                   const char           *schema_name,
                                   const char           *slot_name,
                                   ds_series_agg_kind_t  agg,
                                   bool                  need_value)
{
    const uint64_t agg_bit = DS_SERIES_AGG_BIT(agg);
    for (size_t i = 0; i < engine->n_series_decls; i++) {
        const struct ds_series_decl_record *d = &engine->series_decls[i];
        if (d->schema_name == NULL || d->slot_name == NULL) continue;
        if (strcmp(d->schema_name, schema_name) != 0) continue;
        if (strcmp(d->slot_name, slot_name) != 0) continue;
        for (size_t s = 0; s < engine->n_backend_slots; s++) {
            const ds_series_backend_vtable_t *vt =
                engine->backend_slots[s].vtable;
            if (vt == NULL) continue;
            if (vt->atom_field != d->atom_field) continue;
            if ((vt->supported_aggs & agg_bit) == 0) continue;
            if (need_value && vt->query_with_value == NULL) continue;
            return true;
        }
    }
    return false;
}

/* Stashed: returning it would abort the activation mid-match. A literal detail, since
   the rule-matching path must not allocate or format. */
static void series_report_unserved(ds_engine_t *engine, const char *what)
{
    ds_engine_set_pending(engine, DS_ERR_R(DS_ERR_SERIES_NO_BACKING, what));
}

/* A step function: each value holds until the next assertion ([LSIG.1.3.1],
   [LSIG.1.5.1], [LSIG.2.5.1]), so age alone never empties the window. */
static bool series_agg_holds_forward(ds_series_agg_kind_t agg)
{
    return agg == DS_SERIES_AGG_ACTIVE_FRACTION
        || agg == DS_SERIES_AGG_INTEGRAL;
}

/* [LSER.19.8]: the newest sample is the last to leave, and a sample exactly
   `window_ns` old is out ([LSER.14.1]). window_ns 0 is unbounded. */
static bool series_window_emptied(ds_engine_t                 *engine,
                                  const ds_series_state_row_t *row,
                                  ds_series_agg_kind_t         agg,
                                  uint64_t                     window_ns)
{
    if (window_ns == 0 || !row->has_absorbed) return false;
    if (series_agg_holds_forward(agg)) return false;
    uint64_t now_ns = 0;
    if (ds_clock_now_ns(&engine->clock, &now_ns).status != DS_OK) return false;
    if (now_ns <= row->last_absorbed_ts_ns) return false;
    return now_ns - row->last_absorbed_ts_ns >= window_ns;
}

/* [LSER.14.1]: a read answers the window at the firing, and `query` takes no instant,
 * so the read evicts the backing it is about to ask. */
static void series_evict_at_clock(ds_engine_t                      *engine,
                                  const ds_series_backend_vtable_t *vt,
                                  void                             *st)
{
    if (vt->evict_stale == NULL || st == NULL) return;
    uint64_t now_ns = 0;
    if (ds_clock_now_ns(&engine->clock, &now_ns).status != DS_OK) return;
    vt->evict_stale(st, now_ns);
}

static ds_result_t series_read_dispatch(ds_rete_engine_t     *re,
                                         ds_rete_val_t        *args,
                                         uint32_t              argc,
                                         ds_rete_val_t        *out,
                                         ds_series_agg_kind_t  agg)
{
    (void)argc;
    *out = series_zero_default(agg);
    if (re == NULL || re->ds_engine_back == NULL) return DS_OK_R;
    ds_engine_t *engine = (ds_engine_t *)re->ds_engine_back;

    if (args[0].kind != DS_RETE_VAL_STR
        || args[1].kind != DS_RETE_VAL_STR
        || args[2].kind != DS_RETE_VAL_STR
        || args[4].kind != DS_RETE_VAL_INT) {
        return DS_OK_R;
    }
    const char *schema_name = args[0].s.ptr ? args[0].s.ptr : "";
    const char *slot_name   = args[1].s.ptr ? args[1].s.ptr : "";
    const char *id_slot     = args[2].s.ptr ? args[2].s.ptr : "";

    /* A warm answer narrows for all five ([LSER.17.2]), a cold zero for `sum` alone
       ([LSER.19.8]). Before the row lookup, for the pre-sample read ([LSER.8.6.1]). */
    const bool narrow = series_agg_preserves_slot_type(agg)
                        && series_slot_is_int(engine, schema_name, slot_name);
    if (narrow && agg == DS_SERIES_AGG_SUM) *out = ds_rete_val_int(0);

    char id_buf[64];
    const char *id_value = val_stringify_identity(
        &args[3], id_buf, sizeof(id_buf));
    uint64_t window_ns = (uint64_t)args[4].i;

    /* [RDSC.5a.8.1]: the reading line's window picks the row. */
    ds_series_state_row_t *row = ds_series_state_lookup(
        &engine->series_state,
        schema_name, slot_name, id_slot, id_value, window_ns);
    if (row == NULL) return DS_OK_R;
    if (series_window_emptied(engine, row, agg, window_ns)) return DS_OK_R;

    size_t slot;
    if (series_pick_backend_slot(engine, row, agg, window_ns,
                                 /*need_value=*/false, &slot)) {
        const ds_series_backend_vtable_t *vt =
            engine->backend_slots[slot].vtable;
        series_evict_at_clock(engine, vt, row->backend_state[slot]);
        ds_slot_value_t result;
        memset(&result, 0, sizeof(result));
        ds_result_t qr = series_query_as_of_now(
            engine, vt, row, row->backend_state[slot], agg, window_ns, &result);
        if (qr.status != DS_OK) {
            /* The match still needs a value, so *out keeps the neutral default. */
            series_report_unserved(engine,
                "series read: backend query failed; the 0 in the rule is a "
                "placeholder, not an answer");
            return DS_OK_R;
        }
        *out = slot_value_to_rete_val(&result);
        if (narrow) *out = series_narrow_to_slot_type(*out);
        return DS_OK_R;
    }
    if (!series_agg_is_declared(engine, schema_name, slot_name, agg,
                                /*need_value=*/false)) {
        series_report_unserved(engine,
            "series read: no declared backing serves this aggregation; the "
            "emit plan asked for a value nothing can compute (SERIESQ1)");
    }
    return DS_OK_R;
}

/* For query_with_value. The string borrows the interned pointer for the call. */
static void rete_val_to_slot_value(const ds_rete_val_t *rv,
                                   ds_slot_value_t     *out)
{
    switch (rv->kind) {
    case DS_RETE_VAL_FLOAT: out->kind = DS_SLOT_FLOAT;  out->v.f = rv->f; break;
    case DS_RETE_VAL_INT:   out->kind = DS_SLOT_INT;    out->v.i = rv->i; break;
    case DS_RETE_VAL_BOOL:  out->kind = DS_SLOT_BOOL;   out->v.b = rv->b; break;
    case DS_RETE_VAL_STR:   out->kind = DS_SLOT_STRING; out->v.s = rv->s.ptr; break;
    case DS_RETE_VAL_TIME:
        /* ds_slot_value_t has no Time kind; the offset does not cross. */
        out->kind = DS_SLOT_INT;    out->v.i = rv->time.utc_ns; break;
    default:                out->kind = DS_SLOT_FLOAT;  out->v.f = 0.0; break;
    }
}

/* As series_read_dispatch, with a sixth operand, the lookup value, for
   query_with_value. */
static ds_result_t series_read_with_value_dispatch(ds_rete_engine_t     *re,
                                                    ds_rete_val_t        *args,
                                                    uint32_t              argc,
                                                    ds_rete_val_t        *out,
                                                    ds_series_agg_kind_t  agg)
{
    (void)argc;
    *out = series_zero_default(agg);
    if (re == NULL || re->ds_engine_back == NULL) return DS_OK_R;
    ds_engine_t *engine = (ds_engine_t *)re->ds_engine_back;

    if (args[0].kind != DS_RETE_VAL_STR
        || args[1].kind != DS_RETE_VAL_STR
        || args[2].kind != DS_RETE_VAL_STR
        || args[4].kind != DS_RETE_VAL_INT) {
        return DS_OK_R;
    }
    const char *schema_name = args[0].s.ptr ? args[0].s.ptr : "";
    const char *slot_name   = args[1].s.ptr ? args[1].s.ptr : "";
    const char *id_slot     = args[2].s.ptr ? args[2].s.ptr : "";

    char id_buf[64];
    const char *id_value = val_stringify_identity(
        &args[3], id_buf, sizeof(id_buf));
    uint64_t window_ns = (uint64_t)args[4].i;

    ds_slot_value_t lookup;
    memset(&lookup, 0, sizeof(lookup));
    rete_val_to_slot_value(&args[5], &lookup);

    ds_series_state_row_t *row = ds_series_state_lookup(
        &engine->series_state,
        schema_name, slot_name, id_slot, id_value, window_ns);
    if (row == NULL) return DS_OK_R;
    if (series_window_emptied(engine, row, agg, window_ns)) return DS_OK_R;

    size_t slot;
    if (series_pick_backend_slot(engine, row, agg, window_ns,
                                 /*need_value=*/true, &slot)) {
        const ds_series_backend_vtable_t *vt =
            engine->backend_slots[slot].vtable;
        series_evict_at_clock(engine, vt, row->backend_state[slot]);
        ds_slot_value_t result;
        memset(&result, 0, sizeof(result));
        ds_result_t qr = vt->query_with_value(
            row->backend_state[slot], agg, window_ns, &lookup, 0, &result);
        if (qr.status != DS_OK) {
            series_report_unserved(engine,
                "series value-read: backend query_with_value failed; the "
                "0/false in the rule is a placeholder, not an answer");
            return DS_OK_R;
        }
        *out = slot_value_to_rete_val(&result);
        return DS_OK_R;
    }
    if (!series_agg_is_declared(engine, schema_name, slot_name, agg,
                                /*need_value=*/true)) {
        series_report_unserved(engine,
            "series value-read: no declared backing serves this aggregation "
            "with a value argument; the emit plan asked for a value nothing "
            "can compute (SERIESQ1)");
    }
    return DS_OK_R;
}

/* (schema, slot, id slot, id value, window): `eval_call` counts the operands. */
#define DEFINE_SERIES_ADAPTER(agg_kind_const)                          \
    static ds_result_t series_read_##agg_kind_const(                   \
        ds_rete_engine_t *engine, ds_rete_eval_ctx_t *ctx,             \
        ds_rete_val_t *args, uint32_t argc, ds_rete_val_t *out)        \
    { (void)ctx;                                                       \
      return series_read_dispatch(engine, args, argc, out,             \
                                   agg_kind_const); }

DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_AVG)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_STDEV)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_PSTDEV)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_VARIANCE)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_PVARIANCE)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_RATE)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_DIRECTION)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_COUNT)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_MIN)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_MAX)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_MEDIAN)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_SUM)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_FIRST)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_LAST)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_BOOL_AND)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_BOOL_OR)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_COUNT_DISTINCT)
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_ONSET_RATE)       /* [LSIG.1.4] */
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_ACTIVE_FRACTION)  /* [LSIG.1.3] */
DEFINE_SERIES_ADAPTER(DS_SERIES_AGG_INTEGRAL)         /* [LSIG.1.5] */

#define DEFINE_SERIES_VALUE_ADAPTER(agg_kind_const)                    \
    static ds_result_t series_read_##agg_kind_const(                   \
        ds_rete_engine_t *engine, ds_rete_eval_ctx_t *ctx,             \
        ds_rete_val_t *args, uint32_t argc, ds_rete_val_t *out)        \
    { (void)ctx;                                                       \
      return series_read_with_value_dispatch(engine, args, argc, out,  \
                                             agg_kind_const); }

DEFINE_SERIES_VALUE_ADAPTER(DS_SERIES_AGG_COUNT_OF)
DEFINE_SERIES_VALUE_ADAPTER(DS_SERIES_AGG_CONTAINS)
/* [LSER.17.6]: the percentile rides the sixth operand. */
DEFINE_SERIES_VALUE_ADAPTER(DS_SERIES_AGG_PERCENTILE)

#undef DEFINE_SERIES_ADAPTER
#undef DEFINE_SERIES_VALUE_ADAPTER

static ds_result_t register_series_read_adapters(ds_engine_t *engine)
{
    if (engine == NULL || engine->rete_engine == NULL) return DS_OK_R;
    static const struct {
        ds_builtin_fn_t op;
        ds_fn_t         fn;
    } k_specs[] = {
        { DS_FN_SERIES_MEAN,      series_read_DS_SERIES_AGG_AVG       },
        { DS_FN_SERIES_STDEV,     series_read_DS_SERIES_AGG_STDEV     },
        { DS_FN_SERIES_PSTDEV,    series_read_DS_SERIES_AGG_PSTDEV    },
        { DS_FN_SERIES_VARIANCE,  series_read_DS_SERIES_AGG_VARIANCE  },
        { DS_FN_SERIES_PVARIANCE, series_read_DS_SERIES_AGG_PVARIANCE },
        { DS_FN_SERIES_RATE,      series_read_DS_SERIES_AGG_RATE      },
        { DS_FN_SERIES_DIRECTION, series_read_DS_SERIES_AGG_DIRECTION },
        { DS_FN_SERIES_COUNT,          series_read_DS_SERIES_AGG_COUNT          },
        { DS_FN_SERIES_MIN,            series_read_DS_SERIES_AGG_MIN            },
        { DS_FN_SERIES_MAX,            series_read_DS_SERIES_AGG_MAX            },
        { DS_FN_SERIES_MEDIAN,         series_read_DS_SERIES_AGG_MEDIAN         },
        { DS_FN_SERIES_PERCENTILE,     series_read_DS_SERIES_AGG_PERCENTILE     },
        { DS_FN_SERIES_SUM,            series_read_DS_SERIES_AGG_SUM            },
        { DS_FN_SERIES_FIRST,          series_read_DS_SERIES_AGG_FIRST          },
        { DS_FN_SERIES_LAST,           series_read_DS_SERIES_AGG_LAST           },
        { DS_FN_SERIES_BOOL_AND,       series_read_DS_SERIES_AGG_BOOL_AND       },
        { DS_FN_SERIES_BOOL_OR,        series_read_DS_SERIES_AGG_BOOL_OR        },
        { DS_FN_SERIES_COUNT_DISTINCT, series_read_DS_SERIES_AGG_COUNT_DISTINCT },
        { DS_FN_SERIES_ONSET_RATE,     series_read_DS_SERIES_AGG_ONSET_RATE     },
        { DS_FN_SERIES_ACTIVE_FRACTION,
              series_read_DS_SERIES_AGG_ACTIVE_FRACTION },
        { DS_FN_SERIES_INTEGRAL,       series_read_DS_SERIES_AGG_INTEGRAL       },
        { DS_FN_SERIES_COUNT_OF,       series_read_DS_SERIES_AGG_COUNT_OF       },
        { DS_FN_SERIES_CONTAINS,       series_read_DS_SERIES_AGG_CONTAINS       },
    };
    for (size_t i = 0; i < sizeof(k_specs) / sizeof(*k_specs); i++) {
        ds_result_t r = ds_register_fn(k_specs[i].op, k_specs[i].fn);
        if (r.status != DS_OK) return r;
    }
    return DS_OK_R;
}


/* ---- end-of-pump series absorber ---------------------------------- */

/* [LSER.8.6]: fire, then sample. A fact asserted before pump P is absorbed after P's
 * run drains, so P's rules read aggregates without it and P+1's read them with it.
 * Each fact's series_absorbed flag makes it once only. */

static const char *
val_stringify_identity(const ds_rete_val_t *v, char *buf, size_t bufn);

/* False skips absorption for the fact's slot. */
static bool rete_val_to_sample(const ds_rete_val_t *rv,
                                ds_slot_value_t      *out)
{
    memset(out, 0, sizeof(*out));
    switch (rv->kind) {
    case DS_RETE_VAL_INT:
        out->kind = DS_SLOT_INT;   out->v.i = rv->i; return true;
    case DS_RETE_VAL_FLOAT:
        out->kind = DS_SLOT_FLOAT; out->v.f = rv->f; return true;
    case DS_RETE_VAL_BOOL:
        out->kind = DS_SLOT_BOOL;  out->v.b = rv->b; return true;
    case DS_RETE_VAL_STR:
    case DS_RETE_VAL_BYTES:
        out->kind = DS_SLOT_STRING;
        out->v.s  = rv->s.ptr ? rv->s.ptr : "";
        return true;
    case DS_RETE_VAL_TIME:
        out->kind = DS_SLOT_INT;   out->v.i = rv->time.utc_ns; return true;
    case DS_RETE_VAL_NULL:
        /* [LNUL.8.6]: `ds_series_absorb_one` decides it, per declaration. */
        out->kind = DS_SLOT_NULL;  return true;
    default:
        return false;
    }
}

/* A NULL ptr is the `""` literal the renderers substitute, not in the table. */
static bool rete_val_is_interned(const ds_rete_val_t *v)
{
    return v != NULL
           && (v->kind == DS_RETE_VAL_STR || v->kind == DS_RETE_VAL_BYTES)
           && v->s.ptr != NULL;
}

/* The supersede-retract is about to release the intern entries `id_value` and a
 * String sample point into, so this takes a counted reference on each, dropped at
 * drain. On overflow or OOM the sample is dropped and the pending status set. */
static void queue_pending_sample(ds_engine_t                        *engine,
                                 const struct ds_series_decl_record *d,
                                 const char                         *id_value,
                                 const ds_rete_val_t                *id_val,
                                 const ds_slot_value_t              *sample,
                                 const ds_rete_val_t                *slot_val,
                                 uint64_t                            ts_ns)
{
    if (engine->n_pending_samples == engine->cap_pending_samples) {
        if (engine->pending_samples_fixed) {
            ds_engine_set_pending(engine, DS_ERR_R(
                DS_ERR_CONTRACT_BREACH,
                "series-absorb: superseded-sample queue full; more keyed "
                "supersedes between two pumps than N_max (NRTM.1.1 forbids "
                "growing it here)"));
            return;
        }
        size_t new_cap = engine->cap_pending_samples
                         ? engine->cap_pending_samples * 2 : 8;
        struct ds_series_pending_sample *nv = DS_REALLOC(
            engine->pending_samples, new_cap * sizeof(*nv));
        if (nv == NULL) {
            ds_engine_set_pending(engine, DS_ERR_R(
                DS_ERR_OOM,
                "series-absorb: superseded-sample queue growth"));
            return;
        }
        engine->pending_samples     = nv;
        engine->cap_pending_samples = new_cap;
    }

    struct ds_series_pending_sample *p =
        &engine->pending_samples[engine->n_pending_samples];
    memset(p, 0, sizeof(*p));

    ds_rete_intern_t *intern = engine->rete_engine
                               ? engine->rete_engine->intern : NULL;

    if (intern != NULL && rete_val_is_interned(id_val)
        && id_value == id_val->s.ptr) {
        p->identity_interned = id_val->s.ptr;
        p->identity_len      = id_val->s.len;
        ds_rete_intern_acquire_ptr(intern, p->identity_interned,
                                   p->identity_len);
    } else {
        const char *src = id_value ? id_value : "";
        size_t      n   = strlen(src);
        if (n >= sizeof(p->identity_buf)) n = sizeof(p->identity_buf) - 1;
        memcpy(p->identity_buf, src, n);
        p->identity_buf[n] = '\0';
    }

    if (sample->kind == DS_SLOT_STRING && intern != NULL
        && rete_val_is_interned(slot_val)) {
        p->value_interned = slot_val->s.ptr;
        p->value_len      = slot_val->s.len;
        ds_rete_intern_acquire_ptr(intern, p->value_interned, p->value_len);
    }

    p->schema_name        = d->schema_name;
    p->slot_name          = d->slot_name;
    p->identity_slot_name = d->identity_slot_name
                            ? d->identity_slot_name : "";
    p->value              = *sample;
    p->ts_ns              = ts_ns;
    engine->n_pending_samples++;
}

/* Safe to call twice: the drain and the teardown can both reach an entry. */
static void release_pending_sample(ds_engine_t                     *engine,
                                   struct ds_series_pending_sample *p)
{
    ds_rete_intern_t *intern = engine->rete_engine
                               ? engine->rete_engine->intern : NULL;
    if (intern == NULL) return;
    if (p->identity_interned != NULL) {
        ds_rete_intern_release(intern, p->identity_interned,
                               p->identity_len);
        p->identity_interned = NULL;
    }
    if (p->value_interned != NULL) {
        ds_rete_intern_release(intern, p->value_interned, p->value_len);
        p->value_interned = NULL;
    }
}

/* One call per (schema, slot, identity slot): ds_series_absorb_one walks every decl
 * of that group, under the identity this fact gives it ([LSER.8.5.1],
 * [LSER.7.6.1]). `queue` parks the sample for the drain, for a fact being
 * superseded. Every fact that entered working memory is a sample, whatever its
 * slots are named: no clause in force exempts one. */
static void series_walk_fact(ds_engine_t            *engine,
                             const ds_rete_schema_t *sc,
                             const ds_rete_val_t    *slots,
                             uint64_t                ts_ns,
                             bool                    queue)
{
    if (sc == NULL || sc->name == NULL) return;
    if (slots == NULL && sc->slot_count > 0) return;

    for (size_t i = 0; i < engine->n_series_decls; i++) {
        const struct ds_series_decl_record *d =
            &engine->series_decls[i];
        if (d->group_repeat) continue;
        if (strcmp(d->schema_name, sc->name) != 0) continue;

        int slot_idx = -1, id_idx = -1;
        const bool has_id = d->identity_slot_name != NULL
                            && d->identity_slot_name[0] != '\0';
        for (uint16_t k = 0; k < sc->slot_count; k++) {
            const char *n = sc->slots[k].name;
            if (n == NULL) continue;
            if (slot_idx < 0 && strcmp(n, d->slot_name) == 0) {
                slot_idx = (int)k;
            }
            if (has_id && id_idx < 0
                && strcmp(n, d->identity_slot_name) == 0) {
                id_idx = (int)k;
            }
        }
        if (slot_idx < 0) continue;

        ds_slot_value_t sample;
        if (!rete_val_to_sample(&slots[slot_idx], &sample)) continue;

        char id_buf[64];
        const char *id_value = "";
        if (id_idx >= 0) {
            id_value = val_stringify_identity(
                &slots[id_idx], id_buf, sizeof(id_buf));
        }

        if (queue) {
            queue_pending_sample(engine, d, id_value,
                                 id_idx >= 0 ? &slots[id_idx] : NULL,
                                 &sample, &slots[slot_idx], ts_ns);
        } else {
            ds_series_absorb_one(engine,
                                  d->schema_name, d->slot_name,
                                  d->identity_slot_name
                                      ? d->identity_slot_name : "",
                                  id_value,
                                  &sample,
                                  ts_ns);
        }
    }
}

static void absorb_one_fact(ds_engine_t *engine, struct ds_rete_fact *fact)
{
    if (fact == NULL || fact->series_absorbed) return;
    fact->series_absorbed = true;
    series_walk_fact(engine, fact->schema, fact->slots,
                     (uint64_t)fact->assert_ns, false);
}

/* [LUNI.4.6.1], [LUNI.4.6.2]: counted, since neither case changes the computed value. */
void ds_engine_fx_note_fallback(struct ds_rete_engine *re, const char *pair)
{
    if (re == NULL) return;
    ds_engine_t *engine = (ds_engine_t *)re->ds_engine_back;
    if (engine == NULL) return;
    ds_metric_label_t labels[1] = {
        { .key = "pair", .value = pair ? pair : "" },
    };
    ds_metric_t m = {
        .name = "ds.currency.fx_rate_missing_total",
        .kind = DS_METRIC_COUNTER, .value = 1.0,
        .labels = labels, .n_labels = 1,
    };
    ds_telemetry_emit_metric(engine, &m);
}

void ds_engine_fx_note_ambiguous(struct ds_rete_engine *re, const char *pair)
{
    if (re == NULL) return;
    ds_engine_t *engine = (ds_engine_t *)re->ds_engine_back;
    if (engine == NULL) return;
    ds_metric_label_t labels[1] = {
        { .key = "pair", .value = pair ? pair : "" },
    };
    ds_metric_t m = {
        .name = "ds.currency.fx_rate_ambiguous_total",
        .kind = DS_METRIC_COUNTER, .value = 1.0,
        .labels = labels, .n_labels = 1,
    };
    ds_telemetry_emit_metric(engine, &m);
}

/* Engine teardown: releases the queue without absorbing. */
void ds_engine_drop_pending_samples(ds_engine_t *engine)
{
    if (engine == NULL) return;
    for (size_t i = 0; i < engine->n_pending_samples; i++) {
        release_pending_sample(engine, &engine->pending_samples[i]);
    }
    DS_FREE(engine->pending_samples);
    engine->pending_samples       = NULL;
    engine->n_pending_samples     = 0;
    engine->cap_pending_samples   = 0;
    engine->pending_samples_fixed = false;
}

/* [LSER.8.5.1]: from ds_rete_wm_assert_ex's supersede path, before the outgoing fact
 * is freed. A plain retract never calls it: supersession is an update, retraction is
 * not. */
void ds_engine_queue_superseded_sample(struct ds_rete_engine *re,
                                        struct ds_rete_fact   *outgoing)
{
    if (re == NULL || outgoing == NULL) return;
    if (outgoing->series_absorbed) return;
    ds_engine_t *engine = (ds_engine_t *)re->ds_engine_back;
    if (engine == NULL || engine->n_series_decls == 0) return;
    outgoing->series_absorbed = true;
    series_walk_fact(engine, outgoing->schema, outgoing->slots,
                     (uint64_t)outgoing->assert_ns, true);
}

static bool pending_identity_is(const struct ds_series_pending_sample *p,
                                const char                            *id)
{
    if (p->identity_interned == NULL)
        return strcmp(p->identity_buf, id) == 0;
    if (p->identity_interned == id) return true;
    size_t n = strlen(id);
    return n == p->identity_len
           && memcmp(p->identity_interned, id, n) == 0;
}

/* [LSER.13.14], [LNUL.8.6]: whether this reading reaches the backing, as
 * ds_series_absorb_one decides it. `*held` is whether the row would hold a value at
 * this point in the pump's absorb order. */
static bool capacity_reading_absorbs(const struct ds_series_decl_record *d,
                                     const ds_slot_value_t              *s,
                                     bool                               *held)
{
    if (s->kind != DS_SLOT_NULL) { *held = true; return true; }
    if (d->null_policy == DS_SERIES_NULLS_ZERO) { *held = true; return true; }
    if (d->null_policy == DS_SERIES_NULLS_HOLD) return *held;
    return false;
}

/* [LSER.13.14], [LSIG.1.1]: from ds_rete_wm_assert_ex for a new sample, before anything
 * is stored. An identity's count is what its row retains in the window, the carry
 * excluded, plus every sample admitted and not yet absorbed. The readings are walked
 * in the end-of-pump absorb's order, so `hold` knows whether a value is held. */
ds_result_t ds_engine_series_capacity_check(struct ds_rete_engine  *re,
                                            const ds_rete_schema_t *sc,
                                            const ds_rete_val_t    *slots)
{
    if (re == NULL || sc == NULL || sc->name == NULL) return DS_OK_R;
    ds_engine_t *engine = (ds_engine_t *)re->ds_engine_back;
    if (engine == NULL || engine->n_series_decls == 0) return DS_OK_R;
    if (slots == NULL && sc->slot_count > 0) return DS_OK_R;

    uint64_t now = (uint64_t)re->clock_fn(re->clock_ctx);

    for (size_t i = 0; i < engine->n_series_decls; i++) {
        const struct ds_series_decl_record *d = &engine->series_decls[i];
        if (!ds_series_refuses_at_capacity(d)) continue;
        if (strcmp(d->schema_name, sc->name) != 0) continue;

        int slot_idx = -1, id_idx = -1;
        const bool has_id = d->identity_slot_name != NULL
                            && d->identity_slot_name[0] != '\0';
        for (uint16_t k = 0; k < sc->slot_count; k++) {
            const char *n = sc->slots[k].name;
            if (n == NULL) continue;
            if (slot_idx < 0 && strcmp(n, d->slot_name) == 0)
                slot_idx = (int)k;
            if (has_id && id_idx < 0 && strcmp(n, d->identity_slot_name) == 0)
                id_idx = (int)k;
        }
        if (slot_idx < 0) continue;
        ds_slot_value_t sample;
        if (!rete_val_to_sample(&slots[slot_idx], &sample)) continue;

        char id_buf[64];
        const char *id_value = "";
        if (id_idx >= 0)
            id_value = val_stringify_identity(&slots[id_idx], id_buf,
                                              sizeof(id_buf));

        uint64_t count = 0;
        const ds_series_state_row_t *row = ds_series_state_lookup(
            &engine->series_state, d->schema_name, d->slot_name,
            d->identity_slot_name ? d->identity_slot_name : "",
            id_value, d->window_ns);
        count += ds_series_state_capacity_retained(row, now, d->window_ns);
        bool held = row != NULL && row->has_last_value;

        for (size_t q = 0; q < engine->n_pending_samples; q++) {
            const struct ds_series_pending_sample *p =
                &engine->pending_samples[q];
            if (strcmp(p->schema_name, d->schema_name) != 0
                || strcmp(p->slot_name, d->slot_name) != 0)
                continue;
            if (!pending_identity_is(p, id_value)) continue;
            if (capacity_reading_absorbs(d, &p->value, &held)) count++;
        }

        uint32_t end = re->next_fact_id;
        for (uint32_t id = engine->series_absorb_mark; id < end; id++) {
            const ds_rete_fact_t *f = ds_rete_wm_find_by_id(re, id);
            if (f == NULL || f->series_absorbed || f->schema != sc) continue;
            ds_slot_value_t s2;
            if (!rete_val_to_sample(&f->slots[slot_idx], &s2)) continue;
            if (id_idx >= 0) {
                char b2[64];
                const char *v2 = val_stringify_identity(&f->slots[id_idx],
                                                        b2, sizeof(b2));
                if (strcmp(v2, id_value) != 0) continue;
            }
            if (capacity_reading_absorbs(d, &s2, &held)) count++;
        }

        /* A null this backing would not absorb is no sample, and is not refused. */
        if (!capacity_reading_absorbs(d, &sample, &held)) continue;

        if (count >= d->max_samples) {
            ds_rete_emit_breach(re, DS_CAP_SERIES_CAPACITY, d->max_samples,
                                count + 1u, NULL, 0);
            return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                            "series: a sample past the series capacity "
                            "(LSER.13.14)");
        }
    }
    return DS_OK_R;
}

/* The queue before the WM walk: a superseded fact was asserted before the one that
 * replaced it, so each row's samples stay in assert order. */
void ds_rete_engine_absorb_pending(ds_engine_t *engine)
{
    if (engine == NULL || engine->rete_engine == NULL) return;
    if (engine->n_series_decls == 0) return;
    struct ds_rete_engine *re = engine->rete_engine;

    uint32_t from = engine->series_absorb_mark;

    /* [LSER.13.14] */
    engine->series_absorb_mark = re->next_fact_id;

    /* The array is retained across drains, so steady state allocates nothing. */
    size_t nq = engine->n_pending_samples;

    for (size_t i = 0; i < nq; i++) {
        struct ds_series_pending_sample ent = engine->pending_samples[i];
        engine->pending_samples[i].identity_interned = NULL;
        engine->pending_samples[i].value_interned    = NULL;

        if (ent.value.kind == DS_SLOT_STRING)
            ent.value.v.s = ent.value_interned ? ent.value_interned : "";
        const char *idv = ent.identity_interned ? ent.identity_interned
                                                : ent.identity_buf;
        ds_series_absorb_one(engine, ent.schema_name, ent.slot_name,
                              ent.identity_slot_name, idv,
                              &ent.value, ent.ts_ns);
        release_pending_sample(engine, &ent);
    }

    size_t carried = engine->n_pending_samples - nq;
    if (carried > 0) {
        memmove(&engine->pending_samples[0], &engine->pending_samples[nq],
                carried * sizeof(engine->pending_samples[0]));
    }
    engine->n_pending_samples = carried;

    /* [LSER.8.6]: by id, which is assertion order; a retract swap-removes in working
       memory's dense vector. */
    uint32_t to = re->next_fact_id;
    for (uint32_t id = from; id < to; id++) {
        ds_rete_fact_t *f = ds_rete_wm_find_by_id(re, id);
        if (f != NULL) absorb_one_fact(engine, f);
    }
}


/* ---- $ClockTick fact cycle ---------------------------------------- */

/* A no-op for a program with no after-clauses, where $ClockTick is not registered. */
void ds_rete_engine_tick_clock(ds_engine_t *engine)
{
    if (engine == NULL || engine->rete_engine == NULL) return;
    struct ds_rete_engine *re = engine->rete_engine;

    if (re->clock_tick_schema == NULL) {
        const char *iname = NULL;
        if (ds_rete_intern_cstr(re->intern, DS_RETE_CLOCK_TICK_NAME, &iname).status
                != DS_OK) {
            return;
        }
        re->clock_tick_schema = ds_rete_schema_by_name(re, iname);
        if (re->clock_tick_schema == NULL) return;
    }

    if (re->clock_tick_fact != NULL) {
        re->retracting_tick = true;
        (void)ds_rete_wm_retract(re, re->clock_tick_fact);
        re->retracting_tick = false;
        re->clock_tick_fact = NULL;
    }

    /* [LERR.1.4.7]: the old tick's retraction can raise the EngineError. */
    if (re->halted) return;

    ds_rete_fact_t *new_tick = NULL;
    (void)ds_rete_wm_assert(re, re->clock_tick_schema->id,
                             NULL, &new_tick);
    re->clock_tick_fact = new_tick;

    /* A fired activation the new tick did not re-form has ended ([IRET.19.5],
     * [IRET.12.2]). */
    ds_rete_engine_tick_flush(re);
}


/* ---- ds_retract_corr support ---------------------------------------- */

/* Through the wrapper when there is one, so fact_count() reflects the retract. */
ds_result_t ds_engine_retract_rete_fact(struct ds_rete_engine *re,
                                         struct ds_rete_fact   *rfact,
                                         uint8_t                cause)
{
    if (re == NULL || rfact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds_engine_retract_rete_fact: NULL re or rfact");
    }
    ds_engine_t *engine = (ds_engine_t *)re->ds_engine_back;
    if (engine == NULL) {
        return ds_rete_wm_retract(re, rfact);
    }
    /* Before the retract frees the fact: its leaving discharges what waits on it. */
    const uint32_t gone_id = rfact->id;
    ds_fact_t *wrapper = NULL;
    ds_result_t lr = ds_wm_fact_lookup(&engine->wm, rfact, &wrapper);
    ds_result_t rr;
    if (lr.status == DS_OK && wrapper != NULL) {
        const uint8_t prev_cause = engine->wm.retract_cause;
        engine->wm.retract_cause = cause;
        rr = ds_engine_retract(engine, wrapper);
        engine->wm.retract_cause = prev_cause;
    } else {
        rr = ds_rete_wm_retract(re, rfact);
    }
    ds_engine_act_discharge(engine, re, gone_id);
    return rr;
}


/* The public API takes the DS fact id ([IDAT.4.1]) and rete tables are keyed by the
   rete id, a second counter: an introspection API resolves one through the wrapper,
   and never casts it into the other. O(live facts). */
static const ds_fact_t *live_fact_by_id(ds_engine_t *engine, uint64_t fact_id)
{
    const uint32_t wm_n = oa_len(&engine->wm.table);
    for (uint32_t i = 0; i < wm_n; i++) {
        const ds_fact_t *f =
            *(ds_fact_t *const *)ds_oa_val_at(&engine->wm.table, i);
        if (f != NULL && f->fact_id == fact_id)
            return f;
    }
    return NULL;
}

/* ---- ds_engine_get_justifiers -------------------------------------- */

ds_result_t ds_engine_get_justifiers(ds_engine_t   *engine,
                                      uint64_t       fact_id,
                                      int64_t      **out_timetags,
                                      char        ***out_rule_names,
                                      uint32_t      *out_count)
{
    if (out_timetags)   *out_timetags   = NULL;
    if (out_rule_names) *out_rule_names = NULL;
    if (out_count)      *out_count      = 0;

    if (!engine || !out_timetags || !out_rule_names || !out_count)
        return DS_ERR_R(DS_ERR_INVAL, "get_justifiers: NULL arg"); /* [NDBG.7.1] */
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (!engine->rete_engine) return DS_OK_R;

    ds_tms_table_t *tms = &engine->rete_engine->tms;

    /* The TMS's lists hold the rete id. */
    const ds_fact_t *live = live_fact_by_id(engine, fact_id);
    if (live == NULL) return DS_OK_R;
    const uint32_t fid = live->rete_id;

    uint32_t  found  = 0;
    int64_t  *tts    = NULL;
    char    **rns    = NULL;

    uint32_t tms_len = oa_len(&tms->map);
    for (uint32_t i = 0; i < tms_len; i++) {
        int64_t        timetag = *(const int64_t *)ds_oa_key_at(&tms->map, i);
        ds_tms_just_t *e       = (ds_tms_just_t *)ds_oa_val_at(&tms->map, i);

        bool has = false;
        uint32_t inline_n = e->count < DS_TMS_INLINE ? e->count : DS_TMS_INLINE;
        for (uint32_t j = 0; j < inline_n && !has; j++)
            if (e->inline_ids[j] == fid) has = true;
        if (!has && e->count > DS_TMS_INLINE)
            for (uint32_t j = 0; j < e->count - DS_TMS_INLINE && !has; j++)
                if (e->heap_ids[j] == fid) has = true;

        if (!has) continue;

        int64_t *t2 = DS_REALLOC(tts, (found + 1) * sizeof(*t2));
        char   **r2 = DS_REALLOC(rns, (found + 1) * sizeof(*r2));
        if (!t2 || !r2) {
            /* A failed realloc left its old block live; one that succeeded may have
               moved it. */
            if (t2) tts = t2;
            if (r2) rns = r2;
            for (uint32_t k = 0; k < found; k++) DS_FREE(rns[k]);
            DS_FREE(tts); DS_FREE(rns);
            return DS_ERR_R(DS_ERR_OOM, "get_justifiers");
        }
        tts = t2;
        rns = r2;
        tts[found]  = timetag;
        rns[found]  = e->rule_name ? DS_STRDUP(e->rule_name) : DS_STRDUP("");
        if (!rns[found]) {
            for (uint32_t k = 0; k < found; k++) DS_FREE(rns[k]);
            DS_FREE(tts); DS_FREE(rns);
            return DS_ERR_R(DS_ERR_OOM, "get_justifiers strdup");
        }
        found++;
    }

    *out_timetags   = tts;
    *out_rule_names = rns;
    *out_count      = found;
    return DS_OK_R;
}

/* An edge to a node not this engine's own is not drawn. The index is not the node's
   name: that is its artefact node_id ([NDBG.4.1]). */
static int32_t _beta_index(ds_rete_engine_t *re, ds_rete_beta_node_t *beta)
{
    for (uint32_t i = 0; i < re->owned_beta_count; i++)
        if (re->owned_betas[i] == beta) return (int32_t)i;
    return -1;
}

static int32_t _terminal_index(ds_rete_engine_t *re, ds_rete_terminal_t *term)
{
    for (uint32_t i = 0; i < re->owned_terminal_count; i++)
        if (re->owned_terminals[i] == term) return (int32_t)i;
    return -1;
}

static void _fmt_alpha_filter(const ds_rete_alpha_node_t *alpha,
                               const ds_rete_schema_t     *schema,
                               char *buf, size_t buflen)
{
    if (!alpha->test_count || buflen < 4) { buf[0] = '\0'; return; }
    ds_text_t out = ds_text(buf, buflen);
    for (uint32_t ti = 0; ti < alpha->test_count && out.len < buflen - 2; ti++) {
        const ds_rete_alpha_test_t *t = &alpha->tests[ti];
        const char *slot = "?";
        if (schema && t->slot_index < schema->slot_count)
            slot = schema->slots[t->slot_index].name;
        const char *op_str = "==";
        if (t->kind == DS_RETE_ALPHA_CMP) {
            switch (t->op) {
                case DS_RETE_CMP_NEQ: op_str = "!="; break;
                case DS_RETE_CMP_LT:  op_str = "<";  break;
                case DS_RETE_CMP_GT:  op_str = ">";  break;
                case DS_RETE_CMP_LTE: op_str = "<="; break;
                case DS_RETE_CMP_GTE: op_str = ">="; break;
                default:              op_str = "=="; break;
            }
        }
        char val_buf[64];
        ds_text_t val = ds_text(val_buf, sizeof(val_buf));
        if (t->kind == DS_RETE_ALPHA_REGEX) {
            ds_text_str(&val, "/<re>/");
        } else {
            switch (t->literal.kind) {
                case DS_RETE_VAL_INT:   ds_text_i64(&val, t->literal.i); break;
                case DS_RETE_VAL_FLOAT: ds_text_float(&val, t->literal.f); break;
                case DS_RETE_VAL_BOOL:
                    ds_text_str(&val, t->literal.b ? "true" : "false"); break;
                case DS_RETE_VAL_STR:
                    ds_text_char(&val, '"');
                    ds_text_strn(&val, t->literal.s.ptr, t->literal.s.len);
                    ds_text_char(&val, '"');
                    break;
                default: ds_text_str(&val, "<val>"); break;
            }
        }
        if (ti) ds_text_str(&out, ", ");
        ds_text_str(&out, slot);
        ds_text_char(&out, ' ');
        ds_text_str(&out, t->kind == DS_RETE_ALPHA_REGEX ? "~" : op_str);
        ds_text_char(&out, ' ');
        ds_text_str(&out, val_buf);
    }
}

/* [NDBG.4.1], [NDBG.4.2]: the artefact's node_id, not a position in this engine's
   arrays ([RARC.5.3.2]). */
static void _node_id(char *buf, size_t n, uint32_t node_id)
{
    ds_text_t t = ds_text(buf, n);
    ds_text_u64(&t, node_id);
}

/* ---- the enumerating reads' callbacks -------------------------------- */

/* [RARC.13.16], [RARC.13.17]: each per-item callback of the enumerating reads runs in
   the bracket, on the call expression, so no early return can leave it raised. */
static void _visit_node(ds_engine_t *engine, ds_rete_node_cb_t cb,
                        const char *id, const char *kind, const char *label,
                        const char *filter, uint32_t occ, bool negative,
                        void *user)
{
    ds_callback_enter(engine);
    cb(id, kind, label, filter, occ, negative, user);
    ds_callback_leave(engine);
}

static void _visit_edge(ds_engine_t *engine, ds_rete_edge_cb_t cb,
                        const char *from, const char *to, void *user)
{
    /* A NULL edge_cb enumerates the nodes alone ([NDBG.4.1]). */
    if (!cb) return;
    ds_callback_enter(engine);
    cb(from, to, user);
    ds_callback_leave(engine);
}

/* ---- ds_engine_rete_network ---------------------------------------- */

/* [NDBG.4.1]'s rule_filter: the nodes upstream of a terminal carrying the rule's name.
   Every link points downstream, so a node is kept iff one of its outputs is: a fixpoint
   over the joins, then the alphas once. `keep_*` are indexed like the owned arrays. */
static void _keep_upstream(ds_rete_engine_t *re, const char *rule,
                           bool *keep_alpha, bool *keep_beta, bool *keep_term)
{
    for (uint32_t i = 0; i < re->owned_terminal_count; i++) {
        ds_rete_terminal_t *t = re->owned_terminals[i];
        keep_term[i] = t != NULL && strcmp(t->rule_name, rule) == 0;
    }
    bool grew = true;
    while (grew) {
        grew = false;
        for (uint32_t i = 0; i < re->owned_beta_count; i++) {
            ds_rete_beta_node_t *b = re->owned_betas[i];
            if (!b || keep_beta[i]) continue;
            bool k = false;
            for (uint32_t c = 0; c < b->terminal_child_count && !k; c++) {
                int32_t ti = _terminal_index(re, b->terminal_children[c]);
                k = ti >= 0 && keep_term[ti];
            }
            for (uint32_t c = 0; c < b->beta_child_count && !k; c++) {
                int32_t bi = _beta_index(re, b->beta_children[c]);
                k = bi >= 0 && keep_beta[bi];
            }
            if (k) { keep_beta[i] = true; grew = true; }
        }
    }
    for (uint32_t i = 0; i < re->owned_alpha_count; i++) {
        ds_rete_alpha_node_t *a = re->owned_alphas[i];
        if (!a) continue;
        for (uint32_t bo = 0; bo < a->beta_output_count && !keep_alpha[i]; bo++) {
            int32_t bi = _beta_index(re, a->beta_outputs[bo]);
            keep_alpha[i] = bi >= 0 && keep_beta[bi];
        }
    }
}

static bool _kept(const bool *keep, uint32_t i)
{
    return keep == NULL || keep[i];
}

ds_result_t ds_engine_rete_network(
    ds_engine_t       *engine,
    const char        *rule_filter,
    bool               include_occupancy,
    ds_rete_node_cb_t  node_cb,  void *node_user,
    ds_rete_edge_cb_t  edge_cb,  void *edge_user)
{
    if (!engine)
        return DS_ERR_R(DS_ERR_INVAL, "ds_engine_rete_network: engine must not be null");
    if (!node_cb)
        return DS_ERR_R(DS_ERR_INVAL, "ds_engine_rete_network: node_cb must not be null");
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (!engine->rete_engine)  return DS_OK_R;

    ds_rete_engine_t *re = engine->rete_engine;

    bool *keep_alpha = NULL, *keep_beta = NULL, *keep_term = NULL;
    if (rule_filter) {
        /* +1: a count of 0 still allocates, so NULL means only OOM. */
        keep_alpha = DS_CALLOC(re->owned_alpha_count + 1u, sizeof(bool));
        keep_beta  = DS_CALLOC(re->owned_beta_count + 1u, sizeof(bool));
        keep_term  = DS_CALLOC(re->owned_terminal_count + 1u, sizeof(bool));
        if (!keep_alpha || !keep_beta || !keep_term) {
            DS_FREE(keep_alpha); DS_FREE(keep_beta); DS_FREE(keep_term);
            return DS_ERR_R(DS_ERR_OOM, "rete_network: rule_filter");
        }
        _keep_upstream(re, rule_filter, keep_alpha, keep_beta, keep_term);
    }

    char id_buf[32];
    char filter_buf[256];

    for (uint32_t i = 0; i < re->owned_alpha_count; i++) {
        ds_rete_alpha_node_t *a = re->owned_alphas[i];
        if (!a || !_kept(keep_alpha, i)) continue;

        _node_id(id_buf, sizeof(id_buf), a->node_id);

        ds_rete_schema_t *schema = (a->schema_id < (uint16_t)re->schema_cap)
                                    ? re->schemas_by_id[a->schema_id] : NULL;
        const char *label = schema ? schema->name : "?";

        _fmt_alpha_filter(a, schema, filter_buf, sizeof(filter_buf));

        uint32_t occ = include_occupancy ? oa_len(&a->memory.map) : UINT32_MAX;
        _visit_node(engine, node_cb, id_buf, "alpha", label, filter_buf, occ,
                    false, node_user);
    }

    for (uint32_t i = 0; i < re->owned_beta_count; i++) {
        ds_rete_beta_node_t *b = re->owned_betas[i];
        if (!b || !_kept(keep_beta, i)) continue;

        _node_id(id_buf, sizeof(id_buf), b->node_id);
        uint32_t occ = include_occupancy ? b->left_count : UINT32_MAX;
        _visit_node(engine, node_cb, id_buf, "beta", "join",
                    b->join_test_count ? "join" : "", occ, b->is_negative,
                    node_user);
    }

    for (uint32_t i = 0; i < re->owned_terminal_count; i++) {
        ds_rete_terminal_t *t = re->owned_terminals[i];
        if (!t || !_kept(keep_term, i)) continue;

        _node_id(id_buf, sizeof(id_buf), t->node_id);
        uint32_t pending = 0;
        if (include_occupancy) {
            for (ds_rete_activation_t *a = t->activations; a; a = a->term_next)
                if (!a->fired) pending++;
        }
        _visit_node(engine, node_cb, id_buf, "terminal", t->rule_name, "",
                    include_occupancy ? pending : UINT32_MAX, false, node_user);
    }

    /* Edges only between two nodes reported above. */
    char from_buf[32], to_buf[32];

    for (uint32_t i = 0; i < re->owned_alpha_count; i++) {
        ds_rete_alpha_node_t *a = re->owned_alphas[i];
        if (!a || !_kept(keep_alpha, i)) continue;
        for (uint32_t bo = 0; bo < a->beta_output_count; bo++) {
            ds_rete_beta_node_t *b = a->beta_outputs[bo];
            int32_t bi = _beta_index(re, b);
            if (bi < 0 || !_kept(keep_beta, (uint32_t)bi)) continue;
            _node_id(from_buf, sizeof(from_buf), a->node_id);
            _node_id(to_buf, sizeof(to_buf), b->node_id);
            _visit_edge(engine, edge_cb, from_buf, to_buf, edge_user);
        }
    }

    for (uint32_t i = 0; i < re->owned_beta_count; i++) {
        ds_rete_beta_node_t *b = re->owned_betas[i];
        if (!b || !_kept(keep_beta, i)) continue;
        for (uint32_t ci = 0; ci < b->beta_child_count; ci++) {
            int32_t bi = _beta_index(re, b->beta_children[ci]);
            if (bi < 0 || !_kept(keep_beta, (uint32_t)bi)) continue;
            _node_id(from_buf, sizeof(from_buf), b->node_id);
            _node_id(to_buf, sizeof(to_buf), b->beta_children[ci]->node_id);
            _visit_edge(engine, edge_cb, from_buf, to_buf, edge_user);
        }
        for (uint32_t ci = 0; ci < b->terminal_child_count; ci++) {
            int32_t ti = _terminal_index(re, b->terminal_children[ci]);
            if (ti < 0 || !_kept(keep_term, (uint32_t)ti)) continue;
            _node_id(from_buf, sizeof(from_buf), b->node_id);
            _node_id(to_buf, sizeof(to_buf), b->terminal_children[ci]->node_id);
            _visit_edge(engine, edge_cb, from_buf, to_buf, edge_user);
        }
    }

    DS_FREE(keep_alpha);
    DS_FREE(keep_beta);
    DS_FREE(keep_term);
    return DS_OK_R;
}

/* ---- ds_engine_rete_match_trace ------------------------------------ */

ds_result_t ds_engine_rete_match_trace(
    ds_engine_t       *engine,
    uint64_t           fact_id,
    ds_rete_trace_cb_t cb, void *user)
{
    if (!engine)
        return DS_ERR_R(DS_ERR_INVAL, "ds_engine_rete_match_trace: engine must not be null");
    if (!cb)
        return DS_ERR_R(DS_ERR_INVAL, "ds_engine_rete_match_trace: cb must not be null");
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (!engine->rete_engine) return DS_OK_R;

    ds_rete_engine_t *re = engine->rete_engine;

    const ds_fact_t *live = live_fact_by_id(engine, fact_id);
    if (live == NULL || live->rete_fact == NULL) return DS_OK_R;
    ds_rete_fact_t *target = (ds_rete_fact_t *)live->rete_fact;

    uint16_t schema_id = target->schema ? target->schema->id : 0xFFFF;
    if (schema_id >= re->schema_cap) return DS_OK_R;

    ds_rete_dispatch_entry_t *de = &re->alpha_dispatch[schema_id];
    char id_buf[32];
    char detail_buf[256];

    for (uint32_t i = 0; i < de->count; i++) {
        ds_rete_alpha_node_t *a = de->nodes[i];
        if (!a) continue;

        _node_id(id_buf, sizeof(id_buf), a->node_id);

        /* NULL ctx: a read-only debugger query raises no fault. */
        bool passed = ds_rete_alpha_test_fact(a, target, NULL);

        ds_text_t detail = ds_text(detail_buf, sizeof(detail_buf));
        if (passed) {
            ds_text_str(&detail, "schema ");
            ds_text_str(&detail, target->schema->name);
            ds_text_str(&detail, " passed");
            if (a->test_count == 0) ds_text_str(&detail, " (no alpha filter)");
        } else {
            char filter_buf[128];
            _fmt_alpha_filter(a, target->schema, filter_buf, sizeof(filter_buf));
            ds_text_str(&detail, "alpha filter failed: ");
            ds_text_str(&detail, filter_buf[0] ? filter_buf : "<test>");
        }

        ds_callback_enter(engine);
        cb(id_buf, "alpha", passed ? "passed" : "filtered", detail_buf, user);
        ds_callback_leave(engine);
    }
    return DS_OK_R;
}

/* ---- ds_engine_refracted_activations ------------------------------- */

/* A fired activation's author facts, as DS fact_ids, in token order. */
typedef struct {
    const uint64_t *ids;
    uint32_t        n;
} refract_row_t;

static int _refract_row_cmp(const void *pa, const void *pb)
{
    const refract_row_t *a = pa, *b = pb;
    const uint32_t n = a->n < b->n ? a->n : b->n;
    for (uint32_t i = 0; i < n; i++)
        if (a->ids[i] != b->ids[i]) return a->ids[i] < b->ids[i] ? -1 : 1;
    return (a->n > b->n) - (a->n < b->n);
}

/* [LLEX.10.6.1]: it has no DS fact_id to list. */
static bool _synthetic_fact(const ds_rete_fact_t *f)
{
    return f != NULL && f->schema != NULL
        && ds_rete_name_is_synthetic(f->schema->name);
}

/* [NDBG.4.3], [IRET.11.3]: the activations a terminal holds with `refracts` set; not
   `fired`, which also marks an immature maturity guard's, nor the generational
   `refract` table. Terminals in ordinal order, then entries by their listed fact-id
   tuple; the author's facts only. The token's rete ids go through the wrapper table,
   so 0 marks a fact that is gone. */
ds_result_t ds_engine_refracted_activations(
    ds_engine_t          *engine,
    const char           *rule_filter,
    ds_rete_refract_cb_t  cb,  void *user)
{
    if (!engine)
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds_engine_refracted_activations: engine must not be null");
    if (!cb)
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds_engine_refracted_activations: cb must not be null");
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (!engine->rete_engine) return DS_OK_R;

    ds_rete_engine_t *re = engine->rete_engine;

    for (uint32_t ti = 0; ti < re->owned_terminal_count; ti++) {
        ds_rete_terminal_t *term = re->owned_terminals[ti];
        if (!term) continue;
        if (rule_filter && strcmp(term->rule_name, rule_filter) != 0) continue;

        uint32_t n_rows = 0;
        size_t   n_ids  = 0;
        for (ds_rete_activation_t *a = term->activations; a; a = a->term_next) {
            if (!a->refracts || !a->token) continue;
            n_rows++;
            n_ids += a->token->fact_count;
        }
        if (n_rows == 0) continue;

        refract_row_t *rows = DS_MALLOC((size_t)n_rows * sizeof *rows);
        uint64_t      *pool = DS_MALLOC((n_ids ? n_ids : 1) * sizeof *pool);
        if (!rows || !pool) {
            if (rows) DS_FREE(rows);
            if (pool) DS_FREE(pool);
            return DS_ERR_R(DS_ERR_OOM, "refracted_activations: rows");
        }

        uint32_t  r    = 0;
        uint64_t *next = pool;
        for (ds_rete_activation_t *a = term->activations; a; a = a->term_next) {
            if (!a->refracts || !a->token) continue;
            rows[r].ids = next;
            rows[r].n   = 0;
            for (uint32_t fi = 0; fi < a->token->fact_count; fi++) {
                const ds_rete_fact_t *rf = a->token->facts[fi];
                if (rf == NULL || _synthetic_fact(rf)) continue;
                ds_fact_t *f = NULL;
                (void)ds_engine_fact_by_rete_id(engine, rf->id, &f);
                next[rows[r].n++] = f ? f->fact_id : 0;
            }
            next += rows[r].n;
            r++;
        }
        qsort(rows, n_rows, sizeof *rows, _refract_row_cmp);

        for (uint32_t i = 0; i < n_rows; i++) {
            ds_callback_enter(engine);
            cb(term->rule_name, "refraction", "fired, and not re-created since",
               rows[i].n ? rows[i].ids : NULL, rows[i].n, user);
            ds_callback_leave(engine);
        }
        DS_FREE(rows);
        DS_FREE(pool);
    }
    return DS_OK_R;
}

/* ---- Entry point called from engine.c ----------------------------- */

static void _rete_before_fire(const char *rule_name, void *ctx);
static void _rete_after_fire(const char *rule_name, void *ctx);

extern ds_result_t ds_rete_register_adapters(
    struct ds_rete_engine          *engine,
    const ds_rete_adapter_config_t *config);

extern ds_result_t ds_rete_set_clock(struct ds_rete_engine *engine,
                                       int64_t (*fn)(void *ctx),
                                       void             *ctx);

static int64_t _rete_clock_via_ds_engine(void *ctx)
{
    ds_engine_t *engine = (ds_engine_t *)ctx;
    if (engine == NULL) return 0;
    uint64_t out = 0;
    if (ds_clock_now_ns(&engine->clock, &out).status != DS_OK) return 0;
    return (int64_t)out;
}

/* [LTIM.2.8.3]: the held wall sample, and whether there is one. */
static bool _rete_wall_via_ds_engine(void *ctx, int64_t *out_utc_ns)
{
    ds_engine_t *engine = (ds_engine_t *)ctx;
    if (engine == NULL) return false;
    bool set = false;
    if (ds_clock_wall_ns(&engine->clock, out_utc_ns, &set).status != DS_OK)
        return false;
    return set;
}

static ds_result_t register_series_read_adapters(ds_engine_t *engine);

void ds_engine_wire_rete_adapters(ds_engine_t *engine)
{
    engine->rete_engine->ds_engine_back       = engine;
    engine->rete_engine->ds_dispatch_table_ptr = &engine->dispatch_table;

    ds_rete_adapter_config_t cfg = {
        .log_cb              = bridge_log,
        .log_user            = engine,
        .call_cb             = bridge_call,
        .call_user           = engine,
        .cache_get_cb        = bridge_cache_get,
        .cache_set_cb        = bridge_cache_set,
        .cache_delete_cb     = bridge_cache_delete,
        .cache_user          = engine,
        .publish_cb          = bridge_publish,
        .publish_user        = engine,
        .emit_cb             = bridge_emit,
        .emit_user           = engine,
        .emit_action_cb      = bridge_emit_action,
        .emit_action_user    = engine,
    };
    ds_rete_register_adapters(engine->rete_engine, &cfg);
    register_series_read_adapters(engine);

    ds_rete_set_clock(engine->rete_engine,
                       _rete_clock_via_ds_engine, engine);
    ds_rete_set_wall_clock(engine->rete_engine, _rete_wall_via_ds_engine);

    ds_rete_set_before_fire(engine->rete_engine,
                             _rete_before_fire, engine);
    ds_rete_set_after_fire(engine->rete_engine,
                            _rete_after_fire, engine);
}

/* ---- fire hooks ---- */

static void _rete_before_fire(const char *rule_name, void *ctx)
{
    ds_engine_t *engine = (ds_engine_t *)ctx;
    if (!engine) return;

    struct ds_rete_engine *re = engine->rete_engine;
    if (re && re->current_fire_token) {
        ds_rete_token_t *tok    = re->current_fire_token;
        uint32_t         n      = tok->fact_count;
        ds_fact_t *fact_buf_stack[64];
        ds_fact_t **fact_buf = fact_buf_stack;
        ds_fact_t **heap_buf = NULL;
        if (n > 64) {
            heap_buf = DS_MALLOC(n * sizeof(*heap_buf));
            if (!heap_buf) goto skip_lhs;
            fact_buf = heap_buf;
        }
        uint32_t  valid = 0;
        for (uint32_t i = 0; i < n; i++) {
            ds_fact_t *df = NULL;
            ds_wm_fact_from_rete_fact(&engine->wm,
                                        (void *)tok->facts[i], &df);
            if (df) fact_buf[valid++] = df;
        }
        /* [NCBK.2.12]: this and the begin below join by timetag. */
        if (valid > 0)
            ds_recorder_emit_rule_lhs_facts(engine, rule_name,
                                             tok->creation_timetag,
                                             fact_buf, valid);
        DS_FREE(heap_buf);
    }
skip_lhs:
    /* [RFCS.11.2], [RFCS.15.2]: the fire identity, identical to the bracket's
       CallIssued. */
    ds_recorder_emit_rule_fire_begin(engine, rule_name,
        (re && re->current_fire_token)
            ? re->current_fire_token->creation_timetag : 0);
}

static void _rete_after_fire(const char *rule_name, void *ctx)
{
    ds_engine_t *engine = (ds_engine_t *)ctx;
    if (!engine) return;

    struct ds_rete_engine *re = engine->rete_engine;
    /* [LERR.1.4.7]: an EngineError raised in this firing is the tier's last record.
       The pending facts are forgotten, not retracted. */
    if (re != NULL && re->halted) {
        engine->n_act_pending = 0;
        engine->n_act_tokens  = 0;
        return;
    }
    ds_engine_act_complete(engine, re);
    ds_recorder_emit_rule_fire_end(engine, rule_name,
        (re && re->current_fire_token)
            ? re->current_fire_token->creation_timetag : 0);

    /* [NCBK.2.6]: immediately after RULE_FIRE_END, only for a firing the rate gate
       admits ([LCDB.3.2.1]). */
    struct ds_rule_meta *rm = ds_engine_find_rule_meta(engine, rule_name);
    if (rm && rm->has_cool && rm->cool_window_ns > 0
            && !(re && re->current_fire_gate_denied)) {
        uint64_t now_ns = 0;
        ds_clock_now_ns(&engine->clock, &now_ns);
        ds_recorder_emit_timer_armed(engine, rule_name,
            (re && re->current_fire_token)
                ? re->current_fire_token->creation_timetag : 0,
            "cooldown", rm->cool_window_ns,
            now_ns + rm->cool_window_ns);
    }
}

ds_result_t ds_engine_mem(ds_engine_t *engine, ds_engine_mem_t *out)
{
    if (engine == NULL || out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_engine_mem: NULL arg");
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (engine->rete_engine == NULL)
        return DS_ERR_R(DS_ERR_UNSUPPORTED,
                        "ds_engine_mem: no RETE network");
    return ds_rete_engine_mem(engine->rete_engine, out);
}

/* ---- RT tuning shims ([NRTM.9.1]) ---- */

ds_result_t ds_engine_set_rt_token_depth(ds_engine_t *engine, uint32_t depth)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (!engine || !engine->rete_engine) return DS_OK_R;
    return ds_rete_engine_set_token_depth(engine->rete_engine, depth);
}

ds_result_t ds_engine_set_rt_token_pool_cap(ds_engine_t *engine, uint32_t cap)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (!engine || !engine->rete_engine) return DS_OK_R;
    return ds_rete_engine_set_token_pool_cap(engine->rete_engine, cap);
}

ds_result_t ds_engine_set_rt_presz_cap(ds_engine_t *engine, uint32_t cap)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (!engine || !engine->rete_engine) return DS_OK_R;
    engine->rete_engine->presz_cap_override = cap;
    return DS_OK_R;
}

/* ---- +constspace boot-time cache-cap setter ([LCSP.2.2]) ---- */

ds_result_t ds_engine_set_cache_cap(ds_engine_t *engine,
                                    uint32_t cap_keys, uint64_t cap_bytes)
{
    if (engine == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    /* 0 = unbounded; enforcement is in ds_cache_set. */
    ds_cache_set_caps(&engine->cache, cap_keys, cap_bytes);
    return DS_OK_R;
}

/* ---- ds_engine_set_wm_max with lazy RT init ([RDSC.16.3.7]) ---- */

ds_result_t ds_engine_set_wm_max(ds_engine_t *engine, uint32_t n_max)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (engine == NULL || engine->rete_engine == NULL) return DS_OK_R;

    /* [NRTM.3.1]: advisory without a realtime contract. */
    if (!engine->rete_engine->rt_mode && !engine->rete_engine->pending_rt)
        return DS_OK_R;

    ds_result_t r = ds_rete_engine_set_wm_max(engine->rete_engine, n_max);
    if (r.status != DS_OK) return r;

    /* [NLFC.10.3]: only an artefact arms `pending_rt`; a sizing call supplies a
       capacity and must not switch strategies. */
    if (!engine->rete_engine->rt_mode && engine->rete_engine->pending_rt) {
        engine->rete_engine->pending_rt = false;

        r = ds_rete_engine_set_rt_mode(engine->rete_engine, true);
        if (r.status != DS_OK) return r;

        r = ds_rete_engine_init_rt_pools(engine->rete_engine);
        if (r.status != DS_OK) return r;

        r = ds_rete_engine_presz_rt_tables(engine->rete_engine);
        if (r.status != DS_OK) return r;

        /* So ds_wm_fact_new never calls malloc in steady state. */
        uint32_t max_slots = 0;
        for (size_t i = 0; i < engine->schemas.n_schemas; i++) {
            uint32_t ns = engine->schemas.schemas[i]->n_slots;
            if (ns > max_slots) max_slots = ns;
        }
        size_t stride = sizeof(ds_fact_t) +
                        (size_t)max_slots * sizeof(ds_slot_value_t);
        /* [LERR.9.10]: a fault fact's wrapper must not take one of the n_max. */
        r = ds_wm_init_rt_pool(&engine->wm,
                               n_max + engine->rete_engine->fault_fact_sites,
                               stride);
        if (r.status != DS_OK) return r;

        /* [NRTM.1.1]: a keyed supersede enqueues on the assert path, so the queue is
         * pre-sized and fixed, with N_max the bound. */
        if (engine->n_series_decls > 0 && n_max > 0
            && engine->pending_samples == NULL) {
            struct ds_series_pending_sample *q =
                DS_CALLOC(n_max, sizeof(*q));
            if (q == NULL) {
                return DS_ERR_R(DS_ERR_OOM,
                                "rt: superseded-sample queue pre-size");
            }
            engine->pending_samples       = q;
            engine->cap_pending_samples   = n_max;
            engine->n_pending_samples     = 0;
            engine->pending_samples_fixed = true;
        }
    }

    return DS_OK_R;
}

/* ---- programmatic schema registration into Rete ---- */

ds_result_t ds_engine_register_schema_in_rete(
    ds_engine_t           *engine,
    const char            *type_name,
    ds_schema_lifecycle_t  lifecycle,
    uint64_t               ttl_ns,
    const ds_slot_desc_t  *slots,
    uint32_t               n_slots)
{
    if (!engine || !engine->rete_engine || n_slots > UINT16_MAX)
        return DS_OK_R;

    ds_rete_slot_desc_t *rslots = NULL;
    if (n_slots > 0) {
        rslots = DS_CALLOC(n_slots, sizeof(*rslots));
        if (!rslots) return DS_OK_R; /* non-fatal on OOM */
        for (uint32_t i = 0; i < n_slots; i++) {
            rslots[i].name        = slots[i].name;
            rslots[i].sampled     = slots[i].sampled;
            rslots[i].retained    = slots[i].retained;
            rslots[i].tolerance   = slots[i].tolerance;
            rslots[i].is_key      = (slots[i].identity_role == DS_IDENTITY_KEY);
            rslots[i].is_marked   = (slots[i].identity_role != DS_IDENTITY_UNSPECIFIED);
            rslots[i].is_engine   = (slots[i].identity_role == DS_IDENTITY_ENGINE);
            rslots[i].nullable    = slots[i].nullable;
            rslots[i].duration    =
                (slots[i].type == DS_SLOT_TYPE_DURATION); /* NFCT.2.3 */
            rslots[i].time        =
                (slots[i].type == DS_SLOT_TYPE_TIME);     /* LTIM.1.1.3 */
            rslots[i].type = ds_rete_val_kind_for_slot_type(slots[i].type);
        }
    }
    ds_rete_scope_t scope;
    switch (lifecycle) {
    case DS_SCHEMA_LIFECYCLE_LOGICAL: scope = DS_RETE_SCOPE_LOGICAL; break;
    case DS_SCHEMA_LIFECYCLE_TTL:     scope = DS_RETE_SCOPE_TTL;     break;
    default:                          scope = DS_RETE_SCOPE_PLAIN;   break;
    }
    ds_rete_schema_t *rs = NULL;
    ds_rete_schema_register(engine->rete_engine, type_name, scope,
                            (int64_t)ttl_ns, rslots, (uint16_t)n_slots, &rs);
    DS_FREE(rslots);
    return DS_OK_R;
}

/* ---- [NFCT.1.4.6] a number through a slot's unit conversion ---- */

static ds_result_t not_representable(void)
{
    return DS_ERR_R(DS_ERR_NOT_REPRESENTABLE,
                    "the slot's conversion has no result for this number "
                    "(NFCT.1.4.6)");
}

/* The conversion is the rete schema's ([RDSC.5.5.9]); the public schema of
   the same name has the same slots in the same order. It is evaluated with
   `bind_frame[0]` holding the host's number, a frame of one ([IRET.9.4],
   [RDSC.4a.9.6]), and every fault held. A held EngineError is then raised as
   any public call raises one ([NCBK.2.9]): recorded with no node and the
   `$engine` rule, since no rule's evaluation holds it ([LERR.9.11]), and the
   engine halts, so the call answers DS_ERR_ENGINE_HALTED. Any other held
   fault is DS_ERR_NOT_REPRESENTABLE, and nothing is recorded, queued as a
   fault fact or halted. A slot that names a unit stores an Int, a Duration's
   nanoseconds as one, or a Float ([LUNI.7.2]). */
static ds_result_t nfct_1_4_6_convert(const ds_schema_t *schema, uint32_t index,
                                      const ds_slot_value_t *in,
                                      ds_slot_value_t *out, bool to_stored)
{
    if (schema == NULL || in == NULL || out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "NULL arg");
    DS_HANDLE_REFUSE_IF_HALTED(schema->engine);
    if (index >= schema->n_slots)
        return DS_ERR_R(DS_ERR_NOT_FOUND, "slot index out of range");

    ds_engine_t *engine = schema->engine;
    const ds_rete_schema_t *rs =
        (engine != NULL && engine->rete_engine != NULL)
            ? ds_rete_schema_by_name(engine->rete_engine, schema->type_name)
            : NULL;
    const ds_rete_expr_t *conv = NULL;
    if (rs != NULL && index < rs->slot_count)
        conv = to_stored ? rs->slots[index].to_stored
                         : rs->slots[index].from_stored;
    if (conv == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "the slot names no unit (NFCT.1.4.6)");

    /* [NFCT.2.3] */
    const bool is_float = schema->slots[index].type == DS_SLOT_TYPE_FLOAT;
    if (in->kind != (is_float ? DS_SLOT_FLOAT : DS_SLOT_INT))
        return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                        "the value is not of the kind the slot stores");
    if (is_float && isnan(in->v.f))
        return DS_ERR_R(DS_ERR_NAN_REJECTED, "the value is a NaN");

    ds_rete_val_t frame = is_float ? ds_rete_val_float(in->v.f)
                                   : ds_rete_val_int(in->v.i);
    ds_rete_eval_ctx_t ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.bind_frame = &frame;
    ctx.bind_count = 1;
    ctx.engine     = engine->rete_engine;

    /* [NCBK.1.5]: the call can emit the EngineError, so it runs as a public
       call does; ds_api_leave reports a halt raised here. */
    ds_api_enter(engine);
    const bool was_halted = engine->halted;
    ds_rete_held_t held;
    const ds_rete_val_t v = ds_rete_eval_holding(&ctx, conv, &held);
    if (ds_rete_held_is_engine_error(&held))
        (void)ds_rete_raise_held(&ctx, &held);

    ds_result_t r = DS_OK_R;
    if (engine->halted && !was_halted)
        r = DS_ERR_R(DS_ERR_ENGINE_HALTED,
                     "the slot's conversion raised an EngineError "
                     "(NFCT.1.4.6)");
    else if (ctx.faulted || held.held)
        r = not_representable();
    else if (is_float) {
        if (v.kind != DS_RETE_VAL_FLOAT || isnan(v.f)) {
            r = not_representable();
        } else {
            out->kind = DS_SLOT_FLOAT;
            out->v.f  = v.f;
        }
    } else {
        if (v.kind != DS_RETE_VAL_INT) {
            r = not_representable();
        } else {
            out->kind = DS_SLOT_INT;
            out->v.i  = v.i;
        }
    }
    return ds_api_leave(engine, r);
}

ds_result_t ds_schema_slot_to_stored(const ds_schema_t     *schema,
                                     uint32_t               index,
                                     const ds_slot_value_t *in,
                                     ds_slot_value_t       *out)
{
    return nfct_1_4_6_convert(schema, index, in, out, true);
}

ds_result_t ds_schema_slot_from_stored(const ds_schema_t     *schema,
                                       uint32_t               index,
                                       const ds_slot_value_t *in,
                                       ds_slot_value_t       *out)
{
    return nfct_1_4_6_convert(schema, index, in, out, false);
}

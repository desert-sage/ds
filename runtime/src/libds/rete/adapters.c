/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/adapters.c — DS action-verb adapter functions for the DS Rete engine.
 *
 * Each function implements one DS action verb as a ds_fn_t, decoding
 * ds_rete_val_t arguments and dispatching to the registered callback
 * or (for ds-publish) directly into working memory.
 *
 * ds-rate-allow: the cooldown gate.  State is stored
 * in a per-engine open-addressing hash table keyed by (rule_name, key).
 * The cooldown window is the call's last argument.
 *
 * `eval_call` counts operands from [RDSC.4a.9.5]'s table before an adapter
 * runs, so an adapter counts none, except `publish`'s values against its
 * schema, which no row can state.
 *
 * A `none` row has no adapter, so the loader refuses an ACTION_CALL of it
 * ([RDSC.4a.9.3]).
 */
#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <sys/types.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rfcs/rfcs.h"
#include "libds.h"
#include "internal/json.h"
#include "date_range.h"
#include "ds_alloc.h"
#include "ds_text.h"

#include "float_fmt.h"
#include "fn.h"
#include "telemetry.h"
#include "rete/adapters.h"
#include "rete/clone.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/intern.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/tms.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

/* Defined in engine_rete_adapters.c, which can include the ds_engine struct
   body: rete/engine.h shadows the bare `engine.h` name here. Retracts through
   the ds_fact_t wrapper when there is one, so engine->wm.table stays in sync. */
ds_result_t ds_engine_retract_rete_fact(struct ds_rete_engine *re,
                                         struct ds_rete_fact   *rfact,
                                         uint8_t                cause);

/* `expr` is NULL: an adapter is handed no expression node. Provenance comes
   from `ctx->json_tainted`, which `eval_call` stamps from the CALL node. */
#define FAULT(cause_) ds_rete_fault(ctx, NULL, (cause_))

/* A String value as the C string libds.h hands a host callback. The one reader
   here of the terminator every string value carries (rete/val.h). */
static const char *val_str(const ds_rete_val_t *v)
{
    return (v->kind == DS_RETE_VAL_STR) ? v->s.ptr : NULL;
}

/* ---- ds-publish ----------------------------------------------------- */

/*
 * (ds-publish <schema-name> <val0> <val1> ...)
 * Positional: args[0] = schema name, args[1..N] = slot values in order.
 * Returns DS_RETE_VAL_BOOL(true) when the values were sent.
 *
 * [LTIE.4.3]: A `publish` SENDS UPSTREAM AND ASSERTS NOTHING IN THIS TIER.
 * [LTIE.4.8]: its values are judged as an `emit`'s are -- the `ts` fill first
 * (rete/engine.c, before the call), a slot value's fault abandoning the
 * activation (`eval_call`, before this runs), a value its slot does not admit
 * a TypeError (here), and a `String` over its slot's `capacity` refused (the
 * publish callback, which records the refusal as a bound's) -- and a refused
 * `publish` sends nothing. No bound on working memory or a series applies,
 * and there is no deadline, so no wrap, no TMS, no fact id. The values go to
 * publish_cb, which builds the event and its FactExternal
 * (engine_rete_adapters.c, bridge_publish).
 */
static ds_result_t adapter_ds_publish(ds_rete_engine_t   *engine,
                                       ds_rete_eval_ctx_t *ctx,
                                       ds_rete_val_t      *args,
                                       uint32_t            argc,
                                       ds_rete_val_t      *result_out)
{
    /* [RDSC.4a.9.3]: the schema name, then one value per slot in declaration
       order ([IRET.27.5]). */
    if (argc < 1) {
        *result_out = ds_rete_fault(ctx, NULL, DS_FAULT_ARTEFACT);
        return DS_OK_R;
    }
    if (args[0].kind != DS_RETE_VAL_STR) {
        *result_out = ds_rete_val_bool(false);
        return DS_ERR_R(DS_ERR_INVAL, "ds-publish: arg 0 must be schema name");
    }

    if (args[0].s.ptr == NULL) {
        *result_out = ds_rete_val_bool(false);
        return DS_ERR_R(DS_ERR_INVAL, "ds-publish: arg 0 must be schema name");
    }
    const char *iname;
    ds_result_t r = ds_rete_intern(engine->intern, args[0].s.ptr,
                                   args[0].s.len, &iname);
    if (r.status != DS_OK) { *result_out = ds_rete_val_bool(false); return r; }

    const ds_rete_schema_t *schema = ds_rete_schema_by_name(engine, iname);
    if (!schema) {
        *result_out = ds_rete_val_bool(false);
        return DS_ERR_R(DS_ERR_SCHEMA_UNKNOWN, "ds-publish: unknown schema");
    }

    /* [RDSC.4a.9.3]: exactly one value per slot. */
    uint16_t slot_count = schema->slot_count;
    if (argc - 1 != (uint32_t)slot_count) {
        *result_out = ds_rete_fault(ctx, NULL, DS_FAULT_ARTEFACT);
        return DS_OK_R;
    }

    ds_rete_val_t slot_buf[32];
    ds_rete_val_t *slots = (slot_count <= 32)
        ? slot_buf : DS_CALLOC(slot_count, sizeof(*slots));
    if (!slots) { *result_out = ds_rete_val_bool(false); return DS_ERR_R(DS_ERR_OOM, "ds-publish"); }

    for (uint32_t i = 0; i < slot_count; i++)
        slots[i] = args[i + 1];

    r = ds_rete_publish_values(engine, ctx, schema, slots);
    if (slots != slot_buf) DS_FREE(slots);
    *result_out = ds_rete_val_bool(r.status == DS_OK
                                   && !(ctx != NULL && ctx->faulted));
    return r;
}

ds_result_t ds_rete_publish_values(ds_rete_engine_t       *engine,
                                   ds_rete_eval_ctx_t     *ctx,
                                   const ds_rete_schema_t *schema,
                                   ds_rete_val_t          *slots)
{
    /* [RARC.5.2.7] A rule's `publish` of a value its slot does not admit -- a
       kind it does not accept, `null` where it is not `T?`, or a NaN
       ([LEXP.4.2]) -- is a TypeError ([LTIE.4.8]): the activation is
       abandoned through the latch on `ctx`, and nothing is sent. Without a
       ctx -- the compiled RHS, which has no firing to abandon -- it is refused
       as the host's door refuses one, and as a ctx-less `emit` is
       (wm_rete.c, rete_validate_slot_kinds): a NaN in a `Float` slot with
       DS_ERR_NAN_REJECTED, anything else with DS_ERR_SLOT_TYPE_MISMATCH.

       A `Json` value whose root is null is null first ([LNUL.3.4]): sent as
       null in `Json?`, refused in `Json`. The slots are copies of the
       arguments, so nothing is freed. */
    ds_rete_lnul_3_4_canonical(schema, slots);
    const int32_t bad = ds_rete_slot_refused(schema, slots);
    if (bad >= 0) {
        if (ctx == NULL) {
            if (schema->slots[bad].type == DS_RETE_VAL_FLOAT
                && slots[bad].kind == DS_RETE_VAL_FLOAT
                && slots[bad].f != slots[bad].f)
                return DS_ERR_R(DS_ERR_NAN_REJECTED,
                                "publish: NaN Float in a slot (LEXP.4.2)");
            return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                            "publish: slot-value kind does not match the "
                            "declared slot type (RARC.5.2.6)");
        }
        (void)ds_rete_fault_slot_refused(ctx, schema->name,
                                         schema->slots[bad].name, &slots[bad]);
        return DS_OK_R;
    }

    /* Nothing is cloned and nothing interned: no fact keeps these values.
       The callback reads them while it runs, which is while the arguments
       live. */
    ds_rete_publish_cb_t cb = engine->adapter.publish_cb;
    if (cb == NULL) return DS_OK_R;
    ds_result_t r = cb(engine, schema, slots, engine->adapter.publish_user);
    /* [LSTR.11.3]: a `String` over its slot's `capacity` is refused as a
       bound's refusal, by the callback, which records the BoundsError and
       pends DS_ERR_CONTRACT_BREACH; the firing stops here as it does at a
       refused `emit`. `eval_call` drops this status, so the action loop
       learns of it from the ctx (eval.h, `bounds_refused`), as for a cache
       write. */
    if (r.status == DS_ERR_CONTRACT_BREACH && ctx != NULL)
        ctx->bounds_refused = true;
    return r;
}

/* ---- ds-log -------------------------------------------------------- */

/*
 * (ds-log <level:Int> <category:Str> <message:Str>)
 * level: ds_log_level_t — 0=debug 1=info 2=warning 3=error 4=critical.
 */
static ds_result_t adapter_ds_log(ds_rete_engine_t   *engine,
                                   ds_rete_eval_ctx_t *ctx,
                                   ds_rete_val_t      *args,
                                   uint32_t            argc,
                                   ds_rete_val_t      *out)
{
    *out = ds_rete_val_bool(true);

    ds_rete_log_cb_t cb = engine->adapter.log_cb;
    if (!cb) return DS_OK_R;

    int64_t level_i = (args[0].kind == DS_RETE_VAL_INT) ? args[0].i : 2;
    ds_log_level_t level = (level_i < 0 || level_i > 4)
                         ? DS_LOG_ERROR
                         : (ds_log_level_t)level_i;

    ds_rete_log_event_t ev = {
        .level    = level,
        .category = val_str(&args[1]),
        .message  = val_str(&args[2]),
    };
    return cb(engine, &ev, engine->adapter.log_user);
}

/* ---- ds-call ------------------------------------------------------- */

/* (ds-call <service:Str> <correlation:Str|null> "k1" v1 "k2" v2 ...)
 *
 * The engine-side bridge types the kwargs and refuses a NaN Float, an odd
 * count or a non-String name. A `null` correlation reaches the dispatcher as
 * NULL and is refused there. */
static ds_result_t adapter_ds_call(ds_rete_engine_t   *engine,
                                    ds_rete_eval_ctx_t *ctx,
                                    ds_rete_val_t      *args,
                                    uint32_t            argc,
                                    ds_rete_val_t      *out)
{
    *out = ds_rete_val_bool(true);

    ds_rete_call_cb_t cb = engine->adapter.call_cb;
    if (!cb)
        return DS_ERR_R(DS_ERR_STORAGE_UNAVAILABLE, "ds-call: no callback registered");

    ds_rete_call_request_t req = {
        .service       = val_str(&args[0]),
        .correlation   = val_str(&args[1]),
        .operands      = argc > 2 ? &args[2] : NULL,
        .operand_count = argc - 2,
        .timetag       = ctx->timetag,
        .rule_name     = ctx->rule_name,
    };
    return cb(engine, &req, engine->adapter.call_user);
}

/* ---- ds-retract-corr ---------------------------------------------- */

/* Victims are collected and retracted after the walk: mutating WM during it
   would invalidate ds_rete_wm_for_each's cursor. */
typedef struct {
    const char       *schema_name;
    const char       *slot_name;
    const ds_rete_val_t *corr;       /* typed ([LRST.1.4]) */
    ds_rete_fact_t  **victims;
    size_t            n;
    size_t            cap;
    bool              oom;
} retract_corr_ctx_t;

/* Content equality for a supersedure key ([LRST.1.4]). Not beta.c's
 * lmem_idx_val_eq, which is join-key identity by interned pointer: a correlation
 * key can come from another intern pool. BYTES keys may hold NULs, hence memcmp.
 * The unequatable kinds are listed so -Wswitch names this function when a value
 * kind is added. */
static bool corr_key_eq(const ds_rete_val_t *a, const ds_rete_val_t *b)
{
    /* [LTIM.1.1.3]: a `Time` key held in a slot is INT and the same key computed
       by an expression is a TIME. Both sides name one slot of one schema, so an
       INT here is never an `Int` key meeting a `Time` one. */
    if (a->kind == DS_RETE_VAL_TIME && b->kind == DS_RETE_VAL_INT)
        return a->time.utc_ns == b->i;
    if (a->kind == DS_RETE_VAL_INT && b->kind == DS_RETE_VAL_TIME)
        return a->i == b->time.utc_ns;
    if (a->kind != b->kind) return false;
    switch (a->kind) {
    case DS_RETE_VAL_INT:   return a->i == b->i;
    case DS_RETE_VAL_FLOAT: return a->f == b->f;
    case DS_RETE_VAL_BOOL:  return a->b == b->b;
    /* [LTIM.5.2]: the offset is presentation. */
    case DS_RETE_VAL_TIME:  return a->time.utc_ns == b->time.utc_ns;
    case DS_RETE_VAL_STR:
    case DS_RETE_VAL_BYTES:
        if (a->s.ptr == b->s.ptr) return true;
        if (a->s.ptr == NULL || b->s.ptr == NULL) return false;
        if (a->s.len != b->s.len) return false;
        return memcmp(a->s.ptr, b->s.ptr, a->s.len) == 0;
    case DS_RETE_VAL_JSON:
    case DS_RETE_VAL_JSON_BORROW:
    case DS_RETE_VAL_UNBOUND:
    case DS_RETE_VAL_FACT_REF:
    case DS_RETE_VAL_NULL:
    case DS_RETE_VAL_RATIO:
        return false;
    }
    return false;
}

/* True when the key means "no supersedure", so the sweep must not run. Only the
   string-shaped kinds have an absent form: 0 and false are ordinary keys. */
static bool corr_key_absent(const ds_rete_val_t *c)
{
    if (c == NULL) return true;
    if (c->kind == DS_RETE_VAL_STR || c->kind == DS_RETE_VAL_BYTES)
        return c->s.ptr == NULL || c->s.len == 0;
    return false;
}

static int retract_corr_visitor(ds_rete_fact_t *fact, void *ctx_v)
{
    retract_corr_ctx_t *cx = ctx_v;
    const ds_rete_schema_t *sc = fact->schema;
    if (!sc || !sc->name) return 0;
    if (sc->name != cx->schema_name && strcmp(sc->name, cx->schema_name) != 0)
        return 0;
    int slot_idx = -1;
    for (uint16_t i = 0; i < sc->slot_count; i++) {
        const char *n = sc->slots[i].name;
        if (n != NULL && (n == cx->slot_name || strcmp(n, cx->slot_name) == 0)) {
            slot_idx = (int)i;
            break;
        }
    }
    if (slot_idx < 0) return 0;
    const ds_rete_val_t *v = &fact->slots[slot_idx];
    if (!corr_key_eq(v, cx->corr)) return 0;

    if (cx->n == cx->cap) {
        size_t new_cap = cx->cap ? cx->cap * 2 : 8;
        ds_rete_fact_t **nv = DS_REALLOC(cx->victims, new_cap * sizeof(*nv));
        if (!nv) { cx->oom = true; return 1; }
        cx->victims = nv;
        cx->cap     = new_cap;
    }
    cx->victims[cx->n++] = fact;
    return 0;
}

/* LDET.5.11: the victims leave by entry position, which is id order: an id is
   assigned monotonically at entry and never reused. */
static int retract_corr_victim_cmp(const void *a, const void *b)
{
    const ds_rete_fact_t *fa = *(const ds_rete_fact_t *const *) a;
    const ds_rete_fact_t *fb = *(const ds_rete_fact_t *const *) b;
    return (fa->id > fb->id) - (fa->id < fb->id);
}

static ds_result_t do_retract_corr_sweep(ds_rete_engine_t    *engine,
                                          const char          *schema_name,
                                          const char          *slot_name,
                                          const ds_rete_val_t *corr)
{
    if (corr_key_absent(corr)) return DS_OK_R;
    if (schema_name == NULL || slot_name == NULL) return DS_OK_R;

    retract_corr_ctx_t cx = {
        .schema_name = schema_name,
        .slot_name   = slot_name,
        .corr        = corr,
        .victims     = NULL,
        .n           = 0,
        .cap         = 0,
        .oom         = false,
    };

    (void)ds_rete_wm_for_each(engine, retract_corr_visitor, &cx);

    if (cx.oom) {
        DS_FREE(cx.victims);
        return DS_ERR_R(DS_ERR_OOM, "ds-retract-corr: victim array allocation");
    }

    /* LDET.5.11: the walk's dense order is reshuffled by a retract's
       swap-remove, so a run and its replay could disagree. */
    if (cx.n > 1)
        qsort(cx.victims, cx.n, sizeof(*cx.victims), retract_corr_victim_cmp);

    ds_result_t r = DS_OK_R;
    for (size_t i = 0; i < cx.n; i++) {
        /* [LERR.1.4.7]: the sweep stops at the halt, between facts. */
        if (engine->halted) break;
        ds_result_t rr = ds_engine_retract_rete_fact(
            engine, cx.victims[i], DS_FWTH_CAUSE_SUPERSEDED);
        if (rr.status != DS_OK && r.status == DS_OK) r = rr;
    }
    DS_FREE(cx.victims);
    return r;
}

/* (ds-retract-corr <schema_name:Str> <slot_name:Str> <corr>) -> Bool, true
   however many were retracted. */
static ds_result_t adapter_ds_retract_corr(ds_rete_engine_t   *engine,
                                            ds_rete_eval_ctx_t *ctx,
                                            ds_rete_val_t      *args,
                                            uint32_t            argc,
                                            ds_rete_val_t      *out)
{
    *out = ds_rete_val_bool(true);

    if (args[0].kind != DS_RETE_VAL_STR || args[1].kind != DS_RETE_VAL_STR)
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds-retract-corr: requires (schema_name, slot_name) Str");

    /* Every schema and slot name is interned when its schema registers, so a
       name the table does not hold names nothing the sweep could retract. */
    const char *schema_name = NULL, *slot_name = NULL;
    if (args[0].s.ptr == NULL || args[1].s.ptr == NULL) return DS_OK_R;
    (void)ds_rete_intern_find(engine->intern, args[0].s.ptr, args[0].s.len,
                              &schema_name);
    (void)ds_rete_intern_find(engine->intern, args[1].s.ptr, args[1].s.len,
                              &slot_name);
    if (schema_name == NULL || slot_name == NULL) return DS_OK_R;

    return do_retract_corr_sweep(engine, schema_name, slot_name, &args[2]);
}

ds_result_t ds_rete_retract_corr_sweep(ds_rete_engine_t    *engine,
                                        const char          *schema_name,
                                        const char          *slot_name,
                                        const ds_rete_val_t *corr)
{
    return do_retract_corr_sweep(engine, schema_name, slot_name, corr);
}

/* ---- ds-retract-token-fact ---------------------------------------- */

/* (ds-retract-token-fact <pattern_index:Int>) -> Bool. Retracts the fact at
 * that token position. Follow-up rules drop their timer fact with it: each new
 * ClockTick makes a fresh token, so refraction alone would let them re-fire. An
 * out-of-range index or a missing token is a no-op answering true. */
static ds_result_t adapter_ds_retract_token_fact(ds_rete_engine_t   *engine,
                                                  ds_rete_eval_ctx_t *ctx,
                                                  ds_rete_val_t      *args,
                                                  uint32_t            argc,
                                                  ds_rete_val_t      *out)
{
    *out = ds_rete_val_bool(true);
    if (args[0].kind != DS_RETE_VAL_INT) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "ds-retract-token-fact: requires (pattern_index:Int)");
    }
    if (ctx == NULL || ctx->token == NULL) return DS_OK_R;
    int64_t pi = args[0].i;
    if (pi < 0 || (uint32_t)pi >= ctx->token->fact_count) return DS_OK_R;
    ds_rete_fact_t *f = ctx->token->facts[pi];
    if (f == NULL) return DS_OK_R;
    return ds_engine_retract_rete_fact(engine, f,
                                       DS_FWTH_CAUSE_SYNTHETIC_DISCHARGED);
}

/* ---- ds-cache-get/set/delete --------------------------------------- */

/* (ds-cache-get <key:Str>) → Str on hit, null on miss ([LGRA.2.9.6.2],
   [LSTO.4.3.1a]). */
static ds_result_t adapter_ds_cache_get(ds_rete_engine_t   *engine,
                                         ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t      *args,
                                         uint32_t            argc,
                                         ds_rete_val_t      *out)
{
    *out = ds_rete_val_null();

    ds_rete_cache_get_cb_t cb = engine->adapter.cache_get_cb;
    if (!cb)
        return DS_ERR_R(DS_ERR_STORAGE_UNAVAILABLE, "ds-cache-get: no callback");

    char *json_out = NULL;
    ds_result_t r = cb(engine, val_str(&args[0]), &json_out, engine->adapter.cache_user);
    if (r.status != DS_OK) return r;
    if (!json_out) return DS_OK_R;

    /* A transient result: arena, not interned, until an emit commits it. */
    size_t jlen = strlen(json_out);
    const char *ip = ds_rete_arena_dup(&engine->comp_arena, json_out, jlen);
    DS_FREE(json_out);
    if (ip == NULL) return DS_ERR_R(DS_ERR_OOM, "ds-cache-get: arena");
    *out = ds_rete_val_str(ip, (uint32_t)jlen);
    return DS_OK_R;
}

/* (ds-cache-set <key:Str> <value-json:Str> <ttl-ns:Int>) → Bool(true) */
static ds_result_t adapter_ds_cache_set(ds_rete_engine_t   *engine,
                                         ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t      *args,
                                         uint32_t            argc,
                                         ds_rete_val_t      *out)
{
    *out = ds_rete_val_bool(false);

    ds_rete_cache_set_cb_t cb = engine->adapter.cache_set_cb;
    if (!cb)
        return DS_ERR_R(DS_ERR_STORAGE_UNAVAILABLE, "ds-cache-set: no callback");

    /* [IDSP.7.10]: here, not in the bridge, which takes the ttl as uint64_t. */
    if (args[2].kind == DS_RETE_VAL_INT && args[2].i < 0)
        return DS_ERR_R(DS_ERR_INVAL, "ds-cache-set: negative ttl");

    const char *value_json = val_str(&args[1]);
    if (value_json && args[1].s.len > 0) {
        /* The engine's own serialization, so the TEXT limit does not apply; a
           value over a tree limit is NOT_REPRESENTABLE ([LGRA.5.8.6]). */
        ds_json_t  *probe = NULL;
        ds_result_t jr = ds_json_parse_limited(value_json, args[1].s.len,
                                               &probe, NULL, false);
        if (probe) ds_json_free(probe);
        if (jr.status == DS_ERR_JSON_LIMIT) {
            *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
            return DS_OK_R;
        }
        if (jr.status != DS_OK)
            return DS_ERR_R(DS_ERR_INVAL,
                            "ds-cache-set: value is not valid JSON");
    }

    uint64_t ttl = (args[2].kind == DS_RETE_VAL_INT && args[2].i > 0)
                   ? (uint64_t)args[2].i : 0;

    /* [LTIM.1.1.5]: a deadline past the `Time` range is NOT_REPRESENTABLE, after
       the value's limits. Without a ctx ds_cache_set refuses it with
       DS_ERR_TIME_RANGE. */
    if (ctx != NULL && ttl != 0) {
        int64_t now = engine->clock_fn(engine->clock_ctx);
        if (now < 0 || ttl > (uint64_t)(INT64_MAX - now)) {
            *out = ds_rete_fault(ctx, NULL, DS_FAULT_NOT_REPRESENTABLE);
            return DS_OK_R;
        }
    }

    ds_result_t r = cb(engine, val_str(&args[0]), val_str(&args[1]),
                        ttl, engine->adapter.cache_user);
    if (r.status == DS_OK) *out = ds_rete_val_bool(true);
    /* LSTO.4.7.5: a write a cache bound refused stops the firing. `eval_call`
       drops this status, so the action loop learns of it from the ctx. */
    if (r.status == DS_ERR_CONTRACT_BREACH && ctx != NULL)
        ctx->bounds_refused = true;
    return r;
}

/* (ds-cache-delete <key:Str>) → Bool(true) */
static ds_result_t adapter_ds_cache_delete(ds_rete_engine_t   *engine,
                                             ds_rete_eval_ctx_t *ctx,
                                             ds_rete_val_t      *args,
                                             uint32_t            argc,
                                             ds_rete_val_t      *out)
{
    *out = ds_rete_val_bool(false);

    ds_rete_cache_delete_cb_t cb = engine->adapter.cache_delete_cb;
    if (!cb)
        return DS_ERR_R(DS_ERR_STORAGE_UNAVAILABLE, "ds-cache-delete: no callback");

    ds_result_t r = cb(engine, val_str(&args[0]), engine->adapter.cache_user);
    if (r.status == DS_OK) *out = ds_rete_val_bool(true);
    return r;
}

/* ---- ds-rate-allow ------------------------------------------------- */

/*
 * Rate-allow state table: open-addressing hash keyed by
 * (interned rule_name ptr, activation key).
 *
 * The key is typed and whole ([IRET.25.5.3], RLOW.4.6.2.1). Each component is
 * encoded as a representation tag and its value -- fixed width for a scalar,
 * length-prefixed for a string, bytes or Json. The tag is the representation,
 * not the declared type, so a Time keys as its Int count.
 *
 * No buffer on the lookup path: `rk_walk` feeds its bytes to a sink that
 * hashes, measures or compares them in place. Only an insert allocates.
 */

#define RATE_ALLOW_INIT_CAP 32u
#define RATE_ALLOW_MAX_LOAD 70u

typedef struct {
    const char *rule_name;   /* interned; NULL = empty */
    uint32_t    key_hash;
    /* 0 is a valid instant, so it cannot mean "never"; zeroed entries read as
       never fired. */
    bool        has_fired;
    unsigned char *key;      /* heap-allocated encoded key, `key_len` bytes */
    size_t      key_len;
    int64_t     last_fire_ns;    /* meaningful only when has_fired */
    int64_t     cooldown_ns;  /* window last seen, for safe eviction */
} ds_rate_entry_t;

typedef struct {
    ds_rate_entry_t *entries;
    uint32_t         cap;
    uint32_t         count;
} ds_rate_table_t;

/* Allocated on the first ds_rate_allow call, hung off
   `engine->adapter._cleanup_state`; engine destroy runs the cleanup hook. */
static void rate_table_free(void *state)
{
    ds_rate_table_t *t = (ds_rate_table_t *)state;
    if (!t) return;
    if (t->entries) {
        for (uint32_t i = 0; i < t->cap; i++)
            DS_FREE(t->entries[i].key);
        DS_FREE(t->entries);
    }
    DS_FREE(t);
}

static ds_rate_table_t *get_rate_table(ds_rete_engine_t *engine)
{
    if (!engine->adapter._cleanup_state) {
        /* Past go_live nothing allocates. */
        if (engine->live) return NULL;
        ds_rate_table_t *t = DS_CALLOC(1, sizeof(*t));
        if (!t) return NULL;
        engine->adapter._cleanup_state = t;
        engine->adapter._cleanup       = rate_table_free;
    }
    return (ds_rate_table_t *)engine->adapter._cleanup_state;
}

/* [LDET.2.2b]: a clone carries the rate gate's state. Key bytes are a function
   of the activation's values alone, so they carry over. Only rule_name is an
   interned pointer, re-interned for the clone; the probe position hashes it, so
   each entry is placed again. Installed on dst before it is filled, so on OOM
   the cleanup hook frees it with dst. */
ds_result_t ds_rete_rate_table_clone(ds_rete_clone_ctx_t    *cx,
                                     const ds_rete_engine_t *src,
                                     ds_rete_engine_t       *dst)
{
    const ds_rate_table_t *s = src->adapter._cleanup == rate_table_free
        ? (const ds_rate_table_t *)src->adapter._cleanup_state : NULL;
    if (s == NULL) return DS_OK_R;

    if (dst->adapter._cleanup_state != NULL && dst->adapter._cleanup != NULL)
        dst->adapter._cleanup(dst->adapter._cleanup_state);
    dst->adapter._cleanup_state = NULL;
    dst->adapter._cleanup       = NULL;

    ds_rate_table_t *d = DS_CALLOC(1, sizeof(*d));
    if (!d) return DS_ERR_R(DS_ERR_OOM, "engine_clone: rate table");
    dst->adapter._cleanup_state = d;
    dst->adapter._cleanup       = rate_table_free;
    if (s->cap == 0) return DS_OK_R;

    d->entries = DS_CALLOC(s->cap, sizeof(*d->entries));
    if (!d->entries) return DS_ERR_R(DS_ERR_OOM, "engine_clone: rate entries");
    d->cap = s->cap;
    for (uint32_t i = 0; i < s->cap; i++) {
        const ds_rate_entry_t *se = &s->entries[i];
        if (!se->rule_name) continue;
        const char *name = ds_rete_clone_intern(cx, se->rule_name,
                                                (uint32_t)strlen(se->rule_name));
        if (!name) return DS_ERR_R(DS_ERR_OOM, "engine_clone: rate rule name");
        unsigned char *key = DS_MALLOC(se->key_len ? se->key_len : 1u);
        if (!key) return DS_ERR_R(DS_ERR_OOM, "engine_clone: rate key");
        if (se->key_len) memcpy(key, se->key, se->key_len);
        uint32_t j = (se->key_hash ^ (uint32_t)((uintptr_t)name >> 3)) % d->cap;
        while (d->entries[j].rule_name) j = (j + 1) % d->cap;
        d->entries[j]           = *se;
        d->entries[j].rule_name = name;
        d->entries[j].key       = key;
        d->count++;
    }
    return DS_OK_R;
}

/* One tag per representation ([LNUL.4.9]'s, plus the kinds it names none for). */
typedef enum {
    RK_NULL    = 0,
    RK_INT     = 1,   /* Int, and Time by its utc_ns count */
    RK_FLOAT   = 2,
    RK_BOOL    = 3,
    RK_STRING  = 4,
    RK_BYTES   = 5,
    RK_JSON    = 6,   /* canonical serialization */
    RK_FACT    = 7,   /* by id */
    RK_RATIO   = 8,
    RK_UNBOUND = 9
} rk_tag_t;

#define RK_FNV_BASIS 2166136261u

/* Where `rk_walk` sends the key's bytes. Every mode hashes and measures;
   `out` also writes them, `cmp` also compares them with a stored key. */
typedef struct {
    uint32_t             hash;
    size_t               len;
    unsigned char       *out;
    const unsigned char *cmp;
    size_t               cmp_len;
    bool                 differs;
} rk_sink_t;

static void rk_feed(rk_sink_t *s, const void *p, size_t n)
{
    if (n == 0) return;
    const unsigned char *b = (const unsigned char *)p;
    for (size_t i = 0; i < n; i++) { s->hash ^= b[i]; s->hash *= 16777619u; }
    if (s->out) memcpy(s->out + s->len, b, n);
    if (s->cmp && !s->differs &&
        (s->len + n > s->cmp_len || memcmp(s->cmp + s->len, b, n) != 0))
        s->differs = true;
    s->len += n;
}

/* Little-endian whatever the host, so the bytes are a function of the value. */
static void rk_feed_u64(rk_sink_t *s, uint64_t v)
{
    unsigned char b[8];
    for (int i = 0; i < 8; i++) { b[i] = (unsigned char)(v & 0xffu); v >>= 8; }
    rk_feed(s, b, sizeof b);
}

static void rk_feed_tag(rk_sink_t *s, rk_tag_t tag)
{
    unsigned char b = (unsigned char)tag;
    rk_feed(s, &b, 1);
}

static void rk_feed_bytes(rk_sink_t *s, rk_tag_t tag, const void *p, size_t n)
{
    rk_feed_tag(s, tag);
    rk_feed_u64(s, (uint64_t)n);
    rk_feed(s, p, n);
}

/* Feeds the whole key. False when a Json component cannot be serialized or, in
   a live engine, when there is one at all, since serializing allocates. The
   caller allows on false, as a live engine does on an unknown key. Exhaustive:
   a kind with no arm would contribute nothing and collide. */
static bool rk_walk(rk_sink_t *s, const ds_rete_val_t *args, uint32_t n,
                    bool live)
{
    rk_feed_u64(s, n);
    for (uint32_t i = 0; i < n; i++) {
        const ds_rete_val_t *v = &args[i];
        switch (v->kind) {
        case DS_RETE_VAL_INT:
            rk_feed_tag(s, RK_INT);
            rk_feed_u64(s, (uint64_t)v->i);
            break;
        case DS_RETE_VAL_TIME:
            /* The offset is identity-irrelevant ([LTIM.1.1.2]). */
            rk_feed_tag(s, RK_INT);
            rk_feed_u64(s, (uint64_t)v->time.utc_ns);
            break;
        case DS_RETE_VAL_FLOAT: {
            double f = v->f;
            uint64_t bits;
            if (f == 0.0) f = 0.0;          /* -0.0 == 0.0: one key */
            if (f != f)
                bits = UINT64_C(0x7ff8000000000000);
            else
                memcpy(&bits, &f, sizeof bits);
            rk_feed_tag(s, RK_FLOAT);
            rk_feed_u64(s, bits);
            break;
        }
        case DS_RETE_VAL_BOOL:
            rk_feed_tag(s, RK_BOOL);
            rk_feed_u64(s, v->b ? 1u : 0u);
            break;
        case DS_RETE_VAL_STR:
            rk_feed_bytes(s, RK_STRING, v->s.ptr, v->s.ptr ? v->s.len : 0);
            break;
        case DS_RETE_VAL_BYTES:
            rk_feed_bytes(s, RK_BYTES, v->s.ptr, v->s.ptr ? v->s.len : 0);
            break;
        case DS_RETE_VAL_JSON:
        case DS_RETE_VAL_JSON_BORROW: {
            if (v->json == NULL) {          /* an absent Json field is null */
                rk_feed_tag(s, RK_NULL);
                break;
            }
            if (live) return false;
            char  *txt = NULL;
            size_t len = 0;
            ds_result_t jr = ds_json_serialize(v->json, &txt, &len);
            if (jr.status != DS_OK || txt == NULL) {
                DS_FREE(txt);
                return false;
            }
            rk_feed_bytes(s, RK_JSON, txt, len);
            DS_FREE(txt);
            break;
        }
        case DS_RETE_VAL_FACT_REF:
            rk_feed_tag(s, RK_FACT);
            rk_feed_u64(s, (uint64_t)v->fact_ref_id);
            break;
        case DS_RETE_VAL_RATIO:
            rk_feed_tag(s, RK_RATIO);
            rk_feed_u64(s, (uint64_t)v->ratio.num);
            rk_feed_u64(s, (uint64_t)v->ratio.den);
            break;
        case DS_RETE_VAL_NULL:
            rk_feed_tag(s, RK_NULL);
            break;
        case DS_RETE_VAL_UNBOUND:
            rk_feed_tag(s, RK_UNBOUND);
            break;
        }
    }
    return true;
}

static ds_rate_entry_t *rate_find(ds_rate_table_t       *t,
                                   const char            *rule_name,
                                   const ds_rete_val_t   *key_args,
                                   uint32_t               n_key_args,
                                   uint32_t               key_hash,
                                   size_t                 key_len,
                                   bool                   live)
{
    if (!t->cap) return NULL;
    uint32_t i = (key_hash ^ (uint32_t)((uintptr_t)rule_name >> 3)) % t->cap;
    for (;;) {
        ds_rate_entry_t *e = &t->entries[i];
        if (!e->rule_name) return NULL;
        if (e->rule_name == rule_name && e->key_hash == key_hash &&
            e->key != NULL && e->key_len == key_len) {
            rk_sink_t c = { .hash = RK_FNV_BASIS, .cmp = e->key,
                            .cmp_len = e->key_len };
            if (rk_walk(&c, key_args, n_key_args, live) && !c.differs)
                return e;
        }
        i = (i + 1) % t->cap;
    }
}

/* Evictable when it would behave as an absent key does. */
static bool rate_entry_evictable(const ds_rate_entry_t *e, int64_t now_ns)
{
    if (!e->has_fired)         return true;
    if (e->cooldown_ns <= 0)   return true;
    return now_ns - e->last_fire_ns >= e->cooldown_ns;
}

static ds_rate_entry_t *rate_get_or_create(ds_rete_engine_t    *engine,
                                            ds_rate_table_t     *t,
                                            const char          *rule_name,
                                            const ds_rete_val_t *key_args,
                                            uint32_t             n_key_args,
                                            uint32_t             key_hash,
                                            size_t               key_len,
                                            int64_t              now_ns)
{
    ds_rate_entry_t *e = rate_find(t, rule_name, key_args, n_key_args,
                                   key_hash, key_len, engine->live);
    if (e) return e;

    /* No allocation after go_live: unknown keys must be pre-warmed. */
    if (engine->live) return NULL;

    /* A varying bound value mints a key every firing, so growing first reclaims
       entries whose windows have elapsed, bounding the table to the active
       working set. */
    if (!t->cap || t->count * 100u / t->cap >= RATE_ALLOW_MAX_LOAD) {
        uint32_t survivors = 0;
        for (uint32_t j = 0; j < t->cap; j++)
            if (t->entries[j].rule_name && !rate_entry_evictable(&t->entries[j], now_ns))
                survivors++;
        uint32_t nc = RATE_ALLOW_INIT_CAP;
        while (survivors * 100u / nc >= RATE_ALLOW_MAX_LOAD) nc *= 2;
        ds_rate_entry_t *nb = DS_CALLOC(nc, sizeof(*nb));
        if (!nb) return NULL;
        for (uint32_t j = 0; j < t->cap; j++) {
            if (!t->entries[j].rule_name) continue;
            if (rate_entry_evictable(&t->entries[j], now_ns)) {
                DS_FREE(t->entries[j].key);
                continue;
            }
            uint32_t h2 = (t->entries[j].key_hash ^
                           (uint32_t)((uintptr_t)t->entries[j].rule_name >> 3)) % nc;
            while (nb[h2].rule_name) h2 = (h2 + 1) % nc;
            nb[h2] = t->entries[j];
        }
        DS_FREE(t->entries);
        t->entries = nb;
        t->cap     = nc;
        t->count   = survivors;
    }

    unsigned char *key = DS_MALLOC(key_len);
    if (!key) return NULL;
    rk_sink_t w = { .hash = RK_FNV_BASIS, .out = key };
    if (!rk_walk(&w, key_args, n_key_args, false) || w.len != key_len) {
        DS_FREE(key);
        return NULL;
    }
    uint32_t i = (key_hash ^ (uint32_t)((uintptr_t)rule_name >> 3)) % t->cap;
    while (t->entries[i].rule_name) i = (i + 1) % t->cap;
    t->entries[i].rule_name    = rule_name;
    t->entries[i].key_hash     = key_hash;
    t->entries[i].key          = key;
    t->entries[i].key_len      = key_len;
    t->entries[i].last_fire_ns    = 0;
    t->entries[i].has_fired       = false;
    t->entries[i].cooldown_ns   = 0;
    t->count++;
    return &t->entries[i];
}

/*
 * (ds-rate-allow <rule-name:Str> [<bound-val> ...] <cooldown-ns:Int>)
 *
 * The bound values form the activation key; a cooldown of 0 is no cooldown.
 * Returns Bool(true) if the activation should fire, Bool(false) to suppress.
 */
static ds_result_t adapter_ds_rate_allow(ds_rete_engine_t   *engine,
                                          ds_rete_eval_ctx_t *ctx,
                                          ds_rete_val_t      *args,
                                          uint32_t            argc,
                                          ds_rete_val_t      *out)
{
    *out = ds_rete_val_bool(false);

    const char *rule_name_str = val_str(&args[0]);
    if (!rule_name_str) { *out = ds_rete_val_bool(true); return DS_OK_R; }

    const char *rule_name;
    ds_rete_intern(engine->intern, rule_name_str, args[0].s.len, &rule_name);

    int64_t cooldown_ns = 0;
    if (args[argc - 1].kind == DS_RETE_VAL_INT) cooldown_ns = args[argc - 1].i;

    const ds_rete_val_t *key_args = &args[1];
    uint32_t n_key_args = argc - 2;

    if (cooldown_ns <= 0) {
        *out = ds_rete_val_bool(true);
        return DS_OK_R;
    }

    ds_rate_table_t *rt = get_rate_table(engine);
    if (!rt) { *out = ds_rete_val_bool(true); return DS_OK_R; }

    int64_t now_ns = engine->clock_fn(engine->clock_ctx);

    rk_sink_t probe = { .hash = RK_FNV_BASIS };
    if (!rk_walk(&probe, key_args, n_key_args, engine->live)) {
        *out = ds_rete_val_bool(true); return DS_OK_R;
    }
    ds_rate_entry_t *entry = rate_get_or_create(engine, rt, rule_name,
                                                key_args, n_key_args,
                                                probe.hash, probe.len, now_ns);
    if (!entry) { *out = ds_rete_val_bool(true); return DS_OK_R; }
    entry->cooldown_ns = cooldown_ns;

    /* The elapsed time, since the sum of an instant and a window can pass the
       top of the clock's range ([LCDB.3.2.1], [LTIM.2.8.2]). */
    if (entry->has_fired
        && now_ns - entry->last_fire_ns < cooldown_ns) {
        *out = ds_rete_val_bool(false);
        return DS_OK_R;
    }

    entry->last_fire_ns = now_ns;
    entry->has_fired    = true;
    *out = ds_rete_val_bool(true);
    return DS_OK_R;
}

/* ---- ds_json_build -------------------------------------------------- */

/*
 * (ds_json_build "k1" v1 "k2" v2 ...) -> Str
 *
 * A JSON object string from (name, value) pairs. Value encoding, canonical
 * ([LDET.3.2.7]):
 *   INT   -> decimal
 *   FLOAT -> shortest round-trip
 *   STR   -> JSON-escaped; BYTES the same
 *   BOOL  -> true / false
 *   TIME  -> its utc_ns instant, a JSON number
 *   JSON  -> the tree's canonical text
 *
 * A key that is not a String is DS_FAULT_ARTEFACT; a value with no JSON spelling
 * is DS_FAULT_NOT_REPRESENTABLE; an allocation failure is DS_FAULT_RESOURCE. A
 * `null` value makes the body `null`, unless another kwarg faults ([LNUL.11.1]).
 */

/* A JSON text under construction. `oom` latches the first allocation failure. */
typedef struct {
    char  *buf;
    size_t len;
    size_t cap;
    bool   oom;
} json_text_t;

static void jt_put(json_text_t *t, const char *s, size_t n)
{
    if (t->oom) return;
    if (t->len + n + 1 > t->cap) {
        size_t cap = t->cap ? t->cap : 256;
        while (t->len + n + 1 > cap) cap *= 2;
        char *nb = DS_REALLOC(t->buf, cap);
        if (nb == NULL) { t->oom = true; return; }
        t->buf = nb;
        t->cap = cap;
    }
    memcpy(t->buf + t->len, s, n);
    t->len += n;
    t->buf[t->len] = '\0';
}

static void jt_putc(json_text_t *t, char c) { jt_put(t, &c, 1); }

static void jt_string(json_text_t *t, const char *s, size_t n)
{
    jt_putc(t, '"');
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if      (c == '"')  jt_put(t, "\\\"", 2);
        else if (c == '\\') jt_put(t, "\\\\", 2);
        else if (c == '\n') jt_put(t, "\\n", 2);
        else if (c == '\r') jt_put(t, "\\r", 2);
        else if (c == '\t') jt_put(t, "\\t", 2);
        else if (c < 0x20) {
            char      esc[8];
            ds_text_t e = ds_text(esc, sizeof esc);
            ds_text_str(&e, "\\u");
            ds_text_hex(&e, c, 4);
            jt_put(t, esc, (size_t)ds_text_len(&e));
        } else {
            jt_putc(t, (char)c);
        }
    }
    jt_putc(t, '"');
}

typedef enum {
    JV_OK,
    JV_NONFINITE,        /* at the top or inside a tree */
    JV_UNREPRESENTABLE,  /* a kind with no JSON spelling */
    JV_RESOURCE,
} jv_status_t;

/* Append one non-null value's JSON text. */
static jv_status_t jt_value(json_text_t *t, const ds_rete_val_t *v)
{
    char      num[64];
    ds_text_t nt = ds_text(num, sizeof num);
    switch (v->kind) {
    case DS_RETE_VAL_INT:
        ds_text_i64(&nt, v->i);
        jt_put(t, num, (size_t)ds_text_len(&nt));
        return JV_OK;
    case DS_RETE_VAL_FLOAT:
        if (!isfinite(v->f)) return JV_NONFINITE;
        ds_text_float(&nt, v->f);
        jt_put(t, num, (size_t)ds_text_len(&nt));
        return JV_OK;
    case DS_RETE_VAL_BOOL:
        if (v->b) jt_put(t, "true", 4); else jt_put(t, "false", 5);
        return JV_OK;
    case DS_RETE_VAL_STR:
    case DS_RETE_VAL_BYTES:
        if (v->s.ptr == NULL && v->s.len > 0) return JV_UNREPRESENTABLE;
        jt_string(t, v->s.ptr ? v->s.ptr : "", v->s.len);
        return JV_OK;
    case DS_RETE_VAL_TIME:
        ds_text_i64(&nt, v->time.utc_ns);
        jt_put(t, num, (size_t)ds_text_len(&nt));
        return JV_OK;
    case DS_RETE_VAL_JSON:
    case DS_RETE_VAL_JSON_BORROW: {
        if (v->json == NULL) return JV_UNREPRESENTABLE;
        char  *text = NULL;
        size_t len  = 0;
        ds_result_t r = ds_json_serialize(v->json, &text, &len);
        if (r.status == DS_ERR_JSON_NONFINITE) return JV_NONFINITE;
        if (r.status != DS_OK) return JV_RESOURCE;
        jt_put(t, text, len);
        ds_free(text);
        return JV_OK;
    }
    case DS_RETE_VAL_NULL:          /* the callers answer null before here */
    case DS_RETE_VAL_FACT_REF:
    case DS_RETE_VAL_RATIO:
    case DS_RETE_VAL_UNBOUND:
        return JV_UNREPRESENTABLE;
    }
    return JV_UNREPRESENTABLE;
}

/* A refused value as the fault that abandons the activation. */
static ds_result_t jt_refuse(ds_rete_engine_t *engine, ds_rete_eval_ctx_t *ctx,
                             jv_status_t why, const char *verb,
                             ds_rete_val_t *out)
{
    switch (why) {
    case JV_NONFINITE:
        ds_json_count_nonfinite(engine, verb);
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_ERR_R(DS_ERR_JSON_NONFINITE,
                        "non-finite Float in a JSON body; verb suppressed");
    case JV_UNREPRESENTABLE:
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    case JV_RESOURCE:
        *out = FAULT(DS_FAULT_RESOURCE);
        return DS_OK_R;
    case JV_OK:
        break;
    }
    return DS_OK_R;
}

/* The finished text into the fire arena. */
static ds_result_t jt_finish(ds_rete_engine_t *engine, ds_rete_eval_ctx_t *ctx,
                             json_text_t *t, ds_rete_val_t *out)
{
    if (t->oom) {
        DS_FREE(t->buf);
        *out = FAULT(DS_FAULT_RESOURCE);
        return DS_OK_R;
    }
    const char *ip = ds_rete_arena_dup(&engine->comp_arena, t->buf, t->len);
    DS_FREE(t->buf);
    if (ip == NULL) {
        *out = FAULT(DS_FAULT_RESOURCE);
        return DS_OK_R;
    }
    *out = ds_rete_val_str(ip, (uint32_t)t->len);
    return DS_OK_R;
}

/* A non-finite Float in a JSON data-plane body is NOT_REPRESENTABLE at the verb
 * ([NERR.6], [LCST.4.5.2]). */
void ds_json_count_nonfinite(ds_rete_engine_t *engine, const char *verb)
{
    if (engine == NULL || engine->ds_engine_back == NULL) return;
    ds_metric_label_t labels[1] = { { .key = "verb", .value = verb } };
    ds_metric_t m = {
        .name   = "ds.json.nonfinite_total",
        .kind   = DS_METRIC_COUNTER, .value = 1.0,
        .labels = labels, .n_labels = 1,
    };
    ds_telemetry_emit_metric((struct ds_engine *)engine->ds_engine_back, &m);
}

static ds_result_t adapter_ds_json_build(ds_rete_engine_t   *engine,
                                          ds_rete_eval_ctx_t *ctx,
                                          ds_rete_val_t      *args,
                                          uint32_t            argc,
                                          ds_rete_val_t      *out)
{
    for (uint32_t i = 0; i < argc; i += 2) {
        if (args[i].kind != DS_RETE_VAL_STR || args[i].s.ptr == NULL) {
            *out = FAULT(DS_FAULT_ARTEFACT);
            return DS_OK_R;
        }
    }

    json_text_t t = { NULL, 0, 0, false };
    bool        absent = false;
    jt_putc(&t, '{');
    for (uint32_t i = 0; i < argc; i += 2) {
        const ds_rete_val_t *v = &args[i + 1];
        /* The scan goes on: a later value's fault still wins ([LNUL.11.1]). */
        if (v->kind == DS_RETE_VAL_NULL) { absent = true; continue; }
        if (t.len > 1) jt_putc(&t, ',');
        jt_string(&t, args[i].s.ptr, args[i].s.len);
        jt_putc(&t, ':');
        jv_status_t st = jt_value(&t, v);
        if (st != JV_OK) {
            DS_FREE(t.buf);
            return jt_refuse(engine, ctx, st, "call", out);
        }
    }
    jt_putc(&t, '}');

    if (absent) {
        DS_FREE(t.buf);
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    return jt_finish(engine, ctx, &t, out);
}


/* ---- ds_json_value -------------------------------------------------- */

/*
 * (ds_json_value v) -> Str. IDSP.13: a single value's JSON text, for a cache
 * value. Encoded as ds_json_build's values are, except that a `null` is stored
 * as `null` ([LNUL.11.1]'s `cache` row).
 */
static ds_result_t adapter_ds_json_value(ds_rete_engine_t   *engine,
                                          ds_rete_eval_ctx_t *ctx,
                                          ds_rete_val_t      *args,
                                          uint32_t            argc,
                                          ds_rete_val_t      *out)
{
    /* IDSP.13.4. Here and not in jt_value, which FN_JSON_BUILD shares. */
    if (args[0].kind == DS_RETE_VAL_BYTES)
        return jt_refuse(engine, ctx, JV_UNREPRESENTABLE, "cache", out);

    json_text_t t = { NULL, 0, 0, false };
    if (args[0].kind == DS_RETE_VAL_NULL) {
        jt_put(&t, "null", 4);
    } else {
        jv_status_t st = jt_value(&t, &args[0]);
        if (st != JV_OK) {
            DS_FREE(t.buf);
            return jt_refuse(engine, ctx, st, "cache", out);
        }
    }
    return jt_finish(engine, ctx, &t, out);
}


/* ---- ds_time_date (LTIM.3.3) -------------------------------------- */

/*
 * (ds_time_date <t:Time> <tz:Str>) -> Date. [LTIM.3.3.1]: the calendar date
 * `t.utc_ns` falls on in zone `tz`, as days since 1970-01-01. Every failure is
 * a fault, never UTC ([LTIM.10.5.3], [LTIM.10.5.4]).
 */
static ds_result_t adapter_ds_time_date(ds_rete_engine_t   *engine,
                                         ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t      *args,
                                         uint32_t            argc,
                                         ds_rete_val_t      *out)
{
    /* A computed Time arrives as TIME, a Time-typed slot as INT. */
    int64_t ns;
    if      (args[0].kind == DS_RETE_VAL_TIME) ns = args[0].time.utc_ns;
    else if (args[0].kind == DS_RETE_VAL_INT)  ns = args[0].i;
    else {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    if (args[1].kind != DS_RETE_VAL_STR || !args[1].s.ptr) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    int32_t offset_s = 0;
    if (!ds_rete_tz_resolve(engine, args[1].s.ptr, args[1].s.len, ns,
                            &offset_s)) {
        *out = FAULT(DS_FAULT_DOMAIN);   /* no row answers ([LTIM.10.7]) */
        return DS_OK_R;
    }
    int64_t days, ns_of_day;
    ds_rete_local_split(ns, offset_s, &days, &ns_of_day);
    /* [LTIM.1.2.2]: a Time near either end of its range can fall on a day
       outside the Date range. */
    if (!ds_date_days_in_range(days)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    *out = ds_rete_val_int(days);
    return DS_OK_R;
}

/* ---- ds_utc / ds_local (LTIM.3.1 / LTIM.3.2) ---------------------- */

/* A computed Time arrives as TIME, a Time-typed slot as INT. */
static bool time_arg_utc_ns(const ds_rete_val_t *v, int64_t *out_ns)
{
    if (v->kind == DS_RETE_VAL_TIME) { *out_ns = v->time.utc_ns; return true; }
    if (v->kind == DS_RETE_VAL_INT)  { *out_ns = v->i;           return true; }
    return false;
}

/*
 * (ds_utc <t>) -> Time. LTIM.3.1: the instant with its offset zeroed. A null is
 * null: the compiler's lowering of a bare `{t}` interpolation can pass one
 * ([LGRA.2.9.6.10]), though an author cannot ([LNUL.5.1]).
 */
static ds_result_t adapter_ds_utc(ds_rete_engine_t   *engine,
                                  ds_rete_eval_ctx_t *ctx,
                                  ds_rete_val_t      *args,
                                  uint32_t            argc,
                                  ds_rete_val_t      *out)
{
    (void)engine;
    int64_t utc_ns;
    if (args[0].kind == DS_RETE_VAL_NULL) {
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    if (!time_arg_utc_ns(&args[0], &utc_ns)) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    *out = ds_rete_val_time(utc_ns, 0);
    return DS_OK_R;
}

/*
 * (ds_local <t> <tz:Str>) -> Time. LTIM.3.2: tz resolved against t.utc_ns; the
 * offset is fixed for the value's lifetime (LTIM.1.1.3). Resolution failure is
 * a fault, never UTC (LTIM.10.5.3, LTIM.10.5.4).
 */
static ds_result_t adapter_ds_local(ds_rete_engine_t   *engine,
                                    ds_rete_eval_ctx_t *ctx,
                                    ds_rete_val_t      *args,
                                    uint32_t            argc,
                                    ds_rete_val_t      *out)
{
    int64_t utc_ns;
    if (!time_arg_utc_ns(&args[0], &utc_ns) ||
        args[1].kind != DS_RETE_VAL_STR || !args[1].s.ptr) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    /* No `TimeZoneOffset` fact answers ([LTIM.10.7]): a DOMAIN ComputationError
       ([LTIM.10.5.3], [LERR.1.4.10]). */
    int32_t offset_s = 0;
    if (!ds_rete_tz_resolve(engine, args[1].s.ptr, args[1].s.len, utc_ns,
                            &offset_s)) {
        *out = FAULT(DS_FAULT_DOMAIN);
        return DS_OK_R;
    }
    *out = ds_rete_val_time(utc_ns, offset_s);
    return DS_OK_R;
}

/*
 * monotonic_ns() -> Duration ([LTIM.2.2.1]): the MONOTONIC clock's held sample
 * ([LTIM.2.8.2], [LTIM.2.8.4]), never a fresh platform read.
 */
static ds_result_t adapter_monotonic_ns(ds_rete_engine_t   *engine,
                                     ds_rete_eval_ctx_t *ctx,
                                     ds_rete_val_t      *args,
                                     uint32_t            argc,
                                     ds_rete_val_t      *out)
{
    (void)engine; (void)args; (void)argc;
    *out = ds_rete_val_int(ds_rete_eval_now_ns(ctx));
    return DS_OK_R;
}

/* ---- to_string format-ids (LTIM.8) and the calendar (LTIM.14) ------------ *
 * Civil<->serial is Hinnant's arithmetic, not gmtime/strftime/timegm, so it is
 * bit-identical across platforms with no libc TZ dependence. */

static int64_t floor_div_i64(int64_t a, int64_t b)
{
    int64_t q = a / b, r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) q--;
    return q;
}

/* In [0, b). Not `a - floor_div_i64(a, b) * b`: near INT64_MIN that product
   overflows. */
static int64_t floor_mod_i64(int64_t a, int64_t b)
{
    int64_t r = a % b;
    return r < 0 ? r + b : r;
}

/* Format-ids are case-insensitive (LTIM.8.2.2). */
static bool fmt_ci_eq(const char *a, size_t len, const char *b)
{
    for (size_t i = 0; i < len; i++, b++) {
        if (*b == '\0') return false;
        char ca = a[i], cb = *b;
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) return false;
    }
    return *b == '\0';
}

typedef enum {
    TFMT_ISO8601, TFMT_EPOCH_S, TFMT_EPOCH_MS, TFMT_EPOCH_US, TFMT_EPOCH_NS,
    TFMT_UNKNOWN
} time_fmt_t;

static time_fmt_t classify_time_fmt(const char *f, size_t len)
{
    if (fmt_ci_eq(f, len, "iso8601"))       return TFMT_ISO8601;
    if (fmt_ci_eq(f, len, "epoch_seconds")) return TFMT_EPOCH_S;
    if (fmt_ci_eq(f, len, "epoch_millis"))  return TFMT_EPOCH_MS;
    if (fmt_ci_eq(f, len, "epoch_micros"))  return TFMT_EPOCH_US;
    if (fmt_ci_eq(f, len, "epoch_nanos"))   return TFMT_EPOCH_NS;
    return TFMT_UNKNOWN;
}

/* Days since 1970-01-01 for a civil date (m in [1,12], d in [1,31]). */
static int64_t days_from_civil(int64_t y, unsigned m, unsigned d)
{
    y -= (m <= 2);
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153u * (m + (m > 2 ? -3u : 9u)) + 2u) / 5u + d - 1u;
    unsigned doe = yoe * 365u + yoe / 4u - yoe / 100u + doy;
    return era * 146097 + (int64_t)doe - 719468;
}

static void civil_from_days(int64_t z, int64_t *y, unsigned *m, unsigned *d)
{
    z += 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);
    unsigned yoe = (doe - doe / 1460u + doe / 36524u - doe / 146096u) / 365u;
    int64_t yy  = (int64_t)yoe + era * 400;
    unsigned doy = doe - (365u * yoe + yoe / 4u - yoe / 100u);
    unsigned mp  = (5u * doy + 2u) / 153u;
    *d = doy - (153u * mp + 2u) / 5u + 1u;
    *m = mp + (mp < 10u ? 3u : (unsigned)-9);
    *y = yy + (*m <= 2);
}

void ds_rete_civil_from_days(int64_t z, int64_t *y, unsigned *m, unsigned *d)
{
    civil_from_days(z, y, m, d);
}

int64_t ds_rete_floor_div_i64(int64_t a, int64_t b)
{
    return floor_div_i64(a, b);
}

int64_t ds_rete_floor_mod_i64(int64_t a, int64_t b)
{
    return floor_mod_i64(a, b);
}

/* Only the UTC day's remainder takes the offset, so no term can overflow:
   |offset_s| * 10^9 is at most 2.2 * 10^18. */
void ds_rete_local_split(int64_t utc_ns, int32_t offset_s,
                         int64_t *days, int64_t *ns_of_day)
{
    const int64_t day = (int64_t)86400 * (int64_t)1000000000;
    int64_t local = floor_mod_i64(utc_ns, day)
                  + (int64_t)offset_s * (int64_t)1000000000;
    int64_t shift = floor_div_i64(local, day);
    *days      = floor_div_i64(utc_ns, day) + shift;
    *ns_of_day = local - shift * day;
}

static bool is_leap_year(int64_t y)
{
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

static unsigned days_in_month(int64_t y, unsigned m)
{
    static const unsigned dim[12] =
        { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return (m == 2u && is_leap_year(y)) ? 29u : dim[m - 1u];
}

/* The largest year a calendar shift may produce: days_from_civil stays inside
   int64 well past this. */
#define SHIFT_YEAR_LIMIT INT64_C(1000000000000000)

static const struct { const char *sym; int64_t ns; } dur_units[] = {
    { "h",  INT64_C(3600000000000) },
    { "m",  INT64_C(60000000000) },
    { "s",  INT64_C(1000000000) },
    { "ms", INT64_C(1000000) },
    { "us", INT64_C(1000) },
    { "ns", INT64_C(1) },
};
#define DUR_UNITS ((int)(sizeof dur_units / sizeof dur_units[0]))

/* [LTIM.8.4]'s compact form, with no sign ([LTIM.8.4.2]). A zero or negative
   count renders `0s` ([LTIM.1.3.1]). */
static void fmt_duration(int64_t d, char *buf, size_t n)
{
    ds_text_t t = ds_text(buf, n);
    if (d <= 0) { ds_text_str(&t, "0s"); return; }
    uint64_t mag = (uint64_t)d;
    for (int i = 0; i < DUR_UNITS; i++) {
        uint64_t u = (uint64_t)dur_units[i].ns;
        uint64_t q = mag / u;
        if (q != 0) {
            ds_text_u64(&t, q);
            ds_text_str(&t, dur_units[i].sym);
            mag -= q * u;
        }
    }
}

/* `YYYY-MM-DD` ([LTIM.8.2.1]). The caller has checked ds_date_days_in_range. */
static void fmt_date(int64_t days, char *buf, size_t n)
{
    int64_t y; unsigned mo, d;
    civil_from_days(days, &y, &mo, &d);
    ds_text_t t = ds_text(buf, n);
    ds_text_i64_zpad(&t, y, 4);  ds_text_char(&t, '-');
    ds_text_i64_zpad(&t, mo, 2); ds_text_char(&t, '-');
    ds_text_i64_zpad(&t, d, 2);
}

/* `days` moved by `months`, its day clamped to the target month's last
   ([LTIM.4.3.2]). False when there is no answer. Whether the result is a Date
   is the caller's to check. */
static bool shift_days(int64_t days, int64_t months, int64_t *out)
{
    int64_t y; unsigned m, d;
    civil_from_days(days, &y, &m, &d);
    int64_t idx;
    if (__builtin_mul_overflow(y, INT64_C(12), &idx) ||
        __builtin_add_overflow(idx, (int64_t)(m - 1u), &idx) ||
        __builtin_add_overflow(idx, months, &idx))
        return false;
    int64_t ny = floor_div_i64(idx, 12);
    unsigned nm = (unsigned)(idx - ny * 12) + 1u;
    if (ny > SHIFT_YEAR_LIMIT || ny < -SHIFT_YEAR_LIMIT) return false;
    unsigned last = days_in_month(ny, nm);
    *out = days_from_civil(ny, nm, d < last ? d : last);
    return true;
}

/* ---- Time components (LTIM.6.5) ------------------------------------- *
 * (FN_<C> <t> <zone:Str>) -> Int: one component of the instant t in the zone,
 * in [LTIM.6.3]'s range. */

typedef enum {
    TC_HOUR, TC_MINUTE, TC_SECOND, TC_DAY, TC_MONTH, TC_YEAR, TC_DAY_OF_WEEK
} time_component_t;

static ds_result_t time_component(ds_rete_engine_t   *engine,
                                  ds_rete_eval_ctx_t *ctx,
                                  ds_rete_val_t      *args,
                                  uint32_t            argc,
                                  time_component_t    which,
                                  ds_rete_val_t      *out)
{
    int64_t utc_ns;
    if (!time_arg_utc_ns(&args[0], &utc_ns) ||
        args[1].kind != DS_RETE_VAL_STR || !args[1].s.ptr) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    /* A component read in a zone is a local() evaluation ([LTIM.10.5.3]). */
    int32_t offset_s = 0;
    if (!ds_rete_tz_resolve(engine, args[1].s.ptr, args[1].s.len, utc_ns,
                            &offset_s)) {
        *out = FAULT(DS_FAULT_DOMAIN);
        return DS_OK_R;
    }
    /* Day 0, 1970-01-01, was a Thursday, so 0 = Monday ([LTIM.6.4]) is
       (day + 3) mod 7. */
    int64_t days, ns_of_day;
    ds_rete_local_split(utc_ns, offset_s, &days, &ns_of_day);

    int64_t y = 0;
    unsigned mo = 0, d = 0;
    civil_from_days(days, &y, &mo, &d);
    int64_t v = 0;
    switch (which) {
    case TC_HOUR:        v = ns_of_day / 3600000000000LL;        break;
    case TC_MINUTE:      v = (ns_of_day / 60000000000LL) % 60;   break;
    case TC_SECOND:      v = (ns_of_day / 1000000000LL) % 60;    break;
    case TC_DAY:         v = (int64_t)d;                         break;
    case TC_MONTH:       v = (int64_t)mo;                        break;
    case TC_YEAR:        v = y;                                  break;
    case TC_DAY_OF_WEEK: v = days + 3 - floor_div_i64(days + 3, 7) * 7; break;
    }
    *out = ds_rete_val_int(v);
    return DS_OK_R;
}

#define TIME_COMPONENT_ADAPTER(name, which)                                  \
    static ds_result_t name(ds_rete_engine_t   *engine,                     \
                            ds_rete_eval_ctx_t *ctx,                        \
                            ds_rete_val_t      *args,                       \
                            uint32_t            argc,                       \
                            ds_rete_val_t      *out)                        \
    {                                                                        \
        return time_component(engine, ctx, args, argc, which, out);         \
    }

TIME_COMPONENT_ADAPTER(adapter_time_hour,        TC_HOUR)
TIME_COMPONENT_ADAPTER(adapter_time_minute,      TC_MINUTE)
TIME_COMPONENT_ADAPTER(adapter_time_second,      TC_SECOND)
TIME_COMPONENT_ADAPTER(adapter_time_day,         TC_DAY)
TIME_COMPONENT_ADAPTER(adapter_time_month,       TC_MONTH)
TIME_COMPONENT_ADAPTER(adapter_time_year,        TC_YEAR)
TIME_COMPONENT_ADAPTER(adapter_time_day_of_week, TC_DAY_OF_WEEK)

/* A builtin's string result is transient: arena, not interned, until an emit
   commits it. */
static ds_rete_val_t intern_str_val(ds_rete_engine_t *engine,
                                    ds_rete_eval_ctx_t *ctx, const char *s)
{
    size_t len = strlen(s);
    const char *ip = ds_rete_arena_dup(&engine->comp_arena, s, len);
    if (ip == NULL) return FAULT(DS_FAULT_RESOURCE);
    return ds_rete_val_str(ip, (uint32_t)len);
}

/* iso8601 into buf (>= 48 bytes). The offset is "Z" for UTC, else
   "+HH:MM"/"-HH:MM"; a nonzero sub-second part is ".<9 digits>", trailing zeros
   trimmed. */
static void fmt_iso8601(int64_t utc_ns, int32_t offset_s, char *buf, size_t n)
{
    int64_t days, ns_of_day;
    ds_rete_local_split(utc_ns, offset_s, &days, &ns_of_day);
    int64_t frac = ns_of_day % 1000000000LL;
    int     sod  = (int)(ns_of_day / 1000000000LL);
    int64_t y; unsigned mo, d;
    civil_from_days(days, &y, &mo, &d);
    int hh = sod / 3600, mm = (sod % 3600) / 60, ss = sod % 60;
    ds_text_t t = ds_text(buf, n);
    ds_text_i64_zpad(&t, y, 4);  ds_text_char(&t, '-');
    ds_text_i64_zpad(&t, mo, 2); ds_text_char(&t, '-');
    ds_text_i64_zpad(&t, d, 2);  ds_text_char(&t, 'T');
    ds_text_i64_zpad(&t, hh, 2); ds_text_char(&t, ':');
    ds_text_i64_zpad(&t, mm, 2); ds_text_char(&t, ':');
    ds_text_i64_zpad(&t, ss, 2);
    int p = ds_text_len(&t);
    if ((size_t)p >= n) return;
    if (frac != 0) {
        char fb[12];
        ds_text_t ft = ds_text(fb, sizeof fb);
        ds_text_i64_zpad(&ft, frac, 9);
        int fl = 9;
        while (fl > 1 && fb[fl - 1] == '0') fl--;
        if ((size_t)(p + 1 + fl) < n) {
            buf[p++] = '.';
            memcpy(buf + p, fb, (size_t)fl);
            p += fl;
            buf[p] = '\0';
        }
    }
    if (offset_s == 0) {
        if ((size_t)(p + 1) < n) { buf[p++] = 'Z'; buf[p] = '\0'; }
    } else {
        int32_t a = offset_s < 0 ? -offset_s : offset_s;
        ds_text_t ot = ds_text(buf + p, n - (size_t)p);
        ds_text_char(&ot, offset_s < 0 ? '-' : '+');
        ds_text_i64_zpad(&ot, a / 3600, 2);
        ds_text_char(&ot, ':');
        ds_text_i64_zpad(&ot, (a % 3600) / 60, 2);
    }
}

/* The format argument of a temporal conversion: "iso8601" when it is absent
   ([LTIM.8.1.1], [LTIM.8.1.2]). False when it is present and not a String. */
static bool time_fmt_arg(ds_rete_val_t *args, uint32_t argc, const char **fmt,
                         size_t *len)
{
    *fmt = "iso8601";
    *len = sizeof "iso8601" - 1;
    if (argc < 2) return true;
    if (args[1].kind != DS_RETE_VAL_STR || !args[1].s.ptr) return false;
    *fmt = args[1].s.ptr;
    *len = args[1].s.len;
    return true;
}

/*
 * (ds_to_string <t:Time|Date> [<fmt:Str>]) -> Str. [LTIM.8.1.2]: a TIME value
 * is a Time, since the compiler hands every `Time` receiver through `utc(...)`.
 * An untagged INT is a Date ([RDSC.5.5.8]), which admits `iso8601` alone. An
 * identifier the receiver does not admit is NOT_REPRESENTABLE ([LTIM.8.3.2]).
 */
static ds_result_t adapter_ds_to_string(ds_rete_engine_t   *engine,
                                        ds_rete_eval_ctx_t *ctx,
                                        ds_rete_val_t      *args,
                                        uint32_t            argc,
                                        ds_rete_val_t      *out)
{
    const char *fmt;
    size_t      fmt_len;
    if (args[0].kind == DS_RETE_VAL_NULL) {
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    if ((args[0].kind != DS_RETE_VAL_TIME && args[0].kind != DS_RETE_VAL_INT) ||
        !time_fmt_arg(args, argc, &fmt, &fmt_len)) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    time_fmt_t f = classify_time_fmt(fmt, fmt_len);
    char buf[48];
    if (args[0].kind == DS_RETE_VAL_INT) {
        if (f != TFMT_ISO8601 || !ds_date_days_in_range(args[0].i)) {
            *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
            return DS_OK_R;
        }
        fmt_date(args[0].i, buf, sizeof buf);
        *out = intern_str_val(engine, ctx, buf);
        return DS_OK_R;
    }
    int64_t utc_ns = args[0].time.utc_ns;
    ds_text_t t = ds_text(buf, sizeof buf);
    switch (f) {
    case TFMT_ISO8601:
        fmt_iso8601(utc_ns, args[0].time.tz_offset_s, buf, sizeof buf);
        break;
    case TFMT_EPOCH_S:  ds_text_i64(&t, floor_div_i64(utc_ns, 1000000000LL)); break;
    case TFMT_EPOCH_MS: ds_text_i64(&t, floor_div_i64(utc_ns, 1000000LL)); break;
    case TFMT_EPOCH_US: ds_text_i64(&t, floor_div_i64(utc_ns, 1000LL)); break;
    case TFMT_EPOCH_NS: ds_text_i64(&t, utc_ns); break;
    default:
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    *out = intern_str_val(engine, ctx, buf);
    return DS_OK_R;
}

/* ---- calendar.time / calendar.date ([LTIM.14]) -------------------------- *
 * A value from its fields ([LTIM.14.1]). In the order [LTIM.14.2] states: a null
 * field is null, a field outside its range is DOMAIN, a value outside its type's
 * range is NOT_REPRESENTABLE.
 *
 * 1677-09-21 is day -106752, whose midnight is below INT64_MIN while most of its
 * instants are not, so a day before the epoch is reached from the next midnight,
 * `(days + 1) * day + (ns_of_day - day)`, and the sum overflows exactly when the
 * instant is out of range. */

#define CALENDAR_REQUIRE(n_) \
    do { for (uint32_t _i = 0; _i < (n_); _i++) \
             if (args[_i].kind == DS_RETE_VAL_NULL) \
                 { *out = ds_rete_val_null(); return DS_OK_R; } \
         for (uint32_t _i = 0; _i < (n_); _i++) \
             if (args[_i].kind != DS_RETE_VAL_INT) \
                 { *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R; } \
    } while (0)

/* The day count of (y, m, d), or false when a field is outside its range
   (*domain) or the year names no value of either type (!*domain). */
static bool calendar_days(int64_t y, int64_t m, int64_t d, int64_t *days,
                          bool *domain)
{
    *domain = m < 1 || m > 12 || d < 1 ||
              d > (int64_t)days_in_month(y, (unsigned)m);
    if (*domain) return false;
    if (y > SHIFT_YEAR_LIMIT || y < -SHIFT_YEAR_LIMIT) return false;
    *days = days_from_civil(y, (unsigned)m, (unsigned)d);
    return true;
}

/*
 * (ds_calendar_time <year> <month> <day> <hour> <minute> <second>
 *  <nanosecond>) -> Time, at offset 0 ([LTIM.14.1]).
 */
static ds_result_t adapter_ds_calendar_time(ds_rete_engine_t   *engine,
                                            ds_rete_eval_ctx_t *ctx,
                                            ds_rete_val_t      *args,
                                            uint32_t            argc,
                                            ds_rete_val_t      *out)
{
    (void)engine;
    const int64_t day = (int64_t)86400 * (int64_t)1000000000;
    CALENDAR_REQUIRE(7u);
    int64_t h = args[3].i, mi = args[4].i, s = args[5].i, ns = args[6].i;
    int64_t days;
    bool domain;
    bool ok = calendar_days(args[0].i, args[1].i, args[2].i, &days, &domain);
    if (domain || h < 0 || h > 23 || mi < 0 || mi > 59 || s < 0 || s > 59 ||
        ns < 0 || ns > 999999999) {
        *out = FAULT(DS_FAULT_DOMAIN);
        return DS_OK_R;
    }
    if (!ok) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    int64_t ns_of_day = ((h * 60 + mi) * 60 + s) * (int64_t)1000000000 + ns;
    int64_t base = days, rest = ns_of_day, result;
    if (days < 0) {
        base = days + 1;
        rest = ns_of_day - day;
    }
    if (__builtin_mul_overflow(base, day, &result) ||
        __builtin_add_overflow(result, rest, &result)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    *out = ds_rete_val_time(result, 0);
    return DS_OK_R;
}

/*
 * (ds_calendar_date <year> <month> <day>) -> Date, its days since the epoch
 * ([LTIM.14.1], [RDSC.5.5.8]).
 */
static ds_result_t adapter_ds_calendar_date(ds_rete_engine_t   *engine,
                                            ds_rete_eval_ctx_t *ctx,
                                            ds_rete_val_t      *args,
                                            uint32_t            argc,
                                            ds_rete_val_t      *out)
{
    (void)engine;
    CALENDAR_REQUIRE(3u);
    int64_t days;
    bool domain;
    bool ok = calendar_days(args[0].i, args[1].i, args[2].i, &days, &domain);
    if (domain) {
        *out = FAULT(DS_FAULT_DOMAIN);
        return DS_OK_R;
    }
    if (!ok || !ds_date_days_in_range(days)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    *out = ds_rete_val_int(days);
    return DS_OK_R;
}

#undef CALENDAR_REQUIRE

/*
 * (ds_duration_to_string <d:Duration>) -> Str. [LTIM.8.1.2], [LTIM.8.4].
 */
static ds_result_t adapter_ds_duration_to_string(ds_rete_engine_t   *engine,
                                                 ds_rete_eval_ctx_t *ctx,
                                                 ds_rete_val_t      *args,
                                                 uint32_t            argc,
                                                 ds_rete_val_t      *out)
{
    if (args[0].kind == DS_RETE_VAL_NULL) {
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    if (args[0].kind != DS_RETE_VAL_INT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    char buf[48];
    fmt_duration(args[0].i, buf, sizeof buf);
    *out = intern_str_val(engine, ctx, buf);
    return DS_OK_R;
}

/*
 * (ds_add_months <t:Time|Date> <n:Int>) and (ds_add_years ...), [LTIM.4.3.1].
 * A TIME moves its UTC calendar date and keeps its nanoseconds since that UTC
 * midnight and its offset ([LTIM.4.3.3]); an untagged INT is a Date. A result
 * its type cannot represent is NOT_REPRESENTABLE ([LTIM.1.1.5]).
 */
static ds_result_t calendar_shift(ds_rete_engine_t   *engine,
                                  ds_rete_eval_ctx_t *ctx,
                                  ds_rete_val_t      *args,
                                  uint32_t            argc,
                                  int64_t             months_per,
                                  ds_rete_val_t      *out)
{
    (void)engine;
    const int64_t day = (int64_t)86400 * (int64_t)1000000000;
    if (args[0].kind == DS_RETE_VAL_NULL || args[1].kind == DS_RETE_VAL_NULL) {
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    if ((args[0].kind != DS_RETE_VAL_TIME && args[0].kind != DS_RETE_VAL_INT) ||
        args[1].kind != DS_RETE_VAL_INT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    int64_t months, shifted;
    if (__builtin_mul_overflow(args[1].i, months_per, &months)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    if (args[0].kind == DS_RETE_VAL_INT) {
        if (!ds_date_days_in_range(args[0].i) ||
            !shift_days(args[0].i, months, &shifted) ||
            !ds_date_days_in_range(shifted)) {
            *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
            return DS_OK_R;
        }
        *out = ds_rete_val_int(shifted);
        return DS_OK_R;
    }
    int64_t utc_ns = args[0].time.utc_ns;
    int64_t days = floor_div_i64(utc_ns, day);
    int64_t ns_of_day = floor_mod_i64(utc_ns, day);
    int64_t result;
    if (!shift_days(days, months, &shifted)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    /* Reached from the next midnight before the epoch, as in the calendar
       adapters: only the result instant can be unrepresentable ([LTIM.4.3.3]). */
    int64_t base = shifted, rest = ns_of_day;
    if (shifted < 0) {
        base = shifted + 1;
        rest = ns_of_day - day;
    }
    if (__builtin_mul_overflow(base, day, &result) ||
        __builtin_add_overflow(result, rest, &result)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    *out = ds_rete_val_time(result, args[0].time.tz_offset_s);
    return DS_OK_R;
}

static ds_result_t adapter_ds_add_months(ds_rete_engine_t   *engine,
                                         ds_rete_eval_ctx_t *ctx,
                                         ds_rete_val_t      *args,
                                         uint32_t            argc,
                                         ds_rete_val_t      *out)
{
    return calendar_shift(engine, ctx, args, argc, 1, out);
}

static ds_result_t adapter_ds_add_years(ds_rete_engine_t   *engine,
                                        ds_rete_eval_ctx_t *ctx,
                                        ds_rete_val_t      *args,
                                        uint32_t            argc,
                                        ds_rete_val_t      *out)
{
    return calendar_shift(engine, ctx, args, argc, 12, out);
}

/*
 * (ds_date_add_duration <d:Date> <dur:Duration>) and
 * (ds_date_sub_duration ...), [LTIM.4.2.3] / RLOW.6.1.5. Null on either side is
 * null ([LNUL.4.1]); a Duration not a whole number of days is DOMAIN
 * ([LTIM.4.2.2]); a receiver or result outside [LTIM.1.2.2]'s range is
 * NOT_REPRESENTABLE. `d - dur` has its own sign because negating INT64_MIN
 * overflows.
 */
static ds_result_t date_shift(ds_rete_eval_ctx_t *ctx, ds_rete_val_t *args,
                              uint32_t argc, int64_t sign, ds_rete_val_t *out)
{
    const int64_t day = (int64_t)86400 * (int64_t)1000000000;
    if (args[0].kind == DS_RETE_VAL_NULL || args[1].kind == DS_RETE_VAL_NULL) {
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    if (args[0].kind != DS_RETE_VAL_INT || args[1].kind != DS_RETE_VAL_INT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    if (args[1].i % day != 0) {
        *out = FAULT(DS_FAULT_DOMAIN);
        return DS_OK_R;
    }
    if (!ds_date_days_in_range(args[0].i)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    int64_t shifted = args[0].i + sign * (args[1].i / day);
    if (!ds_date_days_in_range(shifted)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    *out = ds_rete_val_int(shifted);
    return DS_OK_R;
}

static ds_result_t adapter_ds_date_add_duration(ds_rete_engine_t   *engine,
                                                ds_rete_eval_ctx_t *ctx,
                                                ds_rete_val_t      *args,
                                                uint32_t            argc,
                                                ds_rete_val_t      *out)
{
    (void)engine;
    return date_shift(ctx, args, argc, 1, out);
}

static ds_result_t adapter_ds_date_sub_duration(ds_rete_engine_t   *engine,
                                                ds_rete_eval_ctx_t *ctx,
                                                ds_rete_val_t      *args,
                                                uint32_t            argc,
                                                ds_rete_val_t      *out)
{
    (void)engine;
    return date_shift(ctx, args, argc, -1, out);
}

/*
 * (ds_date_diff <a:Date> <b:Date>), [LTIM.4.2.3] / RLOW.6.1.5: a's day count
 * minus b's, in ns, 0 when a is the earlier ([LTIM.1.3.1]). An operand outside
 * [LTIM.1.2.2]'s range, or a difference whose ns pass int64, is
 * NOT_REPRESENTABLE.
 */
static ds_result_t adapter_ds_date_diff(ds_rete_engine_t   *engine,
                                        ds_rete_eval_ctx_t *ctx,
                                        ds_rete_val_t      *args,
                                        uint32_t            argc,
                                        ds_rete_val_t      *out)
{
    (void)engine;
    const int64_t day = (int64_t)86400 * (int64_t)1000000000;
    if (args[0].kind == DS_RETE_VAL_NULL || args[1].kind == DS_RETE_VAL_NULL) {
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    if (args[0].kind != DS_RETE_VAL_INT || args[1].kind != DS_RETE_VAL_INT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    int64_t ns;
    if (!ds_date_days_in_range(args[0].i) ||
        !ds_date_days_in_range(args[1].i)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    if (args[0].i <= args[1].i) {
        *out = ds_rete_val_int(0);
        return DS_OK_R;
    }
    if (__builtin_mul_overflow(args[0].i - args[1].i, day, &ns)) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    *out = ds_rete_val_int(ns);
    return DS_OK_R;
}

/*
 * (ds_duration_add <a> <b>), [LTIM.4.1.1] / RLOW.6.1.6: the exact sum of two
 * Durations' ns. A sum above 2^63 - 1, or a negative one, is NOT_REPRESENTABLE.
 */
static ds_result_t adapter_ds_duration_add(ds_rete_engine_t   *engine,
                                           ds_rete_eval_ctx_t *ctx,
                                           ds_rete_val_t      *args,
                                           uint32_t            argc,
                                           ds_rete_val_t      *out)
{
    (void)engine;
    if (args[0].kind == DS_RETE_VAL_NULL || args[1].kind == DS_RETE_VAL_NULL) {
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    if (args[0].kind != DS_RETE_VAL_INT || args[1].kind != DS_RETE_VAL_INT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    int64_t ns;
    if (__builtin_add_overflow(args[0].i, args[1].i, &ns) || ns < 0) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        return DS_OK_R;
    }
    *out = ds_rete_val_int(ns);
    return DS_OK_R;
}

/*
 * (ds_duration_mul <n:Int> <dur>), [LTIM.4.1.1] / RLOW.6.1.6: the exact product
 * in ns. A product above 2^63 - 1 is NOT_REPRESENTABLE, and a negative one is 0
 * ([LTIM.1.3.1]), however far below the integer range it lies.
 */
static ds_result_t adapter_ds_duration_mul(ds_rete_engine_t   *engine,
                                           ds_rete_eval_ctx_t *ctx,
                                           ds_rete_val_t      *args,
                                           uint32_t            argc,
                                           ds_rete_val_t      *out)
{
    (void)engine;
    if (args[0].kind == DS_RETE_VAL_NULL || args[1].kind == DS_RETE_VAL_NULL) {
        *out = ds_rete_val_null();
        return DS_OK_R;
    }
    if (args[0].kind != DS_RETE_VAL_INT || args[1].kind != DS_RETE_VAL_INT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc));
        return DS_OK_R;
    }
    int64_t ns;
    if (__builtin_mul_overflow(args[0].i, args[1].i, &ns)) {
        if ((args[0].i < 0) != (args[1].i < 0)) {
            *out = ds_rete_val_int(0);
        } else {
            *out = FAULT(DS_FAULT_NOT_REPRESENTABLE);
        }
        return DS_OK_R;
    }
    *out = ds_rete_val_int(ns < 0 ? 0 : ns);
    return DS_OK_R;
}


/* ---- ds_gensym ------------------------------------------------------ */

/* (ds_gensym) — a unique per-engine string "g<N>", the activation-unique
   correlation between the facts one after-clause RHS asserts. Interned, so
   equality joins on it compare by pointer. */
static ds_result_t adapter_ds_gensym(ds_rete_engine_t   *engine,
                                      ds_rete_eval_ctx_t *ctx,
                                      ds_rete_val_t      *args,
                                      uint32_t            argc,
                                      ds_rete_val_t      *out)
{
    (void)args;
    char buf[32];
    ds_text_t t = ds_text(buf, sizeof(buf));
    ds_text_char(&t, 'g');
    ds_text_u64(&t, engine->next_gensym++);
    int n = ds_text_len(&t);
    /* Becomes a fact-slot value, so counted and reclaimed with the fact. */
    const char *ip = NULL;
    ds_result_t r = ds_rete_intern_value_cstr(engine->intern, buf, &ip);
    if (r.status != DS_OK) return r;
    *out = ds_rete_val_str(ip, (uint32_t)n);
    return DS_OK_R;
}

/* ---- FN_INTERVAL_CHECK ([RLOW.6.1.7]) ---------------------------------- */

/* `eval_interval_check` (rete/eval.c) evaluates an admitted count whole and
   `eval_call` raises ARTEFACT_LIED for any other, so nothing reaches this; a
   runtime holds a handler for the op at its site ([RDSC.4a.9.3]). */
static ds_result_t adapter_ds_interval_check(ds_rete_engine_t   *engine,
                                             ds_rete_eval_ctx_t *ctx,
                                             ds_rete_val_t      *args,
                                             uint32_t            argc,
                                             ds_rete_val_t      *out)
{
    (void)engine;
    (void)args;
    (void)argc;
    *out = ds_rete_fault(ctx, NULL, DS_FAULT_ARTEFACT);
    return DS_OK_R;
}

/* ---- Conversion casts (LCST.4.5) --------------------------------------- */

/* Float→Int (LCST.4.5.4): truncate toward zero. A non-finite or out-of-range
   value is a fault, not a null. */
static ds_result_t adapter_ds_float_to_int(ds_rete_engine_t   *engine,
                                           ds_rete_eval_ctx_t *ctx,
                                           ds_rete_val_t      *args,
                                           uint32_t            argc,
                                           ds_rete_val_t      *out)
{
    (void)engine;
    if (args[0].kind != DS_RETE_VAL_FLOAT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }
    double f = args[0].f;
    /* 9223372036854775808.0 = 2^63 is the first unrepresentable positive. */
    if (!isfinite(f) || f >= 9223372036854775808.0
        || f < -9223372036854775808.0) {
        *out = FAULT(DS_FAULT_NOT_REPRESENTABLE); return DS_OK_R;
    }
    *out = ds_rete_val_int((int64_t)f);
    return DS_OK_R;
}

/* Float→String (LCST.4.5.6). */
static ds_result_t adapter_ds_float_to_string(ds_rete_engine_t   *engine,
                                              ds_rete_eval_ctx_t *ctx,
                                              ds_rete_val_t      *args,
                                              uint32_t            argc,
                                              ds_rete_val_t      *out)
{
    if (args[0].kind != DS_RETE_VAL_FLOAT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }
    char buf[48];
    ds_fmt_float(buf, sizeof buf, args[0].f);
    *out = intern_str_val(engine, ctx, buf);
    return DS_OK_R;
}

/* Int→String ([LCST.4.5.6]). */
static ds_result_t adapter_ds_int_to_string(ds_rete_engine_t   *engine,
                                            ds_rete_eval_ctx_t *ctx,
                                            ds_rete_val_t      *args,
                                            uint32_t            argc,
                                            ds_rete_val_t      *out)
{
    if (args[0].kind != DS_RETE_VAL_INT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }
    char      buf[24];
    ds_text_t t = ds_text(buf, sizeof buf);
    ds_text_i64(&t, args[0].i);
    *out = intern_str_val(engine, ctx, buf);
    return DS_OK_R;
}

/* Bool→String ([LCST.4.5.6]). */
static ds_result_t adapter_ds_bool_to_string(ds_rete_engine_t   *engine,
                                             ds_rete_eval_ctx_t *ctx,
                                             ds_rete_val_t      *args,
                                             uint32_t            argc,
                                             ds_rete_val_t      *out)
{
    if (args[0].kind != DS_RETE_VAL_BOOL) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }
    *out = intern_str_val(engine, ctx, args[0].b ? "true" : "false");
    return DS_OK_R;
}

/* String→Float? ([LCST.4.5.8]). No NaN spelling is accepted. */
static ds_result_t adapter_ds_string_to_float(ds_rete_engine_t   *engine,
                                              ds_rete_eval_ctx_t *ctx,
                                              ds_rete_val_t      *args,
                                              uint32_t            argc,
                                              ds_rete_val_t      *out)
{
    (void)engine;
    /* [IRET.9.6]. A `null` source never gets here: eval_call answers it
       ([LCST.4.3.4]). */
    if (args[0].kind != DS_RETE_VAL_STR) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }
    if (!args[0].s.ptr) { *out = ds_rete_val_null(); return DS_OK_R; }
    double v;
    if (ds_parse_float_text(args[0].s.ptr, args[0].s.len, &v) != 0) {
        *out = ds_rete_val_null(); return DS_OK_R;
    }
    *out = ds_rete_val_float(v);
    return DS_OK_R;
}

/* String→Int? ([LCST.4.5.7]). */
static ds_result_t adapter_ds_string_to_int(ds_rete_engine_t   *engine,
                                            ds_rete_eval_ctx_t *ctx,
                                            ds_rete_val_t      *args,
                                            uint32_t            argc,
                                            ds_rete_val_t      *out)
{
    (void)engine;
    if (args[0].kind != DS_RETE_VAL_STR) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }
    if (!args[0].s.ptr) { *out = ds_rete_val_null(); return DS_OK_R; }
    int64_t v;
    if (ds_parse_int_text(args[0].s.ptr, args[0].s.len, &v) != 0) {
        *out = ds_rete_val_null(); return DS_OK_R;
    }
    *out = ds_rete_val_int(v);
    return DS_OK_R;
}

/* String→Bool? (LCST.4.5.5): exactly "true" and "false". */
static ds_result_t adapter_ds_string_to_bool(ds_rete_engine_t   *engine,
                                             ds_rete_eval_ctx_t *ctx,
                                             ds_rete_val_t      *args,
                                             uint32_t            argc,
                                             ds_rete_val_t      *out)
{
    (void)engine;
    if (args[0].kind != DS_RETE_VAL_STR) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }
    if (!args[0].s.ptr) { *out = ds_rete_val_null(); return DS_OK_R; }
    const char *s = args[0].s.ptr;
    const size_t n = args[0].s.len;
    if (n == 4 && memcmp(s, "true", 4) == 0)
        *out = ds_rete_val_bool(true);
    else if (n == 5 && memcmp(s, "false", 5) == 0)
        *out = ds_rete_val_bool(false);
    else
        *out = ds_rete_val_null();
    return DS_OK_R;
}

static ds_result_t adapter_ds_int_to_float(ds_rete_engine_t   *engine,
                                           ds_rete_eval_ctx_t *ctx,
                                           ds_rete_val_t      *args,
                                           uint32_t            argc,
                                           ds_rete_val_t      *out)
{
    (void)engine;
    if (args[0].kind != DS_RETE_VAL_INT) {
        *out = FAULT(ds_rete_mismatch_cause(args, argc)); return DS_OK_R;
    }
    *out = ds_rete_val_float((double)args[0].i);
    return DS_OK_R;
}

#define REG(op, fn) do { \
    ds_result_t _r = ds_register_fn_rt((op), (fn)); \
    if (_r.status != DS_OK) return _r; \
} while (0)

/* rt_safe: the runtime's gate is for integrator builtins; whether a form is
   permitted under +realtime is enforced at compile time. */
ds_result_t ds_rete_register_adapters(ds_rete_engine_t              *engine,
                                        const ds_rete_adapter_config_t *config)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "register_adapters: NULL engine");

    engine->adapter = config ? *config : (ds_rete_adapter_config_t){0};

    REG(DS_FN_PUBLISH,            adapter_ds_publish);
    REG(DS_FN_LOG,                adapter_ds_log);
    REG(DS_FN_CALL,               adapter_ds_call);
    REG(DS_FN_RETRACT_CORR,       adapter_ds_retract_corr);
    REG(DS_FN_RETRACT_TOKEN_FACT, adapter_ds_retract_token_fact);
    REG(DS_FN_CACHE_GET,          adapter_ds_cache_get);
    REG(DS_FN_CACHE_SET,          adapter_ds_cache_set);
    REG(DS_FN_CACHE_DELETE,       adapter_ds_cache_delete);
    REG(DS_FN_RATE_ALLOW,         adapter_ds_rate_allow);
    REG(DS_FN_INTERVAL_CHECK,     adapter_ds_interval_check);

    REG(DS_FN_FLOAT_TO_INT,       adapter_ds_float_to_int);
    REG(DS_FN_FLOAT_TO_STRING,    adapter_ds_float_to_string);
    REG(DS_FN_INT_TO_STRING,      adapter_ds_int_to_string);
    REG(DS_FN_BOOL_TO_STRING,     adapter_ds_bool_to_string);
    REG(DS_FN_STRING_TO_FLOAT,    adapter_ds_string_to_float);
    REG(DS_FN_STRING_TO_INT,      adapter_ds_string_to_int);
    REG(DS_FN_STRING_TO_BOOL,     adapter_ds_string_to_bool);
    REG(DS_FN_INT_TO_FLOAT,       adapter_ds_int_to_float);

    REG(DS_FN_JSON_BUILD,         adapter_ds_json_build);
    REG(DS_FN_JSON_VALUE,         adapter_ds_json_value);
    REG(DS_FN_TIME_DATE,          adapter_ds_time_date);
    REG(DS_FN_UTC,                adapter_ds_utc);
    REG(DS_FN_LOCAL,              adapter_ds_local);
    REG(DS_FN_MONOTONIC_NS,       adapter_monotonic_ns);
    REG(DS_FN_HOUR,               adapter_time_hour);
    REG(DS_FN_MINUTE,             adapter_time_minute);
    REG(DS_FN_SECOND,             adapter_time_second);
    REG(DS_FN_DAY,                adapter_time_day);
    REG(DS_FN_MONTH,              adapter_time_month);
    REG(DS_FN_YEAR,               adapter_time_year);
    REG(DS_FN_DAY_OF_WEEK,        adapter_time_day_of_week);
    REG(DS_FN_TO_STRING,          adapter_ds_to_string);
    REG(DS_FN_DURATION_TO_STRING, adapter_ds_duration_to_string);
    REG(DS_FN_CALENDAR_TIME,      adapter_ds_calendar_time);
    REG(DS_FN_CALENDAR_DATE,      adapter_ds_calendar_date);
    REG(DS_FN_ADD_MONTHS,         adapter_ds_add_months);
    REG(DS_FN_ADD_YEARS,          adapter_ds_add_years);
    REG(DS_FN_DATE_ADD_DURATION,  adapter_ds_date_add_duration);
    REG(DS_FN_DATE_SUB_DURATION,  adapter_ds_date_sub_duration);
    REG(DS_FN_DATE_DIFF,          adapter_ds_date_diff);
    REG(DS_FN_DURATION_ADD,       adapter_ds_duration_add);
    REG(DS_FN_DURATION_MUL,       adapter_ds_duration_mul);

    REG(DS_FN_GENSYM,             adapter_ds_gensym);

    return DS_OK_R;
}

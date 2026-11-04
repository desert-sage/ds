/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/adapters.h — DS action-verb adapter functions for the DS Rete engine.
 *
 * Each ds_fn_t wrapper implements one DS action verb by decoding ds_rete_val_t
 * arguments and dispatching to the registered integrator callback. ds-publish
 * asserts nothing ([LTIE.4.3]): it judges the values and hands them to
 * publish_cb.
 */
#ifndef LIBDS2_INTERNAL_RETE_ADAPTERS_H
#define LIBDS2_INTERNAL_RETE_ADAPTERS_H

#include <stdint.h>

#include "libds.h"
#include "rete/schema.h"   /* ds_rete_schema_t, publish_cb's schema */
#include "rete/val.h"

struct ds_rete_engine;
struct ds_rete_eval_ctx;
struct ds_rete_fact;

/* ---- Native Rete callback types ----------------------------------- */

/* Log: (ds-log <level> <category> <message>) */
typedef struct {
    ds_log_level_t  level;
    const char     *category;
    const char     *message;
} ds_rete_log_event_t;

typedef ds_result_t (*ds_rete_log_cb_t)(struct ds_rete_engine      *engine,
                                          const ds_rete_log_event_t  *event,
                                          void                       *user);

/* Call: (ds-call <service> <correlation> "k1" v1 "k2" v2 ...), kwargs sorted
   by name (RDSC.4a.9.4, RLOW.7.3.1). The engine-side bridge types them. */
typedef struct {
    const char          *service;
    const char          *correlation;    /* the `as` or generated value (LCRS.3.1); NULL when the artefact's operand is null */
    const ds_rete_val_t *operands;       /* name, value, name, value ... */
    uint32_t             operand_count;  /* 2 x the kwarg count */
    int64_t              timetag;    /* firing activation identity ([RFCS.15]) */
    const char          *rule_name;  /* firing rule (interned) */
} ds_rete_call_request_t;

typedef ds_result_t (*ds_rete_call_cb_t)(struct ds_rete_engine         *engine,
                                           const ds_rete_call_request_t  *request,
                                           void                          *user);

/* Cache: (ds-cache-get <key>), (ds-cache-set <key> <json> <ttl-ns>),
 *        (ds-cache-delete <key>) */
typedef ds_result_t (*ds_rete_cache_get_cb_t)(struct ds_rete_engine *engine,
                                                const char            *key,
                                                char                 **out_json,  /* caller frees */
                                                void                  *user);

typedef ds_result_t (*ds_rete_cache_set_cb_t)(struct ds_rete_engine *engine,
                                                const char            *key,
                                                const char            *value_json,
                                                uint64_t               ttl_ns,
                                                void                  *user);

typedef ds_result_t (*ds_rete_cache_delete_cb_t)(struct ds_rete_engine *engine,
                                                   const char            *key,
                                                   void                  *user);

/* Publish: fires once ds-publish has judged its values ([LTIE.4.8]), with the
   schema and one value per slot in declaration order. No fact exists: the
   values are borrowed for the call only, and nothing enters working memory
   ([LTIE.4.3]). The DS engine turns them into the ACTION_PUBLISH event and its
   FactExternal (engine_rete_adapters.c, bridge_publish). */
typedef ds_result_t (*ds_rete_publish_cb_t)(struct ds_rete_engine  *engine,
                                              const ds_rete_schema_t *schema,
                                              const ds_rete_val_t    *slots,
                                              void                   *user);

/* Emit: fires after a rule's `emit` asserts a fact. The DS engine wires this
   to wrap the fact into a ds_fact_t in engine->wm.table. */
typedef ds_result_t (*ds_rete_emit_cb_t)(struct ds_rete_engine *engine,
                                           struct ds_rete_fact   *fact,
                                           void                  *user);

/* ---- Adapter configuration ---------------------------------------- */

typedef struct {
    /* Log callback (NULL = silent drop) */
    ds_rete_log_cb_t          log_cb;
    void                     *log_user;
    /* Call callback (NULL = DS_ERR_STORAGE_UNAVAILABLE) */
    ds_rete_call_cb_t         call_cb;
    void                     *call_user;
    /* Cache callbacks (each may be NULL → DS_ERR_STORAGE_UNAVAILABLE) */
    ds_rete_cache_get_cb_t    cache_get_cb;
    ds_rete_cache_set_cb_t    cache_set_cb;
    ds_rete_cache_delete_cb_t cache_delete_cb;
    void                     *cache_user;
    /* Publish callback (NULL = no cross-tier notification) */
    ds_rete_publish_cb_t      publish_cb;
    void                     *publish_user;
    /* Emit callback (NULL = no DS-WM wrapping); see ds_rete_emit_cb_t. */
    ds_rete_emit_cb_t         emit_cb;
    void                     *emit_user;
    /* Emit ACTION marker (NULL = no DS_EV_ACTION_EMIT). Fired only by the
       `emit` verb, not by `publish` (IDSP.4.5). */
    ds_rete_emit_cb_t         emit_action_cb;
    void                     *emit_action_user;

    /* Internal: cleanup called by engine_destroy to free rate-allow state.
     * Set by ds_rete_register_adapters; do not set directly. */
    void (*_cleanup)(void *state);
    void  *_cleanup_state;
} ds_rete_adapter_config_t;

/* ---- Registration -------------------------------------------------- */

/*
 * ds_rete_register_adapters — register all adapters into the op-indexed
 * builtin dispatch and store the callbacks. config is copied.
 */
ds_result_t ds_rete_register_adapters(struct ds_rete_engine        *engine,
                                        const ds_rete_adapter_config_t *config);

/*
 * ds_rete_publish_values — a `publish` of `schema` with `slots`, one value per
 * slot in declaration order, judged and sent ([LTIE.4.3], [LTIE.4.8]): a value
 * its slot does not admit is a TypeError on `ctx` or, with no ctx, a refusal;
 * otherwise the values go to publish_cb. Nothing enters working memory.
 * `slots` may be canonicalised in place ([LNUL.3.4]). The interpreted adapter
 * and ds_dispatcher_publish both come here.
 */
ds_result_t ds_rete_publish_values(struct ds_rete_engine   *engine,
                                   struct ds_rete_eval_ctx *ctx,
                                   const ds_rete_schema_t  *schema,
                                   ds_rete_val_t           *slots);

/*
 * ds_json_count_nonfinite — increment ds.json.nonfinite_total{verb} for a
 * non-finite Float refused from a JSON data-plane body. No-op when the rete
 * engine has no DS engine back-pointer.
 */
void ds_json_count_nonfinite(struct ds_rete_engine *engine, const char *verb);

/*
 * ds_rete_retract_corr_sweep — retract every live fact of `schema_name` whose
 * `slot_name` slot equals `corr` (content equality; an empty string-shaped
 * `corr` sweeps nothing), with cause SUPERSEDED. For the host assert path's
 * arrival supersede ([LCRS.6.2.4]).
 */
ds_result_t ds_rete_retract_corr_sweep(struct ds_rete_engine *engine,
                                        const char            *schema_name,
                                        const char            *slot_name,
                                        const ds_rete_val_t   *corr);

/* The proleptic Gregorian civil date of a day count from 1970-01-01, and floor
 * division and modulus (b > 0). */
void    ds_rete_civil_from_days(int64_t z, int64_t *y, unsigned *m, unsigned *d);
int64_t ds_rete_floor_div_i64(int64_t a, int64_t b);
int64_t ds_rete_floor_mod_i64(int64_t a, int64_t b);

/* The local day of `utc_ns` at `offset_s` and the nanosecond of that day, in
 * [0, 86 400 * 10^9), computed without forming `utc_ns + offset_ns`, which
 * leaves int64 near the ends of the Time range. */
void    ds_rete_local_split(int64_t utc_ns, int32_t offset_s,
                            int64_t *days, int64_t *ns_of_day);

#endif /* LIBDS2_INTERNAL_RETE_ADAPTERS_H */

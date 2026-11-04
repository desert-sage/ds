/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * dispatcher.h — internal action-verb routing ([IARC.3.5]): the integrator's action
 * callbacks, and the AOT dispatch table.
 */
#ifndef LIBDS2_INTERNAL_DISPATCHER_H
#define LIBDS2_INTERNAL_DISPATCHER_H


#include "libds.h"

struct ds_engine;



typedef struct ds_dispatcher_state {
    struct ds_engine *engine;       /* non-owning */

    ds_call_cb_t           call_cb;
    void                  *call_user;
    /* Optional, mirroring writes outbound ([NCBK.7]). NULL: a volatile cache. */
    ds_cache_set_cb_t      cache_set_cb;
    ds_cache_delete_cb_t   cache_delete_cb;
    void                  *cache_user;

    /* [NDET.8.2]: how many replays are running on this engine. While nonzero no
       effect callback is invoked, and a missing call_cb is no error ([IDSP.6.4]). */
    uint32_t               replay_depth;
} ds_dispatcher_state_t;

ds_result_t ds_dispatcher_init(ds_dispatcher_state_t *d,
                                struct ds_engine      *engine);

/* Safe even if init failed. */
ds_result_t ds_dispatcher_destroy(ds_dispatcher_state_t *d);

void ds_dispatcher_replay_enter(struct ds_engine *);
void ds_dispatcher_replay_leave(struct ds_engine *);

/* ---- AOT dispatch table ([IDSP.14], [RAOT.6]) ----------------------
 *
 * The field layout is the slot table layout, and must not be reordered. Slots 0-4
 * and 6 are the action verbs and slot 5 is reserved ([IDSP.14.2]). Slot 7 is a
 * formatting service for compiled code, which has no libc.
 */
struct ds_rete_val;
struct ds_rete_token;

typedef struct ds_dispatch_t {
    /* Slot 0 */
    ds_result_t (*wm_assert)      (struct ds_engine *,
                                   const char          *schema_name,
                                   struct ds_rete_val  *slots,
                                   uint32_t             slot_count,
                                   bool                 is_logical,
                                   struct ds_rete_token *justifier);
    /* Slot 1 */
    ds_result_t (*publish)        (struct ds_engine *,
                                   const char          *schema_name,
                                   struct ds_rete_val  *slots,
                                   uint32_t             slot_count,
                                   bool                 is_logical,
                                   int64_t              retain_ns);
    /* Slot 2 — the call's typed arguments, sorted by name ([IDSP.14.2]). */
    ds_result_t (*call)           (struct ds_engine *,
                                   const char        *service,
                                   const char        *correlation,
                                   const ds_arg_t    *args,
                                   uint32_t           arg_count,
                                   uint64_t           cooldown_ns);
    /* Slot 3 */
    ds_result_t (*cache_set)      (struct ds_engine *,
                                   const char        *key,
                                   const char        *value_json,
                                   int64_t            ttl_ns);
    /* Slot 4 */
    ds_result_t (*cache_delete)   (struct ds_engine *,
                                   const char        *key);
    /* Slot 5 — reserved ([IDSP.14.2]). */
    void         *reserved5;
    /* Slot 6 */
    ds_result_t (*log)            (struct ds_engine *,
                                   ds_log_level_t     level,
                                   const char        *rule_name,
                                   const char        *message);
    /* Slot 7 */
    void        (*fmt_float)      (char *buf, size_t cap, double v);
} ds_dispatch_t;

void ds_dispatcher_init_dispatch_table(struct ds_engine *engine);

ds_result_t ds_dispatcher_wm_assert    (struct ds_engine *,
                                        const char          *schema_name,
                                        struct ds_rete_val  *slots,
                                        uint32_t             slot_count,
                                        bool                 is_logical,
                                        struct ds_rete_token *justifier);
ds_result_t ds_dispatcher_publish      (struct ds_engine *,
                                        const char          *schema_name,
                                        struct ds_rete_val  *slots,
                                        uint32_t             slot_count,
                                        bool                 is_logical,
                                        int64_t              retain_ns);
ds_result_t ds_dispatcher_call         (struct ds_engine *,
                                        const char       *service,
                                        const char       *correlation,
                                        const ds_arg_t   *args,
                                        uint32_t          arg_count,
                                        uint64_t          cooldown_ns);

/* A live fact's FactExternal encoding ([RFCS.23.1]), packed into `*out`, which the
   caller frees with DS_FREE. Defined in rfcs/codec.c. Refused for a fact whose
   FactAssert was never numbered. */
ds_result_t ds_fact_external_pack(const ds_fact_t *fact,
                                  uint8_t **out, size_t *out_len);

/* [LCRS.6.2.4]: the arrival supersede, run by the host assert path before an answer
   is asserted. Any other schema, or an empty `corr`, is a no-op. */
ds_result_t ds_dispatch_supersede_arrival(struct ds_engine      *engine,
                                          const ds_schema_t     *schema,
                                          const ds_slot_value_t *values,
                                          uint32_t               n_values);

/* The one call funnel, for the AOT slot and the interpreted bridge. A NaN Float
   argument refuses the call, with no event and no callback ([IDSP.6.5], [LEXP.4.2]).
   Otherwise the event, then the callback ([NCBK.6.9]). NULL callback:
   DS_ERR_STORAGE_UNAVAILABLE, after the event. During a replay no callback is
   invoked ([NDET.8.2], [IDSP.6.4]). */
ds_result_t ds_dispatcher_call_typed   (struct ds_engine *,
                                        const char       *service,
                                        const char       *correlation,
                                        const ds_arg_t   *args,
                                        uint32_t          arg_count,
                                        int64_t           timetag,
                                        const char       *rule_name);
ds_result_t ds_dispatcher_cache_set    (struct ds_engine *,
                                        const char       *key,
                                        const char       *value_json,
                                        int64_t           ttl_ns);
ds_result_t ds_dispatcher_cache_delete (struct ds_engine *,
                                        const char       *key);

/* [NSTG.2.4]: every path that takes an entry out of engine->cache routes through
   here. The callback's error is returned; it does not restore the entry
   ([LSTO.4.7.2]). Not called during a replay ([NDET.8.2]). */
ds_result_t ds_dispatcher_notify_cache_removal(struct ds_engine *,
                                               const char       *key,
                                               ds_cache_removal_reason_t reason);

/* Mirror a write the engine's cache has already taken ([LSTO.4.7.2], [NCBK.7.5]):
   the one place cache_set_cb is invoked. `tree` is NULL for an erase-shaped write.
   The callback's error is returned and the cache is not rolled back. Not called
   during a replay ([NDET.8.2]). */
ds_result_t ds_dispatcher_notify_cache_set(struct ds_engine *,
                                           const char       *key,
                                           const ds_json_t  *tree,
                                           uint64_t          ttl_ns);
ds_result_t ds_dispatcher_log          (struct ds_engine *,
                                        ds_log_level_t    level,
                                        const char       *rule_name,
                                        const char       *message);
void        ds_dispatcher_fmt_float    (char *buf, size_t cap, double v);

#endif /* LIBDS2_INTERNAL_DISPATCHER_H */

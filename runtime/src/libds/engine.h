/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * engine.h — internal definitions for the engine module ([IARC.3.2], [IDAT.9.1]).
 */
#ifndef LIBDS2_INTERNAL_ENGINE_H
#define LIBDS2_INTERNAL_ENGINE_H

#include <stdbool.h>
#include <stdint.h>

/* Whether this target has a floating-point environment to pin ([LDET.3.6.1]). A
   soft-float ARM build's helpers are always to-nearest, and libds.a may not
   reference picolibc's fenv there (runtime/docker/mcu_allow/). */
#if defined(__arm__) && !defined(__ARM_FP)
#define DS_FP_ENV 0
#else
#define DS_FP_ENV 1
#include <fenv.h>
#endif


#include "libds.h"

#include "cache.h"
#include "clock.h"
#include "dispatcher.h"
#include "recorder.h"
#include "schema.h"
#include "telemetry.h"
#include "wm.h"

#include "series/backend.h"
#include "series/dispatch.h"
#include "series/registry.h"
#include "series/state.h"

struct ds_engine {

    ds_clock_t clock;

    ds_telemetry_state_t telemetry;

    ds_recorder_state_t recorder;

    ds_schema_registry_t schemas;

    ds_wm_state_t wm;

    /* [LSTO.4.7]: written only by cache/cache_delete on the input stream and the
       startup hydrate. */
    ds_cache_t cache;

    /* Set on the first ds_engine_pump: ds_engine_cache_seed is setup-phase
       ([NLFC.9.1]). */
    bool has_pumped;

    /* Set when a DS_EV_ENGINE_ERROR is emitted, never cleared ([NCBK.2.9]).
       Latched in the recorder's fault funnel, so a fault cannot reach the stream
       without halting the tier. See DS_ENGINE_REFUSE_IF_HALTED. */
    bool halted;

    /* The fault the first DS_EV_ENGINE_ERROR carried ([NCBK.2.11]). */
    ds_engine_fault_t halt_fault;

    /* Integrator callbacks on the stack ([RARC.13.16]), raised only around the
       call expression, so no early return can leave it raised. Non-zero means a
       ds_engine_* call is re-entry, and answers DS_ERR_STATE. */
    uint32_t callback_depth;

    /* [NCBK.1.5]: the first non-OK status the stream callback returned during the
       current public call, never acted on. `api_depth` counts the public entry
       points on the stack, since libds calls its own; only the outermost clears
       and reports the status. See ds_api_enter. */
    uint32_t    api_depth;
    ds_result_t stream_status;

    /* [NCBK.2.9]: whether the engine had halted when the outermost public call
       entered. ds_api_leave reports a halt the call raised as DS_ERR_ENGINE_HALTED. */
    bool        halted_at_entry;

    /* [RFCS.24]: the FactExternal delivery in progress, while
       ds_engine_assert_external asserts its facts. Owned by rfcs/codec.c. */
    void       *rfcs_delivery;

    /* [LDET.3.6.1]: the integrator's environment, valid only while api_depth > 0.
       See ds_fp_establish. */
#if DS_FP_ENV
    fenv_t fp_saved;
#endif

    ds_dispatcher_state_t dispatcher;

    ds_dispatch_t dispatch_table;

    uint64_t next_seq;      /* stream-event seq */
    uint64_t next_fact_id;  /* monotonic per-engine fact id */
    /* clock_ns at the start of the firing rule's RHS, for
       ds.rules.fire_duration_seconds. 0 outside a fire. */
    uint64_t rule_fire_start_ns;

    /* The dialect-binding tuple ([RBND.1.3]), valid iff dsc_hash_valid. */
    uint8_t dsc_hash[32];
    bool    dsc_hash_valid;   /* false until ds_engine_load_dsc has succeeded. */
    uint8_t  dsc_def_sha256[32];
    uint32_t dsc_capabilities[64];  /* DS_BINDING_CAPABILITIES_MAX (binding.h) */
    size_t   n_dsc_capabilities;
    /* Owned copies of ds_engine_config_t's, NULL when absent or "" ([NLFC.1.2]). */
    char   *run_id;
    char   *tier_id;

    /* [NLFC.10.2]: one ds_admission_t per `Capability` value. Calloc'd, so an
       engine nobody configured admits every setting. */
    uint8_t admission[DS_CAPABILITY_STORAGE_HYDRATE_SAMPLES + 1];

    /* Per-rule metadata from the artefact ([RDSC.6]). */
    struct ds_rule_meta {
        char     *rule_name;       /* owned */
        bool      has_cool;
        uint64_t  cool_window_ns;
        bool      has_srcr;
        char     *src_file;        /* owned; set iff has_srcr */
        uint32_t  src_line;
        uint32_t  src_col;
        bool      has_dnam;
        char     *debug_name_template; /* owned; set iff has_dnam */
    } *rule_metas;
    size_t n_rule_metas;
    size_t cap_rule_metas;

    /* Open-addressing, power-of-two cap, 70% load. Keys point into rule_metas[].
       Present whenever n_rule_metas > 0 outside a load ([RDSC.9.8]). */
    struct ds_rmeta_map_entry {
        const char *key; /* NULL = empty slot */
        size_t      idx; /* index into rule_metas[] */
    } *rule_meta_map;
    size_t rule_meta_map_cap;

    /* [RDSC.14]: tooling reads these; the runtime does not. */
    struct ds_ds_source {
        uint32_t module_id;
        char    *file;      /* owned; display only */
        char    *text;      /* owned */
        size_t   text_len;
    } *ds_sources;
    size_t n_ds_sources;
    size_t cap_ds_sources;
    struct ds_line_span {
        uint32_t node_id;
        uint32_t ds_line;          /* 1-based */
        uint32_t ds_col;           /* 1-based */
        char    *ds_file;          /* owned; display only */
        uint32_t module_id;
    } *line_spans;
    size_t n_line_spans;
    size_t cap_line_spans;

    /* One per backend atom ([RDSC.5a]). The loader's storage shape; absorption
       builds a ds_series_decl_t (series/backend.h) from it for instance_new. */
    struct ds_series_decl_record {
        uint32_t atom_field;          /* the backing atom's DS_ATOM_SERIES_BACKEND_* */
        uint32_t module_id;
        char    *schema_name;         /* owned */
        char    *slot_name;           /* owned */
        char    *identity_slot_name;  /* owned; "" for `by: none` */
        uint64_t window_ns;           /* 0 = unwindowed */
        uint64_t persist_ns;          /* 0 = live-only */
        uint32_t element_type;        /* SeriesBackendRingBuffer only */
        uint32_t max_samples;         /* SeriesBackendRingBuffer only */
        uint32_t time_model;          /* SeriesBackendNumericIntegral only ([LSIG.2.3.6]) */
        uint32_t gap_policy;          /* SeriesBackendNumericIntegral only ([LSIG.3]) */
        uint32_t null_policy;         /* SeriesNullPolicy ([LNUL.8.6]); 0 = non-nullable source */
        /* [LSER.16.2]: numeric backings compute in `double`, and a state row may
           not exist yet at a pre-sample read ([LSER.8.6.1]). */
        bool     slot_is_int;
    } *series_decls;
    size_t n_series_decls;
    size_t cap_series_decls;

    /* [LCRS.6.2.1]: each ServiceDef, in artefact order, with every string owned;
       `response` is "" for `no response`. [NDBG.2.4] reads it. */
    struct ds_call_service {
        char *name;
        char *response;
        bool  no_response;
        ds_service_kwarg_view_t *kwargs;
        uint32_t n_kwargs;
    } *call_services;
    size_t n_call_services;

    /* [LGRA.24.3]: the `initial` items, pending until ds_engine_clock_step's first
       step. Owned; dsc/loader.c frees and clones them. */
    struct dsc_initial *initial;
    size_t n_initial;

    /* [LSER.8.5.1]: samples of facts superseded inside a pump, which the end-of-pump
       walk of working memory cannot see. ds_rete_engine_absorb_pending drains them,
       oldest first, ahead of the walk; a where-clause read must see the pre-sample
       snapshot ([LSER.8.6.1]).

       An entry allocates nothing ([NRTM.1.1]): a String or Bytes value holds a
       counted intern reference, with its length, since the intern is keyed by
       (ptr, len). Anything else renders into identity_buf. */
    struct ds_series_pending_sample {
        const char     *schema_name;         /* borrowed: series_decls */
        const char     *slot_name;           /* borrowed: series_decls */
        const char     *identity_slot_name;  /* borrowed: series_decls */
        const char     *identity_interned;   /* ref held; NULL => *_buf */
        size_t          identity_len;
        const char     *value_interned;      /* ref held; NULL => not STRING */
        size_t          value_len;
        char            identity_buf[64];
        ds_slot_value_t value;               /* v.s rebound at drain */
        uint64_t        ts_ns;
    } *pending_samples;
    size_t n_pending_samples;
    size_t cap_pending_samples;
    /* RT: pre-sized once by ds_engine_set_wm_max; a growth attempt is a contract
       breach. */
    bool   pending_samples_fixed;

    /* [LSER.13.14]: the rete fact id the next fact would have taken when the last
       series absorb began. A live fact at or past it, not yet series_absorbed, is
       one the next absorb will sample, as is every entry of pending_samples. */
    uint32_t series_absorb_mark;

    /* [LSER.9.1.1], [ISBK.1.2]: allocated lazily on first absorption. */
    ds_series_state_registry_t series_state;

    /* A vtable's index here is its stable slot id; series_state's rows index their
       backend_state[] by it. opaque_handle is NULL on every registration ([NSBK.2.3]). */
    struct ds_engine_series_backend_slot {
        const ds_series_backend_vtable_t *vtable;
        void                              *opaque_handle;
    } *backend_slots;
    size_t n_backend_slots;
    size_t cap_backend_slots;

    /* Built lazily by ds_engine_get_platform_signature ([LDET.2.3]). */
    char  **platform_sig_backends;
    size_t  platform_sig_n_backends;

    /* The first error from a void engine callback, drained by the libds call that
       triggered it. pending_detail must be a static literal or an engine-interned
       string: scratch would be overwritten before the drain. */
    ds_status_t  pending_status;
    const char  *pending_detail;

    ds_engine_config_t config;

    /* Opaque, so engine.h does not pull in the rete/ header tree. */
    struct ds_rete_engine *rete_engine;

    /* For ds_engine_sweep_ttl_via_wrappers: sized at go_live so the sweep never
       reallocs during a pump. NULL until then, or with no TTL schema. */
    struct ds_fact **ttl_sweep_buf;
    size_t           ttl_sweep_cap;

    /* `scope activation` ([LSCP.2.4.1], [LSCP.3.1]). The pending and token lists are
       the current firing's, drained by the after-fire hook. `act_attach` holds (token
       rete id, activation rete id) pairs, pruned by ds_engine_retract_rete_fact. All
       hold rete fact ids: one that is gone when looked up is a no-op ([LSCP.3.3]). */
    uint32_t *act_pending;  size_t n_act_pending, cap_act_pending;
    uint32_t *act_tokens;   size_t n_act_tokens,  cap_act_tokens;
    struct ds_act_attach { uint32_t token_id, fact_id; } *act_attach;
    size_t    n_act_attach, cap_act_attach;
};

/* In engine_rete_adapters.c. */
struct ds_rete_fact;
void ds_engine_act_note_emitted(struct ds_engine *engine,
                                struct ds_rete_engine *re,
                                struct ds_rete_fact *fact);
void ds_engine_act_complete(struct ds_engine *engine, struct ds_rete_engine *re);
void ds_engine_act_discharge(struct ds_engine *engine, struct ds_rete_engine *re,
                             uint32_t token_id);

/* [RARC.13.16], [NLFC.3.3]: every ds_engine_* call on this engine, reads included,
   answers DS_ERR_STATE inside a callback. The depth is per engine. Only the four
   calls a halted engine still answers carry this directly. */
#define DS_ENGINE_REFUSE_IF_REENTERED(e)                                    \
    do {                                                                    \
        if ((e) != NULL && (e)->callback_depth != 0) {                      \
            return DS_ERR_R(DS_ERR_STATE,                                   \
                            "called from inside a callback on this engine; " \
                            "the engine is not re-entrant");                \
        }                                                                   \
    } while (0)

/* [NCBK.2.9]: refuses every public call once an EngineError has latched, reads
   included ([LERR.1.4.7]). Four calls do not carry it, none reading that state:
   ds_engine_halted, ds_engine_get_platform_signature,
   ds_engine_get_session_header and ds_engine_free.

   Re-entry is checked first: inside a callback every call is DS_ERR_STATE, the one
   delivering the EngineError included. */
#define DS_ENGINE_REFUSE_IF_HALTED(e)                                       \
    do {                                                                    \
        DS_ENGINE_REFUSE_IF_REENTERED(e);                                   \
        if ((e) != NULL && (e)->halted) {                                   \
            return DS_ERR_R(DS_ERR_ENGINE_HALTED,                           \
                            "engine halted by an EngineError; state is no "  \
                            "longer trustworthy");                          \
        }                                                                   \
    } while (0)

/* [NCBK.2.9]: the ds_fact_get_* / ds_schema_get_* accessors. A handle read is
   answered until the engine has delivered the EngineError (`recorder.closed`) or
   the call that raised it has returned (`api_depth` 0, for a halt whose EngineError
   is never dispatched), so the records [RFCS.6.7] delivers ahead of it can be read.

   No re-entry check: a handle read inside a stream callback is how the integrator
   reads the record it was handed. libds's own reads take the `_unchecked` bodies. */
static inline bool ds_engine_handle_read_refused(const struct ds_engine *e)
{
    return e != NULL && e->halted
        && (e->recorder.closed || e->api_depth == 0);
}

#define DS_HANDLE_REFUSE_IF_HALTED(e)                                       \
    do {                                                                    \
        if (ds_engine_handle_read_refused(e)) {                             \
            return DS_ERR_R(DS_ERR_ENGINE_HALTED,                           \
                            "engine halted by an EngineError; a read "       \
                            "through a fact or schema handle is refused");  \
        }                                                                   \
    } while (0)

/* [NCBK.1.5]: every public entry point that can emit a stream event runs its body
   between these two. On exit the outermost call returns the first non-OK
   stream-callback status in place of an OK; a call that failed keeps its own status.
   Both tolerate a NULL engine. */
void        ds_api_enter(struct ds_engine *engine);
ds_result_t ds_api_leave(struct ds_engine *engine, ds_result_t r);

/* [LDET.3.6.1], [NDET.1.3] (formal/tla/fp_mode.tla): the outermost public call saves
   the environment it found and installs the IEEE default; its return puts the saved
   one back. A callback runs in the saved environment. The whole environment, not
   fesetround: an integrator's FTZ or enabled trap would otherwise reach the engine,
   and its exception flags are restored too.

   Outside a public call (api_depth == 0) nothing was saved and nothing is switched. */
static inline void ds_fp_establish(struct ds_engine *engine)
{
#if DS_FP_ENV
    (void)fegetenv(&engine->fp_saved);
    (void)fesetenv(FE_DFL_ENV);
#else
    (void)engine;
#endif
}

static inline void ds_fp_restore(struct ds_engine *engine)
{
#if DS_FP_ENV
    (void)fesetenv(&engine->fp_saved);
#else
    (void)engine;
#endif
}

static inline void ds_callback_enter(struct ds_engine *engine)
{
    engine->callback_depth++;
    if (engine->api_depth > 0) {
        ds_fp_restore(engine);
    }
}

static inline void ds_callback_leave(struct ds_engine *engine)
{
#if DS_FP_ENV
    if (engine->api_depth > 0) {
        (void)fesetenv(FE_DFL_ENV);
    }
#endif
    engine->callback_depth--;
}

/* In platform.c. */
void ds_engine_platform_signature_dispose(struct ds_engine *engine);

/* First error wins until the slot is drained. */
void ds_engine_set_pending(struct ds_engine *engine, ds_result_t r);

/* Writes DS_OK with NULL detail when no error is pending. */
void ds_engine_take_pending(struct ds_engine *engine, ds_result_t *out);

/* DS_ERR_OOM, the index left as it was, when the table cannot be allocated. */
ds_result_t ds_engine_rule_meta_map_rebuild(struct ds_engine *engine);

struct ds_rule_meta;
struct ds_rule_meta *ds_engine_find_rule_meta(struct ds_engine *engine,
                                           const char *rule_name);

/* [LCAP.1]: sets the rete_engine's cap_* fields. */
void ds_engine_apply_cap_flags(struct ds_engine *engine,
                                bool cap_nological,
                                bool cap_nolinscan,
                                bool cap_dynamic_ttl,
                                bool cap_realtime,
                                bool cap_constspace);

/* The working-memory bound and the pool-sizing setters are internal ([NRTM.9.1]):
 * libds's own tests call them. */

/* [RDSC.16.3.7]: N_max. Advisory without a realtime contract ([NRTM.3.1]): only an
 * engine left pending-RT by its artefact, or already in RT mode, takes it as a hard
 * limit, and then this also sets up RT mode. N=0 means unlimited (non-RT). */
ds_result_t ds_engine_set_wm_max(struct ds_engine *engine, uint32_t n_max);

/* Pool shaping, each before ds_engine_set_wm_max; 0 keeps the default.
 *   token_depth  k_max, the facts[] pointers a token embeds (default 16);
 *   token_pool   the token pool's capacity (default wm_max x 8);
 *   presz        the per-node table pre-size (default next_pow2(N x 4)). */
ds_result_t ds_engine_set_rt_token_depth(struct ds_engine *engine,
                                         uint32_t depth);
ds_result_t ds_engine_set_rt_token_pool_cap(struct ds_engine *engine,
                                            uint32_t cap);
ds_result_t ds_engine_set_rt_presz_cap(struct ds_engine *engine, uint32_t cap);

/* For the RFCS replayer ([RFCS.7.4]): a `+dynamic_ttl` deadline ([LDTL.4.1]) is not
 * recoverable from the artefact.
 *
 * As ds_engine_assert, except the fact's deadline is the assert clock plus
 * ttl_ns_override whatever the schema's lifecycle; 0 means the schema's own
 * TTL. DS_ERR_TIME_RANGE, and nothing asserted, when a non-zero override
 * puts the deadline past INT64_MAX nanoseconds ([LTIM.1.1.5]). */
ds_result_t ds_engine_assert_with_ttl(struct ds_engine      *engine,
                                      const ds_schema_t     *schema,
                                      const ds_slot_value_t *values,
                                      uint32_t               n_values,
                                      uint64_t               ttl_ns_override,
                                      ds_fact_t            **out_fact);

/* For libds's own unit tests, which build a schema without compiling one
 * ([NFCT.1.1]); no product path calls it.
 *
 * The engine owns the schema from then on, and copies type_name and each slot's
 * name and docstring. *out_schema, when out_schema is non-NULL, is a borrow.
 *
 *   lifecycle  DS_SCHEMA_LIFECYCLE_LOGICAL or _TTL; _INTERNAL is refused
 *   ttl_ns     > 0 for TTL; 0 for LOGICAL
 *
 * Setup only: DS_ERR_STATE after the engine's first stream event or first pump, and
 * when the name is taken. Otherwise DS_ERR_INVAL (validation, a `logical` slot with
 * no identity role, a tolerance marker the slot cannot carry, and DS_IDENTITY_ENGINE
 * anywhere but a logical schema's non-nullable Time `ts`), DS_ERR_OOM. */
ds_result_t ds_engine_register_schema(struct ds_engine      *engine,
                                      const char            *type_name,
                                      ds_schema_lifecycle_t  lifecycle,
                                      uint64_t               ttl_ns,
                                      const ds_slot_desc_t  *slots,
                                      uint32_t               n_slots,
                                      const ds_schema_t    **out_schema);

/* ds_engine_cache_seed without its host window ([NLFC.9.1]): the `initial:` block's
   cache items ([LGRA.24.3]), at the first step after its tick is recorded. */
ds_result_t ds_engine_cache_seed_initial(struct ds_engine *engine,
                                         const char       *key,
                                         const ds_json_t  *value,
                                         uint64_t          ttl_ns);

/* [NLFC.9.5]: DS_ERR_TIME_RANGE when the engine's first sample, holding
   `sample_ns`, would give a held seed a deadline outside the `Time` range. Asked
   before a step, so a refused call takes none. */
ds_result_t ds_engine_nlfc_9_5_first_sample_in_range(struct ds_engine *engine,
                                                     uint64_t sample_ns);

/* ds_engine_cache_seed as the replayer applies a recorded CacheSeed
   ([RFCS.26.2]): the host's window and checks, the value as JSON text
   (`len` bytes, parsed under [LGRA.5.8.6]'s limits), and the entry's absolute
   deadline in engine-clock ns, 0 for none, in place of a TTL. Any refusal is
   the caller's to report as a divergence. */
ds_result_t ds_engine_cache_seed_replay(struct ds_engine *engine,
                                        const char       *key,
                                        const char       *value_json,
                                        size_t            len,
                                        uint64_t          deadline_ns);

void ds_engine_apply_rt_config(struct ds_engine *engine,
                                uint32_t max_fires_rt,
                                uint32_t max_token_depth,
                                uint32_t n_ttl_schemas,
                                uint32_t max_bind_count,
                                uint32_t max_join_fanout);

/* After this, lookup_or_insert refuses new rows and sets DS_ERR_RT_UNSAFE. */
void ds_engine_series_go_live(struct ds_engine *engine);

/* Writes NULL to *out and returns DS_OK when no live fact carries that id: rete ids
 * are never reused, so a miss means the fact is gone. Whatever must remember a fact
 * across a point where the engine may retract it holds the id, not the pointer. */
ds_result_t ds_engine_fact_by_rete_id(ds_engine_t *engine, uint32_t rete_id,
                                      ds_fact_t **out);

/* The rule currently firing, or NULL outside a fire. Borrowed; engine-lifetime.
 *
 * Not a provenance test: a synchronous call callback asserts on the pump stack,
 * inside a fire. Provenance is ds_fact.rule_emitted. */
const char *ds_engine_current_fire_rule(const ds_engine_t *engine);

/* The firing activation's timetag ([RFCS.11.2]); 0 outside a fire. The
 * recorder's FactPublish carries it ([RFCS.27.1]). */
int64_t ds_engine_current_fire_timetag(const ds_engine_t *engine);

/* ds_engine_get_session_header without its re-entry guard, for the rfcs recorder,
 * which runs as an engine callback. */
void ds_engine_session_header_fill(const ds_engine_t *engine,
                                   ds_session_header_t *out);

/* [IDSP.1.6]: for a function that may stash a pending error and calls back into
   libds. Take once at the top of the protected region and restore at each `return`
   from inside it, which preserves first-error-wins. */
#define DS_TAKE_PRIOR_PENDING(engine, prior_var) \
    ds_engine_take_pending((engine), (prior_var))

#define DS_RESTORE_PRIOR_PENDING(engine, prior) do { \
    if ((prior).status != DS_OK) ds_engine_set_pending((engine), (prior)); \
} while (0)

/* [LGRA.24.3]: in dsc/loader.c. _apply places all the pending items and empties the
   list. Where a cache item would exceed a cap it places nothing, leaves them pending,
   records the refused step and the BoundsError, and returns DS_ERR_CONTRACT_BREACH. */
ds_result_t ds_engine_initial_apply(struct ds_engine *engine,
                                    ds_clock_step_t   step);
void        ds_engine_initial_free(struct ds_engine *engine);
ds_result_t ds_engine_initial_clone(struct ds_engine       *dst,
                                    const struct ds_engine *src);

/* One service-table entry's owned memory. Leaves the entry zeroed. In engine.c. */
void ds_call_service_dispose(struct ds_call_service *s);

#endif /* LIBDS2_INTERNAL_ENGINE_H */

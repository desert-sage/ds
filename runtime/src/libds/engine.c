/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * engine.c — ds_engine_t lifecycle and consumption-loop pump ([IARC.3.2]).
 */
#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


#include "libds.h"
#include "internal/json.h"   /* ds_json_within_limits ([LGRA.5.8.6]) */
#include "ds_alloc.h"
#include "ds_text.h"         /* ds_utf8_well_formed ([LSTR.8.5]) */

#include "engine.h"
#include "telemetry.h"
#include "wm.h"
#include "rete/engine.h"
#include "rete/token.h"     /* current_fire_token's creation_timetag ([RFCS.27.1]) */
#include "rete/wm_rete.h"
extern ds_result_t ds_register_builtins(ds_rete_engine_t *engine);
extern void ds_rete_bump_cycle(ds_rete_engine_t *engine);
extern void ds_engine_wire_rete_adapters(ds_engine_t *engine);
extern void ds_rete_engine_absorb_pending(ds_engine_t *engine);
extern void ds_engine_drop_pending_samples(ds_engine_t *engine);
extern void ds_rete_engine_tick_clock(ds_engine_t *engine);
#include "recorder.h"
#include "rfcs/rfcs.h"        /* DS_FWTH_CAUSE_* */
#include "series/builtin_backends.h"

#define ENGINE_RULE_HOOK_NAME "libds-engine-rules"
#define ENGINE_SILENCER_NAME  "libds-silencer"


/* The rule_meta map: FNV-1a over the name, open-addressing. */

#define RMETA_MAP_MAX_LOAD 70u

static uint32_t rmeta_hash(const char *s)
{
    uint32_t h = 2166136261u;
    for (; *s; s++) { h ^= (uint8_t)*s; h *= 16777619u; }
    return h;
}

/* The new table is built before the old one is freed. */
ds_result_t ds_engine_rule_meta_map_rebuild(ds_engine_t *engine)
{
    size_t n   = engine->n_rule_metas;
    size_t cap = 8;
    while (cap * RMETA_MAP_MAX_LOAD / 100 < n) cap <<= 1;

    struct ds_rmeta_map_entry *map = DS_CALLOC(cap, sizeof(*map));
    if (map == NULL)
        return DS_ERR_R(DS_ERR_OOM, "dsc: the rule-meta index could not be built");

    for (size_t i = 0; i < n; i++) {
        const char *k = engine->rule_metas[i].rule_name;
        uint32_t h = rmeta_hash(k) & (uint32_t)(cap - 1);
        while (map[h].key)
            h = (h + 1) & (uint32_t)(cap - 1);
        map[h].key = k;
        map[h].idx = i;
    }
    DS_FREE(engine->rule_meta_map);
    engine->rule_meta_map     = map;
    engine->rule_meta_map_cap = cap;
    return DS_OK_R;
}

/* No linear fallback ([RDSC.9.8]): an engine holding rule metadata holds its index. */
struct ds_rule_meta *ds_engine_find_rule_meta(ds_engine_t *engine,
                                           const char *rule_name)
{
    if (engine->rule_meta_map == NULL || engine->rule_meta_map_cap == 0)
        return NULL;
    uint32_t cap = (uint32_t)engine->rule_meta_map_cap;
    uint32_t h   = rmeta_hash(rule_name) & (cap - 1);
    for (;;) {
        const struct ds_rmeta_map_entry *e = &engine->rule_meta_map[h];
        if (!e->key) return NULL;
        if (strcmp(e->key, rule_name) == 0)
            return &engine->rule_metas[e->idx];
        h = (h + 1) & (cap - 1);
    }
}


/* [NLFC.1.2], [LSTR.8.5] */
static bool nlfc_1_2_id_well_formed(const char *id)
{
    return id == NULL || ds_utf8_well_formed(id, strlen(id));
}

ds_result_t ds_engine_new(const ds_engine_config_t *config,
                          ds_engine_t             **out)
{
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = NULL;

    if (config != NULL && !nlfc_1_2_id_well_formed(config->run_id))
        return DS_ERR_R(DS_ERR_ENCODING,
                        "ds_engine_new: run_id is not well-formed UTF-8 "
                        "(NLFC.1.2, LSTR.8.5)");
    if (config != NULL && !nlfc_1_2_id_well_formed(config->tier_id))
        return DS_ERR_R(DS_ERR_ENCODING,
                        "ds_engine_new: tier_id is not well-formed UTF-8 "
                        "(NLFC.1.2, LSTR.8.5)");

    ds_engine_t *e = DS_CALLOC(1, sizeof(*e));
    if (e == NULL) {
        return DS_ERR_R(DS_ERR_OOM, "engine allocation failed");
    }

    {
        ds_result_t r = ds_clock_init(&e->clock);
        if (r.status != DS_OK) { DS_FREE(e); return r; }

        r = ds_telemetry_init(&e->telemetry);
        if (r.status != DS_OK) { DS_FREE(e); return r; }

        r = ds_recorder_init(&e->recorder);
        if (r.status != DS_OK) {
            ds_telemetry_destroy(&e->telemetry);
            DS_FREE(e); return r;
        }

        r = ds_schema_registry_init(&e->schemas, e);
        if (r.status != DS_OK) {
            ds_recorder_destroy(&e->recorder);
            ds_telemetry_destroy(&e->telemetry);
            DS_FREE(e); return r;
        }

        r = ds_wm_init(&e->wm, e);
        if (r.status != DS_OK) {
            ds_schema_registry_destroy(&e->schemas);
            ds_recorder_destroy(&e->recorder);
            ds_telemetry_destroy(&e->telemetry);
            DS_FREE(e); return r;
        }

        r = ds_dispatcher_init(&e->dispatcher, e);
        if (r.status != DS_OK) {
            ds_wm_destroy(&e->wm);
            ds_schema_registry_destroy(&e->schemas);
            ds_recorder_destroy(&e->recorder);
            ds_telemetry_destroy(&e->telemetry);
            DS_FREE(e); return r;
        }

        ds_dispatcher_init_dispatch_table(e);
    }

    e->rete_engine = NULL;
    {
        ds_result_t rr = ds_rete_engine_create(&e->rete_engine);
        if (rr.status != DS_OK) {
            /* [IARC.3.2.5]'s order. */
            ds_dispatcher_destroy(&e->dispatcher);
            ds_wm_destroy(&e->wm);
            ds_schema_registry_destroy(&e->schemas);
            ds_recorder_destroy(&e->recorder);
            ds_telemetry_destroy(&e->telemetry);
            DS_FREE(e);
            return rr;
        }
        ds_register_builtins(e->rete_engine);
        ds_engine_wire_rete_adapters(e);
        /* [IRET.1.4]: a wrapper holds a reference on a counted slot value it borrows. */
        e->wm.intern = e->rete_engine->intern;
    }

    e->next_seq = 0;
    /* From 1: 0 means "not set" in a stream field ([RFCS.6.2]). */
    e->next_fact_id = 1;
    e->rule_fire_start_ns = 0;
    e->pending_status = DS_OK;
    e->pending_detail = NULL;

    ds_cache_init(&e->cache);

    ds_series_state_registry_init(&e->series_state);

    /* [NSBK.2.3]: the closed set of backends. */
    ds_engine_series_registry_init(e);
    e->platform_sig_backends   = NULL;
    e->platform_sig_n_backends = 0;
    {
        ds_result_t br = ds_series_register_builtin_backends(e);
        if (br.status != DS_OK) {
            (void)ds_engine_free(e);
            return br;
        }
    }

    if (config != NULL) {
        e->config = *config;
    }
    /* Copied, and the config's fields cleared, so nothing reads the caller's memory
       later. "" is absent ([NLFC.1.2]). */
    e->run_id  = NULL;
    e->tier_id = NULL;
    if (e->config.run_id != NULL && e->config.run_id[0] == '\0')
        e->config.run_id = NULL;
    if (e->config.tier_id != NULL && e->config.tier_id[0] == '\0')
        e->config.tier_id = NULL;
    if (e->config.run_id != NULL) {
        e->run_id = DS_STRDUP(e->config.run_id);
        if (e->run_id == NULL) { ds_engine_free(e); *out = NULL;
            return DS_ERR_R(DS_ERR_OOM, "ds_engine_new: run_id"); }
    }
    if (e->config.tier_id != NULL) {
        e->tier_id = DS_STRDUP(e->config.tier_id);
        if (e->tier_id == NULL) { ds_engine_free(e); *out = NULL;
            return DS_ERR_R(DS_ERR_OOM, "ds_engine_new: tier_id"); }
    }
    e->config.run_id  = NULL;
    e->config.tier_id = NULL;

    *out = e;
    return DS_OK_R;
}

ds_result_t ds_engine_get_run_id(const ds_engine_t *engine, const char **out)
{
    if (engine == NULL || out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_engine_get_run_id: NULL arg");
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    *out = engine->run_id;
    return DS_OK_R;
}

ds_result_t ds_engine_get_tier_id(const ds_engine_t *engine, const char **out)
{
    if (engine == NULL || out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_engine_get_tier_id: NULL arg");
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    *out = engine->tier_id;
    return DS_OK_R;
}

void ds_engine_series_go_live(ds_engine_t *engine)
{
    if (!engine) return;
    ds_series_state_registry_lock(&engine->series_state);
    if (engine->rete_engine && engine->rete_engine->wm_max_facts > 0
            && engine->ttl_sweep_buf == NULL) {
        size_t cap = engine->rete_engine->wm_max_facts;
        engine->ttl_sweep_buf = DS_MALLOC(cap * sizeof(*engine->ttl_sweep_buf));
        if (engine->ttl_sweep_buf) engine->ttl_sweep_cap = cap;
    }
}

void ds_engine_apply_rt_config(ds_engine_t *engine,
                               uint32_t max_fires_rt,
                               uint32_t max_token_depth,
                               uint32_t n_ttl_schemas,
                               uint32_t max_bind_count,
                               uint32_t max_join_fanout)
{
    if (engine == NULL || engine->rete_engine == NULL) return;
    if (max_fires_rt)    engine->rete_engine->max_fires_rt        = max_fires_rt;
    if (max_token_depth) engine->rete_engine->max_token_depth     = max_token_depth;
    if (max_bind_count)  engine->rete_engine->max_bind_count_hint = max_bind_count;
    if (max_join_fanout) engine->rete_engine->max_join_fanout     = max_join_fanout;
    (void)n_ttl_schemas; /* informational; no rete_engine field */
}

void ds_engine_apply_cap_flags(ds_engine_t *engine,
                               bool cap_nological,
                               bool cap_nolinscan,
                               bool cap_dynamic_ttl,
                               bool cap_realtime,
                               bool cap_constspace)
{
    if (engine == NULL || engine->rete_engine == NULL) return;
    engine->rete_engine->cap_nological   = cap_nological;
    engine->rete_engine->cap_nolinscan   = cap_nolinscan;
    engine->rete_engine->cap_dynamic_ttl = cap_dynamic_ttl;
    engine->rete_engine->cap_realtime    = cap_realtime;
    engine->rete_engine->cap_constspace  = cap_constspace;
    /* [RDSC.16.3.7]: ds_engine_set_wm_max sets rt_mode, not this. */
}

void ds_engine_set_pending(ds_engine_t *engine, ds_result_t r)
{
    if (engine == NULL) return;
    if (engine->pending_status == DS_OK && r.status != DS_OK) {
        engine->pending_status = r.status;
        engine->pending_detail = r.detail;
    }
}

void ds_engine_take_pending(ds_engine_t *engine, ds_result_t *out)
{
    if (engine == NULL || out == NULL) return;
    out->status = engine->pending_status;
    out->detail = engine->pending_detail;
    engine->pending_status = DS_OK;
    engine->pending_detail = NULL;
}


ds_result_t ds_engine_free(ds_engine_t *engine)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    /* [RARC.13.16]: from inside its own callback, this frees the stack the callback
       returns into. */
    DS_ENGINE_REFUSE_IF_REENTERED(engine);

    /* [IERR.1.7]: teardown raises nothing, and finishes what it holds. */
    if (engine->rete_engine != NULL)
        ds_rete_intern_begin_teardown(engine->rete_engine->intern);

    /* In reverse of init order. Teardown fires no callback ([NLFC.6.4]). */
    ds_dispatcher_destroy(&engine->dispatcher);
    ds_wm_destroy(&engine->wm);
    ds_schema_registry_destroy(&engine->schemas);
    ds_recorder_destroy(&engine->recorder);
    ds_telemetry_destroy(&engine->telemetry);

    for (size_t i = 0; i < engine->n_rule_metas; i++) {
        struct ds_rule_meta *m = &engine->rule_metas[i];
        DS_FREE(m->rule_name);
        DS_FREE(m->src_file);
        DS_FREE(m->debug_name_template);
    }
    DS_FREE(engine->rule_metas);
    engine->rule_metas     = NULL;
    engine->n_rule_metas   = 0;
    engine->cap_rule_metas = 0;
    DS_FREE(engine->rule_meta_map);
    engine->rule_meta_map     = NULL;
    engine->rule_meta_map_cap = 0;

    DS_FREE(engine->ttl_sweep_buf);
    engine->ttl_sweep_buf = NULL;
    engine->ttl_sweep_cap = 0;
    DS_FREE(engine->act_pending);
    DS_FREE(engine->act_tokens);
    DS_FREE(engine->act_attach);
    engine->act_pending = NULL;  engine->n_act_pending = engine->cap_act_pending = 0;
    engine->act_tokens  = NULL;  engine->n_act_tokens  = engine->cap_act_tokens  = 0;
    engine->act_attach  = NULL;  engine->n_act_attach  = engine->cap_act_attach  = 0;
    DS_FREE(engine->run_id);
    DS_FREE(engine->tier_id);
    engine->run_id  = NULL;
    engine->tier_id = NULL;

    for (size_t i = 0; i < engine->n_ds_sources; i++) {
        DS_FREE(engine->ds_sources[i].file);
        DS_FREE(engine->ds_sources[i].text);
    }
    DS_FREE(engine->ds_sources);
    engine->ds_sources    = NULL;
    engine->n_ds_sources  = 0;
    engine->cap_ds_sources = 0;

    /* Before the series-decl free: the queue borrows its names. */
    ds_engine_drop_pending_samples(engine);

    for (size_t i = 0; i < engine->n_series_decls; i++) {
        DS_FREE(engine->series_decls[i].schema_name);
        DS_FREE(engine->series_decls[i].slot_name);
        DS_FREE(engine->series_decls[i].identity_slot_name);
    }
    DS_FREE(engine->series_decls);
    engine->series_decls     = NULL;
    engine->n_series_decls   = 0;
    engine->cap_series_decls = 0;

    for (size_t i = 0; i < engine->n_call_services; i++)
        ds_call_service_dispose(&engine->call_services[i]);
    DS_FREE(engine->call_services);
    engine->call_services   = NULL;
    engine->n_call_services = 0;

    ds_engine_initial_free(engine);

    /* [ISBK.1.2]: before the registry is disposed, which takes the vtables. */
    for (size_t r = 0; r < engine->series_state.n_rows; r++) {
        ds_series_state_row_t *row = &engine->series_state.rows[r];
        for (size_t s = 0; s < row->n_slots && s < engine->n_backend_slots; s++) {
            if (row->backend_state[s] != NULL
                && engine->backend_slots[s].vtable != NULL
                && engine->backend_slots[s].vtable->instance_free != NULL) {
                engine->backend_slots[s].vtable->instance_free(
                    row->backend_state[s]);
                row->backend_state[s] = NULL;
            }
        }
    }
    ds_series_state_registry_dispose(&engine->series_state);
    ds_cache_free(&engine->cache);
    ds_engine_series_registry_dispose(engine);
    ds_engine_platform_signature_dispose(engine);
    for (size_t i = 0; i < engine->n_line_spans; i++) {
        DS_FREE(engine->line_spans[i].ds_file);
    }
    DS_FREE(engine->line_spans);
    engine->line_spans    = NULL;
    engine->n_line_spans  = 0;
    engine->cap_line_spans = 0;

    if (engine->rete_engine != NULL) {
        ds_rete_engine_destroy(engine->rete_engine);
        engine->rete_engine = NULL;
    }

    DS_FREE(engine);
    return DS_OK_R;
}

/* [NCBK.2.11]. No halt guard: answering after the halt is the point. */
ds_result_t ds_engine_halted(const ds_engine_t *engine, bool *out_halted,
                             ds_engine_fault_t *out_fault)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_REENTERED(engine);
    if (out_halted != NULL) {
        *out_halted = engine->halted;
    }
    if (out_fault != NULL) {
        *out_fault = engine->halted ? engine->halt_fault
                                    : DS_ENGINE_FAULT_UNSPECIFIED;
    }
    return DS_OK_R;
}

/* [NLFC.2.5]: reads the clock's source as ds_engine_clock_now does, so a mock
   clock moved since the last pump counts, and takes no sample. */
ds_result_t ds_engine_next_deadline_ns(ds_engine_t *engine, uint64_t *out_ns,
                                       bool *out_has)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (out_ns == NULL || out_has == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out_ns and out_has must not be null");
    }
    uint64_t now_ns = 0;
    ds_result_t r = ds_clock_source_ns(&engine->clock, &now_ns);
    if (r.status != DS_OK) return r;

    uint64_t best = 0;
    bool     has  = false;
    ds_rete_wm_next_deadline(engine->rete_engine, now_ns, &best, &has);
    ds_cache_next_deadline(&engine->cache, now_ns, &best, &has);
    *out_ns  = best;
    *out_has = has;
    return DS_OK_R;
}


/* -------- Public introspection over DSC-loaded engine state -------- */

#define IARG(p) do { if ((p) == NULL) return DS_ERR_R(DS_ERR_INVAL, "NULL arg"); } while (0)

static void rule_meta_view_fill(const struct ds_rule_meta *m,
                                 ds_rule_meta_view_t *v)
{
    v->rule_name      = m->rule_name;
    v->has_cool       = m->has_cool;
    v->cool_window_ns = m->cool_window_ns;
    v->has_srcr              = m->has_srcr;
    v->src_file              = m->src_file;
    v->src_line              = m->src_line;
    v->src_col               = m->src_col;
    v->has_dnam              = m->has_dnam;
    v->debug_name_template   = m->debug_name_template;
}

ds_result_t ds_engine_rule_meta_count(ds_engine_t *engine, size_t *out)
{
    IARG(engine); IARG(out);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    *out = engine->n_rule_metas;
    return DS_OK_R;
}

ds_result_t ds_engine_rule_meta_at(ds_engine_t *engine, size_t idx,
                                    ds_rule_meta_view_t *out)
{
    IARG(engine); IARG(out);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (idx >= engine->n_rule_metas) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "rule_meta index out of range");
    }
    rule_meta_view_fill(&engine->rule_metas[idx], out);
    return DS_OK_R;
}

ds_result_t ds_engine_rule_meta_find(ds_engine_t *engine, const char *rule_name,
                                      ds_rule_meta_view_t *out, bool *out_found)
{
    IARG(engine); IARG(rule_name); IARG(out); IARG(out_found);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    *out_found = false;
    struct ds_rule_meta *m = ds_engine_find_rule_meta(engine, rule_name);
    if (m) { rule_meta_view_fill(m, out); *out_found = true; }
    return DS_OK_R;
}

void ds_call_service_dispose(struct ds_call_service *s)
{
    if (s == NULL) return;
    DS_FREE(s->name);
    DS_FREE(s->response);
    for (uint32_t k = 0; k < s->n_kwargs; k++) {
        DS_FREE((char *) s->kwargs[k].name);
        DS_FREE((char *) s->kwargs[k].ds_type);
        DS_FREE((char *) s->kwargs[k].default_text);
    }
    DS_FREE(s->kwargs);
    memset(s, 0, sizeof *s);
}

/* [NDBG.2.4]: a view borrows the entry. */
static void service_view_fill(const struct ds_call_service *s,
                              ds_service_view_t *v)
{
    v->name        = s->name;
    v->response    = s->response;
    v->no_response = s->no_response;
    v->kwarg_count = s->n_kwargs;
    v->kwargs      = s->kwargs;
}

ds_result_t ds_engine_service_count(ds_engine_t *engine, size_t *out)
{
    IARG(engine); IARG(out);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    *out = engine->n_call_services;
    return DS_OK_R;
}

ds_result_t ds_engine_service_at(ds_engine_t *engine, size_t idx,
                                  ds_service_view_t *out)
{
    IARG(engine); IARG(out);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (idx >= engine->n_call_services) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "service index out of range");
    }
    service_view_fill(&engine->call_services[idx], out);
    return DS_OK_R;
}

/* Of two ServiceDefs naming one service the later is found, as
   ds_dispatcher_call_typed takes the later's response. */
ds_result_t ds_engine_service_find(ds_engine_t *engine, const char *name,
                                    ds_service_view_t *out, bool *out_found)
{
    IARG(engine); IARG(name); IARG(out); IARG(out_found);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    *out_found = false;
    for (size_t i = engine->n_call_services; i > 0; i--) {
        const struct ds_call_service *s = &engine->call_services[i - 1];
        if (strcmp(s->name, name) == 0) {
            service_view_fill(s, out);
            *out_found = true;
            break;
        }
    }
    return DS_OK_R;
}

ds_result_t ds_engine_ds_source_count(ds_engine_t *engine, size_t *out)
{
    IARG(engine); IARG(out);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    *out = engine->n_ds_sources;
    return DS_OK_R;
}

ds_result_t ds_engine_ds_source_at(ds_engine_t *engine, size_t idx,
                                    ds_ds_source_view_t *out)
{
    IARG(engine); IARG(out);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (idx >= engine->n_ds_sources) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "ds_source index out of range");
    }
    out->module_id = engine->ds_sources[idx].module_id;
    out->file      = engine->ds_sources[idx].file;
    out->text      = engine->ds_sources[idx].text;
    out->text_len  = engine->ds_sources[idx].text_len;
    return DS_OK_R;
}

ds_result_t ds_engine_line_span_count(ds_engine_t *engine, size_t *out)
{
    IARG(engine); IARG(out);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    *out = engine->n_line_spans;
    return DS_OK_R;
}

ds_result_t ds_engine_line_span_at(ds_engine_t *engine, size_t idx,
                                    ds_line_span_view_t *out)
{
    IARG(engine); IARG(out);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (idx >= engine->n_line_spans) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "line_span index out of range");
    }
    out->node_id        = engine->line_spans[idx].node_id;
    out->ds_line        = engine->line_spans[idx].ds_line;
    out->ds_col         = engine->line_spans[idx].ds_col;
    out->ds_file        = engine->line_spans[idx].ds_file;
    out->module_id      = engine->line_spans[idx].module_id;
    return DS_OK_R;
}

ds_result_t ds_engine_line_span_find(ds_engine_t *engine, uint32_t node_id,
                                     ds_line_span_view_t *out)
{
    IARG(engine); IARG(out);
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    for (size_t i = 0; i < engine->n_line_spans; i++) {
        if (engine->line_spans[i].node_id != node_id) {
            continue;
        }
        out->node_id   = engine->line_spans[i].node_id;
        out->ds_line   = engine->line_spans[i].ds_line;
        out->ds_col    = engine->line_spans[i].ds_col;
        out->ds_file   = engine->line_spans[i].ds_file;
        out->module_id = engine->line_spans[i].module_id;
        return DS_OK_R;
    }
    return DS_ERR_R(DS_ERR_NOT_FOUND, "no LineSpan for node_id");
}

const char *ds_engine_current_fire_rule(const ds_engine_t *engine)
{
    if (!engine || !engine->rete_engine)
        return NULL;
    return engine->rete_engine->current_fire_rule;
}

/* See engine.h: the firing activation's timetag, 0 outside a fire. */
int64_t ds_engine_current_fire_timetag(const ds_engine_t *engine)
{
    if (!engine || !engine->rete_engine
            || !engine->rete_engine->current_fire_token)
        return 0;
    return engine->rete_engine->current_fire_token->creation_timetag;
}

ds_result_t ds_engine_fact_by_rete_id(ds_engine_t *engine, uint32_t rete_id,
                                      ds_fact_t **out)
{
    if (!engine || !out)
        return DS_ERR_R(DS_ERR_INVAL, "fact_by_rete_id: NULL");
    *out = NULL;
    if (!engine->rete_engine)
        return DS_OK_R;

    ds_rete_fact_t *live = ds_rete_wm_find_by_id(engine->rete_engine, rete_id);
    if (!live)
        return DS_OK_R;

    return ds_wm_fact_lookup(&engine->wm, live, out);
}

/* ---- TTL sweep via DS WM wrappers (Rete backend) ----------------- */

/* [LDET.5.11]: by deadline, then by working-memory entry, which is the fact id. */
static bool sweep_expired_after(const ds_fact_t *fa, const ds_fact_t *fb)
{
    if (fa->ttl_deadline_ns != fb->ttl_deadline_ns)
        return fa->ttl_deadline_ns > fb->ttl_deadline_ns;
    return fa->fact_id > fb->fact_id;
}

/* In-place heapsort: the pump must not allocate under `realtime` ([LCAP.2.1]), and
   some C libraries' qsort does. */
static void sweep_expired_sift_down(ds_fact_t **a, size_t i, size_t n)
{
    for (;;) {
        size_t big = i, l = 2u * i + 1u, r = 2u * i + 2u;
        if (l < n && sweep_expired_after(a[l], a[big])) big = l;
        if (r < n && sweep_expired_after(a[r], a[big])) big = r;
        if (big == i) return;
        ds_fact_t *t = a[i]; a[i] = a[big]; a[big] = t;
        i = big;
    }
}

static void sweep_expired_sort(ds_fact_t **a, size_t n)
{
    if (n < 2) return;
    for (size_t i = n / 2u; i-- > 0; ) sweep_expired_sift_down(a, i, n);
    for (size_t end = n - 1u; end > 0; end--) {
        ds_fact_t *t = a[0]; a[0] = a[end]; a[end] = t;
        sweep_expired_sift_down(a, 0, end);
    }
}

static void ds_engine_sweep_ttl_via_wrappers(ds_engine_t *engine, uint64_t now_ns)
{
    if (!engine) return;

    /* Collect, then retract: ds_engine_retract reshuffles the wm table. */
    ds_fact_t  *stack_buf[16];
    ds_fact_t **expired = engine->ttl_sweep_buf
                        ? engine->ttl_sweep_buf : stack_buf;
    size_t cap   = engine->ttl_sweep_buf ? engine->ttl_sweep_cap : 16u;
    size_t count = 0;
    bool   heap_fallback = false;

    for (ds_fact_t *f = engine->wm.deadline_head; f != NULL;
         f = f->deadline_next) {
        if (f->ttl_deadline_ns > now_ns) continue;
        if (count == cap) {
            if (engine->ttl_sweep_buf) {
                break;
            }
            size_t nc = cap == 0 ? 8 : cap * 2;
            ds_fact_t **nb = heap_fallback
                           ? DS_REALLOC(expired, nc * sizeof(*nb))
                           : DS_MALLOC(nc * sizeof(*nb));
            if (!nb) {
                /* The original buffer stays valid: retract what was collected. */
                goto retract_collected;
            }
            if (!heap_fallback) {
                memcpy(nb, expired, count * sizeof(*nb));
            }
            expired        = nb;
            cap            = nc;
            heap_fallback  = true;
        }
        expired[count++] = f;
    }
retract_collected:
    /* C99 [6.8.1]: a label precedes a statement, and the next line is a declaration. */
    ;
    /* The retract goes through ds_engine_retract, where an unset cause tells the
       codec the integrator did it. */
    const uint8_t prev_cause = engine->wm.retract_cause;
    engine->wm.retract_cause = DS_FWTH_CAUSE_TTL_EXPIRED;
    sweep_expired_sort(expired, count);
    for (size_t i = 0; i < count; i++) {
        /* [LERR.1.4.7] */
        if (engine->halted) break;
        ds_engine_retract(engine, expired[i]);
    }
    engine->wm.retract_cause = prev_cause;
    if (heap_fallback) DS_FREE(expired);
}

/* [NSTG.2.4.2]. A hook failure is stashed: the entry is already gone
 * ([LSTO.4.7.2]), and the pump surfaces the status at the end of the cycle. */
static void engine_cache_removed_cb(void *ctx, const char *key)
{
    ds_engine_t *engine = (ds_engine_t *) ctx;
    ds_result_t r = ds_dispatcher_notify_cache_removal(engine, key,
                                                       DS_CACHE_REMOVED_TTL);
    if (r.status != DS_OK) ds_engine_set_pending(engine, r);
}

static void ds_engine_sweep_cache_ttl(ds_engine_t *engine, uint64_t now_ns)
{
    if (engine == NULL) return;
    (void) ds_cache_sweep_expired(&engine->cache, now_ns,
                                  engine_cache_removed_cb, engine);
}


/* `has_deadline`: `deadline_ns` is the entry's absolute deadline, 0 for none
   ([RFCS.26.2]); otherwise `ttl_ns` is a TTL. `host`: the key and value are a host's,
   held to [LSTR.8.5]; the artefact's and a recording's are trusted ([RDSC.9.9]). */
static ds_result_t engine_cache_seed_store(ds_engine_t *engine, const char *key,
                                           const ds_json_t *value,
                                           uint64_t ttl_ns, bool has_deadline,
                                           uint64_t deadline_ns, bool host);

static ds_result_t engine_cache_seed_body(ds_engine_t *engine, const char *key,
                                          const ds_json_t *value,
                                          uint64_t ttl_ns)
{
    return engine_cache_seed_store(engine, key, value, ttl_ns, false, 0, false);
}

static ds_result_t engine_cache_seed_store(ds_engine_t *engine, const char *key,
                                           const ds_json_t *value,
                                           uint64_t ttl_ns, bool has_deadline,
                                           uint64_t deadline_ns, bool host)
{
    if (engine == NULL || key == NULL || value == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "cache_seed: null engine/key/value");
    DS_ENGINE_REFUSE_IF_HALTED(engine);

    /* [NLFC.9.1] */
    if (engine->rete_engine != NULL && engine->rete_engine->rt_mode) {
        if (engine->rete_engine->live)
            return DS_ERR_R(DS_ERR_RT_LIVE,
                            "cache_seed: not permitted after go_live");
    } else if (engine->has_pumped) {
        return DS_ERR_R(DS_ERR_STATE,
                        "cache_seed: not permitted after the first pump");
    }

    /* [LGRA.5.8.6] */
    if (!ds_json_within_limits(value, NULL)) {
        return DS_ERR_R(DS_ERR_JSON_LIMIT,
                        "cache_seed: value over a DS_JSON_MAX_* limit");
    }

    /* [LSTR.8.5]: after the limit, as at assert. */
    if (host && (!ds_utf8_well_formed(key, strlen(key))
                 || !ds_json_utf8_well_formed(value))) {
        return DS_ERR_R(DS_ERR_ENCODING,
                        "cache_seed: the key or the value's text is not "
                        "well-formed UTF-8 ([LSTR.8.5])");
    }

    /* The rule cache-write path's serializer: the two store byte-identically
       ([RARC.5.7.10]). */
    char *text = NULL;
    size_t len = 0;
    ds_result_t sr = ds_json_serialize(value, &text, &len);
    if (sr.status != DS_OK) return sr;
    (void) len;

    /* A direct upsert: no dispatcher, event or write-through callback ([IARC.12.1]).
       [NLFC.9.4]: before the first sample a TTL is held as a duration, and
       ds_engine_clock_step's first sample fixes the deadline. */
    ds_result_t r;
    if (has_deadline) {
        r = ds_cache_set_deadline(&engine->cache, key, text, deadline_ns);
    } else if (!engine->clock.sampled) {
        r = ds_cache_set_held(&engine->cache, key, text, ttl_ns);
    } else {
        uint64_t now_ns = 0;
        ds_clock_now_ns(&engine->clock, &now_ns);
        r = ds_cache_set(&engine->cache, key, text, ttl_ns, now_ns);
    }
    ds_free(text);
    return r;
}

/* [NLFC.9.1]: the recorder announces the seeds in the prelude it writes at the
   engine's first stream event, so a seed after that could not be announced. */
static ds_result_t host_cache_seed_body(ds_engine_t *engine, const char *key,
                                        const ds_json_t *value,
                                        uint64_t ttl_ns, bool has_deadline,
                                        uint64_t deadline_ns)
{
    if (engine == NULL || key == NULL || value == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "cache_seed: null engine/key/value");
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (engine->next_seq > 0)
        return DS_ERR_R(DS_ERR_STATE,
                        "cache_seed: not permitted after the engine's first "
                        "stream event (NLFC.9.1)");
    /* [NLFC.9.5]: after the window, before the value is judged. */
    if (ttl_ns > (uint64_t) INT64_MAX)
        return DS_ERR_R(DS_ERR_TIME_RANGE,
                        "cache_seed: ttl_ns is longer than the Time range "
                        "(NLFC.9.5)");
    return engine_cache_seed_store(engine, key, value, ttl_ns, has_deadline,
                                   deadline_ns, !has_deadline);
}

/* Judges `sample_ns`, the reading the step will hold, never a second read of the
   source, which a live clock would have moved. */
ds_result_t ds_engine_nlfc_9_5_first_sample_in_range(ds_engine_t *engine,
                                                     uint64_t     sample_ns)
{
    if (engine->clock.sampled)
        return DS_OK_R;
    uint64_t ttl = ds_cache_held_ttl_max(&engine->cache);
    if (ttl == 0)
        return DS_OK_R;
    if (!ds_cache_ttl_in_range(sample_ns, ttl))
        return DS_ERR_R(DS_ERR_TIME_RANGE,
                        "step: a seeded entry's deadline would be outside the "
                        "Time range at the first sample (NLFC.9.5)");
    return DS_OK_R;
}

ds_result_t ds_engine_cache_seed(ds_engine_t *engine, const char *key,
                                 const ds_json_t *value, uint64_t ttl_ns)
{
    ds_api_enter(engine);
    return ds_api_leave(engine,
                        host_cache_seed_body(engine, key, value, ttl_ns,
                                             false, 0));
}

/* [RFCS.26.2]: as a host seed, with the deadline the recorded cache held. */
ds_result_t ds_engine_cache_seed_replay(ds_engine_t *engine, const char *key,
                                        const char *value_json, size_t len,
                                        uint64_t deadline_ns)
{
    if (engine == NULL || key == NULL || value_json == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "cache_seed_replay: null argument");
    ds_json_t *tree = NULL;
    /* A recording is trusted ([RDSC.9.9]), so no [LSTR.8.5] check. */
    ds_result_t r = ds_json_parse_limited(value_json, len, &tree, NULL, true);
    if (r.status != DS_OK)
        return r;
    ds_api_enter(engine);
    r = ds_api_leave(engine, host_cache_seed_body(engine, key, tree, 0, true,
                                                  deadline_ns));
    (void) ds_json_free(tree);
    return r;
}

ds_result_t ds_engine_cache_seed_initial(ds_engine_t *engine, const char *key,
                                         const ds_json_t *value,
                                         uint64_t ttl_ns)
{
    ds_api_enter(engine);
    return ds_api_leave(engine,
                        engine_cache_seed_body(engine, key, value, ttl_ns));
}

/* [RMET.4] */
static void ds_engine_emit_intern_si3(ds_engine_t *engine)
{
    if (engine == NULL || engine->rete_engine == NULL) return;
    size_t ic = 0, ib = 0;
    ds_rete_intern_mem(engine->rete_engine->intern, &ic, &ib, NULL);
    ds_metric_t m_entries = {
        .name = "ds.intern.entries", .kind = DS_METRIC_GAUGE,
        .value = (double)ic, .labels = NULL, .n_labels = 0,
    };
    ds_metric_t m_bytes = {
        .name = "ds.intern.bytes", .kind = DS_METRIC_GAUGE,
        .value = (double)ib, .labels = NULL, .n_labels = 0,
    };
    ds_metric_t m_pinned = {
        .name = "ds.intern.pinned_entries", .kind = DS_METRIC_GAUGE,
        .value = (double)ds_rete_intern_pinned_count(engine->rete_engine->intern),
        .labels = NULL, .n_labels = 0,
    };
    ds_metric_t m_arena = {
        .name = "ds.intern.arena_high_water_bytes", .kind = DS_METRIC_GAUGE,
        .value = (double)engine->rete_engine->comp_arena.high_water,
        .labels = NULL, .n_labels = 0,
    };
    (void) ds_telemetry_emit_metric(engine, &m_entries);
    (void) ds_telemetry_emit_metric(engine, &m_bytes);
    (void) ds_telemetry_emit_metric(engine, &m_pinned);
    (void) ds_telemetry_emit_metric(engine, &m_arena);
}

/* [NLFC.2.2]: runs the agenda to exhaustion. */
static ds_result_t engine_pump_body(ds_engine_t *engine)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);

    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }

    /* [LTIM.2.8.4]: one sample per step, which every clock read in this pump returns.
       Only the host's own call samples (api_depth 1). */
    if (engine->api_depth == 1) {
        /* [LGRA.24.3]: a pending `initial` block over a cache cap refuses this step,
           and the pump fires no rule. has_pumped stays false. */
        ds_result_t sr = ds_engine_clock_step(engine, DS_CLOCK_STEP_PUMP);
        if (sr.status != DS_OK) return sr;
        /* [RFCS.22]: after the sample's TICK and before anything the pump records:
           a replayer pumps on meeting it. */
        sr = ds_recorder_emit_pump(engine);
        if (sr.status != DS_OK) return sr;
    }

    /* The pinned-set freeze, with the strings the first pump interns pinned lazily
       pinned ahead of it. After it a new pinned insert violates an engine invariant. */
    if (!engine->has_pumped && engine->rete_engine != NULL) {
        const char *pin = NULL;
        (void) ds_rete_intern_cstr(engine->rete_engine->intern, "", &pin);
        (void) ds_rete_intern_cstr(engine->rete_engine->intern,
                                   DS_RETE_CLOCK_TICK_NAME, &pin);
        ds_rete_intern_freeze(engine->rete_engine->intern);
    }
    engine->has_pumped = true;

    {
        ds_result_t stale_pending;
        ds_engine_take_pending(engine, &stale_pending);
        (void)stale_pending;

        uint64_t now_ns = 0;
        ds_result_t cr = ds_clock_now_ns(&engine->clock, &now_ns);
        if (cr.status != DS_OK) return cr;
        /* Wrapper-tracked facts, then the rule-emitted facts that have no wrapper. */
        ds_engine_sweep_ttl_via_wrappers(engine, now_ns);
        ds_rete_wm_tick_ttl(engine->rete_engine, (int64_t)now_ns, NULL);
        /* [LERR.1.4.7] */
        if (engine->halted) {
            ds_result_t halted_pend;
            ds_engine_take_pending(engine, &halted_pend);
            return halted_pend;
        }
        /* [NSTG.2.4.2]: after both fact sweeps, at the same now_ns. The order is
           observable through the callbacks. */
        ds_engine_sweep_cache_ttl(engine, now_ns);
        ds_rete_bump_cycle(engine->rete_engine);
        /* Re-activates any after-clause follow-up rule, to re-check its fire_guard. */
        ds_rete_engine_tick_clock(engine);
        if (!engine->halted) ds_engine_emit_intern_si3(engine);
        uint32_t max_f = engine->rete_engine->rt_mode
                         ? engine->rete_engine->max_fires_rt : 0u;
        ds_result_t rr = ds_rete_run(engine->rete_engine, max_f, NULL);
        /* [LERR.1.4.7]: a halted pump does no post-run work. */
        if (engine->halted) {
            ds_result_t halted_pend;
            ds_engine_take_pending(engine, &halted_pend);
            if (rr.status != DS_OK) return rr;
            return halted_pend;
        }
        /* [LSER.8.6]: fire, then sample. */
        ds_rete_engine_absorb_pending(engine);
        /* [LSER.9.3]: after absorb, so a sample taken this pump is not swept. */
        {
            uint64_t evict_now_ns = 0;
            if (ds_clock_now_ns(&engine->clock, &evict_now_ns).status == DS_OK)
                ds_series_state_evict_stale(engine, evict_now_ns);
        }
        /* The run's error wins over one stashed during it. Drained on both paths. */
        ds_result_t pend;
        ds_engine_take_pending(engine, &pend);
        if (rr.status != DS_OK) return rr;
        return pend;
    }
}

ds_result_t ds_engine_pump(ds_engine_t *engine)
{
    ds_api_enter(engine);
    return ds_api_leave(engine, engine_pump_body(engine));
}

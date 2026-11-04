/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * engine_clone.c — ds_engine_clone ([NLFC.8], [IARC.11]): a deep copy of the mutable
 * state, with an old fact to new fact remap and its own intern table, over a fresh
 * shell from ds_engine_new. Counters continue from the source ([IARC.11.2]). A clone
 * starts with no callbacks ([NLFC.8.3]).
 */

#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"
#include "cache.h"
#include "engine.h"
#include "recorder.h"
#include "schema.h"
#include "series/registry.h"
#include "series/state.h"
#include "rete/clone.h"
#include "rete/engine.h"
#include "rete/fact.h"

/* [NLFC.8.2] */
static ds_result_t clone_preflight(const ds_engine_t *src,
                                   ds_engine_t *const *out_dst)
{
    if (src == NULL || out_dst == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_engine_clone: NULL src or out_dst");

    const ds_rete_engine_t *re = src->rete_engine;

    if (re != NULL && (re->rt_mode || re->pools_ready))
        return DS_ERR_R(DS_ERR_RT_UNSAFE,
            "ds_engine_clone: source is in real-time mode; clone is a non-RT "
            "primitive (allocates a second engine's state)");

    /* Not `pending_status`: a value left there between pumps says nothing about
       being inside one. */
    if ((re != NULL && re->current_fire_token != NULL)
        || src->rule_fire_start_ns != 0
        || src->recorder.defer_depth != 0)
        return DS_ERR_R(DS_ERR_STATE,
            "ds_engine_clone: engine is mid-pump / mid-callback; clone only "
            "between pumps");

    return DS_OK_R;
}

/* NULL-safe; sets *oom on allocation failure. */
static char *sdup(const char *s, bool *oom)
{
    if (s == NULL) return NULL;
    char *d = DS_STRDUP(s);
    if (d == NULL) *oom = true;
    return d;
}

static ds_result_t clone_rule_metas(const ds_engine_t *src, ds_engine_t *dst)
{
    if (src->n_rule_metas == 0) return DS_OK_R;
    size_t cap = src->cap_rule_metas ? src->cap_rule_metas : src->n_rule_metas;
    dst->rule_metas = DS_CALLOC(cap, sizeof(*dst->rule_metas));
    if (!dst->rule_metas) return DS_ERR_R(DS_ERR_OOM, "clone: rule_metas");
    dst->n_rule_metas   = src->n_rule_metas;
    dst->cap_rule_metas = cap;

    bool oom = false;
    for (size_t i = 0; i < src->n_rule_metas; i++) {
        dst->rule_metas[i] = src->rule_metas[i];
        dst->rule_metas[i].rule_name           = sdup(src->rule_metas[i].rule_name, &oom);
        dst->rule_metas[i].src_file            = sdup(src->rule_metas[i].src_file, &oom);
        dst->rule_metas[i].debug_name_template = sdup(src->rule_metas[i].debug_name_template, &oom);
    }
    if (oom) return DS_ERR_R(DS_ERR_OOM, "clone: rule_meta strings");
    return ds_engine_rule_meta_map_rebuild(dst);
}

/* A pair whose fact the clone does not hold was dead in the source too. The
   per-firing pending and token lists are empty between firings, when a clone is
   taken. */
static ds_result_t clone_act_attach(ds_rete_clone_ctx_t *cx,
                                    const ds_engine_t *src, ds_engine_t *dst)
{
    if (src->n_act_attach == 0) return DS_OK_R;
    dst->act_attach = DS_CALLOC(src->n_act_attach, sizeof(*dst->act_attach));
    if (!dst->act_attach) return DS_ERR_R(DS_ERR_OOM, "clone: act_attach");
    dst->cap_act_attach = src->n_act_attach;
    dst->n_act_attach   = 0;
    for (size_t i = 0; i < src->n_act_attach; i++) {
        const ds_rete_fact_t *t = ds_rete_clone_fact_lookup(cx, src->act_attach[i].token_id);
        const ds_rete_fact_t *f = ds_rete_clone_fact_lookup(cx, src->act_attach[i].fact_id);
        if (t == NULL || f == NULL) continue;
        dst->act_attach[dst->n_act_attach].token_id = t->id;
        dst->act_attach[dst->n_act_attach].fact_id  = f->id;
        dst->n_act_attach++;
    }
    return DS_OK_R;
}

static ds_result_t clone_misc_arrays(const ds_engine_t *src, ds_engine_t *dst)
{
    bool oom = false;

    if (src->n_ds_sources > 0) {
        dst->ds_sources = DS_CALLOC(src->n_ds_sources, sizeof(*dst->ds_sources));
        if (!dst->ds_sources) return DS_ERR_R(DS_ERR_OOM, "clone: ds_sources");
        dst->n_ds_sources = dst->cap_ds_sources = src->n_ds_sources;
        for (size_t i = 0; i < src->n_ds_sources; i++) {
            dst->ds_sources[i]      = src->ds_sources[i];
            dst->ds_sources[i].file = sdup(src->ds_sources[i].file, &oom);
            dst->ds_sources[i].text = NULL;
            if (src->ds_sources[i].text && src->ds_sources[i].text_len > 0) {
                size_t tl = src->ds_sources[i].text_len;
                dst->ds_sources[i].text = DS_MALLOC(tl + 1);
                if (!dst->ds_sources[i].text) return DS_ERR_R(DS_ERR_OOM, "clone: ds_source text");
                memcpy(dst->ds_sources[i].text, src->ds_sources[i].text, tl);
                dst->ds_sources[i].text[tl] = '\0';
            }
        }
    }

    if (src->n_line_spans > 0) {
        dst->line_spans = DS_CALLOC(src->n_line_spans, sizeof(*dst->line_spans));
        if (!dst->line_spans) return DS_ERR_R(DS_ERR_OOM, "clone: line_spans");
        dst->n_line_spans = dst->cap_line_spans = src->n_line_spans;
        for (size_t i = 0; i < src->n_line_spans; i++) {
            dst->line_spans[i]         = src->line_spans[i];
            dst->line_spans[i].ds_file = sdup(src->line_spans[i].ds_file, &oom);
        }
    }

    if (src->n_series_decls > 0) {
        dst->series_decls = DS_CALLOC(src->n_series_decls, sizeof(*dst->series_decls));
        if (!dst->series_decls) return DS_ERR_R(DS_ERR_OOM, "clone: series_decls");
        dst->n_series_decls = dst->cap_series_decls = src->n_series_decls;
        for (size_t i = 0; i < src->n_series_decls; i++) {
            dst->series_decls[i] = src->series_decls[i];
            dst->series_decls[i].schema_name        = sdup(src->series_decls[i].schema_name, &oom);
            dst->series_decls[i].slot_name          = sdup(src->series_decls[i].slot_name, &oom);
            dst->series_decls[i].identity_slot_name = sdup(src->series_decls[i].identity_slot_name, &oom);
        }
    }

    /* Zeroed by the CALLOC, so teardown releases an entry an OOM cut short. */
    if (src->n_call_services > 0) {
        dst->call_services = DS_CALLOC(src->n_call_services, sizeof(*dst->call_services));
        if (!dst->call_services) return DS_ERR_R(DS_ERR_OOM, "clone: call_services");
        dst->n_call_services = src->n_call_services;
        for (size_t i = 0; i < src->n_call_services; i++) {
            const struct ds_call_service *s = &src->call_services[i];
            struct ds_call_service       *d = &dst->call_services[i];
            d->name        = sdup(s->name, &oom);
            d->response    = sdup(s->response, &oom);
            d->no_response = s->no_response;
            if (s->n_kwargs > 0) {
                d->kwargs = DS_CALLOC(s->n_kwargs, sizeof(*d->kwargs));
                if (!d->kwargs) return DS_ERR_R(DS_ERR_OOM, "clone: service kwargs");
                d->n_kwargs = s->n_kwargs;
                for (uint32_t k = 0; k < s->n_kwargs; k++) {
                    d->kwargs[k] = s->kwargs[k];
                    d->kwargs[k].name         = sdup(s->kwargs[k].name, &oom);
                    d->kwargs[k].ds_type      = sdup(s->kwargs[k].ds_type, &oom);
                    d->kwargs[k].default_text = sdup(s->kwargs[k].default_text, &oom);
                }
            }
        }
    }

    /* [LGRA.24.3]: a clone made before the first step applies the block at its own. */
    ds_result_t ir = ds_engine_initial_clone(dst, src);
    if (ir.status != DS_OK) return ir;

    return oom ? DS_ERR_R(DS_ERR_OOM, "clone: misc-array strings") : DS_OK_R;
}

/* [IARC.11.2]: each row verbatim, each backend instance by instance_clone. */
static ds_result_t clone_series(const ds_engine_t *src, ds_engine_t *dst)
{
    /* The source's slot order, which the rows below are indexed by. */
    DS_FREE(dst->backend_slots);
    dst->backend_slots     = NULL;
    dst->n_backend_slots   = 0;
    dst->cap_backend_slots = 0;
    if (src->n_backend_slots > 0) {
        dst->backend_slots = DS_CALLOC(src->n_backend_slots, sizeof(*dst->backend_slots));
        if (!dst->backend_slots) return DS_ERR_R(DS_ERR_OOM, "clone: backend_slots");
        for (size_t i = 0; i < src->n_backend_slots; i++) {
            dst->backend_slots[i].vtable             = src->backend_slots[i].vtable;
            dst->backend_slots[i].opaque_handle      = src->backend_slots[i].opaque_handle;
        }
        dst->n_backend_slots   = src->n_backend_slots;
        dst->cap_backend_slots = src->n_backend_slots;
    }

    for (size_t r = 0; r < src->series_state.n_rows; r++) {
        const ds_series_state_row_t *sr = &src->series_state.rows[r];
        ds_series_state_row_t *dr = ds_series_state_lookup_or_insert(
            dst, &dst->series_state, dst->n_backend_slots,
            sr->schema_name, sr->slot_name, sr->identity_slot_name,
            sr->identity_value, sr->window_ns);
        if (!dr) return DS_ERR_R(DS_ERR_OOM, "clone: series row");
        dr->last_absorbed_ts_ns = sr->last_absorbed_ts_ns;
        dr->absorb_count        = sr->absorb_count;
        dr->has_absorbed        = sr->has_absorbed;
        /* [LSER.13.14] */
        if (!ds_series_state_copy_capacity(dr, sr))
            return DS_ERR_R(DS_ERR_OOM, "clone: series capacity instants");
        /* [LNUL.8.6]: a held String is row-owned. */
        dr->has_last_value      = sr->has_last_value;
        dr->last_value          = sr->last_value;
        if (sr->has_last_value && sr->last_value.kind == DS_SLOT_STRING) {
            bool held_oom = false;
            dr->held_str = sdup(sr->held_str ? sr->held_str : "", &held_oom);
            if (held_oom) {
                return DS_ERR_R(DS_ERR_OOM, "clone: series held value");
            }
            dr->last_value.v.s = dr->held_str;
        }

        for (size_t s = 0; s < sr->n_slots && s < dst->n_backend_slots; s++) {
            if (sr->backend_state[s] == NULL) continue;
            const ds_series_backend_vtable_t *vt = dst->backend_slots[s].vtable;
            if (vt == NULL || vt->instance_clone == NULL)
                return DS_ERR_R(DS_ERR_STATE,
                    "ds_engine_clone: a live series backend has no instance_clone hook");
            ds_result_t cr = vt->instance_clone(sr->backend_state[s], &dr->backend_state[s]);
            if (cr.status != DS_OK) return cr;
        }
    }

    return DS_OK_R;
}

/* After clone_misc_arrays: the borrowed names are re-based onto dst's series_decls. */
static ds_result_t clone_pending_samples(const ds_engine_t *src,
                                         ds_engine_t       *dst)
{
    for (size_t i = 0; i < src->n_pending_samples; i++) {
        const struct ds_series_pending_sample *sp = &src->pending_samples[i];
        if (dst->n_pending_samples == dst->cap_pending_samples) {
            size_t new_cap = dst->cap_pending_samples
                             ? dst->cap_pending_samples * 2 : 8;
            struct ds_series_pending_sample *nv = DS_REALLOC(
                dst->pending_samples, new_cap * sizeof(*nv));
            if (!nv) return DS_ERR_R(DS_ERR_OOM, "clone: pending samples");
            dst->pending_samples     = nv;
            dst->cap_pending_samples = new_cap;
        }
        struct ds_series_pending_sample *dp =
            &dst->pending_samples[dst->n_pending_samples];
        memset(dp, 0, sizeof(*dp));

        /* dst has its own intern table, so the content is re-interned against it. */
        ds_rete_intern_t *di = dst->rete_engine ? dst->rete_engine->intern
                                                : NULL;
        if (sp->identity_interned != NULL && di != NULL) {
            const char *iv = NULL;
            if (ds_rete_intern_value(di, sp->identity_interned,
                                     sp->identity_len, &iv).status != DS_OK)
                return DS_ERR_R(DS_ERR_OOM, "clone: pending identity");
            ds_rete_intern_acquire_ptr(di, iv, sp->identity_len);
            dp->identity_interned = iv;
            dp->identity_len      = sp->identity_len;
        } else {
            memcpy(dp->identity_buf, sp->identity_buf,
                   sizeof(dp->identity_buf));
        }
        if (sp->value_interned != NULL && di != NULL) {
            const char *vv = NULL;
            if (ds_rete_intern_value(di, sp->value_interned,
                                     sp->value_len, &vv).status != DS_OK) {
                if (dp->identity_interned != NULL)
                    ds_rete_intern_release(di, dp->identity_interned,
                                           dp->identity_len);
                return DS_ERR_R(DS_ERR_OOM, "clone: pending sample value");
            }
            ds_rete_intern_acquire_ptr(di, vv, sp->value_len);
            dp->value_interned = vv;
            dp->value_len      = sp->value_len;
        }
        dp->value = sp->value;
        dp->ts_ns = sp->ts_ns;
        bool rebased = false;
        for (size_t k = 0; k < dst->n_series_decls; k++) {
            const struct ds_series_decl_record *d = &dst->series_decls[k];
            if (strcmp(d->schema_name, sp->schema_name) != 0) continue;
            if (strcmp(d->slot_name, sp->slot_name) != 0) continue;
            dp->schema_name        = d->schema_name;
            dp->slot_name          = d->slot_name;
            dp->identity_slot_name = d->identity_slot_name
                                     ? d->identity_slot_name : "";
            rebased = true;
            break;
        }
        if (!rebased) {
            if (di != NULL && dp->identity_interned != NULL)
                ds_rete_intern_release(di, dp->identity_interned,
                                       dp->identity_len);
            if (di != NULL && dp->value_interned != NULL)
                ds_rete_intern_release(di, dp->value_interned,
                                       dp->value_len);
            continue;
        }
        dst->n_pending_samples++;
    }
    return DS_OK_R;
}

/* The integrator's callbacks are not copied ([NLFC.8.3]). */
static void clone_ds_config(const ds_engine_t *src, ds_engine_t *dst)
{
    dst->clock     = src->clock;

    dst->next_seq     = src->next_seq;
    dst->next_fact_id = src->next_fact_id;
    dst->series_absorb_mark = src->series_absorb_mark;
    memcpy(dst->dsc_hash,   src->dsc_hash,   sizeof(dst->dsc_hash));
    dst->dsc_hash_valid = src->dsc_hash_valid;
    memcpy(dst->dsc_def_sha256, src->dsc_def_sha256, sizeof(dst->dsc_def_sha256));
    memcpy(dst->dsc_capabilities, src->dsc_capabilities,
           sizeof(dst->dsc_capabilities));
    dst->n_dsc_capabilities = src->n_dsc_capabilities;
    /* The same identity: a clone derives the same event_id for the same fact. */
    DS_FREE(dst->run_id);
    DS_FREE(dst->tier_id);
    dst->run_id  = src->run_id  ? DS_STRDUP(src->run_id)  : NULL;
    dst->tier_id = src->tier_id ? DS_STRDUP(src->tier_id) : NULL;
}

ds_result_t ds_engine_clone(const ds_engine_t *src, ds_engine_t **out_dst)
{
    DS_ENGINE_REFUSE_IF_HALTED(src);
    ds_result_t r = clone_preflight(src, out_dst);
    if (r.status != DS_OK) {
        if (out_dst != NULL) *out_dst = NULL;
        return r;
    }
    *out_dst = NULL;

    ds_engine_t *dst = NULL;
    r = ds_engine_new(&src->config, &dst);
    if (r.status != DS_OK) return r;

    ds_rete_clone_ctx_t cx;
    ds_rete_clone_ctx_init(&cx, dst->rete_engine->intern);

    /* The rete graph first: it fills cx's id2fact for every later remap. */
    if ((r = ds_rete_engine_clone(&cx, src->rete_engine, dst->rete_engine)).status != DS_OK) goto fail;
    if ((r = ds_rete_rate_table_clone(&cx, src->rete_engine, dst->rete_engine)).status != DS_OK) goto fail;
    /* Before the wrappers, which look schemas up by name. */
    if ((r = ds_schema_registry_clone(&src->schemas, &dst->schemas)).status != DS_OK) goto fail;
    if ((r = ds_wm_bridge_clone(&cx, (ds_engine_t *) src, dst)).status != DS_OK) goto fail;
    if ((r = ds_cache_clone(&dst->cache, &src->cache)).status != DS_OK) goto fail;
    if ((r = clone_series(src, dst)).status != DS_OK) goto fail;
    if ((r = clone_rule_metas(src, dst)).status != DS_OK) goto fail;
    if ((r = clone_act_attach(&cx, src, dst)).status != DS_OK) goto fail;
    if ((r = clone_misc_arrays(src, dst)).status != DS_OK) goto fail;
    if ((r = clone_pending_samples(src, dst)).status != DS_OK) goto fail;
    clone_ds_config(src, dst);

    if (cx.oom) { r = DS_ERR_R(DS_ERR_OOM, "ds_engine_clone: sticky OOM"); goto fail; }

    ds_rete_clone_ctx_dispose(&cx);
    *out_dst = dst;
    return DS_OK_R;

fail:
    ds_rete_clone_ctx_dispose(&cx);
    ds_engine_free(dst);
    *out_dst = NULL;
    return r;
}

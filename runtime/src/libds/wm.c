/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * wm.c — the working-memory bridge: the ds_fact_t wrappers around Rete facts.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>


#include "libds.h"
#include "internal/json.h"
#include "ds_alloc.h"

#include "clock.h"
#include "date_range.h"
#include "ds_text.h"
#include "engine.h"
#include "recorder.h"
#include "rfcs/rfcs.h"
#include "schema.h"
#include "telemetry.h"
#include "wm.h"

#include "rete/intern.h"

#define WM_INITIAL_CAP 16

static uint64_t wm_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    return (uint64_t)(uintptr_t)*(void *const *)key;
}

static bool wm_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return *(void *const *)a == *(void *const *)b;
}

/* [NFCT.6.4]: the id index, keyed by the 64-bit fact_id itself. */
static uint64_t wm_id_hash(const void *key, void *ctx)
{
    (void)ctx;
    uint64_t k;
    memcpy(&k, key, sizeof k);
    return k;
}

static bool wm_id_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return memcmp(a, b, sizeof(uint64_t)) == 0;
}

static void schema_list_insert(ds_fact_t *fact)
{
    struct ds_schema *s = (struct ds_schema *)(uintptr_t)fact->schema;
    if (!s) return;
    fact->schema_prev = NULL;
    fact->schema_next = s->fact_list_head;
    if (s->fact_list_head) s->fact_list_head->schema_prev = fact;
    s->fact_list_head = fact;
}

static void schema_list_remove(ds_fact_t *fact)
{
    struct ds_schema *s = (struct ds_schema *)(uintptr_t)fact->schema;
    if (!s) return;
    if (fact->schema_prev) fact->schema_prev->schema_next = fact->schema_next;
    else                   s->fact_list_head = fact->schema_next;
    if (fact->schema_next) fact->schema_next->schema_prev = fact->schema_prev;
    fact->schema_prev = fact->schema_next = NULL;
}

void ds_wm_deadline_track(ds_wm_state_t *wm, ds_fact_t *fact)
{
    if (!wm || !fact || fact->in_deadline_list) return;
    if (fact->ttl_deadline_ns == 0) return;
    fact->deadline_prev = NULL;
    fact->deadline_next = wm->deadline_head;
    if (wm->deadline_head) wm->deadline_head->deadline_prev = fact;
    wm->deadline_head = fact;
    fact->in_deadline_list = true;
}

static void wm_deadline_untrack(ds_wm_state_t *wm, ds_fact_t *fact)
{
    if (!wm || !fact || !fact->in_deadline_list) return;
    if (fact->deadline_prev) fact->deadline_prev->deadline_next = fact->deadline_next;
    else                     wm->deadline_head = fact->deadline_next;
    if (fact->deadline_next) fact->deadline_next->deadline_prev = fact->deadline_prev;
    fact->deadline_prev = fact->deadline_next = NULL;
    fact->in_deadline_list = false;
}

static ds_result_t wm_table_insert(ds_wm_state_t *wm, ds_fact_t *fact)
{
    void *vp;
    bool  is_new;
    ds_result_t r = ds_oa_put(&wm->table, &fact->rete_fact, &vp, &is_new);
    if (r.status != DS_OK) {
        return r;
    }
    *(ds_fact_t **)vp = fact;
    /* [NFCT.6.4]: both maps, or neither. */
    r = ds_wm_index_id(wm, fact);
    if (r.status != DS_OK) {
        if (is_new) ds_oa_del(&wm->table, &fact->rete_fact);
        return r;
    }
    schema_list_insert(fact);
    ds_wm_deadline_track(wm, fact);
    return DS_OK_R;
}

ds_result_t ds_wm_index_id(ds_wm_state_t *wm, ds_fact_t *fact)
{
    void *vp;
    ds_result_t r = ds_oa_put(&wm->by_id, &fact->fact_id, &vp, NULL);
    if (r.status != DS_OK) return r;
    *(ds_fact_t **)vp = fact;
    return DS_OK_R;
}

ds_fact_t *ds_wm_fact_by_id(const ds_wm_state_t *wm, uint64_t fact_id)
{
    ds_fact_t **vp = (ds_fact_t **)ds_oa_get(&wm->by_id, &fact_id);
    return vp ? *vp : NULL;
}

/* The caller frees the wrapper it returns. */
static ds_fact_t *wm_table_remove(ds_wm_state_t *wm, void *rete_fact)
{
    ds_fact_t **vp = (ds_fact_t **)ds_oa_get(&wm->table, &rete_fact);
    if (vp == NULL) return NULL;
    ds_fact_t *e = *vp;
    schema_list_remove(e);
    wm_deadline_untrack(wm, e);
    ds_oa_del(&wm->table, &rete_fact);
    ds_oa_del(&wm->by_id, &e->fact_id);
    return e;
}

static void wm_fact_release(ds_wm_state_t *wm, ds_fact_t *f)
{
    if (f == NULL) return;
    for (uint32_t i = 0; i < f->n_slots; i++) {
        if (f->slots[i].kind == DS_SLOT_JSON && f->slots[i].v.json != NULL) {
            ds_json_free(f->slots[i].v.json);
            f->slots[i].v.json = NULL;
        }
        /* [IRET.1.4]: the one intern reference a wrapper holds on a value it borrowed
           from a rete fact. Release matches on pointer identity, so it is a no-op for
           a host-borrowed pointer. */
        else if (wm != NULL && wm->intern != NULL) {
            if (f->slots[i].kind == DS_SLOT_STRING && f->slots[i].v.s != NULL)
                ds_rete_intern_release(wm->intern, f->slots[i].v.s,
                                       strlen(f->slots[i].v.s));
            else if (f->slots[i].kind == DS_SLOT_BYTES
                     && f->slots[i].v.bytes.data != NULL)
                ds_rete_intern_release(wm->intern,
                                       (const char *)f->slots[i].v.bytes.data,
                                       f->slots[i].v.bytes.len);
        }
    }
    if (wm && wm->fact_slab) {
        uint8_t *p = (uint8_t *)f;
        if (p >= wm->fact_slab &&
            p <  wm->fact_slab + (size_t)wm->fact_pool_cap * wm->fact_stride) {
            memset(f, 0, wm->fact_stride);
            wm->fact_free_stack[wm->fact_free_n++] = f;
            return;
        }
    }
    DS_FREE(f);
}

ds_result_t ds_wm_init(ds_wm_state_t *wm, struct ds_engine *engine)
{
    if (wm == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "wm must not be null");
    }
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }

    wm->engine = engine;
    ds_oa_init(&wm->table, sizeof(void *), sizeof(ds_fact_t *), 0,
            wm_oa_hash, wm_oa_eq, NULL, NULL);
    ds_result_t rr = ds_oa_reserve(&wm->table, WM_INITIAL_CAP);
    if (rr.status != DS_OK) {
        return DS_ERR_R(DS_ERR_OOM, "wm table allocation failed");
    }
    ds_oa_init(&wm->by_id, sizeof(uint64_t), sizeof(ds_fact_t *), 0,
            wm_id_hash, wm_id_eq, NULL, NULL);
    rr = ds_oa_reserve(&wm->by_id, WM_INITIAL_CAP);
    if (rr.status != DS_OK) {
        ds_oa_free(&wm->table);
        return DS_ERR_R(DS_ERR_OOM, "wm id index allocation failed");
    }
    wm->ttl_override_ns  = 0;
    wm->retract_reason   = NULL;
    wm->assert_from_host = false;


    return DS_OK_R;
}

ds_result_t ds_wm_init_rt_pool(ds_wm_state_t *wm, uint32_t n, size_t stride)
{
    if (!wm || n == 0 || stride == 0)
        return DS_ERR_R(DS_ERR_INVAL, "wm_init_rt_pool: bad args");
    if (wm->fact_slab)
        return DS_OK_R;

    uint8_t *slab = DS_CALLOC(n, stride);
    if (!slab) return DS_ERR_R(DS_ERR_OOM, "wm_init_rt_pool: slab");

    ds_fact_t **stk = DS_MALLOC((size_t)n * sizeof(*stk));
    if (!stk) { DS_FREE(slab); return DS_ERR_R(DS_ERR_OOM, "wm_init_rt_pool: stack"); }

    for (uint32_t i = 0; i < n; i++)
        stk[i] = (ds_fact_t *)(slab + (size_t)i * stride);

    wm->fact_slab       = slab;
    wm->fact_stride     = stride;
    wm->fact_pool_cap   = n;
    wm->fact_free_stack = stk;
    wm->fact_free_n     = n;

    /* So asserts during the locked pump do not grow them. */
    (void)ds_oa_reserve(&wm->table, n);
    (void)ds_oa_reserve(&wm->by_id, n);
    return DS_OK_R;
}

ds_result_t ds_wm_destroy(ds_wm_state_t *wm)
{
    if (wm == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "wm must not be null");
    }


    uint32_t n = oa_len(&wm->table);
    for (uint32_t i = 0; i < n; i++) {
        ds_fact_t *e = *(ds_fact_t **)ds_oa_val_at(&wm->table, i);
        if (e != NULL) {
            wm_fact_release(wm, e);
        }
    }
    ds_oa_free(&wm->table);
    ds_oa_free(&wm->by_id);
    DS_FREE(wm->fact_slab);
    DS_FREE(wm->fact_free_stack);

    wm->engine          = NULL;
    wm->ttl_override_ns = 0;
    wm->retract_reason  = NULL;
    wm->fact_slab       = NULL;
    wm->fact_stride     = 0;
    wm->fact_pool_cap   = 0;
    wm->fact_free_stack = NULL;
    wm->fact_free_n     = 0;
    return DS_OK_R;
}

ds_result_t ds_wm_fact_new(ds_wm_state_t          *wm,
                           const struct ds_schema *schema,
                           void                   *rete_fact,
                           ds_fact_t             **out)
{
    if (wm == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "wm must not be null");
    }
    if (schema == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "schema must not be null");
    }
    if (rete_fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "rete_fact must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = NULL;

    uint32_t n_slots = schema->n_slots;

    ds_result_t r;
    ds_fact_t *f;
    if (wm->fact_slab && wm->fact_free_n > 0) {
        f = wm->fact_free_stack[--wm->fact_free_n];
    } else {
        size_t size = sizeof(ds_fact_t) + (size_t)n_slots * sizeof(ds_slot_value_t);
        f = DS_CALLOC(1, size);
        if (f == NULL)
            return DS_ERR_R(DS_ERR_OOM, "fact allocation failed");
    }

    f->schema     = schema;
    f->rete_fact = rete_fact;
    f->engine     = wm->engine;
    f->n_slots    = n_slots;

    f->fact_id = wm->engine->next_fact_id++;
    r = ds_clock_now_ns(&wm->engine->clock, &f->asserted_ns);
    if (r.status != DS_OK) {
        DS_FREE(f);
        return r;
    }
    /* [RFCS.23.5]: the held wall sample ([LTIM.2.8.4]). A recycled slab wrapper must not
       carry the last fact's seq. */
    f->assert_seq     = 0;
    f->assert_seq_set = false;
    r = ds_clock_wall_ns(&wm->engine->clock, &f->asserted_wall_ns,
                         &f->asserted_wall_set);
    if (r.status != DS_OK) {
        DS_FREE(f);
        return r;
    }
    if (!f->asserted_wall_set) f->asserted_wall_ns = 0;

    /* An override wins regardless of lifecycle ([LHYD.10.5.1]). */
    if (wm->ttl_override_ns != 0) {
        /* Cannot wrap: the assert refused any sum past INT64_MAX ([RFCS.6.7]). */
        f->ttl_deadline_ns = f->asserted_ns + wm->ttl_override_ns;
    } else if (schema->lifecycle == DS_SCHEMA_LIFECYCLE_TTL) {
        f->ttl_deadline_ns = f->asserted_ns + schema->ttl_ns;
    }

    r = wm_table_insert(wm, f);
    if (r.status != DS_OK) {
        wm_fact_release(wm, f);
        return r;
    }
    *out = f;
    return DS_OK_R;
}

ds_result_t ds_wm_fact_free(ds_wm_state_t *wm, ds_fact_t *fact)
{
    if (wm == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "wm must not be null");
    }
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }

    ds_fact_t **vp = (ds_fact_t **)ds_oa_get(&wm->table, &fact->rete_fact);
    if (vp == NULL) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "fact not in wm tracking table");
    }
    /* The rete pool is LIFO and reuses freed slots immediately, so a wrapper carrying a
       stale rete_fact can name a different live fact's key. */
    if (*vp != fact) {
        return DS_ERR_R(DS_ERR_NOT_FOUND,
                        "wm_fact_free: rete_fact key maps to a different fact");
    }
    ds_fact_t *removed = wm_table_remove(wm, fact->rete_fact);
    if (removed == NULL) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "fact not in wm tracking table");
    }
    wm_fact_release(wm, removed);
    return DS_OK_R;
}

/* The caller takes ownership of the wrapper. */
ds_result_t ds_wm_fact_detach(ds_wm_state_t *wm, ds_fact_t *fact)
{
    if (!wm || !fact) return DS_ERR_R(DS_ERR_INVAL, "wm_fact_detach: NULL");
    ds_fact_t *removed = wm_table_remove(wm, fact->rete_fact);
    if (removed == NULL)
        return DS_ERR_R(DS_ERR_NOT_FOUND, "wm_fact_detach: not in table");
    return DS_OK_R;
}

void ds_wm_fact_release_detached(ds_wm_state_t *wm, ds_fact_t *fact)
{
    if (fact == NULL) return;
    wm_fact_release(wm, fact);
}

/* fact->rete_fact is already the new key. */
ds_result_t ds_wm_fact_reattach(ds_wm_state_t *wm, ds_fact_t *fact)
{
    if (!wm || !fact) return DS_ERR_R(DS_ERR_INVAL, "wm_fact_reattach: NULL");
    return wm_table_insert(wm, fact);
}

ds_result_t ds_wm_fact_lookup(const ds_wm_state_t  *wm,
                              void                 *rete_fact,
                              ds_fact_t           **out)
{
    if (wm == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "wm must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = NULL;
    if (rete_fact == NULL) {
        return DS_OK_R;
    }
    ds_fact_t **vp = (ds_fact_t **)ds_oa_get(&wm->table, &rete_fact);
    if (vp != NULL) {
        *out = *vp;
    }
    return DS_OK_R;
}

ds_result_t ds_wm_fact_count(const ds_wm_state_t *wm, size_t *out)
{
    if (wm == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "wm must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = oa_len(&wm->table);
    return DS_OK_R;
}



ds_result_t ds_engine_fact_count(ds_engine_t *engine, size_t *out)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    return ds_wm_fact_count(&engine->wm, out);
}

/* [NFCT.6.4]. */
ds_result_t ds_engine_fact_find(ds_engine_t *engine, uint64_t fact_id,
                                ds_fact_t **out)
{
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = NULL;
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    ds_fact_t *f = ds_wm_fact_by_id(&engine->wm, fact_id);
    if (f == NULL) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "no live fact has this id");
    }
    *out = f;
    return DS_OK_R;
}

ds_result_t ds_fact_get_id_unchecked(const ds_fact_t *fact, uint64_t *out)
{
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = fact->fact_id;
    return DS_OK_R;
}

ds_result_t ds_fact_get_schema_unchecked(const ds_fact_t   *fact,
                                          const ds_schema_t **out)
{
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = fact->schema;
    return DS_OK_R;
}

ds_result_t ds_fact_get_asserted_ns_unchecked(const ds_fact_t *fact,
                                               uint64_t        *out)
{
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = fact->asserted_ns;
    return DS_OK_R;
}

ds_result_t ds_fact_get_ttl_deadline_ns_unchecked(const ds_fact_t *fact,
                                                   uint64_t        *out)
{
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = fact->ttl_deadline_ns;
    return DS_OK_R;
}

ds_result_t ds_fact_get_slot_count_unchecked(const ds_fact_t *fact,
                                              uint32_t        *out)
{
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out must not be null");
    }
    *out = fact->n_slots;
    return DS_OK_R;
}

ds_result_t ds_fact_get_slot_unchecked(const ds_fact_t *fact,
                                        uint32_t          index,
                                        const char      **out_name,
                                        ds_slot_value_t  *out_value)
{
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }
    if (out_name == NULL && out_value == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "at least one of out_name / out_value must be non-null");
    }
    if (index >= fact->n_slots) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "slot index out of range");
    }
    if (out_name != NULL) {
        if (fact->schema == NULL || fact->schema->slots == NULL) {
            *out_name = NULL;
        } else {
            *out_name = fact->schema->slots[index].name;
        }
    }
    if (out_value != NULL) {
        *out_value = fact->slots[index];
        /* A fact-ref slot stores its target's id; the caller gets the live target, or
           NULL once it has left working memory. */
        if (out_value->kind == DS_SLOT_FACT_REF)
            out_value->v.ref = ds_wm_fact_ref_resolve(fact, index);
    }
    return DS_OK_R;
}

ds_result_t ds_fact_get_slot_ref_id_unchecked(const ds_fact_t *fact,
                                              uint32_t         index,
                                              uint64_t        *out)
{
    if (fact == NULL || out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact and out must not be null");
    }
    if (index >= fact->n_slots) {
        return DS_ERR_R(DS_ERR_NOT_FOUND, "slot index out of range");
    }
    if (fact->slots[index].kind != DS_SLOT_FACT_REF) {
        return DS_ERR_R(DS_ERR_INVAL, "slot is not a fact-ref");
    }
    *out = ds_wm_slot_ref_id(&fact->slots[index]);
    return DS_OK_R;
}

/* [NCBK.2.9]. A NULL fact names no engine; its `_unchecked` body refuses it. */
#define DS_FACT_HANDLE_GUARD(fact)                                          \
    do {                                                                    \
        if ((fact) != NULL) DS_HANDLE_REFUSE_IF_HALTED((fact)->engine);     \
    } while (0)

ds_result_t ds_fact_get_id(const ds_fact_t *fact, uint64_t *out)
{
    DS_FACT_HANDLE_GUARD(fact);
    return ds_fact_get_id_unchecked(fact, out);
}

ds_result_t ds_fact_get_schema(const ds_fact_t   *fact,
                                const ds_schema_t **out)
{
    DS_FACT_HANDLE_GUARD(fact);
    return ds_fact_get_schema_unchecked(fact, out);
}

ds_result_t ds_fact_get_asserted_ns(const ds_fact_t *fact,
                                     uint64_t        *out)
{
    DS_FACT_HANDLE_GUARD(fact);
    return ds_fact_get_asserted_ns_unchecked(fact, out);
}

ds_result_t ds_fact_get_ttl_deadline_ns(const ds_fact_t *fact,
                                         uint64_t        *out)
{
    DS_FACT_HANDLE_GUARD(fact);
    return ds_fact_get_ttl_deadline_ns_unchecked(fact, out);
}

ds_result_t ds_fact_get_slot_count(const ds_fact_t *fact,
                                    uint32_t        *out)
{
    DS_FACT_HANDLE_GUARD(fact);
    return ds_fact_get_slot_count_unchecked(fact, out);
}

ds_result_t ds_fact_get_slot(const ds_fact_t *fact,
                              uint32_t          index,
                              const char      **out_name,
                              ds_slot_value_t  *out_value)
{
    DS_FACT_HANDLE_GUARD(fact);
    return ds_fact_get_slot_unchecked(fact, index, out_name, out_value);
}

ds_result_t ds_fact_get_slot_ref_id(const ds_fact_t *fact,
                                    uint32_t         index,
                                    uint64_t        *out)
{
    DS_FACT_HANDLE_GUARD(fact);
    return ds_fact_get_slot_ref_id_unchecked(fact, index, out);
}

ds_result_t ds_engine_for_each_fact(ds_engine_t        *engine,
                                     const ds_schema_t  *schema,
                                     ds_fact_visitor_fn  visitor,
                                     void               *user)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    if (visitor == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "visitor must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    /* The visitor runs between ds_callback_enter and _leave, so it cannot mutate working
       memory ([RARC.13.16], [RARC.13.17]), which licenses walking the dense array. */
    ds_wm_state_t *wm = &engine->wm;
    uint32_t wm_n = oa_len(&wm->table);
    for (uint32_t i = 0; i < wm_n; i++) {
        ds_fact_t *e = *(ds_fact_t **)ds_oa_val_at(&wm->table, i);
        if (e == NULL) continue;
        if (schema != NULL && e->schema != schema) continue;
        ds_callback_enter(engine);
        ds_result_t r = visitor(e, user);
        ds_callback_leave(engine);
        if (r.status != DS_OK) {
            return r;
        }
    }
    return DS_OK_R;
}



struct ds_rete_fact;
extern ds_result_t ds_rete_wm_assert_bridge(struct ds_engine      *engine,
                                          const ds_schema_t     *schema,
                                          const ds_slot_value_t *values,
                                          uint32_t               n_values,
                                          ds_fact_t            **out_fact);
extern ds_result_t ds_rete_wm_retract_bridge(struct ds_engine *engine,
                                           ds_fact_t        *fact);

/* [IDAT.4.6.1], [NFCT.2.2]. */
static ds_result_t wm_validate_assert_values(const ds_schema_t     *schema,
                                             const ds_slot_value_t *values,
                                             uint32_t               n_values)
{
    if (n_values != schema->n_slots)
        return DS_ERR_R(DS_ERR_INVAL,
                        "n_values must equal the schema's slot count "
                        "([NFCT.2.2])");
    const uint32_t n = n_values;
    if (n > 0 && values == NULL)
        return DS_ERR_R(DS_ERR_INVAL,
                        "values must not be null when n_values > 0");

    for (uint32_t i = 0; i < n; i++) {
        const ds_slot_desc_t *desc = &schema->slots[i];
        ds_slot_kind_t        kind = values[i].kind;

        /* [LNUL.3.1]. */
        if (kind == DS_SLOT_NULL) {
            if (!desc->nullable)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "null value in a non-nullable slot (LNUL.3.1)");
            continue;
        }

        switch (desc->type) {
        case DS_SLOT_TYPE_INT:
            if (kind != DS_SLOT_INT)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "slot-value kind does not match declared Int slot");
            break;
        /* [RDSC.5.5.8]: UTC ns, epoch days, ns. */
        case DS_SLOT_TYPE_TIME:
        case DS_SLOT_TYPE_DATE:
        case DS_SLOT_TYPE_DURATION:
            if (kind != DS_SLOT_INT)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "slot-value kind does not match declared "
                                "Time/Date/Duration slot (an Int, RDSC.5.5.8)");
            break;
        case DS_SLOT_TYPE_FLOAT:
            if (kind != DS_SLOT_FLOAT)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "slot-value kind does not match declared Float slot");
            break;
        case DS_SLOT_TYPE_STRING:
            if (kind != DS_SLOT_STRING)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "slot-value kind does not match declared String slot");
            if (values[i].v.s == NULL)
                return DS_ERR_R(DS_ERR_INVAL,
                                "string slot value must not be null");
            break;
        case DS_SLOT_TYPE_BOOL:
            if (kind != DS_SLOT_BOOL)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "slot-value kind does not match declared Bool slot");
            break;
        case DS_SLOT_TYPE_JSON:
            if (kind != DS_SLOT_JSON)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "slot-value kind does not match declared Json slot");
            if (values[i].v.json == NULL)
                return DS_ERR_R(DS_ERR_INVAL,
                                "Json slot value must not be null");
            break;
        case DS_SLOT_TYPE_SCHEMA:
            if (kind != DS_SLOT_FACT_REF)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "slot-value kind does not match declared Schema slot");
            if (values[i].v.ref == NULL)
                return DS_ERR_R(DS_ERR_INVAL,
                                "schema-ref slot value must not be null");
            /* Same name, same pointer ([IDAT.5]). */
            if (desc->schema_ref != NULL &&
                values[i].v.ref->schema != desc->schema_ref)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "schema-ref slot value has wrong target schema");
            break;
        case DS_SLOT_TYPE_BYTES:
            if (kind != DS_SLOT_BYTES)
                return DS_ERR_R(DS_ERR_SLOT_TYPE_MISMATCH,
                                "slot-value kind does not match declared Bytes slot");
            if (values[i].v.bytes.data == NULL && values[i].v.bytes.len > 0)
                return DS_ERR_R(DS_ERR_INVAL,
                                "Bytes slot data must not be null with non-zero len");
            break;
        }
    }
    return DS_OK_R;
}

/* [LNUL.3.4]: a Json slot value whose ROOT is null is the canonical null. */
static bool lnul_3_4_root_null(const ds_slot_value_t *v)
{
    ds_json_kind_t root_kind;
    return v->kind == DS_SLOT_JSON && v->v.json != NULL
        && ds_json_get_kind(v->v.json, &root_kind).status == DS_OK
        && root_kind == DS_JSON_NULL;
}

/* [NFCT.2.3]: stored as 0. */
static bool nfct_2_3_negative_duration(const ds_slot_desc_t *desc,
                                       const ds_slot_value_t *v)
{
    return desc->type == DS_SLOT_TYPE_DURATION && v->kind == DS_SLOT_INT
        && v->v.i < 0;
}

/* The value a slot of `desc`'s type stores in place of `v`, or false when `v` is stored
   as given. */
static bool canonical_slot_value(const ds_slot_desc_t *desc,
                                 const ds_slot_value_t *v,
                                 ds_slot_value_t *out)
{
    if (desc->type == DS_SLOT_TYPE_JSON && lnul_3_4_root_null(v)) {
        *out = (ds_slot_value_t){ .kind = DS_SLOT_NULL };
        return true;
    }
    if (nfct_2_3_negative_duration(desc, v)) {
        *out = (ds_slot_value_t){ .kind = DS_SLOT_INT, .v.i = 0 };
        return true;
    }
    return false;
}

static ds_result_t engine_assert_canonical(ds_engine_t           *engine,
                                           const ds_schema_t     *schema,
                                           const ds_slot_value_t *values,
                                           uint32_t               n_values,
                                           ds_fact_t            **out_fact);

/* [LNUL.3.4], [NFCT.2.3], on a copy: the caller's array is const. A rule's paths
   canonicalise in the Rete layer (ds_rete_lnul_3_4_canonical). */
static ds_result_t engine_assert_body(ds_engine_t           *engine,
                                      const ds_schema_t     *schema,
                                      const ds_slot_value_t *values,
                                      uint32_t               n_values,
                                      ds_fact_t            **out_fact)
{
    uint32_t n = 0;
    if (schema != NULL && values != NULL)
        n = n_values < schema->n_slots ? n_values : schema->n_slots;
    uint32_t first = n;
    ds_slot_value_t scratch;
    for (uint32_t i = 0; i < n; i++) {
        if (canonical_slot_value(&schema->slots[i], &values[i], &scratch)) {
            first = i;
            break;
        }
    }
    if (first == n)
        return engine_assert_canonical(engine, schema, values, n_values,
                                       out_fact);

    ds_slot_value_t  canon_buf[16];
    ds_slot_value_t *canon = canon_buf;
    if (n_values > sizeof(canon_buf) / sizeof(*canon_buf)) {
        canon = DS_MALLOC((size_t)n_values * sizeof(*canon));
        if (canon == NULL) {
            if (out_fact != NULL) *out_fact = NULL;
            return DS_ERR_R(DS_ERR_OOM, "assert: canonical slot values");
        }
    }
    memcpy(canon, values, (size_t)n_values * sizeof(*canon));
    for (uint32_t i = first; i < n; i++) {
        if (canonical_slot_value(&schema->slots[i], &canon[i], &scratch))
            canon[i] = scratch;
    }
    ds_result_t r = engine_assert_canonical(engine, schema, canon, n_values,
                                            out_fact);
    if (canon != canon_buf) DS_FREE(canon);
    return r;
}

static ds_result_t engine_assert_canonical(ds_engine_t           *engine,
                                           const ds_schema_t     *schema,
                                           const ds_slot_value_t *values,
                                           uint32_t               n_values,
                                           ds_fact_t            **out_fact)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (schema == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "schema must not be null");
    }

    /* The argument checks: [NFCT.2.11]'s order. A call refused here consumes nothing and
       records nothing ([RFCS.6.7]), so all of them precede the clock sample below. */
    {
        const ds_schema_t *held = NULL;
        if (schema->type_name == NULL
                || ds_schema_registry_find(&engine->schemas, schema->type_name,
                                           &held).status != DS_OK
                || held == NULL) {
            if (out_fact != NULL) *out_fact = NULL;
            return DS_ERR_R(DS_ERR_SCHEMA_UNKNOWN,
                            "assert: the schema is not registered with this "
                            "engine");
        }
    }

    {
        ds_result_t vr = wm_validate_assert_values(schema, values, n_values);
        if (vr.status != DS_OK) {
            if (out_fact != NULL) *out_fact = NULL;
            return vr;
        }
    }

    /* NaN never self-matches, which corrupts identity, joins and refraction. Inf is a
       value. The self-inequality is the libm-free test. */
    for (uint32_t i = 0; i < n_values && i < schema->n_slots; i++) {
        if (values[i].kind == DS_SLOT_FLOAT && values[i].v.f != values[i].v.f) {
            ds_metric_label_t labels[2] = {
                { .key = "schema",
                  .value = schema->type_name ? schema->type_name : "" },
                { .key = "slot", .value = schema->slots[i].name },
            };
            ds_metric_t m = {
                .name   = "ds.facts.nan_rejected_total",
                .kind   = DS_METRIC_COUNTER, .value = 1.0,
                .labels = labels, .n_labels = 2,
            };
            ds_telemetry_emit_metric(engine, &m);
            if (out_fact != NULL) *out_fact = NULL;
            return DS_ERR_R(DS_ERR_NAN_REJECTED,
                            "NaN Float rejected at assert; a slot must be finite or Inf");
        }
    }

    /* [LGRA.5.8.6]: O(1), from the root's counters. */
    for (uint32_t i = 0; i < n_values && i < schema->n_slots; i++) {
        if (values[i].kind == DS_SLOT_JSON && values[i].v.json != NULL
            && !ds_json_within_limits(values[i].v.json, NULL)) {
            if (out_fact != NULL) *out_fact = NULL;
            return DS_ERR_R(DS_ERR_JSON_LIMIT,
                            "Json slot value over a DS_JSON_MAX_* limit");
        }
    }

    /* [LSTR.8.5]. A FactExternal comes through here with its text already judged
       ([NCBK.10.4]). */
    for (uint32_t i = 0; i < n_values && i < schema->n_slots; i++) {
        bool ill = false;
        if (values[i].kind == DS_SLOT_STRING && values[i].v.s != NULL)
            ill = !ds_utf8_well_formed(values[i].v.s, strlen(values[i].v.s));
        else if (values[i].kind == DS_SLOT_JSON && values[i].v.json != NULL)
            ill = !ds_json_utf8_well_formed(values[i].v.json);
        if (ill) {
            if (out_fact != NULL) *out_fact = NULL;
            return DS_ERR_R(DS_ERR_ENCODING,
                            "assert: a String or Json slot's text is not "
                            "well-formed UTF-8 ([LSTR.8.5])");
        }
    }

    /* [LTIM.1.2.2]. After the kind check, so a Date slot holds an INT or a null. */
    for (uint32_t i = 0; i < n_values && i < schema->n_slots; i++) {
        if (schema->slots[i].type == DS_SLOT_TYPE_DATE
            && values[i].kind == DS_SLOT_INT
            && !ds_date_days_in_range(values[i].v.i)) {
            if (out_fact != NULL) *out_fact = NULL;
            return DS_ERR_R(DS_ERR_TIME_RANGE,
                            "assert: a Date outside the Date range, "
                            "1677-09-22 to 2262-04-11 ([LTIM.1.2.2])");
        }
    }

    {
        const char *why = ds_wm_tz_row_malformed(schema, values, n_values);
        if (why != NULL) {
            if (out_fact != NULL) *out_fact = NULL;
            return DS_ERR_R(DS_ERR_INVAL, why);
        }
    }

    /* [RFCS.6.7], [LTIM.1.1.5], [LTIM.2.8.6]: this judges the value the sample below
       holds: `reading` for the host's own step, and one read, since a live clock moves
       between two. For a nested assert, the enclosing step's held sample. */
    ds_clock_reading_t reading = { 0 };
    if (engine->api_depth == 1) ds_clock_read(&engine->clock, &reading);
    {
        const uint64_t window = engine->wm.ttl_override_ns != 0
            ? engine->wm.ttl_override_ns
            : (schema->lifecycle == DS_SCHEMA_LIFECYCLE_TTL ? schema->ttl_ns
                                                           : 0);
        if (window != 0) {
            uint64_t now_ns = reading.mono_ns;
            if (engine->api_depth != 1) {
                ds_result_t cr = ds_clock_now_ns(&engine->clock, &now_ns);
                if (cr.status != DS_OK) return cr;
            }
            if (now_ns > (uint64_t)INT64_MAX
                || window > (uint64_t)INT64_MAX - now_ns) {
                if (out_fact != NULL) *out_fact = NULL;
                return DS_ERR_R(DS_ERR_TIME_RANGE,
                    "assert: the fact's TTL deadline is outside the Time "
                    "range ([RFCS.6.7])");
            }
        }
    }

    /* [NLFC.9.5]: the same refusal for a held seed's deadline, which this sample would fix
       if it is the engine's first. */
    if (engine->api_depth == 1) {
        ds_result_t sr =
            ds_engine_nlfc_9_5_first_sample_in_range(engine, reading.mono_ns);
        if (sr.status != DS_OK) {
            if (out_fact != NULL) *out_fact = NULL;
            return sr;
        }
    }

    /* [LECC.1.2]: a malformed code is engine-internal, so author rules never see one. */
    ds_slot_value_t call_error_buf[8];
    if (schema->type_name != NULL
        && strcmp(schema->type_name, "CallError") == 0
        && n_values <= (uint32_t)(sizeof(call_error_buf) / sizeof(*call_error_buf))) {
        for (uint32_t i = 0; i < n_values && i < schema->n_slots; i++) {
            if (strcmp(schema->slots[i].name, "code") != 0) continue;
            const char *cs = values[i].v.s;
            extern bool ds_error_code_valid(const char *s);
            if (values[i].kind == DS_SLOT_STRING && cs != NULL
                && !ds_error_code_valid(cs)) {
                memcpy(call_error_buf, values, sizeof(*values) * n_values);
                call_error_buf[i].v.s = "internal.invariant";
                values = call_error_buf;
                ds_metric_label_t lbls[] = {
                    { .key = "schema", .value = schema->type_name },
                };
                ds_metric_t m = {
                    .name = "ds.errors.code_invariant_total",
                    .kind = DS_METRIC_COUNTER, .value = 1.0,
                    .labels = lbls, .n_labels = 1,
                };
                ds_telemetry_emit_metric(engine, &m);
            }
            break;
        }
    }

    /* [LTIM.2.8.4], [LTIM.2.8.5]: one sample per step, recorded before the assert's own
       record. A nested assert takes the enclosing step's sample. */
    if (engine->api_depth == 1) {
        /* [LGRA.24.3]: the step may apply a pending `initial` block, which may refuse the
           step ([RFCS.6.7]). The input is pending across the sample so that refusal's
           BoundsError writes this assert's FactAssert first. */
        ds_recorder_input_begin(engine, schema, values, n_values);
        ds_result_t sr = ds_engine_clock_step_at(engine, DS_CLOCK_STEP_INPUT,
                                                 &reading);
        ds_recorder_input_end(engine);
        if (sr.status != DS_OK) {
            if (out_fact != NULL) *out_fact = NULL;
            return sr;
        }
    }
    /* [LFST.7.3.6]: the assert's own record goes out before any cascade it causes. */
    ds_recorder_defer_enter(engine);
    /* [LCRS.6.2.4], [RFCS.6.7]: an answer supersedes before it enters working memory and
       after it in the stream, so inside the bracket, where the retractions buffer. */
    ds_result_t ar = ds_dispatch_supersede_arrival(engine, schema, values,
                                                   n_values);
    if (ar.status == DS_OK)
        ar = ds_rete_wm_assert_bridge(engine, schema, values, n_values, out_fact);
    else if (out_fact != NULL)
        *out_fact = NULL;
    ds_result_t fr = ds_recorder_defer_leave(engine);
    return ar.status != DS_OK ? ar : fr;
}

/* The slots are zone, valid_from, valid_until, offset_s ([LIMP.12.2]). A row whose periods
   overlap another's is admitted: [LTIM.10.7] decides which answers. */
const char *ds_wm_tz_row_malformed(const struct ds_schema *schema,
                                   const ds_slot_value_t  *values,
                                   uint32_t                n_values)
{
    if (schema->type_name == NULL
        || strcmp(schema->type_name, "TimeZoneOffset") != 0
        || schema->n_slots != 4 || n_values != 4
        || values[0].kind != DS_SLOT_STRING || values[1].kind != DS_SLOT_INT
        || values[2].kind != DS_SLOT_INT || values[3].kind != DS_SLOT_INT)
        return NULL;
    if (!(values[1].v.i < values[2].v.i))
        return "TimeZoneOffset: valid_from is not before valid_until "
               "([LTIM.10.9])";
    if (values[3].v.i < -64800 || values[3].v.i > 64800)
        return "TimeZoneOffset: offset_s outside [-64800, 64800] "
               "([LTIM.10.9])";
    if (values[0].v.s != NULL && strcmp(values[0].v.s, "UTC") == 0)
        return "TimeZoneOffset: the zone \"UTC\" takes no row "
               "([LTIM.10.8], [LTIM.10.9])";
    return NULL;
}

ds_result_t ds_engine_assert(ds_engine_t           *engine,
                             const ds_schema_t     *schema,
                             const ds_slot_value_t *values,
                             uint32_t               n_values,
                             ds_fact_t            **out_fact)
{
    ds_api_enter(engine);
    return ds_api_leave(engine, engine_assert_body(engine, schema, values,
                                                   n_values, out_fact));
}

static ds_result_t engine_assert_with_ttl_body(
    ds_engine_t           *engine,
    const ds_schema_t     *schema,
    const ds_slot_value_t *values,
    uint32_t               n_values,
    uint64_t               ttl_ns_override,
    ds_fact_t            **out_fact)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    uint64_t prev = engine->wm.ttl_override_ns;
    engine->wm.ttl_override_ns = ttl_ns_override;
    /* The body: this call is already the host's step ([LTIM.2.8.4]). */
    ds_result_t r = engine_assert_body(engine, schema, values, n_values,
                                       out_fact);
    engine->wm.ttl_override_ns = prev;
    return r;
}

ds_result_t ds_engine_assert_with_ttl(ds_engine_t           *engine,
                                       const ds_schema_t     *schema,
                                       const ds_slot_value_t *values,
                                       uint32_t               n_values,
                                       uint64_t               ttl_ns_override,
                                       ds_fact_t            **out_fact)
{
    ds_api_enter(engine);
    return ds_api_leave(engine, engine_assert_with_ttl_body(
        engine, schema, values, n_values, ttl_ns_override, out_fact));
}

static ds_result_t engine_retract_body(ds_engine_t *engine, ds_fact_t *fact)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (fact == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "fact must not be null");
    }

    /* [LTIM.2.8.4]: a host retract is an input, sampled before its record. A cascade retract
       runs nested and samples nothing. */
    if (engine->api_depth == 1) {
        ds_result_t sr = ds_engine_clock_step(engine, DS_CLOCK_STEP_INPUT);
        if (sr.status != DS_OK) return sr;
    }
    /* [LFST.7.3.6]. */
    ds_recorder_defer_enter(engine);
    ds_result_t rr = ds_rete_wm_retract_bridge(engine, fact);
    ds_result_t fr = ds_recorder_defer_leave(engine);
    return rr.status != DS_OK ? rr : fr;
}

ds_result_t ds_engine_retract(ds_engine_t *engine, ds_fact_t *fact)
{
    ds_api_enter(engine);
    return ds_api_leave(engine, engine_retract_body(engine, fact));
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/tms.c — truth maintenance dependency table (IRET.12).
 */
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"

#include "rete/clone.h"
#include "rete/tms.h"

#define TMS_MAX_LOAD 70u

static uint64_t tms_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    return (uint64_t)*(const int64_t *)key;
}

static bool tms_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return *(const int64_t *)a == *(const int64_t *)b;
}

static void tms_just_dtor(void *val, void *ctx)
{
    (void)ctx;
    ds_tms_just_t *j = (ds_tms_just_t *)val;
    DS_FREE(j->heap_ids);
}

void ds_tms_table_init(ds_tms_table_t *tms)
{
    memset(tms, 0, sizeof(*tms));
    ds_oa_init(&tms->map, sizeof(int64_t), sizeof(ds_tms_just_t), TMS_MAX_LOAD,
            tms_oa_hash, tms_oa_eq, tms_just_dtor, NULL);
}

void ds_tms_table_destroy(ds_tms_table_t *tms)
{
    ds_oa_free(&tms->map);
    DS_FREE(tms->withdraw_scratch);
    tms->withdraw_scratch     = NULL;
    tms->withdraw_scratch_cap = 0;
    tms->rt_locked            = false;
}

ds_result_t ds_tms_presz(ds_tms_table_t *tms, uint32_t cap)
{
    if (!tms || cap == 0) return DS_ERR_R(DS_ERR_INVAL, "tms_presz");
    return ds_oa_reserve(&tms->map, cap);
}

ds_result_t ds_tms_add(ds_tms_table_t *tms, int64_t timetag,
                        const char *rule_name, uint32_t fact_id)
{
    void *vp;
    bool  is_new;
    /* The table is not locked for grow: RT presizes it. */
    ds_result_t r = ds_oa_put(&tms->map, &timetag, &vp, &is_new);
    if (r.status != DS_OK) return r;
    ds_tms_just_t *e = (ds_tms_just_t *)vp;

    if (is_new) {
        e->rule_name = rule_name;
    }

    if (e->count < DS_TMS_INLINE) {
        e->inline_ids[e->count++] = fact_id;
    } else {
        if (tms->rt_locked)
            return DS_ERR_R(DS_ERR_RT_UNSAFE,
                            "tms_add: >DS_TMS_INLINE logical asserts in RT mode");
        uint32_t overflow = e->count - DS_TMS_INLINE;
        if (overflow >= e->heap_cap) {
            uint32_t nc = e->heap_cap ? e->heap_cap * 2 : 4u;
            uint32_t *nb = DS_REALLOC(e->heap_ids, nc * sizeof(*nb));
            if (!nb) return DS_ERR_R(DS_ERR_OOM, "tms fact list grow");
            e->heap_ids = nb;
            e->heap_cap = nc;
        }
        e->heap_ids[overflow] = fact_id;
        e->count++;
    }
    return DS_OK_R;
}

ds_result_t ds_tms_withdraw(ds_tms_table_t *tms, int64_t timetag,
                              uint32_t **ids_out, uint32_t *count_out,
                              bool *caller_must_free)
{
    *ids_out          = NULL;
    *count_out        = 0;
    *caller_must_free = false;

    ds_tms_just_t *e = (ds_tms_just_t *)ds_oa_get(&tms->map, &timetag);
    if (!e) return DS_OK_R;

    uint32_t n = e->count;
    uint32_t *ids = NULL;

    if (n > 0) {
        if (n > DS_TMS_INLINE) {
            /* The caller owns these, so a cascade that re-enters this while
               it walks them cannot reach them ([IRET.12.2]). RT mode never
               gets here: ds_tms_add refuses more than DS_TMS_INLINE ids. */
            ids = DS_MALLOC(n * sizeof(*ids));
            if (!ids) return DS_ERR_R(DS_ERR_OOM, "tms withdraw: ids");
            *caller_must_free = true;
        } else {
            /* presz allocates the scratch for RT. */
            if (tms->withdraw_scratch_cap < DS_TMS_INLINE) {
                uint32_t *nb = DS_REALLOC(tms->withdraw_scratch,
                                          DS_TMS_INLINE * sizeof(*nb));
                if (!nb) return DS_ERR_R(DS_ERR_OOM, "tms withdraw: scratch");
                tms->withdraw_scratch     = nb;
                tms->withdraw_scratch_cap = DS_TMS_INLINE;
            }
            ids = tms->withdraw_scratch;
        }
        uint32_t inline_n = n < DS_TMS_INLINE ? n : DS_TMS_INLINE;
        memcpy(ids, e->inline_ids, inline_n * sizeof(uint32_t));
        if (n > DS_TMS_INLINE && e->heap_ids)
            memcpy(ids + DS_TMS_INLINE, e->heap_ids,
                   (n - DS_TMS_INLINE) * sizeof(uint32_t));
    }

    ds_oa_del(&tms->map, &timetag);

    *ids_out   = ids;
    *count_out = n;
    return DS_OK_R;
}

ds_result_t ds_tms_rekey(ds_tms_table_t *tms, int64_t from_timetag,
                          int64_t to_timetag)
{
    ds_tms_just_t *e = (ds_tms_just_t *)ds_oa_get(&tms->map, &from_timetag);
    if (!e) return DS_OK_R;
    if (from_timetag == to_timetag) return DS_OK_R;

    /* The copy owns heap_ids from here: the delete runs the val_dtor. */
    ds_tms_just_t moved = *e;
    e->heap_ids = NULL;
    e->heap_cap = 0;
    ds_oa_del(&tms->map, &from_timetag);

    void *vp;
    bool  is_new;
    ds_result_t r = ds_oa_put(&tms->map, &to_timetag, &vp, &is_new);
    if (r.status != DS_OK) {
        DS_FREE(moved.heap_ids);
        return r;
    }
    if (!is_new) {
        DS_FREE(moved.heap_ids);
        return DS_ERR_R(DS_ERR_INVAL, "tms_rekey: the new token is justified already");
    }
    *(ds_tms_just_t *)vp = moved;
    return DS_OK_R;
}

static void tms_val_remap(const void *sv, void *dv, void *ctx)
{
    ds_rete_clone_ctx_t *cx = (ds_rete_clone_ctx_t *) ctx;
    const ds_tms_just_t *s  = (const ds_tms_just_t *) sv;
    ds_tms_just_t       *d  = (ds_tms_just_t *) dv;

    *d = *s;
    d->rule_name = s->rule_name
        ? ds_rete_clone_intern(cx, s->rule_name, (uint32_t) strlen(s->rule_name))
        : NULL;
    d->heap_ids = NULL;
    if (s->heap_ids && s->count > DS_TMS_INLINE && s->heap_cap > 0) {
        uint32_t overflow = s->count - DS_TMS_INLINE;
        d->heap_ids = DS_MALLOC((size_t) s->heap_cap * sizeof(uint32_t));
        if (!d->heap_ids) { cx->oom = true; d->heap_cap = 0; return; }
        memcpy(d->heap_ids, s->heap_ids, (size_t) overflow * sizeof(uint32_t));
    }
}

ds_result_t ds_rete_tms_clone(ds_rete_clone_ctx_t  *cx,
                              const ds_tms_table_t *src,
                              ds_tms_table_t       *dst)
{
    dst->rt_locked = src->rt_locked;
    ds_result_t r = ds_oa_clone_into(&dst->map, &src->map, NULL, tms_val_remap, cx);
    if (r.status != DS_OK) return r;
    return cx->oom ? DS_ERR_R(DS_ERR_OOM, "tms_clone: heap_ids") : DS_OK_R;
}

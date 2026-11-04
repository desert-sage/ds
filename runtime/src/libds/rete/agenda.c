/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/agenda.c — activation agenda min-heap (IRET.11).
 */
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"

#include "rete/agenda.h"
#include "rete/clone.h"
#include "rete/terminal.h"

/*
 * [LDET.5.1]: terminal ordinal ([LDET.5.4]), then creation timetag ([LDET.5.5]),
 * lower first. Total: the ordinal is unique per rule, and a timetag is minted
 * per token and a token reaches exactly one terminal.
 */
static bool higher_priority(const ds_rete_activation_t *a,
                             const ds_rete_activation_t *b)
{
    uint32_t oa = a->terminal->ordinal;
    uint32_t ob = b->terminal->ordinal;
    if (oa != ob) return oa < ob;
    return a->creation_timetag < b->creation_timetag;
}

static void heap_set(ds_rete_agenda_t *ag, uint32_t i,
                     ds_rete_activation_t *act)
{
    ag->items[i]    = act;
    act->heap_index = i;
}

static void heap_swap(ds_rete_agenda_t *ag, uint32_t i, uint32_t j)
{
    ds_rete_activation_t *tmp = ag->items[i];
    heap_set(ag, i, ag->items[j]);
    heap_set(ag, j, tmp);
}

static void sift_up(ds_rete_agenda_t *ag, uint32_t i)
{
    while (i > 0) {
        uint32_t parent = (i - 1) / 2;
        if (!higher_priority(ag->items[i], ag->items[parent])) break;
        heap_swap(ag, i, parent);
        i = parent;
    }
}

static void sift_down(ds_rete_agenda_t *ag, uint32_t i)
{
    for (;;) {
        uint32_t best  = i;
        uint32_t left  = 2 * i + 1;
        uint32_t right = 2 * i + 2;
        if (left  < ag->count &&
            higher_priority(ag->items[left],  ag->items[best]))
            best = left;
        if (right < ag->count &&
            higher_priority(ag->items[right], ag->items[best]))
            best = right;
        if (best == i) break;
        heap_swap(ag, i, best);
        i = best;
    }
}

void ds_rete_agenda_init(ds_rete_agenda_t *ag)
{
    memset(ag, 0, sizeof(*ag));
}

void ds_rete_agenda_destroy(ds_rete_agenda_t *ag)
{
    DS_FREE(ag->items);
    ag->items = NULL;
    ag->count = ag->cap = 0;
}

ds_result_t ds_rete_agenda_insert(ds_rete_agenda_t     *ag,
                                   ds_rete_activation_t *act)
{
    if (ag->count >= ag->cap) {
        uint32_t nc = ag->cap ? ag->cap * 2 : 8u;
        ds_rete_activation_t **nb =
            DS_REALLOC(ag->items, nc * sizeof(*nb));
        if (!nb) return DS_ERR_R(DS_ERR_OOM, "agenda grow");
        ag->items = nb;
        ag->cap   = nc;
    }
    heap_set(ag, ag->count++, act);
    sift_up(ag, ag->count - 1);
    return DS_OK_R;
}

void ds_rete_agenda_remove(ds_rete_agenda_t     *ag,
                            ds_rete_activation_t *act)
{
    uint32_t i = act->heap_index;
    if (i >= ag->count || ag->items[i] != act) return;

    ag->count--;
    if (i == ag->count) {
        ag->items[i] = NULL;
        return;
    }
    heap_set(ag, i, ag->items[ag->count]);
    ag->items[ag->count] = NULL;
    sift_up(ag, i);
    sift_down(ag, ag->items[i]->heap_index);
}

ds_rete_activation_t *ds_rete_agenda_pop(ds_rete_agenda_t *ag)
{
    if (ag->count == 0) return NULL;
    ds_rete_activation_t *top = ag->items[0];
    ag->count--;
    if (ag->count > 0) {
        heap_set(ag, 0, ag->items[ag->count]);
        ag->items[ag->count] = NULL;
        sift_down(ag, 0);
    } else {
        ag->items[0] = NULL;
    }
    return top;
}

ds_result_t ds_rete_agenda_clone(ds_rete_clone_ctx_t    *cx,
                                 const ds_rete_agenda_t *src,
                                 ds_rete_agenda_t       *dst)
{
    /* The heap's pointers are borrowed from the terminals; copied in place with
       each remapped, so the pop order is identical. */
    if (src->count == 0) return DS_OK_R;

    uint32_t cap = src->cap ? src->cap : src->count;
    dst->items = DS_CALLOC(cap, sizeof(*dst->items));
    if (!dst->items) return DS_ERR_R(DS_ERR_OOM, "agenda_clone: items");
    dst->cap   = cap;
    dst->count = src->count;
    for (uint32_t i = 0; i < src->count; i++)
        dst->items[i] = ds_rete_clone_act_lookup(cx, src->items[i]);
    return DS_OK_R;
}

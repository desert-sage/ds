/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/arena.h — bump arena for computed strings the engine does not store in a
 * fact slot, so they never grow the intern table. One emitted into a slot is
 * interned at the emit-commit.
 *
 * A chain of slabs: growth never moves a span, so an outstanding pointer stays
 * valid. Reset, at pump entry, rewinds the slabs and keeps them.
 */
#ifndef LIBDS2_INTERNAL_RETE_ARENA_H
#define LIBDS2_INTERNAL_RETE_ARENA_H

#include <stddef.h>
#include <string.h>

#include "ds_alloc.h"

#define DS_ARENA_SLAB 4096u

typedef struct ds_rete_arena_slab {
    struct ds_rete_arena_slab *next;
    size_t                     cap;   /* usable bytes in data[] */
    size_t                     used;  /* bump offset */
    char                       data[];/* flexible array — cap bytes */
} ds_rete_arena_slab_t;

typedef struct ds_rete_arena {
    ds_rete_arena_slab_t *head;   /* first slab; reset rewinds from here */
    ds_rete_arena_slab_t *cur;    /* current bump slab */
    size_t                bytes_used; /* live bytes this cycle */
    size_t                high_water; /* max bytes_used ever */
} ds_rete_arena_t;

static inline void ds_rete_arena_init(ds_rete_arena_t *a)
{
    a->head = NULL;
    a->cur  = NULL;
    a->bytes_used = 0;
    a->high_water = 0;
}

static inline void ds_rete_arena_destroy(ds_rete_arena_t *a)
{
    ds_rete_arena_slab_t *s = a->head;
    while (s) {
        ds_rete_arena_slab_t *n = s->next;
        DS_FREE(s);
        s = n;
    }
    a->head = a->cur = NULL;
    a->bytes_used = 0;
}

static inline ds_rete_arena_slab_t *ds_rete_arena_new_slab(size_t need)
{
    size_t cap = need > DS_ARENA_SLAB ? need : DS_ARENA_SLAB;
    ds_rete_arena_slab_t *s = DS_MALLOC(sizeof(*s) + cap);
    if (!s) return NULL;
    s->next = NULL;
    s->cap  = cap;
    s->used = 0;
    return s;
}

/*
 * Copy (src, len) plus a NUL terminator into the arena and return a
 * pointer stable until the next ds_rete_arena_reset. Returns NULL on OOM.
 * Bytes are copied, so src may itself be an arena pointer (e.g. a str_cat
 * part) without aliasing the destination span.
 */
static inline const char *ds_rete_arena_dup(ds_rete_arena_t *a,
                                             const char *src, size_t len)
{
    size_t need = len + 1;

    if (a->cur == NULL || a->cur->used + need > a->cur->cap) {
        /* Find a later slab (rewound by a prior reset) that fits, else
           chain a fresh one at the end. */
        ds_rete_arena_slab_t *s = (a->cur == NULL) ? a->head : a->cur->next;
        while (s && s->used + need > s->cap) s = s->next;
        if (s == NULL) {
            s = ds_rete_arena_new_slab(need);
            if (s == NULL) return NULL;
            if (a->cur == NULL) {
                a->head = s;
            } else {
                ds_rete_arena_slab_t *t = a->cur;
                while (t->next) t = t->next;
                t->next = s;
            }
        }
        a->cur = s;
    }

    char *p = a->cur->data + a->cur->used;
    if (len) memcpy(p, src, len);
    p[len] = '\0';
    a->cur->used += need;
    a->bytes_used += need;
    if (a->bytes_used > a->high_water) a->high_water = a->bytes_used;
    return p;
}

static inline void ds_rete_arena_reset(ds_rete_arena_t *a)
{
    for (ds_rete_arena_slab_t *s = a->head; s; s = s->next) s->used = 0;
    a->cur = a->head;
    a->bytes_used = 0;
}

#endif /* LIBDS2_INTERNAL_RETE_ARENA_H */

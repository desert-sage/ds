/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/agenda.h — activation and agenda (IRET.11).
 *
 * A binary min-heap of activations ordered by (terminal ordinal,
 * creation_timetag) ([LDET.5.4], [LDET.5.5], IRET.11.1). Each activation carries
 * a heap_index, for removal when a token is retracted before it fires.
 */
#ifndef LIBDS2_INTERNAL_RETE_AGENDA_H
#define LIBDS2_INTERNAL_RETE_AGENDA_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "rete/pool.h"

/* Forward declarations */
struct ds_rete_terminal;
struct ds_rete_token;

/* ---- Activation (IRET.11) ----------------------------------------- */

typedef struct ds_rete_activation {
    struct ds_rete_terminal  *terminal;
    struct ds_rete_token     *token;           /* owned copy */
    int64_t                   creation_timetag;
    uint32_t                  heap_index;
    bool                      fired;           /* fired, or dismissed by an immature maturity guard ([LTIM.2.5.1]) */
    /* [IRET.11.3]: the match has produced a firing, so its identity is in the
       terminal's refraction set until the activation is re-created
       ([IRET.11.3.2]). */
    bool                      refracts;
    struct ds_rete_activation *term_next;      /* per-terminal list */
    struct ds_rete_activation *term_prev;      /* NULL = head */
    ds_rete_pool_t            *act_pool;       /* non-NULL when pool-allocated */
} ds_rete_activation_t;

/* ---- Agenda -------------------------------------------------------- */

typedef struct {
    ds_rete_activation_t **items;
    uint32_t               count;
    uint32_t               cap;
} ds_rete_agenda_t;

void ds_rete_agenda_init(ds_rete_agenda_t *ag);
void ds_rete_agenda_destroy(ds_rete_agenda_t *ag);

ds_result_t ds_rete_agenda_insert(ds_rete_agenda_t     *ag,
                                   ds_rete_activation_t *act);

/* Does not free act. */
void ds_rete_agenda_remove(ds_rete_agenda_t     *ag,
                            ds_rete_activation_t *act);

/* NULL if the agenda is empty. The caller owns the returned activation. */
ds_rete_activation_t *ds_rete_agenda_pop(ds_rete_agenda_t *ag);

#endif /* LIBDS2_INTERNAL_RETE_AGENDA_H */

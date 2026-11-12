/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/dispatch.c — a sample's absorption into each declaration of its slot.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

#include "engine.h"
#include "recorder.h"
#include "rete/engine.h"
#include "series/dispatch.h"
#include "series/registry.h"
#include "series/state.h"
#include "telemetry.h"


/* [LSER.13.14], [LSIG.1.1]: the two step backings refuse, and only on a window: an
   `integral all_time` retains no samples. Every other backing drops its oldest. */
bool ds_series_refuses_at_capacity(const struct ds_series_decl_record *d)
{
    return d != NULL
        && (d->atom_field == DS_ATOM_SERIES_BACKEND_INTERVAL_PULSE
            || d->atom_field == DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL)
        && d->max_samples > 0
        && d->window_ns > 0;
}

/* Walks every decl of (schema, slot) that groups by `id_slot`, so parallel backings
   absorb the same sample, each under the identity its own `by:` names
   ([LSER.7.6.1]). */
void ds_series_absorb_one(struct ds_engine        *engine,
                          const char              *schema_name,
                          const char              *slot_name,
                          const char              *id_slot,
                          const char              *id_value,
                          const ds_slot_value_t   *value,
                          uint64_t                 ts_ns)
{
    if (engine == NULL || value == NULL) return;
    if (engine->n_series_decls == 0
        || engine->n_backend_slots == 0) {
        return;
    }
    if (id_slot == NULL) id_slot = "";

    for (size_t i = 0; i < engine->n_series_decls; i++) {
        const struct ds_series_decl_record *d =
            &engine->series_decls[i];
        if (strcmp(d->schema_name, schema_name) != 0
            || strcmp(d->slot_name, slot_name) != 0
            || strcmp(d->identity_slot_name ? d->identity_slot_name : "",
                      id_slot) != 0) {
            continue;
        }
        size_t backend_slot;
        if (!ds_engine_series_backend_slot_by_atom(
                engine, d->atom_field, &backend_slot)) {
            ds_engine_set_pending(engine, DS_ERR_R(
                DS_ERR_BACKEND_NOT_REGISTERED,
                "series-absorb: no backend registered for the backing atom"));
            continue;
        }
        const ds_series_backend_vtable_t *vt =
            ds_engine_series_backend_vtable_at(engine, backend_slot);

        ds_series_state_row_t *row = ds_series_state_lookup_or_insert(
            engine, &engine->series_state, engine->n_backend_slots,
            d->schema_name, d->slot_name,
            d->identity_slot_name, id_value,
            /* [RDSC.5a.8.1] */
            d->window_ns);
        if (row == NULL) {
            return;  /* OOM; pending error set */
        }

        /* [LNUL.8.6] */
        ds_slot_value_t         substituted;
        const ds_slot_value_t  *sample = value;
        if (value->kind == DS_SLOT_NULL) {
            if (d->null_policy == DS_SERIES_NULLS_HOLD) {
                if (!row->has_last_value) continue;
                substituted = row->last_value;
            } else if (d->null_policy == DS_SERIES_NULLS_ZERO) {
                memset(&substituted, 0, sizeof(substituted));
                if (d->slot_is_int) {
                    substituted.kind = DS_SLOT_INT;
                    substituted.v.i  = 0;
                } else {
                    substituted.kind = DS_SLOT_FLOAT;
                    substituted.v.f  = 0.0;
                }
            } else {
                continue;
            }
            sample = &substituted;
        }

        if (row->backend_state[backend_slot] == NULL) {
            ds_series_decl_t pub = {
                .schema_name        = d->schema_name,
                .slot_name          = d->slot_name,
                .identity_slot_name = d->identity_slot_name,
                .window_ns          = d->window_ns,
                .persist_ns         = d->persist_ns,
                .atom_field         = d->atom_field,
                .element_type       = (ds_series_element_type_t) d->element_type,
                .max_samples        = d->max_samples,
                .time_model         = d->time_model,
                .gap_policy         = d->gap_policy,
            };
            ds_result_t r = vt->instance_new(
                &pub, &row->backend_state[backend_slot]);
            if (r.status != DS_OK) {
                ds_engine_set_pending(engine, r);
                continue;
            }
        }
        /* The per-series cap: series_id is this decl's index, and contract_series is
           sorted by it. */
        if (engine->rete_engine && engine->rete_engine->has_contract) {
            uint32_t cap = 0;
            uint32_t lo = 0;
            uint32_t hi = engine->rete_engine->contract_n_series;
            while (lo < hi) {
                uint32_t mid = (lo + hi) / 2;
                const ds_rete_contract_series_cap_t *s =
                    &engine->rete_engine->contract_series[mid];
                if (s->series_id == (uint32_t)i) { cap = s->capacity; break; }
                if (s->series_id < (uint32_t)i) lo = mid + 1;
                else                            hi = mid;
            }
            if (cap > 0 && row->absorb_count + 1 > cap) {
                ds_recorder_emit_bounds_error(engine, DS_CAP_SERIES_CAPACITY,
                                              cap,
                                              (uint64_t)row->absorb_count + 1u,
                                              NULL, 0);
                ds_engine_set_pending(engine, DS_ERR_R(
                    DS_ERR_CONTRACT_BREACH,
                    "series: contract per-series capacity exceeded"));
                continue;
            }
        }

        ds_result_t r = vt->update(
            row->backend_state[backend_slot], sample, ts_ns);
        if (r.status != DS_OK) {
            ds_engine_set_pending(engine, r);
            continue;
        }
        row->last_absorbed_ts_ns = ts_ns;
        row->has_absorbed = true;
        row->absorb_count++;
        /* [LSER.13.14] */
        if (ds_series_refuses_at_capacity(d))
            (void) ds_series_state_note_capacity_sample(
                engine, row, d->max_samples, d->window_ns, ts_ns);

        /* For a later `nulls: hold`. A String is copied: the sample's pointer is the
           fact's. */
        if (sample != &substituted || d->null_policy != DS_SERIES_NULLS_HOLD) {
            if (sample->kind == DS_SLOT_STRING) {
                char *copy = DS_STRDUP(sample->v.s ? sample->v.s : "");
                if (copy != NULL) {
                    DS_FREE(row->held_str);
                    row->held_str       = copy;
                    row->last_value     = *sample;
                    row->last_value.v.s = copy;
                    row->has_last_value = true;
                }
            } else {
                row->last_value     = *sample;
                row->has_last_value = true;
            }
        }
    }
}

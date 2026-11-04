/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * telemetry.h — dispatch for metrics and operational logs ([IARC.1.14]).
 */
#ifndef LIBDS2_INTERNAL_TELEMETRY_H
#define LIBDS2_INTERNAL_TELEMETRY_H

#include "libds.h"

struct ds_engine;   /* forward decl */

typedef struct ds_telemetry_state {
    ds_metric_cb_t           metric_cb;
    void                    *metric_user;
    ds_log_cb_t              log_cb;
    void                    *log_user;
} ds_telemetry_state_t;

ds_result_t ds_telemetry_init(ds_telemetry_state_t *t);
ds_result_t ds_telemetry_destroy(ds_telemetry_state_t *t);

/*
 * [NCBK.1.5]: fire-and-forget. With no callback, a silent drop; a callback's status is
 * dropped. DS_OK unless an argument is NULL.
 */
ds_result_t ds_telemetry_emit_metric(struct ds_engine  *engine,
                                      const ds_metric_t *metric);

/* As ds_telemetry_emit_metric. */
ds_result_t ds_telemetry_emit_log(struct ds_engine     *engine,
                                   const ds_log_event_t *event);

#endif /* LIBDS2_INTERNAL_TELEMETRY_H */

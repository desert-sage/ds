/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * telemetry.c — dispatch for integrator-registered metric and log callbacks.
 */
#include <stddef.h>
#include <string.h>

#include "libds.h"

#include "engine.h"
#include "telemetry.h"

ds_result_t ds_telemetry_init(ds_telemetry_state_t *t)
{
    if (t == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "telemetry state must not be null");
    }
    t->metric_cb        = NULL;
    t->metric_user      = NULL;
    t->log_cb           = NULL;
    t->log_user         = NULL;
    return DS_OK_R;
}

ds_result_t ds_telemetry_destroy(ds_telemetry_state_t *t)
{
    if (t == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "telemetry state must not be null");
    }
    t->metric_cb        = NULL;
    t->metric_user      = NULL;
    t->log_cb           = NULL;
    t->log_user         = NULL;
    return DS_OK_R;
}

ds_result_t ds_telemetry_emit_metric(struct ds_engine  *engine,
                                      const ds_metric_t *metric)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    if (metric == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "metric must not be null");
    }

    ds_metric_cb_t  cb   = engine->telemetry.metric_cb;
    void           *user = engine->telemetry.metric_user;

    if (cb == NULL) {
        return DS_OK_R;
    }

    ds_callback_enter(engine);
    /* [NCBK.1.5] */
    (void) cb(engine, metric, user);
    ds_callback_leave(engine);
    return DS_OK_R;
}

ds_result_t ds_telemetry_emit_log(struct ds_engine     *engine,
                                   const ds_log_event_t *event)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    if (event == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "event must not be null");
    }

    ds_log_cb_t  cb   = engine->telemetry.log_cb;
    void        *user = engine->telemetry.log_user;

    if (cb == NULL) {
        return DS_OK_R;
    }

    ds_callback_enter(engine);
    /* [NCBK.1.5] */
    (void) cb(engine, event, user);
    ds_callback_leave(engine);
    return DS_OK_R;
}

/* -------- Public setters -------- */

ds_result_t ds_engine_set_metric_callback(ds_engine_t    *engine,
                                          ds_metric_cb_t  cb,
                                          void           *user)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    engine->telemetry.metric_cb   = cb;
    engine->telemetry.metric_user = user;
    return DS_OK_R;
}

ds_result_t ds_engine_set_log_callback(ds_engine_t *engine,
                                       ds_log_cb_t  cb,
                                       void        *user)
{
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    engine->telemetry.log_cb   = cb;
    engine->telemetry.log_user = user;
    return DS_OK_R;
}

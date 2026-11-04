/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_telemetry_basic — exercise metric + log callback machinery.
 *
 * Registers integrator-style callbacks that stash what they receive
 * into test-local arrays, then directly calls the internal emit
 * helpers to verify dispatch. Also verifies NULL-callback silent
 * drop and setter argument validation.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

#include "engine.h"
#include "telemetry.h"

static int fail(const char *msg, ds_result_t r)
{
    fprintf(stderr, "FAIL: %s: status=%d detail=%s\n",
            msg, r.status, r.detail ? r.detail : "(null)");
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) return fail(what, r);
    return 0;
}

static int expect_status(const char *what, ds_result_t r, ds_status_t want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want status %d, got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

/* Test-local stash for received callbacks. */
#define MAX_OBSERVED 16

struct metric_observation {
    char              name[64];
    ds_metric_kind_t  kind;
    double            value;
    size_t            n_labels;
    char              label_k0[32];
    char              label_v0[32];
};

struct log_observation {
    ds_log_level_t level;
    char           category[32];
    char           message[128];
};

static struct metric_observation metric_obs[MAX_OBSERVED];
static size_t                     metric_obs_n = 0;

static struct log_observation log_obs[MAX_OBSERVED];
static size_t                 log_obs_n = 0;

static void *last_user_metric = NULL;
static void *last_user_log    = NULL;

static ds_result_t metric_cb(ds_engine_t       *engine,
                             const ds_metric_t *metric,
                             void              *user)
{
    (void) engine;
    last_user_metric = user;
    if (metric_obs_n >= MAX_OBSERVED) return DS_OK_R;
    struct metric_observation *o = &metric_obs[metric_obs_n++];
    strncpy(o->name, metric->name, sizeof(o->name) - 1);
    o->name[sizeof(o->name) - 1] = '\0';
    o->kind     = metric->kind;
    o->value    = metric->value;
    o->n_labels = metric->n_labels;
    if (metric->n_labels > 0) {
        strncpy(o->label_k0, metric->labels[0].key,
                sizeof(o->label_k0) - 1);
        o->label_k0[sizeof(o->label_k0) - 1] = '\0';
        strncpy(o->label_v0, metric->labels[0].value,
                sizeof(o->label_v0) - 1);
        o->label_v0[sizeof(o->label_v0) - 1] = '\0';
    }
    return DS_OK_R;
}

static ds_result_t log_cb(ds_engine_t          *engine,
                          const ds_log_event_t *event,
                          void                 *user)
{
    (void) engine;
    last_user_log = user;
    if (log_obs_n >= MAX_OBSERVED) return DS_OK_R;
    struct log_observation *o = &log_obs[log_obs_n++];
    o->level = event->level;
    strncpy(o->category, event->category, sizeof(o->category) - 1);
    o->category[sizeof(o->category) - 1] = '\0';
    strncpy(o->message, event->message, sizeof(o->message) - 1);
    o->message[sizeof(o->message) - 1] = '\0';
    return DS_OK_R;
}

int main(void)
{
    ds_engine_t *e = NULL;
    ds_result_t r;

    r = ds_engine_new(NULL, &e);
    if (expect_ok("engine_new", r)) return 1;

    /* 1. Default state: no callbacks registered. Emit calls are
       silent drops. */
    ds_metric_t m_probe = {
        .name = "ds.probe", .kind = DS_METRIC_COUNTER, .value = 1,
        .labels = NULL, .n_labels = 0,
    };
    r = ds_telemetry_emit_metric(e, &m_probe);
    if (expect_ok("emit_metric unregistered", r)) return 1;

    ds_log_event_t ev_probe = {
        .level = DS_LOG_INFO, .category = "test", .message = "probe",
    };
    r = ds_telemetry_emit_log(e, &ev_probe);
    if (expect_ok("emit_log unregistered", r)) return 1;

    if (metric_obs_n != 0 || log_obs_n != 0) {
        fprintf(stderr, "FAIL: callbacks fired when unregistered\n");
        return 1;
    }

    /* 2. Register. */
    int metric_user_marker = 42;
    int log_user_marker    = 99;
    r = ds_engine_set_metric_callback(e, metric_cb, &metric_user_marker);
    if (expect_ok("set_metric_callback", r)) return 1;
    r = ds_engine_set_log_callback(e, log_cb, &log_user_marker);
    if (expect_ok("set_log_callback", r)) return 1;

    /* 3. Emit a counter without labels. */
    ds_metric_t m_count = {
        .name = "ds.wm.fact_asserted",
        .kind = DS_METRIC_COUNTER,
        .value = 1.0,
        .labels = NULL,
        .n_labels = 0,
    };
    r = ds_telemetry_emit_metric(e, &m_count);
    if (expect_ok("emit counter", r)) return 1;
    if (metric_obs_n != 1) {
        fprintf(stderr, "FAIL: metric_obs_n = %zu, want 1\n", metric_obs_n);
        return 1;
    }
    if (strcmp(metric_obs[0].name, "ds.wm.fact_asserted") != 0) {
        fprintf(stderr, "FAIL: metric name mismatch: %s\n",
                metric_obs[0].name);
        return 1;
    }
    if (metric_obs[0].kind != DS_METRIC_COUNTER) {
        fprintf(stderr, "FAIL: metric kind mismatch\n");
        return 1;
    }
    if (metric_obs[0].value != 1.0) {
        fprintf(stderr, "FAIL: metric value mismatch: %g\n", metric_obs[0].value);
        return 1;
    }
    if (metric_obs[0].n_labels != 0) {
        fprintf(stderr, "FAIL: metric n_labels should be 0\n");
        return 1;
    }
    if (last_user_metric != &metric_user_marker) {
        fprintf(stderr, "FAIL: metric callback user pointer mismatch\n");
        return 1;
    }

    /* 4. Emit a gauge with labels. */
    ds_metric_label_t labels[] = {
        { .key = "engine", .value = "primary" },
    };
    ds_metric_t m_gauge = {
        .name     = "ds.wm.fact_count",
        .kind     = DS_METRIC_GAUGE,
        .value    = 17.0,
        .labels   = labels,
        .n_labels = 1,
    };
    r = ds_telemetry_emit_metric(e, &m_gauge);
    if (expect_ok("emit gauge", r)) return 1;
    if (metric_obs_n != 2) {
        fprintf(stderr, "FAIL: metric_obs_n = %zu, want 2\n", metric_obs_n);
        return 1;
    }
    if (metric_obs[1].kind != DS_METRIC_GAUGE ||
        metric_obs[1].value != 17.0 ||
        metric_obs[1].n_labels != 1 ||
        strcmp(metric_obs[1].label_k0, "engine") != 0 ||
        strcmp(metric_obs[1].label_v0, "primary") != 0) {
        fprintf(stderr, "FAIL: gauge metric mismatch\n");
        return 1;
    }

    /* 5. Emit log events at various levels. */
    ds_log_event_t ev1 = {
        .level = DS_LOG_DEBUG, .category = "wm", .message = "fact wrapped",
    };
    ds_log_event_t ev2 = {
        .level = DS_LOG_WARNING, .category = "schema",
        .message = "duplicate registration attempt",
    };
    r = ds_telemetry_emit_log(e, &ev1);
    if (expect_ok("emit log #1", r)) return 1;
    r = ds_telemetry_emit_log(e, &ev2);
    if (expect_ok("emit log #2", r)) return 1;

    if (log_obs_n != 2) {
        fprintf(stderr, "FAIL: log_obs_n = %zu, want 2\n", log_obs_n);
        return 1;
    }
    if (log_obs[0].level != DS_LOG_DEBUG ||
        strcmp(log_obs[0].category, "wm") != 0 ||
        strcmp(log_obs[0].message, "fact wrapped") != 0) {
        fprintf(stderr, "FAIL: log[0] mismatch\n");
        return 1;
    }
    if (log_obs[1].level != DS_LOG_WARNING ||
        strcmp(log_obs[1].category, "schema") != 0 ||
        strcmp(log_obs[1].message, "duplicate registration attempt") != 0) {
        fprintf(stderr, "FAIL: log[1] mismatch\n");
        return 1;
    }
    if (last_user_log != &log_user_marker) {
        fprintf(stderr, "FAIL: log callback user pointer mismatch\n");
        return 1;
    }

    /* 6. Unregister via NULL. Subsequent emits are dropped. */
    r = ds_engine_set_metric_callback(e, NULL, NULL);
    if (expect_ok("unset metric cb", r)) return 1;
    r = ds_engine_set_log_callback(e, NULL, NULL);
    if (expect_ok("unset log cb", r)) return 1;

    size_t metric_before = metric_obs_n;
    size_t log_before    = log_obs_n;

    r = ds_telemetry_emit_metric(e, &m_count);
    if (expect_ok("emit after unset metric", r)) return 1;
    r = ds_telemetry_emit_log(e, &ev1);
    if (expect_ok("emit after unset log", r)) return 1;

    if (metric_obs_n != metric_before || log_obs_n != log_before) {
        fprintf(stderr, "FAIL: emit fired after callback unset\n");
        return 1;
    }

    /* 7. NULL-arg rejection. */
    r = ds_engine_set_metric_callback(NULL, metric_cb, NULL);
    if (expect_status("set_metric NULL engine", r, DS_ERR_INVAL)) return 1;
    r = ds_engine_set_log_callback(NULL, log_cb, NULL);
    if (expect_status("set_log NULL engine", r, DS_ERR_INVAL)) return 1;

    r = ds_telemetry_emit_metric(NULL, &m_count);
    if (expect_status("emit_metric NULL engine", r, DS_ERR_INVAL)) return 1;
    r = ds_telemetry_emit_metric(e, NULL);
    if (expect_status("emit_metric NULL metric", r, DS_ERR_INVAL)) return 1;
    r = ds_telemetry_emit_log(NULL, &ev1);
    if (expect_status("emit_log NULL engine", r, DS_ERR_INVAL)) return 1;
    r = ds_telemetry_emit_log(e, NULL);
    if (expect_status("emit_log NULL event", r, DS_ERR_INVAL)) return 1;

    r = ds_engine_free(e);
    if (expect_ok("engine_free", r)) return 1;

    printf("test_telemetry_basic: OK\n");
    return 0;
}

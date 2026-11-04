<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Metrics and logs

## Metrics

### `ds_metric_t`

**`typedef struct ds_metric { const char *name; ds_metric_kind_t kind; double value; const ds_metric_label_t *labels; uint32_t n_labels; } ds_metric_t;`**

One metric emission, complete in itself.

`name` has the form `ds.<component>.<name>`. `value` depends on `kind`, and a `double` carries an integer exactly below 2^53. `labels` is NULL when `n_labels` is `0`.

*(libds.h: ds_metric_t, Spec: [NCBK.3.2], [NMET.1.4], [NMET.3.1])*

### `ds_metric_kind_t`

**`typedef enum { DS_METRIC_COUNTER = 0, DS_METRIC_GAUGE = 1, DS_METRIC_HISTOGRAM = 2 } ds_metric_kind_t;`**

How a receiver folds `value`, and what a metric's name ends in.

| Member | `value` | Name |
|---|---|---|
| `DS_METRIC_COUNTER` | the increment, `1.0` per occurrence, not a running total | ends in `_total` |
| `DS_METRIC_GAUGE` | the current reading, replacing the previous one | does not end in `_total`; may end in its unit |
| `DS_METRIC_HISTOGRAM` | one raw observation, which the receiver buckets | ends in `_seconds`, `_bytes` or `_count` |

*(libds.h: ds_metric_kind_t, Spec: [NCBK.3.2], [NCBK.3.3], [NMET.2.2.1], [NMET.2.2.2], [NMET.2.3.1], [NMET.2.3.2], [NMET.2.4.1], [NMET.2.4.2], [NMET.2.4.4], [NMET.3.3], [NMET.8.1])*

### `ds_metric_label_t`

**`typedef struct ds_metric_label { const char *key; const char *value; } ds_metric_label_t;`**

One dimension of a metric emission.

Its values come from a bounded set: schema and slot names from the loaded program, service names from its service declarations, and `kind`, `verb` and `reason` from fixed sets. The engine takes them at the emission site.

*(libds.h: ds_metric_label_t, Spec: [NMET.5.1], [NMET.5.3], [NMET.9.1])*

### `ds_metric_cb_t`

**`typedef ds_result_t (*ds_metric_cb_t)(ds_engine_t *engine, const ds_metric_t *metric, void *user);`**

The metric callback.

The engine invokes it once per occurrence of the event a metric counts, inline, at the rate the events occur, in one serial order. libds drops its [status](contract.md#return-value). Every pointer in `metric` is valid only for the callback.

*(libds.h: ds_metric_cb_t, Spec: [NMET.1.1], [NMET.1.2], [NMET.3.2], [NMET.6.1], [NMET.6.3], [NMET.6.4], [NMET.6.5], [NCBK.3.5])*

### `ds_engine_set_metric_callback`

**`ds_result_t ds_engine_set_metric_callback(ds_engine_t *engine, ds_metric_cb_t cb, void *user);`**

Registers the metric callback.

A NULL `cb` removes it, and each later emission is dropped. Errors: `DS_ERR_INVAL`, `DS_ERR_STATE`, `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_set_metric_callback, Spec: [NMET.1.3], [NCBK.2.9], [RARC.13.16])*

### Metric inventory

[NMET.4](inv:specs:std:label#nmet-4) lists every metric libds emits, with its kind, its labels and the event that emits it. A histogram's row states its unit and bucket boundaries.

*(Spec: [NCBK.3.4], [NMET.1.5], [NMET.2.4.2], [NMET.6.1])*

## Logs

### `ds_log_level_t`

**`typedef enum { DS_LOG_DEBUG = 0, DS_LOG_INFO = 1, DS_LOG_WARNING = 2, DS_LOG_ERROR = 3, DS_LOG_CRITICAL = 4 } ds_log_level_t;`**

The severity of a log line, the C mirror of `proto/log_level.proto`'s `LogSeverity`.

*(libds.h: ds_log_level_t, Spec: [NCBK.4.2], [NCBK.4.5])*

### `ds_log_event_t`

**`typedef struct ds_log_event { ds_log_level_t level; const char *category; const char *message; } ds_log_event_t;`**

One operational log line.

It comes from the engine or from a rule's `log` action, and `category` distinguishes them. `message` is English and advisory, and its text is not stable across versions: branch on `ds_result_t.status`, not on a log line.

*(libds.h: ds_log_event_t, Spec: [NCBK.4.1], [NCBK.4.2], [NCBK.4.4])*

### `ds_log_cb_t`

**`typedef ds_result_t (*ds_log_cb_t)(ds_engine_t *engine, const ds_log_event_t *event, void *user);`**

The log callback.

libds drops its [status](contract.md#return-value).

*(libds.h: ds_log_cb_t, Spec: [NCBK.1.5], [NCBK.4.1])*

### `ds_engine_set_log_callback`

**`ds_result_t ds_engine_set_log_callback(ds_engine_t *engine, ds_log_cb_t cb, void *user);`**

Registers the log callback.

A NULL `cb` removes it. Errors: `DS_ERR_INVAL`, `DS_ERR_STATE`, `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_set_log_callback, Spec: [NCBK.2.9], [RARC.13.16])*

### One event on both callbacks

Where a metric and a log line report one event, the engine invokes both at the same site, the metric callback first.

*(Spec: [NMET.11.1])*

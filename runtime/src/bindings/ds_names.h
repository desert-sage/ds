/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * GENERATED from
 *   proto/stream_event_kind.proto
 *   proto/log_level.proto
 *   specs/registry/metric_kind.ebnf
 *   specs/registry/cache_removal_reason.ebnf
 * Do not edit: change the definition and regenerate ([STYL.5.9.6]).
 *
 * ds_names.h — the names the language bindings give libds's enums.
 *
 * ONE TABLE, TWO BINDINGS. pyds and @ds-lang/ds both hand libds's events to a
 * host language as plain records, and name these enums' values as strings.
 * Those strings are what a harness matches on. Each name is its clause's
 * stable name, and a value with no case takes the clause's name for a value
 * that is not a member.
 *
 * HEADER-ONLY ON PURPOSE. It declares nothing libds exports, so it adds no
 * symbol to libds.a or to either binding's undefined set, and it ships in
 * neither the libds tarball nor its public headers. It is not the integrator
 * surface: libds.h is.
 *
 * NO SERIES NAMES. The element type, the storage mode and the
 * aggregation reached a binding only through the public series reads and
 * the samples plane, which left libds.h before 1.0 ([NSBK.6.3]).
 */
#ifndef DS_BINDINGS_DS_NAMES_H
#define DS_BINDINGS_DS_NAMES_H

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "libds.h"

/* proto/stream_event_kind.proto#StreamEventKind (NCBK.2.13). */
static inline const char *ds_names_event_kind(ds_stream_ev_kind_t k)
{
    switch (k) {
    case DS_EV_FACT_ASSERT:         return "fact_assert";
    case DS_EV_FACT_RETRACT:        return "fact_retract";
    case DS_EV_FACT_MODIFY:         return "fact_modify";
    case DS_EV_RULE_FIRE_BEGIN:     return "rule_fire_begin";
    case DS_EV_RULE_FIRE_END:       return "rule_fire_end";
    case DS_EV_ACTION_CALL:         return "action_call";
    case DS_EV_ACTION_EMIT:         return "action_emit";
    case DS_EV_ACTION_PUBLISH:      return "action_publish";
    case DS_EV_ACTION_CACHE_SET:    return "action_cache_set";
    case DS_EV_ACTION_CACHE_GET:    return "action_cache_get";
    case DS_EV_ACTION_LOG:          return "action_log";
    case DS_EV_TICK:                return "tick";
    case DS_EV_ACTION_CACHE_DELETE: return "action_cache_delete";
    case DS_EV_RULE_LHS_FACTS:      return "rule_lhs_facts";
    case DS_EV_TIMER_ARMED:         return "timer_armed";
    case DS_EV_TIMER_FIRED:         return "timer_fired";
    case DS_EV_TYPE_ERROR:          return "type_error";
    case DS_EV_BOUNDS_ERROR:        return "bounds_error";
    case DS_EV_ENGINE_ERROR:        return "engine_error";
    case DS_EV_COMPUTATION_ERROR:   return "computation_error";
    case DS_EV_PUMP:                return "pump";
    default:                        return "unknown";
    }
}

/* proto/log_level.proto#LogSeverity (NCBK.4.5). */
static inline const char *ds_names_log_level(ds_log_level_t lvl)
{
    switch (lvl) {
    case DS_LOG_DEBUG:    return "DEBUG";
    case DS_LOG_INFO:     return "INFO";
    case DS_LOG_WARNING:  return "WARNING";
    case DS_LOG_ERROR:    return "ERROR";
    case DS_LOG_CRITICAL: return "CRITICAL";
    default:              return "UNKNOWN";
    }
}

/* specs/registry/metric_kind.ebnf (NMET.3.4). */
static inline const char *ds_names_metric_kind(ds_metric_kind_t k)
{
    switch (k) {
    case DS_METRIC_COUNTER:   return "counter";
    case DS_METRIC_GAUGE:     return "gauge";
    case DS_METRIC_HISTOGRAM: return "histogram";
    default:                  return "unknown";
    }
}

/* specs/registry/cache_removal_reason.ebnf (NSTG.2.4.3). */
static inline const char *ds_names_cache_removal(ds_cache_removal_reason_t r)
{
    switch (r) {
    case DS_CACHE_REMOVED_DELETE: return "delete";
    case DS_CACHE_REMOVED_TTL:    return "ttl";
    default:                      return "unknown";
    }
}

#endif /* DS_BINDINGS_DS_NAMES_H */

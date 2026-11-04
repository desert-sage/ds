/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * GENERATED from proto/stream_event_kind.proto.
 * Do not edit: change the definition and regenerate ([STYL.5.9.6]).
 *
 * ds_event_names.h — a stream event kind's stable name, for the recorder's
 * `ds.recorder.events_emitted_total{kind}` label. The same switch as
 * runtime/src/bindings/ds_names.h's ds_names_event_kind, which libds does
 * not reach. Internal: it ships in no tarball.
 */
#ifndef DS_LIBDS_EVENT_NAMES_H
#define DS_LIBDS_EVENT_NAMES_H

#include "libds.h"

/* proto/stream_event_kind.proto#StreamEventKind (NCBK.2.13). */
static inline const char *ds_event_kind_name(ds_stream_ev_kind_t k)
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

#endif /* DS_LIBDS_EVENT_NAMES_H */

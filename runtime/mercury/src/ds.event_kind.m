%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% ds.event_kind -- GENERATED. Do not edit: change the definition and
% regenerate ([STYL.5.9.6]).
%
% proto/stream_event_kind.proto#StreamEventKind (NCBK.2.13): a stream event's kind,
% one constructor per live member, and its stable name as
% runtime/src/bindings/ds_names.h gives it. `ds.events.recorder_kind_label`
% says which kind each of this runtime's events is.
%-----------------------------------------------------------------------------%

:- module ds.event_kind.
:- interface.

    %@helper
:- type stream_event_kind
    --->    sek_fact_assert
    ;       sek_fact_retract
    ;       sek_fact_modify
    ;       sek_rule_fire_begin
    ;       sek_rule_fire_end
    ;       sek_action_call
    ;       sek_action_emit
    ;       sek_action_publish
    ;       sek_action_cache_set
    ;       sek_action_cache_get
    ;       sek_action_log
    ;       sek_tick
    ;       sek_action_cache_delete
    ;       sek_rule_lhs_facts
    ;       sek_timer_armed
    ;       sek_timer_fired
    ;       sek_type_error
    ;       sek_bounds_error
    ;       sek_engine_error
    ;       sek_computation_error
    ;       sek_pump.

    % proto/stream_event_kind.proto#StreamEventKind (NCBK.2.13).
    %
    %@helper
:- func stream_event_kind_name(stream_event_kind) = string.

%-----------------------------------------------------------------------------%

:- implementation.

stream_event_kind_name(sek_fact_assert) = "fact_assert".
stream_event_kind_name(sek_fact_retract) = "fact_retract".
stream_event_kind_name(sek_fact_modify) = "fact_modify".
stream_event_kind_name(sek_rule_fire_begin) = "rule_fire_begin".
stream_event_kind_name(sek_rule_fire_end) = "rule_fire_end".
stream_event_kind_name(sek_action_call) = "action_call".
stream_event_kind_name(sek_action_emit) = "action_emit".
stream_event_kind_name(sek_action_publish) = "action_publish".
stream_event_kind_name(sek_action_cache_set) = "action_cache_set".
stream_event_kind_name(sek_action_cache_get) = "action_cache_get".
stream_event_kind_name(sek_action_log) = "action_log".
stream_event_kind_name(sek_tick) = "tick".
stream_event_kind_name(sek_action_cache_delete) = "action_cache_delete".
stream_event_kind_name(sek_rule_lhs_facts) = "rule_lhs_facts".
stream_event_kind_name(sek_timer_armed) = "timer_armed".
stream_event_kind_name(sek_timer_fired) = "timer_fired".
stream_event_kind_name(sek_type_error) = "type_error".
stream_event_kind_name(sek_bounds_error) = "bounds_error".
stream_event_kind_name(sek_engine_error) = "engine_error".
stream_event_kind_name(sek_computation_error) = "computation_error".
stream_event_kind_name(sek_pump) = "pump".

%-----------------------------------------------------------------------------%
:- end_module ds.event_kind.
%-----------------------------------------------------------------------------%

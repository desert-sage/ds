%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.events.m.
%
% What a call reports: the integrator's stream events, the log lines and the
% metrics, in the order libds hands them to its callbacks.
%
% A report is a value the call returns, not a callback the binding runs.
% libds's stream, log and metric callbacks answer nothing the engine acts on
% ([NCBK.1.5]), so here they are data, and a call that produces them takes no
% host.
%
% An integrator event is one of libds's stream event kinds with its payload,
% as `libds.h` defines them: strings as strings, schemas by name, the four
% fault kinds apart. Its `seq` is the engine's own number for it. The
% runtime's own events carry more than the stream does, and those that
% libds's stream does not deliver are not reported, so the numbers of the
% events reported can have gaps.
%
%---------------------------------------------------------------------------%

:- module mercury_ds.events.
:- interface.

:- import_module mercury_ds.value.
:- import_module ds.
:- import_module ds.action.
:- import_module ds.chrono.
:- import_module ds.events.
:- import_module ds.fact_external.
:- import_module ds.id.
:- import_module list.
:- import_module maybe.

%---------------------------------------------------------------------------%
% Reports
%---------------------------------------------------------------------------%

    % One thing a call reports.
    %
:- type report
    --->    streamed(integrator_event)
            % A stream event.
    ;       logged(log_line)
            % A line for the host's log: a rule's `log`, or one the engine
            % writes itself.
    ;       measured(metric)
            % One emission of a metric libds defines.
    ;       cache_expired(string).
            % A cache entry's TTL ran out and it left the engine's cache: the
            % key, where the expiry happened among the call's other reports
            % -- for a pump, after the fact sweep's and before the run's
            % ([NSTG.2.4.2]) -- which is where libds calls its cache-removal
            % callback. The host's duty to remove it from its store is the
            % pump's `remove_cache` duty, handed over as well; this says
            % when. A rule's `cache_delete` needs no such report: its stream
            % event, `action_cache_delete`, is in place already.

    % A log line.
    %
:- type log_line
    --->    log_line(
                log_line_level    :: log_level,
                log_line_category :: string,
                            % The rule's name for a rule's `log`; the
                            % engine's subsystem for a line it writes itself.
                log_line_message  :: string
            ).

%---------------------------------------------------------------------------%
% Stream events
%---------------------------------------------------------------------------%

    % One stream event. (Not `event`, which Mercury reserves.)
    %
:- type integrator_event
    --->    integrator_event(
                integrator_event_seq   :: seq,
                            % The engine's number for the event, the `seq`
                            % a recording's atom for it carries.
                integrator_event_clock :: instant,
                            % The engine's monotonic clock when the event
                            % was emitted: the sample the step that emitted
                            % it took, which the `tick` before it reports.
                integrator_event_kind  :: event_kind
            ).

:- type event_kind
    --->    fact_assert(fact_id, string, list(storable))
            % The fact, its schema's name and its slot values.
    ;       fact_retract(fact_id)
            % Whoever removed it: the host, an expiry, a supersedure, truth
            % maintenance.
    ;       rule_lhs_facts(activation, list(fact_id))
            % What a firing matched, at most one fact per pattern
            % ([NCBK.2.6]): a fact the compiler made is not among them.
    ;       rule_fire_begin(activation)
    ;       rule_fire_end(activation)
    ;       action_call(service_call)
    ;       action_emit(fact_id, string)
    ;       action_publish(string, list(storable), maybe(fact_external))
            % The schema's name, the published slot values, and the fact as
            % it crosses to another engine, `no` where it would not encode.
            % No fact id: a `publish` puts nothing in this session's working
            % memory ([LTIE.4.3]), so the values are a view of a fact that
            % exists nowhere here ([NCBK.2.5]).
    ;       action_cache_set(cache_write)
    ;       action_cache_delete(string)
    ;       action_log(log_line)
    ;       tick(maybe(int64))
            % A clock sample: the wall sample in UTC nanoseconds, `no` while
            % the wall clock has no value. The monotonic sample is the
            % event's clock.
    ;       timer_armed(activation, duration, instant)
            % A cooldown window: its length and when it ends.
    ;       type_error(fault_info)
    ;       computation_error(trap_kind, fault_info)
    ;       bounds_error(cap_name, fault_info)
    ;       engine_error(engine_fault, fault_info)
            % The last event of a halted session ([NCBK.2.9]).
    ;       pump.
            % One pump begins.

    % The firing an event belongs to: the rule and the firing's timetag,
    % which every event of one firing carries ([NCBK.2.12]).
    %
:- type activation
    --->    activation(
                activation_rule    :: string,
                activation_timetag :: timetag
            ).

    % A rule's `call`, as the stream reports it and a service receives it.
    %
:- type service_call
    --->    service_call(
                service_call_service     :: string,
                service_call_correlation :: string,
                            % The call's `as` value, or the one the compiler
                            % generated for a call with none: every call
                            % carries one, never empty ([LCRS.3.1]).
                service_call_args        :: list(arg),
                            % The typed arguments, sorted by name
                            % ([NCBK.6.10]).
                service_call_activation  :: activation
            ).

    % A rule's `cache` write.
    %
:- type cache_write
    --->    cache_write(
                cache_write_key        :: string,
                cache_write_value_json :: string,
                            % The JSON text the cache holds.
                cache_write_ttl        :: maybe(duration)
                            % `no` for no expiry.
            ).

    % Where a fault was raised ([NCBK.2.10]). Each `maybe` field is `no`
    % where the raise site does not know it.
    %
:- type fault_info
    --->    fault_info(
                fault_info_rule       :: string,
                            % The fault's rule name ([LERR.9.11]): a rule,
                            % `$alpha_<id>`, `$beta_<id>` or `$engine`,
                            % synthetic names ([LLEX.10.6.1]). Never
                            % empty.
                fault_info_activation :: maybe(activation),
                fault_info_node       :: maybe(node_id),
                fault_info_schema     :: maybe(string),
                fault_info_slot       :: maybe(string),
                fault_info_bound      :: maybe(bound),
                fault_info_fact       :: maybe(fact_id),
                fault_info_actual     :: maybe(string)
                            % The tag the offending value had.
            ).

    % A declared cap's limit, and the usage the refused operation would have
    % reached.
    %
:- type bound
    --->    bound(
                bound_limit    :: int,
                bound_observed :: int
            ).

    % A computation error's kind: `proto/engine_error.proto`'s `TrapKind`.
    %
:- type trap_kind
    --->    divide_by_zero
    ;       domain
    ;       not_representable.

    % An engine error's cause: `proto/engine_fault.proto`'s `EngineFault`.
    %
:- type engine_fault
    --->    artefact_lied
    ;       pattern_index
    ;       binding_order
    ;       order_key
    ;       allocation
    ;       pump_wcet
    ;       unspecified_fault.
            % A fault with no `EngineFault` number of its own.

    % A bounds error's cap: `proto/bounds_error.proto`'s `CapName`.
    %
:- type cap_name
    --->    wm_max
    ;       agenda
    ;       max_fires_per_pump
    ;       token_pool
    ;       intern
    ;       intern_bytes
    ;       pump_wcet_ns
    ;       cache
    ;       cache_bytes
    ;       node_capacity
    ;       series_capacity
    ;       value_capacity.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

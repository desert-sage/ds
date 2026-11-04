% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.events -- stream events, and the effect list the pure core returns.
%
% Named `events' because `event' is reserved in Mercury.
%
% `seq` is no field of an event: `ds.effect.record/4` assigns it at append
% [formal/tla/stream_seq.tla].
%-----------------------------------------------------------------------------%

:- module ds.events.
:- interface.

:- import_module ds.action.
:- import_module ds.chrono.
:- import_module ds.event_kind.
:- import_module ds.fact.
:- import_module ds.fact_external.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.value.
:- import_module list.
:- import_module maybe.
:- import_module uint32.
:- import_module uint8.

%-----------------------------------------------------------------------------%
% Fire identity
%-----------------------------------------------------------------------------%

    % Which firing an event belongs to, the causal join key [RFCS.11.2, 15.2].
    % `timetag` is the firing token's creation timetag.
    %
:- type fire_id
    --->    fire_id(
                fi_timetag :: timetag,
                fi_rule    :: intern_ref
            ).

%-----------------------------------------------------------------------------%
% Events
%-----------------------------------------------------------------------------%

    % Which RHS verb put a call on the wire. Only the recording distinguishes
    % them: a `CallIssued` from a hydration omits `rule_name`.
    %
:- type call_origin
    --->    co_call_verb
    ;       co_hydration.

    % The engine's events. `recorder_kind_label` maps each to a stream kind or
    % to none; `event_class` gives its replay role.
    %
:- type stream_event

    % -- Inputs [LFST.6.1] ----------------------------------------------------

    --->    se_fact_assert(fact_id, schema_id, list(ds_value), maybe(duration))
            % The duration is the per-fact TTL override [RHIM.6.2].

    ;       se_fact_retract(fact_id)
            % The host took the fact back; the engine's is `se_fact_withdraw`.

    ;       se_clock_advance(instant)
    ;       se_pump_boundary
            % One host pump begins [RFCS.22], after its sample's tick. A
            % replayer performs a pump on meeting one.
    ;       se_call_response(intern_ref, fact_id)
    ;       se_call_error(intern_ref, string)

    % -- Engine internals [LFST.6.2] ------------------------------------------

    ;       se_rule_lhs_facts(fire_id, list(fact_id))
            % What the firing matched, immediately before `se_fire_begin`
            % [NCBK.2.12]; emitted only when that is at least one live fact.

    ;       se_fire_begin(fire_id)
    ;       se_fire_end(fire_id)

    ;       se_timer_armed(fire_id, duration, instant)
            % A cooldown window armed, after `se_fire_end` and whether or not
            % the gate suppressed the body: the window and `now + window`.

    ;       se_fact_withdraw(fact_id, retract_cause)
            % The engine took the fact back. Never delivered on replay.

    ;       se_fact_withdraw_unnamed(fact_id, uint32)
            % A recorded `FactWithdraw` whose cause number `FactWithdraw.Cause`
            % does not name [RFCS.7a.2]. Only a decoder makes one.

    ;       se_clock_tick(instant, maybe(int64))
            % An observed clock sample [LTIM.2.8.5]: monotonic, and wall in UTC
            % ns (`no` while the wall clock has no value). Emitted by the step
            % that samples, before its own events, for the first sample and
            % when either clock differs from the last recorded; never by a mock
            % mutation [NTST.3.3].

    ;       se_engine_error(engine_error, fault_site)

    % -- Engine-initiated actions [LFST.6.3] ----------------------------------

    ;       se_call_issued(fire_id, intern_ref, correlation, list(arg),
                call_origin)
            % The fourth field is the call's evaluated arguments, one per kwarg
            % in artefact order [NCBK.6.10], [RLOW.7.3.1].
    ;       se_cache_set(string, string, maybe(duration))
            % The key, the value's JSON text, the entry's TTL [NCBK.2.3].
    ;       se_cache_delete(string)
    ;       se_emit(fact_id, schema_id)

    ;       se_publish(schema_id, list(ds_value), maybe(fact_external))
            % No fact id: a `publish` puts nothing in this tier ([LTIE.4.3]).
            % The second field is the view ([NCBK.2.5]), the slot values in
            % declaration order; the third the FactExternal [NCBK.10.1], built
            % from them with `asserted_at` the publish's instant ([RFCS.23.5]),
            % and `no` when they would not encode.

    ;       se_log_emitted(log_level, string).
            % The rendered message.

    % `CacheGet` has no constructor: a cache read is pure and not recorded
    % [LFST.6.3], [RARC.5.7.9].

%-----------------------------------------------------------------------------%
% Where a fault was raised
%-----------------------------------------------------------------------------%

    % What [NCBK.2.10]'s fault payloads carry. A field is `no` where the raise
    % site does not know it, and `ds.rfcs.encode_fault` leaves that absent.
    %
    % `fs_bound` is the cap and refused usage of a `wm_max` or cache-cap breach;
    % a `wm_max` breach has no activation, even from a rule's `emit`.
    % The fact, schema, slot and `actual` of an evaluation fault come from its
    % offending operand, when that was a slot read (`ds.eval.fault_origin`).
    %
:- type fault_site
    --->    fault_site(
                fs_activation :: maybe(fire_id),
                fs_schema     :: maybe(intern_ref),
                fs_slot       :: maybe(intern_ref),
                fs_bound      :: maybe(fault_bound),
                fs_node       :: maybe(node_id),
                fs_fact       :: maybe(fact_id),
                fs_actual     :: maybe(string),
                fs_rule       :: fault_rule
            ).

    % Which rule a fault names [LERR.9.11]: an activation's rule; the node, for
    % a fault raised at a network node during matching; otherwise `$engine`.
    %
:- type fault_rule
    --->    fr_rule(intern_ref)
    ;       fr_alpha(node_id)
    ;       fr_beta(node_id)
    ;       fr_engine.

    % The rule name as text. An `fr_rule` the intern table does not hold reads
    % `$engine`.
    %
:- func fault_rule_name(intern_table, fault_rule) = string.

    % A declared cap's limit, and the usage the refused operation would have
    % reached.
    %
:- type fault_bound
    --->    fault_bound(
                fb_limit    :: uint64,
                fb_observed :: uint64
            ).

:- func no_site = fault_site.

%-----------------------------------------------------------------------------%
% Replay classification
%-----------------------------------------------------------------------------%

    % Every atom is exactly one of three classes [RFCS.3.4, 17.5].
    %
:- type event_class
    --->    inject
            % Recorded external input; delivered to the engine as recorded.

    ;       compare
            % Engine-produced; re-derived and byte-compared, never delivered.

    ;       structural.
            % Framing, schema, seek, attestation. No event has this class.

:- func event_class(stream_event) = event_class.

    % The event for a fact leaving working memory: `rc_explicit` is the host's
    % retract, every other cause the engine's.
    %
:- func removal_event(fact_id, retract_cause) = stream_event.

%-----------------------------------------------------------------------------%
% Effects
%-----------------------------------------------------------------------------%

    % What the pure core returns for the impure shell to perform, in order
    % [RARC.5.8.7]; each is handed to the host in that order.
    %
    % Only `eff_event` carries a `seq` or reaches a recording as an event:
    %
    % `eff_input` brackets the events of one host input whose fact holds a fact
    % reference, which a recording writes as one `ExternalAssert` [RFCS.24].
    %
    % `eff_cache_expired` reports a TTL-expired entry to the host's
    % cache-removal handler [NSTG.2.4]. A replay re-derives it.
    %
    % `eff_metric` is [NCBK.3.2]'s metric callback, placed as it occurs
    % [NMET.6.1].
    %
    % `eff_host_log` is the log callback for a line the engine itself writes:
    % level, category, message. A rule's `log` is `se_log_emitted`.
    %
    % `eff_pump_status` is the pump's return status, raised from inside it.
:- type effect
    --->    eff_event(stream_event)
    ;       eff_action(action)
    ;       eff_input(host_input)
    ;       eff_cache_expired(string)
    ;       eff_metric(metric)
    ;       eff_host_log(log_level, string, string)
    ;       eff_pump_status(pump_status).

    % A status a pump returns.
    %
:- type pump_status
    --->    ps_nan_rejected
            % DS_ERR_NAN_REJECTED: a `Float` call argument that is NaN refuses
            % the call [LEXP.4.2]; the firing's other actions run.
    ;       ps_contract_breach(cap)
            % DS_ERR_CONTRACT_BREACH: a rule's cache write past `cache_cap` or
            % `cache_bytes_cap` [LSTO.4.7.5], its `emit` or `publish` of a
            % `String` past its slot's `capacity` [LSTR.11.3], or its `emit` of
            % a sample past its series' `capacity` [LSER.13.14]. The firing
            % stops at it; the pump goes on.
    ;       ps_time_range.
            % DS_ERR_TIME_RANGE: the pump was refused before its step, because
            % its sample, the engine's first, would give a held seed a deadline
            % outside the `Time` range [NLFC.9.5]. It is the pump's only effect.

    % The first status a pump's effects carry, if any.
    %
:- func first_pump_status(list(effect)) = maybe(pump_status).

    % One metric emission [NCBK.3.2]. The labels are in [NMET.5.1]'s order.
    %
:- type metric
    --->    metric(
                m_name   :: string,
                m_kind   :: metric_kind,
                m_value  :: float,
                m_labels :: list({string, string})
            ).

:- type metric_kind
    --->    mk_counter
            % [NMET.2.2.1]: the delta, `1.0` per occurrence.
    ;       mk_gauge.

:- func counter(string, list({string, string})) = metric.

:- func gauge(string, float) = metric.

    % This event's stream kind, whose name is the label of
    % `ds.recorder.events_emitted_total{kind}` [NMET.4.1]; `no` for an event
    % that has none.
    %
:- func recorder_kind_label(stream_event) = maybe(stream_event_kind).

    % The two ends of one delivery [RFCS.24.1]. Between them, the
    % `se_fact_assert` events are the facts the input asserted [RFCS.24.3].
    %
:- type host_input
    --->    hi_open(list(uint8))
            % The input's FactExternal: the bytes as the host passed them to
            % `assert_external`, or, for a host assert whose fact holds a
            % non-null reference, the fact with each referenced fact inlined
            % [RFCS.23.4].
    ;       hi_close.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module string.

%-----------------------------------------------------------------------------%

event_class(se_fact_assert(_, _, _, _)) = inject.
event_class(se_fact_retract(_)) = inject.
event_class(se_clock_advance(_)) = inject.
event_class(se_pump_boundary) = inject.
event_class(se_call_response(_, _)) = inject.
event_class(se_call_error(_, _)) = inject.

event_class(se_fact_withdraw(_, _)) = compare.
event_class(se_fact_withdraw_unnamed(_, _)) = compare.

removal_event(FactId, Cause) =
    ( if Cause = rc_explicit then
        se_fact_retract(FactId)
    else
        se_fact_withdraw(FactId, Cause)
    ).

first_pump_status([]) = no.
first_pump_status([Effect | Effects]) =
    ( if Effect = eff_pump_status(Status) then
        yes(Status)
    else
        first_pump_status(Effects)
    ).

event_class(se_rule_lhs_facts(_, _)) = compare.
event_class(se_fire_begin(_)) = compare.
event_class(se_fire_end(_)) = compare.
event_class(se_timer_armed(_, _, _)) = compare.
event_class(se_clock_tick(_, _)) = compare.
event_class(se_engine_error(_, _)) = compare.

event_class(se_call_issued(_, _, _, _, _)) = compare.
event_class(se_cache_set(_, _, _)) = compare.
event_class(se_cache_delete(_)) = compare.
event_class(se_emit(_, _)) = compare.
event_class(se_publish(_, _, _)) = compare.
event_class(se_log_emitted(_, _)) = compare.

no_site = fault_site(no, no, no, no, no, no, no, fr_engine).

counter(Name, Labels) = metric(Name, mk_counter, 1.0, Labels).

gauge(Name, Value) = metric(Name, mk_gauge, Value, []).

recorder_kind_label(se_fact_assert(_, _, _, _)) = yes(sek_fact_assert).
recorder_kind_label(se_fact_retract(_)) = yes(sek_fact_retract).
recorder_kind_label(se_fact_withdraw(_, _)) = yes(sek_fact_retract).
recorder_kind_label(se_fact_withdraw_unnamed(_, _)) = yes(sek_fact_retract).
    % An advance reaches the stream as the next sample's `tick` [NTST.3.3].
recorder_kind_label(se_clock_advance(_)) = no.
recorder_kind_label(se_pump_boundary) = yes(sek_pump).
    % An answer reaches the stream as the `fact_assert` of the fact it carries.
recorder_kind_label(se_call_response(_, _)) = no.
recorder_kind_label(se_call_error(_, _)) = no.
recorder_kind_label(se_rule_lhs_facts(_, _)) = yes(sek_rule_lhs_facts).
recorder_kind_label(se_fire_begin(_)) = yes(sek_rule_fire_begin).
recorder_kind_label(se_fire_end(_)) = yes(sek_rule_fire_end).
recorder_kind_label(se_timer_armed(_, _, _)) = yes(sek_timer_armed).
recorder_kind_label(se_clock_tick(_, _)) = yes(sek_tick).
recorder_kind_label(se_engine_error(Err, _)) = yes(Kind) :-
    Class = fault_class(Err),
    (
        Class = fc_computation,
        Kind = sek_computation_error
    ;
        Class = fc_bounds,
        Kind = sek_bounds_error
    ;
        Class = fc_type,
        Kind = sek_type_error
    ;
        Class = fc_engine,
        Kind = sek_engine_error
    ).
recorder_kind_label(se_call_issued(_, _, _, _, _)) = yes(sek_action_call).
recorder_kind_label(se_cache_set(_, _, _)) = yes(sek_action_cache_set).
recorder_kind_label(se_cache_delete(_)) = yes(sek_action_cache_delete).
recorder_kind_label(se_emit(_, _)) = yes(sek_action_emit).
recorder_kind_label(se_publish(_, _, _)) = yes(sek_action_publish).
recorder_kind_label(se_log_emitted(_, _)) = yes(sek_action_log).

fault_rule_name(IT, fr_rule(Ref)) =
    ( if expand(IT, Ref, Name), Name \= "" then Name else "$engine" ).
fault_rule_name(_, fr_alpha(Node)) =
    "$alpha_" ++ string.int_to_string(uint32.cast_to_int(node_id_value(Node))).
fault_rule_name(_, fr_beta(Node)) =
    "$beta_" ++ string.int_to_string(uint32.cast_to_int(node_id_value(Node))).
fault_rule_name(_, fr_engine) = "$engine".

%-----------------------------------------------------------------------------%

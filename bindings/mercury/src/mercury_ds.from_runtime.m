%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.from_runtime.m.
%
% What the runtime's own values become for a host: its effects as reports,
% its values as `storable`s and its facts as views, its load errors as
% `ds_error`s, and its byte lists as bitmaps. A private submodule: the
% package's modules share it, and a host never sees it.
%
%---------------------------------------------------------------------------%

:- module mercury_ds.from_runtime.
:- interface.

:- import_module mercury_ds.error.
:- import_module mercury_ds.events.
:- import_module mercury_ds.value.
:- import_module ds.
:- import_module ds.chrono.
:- import_module ds.events.
:- import_module ds.fact.
:- import_module ds.fault.
:- import_module ds.intern.
:- import_module ds.schema.
:- import_module ds.value.
:- import_module bitmap.
:- import_module list.
:- import_module uint64.

%---------------------------------------------------------------------------%

    % The reports of a run of the runtime's effects, in order. The counter is
    % the engine's `seq` for the run's first event, and moves on by one for
    % every event, reported or not. `Schemas` names a schema id. The clock
    % is the one the last event before the run was emitted at; each `tick`
    % moves it, and each event carries it as it stands there.
    %
:- pred effect_reports(intern_table::in, list(schema)::in, list(effect)::in,
    list(report)::out, instant::in, instant::out, uint64::in, uint64::out)
    is det.

    % A rule's `call` as the stream reports it. Fail for any other event.
    %
:- pred call_of(intern_table::in, stream_event::in, service_call::out)
    is semidet.

    % A value the engine holds, as a host reads it: a `str` expanded to
    % `text` through the engine's intern table. Throw an exception for a
    % value no slot holds (a duration, a time, a ratio) or a `str` the table
    % does not hold: the engine stores neither, so either is a bug in the
    % runtime.
    %
:- func read_value(intern_table, ds_value) = storable.

    % The view of a fact whose schema has the given name.
    %
:- func view_of(intern_table, string, fact) = fact_view.

    % The error libds answers when it refuses an artefact for the same
    % reason.
    %
:- func load_failure(load_error) = ds_error.

    % The runtime's bytes as a host holds them: the runtime keeps bytes as
    % a list, and a host reads a `bitmap`.
    %
:- func bytes_bitmap(list(uint8)) = bitmap.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

:- import_module mercury_ds.status.
:- import_module ds.action.
:- import_module ds.fact_external.
:- import_module ds.id.
:- import_module array.
:- import_module int.
:- import_module maybe.
:- import_module string.
:- import_module uint32.
:- import_module uint8.

    % Qualified: `error/1` is also `maybe_error`'s and `outcome`'s failure.
    %
:- use_module require.

%---------------------------------------------------------------------------%
% Reports
%---------------------------------------------------------------------------%

effect_reports(Interns, Schemas, Effects, Reports, !Clock, !Seq) :-
    convert(Interns, Schemas, "", Effects, Reports, !Clock, !Seq).

    % `Rule0` is the rule of the most recent `fire_begin`: the category of a
    % rule's `log`, which sits inside its firing's brackets.
    %
:- pred convert(intern_table::in, list(schema)::in, string::in,
    list(effect)::in, list(report)::out, instant::in, instant::out,
    uint64::in, uint64::out) is det.

convert(_, _, _, [], [], !Clock, !Seq).
convert(Interns, Schemas, Rule0, [Effect | Effects], Reports, !Clock, !Seq) :-
    (
        Effect = eff_event(Event),
        ( if Event = se_fire_begin(fire_id(_, RuleRef)) then
            Rule = text_of(Interns, RuleRef)
        else
            Rule = Rule0
        ),
        % A tick is the sample its step took, and that step's events read
        % it, the tick's own included, as libds's recorder stamps them.
        ( if Event = se_clock_tick(To, _) then
            !:Clock = To
        else
            true
        ),
        Kind = kind_of(Interns, Schemas, Rule, Event),
        (
            Kind = yes(K),
            Streamed =
                [streamed(integrator_event(make_seq(!.Seq), !.Clock, K))]
        ;
            Kind = no,
            Streamed = []
        ),
        % The engine numbers every event, those libds's stream does not
        % deliver included, so they leave a gap.
        !:Seq = !.Seq + 1u64,
        % A rule's `log` reaches the log callback as well as the stream:
        % the stream event first, then the log line, as the runtime orders
        % an action after the event that records it.
        ( if Event = se_log_emitted(Level, Message) then
            Here = Streamed ++ [logged(log_line(Level, Rule, Message))]
        else
            Here = Streamed
        )
    ;
        Effect = eff_metric(Metric),
        Rule = Rule0,
        Here = [measured(Metric)]
    ;
        Effect = eff_host_log(Level, Category, Message),
        Rule = Rule0,
        Here = [logged(log_line(Level, Category, Message))]
    ;
        % [NSTG.2.4.2]: an expiry is reported where the runtime's
        % effect list has it, which is where libds calls its cache-removal
        % callback: the fact sweep's reports before it and the run's after.
        % It is the host's duty as well (`mercury_ds.session`'s `duty_of`).
        Effect = eff_cache_expired(Key),
        Rule = Rule0,
        Here = [cache_expired(Key)]
    ;
        % The rest are not reports. An action is performed through the event
        % that records it; an input bracket is a recorder's; a pump's status
        % is the pump's outcome (`mercury_ds.session.pump`).
        ( Effect = eff_action(_)
        ; Effect = eff_input(_)
        ; Effect = eff_pump_status(_)
        ),
        Rule = Rule0,
        Here = []
    ),
    convert(Interns, Schemas, Rule, Effects, Rest, !Clock, !Seq),
    Reports = Here ++ Rest.

    % The stream's kind for a runtime event, or `no` for one libds's stream
    % does not deliver: the same choice as `ds.events.recorder_kind_label`.
    %
:- func kind_of(intern_table, list(schema), string, stream_event)
    = maybe(event_kind).

kind_of(I, S, _, se_fact_assert(Id, Sid, Values, _)) =
    yes(fact_assert(Id, schema_text(I, S, Sid),
        list.map(read_value(I), Values))).
kind_of(_, _, _, se_fact_retract(Id)) = yes(fact_retract(Id)).
kind_of(_, _, _, se_fact_withdraw(Id, _)) = yes(fact_retract(Id)).
kind_of(_, _, _, se_fact_withdraw_unnamed(Id, _)) = yes(fact_retract(Id)).
kind_of(_, _, _, se_clock_advance(_)) = no.
kind_of(_, _, _, se_pump_boundary) = yes(pump).
kind_of(_, _, _, se_call_response(_, _)) = no.
kind_of(_, _, _, se_call_error(_, _)) = no.
kind_of(I, _, _, se_rule_lhs_facts(F, Ids)) =
    yes(rule_lhs_facts(activation_of(I, F), Ids)).
kind_of(I, _, _, se_fire_begin(F)) = yes(rule_fire_begin(activation_of(I, F))).
kind_of(I, _, _, se_fire_end(F)) = yes(rule_fire_end(activation_of(I, F))).
kind_of(I, _, _, se_timer_armed(F, Window, At)) =
    yes(timer_armed(activation_of(I, F), Window, At)).
kind_of(_, _, _, se_clock_tick(_, Wall)) = yes(tick(Wall)).
kind_of(I, _, _, se_engine_error(Err, Site)) =
    yes(fault_kind(Err, info_of(I, Site))).
kind_of(I, _, _, se_call_issued(Fire, Service, Corr, Args, _)) =
    yes(action_call(call_from(I, Fire, Service, Corr, Args))).
kind_of(_, _, _, se_cache_set(Key, Value, Ttl)) =
    yes(action_cache_set(cache_write(Key, Value, Ttl))).
kind_of(_, _, _, se_cache_delete(Key)) = yes(action_cache_delete(Key)).
kind_of(I, S, _, se_emit(Id, Sid)) =
    yes(action_emit(Id, schema_text(I, S, Sid))).
kind_of(I, S, _, se_publish(Sid, Values, External)) =
    yes(action_publish(schema_text(I, S, Sid), list.map(read_value(I), Values),
        External)).
kind_of(_, _, Rule, se_log_emitted(Level, Message)) =
    yes(action_log(log_line(Level, Rule, Message))).

call_of(I, se_call_issued(Fire, Service, Corr, Args, _),
    call_from(I, Fire, Service, Corr, Args)).

:- func call_from(intern_table, fire_id, intern_ref, correlation, list(arg))
    = service_call.

call_from(I, Fire, Service, Corr, Args) =
    service_call(text_of(I, Service), correlation_text(I, Corr), Args,
        activation_of(I, Fire)).

%---------------------------------------------------------------------------%
% Faults
%---------------------------------------------------------------------------%

    % The four kinds, by the runtime's own classification, which also decides
    % the kind libds's stream reports.
    %
:- func fault_kind(engine_error, fault_info) = event_kind.

fault_kind(Err, Info) = Kind :-
    Class = fault_class(Err),
    (
        Class = fc_type,
        Kind = type_error(Info)
    ;
        Class = fc_computation,
        ( if trap_of(Err, Trap) then
            Kind = computation_error(Trap, Info)
        else
            Kind = engine_error(unspecified_fault, Info)
        )
    ;
        Class = fc_bounds,
        ( if cap_of(Err, Cap) then
            Kind = bounds_error(Cap, Info)
        else
            Kind = engine_error(unspecified_fault, Info)
        )
    ;
        Class = fc_engine,
        Kind = engine_error(engine_fault_of(Err), Info)
    ).

    % A `fc_computation` fault's trap. Every such fault has one (`ds.fault`'s
    % `fault_class` and `expr_trap_kind`), so `fault_kind`'s other arm is
    % there for a class and a trap table that come to disagree.
    %
:- pred trap_of(engine_error::in, trap_kind::out) is semidet.

trap_of(ee_expr_fault(Fault), Trap) :-
    trap_number(expr_trap_kind(Fault), Trap).
    % The trap `ds.rfcs.trap_kind` records for it, so a host's report
    % and the recording of the same fault agree.
trap_of(ee_slot_invalid(_, _), domain).

:- pred trap_number(uint32::in, trap_kind::out) is semidet.

trap_number(1u32, divide_by_zero).
trap_number(2u32, domain).
trap_number(3u32, not_representable).

:- pred cap_of(engine_error::in, cap_name::out) is semidet.

cap_of(ee_contract_breach(Cap), cap_name_of(Cap)).
cap_of(ee_fire_budget_exceeded(_), max_fires_per_pump).

:- func cap_name_of(cap) = cap_name.

cap_name_of(cap_wm_max) = wm_max.
cap_name_of(cap_agenda) = agenda.
cap_name_of(cap_max_fires_per_pump) = max_fires_per_pump.
cap_name_of(cap_token_pool) = token_pool.
cap_name_of(cap_intern) = intern.
cap_name_of(cap_intern_bytes) = intern_bytes.
cap_name_of(cap_pump_wcet) = pump_wcet_ns.
cap_name_of(cap_node(_)) = node_capacity.
cap_name_of(cap_series) = series_capacity.
cap_name_of(cap_cache) = cache.
cap_name_of(cap_cache_bytes) = cache_bytes.
cap_name_of(cap_value_capacity) = value_capacity.

:- func engine_fault_of(engine_error) = engine_fault.

engine_fault_of(Err) = Fault :-
    ( if
        Err = ee_expr_fault(F),
        fault_number(expr_engine_fault(F), Numbered)
    then
        Fault = Numbered
    else if Err = ee_duplicate_order_key then
        Fault = order_key
    else
        Fault = unspecified_fault
    ).

:- pred fault_number(uint32::in, engine_fault::out) is semidet.

fault_number(1u32, artefact_lied).
fault_number(2u32, pattern_index).
fault_number(3u32, binding_order).
fault_number(4u32, order_key).
fault_number(6u32, allocation).
fault_number(7u32, pump_wcet).

:- func info_of(intern_table, fault_site) = fault_info.

info_of(I, fault_site(Activation, Schema, Slot, Bound, Node, Fact, Actual,
        Rule)) =
    fault_info(fault_rule_name(I, Rule),
        maybe.map_maybe(activation_of(I), Activation), Node,
        maybe.map_maybe(text_of(I), Schema), maybe.map_maybe(text_of(I), Slot),
        maybe.map_maybe(bound_of, Bound), Fact, Actual).

:- func bound_of(fault_bound) = bound.

bound_of(fault_bound(Limit, Observed)) =
    bound(uint64.cast_to_int(Limit), uint64.cast_to_int(Observed)).

%---------------------------------------------------------------------------%
% Names
%---------------------------------------------------------------------------%

:- func activation_of(intern_table, fire_id) = activation.

activation_of(I, fire_id(Timetag, Rule)) =
    activation(text_of(I, Rule), Timetag).

    % An issued call's correlation, which every call carries ([LCRS.3.1]).
    % The runtime resolves it before the call is issued
    % (`ds.exec.resolve_correlation`), so an event's is always
    % `correlated`: a `correlated_expr` reaching one is a runtime defect, and
    % thrown rather than reported as no correlation.
    %
:- func correlation_text(intern_table, correlation) = string.

correlation_text(I, correlated(Ref)) = text_of(I, Ref).
correlation_text(_, correlated_expr(_)) = _ :-
    require.error("mercury_ds.from_runtime.correlation_text: an issued "
        ++ "call carries an unresolved correlation ([LCRS.3.1])").

:- func text_of(intern_table, intern_ref) = string.

text_of(I, Ref) = ( if expand(I, Ref, String) then String else "" ).

:- func schema_text(intern_table, list(schema), schema_id) = string.

schema_text(I, Schemas, Id) = Name :-
    ( if list.find_first_match(has_id(Id), Schemas, Schema) then
        Name = text_of(I, schema_name_ref(Schema ^ s_name))
    else
        Name = ""
    ).

:- pred has_id(schema_id::in, schema::in) is semidet.

has_id(Id, Schema) :-
    Schema ^ s_id = Id.

%---------------------------------------------------------------------------%
% Values and facts
%---------------------------------------------------------------------------%

read_value(Interns, V) = S :-
    (
        V = int(I),
        S = int(I)
    ;
        V = float(F),
        S = float(F)
    ;
        V = str(Ref),
        ( if expand(Interns, Ref, Text) then
            S = text(Text)
        else
            require.error("mercury_ds.from_runtime.read_value: "
                ++ "a string the intern table does not hold")
        )
    ;
        V = text(Text),
        S = text(Text)
    ;
        V = bool(B),
        S = bool(B)
    ;
        V = bytes(Bytes),
        S = bytes(Bytes)
    ;
        V = json(J),
        S = json(J)
    ;
        V = fact_ref(Id),
        S = fact_ref(Id)
    ;
        V = null,
        S = null
    ;
        ( V = duration(_)
        ; V = time(_)
        ; V = ratio(_, _)
        ),
        require.error("mercury_ds.from_runtime.read_value: no slot holds "
            ++ string.string(V))
    ).

view_of(Interns, SchemaName, F) =
    fact_view(F ^ f_id, SchemaName,
        list.map(read_value(Interns), array.to_list(F ^ f_slots)),
        F ^ f_asserted, F ^ f_deadline).

%---------------------------------------------------------------------------%
% Load errors
%---------------------------------------------------------------------------%

load_failure(load_error(Kind, Offset, Atom, Clause, Reason)) =
        status_error(load_status(Kind), Detail) :-
    Where = ( if Offset = yes(O) then
                [" at offset " ++ string.int_to_string(O)]
              else
                [] ),
    What = ( if Atom = yes(A) then [" in " ++ A] else [] ),
    % [RDSC.9.5]: a body that fails to decode is refused naming the
    % decoder's reason as well as the atom and the offset.
    Why = ( if Reason = yes(R) then [": " ++ R] else [] ),
    Detail = string.append_list(["load refused [", clause_id_string(Clause),
        "]" | Where ++ What ++ Why]).

    % The runtime names each load failure for the code libds answers, and
    % this follows those names. Where a kind is the runtime's own
    % distinction, it takes the code of the libds check that refuses the
    % same artefact.
    %
:- func load_status(load_error_kind) = status.

load_status(lek_truncated) = dsc_truncated.
load_status(lek_version) = dsc_version.
load_status(lek_decode) = dsc_decode.
load_status(lek_semantic) = dsc_semantic.
load_status(lek_dangling) = dsc_dangling.
load_status(lek_decompress) = dsc_decompress.
load_status(lek_bad_first_atom) = dsc_bad_magic.
load_status(lek_empty_atom) = dsc_decode.
load_status(lek_malformed_field_number) = dsc_decode.
load_status(lek_unknown_inject) = fs_unknown_inject.
load_status(lek_retp_invalid) = retp_invalid.
load_status(lek_retp_index_oob) = retp_index_oob.
load_status(lek_pir_type) = dsc_semantic.
load_status(lek_pir_tms) = dsc_semantic.
load_status(lek_binding_mismatch) = bnd_dialect_mismatch.
load_status(lek_capability_absent(_)) = dsc_capability_absent.
load_status(lek_not_admitted(_, _)) = bnd_dialect_mismatch.
load_status(lek_contract_missing) = contract_missing.
load_status(lek_contract_invalid) = contract_invalid.
load_status(lek_contract_breach(_)) = contract_breach.
load_status(lek_no_portable_ir) = dsc_semantic.
load_status(lek_binding_incomplete) = bnd_incomplete.
load_status(lek_fn_not_found) = fn_not_found.   % [RDSC.4a.9.3]

%---------------------------------------------------------------------------%
% Bytes
%---------------------------------------------------------------------------%

bytes_bitmap(Bytes) =
    fill_bytes(Bytes, 0, bitmap.init(list.length(Bytes) * 8)).

:- func fill_bytes(list(uint8), int, bitmap) = bitmap.
:- mode fill_bytes(in, in, bitmap_di) = bitmap_uo is det.

fill_bytes([], _, BM) = BM.
fill_bytes([B | Bs], I, BM0) =
    fill_bytes(Bs, I + 1, BM0 ^ byte(I) := uint8.cast_to_int(B)).

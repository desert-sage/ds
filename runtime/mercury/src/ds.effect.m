% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.effect -- the effect spine: ordered emission, firing frames, the recorder.
%
% Record before act [IDSP.1.4], [RARC.5.8.12]: `acted/4`.
% The firing frame [formal/alloy/firing_event_frame.als]: `firing/3`.
% `seq` assigned only at append [formal/tla/stream_seq.tla]: `record/4`.
%-----------------------------------------------------------------------------%

:- module ds.effect.
:- interface.

:- import_module ds.action.
:- import_module ds.events.
:- import_module ds.id.
:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%
% Ordered emission
%-----------------------------------------------------------------------------%

    % An effect list under construction, append-only.
    %
:- type effect_log.

:- func empty_log = effect_log.

:- pred emit_event(stream_event::in, effect_log::in, effect_log::out) is det.
:- pred emit_action(action::in, effect_log::in, effect_log::out) is det.

    % A metric emission ([NMET.4.1]), where its event occurs ([NMET.6.1]).
    %
:- pred emit_metric(metric::in, effect_log::in, effect_log::out) is det.

    % A status for the pump to return. Every one is kept, in order; the shell
    % reports the first.
    %
:- pred emit_pump_status(pump_status::in, effect_log::in, effect_log::out)
    is det.

    % An action and the event that records it, in that order. Use this for any
    % action that has a stream event.
    %
:- pred acted(stream_event::in, action::in, effect_log::in, effect_log::out)
    is det.

    % The effects, in emission order.
    %
:- func log_effects(effect_log) = list(effect).

:- func log_length(effect_log) = int.

%-----------------------------------------------------------------------------%
% Firing frames
%-----------------------------------------------------------------------------%

    % One rule firing: the LHS facts event (`no` when the firing matched no live
    % fact), `RULE_FIRE_BEGIN`, the body in order, `RULE_FIRE_END`.
    %
:- func firing(fire_id, maybe(list(fact_id)), list(effect)) = list(effect).

:- pred emit_firing(fire_id::in, maybe(list(fact_id))::in, list(effect)::in,
                    effect_log::in, effect_log::out) is det.

%-----------------------------------------------------------------------------%
% The recorder
%-----------------------------------------------------------------------------%

:- type recorder.

:- func init_recorder = recorder.

    % Append one event and hand back its `seq`, the only source of one.
    %
:- pred record(stream_event::in, seq::out, recorder::in, recorder::out) is det.

    % The records, in `seq` order.
    %
:- func records(recorder) = list({seq, stream_event}).

    % The record count, which is also the next `seq`.
    %
:- func record_count(recorder) = int.

%-----------------------------------------------------------------------------%
% The replay gate
%-----------------------------------------------------------------------------%

    % Whether an event may be delivered to the engine on replay [RFCS.3.4].
    %
:- pred deliverable(stream_event::in) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module uint64.

%-----------------------------------------------------------------------------%

:- type effect_log
    --->    effect_log(
                el_rev :: list(effect),     % reverse emission order
                el_len :: int
            ).

empty_log = effect_log([], 0).

emit_event(E, !L) :-
    !L ^ el_rev := [eff_event(E) | !.L ^ el_rev],
    !L ^ el_len := !.L ^ el_len + 1.

emit_action(A, !L) :-
    !L ^ el_rev := [eff_action(A) | !.L ^ el_rev],
    !L ^ el_len := !.L ^ el_len + 1.

emit_metric(M, !L) :-
    !L ^ el_rev := [eff_metric(M) | !.L ^ el_rev],
    !L ^ el_len := !.L ^ el_len + 1.

emit_pump_status(S, !L) :-
    !L ^ el_rev := [eff_pump_status(S) | !.L ^ el_rev],
    !L ^ el_len := !.L ^ el_len + 1.

acted(E, A, !L) :-
    emit_event(E, !L),
    emit_action(A, !L).

log_effects(L) = list.reverse(L ^ el_rev).

log_length(L) = L ^ el_len.

%-----------------------------------------------------------------------------%

firing(Id, Lhs, Body) = Lhs_Events ++
    [eff_event(se_fire_begin(Id))] ++ Body ++ [eff_event(se_fire_end(Id))] :-
    (
        Lhs = yes(Facts),
        Lhs_Events = [eff_event(se_rule_lhs_facts(Id, Facts))]
    ;
        Lhs = no,
        Lhs_Events = []
    ).

emit_firing(Id, Lhs, Body, !L) :-
    list.foldl(emit_one, firing(Id, Lhs, Body), !L).

:- pred emit_one(effect::in, effect_log::in, effect_log::out) is det.

emit_one(eff_event(E), !L) :- emit_event(E, !L).
emit_one(eff_action(A), !L) :- emit_action(A, !L).
emit_one(eff_input(I), !L) :-
    !L ^ el_rev := [eff_input(I) | !.L ^ el_rev],
    !L ^ el_len := !.L ^ el_len + 1.
emit_one(eff_cache_expired(K), !L) :-
    !L ^ el_rev := [eff_cache_expired(K) | !.L ^ el_rev],
    !L ^ el_len := !.L ^ el_len + 1.
emit_one(eff_metric(M), !L) :- emit_metric(M, !L).
emit_one(eff_host_log(Level, Category, Message), !L) :-
    !L ^ el_rev := [eff_host_log(Level, Category, Message) | !.L ^ el_rev],
    !L ^ el_len := !.L ^ el_len + 1.
emit_one(eff_pump_status(S), !L) :- emit_pump_status(S, !L).

%-----------------------------------------------------------------------------%

:- type recorder
    --->    recorder(
                rec_rev  :: list({seq, stream_event}),
                rec_next :: uint64
            ).

init_recorder = recorder([], 0u64).

record(E, S, !R) :-
    N = !.R ^ rec_next,
    S = make_seq(N),
    !R ^ rec_rev := [{S, E} | !.R ^ rec_rev],
    !R ^ rec_next := N + 1u64.

records(R) = list.reverse(R ^ rec_rev).

record_count(R) = uint64.cast_to_int(R ^ rec_next).

%-----------------------------------------------------------------------------%

deliverable(E) :-
    event_class(E) = inject.

%-----------------------------------------------------------------------------%

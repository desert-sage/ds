% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.conform -- executable forms of the formal layer's properties.
%
% Not part of the engine, and nothing in the fire path calls it: a check the
% engine could act on is not a check.
%
% `ds.tms` is the activation refcount; this is the fixpoint over facts
% `formal/tla/tms_cascade.tla` defines, which decides whether the count has
% desynchronised. It trusts the engine's justification table, so it cannot see a
% derivation the engine should have made: that is `formal/souffle/`. It reads
% positive antecedents only; a `no` is judged by the TMS checker's negation
% evaluator.
%
% `orphans/3` is a positive control [RTCT.12.3]: the test suite asserts it fires
% on the orphan scenario.
%-----------------------------------------------------------------------------%

:- module ds.conform.
:- interface.

:- import_module bool.
:- import_module ds.id.
:- import_module ds.tms.
:- import_module ds.wm.
:- import_module list.

%-----------------------------------------------------------------------------%

    % The facts that survive the cascade to quiescence. A fact not TMS-linked
    % always survives.
    %
:- func quiescent_set(tms, wm) = list(fact_id).

    % Live facts the fixpoint says should not be: the executable form of
    % `iret_12_2__no_unsupported_forever`.
    %
:- func orphans(tms, wm) = list(fact_id).

:- pred supported_fixpoint(tms::in, wm::in, fact_id::in) is semidet.

%-----------------------------------------------------------------------------%
% Cross-checking the mechanism against the property
%-----------------------------------------------------------------------------%

    % Where the refcount and the support relation disagree.
    %
:- type desync
    --->    desync(
                dy_fact      :: fact_id,
                dy_count     :: int,
                dy_supported :: bool
            ).

:- func desyncs(tms, wm) = list(desync).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module set.

%-----------------------------------------------------------------------------%

quiescent_set(T, W) = set.to_sorted_list(Final) :-
    Live = set.list_to_set(live_facts(T, W)),
    settle(T, Live, Final).

    % The live derived facts and their antecedents: another fact cannot affect
    % the cascade.
    %
:- func live_facts(tms, wm) = list(fact_id).

live_facts(T, W) = Live :-
    Derived = derived_facts(T),
    Antecedents = list.condense(list.condense(
        list.map(justifications_of(T), Derived))),
    Live = list.filter(is_live(W), Derived ++ Antecedents).

:- func justifications_of(tms, fact_id) = list(list(fact_id)).

justifications_of(T, F) = justifications(T, F).

:- pred is_live(wm::in, fact_id::in) is semidet.

is_live(W, F) :-
    lookup_fact(W, F, _).

:- pred settle(tms::in, set(fact_id)::in, set(fact_id)::out) is det.

settle(T, Set0, Final) :-
    Set = set.filter(survives(T, Set0), Set0),
    Before = set.count(Set0) : int,
    After = set.count(Set) : int,
    ( if After = Before then
        Final = Set
    else
        settle(T, Set, Final)
    ).

:- pred survives(tms::in, set(fact_id)::in, fact_id::in) is semidet.

survives(T, Set, Fact) :-
    ( if is_derived(T, Fact) then
        list.member(Antecedents, justifications(T, Fact)),
        list.all_true(in_set(Set), Antecedents)
    else
        true
    ).

:- pred in_set(set(fact_id)::in, fact_id::in) is semidet.

in_set(Set, F) :-
    set.contains(Set, F).

%-----------------------------------------------------------------------------%

orphans(T, W) = Orphans :-
    Surviving = set.list_to_set(quiescent_set(T, W)),
    Orphans = list.filter(is_orphan(W, Surviving), derived_facts(T)).

:- pred is_orphan(wm::in, set(fact_id)::in, fact_id::in) is semidet.

is_orphan(W, Surviving, Fact) :-
    is_live(W, Fact),
    not set.contains(Surviving, Fact).

supported_fixpoint(T, W, Fact) :-
    set.contains(set.list_to_set(quiescent_set(T, W)), Fact).

%-----------------------------------------------------------------------------%

desyncs(T, W) = list.filter_map(disagreement(T, W), derived_facts(T)).

:- func disagreement(tms, wm, fact_id) = desync is semidet.

disagreement(T, W, Fact) = desync(Fact, Count, Supported) :-
    is_live(W, Fact),
    Count = justif_count(T, Fact),
    ( if supported_fixpoint(T, W, Fact) then
        Supported = yes
    else
        Supported = no
    ),
    % A positive count with no support is an orphan; support with no count, a
    % fact the refcount is about to retract though still justified.
    ( Count > 0, Supported = no
    ; Count =< 0, Supported = yes
    ).

%-----------------------------------------------------------------------------%

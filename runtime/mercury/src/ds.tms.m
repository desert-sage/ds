% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.tms -- truth maintenance: the liveness of derived facts.
%
% The engine is a refcount over activations ([IRET.12]). The check is the count's
% obligation, a fixpoint over facts (`ds.conform`, `formal/tla/tms_cascade.tla`): the
% antecedent sets kept here exist for it and drive nothing.
%
% A match that ends inside its own firing justifies nothing after ([LLOG.15.1],
% [IRET.12.2]). So a firing's `logical` emits are justified at the end of their action,
% once it has settled (`defer`, `resolve_deferred`), and a fact made after the match
% ended is not entered against it.
%-----------------------------------------------------------------------------%

:- module ds.tms.
:- interface.

:- import_module ds.id.
:- import_module ds.token.
:- import_module bool.
:- import_module uint32.
:- import_module list.

%-----------------------------------------------------------------------------%

:- type tms.

:- func init_tms = tms.

    % A firing activation derived a fact: its token is the justifier [RLOW.7.1.4].
    %
:- pred justify(activation::in, fact_id::in, tms::in, tms::out) is det.

    % An activation's match no longer holds. Returns the derived facts whose count
    % reached zero, for the engine's cascade to retract.
    %
:- pred activation_ended(activation::in, list(fact_id)::out,
                         tms::in, tms::out) is det.

    % The tick's turnover carried an activation's match to a new token ([IRET.19.5]):
    % the successor takes over what the old one justified, and no count moves
    % ([IRET.12.2]).
    %
:- pred carried_over(activation::in, activation::in, tms::in, tms::out) is det.

    % Forget a fact that has left working memory for any reason.
    %
:- pred forget_fact(fact_id::in, tms::in, tms::out) is det.

%-----------------------------------------------------------------------------%
% A firing ([LLOG.15.1], [IRET.12.2])
%-----------------------------------------------------------------------------%

    % The activation about to fire.
    %
:- pred begin_firing(activation::in, tms::in, tms::out) is det.

:- pred end_firing(tms::in, tms::out) is det.

    % A `logical` fact the firing's current action asserted, to be justified
    % by the firing activation once the action has settled. `Made` is `no`
    % for a no-op re-assert, whose fact stood already.
    %
:- pred defer(fact_id::in, bool::in, tms::in, tms::out) is det.

    % The current action has settled. While the firing activation stands, the
    % deferred facts are justified by it and `Unjustified` is empty. Once it
    % has ended, nothing is entered against it, and `Unjustified` is the facts
    % to retract as they are made: each new (`Made`) and held by no other
    % justification. Either way nothing stays deferred.
    %
:- pred resolve_deferred(list(fact_id)::out, tms::in, tms::out) is det.

    % Drop what the current action deferred: the action did not happen (a
    % node cap put the engine back, `ds.engine.settle_actions`).
    %
:- pred drop_deferred(tms::in, tms::out) is det.

%-----------------------------------------------------------------------------%
% Reading
%-----------------------------------------------------------------------------%

:- func justif_count(tms, fact_id) = int.

:- pred is_derived(tms::in, fact_id::in) is semidet.

    % Every justification targeting a fact, as its antecedent sets, for the check.
    %
:- func justifications(tms, fact_id) = list(list(fact_id)).

:- func derived_facts(tms) = list(fact_id).

    % The terminal of every live activation that justifies a fact, one per
    % justification.
    %
:- func justifying_terminals(tms, fact_id) = list(uint32).

    % Every live activation that justifies something: its terminal, its token's facts
    % in pattern order, and the facts it derived, in activation-key order. For the check
    % (the TMS checker's negation evaluator).
    %
:- func live_justifications(tms) = list({uint32, list(fact_id), list(fact_id)}).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module maybe.
:- import_module pair.
:- import_module uint64.
:- import_module version_hash_table.

%-----------------------------------------------------------------------------%

:- type tms
    --->    tms(
                tm_count  :: version_hash_table(fact_id, int),
                            % derived fact -> live supporting activations

                tm_justif :: version_hash_table(fact_id, list(list(fact_id))),
                            % Derived fact -> antecedent sets, in creation order.
                            % Hashed, as `tm_count` is, for [LNLS.4.7].

                tm_derived :: version_hash_table(activation_key, list(fact_id)),
                            % activation key -> the facts it derived

                tm_firing  :: maybe(firing)
                            % `no` between firings.
            ).

    % The activation, whether an action of the firing has ended it, and the current
    % action's deferred facts, oldest first, each with whether that action made it.
    %
:- type firing
    --->    firing(
                fi_activation :: activation,
                fi_ended      :: bool,
                fi_deferred   :: list({fact_id, bool})
            ).

init_tms = tms(version_hash_table.init_default(fact_id_hash),
    version_hash_table.init_default(fact_id_hash),
    version_hash_table.init_default(activation_key_hash), no).

:- pred activation_key_hash(activation_key::in, int::out) is det.

activation_key_hash(activation_key(Terminal, Facts), Hash) :-
    H = fact_tuple_hash(uint32.cast_to_uint64(Terminal), Facts),
    Hash = uint64.cast_to_int(H >> 1).

%-----------------------------------------------------------------------------%

justify(Activation, Derived, !T) :-
    Prior = ( if version_hash_table.search(!.T ^ tm_count, Derived, N) then N
              else 0 ),
    !T ^ tm_count := version_hash_table.set(!.T ^ tm_count, Derived, Prior + 1),

    Antecedents = Activation ^ ac_token ^ t_facts,
    Sets = ( if version_hash_table.search(!.T ^ tm_justif, Derived, S) then S
             else [] ),
    !T ^ tm_justif := version_hash_table.set(!.T ^ tm_justif, Derived,
        Sets ++ [Antecedents]),

    AKey = key_of(Activation),
    Derived0 = ( if version_hash_table.search(!.T ^ tm_derived, AKey, D) then D
                 else [] ),
    !T ^ tm_derived := version_hash_table.set(!.T ^ tm_derived, AKey,
        Derived0 ++ [Derived]).

    % An activation's identity: the exact pair, without the timetag, since two
    % activations of one terminal over one tuple are the same match re-created.
    %
:- type activation_key
    --->    activation_key(uint32, list(fact_id)).

:- func key_of(activation) = activation_key.

key_of(activation(Terminal, token(Facts, _))) =
    activation_key(node_id_value(Terminal), Facts).

%-----------------------------------------------------------------------------%

activation_ended(Activation, Unsupported, !T) :-
    AKey = key_of(Activation),
    % [LLOG.15.1]: noted whether or not it has justified anything yet.
    ( if
        !.T ^ tm_firing = yes(F),
        key_of(F ^ fi_activation) = AKey
    then
        !T ^ tm_firing := yes(F ^ fi_ended := yes)
    else
        true
    ),
    ( if version_hash_table.search(!.T ^ tm_derived, AKey, Facts) then
        !T ^ tm_derived := version_hash_table.delete(!.T ^ tm_derived, AKey),
        list.foldl2(decrement, Facts, [], Unsupported, !T)
    else
        Unsupported = []
    ).

begin_firing(Activation, !T) :-
    !T ^ tm_firing := yes(firing(Activation, no, [])).

end_firing(!T) :-
    !T ^ tm_firing := no.

defer(Fact, Made, !T) :-
    ( if !.T ^ tm_firing = yes(F) then
        !T ^ tm_firing := yes(F ^ fi_deferred := F ^ fi_deferred ++ [{Fact, Made}])
    else
        % No `logical` emit is made outside a firing.
        true
    ).

resolve_deferred(Unjustified, !T) :-
    ( if !.T ^ tm_firing = yes(F) then
        !T ^ tm_firing := yes(F ^ fi_deferred := []),
        (
            F ^ fi_ended = no,
            Unjustified = [],
            list.foldl(
                ( pred({Fact, _}::in, T0::in, T1::out) is det :-
                    justify(F ^ fi_activation, Fact, T0, T1) ),
                F ^ fi_deferred, !T)
        ;
            F ^ fi_ended = yes,
            % A no-op made no fact: the standing fact keeps whatever holds it.
            Counts = !.T,
            Unjustified = list.filter_map(
                ( func({Fact, Made}) = Fact is semidet :-
                    Made = yes,
                    justif_count(Counts, Fact) = 0 ),
                F ^ fi_deferred)
        )
    else
        Unjustified = []
    ).

drop_deferred(!T) :-
    ( if !.T ^ tm_firing = yes(F) then
        !T ^ tm_firing := yes(F ^ fi_deferred := [])
    else
        true
    ).

carried_over(Old, New, !T) :-
    OldKey = key_of(Old),
    ( if version_hash_table.search(!.T ^ tm_derived, OldKey, Facts) then
        !T ^ tm_derived := version_hash_table.set(
            version_hash_table.delete(!.T ^ tm_derived, OldKey),
            key_of(New), Facts),
        OldSet = Old ^ ac_token ^ t_facts,
        NewSet = New ^ ac_token ^ t_facts,
        list.foldl(replace_antecedents(OldSet, NewSet), Facts, !T)
    else
        true
    ).

:- pred replace_antecedents(list(fact_id)::in, list(fact_id)::in, fact_id::in,
                            tms::in, tms::out) is det.

replace_antecedents(OldSet, NewSet, Fact, !T) :-
    ( if version_hash_table.search(!.T ^ tm_justif, Fact, Sets) then
        !T ^ tm_justif := version_hash_table.set(!.T ^ tm_justif, Fact,
            replace_first(OldSet, NewSet, Sets))
    else
        true
    ).

    % One justification per derivation, so one set is the old activation's.
    %
:- func replace_first(list(fact_id), list(fact_id), list(list(fact_id)))
    = list(list(fact_id)).

replace_first(_, _, []) = [].
replace_first(Old, New, [S | Ss]) =
    ( if S = Old then [New | Ss] else [S | replace_first(Old, New, Ss)] ).

:- pred decrement(fact_id::in, list(fact_id)::in, list(fact_id)::out,
                  tms::in, tms::out) is det.

decrement(Fact, !Unsupported, !T) :-
    ( if version_hash_table.search(!.T ^ tm_count, Fact, N) then
        Left = N - 1,
        !T ^ tm_count := version_hash_table.set(!.T ^ tm_count, Fact, Left),
        ( if Left =< 0 then
            !:Unsupported = !.Unsupported ++ [Fact]
        else
            % [IRET.12.3].
            true
        )
    else
        true
    ).

forget_fact(Fact, !T) :-
    !T ^ tm_count := version_hash_table.delete(!.T ^ tm_count, Fact),
    !T ^ tm_justif := version_hash_table.delete(!.T ^ tm_justif, Fact).
        % `tm_derived`'s entry goes when the activation itself ends.

%-----------------------------------------------------------------------------%

justif_count(T, Fact) =
    ( if version_hash_table.search(T ^ tm_count, Fact, N) then N else 0 ).

is_derived(T, Fact) :-
    version_hash_table.search(T ^ tm_justif, Fact, _).

justifications(T, Fact) =
    ( if version_hash_table.search(T ^ tm_justif, Fact, S) then S else [] ).

    % Ascending by id: a hash table's order is not one to expose.
    %
derived_facts(T) = list.map(make_fact_id, list.sort(
    version_hash_table.fold(
        (func(F, _, Acc) = [fact_id_value(F) | Acc]),
        T ^ tm_justif, []))).

    % In activation-key order, for an integrator's read.
    %
justifying_terminals(T, Fact) =
    list.filter_map(
        (func(activation_key(Terminal, _) - Facts) = Terminal is semidet :-
            list.member(Fact, Facts)),
        list.sort(version_hash_table.fold(
            (func(K, V, Acc) = [K - V | Acc]), T ^ tm_derived, []))).

live_justifications(T) =
    list.map(
        (func(activation_key(Terminal, Token) - Derived) =
            {Terminal, Token, Derived}),
        list.sort(version_hash_table.fold(
            (func(K, V, Acc) = [K - V | Acc]), T ^ tm_derived, []))).

%-----------------------------------------------------------------------------%

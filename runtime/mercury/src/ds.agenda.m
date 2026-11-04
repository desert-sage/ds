% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.agenda -- conflict resolution: what fires next.
%
% Two keys, terminal ordinal then creation timetag [LDET.5.4, LDET.5.5]. The
% order is `order_key`'s own ordering, so the agenda is a map and `map.min_key`
% is the selection. A map holds one entry per key, so `enqueue` fails on a
% duplicate.
%
% Refraction is a veto at selection: the chosen activation is destroyed without
% firing [LDET.5.3, IRET.11.3], not re-queued.
%-----------------------------------------------------------------------------%

:- module ds.agenda.
:- interface.

:- import_module ds.id.
:- import_module ds.rules.
:- import_module ds.token.
:- import_module list.
:- import_module set.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%
% The agenda
%-----------------------------------------------------------------------------%

:- type agenda.

:- func init_agenda = agenda.

    % Failure is a defect in this runtime, reported as `ee_duplicate_order_key`:
    % `Rete/NetworkOrderKeep.idr` proves the key unique after any history
    % ([RARC.5.4.9]).
    %
:- pred enqueue(order_key::in, activation::in, agenda::in, agenda::out)
    is semidet.

    % Remove an activation no longer matched. Fails on a key not present.
    %
:- pred withdraw(order_key::in, agenda::in, agenda::out) is semidet.

    % The next activation, without removing it.
    %
:- pred peek(agenda::in, order_key::out, activation::out) is semidet.

:- func agenda_count(agenda) = int.

%-----------------------------------------------------------------------------%
% Refraction
%-----------------------------------------------------------------------------%

    % The per-terminal fired set [IRET.11.3].
    %
:- type refraction.

:- func init_refraction = refraction.

    % Keyed on the terminal and the token's fact ids, not the identity key: a
    % meaningful change mints a fresh `fact_id` [LFAC.2.5.3].
    %
    % Synthetic facts are left out of the key: `$ClockTick` gets a fresh
    % `fact_id` every pump, and with it the rule would fire every pump. The set
    % is passed in because it is a property of the loaded program.
    %
:- pred is_refracted(refraction::in, set(uint64)::in, activation::in)
    is semidet.

:- pred latch(set(uint64)::in, activation::in,
              refraction::in, refraction::out) is det.

    % The token was removed, so its identity no longer refracts ([IRET.11.3.2]):
    % only that identity, since an unrelated change releases nothing.
    %
:- func forget(set(uint64), activation, refraction) = refraction.

    % Diagnostic only.
    %
:- func refraction_size(refraction) = int.

    % [NDBG.4.3]'s listing, in hash-table order;
    % `ds.engine.engine_refracted_activations` sorts it.
    %
:- func refraction_entries(refraction) = list({uint32, list(fact_id)}).

%-----------------------------------------------------------------------------%
% Selection
%-----------------------------------------------------------------------------%

:- type selection
    --->    fire(order_key, activation)
    ;       nothing_to_fire.

    % The next activation to fire. Refracted ones are removed and discarded on
    % the way.
    %
:- pred select(refraction::in, set(uint64)::in, selection::out,
               agenda::in, agenda::out) is det.

    % `select`, not applying refraction at the terminals in `Guarded`, whose rule
    % has a maturity guard: the engine must read the guard first ([LTIM.2.5.1]),
    % since a condition gone false ends its match.
    %
:- pred select_guarded(refraction::in, set(uint64)::in, set(uint32)::in,
                       selection::out, agenda::in, agenda::out) is det.

    % `select`, counting the activations it discarded.
    %
:- pred select_counting(refraction::in, set(uint64)::in, selection::out,
                        int::out,
                        agenda::in, agenda::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module map.
:- import_module pair.
:- import_module unit.
:- import_module version_hash_table.

%-----------------------------------------------------------------------------%

:- type agenda
    --->    agenda(map(order_key, activation)).

init_agenda = agenda(map.init).

enqueue(Key, Activation, agenda(!.M), agenda(!:M)) :-
    map.insert(Key, Activation, !M).

withdraw(Key, agenda(!.M), agenda(!:M)) :-
    map.remove(Key, _, !M).

peek(agenda(M), Key, Activation) :-
    Key = map.min_key(M),
    map.search(M, Key, Activation).

agenda_count(agenda(M)) = map.count(M).

%-----------------------------------------------------------------------------%

:- type refraction
    --->    refraction(map(uint32, version_hash_table(list(fact_id), unit))).
            % terminal node_id -> the fact tuples it has fired on, hashed since
            % [LNLS.4.7] makes a removal O(1) amortized.

init_refraction = refraction(map.init).

:- pred tuple_hash(list(fact_id)::in, int::out) is det.

tuple_hash(Ids, uint64.cast_to_int(fact_tuple_hash(0u64, Ids) >> 1)).

is_refracted(refraction(M), Synth, activation(Terminal, Token)) :-
    map.search(M, node_id_value(Terminal), Fired),
    version_hash_table.search(Fired, refraction_key(Synth, Token), _).

latch(Synth, activation(Terminal, Token), refraction(M0), refraction(M)) :-
    Key = node_id_value(Terminal),
    Prior = ( if map.search(M0, Key, S) then S
              else version_hash_table.init_default(tuple_hash) ),
    M = map.set(M0, Key,
        version_hash_table.set(Prior, refraction_key(Synth, Token), unit)).

    % The token's fact tuple, positional, with the synthetic facts removed.
    %
:- func refraction_key(set(uint64), token) = list(fact_id).

refraction_key(Synth, Token) = Key :-
    Authored = list.negated_filter(
        (pred(F::in) is semidet :- set.contains(Synth, fact_id_value(F))),
        Token ^ t_facts),
    (
        % A wholly synthetic match keeps its tuple: as `[]`, its first firing
        % would latch every later one at the terminal.
        Authored = [],
        Key = Token ^ t_facts
    ;
        Authored = [_ | _],
        Key = Authored
    ).

forget(Synth, activation(Terminal, Token), refraction(M0)) = refraction(M) :-
    Key = node_id_value(Terminal),
    ( if map.search(M0, Key, Fired0) then
        M = map.set(M0, Key,
            version_hash_table.delete(Fired0, refraction_key(Synth, Token)))
    else
        M = M0
    ).

refraction_size(refraction(M)) =
    list.foldl(func(S, Acc) = Acc + version_hash_table.num_occupants(S),
        map.values(M), 0).

refraction_entries(refraction(M)) =
    list.condense(list.map(
        ( func(Terminal - Fired) =
            list.map((func(Tuple - _) = {Terminal, Tuple}),
                version_hash_table.to_assoc_list(Fired)) ),
        map.to_assoc_list(M))).

%-----------------------------------------------------------------------------%

select(Refraction, Synth, Selection, !Agenda) :-
    select_counting(Refraction, Synth, Selection, _, !Agenda).

select_guarded(Refraction, Synth, Guarded, Selection, !Agenda) :-
    select_loop(Refraction, Synth, Guarded, Selection, 0, _, !Agenda).

select_counting(Refraction, Synth, Selection, Suppressed, !Agenda) :-
    select_loop(Refraction, Synth, set.init, Selection, 0, Suppressed, !Agenda).

:- pred select_loop(refraction::in, set(uint64)::in, set(uint32)::in,
                    selection::out, int::in, int::out,
                    agenda::in, agenda::out) is det.

select_loop(Refraction, Synth, Guarded, Selection, !Suppressed, !Agenda) :-
    ( if peek(!.Agenda, Key, Activation) then
        ( if withdraw(Key, !.Agenda, Rest) then
            !:Agenda = Rest
        else
            % Unreachable: `peek` found the key.
            true
        ),
        ( if
            not set.contains(Guarded,
                node_id_value(Activation ^ ac_terminal)),
            is_refracted(Refraction, Synth, Activation)
        then
            !:Suppressed = !.Suppressed + 1,
            select_loop(Refraction, Synth, Guarded, Selection, !Suppressed,
                !Agenda)
        else
            Selection = fire(Key, Activation)
        )
    else
        Selection = nothing_to_fire
    ).

%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% field_order_walk -- [RCTS.1.2.19]'s walk of a container's bytes, for both
% suites that judge it: `test_behave` over the Mercury runtime's recording
% (`field_order`), `test_conformance` over this compiler's `.dsc`
% (`dsc_field_order`).
%
% [RFCS.19.5]: every message's fields in ascending field-number order, nested
% messages and fact bodies included, and a field that is not repeated at most
% once.
%
% The fields come from the table `field_order.py --table` derives from
% `proto/` (staged as `behaviour/FIELD_ORDER_TABLE.json`); the walk is this
% module's own, independent of libds's harness.
%-----------------------------------------------------------------------------%

:- module field_order_walk.
:- interface.

:- import_module ds.
:- import_module ds.json.

:- import_module bool.
:- import_module list.
:- import_module map.

    % One field of a message, as the table gives it: whether it is repeated,
    % and its type: "" for a scalar or an enum, "@fact" for a fact body, or
    % the name of the message it holds.
    %
:- type fo_field
    --->    fo_field(fo_repeated :: bool, fo_type :: string).

:- type fo_table == map(string, map(int, fo_field)).

    % The table as `field_order.py`'s `table_json` writes it: `root`, and
    % `messages`, each a list of [number, repeated, type]. Fails when it is
    % not that shape or names no message `root`.
    %
:- pred fo_table(json::in, string::out, fo_table::out) is semidet.

    % `expect.atoms`: a list of message names.
    %
:- pred fo_wanted_atoms(json_members::in, list(string)::out) is semidet.

:- type fo_verdict
    --->    fo_ok
    ;       fo_refused(string).

    % fo_judge(Root, Table, Want, Noun, Bytes): the container `Bytes`,
    % walked from the message `Root`, judged as [RCTS.1.2.19] judges it: it
    % holds an atom of every name `Want` lists, the walk refuses the copy
    % with two fields of one atom body swapped, and then the walk finds
    % nothing in `Bytes` itself. `Noun` names the container in a refusal
    % ("recording", "artefact").
    %
:- func fo_judge(string, fo_table, list(string), string, list(uint8))
    = fo_verdict.

    % Every place `Bytes` breaks [RFCS.19.5]'s order or its at-most-once
    % rule, in container order, walked from the message `Root`.
    %
:- func fo_walk(fo_table, string, list(uint8)) = list(string).

    % `Bytes` with the first two fields of the first atom body that has two
    % of different numbers swapped in place: every length is kept, and that
    % body now breaks ascending order. `field_order.py`'s `swapped`.
    %
:- pred swapped_stream(list(uint8)::in, list(uint8)::out) is semidet.

    % {atom number, body start, body end} of each top-level atom, in order,
    % up to the first frame that does not walk: `stream_edit.py`'s `atoms`.
    %
:- func stream_atoms(list(uint8), int) = list({int, int, int}).

    % A protobuf varint at `Pos`: its value and the position after it.
    %
:- pred byte_varint(list(uint8)::in, int::in, int::in, int::in,
    int::out, int::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module int64.
:- import_module maybe.
:- import_module pair.
:- import_module string.
:- import_module uint8.

fo_table(TJ, Root, Table) :-
    TJ = j_object(T),
    lookup_member(T, "root", RJ),
    RJ = j_string(Root),
    lookup_member(T, "messages", MJ),
    MJ = j_object(Ms),
    list.map(fo_message, members(Ms), Pairs),
    Table = map.from_assoc_list(Pairs),
    map.contains(Table, Root).

:- pred fo_message(pair(string, json)::in,
    pair(string, map(int, fo_field))::out) is semidet.

fo_message(Name - FieldsJ, Name - Fields) :-
    FieldsJ = j_array(Fs),
    list.map(fo_entry, Fs, Entries),
    Fields = map.from_assoc_list(Entries).

:- pred fo_entry(json::in, pair(int, fo_field)::out) is semidet.

fo_entry(J, Num - fo_field(Repeated, Type)) :-
    J = j_array([j_int(N), j_bool(Repeated), j_string(Type)]),
    Num = int64.cast_to_int(N).

fo_wanted_atoms(Expect, Want) :-
    lookup_member(Expect, "atoms", AJ),
    AJ = j_array(As),
    list.map((pred(J::in, S::out) is semidet :- J = j_string(S)), As, Want).

fo_judge(Root, Table, Want, Noun, Bytes) = Verdict :-
    Held = fo_atom_names(Table, Bytes),
    Absent = list.filter((pred(A::in) is semidet :- not list.member(A, Held)),
        Want),
    ( if Absent = [_ | _] then
        Verdict = fo_refused("the " ++ Noun ++ " holds no "
            ++ string.join_list(", ", Absent)
            ++ " atom, so the walk is not shown to reach it")
    else if
        swapped_stream(Bytes, Probe),
        fo_walk(Table, Root, Probe) = [_ | _]
    then
        Found = fo_walk(Table, Root, Bytes),
        (
            Found = [],
            Verdict = fo_ok
        ;
            Found = [_ | _],
            Verdict = fo_refused(string.format(
                "%d place(s) out of [RFCS.19.5]'s order, first: %s",
                [i(list.length(Found)),
                 s(string.join_list("; ", list.take_upto(5, Found)))]))
        )
    else
        Verdict = fo_refused("the walk did not refuse the " ++ Noun
            ++ " with two fields of one atom body swapped, so it is not "
            ++ "shown to fire")
    ).

    % The message name of every atom in `Bytes`, by the `Atom` oneof's field
    % numbers: `field_order.py`'s `atom_names`.
    %
:- func fo_atom_names(fo_table, list(uint8)) = list(string).

fo_atom_names(Table, Bytes) = Names :-
    ( if map.search(Table, "Atom", Oneof) then
        Names = list.filter_map(
            ( func({Num, _, _}) = Name is semidet :-
                map.search(Oneof, Num, fo_field(_, Name))
            ), stream_atoms(Bytes, 0))
    else
        Names = []
    ).

fo_walk(Table, Root, Bytes) = list.reverse(Rev) :-
    fo_walk_message(Table, Root, Bytes, 0, list.length(Bytes), Root,
        string.to_lower(Root), 0, 0, [], Rev).

    % fo_walk_message(Table, Root, Bytes, Pos, End, Msg, Path, Prev, Nth,
    %   !Out): the fields of message `Msg` from `Pos` to `End`, the highest
    % field number met so far being `Prev`, and `Nth` the index of the next
    % atom when `Msg` is the root.
    %
:- pred fo_walk_message(fo_table::in, string::in, list(uint8)::in, int::in,
    int::in, string::in, string::in, int::in, int::in,
    list(string)::in, list(string)::out) is det.

fo_walk_message(Table, Root, Bytes, Pos, End, Msg, Path, Prev, Nth, !Out) :-
    ( if Pos >= End then
        true
    else if byte_varint(Bytes, Pos, 0, 0, Key, At) then
        Num = Key >> 3,
        Wire = Key /\ 7,
        ( if
            map.search(Table, Msg, Fields),
            map.search(Fields, Num, Field)
        then
            MaybeField = yes(Field)
        else
            MaybeField = no
        ),
        ( if Num < Prev then
            !:Out = [string.format("%s: field %d after field %d",
                [s(Path), i(Num), i(Prev)]) | !.Out]
        else if Num = Prev, not MaybeField = yes(fo_field(yes, _)) then
            !:Out = [string.format("%s: field %d twice, and %s.%d is not "
                ++ "repeated", [s(Path), i(Num), s(Msg), i(Num)]) | !.Out]
        else
            true
        ),
        ( if fo_span(Bytes, At, End, Wire, VStart, VEnd) then
            (
                MaybeField = no,
                !:Out = [string.format("%s: field %d is not a field of %s",
                    [s(Path), i(Num), s(Msg)]) | !.Out],
                Nth1 = Nth
            ;
                MaybeField = yes(fo_field(_, Type)),
                ( if Type = "" then
                    Nth1 = Nth
                else if Wire \= 2 then
                    !:Out = [string.format("%s: field %d holds a %s with "
                        ++ "wire type %d", [s(Path), i(Num), s(Type), i(Wire)])
                        | !.Out],
                    Nth1 = Nth
                else if Type = "@fact" then
                    fo_walk_fact(Bytes, VStart, VEnd,
                        Path ++ " > " ++ Msg ++ ".fact", 0, !Out),
                    Nth1 = Nth
                else
                    ( if Msg = Root then
                        Sub = "atom " ++ string.int_to_string(Nth),
                        Nth1 = Nth + 1
                    else if Msg = "Atom" then
                        Sub = Path ++ " (" ++ Type ++ ")",
                        Nth1 = Nth
                    else
                        Sub = Path ++ " > " ++ Msg ++ "."
                            ++ string.int_to_string(Num),
                        Nth1 = Nth
                    ),
                    fo_walk_message(Table, Root, Bytes, VStart, VEnd, Type,
                        Sub, 0, 0, !Out)
                )
            ),
            fo_walk_message(Table, Root, Bytes, VEnd, End, Msg, Path,
                int.max(Prev, Num), Nth1, !Out)
        else
            !:Out = [string.format("%s: field %d (wire type %d) does not "
                ++ "decode at byte %d", [s(Path), i(Num), i(Wire), i(At)])
                | !.Out]
        )
    else
        !:Out = [string.format("%s: the key at byte %d does not decode",
            [s(Path), i(Pos)]) | !.Out]
    ).

    % A fact body: one scalar field per slot, none repeated, so each field
    % number is greater than the one before.
    %
:- pred fo_walk_fact(list(uint8)::in, int::in, int::in, string::in, int::in,
    list(string)::in, list(string)::out) is det.

fo_walk_fact(Bytes, Pos, End, Path, Prev, !Out) :-
    ( if Pos >= End then
        true
    else if byte_varint(Bytes, Pos, 0, 0, Key, At) then
        Num = Key >> 3,
        ( if Num =< Prev then
            !:Out = [string.format("%s: slot field %d after field %d",
                [s(Path), i(Num), i(Prev)]) | !.Out]
        else
            true
        ),
        ( if fo_span(Bytes, At, End, Key /\ 7, _, VEnd) then
            fo_walk_fact(Bytes, VEnd, End, Path, int.max(Prev, Num), !Out)
        else
            !:Out = [string.format("%s: slot field %d does not decode at "
                ++ "byte %d", [s(Path), i(Num), i(At)]) | !.Out]
        )
    else
        !:Out = [string.format("%s: the key at byte %d does not decode",
            [s(Path), i(Pos)]) | !.Out]
    ).

    % Where the value of a field whose key ends at `At` starts and ends;
    % fails when it runs past `End` or its wire type is not one proto3
    % writes.
    %
:- pred fo_span(list(uint8)::in, int::in, int::in, int::in, int::out,
    int::out) is semidet.

fo_span(Bytes, At, End, Wire, VStart, VEnd) :-
    (
        Wire = 0,
        VStart = At,
        byte_varint(Bytes, At, 0, 0, _, VEnd)
    ;
        Wire = 1,
        VStart = At,
        VEnd = At + 8
    ;
        Wire = 2,
        byte_varint(Bytes, At, 0, 0, Len, VStart),
        VEnd = VStart + Len
    ;
        Wire = 5,
        VStart = At,
        VEnd = At + 4
    ),
    VEnd =< End.

swapped_stream(Bytes, Out) :-
    list.find_first_map(first_two_fields(Bytes), stream_atoms(Bytes, 0),
        {A, B, C}),
    list.det_split_list(C, Bytes, UpToC, Tail),
    list.det_split_list(B, UpToC, UpToB, Second),
    list.det_split_list(A, UpToB, Head, First),
    Out = Head ++ Second ++ First ++ Tail.

:- pred first_two_fields(list(uint8)::in, {int, int, int}::in,
    {int, int, int}::out) is semidet.

first_two_fields(Bytes, {_, Start, End}, {Start, B, C}) :-
    byte_varint(Bytes, Start, 0, 0, K1, At1),
    fo_span(Bytes, At1, End, K1 /\ 7, _, B),
    byte_varint(Bytes, B, 0, 0, K2, At2),
    K1 >> 3 \= K2 >> 3,
    fo_span(Bytes, At2, End, K2 /\ 7, _, C).

stream_atoms(Bytes, Pos) = Atoms :-
    ( if
        list.index0(Bytes, Pos, 0x0Au8),
        byte_varint(Bytes, Pos + 1, 0, 0, OuterLen, Inner),
        End = Inner + OuterLen,
        byte_varint(Bytes, Inner, 0, 0, Key, LenAt),
        Key /\ 7 = 2,
        byte_varint(Bytes, LenAt, 0, 0, BodyLen, Body),
        Body + BodyLen =< End,
        End =< list.length(Bytes)
    then
        Atoms = [{Key >> 3, Body, Body + BodyLen} | stream_atoms(Bytes, End)]
    else
        Atoms = []
    ).

byte_varint(Bytes, Pos, Shift, Acc, Value, Next) :-
    Shift < 63,
    list.index0(Bytes, Pos, B),
    Acc1 = Acc \/ (uint8.cast_to_int(B /\ 0x7Fu8) << Shift),
    ( if B /\ 0x80u8 = 0u8 then
        Value = Acc1,
        Next = Pos + 1
    else
        byte_varint(Bytes, Pos + 1, Shift + 7, Acc1, Value, Next)
    ).

%-----------------------------------------------------------------------------%
:- end_module field_order_walk.
%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.json -- the Json term.
%
% An object's members are stored sorted by key, so Mercury's `=` is Json's deep
% structural equality and the canonical order is the representation. A `map`
% would not do: a 234-tree's shape depends on insertion order, so two maps with
% equal contents need not unify.
%-----------------------------------------------------------------------------%

:- module ds.json.
:- interface.

:- import_module assoc_list.
:- import_module bool.
:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%
% The term
%-----------------------------------------------------------------------------%

    % `j_int` and `j_float` stay apart: a leaf keeps its kind [LEXP.7.12.1].
    %
:- type json
    --->    j_null
    ;       j_bool(bool)
    ;       j_int(int64)
    ;       j_float(float)
    ;       j_string(string)
    ;       j_array(list(json))
    ;       j_object(json_members).

    % An object's members, sorted by key.
    %
:- type json_members.

%-----------------------------------------------------------------------------%
% Objects
%-----------------------------------------------------------------------------%

:- func empty_object = json_members.

    % Build an object from members in any order. On a duplicate key the last
    % binding wins: JSON text that repeats one is refused where it is parsed
    % (LGRA.5.8.7), and this is a builder.
    %
:- func object(assoc_list(string, json)) = json_members.

    % The members, in canonical (key-ascending) order.
    %
:- func members(json_members) = assoc_list(string, json).

:- pred lookup_member(json_members::in, string::in, json::out) is semidet.

%-----------------------------------------------------------------------------%
% Paths
%-----------------------------------------------------------------------------%

:- type json_path == list(json_step).

:- type json_step
    --->    key(string)
    ;       index(int).         % zero-based, into a `j_array`

    % Fails when the path does not resolve; `j_null` is a present null. One layer
    % up the two read alike, and `has(path)` tells them apart [LNUL.8.4].
    %
:- pred resolve(json_path::in, json::in, json::out) is semidet.

:- pred has_path(json_path::in, json::in) is semidet.

    % Dot and bracket notation, e.g. `"forecast[0].max"`, to steps ([IDAT.3.3.10]).
    % Fails on the empty path and on a malformed one.
    %
:- pred parse_path(string::in, json_path::out) is semidet.

%-----------------------------------------------------------------------------%
% Limits
%-----------------------------------------------------------------------------%

    % The four limits on a Json value (LGRA.5.8.6):
    %
    %   depth         a scalar, or an empty array or object, is one level; each
    %                 enclosing array or object adds one
    %   nodes         every scalar, array and object, the root included
    %   string bytes  the UTF-8 bytes of every string and every object key
    %   text bytes    the bytes of JSON text handed to a parse
    %
    % A host hands over a finished term, so they are checked where a term arrives
    % (a slot, a cache seed) and where a rule makes one (a cache write).
    % `ds.json_text` enforces them on text.
    %
    % `max_fx_text_bytes` is a received FactExternal's own text limit: the most
    % LGRA.5.8.7a writes for a value within the other three, 6 x
    % `max_string_bytes` + 32 x `max_nodes`.
    %
:- func max_depth = int.
:- func max_nodes = int.
:- func max_string_bytes = int.
:- func max_text_bytes = int.
:- func max_fx_text_bytes = int.

:- type json_limit
    --->    jl_depth
    ;       jl_nodes
    ;       jl_string_bytes
    ;       jl_text_bytes.

    % Which limit a term crossed, the limit, and the count that crossed it.
    %
:- type json_breach
    --->    json_breach(
                jb_limit    :: json_limit,
                jb_max      :: int,
                jb_observed :: int
            ).

    % The first limit the term crosses, in document order, members by key, or `no`.
    % At each value, depth and then the node count; a string's bytes, and a key's
    % before its value, as they are reached. `jb_observed` is the count at the
    % crossing. Nothing is descended past the first crossing.
    %
:- func limit_breach(json) = maybe(json_breach).

%-----------------------------------------------------------------------------%
% Encoding
%-----------------------------------------------------------------------------%

    % [LSTR.8.5]: well-formed UTF-8 (RFC 3629). A Mercury `string` can hold bytes
    % that are not, and the standard library reads them as U+FFFD wherever it
    % decodes, so the check is on the code units.
    %
:- pred utf8_well_formed(string::in) is semidet.

    % Every string value and object key in the term is well-formed.
    %
:- pred lstr_8_5_well_formed(json::in) is semidet.

%-----------------------------------------------------------------------------%
% Signed zero
%-----------------------------------------------------------------------------%

    % [LGRA.5.8.8]: a float zero in a Json value has no sign. The term with every
    % `j_float` zero made `+0.0`, applied where a term arrives from the host;
    % `ds.json_text` folds as it parses. Only for a term within the limits, since
    % the walk recurses.
    %
:- func unsigned_zeros(json) = json.

%-----------------------------------------------------------------------------%
% Finite floats
%-----------------------------------------------------------------------------%

    % [LGRA.5.8.10]: succeeds when some `j_float` leaf is `+inf`, `-inf` or NaN.
    % Only for a term within the limits, since the walk recurses.
    %
:- pred holds_non_finite(json::in) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module char.
:- import_module float.
:- import_module int.
:- import_module pair.
:- import_module string.

%-----------------------------------------------------------------------------%

    % In the C grades, `to_code_unit_list` gives the bytes as stored.
    %
utf8_well_formed(S) :-
    string.to_code_unit_list(S, Units),
    string.from_utf8_code_unit_list(Units, _).

lstr_8_5_well_formed(j_null).
lstr_8_5_well_formed(j_bool(_)).
lstr_8_5_well_formed(j_int(_)).
lstr_8_5_well_formed(j_float(_)).
lstr_8_5_well_formed(j_string(S)) :-
    utf8_well_formed(S).
lstr_8_5_well_formed(j_array(Items)) :-
    list.all_true(lstr_8_5_well_formed, Items).
lstr_8_5_well_formed(j_object(json_members(Members))) :-
    list.all_true(member_well_formed, Members).

:- pred member_well_formed(pair(string, json)::in) is semidet.

member_well_formed(Key - Value) :-
    utf8_well_formed(Key),
    lstr_8_5_well_formed(Value).

%-----------------------------------------------------------------------------%

:- type json_members
    --->    json_members(assoc_list(string, json)).
            % Sorted by key, ascending, no duplicate keys.

empty_object = json_members([]).

object(Pairs) = json_members(Sorted) :-
    list.sort(compare_key, Pairs, ByKey),
    dedup_last(ByKey, Sorted).

    % The key alone: the sort is stable, so `dedup_last` can take the last.
    %
:- pred compare_key(pair(string, json)::in, pair(string, json)::in,
                    comparison_result::out) is det.

compare_key(K1 - _, K2 - _, R) :-
    compare(R, K1, K2).

:- pred dedup_last(assoc_list(string, json)::in, assoc_list(string, json)::out)
    is det.

dedup_last([], []).
dedup_last([P], [P]).
dedup_last([K1 - V1, K2 - V2 | Rest], Out) :-
    ( if K1 = K2 then
        dedup_last([K2 - V2 | Rest], Out)
    else
        dedup_last([K2 - V2 | Rest], Tail),
        Out = [K1 - V1 | Tail]
    ).

members(json_members(Ms)) = Ms.

lookup_member(json_members(Ms), Key, Value) :-
    assoc_list.search(Ms, Key, Value).

%-----------------------------------------------------------------------------%

resolve([], Json, Json).
resolve([Step | Steps], Json, Value) :-
    (
        Step = key(Key),
        Json = j_object(Members),
        lookup_member(Members, Key, Next)
    ;
        Step = index(Ix),
        Json = j_array(Elems),
        Ix >= 0,
        list.index0(Elems, Ix, Next)
    ),
    resolve(Steps, Next, Value).

has_path(Path, Json) :-
    resolve(Path, Json, _).

%-----------------------------------------------------------------------------%

max_depth = 16.
max_nodes = 256.
max_string_bytes = 16384.
max_text_bytes = 24576.
max_fx_text_bytes = 106496.

limit_breach(Json) = Breach :-
    Walked = walk_value(1, Json, counted(0, 0)),
    (
        Walked = counted(_, _),
        Breach = no
    ;
        Walked = crossed(B),
        Breach = yes(B)
    ).

:- type walk
    --->    counted(int, int)       % values and string bytes so far
    ;       crossed(json_breach).

    % `Level` is the value's; the root is 1.
    %
:- func walk_value(int, json, walk) = walk.

walk_value(_, _, crossed(B)) = crossed(B).
walk_value(Level, Json, counted(Nodes0, Bytes0)) = W :-
    ( if Level > max_depth then
        W = crossed(json_breach(jl_depth, max_depth, Level))
    else if Nodes0 + 1 > max_nodes then
        W = crossed(json_breach(jl_nodes, max_nodes, Nodes0 + 1))
    else
        Nodes = Nodes0 + 1,
        (
            Json = j_array(Elems),
            W = list.foldl(walk_value(Level + 1), Elems, counted(Nodes, Bytes0))
        ;
            Json = j_object(Members),
            W = list.foldl(walk_member(Level + 1), members(Members),
                counted(Nodes, Bytes0))
        ;
            Json = j_string(S),
            W = add_bytes(string.count_utf8_code_units(S), counted(Nodes, Bytes0))
        ;
            ( Json = j_null
            ; Json = j_bool(_)
            ; Json = j_int(_)
            ; Json = j_float(_)
            ),
            W = counted(Nodes, Bytes0)
        )
    ).

:- func walk_member(int, pair(string, json), walk) = walk.

walk_member(Level, Key - Value, W0) =
    walk_value(Level, Value, add_bytes(string.count_utf8_code_units(Key), W0)).

:- func add_bytes(int, walk) = walk.

add_bytes(_, crossed(B)) = crossed(B).
add_bytes(N, counted(Nodes, Bytes0)) = W :-
    Bytes = Bytes0 + N,
    ( if Bytes > max_string_bytes then
        W = crossed(json_breach(jl_string_bytes, max_string_bytes, Bytes))
    else
        W = counted(Nodes, Bytes)
    ).

%-----------------------------------------------------------------------------%

unsigned_zeros(Json) = Folded :-
    (
        Json = j_float(F),
        % A zero of either sign passes both tests, and NaN neither.
        ( if F =< 0.0, F >= 0.0 then
            Folded = j_float(0.0)
        else
            Folded = Json
        )
    ;
        Json = j_array(Elems),
        Folded = j_array(list.map(unsigned_zeros, Elems))
    ;
        Json = j_object(json_members(Ms)),
        Folded = j_object(json_members(list.map(unsigned_member, Ms)))
    ;
        ( Json = j_null
        ; Json = j_bool(_)
        ; Json = j_int(_)
        ; Json = j_string(_)
        ),
        Folded = Json
    ).

%-----------------------------------------------------------------------------%

holds_non_finite(Json) :-
    (
        Json = j_float(F),
        float.is_nan_or_inf(F)
    ;
        Json = j_array(Elems),
        list.any_true(holds_non_finite, Elems)
    ;
        Json = j_object(json_members(Ms)),
        list.any_true(
            ( pred(M::in) is semidet :-
                M = _ - V,
                holds_non_finite(V)
            ), Ms)
    ).

:- func unsigned_member(pair(string, json)) = pair(string, json).

unsigned_member(Key - Value) = Key - unsigned_zeros(Value).

%-----------------------------------------------------------------------------%
% Path parsing
%-----------------------------------------------------------------------------%
%
%     path       := first ( '.' named )*
%     first      := named | subscript subscripts
%     named      := name subscripts
%     name       := [^.[]+
%     subscripts := ( '[' digit+ ']' )*
%
% [IDAT.3.3.10]'s `json_path`. A segment produces at least one step.

parse_path(S, Path) :-
    S \= "",
    parse_first_segment(string.to_char_list(S), Path).

:- pred parse_first_segment(list(char)::in, json_path::out) is semidet.

parse_first_segment(Cs, Path) :-
    take_name(Cs, Name, Rest0),
    take_subscripts(Rest0, Subs, Rest1),
    (
        Name = [],
        Steps = Subs,
        Subs = [_ | _]
    ;
        Name = [_ | _],
        Steps = [key(string.from_char_list(Name)) | Subs]
    ),
    parse_rest(Rest1, Steps, Path).

:- pred parse_named_segment(list(char)::in, json_path::out) is semidet.

parse_named_segment(Cs, Path) :-
    take_name(Cs, Name, Rest0),
    Name = [_ | _],
    take_subscripts(Rest0, Subs, Rest1),
    parse_rest(Rest1, [key(string.from_char_list(Name)) | Subs], Path).

:- pred parse_rest(list(char)::in, json_path::in, json_path::out) is semidet.

parse_rest(Rest, Steps, Path) :-
    (
        Rest = [],
        Path = Steps
    ;
        Rest = ['.' | Rest1],
        parse_named_segment(Rest1, Tail),
        Path = Steps ++ Tail
    ).

:- pred take_name(list(char)::in, list(char)::out, list(char)::out) is det.

take_name([], [], []).
take_name([C | Cs], Name, Rest) :-
    ( if ( C = ('.') ; C = ('[') ) then
        Name = [],
        Rest = [C | Cs]
    else
        take_name(Cs, Name0, Rest),
        Name = [C | Name0]
    ).

:- pred take_subscripts(list(char)::in, json_path::out, list(char)::out)
    is semidet.

take_subscripts(Cs, Subs, Rest) :-
    ( if Cs = ['[' | Cs1] then
        take_digits(Cs1, Digits, Cs2),
        Digits = [_ | _],
        Cs2 = [']' | Cs3],
        take_subscripts(Cs3, More, Rest),
        Subs = [index(digits_value(Digits, 0)) | More]
    else
        Subs = [],
        Rest = Cs
    ).

:- pred take_digits(list(char)::in, list(char)::out, list(char)::out) is det.

take_digits([], [], []).
take_digits([C | Cs], Digits, Rest) :-
    ( if char.is_digit(C) then
        take_digits(Cs, Digits0, Rest),
        Digits = [C | Digits0]
    else
        Digits = [],
        Rest = [C | Cs]
    ).

    % A number past `max_int` saturates, so it is past every array's end, a miss
    % ([IDAT.3.3.10]).
    %
:- func digits_value(list(char), int) = int.

digits_value([], Acc) = Acc.
digits_value([C | Cs], Acc) =
    ( if char.decimal_digit_to_int(C, D) then
        digits_value(Cs,
            ( if Acc > (int.max_int - D) // 10 then int.max_int
              else Acc * 10 + D ))
    else
        Acc
    ).

%-----------------------------------------------------------------------------%

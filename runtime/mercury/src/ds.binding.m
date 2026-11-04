% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.binding -- the two binding comparators, and only these two.
%
% [RBND.6.1]: no call site reimplements these. The detail string is part of the
% contract ([RBND.5.2]).
%-----------------------------------------------------------------------------%

:- module ds.binding.
:- interface.

:- import_module list.
:- import_module string.
:- import_module uint8.

%-----------------------------------------------------------------------------%

    % [RBND.1.3].
    %
:- type dialect_binding
    --->    dialect_binding(
                db_dsc_sha       :: list(uint8),
                db_capabilities  :: list(int),
                    % As the artefact carries them; compared as written.
                db_def_sha       :: list(uint8)
            ).

    % [RBND.1.4].
    %
:- type rt_binding
    --->    rt_binding(
                rb_sha :: list(uint8)
            ).

:- type binding_result
    --->    bound
    ;       mismatch(
                bm_code   :: int,       % -700, -701 or -704 [RBND.5.2]
                bm_detail :: string
            ).

    % First mismatch wins.
    %
:- func compare_dialect(dialect_binding, dialect_binding) = binding_result.

:- func compare_rt(rt_binding, rt_binding) = binding_result.

    % [RBND.1.3]: strictly ascending, every entry a `Capability` other than 0.
    % Not a comparator: it reads one artefact.
    %
:- pred capabilities_well_formed(list(int)::in) is semidet.

    % [RBND.5.2]'s truncation.
    %
:- func short_hex(list(uint8)) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.capability.
:- import_module ds.sha256.
:- import_module int.

%-----------------------------------------------------------------------------%

compare_dialect(A, B) = Result :-
    ( if A ^ db_dsc_sha \= B ^ db_dsc_sha then
        Result = mismatch(-700, field_detail("dsc_sha256",
            short_hex(A ^ db_dsc_sha), short_hex(B ^ db_dsc_sha)))
    else if A ^ db_capabilities \= B ^ db_capabilities then
        Result = mismatch(-701, "capabilities: in one and not the other: "
            ++ names(only_in(A ^ db_capabilities, B ^ db_capabilities))
            ++ " vs " ++ names(only_in(B ^ db_capabilities,
                A ^ db_capabilities)))
    else if A ^ db_def_sha \= B ^ db_def_sha then
        Result = mismatch(-701, field_detail("dialect_def_sha256",
            short_hex(A ^ db_def_sha), short_hex(B ^ db_def_sha)))
    else
        Result = bound
    ).

compare_rt(A, B) = Result :-
    ( if A ^ rb_sha \= B ^ rb_sha then
        Result = mismatch(-704, field_detail("rt_config_sha256",
            short_hex(A ^ rb_sha), short_hex(B ^ rb_sha)))
    else
        Result = bound
    ).

capabilities_well_formed([]).
capabilities_well_formed([N | Ns]) :-
    capability_of_number(N, _),
    caps_ascending_from(N, Ns).

:- pred caps_ascending_from(int::in, list(int)::in) is semidet.

caps_ascending_from(_, []).
caps_ascending_from(Prev, [N | Ns]) :-
    N > Prev,
    capability_of_number(N, _),
    caps_ascending_from(N, Ns).

:- func only_in(list(int), list(int)) = list(int).

only_in(Xs, Ys) = list.filter((pred(X::in) is semidet :- not list.member(X, Ys)),
    Xs).

    % A number this build does not know is named by its number, which is
    % what the artefact said.
    %
:- func names(list(int)) = string.

names([]) = "(none)".
names(Ns @ [_ | _]) = string.join_list(",", list.map(
    ( func(N) = ( if capability_of_number(N, C) then capability_name(C)
                  else string.from_int(N) ) ), Ns)).

:- func field_detail(string, string, string) = string.

field_detail(Field, Got, Want) =
    Field ++ ": " ++ Got ++ " vs " ++ Want.

short_hex(Bytes) = Hex :-
    Full = hex(Bytes),
    ( if string.length(Full) =< 16 then
        Hex = Full
    else
        Hex = string.left(Full, 16)
    ).

%-----------------------------------------------------------------------------%

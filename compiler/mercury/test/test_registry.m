% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% test_registry -- the two generated views of the diagnostic registry agree.
%
% [RCLI.5.1]: `specs/registry/validate.ebnf` generates the runtime's
% `ds.ds_validate` and the compiler's `dsc.validate_codes`. The generator's
% `--check` holds each to the registry; this holds the two to each other, by
% enumerating both DUs' constants (`construct`), never a list kept by hand.
% `DS_VALIDATE_UNSPECIFIED`, the runtime's zero value, names no code.
%
% `use_module`: both modules export `ds_validate` and `ds_validate_name`, so
% every reference is qualified, and this is a module of its own.
%-----------------------------------------------------------------------------%

:- module test_registry.
:- interface.

:- import_module io.

:- pred run(int::out, int::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- use_module ds.
:- use_module ds.ds_validate.
:- use_module dsc.
:- use_module dsc.validate_codes.

:- import_module construct.
:- import_module int.
:- import_module list.
:- import_module set.
:- import_module string.
:- import_module type_desc.
:- import_module univ.

%-----------------------------------------------------------------------------%

run(Pass, Fail, !IO) :-
    Compiler = compiler_names,
    Registry = registry_names,
    NotRegistered = set.to_sorted_list(set.difference(Compiler, Registry)),
    NotEmitted = set.to_sorted_list(set.difference(Registry, Compiler)),
    io.format("  registry: dsc.validate_codes holds %d code(s), "
        ++ "ds.ds_validate %d live\n",
        [i(set.count(Compiler)), i(set.count(Registry))], !IO),
    arm("dsc.validate_codes names %d code(s) ds.ds_validate does not hold "
        ++ "as live:\n", NotRegistered, 0, Fail1, !IO),
    arm("ds.ds_validate holds %d live code(s) dsc.validate_codes has no "
        ++ "constructor for:\n", NotEmitted, Fail1, Fail, !IO),
    Pass = 2 - Fail.

    % A non-empty difference fails, each name printed.
    %
:- pred arm(string::in, list(string)::in, int::in, int::out,
            io::di, io::uo) is det.

arm(Header, Names, !Fail, !IO) :-
    (
        Names = []
    ;
        Names = [_ | _],
        !:Fail = !.Fail + 1,
        io.format("  FAIL  [RCLI.5.1] " ++ Header,
            [i(list.length(Names))], !IO),
        list.foldl(print_name, Names, !IO)
    ).

:- pred print_name(string::in, io::di, io::uo) is det.

print_name(Name, !IO) :-
    io.format("        %s\n", [s(Name)], !IO).

    % Every name the compiler's view gives a `DS_VALIDATE_*` code.
    %
:- func compiler_names = set(string).

compiler_names = set.list_to_set(list.map(dsc.validate_codes.ds_validate_name,
    constants(type_of(dsc.validate_codes.dv_unknown_slot)))).

    % Every live member of the runtime's view, less the generated zero value,
    % which names no code.
    %
:- func registry_names = set(string).

registry_names = set.delete(
    set.list_to_set(list.map(ds.ds_validate.ds_validate_name,
        constants(type_of(ds.ds_validate.ds_validate_unspecified)))),
    "DS_VALIDATE_UNSPECIFIED").

    % Every constant of the enumeration `Type`; both DUs here have only
    % constants.
    %
:- func constants(type_desc) = list(T).

constants(Type) = Values :-
    N = construct.det_num_functors(Type),
    Values = list.filter_map(
        ( func(I) = V is semidet :-
            U = construct.construct(Type, I, []),
            univ_to_type(U, V)
        ), 0 .. (N - 1)).

%-----------------------------------------------------------------------------%
:- end_module test_registry.
%-----------------------------------------------------------------------------%

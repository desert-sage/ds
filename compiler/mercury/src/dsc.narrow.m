% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.narrow -- case (a) of [LNUL.5.4]'s two narrowing cases. Case (b) is typed
% where `??` is.
%
% `x is not null and ...` narrows and `not (x is null) and ...` does not. Called
% per `where` clause; the result does not reach the actions ([LNUL.5.2]).
%-----------------------------------------------------------------------------%

:- module dsc.narrow.
:- interface.

:- import_module dsc.expr.

:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%

    % The paths a `where` expression establishes as non-null, for use by the
    % conjuncts to its right. Keyed by spelling, since a node carries a position.
    %
    %@spec [LNUL.5.2]
    %@spec [LNUL.5.4]
:- func lnul_5_4_narrowed(lgra_9_3_1_expr) = set(string).

    % The spelling of a binding, a slot access or a chain of them. Fails for
    % anything else.
    %
    %@spec [LNUL.5.4]
:- func lnul_5_4_path(lgra_9_3_1_expr) = string is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.token.
:- import_module list.

%-----------------------------------------------------------------------------%

lnul_5_4_narrowed(Expr) = Narrowed :-
    (
        Expr = ex_binary(Op, Left, Right, _),
        ( if Op = bo_and then
            Narrowed = set.union(lnul_5_4_narrowed(Left),
                lnul_5_4_narrowed(Right))
        else
            Narrowed = set.init
        )
    ;
        Expr = ex_is(Operand, Negation, Subject, _),
        ( if
            Negation = is_negated,
            Subject = is_null,
            Path = lnul_5_4_path(Operand)
        then
            Narrowed = set.make_singleton_set(Path)
        else
            Narrowed = set.init
        )
    ;
        ( Expr = ex_not(_, _)
        ; Expr = ex_int(_, _)
        ; Expr = ex_float(_, _)
        ; Expr = ex_string(_, _)
        ; Expr = ex_bool(_, _)
        ; Expr = ex_null(_)
        ; Expr = ex_unit(_, _, _)
        ; Expr = ex_name(_)
        ; Expr = ex_unary(_, _, _)
        ; Expr = ex_compare(_, _, _)
        ; Expr = ex_slot(_, _, _)
        ; Expr = ex_index(_, _, _)
        ; Expr = ex_call(_, _, _)
        ; Expr = ex_cast(_, _, _, _)
        ; Expr = ex_match(_, _, _, _, _)
        ),
        Narrowed = set.init
    ).

lnul_5_4_path(ex_name(Id)) = Id ^ id_name.
lnul_5_4_path(ex_slot(Base, Field, _)) =
    lnul_5_4_path(Base) ++ "." ++ Field ^ id_name.

%-----------------------------------------------------------------------------%
:- end_module dsc.narrow.
%-----------------------------------------------------------------------------%

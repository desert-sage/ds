% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.expr -- the expression sublanguage, one type for the CST and the AST:
% `build` does not transform an expression.
%-----------------------------------------------------------------------------%
:- module dsc.expr.
:- interface.
:- import_module dsc.token.
:- import_module bool.
:- import_module list.
%-----------------------------------------------------------------------------%
    % `T?` -- a slot type, a cast target, or a `let` annotation.
    %
    %@helper
:- type nullability
    --->    nullable
    ;       non_null.

    %@spec [LGRA.10.1.1]
:- type lgra_10_1_1_log_level
    --->    ll_debug ; ll_info ; ll_warning ; ll_error ; ll_critical
    ;       ll_unknown(string).
            % A name `validate` refuses by code.

    %@spec [LGRA.7.6a]
:- type lgra_7_6a_gap_policy
    --->    gp_hold(pos)
    ;       gp_zero(pos)
    ;       gp_skip(pos).
%-----------------------------------------------------------------------------%
% Expressions -- [LGRA.9.3.1]
%-----------------------------------------------------------------------------%

    %@spec [LGRA.9.3.1]
    %@spec [LGRA.9.7.1]
:- type lgra_9_3_1_expr
    --->    ex_int(int64, pos)      % a DS `Int`, `int64` on any host
    ;       ex_float(float, pos)
    ;       ex_string(string, pos)
    ;       ex_unit(string, string, pos)    % magnitude text, unit suffix
    ;       ex_bool(bool, pos)
    ;       ex_null(pos)
    ;       ex_name(ident)
            % `lib.CONST` parses as `ex_slot` over `ex_name`:
            % `dsc.resolve.lgra_22_9_library_member` decides which it is.
    ;       ex_unary(lgra_9_5_1_unary_op, lgra_9_3_1_expr, pos)
    ;       ex_not(lgra_9_3_1_expr, pos)
    ;       ex_binary(lgra_9_3_1_binary_op, lgra_9_3_1_expr,
                      lgra_9_3_1_expr, pos)
    ;       ex_compare(lgra_9_3_1_expr, list(lgra_9_3_2_compare_step), pos)
    ;       ex_is(lgra_9_3_1_expr, is_negation, is_subject, pos)
    ;       ex_slot(lgra_9_3_1_expr, ident, pos)
    ;       ex_index(lgra_9_3_1_expr, lgra_9_3_1_expr, pos)
    ;       ex_call(lgra_9_3_1_expr, list(lgra_9_3_1_expr), pos)
    ;       ex_cast(lgra_9_3_1_expr, ident, nullability, pos)
    ;       ex_match(lgra_9_3_1_expr, lreg_1_1_sense, string, string, pos).
            % Operand, sense, pattern, flags, and the operator's position.

    %@spec [LREG.1.1]
    %@spec [LREG.1.3]
:- type lreg_1_1_sense
    --->    ms_match        % `~`
    ;       ms_not_match.   % `!~`
    % A chain, not a nested tree: `a < b < c` is `(a < b) and (b < c)`.
    %
    %@spec [LGRA.9.3.2]
:- type lgra_9_3_2_compare_step
    --->    lgra_9_3_2_compare_step(
                cs_op    :: lgra_9_3_2_compare_op,
                cs_right :: lgra_9_3_1_expr,
                cs_pos   :: pos
            ).
    %@spec [LGRA.9.3.2]
:- type lgra_9_3_2_compare_op
    --->    co_eq ; co_ne ; co_lt ; co_le ; co_gt ; co_ge.
    %@spec [LGRA.9.3.1]
    %@spec [LGRA.9.4.1]
    %@spec [LGRA.9.5.1]
:- type lgra_9_3_1_binary_op
    --->    bo_or
    ;       bo_and
    ;       bo_coalesce                     % `??`
    ;       bo_in ; bo_contains ; bo_overlaps
    ;       bo_interval                     % `..`
    ;       bo_bitor ; bo_bitxor ; bo_bitand ; bo_shl ; bo_shr
    ;       bo_add ; bo_sub
    ;       bo_mul ; bo_div ; bo_floordiv ; bo_mod
    ;       bo_pow.
    % A negative number is `uo_neg` over a literal: no numeric token is signed.
    %
    %@spec [LGRA.9.5.1]
    %@spec [LGRA.2.7.6]
:- type lgra_9_5_1_unary_op
    --->    uo_neg ; uo_pos ; uo_bitnot.
    %@helper
:- type is_negation
    --->    is_positive
    ;       is_negated.
    % `is_tag` carries the name as written; the parser admits only the six tags.
    %
    %@helper
:- type is_subject
    --->    is_null
    ;       is_bool(bool)
    ;       is_inf(is_inf_sign)
    ;       is_nan
    ;       is_tag(ident).
    %@helper
:- type is_inf_sign
    --->    inf_positive
    ;       inf_negative.

    % Its leftmost token.
    %
    %@helper
:- func expr_start(lgra_9_3_1_expr) = pos.

%-----------------------------------------------------------------------------%
:- implementation.

expr_start(ex_int(_, P)) = P.
expr_start(ex_float(_, P)) = P.
expr_start(ex_string(_, P)) = P.
expr_start(ex_unit(_, _, P)) = P.
expr_start(ex_bool(_, P)) = P.
expr_start(ex_null(P)) = P.
expr_start(ex_name(Id)) = Id ^ id_pos.
expr_start(ex_unary(_, _, P)) = P.
expr_start(ex_not(_, P)) = P.
expr_start(ex_binary(_, L, _, _)) = expr_start(L).
expr_start(ex_compare(L, _, _)) = expr_start(L).
expr_start(ex_is(E, _, _, _)) = expr_start(E).
expr_start(ex_slot(E, _, _)) = expr_start(E).
expr_start(ex_index(E, _, _)) = expr_start(E).
expr_start(ex_call(E, _, _)) = expr_start(E).
expr_start(ex_cast(E, _, _, _)) = expr_start(E).
expr_start(ex_match(E, _, _, _, _)) = expr_start(E).

%-----------------------------------------------------------------------------%
:- end_module dsc.expr.
%-----------------------------------------------------------------------------%

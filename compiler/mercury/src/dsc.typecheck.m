% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.typecheck -- the expression-typing walk.
%-----------------------------------------------------------------------------%

:- module dsc.typecheck.
:- interface.

:- import_module dsc.cast.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.expr.
:- import_module dsc.resolve.
:- import_module dsc.token.
:- import_module dsc.types.

:- import_module list.
:- import_module set.

%-----------------------------------------------------------------------------%

    % `ty_unknown` is no error: no check that needs a type may fire on it.
    %
    %@helper
:- type lexp_7_type
    --->    ty_known(ds_type)
    ;       ty_unknown
    ;       ty_error(list(diagnostic)).

    %@helper
:- type type_env
    --->    type_env(
                te_file      :: resolved_file,
                te_scope     :: rule_scope,
                te_ambiguity :: dim_ambiguity,

                    % The paths an `x is not null and` guard to the left has
                    % established as present ([LNUL.5.4]). Starts empty at every
                    % rule and does not cross the arrow ([LNUL.5.2]).
                te_narrowed  :: set(string)
            ).

    % Whether a dimensioned-times-dimensioned result has an annotation to name
    % its unit ([LUNI.8.4]): `r.w * r.h` is refused in a `where` and correct in
    % `let area: meter_squared = …`.
    %
    %@helper
:- type dim_ambiguity
    --->    da_reported
    ;       da_annotated.

    % How many `implicit` formulas bridge two dimensions, per declaration: both
    % lines of a `unit formula pair` bridge one pair.
    %
    %@helper
:- type luni_4_5_bridge
    --->    bridge_none
    ;       bridge_one
    ;       bridge_ambiguous.

    %@spec [LUNI.4.5]
:- func luni_4_5_implicit_bridge(type_env, decl_ref, decl_ref) = luni_4_5_bridge.

    % A `T?` reaching a concrete-value position, whose name the caller gives.
    % `type_of_expr` has already applied narrowing. Empty or a singleton.
    %
    %@spec [LNUL.5.1]
:- func lnul_5_1_concrete(type_env, lgra_9_3_1_expr, lexp_7_type, pos, string)
    = list(diagnostic).

    % The `::` spelling that replaces a callee name. `dsc.validate` refuses the
    % call; this pass only must not also call the name unknown. A builtin
    % function's name is never a unit assertion: `min(a, b)` is the builtin.
    %
    %@spec [LCST.4.6.1]
:- pred lcst_4_6_1_coercion_head(resolved_file::in, string::in, string::out)
    is semidet.

    %@spec [LCST.4.5.1]
:- pred lcst_4_5_1_identity_cast(type_env::in, lgra_9_3_1_expr::in, ident::in,
                                 nullability::in) is semidet.

    % The `(source, target)` pair a `::` cast converts, when the operand has a
    % known type and the target resolves: the key the lowering dispatches on.
    %
    %@helper
:- pred lcst_4_cast_pair(type_env::in, lgra_9_3_1_expr::in, ident::in,
                         lcst_4_5_2_kind::out, lcst_4_1_6_target::out)
    is semidet.

    % A name that is a zero-argument member of some receiver type
    % ([LGRA.9.6.2]): `bit_count`, `bit_length`, `utc`, and the components.
    %
    %@spec [LGRA.9.6.2]
:- pred lgra_9_6_2_zero_arg_member(string::in) is semidet.

    %@helper
:- func type_of_expr(type_env, lgra_9_3_1_expr) = lexp_7_type.

    % The own name of the schema a fact type's name names, which a binding of a
    % qualified head does not spell.
    %
    %@spec [LIMP.13.1]
:- func limp_13_1_fact_own(type_env, string) = string is semidet.

    % `Env` with one more pattern binding, `Name`, over the schema called
    % `Schema`: a binding a continuation body sees and its rule does not. An
    % `error:` body reads the `CallError` it matched as `error` ([LCCO.8.2],
    % [LCCO.8.4]). A schema this file does not declare is an imported head, and
    % a read through it is `ty_unknown`.
    %
    %@helper
:- func env_with_binding(type_env, string, string, pos) = type_env.

    % Whether this expression, at its top, is a series read: an [LSER.16]
    % aggregation over a cursor, as a call or as a companion slot ([LSER.6.3]).
    % `t.mean` on a schema with a `mean` slot is the slot, and `min(a, b)` is
    % the scalar builtin. The caller walks the subexpressions.
    %
    %@spec [LTIM.2.4.1]
:- pred ltim_2_4_1_series_read(type_env::in, lgra_9_3_1_expr::in) is semidet.

    % Whether this expression, at its top, reads [LUNI.9.2]'s unit-changing
    % aggregation, `integral`, over a slot that carries a unit: the
    % aggregation, and the slot's unit (its dimension's name where the slot
    % names a dimension). The caller walks the subexpressions.
    %
    %@spec [LUNI.9.2]
:- pred luni_9_2_unit_changing_read(type_env::in, lgra_9_3_1_expr::in,
                                    string::out, string::out) is semidet.

    % Whether this expression, at its top, is a zone read ([LTIM.2.4.1]):
    % `t.local(tz)` or `t.date(tz)` on a `Time`, with a zone that does not fold
    % to `"UTC"` ([LTIM.10.8]): a literal, or a `const` whose folded value it is.
    % The caller walks the subexpressions.
    %
    %@spec [LTIM.2.4.1]
    %@spec [LTIM.2.6.2]
:- pred ltim_2_4_1_zone_read(type_env::in, lgra_9_3_1_expr::in) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.ast.
:- import_module dsc.builtin_types.
:- import_module dsc.builtins.
:- import_module ds.capability.
:- import_module dsc.capability.
:- import_module dsc.dstest.
:- import_module dsc.narrow.
:- import_module dsc.quantity.
:- import_module dsc.series.

:- import_module ds.
:- import_module ds.i64.

:- import_module int.
:- import_module int64.
:- import_module map.
:- import_module maybe.
:- import_module string.

%-----------------------------------------------------------------------------%

env_with_binding(Env, Name, SchemaName, Pos) =
        Env ^ te_scope ^ rsc_bindings := Bindings :-
    Types = Env ^ te_file ^ rf_types,
    ( if map.search(Types, SchemaName, Entry), Entry = te_schema(Schema) then
        Head = head_local(Schema)
    else
        Head = head_imported(ident(SchemaName, Pos))
    ),
    map.set(Name, pattern_binding(ident(Name, Pos), Head),
        Env ^ te_scope ^ rsc_bindings, Bindings).

%-----------------------------------------------------------------------------%

    % Narrowing changes the type: the guarded path is `T`, so a result built on
    % it is not nullable either.
    %
    %@spec [LNUL.5.2]
type_of_expr(Env, Expr) = Type :-
    Raw = lnul_5_2_unnarrowed_type(Env, Expr),
    ( if
        Raw = ty_known(Known),
        Known ^ dt_null = nullable,
        narrowed_here(Env, Expr)
    then
        Type = ty_known(Known ^ dt_null := non_null)
    else
        Type = Raw
    ).

    %@helper
:- func lnul_5_2_unnarrowed_type(type_env, lgra_9_3_1_expr) = lexp_7_type.

lnul_5_2_unnarrowed_type(Env, Expr) = Type :-
    (
        Expr = ex_int(_, _),
        Type = scalar(lk_int)
    ;
        Expr = ex_float(_, _),
        Type = scalar(lk_float)
    ;
        Expr = ex_string(_, _),
        Type = scalar(lk_string)
    ;
        Expr = ex_bool(_, _),
        Type = scalar(lk_bool)
    ;
        Expr = ex_null(_),
        Type = ty_unknown
    ;
        Expr = ex_unit(Magnitude, Suffix, Pos),
        Type = luni_3_1_7_literal_type(Env, Magnitude, Suffix, Pos)
    ;
        Expr = ex_name(Id),
        Type = lgra_22_7_value_name(Env, Id)
    ;
        % `is` is total ([LNUL.4.9]), and its operand's diagnostics still count.
        Expr = ex_is(Operand, _, _, _),
        Type = total_bool(Env, Operand)
    ;
        Expr = ex_not(Inner, _),
        Type = kleene_bool(Env, [Inner])
    ;
        Expr = ex_compare(First, Steps, _),
        Type = ltim_5_5_comparison(Env, First, Steps)
    ;
        Expr = ex_binary(Op, Left, Right, Pos),
        Type = lnul_5_3_binary_type(Env, Op, Left, Right, Pos)
    ;
        Expr = ex_slot(Base, Field, Pos),
        % A library member first: `ha.RETRY`'s root is no binding ([LGRA.22.9]).
        % The cursor on the whole chain next: typing the base of `s.recent.p99`
        % would ask the schema for a slot `recent`.
        ( if lgra_22_9_library_member(Env ^ te_file, Expr, Lib, Member) then
            Type = limp_4_3_2_qualified_const(Env, Lib, Member,
                expr_start(Expr))
        else if lser_6_10_2_cursor_read(Env, Base, Field, Pos, CursorType) then
            Type = CursorType
        else if lser_10_4_dwell_read(Env, Base, Field, DwellType) then
            Type = DwellType
        else if hydrated_corr_read(Env, Base, Field) then
            Type = scalar(lk_string)
        else
            Type = luni_7_1_access_type(Env, Base, Field, Pos)
        )
    ;
        Expr = ex_cast(Operand, Target, Written, Pos),
        Type = lcst_4_1_5_cast_type(Env, Operand, Target, Written, Pos)
    ;
        Expr = ex_index(Base, _, Pos),
        Type = lgra_5_8_5_index_type(Env, Base, Pos)
    ;
        Expr = ex_call(Callee, Args, Pos),
        Type = lexp_5_3_call(Env, Callee, Args, Pos)
    ;
        Expr = ex_unary(Op, Operand, Pos),
        Type = lexp_7_10_unary(Env, Op, Operand, Pos)
    ;
        Expr = ex_match(Operand, _, _, _, Pos),
        Type = lreg_4_5_match_type(Env, Operand, Pos)
    ).

    % A `Json` operand is admitted: a mismatch at its leaf is a runtime
    % `TypeError` ([LEXP.7.12]). The result is nullable when the operand is
    % ([LNUL.4.1]).
    %
    %@spec [LREG.4.5]
:- func lreg_4_5_match_type(type_env, lgra_9_3_1_expr, pos) = lexp_7_type.

lreg_4_5_match_type(Env, Operand, Pos) = Type :-
    OperandType = type_of_expr(Env, Operand),
    (
        OperandType = ty_error(Ds),
        Type = ty_error(Ds)
    ;
        OperandType = ty_unknown,
        Type = scalar(lk_bool)
    ;
        OperandType = ty_known(Known),
        Leaf = Known ^ dt_leaf,
        ( if Leaf = lk_bytes then
            Type = ty_error([with_hint(error_at(dv_regex_on_bytes, Pos,
                "a regex matches a `String` by codepoint, and this operand is "
                    ++ "`Bytes` ([LSTR.7.1.1])"),
                "`decode` it to a `String` first")])
        else if ( Leaf = lk_string ; Leaf = lk_json ) then
            Type = ty_known(ds_type(lk_bool, dimensionless, Known ^ dt_null))
        else
            Type = ty_error([error_at(dv_regex_non_string_operand, Pos,
                "`~` and `!~` match a `String`, and this operand is not one "
                    ++ "([LREG.4.5])")])
        )
    ).

    %@spec [LEXP.7.9]
    %@spec [LEXP.7.10]
    %@spec [LEXP.7.11]
:- func lexp_7_10_unary(type_env, lgra_9_5_1_unary_op, lgra_9_3_1_expr, pos)
    = lexp_7_type.

lexp_7_10_unary(Env, Op, Operand, Pos) = Type :-
    OperandType = type_of_expr(Env, Operand),
    (
        OperandType = ty_error(Ds),
        Type = ty_error(Ds)
    ;
        OperandType = ty_unknown,
        Type = ty_unknown
    ;
        OperandType = ty_known(K),
        (
            Op = uo_bitnot,
            ( if K ^ dt_leaf = lk_int then
                Type = ty_known(K)
            else
                Type = ty_error([with_hint(error_at(dv_bitwise_type, Pos,
                    "unary `~` requires an integer operand ([LEXP.7.9])"),
                    "convert with `::Int`")])
            )
        ;
            % A `Duration` is refused: it is never negative ([LTIM.1.3.1]).
            ( Op = uo_neg
            ; Op = uo_pos
            ),
            ( if lexp_7_1a_numeric(K ^ dt_leaf) then
                Type = ty_known(K)
            else
                Type = ty_error([error_at(dv_bad_operand_type, Pos,
                    "unary `-` and `+` take `Int` or `Float` ([LEXP.7.10])")])
            )
        )
    ).

    %@helper
:- func scalar(leaf_kind) = lexp_7_type.

scalar(Leaf) = ty_known(ds_type(Leaf, dimensionless, non_null)).

    %@helper
:- func total_bool(type_env, lgra_9_3_1_expr) = lexp_7_type.

total_bool(Env, Operand) = Type :-
    OperandType = type_of_expr(Env, Operand),
    (
        OperandType = ty_error(Ds),
        Type = ty_error(Ds)
    ;
        ( OperandType = ty_known(_)
        ; OperandType = ty_unknown
        ),
        Type = scalar(lk_bool)
    ).

%-----------------------------------------------------------------------------%
% Kleene results
%-----------------------------------------------------------------------------%

    % `Bool?` when any operand is nullable ([LNUL.4.1], [LNUL.4.2]). An operand
    % of unknown type counts as non-null.
    %
    %@helper
:- func kleene_bool(type_env, list(lgra_9_3_1_expr)) = lexp_7_type.

kleene_bool(Env, Operands) = Type :-
    Types = list.map(type_of_expr(Env), Operands),
    Errors = list.condense(list.filter_map(errors_of, Types)),
    (
        Errors = [_ | _],
        Type = ty_error(Errors)
    ;
        Errors = [],
        ( if list.member(T, Types), T = ty_known(K), K ^ dt_null = nullable then
            Null = nullable
        else
            Null = non_null
        ),
        Type = ty_known(ds_type(lk_bool, dimensionless, Null))
    ).

    % `Left and Right`, with `Left`'s guards in scope for `Right`.
    %
    %@helper
:- func kleene_bool_narrowing(type_env, lgra_9_3_1_expr, lgra_9_3_1_expr)
    = lexp_7_type.

kleene_bool_narrowing(Env, Left, Right) = Type :-
    RightEnv = Env ^ te_narrowed :=
        set.union(Env ^ te_narrowed, lnul_5_4_narrowed(Left)),
    LeftType = type_of_expr(Env, Left),
    RightType = type_of_expr(RightEnv, Right),
    Types = [LeftType, RightType],
    Errors = list.condense(list.filter_map(errors_of, Types)),
    (
        Errors = [_ | _],
        Type = ty_error(Errors)
    ;
        Errors = [],
        ( if list.member(T, Types), T = ty_known(K), K ^ dt_null = nullable then
            Null = nullable
        else
            Null = non_null
        ),
        Type = ty_known(ds_type(lk_bool, dimensionless, Null))
    ).

    %@helper
:- func errors_of(lexp_7_type) = list(diagnostic) is semidet.

errors_of(ty_error(Ds)) = Ds.

%-----------------------------------------------------------------------------%
% Comparison operands -- [LTIM.5.5]
%-----------------------------------------------------------------------------%
%
% A chain compares pairwise ([LGRA.9.3.2]): `b` with each neighbour, never `a`
% with `c`.

    %@spec [LTIM.5.5]
    %@spec [LEXP.7.12.5]
:- func ltim_5_5_comparison(type_env, lgra_9_3_1_expr,
                            list(lgra_9_3_2_compare_step)) = lexp_7_type.

ltim_5_5_comparison(Env, First, Steps) = Type :-
    Operands = [First | list.map((func(S) = S ^ cs_right), Steps)],
    Types = list.map(type_of_expr(Env), Operands),
    Errors = list.condense(list.filter_map(errors_of, Types)),
    Mismatches = adjacent_mismatches(Env, Steps, Operands, Types),
    NullLiterals = lnul_4_4_null_literals(Steps, Operands),
    ClosedSet = lerr_9_2_closed_set(Env, Steps, Operands),
    ( if Errors = [], Mismatches = [], NullLiterals = [], ClosedSet = [] then
        Type = kleene_bool(Env, Operands)
    else
        Type = ty_error(Errors ++ NullLiterals ++ ClosedSet ++ Mismatches)
    ).

    % `==` and `!=` only, either operand position. An ordering comparison of
    % `kind` is a string comparison.
    %
    %@spec [LERR.9.2]
:- func lerr_9_2_closed_set(type_env, list(lgra_9_3_2_compare_step),
                            list(lgra_9_3_1_expr)) = list(diagnostic).

lerr_9_2_closed_set(_, [], _) = [].
lerr_9_2_closed_set(Env, [Step | Steps], Operands) = Found :-
    ( if Operands = [A, B | Rest] then
        Op = Step ^ cs_op,
        ( if
            ( Op = co_eq ; Op = co_ne ),
            kind_against_literal(Env, A, B, Lit),
            not lerr_9_2_trap_kind(Lit)
        then
            Here = [with_hint(error_at(dv_closed_set_literal, Step ^ cs_pos,
                "`ComputationError.kind` is one of \"DIVIDE_BY_ZERO\", "
                    ++ "\"DOMAIN\" or \"NOT_REPRESENTABLE\", so it is never \""
                    ++ Lit ++ "\" ([LERR.9.2])"),
                "compare against one of the three members")]
        else
            Here = []
        ),
        Found = Here ++ lerr_9_2_closed_set(Env, Steps, [B | Rest])
    else
        Found = []
    ).

    %@helper
:- pred kind_against_literal(type_env::in, lgra_9_3_1_expr::in,
                             lgra_9_3_1_expr::in, string::out) is semidet.

kind_against_literal(Env, A, B, Lit) :-
    ( if fault_kind_read(Env, A), B = ex_string(L, _) then
        Lit = L
    else
        fault_kind_read(Env, B),
        A = ex_string(Lit, _)
    ).

    %@helper
:- pred fault_kind_read(type_env::in, lgra_9_3_1_expr::in) is semidet.

fault_kind_read(Env, ex_slot(ex_name(Binding), Slot, _)) :-
    Slot ^ id_name = "kind",
    map.search(Env ^ te_scope ^ rsc_bindings, Binding ^ id_name, PB),
    PB ^ pb_head = head_local(Schema),
    Schema ^ as_lifecycle = al_internal,
    Schema ^ as_name ^ id_name = "ComputationError".

    %@spec [LERR.9.2]
:- pred lerr_9_2_trap_kind(string::in) is semidet.

lerr_9_2_trap_kind("DIVIDE_BY_ZERO").
lerr_9_2_trap_kind("DOMAIN").
lerr_9_2_trap_kind("NOT_REPRESENTABLE").

    %@spec [LNUL.4.4]
:- func lnul_4_4_null_literals(list(lgra_9_3_2_compare_step),
                               list(lgra_9_3_1_expr)) = list(diagnostic).

lnul_4_4_null_literals([], _) = [].
lnul_4_4_null_literals([Step | Steps], Operands) = Found :-
    ( if Operands = [A, B | Rest] then
        Op = Step ^ cs_op,
        ( if
            ( Op = co_eq ; Op = co_ne ),
            ( A = ex_null(_) ; B = ex_null(_) )
        then
            Here = [with_hint(error_at(dv_null_literal_comparison,
                Step ^ cs_pos,
                "`null` as an operand of `==` or `!=` is a compile error: the "
                    ++ "comparison propagates `null` and is never true "
                    ++ "([LNUL.4.4])"),
                "test absence with `x is null` or `x is not null`")]
        else
            Here = []
        ),
        Found = Here ++ lnul_4_4_null_literals(Steps, [B | Rest])
    else
        Found = []
    ).

    % Only two operands of settled families can mismatch.
    %
    %@helper
:- func adjacent_mismatches(type_env, list(lgra_9_3_2_compare_step),
                            list(lgra_9_3_1_expr), list(lexp_7_type))
    = list(diagnostic).

adjacent_mismatches(_, [], _, _) = [].
adjacent_mismatches(Env, [Step | Steps], Operands, Types) = Mismatches :-
    ( if
        Types = [TA, TB | TRest],
        Operands = [_, B | ORest]
    then
        ( if
            TA = ty_known(IntervalA),
            TB = ty_known(IntervalB),
            IntervalA ^ dt_leaf = lk_interval(ElementA),
            IntervalB ^ dt_leaf = lk_interval(ElementB)
        then
            ( if lopq_3_3_ordering(Step ^ cs_op) then
                Here = [with_hint(error_at(dv_interval_no_ordering,
                    Step ^ cs_pos,
                    "intervals have no ordering; only `==` and `!=` compare "
                        ++ "two intervals ([LINT.5.3])"),
                    "order them by an endpoint: `a.start < b.start`")]
            else if
                ElementA = yes(EA),
                ElementB = yes(EB),
                settled_family(EA, FamilyA),
                settled_family(EB, FamilyB),
                FamilyA \= FamilyB
            then
                Here = [with_hint(error_at(dv_type_mismatch, Step ^ cs_pos,
                    "cannot compare an interval of " ++ FamilyA
                        ++ " with one of " ++ FamilyB ++ " ([LINT.5.4])"),
                    "both intervals must have one element type")]
            else
                Here = []
            )
        else if
            lopq_3_3_ordering(Step ^ cs_op),
            opaque_operand(TA, TB, OpaqueName)
        then
            Here = [with_hint(error_at(dv_opaque_no_op, Step ^ cs_pos,
                "an opaque `" ++ OpaqueName ++ "` has no ordering; v1 seals "
                    ++ "everything but equality ([LOPQ.3.3])"),
                "`==` and `!=` are always available -- an equality join is "
                    ++ "how a rule matches an opaque value ([LOPQ.3.1])")]
        else if
            % [LOPQ.2.3].
            TA = ty_known(OA),
            TB = ty_known(OB),
            ( OA ^ dt_leaf = lk_opaque(_)
            ; OB ^ dt_leaf = lk_opaque(_)
            ),
            OA ^ dt_leaf \= OB ^ dt_leaf
        then
            Here = [with_hint(error_at(dv_opaque_type_mismatch, Step ^ cs_pos,
                "cannot compare " ++ leaf_text(OA ^ dt_leaf) ++ " with "
                    ++ leaf_text(OB ^ dt_leaf) ++ ": an opaque type is "
                    ++ "distinct from every other type, its representation "
                    ++ "included ([LOPQ.2.3])"),
                "compare two values of the same opaque type")]
        else if
            % [LEXP.7.19], whatever the other operand is, so ahead of the
            % cross-family arm. A `Json` path read is `ty_unknown` and never
            % reaches this.
            lopq_3_3_ordering(Step ^ cs_op),
            unordered_operand(TA, TB, UnorderedName)
        then
            Here = [with_hint(error_at(dv_unordered_type, Step ^ cs_pos,
                "a " ++ UnorderedName ++ " value has no ordering"),
                "only `==` and `!=` compare `Bytes` and whole `Json` values; "
                    ++ "to order by part of a `Json` value, read a path "
                    ++ "(`p.doc.n > 3`)")]
        else if
            % [LEXP.7.20]'s fact references are what types as `lk_fact`.
            lopq_3_3_ordering(Step ^ cs_op),
            fact_operand(TA, TB, Schema)
        then
            Here = [with_hint(error_at(dv_unordered_type, Step ^ cs_pos,
                "a fact reference (" ++ Schema ++ ") has no ordering"),
                "`==` and `!=` ask whether two references name the same "
                    ++ "fact; to order facts, compare a slot (`a.ts < b.ts`)")]
        else if
            TA = ty_known(KA),
            TB = ty_known(KB),
            settled_family(KA ^ dt_leaf, FamilyA),
            settled_family(KB ^ dt_leaf, FamilyB),
            FamilyA \= FamilyB
        then
            Here = [with_hint(error_at(dv_type_mismatch, Step ^ cs_pos,
                "cannot compare " ++ FamilyA ++ " with " ++ FamilyB
                    ++ ": cross-type comparison is a compile error "
                    ++ "([LTIM.5.5])"),
                "convert one side explicitly -- `t.date(tz) < d` is the "
                    ++ "clause's own example")]
        else if
            % A comparison combines dimensions as the additive row does
            % ([LUNI.8.1]). One `implicit` formula makes the pair comparable
            % ([LUNI.4.5.1]).
            TA = ty_known(DimKA),
            TB = ty_known(DimKB),
            luni_8_1_combine(op_additive, DimKA ^ dt_dim, DimKB ^ dt_dim)
                = dr_cross_dimension(DimA, DimB),
            Bridge = luni_4_5_implicit_bridge(Env, DimA, DimB),
            Bridge \= bridge_one
        then
            ( if Bridge = bridge_ambiguous then
                Here = [with_hint(error_at(dv_formula_ambiguous, Step ^ cs_pos,
                    "two `implicit` formulas bridge `" ++ DimA ^ dr_name
                        ++ "` and `"
                        ++ DimB ^ dr_name ++ "`, so this comparison has no unique "
                        ++ "conversion ([LUNI.4.5])"),
                    "drop `implicit` from all but one of them")]
            else if luni_13_1_currency(DimA), luni_13_1_currency(DimB) then
                Here = [with_hint(error_at(dv_currency_cross_compare,
                    Step ^ cs_pos,
                    "cannot compare `" ++ DimA ^ dr_name ++ "` with `"
                        ++ DimB ^ dr_name
                        ++ "`: two currencies are two dimensions "
                        ++ "([LUNI.13.7])"),
                    "convert one side explicitly with a rate and a round "
                        ++ "mode -- `.to_currency(<fx_pair>).round(<mode>)`")]
            else
                Here = [with_hint(error_at(dv_dim_mismatch, Step ^ cs_pos,
                    "cannot compare `" ++ DimA ^ dr_name ++ "` with `"
                        ++ DimB ^ dr_name
                        ++ "`: they are different dimensions ([LUNI.8.2])"),
                    "convert one side, or strip both with `::Float`")]
            )
        else
            Here = []
        ),
        Mismatches = Here
            ++ adjacent_mismatches(Env, Steps, [B | ORest], [TB | TRest])
    else
        Mismatches = []
    ).

    %@helper
:- func leaf_text(leaf_kind) = string.

leaf_text(Leaf) =
    ( if Leaf = lk_opaque(Name) then
        "an opaque `" ++ Name ^ dr_name ++ "`"
    else if settled_family(Leaf, Family) then
        Family
    else
        "a value of another type"
    ).

    %@helper
:- pred opaque_operand(lexp_7_type::in, lexp_7_type::in, string::out)
    is semidet.

opaque_operand(TA, TB, Name) :-
    ( if TA = ty_known(A), A ^ dt_leaf = lk_opaque(Left) then
        Name = Left ^ dr_name
    else
        TB = ty_known(B),
        B ^ dt_leaf = lk_opaque(Right),
        Name = Right ^ dr_name
    ).

    %@helper
:- pred unordered_operand(lexp_7_type::in, lexp_7_type::in, string::out)
    is semidet.

unordered_operand(TA, TB, Name) :-
    ( if TA = ty_known(A), unordered_leaf(A ^ dt_leaf, Left) then
        Name = Left
    else
        TB = ty_known(B),
        unordered_leaf(B ^ dt_leaf, Name)
    ).

    %@helper
:- pred unordered_leaf(leaf_kind::in, string::out) is semidet.

unordered_leaf(lk_bytes, "`Bytes`").
unordered_leaf(lk_json, "whole `Json`").

    %@helper
:- pred fact_operand(lexp_7_type::in, lexp_7_type::in, string::out)
    is semidet.

fact_operand(TA, TB, Schema) :-
    ( if TA = ty_known(A), A ^ dt_leaf = lk_fact(Left) then
        Schema = Left
    else
        TB = ty_known(B),
        B ^ dt_leaf = lk_fact(Schema)
    ).

    % `co_eq` and `co_ne` are absent: [LOPQ.3.1] has no check of its own.
    %
    %@spec [LOPQ.3.3]
    %@spec [LOPQ.3.1]
:- pred lopq_3_3_ordering(lgra_9_3_2_compare_op::in) is semidet.

lopq_3_3_ordering(co_lt).
lopq_3_3_ordering(co_le).
lopq_3_3_ordering(co_gt).
lopq_3_3_ordering(co_ge).

    % Either direction counts. By distinct name: `rf_units` holds a library's
    % unit group once per item imported from it.
    %
luni_4_5_implicit_bridge(Env, DimA, DimB) = Bridge :-
    Names = list.filter_map(bridging_name(Env, DimA, DimB),
        Env ^ te_file ^ rf_units),
    Distinct = list.remove_dups(Names),
    (
        Distinct = [],
        Bridge = bridge_none
    ;
        Distinct = [_],
        Bridge = bridge_one
    ;
        Distinct = [_, _ | _],
        Bridge = bridge_ambiguous
    ).

    %@helper
:- func bridging_name(type_env, decl_ref, decl_ref, ast_unit) = string is semidet.

bridging_name(Env, DimA, DimB, Unit) = Unit ^ auf_name ^ id_name :-
    bridges_pair(Env, DimA, DimB, Unit).

    %@helper
:- pred bridges_pair(type_env::in, decl_ref::in, decl_ref::in,
                     ast_unit::in) is semidet.

bridges_pair(Env, DimA, DimB, Unit) :-
    Unit = au_formula(_, Modifiers, Lines, _),
    list.member(afm_implicit(_), Modifiers),
    list.member(Line, Lines),
    unit_dimension(Env, Line ^ afl_param_type, From),
    unit_dimension(Env, Line ^ afl_return, To),
    ( From = DimA, To = DimB
    ; From = DimB, To = DimA
    ).

    %@helper
:- pred unit_dimension(type_env::in, ident::in, decl_ref::out) is semidet.

unit_dimension(Env, Id, Dimension) :-
    map.search(Env ^ te_file ^ rf_types, Id ^ id_name, te_unit(Kind, Declared)),
    (
        Kind = uk_symbol(Dimension)
    ;
        % A currency has no unit symbol ([LUNI.13.1]).
        Kind = uk_dimension,
        Dimension = Declared
    ).

    %@spec [LUNI.13.1]
:- pred luni_13_1_currency(decl_ref::in) is semidet.

luni_13_1_currency(Dimension) :-
    string.prefix(Dimension ^ dr_name, "currency_").

    % `lk_json`, `lk_interval`, `lk_fact` and `lk_opaque` have no family: each
    % has its own clauses on what it may be compared with.
    %
    %@helper
:- pred settled_family(leaf_kind::in, string::out) is semidet.

settled_family(lk_int, "a number").
settled_family(lk_float, "a number").
settled_family(lk_string, "a String").
settled_family(lk_bool, "a Bool").
settled_family(lk_bytes, "Bytes").
settled_family(lk_time, "a Time").
settled_family(lk_date, "a Date").
settled_family(lk_duration, "a Duration").

%-----------------------------------------------------------------------------%
% Binary operators
%-----------------------------------------------------------------------------%

    %@spec [LNUL.5.3]
:- func lnul_5_3_binary_type(type_env, lgra_9_3_1_binary_op, lgra_9_3_1_expr,
                    lgra_9_3_1_expr, pos) = lexp_7_type.

lnul_5_3_binary_type(Env, Op, Left, Right, Pos) = Type :-
    (
        % `and` narrows to its right and `or` does not ([LNUL.5.4]).
        Op = bo_and,
        Type = kleene_bool_narrowing(Env, Left, Right)
    ;
        Op = bo_or,
        Type = kleene_bool(Env, [Left, Right])
    ;
        % The result takes the default's type ([LNUL.5.4]).
        Op = bo_coalesce,
        RightType = type_of_expr(Env, Right),
        LeftType = type_of_expr(Env, Left),
        (
            LeftType = ty_error(Ds),
            Type = ty_error(Ds)
        ;
            ( LeftType = ty_known(_)
            ; LeftType = ty_unknown
            ),
            (
                RightType = ty_known(K),
                Type = ty_known(K ^ dt_null := non_null)
            ;
                RightType = ty_unknown,
                Type = ty_unknown
            ;
                RightType = ty_error(Ds),
                Type = ty_error(Ds)
            )
        )
    ;
        ( Op = bo_add ; Op = bo_sub
        ; Op = bo_mul ; Op = bo_div ; Op = bo_floordiv ; Op = bo_mod
        ; Op = bo_pow
        ),
        Type = lexp_7_1a_arithmetic(Env, Op, Left, Right, Pos)
    ;
        ( Op = bo_bitor ; Op = bo_bitxor ; Op = bo_bitand
        ; Op = bo_shl ; Op = bo_shr
        ),
        Type = lexp_7_7_bitwise(Env, Op, Left, Right, Pos)
    ;
        Op = bo_interval,
        Type = lint_2_2_interval(Env, Left, Right, Pos)
    ;
        Op = bo_in,
        Type = lint_3_1_3_in(Env, Left, Right, Pos)
    ;
        ( Op = bo_contains
        ; Op = bo_overlaps
        ),
        Type = lint_4_5_relation(Env, Op, Left, Right, Pos)
    ).

%-----------------------------------------------------------------------------%
% Intervals -- [LINT]
%-----------------------------------------------------------------------------%

    % An unlisted operand is refused before a mixed pair: `w.lo .. w.b0`'s
    % `Bool` is wrong whatever it is joined to.
    %
    %@spec [LINT.1.2]
    %@spec [LINT.2.2]
    %@spec [LINT.7.4]
:- func lint_2_2_interval(type_env, lgra_9_3_1_expr, lgra_9_3_1_expr, pos)
    = lexp_7_type.

lint_2_2_interval(Env, Left, Right, Pos) = Type :-
    LeftType = type_of_expr(Env, Left),
    RightType = type_of_expr(Env, Right),
    Errors = list.condense(list.filter_map(errors_of, [LeftType, RightType])),
    ( if Errors = [_ | _] then
        Type = ty_error(Errors)
    else if interval_unlisted_operand(LeftType, RightType, Unlisted) then
        Type = ty_error([with_hint(error_at(dv_unordered_type, Pos,
            "`..` over " ++ Unlisted ++ ", which has no ordering; an "
                ++ "interval's endpoints are of a type `<` orders "
                ++ "([LINT.1.1], [LINT.2.2])"),
            "an interval ranges over `Int`, `Float`, `String`, `Time`, `Date` "
                ++ "or `Duration`")])
    else if
        LeftType = ty_known(L),
        RightType = ty_known(R),
        settled_family(L ^ dt_leaf, FamilyL),
        settled_family(R ^ dt_leaf, FamilyR),
        FamilyL \= FamilyR
    then
        Type = ty_error([with_hint(error_at(dv_interval_mixed_operands, Pos,
            "`..` joins " ++ FamilyL ++ " to " ++ FamilyR ++ "; both "
                ++ "endpoints of an interval have one type ([LINT.2.2])"),
            "convert one endpoint explicitly")])
    else if
        Left = ex_int(Start, _),
        Right = ex_int(End, _),
        End < Start
    then
        Type = ty_error([with_hint(error_at(dv_interval_inverted, Pos,
            "`" ++ int64_to_string(Start) ++ " .. " ++ int64_to_string(End)
                ++ "` ends before it starts ([LINT.7.4])"),
            "an interval runs from its start to a later end; swap the "
                ++ "endpoints")])
    else
        % An interval with an absent endpoint is absent ([LNUL.4.1]).
        ( if
            ( LeftType = ty_known(KL), KL ^ dt_null = nullable
            ; RightType = ty_known(KR), KR ^ dt_null = nullable
            )
        then
            Null = nullable
        else
            Null = non_null
        ),
        Type = ty_known(ds_type(lk_interval(interval_element(LeftType,
            RightType)), dimensionless, Null))
    ).

    %@helper
:- pred interval_unlisted_operand(lexp_7_type::in, lexp_7_type::in,
    string::out) is semidet.

interval_unlisted_operand(TA, TB, Name) :-
    ( if TA = ty_known(A), lint_1_1_unlisted(A ^ dt_leaf) = yes(Left) then
        Name = Left
    else
        TB = ty_known(B),
        lint_1_1_unlisted(B ^ dt_leaf) = yes(Name)
    ).

    % `no` for the six [LINT.1.1] lists, and the name of every other leaf kind.
    % A unit value's leaf is its storage kind, so it is listed.
    %
    %@spec [LINT.1.1]
:- func lint_1_1_unlisted(leaf_kind) = maybe(string).

lint_1_1_unlisted(lk_int) = no.
lint_1_1_unlisted(lk_float) = no.
lint_1_1_unlisted(lk_string) = no.
lint_1_1_unlisted(lk_time) = no.
lint_1_1_unlisted(lk_date) = no.
lint_1_1_unlisted(lk_duration) = no.
lint_1_1_unlisted(lk_bool) = yes("`Bool`").
lint_1_1_unlisted(lk_bytes) = yes("`Bytes`").
lint_1_1_unlisted(lk_json) = yes("a whole `Json` value").
lint_1_1_unlisted(lk_fact(Schema)) = yes("a fact reference (" ++ Schema ++ ")").
lint_1_1_unlisted(lk_opaque(Name)) = yes("the opaque `" ++ Name ^ dr_name ++ "`").
lint_1_1_unlisted(lk_interval(_)) = yes("an interval").

    %@helper
:- func interval_element(lexp_7_type, lexp_7_type) = maybe(leaf_kind).

interval_element(LeftType, RightType) = Element :-
    ( if LeftType = ty_known(K) then
        Element = yes(K ^ dt_leaf)
    else if RightType = ty_known(K) then
        Element = yes(K ^ dt_leaf)
    else
        Element = no
    ).

    %@spec [LINT.3.1.3]
:- func lint_3_1_3_in(type_env, lgra_9_3_1_expr, lgra_9_3_1_expr, pos)
    = lexp_7_type.

lint_3_1_3_in(Env, Left, Right, Pos) = Type :-
    PointType = type_of_expr(Env, Left),
    IntervalType = type_of_expr(Env, Right),
    Errors = list.condense(list.filter_map(errors_of,
        [PointType, IntervalType])),
    ( if Errors = [_ | _] then
        Type = ty_error(Errors)
    else if
        PointType = ty_known(P),
        IntervalType = ty_known(I),
        I ^ dt_leaf = lk_interval(yes(Element)),
        settled_family(P ^ dt_leaf, FamilyP),
        settled_family(Element, FamilyE),
        FamilyP \= FamilyE
    then
        Type = ty_error([with_hint(error_at(dv_type_mismatch, Pos,
            "`in` tests " ++ FamilyP ++ " against an interval of " ++ FamilyE
                ++ "; the point and the interval must have one element type "
                ++ "([LINT.3.1.3])"),
            "convert the point or the endpoints explicitly")])
    else
        Type = kleene_bool(Env, [Left, Right])
    ).

    %@spec [LINT.3.2.2]
    %@spec [LINT.4.2]
    %@spec [LINT.4.5]
:- func lint_4_5_relation(type_env, lgra_9_3_1_binary_op, lgra_9_3_1_expr,
                          lgra_9_3_1_expr, pos) = lexp_7_type.

lint_4_5_relation(Env, Op, Left, Right, Pos) = Type :-
    ( if Op = bo_contains then Name = "contains" else Name = "overlaps" ),
    LeftType = type_of_expr(Env, Left),
    RightType = type_of_expr(Env, Right),
    Errors = list.condense(list.filter_map(errors_of, [LeftType, RightType])),
    ( if Errors = [_ | _] then
        Type = ty_error(Errors)
    else if
        ( scalar_literal(Left)
        ; scalar_literal(Right)
        )
    then
        Type = ty_error([with_hint(error_at(dv_interval_rel_non_interval, Pos,
            "`" ++ Name ++ "` relates two intervals, and one operand is a "
                ++ "literal of another kind ([LINT.4.5])"),
            "build the interval with `..`, or test a point with `in`")])
    else if
        LeftType = ty_known(L),
        RightType = ty_known(R),
        L ^ dt_leaf = lk_interval(yes(ElementL)),
        R ^ dt_leaf = lk_interval(yes(ElementR)),
        settled_family(ElementL, FamilyL),
        settled_family(ElementR, FamilyR),
        FamilyL \= FamilyR
    then
        Type = ty_error([with_hint(error_at(dv_type_mismatch, Pos,
            "`" ++ Name ++ "` relates an interval of " ++ FamilyL
                ++ " to one of " ++ FamilyR ++ " ([LINT.3.2.2], [LINT.4.2])"),
            "both intervals must have one element type")])
    else
        Type = kleene_bool(Env, [Left, Right])
    ).

    %@helper
:- pred scalar_literal(lgra_9_3_1_expr::in) is semidet.

scalar_literal(ex_int(_, _)).
scalar_literal(ex_float(_, _)).
scalar_literal(ex_string(_, _)).
scalar_literal(ex_bool(_, _)).
scalar_literal(ex_unit(_, _, _)).

    % An unknown element's `duration` types as `Duration`.
    %
    %@spec [LINT.6.1]
    %@spec [LINT.6.2]
:- func lint_6_1_component(maybe(leaf_kind), ident) = lexp_7_type.

lint_6_1_component(Element, Field) = Type :-
    Name = Field ^ id_name,
    ( if ( Name = "start" ; Name = "end" ) then
        (
            Element = yes(E),
            Type = ty_known(ds_type(E, dimensionless, non_null))
        ;
            Element = no,
            Type = ty_unknown
        )
    else if
        Name = "duration",
        Element = yes(E),
        E \= lk_time,
        E \= lk_date
    then
        Type = ty_error([with_hint(error_at(dv_bad_interval_component,
            Field ^ id_pos,
            "`duration` of an interval of " ++ leaf_text(E) ++ ": only a "
                ++ "`Time` or `Date` interval has one ([LINT.6.1])"),
            "subtract the endpoints: `i.end - i.start`")])
    else if Name = "duration" then
        Type = scalar(lk_duration)
    else
        Type = ty_error([with_hint(error_at(dv_bad_interval_component,
            Field ^ id_pos,
            "`" ++ Name ++ "` is not a component of an interval ([LINT.6.1])"),
            "an interval has `start`, `end` and `duration`")])
    ).

%-----------------------------------------------------------------------------%
% Arithmetic -- [LEXP.7.1a] through [LEXP.7.6]
%-----------------------------------------------------------------------------%

    %@spec [LEXP.7.1a]
    %@spec [LEXP.7.2]
    %@spec [LEXP.7.3]
    %@spec [LEXP.7.4]
    %@spec [LEXP.7.5]
    %@spec [LEXP.7.6]
:- func lexp_7_1a_arithmetic(type_env, lgra_9_3_1_binary_op,
                             lgra_9_3_1_expr, lgra_9_3_1_expr, pos)
    = lexp_7_type.

lexp_7_1a_arithmetic(Env, Op, Left, Right, Pos) = Type :-
    LeftType = type_of_expr(Env, Left),
    RightType = type_of_expr(Env, Right),
    % A `T?` operand propagates ([LNUL.5.1]), and is refused where it escapes.
    ( if Both = both_known(LeftType, RightType) then
        Both = pair_of(L, R),
        ( if Temporal = ltim_4_1_1_temporal(Op, L ^ dt_leaf, R ^ dt_leaf) then
            Subday = ltim_4_2_2_whole_day(L, R, Left, Right, Pos),
            (
                Subday = [_ | _],
                Type = ty_error(Subday)
            ;
                Subday = [],
                Type = ty_known(ds_type(Temporal, dimensionless,
                    propagated(L, R)))
            )
        else if lexp_7_1a_numeric(L ^ dt_leaf), lexp_7_1a_numeric(R ^ dt_leaf)
        then
            Dim = luni_8_1_combine(luni_8_3_class_of(Op), L ^ dt_dim, R ^ dt_dim),
            (
                Dim = dr_ok(ResultDim),
                Type = ty_known(ds_type(lexp_7_2_arith_leaf(Op, L, R, Right),
                    ResultDim, propagated(L, R)))
            ;
                Dim = dr_cross_dimension(LeftDim, RightDim),
                Type = ty_error([with_hint(error_at(dv_dim_mismatch, Pos,
                    "`" ++ LeftDim ^ dr_name ++ "` and `" ++ RightDim ^ dr_name
                        ++ "` are different dimensions ([LUNI.8.2])"),
                    "convert one side, or strip both with `::Float`")])
            ;
                Dim = dr_needs_annotation(LeftDim, RightDim),
                Type = luni_8_4_ambiguous(Env, LeftDim, RightDim, Pos)
            )
        else
            Type = ty_error([with_hint(error_at(dv_bad_operand_type, Pos,
                "the arithmetic operators take `Int` or `Float` "
                    ++ "([LEXP.7.1a])"),
                "there is no string `+`; build strings with interpolation")])
        )
    else
        Type = merge_unknown(LeftType, RightType)
    ).

    % By value, on a literal with a whole magnitude: `24_h` is legal and `12_h`
    % is not. A fractional magnitude (`0.5_d`) is not judged here.
    %
    %@spec [LTIM.4.2.2]
:- func ltim_4_2_2_whole_day(ds_type, ds_type, lgra_9_3_1_expr,
                             lgra_9_3_1_expr, pos) = list(diagnostic).

ltim_4_2_2_whole_day(L, R, Left, Right, Pos) = Diagnostics :-
    ( if
        L ^ dt_leaf = lk_date,
        R ^ dt_leaf = lk_duration,
        literal_nanoseconds(Right, Ns),
        Ns mod day_nanoseconds \= 0i64
    then
        Diagnostics = [with_hint(error_at(dv_date_subday_arithmetic, Pos,
            "a `Date` has no time-of-day, so it takes a whole number of days "
                ++ "([LTIM.4.2.2])"),
            "use `1_d` / `7_d`, or a whole multiple of 24 hours -- `24_h` and "
                ++ "`1440_min` are the same duration and are legal")]
    else
        Diagnostics = ( if
                        L ^ dt_leaf = lk_duration,
                        R ^ dt_leaf = lk_date,
                        literal_nanoseconds(Left, LeftNs),
                        LeftNs mod day_nanoseconds \= 0i64
                      then
                        [with_hint(error_at(dv_date_subday_arithmetic, Pos,
                            "a `Date` has no time-of-day, so it takes a whole "
                                ++ "number of days ([LTIM.4.2.2])"),
                            "use `1_d` / `7_d`, or a whole multiple of 24 "
                                ++ "hours")]
                      else
                        []
                      )
    ).

    %@helper
:- func day_nanoseconds = int64.

day_nanoseconds = 86400000000000i64.

    %@helper
:- pred literal_nanoseconds(lgra_9_3_1_expr::in, int64::out) is semidet.

literal_nanoseconds(ex_unit(Magnitude, RawSuffix, _), Nanoseconds) :-
    i64.from_decimal(Magnitude, Whole),
    luni_10_2_time_unit(llex_12_5_symbol_of(RawSuffix), Multiplier),
    Nanoseconds = Whole * Multiplier.

%-----------------------------------------------------------------------------%

lnul_5_1_concrete(_Env, Expr, Type, Pos, Position) = Diagnostics :-
    ( if
        Type = ty_known(Known),
        Known ^ dt_null = nullable
    then
        Diagnostics = [with_hint(error_at(dv_nullable_unnarrowed, Pos,
            described(Expr) ++ " may be null, and " ++ Position
                ++ " is a concrete-value position ([LNUL.5.1])"),
            "guard it -- `" ++ narrowing_hint(Expr)
                ++ " is not null and ...` -- or supply a default with `??`")]
    else
        Diagnostics = []
    ).

    %@helper
:- pred narrowed_here(type_env::in, lgra_9_3_1_expr::in) is semidet.

narrowed_here(Env, Expr) :-
    Path = lnul_5_4_path(Expr),
    set.contains(Env ^ te_narrowed, Path).

    %@helper
:- func described(lgra_9_3_1_expr) = string.

described(Expr) =
    ( if Path = lnul_5_4_path(Expr) then
        "`" ++ Path ++ "`"
    else
        "this value"
    ).

    %@helper
:- func narrowing_hint(lgra_9_3_1_expr) = string.

narrowing_hint(Expr) =
    ( if Path = lnul_5_4_path(Expr) then Path else "<value>" ).

    % The annotated case is `ty_unknown`: the annotation's type is the binding's
    % ([LUNI.8.6]), read through `rsc_let_types`.
    %
    %@spec [LUNI.8.4]
:- func luni_8_4_ambiguous(type_env, decl_ref, decl_ref, pos) = lexp_7_type.

luni_8_4_ambiguous(Env, LeftDim, RightDim, Pos) = Type :-
    (
        Env ^ te_ambiguity = da_annotated,
        Type = ty_unknown
    ;
        Env ^ te_ambiguity = da_reported,
        Type = ty_error([with_hint(error_at(dv_dim_ambiguous, Pos,
            "a result combining `" ++ LeftDim ^ dr_name ++ "` and `"
                ++ RightDim ^ dr_name
                ++ "` has no inferrable unit: DS performs no unit "
                ++ "algebra ([LUNI.8.4])"),
            "annotate the result with `let x: <unit> = …`, or strip "
                ++ "the units with `::Float`")])
    ).

    %@spec [LEXP.7.2]
    %@spec [LEXP.7.3]
    %@spec [LEXP.7.4]
:- func lexp_7_2_arith_leaf(lgra_9_3_1_binary_op, ds_type, ds_type,
                            lgra_9_3_1_expr) = leaf_kind.

lexp_7_2_arith_leaf(Op, L, R, RightExpr) = Leaf :-
    ( if Op = bo_div then
        Leaf = lk_float
    else if Op = bo_pow then
        Leaf = lexp_7_3a_pow_leaf(L, R, RightExpr)
    else if L ^ dt_leaf = lk_int, R ^ dt_leaf = lk_int then
        Leaf = lk_int
    else
        Leaf = lk_float
    ).

    %@spec [LEXP.7.3a]
    %@spec [LEXP.7.3a.1]
:- func lexp_7_3a_pow_leaf(ds_type, ds_type, lgra_9_3_1_expr) = leaf_kind.

lexp_7_3a_pow_leaf(L, R, RightExpr) = Leaf :-
    ( if
        L ^ dt_leaf = lk_int,
        R ^ dt_leaf = lk_int,
        RightExpr = ex_int(N, _),
        N >= 0i64
    then
        Leaf = lk_int
    else
        Leaf = lk_float
    ).

    %@spec [LUNI.8.3]
:- func luni_8_3_class_of(lgra_9_3_1_binary_op) = luni_8_3_operator.

luni_8_3_class_of(Op) = Class :-
    ( if Op = bo_pow then
        Class = op_exponent
    else if ( Op = bo_mul ; Op = bo_div ; Op = bo_floordiv ) then
        Class = op_multiplicative
    else
        Class = op_additive
    ).

    %@spec [LEXP.7.1a]
:- pred lexp_7_1a_numeric(leaf_kind::in) is semidet.

lexp_7_1a_numeric(lk_int).
lexp_7_1a_numeric(lk_float).

%-----------------------------------------------------------------------------%
% Calls
%-----------------------------------------------------------------------------%

    %@spec [LEXP.5.3]
    %@spec [LOPQ.4.1]
:- func lexp_5_3_call(type_env, lgra_9_3_1_expr, list(lgra_9_3_1_expr), pos)
    = lexp_7_type.

lexp_5_3_call(Env, Callee, Args, Pos) = Type :-
    ( if
        Callee = ex_name(LatestId),
        LatestId ^ id_name = "latest"
    then
        Type = lgra_9_8_2_latest(LatestId, list.length(Args), Pos)
    else if
        % `dsc.validate.lgra_9_8_3_json_refused` refuses every call.
        Callee = ex_name(JsonId),
        JsonId ^ id_name = "json"
    then
        Type = ty_unknown
    else if
        % Before any receiver is typed: `distance` in `distance.levenshtein(...)`
        % is no binding.
        lgra_22_9_library_member(Env ^ te_file, Callee, LibPath, LibMember)
    then
        Type = lgra_22_9_member_call(Env, LibPath, LibMember, Args)
    else if
        Callee = ex_slot(DateReceiver, DateMethod, _),
        DateMethod ^ id_name = "date",
        Args = [],
        type_of_expr(Env, DateReceiver) = ty_known(DateType),
        DateType ^ dt_leaf = lk_time
    then
        Type = ltim_3_3_2_date(DateMethod)
    else if
        Callee = ex_name(Id),
        CursorType = lser_16_1_cursor_call(Env, Id, Args)
    then
        Type = CursorType
    else if
        % `Key(some_bytes)`, with `Key` an opaque type ([LOPQ.4.1]).
        Callee = ex_name(TypeName),
        map.search(Env ^ te_file ^ rf_types, TypeName ^ id_name, te_opaque(_))
    then
        Type = ty_error([with_hint(error_at(dv_opaque_no_op,
            TypeName ^ id_pos,
            "an opaque `" ++ TypeName ^ id_name ++ "` cannot be constructed "
                ++ "in a rule ([LOPQ.4.1])"),
            "an opaque value arrives from adapter ingest, from a declared "
                ++ "operation that returns it, or as a contract-library "
                ++ "constant ([LOPQ.4.2])")])
    else if
        % A method on an opaque receiver ([LOPQ.3.3]).
        Callee = ex_slot(Receiver, Method, _),
        type_of_expr(Env, Receiver) = ty_known(ReceiverType),
        ReceiverType ^ dt_leaf = lk_opaque(Sealed)
    then
        Type = ty_error([with_hint(error_at(dv_opaque_no_op, Method ^ id_pos,
            "`" ++ Method ^ id_name ++ "` is a method of the representation, "
                ++ "and an opaque `" ++ Sealed ^ dr_name
                ++ "` is sealed ([LOPQ.3.3])"),
            "only equality and the operations the type declares reach an "
                ++ "opaque value")])
    else if
        Callee = ex_slot(Receiver, Method, _),
        luni_13_5_3_currency_method(Method ^ id_name)
    then
        Type = luni_13_5_3_method(Env, Receiver, Method, Args)
    else if
        Callee = ex_slot(_, Method, _),
        ( Method ^ id_name = "encode"
        ; Method ^ id_name = "decode"
        )
    then
        % Refused whatever the receiver ([LSTR.4.6]).
        Type = lstr_4_6_retired_method(Method)
    else if
        % [LTIM.8.1.2]'s members with their format. Formatless, and a
        % `Duration`'s in any form, fall to `lgra_9_6_2_member_call`, which
        % refuses the spelling and names the cast ([LGRA.9.6.3]).
        Callee = ex_slot(Receiver, Method, _),
        Method ^ id_name = "to_string",
        Args = [_],
        type_of_expr(Env, Receiver) = ty_known(ReceiverType),
        ( ReceiverType ^ dt_leaf = lk_time
        ; ReceiverType ^ dt_leaf = lk_date
        )
    then
        Type = ltim_8_1_2_to_string(ReceiverType, Method, Args)
    else if
        Callee = ex_slot(Receiver, Method, _),
        Method ^ id_name = "date",
        Args = [_],
        type_of_expr(Env, Receiver) = ty_known(ReceiverType),
        ReceiverType ^ dt_leaf = lk_time
    then
        Type = ltim_3_3_1_date(Env, ReceiverType, Args)
    else if
        Callee = ex_slot(Receiver, Method, _),
        ReceiverType = type_of_expr(Env, Receiver),
        member_receiver(ReceiverType)
    then
        Type = lgra_9_6_2_member_call(Env, ReceiverType, Method, Args, Pos)
    else if
        Callee = ex_name(Id),
        lgra_9_6_3_retired(Env, Id, Args, Retired)
    then
        Type = ty_error([Retired])
    else
        Type = lexp_5_3_plain_call(Env, Callee, Args, Pos)
    ).

    % A call of an imported library's member that `dsc.libcall` did not rewrite
    % to a builtin row, so it names nothing callable. `lib.NOPE` not called is
    % `limp_4_3_2_qualified_const`'s.
    %
    %@spec [LGRA.22.9]
    %@spec [LGRA.22.7]
    %@spec [LIMP.3.3.4]
:- func lgra_22_9_member_call(type_env, list(ident), ident,
                              list(lgra_9_3_1_expr)) = lexp_7_type.

lgra_22_9_member_call(Env, LibPath, Member, Args) = Type :-
    ArgErrors = list.condense(list.filter_map(errors_of,
        list.map(type_of_expr(Env), Args))),
    (
        ArgErrors = [_ | _],
        Type = ty_error(ArgErrors)
    ;
        ArgErrors = [],
        Lib = string.join_list(".",
            list.map((func(I) = I ^ id_name), LibPath)),
        Name = Lib ++ "." ++ Member ^ id_name,
        Carried = list.filter(
            ( pred(Row::in) is semidet :- string.prefix(Row, Lib ++ ".") ),
            admitted_builtin_names),
        (
            Carried = [_ | _],
            Hint = "`" ++ Lib ++ "` carries: " ++ string.join_list(", ", Carried)
        ;
            Carried = [],
            Hint = "a library's members are what its source declares; only "
                ++ "`math`, `distance` and `calendar` carry builtins "
                ++ "([LIMP.3.3.4])"
        ),
        Type = ty_error([with_hint(error_at(dv_unknown_function,
            Member ^ id_pos,
            "`" ++ Name ++ "` is not a function: `" ++ Lib ++ "` carries no "
                ++ "builtin `" ++ Member ^ id_name ++ "` ([LGRA.22.9], "
                ++ "[LGRA.22.7])"),
            Hint)])
    ).

%-----------------------------------------------------------------------------%
% Members -- [LGRA.9.6.2]
%-----------------------------------------------------------------------------%
%
% Resolved by the receiver's static type: a `ty_unknown` receiver is not judged.
% `.NAME` on a fact reads a slot and on a `Json` value a key, and an interval's
% and an opaque value's have their own paths. `Float` and `Bool` have no members,
% so `s.v.bit_count` on a `Float` is an unknown member ([LEXP.3.7.2]).

    %@helper
:- pred member_receiver(lexp_7_type::in) is semidet.

member_receiver(ty_error(_)).
member_receiver(ty_known(K)) :-
    member_leaf(K ^ dt_leaf).

    %@helper
:- pred member_leaf(leaf_kind::in) is semidet.

member_leaf(Leaf) :-
    Leaf \= lk_json,
    Leaf \= lk_interval(_),
    Leaf \= lk_fact(_),
    Leaf \= lk_opaque(_).

lgra_9_6_2_zero_arg_member("bit_count").
lgra_9_6_2_zero_arg_member("bit_length").
lgra_9_6_2_zero_arg_member("leading_zeros").
lgra_9_6_2_zero_arg_member("trailing_zeros").
lgra_9_6_2_zero_arg_member("utc").
lgra_9_6_2_zero_arg_member(Name) :-
    ltim_6_1_time_component(Name).

    % The members that take an argument list, per receiver type ([LGRA.9.6.2]).
    %
    %@helper
:- pred member_with_arguments(leaf_kind::in, string::in) is semidet.

member_with_arguments(lk_int, "bits").
member_with_arguments(lk_int, "sign_extend").
member_with_arguments(lk_int, "swap_bytes").
member_with_arguments(lk_time, "local").
member_with_arguments(lk_time, "floor").
member_with_arguments(lk_time, "add_months").
member_with_arguments(lk_time, "add_years").
member_with_arguments(lk_time, "to_string").
member_with_arguments(lk_time, "date").
member_with_arguments(lk_date, "add_months").
member_with_arguments(lk_date, "add_years").
member_with_arguments(lk_date, "to_string").

    %@spec [LGRA.9.6.2]
    %@spec [LGRA.9.6.3]
:- func lgra_9_6_2_member_call(type_env, lexp_7_type, ident,
                               list(lgra_9_3_1_expr), pos) = lexp_7_type.

lgra_9_6_2_member_call(Env, ReceiverType, Method, Args, Pos) = Type :-
    ArgTypes = list.map(type_of_expr(Env), Args),
    ArgErrors = list.condense(list.filter_map(errors_of, ArgTypes)),
    ( if ReceiverType = ty_error(ReceiverErrors) then
        Type = ty_error(ReceiverErrors ++ ArgErrors)
    else if ArgErrors = [_ | _] then
        Type = ty_error(ArgErrors)
    else if ReceiverType = ty_known(K) then
        Type = member_call_type(K, Method, Args, ArgTypes, Pos)
    else
        Type = ty_unknown
    ).

    %@helper
:- func member_call_type(ds_type, ident, list(lgra_9_3_1_expr),
                         list(lexp_7_type), pos) = lexp_7_type.

member_call_type(K, Method, Args, ArgTypes, Pos) = Type :-
    Leaf = K ^ dt_leaf,
    Null = K ^ dt_null,
    Name = Method ^ id_name,
    NArgs = list.length(Args),
    ( if
        formatless(Leaf, Name, Replacement),
        ( Args = []
        ; Leaf = lk_duration
        )
    then
        Type = retired_spelling(Method ^ id_pos,
            "`." ++ Name ++ "(" ++ ( if Args = [] then "" else "..." ) ++ ")`",
            Replacement)
    else if lgra_9_6_2_zero_arg_member(Name), member_leaf_has(Leaf, Name) then
        Type = ty_error([with_hint(error_at(dv_unknown_member, Method ^ id_pos,
            "`." ++ Name ++ "` takes no arguments and is written without an "
                ++ "argument list ([LGRA.9.6.2])"),
            "write `." ++ Name ++ "`")])
    else if member_with_arguments(Leaf, Name) then
        Arity = member_arity(Name),
        ( if NArgs = Arity then
            Type = member_result(K, Name, Args, ArgTypes, Pos)
        else
            Type = ty_error([error_at(dv_bad_arity, Pos,
                "`." ++ Name ++ "` takes " ++ string.from_int(Arity)
                    ++ ( if Arity = 1 then " argument" else " arguments" )
                    ++ ", not " ++ string.from_int(NArgs))])
        )
    else
        Type = unknown_member(Leaf, Null, Method)
    ).

    %@helper
:- func member_arity(string) = int.

member_arity(Name) = ( if Name = "bits" then 2 else 1 ).

    % A zone the resolver refuses is the runtime's to raise ([LTIM.10.5.3]).
    %
    %@spec [LTIM.3.3.1]
:- func ltim_3_3_1_date(type_env, ds_type, list(lgra_9_3_1_expr))
    = lexp_7_type.

ltim_3_3_1_date(Env, ReceiverType, Args) = Type :-
    ArgErrors = list.condense(list.filter_map(errors_of,
        list.map(type_of_expr(Env), Args))),
    (
        ArgErrors = [_ | _],
        Type = ty_error(ArgErrors)
    ;
        ArgErrors = [],
        Type = ty_known(ds_type(lk_date, dimensionless,
            ReceiverType ^ dt_null))
    ).

    %@spec [LTIM.8.1.2]
:- func ltim_8_1_2_to_string(ds_type, ident, list(lgra_9_3_1_expr))
    = lexp_7_type.

ltim_8_1_2_to_string(ReceiverType, Method, Args) = Type :-
    Errors = ltim_8_3_2_format_errors(ReceiverType ^ dt_leaf, Method, Args),
    (
        Errors = [_ | _],
        Type = ty_error(Errors)
    ;
        Errors = [],
        Type = ty_known(ds_type(lk_string, dimensionless,
            ReceiverType ^ dt_null))
    ).

    % A computed format identifier is the runtime's ([LTIM.8.3.2]).
    %
    %@spec [LTIM.8.1.3]
    %@spec [LTIM.8.3.2]
    %@spec [LTIM.8.2.1]
:- func ltim_8_3_2_format_errors(leaf_kind, ident, list(lgra_9_3_1_expr))
    = list(diagnostic).

ltim_8_3_2_format_errors(Leaf, Method, Args) = Errors :-
    Name = Method ^ id_name,
    ( if Leaf = lk_duration then
        (
            Args = [],
            Errors = []
        ;
            Args = [_ | _],
            Errors = [with_hint(error_at(dv_bad_arity, Method ^ id_pos,
                "`." ++ Name ++ "()` takes no format; the compact form is "
                    ++ "the only one ([LTIM.8.1.3])"),
                "write `." ++ Name ++ "()`")]
        )
    else if Args = [] then
        Errors = []
    else if Args = [Format] then
        ( if
            Format = ex_string(Id, IdPos),
            not ltim_8_2_1_admits(Leaf, string.to_lower(Id))
        then
            ( if Leaf = lk_date then
                Formats = "a `Date` has iso8601 only"
            else
                Formats = "the formats are iso8601, epoch_seconds, "
                    ++ "epoch_millis, epoch_micros and epoch_nanos"
            ),
            Errors = [with_hint(error_at(dv_unknown_time_format, IdPos,
                "`\"" ++ Id ++ "\"` is not " ++ leaf_text(Leaf)
                    ++ " format ([LTIM.8.3.2])"),
                Formats)]
        else
            Errors = []
        )
    else
        Errors = [with_hint(error_at(dv_bad_arity, Method ^ id_pos,
            "`." ++ Name ++ "` takes at most one argument, the format "
                ++ "([LTIM.8.1.2])"),
            "write `." ++ Name ++ "()` or `." ++ Name ++ "(\"iso8601\")`")]
    ).

    %@helper
:- pred ltim_8_2_1_admits(leaf_kind::in, string::in) is semidet.

ltim_8_2_1_admits(Leaf, Id) :-
    ( if Leaf = lk_date then
        Id = "iso8601"
    else
        ltim_8_2_1_format(Id)
    ).

    %@helper
:- func ltim_4_3_1_operand_errors(string, lexp_7_type, lexp_7_type, pos)
    = list(diagnostic).

ltim_4_3_1_operand_errors(Name, SubjectType, CountType, Pos) =
        SubjectErrors ++ CountErrors :-
    ( if
        SubjectType = ty_known(Subject),
        Subject ^ dt_leaf \= lk_time,
        Subject ^ dt_leaf \= lk_date
    then
        SubjectErrors = [with_hint(error_at(dv_bad_operand_type, Pos,
            "`" ++ Name ++ "` shifts a `Time` or a `Date`, not "
                ++ leaf_text(Subject ^ dt_leaf) ++ " ([LTIM.4.3.1])"),
            "a `Duration` is added with `+`")]
    else
        SubjectErrors = []
    ),
    ( if
        CountType = ty_known(Count),
        Count ^ dt_leaf \= lk_int
    then
        CountErrors = [error_at(dv_bad_operand_type, Pos,
            "`" ++ Name ++ "` takes an `Int` count, not "
                ++ leaf_text(Count ^ dt_leaf) ++ " ([LTIM.4.3.1])")]
    else
        CountErrors = []
    ).

    % Whether a zero-argument member belongs to this receiver type. Time
    % components belong to a `Time` only through `.utc` / `.local(tz)`, but a
    % component written with parentheses is refused for its parentheses first.
    %
    %@helper
:- pred member_leaf_has(leaf_kind::in, string::in) is semidet.

member_leaf_has(lk_int, "bit_count").
member_leaf_has(lk_int, "bit_length").
member_leaf_has(lk_int, "leading_zeros").
member_leaf_has(lk_int, "trailing_zeros").
member_leaf_has(lk_time, "utc").
member_leaf_has(lk_time, Name) :-
    ltim_6_1_time_component(Name).
member_leaf_has(lk_date, Name) :-
    ltim_6_1_date_component(Name).

    % [LGRA.9.6.3]'s member rows: the formatless members and `Duration`'s
    % `to_string`, each refused in favour of a cast.
    %
    %@helper
:- pred formatless(leaf_kind::in, string::in, string::out) is semidet.

formatless(lk_time, "to_string", "t::String ([LCST.4.5.9])").
formatless(lk_date, "to_string", "d::String ([LCST.4.5.9])").
formatless(lk_duration, "to_string", "dur::String ([LCST.4.5.9])").

    % A one-argument member's result. Each carries the receiver's
    % nullability: a member of an absent value is absent.
    %
    %@spec [LTIM.3.2.1]
    %@spec [LTIM.4.3.1]
    %@spec [LTIM.7.1]
    %@spec [LTIM.8.1.2]
:- func member_result(ds_type, string, list(lgra_9_3_1_expr),
                      list(lexp_7_type), pos) = lexp_7_type.

member_result(K, Name, Args, ArgTypes, Pos) = Type :-
    Leaf = K ^ dt_leaf,
    Null = K ^ dt_null,
    ( if Leaf = lk_int, member_with_arguments(lk_int, Name) then
        Type = lexp_3_7_3_member_type(Null, Name, ArgTypes, Pos)
    else if Leaf = lk_time, Name = "local" then
        Type = ty_known(ds_type(lk_time, dimensionless, Null))
    else if Leaf = lk_time, Name = "floor" then
        ( if
            ltim_7_1_floor_operands([ty_known(K) | ArgTypes], Pos, FloorError)
        then
            Type = ty_error([FloorError])
        else
            Type = ty_known(ds_type(lk_time, dimensionless, Null))
        )
    else if
        ( Name = "add_months" ; Name = "add_years" ),
        ArgTypes = [CountType]
    then
        ( if
            ltim_4_3_1_operand_errors(Name, ty_known(K), CountType, Pos)
                = Errors,
            Errors = [_ | _]
        then
            Type = ty_error(Errors)
        else
            Type = ty_known(ds_type(Leaf, dimensionless, Null))
        )
    else if Name = "to_string", Args = [Format] then
        Type = ltim_8_3_2_format(Format,
            ty_known(ds_type(lk_string, dimensionless, Null)))
    else
        Type = ty_unknown
    ).

    % The constant-domain refusal is `dsc.validate.lexp_3_7_4_bit_field_range`.
    %
    %@spec [LEXP.3.7.3]
:- func lexp_3_7_3_member_type(nullability, string, list(lexp_7_type), pos)
    = lexp_7_type.

lexp_3_7_3_member_type(ReceiverNull, Name, ArgTypes, Pos) = Type :-
    Errors = list.filter_map(
        ( func(ArgType::in) = (Error::out) is semidet :-
            ArgType = ty_known(A),
            A ^ dt_leaf \= lk_int,
            Error = error_at(dv_bad_operand_type, Pos,
                "`." ++ Name ++ "` takes `Int` arguments, not "
                    ++ leaf_text(A ^ dt_leaf) ++ " ([LEXP.3.7.3])")
        ), ArgTypes),
    NullableArgs = list.filter(
        ( pred(ArgType::in) is semidet :-
            ArgType = ty_known(A),
            A ^ dt_null = nullable
        ), ArgTypes),
    (
        Errors = [_ | _],
        Type = ty_error(Errors)
    ;
        Errors = [],
        ( if
            ( ReceiverNull = nullable
            ; NullableArgs = [_ | _]
            )
        then
            Null = nullable
        else
            Null = non_null
        ),
        Type = ty_known(ds_type(lk_int, dimensionless, Null))
    ).

    %@spec [LTIM.8.3.2]
:- func ltim_8_3_2_format(lgra_9_3_1_expr, lexp_7_type) = lexp_7_type.

ltim_8_3_2_format(Format, Result) = Type :-
    ( if
        Format = ex_string(Id, IdPos),
        not ltim_8_2_1_format(string.to_lower(Id))
    then
        Type = ty_error([with_hint(error_at(dv_unknown_time_format, IdPos,
            "`\"" ++ Id ++ "\"` is not a time format ([LTIM.8.3.2])"),
            "the formats are iso8601, epoch_seconds, epoch_millis, "
                ++ "epoch_micros and epoch_nanos")])
    else
        Type = Result
    ).

    % `receiver.NAME` with no argument list. A `Time` component is a member only
    % through `.utc` / `.local(tz)`.
    %
    %@spec [LGRA.9.6.2]
    %@spec [LEXP.3.7.1]
    %@spec [LTIM.3.1.1]
    %@spec [LTIM.6.1]
    %@spec [LTIM.6.2]
:- func lgra_9_6_2_member_read(lgra_9_3_1_expr, ds_type, ident) = lexp_7_type.

lgra_9_6_2_member_read(Base, K, Field) = Type :-
    Leaf = K ^ dt_leaf,
    Null = K ^ dt_null,
    Name = Field ^ id_name,
    ( if Leaf = lk_int, member_leaf_has(lk_int, Name) then
        Type = ty_known(ds_type(lk_int, dimensionless, Null))
    else if Leaf = lk_time, Name = "utc" then
        Type = ty_known(ds_type(lk_time, dimensionless, Null))
    else if Leaf = lk_time, ltim_6_1_time_component(Name) then
        ( if ltim_6_1_tz_context(Base) then
            Type = ty_known(ds_type(lk_int, dimensionless, Null))
        else
            Type = ltim_6_2_bare_time(Field)
        )
    else if Leaf = lk_date, ltim_6_1_date_component(Name) then
        Type = ty_known(ds_type(lk_int, dimensionless, Null))
    else if member_with_arguments(Leaf, Name) then
        Type = ty_error([with_hint(error_at(dv_unknown_member, Field ^ id_pos,
            "`." ++ Name ++ "` takes arguments and is followed by its argument "
                ++ "list ([LGRA.9.6.2])"),
            "write `." ++ Name ++ "(...)`")])
    else
        Type = unknown_member(Leaf, Null, Field)
    ).

    %@helper
:- func unknown_member(leaf_kind, nullability, ident) = lexp_7_type.

unknown_member(Leaf, _Null, Member) =
    ty_error([with_hint(error_at(dv_unknown_member, Member ^ id_pos,
        "`." ++ Member ^ id_name ++ "` is not a member of "
            ++ leaf_text(Leaf) ++ " ([LGRA.9.6.2])"),
        members_hint(Leaf))]).

    %@helper
:- func members_hint(leaf_kind) = string.

members_hint(Leaf) = Hint :-
    ( if Leaf = lk_int then
        Hint = "an `Int` has `.bit_count`, `.bit_length`, `.leading_zeros`, "
            ++ "`.trailing_zeros`, `.bits(lo, width)`, `.sign_extend(width)` "
            ++ "and `.swap_bytes(width)`"
    else if Leaf = lk_string then
        Hint = "a `String` has no members; DS reads no temporal text, and "
            ++ "`calendar.time` / `calendar.date` build one from its fields "
            ++ "([LTIM.14])"
    else if Leaf = lk_bytes then
        Hint = "`Bytes` has no members: a `Bytes` value is passed through, "
            ++ "never converted (LSTR.4.6)"
    else if Leaf = lk_time then
        Hint = "a `Time` has `.utc`, `.local(tz)`, `.date(tz)`, `.floor(d)`, "
            ++ "`.add_months(n)`, `.add_years(n)`, `.to_string(fmt)`, and the "
            ++ "components through `.utc` / `.local(tz)`"
    else if Leaf = lk_date then
        Hint = "a `Date` has `.day`, `.month`, `.year`, `.day_of_week`, "
            ++ "`.add_months(n)`, `.add_years(n)` and `.to_string(fmt)`"
    else if Leaf = lk_duration then
        Hint = "a `Duration` has no members; `dur::String` renders it"
    else
        Hint = "this type has no members; cast it first ([LCST.4])"
    ).

    %@helper
:- func retired_spelling(pos, string, string) = lexp_7_type.

retired_spelling(Pos, Written, Replacement) =
    ty_error([retired_diagnostic(Pos, Written, Replacement)]).

    %@helper
:- func retired_diagnostic(pos, string, string) = diagnostic.

retired_diagnostic(Pos, Written, Replacement) =
    with_hint(error_at(dv_retired_builtin_spelling, Pos,
        Written ++ " is no longer DS; it is written " ++ Replacement
            ++ " ([LGRA.9.6.3])"),
        "write " ++ Replacement).

    % `math.floor` is refused only with a `Time` or `Date` first argument.
    %
    %@spec [LGRA.9.6.3]
:- pred lgra_9_6_3_retired(type_env::in, ident::in, list(lgra_9_3_1_expr)::in,
                           diagnostic::out) is semidet.

lgra_9_6_3_retired(Env, Id, Args, Diagnostic) :-
    Name = Id ^ id_name,
    ( if Name = "math.floor" then
        Args = [Instant, _],
        type_of_expr(Env, Instant) = ty_known(InstantType),
        ( InstantType ^ dt_leaf = lk_time
        ; InstantType ^ dt_leaf = lk_date
        ),
        Replacement = "`t.floor(d)` ([LTIM.7.1])"
    else
        retired_function(Name, Replacement)
    ),
    Diagnostic = retired_diagnostic(Id ^ id_pos, "`" ++ Name ++ "(...)`",
        Replacement).

    %@helper
:- pred retired_function(string::in, string::out) is semidet.

retired_function("bit_count", "`x.bit_count` ([LEXP.3.7.1])").
retired_function("bit_length", "`x.bit_length` ([LEXP.3.7.1])").
retired_function("utc", "`t.utc` ([LTIM.3.1.1])").
retired_function("local", "`t.local(tz)` ([LTIM.3.2.1])").
retired_function("add_months", "`t.add_months(n)` ([LTIM.4.3.1])").
retired_function("add_years", "`t.add_years(n)` ([LTIM.4.3.1])").
retired_function("is_null", "`x is null` ([LNUL.4.9])").

    %@spec [LTIM.8.2.1]
    %@spec [LTIM.8.2.2]
:- pred ltim_8_2_1_format(string::in) is semidet.

ltim_8_2_1_format("iso8601").
ltim_8_2_1_format("epoch_seconds").
ltim_8_2_1_format("epoch_millis").
ltim_8_2_1_format("epoch_micros").
ltim_8_2_1_format("epoch_nanos").

    %@helper
:- func lstr_4_6_retired_method(ident) = lexp_7_type.

lstr_4_6_retired_method(Method) =
    ty_error([with_hint(error_at(dv_bytes_conversion_retired, Method ^ id_pos,
        "`." ++ Method ^ id_name ++ "(…)` has left the language (LSTR.4.6): "
            ++ "a `Bytes` value is passed through, never converted"),
        "decode or encode in the adapter, before the fact is asserted")]).

    %@spec [LUNI.13.5.3]
:- pred luni_13_5_3_currency_method(string::in) is semidet.

luni_13_5_3_currency_method("round").
luni_13_5_3_currency_method("round_to").
luni_13_5_3_currency_method("to_currency").

    % The unit and pair arguments are not values: `USD` names a unit symbol and
    % `USD_to_EUR` a pair.
    %
    %@spec [LUNI.13.5.3]
    %@spec [LUNI.13.4]
    %@spec [LUNI.13.5.1]
:- func luni_13_5_3_method(type_env, lgra_9_3_1_expr, ident,
                            list(lgra_9_3_1_expr)) = lexp_7_type.

luni_13_5_3_method(Env, Receiver, Method, Args) = Type :-
    ReceiverType = type_of_expr(Env, Receiver),
    Name = Method ^ id_name,
    MethodPos = Method ^ id_pos,
    ( if ReceiverType = ty_error(_) then
        Type = ReceiverType
    else if Name = "round" then
        ( if Args = [] then
            Type = ty_error([with_hint(error_at(dv_currency_round_no_mode,
                MethodPos,
                "`.round()` needs a mode; there is no default "
                    ++ "([LUNI.13.5.1])"),
                "write `.round(\"half_even\")` or another of the six modes")])
        else if Args = [Mode] then
            Diagnostics = luni_13_6_round_mode(MethodPos, Mode),
            ( if Diagnostics = [] then
                Type = ReceiverType
            else
                Type = ty_error(Diagnostics)
            )
        else
            Type = ReceiverType
        )
    else if Name = "round_to" then
        ( if Args = [Unit, Mode] then
            Diagnostics = round_to_unit(Env, ReceiverType, Unit)
                ++ luni_13_6_round_mode(MethodPos, Mode),
            ( if Diagnostics = [] then
                Type = ReceiverType
            else
                Type = ty_error(Diagnostics)
            )
        else
            Type = ReceiverType
        )
    else if Args = [ex_name(Pair)] then
        ( if fx_pair_target(Env ^ te_file ^ rf_ast ^ af_decls, Pair ^ id_name,
                Target)
        then
            ( if ReceiverType = ty_known(K) then
                Null = K ^ dt_null
            else
                Null = non_null
            ),
            % The file's own dimension or one it imports: a pair's target is
            % spelled in the file declaring the pair ([LUNI.4.1.5]).
            ( if
                map.search(Env ^ te_file ^ rf_types, Target,
                    te_unit(uk_dimension, Bound))
            then
                TargetDim = Bound
            else
                TargetDim = decl_ref("", Target)
            ),
            Type = ty_known(ds_type(lk_float, dim(TargetDim, no), Null))
        else
            Type = ty_error([with_hint(error_at(dv_fx_pair_unknown,
                Pair ^ id_pos,
                "`.to_currency(" ++ Pair ^ id_name ++ ")`: `" ++ Pair ^ id_name
                    ++ "` is not a declared `unit fx_pair` ([LUNI.4.6])"),
                "declare the pair with `unit fx_pair " ++ Pair ^ id_name
                    ++ ": <from> to <to>`")])
        )
    else
        Type = ty_unknown
    ).

    %@spec [LUNI.13.6]
:- func luni_13_6_round_mode(pos, lgra_9_3_1_expr) = list(diagnostic).

luni_13_6_round_mode(MethodPos, Mode) = Diagnostics :-
    ( if Mode = ex_string(Text, Pos) then
        ( if canonical_round_mode(Text) then
            Diagnostics = []
        else
            Diagnostics = [with_hint(error_at(
                dv_currency_unknown_round_mode, Pos,
                "`\"" ++ Text ++ "\"` is not a round mode ([LUNI.13.6])"),
                "the modes are half_even, half_up, half_down, ceiling, floor "
                    ++ "and truncate")]
        )
    else
        Diagnostics = [with_hint(error_at(dv_currency_round_arg_not_string,
            MethodPos,
            "a round mode is a string literal, checked at compile time "
                ++ "([LUNI.13.6])"),
            "write the mode as a literal, such as `\"half_even\"`")]
    ).

    %@helper
:- pred canonical_round_mode(string::in) is semidet.

canonical_round_mode("half_even").
canonical_round_mode("half_up").
canonical_round_mode("half_down").
canonical_round_mode("ceiling").
canonical_round_mode("floor").
canonical_round_mode("truncate").

    %@helper
:- func round_to_unit(type_env, lexp_7_type, lgra_9_3_1_expr)
    = list(diagnostic).

round_to_unit(Env, ReceiverType, Unit) = Diagnostics :-
    ( if Unit = ex_name(UnitId) then
        Name = UnitId ^ id_name,
        ( if unit_symbol_dimension(Env, Name, UnitDim) then
            ( if
                ReceiverType = ty_known(K),
                K ^ dt_dim = dim(ReceiverDim, _),
                UnitDim \= ReceiverDim
            then
                Diagnostics = [with_hint(error_at(dv_currency_round_to_unit,
                    UnitId ^ id_pos,
                    "`.round_to(" ++ Name ++ ", ...)`: `" ++ Name ++ "` is a `"
                        ++ UnitDim ^ dr_name ++ "` unit and the value is `"
                        ++ ReceiverDim ^ dr_name ++ "` ([LUNI.13.5])"),
                    "round to a unit of the same dimension, or convert first "
                        ++ "with `.to_currency(<fx_pair>)`")]
            else
                Diagnostics = []
            )
        else
            Diagnostics = [with_hint(error_at(dv_currency_round_to_unit,
                UnitId ^ id_pos,
                "`.round_to(" ++ Name ++ ", ...)`: `" ++ Name ++ "` is not a "
                    ++ "declared unit symbol ([LUNI.13.5])"),
                "name a unit of the value's dimension, such as its major unit")]
        )
    else
        Diagnostics = []
    ).

    %@helper
:- pred unit_symbol_dimension(type_env::in, string::in, decl_ref::out)
    is semidet.

unit_symbol_dimension(Env, Name, Dimension) :-
    Types = Env ^ te_file ^ rf_types,
    ( if map.search(Env ^ te_file ^ rf_unit_alias, Name, Canonical) then
        Symbol = Canonical ^ id_name
    else
        Symbol = Name
    ),
    map.search(Types, Symbol, Entry),
    Entry = te_unit(uk_symbol(Dimension), _).

    %@helper
:- pred fx_pair_target(list(ast_decl)::in, string::in, string::out) is semidet.

fx_pair_target([D | Ds], Name, Target) :-
    ( if
        D = ad_unit(au_fx_pair(PairName, _, To, _, _, _, _, _)),
        PairName ^ id_name = Name
    then
        Target = To ^ id_name
    else
        fx_pair_target(Ds, Name, Target)
    ).

    % `<agg>(cursor)`. The cursor is not typed as a value: its components are no
    % slot reads ([LSER.6.11.2]). Its root must type to a fact, so a scalar call
    % such as `min(a, b)` fails out of this.
    %
    %@spec [LSER.16.1]
    %@spec [LSER.10.6]
    %@spec [LSER.6.8.2]
    %@spec [LEXP.3.8.1]
:- func lser_16_1_cursor_call(type_env, ident, list(lgra_9_3_1_expr))
    = lexp_7_type is semidet.

lser_16_1_cursor_call(Env, Id, Args) = Type :-
    Args = [CursorArg | Rest],
    cursor_chain(CursorArg, Root, Components),
    type_of_expr(Env, Root) = ty_known(RootType),
    RootType ^ dt_leaf = lk_fact(SchemaName),
    Name = Id ^ id_name,

    % The aggregation reading of `min` / `max` is the one-argument call
    % ([LSER.6.11.3]): `max(s.v, 1.0)` is the scalar.
    ( if lser_16_overloaded_with_scalar(Name) then
        Rest = []
    else
        true
    ),

    RestErrors = list.condense(list.filter_map(errors_of,
        list.map(type_of_expr(Env), Rest))),
    (
        RestErrors = [_ | _],
        Type = ty_error(RestErrors)
    ;
        RestErrors = [],
        % Ahead of the arity: another name, such as `distance.euclidean(p.x,
        % ...)`, fails out to the plain call path.
        lser_17_2_aggregation(Name),
        ( if lser_6_11_3_surplus_argument(Name, Rest, Allowed) then
            Type = ty_error([with_hint(error_at(dv_bad_arity, Id ^ id_pos,
                "`" ++ Name ++ "` takes " ++ arity_text([Allowed + 1])
                    ++ ", not " ++ string.from_int(list.length(Rest) + 1)
                    ++ ": a series read names no window ([LSER.6.11.3])"),
                "read `" ++ Name ++ "(<cursor>"
                    ++ ( if Allowed = 1 then ", <value>" else "" )
                    ++ ")`; the window is the declaration's, and a label "
                    ++ "on the cursor picks the line where the slot "
                    ++ "declares more than one ([LSER.6.11.1])")])
        else
            Outcome = lser_6_11_1_cursor(Env ^ te_file, SchemaName,
                Components ++ [Id], Id ^ id_pos),
            (
                Outcome = cursor_failed(Diagnostic),
                Type = ty_error([Diagnostic])
            ;
                Outcome = cursor_resolved(Observation, Agg),
                Slot = Observation ^ so_slot,
                ( if
                    lnls_3_11_series_scan(Env, Name, SchemaName, Slot,
                        Id ^ id_pos, Scan)
                then
                    Type = ty_error([Scan])
                else
                    Type = luni_9_1_agg_type(Env, SchemaName, Slot, Agg)
                )
            )
        )
    ).

    %@helper
:- pred lser_16_overloaded_with_scalar(string::in) is semidet.

lser_16_overloaded_with_scalar("min").
lser_16_overloaded_with_scalar("max").

    %@spec [LSER.6.11.3]
:- pred lser_6_11_3_surplus_argument(string::in, list(lgra_9_3_1_expr)::in,
                                     int::out) is semidet.

lser_6_11_3_surplus_argument(Name, Rest, Allowed) :-
    ( if ( Name = "count_of" ; Name = "contains" ) then
        Allowed = 1
    else
        Allowed = 0
    ),
    list.length(Rest) > Allowed.

    %@helper
:- func lexp_5_3_plain_call(type_env, lgra_9_3_1_expr, list(lgra_9_3_1_expr),
                            pos) = lexp_7_type.

lexp_5_3_plain_call(Env, Callee, Args, Pos) = Type :-
    ArgTypes = list.map(type_of_expr(Env), Args),
    ArgErrors = list.condense(list.filter_map(errors_of, ArgTypes)),
    (
        % An argument's errors win over the callee's.
        ArgErrors = [_ | _],
        Type = ty_error(ArgErrors)
    ;
        ArgErrors = [],
        ( if
            Callee = ex_name(Id),
            lcst_4_6_1_coercion_head(Env ^ te_file, Id ^ id_name, _)
        then
            % Refused by `dsc.validate`'s walk, with the `::` form to use.
            Type = ty_unknown
        else if
            Callee = ex_name(Id),
            lstr_4_6_retired_fn(Id ^ id_name)
        then
            Type = ty_error([with_hint(error_at(dv_bytes_conversion_retired,
                Id ^ id_pos,
                "`" ++ Id ^ id_name ++ "` has left the language (LSTR.4.6): "
                    ++ "a `Bytes` value is passed through, never converted"),
                "decode or unpack the bytes in the adapter, before the fact "
                    ++ "is asserted")])
        else if
            Callee = ex_name(Id),
            NullArgErrors = lnul_5_1_builtin_arguments(Env, Id ^ id_name,
                Args, ArgTypes, Pos),
            NullArgErrors = [_ | _]
        then
            Type = ty_error(NullArgErrors)
        else if
            % A `unit formula`'s function ([LGRA.9.8.11]). A builtin of the same
            % spelling wins.
            Callee = ex_name(Id),
            not lgra_22_7_builtin_fn(Id ^ id_name),
            lgra_9_8_11_formula_function(Env ^ te_file, Id ^ id_name, Line)
        then
            Type = lgra_9_8_11_formula_call(Env, Id, Line, ArgTypes, Pos)
        else if
            Callee = ex_name(Id),
            Id ^ id_name = "distance.great_circle",
            lgra_9_8_11_builtin_call(Id, list.length(Args), Pos) = ty_unknown,
            map.search(Env ^ te_file ^ rf_types, "meter", Meter)
        then
            % The one builtin whose result carries a unit ([LEXP.5.11.1]).
            Type = ty_known(luni_7_1_slot_type(Env ^ te_file ^ rf_unit_storage,
                Meter, non_null))
        else if
            Callee = ex_name(Id),
            Id ^ id_name = "math.fma",
            lgra_9_8_11_builtin_call(Id, list.length(Args), Pos) = ty_unknown,
            Args = [X, Y, Z]
        then
            Type = lexp_3_2_2_fma_type(Env, X, Y, Z, Pos)
        else if
            Callee = ex_name(Id),
            IntErrors = ltim_14_1_int_fields(Id ^ id_name, ArgTypes, Pos),
            IntErrors = [_ | _]
        then
            Type = ty_error(IntErrors)
        else if Callee = ex_name(Id) then
            Type = lgra_9_8_11_builtin_call(Id, list.length(Args), Pos)
        else
            Type = ty_unknown
        )
    ).

    % Typed as `x * y + z`, with a `Float` leaf. The expression built here is
    % never lowered.
    %
    %@spec [LEXP.3.2.2]
:- func lexp_3_2_2_fma_type(type_env, lgra_9_3_1_expr, lgra_9_3_1_expr,
                            lgra_9_3_1_expr, pos) = lexp_7_type.

lexp_3_2_2_fma_type(Env, X, Y, Z, Pos) = Type :-
    AsWritten = type_of_expr(Env,
        ex_binary(bo_add, ex_binary(bo_mul, X, Y, Pos), Z, Pos)),
    (
        AsWritten = ty_known(Known),
        Type = ty_known(Known ^ dt_leaf := lk_float)
    ;
        ( AsWritten = ty_unknown
        ; AsWritten = ty_error(_)
        ),
        Type = AsWritten
    ).

    %@spec [LTIM.14.1]
:- func ltim_14_1_int_fields(string, list(lexp_7_type), pos)
    = list(diagnostic).

ltim_14_1_int_fields(Name, ArgTypes, Pos) = Errors :-
    ( if ( Name = "calendar.time" ; Name = "calendar.date" ) then
        Errors = list.filter_map(
            ( func(ArgType::in) = (Error::out) is semidet :-
                ArgType = ty_known(A),
                A ^ dt_leaf \= lk_int,
                Error = error_at(dv_bad_operand_type, Pos,
                    "`" ++ Name ++ "` takes `Int` fields, not "
                        ++ leaf_text(A ^ dt_leaf) ++ " ([LTIM.14.1])")
            ), ArgTypes)
    else
        Errors = []
    ).

    % A builtin's argument is a concrete-value position. `has()` is the absence
    % test, and only its path's root is concrete: a `Json?` slot holding `null`
    % makes it raise at runtime. `math.fma` propagates, as an operator does.
    %
    %@spec [LNUL.5.1]
:- func lnul_5_1_builtin_arguments(type_env, string, list(lgra_9_3_1_expr),
                                   list(lexp_7_type), pos) = list(diagnostic).

lnul_5_1_builtin_arguments(Env, Name, Args, ArgTypes, Pos) = Errors :-
    ( if Name = "has" then
        Errors = list.condense(list.map(lnul_5_1_has_root(Env, Pos), Args))
    else if
        ( Name = "math.fma"
        ; not lgra_22_7_builtin_fn(Name)
        )
    then
        Errors = []
    else
        Errors = list.condense(list.map_corresponding(
            ( func(Arg, ArgType) = lnul_5_1_concrete(Env, Arg, ArgType, Pos,
                "an argument of `" ++ Name ++ "()`") ),
            Args, ArgTypes))
    ).

    % The root is the innermost operand of the path's projections that types as
    % `Json`.
    %
    %@spec [LNUL.5.1]
:- func lnul_5_1_has_root(type_env, pos, lgra_9_3_1_expr) = list(diagnostic).

lnul_5_1_has_root(Env, Pos, Arg) = Errors :-
    ( if json_path_root(Env, Arg, Root) then
        Errors = lnul_5_1_concrete(Env, Root, type_of_expr(Env, Root), Pos,
            "the root of `has()`'s path")
    else
        Errors = []
    ).

    %@helper
:- pred json_path_root(type_env::in, lgra_9_3_1_expr::in,
                       lgra_9_3_1_expr::out) is semidet.

json_path_root(Env, E, Root) :-
    ( if
        ( E = ex_slot(Base, _, _)
        ; E = ex_index(Base, _, _)
        ),
        json_path_root(Env, Base, Root0)
    then
        Root = Root0
    else
        type_of_expr(Env, E) = ty_known(Known),
        Known ^ dt_leaf = lk_json,
        Root = E
    ).

    % The list is the receiver's type, then the argument's.
    %
    %@spec [LTIM.7.1]
    %@spec [LTIM.7.4]
:- pred ltim_7_1_floor_operands(list(lexp_7_type)::in, pos::in,
                                diagnostic::out) is semidet.

ltim_7_1_floor_operands([_InstantType, SpanType], Pos, Error) :-
    SpanType = ty_known(Span),
    Span ^ dt_leaf \= lk_duration,
    Error = with_hint(error_at(dv_bad_operand_type, Pos,
        "`t.floor(d)` truncates to a `Duration`, not "
            ++ leaf_text(Span ^ dt_leaf) ++ " ([LTIM.7.1])"),
        "write the boundary as a duration literal, such as `1_h`").

    %@spec [LGRA.9.8.11]
    %@spec [LEXP.10.2.4]
    %@spec [LEXP.3.1]
:- func lgra_9_8_11_builtin_call(ident, int, pos) = lexp_7_type.

lgra_9_8_11_builtin_call(Id, Arity, Pos) = Type :-
    Name = Id ^ id_name,
    ( if lexp_5_8_1_arity(Name, Arities) then
        ( if list.member(Arity, Arities) then
            ( if lgra_9_8_1_returns(Name, Result) then
                Type = ty_known(ds_type(result_leaf(Result), dimensionless,
                    non_null))
            else
                Type = ty_unknown
            )
        else
            Type = ty_error([error_at(dv_bad_arity, Pos,
                "`" ++ Name ++ "` takes " ++ arity_text(Arities)
                    ++ ", not " ++ string.from_int(Arity))])
        )
    else if lgra_22_7_builtin_fn(Name) then
        Type = ty_unknown
    else
        Type = ty_error([with_hint(error_at(dv_unknown_function, Id ^ id_pos,
            "`" ++ Name ++ "` is not a builtin function ([LGRA.9.8.11])"),
            "the builtins are: "
                ++ string.join_list(", ", admitted_builtin_names))])
    ).

    % The argument is checked by [LUNI.8.1]'s additive row, so a bare number
    % passes. The result is nullable when the argument is.
    %
    %@spec [LGRA.9.8.11]
    %@spec [LUNI.4.5]
:- func lgra_9_8_11_formula_call(type_env, ident, ast_formula_line,
                                 list(lexp_7_type), pos) = lexp_7_type.

lgra_9_8_11_formula_call(Env, Id, Line, ArgTypes, Pos) = Type :-
    RF = Env ^ te_file,
    Name = Id ^ id_name,
    ( if ArgTypes = [ArgType] then
        ( if
            map.search(RF ^ rf_types, Line ^ afl_param_type ^ id_name, PEntry),
            ParamType = luni_7_1_slot_type(RF ^ rf_unit_storage, PEntry,
                non_null),
            map.search(RF ^ rf_types, Line ^ afl_return ^ id_name, REntry),
            ReturnType = luni_7_1_slot_type(RF ^ rf_unit_storage, REntry,
                non_null)
        then
            ( if
                ArgType = ty_known(Arg),
                luni_8_1_combine(op_additive, Arg ^ dt_dim,
                    ParamType ^ dt_dim) = dr_cross_dimension(ArgDim, ParamDim)
            then
                Type = ty_error([with_hint(error_at(dv_dim_mismatch, Pos,
                    "`" ++ Name ++ "` takes `" ++ ParamDim ^ dr_name ++ "` (its "
                        ++ "parameter is `" ++ Line ^ afl_param_type ^ id_name
                        ++ "`), not `" ++ ArgDim ^ dr_name ++ "` ([LGRA.9.8.11])"),
                    "pass a value in `" ++ Line ^ afl_param_type ^ id_name
                        ++ "`'s dimension")])
            else
                ( if ArgType = ty_known(Known) then
                    Null = Known ^ dt_null
                else
                    Null = non_null
                ),
                Type = ty_known(ReturnType ^ dt_null := Null)
            )
        else
            % The declaration's error, reported there.
            Type = ty_unknown
        )
    else
        Type = ty_error([error_at(dv_bad_arity, Pos,
            "`" ++ Name ++ "` is a `unit formula` function and takes one "
                ++ "argument, not " ++ string.from_int(list.length(ArgTypes))
                ++ " ([LUNI.4.5])")])
    ).

lcst_4_6_1_coercion_head(RF, Name, Rewrite) :-
    ( if Name = "Float" then
        Rewrite = "Float"
    else if Name = "Int" then
        Rewrite = "Int"
    else if Name = "Json" then
        Rewrite = "Json"
    else if Name = "int" then
        Rewrite = "Int?"
    else
        not lgra_22_7_builtin_fn(Name),
        ( map.search(RF ^ rf_types, Name, te_unit(_, _))
        ; map.contains(RF ^ rf_unit_alias, Name)
        ),
        Rewrite = Name
    ).

    % `binding.NAME` in expression position, a library member ([LGRA.22.9]).
    %
    % A constant is typed with none of the importer's `const`s in scope: a bare
    % name in its right-hand side means the library's. A library constant naming
    % another is therefore `ty_unknown`. Another name the library declares
    % passes untyped, and so does a binding with no recorded surface.
    %
    %@spec [LIMP.4.3.2]
    %@spec [LIMP.4.1.1]
:- func limp_4_3_2_qualified_const(type_env, list(ident), ident, pos)
    = lexp_7_type.

limp_4_3_2_qualified_const(Env, Lib, NameId, Pos) = Type :-
    Binding = string.join_list(".", list.map((func(I) = I ^ id_name), Lib)),
    Name = NameId ^ id_name,
    File = Env ^ te_file,
    ( if map.search(File ^ rf_qualified_consts, Binding ++ ";" ++ Name, Const)
    then
        Type = lgra_13_3_const_type((Env ^ te_file ^ rf_consts := map.init),
            Name, Const)
    else if
        map.search(File ^ rf_qualified_surface, Binding, Surface),
        not list.member(Name, Surface)
    then
        Type = ty_error([with_hint(error_at(dv_unknown_qualified_const, Pos,
            "`" ++ Binding ++ "." ++ Name ++ "`: library `" ++ Binding
                ++ "` exports no `" ++ Name ++ "` ([LIMP.4.3.2])"),
            "a leading `_` keeps a name library-internal ([LIMP.4.3.1])")])
    else
        Type = ty_unknown
    ).

    %@spec [LTIM.3.3.2]
:- func ltim_3_3_2_date(ident) = lexp_7_type.

ltim_3_3_2_date(Method) =
    ty_error([with_hint(error_at(dv_date_needs_tz, Method ^ id_pos,
        "`.date()` on a `Time` needs a timezone: a local date without one is "
            ++ "undefined ([LTIM.3.3.2])"),
        "`t.date(\"UTC\")`, or the zone the date is meant in")]).

    % The arguments are not typed first: `latest(S)`'s `S` names a schema.
    %
    %@spec [LGRA.9.8.2]
:- func lgra_9_8_2_latest(ident, int, pos) = lexp_7_type.

lgra_9_8_2_latest(LatestId, Arity, Pos) =
    lgra_9_8_11_builtin_call(LatestId, Arity, Pos).

    %@helper
:- func arity_text(list(int)) = string.

arity_text(Arities) = Text :-
    ( if Arities = [One] then
        Text = string.from_int(One) ++ plural(One)
    else
        Text = string.join_list(" or ",
            list.map(string.from_int, Arities)) ++ " arguments"
    ).

    %@helper
:- func plural(int) = string.

plural(N) = ( if N = 1 then " argument" else " arguments" ).

    %@helper
:- func result_leaf(builtin_result) = leaf_kind.

result_leaf(br_int) = lk_int.
result_leaf(br_float) = lk_float.
result_leaf(br_bool) = lk_bool.
result_leaf(br_time) = lk_time.
result_leaf(br_date) = lk_date.
result_leaf(br_duration) = lk_duration.

%-----------------------------------------------------------------------------%
% Temporal arithmetic -- [LTIM.4.1.1], [LTIM.4.2.1]
%-----------------------------------------------------------------------------%

    % Fails for a pair that is not temporal, which sends the caller to the
    % numeric rule.
    %
    %@spec [LTIM.4.1.1]
    %@spec [LTIM.4.2.1]
:- func ltim_4_1_1_temporal(lgra_9_3_1_binary_op, leaf_kind, leaf_kind)
    = leaf_kind is semidet.

ltim_4_1_1_temporal(bo_sub, lk_time, lk_time) = lk_duration.
ltim_4_1_1_temporal(bo_sub, lk_date, lk_date) = lk_duration.
ltim_4_1_1_temporal(bo_add, lk_time, lk_duration) = lk_time.
ltim_4_1_1_temporal(bo_sub, lk_time, lk_duration) = lk_time.
ltim_4_1_1_temporal(bo_add, lk_date, lk_duration) = lk_date.
ltim_4_1_1_temporal(bo_sub, lk_date, lk_duration) = lk_date.
ltim_4_1_1_temporal(bo_add, lk_duration, lk_duration) = lk_duration.
ltim_4_1_1_temporal(bo_sub, lk_duration, lk_duration) = lk_duration.
ltim_4_1_1_temporal(bo_mul, lk_int, lk_duration) = lk_duration.
ltim_4_1_1_temporal(bo_mul, lk_duration, lk_int) = lk_duration.
ltim_4_1_1_temporal(bo_div, lk_duration, lk_int) = lk_duration.

%-----------------------------------------------------------------------------%
% Bitwise -- [LEXP.7.7], [LEXP.7.8]
%-----------------------------------------------------------------------------%

    %@spec [LEXP.7.7]
    %@spec [LEXP.7.8]
    %@spec [LEXP.10.2.1]
:- func lexp_7_7_bitwise(type_env, lgra_9_3_1_binary_op, lgra_9_3_1_expr,
                         lgra_9_3_1_expr, pos) = lexp_7_type.

lexp_7_7_bitwise(Env, Op, Left, Right, Pos) = Type :-
    LeftType = type_of_expr(Env, Left),
    RightType = type_of_expr(Env, Right),
    ( if Both = both_known(LeftType, RightType) then
        Both = pair_of(L, R),
        ( if L ^ dt_leaf = lk_int, R ^ dt_leaf = lk_int then
            ( if lexp_7_8_negative_shift(Op, Right) then
                Type = ty_error([error_at(dv_negative_shift, Pos,
                    "a shift amount must be a non-negative integer "
                        ++ "([LEXP.7.8])")])
            else
                Type = ty_known(ds_type(lk_int, dimensionless,
                    propagated(L, R)))
            )
        else
            Type = ty_error([with_hint(error_at(dv_bitwise_type, Pos,
                "the bitwise operators require integer operands "
                    ++ "([LEXP.7.7])"),
                "convert with `::Int`, or use the arithmetic operators")])
        )
    else
        Type = merge_unknown(LeftType, RightType)
    ).

    %@spec [LEXP.7.8]
    %@spec [LEXP.10.2.3]
:- pred lexp_7_8_negative_shift(lgra_9_3_1_binary_op::in, lgra_9_3_1_expr::in)
    is semidet.

lexp_7_8_negative_shift(Op, Right) :-
    ( Op = bo_shl ; Op = bo_shr ),
    % `-1` parses as a unary minus: no literal is signed.
    Right = ex_unary(uo_neg, ex_int(N, _), _),
    N > 0i64.

%-----------------------------------------------------------------------------%
% Shared operand plumbing
%-----------------------------------------------------------------------------%

    %@helper
:- type type_pair
    --->    pair_of(ds_type, ds_type).

    %@helper
:- func both_known(lexp_7_type, lexp_7_type) = type_pair is semidet.

both_known(ty_known(L), ty_known(R)) = pair_of(L, R).

    %@helper
:- func merge_unknown(lexp_7_type, lexp_7_type) = lexp_7_type.

merge_unknown(L, R) = Type :-
    ( if L = ty_error(LD) then
        ( if R = ty_error(RD) then
            Type = ty_error(LD ++ RD)
        else
            Type = ty_error(LD)
        )
    else if R = ty_error(RD) then
        Type = ty_error(RD)
    else
        Type = ty_unknown
    ).

    %@helper
:- func propagated(ds_type, ds_type) = nullability.

propagated(L, R) = Null :-
    ( if ( L ^ dt_null = nullable ; R ^ dt_null = nullable ) then
        Null = nullable
    else
        Null = non_null
    ).

%-----------------------------------------------------------------------------%
% Names -- [LGRA.22.7]'s value namespace
%-----------------------------------------------------------------------------%

    % Typed in the `let`'s own position, not the use's. An error in it is
    % `dsc.validate`'s to report (`luni_8_4_let_binding`), so here it is
    % `ty_unknown`. The name leaves scope while its right-hand side is typed,
    % which ends a cycle ([LLET.12.3] refuses one).
    %
    %@spec [LLET.3.6]
:- func llet_3_6_let_type(type_env, string, lgra_9_3_1_expr) = lexp_7_type.

llet_3_6_let_type(Env, Name, Rhs) = Type :-
    Scope0 = Env ^ te_scope,
    Scope = (Scope0 ^ rsc_lets := map.delete(Scope0 ^ rsc_lets, Name))
        ^ rsc_let_exprs := map.delete(Scope0 ^ rsc_let_exprs, Name),
    Own = ((Env ^ te_scope := Scope)
        ^ te_ambiguity := da_reported)
        ^ te_narrowed := set.init,
    RhsType = type_of_expr(Own, Rhs),
    (
        RhsType = ty_known(_),
        Type = RhsType
    ;
        RhsType = ty_unknown,
        Type = ty_unknown
    ;
        RhsType = ty_error(_),
        Type = ty_unknown
    ).

    % Its annotation's type where it has one, otherwise its right-hand side's,
    % typed in an empty rule scope and with the name out of the file's `const`s,
    % which ends a cycle. An error in it is `dsc.validate`'s to report
    % (`lgra_4_1_consts`), so here it is `ty_unknown`.
    %
    %@spec [LGRA.13.3]
:- func lgra_13_3_const_type(type_env, string, ast_const) = lexp_7_type.

lgra_13_3_const_type(Env, Name, Const) = Type :-
    Form = Const ^ acn_form,
    (
        Form = acf_value(yes(Ann), _),
        ( if
            map.search(const_scope(Env ^ te_file, Const) ^ rf_types,
                Ann ^ aan_type ^ id_name, Entry)
        then
            Type = ty_known(luni_7_1_slot_type(Env ^ te_file ^ rf_unit_storage,
                Entry, Ann ^ aan_nullable))
        else
            Type = ty_unknown
        )
    ;
        Form = acf_value(no, Rhs),
        File0 = const_scope(Env ^ te_file, Const),
        File = File0 ^ rf_consts := map.delete(File0 ^ rf_consts, Name),
        Scope0 = Env ^ te_scope,
        Scope = ((((Scope0 ^ rsc_bindings := map.init)
            ^ rsc_lets := map.init)
            ^ rsc_captures := map.init)
            ^ rsc_let_types := map.init)
            ^ rsc_let_exprs := map.init,
        Own = (((Env ^ te_file := File)
            ^ te_scope := Scope)
            ^ te_ambiguity := da_reported)
            ^ te_narrowed := set.init,
        RhsType = type_of_expr(Own, Rhs),
        (
            RhsType = ty_known(_),
            Type = RhsType
        ;
            RhsType = ty_unknown,
            Type = ty_unknown
        ;
            RhsType = ty_error(_),
            Type = ty_unknown
        )
    ;
        Form = acf_colon_literal(_),
        Type = ty_unknown
    ).

    %@spec [LGRA.22.7]
    %@spec [LEXP.4.2]
:- func lgra_22_7_value_name(type_env, ident) = lexp_7_type.

lgra_22_7_value_name(Env, Id) = Type :-
    Name = Id ^ id_name,
    Scope = Env ^ te_scope,
    ( if map.search(Scope ^ rsc_bindings, Name, Binding) then
        (
            Binding ^ pb_head = head_local(Schema),
            Type = ty_known(ds_type(lk_fact(Schema ^ as_own),
                dimensionless, non_null))
        ;
            % An imported head types as its fact when the library loaded, under
            % the keys `fact_schema` reads.
            Binding ^ pb_head = head_imported(Head),
            ( if fact_schema(Env, Head ^ id_name, _) then
                Type = ty_known(ds_type(lk_fact(Head ^ id_name),
                    dimensionless, non_null))
            else
                Type = ty_unknown
            )
        ;
            Binding ^ pb_head = head_qualified(Lib, Head),
            Key = string.join_list(".", list.map((func(I) = I ^ id_name), Lib))
                ++ ";" ++ Head ^ id_name,
            ( if fact_schema(Env, Key, _) then
                Type = ty_known(ds_type(lk_fact(Key), dimensionless, non_null))
            else
                Type = ty_unknown
            )
        )
    else if map.search(Scope ^ rsc_captures, Name, _) then
        % Non-null: a capture binds only on a match ([LREG.4.1], [LREG.4.4]).
        Type = ty_known(ds_type(lk_string, dimensionless, non_null))
    else if map.search(Scope ^ rsc_lets, Name, _) then
        % An annotated `let` has its annotation's type ([LUNI.8.6]), and
        % `dsc.validate.luni_8_6_annotation` checks it against the right-hand
        % side.
        ( if map.search(Scope ^ rsc_let_types, Name, Ann) then
            ( if
                map.search(Env ^ te_file ^ rf_types, Ann ^ aan_type ^ id_name,
                    Entry),
                Annotated = luni_7_1_slot_type(Env ^ te_file ^ rf_unit_storage,
                    Entry, Ann ^ aan_nullable)
            then
                Type = ty_known(Annotated)
            else
                Type = ty_unknown
            )
        else if map.search(Scope ^ rsc_let_exprs, Name, Rhs) then
            Type = llet_3_6_let_type(Env, Name, Rhs)
        else
            Type = ty_unknown
        )
    else if map.search(Env ^ te_file ^ rf_consts, Name, Const) then
        Type = lgra_13_3_const_type(Env, Name, Const)
    else if lexp_4_1_math_constant(Name) then
        ( if lexp_4_2_unusable(Name) then
            Type = ty_error([with_hint(error_at(dv_nan_value, Id ^ id_pos,
                "`nan` is reserved and is not a usable value: NaN must never "
                    ++ "enter working memory, because `NaN != NaN` breaks fact "
                    ++ "identity, joins and refraction ([LEXP.4.2])"),
                "test for it with `is not null` or a range guard; `inf` IS a "
                    ++ "permitted Float value")])
        else
            Type = ty_known(ds_type(lk_float, dimensionless, non_null))
        )
    else if lgra_22_7_builtin_fn(Name) then
        Type = ty_unknown
    else if unit_name(Env, Name) then
        % A bare unit name, as `round_to`'s argument ([LUNI.13.5]). What it
        % denotes depends on the argument it is in.
        Type = ty_unknown
    else if map.contains(Env ^ te_file ^ rf_types, Name) then
        Type = ty_error([with_hint(error_at(dv_unknown_const, Id ^ id_pos,
            "`" ++ Name ++ "` names a type, and in an expression a name is a "
                ++ "binding, a constant or a builtin ([LGRA.22.7])"),
            "declare a constant -- `const " ++ Name ++ " = <value>` -- or "
                ++ "compare a slot")])
    else
        Type = ty_error([with_hint(error_at(dv_unknown_binding, Id ^ id_pos,
            "`" ++ Name ++ "` is not a binding, a constant or a builtin "
                ++ "([LGRA.22.7])"),
            "bind it in a pattern, declare it as a `const`, or check the "
                ++ "spelling")])
    ).

    %@helper
:- pred unit_name(type_env::in, string::in) is semidet.

unit_name(Env, Name) :-
    map.search(Env ^ te_file ^ rf_types, Name, Entry),
    Entry = te_unit(_, _).

%-----------------------------------------------------------------------------%
% Slot access
%-----------------------------------------------------------------------------%

    %@spec [LUNI.7.1]
    %@spec [LGRA.5.8.5]
:- func luni_7_1_access_type(type_env, lgra_9_3_1_expr, ident, pos) = lexp_7_type.

luni_7_1_access_type(Env, Base, Field, _Pos) = Type :-
    BaseType = type_of_expr(Env, Base),
    (
        BaseType = ty_error(Ds),
        Type = ty_error(Ds)
    ;
        BaseType = ty_unknown,
        ( if ltim_6_1_tz_context(Base) then
            Type = ltim_6_1_component(Field)
        else
            Type = ty_unknown
        )
    ;
        BaseType = ty_known(K),
        Leaf = K ^ dt_leaf,
        ( if Leaf = lk_fact(SchemaName) then
            Type = schema_slot(Env, SchemaName, Field)
        else if Leaf = lk_interval(Element) then
            Type = lint_6_1_component(Element, Field)
        else if Leaf = lk_json then
            % A leaf's type is known only at runtime ([LEXP.7.12.1]).
            Type = ty_unknown
        else if member_leaf(Leaf) then
            Type = lgra_9_6_2_member_read(Base, K, Field)
        else
            Type = ty_error([error_at(dv_bad_path, Field ^ id_pos,
                "`" ++ Field ^ id_name ++ "`: only a fact binding or a `Json` "
                    ++ "value has fields")])
        )
    ).

    % Past a builtin slot that is not `Json`, the set `member_leaf` names.
    %
    %@spec [LGRA.5.8.5]
:- func lgra_5_8_5_index_type(type_env, lgra_9_3_1_expr, pos) = lexp_7_type.

lgra_5_8_5_index_type(Env, Base, Pos) = Type :-
    ( if
        Base = ex_slot(_, Slot, _),
        type_of_expr(Env, Base) = ty_known(K),
        member_leaf(K ^ dt_leaf)
    then
        Type = ty_error([error_at(dv_bad_path, Pos,
            "`" ++ Slot ^ id_name ++ "[...]`: only a `Json` slot is indexed "
                ++ "([LGRA.5.8.5])")])
    else
        Type = ty_unknown
    ).

%-----------------------------------------------------------------------------%
% Time components -- [LTIM.6]
%-----------------------------------------------------------------------------%

    % `t.utc` or `t.local(tz)`. Recognised by shape: the type carries no zone.
    %
    %@spec [LTIM.6.1]
:- pred ltim_6_1_tz_context(lgra_9_3_1_expr::in) is semidet.

ltim_6_1_tz_context(ex_slot(_, Member, _)) :-
    Member ^ id_name = "utc".
ltim_6_1_tz_context(ex_call(ex_slot(_, Member, _), [_], _)) :-
    Member ^ id_name = "local".

    % Reached only when the zoned receiver could not be typed; a typed one goes
    % through `lgra_9_6_2_member_read`.
    %
    %@spec [LTIM.6.1]
    %@spec [LTIM.6.3]
:- func ltim_6_1_component(ident) = lexp_7_type.

ltim_6_1_component(Field) = Type :-
    ( if ltim_6_1_time_component(Field ^ id_name) then
        Type = scalar(lk_int)
    else
        Type = ty_error([with_hint(error_at(dv_unknown_member, Field ^ id_pos,
            "`." ++ Field ^ id_name ++ "` is not a time component "
                ++ "([LTIM.6.1])"),
            "the components are `.hour`, `.minute`, `.second`, `.day`, "
                ++ "`.month`, `.year` and `.day_of_week`")])
    ).

    %@spec [LTIM.6.1]
:- pred ltim_6_1_time_component(string::in) is semidet.

ltim_6_1_time_component("hour").
ltim_6_1_time_component("minute").
ltim_6_1_time_component("second").
ltim_6_1_time_component(Name) :-
    ltim_6_1_date_component(Name).

    %@spec [LTIM.6.1]
:- pred ltim_6_1_date_component(string::in) is semidet.

ltim_6_1_date_component("day").
ltim_6_1_date_component("month").
ltim_6_1_date_component("year").
ltim_6_1_date_component("day_of_week").

    %@spec [LTIM.6.2]
:- func ltim_6_2_bare_time(ident) = lexp_7_type.

ltim_6_2_bare_time(Field) =
    ty_error([with_hint(error_at(dv_time_needs_tz_context, Field ^ id_pos,
        "`." ++ Field ^ id_name ++ "` on a raw `Time` has no timezone "
            ++ "([LTIM.6.2])"),
        "`<time>.utc." ++ Field ^ id_name ++ "` for UTC, or `<time>.local(tz)."
            ++ Field ^ id_name ++ "` for a named zone")]).

%-----------------------------------------------------------------------------%
% Series companion slots -- [LSER.6]
%-----------------------------------------------------------------------------%
%
% A chain is a cursor when its last component is an aggregation ([LSER.17.2]),
% a bare `t.<name>` names no declared slot, and `t.<head>...<agg>`'s head is no
% `Json` slot. Anything else falls through to `luni_7_1_access_type`.

    %@spec [LSER.6.10.2]
    %@spec [LSER.6.1]
    %@spec [LSER.6.2]
:- pred lser_6_10_2_cursor_read(type_env::in, lgra_9_3_1_expr::in, ident::in,
                                pos::in, lexp_7_type::out) is semidet.

lser_6_10_2_cursor_read(Env, Base, Field, Pos, Type) :-
    cursor_chain(Base, Root, Leading),
    Components = Leading ++ [Field],

    list.length(Components) =< 3,

    type_of_expr(Env, Root) = ty_known(RootType),
    RootType ^ dt_leaf = lk_fact(SchemaName),
    companion_shape(Env, SchemaName, Components),

    Outcome = lser_6_11_1_cursor(Env ^ te_file, SchemaName, Components, Pos),
    (
        Outcome = cursor_failed(Diagnostic),
        Type = ty_error([Diagnostic])
    ;
        Outcome = cursor_resolved(Observation, Agg),
        Slot = Observation ^ so_slot,
        Type = luni_9_1_agg_type(Env, SchemaName, Slot, Agg)
    ).

ltim_2_4_1_series_read(Env, Expr) :-
    (
        Expr = ex_slot(Base, Field, Pos),
        lser_6_10_2_cursor_read(Env, Base, Field, Pos, _)
    ;
        Expr = ex_call(ex_name(Id), Args, _),
        lser_16_1_cursor_call(Env, Id, Args) = _
    ).

luni_9_2_unit_changing_read(Env, Expr, Agg, Unit) :-
    (
        Expr = ex_slot(Base, Field, Pos),
        cursor_chain(Base, Root, Leading),
        Components = Leading ++ [Field],
        list.length(Components) =< 3,
        type_of_expr(Env, Root) = ty_known(RootType),
        RootType ^ dt_leaf = lk_fact(SchemaName),
        companion_shape(Env, SchemaName, Components)
    ;
        Expr = ex_call(ex_name(Id), [CursorArg], _),
        cursor_chain(CursorArg, Root, Leading),
        Components = Leading ++ [Id],
        Pos = Id ^ id_pos,
        type_of_expr(Env, Root) = ty_known(RootType),
        RootType ^ dt_leaf = lk_fact(SchemaName)
    ),
    lser_6_11_1_cursor(Env ^ te_file, SchemaName, Components, Pos)
        = cursor_resolved(Observation, Agg),
    Agg = "integral",
    declared_slot(Env, SchemaName, Observation ^ so_slot, Slot),
    schema_slot(Env, SchemaName, Slot ^ af_name) = ty_known(Known),
    Known ^ dt_dim = dim(Dimension, MaybeUnit),
    Unit = ( if MaybeUnit = yes(U) then U ^ dr_name else Dimension ^ dr_name ).

ltim_2_4_1_zone_read(Env, Expr) :-
    Expr = ex_call(ex_slot(Receiver, Member, _), [Zone], _),
    ( Member ^ id_name = "local" ; Member ^ id_name = "date" ),
    type_of_expr(Env, Receiver) = ty_known(ReceiverType),
    ReceiverType ^ dt_leaf = lk_time,
    not ltsl_4_1_string_constant(Env ^ te_file, Zone, "UTC").

%-----------------------------------------------------------------------------%
% Series reads the file cannot afford -- [LNLS.3.11]
%-----------------------------------------------------------------------------%

    % Decided where a cursor resolves. Every declaration of the slot must carry
    % `capacity`: a read is answered by whichever backing serves it. Only the
    % call form: [LSER.6.5] withholds both names from the companion form.
    %
    %@spec [LNLS.3.11]
:- pred lnls_3_11_series_scan(type_env::in, string::in, string::in,
                              string::in, pos::in, diagnostic::out) is semidet.

lnls_3_11_series_scan(Env, Name, SchemaName, Slot, Pos, D) :-
    ( Name = "contains"
    ; Name = "count_of"
    ),
    not enabled(Env ^ te_file ^ rf_program, cap_linear_scan),
    not lnls_3_11_bounded(Env ^ te_file, SchemaName, Slot),
    D = with_hint(error_at(dv_nolinscan_series_unbounded, Pos,
        "`linear_scan: false`: series `" ++ Name ++ "()` on `" ++ SchemaName
            ++ "." ++ Slot ++ "` scans the window (O(series depth)), which "
            ++ "is unbounded ([LNLS.3.11])"),
        "add `capacity: <N>` to the series declaration ([LSER.13.14])").

    %@helper
:- pred lnls_3_11_bounded(resolved_file::in, string::in, string::in)
    is semidet.

lnls_3_11_bounded(RF, SchemaName, Slot) :-
    Decls = list.filter_map(
        (func(D) = S is semidet :-
            D = ad_series(S),
            S ^ asr_slot ^ asf_slot ^ id_name = Slot,
            ( S ^ asr_slot ^ asf_schema = yes(Q),
                limp_13_1_own_of(RF, Q ^ id_name) = SchemaName
            ; S ^ asr_slot ^ asf_schema = no
            )),
        RF ^ rf_ast ^ af_decls),
    Decls = [_ | _],
    list.all_true((pred(S::in) is semidet :-
        list.find_first_match((pred(O::in) is semidet :-
            O = abk_capacity(_, _)), S ^ asr_opts, _)), Decls).

    %@helper
:- pred cursor_chain(lgra_9_3_1_expr::in, lgra_9_3_1_expr::out,
                     list(ident)::out) is det.

cursor_chain(Expr, Root, Components) :-
    ( if Expr = ex_slot(Inner, Field, _) then
        cursor_chain(Inner, Root, Leading),
        Components = Leading ++ [Field]
    else
        Root = Expr,
        Components = []
    ).

    %@helper
:- pred companion_shape(type_env::in, string::in, list(ident)::in) is semidet.

companion_shape(Env, SchemaName, Components) :-
    list.split_last(Components, Leading, AggId),
    lser_6_5_companion_aggregation(AggId ^ id_name),
    (
        Leading = [],
        not declared_slot(Env, SchemaName, AggId ^ id_name, _)
    ;
        Leading = [Head | _],
        not json_slot(Env, SchemaName, Head ^ id_name)
    ).

    %@helper
:- pred declared_slot(type_env::in, string::in, string::in,
                      ast_field::out) is semidet.

declared_slot(Env, SchemaName, Name, Field) :-
    fact_schema(Env, SchemaName, Schema),
    find_field(Schema ^ as_fields, Name, Field).

    %@helper
:- pred json_slot(type_env::in, string::in, string::in) is semidet.

json_slot(Env, SchemaName, Name) :-
    declared_slot(Env, SchemaName, Name, Field),
    schema_slot(Env, SchemaName, Field ^ af_name) = ty_known(Type),
    Type ^ dt_leaf = lk_json.

%-----------------------------------------------------------------------------%

    % `t.dwell`: an alias, not a series read. It needs no `series` declaration.
    %
    %@spec [LSER.10.4]
    %@spec [LSER.8.2.1]
    %@spec [LEXP.9.5.1]
:- pred lser_10_4_dwell_read(type_env::in, lgra_9_3_1_expr::in, ident::in,
                             lexp_7_type::out) is semidet.

lser_10_4_dwell_read(Env, Base, Field, Type) :-
    Field ^ id_name = "dwell",
    type_of_expr(Env, Base) = ty_known(BaseType),
    BaseType ^ dt_leaf = lk_fact(SchemaName),

    not declared_slot(Env, SchemaName, "dwell", _),

    fact_schema(Env, SchemaName, Schema),
    (
        Schema ^ as_lifecycle = al_ttl(_, _),
        Type = ty_error([with_hint(error_at(dv_dwell_ttl_schema,
            Field ^ id_pos,
            "`dwell` is well-defined on a `logical` schema ([LFAC.1.2.4]); `"
                ++ SchemaName ++ "` is `ttl`"),
            "write the difference against the event's own timestamp -- "
                ++ "`now() - <binding>.<ts-slot>`")])
    ;
        % `monotonic_ns()` minus the fact's entry stamp ([LEXP.9.5.1]).
        Schema ^ as_lifecycle = al_logical(_),
        Type = ty_known(ds_type(lk_duration, dimensionless, non_null))
    ).

%-----------------------------------------------------------------------------%

    % The compiler supplies this slot ([LHYD.4.1.7]).
    %
    %@helper
:- pred hydrated_corr_read(type_env::in, lgra_9_3_1_expr::in,
                           ident::in) is semidet.

hydrated_corr_read(Env, Base, Field) :-
    Field ^ id_name = "hydrated_corr",
    type_of_expr(Env, Base) = ty_known(BaseType),
    BaseType ^ dt_leaf = lk_fact(SchemaName),
    not declared_slot(Env, SchemaName, "hydrated_corr", _).

    % The statistical family is `Float`, with the slot's dimension: they
    % interpolate. `variance`, `pvariance` and `rate` are typed only over a
    % dimensionless slot: over another their unit has no spelling ([LUNI.8.4]).
    % `integral` and `onset_rate` stay `ty_unknown`.
    %
    %@spec [LUNI.9.1]
    %@spec [LUNI.9.3]
    %@spec [LSER.17.2]
:- func luni_9_1_agg_type(type_env, string, string, string) = lexp_7_type.

luni_9_1_agg_type(Env, SchemaName, Slot, Agg) = Type :-
    Null = lser_19_8_cold_nullability(Agg),
    ( if luni_9_3_count_agg(Agg) then
        Type = scalar(lk_int)
    else if Agg = "direction" then
        Type = ty_known(ds_type(lk_int, dimensionless, Null))
    else if ( Agg = "contains" ; Agg = "bool_and" ; Agg = "bool_or" ) then
        Type = ty_known(ds_type(lk_bool, dimensionless, Null))
    else if Agg = "active_fraction" then
        Type = scalar(lk_float)
    else if
        luni_9_1_preserving(Agg),
        declared_slot(Env, SchemaName, Slot, Field)
    then
        % Its nullability is the aggregation's, not the slot's.
        SlotType = schema_slot(Env, SchemaName, Field ^ af_name),
        ( if SlotType = ty_known(Known) then
            Leaf = ( if lser_17_2_slot_typed(Agg) then Known ^ dt_leaf
                     else lk_float ),
            Type = ty_known(ds_type(Leaf, Known ^ dt_dim, Null))
        else
            Type = SlotType
        )
    else if
        ( Agg = "variance" ; Agg = "pvariance" ; Agg = "rate" ),
        declared_slot(Env, SchemaName, Slot, Field),
        schema_slot(Env, SchemaName, Field ^ af_name) = ty_known(Known),
        Known ^ dt_dim = dimensionless
    then
        Type = ty_known(ds_type(lk_float, dimensionless, Null))
    else
        Type = ty_unknown
    ).

    %@helper
:- pred lser_17_2_slot_typed(string::in) is semidet.

lser_17_2_slot_typed("min").
lser_17_2_slot_typed("max").
lser_17_2_slot_typed("sum").
lser_17_2_slot_typed("first").
lser_17_2_slot_typed("last").

    %@spec [LSER.19.8]
:- func lser_19_8_cold_nullability(string) = nullability.

lser_19_8_cold_nullability(Agg) =
    ( if lser_19_8_concrete_when_cold(Agg) then non_null else nullable ).

    %@helper
:- pred lser_19_8_concrete_when_cold(string::in) is semidet.

lser_19_8_concrete_when_cold("count").
lser_19_8_concrete_when_cold("count_distinct").
lser_19_8_concrete_when_cold("count_of").
lser_19_8_concrete_when_cold("contains").
lser_19_8_concrete_when_cold("sum").
lser_19_8_concrete_when_cold("active_fraction").
lser_19_8_concrete_when_cold("onset_rate").
lser_19_8_concrete_when_cold("integral").

    %@helper
:- pred luni_9_1_preserving(string::in) is semidet.

luni_9_1_preserving("min").
luni_9_1_preserving("max").
luni_9_1_preserving("mean").
luni_9_1_preserving("median").
luni_9_1_preserving("stdev").
luni_9_1_preserving("pstdev").
luni_9_1_preserving("sum").
luni_9_1_preserving("first").
luni_9_1_preserving("last").
luni_9_1_preserving(Agg) :-
    quantile_fn(Agg).

    %@helper
:- pred luni_9_3_count_agg(string::in) is semidet.

luni_9_3_count_agg("count").
luni_9_3_count_agg("count_distinct").
luni_9_3_count_agg("count_of").

%-----------------------------------------------------------------------------%

    % The schema a fact type names: a type-namespace entry, a qualified
    % `lib;Schema`, or the schema's own name ([LIMP.13.1]), which is how a
    % binding is typed.
    %
    %@helper
:- pred fact_schema(type_env::in, string::in, ast_schema::out) is semidet.

limp_13_1_fact_own(Env, Name) = Schema ^ as_own :-
    fact_schema(Env, Name, Schema).

fact_schema(Env, Name, Schema) :-
    Types = Env ^ te_file ^ rf_types,
    ( if map.search(Types, Name, te_schema(Found)) then
        Schema = Found
    else if
        map.search(Env ^ te_file ^ rf_qualified_schemas, Name, Qualified)
    then
        Schema = Qualified
    else
        list.find_first_match(limp_13_1_own_named(Name),
            list.filter_map(entry_schema, map.values(Types)), Schema)
    ).

    %@helper
:- func entry_schema(type_entry) = ast_schema is semidet.

entry_schema(te_schema(S)) = S.

    %@helper
:- pred limp_13_1_own_named(string::in, ast_schema::in) is semidet.

limp_13_1_own_named(Name, S) :-
    S ^ as_own = Name.

    %@helper
:- func schema_slot(type_env, string, ident) = lexp_7_type.

schema_slot(Env, SchemaName, Field) = Type :-
    ( if
        fact_schema(Env, SchemaName, Schema),
        find_field(Schema ^ as_fields, Field ^ id_name, F)
    then
        ( if slot_entry(Env ^ te_file, F, Entry) then
            Type = ty_known(luni_7_1_slot_type(Env ^ te_file ^ rf_unit_storage,
                Entry, F ^ af_nullable))
        else
            Type = ty_error([error_at(dv_unknown_type, F ^ af_type ^ id_pos,
                "slot `" ++ Field ^ id_name ++ "` is declared `"
                    ++ F ^ af_type ^ id_name ++ "`, which names no type")])
        )
    else
        Type = ty_error([error_at(dv_unknown_slot, Field ^ id_pos,
            "schema `" ++ SchemaName ++ "` has no slot `"
                ++ Field ^ id_name ++ "`")])
    ).

    %@helper
:- pred find_field(list(ast_field)::in, string::in, ast_field::out) is semidet.

find_field([F | Fs], Name, Found) :-
    ( if F ^ af_name ^ id_name = Name then
        Found = F
    else
        find_field(Fs, Name, Found)
    ).

%-----------------------------------------------------------------------------%
% Casts -- [LCST.4] end to end
%-----------------------------------------------------------------------------%

    %@spec [LCST.4.1.5]
    %@spec [LUNI.8.7.1]
    %@spec [LUNI.8.7.2]
    %@spec [LCST.4.3.2]
    %@spec [LCST.4.5.1]
    %@spec [LCST.4.5.3]
:- func lcst_4_1_5_cast_type(type_env, lgra_9_3_1_expr, ident, nullability, pos)
    = lexp_7_type.

lcst_4_5_1_identity_cast(Env, Operand, Target, Written) :-
    type_of_expr(Env, Operand) = ty_known(Source),
    Resolved = lcst_4_1_6_target_of(Env, Target),
    lcst_4_cast(luni_8_7_3_cast_kind(Source), Source ^ dt_null,
        Resolved ^ rt_target, Written) = co_ok(_, cs_identity).

lcst_4_1_5_cast_type(Env, Operand, Target, Written, Pos) = Type :-
    ( if Operand = ex_null(_) then
        Type = lcst_4_2_3_null_cast_type(Env, Target, Written, Pos)
    else
        SourceType = type_of_expr(Env, Operand),
        (
            SourceType = ty_error(Ds),
            Type = ty_error(Ds)
        ;
            SourceType = ty_unknown,
            Type = ty_unknown
        ;
            SourceType = ty_known(Source),
            ( if Resolved = lcst_4_1_6_target_of(Env, Target) then
                Outcome = lcst_4_cast(luni_8_7_3_cast_kind(Source),
                    Source ^ dt_null, Resolved ^ rt_target, Written),
                Type = lcst_4_3_2_outcome_type(Resolved, Target, Outcome, Pos)
            else
                Type = lcst_4_1_6_bad_target(Target)
            )
        )
    ).

    % The `null` literal has no leaf kind for `dsc.cast`'s table, and needs none:
    % only [LCST.4.3.1]'s nullable-source column applies.
    %
    %@spec [LCST.4.2.3]
    %@spec [LNUL.3.3]
:- func lcst_4_2_3_null_cast_type(type_env, ident, nullability, pos)
    = lexp_7_type.

lcst_4_2_3_null_cast_type(Env, Target, Written, Pos) = Type :-
    ( if Resolved = lcst_4_1_6_target_of(Env, Target) then
        (
            Written = nullable,
            Outcome = co_ok(nullable, cs_conversion)
        ;
            Written = non_null,
            Outcome = co_missing_q(why_source_nullable)
        ),
        Type = lcst_4_3_2_outcome_type(Resolved, Target, Outcome, Pos)
    else
        Type = lcst_4_1_6_bad_target(Target)
    ).

    %@spec [LCST.4.1.6]
:- func lcst_4_1_6_bad_target(ident) = lexp_7_type.

lcst_4_1_6_bad_target(Target) =
    ty_error([with_hint(error_at(dv_cast_undefined, Target ^ id_pos,
        "cannot convert to `" ++ Target ^ id_name ++ "`: a `::` target "
            ++ "must be a scalar builtin, `Json`, or a unit ([LCST.4.1.6])"),
        "a schema is not a cast target")]).

lcst_4_cast_pair(Env, Operand, Target, luni_8_7_3_cast_kind(Source),
        Resolved ^ rt_target) :-
    type_of_expr(Env, Operand) = ty_known(Source),
    Resolved = lcst_4_1_6_target_of(Env, Target).

    % A unit alias is a valid cast target, though not a valid slot type
    % ([LUNI.7.5]).
    %
    %@spec [LCST.4.1.6]
:- func lcst_4_1_6_target_of(type_env, ident) = resolved_target is semidet.

lcst_4_1_6_target_of(Env, Id) = Resolved :-
    Types = Env ^ te_file ^ rf_types,
    Storage = Env ^ te_file ^ rf_unit_storage,
    Name = Id ^ id_name,
    ( if map.search(Types, Name, Entry) then
        (
            Entry = te_builtin(B),
            builtin_target(B) = yes(Target),
            Resolved = resolved_target(Target, dimensionless)
        ;
            Entry = te_unit(uk_symbol(Dimension), Sym),
            Resolved = resolved_target(ct_unit(Sym,
                    luni_8_7_3_storage(Storage, Dimension)),
                dim(Dimension, yes(Sym)))
        )
    else
        map.search(Env ^ te_file ^ rf_unit_alias, Name, Canonical),
        map.search(Types, Canonical ^ id_name,
            te_unit(uk_symbol(Dimension), Sym)),
        Resolved = resolved_target(ct_unit(Sym,
                luni_8_7_3_storage(Storage, Dimension)),
            dim(Dimension, yes(Sym)))
    ).

    %@helper
:- type resolved_target
    --->    resolved_target(
                rt_target :: lcst_4_1_6_target,
                rt_dim    :: luni_8_7_3_dim
            ).

    %@helper
:- func builtin_target(lgra_22_8_builtin_type) = maybe(lcst_4_1_6_target).

builtin_target(bt_bool) = yes(ct_bool).
builtin_target(bt_bytes) = yes(ct_bytes).
builtin_target(bt_date) = yes(ct_date).
builtin_target(bt_duration) = yes(ct_duration).
builtin_target(bt_float) = yes(ct_float).
builtin_target(bt_int) = yes(ct_int).
builtin_target(bt_interval) = no.
builtin_target(bt_json) = yes(ct_json).
builtin_target(bt_string) = yes(ct_string).
builtin_target(bt_time) = yes(ct_time).

    %@spec [LCST.4.3.2]
:- func lcst_4_3_2_outcome_type(resolved_target, ident, cast_outcome, pos)
    = lexp_7_type.

lcst_4_3_2_outcome_type(Resolved, Target, Outcome, Pos) = Type :-
    (
        Outcome = co_ok(ResultNull, _Shape),
        % The result's dimension is the target's ([LUNI.8.7.1], [LUNI.8.7.2]).
        Type = ty_known(ds_type(target_leaf(Resolved ^ rt_target),
            Resolved ^ rt_dim, ResultNull))
    ;
        Outcome = co_refused(Why),
        Type = ty_error([error_at(lopq_4_3_refusal_code(Why), Pos,
            refusal_message(Why, Target ^ id_name))])
    ;
        Outcome = co_missing_q(Reason),
        (
            Reason = why_source_nullable,
            Because = "the source may be null"
        ;
            Reason = why_conversion_fallible,
            Because = "the conversion is fallible"
        ),
        Type = ty_error([with_hint(error_at(dv_cast_nullability, Pos,
            "missing `?`: `::" ++ Target ^ id_name ++ "?` is required because "
                ++ Because ++ " ([LCST.4.3])"),
            "write `::" ++ Target ^ id_name ++ "?`")])
    ;
        Outcome = co_redundant_q,
        Type = ty_error([with_hint(error_at(dv_cast_nullability, Pos,
            "redundant `?`: `::" ++ Target ^ id_name ++ "` is total and the "
                ++ "source is non-null, so the result can never be null "
                ++ "([LCST.4.3.2])"),
            "drop the `?`")])
    ).

    %@spec [LOPQ.4.3]
:- func lopq_4_3_refusal_code(lcst_4_5_3_refusal) = ds_validate.

lopq_4_3_refusal_code(cr_opaque_sealed) = dv_opaque_no_op.
lopq_4_3_refusal_code(cr_no_conversion) = dv_cast_undefined.
lopq_4_3_refusal_code(cr_bool_numeric) = dv_cast_undefined.
lopq_4_3_refusal_code(cr_json_not_fact) = dv_cast_undefined.
lopq_4_3_refusal_code(cr_json_source) = dv_cast_undefined.
lopq_4_3_refusal_code(cr_bytes_retired) = dv_bytes_conversion_retired.
lopq_4_3_refusal_code(cr_temporal_text) = dv_cast_undefined.

    %@helper
:- func refusal_message(lcst_4_5_3_refusal, string) = string.

refusal_message(cr_no_conversion, T) =
    "no conversion to `" ++ T ++ "` ([LCST.4.5.3]); the defined-conversion set "
        ++ "is closed".
refusal_message(cr_bool_numeric, T) =
    "no conversion to `" ++ T ++ "`: there is no implicit truthiness, so a "
        ++ "number and a `Bool` do not convert ([LCST.4.5.2])".
refusal_message(cr_json_not_fact, _) =
    "`Json` is fact-only: only a fact-typed value converts to `Json` "
        ++ "([LCST.4.5.2])".
refusal_message(cr_json_source, T) =
    "`Json` is fact-only; read a scalar via path projection (`j.field`) rather "
        ++ "than a cast to `" ++ T ++ "` ([LCST.4.5.2])".
refusal_message(cr_opaque_sealed, T) =
    "an opaque value is sealed and does not convert to `" ++ T
        ++ "` ([LOPQ.4.3])".
refusal_message(cr_bytes_retired, T) =
    "a cast to `" ++ T ++ "` between `Bytes` and `String` has left the "
        ++ "language (LSTR.4.6): decode or encode in the adapter, before the "
        ++ "fact is asserted".
refusal_message(cr_temporal_text, T) =
    "no conversion from `String` to `" ++ T ++ "`: DS reads no temporal text "
        ++ "([LCST.4.5.2], [LTIM.14]); the host delivers it typed, or "
        ++ "`calendar.time` / `calendar.date` build it from its fields, and a "
        ++ "`Duration` is unit arithmetic".

    %@helper
:- func target_leaf(lcst_4_1_6_target) = leaf_kind.

target_leaf(ct_int) = lk_int.
target_leaf(ct_float) = lk_float.
target_leaf(ct_bool) = lk_bool.
target_leaf(ct_string) = lk_string.
target_leaf(ct_bytes) = lk_bytes.
target_leaf(ct_json) = lk_json.
target_leaf(ct_unit(_, st_float)) = lk_float.
target_leaf(ct_unit(_, st_int)) = lk_int.
target_leaf(ct_time) = lk_time.
target_leaf(ct_date) = lk_date.
target_leaf(ct_duration) = lk_duration.

%-----------------------------------------------------------------------------%
% Unit literals
%-----------------------------------------------------------------------------%

    %@spec [LUNI.3.1.7]
    %@spec [LUNI.3.1.9]
:- func luni_3_1_7_literal_type(type_env, string, string, pos) = lexp_7_type.

luni_3_1_7_literal_type(Env, Magnitude, RawSuffix, Pos) = Type :-
    Suffix = llex_12_5_symbol_of(RawSuffix),
    RF = Env ^ te_file,
    ( if luni_3_1_7_unit_of(RF, RawSuffix, Dimension, Canonical) then
        % A literal whose value cannot be folded is not judged here. A literal
        % is judged as written, where [LUNI.3.1.9] judges a negated one after
        % negation: the two differ only for a body with a fractional offset.
        ( if
            luni_3_1_9_whole_dimension(RF ^ rf_unit_storage, Dimension),
            luni_4_3_base_value(RF, Magnitude, RawSuffix, Base),
            not is_whole(Base)
        then
            Type = ty_error([with_hint(error_at(dv_unit_literal_not_whole, Pos,
                "`" ++ Magnitude ++ RawSuffix ++ "` is not a whole number of "
                    ++ "the `" ++ Dimension ^ dr_name
                    ++ "` dimension's base unit, which "
                    ++ "stores whole numbers; it is never truncated "
                    ++ "([LUNI.3.1.9])"),
                "write the value in a smaller unit, or as a whole number of "
                    ++ "this one")])
        else
            Type = ltim_1_3_2_dimensioned(RF ^ rf_unit_storage, Dimension,
                Canonical)
        )
    else
        Type = ty_error([with_hint(error_at(dv_unknown_unit, Pos,
            "`" ++ Suffix ++ "` is not a declared unit symbol"),
            "declare it with `unit " ++ Suffix ++ ": <dimension>`, or import "
                ++ "the library that does")])
    ).

    % A `time`-dimensioned literal is a `Duration`, whichever unit it names, and
    % `dimensionless` as a `Duration` slot is. Any other dimension's takes its
    % storage's leaf kind ([LUNI.8.7.3]).
    %
    %@spec [LTIM.1.3.2]
:- func ltim_1_3_2_dimensioned(map(decl_ref, string), decl_ref, decl_ref)
    = lexp_7_type.

ltim_1_3_2_dimensioned(Storage, Dimension, Symbol) = Type :-
    ( if Dimension = time_dimension then
        Type = ty_known(ds_type(lk_duration, dimensionless, non_null))
    else
        Type = ty_known(ds_type(luni_8_7_3_leaf(Storage, Dimension),
            dim(Dimension, yes(Symbol)), non_null))
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.typecheck.
%-----------------------------------------------------------------------------%

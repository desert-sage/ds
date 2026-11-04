% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.quantity -- a quantity's exact value: in its dimension's base unit, and
% in a named unit of that dimension ([LUNI.4.3], [LADP.8.5.2]).
%
% Values are exact; a caller rounds once, when it emits ([LDET.3.3a.7]). The time
% units come from `luni_10_2_time_unit`'s table before the file's declarations.
%-----------------------------------------------------------------------------%
:- module dsc.quantity.
:- interface.

:- import_module dsc.ast.
:- import_module dsc.exact.
:- import_module dsc.expr.
:- import_module dsc.resolve.
:- import_module dsc.token.
:- import_module ds.
:- import_module ds.builtins.
:- import_module ds.value.

:- import_module bool.

    % The line of a `unit formula` in `rf_units` whose function is `Name`.
    %
    %@spec [LGRA.9.8.11]
:- pred lgra_9_8_11_formula_function(resolved_file::in, string::in,
                                     ast_formula_line::out) is semidet.

    % Whether `Unit`, a canonical symbol or an alias, is declared with no body.
    %
    %@helper
:- pred luni_4_3_base_unit(resolved_file::in, string::in) is semidet.

    % The dimension of a unit literal's suffix and its canonical symbol: the
    % file's unit registry first, then an alias, then the time units.
    %
    %@spec [LUNI.3.1.7]
:- pred luni_3_1_7_unit_of(resolved_file::in, string::in, decl_ref::out,
                           decl_ref::out) is semidet.

    % A unit literal's exact value in its dimension's base unit, not truncated
    % ([LUNI.3.1.9]). Fails for a tier-2 body, an unknown unit, or a magnitude
    % that does not read.
    %
    %@spec [LUNI.4.3]
:- pred luni_4_3_base_value(resolved_file::in, string::in, string::in,
                            rational::out) is semidet.

    % The non-time half of `luni_4_3_base_value`, for a symbol already stripped
    % of its separator.
    %
    %@spec [LUNI.4.3]
:- pred luni_4_3_affine_base(resolved_file::in, string::in, string::in,
                             rational::out) is semidet.

    % The magnitude negated, then the body applied: `-10_celsius` is 263.15 K.
    %
    %@spec [LUNI.3.3]
:- pred luni_3_3_negated_affine_base(resolved_file::in, string::in,
                                     string::in, rational::out) is semidet.

    % `<magnitude>_<unit>` in base units, as the literal of its dimension's
    % storage kind. Fails for a tier-2 unit. `dsc.typecheck` has refused a
    % non-whole literal in an integer-stored dimension, so the truncation is of
    % a whole number.
    %
    %@spec [LUNI.4.3]
    %@spec [LUNI.3.1.9]
:- pred luni_4_3_unit_literal(resolved_file::in, string::in, string::in,
                              ds_value::out) is semidet.

    %@spec [LUNI.3.3]
:- pred luni_4_3_negated_unit_literal(resolved_file::in, string::in,
                                      string::in, ds_value::out) is semidet.

    % A tier-2 unit's `to_base` body; fails for any other unit.
    %
    %@spec [LUNI.4.3]
:- pred luni_4_3_tier2_to_base(resolved_file::in, string::in,
                               lgra_9_3_1_expr::out) is semidet.

    % A base-unit value expressed in `Unit`. Fails when the body is tier-2, or
    % is not affine in `x`.
    %
    %@spec [LADP.8.5.2]
:- pred ladp_8_5_2_in_unit(resolved_file::in, string::in, rational::in,
                           rational::out) is semidet.

    % A slot tolerance declared in `Unit`, in the base unit: for `y = a*x + b`,
    % `|a| * Declared`. Fails for a tier-2 unit and for a name that is no unit.
    %
    %@spec [LUNI.7.4]
:- pred luni_7_4_tolerance_base(resolved_file::in, decl_ref::in, rational::in,
                                rational::out) is semidet.

    % Whether `Unit` is a base or tier-1 unit.
    %
    %@spec [LGRA.5.9.4]
:- pred lgra_5_9_4_scaled_unit(resolved_file::in, decl_ref::in) is semidet.

    % A base or tier-1 unit's line `base = A * declared + B`, each constant
    % folded exactly and rounded once, ties to even ([LUNI.2.7.1]): a base
    % unit's is `1.0` and `0.0`. Fails for a tier-2 unit, and for a declaration
    % that is no unit.
    %
    %@spec [RCLI.1.14]
:- pred rcli_1_14_baked_line(resolved_file::in, decl_ref::in, float::out,
                             float::out) is semidet.

    % Whether `Dimension` declares `storage int64` or `int32`.
    %
    %@helper
:- pred whole_number_dimension(resolved_file::in, decl_ref::in) is semidet.

    %@helper
:- pred is_whole(rational::in) is semidet.

    %@helper
:- pred quantity_literal(lgra_9_3_1_expr::in, bool::out, string::out,
                         string::out) is semidet.

    % A unit literal, or one negated, as its exact base-unit value.
    %
    %@helper
:- pred quantity_base(resolved_file::in, lgra_9_3_1_expr::in, rational::out)
    is semidet.

    % A quantity known at compile time ([LADP.8.5.3]), as its dimension and its
    % exact base-unit value. `LetRhs` gives a `let`'s right-hand side by name;
    % `Shadowed` says a pattern binding hides a `const`. Only a negated literal
    % negates its number first ([LUNI.3.3]). A whole-number quantity folds only
    % where its `Int` arithmetic is exact. Fails for anything else, and the
    % value is then converted when the call is evaluated.
    %
    %@helper
:- pred known_quantity(resolved_file::in,
                       pred(string, lgra_9_3_1_expr)::in(pred(in, out)
                           is semidet),
                       pred(string)::in(pred(in) is semidet),
                       lgra_9_3_1_expr::in, decl_ref::out, rational::out)
    is semidet.

    % Fails for a body that is not affine or, where the dimension is held as
    % whole numbers, a unit that is not a positive whole number of base units.
    %
    %@spec [RLOW.7.3.9]
:- pred rlow_7_3_9_conversion(resolved_file::in, decl_ref::in, string::in,
                              rlow_7_3_9_conversion::out) is semidet.

:- type rlow_7_3_9_conversion
    --->    cv_none
            % The kwarg's unit is its dimension's base unit.
    ;       cv_affine(float, float)
            % `(base - Offset) / Slope`.
    ;       cv_div_exact(int64)
            % `FN_INT_DIV_EXACT(base, Factor)`.
    ;       cv_from_base(lgra_9_3_1_expr).
            % A tier-2 unit's `from_base` body.

    %@spec [LUNI.4.3]
:- pred luni_4_3_tier2_fn(string::in, builtin_fn::out) is semidet.

    % The first node, left to right, of a tier-2 body that is outside
    % [LUNI.4.3]'s vocabulary. Fails when every node is inside it.
    %
    %@spec [LUNI.4.3]
:- pred luni_4_3_tier2_outside(lgra_9_3_1_expr::in, lgra_9_3_1_expr::out)
    is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.types.

:- import_module int.
:- import_module int64.
:- import_module list.
:- import_module map.
:- import_module string.

%-----------------------------------------------------------------------------%

lgra_9_8_11_formula_function(RF, Name, Line) :-
    list.find_first_match(
        ( pred(U::in) is semidet :-
            U = au_formula(_, _, Lines, _),
            list.find_first_match(
                ( pred(L::in) is semidet :- L ^ afl_name ^ id_name = Name ),
                Lines, _)
        ), RF ^ rf_units, Formula),
    Formula = au_formula(_, _, FormulaLines, _),
    list.find_first_match(
        ( pred(L::in) is semidet :- L ^ afl_name ^ id_name = Name ),
        FormulaLines, Line).

luni_4_3_base_unit(RF, Unit) :-
    unit_body(RF, Unit, aub_base).

luni_3_1_7_unit_of(RF, RawSuffix, Dimension, Canonical) :-
    Types = RF ^ rf_types,
    Suffix = llex_12_5_symbol_of(RawSuffix),
    ( if
        map.search(Types, Suffix, te_unit(uk_symbol(Dimension0), Symbol0))
    then
        Dimension = Dimension0,
        Canonical = Symbol0
    else if
        map.search(RF ^ rf_unit_alias, Suffix, CanonicalId),
        map.search(Types, CanonicalId ^ id_name,
            te_unit(uk_symbol(Dimension0), Symbol0))
    then
        Dimension = Dimension0,
        Canonical = Symbol0
    else
        luni_10_2_time_unit(Suffix, _),
        Dimension = time_dimension,
        Canonical = core_decl(Suffix)
    ).

luni_4_3_base_value(RF, Magnitude, RawSuffix, Base) :-
    Symbol = llex_12_5_symbol_of(RawSuffix),
    ( if luni_10_2_time_unit(Symbol, Multiplier) then
        luni_3_1_9_exact_ns(Magnitude, Multiplier, Base)
    else
        luni_4_3_affine_base(RF, Magnitude, Symbol, Base)
    ).

luni_4_3_affine_base(RF, Magnitude, Symbol, Base) :-
    dsc.exact.from_decimal(string.replace_all(Magnitude, "_", ""), X),
    affine_value(RF, X, Symbol, Base).

luni_3_3_negated_affine_base(RF, Magnitude, Symbol, Base) :-
    dsc.exact.from_decimal(string.replace_all(Magnitude, "_", ""), X),
    affine_value(RF, dsc.exact.negate(X), Symbol, Base).

luni_4_3_unit_literal(RF, Magnitude, Symbol, Value) :-
    luni_4_3_affine_base(RF, Magnitude, Symbol, Exact),
    storage_literal(RF, Symbol, Exact, Value).

luni_4_3_negated_unit_literal(RF, Magnitude, Symbol, Value) :-
    luni_3_3_negated_affine_base(RF, Magnitude, Symbol, Exact),
    storage_literal(RF, Symbol, Exact, Value).

luni_4_3_tier2_to_base(RF, Symbol, ToBase) :-
    unit_body(RF, Symbol, Body),
    Body = aub_tier2(ToBase, _, _).

    %@helper
:- pred storage_literal(resolved_file::in, string::in, rational::in,
                        ds_value::out) is semidet.

storage_literal(RF, Symbol, Exact, Value) :-
    ( if
        luni_3_1_7_unit_of(RF, Symbol, Dimension, _),
        whole_number_dimension(RF, Dimension)
    then
        Value = int(dsc.exact.truncate_wrapping_int64(Exact))
    else
        dsc.exact.to_float(Exact, F),
        Value = float(F)
    ).

    %@helper
:- pred affine_value(resolved_file::in, rational::in, string::in,
                     rational::out) is semidet.

affine_value(RF, X, Symbol, Base) :-
    unit_body(RF, Symbol, Body),
    (
        Body = aub_base,
        Base = X
    ;
        Body = aub_affine(Affine),
        affine_at(X, Affine, Base)
    ).

ladp_8_5_2_in_unit(RF, Unit, Base, Value) :-
    unit_line(RF, Unit, Line),
    (
        Line = line_identity,
        Value = Base
    ;
        % `base = Slope * x + Offset`, so `x = (base - Offset) / Slope`.
        Line = line_affine(Offset, Slope),
        dsc.exact.divide(dsc.exact.sub(Base, Offset), Slope, Value)
    ).

rlow_7_3_9_conversion(RF, Dimension, Unit, Conversion) :-
    ( if unit_line(RF, Unit, Line) then
        (
            Line = line_identity,
            Conversion = cv_none
        ;
            Line = line_affine(Offset, Slope),
            ( if whole_number_dimension(RF, Dimension) then
                Offset = dsc.exact.from_int64(0i64),
                is_whole(Slope),
                Factor = dsc.exact.truncate_wrapping_int64(Slope),
                Factor > 0i64,
                Conversion = ( if Factor = 1i64 then cv_none
                               else cv_div_exact(Factor) )
            else
                dsc.exact.to_float(Offset, OffsetF),
                dsc.exact.to_float(Slope, SlopeF),
                Conversion = cv_affine(OffsetF, SlopeF)
            )
        )
    else
        not whole_number_dimension(RF, Dimension),
        unit_body(RF, Unit, Body),
        Body = aub_tier2(_, FromBase, _),
        Conversion = cv_from_base(FromBase)
    ).

    % The line `base = Slope * x + Offset` a unit's value lies on.
    %
    %@helper
:- type unit_line
    --->    line_identity
    ;       line_affine(rational, rational).    % Offset, Slope

    %@helper
:- pred unit_line(resolved_file::in, string::in, unit_line::out) is semidet.

unit_line(RF, Unit, Line) :-
    ( if luni_10_2_time_unit(Unit, Multiplier) then
        Line = line_affine(dsc.exact.from_int64(0i64),
            dsc.exact.from_int64(Multiplier))
    else
        unit_body(RF, Unit, Body),
        body_line(Body, Line)
    ).

    % A third point checks the body is a line: `x ** 2` agrees with one at 0 and
    % 1.
    %
    %@helper
:- pred body_line(ast_unit_body::in, unit_line::out) is semidet.

body_line(Body, Line) :-
    (
        Body = aub_base,
        Line = line_identity
    ;
        Body = aub_affine(Affine),
        Zero = dsc.exact.from_int64(0i64),
        One = dsc.exact.from_int64(1i64),
        Two = dsc.exact.from_int64(2i64),
        affine_at(Zero, Affine, Offset),
        affine_at(One, Affine, AtOne),
        affine_at(Two, Affine, AtTwo),
        Slope = dsc.exact.sub(AtOne, Offset),
        AtTwo = dsc.exact.add(Offset, dsc.exact.mul(Slope, Two)),
        Line = line_affine(Offset, Slope)
    ).

luni_7_4_tolerance_base(RF, Unit, Declared, Base) :-
    declared_unit_body(RF, Unit, Body),
    body_line(Body, Line),
    (
        Line = line_identity,
        Base = Declared
    ;
        Line = line_affine(_Offset, Slope),
        Scale = ( if dsc.exact.sign(Slope) < 0 then dsc.exact.negate(Slope)
                  else Slope ),
        Base = dsc.exact.mul(Scale, Declared)
    ).

lgra_5_9_4_scaled_unit(RF, Unit) :-
    declared_unit_body(RF, Unit, Body),
    body_line(Body, _).

rcli_1_14_baked_line(RF, Unit, A, B) :-
    declared_unit_body(RF, Unit, Body),
    body_line(Body, Line),
    (
        Line = line_identity,
        A = 1.0,
        B = 0.0
    ;
        Line = line_affine(Offset, Slope),
        dsc.exact.to_float(Slope, A),
        dsc.exact.to_float(Offset, B)
    ).

whole_number_dimension(RF, Dimension) :-
    luni_3_1_9_whole_dimension(RF ^ rf_unit_storage, Dimension).

is_whole(R) :-
    R = dsc.exact.from_int64(dsc.exact.truncate_wrapping_int64(R)).

quantity_literal(E, Negated, Magnitude, Suffix) :-
    ( if E = ex_unary(uo_neg, Inner, _) then
        Inner = ex_unit(Magnitude, Suffix, _),
        Negated = yes
    else
        E = ex_unit(Magnitude, Suffix, _),
        Negated = no
    ).

quantity_base(RF, E, Base) :-
    quantity_literal(E, Negated, Magnitude, Suffix),
    (
        Negated = no,
        luni_4_3_base_value(RF, Magnitude, Suffix, Base)
    ;
        Negated = yes,
        Symbol = llex_12_5_symbol_of(Suffix),
        ( if luni_10_2_time_unit(Symbol, _) then
            luni_4_3_base_value(RF, Magnitude, Suffix, Base0),
            Base = dsc.exact.negate(Base0)
        else
            luni_3_3_negated_affine_base(RF, Magnitude, Symbol, Base)
        )
    ).

known_quantity(RF, LetRhs, Shadowed, E, Dimension, Base) :-
    known_quantity_within(RF, LetRhs, Shadowed, name_depth, E, Dimension,
        Base).

    % How many names a fold reads through. `dsc.validate` refuses a cycle in the
    % same pass that asks this, so a cycle has to stop here.
    %
    %@helper
:- func name_depth = int.

name_depth = 64.

    %@helper
:- pred known_quantity_within(resolved_file::in,
                              pred(string, lgra_9_3_1_expr)::in(pred(in, out)
                                  is semidet),
                              pred(string)::in(pred(in) is semidet), int::in,
                              lgra_9_3_1_expr::in, decl_ref::out, rational::out)
    is semidet.

known_quantity_within(RF, LetRhs, Shadowed, Depth, E, Dimension, Base) :-
    ( if quantity_literal(E, _, _, Suffix) then
        luni_3_1_7_unit_of(RF, Suffix, Dimension, _),
        quantity_base(RF, E, Base)
    else if E = ex_name(Id) then
        Depth > 0,
        ( if LetRhs(Id ^ id_name, Rhs) then
            known_quantity_within(RF, LetRhs, Shadowed, Depth - 1, Rhs,
                Dimension, Base)
        else
            not Shadowed(Id ^ id_name),
            map.search(RF ^ rf_consts, Id ^ id_name, Const),
            Const ^ acn_form = acf_value(_, ConstExpr),
            known_quantity_within(const_scope(RF, Const), LetRhs, Shadowed,
                Depth - 1, ConstExpr, Dimension, Base)
        )
    else if E = ex_unary(uo_neg, Inner, _) then
        known_quantity_within(RF, LetRhs, Shadowed, Depth, Inner, Dimension,
            Base0),
        Base = dsc.exact.negate(Base0)
    else if E = ex_unary(uo_pos, Inner, _) then
        known_quantity_within(RF, LetRhs, Shadowed, Depth, Inner, Dimension,
            Base)
    else if E = ex_binary(Op, L, R, _), ( Op = bo_add ; Op = bo_sub ) then
        known_quantity_within(RF, LetRhs, Shadowed, Depth, L, Dimension,
            LBase),
        known_quantity_within(RF, LetRhs, Shadowed, Depth, R, Dimension,
            RBase),
        Base = ( if Op = bo_add then dsc.exact.add(LBase, RBase)
                 else dsc.exact.sub(LBase, RBase) )
    else if E = ex_binary(bo_mul, L, R, _) then
        ( if
            known_quantity_within(RF, LetRhs, Shadowed, Depth, L, Dimension0,
                QBase0)
        then
            Dimension = Dimension0,
            QBase = QBase0,
            number_literal(R, IsInt, N)
        else
            number_literal(L, IsInt, N),
            known_quantity_within(RF, LetRhs, Shadowed, Depth, R, Dimension,
                QBase)
        ),
        ( if whole_number_dimension(RF, Dimension) then IsInt = yes
          else true ),
        Base = dsc.exact.mul(QBase, N)
    else
        E = ex_binary(bo_div, L, R, _),
        known_quantity_within(RF, LetRhs, Shadowed, Depth, L, Dimension,
            QBase),
        not whole_number_dimension(RF, Dimension),
        number_literal(R, _, N),
        dsc.exact.divide(QBase, N, Base)
    ).

    %@helper
:- pred number_literal(lgra_9_3_1_expr::in, bool::out, rational::out)
    is semidet.

number_literal(E, IsInt, N) :-
    (
        E = ex_int(I, _),
        IsInt = yes,
        N = dsc.exact.from_int64(I)
    ;
        E = ex_float(F, _),
        IsInt = no,
        dsc.exact.from_float(F, N)
    ;
        E = ex_unary(uo_neg, Inner, _),
        number_literal(Inner, IsInt, N0),
        N = dsc.exact.negate(N0)
    ).

    %@helper
:- pred unit_body(resolved_file::in, string::in, ast_unit_body::out)
    is semidet.

unit_body(RF, Symbol, Body) :-
    ( if map.search(RF ^ rf_types, Symbol, te_unit(uk_symbol(_), Named)) then
        Ref = Named
    else
        map.search(RF ^ rf_unit_alias, Symbol, Canonical),
        map.search(RF ^ rf_types, Canonical ^ id_name,
            te_unit(uk_symbol(_), Ref))
    ),
    declared_unit_body(RF, Ref, Body).

    %@spec [LUNI.4.1.5]
:- pred declared_unit_body(resolved_file::in, decl_ref::in, ast_unit_body::out)
    is semidet.

declared_unit_body(RF, decl_ref(File, Name), Body) :-
    list.find_first_match(
        ( pred(U::in) is semidet :-
            U = au_symbol(Id, _, _, _, _, _, File, _),
            Id ^ id_name = Name
        ), RF ^ rf_units, Decl),
    Decl = au_symbol(_, _, Body, _, _, _, _, _).

    % A tier-1 body at `x`. `dsc.libcall` has named `pi` as `math.pi`.
    %
    %@helper
:- pred affine_at(rational::in, lgra_9_3_1_expr::in, rational::out)
    is semidet.

affine_at(X, Expr, Value) :-
    (
        Expr = ex_name(Id),
        ( if Id ^ id_name = "x" then
            Value = X
        else
            Id ^ id_name = "math.pi",
            Value = dsc.exact.pi
        )
    ;
        Expr = ex_int(I, _),
        Value = dsc.exact.from_int64(I)
    ;
        Expr = ex_float(F, _),
        dsc.exact.from_float(F, Value)
    ;
        Expr = ex_unary(uo_neg, Operand, _),
        affine_at(X, Operand, V),
        Value = dsc.exact.negate(V)
    ;
        Expr = ex_unary(uo_pos, Operand, _),
        affine_at(X, Operand, Value)
    ;
        Expr = ex_binary(Op, Left, Right, _),
        affine_at(X, Left, L),
        affine_at(X, Right, R),
        (
            Op = bo_add, Value = dsc.exact.add(L, R)
        ;
            Op = bo_sub, Value = dsc.exact.sub(L, R)
        ;
            Op = bo_mul, Value = dsc.exact.mul(L, R)
        ;
            Op = bo_div, dsc.exact.divide(L, R, Value)
        ;
            Op = bo_pow, dsc.exact.int_pow(L, R, Value)
        )
    ).

%-----------------------------------------------------------------------------%
% A tier-2 body's vocabulary -- [LUNI.4.3]
%-----------------------------------------------------------------------------%

luni_4_3_tier2_fn("math.sqrt", fn_sqrt).
luni_4_3_tier2_fn("abs", fn_abs).
luni_4_3_tier2_fn("math.ln", fn_ln).
luni_4_3_tier2_fn("math.log10", fn_log10).
luni_4_3_tier2_fn("math.log2", fn_log2).
luni_4_3_tier2_fn("math.exp", fn_exp).

    % The same shapes `dsc.rete`'s `luni_4_3_from_base` lowers.
    %
luni_4_3_tier2_outside(Expr, Outside) :-
    ( if tier2_leaf(Expr) then
        fail
    else if tier2_children(Expr, Children) then
        tier2_first_outside(Children, Outside)
    else
        Outside = Expr
    ).

    %@helper
:- pred tier2_leaf(lgra_9_3_1_expr::in) is semidet.

tier2_leaf(ex_name(Id)) :-
    ( Id ^ id_name = "x"
    ; Id ^ id_name = "math.pi"
    ).
tier2_leaf(ex_int(_, _)).
tier2_leaf(ex_float(_, _)).

    %@helper
:- pred tier2_children(lgra_9_3_1_expr::in, list(lgra_9_3_1_expr)::out)
    is semidet.

tier2_children(ex_unary(Op, Operand, _), [Operand]) :-
    ( Op = uo_neg
    ; Op = uo_pos
    ).
tier2_children(ex_binary(Op, L, R, _), [L, R]) :-
    ( Op = bo_add
    ; Op = bo_sub
    ; Op = bo_mul
    ; Op = bo_div
    ; Op = bo_pow
    ).
tier2_children(ex_call(ex_name(Fn), [Arg], _), [Arg]) :-
    luni_4_3_tier2_fn(Fn ^ id_name, _).

    %@helper
:- pred tier2_first_outside(list(lgra_9_3_1_expr)::in, lgra_9_3_1_expr::out)
    is semidet.

tier2_first_outside([E | Es], Outside) :-
    ( if luni_4_3_tier2_outside(E, O) then
        Outside = O
    else
        tier2_first_outside(Es, Outside)
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.quantity.
%-----------------------------------------------------------------------------%

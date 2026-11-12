% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.types -- the static type, as three independent facets.
%
% Leaf kind and dimension are independent ([LUNI.8.7.3]). The dimension is a name:
% no syntax gives one exponents, and [LUNI.8.4] has no unit algebra to use them. A
% dimensioned value carries its symbol too: [LUNI.8.2] compares dimensions and
% [LCST.4.5.1] symbols.
%-----------------------------------------------------------------------------%

:- module dsc.types.
:- interface.

:- import_module dsc.cast.
:- import_module dsc.exact.
:- import_module dsc.expr.
:- import_module dsc.resolve.
:- import_module dsc.token.

:- import_module int64.
:- import_module map.
:- import_module maybe.
:- import_module string.

%-----------------------------------------------------------------------------%

    %@helper
:- type ds_type
    --->    ds_type(
                dt_leaf :: leaf_kind,
                dt_dim  :: luni_8_7_3_dim,
                dt_null :: nullability
            ).

    % A unit value's leaf kind is its dimension's storage kind.
    %
    %@helper
:- type leaf_kind
    --->    lk_int
    ;       lk_float
    ;       lk_bool
    ;       lk_string
    ;       lk_bytes
    ;       lk_json
    ;       lk_time
    ;       lk_date
    ;       lk_duration
    ;       lk_interval(maybe(leaf_kind))
            % The element type ([LINT.1.2]); `no` when neither endpoint's type
            % is known, or for a slot declared bare `Interval`.
    ;       lk_fact(string)
    ;       lk_opaque(decl_ref).

    % A dimension-typed slot or kwarg has no unit symbol ([LUNI.7.1]).
    %
    %@spec [LUNI.8.7.3]
    %@spec [LUNI.8.7.4]
:- type luni_8_7_3_dim
    --->    dimensionless
    ;       dim(
                dm_dimension :: decl_ref,
                dm_unit      :: maybe(decl_ref)
            ).

    % `%` is additive ([LUNI.8.3]). `/` and `//` are apart from `*` because a bare
    % number on their left has no dimension DS can state ([LUNI.8.4]), and the
    % same dimension on both sides gives a bare number ([LUNI.8.1]). `**` refuses
    % a dimensioned operand on either side.
    %
    %@spec [LUNI.8.3]
    %@spec [LUNI.8.4]
:- type luni_8_3_operator
    --->    op_additive
    ;       op_multiplicative
    ;       op_division
    ;       op_exponent.

    % `dr_bare_number` is a bare number beside a value of that dimension
    % ([LUNI.8.3]).
    %
    %@spec [LUNI.8.2]
    %@spec [LUNI.8.3]
    %@spec [LUNI.8.4]
:- type luni_8_2_result
    --->    dr_ok(luni_8_7_3_dim)
    ;       dr_cross_dimension(decl_ref, decl_ref)
    ;       dr_bare_number(decl_ref)
    ;       dr_needs_annotation(decl_ref, decl_ref).

    %@spec [LUNI.8.1]
    %@spec [LUNI.8.2]
    %@spec [LUNI.8.3]
    %@spec [LUNI.8.4]
:- func luni_8_1_combine(luni_8_3_operator, luni_8_7_3_dim, luni_8_7_3_dim)
    = luni_8_2_result.

    %@spec [LUNI.8.7.3]
:- func luni_8_7_3_cast_kind(ds_type) = lcst_4_5_2_kind.

    % The map is `rf_unit_storage`. `time` is `lk_duration` whether or not it
    % holds it ([LTIM.1.3.5]). A dimension it does not hold is `lk_float`, reached
    % only by a program already refused.
    %
    %@spec [LUNI.8.7.3]
:- func luni_8_7_3_leaf(map(decl_ref, string), decl_ref) = leaf_kind.

    %@spec [LUNI.8.7.3]
:- func luni_8_7_3_storage(map(decl_ref, string), decl_ref) = lcst_4_5_2_storage.

    %@spec [LUNI.3.1.9]
:- pred luni_3_1_9_whole_dimension(map(decl_ref, string)::in, decl_ref::in)
    is semidet.

    % A `unit scalar` group is a dimension here ([LUNI.4.2]), so [LUNI.8.2] keeps
    % `dB + radian` apart.
    %
    %@spec [LUNI.7.1]
:- func luni_7_1_slot_type(map(decl_ref, string), type_entry, nullability)
    = ds_type.

    % Fails for a plain number.
    %
    %@spec [LUNI.8.2]
:- pred luni_8_2_quantity_dimension(ds_type::in, decl_ref::out) is semidet.

    % The dimension a type of this leaf carries with no unit named: a `Duration`
    % is a value of `time`, and no other leaf has one.
    %
    %@spec [LTIM.1.3.5]
:- func ltim_1_3_5_leaf_dim(leaf_kind) = luni_8_7_3_dim.

    % The lexer keeps the separator: `30_s` lexes as `unit_lit("30", "_s")`.
    %
    %@spec [LLEX.12.5]
:- func llex_12_5_symbol_of(string) = string.

    % The time-dimension units, which resolve with no import, and each one's
    % nanosecond multiplier. `m` is no row: it means meters ([LGRA.2.8.9]).
    %
    %@spec [LUNI.10.2]
    %@spec [LGRA.2.8.9]
:- pred luni_10_2_time_unit(string::in, int64::out) is semidet.

    %@helper
:- func time_dimension = decl_ref.

    % A declaration of `units.core`, which every file holds ([LUNI.4.1.2]).
    %
    %@helper
:- func core_decl(string) = decl_ref.

    % The magnitude, decimal, times the multiplier, exactly ([LDET.3.3a.7]). A
    % non-whole product is refused before here ([LUNI.3.1.9]). Fails for a
    % product outside int64, which is never wrapped ([LUNI.2.4.1]): the caller
    % refuses it at the literal, or has.
    %
    %@spec [LUNI.3.1.5]
    %@spec [LUNI.2.4.1]
:- pred luni_3_1_5_magnitude_ns(string::in, int64::in, int64::out) is semidet.

    % The same product, exact. Fails on a magnitude that does not read as decimal.
    %
    %@spec [LUNI.3.1.9]
:- pred luni_3_1_9_exact_ns(string::in, int64::in, rational::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.ast.
:- import_module dsc.builtin_types.

:- import_module int.
:- import_module require.

luni_3_1_5_magnitude_ns(Magnitude, Multiplier, Value) :-
    Cleaned = string.replace_all(Magnitude, "_", ""),
    ( if dsc.exact.from_decimal(Cleaned, Exact) then
        dsc.exact.luni_2_4_1_int64(dsc.exact.truncate_integer(
            dsc.exact.mul(Exact, dsc.exact.from_int64(Multiplier))), Value)
    else
        unexpected($pred, unreadable(Magnitude))
    ).

luni_3_1_9_exact_ns(Magnitude, Multiplier, Exact) :-
    dsc.exact.from_decimal(string.replace_all(Magnitude, "_", ""), M),
    Exact = dsc.exact.mul(M, dsc.exact.from_int64(Multiplier)).

    %@helper
:- func unreadable(string) = string.

unreadable(Magnitude) =
    "unit literal magnitude `" ++ Magnitude ++ "` is not a decimal number "
        ++ "([LUNI.3.1.8])".

%-----------------------------------------------------------------------------%
% [LUNI.8.1] - [LUNI.8.4]
%-----------------------------------------------------------------------------%

luni_8_1_combine(_, dimensionless, dimensionless) = dr_ok(dimensionless).
luni_8_1_combine(Op, dim(D, U), dimensionless) = Result :-
    (
        Op = op_additive,
        Result = dr_bare_number(D)
    ;
        ( Op = op_multiplicative
        ; Op = op_division
        ),
        Result = dr_ok(dim(D, U))
    ;
        Op = op_exponent,
        Result = dr_needs_annotation(D, D)
    ).
luni_8_1_combine(Op, dimensionless, dim(D, U)) = Result :-
    (
        Op = op_additive,
        Result = dr_bare_number(D)
    ;
        Op = op_multiplicative,
        Result = dr_ok(dim(D, U))
    ;
        ( Op = op_division
        ; Op = op_exponent
        ),
        Result = dr_needs_annotation(D, D)
    ).
luni_8_1_combine(Op, dim(LeftDim, LeftUnit), dim(RightDim, _RightUnit))
        = Result :-
    (
        Op = op_additive,
        ( if LeftDim = RightDim then
            % The result takes the left operand's unit, a presentation choice.
            Result = dr_ok(dim(LeftDim, LeftUnit))
        else
            Result = dr_cross_dimension(LeftDim, RightDim)
        )
    ;
        Op = op_division,
        ( if LeftDim = RightDim then
            Result = dr_ok(dimensionless)
        else
            Result = dr_needs_annotation(LeftDim, RightDim)
        )
    ;
        ( Op = op_multiplicative
        ; Op = op_exponent
        ),
        Result = dr_needs_annotation(LeftDim, RightDim)
    ).

%-----------------------------------------------------------------------------%

luni_8_7_3_cast_kind(ds_type(Leaf, Dim, _)) = Kind :-
    (
        % The dimension wins over the leaf kind: `x::Float` on a `celsius` is
        % [LUNI.8.5]'s strip, not an identity. A `Duration` is its own row,
        % whichever `time` unit it was declared in ([LTIM.1.3.5]).
        Dim = dim(DimName, MaybeUnit),
        ( if Leaf = lk_duration then
            Kind = ck_duration
        else
            Storage = ( if Leaf = lk_int then st_int else st_float ),
            (
                MaybeUnit = yes(Unit),
                Kind = ck_unit(Unit, Storage)
            ;
                MaybeUnit = no,
                Kind = ck_dimension(DimName, Storage)
            )
        )
    ;
        Dim = dimensionless,
        (
            Leaf = lk_int,
            Kind = ck_int
        ;
            Leaf = lk_float,
            Kind = ck_float
        ;
            Leaf = lk_bool,
            Kind = ck_bool
        ;
            Leaf = lk_string,
            Kind = ck_string
        ;
            Leaf = lk_bytes,
            Kind = ck_bytes
        ;
            Leaf = lk_json,
            Kind = ck_json
        ;
            Leaf = lk_time,
            Kind = ck_time
        ;
            Leaf = lk_date,
            Kind = ck_date
        ;
            Leaf = lk_duration,
            Kind = ck_duration
        ;
            Leaf = lk_interval(_),
            Kind = ck_interval
        ;
            Leaf = lk_fact(Schema),
            Kind = ck_fact(Schema)
        ;
            Leaf = lk_opaque(Name),
            Kind = ck_opaque(Name)
        )
    ).

%-----------------------------------------------------------------------------%
% [LUNI.7.1] -- a declared name in type position becomes a static type
%-----------------------------------------------------------------------------%

luni_7_1_slot_type(_, te_builtin(Builtin), Null) =
    ds_type(builtin_leaf(Builtin), ltim_1_3_5_leaf_dim(builtin_leaf(Builtin)),
        Null).
luni_7_1_slot_type(_, te_schema(S), Null) =
    ds_type(lk_fact(S ^ as_own), dimensionless, Null).
luni_7_1_slot_type(_, te_opaque(O), Null) =
    ds_type(lk_opaque(decl_ref(O ^ aop_file, O ^ aop_name ^ id_name)),
        dimensionless, Null).
luni_7_1_slot_type(Storage, te_unit(Kind, Name), Null) = Type :-
    (
        Kind = uk_symbol(Dimension),
        Type = ds_type(luni_8_7_3_leaf(Storage, Dimension),
            dim(Dimension, yes(Name)), Null)
    ;
        Kind = uk_dimension,
        Type = ds_type(luni_8_7_3_leaf(Storage, Name), dim(Name, no), Null)
    ;
        Kind = uk_scalar,
        Type = ds_type(luni_8_7_3_leaf(Storage, Name), dim(Name, no), Null)
    ).

luni_8_2_quantity_dimension(Type, Dimension) :-
    Type ^ dt_dim = dim(Dimension, _).

ltim_1_3_5_leaf_dim(Leaf) =
    ( if Leaf = lk_duration then dim(time_dimension, no) else dimensionless ).

luni_8_7_3_leaf(Storage, Dimension) =
    ( if Dimension = time_dimension then lk_duration
      else if luni_3_1_9_whole_dimension(Storage, Dimension) then lk_int
      else lk_float ).

luni_8_7_3_storage(Storage, Dimension) =
    ( if Dimension = time_dimension then st_time
      else if luni_3_1_9_whole_dimension(Storage, Dimension) then st_int
      else st_float ).

luni_3_1_9_whole_dimension(Storage, Dimension) :-
    ( if Dimension = time_dimension then
        true
    else
        map.search(Storage, Dimension, Declared),
        ( Declared = "int64"
        ; Declared = "int32"
        )
    ).

    %@helper
:- func builtin_leaf(lgra_22_8_builtin_type) = leaf_kind.

builtin_leaf(bt_bool) = lk_bool.
builtin_leaf(bt_bytes) = lk_bytes.
builtin_leaf(bt_date) = lk_date.
builtin_leaf(bt_duration) = lk_duration.
builtin_leaf(bt_float) = lk_float.
builtin_leaf(bt_int) = lk_int.
builtin_leaf(bt_interval) = lk_interval(no).
builtin_leaf(bt_json) = lk_json.
builtin_leaf(bt_string) = lk_string.
builtin_leaf(bt_time) = lk_time.

%-----------------------------------------------------------------------------%

llex_12_5_symbol_of(Raw) = Symbol :-
    ( if string.remove_prefix("_", Raw, Rest) then
        Symbol = Rest
    else
        Symbol = Raw
    ).

%-----------------------------------------------------------------------------%
% The time units -- [LUNI.10.2]
%-----------------------------------------------------------------------------%
%
% U+00B5 and U+03BC render alike; both `µs` rows are here.

luni_10_2_time_unit("ns", 1i64).
luni_10_2_time_unit("µs", 1000i64).
luni_10_2_time_unit("μs", 1000i64).
luni_10_2_time_unit("us", 1000i64).
luni_10_2_time_unit("ms", 1000000i64).
luni_10_2_time_unit("s", 1000000000i64).
luni_10_2_time_unit("min", 60000000000i64).
luni_10_2_time_unit("h", 3600000000000i64).
luni_10_2_time_unit("d", 86400000000000i64).

time_dimension = core_decl("time").

core_decl(Name) = decl_ref("units.core", Name).

%-----------------------------------------------------------------------------%
:- end_module dsc.types.
%-----------------------------------------------------------------------------%

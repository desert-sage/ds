% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.cast -- the `::` conversion table, [LCST.4].
%
% Answers whether a pair is legal and what the result's nullability is. No row
% has a catch-all, so a new target is a compile error in every row. `typecheck`
% renders a refusal.
%-----------------------------------------------------------------------------%

:- module dsc.cast.
:- interface.

:- import_module dsc.expr.
:- import_module dsc.token.

%-----------------------------------------------------------------------------%

    % A source value's kind, for classification only: nullability is passed
    % separately.
    %
    %@spec [LCST.4.5.2]
:- type lcst_4_5_2_kind
    --->    ck_int
    ;       ck_float
    ;       ck_bool
    ;       ck_string
    ;       ck_bytes
    ;       ck_json
    ;       ck_unit(decl_ref, lcst_4_5_2_storage)
    ;       ck_dimension(decl_ref, lcst_4_5_2_storage)
    ;       ck_fact(string)
    ;       ck_opaque(decl_ref)
    ;       ck_time
    ;       ck_date
    ;       ck_duration
    ;       ck_interval.

    % The numeric kind a unit's dimension stores: `float64` is `Float`, `int64`
    % and `int32` are `Int`.
    %
    %@spec [LCST.4.5.2]
:- type lcst_4_5_2_storage
    --->    st_float
    ;       st_int.

    %@spec [LCST.4.1.6]
    %@spec [LCST.4.5.9]
:- type lcst_4_1_6_target
    --->    ct_int
    ;       ct_float
    ;       ct_bool
    ;       ct_string
    ;       ct_bytes
    ;       ct_json
    ;       ct_unit(decl_ref, lcst_4_5_2_storage)
    ;       ct_time
    ;       ct_date
    ;       ct_duration.

    %@spec [LCST.4.5.1]
    %@spec [LCST.4.5.2]
    %@spec [LCST.4.5.3]
:- type lcst_4_5_2_class
    --->    cc_total
    ;       cc_fallible
    ;       cc_identity
    ;       cc_rejected(lcst_4_5_3_refusal).

    %@spec [LCST.4.5.3]
:- type lcst_4_5_3_refusal
    --->    cr_no_conversion
    ;       cr_bool_numeric
    ;       cr_json_not_fact
    ;       cr_json_source
    ;       cr_opaque_sealed
    ;       cr_bytes_retired
            % `Bytes` <-> `String`, either way ([LSTR.4.6]).
    ;       cr_temporal_text.
            % `String` -> `Time`, `Date` or `Duration` ([LTIM.14]).

    %@spec [LCST.4.2.1]
    %@spec [LCST.4.2.2]
:- type lcst_4_2_1_fallibility
    --->    cf_total
    ;       cf_fallible.

    %@spec [LCST.4.3.1]
    %@spec [LCST.4.3.2]
:- type lcst_4_3_1_verdict
    --->    cv_ok(nullability)
    ;       cv_missing_q(lcst_4_3_1_why)
    ;       cv_redundant_q.

    % What made the result nullable; the source, when both did.
    %
    %@spec [LCST.4.3.1]
:- type lcst_4_3_1_why
    --->    why_source_nullable
    ;       why_conversion_fallible.

    %@helper
:- type cast_outcome
    --->    co_ok(nullability, cast_shape)
    ;       co_refused(lcst_4_5_3_refusal)
    ;       co_missing_q(lcst_4_3_1_why)
    ;       co_redundant_q.

    % An identity cast is legal and warnable ([LCST.4.5.1]).
    %
    %@helper
:- type cast_shape
    --->    cs_conversion
    ;       cs_identity.

    %@helper
:- func lcst_4_cast(lcst_4_5_2_kind, nullability, lcst_4_1_6_target,
                    nullability) = cast_outcome.

    %@spec [LCST.4.5.2]
:- func lcst_4_5_2_classify(lcst_4_5_2_kind, lcst_4_1_6_target)
    = lcst_4_5_2_class.

    % `null::T` is refused here, by the `nullable / total / non_null` cell.
    %
    %@spec [LCST.4.2.3]
    %@spec [LCST.4.3.1]
    %@spec [LCST.4.3.2]
:- func lcst_4_3_1_check(nullability, lcst_4_2_1_fallibility, nullability)
    = lcst_4_3_1_verdict.

    %@spec [LCST.4.2.1]
:- func lcst_4_2_1_fallibility_of(lcst_4_5_2_class) = lcst_4_2_1_fallibility
    is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

%-----------------------------------------------------------------------------%

lcst_4_cast(Source, SourceNull, Target, Written) = Outcome :-
    Class = lcst_4_5_2_classify(Source, Target),
    (
        Class = cc_rejected(Why),
        Outcome = co_refused(Why)
    ;
        ( Class = cc_total,    Shape = cs_conversion, F = cf_total
        ; Class = cc_fallible, Shape = cs_conversion, F = cf_fallible
        ; Class = cc_identity, Shape = cs_identity,   F = cf_total
        ),
        Verdict = lcst_4_3_1_check(SourceNull, F, Written),
        (
            Verdict = cv_ok(ResultNull),
            Outcome = co_ok(ResultNull, Shape)
        ;
            Verdict = cv_missing_q(Why2),
            Outcome = co_missing_q(Why2)
        ;
            Verdict = cv_redundant_q,
            Outcome = co_redundant_q
        )
    ).

lcst_4_2_1_fallibility_of(cc_total) = cf_total.
lcst_4_2_1_fallibility_of(cc_identity) = cf_total.
lcst_4_2_1_fallibility_of(cc_fallible) = cf_fallible.

%-----------------------------------------------------------------------------%
% [LCST.4.3.1]
%-----------------------------------------------------------------------------%

lcst_4_3_1_check(non_null, cf_total,    non_null) = cv_ok(non_null).
lcst_4_3_1_check(non_null, cf_total,    nullable) = cv_redundant_q.
lcst_4_3_1_check(non_null, cf_fallible, non_null) =
    cv_missing_q(why_conversion_fallible).
lcst_4_3_1_check(non_null, cf_fallible, nullable) = cv_ok(nullable).
lcst_4_3_1_check(nullable, cf_total,    non_null) =
    cv_missing_q(why_source_nullable).
lcst_4_3_1_check(nullable, cf_total,    nullable) = cv_ok(nullable).
lcst_4_3_1_check(nullable, cf_fallible, non_null) =
    cv_missing_q(why_source_nullable).
lcst_4_3_1_check(nullable, cf_fallible, nullable) = cv_ok(nullable).

%-----------------------------------------------------------------------------%
% [LCST.4.5.2] -- the defined conversions, one row per source kind
%-----------------------------------------------------------------------------%

lcst_4_5_2_classify(ck_int, Target) = Class :-
    (
        Target = ct_int,
        Class = cc_identity
    ;
        Target = ct_float,
        Class = cc_total
    ;
        Target = ct_bool,
        Class = cc_rejected(cr_bool_numeric)
    ;
        Target = ct_string,
        Class = cc_total
    ;
        Target = ct_json,
        Class = cc_rejected(cr_json_not_fact)
    ;
        % Tag-only ([LUNI.8.5]).
        Target = ct_unit(_, Storage),
        (
            Storage = st_int,
            Class = cc_total
        ;
            Storage = st_float,
            Class = cc_rejected(cr_no_conversion)
        )
    ;
        ( Target = ct_bytes
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_no_conversion)
    ).

lcst_4_5_2_classify(ck_float, Target) = Class :-
    (
        % Not fallible: a non-finite source is a runtime trap ([LCST.4.5.4]).
        Target = ct_int,
        Class = cc_total
    ;
        Target = ct_float,
        Class = cc_identity
    ;
        Target = ct_bool,
        Class = cc_rejected(cr_bool_numeric)
    ;
        Target = ct_string,
        Class = cc_total
    ;
        % Tag-only ([LUNI.8.5]): `20.0::celsius` is 20 celsius.
        Target = ct_unit(_, Storage),
        (
            Storage = st_float,
            Class = cc_total
        ;
            Storage = st_int,
            Class = cc_rejected(cr_no_conversion)
        )
    ;
        Target = ct_json,
        Class = cc_rejected(cr_json_not_fact)
    ;
        ( Target = ct_bytes
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_no_conversion)
    ).

lcst_4_5_2_classify(ck_bool, Target) = Class :-
    (
        Target = ct_bool,
        Class = cc_identity
    ;
        Target = ct_string,
        Class = cc_total
    ;
        ( Target = ct_int
        ; Target = ct_float
        ),
        Class = cc_rejected(cr_bool_numeric)
    ;
        Target = ct_json,
        Class = cc_rejected(cr_json_not_fact)
    ;
        ( Target = ct_bytes
        ; Target = ct_unit(_, _)
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_no_conversion)
    ).

lcst_4_5_2_classify(ck_string, Target) = Class :-
    (
        ( Target = ct_int
        ; Target = ct_float
        ; Target = ct_bool
        ),
        Class = cc_fallible
    ;
        ( Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_temporal_text)
    ;
        Target = ct_string,
        Class = cc_identity
    ;
        Target = ct_bytes,
        Class = cc_rejected(cr_bytes_retired)
    ;
        Target = ct_json,
        Class = cc_rejected(cr_json_not_fact)
    ;
        Target = ct_unit(_, _),
        Class = cc_rejected(cr_no_conversion)
    ).

lcst_4_5_2_classify(ck_bytes, Target) = Class :-
    (
        Target = ct_string,
        Class = cc_rejected(cr_bytes_retired)
    ;
        Target = ct_bytes,
        Class = cc_identity
    ;
        Target = ct_json,
        Class = cc_rejected(cr_json_not_fact)
    ;
        ( Target = ct_int
        ; Target = ct_float
        ; Target = ct_bool
        ; Target = ct_unit(_, _)
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_no_conversion)
    ).

lcst_4_5_2_classify(ck_json, Target) = Class :-
    (
        Target = ct_json,
        Class = cc_identity
    ;
        ( Target = ct_int
        ; Target = ct_float
        ; Target = ct_bool
        ; Target = ct_string
        ; Target = ct_bytes
        ; Target = ct_unit(_, _)
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_json_source)
    ).

lcst_4_5_2_classify(ck_unit(Symbol, Storage), Target) = Class :-
    (
        ( Target = ct_float
        ; Target = ct_int
        ),
        Class = storage_strip(Storage, Target)
    ;
        Target = ct_unit(TargetSymbol, _),
        ( if Symbol = TargetSymbol then
            Class = cc_identity
        else
            Class = cc_rejected(cr_no_conversion)
        )
    ;
        Target = ct_json,
        Class = cc_rejected(cr_json_not_fact)
    ;
        ( Target = ct_bool
        ; Target = ct_string
        ; Target = ct_bytes
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_no_conversion)
    ).

    %@helper
:- func storage_strip(lcst_4_5_2_storage, lcst_4_1_6_target) = lcst_4_5_2_class.

storage_strip(st_float, Target) =
    ( if Target = ct_float then cc_total else cc_rejected(cr_no_conversion) ).
storage_strip(st_int, Target) =
    ( if Target = ct_int then cc_total else cc_rejected(cr_no_conversion) ).

lcst_4_5_2_classify(ck_fact(_), Target) = Class :-
    (
        Target = ct_json,
        Class = cc_total
    ;
        ( Target = ct_int
        ; Target = ct_float
        ; Target = ct_bool
        ; Target = ct_string
        ; Target = ct_bytes
        ; Target = ct_unit(_, _)
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_no_conversion)
    ).

lcst_4_5_2_classify(ck_opaque(_), Target) = Class :-
    (
        ( Target = ct_int
        ; Target = ct_float
        ; Target = ct_bool
        ; Target = ct_string
        ; Target = ct_bytes
        ; Target = ct_json
        ; Target = ct_unit(_, _)
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_opaque_sealed)
    ).

lcst_4_5_2_classify(ck_time, Target) = temporal_row(ct_time, Target).
lcst_4_5_2_classify(ck_date, Target) = temporal_row(ct_date, Target).
    % `Duration → Int` is its nanoseconds.
lcst_4_5_2_classify(ck_duration, Target) =
    ( if Target = ct_int then cc_total
    else temporal_row(ct_duration, Target) ).
lcst_4_5_2_classify(ck_interval, Target) = no_conversion_row(Target).

    %@spec [LUNI.8.5]
lcst_4_5_2_classify(ck_dimension(_, Storage), Target) = Class :-
    (
        ( Target = ct_float
        ; Target = ct_int
        ),
        Class = storage_strip(Storage, Target)
    ;
        Target = ct_json,
        Class = cc_rejected(cr_json_not_fact)
    ;
        ( Target = ct_bool
        ; Target = ct_string
        ; Target = ct_bytes
        ; Target = ct_unit(_, _)
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_no_conversion)
    ).

    %@helper
:- func temporal_row(lcst_4_1_6_target, lcst_4_1_6_target) = lcst_4_5_2_class.

temporal_row(Own, Target) = Class :-
    ( if Target = Own then
        Class = cc_identity
    else if Target = ct_string then
        Class = cc_total
    else
        Class = no_conversion_row(Target)
    ).

    %@helper
:- func no_conversion_row(lcst_4_1_6_target) = lcst_4_5_2_class.

no_conversion_row(Target) = Class :-
    (
        Target = ct_json,
        Class = cc_rejected(cr_json_not_fact)
    ;
        ( Target = ct_int
        ; Target = ct_float
        ; Target = ct_bool
        ; Target = ct_string
        ; Target = ct_bytes
        ; Target = ct_unit(_, _)
        ; Target = ct_time
        ; Target = ct_date
        ; Target = ct_duration
        ),
        Class = cc_rejected(cr_no_conversion)
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.cast.
%-----------------------------------------------------------------------------%

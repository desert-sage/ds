% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.value -- the DS value type.
%
% One absent value: `null`, Kleene three-valued, rescued by `??`. A cache miss, an
% unresolved Json path and a Json `null` all read as it [LNUL.8.4]. A fault is no
% value: `ds.expr.eval_outcome`'s second arm.
%-----------------------------------------------------------------------------%

:- module ds.value.
:- interface.

:- import_module ds.chrono.
:- import_module ds.id.
:- import_module ds.json.
:- import_module bitmap.
:- import_module bool.

%-----------------------------------------------------------------------------%

:- type ds_value
    --->    int(int64)
            % Wrapping [LDET.6.2].

    ;       float(float)

    ;       str(intern_ref)

    ;       text(string)
            % A string computed during evaluation and not yet interned: the
            % evaluator holds the intern table read-only. Compared by content, also
            % against a `str`; interned where it is stored.

    ;       bool(bool)

    ;       bytes(bitmap)

    ;       json(json_term)

    ;       fact_ref(fact_id)
            % A reference to another fact in the same working memory.

    ;       duration(duration)
            % Not storable: a `Duration` slot holds its `int`.

    ;       time(ds_time)
            % `(utc_ns, tz_offset_ns)` [LTIM.1.1.1]. A slot persists `utc_ns` only
            % [LTIM.1.1.3] (`stored_value`).

    ;       ratio(int64, int64)
            % An exact rational between `FN_CURRENCY_CONVERT` and `FN_CURRENCY_ROUND`
            % [LUNI.13.3]. Not storable. Reduced, sign on the numerator, `q > 0`
            % [LUNI.2.1], so structural equality is rational equality.

    ;       null.

%-----------------------------------------------------------------------------%
% Json
%-----------------------------------------------------------------------------%

:- type json_term == json.

%-----------------------------------------------------------------------------%
% A literal on the wire
%-----------------------------------------------------------------------------%

    % `TestSlotLiteral`'s `value` oneof (`proto/test_scenario.proto`): the literal a
    % `.dstest` or an `initial:` block carries ([LGRA.24]). Not a `ds_value`: it becomes
    % one only against the slot it is given to.
    %
:- type test_value
    --->    tv_int(int64)
    ;       tv_float(float)
    ;       tv_string(string)
    ;       tv_bool(bool)
    ;       tv_duration(uint64)     % nanoseconds
    ;       tv_json(string).        % the JSON text, verbatim

%-----------------------------------------------------------------------------%
% Classification
%-----------------------------------------------------------------------------%

:- pred is_absent(ds_value::in) is semidet.

    % `fact_ref` can sit in a slot and cannot cross a tier boundary.
    %
:- pred is_storable(ds_value::in) is semidet.
:- pred is_portable(ds_value::in) is semidet.

    % What a slot holds for a value written to it: a `time` becomes its `utc_ns` as an
    % `int` [LTIM.1.1.3].
    %
:- func stored_value(ds_value) = ds_value.

%-----------------------------------------------------------------------------%
:- implementation.

is_absent(null).

is_storable(int(_)).
is_storable(float(_)).
is_storable(str(_)).
is_storable(bool(_)).
is_storable(bytes(_)).
is_storable(json(_)).
is_storable(fact_ref(_)).
is_storable(time(_)).
is_storable(null).

is_portable(int(_)).
is_portable(float(_)).
is_portable(str(_)).
is_portable(bool(_)).
is_portable(bytes(_)).
is_portable(json(_)).
is_portable(time(_)).
is_portable(null).

stored_value(V) = ( if V = time(T) then int(utc_ns(T)) else V ).

%-----------------------------------------------------------------------------%

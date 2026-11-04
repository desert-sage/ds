% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.builtins -- the author-surface names of the builtin functions.
%
% The names, arities and tiers are `lexp_17_2_row`, generated from [LEXP.17.2]. A
% `math` or `distance` row is qualified, `math.sin`, and `dsc.libcall` rewrites a
% call to the row's own name. Nothing ties the names to the runtime's `builtin_fn`.
%-----------------------------------------------------------------------------%

:- module dsc.builtins.
:- interface.

:- import_module list.

%-----------------------------------------------------------------------------%

    %@spec [LGRA.22.7]
:- pred lgra_22_7_builtin_fn(string::in) is semidet.

    % Sorted, with the percentile family as one entry ([LGRA.9.8.11]).
    %
    %@helper
:- func admitted_builtin_names = list(string).

    % Calls refused with `DS_VALIDATE_BYTES_CONVERSION_RETIRED`. None is a
    % builtin name, so a binding may take one.
    %
    %@spec [LSTR.4.6]
:- pred lstr_4_6_retired_fn(string::in) is semidet.

    % A sync-impure builtin, and its arities.
    %
    %@spec [LGRA.9.8.4]
:- pred lgra_9_8_4_sync_impure(string::in, list(int)::out) is semidet.

    % `inf` and `nan` are constants, not niladic functions. `nan` resolves here
    % so the caller can refuse it as NaN ([LEXP.4.2]).
    %
    %@spec [LEXP.4.1]
:- pred lexp_4_1_math_constant(string::in) is semidet.

    %@spec [LEXP.4.2]
:- pred lexp_4_2_unusable(string::in) is semidet.

    % `nan` has no value: it never reaches a lowering.
    %
    %@helper
:- pred lexp_4_1_math_constant_value(string::in, float::out) is semidet.

%-----------------------------------------------------------------------------%
% Builtin schemas
%-----------------------------------------------------------------------------%
%
% Held as DS source: the clauses give each as a `schema` declaration. `dsc.driver`
% injects these when a pattern names one, on any `call`, and on a hydration
% dispatch. A user declaration of one is refused ([LIMP.12.3]).

    %@helper
:- pred builtin_schema(string::in, string::out) is semidet.

    %@helper
:- func builtin_schema_names = list(string).

    % `ComputationError` and `TypeError`, written into every artefact
    % ([LERR.9.4]). The source has no `key` markers, though [LERR.9.2] marks `rule`
    % and `node`: only a `logical` schema carries slot roles ([RDSC.5.5.7]).
    %
    %@helper
:- func fault_schema_names = list(string).

    %@spec [LIMP.12.2]
:- func limp_12_2_always_written = list(string).

    % Every [LIMP.12.2] row but the two fault schemas, which are reserved words.
    %
    %@spec [LIMP.12.3]
:- func limp_12_3_collision_names = list(string).

    % A builtin's admitted argument counts: a set, not a range.
    %
    %@spec [LEXP.5.3.1]
    %@spec [LEXP.5.8.1]
:- pred lexp_5_8_1_arity(string::in, list(int)::out) is semidet.

    % What a builtin returns, where a clause gives it. Everything else is
    % `ty_unknown`.
    %
    %@spec [LGRA.9.8.1]
    %@spec [LEXP.5.9.1]
    %@spec [LTIM.2.1.1]
    %@spec [LTIM.2.2.1]
:- pred lgra_9_8_1_returns(string::in, builtin_result::out) is semidet.

    % `p1` through `p99` ([LSER.17.6]).
    %
    %@helper
:- pred quantile_fn(string::in) is semidet.

    %@helper
:- type builtin_result
    --->    br_int
    ;       br_float
    ;       br_bool
    ;       br_time
    ;       br_date
    ;       br_duration.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.builtin_fns.
:- import_module float.
:- import_module int.
:- import_module math.
:- import_module solutions.
:- import_module string.

%-----------------------------------------------------------------------------%

lgra_22_7_builtin_fn(Name) :-
    lexp_17_2_row(Name, _, _).

lstr_4_6_retired_fn("bytes_to_utf8").
lstr_4_6_retired_fn("bytes_to_int").
lstr_4_6_retired_fn("bytes_to_int_le").

lgra_9_8_4_sync_impure(Name, Arities) :-
    lexp_17_2_row(Name, Arities, tier_sync_impure).

admitted_builtin_names = Names ++ ["p1 … p99"] :-
    % The lambda names the `out` mode, which a bare predicate name does not
    % select.
    solutions(
        ( pred(N::out) is nondet :-
            lexp_17_2_row(N, _, _),
            not quantile_fn(N)
        ), Names).

%-----------------------------------------------------------------------------%

lexp_4_1_math_constant("inf").
lexp_4_1_math_constant("nan").

lexp_4_2_unusable("nan").

lexp_4_1_math_constant_value("inf", Value) :-
    Value = float.infinity.

%-----------------------------------------------------------------------------%
% The builtin schemas' source
%-----------------------------------------------------------------------------%
%
% The clauses' own code blocks, comments included.

builtin_schema_names =
    ["CallError", "HydrationComplete", "HydratedSample"].

fault_schema_names = ["ComputationError", "TypeError"].

limp_12_2_always_written = fault_schema_names ++ ["TimeZoneOffset"].

limp_12_3_collision_names = builtin_schema_names ++ ["TimeZoneOffset"].

    % [LTIM.10.6].
builtin_schema("TimeZoneOffset",
    "schema TimeZoneOffset scope logical ambient:\n" ++
    "    zone: String key          # the designation, byte for byte\n" ++
    "    valid_from: Time key      # the period's first instant, inclusive\n" ++
    "    valid_until: Time mutable # the period's end, exclusive\n" ++
    "    offset_s: Int mutable     # seconds east of UTC\n").

    % [LERR.9.2], slots in the table's order, which is the field numbering
    % ([LFST.8.10]). `dsc.driver` makes the lifecycle `internal`, which the author
    % grammar lacks ([LSCP.2.6.2]).
builtin_schema("ComputationError",
    "schema ComputationError scope explicit:\n" ++
    "    kind: String      # DIVIDE_BY_ZERO, DOMAIN or NOT_REPRESENTABLE\n" ++
    "    rule: String      # the fault's rule name (LERR.9.11); identity\n" ++
    "    schema: String    # the schema of the value with no answer\n" ++
    "    slot: String      # the slot of that value\n" ++
    "    node: Int         # the node that faulted; identity\n").

    % [LERR.9.3], as above.
builtin_schema("TypeError",
    "schema TypeError scope explicit:\n" ++
    "    actual: String    # the type tag the value actually had\n" ++
    "    rule: String      # the fault's rule name (LERR.9.11); identity\n" ++
    "    schema: String    # the schema of the value\n" ++
    "    slot: String      # the slot of that value\n" ++
    "    node: Int         # the node that faulted; identity\n").

    % [LCRS.4.2.1].
builtin_schema("CallError",
    "schema CallError scope ttl 5_min:\n" ++
    "    \"\"\"\n" ++
    "    Async error response to a `call` action. Asserted instead\n" ++
    "    of the response fact when the adapter could not fulfil\n" ++
    "    the request.\n" ++
    "    \"\"\"\n" ++
    "    corr: String              # correlation from the call's `as` binding\n" ++
    "    code: String              # error kind (see LECC)\n" ++
    "    message: String           # human-readable detail\n" ++
    "    ts: Time\n").

    % [LHYD.5.1]. `count` is a reserved word; the reserved-word check skips an
    % injected schema.
builtin_schema("HydrationComplete",
    "schema HydrationComplete scope ttl 5_min:\n" ++
    "    \"\"\"\n" ++
    "    Emitted once per hydration call after all matching facts\n" ++
    "    have been asserted. Signals that rules matching on the\n" ++
    "    hydrated set may fire.\n" ++
    "    \"\"\"\n" ++
    "    corr: String                    # correlation id from `as` binding\n" ++
    "    schema_name: String             # schema name queried\n" ++
    "    count: Int                      # facts asserted this hydration\n" ++
    "    truncated: Bool                 # hit the caller's `limit:`\n" ++
    "    t_start: Float                  # window start (epoch seconds)\n" ++
    "    t_end: Float                    # window end (approx call time)\n").

    % [LHYD.4.3.1].
builtin_schema("HydratedSample",
    "schema HydratedSample scope ttl 24_h:\n" ++
    "    adapter: String            # which adapter supplied the sample\n" ++
    "    entity_id: String\n" ++
    "    field: String\n" ++
    "    ts: Time\n" ++
    "    value: Float               # or stringified per value_type\n" ++
    "    value_type: String         # \"Float\", \"Int\", \"String\", \"Bool\"\n" ++
    "    hydrated_corr: String\n").

    % The round trip through `from_int` refuses `p01`.
quantile_fn(Name) :-
    string.remove_prefix("p", Name, Digits),
    string.to_int(Digits, N),
    N >= 1,
    N =< 99,
    string.from_int(N) = Digits.

%-----------------------------------------------------------------------------%
% Arity
%-----------------------------------------------------------------------------%

lexp_5_8_1_arity(Name, Arities) :-
    lexp_17_2_row(Name, Arities, _).

%-----------------------------------------------------------------------------%
% Return types
%-----------------------------------------------------------------------------%

    % [LGRA.9.8.1].
lgra_9_8_1_returns("len", br_int).
lgra_9_8_1_returns("has", br_bool).

    % [LTIM.2.1.1].
lgra_9_8_1_returns("now", br_time).

    % [LTIM.2.2.1].
lgra_9_8_1_returns("monotonic_ns", br_duration).

    % [LEXP.5.9.1]. `distance.great_circle` returns a `length`, which
    % `dsc.typecheck` types.
lgra_9_8_1_returns("distance.euclidean", br_float).
lgra_9_8_1_returns("distance.manhattan", br_float).
lgra_9_8_1_returns("distance.chebyshev", br_float).
lgra_9_8_1_returns("distance.cosine", br_float).
lgra_9_8_1_returns("distance.hypotenuse", br_float).

    % [LTIM.14.1].
lgra_9_8_1_returns("calendar.time", br_time).
lgra_9_8_1_returns("calendar.date", br_date).

%-----------------------------------------------------------------------------%
:- end_module dsc.builtins.
%-----------------------------------------------------------------------------%

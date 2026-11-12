% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.expr -- the single expression representation: `rete_expr.proto`'s `Expr`,
% carried by join tests, alpha tests and action arguments ([RTIM.14.8]).
% `ds.dsc_expr` decodes all three.
%
% No decoder produces `e_slot_named`, `e_json_path` or `e_agg`.
%-----------------------------------------------------------------------------%

:- module ds.expr.
:- interface.

:- import_module bool.
:- import_module ds.builtins.
:- import_module ds.chrono.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.json.
:- import_module ds.value.
:- import_module list.
:- import_module maybe.
:- import_module uint32.

%-----------------------------------------------------------------------------%
% Reading from a token
%-----------------------------------------------------------------------------%

    % Which fact of the firing token an expression reads.
    %
    % `pattern_index = 255` on a `VarExpr` means "the candidate right fact",
    % not a position ([RDSC.4a.7], [RDSC.4a.9.1]).
    %
:- type fact_index
    --->    token_fact(int)     % zero-based position in the token
    ;       candidate.          % the right-activating fact; join tests only

    % What an expression reads out of that fact. `VarExpr.slot_index = 255`, and
    % only `VarExpr`'s, means the fact itself ([RDSC.4a.9.1]).
    %
:- type slot_read
    --->    slot(slot_index)
    ;       whole_fact.

    % The two markers lifted at the wire boundary ([RDSC.4a.9.1]). An index field
    % holds 0..254, and 255 where it has a marker. Each reader FAILS on a value
    % its field cannot hold.
    %
    %   wire_fact_index   a pattern index (`VarExpr.pattern_index`,
    %                     `Expr.entry_stamp`): 255 is `candidate`
    %   wire_slot_read    `VarExpr.slot_index`, and ONLY it: 255 is
    %                     `whole_fact`
    %   wire_slot_strict  a slot index with no marker (`AlphaTest.slot_index`
    %                     [RDSC.4a.6.1], `SlotAssign.slot_index`): 0..254
    %
    % `Action.withdraw_pattern_index`, a token position with no marker, is
    % `wire_fact_index` answering a `token_fact`.
    %
:- pred wire_fact_index(uint32::in, fact_index::out) is semidet.
:- pred wire_slot_read(uint32::in, slot_read::out) is semidet.
:- pred wire_slot_strict(uint32::in, slot_index::out) is semidet.

%-----------------------------------------------------------------------------%
% Operators
%-----------------------------------------------------------------------------%

    % Symbolic: the decoder owns the number-to-symbol table.
    %
:- type binop
    --->    op_add ; op_sub ; op_mul
    ;       op_div          % always Float [LEXP.7.14]
    ;       op_floordiv     % `//`
    ;       op_rem          % `%`
        % No `**`: it is the `FN_POW` call ([LEXP.7.3a]).

    ;       op_eq ; op_ne ; op_lt ; op_le ; op_gt ; op_ge

    ;       op_and ; op_or

    ;       op_bit_and ; op_bit_or ; op_bit_xor
    ;       op_shl
    ;       op_shr.         % arithmetic, sign-preserving [LEXP.7.14]

:- type unop
    --->    op_not
    ;       op_neg
    ;       op_pos
    ;       op_bitnot.

%-----------------------------------------------------------------------------%
% Interpolation primitives
%-----------------------------------------------------------------------------%

    % `FormatPrim` (RLOW.6.4): the compiler resolves every spec into these, so
    % no format string reaches a runtime ([IARC.1.16]). How the parts combine
    % with the type is judged at render (`ds.format`), not at load.
    %
:- type format_prim
    --->    fp_text(string)

    ;       fp_value(value_prim)

    ;       fp_time(expr, list(time_item)).
            % One `Time` under a timestamp spec [LGRA.2.9.6.4]: evaluated once,
            % every field in the value's own UTC offset.

    % `ValuePrim`: one value under [LGRA.2.9.6.10]. Width and precision count
    % code points.
    %
:- type value_prim
    --->    value_prim(
                vp_value     :: expr,
                vp_align     :: format_align,
                vp_plus      :: bool,       % `+`: a non-negative number carries `+`
                vp_zero      :: bool,       % `0`: zeros after the sign
                vp_width     :: uint32,     % 0 is no minimum
                vp_precision :: maybe(uint32),
                vp_type      :: format_type
            ).

:- type format_align
    --->    align_default       % a number right, a String or Bool left
    ;       align_left          % `<`
    ;       align_right.        % `>`

:- type format_type
    --->    ft_canonical        % no type: the value's canonical text
    ;       ft_d
    ;       ft_f
    ;       ft_s
    ;       ft_x_lower
    ;       ft_x_upper
    ;       ft_b.

:- type time_item
    --->    ti_text(string)     % `%%` resolved to `%`
    ;       ti_field(time_field).

:- type time_field
    --->    tf_year             % %Y
    ;       tf_month            % %m
    ;       tf_day              % %d
    ;       tf_hour             % %H
    ;       tf_minute           % %M
    ;       tf_second           % %S
    ;       tf_microsecond      % %f
    ;       tf_utc_offset.      % %z

%-----------------------------------------------------------------------------%
% Series aggregation
%-----------------------------------------------------------------------------%

    % `all_time` and a zero-length sliding window are different queries.
    %
:- type agg_window
    --->    all_time
    ;       sliding(duration).

:- type agg_kind
    --->    agg_mean
    ;       agg_median
    ;       agg_min
    ;       agg_max
    ;       agg_sum
    ;       agg_count
    ;       agg_stdev           % sample
    ;       agg_pstdev          % population
    ;       agg_var             % sample
    ;       agg_pvar            % population

    ;       agg_p1
    ;       agg_p5
    ;       agg_p10
    ;       agg_p25
    ;       agg_p50
    ;       agg_p75
    ;       agg_p90
    ;       agg_p95
    ;       agg_p99

    ;       agg_first
    ;       agg_last
    ;       agg_rate
    ;       agg_direction
    ;       agg_count_distinct
    ;       agg_bool_and
    ;       agg_bool_or.

:- type agg_spec
    --->    agg_spec(
                ag_kind    :: agg_kind,
                ag_schema  :: schema_id,
                ag_slot    :: slot_index,
                ag_window  :: agg_window,
                ag_id_fact :: fact_index
                            % the token fact supplying the series' identity value
            ).

%-----------------------------------------------------------------------------%
% Bindings
%-----------------------------------------------------------------------------%

    % A `bind_ref` index into its site's frame. `bind_index/3` makes one inside a
    % frame of the given size, for code that builds a frame.
    %
:- type bind_index.
:- func bind_index_int(bind_index) = int.
:- pred bind_index(int::in, int::in, bind_index::out) is semidet.

    % An index as the artefact wrote it, whatever its site's frame. A loader
    % keeps it: one outside the frame is `ARTEFACT_LIED` where the engine reads
    % or writes it, never a load refusal [RDSC.4a.9.6].
    %
:- func bind_index_of(uint32) = bind_index.

    % The frame an expression's site has. A `fire_guard` has its terminal's; a
    % `BetaNode`'s `join_tests` have none.
    %
:- type bind_scope
    --->    no_bind_frame
    ;       bind_frame(int).        % TerminalNode.bind_count

%-----------------------------------------------------------------------------%
% The expression
%-----------------------------------------------------------------------------%

:- type expr
    --->    e_lit(ds_value)

    ;       e_slot(fact_index, slot_read)
            % `VarExpr`: reads a slot by index.

    ;       e_slot_named(fact_index, intern_ref)

    ;       e_json_path(fact_index, json_path)

    ;       e_json_path_expr(expr, expr)
            % `JsonPathExpr`. The compiler emits a `json_path` builtin call
            % instead, so no artefact of its carries this.

    ;       e_binop(binop, expr, expr)
    ;       e_unop(unop, expr)

    ;       e_interp(list(format_prim))
            % `InterpExpr` (RLOW.6.4): rendered in one pass, left to right.

    ;       e_agg(agg_spec)

    ;       e_call(builtin_fn, list(expr))

    ;       e_now
            % `now()`: the wall clock's held sample, one per step ([LTIM.2.8.3],
            % [LTIM.2.8.4]).

    ;       e_entry_stamp(fact_index)
            % [LTIM.2.8.6]: the monotonic sample when a fact of the token, or the
            % join's candidate, entered working memory.

    ;       e_if(expr, expr, expr)

    ;       e_coalesce(expr, expr)
            % `??`: rescues `null`, lazily [LNUL.8.9], and no fault.

    ;       e_bind(bind_index, expr)
            % `BindExpr`: yields its value. Not a memoisation point.

    ;       e_bind_ref(bind_index)

    ;       e_tainted(expr)
            % `Expr.json_tainted`: the value derives from a `Json` projection
            % ([IRET.9.6]), carried only where the bit is set. A type mismatch
            % raised by a tainted node is a TypeError; by a clean one, EngineError
            % ARTEFACT_LIED. `ds.eval.eval` classifies at the node.

    ;       e_is_test(expr, is_subject, bool).
            % `x is <subject>` [LNUL.4.9]: total, never `null`, never a fault.
            % The `bool` is `negated`, which inverts after the test.

    % [LNUL.4.9]'s closed subject set: six constants that test tag and value, six
    % tag names that test the tag alone.
    %
:- type is_subject
    --->    is_null
    ;       is_true
    ;       is_false
    ;       is_inf
    ;       is_neg_inf
    ;       is_nan
    ;       is_int
    ;       is_float
    ;       is_bool
    ;       is_string
    ;       is_bytes
    ;       is_json.

    % An expression's immediate sub-expressions, in no particular order.
    %
:- func expr_children(expr) = list(expr).

    % The expression beneath any `e_tainted` wrappers, for code that matches an
    % expression's shape; evaluation reads the wrapper.
    %
:- func untainted(expr) = expr.

%-----------------------------------------------------------------------------%
% Evaluation
%-----------------------------------------------------------------------------%

    % A fault abandons the evaluation, and an action that meets one abandons its
    % activation [LERR.1].
    %
:- type eval_outcome
    --->    ev_ok(ds_value)
    ;       ev_fault(runtime_fault).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.

%-----------------------------------------------------------------------------%

wire_fact_index(N, Fact) :-
    ( if N = rdsc_4a_9_1_marker then
        Fact = candidate
    else
        uint32.cast_to_int(N) < rdsc_4a_9_1_index_count,
        Fact = token_fact(uint32.cast_to_int(N))
    ).

wire_slot_read(N, Read) :-
    ( if N = rdsc_4a_9_1_marker then
        Read = whole_fact
    else
        wire_slot_strict(N, Slot),
        Read = slot(Slot)
    ).

wire_slot_strict(N, Slot) :-
    uint32.cast_to_int(N) < rdsc_4a_9_1_index_count,
    slot_index(N, Slot).

%-----------------------------------------------------------------------------%

:- type bind_index ---> bind_index(int).

bind_index(BindCount, N, bind_index(N)) :-
    N >= 0,
    N < BindCount.

bind_index_int(bind_index(N)) = N.

bind_index_of(N) = bind_index(uint32.cast_to_int(N)).

%-----------------------------------------------------------------------------%

expr_children(e_lit(_)) = [].
expr_children(e_slot(_, _)) = [].
expr_children(e_slot_named(_, _)) = [].
expr_children(e_json_path(_, _)) = [].
expr_children(e_json_path_expr(A, B)) = [A, B].
expr_children(e_binop(_, A, B)) = [A, B].
expr_children(e_unop(_, A)) = [A].
expr_children(e_interp(Prims)) = list.condense(list.map(prim_children, Prims)).
expr_children(e_agg(_)) = [].
expr_children(e_call(_, Es)) = Es.
expr_children(e_now) = [].
expr_children(e_entry_stamp(_)) = [].
expr_children(e_if(C, T, E)) = [C, T, E].
expr_children(e_coalesce(A, B)) = [A, B].
expr_children(e_bind(_, A)) = [A].
expr_children(e_bind_ref(_)) = [].
expr_children(e_is_test(A, _, _)) = [A].
expr_children(e_tainted(A)) = [A].

:- func prim_children(format_prim) = list(expr).

prim_children(fp_text(_)) = [].
prim_children(fp_value(V)) = [V ^ vp_value].
prim_children(fp_time(E, _)) = [E].

untainted(E0) = E :-
    ( if E0 = e_tainted(Inner) then
        E = untainted(Inner)
    else
        E = E0
    ).

%-----------------------------------------------------------------------------%

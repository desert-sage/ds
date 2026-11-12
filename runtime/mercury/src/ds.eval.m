% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.eval -- the expression evaluator [RTIM.14.8]: `where` clauses, join tests,
% fire guards and action arguments all arrive here. Modelled by
% `formal/k/dsexpr.k`.
%
% `eval` is total: an expression has a value or it faults, and the node that
% raised a fault classifies it [LERR.1].
%-----------------------------------------------------------------------------%

:- module ds.eval.
:- interface.

:- import_module ds.cache.
:- import_module ds.chrono.
:- import_module ds.expr.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.schema.
:- import_module ds.series.
:- import_module ds.value.
:- import_module ds.wm.
:- import_module list.
:- import_module map.
:- import_module maybe.

%-----------------------------------------------------------------------------%

    % What an expression is evaluated against.
    %
:- type eval_ctx
    --->    eval_ctx(
                ec_token     :: list(fact_id),
                            % Position i is the fact bound by the rule's i-th
                            % positive pattern.

                ec_candidate :: maybe(fact_id),
                            % The right-activating fact, for a join test.

                ec_wm        :: wm,
                ec_schemas   :: map(uint32, schema),
                            % By `schema_id` value.

                ec_interns   :: intern_table,
                ec_now       :: instant,
                            % The monotonic clock's held sample [LTIM.2.8.2],
                            % the same for every evaluation in the step
                            % [LTIM.2.8.4].

                ec_wall      :: maybe(int64),
                            % The wall clock's held sample [LTIM.2.8.3], UTC ns:
                            % what `now()` reads. `no` while it has no value.

                ec_binds     :: map(int, ds_value),
                            % The terminal's bind frame; empty in a join test.

                ec_frame     :: int,
                            % The frame's size: the terminal's `bind_count`, 1
                            % for a slot's conversion, 0 for a node's test. An
                            % index past it is ARTEFACT_LIED [RDSC.4a.9.6].

                ec_cache     :: cache,
                ec_series    :: series_state
            ).

:- pred eval(expr::in, eval_ctx::in, eval_outcome::out) is det.

    % `eval`, and the keys of the cache entries it read and found expired, each
    % once, in the order first read [NSTG.2.4.2]. The cache is read-only here, so
    % the caller evicts and notifies.
    %
:- pred eval_noting_expiry(expr::in, eval_ctx::in, eval_outcome::out,
                           list(string)::out) is det.

    % Evaluate a list, stopping at the first hard fault.
    %
:- type eval_list_outcome
    --->    evs_ok(list(ds_value))
    ;       evs_fault(runtime_fault).

:- pred eval_all(list(expr)::in, eval_ctx::in, eval_list_outcome::out) is det.

    % Evaluate an action-argument expression to its rendered text. Interpolation is
    % action-argument-only [LGRA.2.9.6.8]. A string computed during evaluation is
    % carried as `ds.value.text` and interned only where it is stored.
    %
:- type text_outcome
    --->    text_ok(string)
    ;       text_fault(runtime_fault).
            % A fault inside the text, or a value that has no text. The action
            % that wanted it is abandoned [LERR.1].

:- pred eval_text(expr::in, eval_ctx::in, text_outcome::out) is det.

    % Whether a value admits a match at the Rete boundary [LNUL.4.3]: only `true`.
    %
:- pred admits(eval_outcome::in) is semidet.

    % The fault a positive join test raises, if it does [IRET.7.6]: a fault its
    % evaluation met, or a present value in the predicate position that is neither
    % a Bool nor `null`, classified by the test's own taint. Fails on a Bool or
    % `null`.
    %
:- pred test_fault(expr::in, eval_outcome::in, runtime_fault::out) is semidet.

    % `true` or `null` [LNUL.4.7]. Only tests call this: a match decides by
    % `ds.match.block_verdict`, where a fault or a non-Bool also keeps the block.
    %
:- pred blocks(eval_outcome::in) is semidet.

%-----------------------------------------------------------------------------%
% Where a fault came from
%-----------------------------------------------------------------------------%

    % The value an evaluation had no answer for [NCBK.2.10]: the fact and slot the
    % offending operand was read from, and its kind. Each field is `no` where the
    % operand was not a slot read.
    %
:- type fault_origin
    --->    fault_origin(
                fo_fact   :: maybe(fact_id),
                fo_schema :: maybe(intern_ref),
                fo_slot   :: maybe(intern_ref),
                fo_actual :: maybe(string)
            ).

:- func no_origin = fault_origin.

    % Where in `Expr`, evaluated under `Ctx`, the fault was raised, and what over.
    % Found on the fault path only, by re-evaluating: the descent takes the child
    % that raises the same fault, or of several the one whose origin [LNUL.4.2]
    % ranks first, until no child does.
    %
    % At the raise site the offending operand is the first whose value is known and
    % `null` [IRET.9.6], else a division's or remainder's divisor, else the first
    % operand. Known means a literal or a slot read. So `a + b` over a String and
    % an Int names `a`.
    %
:- func fault_origin(expr, eval_ctx, runtime_fault) = fault_origin.

:- type located
    --->    located(runtime_fault, fault_origin).

    % [LNUL.4.2]: whether the first fault ranks strictly before the second: kind
    % first (`ds.fault.lnul_4_2_kind_key`), then the offending operand's fields of
    % the record, the only ones that can differ. A `ComputationError` orders by
    % (`schema_name`, `slot_name`, `fact_id`), a `TypeError` by (`schema_name`,
    % `slot_name`, `actual`). A string compares by its UTF-8 bytes, a proper prefix
    % first, and an unset field as `""` or `0`.
    %
:- pred lnul_4_2_before(eval_ctx::in, located::in, located::in) is semidet.

    % [LNUL.4.2]: the one of two operand faults an expression yields; of a complete
    % tie, the first. Position never enters [LNUL.4.10].
    %
:- func lnul_4_2_yielded(eval_ctx, located, located) = located.

    % The tag of a value, as `actual` carries it: the DS type name, `Null` for
    % `null`. A computed string is a `String`.
    %
:- func value_tag(ds_value) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.builtins.
:- import_module ds.core_math.
:- import_module ds.fact.
:- import_module ds.float_text.
:- import_module ds.format.
:- import_module ds.i64.
:- import_module ds.json.
:- import_module ds.json_text.
:- import_module ds.re2.
:- import_module array.
:- import_module bitmap.
:- import_module bool.
:- import_module char.
:- import_module float.
:- import_module int.
:- import_module int32.
:- import_module int64.
:- import_module integer.
:- import_module math.
:- import_module string.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%

eval(E, Ctx, Outcome) :-
    ev(E, Ctx, Outcome, [], _).

eval_noting_expiry(E, Ctx, Outcome, Expired) :-
    ev(E, Ctx, Outcome, [], Rev),
    Expired = list.reverse(Rev).

eval_all(Es, Ctx, Outcome) :-
    ev_all(Es, Ctx, Outcome, [], _).

    % `Key` joins the expired keys read so far, which are held newest first,
    % unless it is there already.
    %
:- pred noted(string::in, list(string)::in, list(string)::out) is det.

noted(Key, !Reads) :-
    ( if list.member(Key, !.Reads) then
        true
    else
        !:Reads = [Key | !.Reads]
    ).

    % The one classification point. A type mismatch is raised unclassified, and the
    % node that raised it classifies it from its own taint; a builtin inherits the
    % call's.
    %
    % `!Reads` carries the expired cache keys read, newest first.
    %
:- pred ev(expr::in, eval_ctx::in, eval_outcome::out,
           list(string)::in, list(string)::out) is det.

ev(E, Ctx, Outcome, !Reads) :-
    ( if E = e_tainted(Inner) then
        Tainted = yes,
        Node = Inner
    else
        Tainted = no,
        Node = E
    ),
    % A connective's own mismatch is ranked against its operands' faults
    % [LNUL.4.2], so it is classified before anything returns.
    ( if Node = e_binop(Op, L, R), connective(Op, Decider) then
        lnul_4_2_absorbing(Tainted, Decider, L, R, Ctx, Outcome, !Reads)
    else
        ev_node(Node, Ctx, Raw, !Reads),
        Outcome = classified(Tainted, Raw)
    ).

    % The two absorbing connectives, and the value that decides each: `false`
    % for `and`, `true` for `or`.
    %
:- pred connective(binop::in, bool::out) is semidet.

connective(op_and, no).
connective(op_or, yes).

:- func classified(bool, eval_outcome) = eval_outcome.

classified(Tainted, Raw) = Outcome :-
    ( if Raw = ev_fault(rf_type_mismatch) then
        (
            Tainted = yes,
            Outcome = ev_fault(rf_type_error)
        ;
            Tainted = no,
            Outcome = ev_fault(rf_artefact_lied)
        )
    else
        Outcome = Raw
    ).

:- pred ev_node(expr::in, eval_ctx::in, eval_outcome::out,
                list(string)::in, list(string)::out) is det.

ev_node(e_tainted(Inner), Ctx, Outcome, !Reads) :-
    ev(e_tainted(Inner), Ctx, Outcome, !Reads).

ev_node(e_lit(V), _, ev_ok(V), !Reads).

ev_node(e_slot(FactIx, Read), Ctx, Outcome, !Reads) :-
    ( if
        fact_at(Ctx, FactIx, Fact)
    then
        (
            Read = whole_fact,
            Outcome = ev_ok(fact_ref(Fact ^ f_id))
        ;
            Read = slot(Ix),
            Outcome = slot_value(Ctx, Fact, slot_index_int(Ix))
        )
    else
        % A token position the match never bound.
        Outcome = ev_fault(rf_pattern_index)
    ).

ev_node(e_entry_stamp(FactIx), Ctx, Outcome, !Reads) :-
    % [LTIM.2.8.6].
    ( if fact_at(Ctx, FactIx, Fact) then
        Outcome = ev_ok(int(int64.cast_from_uint64(
            instant_ns(Fact ^ f_asserted))))
    else
        Outcome = ev_fault(rf_pattern_index)
    ).

ev_node(e_slot_named(FactIx, Name), Ctx, Outcome, !Reads) :-
    % By name, against the schema of the fact actually present.
    ( if
        fact_at(Ctx, FactIx, Fact),
        map.search(Ctx ^ ec_schemas, schema_id_value(Fact ^ f_schema), Schema),
        slot_by_name(Schema, Name, Slot)
    then
        Outcome = slot_value(Ctx, Fact, slot_index_int(Slot ^ sc_index))
    else
        Outcome = ev_fault(rf_artefact_lied)
    ).

    % Never emitted, and refused at load by `ds.dsc`: every `a.b.c` lowers to a
    % `json_path` builtin call.
ev_node(e_json_path(_FactIx, _Path), _Ctx, ev_fault(rf_unimplemented),
        !Reads).

ev_node(e_json_path_expr(ValExpr, PathExpr), Ctx, Outcome, !Reads) :-
    % [LNUL.4.10].
    ev(ValExpr, Ctx, ValOut, !Reads),
    ev(PathExpr, Ctx, PathOut, !Reads),
    (
        ValOut = ev_fault(F),
        Outcome = ev_fault(lnul_4_10_yielded(Ctx, ValExpr, F, PathExpr, PathOut))
    ;
        ValOut = ev_ok(Val),
        (
            PathOut = ev_fault(F2),
            Outcome = ev_fault(F2)
        ;
            PathOut = ev_ok(PathVal),
            Outcome = json_walk(Ctx, Val, PathVal)
        )
    ).

ev_node(e_binop(Op, L, R), Ctx, Outcome, !Reads) :-
    ( if connective(Op, Decider) then
        % `ev` takes every `and` / `or` first, so no taint is left here.
        lnul_4_2_absorbing(no, Decider, L, R, Ctx, Outcome, !Reads)
    else
        % [LNUL.4.10]: both operands are evaluated, and a fault yields what
        % `lnul_4_2_yielded` selects; a `null` beside it absorbs nothing.
        ev(L, Ctx, LOut, !Reads),
        ev(R, Ctx, ROut, !Reads),
        (
            LOut = ev_fault(LF),
            Outcome = ev_fault(lnul_4_10_yielded(Ctx, L, LF, R, ROut))
        ;
            LOut = ev_ok(LV),
            (
                ROut = ev_fault(RF),
                Outcome = ev_fault(RF)
            ;
                ROut = ev_ok(RV),
                apply_binop(Ctx, Op, LV, RV, Outcome)
            )
        )
    ).

ev_node(e_unop(Op, Operand), Ctx, Outcome, !Reads) :-
    ev(Operand, Ctx, OperandOut, !Reads),
    (
        OperandOut = ev_fault(F),
        Outcome = ev_fault(F)
    ;
        OperandOut = ev_ok(V),
        Outcome = apply_unop(Op, V)
    ).

ev_node(e_interp(Prims), Ctx, Outcome, !Reads) :-
    % A `let` binding an interpolation reaches here; an action, under a pump's
    % sample, finds no expired entry to note.
    eval_text(e_interp(Prims), Ctx, Text),
    Outcome = text_value(Text).

    % No artefact carries one, and `ds.dsc` refuses it at load: a series read
    % arrives as `e_call(fn_series_*)`.
ev_node(e_agg(_), _, ev_fault(rf_unimplemented), !Reads).

    % A null argument, for every builtin here: a conversion whose source is `null`
    % answers `null` [LCST.4.3.4] (`null_converts`); any other builtin raising a
    % mismatch with a `null` among its arguments raises a TypeError, whatever the
    % call's taint [LNUL.5.1]. So builtins raise a plain mismatch on a `null`.
    %
    %@spec [IRET.9.6]
    %@spec [LCST.4.3.4]
ev_node(e_call(Fn, Args), Ctx, Outcome, !Reads) :-
    ( if Fn = fn_interval_check then
        rlow_6_1_7_interval_check(Args, Ctx, Outcome, !Reads)
    else
        ev_all(Args, Ctx, ArgsOut, !Reads),
        (
            ArgsOut = evs_fault(F),
            Outcome = ev_fault(F)
        ;
            ArgsOut = evs_ok(Values),
            Shape = rdsc_4a_9_3_shape(Fn, Values),
            (
                Shape = rdsc_not_admitted,
                Outcome = ev_fault(rf_artefact_lied)
            ;
                Shape = rdsc_admitted,
                ev_call(Fn, Values, Ctx, Outcome, !Reads)
            )
        )
    ).

    % `FN_INTERVAL_CHECK(s1, e1, v)`, or `(s1, e1, s2, e2, v)`, where `v` is the
    % operation's lowered value. Every argument is evaluated [LNUL.4.10], and each
    % pair of non-null endpoints that are not `s <= e` adds a `DOMAIN`. The call
    % yields the one fault [LNUL.4.2] selects, or `v`. Not through `ev_all`, which
    % yields an argument's fault before a pair's can join it.
    %
    % A NaN endpoint compares false, so it is invalid; endpoints of two kinds mean
    % the artefact lied [LINT.2.2]. Another count than [RDSC.4a.9.5] admits is
    % raised after the operands' own faults [RDSC.4a.9.3].
    %
    %@spec [RLOW.6.1.7]
    %@spec [LINT.7.2]
:- pred rlow_6_1_7_interval_check(list(expr)::in, eval_ctx::in,
    eval_outcome::out, list(string)::in, list(string)::out) is det.

rlow_6_1_7_interval_check(Args, Ctx, Outcome, !Reads) :-
    list.map_foldl(
        ( pred(E::in, O::out, R0::in, R::out) is det :- ev(E, Ctx, O, R0, R) ),
        Args, Outs, !Reads),
    Evaluated = rlow_6_1_7_evaluated(Args, Outs),
    ( if
        rdsc_4a_9_5_admits(fn_interval_check, list.length(Args)),
        rlow_6_1_7_candidates(Ctx, Evaluated, Candidates, Last)
    then
        (
            Candidates = [C | Cs],
            Outcome = ev_fault(located_fault(rlow_6_1_7_selected(Ctx, C, Cs)))
        ;
            Candidates = [],
            Outcome = Last
        )
    else
        ArgFaults = rlow_6_1_7_arg_faults(Ctx, Evaluated),
        (
            ArgFaults = [C | Cs],
            Outcome = ev_fault(located_fault(rlow_6_1_7_selected(Ctx, C, Cs)))
        ;
            ArgFaults = [],
            Outcome = ev_fault(rf_artefact_lied)
        )
    ).

    % [RLOW.6.1.7]: the origin of the fault a check yields: the selected candidate's
    % among those raising it, or with none, the check's own site.
    %
:- func rlow_6_1_7_origin(expr, list(expr), eval_ctx, runtime_fault)
    = fault_origin.

rlow_6_1_7_origin(Site, Args, Ctx, Fault) = Origin :-
    Evaluated = rlow_6_1_7_evaluated(Args,
        list.map(( func(E) = O :- eval(E, Ctx, O) ), Args)),
    ( if
        rdsc_4a_9_5_admits(fn_interval_check, list.length(Args)),
        rlow_6_1_7_candidates(Ctx, Evaluated, Candidates0, _)
    then
        Candidates = Candidates0
    else
        Candidates = rlow_6_1_7_arg_faults(Ctx, Evaluated)
    ),
    Raising = list.filter(( pred(L::in) is semidet :- L = located(Fault, _) ),
        Candidates),
    (
        Raising = [],
        Origin = site_origin(Site, Ctx)
    ;
        Raising = [R | Rs],
        located(_, Origin) = rlow_6_1_7_selected(Ctx, R, Rs)
    ).

:- func rlow_6_1_7_evaluated(list(expr), list(eval_outcome))
    = list({expr, eval_outcome}).

rlow_6_1_7_evaluated([], _) = [].
rlow_6_1_7_evaluated([_ | _], []) = [].
rlow_6_1_7_evaluated([E | Es], [O | Os]) =
    [{E, O} | rlow_6_1_7_evaluated(Es, Os)].

    % Every candidate fault of a check with three or five operands, the
    % arguments' and then the pairs', and the value `v` gave. Fails on any
    % other count.
    %
:- pred rlow_6_1_7_candidates(eval_ctx::in, list({expr, eval_outcome})::in,
    list(located)::out, eval_outcome::out) is semidet.

rlow_6_1_7_candidates(Ctx, Evaluated, Candidates, Last) :-
    list.split_last(Evaluated, Endpoints, {_, Last}),
    rlow_6_1_7_pairs(Endpoints, Pairs),
    Candidates = rlow_6_1_7_arg_faults(Ctx, Evaluated)
        ++ list.filter_map(rlow_6_1_7_pair_candidate(Ctx), Pairs).

:- func rlow_6_1_7_arg_faults(eval_ctx, list({expr, eval_outcome}))
    = list(located).

rlow_6_1_7_arg_faults(Ctx, Evaluated) =
    list.filter_map(rlow_6_1_7_arg_fault(Ctx), Evaluated).

:- func rlow_6_1_7_arg_fault(eval_ctx, {expr, eval_outcome}) = located
    is semidet.

rlow_6_1_7_arg_fault(Ctx, {E, ev_fault(F)}) =
    located(F, fault_origin(E, Ctx, F)).

    % The fault a pair adds, if any, at the pair's start [LERR.9.12].
    %
:- func rlow_6_1_7_pair_candidate(eval_ctx,
    {{expr, eval_outcome}, {expr, eval_outcome}}) = located is semidet.

rlow_6_1_7_pair_candidate(Ctx, {{Start, SO}, {_, EO}}) =
    located(rlow_6_1_7_pair_fault(Ctx, {SO, EO}), operand_origin(Start, Ctx)).

:- func rlow_6_1_7_selected(eval_ctx, located, list(located)) = located.

rlow_6_1_7_selected(Ctx, C, Cs) =
    list.foldl(( func(L, Acc) = lnul_4_2_yielded(Ctx, Acc, L) ), Cs, C).

    % One pair or two; fails on any other count.
    %
:- pred rlow_6_1_7_pairs(list(T)::in, list({T, T})::out) is semidet.

rlow_6_1_7_pairs(Endpoints, Pairs) :-
    ( if Endpoints = [S, E] then
        Pairs = [{S, E}]
    else
        Endpoints = [S1, E1, S2, E2],
        Pairs = [{S1, E1}, {S2, E2}]
    ).

    % A pair with a faulted endpoint adds nothing; one with a `null` endpoint is
    % valid [LINT.7.2].
    %
:- func rlow_6_1_7_pair_fault(eval_ctx, {eval_outcome, eval_outcome})
    = runtime_fault is semidet.

rlow_6_1_7_pair_fault(Ctx, {ev_ok(S), ev_ok(E)}) = Fault :-
    S \= null,
    E \= null,
    compare_outcome(content_of(Ctx, S), content_of(Ctx, E), le, Compared),
    ( if Compared = ev_ok(bool(yes)) then
        fail
    else if Compared = ev_ok(_) then
        Fault = rf_domain
    else
        Fault = rf_artefact_lied
    ).

    % A call whose operands `rdsc_4a_9_3_shape` has counted.
    %
:- pred ev_call(builtin_fn::in, list(ds_value)::in, eval_ctx::in,
                eval_outcome::out, list(string)::in, list(string)::out) is det.

ev_call(Fn, Values, Ctx, Outcome, !Reads) :-
    (
        % `apply_builtin` answers the miss of an expired entry; this notes it.
        ( if
            Fn = fn_cache_get,
            Values = [KeyVal],
            string_of(Ctx, KeyVal, Key),
            cache_expired(Ctx ^ ec_cache, Ctx ^ ec_now, Key)
        then
            noted(Key, !Reads)
        else
            true
        ),
        ( if null_converts(Fn), Values = [null | _] then
            Outcome = ev_ok(null)
        else
            apply_builtin(Fn, Values, Ctx, Raw),
            ( if
                Raw = ev_fault(rf_type_mismatch),
                list.member(null, Values)
            then
                Outcome = ev_fault(rf_type_error)
            else
                Outcome = Raw
            )
        )
    ).

    % A builtin call's operands, counted by [RDSC.4a.9.5]'s rows, after the operands
    % are evaluated and before anything reads them. A `rdsc_none` row is not judged:
    % the loader refuses those ops. The rate gate, an action's verbs and the
    % interval check count at their own sites.
    %
:- type rdsc_4a_9_3_shape
    --->    rdsc_admitted
    ;       rdsc_not_admitted.

    %@spec [RDSC.4a.9.3]
:- func rdsc_4a_9_3_shape(builtin_fn, list(ds_value)) = rdsc_4a_9_3_shape.

rdsc_4a_9_3_shape(Fn, Values) = Shape :-
    ( if
        ( rdsc_4a_9_5_operands(Fn) = rdsc_none
        ; rdsc_4a_9_5_admits(Fn, list.length(Values))
        )
    then
        Shape = rdsc_admitted
    else
        Shape = rdsc_not_admitted
    ).

    % The conversions `::` compiles to [LCST.4.5.2], whose `null` source converts to
    % `null` [LCST.4.3.4].
    %
:- pred null_converts(builtin_fn::in) is semidet.

null_converts(fn_float_to_int).
null_converts(fn_float_to_string).
null_converts(fn_int_to_string).
null_converts(fn_bool_to_string).
null_converts(fn_string_to_float).
null_converts(fn_string_to_int).
null_converts(fn_string_to_bool).
null_converts(fn_int_to_float).

ev_node(e_now, Ctx, Outcome, !Reads) :-
    % The wall clock's held sample [LTIM.2.8.3], as a `time` at offset 0; with no
    % value, a DOMAIN fault [LERR.1.4.10].
    (
        Ctx ^ ec_wall = yes(Utc),
        Outcome = ev_ok(time(ds_time(Utc, 0i64)))
    ;
        Ctx ^ ec_wall = no,
        Outcome = ev_fault(rf_domain)
    ).

ev_node(e_if(Cond, Then, Else), Ctx, Outcome, !Reads) :-
    ev(Cond, Ctx, CondOut, !Reads),
    (
        CondOut = ev_fault(F),
        Outcome = ev_fault(F)
    ;
        CondOut = ev_ok(CondV),
        ( if CondV = bool(yes) then
            ev(Then, Ctx, Outcome, !Reads)
        else if CondV = bool(no) then
            ev(Else, Ctx, Outcome, !Reads)
        else
            % Any condition that is not a Bool, `null` included.
            Outcome = ev_fault(rf_type_mismatch)
        )
    ).

ev_node(e_coalesce(Left, Right), Ctx, Outcome, !Reads) :-
    ev(Left, Ctx, LeftOut, !Reads),
    (
        LeftOut = ev_fault(F),
        Outcome = ev_fault(F)
    ;
        LeftOut = ev_ok(LV),
        ( if LV = null then
            % [LNUL.5.3]: lazy, and it rescues only absence, not a fault.
            ev(Right, Ctx, Outcome, !Reads)
        else
            Outcome = ev_ok(LV)
        )
    ).

ev_node(e_is_test(Operand, Subject, Negated), Ctx, Outcome, !Reads) :-
    % [LNUL.4.9]: total over `ds_value`; a fault in the operand still propagates.
    ev(Operand, Ctx, OperandOut, !Reads),
    (
        OperandOut = ev_fault(F),
        Outcome = ev_fault(F)
    ;
        OperandOut = ev_ok(V),
        Hit = is_hit(V, Subject),
        (
            Negated = yes,
            Outcome = ev_ok(bool(not Hit))
        ;
            Negated = no,
            Outcome = ev_ok(bool(Hit))
        )
    ).

ev_node(e_bind(Ix, Bound), Ctx, Outcome, !Reads) :-
    % The frame update is the executor's. A slot outside the frame names
    % nothing [RDSC.4a.9.6].
    ( if bind_index_int(Ix) >= Ctx ^ ec_frame then
        Outcome = ev_fault(rf_artefact_lied)
    else
        ev(Bound, Ctx, Outcome, !Reads)
    ).

    % [LNUL.4.9]'s truth table. A constant subject tests tag and value; a tag name
    % tests the tag alone.
    %
:- func is_hit(ds_value, is_subject) = bool.

is_hit(V, is_null)    = ( if V = null       then yes else no ).
is_hit(V, is_true)    = ( if V = bool(yes)  then yes else no ).
is_hit(V, is_false)   = ( if V = bool(no)   then yes else no ).
is_hit(V, is_bool)    = ( if V = bool(_)    then yes else no ).
is_hit(V, is_float)   = ( if V = float(_)   then yes else no ).
is_hit(V, is_string)  = ( if ( V = str(_) ; V = text(_) ) then yes else no ).
is_hit(V, is_bytes)   = ( if V = bytes(_)   then yes else no ).
is_hit(V, is_json)    = ( if V = json(_)    then yes else no ).
is_hit(V, is_inf)     =
    ( if V = float(F), float.is_nan_or_inf(F), not float.is_nan(F), F > 0.0
      then yes else no ).
is_hit(V, is_neg_inf) =
    ( if V = float(F), float.is_nan_or_inf(F), not float.is_nan(F), F < 0.0
      then yes else no ).
is_hit(V, is_nan)     = ( if V = float(F), float.is_nan(F) then yes else no ).

    % A tag names a representation, not a declared type [LNUL.4.9].
is_hit(V, is_int)     =
    ( if ( V = int(_) ; V = duration(_) ; V = time(_) ) then yes else no ).

ev_node(e_bind_ref(Ix), Ctx, Outcome, !Reads) :-
    N = bind_index_int(Ix),
    ( if N >= Ctx ^ ec_frame then
        % A slot outside the frame names nothing [RDSC.4a.9.6].
        Outcome = ev_fault(rf_artefact_lied)
    else if map.search(Ctx ^ ec_binds, N, Found) then
        Outcome = ev_ok(Found)
    else
        % Read before the binding action ran [RARC.5.6.11].
        Outcome = ev_fault(rf_binding_order)
    ).

%-----------------------------------------------------------------------------%

    % [LNUL.4.10]: every argument is evaluated, and a fault yields what
    % `lnul_4_2_yielded` selects among them.
    %
:- pred ev_all(list(expr)::in, eval_ctx::in, eval_list_outcome::out,
               list(string)::in, list(string)::out) is det.

ev_all([], _, evs_ok([]), !Reads).
ev_all([E | Es], Ctx, Outcome, !Reads) :-
    ev(E, Ctx, One, !Reads),
    ev_all(Es, Ctx, Rest, !Reads),
    (
        One = ev_fault(F),
        (
            Rest = evs_fault(F2),
            Outcome = evs_fault(located_fault(lnul_4_2_yielded(Ctx,
                located(F, fault_origin(E, Ctx, F)),
                located(F2, least_origin(Ctx, F2, Es)))))
        ;
            Rest = evs_ok(_),
            Outcome = evs_fault(F)
        )
    ;
        One = ev_ok(V),
        (
            Rest = evs_fault(F2),
            Outcome = evs_fault(F2)
        ;
            Rest = evs_ok(Vs),
            Outcome = evs_ok([V | Vs])
        )
    ).

    % The fault an operator yields when its operand `LE` faulted with `F`: `F`, or
    % when `RE` faulted too, the one `lnul_4_2_yielded` selects.
    %
    %@spec [LNUL.4.10]
:- func lnul_4_10_yielded(eval_ctx, expr, runtime_fault, expr, eval_outcome)
    = runtime_fault.

lnul_4_10_yielded(_, _, F, _, ev_ok(_)) = F.
lnul_4_10_yielded(Ctx, LE, F, RE, ev_fault(G)) =
    located_fault(lnul_4_2_yielded(Ctx,
        located(F, fault_origin(LE, Ctx, F)),
        located(G, fault_origin(RE, Ctx, G)))).

:- func located_fault(located) = runtime_fault.

located_fault(located(F, _)) = F.

admits(ev_ok(bool(yes))).

blocks(ev_ok(bool(yes))).
blocks(ev_ok(null)).

:- func negate(bool) = bool.

negate(yes) = no.
negate(no) = yes.

%-----------------------------------------------------------------------------%
% Kleene connectives
%-----------------------------------------------------------------------------%
%
% `and` = min and `or` = max over false < null < true [LNUL.4.2], and absorbing:
% the deciding value decides wherever it stands, whatever the other operand
% raises; a fault only if no operand decides; `null` only if none decides and
% none faults [IRET.9.5]. An absorbed `EngineError` halts nothing [IRET.9.6]. Of
% two faults only the one `lnul_4_2_yielded` selects is recorded [LERR.1.4.11].

    % `Tainted` is the connective node's own taint; `Decider` the value that
    % decides, `no` for `and` and `yes` for `or`. A deciding left operand leaves the
    % right unevaluated.
    %
    %@spec [LNUL.4.2]
    %@spec [IRET.9.5]
:- pred lnul_4_2_absorbing(bool::in, bool::in, expr::in, expr::in,
                           eval_ctx::in, eval_outcome::out,
                           list(string)::in, list(string)::out) is det.

lnul_4_2_absorbing(Tainted, Decider, L, R, Ctx, Outcome, !Reads) :-
    ev(L, Ctx, LOut, !Reads),
    ( if LOut = ev_ok(bool(Decider)) then
        Outcome = LOut
    else
        ev(R, Ctx, ROut, !Reads),
        ( if ROut = ev_ok(bool(Decider)) then
            Outcome = ROut
        else if operand_fault(Tainted, LOut, LF) then
            ( if operand_fault(Tainted, ROut, RF) then
                Outcome = ev_fault(located_fault(lnul_4_2_yielded(Ctx,
                    located(LF, connective_origin(Ctx, Decider, L, R, L, LOut, LF)),
                    located(RF, connective_origin(Ctx, Decider, L, R, R, ROut, RF)))))
            else
                Outcome = ev_fault(LF)
            )
        else if operand_fault(Tainted, ROut, RF) then
            Outcome = ev_fault(RF)
        else if ( LOut = ev_ok(null) ; ROut = ev_ok(null) ) then
            Outcome = ev_ok(null)
        else
            Outcome = ev_ok(bool(negate(Decider)))
        )
    ).

    % One its evaluation met, or the connective's own mismatch for a value that is
    % neither a Bool nor `null`.
    %
:- pred operand_fault(bool::in, eval_outcome::in, runtime_fault::out)
    is semidet.

operand_fault(_, ev_fault(F), F).
operand_fault(Tainted, ev_ok(V), F) :-
    not boolean_or_null(V),
    F = mismatch_of(Tainted).

    % Where its evaluation raised it, or for the connective's own mismatch, the
    % connective's site.
    %
:- func connective_origin(eval_ctx, bool, expr, expr, expr, eval_outcome,
    runtime_fault) = fault_origin.

connective_origin(Ctx, Decider, L, R, Operand, Out, F) = Origin :-
    (
        Out = ev_fault(_),
        Origin = fault_origin(Operand, Ctx, F)
    ;
        Out = ev_ok(_),
        Origin = site_origin(e_binop(connective_op(Decider), L, R), Ctx)
    ).

:- func connective_op(bool) = binop.

connective_op(no) = op_and.
connective_op(yes) = op_or.

:- func mismatch_of(bool) = runtime_fault.

mismatch_of(yes) = rf_type_error.
mismatch_of(no) = rf_artefact_lied.

test_fault(_, ev_fault(F), F).
test_fault(Test, ev_ok(V), F) :-
    not boolean_or_null(V),
    F = mismatch_of(( if Test = e_tainted(_) then yes else no )).

:- pred boolean_or_null(ds_value::in) is semidet.

boolean_or_null(bool(_)).
boolean_or_null(null).

%-----------------------------------------------------------------------------%
% Arithmetic and comparison
%-----------------------------------------------------------------------------%

:- pred apply_binop(eval_ctx::in, binop::in, ds_value::in, ds_value::in,
                    eval_outcome::out) is det.

apply_binop(Ctx, Op, L0, R0, Outcome) :-
    L = content_of(Ctx, L0),
    R = content_of(Ctx, R0),
    ( if ( L = null ; R = null ) then
        % [LNUL.4.1]: arithmetic and comparison alike.
        Outcome = ev_ok(null)
    else
        arith(Op, L, R, Outcome)
    ).

:- pred arith(binop::in, ds_value::in, ds_value::in, eval_outcome::out) is det.

arith(op_add, L, R, Out) :-
    ( if ltim_4_1_time_plus(L, R, TimeOut) then
        Out = TimeOut
    else
        numeric(L, R, plus_i, plus_f, Out)
    ).
arith(op_sub, L, R, Out) :-
    ( if ltim_4_1_time_minus(L, R, TimeOut) then
        Out = TimeOut
    else
        numeric(L, R, minus_i, minus_f, Out)
    ).
arith(op_mul, L, R, Out) :- numeric(L, R, times_i, times_f, Out).

arith(op_div, L, R, Out) :-
    % Always Float [LEXP.7.4]. Only an all-`Int` division by zero traps
    % [LEXP.7.15.1]; a `Float` operand makes it IEEE 754's [LDET.3.6.2], and
    % Mercury's float `/` would throw on a zero divisor.
    ( if L = int(_), R = int(0i64) then
        Out = ev_fault(rf_div_zero)
    else if numbers(L, R, LF, RF) then
        Out = ev_ok(float(float.unchecked_quotient(LF, RF)))
    else
        Out = ev_fault(rf_type_mismatch)
    ).

arith(op_floordiv, L, R, Out) :-
    % `div` floors [LEXP.7.5]; Mercury's `//` truncates. (min_int64, -1) would trap
    % in C's `/`, and wraps [LEXP.7.13.1].
    ( if L = int(A), R = int(B) then
        ( if B = 0i64 then Out = ev_fault(rf_div_zero)
        else if A = int64.min_int64, B = -1i64 then
            Out = ev_ok(int(int64.min_int64))
        else Out = ev_ok(int(A div B)) )
    else if numbers(L, R, LF, RF) then
        Out = ev_ok(float(lexp_7_5_float_floordiv(LF, RF)))
    else
        Out = ev_fault(rf_type_mismatch)
    ).

arith(op_rem, L, R, Out) :-
    % (min_int64, -1) would trap in C's `%`.
    ( if L = int(A), R = int(B) then
        ( if B = 0i64 then Out = ev_fault(rf_mod_zero)
        else if A = int64.min_int64, B = -1i64 then Out = ev_ok(int(0i64))
        else Out = ev_ok(int(A mod B)) )
    else if numbers(L, R, LF, RF) then
        Out = ev_ok(float(lexp_7_6_float_mod(LF, RF)))
    else
        Out = ev_fault(rf_type_mismatch)
    ).

%-----------------------------------------------------------------------------%
% Float `//` and `%` [LEXP.7.5], [LEXP.7.6]
%-----------------------------------------------------------------------------%

    % `%` with a `Float` operand: the exact truncated remainder, moved to the
    % divisor's sign [LDET.3.3a.4]. A zero divisor is NaN [LEXP.7.15.1], made as
    % `inf - inf` since Mercury offers no constant.
    %
    %@spec [LEXP.7.6]
:- func lexp_7_6_float_mod(float, float) = float.

lexp_7_6_float_mod(A, B) = Mod :-
    ( if B = 0.0 then
        Mod = float.infinity - float.infinity
    else
        float_divmod(A, B, Mod, _)
    ).

    % `//` with a `Float` operand, derived from the remainder and never `floor(a /
    % b)`, which rounds first: `0.3 // 0.1` is 2.0. A zero divisor is IEEE division's
    % answer [LEXP.7.15.1].
    %
    %@spec [LEXP.7.5]
:- func lexp_7_5_float_floordiv(float, float) = float.

lexp_7_5_float_floordiv(A, B) = Div :-
    ( if B = 0.0 then
        Div = float.unchecked_quotient(A, B)
    else
        float_divmod(A, B, _, Div)
    ).

    % CPython's `_float_div_mod`, for a non-zero divisor. A NaN takes the `\= 0` arms.
    %
:- pred float_divmod(float::in, float::in, float::out, float::out) is det.

float_divmod(A, B, Mod, FloorDiv) :-
    Raw = exact_fmod(A, B),
    Div0 = float.unchecked_quotient(A - Raw, B),
    ( if Raw \= 0.0 then
        ( if is_negative(B) \= is_negative(Raw) then
            Mod = Raw + B,
            Div = Div0 - 1.0
        else
            Mod = Raw,
            Div = Div0
        )
    else
        Mod = signed_zero(B),
        Div = Div0
    ),
    ( if Div \= 0.0 then
        Floor = math.floor(Div),
        FloorDiv = ( if Div - Floor > 0.5 then Floor + 1.0 else Floor )
    else
        FloorDiv = signed_zero(float.unchecked_quotient(A, B))
    ).

:- func is_negative(float) = bool.

is_negative(X) = ( if X < 0.0 then yes else no ).

    % copysign(0.0, X).
    %
:- func signed_zero(float) = float.

signed_zero(X) =
    ( if sign_bit(X) then float.unchecked_quotient(-1.0, float.infinity)
    else 0.0 ).

:- pred sign_bit(float::in) is semidet.

sign_bit(X) :-
    integer.from_string(float.float64_bits_string(X), Signed),
    Signed < integer.zero.

    % C's `fmod`, over the operands' exact integer mantissas, with its special
    % operands. Not a foreign call: the promise ledger does not admit one here.
    %
:- func exact_fmod(float, float) = float.

exact_fmod(A, B) = R :-
    ( if
        ( float.is_nan(A) ; float.is_nan(B) ; float.is_infinite(A) )
    then
        R = float.infinity - float.infinity
    else if float.is_infinite(B) then
        R = A
    else if A = 0.0 then
        R = A
    else
        mantissa_exponent(float.abs(A), MA, EA),
        mantissa_exponent(float.abs(B), MB, EB),
        E = int.min(EA, EB),
        IA = MA << (EA - E),
        IB = MB << (EB - E),
        IR = IA rem IB,
        % IR < 2^53, so `integer.float` is exact, and the scaled result is
        % representable.
        Magnitude = scale2(integer.float(IR), E),
        R = ( if A < 0.0 then -Magnitude else Magnitude )
    ).

    % A finite, positive double as `M * 2^E` with an integer M below 2^53.
    %
:- pred mantissa_exponent(float::in, integer::out, int::out) is det.

mantissa_exponent(F, M, E) :-
    Bits = integer.det_from_string(float.float64_bits_string(F)),
    Field = integer.det_to_int((Bits >> 52) /\ integer.integer(0x7ff)),
    Fraction = Bits /\ ((integer.one << 52) - integer.one),
    ( if Field = 0 then
        M = Fraction,
        E = -1074
    else
        M = (integer.one << 52) + Fraction,
        E = Field - 1075
    ).

    % X * 2^E, exactly, for a result that is representable. Below 2^-1022 the
    % power itself is subnormal and `float.pow` cannot make it, so the scale is
    % taken in two steps, the first of which keeps X normal.
    %
:- func scale2(float, int) = float.

scale2(X, E) =
    ( if E >= -1022 then
        X * float.pow(2.0, E)
    else
        (X * float.pow(2.0, E + 600)) * float.pow(2.0, -600)
    ).

arith(op_eq, L, R, Out) :- compare_outcome(L, R, eq, Out).
arith(op_ne, L, R, Out) :- compare_outcome(L, R, ne, Out).
arith(op_lt, L, R, Out) :- compare_outcome(L, R, lt, Out).
arith(op_le, L, R, Out) :- compare_outcome(L, R, le, Out).
arith(op_gt, L, R, Out) :- compare_outcome(L, R, gt, Out).
arith(op_ge, L, R, Out) :- compare_outcome(L, R, ge, Out).

arith(op_and, _, _, ev_fault(rf_type_mismatch)).
arith(op_or, _, _, ev_fault(rf_type_mismatch)).

arith(op_bit_and, L, R, Out) :- bitwise(L, R, band, Out).
arith(op_bit_or, L, R, Out) :- bitwise(L, R, bor, Out).
arith(op_bit_xor, L, R, Out) :- bitwise(L, R, bxor, Out).
arith(op_shl, L, R, Out) :- bitwise(L, R, shl, Out).
arith(op_shr, L, R, Out) :- bitwise(L, R, shr, Out).

    % A comparison across kinds is a type mismatch: `"a" == 1` is not `false`.
    % Numbers order numerically, Strings by content, Bools false-before-true;
    % ordering any other kind is a type mismatch. Strings arrive here as `text`.
    %
:- pred compare_outcome(ds_value::in, ds_value::in, cmp::in,
                        eval_outcome::out) is det.

compare_outcome(L, R, Cmp, Out) :-
    ( if time_order(L, R, Order) then
        Out = ev_ok(bool(ordered(Cmp, Order)))
    else if as_float(L, _), as_float(R, _) then
        Out = ev_ok(compare_values(L, R, Cmp))
    else if value_family(L) \= value_family(R) then
        Out = ev_fault(rf_type_mismatch)
    else if ( L = text(_) ; L = bool(_) ; equality_only(Cmp) ) then
        % Equality on a kind with no order is structural: `Bytes` and `Json`
        % [LEXP.7.19], [LFAC.2.5.1], and fact references, by id [LEXP.7.20].
        Out = ev_ok(compare_values(L, R, Cmp))
    else
        Out = ev_fault(rf_type_mismatch)
    ).

    % A `Time` against a `Time`, an `Int` or a `Float`, on the instant [LTIM.5.2]:
    % two integral operands as exact int64; with a Float both as doubles, where a
    % NaN orders equal. The compiler gates a true cross-type comparison [LTIM.5.5].
    %
:- pred time_order(ds_value::in, ds_value::in, comparison_result::out)
    is semidet.

time_order(L, R, Order) :-
    ( L = time(_) ; R = time(_) ),
    ( if instant_int(L, IL), instant_int(R, IR) then
        compare(Order, IL, IR)
    else
        instant_float(L, FL),
        instant_float(R, FR),
        Order = ( if FL > FR then (>) else if FL < FR then (<) else (=) )
    ).

:- pred instant_int(ds_value::in, int64::out) is semidet.

instant_int(int(I), I).
instant_int(time(T), utc_ns(T)).

    % The offset, in seconds east, the zone takes at the instant `Utc`. Exactly
    % "UTC" is 0 with no fact consulted; any other zone resolves through working
    % memory's `TimeZoneOffset` facts, by interned ref. Fails when nothing answers.
    % `Name` is `Zone`'s text.
    %
    %@spec [LTIM.10.7]
    %@spec [LTIM.10.8]
:- pred ltim_10_7_resolve(eval_ctx::in, ds_value::in, string::in, int64::in,
                          int32::out) is semidet.

ltim_10_7_resolve(Ctx, Zone, Name, Utc, OffsetS) :-
    ( if Name = "UTC" then
        OffsetS = 0i32
    else
        ( if Zone = str(R) then
            Ref = R
        else
            interned(Ctx ^ ec_interns, Name, Ref)
        ),
        ltim_10_7_offset(Ctx ^ ec_wm, Ref, Utc, OffsetS)
    ).

    % `local(t, tz)` [LTIM.3.2]: `t`'s instant, with the offset `tz`'s facts give it
    % at that instant [LTIM.10.7], as nanoseconds [LTIM.3.2.2]. Every failure is a
    % fault, never UTC [LTIM.10.5.3]: no fact answering is `rf_domain` [LERR.1.4.10];
    % any other operand is a mismatch.
    %
:- func ltim_3_2_local(eval_ctx, ds_value, ds_value) = eval_outcome.

ltim_3_2_local(Ctx, V, Zone) = Outcome :-
    ( if instant_int(V, Utc), string_of(Ctx, Zone, Name) then
        ( if ltim_10_7_resolve(Ctx, Zone, Name, Utc, OffsetS) then
            Outcome = ev_ok(time(ds_time(Utc,
                int64.from_int(int32.to_int(OffsetS)) * 1000000000i64)))
        else
            Outcome = ev_fault(rf_domain)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % `t.date(tz)` [LTIM.3.3.1]: the calendar date `t`'s instant falls on in `tz`, as
    % days since 1970-01-01, with `ltim_3_2_local`'s failures.
    %
:- func ltim_3_3_date(eval_ctx, ds_value, ds_value) = eval_outcome.

ltim_3_3_date(Ctx, V, Zone) = Outcome :-
    ( if instant_int(V, Utc), string_of(Ctx, Zone, Name) then
        ( if ltim_10_7_resolve(Ctx, Zone, Name, Utc, OffsetS) then
            Day = ltim_3_3_local_day(Utc, OffsetS),
            % [LTIM.1.2.2]: a `Time` at a range's end can fall on a day outside.
            ( if ltim_1_2_2_date_in_range(Day) then
                Outcome = ev_ok(int(Day))
            else
                Outcome = ev_fault(rf_not_representable)
            )
        else
            Outcome = ev_fault(rf_domain)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % floor((Utc + OffsetS * 1e9) / day), without forming the sum, which overflows
    % int64 near the ends of the Time range.
    %
:- func ltim_3_3_local_day(int64, int32) = int64.

ltim_3_3_local_day(Utc, OffsetS) = (Utc div Day) + (Local div Day) :-
    Day = 86400000000000i64,
    Local = (Utc mod Day) + int64.from_int(int32.to_int(OffsetS)) * 1000000000i64.

    % [LTIM.6.5]: one component of the instant `V` in the zone `Zone`, an `Int` in
    % [LTIM.6.3]'s range, with `ltim_3_2_local`'s failures [LTIM.10.5.3].
    %
:- func ltim_6_5_component(eval_ctx, builtin_fn, ds_value, ds_value)
    = eval_outcome.

ltim_6_5_component(Ctx, Fn, V, Zone) = Outcome :-
    ( if instant_int(V, Utc), string_of(Ctx, Zone, Name) then
        ( if ltim_10_7_resolve(Ctx, Zone, Name, Utc, OffsetS) then
            Outcome = ev_ok(int(component_at(Fn, Utc, OffsetS)))
        else
            Outcome = ev_fault(rf_domain)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % The component of `Utc` at `OffsetS`, split as in `ltim_3_3_local_day`. Day 0
    % was a Thursday, so `0` = Monday [LTIM.6.4] is `(day + 3) mod 7`.
    %
:- func component_at(builtin_fn, int64, int32) = int64.

component_at(Fn, Utc, OffsetS) = C :-
    Day = 86400000000000i64,
    Local = (Utc mod Day) + int64.from_int(int32.to_int(OffsetS)) * 1000000000i64,
    Days = (Utc div Day) + (Local div Day),
    NsOfDay = Local mod Day,
    civil_from_days(Days, Y, Mo, D),
    ( if Fn = fn_hour then
        C = NsOfDay div 3600000000000i64
    else if Fn = fn_minute then
        C = (NsOfDay div 60000000000i64) mod 60i64
    else if Fn = fn_second then
        C = (NsOfDay div 1000000000i64) mod 60i64
    else if Fn = fn_day then
        C = D
    else if Fn = fn_month then
        C = Mo
    else if Fn = fn_year then
        C = Y
    else
        C = (Days + 3i64) mod 7i64
    ).

:- pred instant_float(ds_value::in, float::out) is semidet.

instant_float(int(I), i64.to_float(I)).
instant_float(float(F), F).
instant_float(time(T), i64.to_float(utc_ns(T))).

    % Which values can compare with each other.
    %
:- func value_family(ds_value) = int.

value_family(int(_)) = 0.
value_family(float(_)) = 0.
value_family(duration(_)) = 0.
value_family(time(_)) = 0.
value_family(str(_)) = 1.
value_family(text(_)) = 1.
value_family(bool(_)) = 2.
value_family(bytes(_)) = 3.
value_family(json(_)) = 4.
value_family(fact_ref(_)) = 5.
value_family(ratio(_, _)) = 6.
value_family(null) = 7.

    % A String operand as its content, so `str` and `text` compare alike.
    %
:- func content_of(eval_ctx, ds_value) = ds_value.

content_of(Ctx, V) =
    ( if V = str(Ref), expand(Ctx ^ ec_interns, Ref, S) then text(S) else V ).

%-----------------------------------------------------------------------------%

:- type num_op ---> plus_i ; minus_i ; times_i ; plus_f ; minus_f ; times_f.

    % Int OP Int is Int; any Float operand promotes the result [LEXP.7.2, 7.3].
    %
:- pred numeric(ds_value::in, ds_value::in, num_op::in, num_op::in,
                eval_outcome::out) is det.

numeric(L, R, IntOp, FloatOp, Out) :-
    ( if L = int(A), R = int(B) then
        Out = ev_ok(int(int_op(IntOp, A, B)))
    else if numbers(L, R, LF, RF) then
        Out = ev_ok(float(float_op(FloatOp, LF, RF)))
    else
        Out = ev_fault(rf_type_mismatch)
    ).

    % [LTIM.4.1]: `Time + Duration`, `Duration + Time` and `Time - Duration` are a
    % `Time` at the `Time` operand's offset [LTIM.4.1.1], and `Time - Time` the
    % `Duration` between them. Each is exact: a result past the representable range
    % raises NOT_REPRESENTABLE [LTIM.1.1.5]. A `Time - Time` below the Int range is
    % the most negative Int, which the compiler's `FN_MAX(_, 0)` saturates
    % [RLOW.6.1.6]. Fails when the operands are not one of these rows.
    %
:- pred ltim_4_1_time_plus(ds_value::in, ds_value::in, eval_outcome::out)
    is semidet.

ltim_4_1_time_plus(L, R, Out) :-
    ( if L = time(TL), duration_operand_ns(R, NR) then
        T = TL,
        Ns = NR
    else
        R = time(T),
        duration_operand_ns(L, Ns)
    ),
    ( if ltim_1_1_5_add(utc_ns(T), Ns, At) then
        Out = ev_ok(time(ds_time(At, tz_offset_ns(T))))
    else
        Out = ev_fault(rf_time_range)
    ).

:- pred ltim_4_1_time_minus(ds_value::in, ds_value::in, eval_outcome::out)
    is semidet.

ltim_4_1_time_minus(L, R, Out) :-
    L = time(TL),
    ( if R = time(TR) then
        ( if ltim_1_1_5_sub(utc_ns(TL), utc_ns(TR), D) then
            Out = ev_ok(int(D))
        else if utc_ns(TL) < utc_ns(TR) then
            Out = ev_ok(int(int64.min_int64))
        else
            Out = ev_fault(rf_time_range)
        )
    else
        duration_operand_ns(R, NR),
        ( if ltim_1_1_5_sub(utc_ns(TL), NR, At) then
            Out = ev_ok(time(ds_time(At, tz_offset_ns(TL))))
        else
            Out = ev_fault(rf_time_range)
        )
    ).

    % `A + B` and `A - B` where the exact result is an `Int64`. The bound is
    % tested before the operation, which therefore cannot wrap.
    %
    %@spec [LTIM.1.1.5]
:- pred ltim_1_1_5_add(int64::in, int64::in, int64::out) is semidet.

ltim_1_1_5_add(A, B, Sum) :-
    ( if B >= 0i64 then
        A =< int64.max_int64 - B
    else
        A >= int64.min_int64 - B
    ),
    Sum = A + B.

    %@spec [LTIM.1.1.5]
:- pred ltim_1_1_5_sub(int64::in, int64::in, int64::out) is semidet.

ltim_1_1_5_sub(A, B, Diff) :-
    ( if B >= 0i64 then
        A >= int64.min_int64 + B
    else
        A =< int64.max_int64 + B
    ),
    Diff = A - B.

:- func int_op(num_op, int64, int64) = int64.

int_op(plus_i, A, B) = A + B.
int_op(minus_i, A, B) = A - B.
int_op(times_i, A, B) = A * B.
int_op(plus_f, A, B) = A + B.
int_op(minus_f, A, B) = A - B.
int_op(times_f, A, B) = A * B.

:- func float_op(num_op, float, float) = float.

float_op(plus_i, A, B) = A + B.
float_op(minus_i, A, B) = A - B.
float_op(times_i, A, B) = A * B.
float_op(plus_f, A, B) = A + B.
float_op(minus_f, A, B) = A - B.
float_op(times_f, A, B) = A * B.

    % Both operands as floats, promoting an Int. Fails on anything else.
    %
:- pred numbers(ds_value::in, ds_value::in, float::out, float::out) is semidet.

numbers(L, R, LF, RF) :-
    as_float(L, LF),
    as_float(R, RF).

:- pred as_float(ds_value::in, float::out) is semidet.

as_float(int(I), i64.to_float(I)).
as_float(float(F), F).

:- type bit_op ---> band ; bor ; bxor ; shl ; shr.

:- pred bitwise(ds_value::in, ds_value::in, bit_op::in, eval_outcome::out)
    is det.

bitwise(L, R, Op, Out) :-
    ( if L = int(A), R = int(B) then
        ( if ( Op = shl ; Op = shr ), B < 0i64 then
            % [LEXP.7.14.1].
            Out = ev_fault(rf_domain)
        else
            Out = ev_ok(int(bit_result(Op, A, B)))
        )
    else
        Out = ev_fault(rf_type_mismatch)
    ).

    % [LEXP.7.14.1]: the count is never reduced modulo 64, and `>>` is arithmetic.
    %
:- func bit_result(bit_op, int64, int64) = int64.

bit_result(band, A, B) = A /\ B.
bit_result(bor, A, B) = A \/ B.
bit_result(bxor, A, B) = int64.xor(A, B).
bit_result(shl, A, B) =
    ( if B >= 64i64 then 0i64 else A << int64.cast_to_int(B) ).
bit_result(shr, A, B) =
    ( if B >= 64i64 then ( if A < 0i64 then -1i64 else 0i64 )
      else A >> int64.cast_to_int(B) ).

%-----------------------------------------------------------------------------%
% Comparison
%-----------------------------------------------------------------------------%

:- type cmp ---> eq ; ne ; lt ; le ; gt ; ge.

    % Two Ints compare exactly, before `as_float` could accept them [LDET.3.2.2]; a
    % mixed Int/Float pair numerically; Strings by code unit; anything else only for
    % equality. `compare_outcome` decides which pairs reach here.
    %
:- func compare_values(ds_value, ds_value, cmp) = ds_value.

compare_values(L, R, Cmp) = V :-
    ( if L = int(LI), R = int(RI) then
        compare(Order, LI, RI),
        V = bool(ordered(Cmp, Order))
    else if as_float(L, LF), as_float(R, RF) then
        V = bool(numeric_cmp(Cmp, LF, RF))
    else if L = text(LS), R = text(RS) then
        compare(Order, LS, RS),
        V = bool(ordered(Cmp, Order))
    else if L = bool(LB), R = bool(RB) then
        V = bool(ordered(Cmp, bool_order(LB, RB)))
    else
        ( if L = R then
            V = bool(same_sense(Cmp))
        else
            V = bool(negate(same_sense(Cmp)))
        )
    ).

:- func ordered(cmp, comparison_result) = bool.

ordered(eq, O) = ( if O = (=) then yes else no ).
ordered(ne, O) = ( if O = (=) then no else yes ).
ordered(lt, O) = ( if O = (<) then yes else no ).
ordered(le, O) = ( if O = (>) then no else yes ).
ordered(gt, O) = ( if O = (>) then yes else no ).
ordered(ge, O) = ( if O = (<) then no else yes ).

:- func bool_order(bool, bool) = comparison_result.

bool_order(no, no) = (=).
bool_order(no, yes) = (<).
bool_order(yes, no) = (>).
bool_order(yes, yes) = (=).

:- pred equality_only(cmp::in) is semidet.

equality_only(eq).
equality_only(ne).

:- func same_sense(cmp) = bool.

same_sense(eq) = yes.
same_sense(ne) = no.
same_sense(lt) = no.
same_sense(le) = no.
same_sense(gt) = no.
same_sense(ge) = no.

:- func numeric_cmp(cmp, float, float) = bool.

numeric_cmp(eq, A, B) = ( if A = B then yes else no ).
numeric_cmp(ne, A, B) = ( if A = B then no else yes ).
numeric_cmp(lt, A, B) = ( if A < B then yes else no ).
numeric_cmp(le, A, B) = ( if A =< B then yes else no ).
numeric_cmp(gt, A, B) = ( if A > B then yes else no ).
numeric_cmp(ge, A, B) = ( if A >= B then yes else no ).

%-----------------------------------------------------------------------------%
% Unary
%-----------------------------------------------------------------------------%

:- func apply_unop(unop, ds_value) = eval_outcome.

apply_unop(Op, V) = Outcome :-
    ( if V = null then
        % [LNUL.4.1].
        Outcome = ev_ok(null)
    else
        (
            Op = op_not,
            ( if V = bool(B) then
                Outcome = ev_ok(bool(negate(B)))
            else
                Outcome = ev_fault(rf_type_mismatch)
            )
        ;
            Op = op_neg,
            % `-1.0 *`: Mercury's unary `-` is `0.0 - X`, which makes 0.0 into
            % +0.0 [LDET.3.6.2].
            ( if V = int(I) then Outcome = ev_ok(int(-I))
            else if V = float(F) then Outcome = ev_ok(float((-1.0) * F))
            else Outcome = ev_fault(rf_type_mismatch) )
        ;
            Op = op_pos,
            ( if V = int(_) then Outcome = ev_ok(V)
            else if V = float(_) then Outcome = ev_ok(V)
            else Outcome = ev_fault(rf_type_mismatch) )
        ;
            Op = op_bitnot,
            ( if V = int(I) then Outcome = ev_ok(int(\ I))
            else Outcome = ev_fault(rf_type_mismatch) )
        )
    ).

%-----------------------------------------------------------------------------%
% Fault origin
%-----------------------------------------------------------------------------%

no_origin = fault_origin(no, no, no, no).

fault_origin(Expr, Ctx, Fault) = Origin :-
    ( if Expr = e_call(fn_interval_check, Args) then
        % A pair's `DOMAIN` is raised by no child.
        Origin = rlow_6_1_7_origin(Expr, Args, Ctx, Fault)
    else
        Raising = list.filter(raises(Ctx, Fault),
            evaluated_children(Expr, Ctx)),
        (
            Raising = [],
            Origin = site_origin(Expr, Ctx)
        ;
            Raising = [_ | _],
            Origin = least_origin(Ctx, Fault, Raising)
        )
    ).

    % The origin of `Fault` that [LNUL.4.2] ranks first among `Exprs` raising it;
    % `no_origin` when none does.
    %
:- func least_origin(eval_ctx, runtime_fault, list(expr)) = fault_origin.

least_origin(Ctx, Fault, Exprs) = Origin :-
    Origins = list.map((func(E) = fault_origin(E, Ctx, Fault)),
        list.filter(raises(Ctx, Fault), Exprs)),
    (
        Origins = [],
        Origin = no_origin
    ;
        Origins = [First | Rest],
        Origin = list.foldl(
            ( func(O, Best) =
                ( if lnul_4_2_before(Ctx, located(Fault, O), located(Fault, Best))
                  then O else Best ) ),
            Rest, First)
    ).

lnul_4_2_before(Ctx, located(FA, OA), located(FB, OB)) :-
    KA = lnul_4_2_kind_key(FA),
    KB = lnul_4_2_kind_key(FB),
    (
        KA < KB
    ;
        KA = KB,
        compare((<), record_key(Ctx, FA, OA), record_key(Ctx, FB, OB))
    ).

lnul_4_2_yielded(Ctx, A, B) = ( if lnul_4_2_before(Ctx, B, A) then B else A ).

    % The fields of a fault's record that an operand supplies, so that `compare` on
    % this term is [LNUL.4.2]'s order: schema name, slot name, then a
    % ComputationError's `fact_id` or a TypeError's `actual`.
    %
:- type record_key
    --->    record_key(list(int), list(int), uint64, list(int)).

:- func record_key(eval_ctx, runtime_fault, fault_origin) = record_key.

record_key(Ctx, Fault, fault_origin(Fact, Schema, Slot, Actual)) = Key :-
    Class = expr_fault_class(Fault),
    (
        Class = fc_computation,
        Key = record_key(ref_bytes(Ctx, Schema), ref_bytes(Ctx, Slot),
            fact_number(Fact), [])
    ;
        Class = fc_type,
        Key = record_key(ref_bytes(Ctx, Schema), ref_bytes(Ctx, Slot), 0u64,
            text_bytes(Actual))
    ;
        ( Class = fc_engine
        ; Class = fc_bounds
        ),
        Key = record_key([], [], 0u64, [])
    ).

:- func ref_bytes(eval_ctx, maybe(intern_ref)) = list(int).

ref_bytes(_, no) = [].
ref_bytes(Ctx, yes(Ref)) = Bytes :-
    ( if expand(Ctx ^ ec_interns, Ref, S) then
        string.to_utf8_code_unit_list(S, Bytes)
    else
        Bytes = []
    ).

:- func text_bytes(maybe(string)) = list(int).

text_bytes(no) = [].
text_bytes(yes(S)) = Bytes :-
    string.to_utf8_code_unit_list(S, Bytes).

:- func fact_number(maybe(fact_id)) = uint64.

fact_number(no) = 0u64.
fact_number(yes(F)) = fact_id_value(F).

:- pred raises(eval_ctx::in, runtime_fault::in, expr::in) is semidet.

raises(Ctx, Fault, E) :-
    eval(E, Ctx, ev_fault(Fault)).

    % The children `eval` evaluates, in its order. A lazy node gives only what ran.
    %
:- func evaluated_children(expr, eval_ctx) = list(expr).

evaluated_children(E, Ctx) = Children :-
    (
        ( E = e_lit(_)
        ; E = e_slot(_, _)
        ; E = e_slot_named(_, _)
        ; E = e_json_path(_, _)
        ; E = e_agg(_)
        ; E = e_now
        ; E = e_entry_stamp(_)
        ; E = e_bind_ref(_)
        ),
        Children = []
    ;
        E = e_json_path_expr(A, B),
        Children = [A, B]
    ;
        E = e_binop(_, A, B),
        Children = [A, B]
    ;
        ( E = e_unop(_, A)
        ; E = e_bind(_, A)
        ; E = e_tainted(A)
        ; E = e_is_test(A, _, _)
        ),
        Children = [A]
    ;
        E = e_call(_, As),
        Children = As
    ;
        E = e_interp(_),
        Children = expr_children(E)
    ;
        E = e_if(Cond, Then, Else),
        ( if eval(Cond, Ctx, ev_ok(bool(yes))) then
            Children = [Cond, Then]
        else if eval(Cond, Ctx, ev_ok(bool(no))) then
            Children = [Cond, Else]
        else
            Children = [Cond]
        )
    ;
        E = e_coalesce(Left, Right),
        ( if eval(Left, Ctx, ev_ok(null)) then
            Children = [Left, Right]
        else
            Children = [Left]
        )
    ).

    % The origin at the node that raised: its offending operand. A leaf is its own.
    %
:- func site_origin(expr, eval_ctx) = fault_origin.

site_origin(Site, Ctx) = Origin :-
    Operands = evaluated_children(Site, Ctx),
    ( if offending(Site, Operands, Ctx, Operand) then
        Origin = operand_origin(Operand, Ctx)
    else
        Origin = operand_origin(Site, Ctx)
    ).

:- pred offending(expr::in, list(expr)::in, eval_ctx::in, expr::out)
    is semidet.

offending(Site, Operands, Ctx, Operand) :-
    ( if
        list.find_first_match(
            ( pred(O::in) is semidet :- known_value(O, Ctx, null) ),
            Operands, Null)
    then
        Operand = Null
    else if
        Site = e_binop(Op, _, Divisor),
        ( Op = op_div ; Op = op_floordiv ; Op = op_rem )
    then
        Operand = Divisor
    else
        Operands = [Operand | _]
    ).

    % What a slot-read operand names: the fact, its schema, the slot, the value's tag.
    %
:- func operand_origin(expr, eval_ctx) = fault_origin.

operand_origin(Operand, Ctx) = Origin :-
    ( if Operand = e_tainted(Inner) then
        Origin = operand_origin(Inner, Ctx)
    else
        Actual = ( if known_value(Operand, Ctx, V) then yes(value_tag(V))
                   else no ),
        ( if
            slot_operand(Operand, Index, Read),
            fact_at(Ctx, Index, Fact),
            map.search(Ctx ^ ec_schemas, schema_id_value(Fact ^ f_schema),
                Schema)
        then
            SchemaRef = yes(schema_name_ref(Schema ^ s_name)),
            (
                Read = by_index(Ix),
                Slot = slot_name_at(Schema, Ix)
            ;
                Read = by_name(Name),
                Slot = yes(Name)
            ;
                Read = no_slot,
                Slot = no
            ),
            Origin = fault_origin(yes(Fact ^ f_id), SchemaRef, Slot, Actual)
        else
            Origin = fault_origin(no, no, no, Actual)
        )
    ).

    % An operand's value where knowing it takes no evaluation: a literal or a slot
    % read. The other runtime can know no more, so both name the same operand.
    %
:- pred known_value(expr::in, eval_ctx::in, ds_value::out) is semidet.

known_value(Operand, Ctx, V) :-
    ( if Operand = e_tainted(Inner) then
        known_value(Inner, Ctx, V)
    else if Operand = e_lit(Lit) then
        V = Lit
    else
        ( Operand = e_slot(_, slot(_)) ; Operand = e_slot_named(_, _) ),
        eval(Operand, Ctx, ev_ok(V))
    ).

:- type operand_read
    --->    by_index(int)
    ;       by_name(intern_ref)
    ;       no_slot.            % the whole fact, or a Json path into it

:- pred slot_operand(expr::in, fact_index::out, operand_read::out) is semidet.

slot_operand(e_slot(Index, Read), Index, OpRead) :-
    (
        Read = slot(Slot),
        OpRead = by_index(uint32.cast_to_int(slot_index_value(Slot)))
    ;
        Read = whole_fact,
        OpRead = no_slot
    ).
slot_operand(e_slot_named(Index, Name), Index, by_name(Name)).
slot_operand(e_json_path(Index, _), Index, no_slot).

value_tag(int(_)) = "Int".
value_tag(float(_)) = "Float".
value_tag(str(_)) = "String".
value_tag(text(_)) = "String".
value_tag(bool(_)) = "Bool".
value_tag(bytes(_)) = "Bytes".
value_tag(json(_)) = "Json".
value_tag(fact_ref(_)) = "FactRef".
value_tag(duration(_)) = "Duration".
value_tag(time(_)) = "Time".
value_tag(ratio(_, _)) = "Ratio".
value_tag(null) = "Null".

%-----------------------------------------------------------------------------%
% Helpers
%-----------------------------------------------------------------------------%

:- pred fact_at(eval_ctx::in, fact_index::in, fact::out) is semidet.

fact_at(Ctx, candidate, Fact) :-
    Ctx ^ ec_candidate = yes(Id),
    lookup_fact(Ctx ^ ec_wm, Id, Fact).
fact_at(Ctx, token_fact(N), Fact) :-
    list.index0(Ctx ^ ec_token, N, Id),
    lookup_fact(Ctx ^ ec_wm, Id, Fact).

    % A slot's value as an expression sees it [LTIM.1.1.3]: a `Time` slot holds an
    % `int` and reads back as a `time` at offset 0.
    %
:- func slot_value(eval_ctx, fact, int) = eval_outcome.

slot_value(Ctx, Fact, Ix) = Outcome :-
    ( if Ix >= 0, Ix < array.size(Fact ^ f_slots) then
        V = array.lookup(Fact ^ f_slots, Ix),
        ( if
            V = int(Ns),
            map.search(Ctx ^ ec_schemas, schema_id_value(Fact ^ f_schema),
                Schema),
            list.index0(slot_commons(Schema), Ix, Common),
            Common ^ sc_kind = k_time
        then
            Outcome = ev_ok(time(ds_time(Ns, 0i64)))
        else
            Outcome = ev_ok(V)
        )
    else
        Outcome = ev_fault(rf_artefact_lied)
    ).

%-----------------------------------------------------------------------------%
% Rendering an action argument to text
%-----------------------------------------------------------------------------%

eval_text(E0, Ctx, Out) :-
    % The wrapper's taint classifies a value the node cannot render [IRET.9.6].
    Tainted = ( if E0 = e_tainted(_) then yes else no ),
    E = untainted(E0),
    ( if E = e_interp(Prims) then
        % [LNUL.4.10]: every primitive's value is evaluated first, and a fault
        % yields what `lnul_4_2_yielded` selects. Otherwise rendering runs left to
        % right, and the first primitive it cannot render decides.
        Evaluated = list.map(evaluate_prim(Ctx), Prims),
        ( if
            list.foldl(lnul_4_10_prim_fault(Ctx), Evaluated, no)
                = yes(located(Fault, _))
        then
            Out = text_fault(Fault)
        else
            render_prims(Evaluated, Tainted, Ctx, [], Out)
        )
    else
        eval(E0, Ctx, Outcome),
        (
            Outcome = ev_ok(V),
            render_bare(Ctx, V, Raw),
            Out = text_classified(Tainted, Raw)
        ;
            Outcome = ev_fault(Fault),
            Out = text_fault(Fault)
        )
    ).

    % A primitive with its value evaluated; a text primitive carries `ev_ok(null)`.
    %
:- type evaluated_prim
    --->    evaluated_prim(format_prim, eval_outcome).

:- func evaluate_prim(eval_ctx, format_prim) = evaluated_prim.

evaluate_prim(_, fp_text(T)) = evaluated_prim(fp_text(T), ev_ok(null)).
evaluate_prim(Ctx, fp_value(VP)) = evaluated_prim(fp_value(VP), Outcome) :-
    eval(VP ^ vp_value, Ctx, Outcome).
evaluate_prim(Ctx, fp_time(E, Items)) = evaluated_prim(fp_time(E, Items), Outcome) :-
    eval(E, Ctx, Outcome).

:- func lnul_4_10_prim_fault(eval_ctx, evaluated_prim, maybe(located))
    = maybe(located).

lnul_4_10_prim_fault(_, evaluated_prim(_, ev_ok(_)), Acc) = Acc.
lnul_4_10_prim_fault(Ctx, evaluated_prim(P, ev_fault(F)), Acc) = yes(Yielded) :-
    Here = located(F, least_origin(Ctx, F, expr_children(e_interp([P])))),
    (
        Acc = no,
        Yielded = Here
    ;
        Acc = yes(G),
        Yielded = lnul_4_2_yielded(Ctx, G, Here)
    ).

:- pred render_prims(list(evaluated_prim)::in, bool::in, eval_ctx::in,
                     list(string)::in, text_outcome::out) is det.

render_prims([], _, _, Acc, text_ok(string.append_list(list.reverse(Acc)))).
render_prims([P | Ps], Tainted, Ctx, Acc, Out) :-
    render_prim(P, Tainted, Ctx, One),
    (
        One = text_fault(Fault),
        Out = text_fault(Fault)
    ;
        One = text_ok(Text),
        render_prims(Ps, Tainted, Ctx, [Text | Acc], Out)
    ).

    % A value the primitive cannot render is the interpolation node's type error.
    %
:- pred render_prim(evaluated_prim::in, bool::in, eval_ctx::in,
                    text_outcome::out) is det.

render_prim(evaluated_prim(fp_text(Text), _), _, _, text_ok(Text)).
render_prim(evaluated_prim(fp_value(VP), Outcome), Tainted, Ctx, Out) :-
    (
        Outcome = ev_fault(Fault),
        Out = text_fault(Fault)
    ;
        Outcome = ev_ok(V),
        ( if V = null then
            % [LGRA.2.9.6.10]: nothing, and no padding.
            Out = text_ok("")
        else if
            renderable_of(Ctx, V, R),
            render_value(VP, R, Text)
        then
            Out = text_ok(Text)
        else
            Out = text_classified(Tainted, text_fault(rf_type_mismatch))
        )
    ).
render_prim(evaluated_prim(fp_time(_, Items), Outcome), Tainted, _Ctx, Out) :-
    (
        Outcome = ev_fault(Fault),
        Out = text_fault(Fault)
    ;
        Outcome = ev_ok(V),
        ( if V = null then
            Out = text_ok("")
        else if V = time(T) then
            Out = text_ok(render_time(Items, utc_ns(T), tz_offset_ns(T)))
        else if instant_ns(V, Ns) then
            Out = text_ok(render_time(Items, Ns, 0i64))
        else
            Out = text_classified(Tainted, text_fault(rf_type_mismatch))
        )
    ).

    % The kinds a `ValuePrim` has a rule for. Fails on Bytes, Json, a fact reference
    % and a Ratio.
    %
:- pred renderable_of(eval_ctx::in, ds_value::in, renderable::out) is semidet.

renderable_of(Ctx, V, R) :-
    ( if V = float(F) then
        R = r_float(F)
    else if V = bool(B) then
        R = r_bool(B)
    else if string_of(Ctx, V, S) then
        R = r_string(S)
    else
        instant_ns(V, Ns),
        R = r_int(Ns)
    ).

:- pred instant_ns(ds_value::in, int64::out) is semidet.

instant_ns(int(I), I).
instant_ns(time(T), utc_ns(T)).
instant_ns(duration(D), int64.cast_from_uint64(duration_ns(D))).

    % `classified/2` for a rendering.
    %
:- func text_classified(bool, text_outcome) = text_outcome.

text_classified(_, text_ok(S)) = text_ok(S).
text_classified(Tainted, text_fault(F0)) = text_fault(F) :-
    ( if classified(Tainted, ev_fault(F0)) = ev_fault(F1) then
        F = F1
    else
        F = F0
    ).

:- func text_value(text_outcome) = eval_outcome.

text_value(text_ok(S)) = ev_ok(text(S)).
text_value(text_fault(F)) = ev_fault(F).

    % A value in a text position that is not an interpolation, and a series row's
    % identity: a String, an Int, a Float, a Bool or `null` arrives.
    %
:- pred render_bare(eval_ctx::in, ds_value::in, text_outcome::out) is det.

render_bare(Ctx, V, Out) :-
    ( if V = null then
        Out = text_ok("")
    else if V = int(I) then
        Out = text_ok(bare_int(I))
    else if V = float(F) then
        Out = text_ok(bare_float(F))
    else if V = bool(B) then
        Out = text_ok(bare_bool(B))
    else if string_of(Ctx, V, S) then
        Out = text_ok(S)
    else
        Out = unrendered(V)
    ).

    % A value `render_bare` has no rule for. A `time`, a `duration` or a `ratio` does
    % not reach here.
    %
:- func unrendered(ds_value) = text_outcome.

unrendered(V) =
    ( if ( V = bytes(_) ; V = json(_) ; V = fact_ref(_) ) then
        text_fault(rf_type_mismatch)
    else
        text_fault(rf_unimplemented)
    ).

    % The content of a String value, interned or computed.
    %
:- pred string_of(eval_ctx::in, ds_value::in, string::out) is semidet.

string_of(Ctx, str(Ref), S) :-
    expand(Ctx ^ ec_interns, Ref, S).
string_of(_, text(S), S).

    % The `error <code>:` test on a call continuation [LCCO.8.3.2]: the pattern's
    % segments must be a prefix of the code's. Only `.` is a boundary [LECC.1.2].
    % A non-String operand is `false`, not a fault.
    %
:- func error_code_matches(eval_ctx, ds_value, ds_value) = ds_value.

error_code_matches(Ctx, CodeVal, PatternVal) = Result :-
    ( if
        string_of(Ctx, CodeVal, Code),
        string_of(Ctx, PatternVal, Pattern)
    then
        Result = bool(code_matches(Code, Pattern))
    else
        Result = bool(no)
    ).

    % The lowering of `s ~ /pattern/flags` [LREG.1.2]; `!~` is its `not` [LREG.1.3].
    % A partial match, by RE2 [LREG.8.1], compiled per call. A null subject is `null`
    % [LNUL.4.1]; a non-String subject is `false`, not a fault.
    %
:- func regex_match(eval_ctx, ds_value, ds_value, maybe(ds_value)) = ds_value.

regex_match(Ctx, SubjectVal, RegexVal, FlagsVal) = Result :-
    ( if SubjectVal = null then
        Result = null
    else if
        string_of(Ctx, SubjectVal, Subject),
        string_of(Ctx, RegexVal, Pattern),
        (
            FlagsVal = no,
            Letters = ""
        ;
            FlagsVal = yes(FlagArg),
            string_of(Ctx, FlagArg, Letters)
        )
    then
        Result = bool(( if re2_matches(Pattern, re2_flags_of_letters(Letters),
            Subject) then yes else no ))
    else
        Result = bool(no)
    ).

    % One capturing group of the match a `where (a, b) = s ~ /re/` binds [LREG.4.1],
    % as a computed String [LREG.4.4]; a group that did not participate is "". A
    % subject or pattern that is not a String, `null` included, or a non-Int group,
    % is a mismatch. A group out of range, a pattern RE2 refuses and no match mean
    % the artefact lied, since the lowering gates the rule on the match.
    %
:- func regex_capture(eval_ctx, ds_value, ds_value, ds_value, ds_value)
    = eval_outcome.

regex_capture(Ctx, SubjectVal, RegexVal, FlagsVal, GroupVal) = Outcome :-
    ( if
        string_of(Ctx, SubjectVal, Subject),
        string_of(Ctx, RegexVal, Pattern),
        GroupVal = int(Group)
    then
        ( if string_of(Ctx, FlagsVal, Found) then
            Letters = Found
        else
            Letters = ""
        ),
        Captured = re2_capture(Pattern, re2_flags_of_letters(Letters), Subject,
            int64.cast_to_int(Group)),
        (
            Captured = re2_captured(Piece),
            Outcome = ev_ok(text(Piece))
        ;
            ( Captured = re2_no_match
            ; Captured = re2_no_such_group
            ; Captured = re2_rejected
            ),
            Outcome = ev_fault(rf_artefact_lied)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

:- func code_matches(string, string) = bool.

code_matches(Code, Pattern) = Matches :-
    ( if Pattern = "" then
        Matches = yes
    else if string.append(Pattern, Rest, Code) then
        ( if Rest = "" then
            Matches = yes
        else if string.first_char(Rest, C, _), C = ('.') then
            Matches = yes
        else
            Matches = no
        )
    else
        Matches = no
    ).

    % Walk a Json value along a path value. An unresolved path is `null`, as is one
    % resolving to a JSON `null` [LNUL.8.4, IRET.9.6]; an unparseable path finds
    % nothing. A `null` root, a `Json?` slot holding none, has no document to
    % resolve against and reads `null` [LNUL.8.4]. A non-String path, or a value
    % neither Json, text nor `null`, is a mismatch.
    %
:- func json_walk(eval_ctx, ds_value, ds_value) = eval_outcome.

json_walk(Ctx, Val, PathVal) = Outcome :-
    ( if not string_of(Ctx, PathVal, _) then
        Outcome = ev_fault(rf_type_mismatch)
    else if Val = null then
        Outcome = ev_ok(null)
    else if Val = json(Doc), string_of(Ctx, PathVal, Text) then
        ( if parse_path(Text, Path), resolve(Path, Doc, Leaf) then
            Outcome = ev_ok(json_value(Leaf))
        else
            Outcome = ev_ok(null)
        )
    else if string_of(Ctx, Val, JsonText) then
        ds.json_text.parse(JsonText, Parsed),
        (
            Parsed = parsed(Doc),
            Outcome = json_walk(Ctx, json(Doc), PathVal)
        ;
            Parsed = refused(Why),
            Outcome = json_text_refused(Why)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % A String handed a Json builtin as its root is Json text, parsed under
    % [LGRA.5.8.6]'s limits: over a limit is NOT_REPRESENTABLE, and anything else
    % that is not JSON a mismatch. Only a hand-built artefact reaches this
    % [RLOW.6.3.3].
    %
:- func json_text_refused(json_refusal) = eval_outcome.

json_text_refused(Why) =
    ( if Why = jr_limit(_) then
        ev_fault(rf_not_representable)
    else
        ev_fault(rf_type_mismatch)
    ).

    % `has(<path>)` and `len(<path>)` [LEXP.6.1]. A path resolving to JSON `null` has
    % it; one resolving to nothing does not [LNUL.8.4]. `len` of anything but an
    % array, an unresolved path included, is a mismatch [LEXP.6.2].
    %
:- func json_introspect(eval_ctx, builtin_fn, ds_value, ds_value)
    = eval_outcome.

json_introspect(Ctx, Fn, Val, PathVal) = Outcome :-
    ( if string_of(Ctx, PathVal, Text) then
        ( if Val = json(Doc) then
            ( if Fn = fn_json_has then
                Outcome = ev_ok(bool(( if parse_path(Text, Path),
                    has_path(Path, Doc) then yes else no )))
            else if
                parse_path(Text, Path),
                resolve(Path, Doc, j_array(Es))
            then
                Outcome = ev_ok(int(int64.from_int(list.length(Es))))
            else
                Outcome = ev_fault(rf_type_mismatch)
            )
        else if string_of(Ctx, Val, JsonText) then
            ds.json_text.parse(JsonText, Parsed),
            (
                Parsed = parsed(Doc),
                Outcome = json_introspect(Ctx, Fn, json(Doc), PathVal)
            ;
                Parsed = refused(Why),
                Outcome = json_text_refused(Why)
            )
        else
            Outcome = absent_or_mismatch(Val)
        )
    else
        Outcome = absent_or_mismatch(PathVal)
    ).

:- func json_value(json) = ds_value.

json_value(j_null) = null.
json_value(j_bool(B)) = bool(B).
json_value(j_int(I)) = int(I).
json_value(j_float(F)) = float(F).
json_value(j_string(S)) = text(S).
    % A composite leaf stays Json [RLOW.6.3.4].
json_value(j_array(Es)) = json(j_array(Es)).
json_value(j_object(M)) = json(j_object(M)).

%-----------------------------------------------------------------------------%
% Builtins
%-----------------------------------------------------------------------------%

    % The rest fault `rf_unimplemented`, which `ds.dsc` refuses at load.
    %
:- pred apply_builtin(builtin_fn::in, list(ds_value)::in, eval_ctx::in,
                      eval_outcome::out) is det.

apply_builtin(Fn, Args, Ctx, Outcome) :-
    ( if Fn = fn_now, Args = [] then
        eval(e_now, Ctx, Outcome)
    else if Fn = fn_monotonic_ns, Args = [] then
        % [LTIM.2.2.1]: a count of nanoseconds.
        Outcome = ev_ok(int(int64.cast_from_uint64(instant_ns(Ctx ^ ec_now))))
    else if Fn = fn_abs, Args = [V] then
        % Not `int64.abs`, which throws on min_int64; it wraps [LEXP.7.13.1].
        ( if V = int(I) then
            Outcome = ev_ok(int(( if I < 0i64 then -I else I )))
        else if V = float(F) then Outcome = ev_ok(float(float.abs(F)))
        else Outcome = absent_or_mismatch(V) )
    else if
        ( Fn = fn_floor ; Fn = fn_ceil ; Fn = fn_trunc ; Fn = fn_round ),
        Args = [V]
    then
        Outcome = to_integer(Fn, V)
    else if Fn = fn_sign, Args = [V] then
        % An `Int` [LEXP.3.2], whatever the operand's type.
        ( if V = int(I) then
            Outcome = ev_ok(int(( if I > 0i64 then 1i64
                else if I < 0i64 then -1i64 else 0i64 )))
        else if V = float(F) then
            Outcome = ev_ok(int(( if F > 0.0 then 1i64 else if F < 0.0 then -1i64
                else 0i64 )))
        else
            Outcome = absent_or_mismatch(V)
        )
    else if
        ( Fn = fn_bit_count ; Fn = fn_bit_length ),
        Args = [V]
    then
        % [LEXP.3.7.1]: `bit_count` counts the two's-complement word's bits (-1
        % answers 64); `bit_length` those of the unsigned magnitude (INT64_MIN
        % answers 64).
        ( if V = int(I) then
            W = uint64.cast_from_int64(I),
            ( if Fn = fn_bit_count then
                Outcome = ev_ok(int(int64.from_int(u64_ones(W))))
            else
                M = ( if I < 0i64 then 0u64 - W else W ),
                Outcome = ev_ok(int(int64.from_int(u64_width(M))))
            )
        else
            Outcome = absent_or_mismatch(V)
        )
    else if lexp_3_7_3_member_args(Fn, Args) then
        Outcome = lexp_3_7_3_member(Fn, Args)
    else if Fn = fn_sqrt, Args = [V] then
        % [LEXP.3.2]. A negative operand gives NaN [LDET.3.6.2], where `math.sqrt`
        % would throw.
        ( if as_float(V, F) then
            Outcome = ev_ok(float(math.unchecked_sqrt(F)))
        else
            Outcome = absent_or_mismatch(V)
        )
    else if Fn = fn_pow, Args = [Base, Exp] then
        Outcome = power(Base, Exp)
    else if Fn = fn_fma, Args = [X, Y, Z] then
        Outcome = lexp_3_2_2_fma(X, Y, Z)
    else if transcendental(Fn, Args, Transcendental) then
        Outcome = ev_ok(float(Transcendental))
    else if transcendental_fn(Fn) then
        Outcome = ev_fault(rf_type_mismatch)
    else if Fn = fn_currency_round, Args = [V, Mode] then
        Outcome = currency_round(V, int(1i64), Mode)
    else if Fn = fn_currency_round_to, Args = [V, Scale, Mode] then
        Outcome = currency_round(V, Scale, Mode)
    else if
        Fn = fn_currency_convert,
        Args = [Amount, _Pair, SchemaV, NumV, DenV | Selector]
    then
        Outcome = currency_convert(Ctx, Amount, SchemaV, NumV, DenV, Selector)
    else if Fn = fn_float_to_string, Args = [V] then
        % [LCST.4.5.6], [LDET.3.2.7].
        ( if V = float(F) then
            Outcome = ev_ok(text(bare_float(F)))
        else
            Outcome = absent_or_mismatch(V)
        )
    else if Fn = fn_int_to_string, Args = [V] then
        % [LCST.4.5.6].
        ( if V = int(I) then
            Outcome = ev_ok(text(bare_int(I)))
        else
            Outcome = absent_or_mismatch(V)
        )
    else if Fn = fn_bool_to_string, Args = [V] then
        % [LCST.4.5.6].
        ( if V = bool(B) then
            Outcome = ev_ok(text(bare_bool(B)))
        else
            Outcome = absent_or_mismatch(V)
        )
    else if Fn = fn_utc, Args = [V] then
        % [LTIM.3.1]: the offset zeroed; an `Int` reads as UTC nanoseconds. Only the
        % lowering of a bare `{t}` site hands it a `null` [LGRA.2.9.6.10].
        ( if V = null then
            Outcome = ev_ok(null)
        else if instant_int(V, Utc) then
            Outcome = ev_ok(time(ds_time(Utc, 0i64)))
        else
            Outcome = absent_or_mismatch(V)
        )
    else if Fn = fn_local, Args = [V, Zone] then
        Outcome = ltim_3_2_local(Ctx, V, Zone)
    else if Fn = fn_time_date, Args = [V, Zone] then
        Outcome = ltim_3_3_date(Ctx, V, Zone)
    else if
        ( Fn = fn_hour ; Fn = fn_minute ; Fn = fn_second ; Fn = fn_day
        ; Fn = fn_month ; Fn = fn_year ; Fn = fn_day_of_week ),
        Args = [V, Zone]
    then
        Outcome = ltim_6_5_component(Ctx, Fn, V, Zone)
    else if Fn = fn_to_string, Args = [V | Format] then
        Outcome = time_to_string(Ctx, V, Format)
    else if Fn = fn_calendar_time, Args = [_, _, _, _, _, _, _] then
        Outcome = ltim_14_2_calendar_time(Args)
    else if Fn = fn_calendar_date, Args = [_, _, _] then
        Outcome = ltim_14_2_calendar_date(Args)
    else if Fn = fn_duration_to_string, Args = [V] then
        Outcome = duration_to_string(V)
    else if Fn = fn_add_months, Args = [V, N] then
        Outcome = ltim_4_3_shift(V, N, 1i64)
    else if Fn = fn_add_years, Args = [V, N] then
        Outcome = ltim_4_3_shift(V, N, 12i64)
    else if Fn = fn_int_div_exact, Args = [N, D] then
        Outcome = rlow_7_3_9_int_div_exact(N, D)
    else if Fn = fn_int_mul_add_checked, Args = [X, M, A] then
        Outcome = rlow_7_3_9_int_mul_add_checked(X, M, A)
    else if Fn = fn_floor_time, Args = [T, D] then
        Outcome = ltim_7_1_floor(T, D)
    else if Fn = fn_date_add_duration, Args = [D, Dur] then
        Outcome = ltim_4_2_3_date_shift(D, Dur, 1i64)
    else if Fn = fn_date_sub_duration, Args = [D, Dur] then
        Outcome = ltim_4_2_3_date_shift(D, Dur, -1i64)
    else if Fn = fn_date_diff, Args = [A, B] then
        Outcome = ltim_4_2_3_date_diff(A, B)
    else if Fn = fn_duration_add, Args = [A, B] then
        Outcome = ltim_4_1_1_duration_add(A, B)
    else if Fn = fn_duration_mul, Args = [N, D] then
        Outcome = ltim_4_1_1_duration_mul(N, D)
    else if geometric(Fn, Args, Outcome0) then
        Outcome = Outcome0
    else if lexp_3_6_1_angle(Fn, Args, AngleOutcome) then
        Outcome = AngleOutcome
    else if Fn = fn_great_circle then
        Outcome = lexp_5_11_2_great_circle(Args)
    else if Fn = fn_str_length, Args = [V] then
        % Codepoints [LSTR.2.1]; a `Bytes` value's byte count [LSTR.4.2]; a whole
        % `Json` array's length [LEXP.6.1], since only a path folds to `FN_JSON_LEN`.
        ( if string_of(Ctx, V, S) then
            Outcome = ev_ok(int(int64.from_int(string.count_codepoints(S))))
        else if V = bytes(B) then
            Outcome = ev_ok(int(int64.from_int(bitmap.det_num_bytes(B))))
        else if V = json(j_array(Es)) then
            Outcome = ev_ok(int(int64.from_int(list.length(Es))))
        else
            Outcome = absent_or_mismatch(V)
        )
    else if
        ( Fn = fn_json_has ; Fn = fn_json_len ),
        Args = [Val, PathVal]
    then
        Outcome = json_introspect(Ctx, Fn, Val, PathVal)
    else if Fn = fn_min, Args = [A, B] then
        Outcome = pick(Ctx, A, B, le)
    else if Fn = fn_max, Args = [A, B] then
        Outcome = pick(Ctx, A, B, ge)
    else if Fn = fn_cache_get, Args = [KeyVal] then
        % `cached(key)` [LGRA.9.8]. A miss, an expired entry [NSTG.2.4.2] and a
        % non-String key all answer `null`, the same as a stored `null` [LNUL.11.1].
        ( if
            string_of(Ctx, KeyVal, Key),
            cache_get_live(Ctx ^ ec_cache, Ctx ^ ec_now, Key, Found)
        then
            Outcome = ev_ok(Found)
        else
            Outcome = ev_ok(null)
        )
    else if Fn = fn_json_path, Args = [Val, PathVal] then
        Outcome = json_walk(Ctx, Val, PathVal)
    else if Fn = fn_error_code_matches, Args = [CodeVal, PatternVal] then
        Outcome = ev_ok(error_code_matches(Ctx, CodeVal, PatternVal))
    else if
        Fn = fn_regex_match,
        (
            Args = [SubjectVal, RegexVal],
            FlagsVal = no
        ;
            Args = [SubjectVal, RegexVal, FlagArg],
            FlagsVal = yes(FlagArg)
        )
    then
        Outcome = ev_ok(regex_match(Ctx, SubjectVal, RegexVal, FlagsVal))
    else if
        Fn = fn_regex_capture,
        Args = [SubjectVal, RegexVal, FlagArg, GroupVal]
    then
        Outcome = regex_capture(Ctx, SubjectVal, RegexVal, FlagArg, GroupVal)
    else if cast_builtin(Fn, Args, Ctx, CastOut) then
        Outcome = CastOut
    else if Fn = fn_series_percentile then
        % `pNN` rides a sixth argument, its N, after the window.
        ( if list.index0(Args, 5, int(N)) then
            Outcome = ev_ok(series_read(agg_percentile(int64.cast_to_int(N)),
                Args, Ctx))
        else
            Outcome = ev_ok(cold_value(agg_percentile(50), no))
        )
    else if ( Fn = fn_series_count_of ; Fn = fn_series_contains ) then
        % The lookup value is the sixth argument. A computed String is interned
        % for the comparison, since samples hold `str`; a Time is taken to its
        % instant, since a Time slot's samples hold the stored Int
        % (`stored_value`), so one instant at any offset is one value
        % ([LSER.16.5.1], [LTIM.5.2]).
        ( if list.index0(Args, 5, Lookup0) then
            ( if
                Lookup0 = text(S),
                interned(Ctx ^ ec_interns, S, Ref)
            then
                Lookup = str(Ref)
            else
                Lookup = series_identity(Lookup0)
            ),
            ( if Fn = fn_series_count_of then
                Agg = agg_count_of(Lookup)
            else
                Agg = agg_contains(Lookup)
            ),
            Outcome = ev_ok(series_read(Agg, Args, Ctx))
        else if Fn = fn_series_count_of then
            Outcome = ev_ok(int(0i64))
        else
            Outcome = ev_ok(bool(no))
        )
    else if series_agg(Fn, Agg) then
        Outcome = ev_ok(series_read(Agg, Args, Ctx))
    else
        Outcome = ev_fault(rf_unimplemented)
    ).

    % The `::` casts [LCST.4.5]. `float_to_int` truncates, and traps on a non-finite
    % or unrepresentable operand [LCST.4.5.4]; `int_to_float` cannot fail; `string_to_*`
    % answer `null` on a failed parse. `string_to_bool` is case-sensitive [LCST.4.5.5].
    %
:- pred cast_builtin(builtin_fn::in, list(ds_value)::in, eval_ctx::in,
                     eval_outcome::out) is semidet.

cast_builtin(fn_float_to_int, [V], _, Outcome) :-
    ( if V = float(F) then
        ( if float.is_nan_or_inf(F) then
            Outcome = ev_fault(rf_cast_non_finite(F))
        else if i64.truncate_float(F, I) then
            Outcome = ev_ok(int(I))
        else
            % [LERR.1.4.9]: `1e30 :: Int` does not wrap.
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = absent_or_mismatch(V)
    ).
cast_builtin(fn_int_to_float, [V], _, Outcome) :-
    ( if V = int(I) then
        Outcome = ev_ok(float(i64.to_float(I)))
    else
        Outcome = absent_or_mismatch(V)
    ).
cast_builtin(fn_string_to_int, [V], Ctx, Outcome) :-
    ( if string_of(Ctx, V, S) then
        % [LCST.4.5.7]: a signed INT_LIT, any base, separators as in source.
        ( if i64.from_literal(S, I) then
            Outcome = ev_ok(int(I))
        else
            Outcome = ev_ok(null)
        )
    else
        Outcome = absent_or_mismatch(V)
    ).
cast_builtin(fn_string_to_float, [V], Ctx, Outcome) :-
    ( if string_of(Ctx, V, S) then
        % [LCST.4.5.8]. Mercury's `to_float` reads a different set.
        ( if float_text.parse_text(S, F) then
            Outcome = ev_ok(float(F))
        else
            Outcome = ev_ok(null)
        )
    else
        Outcome = absent_or_mismatch(V)
    ).
cast_builtin(fn_string_to_bool, [V], Ctx, Outcome) :-
    ( if string_of(Ctx, V, S) then
        ( if S = "true" then
            Outcome = ev_ok(bool(yes))
        else if S = "false" then
            Outcome = ev_ok(bool(no))
        else
            Outcome = ev_ok(null)
        )
    else
        Outcome = absent_or_mismatch(V)
    ).

    % The series ops answered by `agg` alone.
    %
:- pred series_agg(builtin_fn::in, agg::out) is semidet.

series_agg(fn_series_mean, agg_mean).
series_agg(fn_series_min, agg_min).
series_agg(fn_series_max, agg_max).
series_agg(fn_series_count, agg_count).
series_agg(fn_series_sum, agg_sum).
series_agg(fn_series_first, agg_first).
series_agg(fn_series_last, agg_last).
series_agg(fn_series_variance, agg_variance).
series_agg(fn_series_pvariance, agg_pvariance).
series_agg(fn_series_stdev, agg_stdev).
series_agg(fn_series_pstdev, agg_pstdev).
series_agg(fn_series_active_fraction, agg_active_fraction).
series_agg(fn_series_integral, agg_integral).
series_agg(fn_series_bool_and, agg_bool_and).
series_agg(fn_series_bool_or, agg_bool_or).
series_agg(fn_series_count_distinct, agg_count_distinct).
series_agg(fn_series_onset_rate, agg_onset_rate).
series_agg(fn_series_rate, agg_rate).
series_agg(fn_series_direction, agg_direction).
% [LSER.17.2].
series_agg(fn_series_median, agg_percentile(50)).

:- func series_read(agg, list(ds_value), eval_ctx) = ds_value.

series_read(Agg, Args, Ctx) = Value :-
    ( if series_key_of(Args, Ctx, Key) then
        Zero = cold_value(Agg, slot_is_int(Ctx, Key)),
        query(Agg, Key, Ctx ^ ec_now, Ctx ^ ec_series, Zero, Value)
    else
        % An argument shape the compiler does not emit.
        Value = cold_value(Agg, no)
    ).

    % Whether the series' slot is Int-represented [RDSC.5.5.8], which narrows the
    % zero of a type-preserving aggregation [LSER.16.2].
    %
:- func slot_is_int(eval_ctx, series_key) = bool.

slot_is_int(Ctx, series_key(SchemaName, SlotName, _, _, _)) = IsInt :-
    ( if
        interned(Ctx ^ ec_interns, SlotName, SlotRef),
        list.member(Schema, map.values(Ctx ^ ec_schemas)),
        expand(Ctx ^ ec_interns, schema_name_ref(Schema ^ s_name), SchemaName),
        slot_by_name(Schema, SlotRef, Common),
        int_represented(Common ^ sc_kind)
    then
        IsInt = yes
    else
        IsInt = no
    ).

    % The compiler's argument shape:
    %
    %     <op>(lit_str schema, lit_str slot, lit_str id_slot, <id value>,
    %          <window>, [<lookup value>])
    %
    % The id is `lit_str ""` for `by: none`. The window selects the row
    % [RDSC.5a.8.1]. The identity is stringified, so an Int 1 and a String "1" are
    % one row.
    %
:- pred series_key_of(list(ds_value)::in, eval_ctx::in, series_key::out)
    is semidet.

series_key_of([SchemaV, SlotV, IdSlotV, IdV | Rest], Ctx, Key) :-
    string_of(Ctx, SchemaV, Schema),
    string_of(Ctx, SlotV, Slot),
    string_of(Ctx, IdSlotV, IdSlot),
    ( if render_bare(Ctx, series_identity(IdV), text_ok(Id)) then
        Key = series_key(Schema, Slot, IdSlot, Id, window_arg(Rest))
    else
        % An identity that will not render has no row.
        fail
    ).

    % A Time identity keys its row by its instant, as the stored slot's Int does.
    %
:- func series_identity(ds_value) = ds_value.

series_identity(V) = ( if V = time(T) then int(utc_ns(T)) else V ).

    % The window from a series builtin's fifth argument. Absent means 0, all-time
    % [LSER.5.2].
    %
:- func window_arg(list(ds_value)) = uint64.

window_arg([]) = 0u64.
window_arg([V | _]) =
    ( if V = int(I), I >= 0i64 then uint64.cast_from_int64(I) else 0u64 ).

    % A builtin's operand of the wrong kind, `null` included [LNUL.5.1], classified
    % by the `e_call` arm.
    %
:- func absent_or_mismatch(ds_value) = eval_outcome.

absent_or_mismatch(_) = ev_fault(rf_type_mismatch).

    % The set bits of a word. Not the stdlib's, so the answer does not depend on
    % which Mercury the image carries.
    %
:- func u64_ones(uint64) = int.

u64_ones(W) =
    ( if W = 0u64 then 0
    else uint64.cast_to_int(W /\ 1u64) + u64_ones(W >> 1) ).

    % The position of the highest set bit, 0 for 0.
    %
:- func u64_width(uint64) = int.

u64_width(W) = ( if W = 0u64 then 0 else 1 + u64_width(W >> 1) ).

:- pred lexp_3_7_3_member_args(builtin_fn::in, list(ds_value)::in) is semidet.

lexp_3_7_3_member_args(fn_bits, [_, _, _]).
lexp_3_7_3_member_args(fn_sign_extend, [_, _]).
lexp_3_7_3_member_args(fn_swap_bytes, [_, _]).
lexp_3_7_3_member_args(fn_leading_zeros, [_]).
lexp_3_7_3_member_args(fn_trailing_zeros, [_]).

    % [LEXP.3.7.3]: five `Int` members over the receiver's 64-bit pattern, as uint64.
    % A `null` operand is `null`, before the kind test, unlike `bit_count`. An
    % argument outside the member's domain is DOMAIN [LEXP.3.7.4].
    %
:- func lexp_3_7_3_member(builtin_fn, list(ds_value)) = eval_outcome.

lexp_3_7_3_member(Fn, Args) = Outcome :-
    ( if list.member(null, Args) then
        Outcome = ev_ok(null)
    else if list.map(int_operand, Args, Is) then
        Outcome = lexp_3_7_3_answer(Fn, Is)
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

:- pred int_operand(ds_value::in, int64::out) is semidet.

int_operand(int(I), I).

:- func lexp_3_7_3_answer(builtin_fn, list(int64)) = eval_outcome.

lexp_3_7_3_answer(Fn, Is) = Outcome :-
    ( if Fn = fn_bits, Is = [X, Lo, W] then
        ( if Lo >= 0i64, W >= 1i64, W =< 64i64, Lo =< 64i64 - W then
            P = uint64.cast_from_int64(X) >> int64.cast_to_int(Lo),
            Outcome = ev_ok(int(int64.cast_from_uint64(P /\ low_mask(W))))
        else
            Outcome = ev_fault(rf_domain)
        )
    else if Fn = fn_sign_extend, Is = [X, W] then
        ( if W = 64i64 then
            Outcome = ev_ok(int(X))
        else if W >= 1i64, W < 64i64 then
            Mask = low_mask(W),
            U = uint64.cast_from_int64(X) /\ Mask,
            Sign = (U >> int64.cast_to_int(W - 1i64)) /\ 1u64,
            Extended = ( if Sign = 1u64 then U \/ \ Mask else U ),
            Outcome = ev_ok(int(int64.cast_from_uint64(Extended)))
        else
            Outcome = ev_fault(rf_domain)
        )
    else if Fn = fn_swap_bytes, Is = [X, W] then
        ( if ( W = 16i64 ; W = 32i64 ; W = 64i64 ) then
            Swapped = swap_low_bytes(uint64.cast_from_int64(X), 0,
                int64.cast_to_int(W) // 8, 0u64),
            Outcome = ev_ok(int(int64.cast_from_uint64(Swapped)))
        else
            Outcome = ev_fault(rf_domain)
        )
    else if Fn = fn_leading_zeros, Is = [X] then
        Outcome = ev_ok(int(int64.from_int(
            64 - u64_width(uint64.cast_from_int64(X)))))
    else if Fn = fn_trailing_zeros, Is = [X] then
        Outcome = ev_ok(int(int64.from_int(
            u64_trailing_zeros(uint64.cast_from_int64(X), 0))))
    else
        Outcome = ev_fault(rf_unimplemented)
    ).

    % The low `W` bits set, 1 =< W =< 64.
    %
:- func low_mask(int64) = uint64.

low_mask(W) =
    ( if W >= 64i64 then uint64.max_uint64
    else (1u64 << int64.cast_to_int(W)) - 1u64 ).

    % Bytes `I` .. `N - 1` of `P`, appended to `Acc`, so byte 0 ends most significant.
    %
:- func swap_low_bytes(uint64, int, int, uint64) = uint64.

swap_low_bytes(P, I, N, Acc) =
    ( if I >= N then Acc
    else swap_low_bytes(P, I + 1, N,
        (Acc << 8) \/ ((P >> (8 * I)) /\ 255u64)) ).

    % The 0 bits below the lowest 1 bit, 64 for 0.
    %
:- func u64_trailing_zeros(uint64, int) = int.

u64_trailing_zeros(W, N) =
    ( if N >= 64 then 64
    else if W /\ 1u64 = 1u64 then N
    else u64_trailing_zeros(W >> 1, N + 1) ).

    % `floor`, `ceil`, `trunc` and `round` [LEXP.3.2]: an `Int` result. A result with
    % no `Int` traps, as `Float :: Int` does [LEXP.3.2.1].
    %
:- func to_integer(builtin_fn, ds_value) = eval_outcome.

to_integer(Fn, V) = Outcome :-
    ( if V = int(I) then
        Outcome = ev_ok(int(I))
    else if V = float(F) then
        ( if float.is_nan_or_inf(F) then
            Outcome = ev_fault(rf_cast_non_finite(F))
        else if i64.truncate_float(rounded(Fn, F), I) then
            Outcome = ev_ok(int(I))
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = absent_or_mismatch(V)
    ).

    % `trunc`'s is the operand, because `i64.truncate_float` truncates.
    %
:- func rounded(builtin_fn, float) = float.

rounded(Fn, F) =
    ( if Fn = fn_floor then math.floor(F)
    else if Fn = fn_ceil then math.ceiling(F)
    else if Fn = fn_round then round_half_even(F)
    else F ).

    % Nearest integral value, ties to even; `float.round_to_int` is ties-away.
    % `F - floor(F)` is exact for a finite double.
    %
:- func round_half_even(float) = float.

round_half_even(F) = R :-
    Lo = math.floor(F),
    Diff = F - Lo,
    ( if Diff < 0.5 then
        R = Lo
    else if Diff > 0.5 then
        R = Lo + 1.0
    else if even_integral(Lo) then
        R = Lo
    else
        R = Lo + 1.0
    ).

    % `<amount>.round("<mode>")` and `<amount>.round_to(<unit>, "<mode>")` [LUNI.13.5];
    % `FN_CURRENCY_ROUND` is this with a scale of 1. `round(amount / scale) * scale`,
    % in base units and exact: a `Float` is decomposed into its exact fraction. A
    % result outside `Int64` refuses [LUNI.13.10], as does a `Float` with no `Int64`
    % fraction.
    %
:- func currency_round(ds_value, ds_value, ds_value) = eval_outcome.

currency_round(V, ScaleV, ModeV) = Outcome :-
    ( if
        ScaleV = int(Scale),
        ModeV = int(Mode),
        Scale > 0i64,
        Mode >= 0i64, Mode =< 5i64
    then
        ( if V = int(I) then
            Outcome = scaled_round(I, 1i64, Scale, Mode)
        else if V = ratio(N, D) then
            Outcome = scaled_round(N, D, Scale, Mode)
        else if V = float(F) then
            ( if float_fraction(F, N, D) then
                Outcome = scaled_round(N, D, Scale, Mode)
            else
                Outcome = ev_fault(rf_not_representable)
            )
        else
            Outcome = ev_fault(rf_type_mismatch)
        )
    else if ( ScaleV = int(_), ModeV = int(_) ) then
        Outcome = ev_fault(rf_artefact_lied)
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

:- func scaled_round(int64, int64, int64, int64) = eval_outcome.

scaled_round(Num, Den, Scale, Mode) =
    ( if
        checked_mul(Den, Scale, ScaledDen),
        round_ratio(Num, ScaledDen, Mode, K),
        checked_mul(K, Scale, Result)
    then
        ev_ok(int(Result))
    else
        ev_fault(rf_not_representable)
    ).

    % `Num / Den` (Den > 0) to an integer under one of [LUNI.13.6]'s six modes:
    % 0 half_even, 1 half_up, 2 half_down, 3 ceiling, 4 floor, 5 truncate. The tie
    % test avoids doubling, which could overflow. Fails only when stepping away from
    % zero would leave `Int64`.
    %
:- pred round_ratio(int64::in, int64::in, int64::in, int64::out) is semidet.

round_ratio(Num, Den, Mode, Out) :-
    Den > 0i64,
    Q = Num // Den,
    R = Num rem Den,
    ( if R = 0i64 then
        Out = Q
    else
        Neg = ( if Num < 0i64 then yes else no ),
        AR = int64.abs(R),
        Rest = Den - AR,
        ( if Mode = 5i64 then
            Away = no
        else if Mode = 3i64 then
            Away = bool.not(Neg)
        else if Mode = 4i64 then
            Away = Neg
        else if Mode = 1i64 then
            Away = ( if AR >= Rest then yes else no )
        else if Mode = 2i64 then
            Away = ( if AR > Rest then yes else no )
        else
            Away = ( if AR \= Rest then ( if AR > Rest then yes else no )
                     else if Q rem 2i64 \= 0i64 then yes else no )
        ),
        (
            Away = no,
            Out = Q
        ;
            Away = yes,
            (
                Neg = yes,
                Q > int64.min_int64,
                Out = Q - 1i64
            ;
                Neg = no,
                Q < int64.max_int64,
                Out = Q + 1i64
            )
        )
    ).

    % `A * B` when it fits `Int64`.
    %
:- pred checked_mul(int64::in, int64::in, int64::out) is semidet.

checked_mul(A, B, Out) :-
    ( if A = 0i64 ; B = 0i64 then
        Out = 0i64
    else
        ( if A > 0i64 then
            ( if B > 0i64 then A =< int64.max_int64 // B
              else B >= int64.min_int64 // A )
        else
            ( if B > 0i64 then A >= int64.min_int64 // B
              else A >= int64.max_int64 // B )
        ),
        Out = A * B
    ).

    % The exact fraction a finite double is, its denominator a power of two. Fails
    % for a non-finite value or one whose scaled numerator leaves `Int64`.
    %
:- pred float_fraction(float::in, int64::out, int64::out) is semidet.

float_fraction(F, Num, Den) :-
    not float.is_nan_or_inf(F),
    float_fraction_loop(F, 1i64, 0, Num, Den).

:- pred float_fraction_loop(float::in, int64::in, int::in,
                            int64::out, int64::out) is semidet.

float_fraction_loop(Scaled, Den0, Steps, Num, Den) :-
    ( if Scaled = math.floor(Scaled) then
        i64.truncate_float(Scaled, Num),
        Den = Den0
    else
        Steps < 62,
        Den0 =< int64.max_int64 // 2i64,
        float_fraction_loop(Scaled * 2.0, Den0 * 2i64, Steps + 1, Num, Den)
    ).

    % `<amount>.to_currency(<fx_pair>)` [LUNI.13.4]:
    % `(amount, pair, via_schema, num_field, den_field, [slot, value]...)`. An exact
    % `Ratio`; rounding is the author's [LUNI.13.5]. The rate is the live matching
    % fact with the greatest `asof` [LUNI.4.6.2], the first met on a tie; none
    % converts at 1:1 [LUNI.4.6.1]. A zero rate denominator is DIVIDE_BY_ZERO and an
    % overflow NOT_REPRESENTABLE [LUNI.13.10].
    %
:- func currency_convert(eval_ctx, ds_value, ds_value, ds_value, ds_value,
                         list(ds_value)) = eval_outcome.

currency_convert(Ctx, Amount, SchemaV, NumV, DenV, Selector) = Outcome :-
    ( if Amount = int(A) then
        ( if
            string_of(Ctx, SchemaV, SchemaName),
            string_of(Ctx, NumV, NumField),
            string_of(Ctx, DenV, DenField),
            selector_pairs(Ctx, Selector, Pairs)
        then
            ( if
                list.find_first_match(schema_named(Ctx, SchemaName),
                    map.values(Ctx ^ ec_schemas), Schema)
            then
                list.foldl(fx_candidate(Ctx, Schema, Pairs, NumField, DenField),
                    facts_of_schema(Ctx ^ ec_wm, Schema ^ s_id), no, Best)
            else
                Best = no
            ),
            (
                Best = no,
                Outcome = apply_rate(A, 1i64, 1i64)
            ;
                Best = yes({_, RateNum, RateDen}),
                Outcome = apply_rate(A, RateNum, RateDen)
            )
        else
            Outcome = ev_fault(rf_artefact_lied)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

:- pred selector_pairs(eval_ctx::in, list(ds_value)::in,
                       list({string, string})::out) is semidet.

selector_pairs(_, [], []).
selector_pairs(Ctx, [SlotV, ValueV | Rest], [{Slot, Value} | Pairs]) :-
    string_of(Ctx, SlotV, Slot),
    string_of(Ctx, ValueV, Value),
    selector_pairs(Ctx, Rest, Pairs).

:- pred schema_named(eval_ctx::in, string::in, schema::in) is semidet.

schema_named(Ctx, Name, Schema) :-
    expand(Ctx ^ ec_interns, schema_name_ref(Schema ^ s_name), Name).

    % One live fact of the via-schema, kept if it matches every selector equality,
    % carries Int `num` / `den` slots, and has a greater `asof` than the best so far.
    % An `asof` missing or not a number orders as 0.
    %
:- pred fx_candidate(eval_ctx::in, schema::in, list({string, string})::in,
                     string::in, string::in, fact::in,
                     maybe({float, int64, int64})::in,
                     maybe({float, int64, int64})::out) is det.

fx_candidate(Ctx, Schema, Pairs, NumField, DenField, Fact, Best0, Best) :-
    ( if
        all [Slot, Value] (
            list.member({Slot, Value}, Pairs)
        =>
            (
                slot_named(Ctx, Schema, Fact, Slot, Got),
                string_of(Ctx, Got, Value)
            )
        ),
        slot_named(Ctx, Schema, Fact, NumField, NumV),
        NumV = int(N),
        slot_named(Ctx, Schema, Fact, DenField, DenV),
        DenV = int(D)
    then
        ( if
            slot_named(Ctx, Schema, Fact, "asof", AsofV),
            ( AsofV = float(F), Asof = F
            ; AsofV = int(I), Asof = i64.to_float(I)
            )
        then
            Order = Asof
        else
            Order = 0.0
        ),
        ( if
            Best0 = yes({BestOrder, _, _}),
            not Order > BestOrder
        then
            Best = Best0
        else
            Best = yes({Order, N, D})
        )
    else
        Best = Best0
    ).

:- pred slot_named(eval_ctx::in, schema::in, fact::in, string::in,
                   ds_value::out) is semidet.

slot_named(Ctx, Schema, Fact, Name, Value) :-
    interned(Ctx ^ ec_interns, Name, Ref),
    slot_by_name(Schema, Ref, Common),
    Ix = slot_index_int(Common ^ sc_index),
    Ix >= 0,
    Ix < array.size(Fact ^ f_slots),
    Value = array.lookup(Fact ^ f_slots, Ix).

    % `amount * num / den` as a `Ratio` with a positive denominator.
    %
:- func apply_rate(int64, int64, int64) = eval_outcome.

apply_rate(Amount, RateNum, RateDen) = Outcome :-
    ( if RateDen = 0i64 then
        Outcome = ev_fault(rf_div_zero)
    else if checked_mul(Amount, RateNum, Num) then
        ( if RateDen > 0i64 then
            Outcome = ev_ok(ratio(Num, RateDen))
        else if RateDen > int64.min_int64, Num > int64.min_int64 then
            Outcome = ev_ok(ratio(-Num, -RateDen))
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_not_representable)
    ).

    % `t.floor(d)` [LTIM.7.1]: the boundary of `d` at or before `t`, in the offset `t`
    % carries, `utc_ns - ((utc_ns + tz_offset_ns) mod d)` with a flooring `mod`, summed
    % as an `integer` to avoid overflow. The receiver keeps its kind. No zone is
    % consulted. `d =< 0` is DIVIDE_BY_ZERO [LTIM.1.3.1]; a floor below the first int64
    % ns is NOT_REPRESENTABLE [LTIM.1.1.5].
    %
:- func ltim_7_1_floor(ds_value, ds_value) = eval_outcome.

ltim_7_1_floor(V, D) = Outcome :-
    ( if
        ( V = time(T), Utc = utc_ns(T), Off = tz_offset_ns(T)
        ; V = int(Utc), Off = 0i64
        ),
        duration_operand_ns(D, Ns)
    then
        ( if Ns =< 0i64 then
            Outcome = ev_fault(rf_div_zero)
        else
            I = integer.from_int64(Utc),
            R = (I + integer.from_int64(Off)) mod integer.from_int64(Ns),
            ( if integer.to_int64(I - R, Floored) then
                ( if V = time(_) then
                    Outcome = ev_ok(time(ds_time(Floored, Off)))
                else
                    Outcome = ev_ok(int(Floored))
                )
            else
                Outcome = ev_fault(rf_not_representable)
            )
        )
    else
        Outcome = absent_or_mismatch(V)
    ).

    % `FN_INT_DIV_EXACT(n, d)` [RLOW.7.3.9]: `n / d` when `d` divides `n`. A remainder,
    % and `min_int64 / -1` on which `//` throws, are NOT_REPRESENTABLE; a zero divisor
    % DIVIDE_BY_ZERO; a `null` on either side `null`.
    %
:- func rlow_7_3_9_int_div_exact(ds_value, ds_value) = eval_outcome.

rlow_7_3_9_int_div_exact(N, D) = Outcome :-
    ( if ( N = null ; D = null ) then
        Outcome = ev_ok(null)
    else if N = int(A), D = int(B) then
        ( if B = 0i64 then
            Outcome = ev_fault(rf_div_zero)
        else if A = int64.min_int64, B = -1i64 then
            Outcome = ev_fault(rf_not_representable)
        else if int64.rem(A, B) \= 0i64 then
            Outcome = ev_fault(rf_not_representable)
        else
            Outcome = ev_ok(int(A // B))
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % `FN_INT_MUL_ADD_CHECKED(x, m, a)` [RLOW.7.3.9]: `m·x + a`, the product and
    % then the sum each held to the `Int` range. Either outside it is
    % NOT_REPRESENTABLE, so a sum that would come back into range after the
    % product left it raises too; nothing wraps. A `null` operand is `null`; the
    % compiler writes `m` and `a` as literals.
    %
:- func rlow_7_3_9_int_mul_add_checked(ds_value, ds_value, ds_value)
    = eval_outcome.

rlow_7_3_9_int_mul_add_checked(XV, MV, AV) = Outcome :-
    ( if ( XV = null ; MV = null ; AV = null ) then
        Outcome = ev_ok(null)
    else if XV = int(X), MV = int(M), AV = int(A) then
        Product = integer.from_int64(M) * integer.from_int64(X),
        ( if
            integer.to_int64(Product, P),
            integer.to_int64(integer.from_int64(P) + integer.from_int64(A), S)
        then
            Outcome = ev_ok(int(S))
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % The temporal conversions [LTIM.8] and calendar shifts [LTIM.4.3]. A result its
    % type cannot represent [LTIM.4.3.3], and an identifier the operation does not
    % admit [LTIM.8.3.2], are NOT_REPRESENTABLE; a `null` operand is `null`. The
    % receiver chooses the arm: a `time(_)` is a `Time`, an `int(_)` a `Date`
    % [RDSC.5.5.8].

    % The format argument: "iso8601" when absent [LTIM.8.1.2], lowercased [LTIM.8.2.2].
    % Fails when present and not a `String`.
    %
:- pred time_format_arg(eval_ctx::in, list(ds_value)::in, string::out)
    is semidet.

time_format_arg(Ctx, Format, Id) :-
    (
        Format = [],
        Id = "iso8601"
    ;
        Format = [FormatV],
        string_of(Ctx, FormatV, S),
        Id = string.to_lower(S)
    ).

    % [LTIM.8.1.2]. A `Date` admits `iso8601` alone [LTIM.8.2.1].
    %
:- func time_to_string(eval_ctx, ds_value, list(ds_value)) = eval_outcome.

time_to_string(Ctx, V, Format) = Outcome :-
    ( if V = null then
        Outcome = ev_ok(null)
    else if
        ( V = time(_) ; V = int(_) ),
        time_format_arg(Ctx, Format, Id)
    then
        ( if V = time(T) then
            ( if Id = "iso8601" then
                Outcome = ev_ok(text(render_iso8601(utc_ns(T),
                    tz_offset_ns(T))))
            else if render_epoch(Id, utc_ns(T), Out) then
                Outcome = ev_ok(text(Out))
            else
                Outcome = ev_fault(rf_not_representable)
            )
        else if
            V = int(Days),
            Id = "iso8601",
            ltim_1_2_2_date_in_range(Days)
        then
            Outcome = ev_ok(text(ltim_8_2_1_render_date(Days)))
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % A `null` field is `null` [LNUL.4.10]; a non-`Int` field a mismatch; the rest is
    % `ds.chrono.ltim_14_2_time` / `ltim_14_2_date`.
    %
    %@spec [LTIM.14.2]
    %@spec [LTIM.14.1]
:- func ltim_14_2_calendar_time(list(ds_value)) = eval_outcome.

ltim_14_2_calendar_time(Args) = Outcome :-
    ( if list.member(null, Args) then
        Outcome = ev_ok(null)
    else if
        list.map(int_operand, Args, Is),
        Is = [Y, Mo, D, H, Mi, S, Ns]
    then
        Answer = ltim_14_2_time(Y, Mo, D, H, Mi, S, Ns),
        (
            Answer = calendar_value(Utc),
            Outcome = ev_ok(time(ds_time(Utc, 0i64)))
        ;
            Answer = calendar_domain,
            Outcome = ev_fault(rf_domain)
        ;
            Answer = calendar_not_representable,
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    %@spec [LTIM.14.2]
    %@spec [LTIM.14.1]
:- func ltim_14_2_calendar_date(list(ds_value)) = eval_outcome.

ltim_14_2_calendar_date(Args) = Outcome :-
    ( if list.member(null, Args) then
        Outcome = ev_ok(null)
    else if
        list.map(int_operand, Args, Is),
        Is = [Y, Mo, D]
    then
        Answer = ltim_14_2_date(Y, Mo, D),
        (
            Answer = calendar_value(Days),
            Outcome = ev_ok(int(Days))
        ;
            Answer = calendar_domain,
            Outcome = ev_fault(rf_domain)
        ;
            Answer = calendar_not_representable,
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % [LTIM.8.1.2], [LTIM.8.4].
    %
:- func duration_to_string(ds_value) = eval_outcome.

duration_to_string(V) = Outcome :-
    ( if V = null then
        Outcome = ev_ok(null)
    else if V = int(Ns) then
        Outcome = ev_ok(text(ltim_8_4_render_duration(Ns)))
    else if V = duration(D) then
        Outcome = ev_ok(text(ltim_8_4_render_duration(
            int64.cast_from_uint64(duration_ns(D)))))
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % [LTIM.4.2.3]'s `d + dur` (`Sign` 1) and `d - dur` (`Sign` -1) [RLOW.6.1.5]. A
    % `null` operand is `null`; a `Duration` not of whole days is DOMAIN [LTIM.4.2.2];
    % a receiver or result outside [LTIM.1.2.2] is NOT_REPRESENTABLE. `Sign` because
    % negating the int64 minimum wraps. The shift itself cannot overflow.
    %
:- func ltim_4_2_3_date_shift(ds_value, ds_value, int64) = eval_outcome.

ltim_4_2_3_date_shift(V, DurV, Sign) = Outcome :-
    Day = 86400000000000i64,
    ( if ( V = null ; DurV = null ) then
        Outcome = ev_ok(null)
    else if V = int(Days), duration_operand_ns(DurV, Ns) then
        ( if Ns rem Day \= 0i64 then
            Outcome = ev_fault(rf_domain)
        else if ltim_1_2_2_date_in_range(Days) then
            Shifted = Days + Sign * (Ns // Day),
            ( if ltim_1_2_2_date_in_range(Shifted) then
                Outcome = ev_ok(int(Shifted))
            else
                Outcome = ev_fault(rf_not_representable)
            )
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % [LTIM.4.2.3]'s `a - b` of two `Date`s [RLOW.6.1.5]: the difference in ns, `0` when
    % `a` is earlier [LTIM.1.3.1]. A `null` operand is `null`; an operand outside
    % [LTIM.1.2.2], or a difference past int64, is NOT_REPRESENTABLE.
    %
:- func ltim_4_2_3_date_diff(ds_value, ds_value) = eval_outcome.

ltim_4_2_3_date_diff(A, B) = Outcome :-
    ( if ( A = null ; B = null ) then
        Outcome = ev_ok(null)
    else if A = int(DaysA), B = int(DaysB) then
        ( if
            not ( ltim_1_2_2_date_in_range(DaysA),
                  ltim_1_2_2_date_in_range(DaysB) )
        then
            Outcome = ev_fault(rf_not_representable)
        else if DaysA =< DaysB then
            Outcome = ev_ok(int(0i64))
        else if
            integer.to_int64((integer.from_int64(DaysA)
                - integer.from_int64(DaysB))
                * integer.from_int64(86400000000000i64), Ns)
        then
            Outcome = ev_ok(int(Ns))
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % [LTIM.4.1.1]'s `Duration + Duration` [RLOW.6.1.6]: the exact sum in ns. A
    % `null` operand is `null`; a sum above 2^63 - 1, or a negative one, is
    % NOT_REPRESENTABLE.
    %
:- func ltim_4_1_1_duration_add(ds_value, ds_value) = eval_outcome.

ltim_4_1_1_duration_add(A, B) = Outcome :-
    ( if ( A = null ; B = null ) then
        Outcome = ev_ok(null)
    else if duration_operand_ns(A, NsA), duration_operand_ns(B, NsB) then
        Sum = integer.from_int64(NsA) + integer.from_int64(NsB),
        ( if
            Sum >= integer.zero,
            integer.to_int64(Sum, Ns)
        then
            Outcome = ev_ok(int(Ns))
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % [LTIM.4.1.1]'s `n * dur` [RLOW.6.1.6]: the exact product in ns. A `null`
    % operand is `null`; a product above 2^63 - 1 is NOT_REPRESENTABLE, and a
    % negative one is `0` [LTIM.1.3.1].
    %
:- func ltim_4_1_1_duration_mul(ds_value, ds_value) = eval_outcome.

ltim_4_1_1_duration_mul(NV, DV) = Outcome :-
    ( if ( NV = null ; DV = null ) then
        Outcome = ev_ok(null)
    else if NV = int(N), duration_operand_ns(DV, NsD) then
        Product = integer.from_int64(N) * integer.from_int64(NsD),
        ( if Product < integer.zero then
            Outcome = ev_ok(int(0i64))
        else if integer.to_int64(Product, Ns) then
            Outcome = ev_ok(int(Ns))
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

:- pred duration_operand_ns(ds_value::in, int64::out) is semidet.

duration_operand_ns(int(Ns), Ns).
duration_operand_ns(duration(D), int64.cast_from_uint64(duration_ns(D))).

    % `add_months(x, n)` and `add_years(x, n)` [LTIM.4.3.1], `MonthsPer` being 1 or 12.
    % A `Time` moves on the UTC calendar, keeping its nanoseconds since UTC midnight
    % and its offset [LTIM.4.3.3]. The day clamps to the month's last [LTIM.4.3.2].
    %
:- func ltim_4_3_shift(ds_value, ds_value, int64) = eval_outcome.

ltim_4_3_shift(V, N, MonthsPer) = Outcome :-
    Day = 86400000000000i64,
    ( if ( V = null ; N = null ) then
        Outcome = ev_ok(null)
    else if N = int(Count), V = int(Days) then
        ( if
            ltim_1_2_2_date_in_range(Days),
            ltim_4_3_shift_days(Days, Count, MonthsPer, Shifted),
            ltim_1_2_2_date_in_range(Shifted)
        then
            Outcome = ev_ok(int(Shifted))
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else if N = int(Count), V = time(T) then
        Utc = utc_ns(T),
        Days = Utc div Day,
        ( if ltim_4_3_shift_days(Days, Count, MonthsPer, Shifted) then
            % Only the result instant can be unrepresentable [LTIM.1.1.5], not the
            % shifted day's midnight, so it is computed whole.
            ( if
                integer.to_int64(integer.from_int64(Shifted)
                    * integer.from_int64(Day)
                    + integer.from_int64(Utc mod Day), Result)
            then
                Outcome = ev_ok(time(ds_time(Result, tz_offset_ns(T))))
            else
                Outcome = ev_fault(rf_not_representable)
            )
        else
            Outcome = ev_fault(rf_not_representable)
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % The civil date of `Days` moved by `Count * MonthsPer` months, clamped. Fails for
    % a resulting year past 10^15 either way. Whether the result is in range is the
    % caller's to check.
    %
:- pred ltim_4_3_shift_days(int64::in, int64::in, int64::in, int64::out)
    is semidet.

ltim_4_3_shift_days(Days, Count, MonthsPer, Shifted) :-
    civil_from_days(Days, Y, M, D),
    Idx = integer.from_int64(Y) * integer(12) + integer.from_int64(M - 1i64)
        + integer.from_int64(Count) * integer.from_int64(MonthsPer),
    NY0 = Idx // integer(12),
    % `//` truncates; floor it, so a negative index lands in its own year.
    NY = ( if NY0 * integer(12) > Idx then NY0 - integer.one else NY0 ),
    Limit = integer.from_int64(1000000000000000i64),
    NY =< Limit,
    NY >= -Limit,
    integer.to_int64(NY, Year),
    integer.to_int64(Idx - NY * integer(12) + integer.one, Month),
    Last = ltim_days_in_month(Year, Month),
    Shifted = ltim_days_from_civil(Year, Month,
        ( if D < Last then D else Last )).

    % `pow(x, y)` and `x ** y` [LEXP.7.3a]: `Int ** Int` with a non-negative exponent
    % is `Int`; anything else is `Float`, from CORE-MATH's `pow` [LEXP.3.9.2], and
    % special operands answer as [LEXP.3.9.3] says, without a trap [LDET.3.6.2].
    %
:- func power(ds_value, ds_value) = eval_outcome.

power(Base, Exp) = Outcome :-
    ( if Base = int(B), Exp = int(E), E >= 0i64 then
        Outcome = ev_ok(int(i64.pow(B, E)))
    else if as_float(Base, BF), as_float(Exp, EF) then
        Outcome = ev_ok(float(core_math.pow(BF, EF)))
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % [LEXP.3.2.2]: `math.fma(x, y, z)`, rounded once [IARC.7.14]. An `Int` promotes
    % [LEXP.7.3]. A `null` operand is `null` [LNUL.4.1], as for the operators and unlike
    % other builtins [LNUL.5.1].
    %
:- func lexp_3_2_2_fma(ds_value, ds_value, ds_value) = eval_outcome.

lexp_3_2_2_fma(X, Y, Z) = Outcome :-
    ( if ( X = null ; Y = null ; Z = null ) then
        Outcome = ev_ok(null)
    else if as_float(X, FX), as_float(Y, FY), as_float(Z, FZ) then
        Outcome = ev_ok(float(core_math.fma(FX, FY, FZ)))
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % The fourteen transcendentals of [LEXP.3.9.1]. A pole or an argument outside the
    % domain is a value, not a fault [LDET.3.6.2]. An `Int` promotes.
    %
:- pred transcendental(builtin_fn::in, list(ds_value)::in, float::out)
    is semidet.

transcendental(Fn, Args, R) :-
    ( if Args = [V], as_float(V, X) then
        unary_transcendental(Fn, X, R)
    else
        Fn = fn_atan2,
        Args = [VY, VX],
        as_float(VY, Y),
        as_float(VX, X),
        R = core_math.atan2(Y, X)
    ).

:- pred unary_transcendental(builtin_fn::in, float::in, float::out)
    is semidet.

unary_transcendental(fn_exp, X, core_math.exp(X)).
unary_transcendental(fn_ln, X, core_math.ln(X)).
unary_transcendental(fn_log2, X, core_math.log2(X)).
unary_transcendental(fn_log10, X, core_math.log10(X)).
unary_transcendental(fn_sin, X, core_math.sin(X)).
unary_transcendental(fn_cos, X, core_math.cos(X)).
unary_transcendental(fn_tan, X, core_math.tan(X)).
unary_transcendental(fn_asin, X, core_math.asin(X)).
unary_transcendental(fn_acos, X, core_math.acos(X)).
unary_transcendental(fn_atan, X, core_math.atan(X)).
unary_transcendental(fn_sinh, X, core_math.sinh(X)).
unary_transcendental(fn_cosh, X, core_math.cosh(X)).
unary_transcendental(fn_tanh, X, core_math.tanh(X)).

:- pred transcendental_fn(builtin_fn::in) is semidet.

transcendental_fn(Fn) :-
    ( Fn = fn_atan2
    ; unary_transcendental(Fn, 0.0, _)
    ).

    % [LEXP.5.3.1], [LEXP.5.5], [LEXP.5.7.1]: the Minkowski distances, vector length and
    % cosine distance, all `Float` [LEXP.5.9.1], an `Int` promoting. Fails on a builtin or
    % arity it does not own.
    %
:- pred geometric(builtin_fn::in, list(ds_value)::in, eval_outcome::out)
    is semidet.

geometric(Fn, Args, Outcome) :-
    geometric_arity(Fn, Arity),
    list.length(Args, Arity),
    ( if list.map(as_float_of, Args, Fs) then
        Outcome = ev_ok(float(geometric_value(Fn, Fs)))
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

:- pred geometric_arity(builtin_fn::in, int::out) is semidet.

geometric_arity(fn_euclidean_2d, 4).
geometric_arity(fn_euclidean_3d, 6).
geometric_arity(fn_manhattan_2d, 4).
geometric_arity(fn_manhattan_3d, 6).
geometric_arity(fn_chebyshev_2d, 4).
geometric_arity(fn_chebyshev_3d, 6).
geometric_arity(fn_hypotenuse_2d, 2).
geometric_arity(fn_hypotenuse_3d, 3).
geometric_arity(fn_cosine_2d, 4).
geometric_arity(fn_cosine_3d, 6).

:- pred as_float_of(ds_value::in, float::out) is semidet.

as_float_of(V, F) :- as_float(V, F).

    % `sqrt(dx*dx + dy*dy)`, not an overflow-avoiding hypot, so both runtimes agree
    % bit for bit.
    %
:- func geometric_value(builtin_fn, list(float)) = float.

geometric_value(Fn, Fs) = D :-
    ( if Fn = fn_hypotenuse_2d ; Fn = fn_hypotenuse_3d then
        D = math.sqrt(list.foldl((func(X, A) = A + X * X), Fs, 0.0))
    else if Fn = fn_cosine_2d, Fs = [AX, AY, BX, BY] then
        D = lexp_5_7_3_cosine(AX * BX + AY * BY,
            AX * AX + AY * AY, BX * BX + BY * BY)
    else if Fn = fn_cosine_3d, Fs = [AX, AY, AZ, BX, BY, BZ] then
        D = lexp_5_7_3_cosine(AX * BX + AY * BY + AZ * BZ,
            AX * AX + AY * AY + AZ * AZ, BX * BX + BY * BY + BZ * BZ)
    else
        Half = list.length(Fs) // 2,
        list.det_split_list(Half, Fs, As, Bs),
        Ds = list.map_corresponding((func(X, Y) = float.abs(X - Y)), As, Bs),
        ( if ( Fn = fn_euclidean_2d ; Fn = fn_euclidean_3d ) then
            D = math.sqrt(list.foldl((func(X, A) = A + X * X), Ds, 0.0))
        else if ( Fn = fn_manhattan_2d ; Fn = fn_manhattan_3d ) then
            D = list.foldl((func(X, A) = A + X), Ds, 0.0)
        else
            D = list.foldl(float.max, Ds, 0.0)
        )
    ).

    % [LEXP.3.6.1]: `degrees(x)` is x times the binary64 nearest 180/math.pi, `radians(x)`
    % x times the one nearest math.pi/180. An `Int` promotes [LEXP.7.3].
    %
:- pred lexp_3_6_1_angle(builtin_fn::in, list(ds_value)::in,
                         eval_outcome::out) is semidet.

lexp_3_6_1_angle(Fn, Args, Outcome) :-
    ( if Fn = fn_degrees then
        Factor = lexp_3_6_1_rad_to_deg
    else
        Fn = fn_radians,
        Factor = lexp_3_6_1_deg_to_rad
    ),
    ( if Args = [V], as_float(V, X) then
        Outcome = ev_ok(float(X * Factor))
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

:- func lexp_3_6_1_rad_to_deg = float.

lexp_3_6_1_rad_to_deg = 57.29577951308232.

:- func lexp_3_6_1_deg_to_rad = float.

lexp_3_6_1_deg_to_rad = 0.017453292519943295.

    % [LEXP.5.11.2]'s haversine composition, in metres, every operation associated as
    % written. A latitude outside [-90, 90], a longitude outside [-180, 180], or a NaN
    % or infinite argument gives NaN [LEXP.5.11.3], since a comparison with a NaN fails.
    % An `Int` promotes.
    %
:- func lexp_5_11_2_great_circle(list(ds_value)) = eval_outcome.

lexp_5_11_2_great_circle(Args) = Outcome :-
    ( if
        Args = [VLat1, VLon1, VLat2, VLon2],
        as_float(VLat1, Lat1),
        as_float(VLon1, Lon1),
        as_float(VLat2, Lat2),
        as_float(VLon2, Lon2)
    then
        ( if
            Lat1 >= -90.0, Lat1 =< 90.0,
            Lat2 >= -90.0, Lat2 =< 90.0,
            Lon1 >= -180.0, Lon1 =< 180.0,
            Lon2 >= -180.0, Lon2 =< 180.0
        then
            K = lexp_3_6_1_deg_to_rad,
            Phi1 = Lat1 * K,
            Phi2 = Lat2 * K,
            DPhi = (Lat2 - Lat1) * K,
            DLam = (Lon2 - Lon1) * K,
            S = core_math.sin(DPhi / 2.0),
            T = core_math.sin(DLam / 2.0),
            A = S * S + (core_math.cos(Phi1) * core_math.cos(Phi2)) * (T * T),
            AClamped = ( if A < 0.0 then 0.0 else if A > 1.0 then 1.0 else A ),
            D = 6371008.8 * (2.0 * core_math.atan2(
                math.unchecked_sqrt(AClamped),
                math.unchecked_sqrt(1.0 - AClamped))),
            Outcome = ev_ok(float(D))
        else
            Outcome = ev_ok(float(float.unchecked_quotient(0.0, 0.0)))
        )
    else
        Outcome = ev_fault(rf_type_mismatch)
    ).

    % [LEXP.5.7.3]: `1 - dot / (sqrt(|a|^2) * sqrt(|b|^2))`, the caller summing left to
    % right with no `0.0` seed. A zero vector gives NaN [LDET.3.6.2], hence the unchecked
    % forms.
    %
:- func lexp_5_7_3_cosine(float, float, float) = float.

lexp_5_7_3_cosine(Dot, NormA2, NormB2) =
    1.0 - float.unchecked_quotient(Dot,
        math.unchecked_sqrt(NormA2) * math.unchecked_sqrt(NormB2)).

    % Whether an integral float is even, without converting it to `int`.
    %
:- pred even_integral(float::in) is semidet.

even_integral(F) :-
    math.floor(F / 2.0) * 2.0 = F.

    % Two-argument `min` / `max`. A `null` is a mismatch [LNUL.5.1]. A tie goes to `A`
    % [LEXP.3.8.2], so `max(2, 2.0)` is the `Int`; with a NaN, `B` wins.
    %
:- func pick(eval_ctx, ds_value, ds_value, cmp) = eval_outcome.

pick(Ctx, A, B, Cmp) = Outcome :-
    ( if ( A = null ; B = null ) then
        Outcome = ev_fault(rf_type_mismatch)
    else
        compare_outcome(content_of(Ctx, A), content_of(Ctx, B), Cmp, Compared),
        (
            Compared = ev_ok(Answer),
            ( if Answer = bool(yes) then
                Outcome = ev_ok(A)
            else
                Outcome = ev_ok(B)
            )
        ;
            Compared = ev_fault(F),
            Outcome = ev_fault(F)
        )
    ).

%-----------------------------------------------------------------------------%

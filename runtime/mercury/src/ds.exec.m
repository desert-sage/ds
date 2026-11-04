% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.exec -- firing a terminal: the action executor.
%
% Walks a terminal's action list in order [IRET.10], evaluates the expressions
% each verb references, and emits effects. Every verb with an outward effect goes
% through `ds.effect.acted/4` [RARC.5.8.12]. `fire` settles each action before
% announcing it.
%
% A fault in any argument abandons the activation [LERR.1]: the event is emitted
% where the fault happened, the actions after it do not run, and those before stand.
%-----------------------------------------------------------------------------%

:- module ds.exec.
:- interface.

:- import_module ds.action.
:- import_module ds.cache.
:- import_module ds.contract.
:- import_module ds.chrono.
:- import_module ds.eval.
:- import_module ds.events.
:- import_module ds.fact.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.rate.
:- import_module ds.rules.
:- import_module ds.schema.
:- import_module ds.series.
:- import_module ds.tms.
:- import_module ds.token.
:- import_module ds.value.
:- import_module ds.wm.
:- import_module list.
:- import_module bool.
:- import_module maybe.
:- import_module map.

%-----------------------------------------------------------------------------%

    % Engine state the executor reads and writes.
    %
:- type exec_state
    --->    exec_state(
                xs_wm      :: wm,
                xs_tms     :: tms,
                xs_cache   :: cache,
                xs_series  :: series_state,
                            % Read-only here: absorption is at the pump's end.
                xs_rate    :: rate_table,
                            % A `rate_allow(...)` guard records the firing it
                            % admits, so it runs here, once per firing [LCDB.3.1].

                xs_capped  :: bool,
                    % The firing is over: a cap refused an assert [RTCT.7] or a
                    % cache write [LSTO.4.7.5], or an action faulted [LERR.1]. The
                    % remaining actions are visited and do nothing.

                xs_interns :: intern_table,
                    % Threaded: an interpolation that becomes a slot value is
                    % interned, because `str(intern_ref)` compares by identity.

                xs_gensym :: int,
                    % The next `FN_GENSYM` number.

                % `scope activation` bookkeeping [LSCP.2.4.1], [LSCP.3.1]. The two
                % lists are this firing's; the map persists.
                xs_act_pending :: list(fact_id),
                    % Facts this firing emitted into an `lc_activation` schema, newest
                    % first, retracted at the synchronous end of the RHS [LSCP.3.2]
                    % unless the firing began an async tail, when they attach to the
                    % token facts it asserted.
                xs_act_tokens  :: list(fact_id),
                    % The synthetic token facts this firing asserted [LSCP.2.4.2].
                xs_act_attach  :: map(uint64, list(fact_id))
                    % Token fact (raw id) -> the activation facts its retraction
                    % discharges [LSCP.3.3].
            ).

    % What the executor needs that does not change during a firing.
    %
:- type exec_ctx
    --->    exec_ctx(
                xc_schemas :: map(uint32, schema),
                xc_now     :: instant,
                            % The monotonic clock's held sample [LTIM.2.8.2].
                xc_wall    :: maybe(int64),
                            % The wall clock's held sample [LTIM.2.8.3], for `now()`.
                xc_rule    :: rule_meta,
                xc_contract :: maybe(contract),
                            % [RTCT.7]'s caps, for facts a rule emits; `no` for an
                            % ordinary bundle.

                xc_cache_caps :: cache_caps,

                xc_hydration_budget :: int,
                    % [LHYD.7.4]: the effective number, never zero.

                xc_sdecls :: list(series_decl),
                    % For [LSER.13.14]'s refuse arm.

                xc_fault_schemas :: list(schema_id),
                    % Whose facts never count against `wm_max` [LERR.9.10].

                xc_service_responses :: map(string, string)
                    % Each service's response schema by name, `""` for `no response`
                    % [LCRS.6.2.1].
            ).

    % A slot's value, by name, as the backing atom carries it.
    %
:- pred slot_text_value(intern_table::in, schema::in, fact::in, string::in,
                        ds_value::out) is semidet.

    % `by: none` is the empty identity slot and the empty identity string
    % [LSER.7.6.2].
    %
:- pred identity_text(intern_table::in, schema::in, fact::in, string::in,
                      string::out) is semidet.

    % [LSER.13.14]'s refuse arm: would this assert put more samples on a step
    % backing's identity than its `capacity`? `WM0` is working memory before the
    % assert, `WM` the candidate after, `Result` what the assert decided. On success,
    % the capacity and the count the sample would reach.
    %
    % The count is the identity's samples retained inside the window, the carry
    % excluded, plus every sample admitted this pump and not yet absorbed, walked in
    % absorb order so `hold` knows what is held when each null arrives. Only a new
    % sample on a live fact is refused, and a null only where the backing absorbs one
    % [LNUL.8.6]. Only step backings refuse (`ds.series.lser_13_14_refuses`).
    %
:- pred lser_13_14_over_capacity(list(series_decl)::in, intern_table::in,
                                 series_state::in, instant::in, schema::in,
                                 wm::in, wm::in, assert_result::in,
                                 uint32::out, uint64::out) is semidet.

    % Propagate one action's fact changes and return what that caused, supplied by
    % the caller, which holds the network and agenda. `exec_state` comes back with
    % what a cascade retracted. `Kept` is the action's own effects, or none where the
    % settler refused them on a capacity breach.
:- type settle_pred(T) == pred(list(effect), list(effect), list(effect),
                               exec_state, exec_state, T, T).
:- inst settle_pred == (pred(in, out, out, in, out, in, out) is det).

    % Fire one activation, returning the effects in emission order. Each action is
    % applied, propagated against the working memory in force then, and only then
    % announced.
    %
:- pred fire(exec_ctx::in, activation::in, list(action)::in,
             settle_pred(T)::in(settle_pred),
             list(effect)::out, exec_state::in, exec_state::out,
             T::in, T::out) is det.

    % An EngineError whose disposition is `latched` [LERR.1], [NCBK.2.9].
    %
:- pred latching(effect::in) is semidet.

    % The cache bounds: `cache_cap`, live keys, and `cache_bytes_cap`, value bytes.
    % Zero is unbounded, for each alone.
    %
:- type cache_caps
    --->    cache_caps(
                cc_keys  :: uint32,
                cc_bytes :: uint64
            ).

:- func no_cache_caps = cache_caps.

    % The bounds a contract declares, or none without one.
    %
:- func contract_cache_caps(maybe(contract)) = cache_caps.

    % Whether a cache write from `Before` to `After` breaches `cache_cap` or
    % `cache_bytes_cap`, and which.
    %
:- pred cache_capped(cache_caps::in, cache::in, cache::in, cap::out) is semidet.

    % Whether the rule's fire guard has a condition [RDSC.4a.8.2.1], which suppresses
    % the firing when not true, as against the rate gate, which denies the actions.
    %
:- pred maturity_guarded(rule_meta::in) is semidet.

    % The rule's condition alone, read at selection under this pump's sample
    % [LTIM.2.5.1]. A fault is a stream event naming the terminal, and no frame.
    %
:- type guard_check
    --->    gc_admits
    ;       gc_denies
    ;       gc_faulted(list(effect)).

:- pred check_guard(exec_ctx::in, activation::in, exec_state::in,
                    guard_check::out) is det.

    % A fault site with an evaluation's origin laid over it.
    %
:- func origin_site(fault_site, fault_origin) = fault_site.

    % [LCRS.6.2.4]: the live answers an arriving fact supersedes, in retraction order:
    % for a fact of a response schema T with `corr` K, T's live facts with K and then
    % `CallError`'s; for a `CallError`, `CallError`'s and then each response schema's,
    % in `Responses`' order, schema-id order. Empty for any other schema, for a `corr`
    % that is not a non-empty String, and for a target with no `corr` slot.
    %
:- func lcrs_6_2_4_arrival_victims(map(uint32, schema), intern_table,
    list(schema), schema, list(ds_value), wm) = list(fact_id).

    % A live fact as a host input's recording writes it when the fact holds a
    % reference [RFCS.24.1]: its FactExternal, each referenced live fact inlined,
    % encoded. `Wall` stands in for a stamp the fact does not carry yet. Fails for a
    % fact that is not live.
    %
    %@helper
:- pred recorded_external_bytes(map(uint32, schema)::in, intern_table::in,
    wm::in, maybe(int64)::in, fact_id::in, list(uint8)::out) is semidet.

    % [NMET.4.1]'s `ds.facts.noop_reassert_suppressed_total{schema}`, once per
    % reassertion suppressed as a no-op [LFAC.2.5.1], from a host's assert and a rule's
    % emit alike. Empty for a schema whose name the table does not hold.
    %
:- func noop_counted(intern_table, schema) = list(metric).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.effect.
:- import_module ds.format.
:- import_module ds.id.
:- import_module ds.value.
:- import_module ds.json.
:- import_module ds.expr.
:- import_module ds.fact.
:- import_module ds.fact_external.
:- import_module array.
:- import_module bitmap.
:- import_module float.
:- import_module ds.builtins.
:- import_module int.
:- import_module int64.
:- import_module assoc_list.
:- import_module pair.
:- import_module require.
:- import_module string.
:- import_module uint64.
:- import_module uint32.
:- import_module uint8.

%-----------------------------------------------------------------------------%
% A series row's key, and [LSER.13.14]'s refuse arm
%-----------------------------------------------------------------------------%
%
% Here because the capacity check runs on both paths into working memory, and
% keys a row as the absorb in `ds.engine` does.

slot_text_value(Interns, Schema, Fact, Name, Value) :-
    interned(Interns, Name, Ref),
    slot_by_name(Schema, Ref, Common),
    Ix = uint32.cast_to_int(slot_index_value(Common ^ sc_index)),
    Ix >= 0,
    Ix < array.size(Fact ^ f_slots),
    Value = array.lookup(Fact ^ f_slots, Ix).

identity_text(Interns, Schema, Fact, IdSlot, Id) :-
    ( if IdSlot = "" then
        Id = ""
    else
        slot_text_value(Interns, Schema, Fact, IdSlot, V),
        stringify(Interns, V, Id)
    ).

    % The stringified identity. What matters is the partition, not the spelling. A
    % Float keys by canonical text [LDET.3.2.7], `-0.0` apart from `0.0`; a Time by its
    % instant. A Json or Bytes identity declines, and leaves the fact unabsorbed.
    %
:- pred stringify(intern_table::in, ds_value::in, string::out) is semidet.

stringify(Interns, V, S) :-
    ( if V = str(Ref) then
        expand(Interns, Ref, S)
    else if V = int(I) then
        S = bare_int(I)
    else if V = float(F) then
        S = bare_float(F)
    else if V = bool(B) then
        S = bare_bool(B)
    else if V = time(T) then
        S = bare_int(utc_ns(T))
    else
        fail
    ).

lser_13_14_over_capacity(Decls, Interns, Series, Now, Schema, WM0, WM, Result,
        Cap, Reached) :-
    ( Result = inserted(NewId)
    ; Result = replaced(_, NewId)
    ),
    lookup_fact(WM, NewId, New),
    New ^ f_hydrated = live,
    list.filter_map(lser_13_14_decl_over(Interns, Series, Now, Schema, WM0,
        New), Decls, Hits),
    Hits = [{Cap, Reached} | _].

:- pred lser_13_14_decl_over(intern_table::in, series_state::in, instant::in,
                             schema::in, wm::in, fact::in, series_decl::in,
                             {uint32, uint64}::out) is semidet.

lser_13_14_decl_over(Interns, Series, Now, Schema, WM0, New, Decl,
        {Cap, Reached}) :-
    lser_13_14_refuses(Decl),
    interned(Interns, Decl ^ sd_schema, SchemaRef),
    schema_name_ref(Schema ^ s_name) = SchemaRef,
    slot_text_value(Interns, Schema, New, Decl ^ sd_slot, Value),
    identity_text(Interns, Schema, New, Decl ^ sd_id_slot, Id),
    Key = series_key(Decl ^ sd_schema, Decl ^ sd_slot, Decl ^ sd_id_slot, Id,
        Decl ^ sd_window),
    Retained = lser_13_14_retained(Key, Now, Series),
    Held0 = ( if held_value(Key, Series, _) then yes else no ),
    list.filter_map(lser_13_14_pending(Interns, Schema, Decl, Id),
        unabsorbed_of_schema(WM0, Schema ^ s_id), Readings),
    list.foldl2(lser_13_14_count(Decl), Readings, 0, Pending, Held0, Held1),
    % The arriving reading last: a null this backing would not absorb is no
    % sample, and is not refused.
    lser_13_14_absorbs(Decl, Value, Held1, _),
    Cap = Decl ^ sd_max,
    Retained + Pending >= uint32.cast_to_int(Cap),
    Reached = uint64.det_from_int(Retained + Pending + 1).

    % An unabsorbed fact's reading on this row: live, of the row's identity.
    %
:- pred lser_13_14_pending(intern_table::in, schema::in, series_decl::in,
                           string::in, fact::in, ds_value::out) is semidet.

lser_13_14_pending(Interns, Schema, Decl, Id, Fact, Value) :-
    Fact ^ f_hydrated = live,
    slot_text_value(Interns, Schema, Fact, Decl ^ sd_slot, Value),
    identity_text(Interns, Schema, Fact, Decl ^ sd_id_slot, Id).

:- pred lser_13_14_count(series_decl::in, ds_value::in, int::in, int::out,
                         bool::in, bool::out) is det.

lser_13_14_count(Decl, Value, !N, !Held) :-
    ( if lser_13_14_absorbs(Decl, Value, !.Held, Held) then
        !:N = !.N + 1,
        !:Held = Held
    else
        true
    ).

%-----------------------------------------------------------------------------%

latching(eff_event(se_engine_error(Err, _))) :-
    disposition(Err) = latched.

%-----------------------------------------------------------------------------%

fire(Ctx, Activation, Actions, Settle, Effects, !S, !T) :-
    Meta = Ctx ^ xc_rule,
    Fire = fire_id(Activation ^ ac_token ^ t_created, Meta ^ rm_name),
    Lhs = lhs_facts(Activation),

    rdsc_4a_8_2_1_guard_parts(Meta ^ rm_fire_guard, Condition, Gate),

    % The condition first, then the gate [RDSC.4a.8.2.2], [RDSC.4a.8.2.3]. A
    % maturity-guarded condition is read twice under one sample, which is harmless.
    CondVerdict = guard_verdict(Ctx, Activation, !.S, Condition),
    (
        CondVerdict = gv_admits,
        (
            Gate = yes(_),
            % A rate gate denies the actions, not the firing: the bracket stays,
            % around an empty body. Read here once, since it records the firing it
            % admits [LCDB.3.2.1].
            rhs_gate(Ctx, Activation, Gate, Verdict, !S),
            (
                Verdict = gv_admits,
                run_body(Ctx, Activation, Fire, Settle, Actions, Body0, !S,
                    !T),
                complete_activation(Settle, Body0, Body, !S, !T),
                Armed = ncbk_2_6_timer_armed(Ctx, Fire)
            ;
                % A suppressed firing arms nothing [NCBK.2.6].
                Verdict = gv_denies,
                Body = [],
                Armed = []
            ;
                % Inside the bracket, and it arms nothing.
                Verdict = gv_faulted(raised(Fault, Origin)),
                Body = [eff_event(se_engine_error(ee_expr_fault(Fault),
                    origin_site(activation_site(Ctx, Activation), Origin)))],
                Armed = []
            ),
            Effects = firing(Fire, Lhs, Body) ++ Armed
        ;
            Gate = no,
            run_body(Ctx, Activation, Fire, Settle, Actions, Body0, !S, !T),
            complete_activation(Settle, Body0, Body, !S, !T),
            Effects = firing(Fire, Lhs, Body)
                ++ ncbk_2_6_timer_armed(Ctx, Fire)
        )
    ;
        % A denied condition emits nothing at all: a withheld activation is not a
        % firing [RDSC.4a.8.2.2], [LTAC.4.2].
        CondVerdict = gv_denies,
        Effects = []
    ;
        % A faulted condition denies as a `false` one does, and the fault is the
        % stream's only word on this activation [LERR.1].
        CondVerdict = gv_faulted(raised(CondFault, CondOrigin)),
        Effects = [eff_event(se_engine_error(ee_expr_fault(CondFault),
            origin_site(guard_site(Ctx, Activation), CondOrigin)))]
    ).

:- type guard_verdict
    --->    gv_admits
    ;       gv_denies
    ;       gv_faulted(raised).

    % A fault in a guard evaluated at selection: the rule's terminal, and the
    % activation, which exists though it never fires, so it names its rule
    % [LERR.9.11].
    %
:- func guard_site(exec_ctx, activation) = fault_site.

guard_site(Ctx, Activation) =
    fault_site(yes(fire_of(Ctx, Activation)), no, no, no,
        yes(Activation ^ ac_terminal), no, no,
        fr_rule(Ctx ^ xc_rule ^ rm_name)).

    % The guard's two parts: the guard is a condition, a rate gate (told by its
    % callee, `fn_rate_allow`), or `e_binop(op_and, Condition, Gate)`.
    %
    %@spec [RDSC.4a.8.2.1]
:- pred rdsc_4a_8_2_1_guard_parts(maybe(expr)::in, maybe(expr)::out,
                                  maybe(expr)::out) is det.

rdsc_4a_8_2_1_guard_parts(no, no, no).
rdsc_4a_8_2_1_guard_parts(yes(Guard), Condition, Gate) :-
    ( if is_rate_gate(Guard) then
        Condition = no,
        Gate = yes(Guard)
    else if
        untainted(Guard) = e_binop(op_and, Left, Right),
        is_rate_gate(Right)
    then
        Condition = yes(Left),
        Gate = yes(Right)
    else
        Condition = yes(Guard),
        Gate = no
    ).

:- pred is_rate_gate(expr::in) is semidet.

is_rate_gate(E) :-
    untainted(E) = e_call(fn_rate_allow, _).

maturity_guarded(Meta) :-
    rdsc_4a_8_2_1_guard_parts(Meta ^ rm_fire_guard, Condition, _),
    Condition = yes(_).

check_guard(Ctx, Activation, S, Check) :-
    rdsc_4a_8_2_1_guard_parts(Ctx ^ xc_rule ^ rm_fire_guard, Condition, _),
    Verdict = guard_verdict(Ctx, Activation, S, Condition),
    (
        Verdict = gv_admits,
        Check = gc_admits
    ;
        Verdict = gv_denies,
        Check = gc_denies
    ;
        Verdict = gv_faulted(raised(Fault, Origin)),
        Check = gc_faulted([eff_event(se_engine_error(ee_expr_fault(Fault),
            origin_site(guard_site(Ctx, Activation), Origin)))])
    ).

    % Immediately after `fire_end`, for a firing the rate gate admits [RDSC.4a.8.2.3]:
    % the window and `now + window`, joined to its firing by timetag [NCBK.2.12].
    %
    %@spec [NCBK.2.6]
:- func ncbk_2_6_timer_armed(exec_ctx, fire_id) = list(effect).

ncbk_2_6_timer_armed(Ctx, Fire) = Effects :-
    ( if
        Ctx ^ xc_rule ^ rm_rate ^ rc_cooldown = yes(Window),
        duration_ns(Window) > 0u64
    then
        Now = Ctx ^ xc_now,
        Effects = [eff_event(se_timer_armed(Fire, Window, add(Now, Window)))]
    else
        Effects = []
    ).

    % The one place an expression is evaluated for its effect: `rate_allow(...)` records
    % the firing it admits, once per firing [LCDB.3.1], so only its arguments go through
    % `ds.eval`.
    %
:- pred rhs_gate(exec_ctx::in, activation::in, maybe(expr)::in,
                 guard_verdict::out, exec_state::in, exec_state::out) is det.

rhs_gate(Ctx, Activation, Guard, Verdict, !S) :-
    ( if Guard = yes(G), untainted(G) = e_call(fn_rate_allow, Args) then
        EvalCtx = eval_context(Ctx, Activation, !.S, empty_frame),
        ( if list.map(guard_arg(Ctx, Activation, !.S), Args, Values) then
            ( if
                not rdsc_4a_9_5_admits(fn_rate_allow, list.length(Values))
            then
                % [RDSC.4a.9.3], counted once the operands have evaluated.
                Verdict = gv_faulted(raised_in(G, EvalCtx, rf_artefact_lied))
            else
                rate_gate(Values, !.S ^ xs_interns, Ctx ^ xc_now, Gate,
                    !.S ^ xs_rate, Table),
                !S ^ xs_rate := Table,
                ( if allows(Gate) then
                    Verdict = gv_admits
                else
                    Verdict = gv_denies
                )
            )
        else if first_arg_fault(Args, EvalCtx, Raised) then
            % Denies the actions, stamps nothing, and is recorded.
            Verdict = gv_faulted(Raised)
        else
            Verdict = gv_denies
        )
    else
        Verdict = guard_verdict(Ctx, Activation, !.S, Guard)
    ).

    % The first argument that faults, other than `rf_unimplemented`, which
    % `guard_verdict` does not record either.
    %
:- pred first_arg_fault(list(expr)::in, eval_ctx::in, raised::out) is semidet.

first_arg_fault([E | Es], EvalCtx, Raised) :-
    eval(E, EvalCtx, Outcome),
    ( if Outcome = ev_fault(F), F \= rf_unimplemented then
        Raised = raised_in(E, EvalCtx, F)
    else
        first_arg_fault(Es, EvalCtx, Raised)
    ).

    % A guard argument's value. Fails on a fault, which denies the gate.
    %
:- pred guard_arg(exec_ctx::in, activation::in, exec_state::in, expr::in,
                  ds_value::out) is semidet.

guard_arg(Ctx, Activation, S, Arg, Value) :-
    eval(Arg, eval_context(Ctx, Activation, S, empty_frame), ev_ok(Value)).

:- pred run_body(exec_ctx::in, activation::in, fire_id::in,
                 settle_pred(T)::in(settle_pred), list(action)::in,
                 list(effect)::out,
                 exec_state::in, exec_state::out, T::in, T::out) is det.

run_body(Ctx, Activation, Fire, Settle, Actions, Body, !S, !T) :-
    % Marked for the length of the body, so the TMS can say whether an action ended
    % it [LLOG.15.1].
    begin_firing(Activation, !.S ^ xs_tms, TMS0),
    !S ^ xs_tms := TMS0,
    list.foldl4(run_and_settle(Ctx, Activation, Fire, Settle), Actions,
        [], Body, !S, !T, empty_frame, _),
    end_firing(!.S ^ xs_tms, TMS),
    !S ^ xs_tms := TMS.

    % Run one action, propagate what it did, and place the two (`place_settled`).
    %
:- pred run_and_settle(exec_ctx::in, activation::in, fire_id::in,
                       settle_pred(T)::in(settle_pred), action::in,
                       list(effect)::in, list(effect)::out,
                       exec_state::in, exec_state::out, T::in, T::out,
                       bind_frame::in, bind_frame::out) is det.

run_and_settle(Ctx, Activation, Fire, Settle, Action, !Acc, !S, !T, !Frame) :-
    ( if
        !.S ^ xs_capped = bool.yes
    then
        true
    else if
        % [LERR.1.4.7]: an earlier action, or what its fact change caused, raised an
        % EngineError.
        list.find_first_match(latching, !.Acc, _)
    then
        true
    else
        run_action(Ctx, Activation, Fire, Action, !Frame, empty_log, Log, !S),
        Own = log_effects(Log),
        place_settled(Settle, Own, !Acc, !S, !T),
        llog_15_1_justify_settled(Settle, !Acc, !S, !T)
    ).

    % A match that ends inside its own firing justifies nothing after [LLOG.15.1],
    % [IRET.12.2]. The action's `logical` facts are justified once it has settled: by
    % the firing activation while it stands; otherwise each new fact no other
    % justification holds is retracted, after the action's records and cascade
    % [RFCS.7a.4]. A node cap that put the engine back dropped the deferral too.
    %
:- pred llog_15_1_justify_settled(settle_pred(T)::in(settle_pred),
                                  list(effect)::in, list(effect)::out,
                                  exec_state::in, exec_state::out,
                                  T::in, T::out) is det.

llog_15_1_justify_settled(Settle, !Acc, !S, !T) :-
    ( if !.S ^ xs_capped = bool.yes then
        drop_deferred(!.S ^ xs_tms, TMS),
        !S ^ xs_tms := TMS
    else
        resolve_deferred(Unjustified, !.S ^ xs_tms, TMS),
        !S ^ xs_tms := TMS,
        list.foldl3(retract_unjustified(Settle), Unjustified, !Acc, !S, !T)
    ).

:- pred retract_unjustified(settle_pred(T)::in(settle_pred), fact_id::in,
                            list(effect)::in, list(effect)::out,
                            exec_state::in, exec_state::out,
                            T::in, T::out) is det.

retract_unjustified(Settle, Fact, !Acc, !S, !T) :-
    retract_one(Fact, rc_justifier_end, empty_log, Log, !S),
    list.foldl3(settle_removal(Settle), log_effects(Log), !Acc, !S, !T).

    % Settle one action's effects and place them with what they caused. An assert's
    % cascade goes first [RARC.5.6.8]. An action of removals only goes removal by
    % removal, each followed by its own cascade [RFCS.7a.4], [LFST.7.3.6]. An action
    % that also asserts keeps the cascade first [RFCS.6a.4].
    %
:- pred place_settled(settle_pred(T)::in(settle_pred), list(effect)::in,
                      list(effect)::in, list(effect)::out,
                      exec_state::in, exec_state::out, T::in, T::out) is det.

place_settled(Settle, Own, !Acc, !S, !T) :-
    ( if Own = [_ | _], list.all_true(rfcs_7a_4_removal, Own) then
        list.foldl3(settle_removal(Settle), Own, !Acc, !S, !T)
    else
        Settle(Own, Kept, Cascade, !S, !T),
        !:Acc = !.Acc ++ Cascade ++ Kept
    ).

:- pred settle_removal(settle_pred(T)::in(settle_pred), effect::in,
                       list(effect)::in, list(effect)::out,
                       exec_state::in, exec_state::out, T::in, T::out) is det.

settle_removal(Settle, Removal, !Acc, !S, !T) :-
    Settle([Removal], Kept, Cascade, !S, !T),
    !:Acc = !.Acc ++ Kept ++ Cascade.

    %@spec [RFCS.7a.4]
:- pred rfcs_7a_4_removal(effect::in) is semidet.

rfcs_7a_4_removal(eff_event(se_fact_withdraw(_, _))).
rfcs_7a_4_removal(eff_event(se_fact_retract(_))).

    % The synchronous end of the RHS is a completion path [LSCP.3.1], [LSCP.3.2],
    % unless the firing began an async tail, known by the token facts it asserted: an
    % `after` timer [LTAC.3.1], a capture [LCCO.5.2], a timeout timer [LCCO.7]. Then the
    % activation's facts attach to those (`discharge_attached`). Inside the frame,
    % settled like an action. A `call` with continuations, no timeout and no capture
    % asserts no token fact, so its facts go at the synchronous end.
    %
:- pred complete_activation(settle_pred(T)::in(settle_pred),
                            list(effect)::in, list(effect)::out,
                            exec_state::in, exec_state::out, T::in, T::out)
    is det.

complete_activation(Settle, !Body, !S, !T) :-
    Pending = list.reverse(!.S ^ xs_act_pending),
    Tokens = !.S ^ xs_act_tokens,
    !S ^ xs_act_pending := [],
    !S ^ xs_act_tokens := [],
    ( if
        % [LERR.1.4.7]: its facts are forgotten, neither retracted nor attached.
        list.find_first_match(latching, !.Body, _)
    then
        true
    else if
        Pending = []
    then
        true
    else
        (
            Tokens = [],
            list.foldl2(retract_completed, Pending, empty_log, Log, !S),
            Own = log_effects(Log),
            place_settled(Settle, Own, !Body, !S, !T)
        ;
            Tokens = [_ | _],
            list.foldl(attach_pending(Pending), Tokens,
                !.S ^ xs_act_attach, Attach),
            !S ^ xs_act_attach := Attach
        )
    ).

:- pred retract_completed(fact_id::in, effect_log::in, effect_log::out,
                          exec_state::in, exec_state::out) is det.

retract_completed(FactId, !Log, !S) :-
    retract_one(FactId, rc_activation_completed, !Log, !S).

:- pred attach_pending(list(fact_id)::in, fact_id::in,
                       map(uint64, list(fact_id))::in,
                       map(uint64, list(fact_id))::out) is det.

attach_pending(Pending, Token, !Attach) :-
    Key = fact_id_value(Token),
    ( if map.search(!.Attach, Key, Already) then
        map.set(Key, Already ++ Pending, !Attach)
    else
        map.set(Key, Pending, !Attach)
    ).

    % A token fact has left working memory, for any cause: the activation facts waiting
    % on it are retracted, idempotently [LSCP.3.3]. Called after `retract_one` of the
    % token, so they settle with that action's effects.
    %
:- pred discharge_attached(fact_id::in, effect_log::in, effect_log::out,
                           exec_state::in, exec_state::out) is det.

discharge_attached(Token, !Log, !S) :-
    Key = fact_id_value(Token),
    ( if map.search(!.S ^ xs_act_attach, Key, Attached) then
        !S ^ xs_act_attach := map.delete(!.S ^ xs_act_attach, Key),
        list.foldl2(retract_completed, Attached, !Log, !S)
    else
        true
    ).

:- pred note_activation_fact(schema::in, fact_id::in,
                             exec_state::in, exec_state::out) is det.

note_activation_fact(Schema, FactId, !S) :-
    ( if Schema ^ s_lifecycle = lc_activation(_) then
        !S ^ xs_act_pending := [FactId | !.S ^ xs_act_pending]
    else if synthetic(!.S ^ xs_interns, Schema) then
        !S ^ xs_act_tokens := [FactId | !.S ^ xs_act_tokens]
    else
        true
    ).

:- func lhs_facts(activation) = maybe(list(fact_id)).

lhs_facts(Activation) = Lhs :-
    Facts = Activation ^ ac_token ^ t_facts,
    (
        Facts = [],
        Lhs = no
    ;
        Facts = [_ | _],
        Lhs = yes(Facts)
    ).

:- func guard_verdict(exec_ctx, activation, exec_state, maybe(expr))
    = guard_verdict.

guard_verdict(_, _, _, no) = gv_admits.
guard_verdict(Ctx, Activation, S, yes(Guard)) = Verdict :-
    EvalCtx = eval_context(Ctx, Activation, S, empty_frame),
    eval(Guard, EvalCtx, Outcome),
    ( if Outcome = ev_fault(rf_unimplemented) then
        % A guard this runtime cannot evaluate fails open. `ds.dsc` does not refuse a
        % bundle for its guards.
        Verdict = gv_admits
    else if Outcome = ev_fault(Fault) then
        Verdict = gv_faulted(raised_in(Guard, EvalCtx, Fault))
    else if admits(Outcome) then
        Verdict = gv_admits
    else
        Verdict = gv_denies
    ).

:- func eval_context(exec_ctx, activation, exec_state, bind_frame) = eval_ctx.

eval_context(Ctx, Activation, S, Frame) =
    eval_ctx(Activation ^ ac_token ^ t_facts, no, S ^ xs_wm,
        Ctx ^ xc_schemas, S ^ xs_interns, Ctx ^ xc_now, Ctx ^ xc_wall, Frame,
        S ^ xs_cache, S ^ xs_series).

    % `let` slots to their bound values, for one firing [IRET.9.4]: threaded through
    % the action fold, not engine state.
    %
:- type bind_frame == map(int, ds_value).

:- func empty_frame = bind_frame.

empty_frame = map.init.

%-----------------------------------------------------------------------------%
% The verbs
%-----------------------------------------------------------------------------%

:- pred run_action(exec_ctx::in, activation::in, fire_id::in, action::in,
                   bind_frame::in, bind_frame::out,
                   effect_log::in, effect_log::out,
                   exec_state::in, exec_state::out) is det.

run_action(Ctx, Activation, Fire, Action, !Frame, !Log, !S) :-
    (
        Action = a_emit(SchemaId, Slots, Mode, Retain),
        assert_verb(Ctx, Activation, Fire, SchemaId, Slots, Mode, Retain, !.Frame,
            !Log, !S)
    ;
        Action = a_publish(SchemaId, Slots),
        publish_verb(Ctx, Activation, SchemaId, Slots, !.Frame, !Log, !S)
    ;
        Action = a_call(Service, Correlation, Kwargs, Gate),
        call_verb(Ctx, Activation, Fire, Service, Correlation, Kwargs,
            Gate, !.Frame, !Log, !S)
    ;
        Action = a_cache_set(KeyExpr, ValueExpr, TtlExpr),
        cache_set_verb(Ctx, Activation, KeyExpr, ValueExpr, TtlExpr, !.Frame, !Log, !S)
    ;
        Action = a_cache_delete(KeyExpr),
        cache_delete_verb(Ctx, Activation, KeyExpr, !.Frame, !Log, !S)
    ;
        Action = a_log(Level, Message),
        message_verb(Ctx, Activation, Message,
            (func(Text) = se_log_emitted(Level, Text)),
            a_log(Level, Message), !.Frame, !Log, !S)
    ;
        Action = a_bind(Ix, Bound),
        % The one step that writes the frame [IRET.9.4]. `FN_GENSYM` is answered here,
        % since it interns and advances a counter; the compiler emits it only as a
        % whole bind's expression [LTAC.3.5].
        ( if Bound = e_call(fn_gensym, []) then
            gensym(Generated, !S),
            map.set(bind_index_int(Ix), Generated, !Frame)
        else
            BindCtx = eval_context(Ctx, Activation, !.S, !.Frame),
            eval(Bound, BindCtx, Outcome),
            (
                Outcome = ev_ok(V),
                map.set(bind_index_int(Ix), V, !Frame)
            ;
                Outcome = ev_fault(Fault),
                abandon(Ctx, Activation, raised_in(Bound, BindCtx, Fault),
                    !Log, !S)
            )
        )
    ;
        Action = a_retract_token_fact(Args),
        retract_token_fact(Ctx, Activation, Args, !.Frame, !Log, !S)
    ;
        Action = a_retract_corr(Args),
        retract_corr(Ctx, Activation, Args, !.Frame, !Log, !S)
    ;
        Action = a_withdraw(Position),
        iret_10_5_withdraw(Ctx, Activation, Position, !Log, !S)
    ;
        Action = a_withdraw_by_id(FactExpr),
        iret_10_7_withdraw_by_id(Ctx, Activation, FactExpr, !.Frame, !Log, !S)
    ;
        Action = a_hydration_call(Target, Correlation, Service, Body, Gate),
        hydration_call(Ctx, Activation, Fire, Target, Correlation, Service,
            Body, Gate, !.Frame, !Log, !S)
    ;
        Action = a_operands_not_admitted(Fn, Args, Gate),
        rdsc_4a_9_3_not_admitted(Ctx, Activation, Fn, Args, Gate, !.Frame,
            !Log, !S)
    ).

    % A verb or a mechanism whose operands its op does not admit:
    % `ENGINE_FAULT_ARTEFACT_LIED`, which halts the tier. A per-call gate runs first, and
    % one that denies means the call is never reached; then the operands are evaluated,
    % and a fault among them is raised instead [LNUL.4.10].
    %
    %@spec [RDSC.4a.9.3]
:- pred rdsc_4a_9_3_not_admitted(exec_ctx::in, activation::in, builtin_fn::in,
                                 list(expr)::in, maybe(list(expr))::in,
                                 bind_frame::in,
                                 effect_log::in, effect_log::out,
                                 exec_state::in, exec_state::out) is det.

rdsc_4a_9_3_not_admitted(Ctx, Activation, Fn, Args, Gate, Frame, !Log, !S) :-
    (
        Gate = yes(GateArgs),
        rhs_gate(Ctx, Activation, yes(e_call(fn_rate_allow, GateArgs)),
            GateVerdict, !S)
    ;
        Gate = no,
        GateVerdict = gv_admits
    ),
    (
        GateVerdict = gv_denies
    ;
        GateVerdict = gv_faulted(GateFault),
        abandon(Ctx, Activation, GateFault, !Log, !S)
    ;
        GateVerdict = gv_admits,
        EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
        Call = e_call(Fn, Args),
        eval_all(Args, EvalCtx, Operands),
        (
            Operands = evs_fault(Fault),
            abandon(Ctx, Activation, raised_in(Call, EvalCtx, Fault), !Log, !S)
        ;
            Operands = evs_ok(_),
            abandon(Ctx, Activation,
                raised_in(Call, EvalCtx, rf_artefact_lied), !Log, !S)
        )
    ).

    % The string `g<N>`, interned, with the engine's counter advanced.
    %
:- pred gensym(ds_value::out, exec_state::in, exec_state::out) is det.

gensym(str(Ref), !S) :-
    N = !.S ^ xs_gensym,
    intern("g" ++ string.int_to_string(N), Ref, !.S ^ xs_interns, Interns),
    !S ^ xs_interns := Interns,
    !S ^ xs_gensym := N + 1.

%-----------------------------------------------------------------------------%
% The mechanisms
%-----------------------------------------------------------------------------%
%
% Not author-written: the compiler emits each beside the construct it implements.
% Every argument is checked before anything happens, and a shape mismatch does
% nothing.

    % [LERR.1]: a fault in an action abandons the activation. The event goes on the
    % stream where it happened, and `xs_capped` stops the actions after it. Each verb
    % checks its arguments with `first_fault` first, so no partial effect escapes.
    %
:- pred abandon(exec_ctx::in, activation::in, raised::in,
                effect_log::in, effect_log::out,
                exec_state::in, exec_state::out) is det.

abandon(Ctx, Activation, raised(Fault, Origin), !Log, !S) :-
    emit_event(se_engine_error(ee_expr_fault(Fault),
        origin_site(activation_site(Ctx, Activation), Origin)), !Log),
    !S ^ xs_capped := bool.yes.

origin_site(Site, fault_origin(Fact, Schema, Slot, Actual)) =
    (((Site ^ fs_fact := Fact) ^ fs_schema := Schema) ^ fs_slot := Slot)
        ^ fs_actual := Actual.

:- func fire_of(exec_ctx, activation) = fire_id.

fire_of(Ctx, Activation) =
    fire_id(Activation ^ ac_token ^ t_created, Ctx ^ xc_rule ^ rm_name).

    % A fault in a firing: its activation, and the rule's terminal as the node.
    %
:- func activation_site(exec_ctx, activation) = fault_site.

activation_site(Ctx, Activation) =
    fault_site(yes(fire_of(Ctx, Activation)), no, no, no,
        yes(Activation ^ ac_terminal), no, no,
        fr_rule(Ctx ^ xc_rule ^ rm_name)).

:- func slot_site(exec_ctx, activation, schema, int) = fault_site.

slot_site(Ctx, Activation, Schema, Index) =
    ( activation_site(Ctx, Activation)
        ^ fs_schema := yes(schema_name_ref(Schema ^ s_name)) )
        ^ fs_slot := slot_name_at(Schema, Index).

    % The slot refusals that are a TypeError in a rule's action: a kind the declared type
    % does not accept, `null` into a slot not `T?` [LNUL.3.1], a NaN [LEXP.4.2]. The
    % others keep `ee_slot_invalid`.
    %
    %@spec [RARC.5.2.7]
:- pred rarc_5_2_7_type_error(slot_reason::in) is semidet.

rarc_5_2_7_type_error(Reason) :-
    rarc_5_2_7_is_type_error(Reason) = yes.

    %@helper
:- func rarc_5_2_7_is_type_error(slot_reason) = bool.

rarc_5_2_7_is_type_error(sr_kind_mismatch) = yes.
rarc_5_2_7_is_type_error(sr_null_non_nullable) = yes.
rarc_5_2_7_is_type_error(sr_nan_rejected) = yes.
rarc_5_2_7_is_type_error(sr_json_nonfinite) = no.
rarc_5_2_7_is_type_error(sr_json_limit(_)) = no.

    % A slot value `Schema` refused, with no firing to name.
    %
:- func schema_slot_site(schema, int) = fault_site.

schema_slot_site(Schema, Index) =
    ( no_site ^ fs_schema := yes(schema_name_ref(Schema ^ s_name)) )
        ^ fs_slot := slot_name_at(Schema, Index).

    % A `wm_max` breach: the cap and the candidate memory's live count. No activation
    % and no node.
    %
:- func wm_breach_site(exec_ctx, wm) = fault_site.

wm_breach_site(Ctx, WM) = no_site ^ fs_bound := Bound :-
    ( if Ctx ^ xc_contract = yes(RT) then
        Bound = yes(fault_bound(
            uint64.det_from_int(uint32.cast_to_int(RT ^ c_wm_max)),
            uint64.det_from_int(
                lerr_9_10_capacity_count(WM, Ctx ^ xc_fault_schemas))))
    else
        Bound = no
    ).

    % A cache-cap breach, in a firing: the cap and the size the refused write would
    % have reached.
    %
:- func cache_breach_site(exec_ctx, activation, cache_caps, cap, cache)
    = fault_site.

cache_breach_site(Ctx, Activation, Caps, Cap, After) =
        activation_site(Ctx, Activation) ^ fs_bound := Bound :-
    ( if Cap = cap_cache then
        Bound = yes(fault_bound(
            uint64.det_from_int(uint32.cast_to_int(Caps ^ cc_keys)),
            uint64.det_from_int(cache_size(After))))
    else if Cap = cap_cache_bytes then
        Bound = yes(fault_bound(Caps ^ cc_bytes,
            uint64.det_from_int(cache_bytes(After))))
    else
        Bound = no
    ).

    % The first fault among an action's argument expressions, in wire order. Evaluation
    % is pure, so a verb that got past this cannot then meet a fault.
    %
:- func first_fault(eval_ctx, list(expr)) = maybe(raised).

first_fault(_, []) = no.
first_fault(EvalCtx, [E | Es]) = Found :-
    ( if expr_fault(EvalCtx, E, Fault) then
        Found = yes(raised_in(E, EvalCtx, Fault))
    else
        Found = first_fault(EvalCtx, Es)
    ).

    % The first argument with no JSON spelling, in a position that renders JSON: a
    % non-finite Float, a fact reference, a Ratio. Runs after `first_fault`. A `null` is
    % not one [LNUL.11.1].
    %
:- func first_unrepresentable(eval_ctx, list(expr)) = maybe(raised).

first_unrepresentable(_, []) = no.
first_unrepresentable(EvalCtx, [E | Es]) = Found :-
    ( if
        not interpolation(E),
        eval(E, EvalCtx, ev_ok(V)),
        no_json_spelling(V)
    then
        Found = yes(raised_in(E, EvalCtx, rf_not_representable))
    else
        Found = first_unrepresentable(EvalCtx, Es)
    ).

    % `first_unrepresentable` for a cached value, which a `Bytes` value fails too
    % [IDSP.13.4].
    %
:- func first_uncacheable(eval_ctx, list(expr)) = maybe(raised).

first_uncacheable(_, []) = no.
first_uncacheable(EvalCtx, [E | Es]) = Found :-
    ( if
        not interpolation(E),
        eval(E, EvalCtx, ev_ok(V)),
        ( no_json_spelling(V)
        ; V = bytes(_)
        )
    then
        Found = yes(raised_in(E, EvalCtx, rf_not_representable))
    else
        Found = first_uncacheable(EvalCtx, Es)
    ).

:- func first_raised(maybe(raised), maybe(raised)) = maybe(raised).

first_raised(yes(R), _) = yes(R).
first_raised(no, Second) = Second.

:- pred no_json_spelling(ds_value::in) is semidet.

no_json_spelling(float(F)) :- float.is_nan_or_inf(F).
no_json_spelling(json(J)) :- not json_text(J, _).
no_json_spelling(fact_ref(_)).
no_json_spelling(ratio(_, _)).

:- type raised
    --->    raised(
                rd_fault  :: runtime_fault,
                rd_origin :: fault_origin
            ).

:- func raised_in(expr, eval_ctx, runtime_fault) = raised.

raised_in(E, EvalCtx, Fault) = raised(Fault, fault_origin(E, EvalCtx, Fault)).

:- pred expr_fault(eval_ctx::in, expr::in, runtime_fault::out) is semidet.

expr_fault(EvalCtx, E, Fault) :-
    ( if interpolation(E) then
        eval_text(E, EvalCtx, text_fault(Fault))
    else
        eval(E, EvalCtx, ev_fault(Fault))
    ).

    % `FN_RETRACT_TOKEN_FACT(pattern_index)`: the fact bound at that LHS position in the
    % firing token, retracted. Out of range is a no-op. Without this an `after` follow-up
    % re-fires on every tick.
    %
:- pred retract_token_fact(exec_ctx::in, activation::in, list(expr)::in,
                           bind_frame::in, effect_log::in, effect_log::out,
                           exec_state::in, exec_state::out) is det.

retract_token_fact(Ctx, Activation, Args, Frame, !Log, !S) :-
    EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
    ( if first_fault(EvalCtx, Args) = yes(Fault) then
        abandon(Ctx, Activation, Fault, !Log, !S)
    else if
        Args = [IndexExpr | _],
        eval(IndexExpr, EvalCtx, ev_ok(int(Index))),
        Facts = Activation ^ ac_token ^ t_facts,
        % On the `int64`, before the cast, so a large index cannot wrap into range
        % on a 32-bit host.
        Index >= 0i64,
        Index < int64.from_int(list.length(Facts)),
        list.index0(Facts, int64.cast_to_int(Index), FactId)
    then
        retract_one(FactId, rc_synthetic_discharged, !Log, !S),
        % The completion path it was resolves [LSCP.3.1].
        discharge_attached(FactId, !Log, !S)
    else
        true
    ).

    % `withdraw <binding>` [IRET.10.5]. A position outside the token is an EngineError,
    % PATTERN_INDEX, and the tier halts [RDSC.4a.9.1], [RARC.5.3.3].
    %
:- pred iret_10_5_withdraw(exec_ctx::in, activation::in, int::in,
                           effect_log::in, effect_log::out,
                           exec_state::in, exec_state::out) is det.

iret_10_5_withdraw(Ctx, Activation, Position, !Log, !S) :-
    ( if list.index0(Activation ^ ac_token ^ t_facts, Position, FactId) then
        retract_one(FactId, rc_author_withdrawn, !Log, !S)
    else
        abandon(Ctx, Activation, raised(rf_pattern_index, no_origin), !Log, !S)
    ).

    % `withdraw <binding>` in a nested body [IRET.10.7]: the expression reads the fact
    % reference the capture fact took when the outer rule fired. A fault abandons the
    % activation; a value that is not a reference does nothing.
    %
:- pred iret_10_7_withdraw_by_id(exec_ctx::in, activation::in, expr::in,
                                 bind_frame::in,
                                 effect_log::in, effect_log::out,
                                 exec_state::in, exec_state::out) is det.

iret_10_7_withdraw_by_id(Ctx, Activation, FactExpr, Frame, !Log, !S) :-
    EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
    eval(FactExpr, EvalCtx, Outcome),
    (
        Outcome = ev_ok(Value),
        ( if Value = fact_ref(FactId) then
            retract_one(FactId, rc_author_withdrawn, !Log, !S)
        else
            true
        )
    ;
        Outcome = ev_fault(Fault),
        abandon(Ctx, Activation, raised_in(FactExpr, EvalCtx, Fault), !Log, !S)
    ).

    % `FN_RETRACT_CORR(schema_name, slot_name, corr)`: every live fact of that schema
    % whose named slot equals that correlation, gone [IDSP.6.7].
    %
:- pred retract_corr(exec_ctx::in, activation::in, list(expr)::in,
                     bind_frame::in, effect_log::in, effect_log::out,
                     exec_state::in, exec_state::out) is det.

retract_corr(Ctx, Activation, Args, Frame, !Log, !S) :-
    EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
    ( if first_fault(EvalCtx, Args) = yes(Fault) then
        abandon(Ctx, Activation, Fault, !Log, !S)
    else if
        Args = [SchemaExpr, SlotExpr, CorrExpr | _],
        eval(SchemaExpr, EvalCtx, ev_ok(SchemaV)),
        string_ref(!.S ^ xs_interns, SchemaV, SchemaRef),
        eval(SlotExpr, EvalCtx, ev_ok(SlotV)),
        string_ref(!.S ^ xs_interns, SlotV, SlotRef),
        eval(CorrExpr, EvalCtx, ev_ok(CorrV)),
        lrst_1_4_stored_key(!.S ^ xs_interns, CorrV, Key)
    then
        corr_sweep(Ctx, SchemaRef, SlotRef, Key, !Log, !S)
    else
        true
    ).

    % A correlation key [LRST.1.4] as a slot would hold it. Fails on a computed string
    % the table has never seen, which is in no slot.
    %
:- pred lrst_1_4_stored_key(intern_table::in, ds_value::in, ds_value::out)
    is semidet.

lrst_1_4_stored_key(IT, V, Key) :-
    ( if V = text(S) then
        interned(IT, S, Ref),
        Key = str(Ref)
    else
        Key = stored_value(V)
    ).

    % The sweep. An absent key, a schema or a slot that does not resolve sweeps nothing.
    %
:- pred corr_sweep(exec_ctx::in, intern_ref::in, intern_ref::in, ds_value::in,
                   effect_log::in, effect_log::out,
                   exec_state::in, exec_state::out) is det.

corr_sweep(Ctx, SchemaRef, SlotRef, Key, !Log, !S) :-
    ( if
        not lrst_1_4_absent_key(!.S ^ xs_interns, Key),
        find_schema_by_name(Ctx ^ xc_schemas, SchemaRef, Schema),
        slot_by_name(Schema, SlotRef, Slot)
    then
        Victims = list.filter(slot_holds_key(Slot ^ sc_index, Key),
            facts_of_schema(!.S ^ xs_wm, Schema ^ s_id)),
        list.foldl2(retract_victim, Victims, !Log, !S)
    else
        true
    ).

lcrs_6_2_4_arrival_victims(Schemas, Interns, Responses, Schema, Values, WM)
        = Victims :-
    ( if
        interned(Interns, "corr", CorrSlot),
        slot_by_name(Schema, CorrSlot, Slot),
        list.index0(Values, slot_index_int(Slot ^ sc_index), str(CorrRef)),
        expand(Interns, CorrRef, Corr),
        Corr \= "",
        arrival_targets(Schemas, Interns, Responses, Schema, Targets)
    then
        Victims = list.condense(list.map(
            corr_victims(CorrSlot, str(CorrRef), WM), Targets))
    else
        Victims = []
    ).

    % The schemas an arriving answer sweeps, in sweep order. Fails for a schema that is
    % not an answer. `CallError` may be absent from the intern table, and a response
    % schema's answer still supersedes.
    %
:- pred arrival_targets(map(uint32, schema)::in, intern_table::in,
    list(schema)::in, schema::in, list(schema)::out) is semidet.

arrival_targets(Schemas, Interns, Responses, Schema, Targets) :-
    ( if
        interned(Interns, "CallError", CallErrorName),
        schema_name_ref(Schema ^ s_name) = CallErrorName
    then
        % A `CallError` names no service [LCRS.4.2.1].
        Targets = [Schema | Responses]
    else
        list.find_first_match(
            ( pred(R::in) is semidet :- R ^ s_id = Schema ^ s_id ),
            Responses, _),
        ( if
            interned(Interns, "CallError", Name),
            find_schema_by_name(Schemas, Name, CallError)
        then
            Targets = [Schema, CallError]
        else
            Targets = [Schema]
        )
    ).

    % One target schema's live facts whose `corr` slot holds `Corr`.
    %
:- func corr_victims(intern_ref, ds_value, wm, schema) = list(fact_id).

corr_victims(CorrSlot, Corr, WM, Target) = Ids :-
    ( if slot_by_name(Target, CorrSlot, Slot) then
        Ids = list.map((func(F) = F ^ f_id),
            list.filter(slot_holds_key(Slot ^ sc_index, Corr),
                facts_of_schema(WM, Target ^ s_id)))
    else
        Ids = []
    ).

    % A key meaning "no supersedure": only `""`, since a clause with no `as` lowers to it
    % and `hydrated_corr` defaults to it [RHIM.2.4]. `0` and `false` are ordinary keys.
    %
:- pred lrst_1_4_absent_key(intern_table::in, ds_value::in) is semidet.

lrst_1_4_absent_key(IT, str(Ref)) :-
    expand(IT, Ref, "").

:- pred retract_victim(fact::in, effect_log::in, effect_log::out,
                       exec_state::in, exec_state::out) is det.

retract_victim(Fact, !Log, !S) :-
    retract_one(Fact ^ f_id, rc_supersede, !Log, !S),
    discharge_attached(Fact ^ f_id, !Log, !S).

    %@spec [LRST.1.4]
:- pred slot_holds_key(slot_index::in, ds_value::in, fact::in) is semidet.

slot_holds_key(Index, Key, Fact) :-
    array.semidet_lookup(Fact ^ f_slots, slot_index_int(Index), Held),
    lrst_1_4_key_eq(Held, Key).

    % Content equality between two stored keys, kinds agreeing. A `float` compares as
    % IEEE `==`: `-0.0` and `0.0` are one key, and a NaN is none. Any other value matches
    % nothing.
    %
    %@spec [LRST.1.4]
:- pred lrst_1_4_key_eq(ds_value::in, ds_value::in) is semidet.

lrst_1_4_key_eq(Held, Key) :-
    (
        Held = int(A), Key = int(B),
        A = B
    ;
        Held = float(A), Key = float(B),
        A =< B, B =< A
    ;
        Held = bool(A), Key = bool(B),
        A = B
    ;
        Held = str(A), Key = str(B),
        A = B
    ;
        Held = bytes(A), Key = bytes(B),
        A = B
    ).

    % Remove a fact and say so, or nothing if it is gone. The event is what propagates
    % it: `ds.engine.settle_effect` reads it back.
    %
:- pred retract_one(fact_id::in, retract_cause::in,
                    effect_log::in, effect_log::out,
                    exec_state::in, exec_state::out) is det.

retract_one(FactId, Cause, !Log, !S) :-
    ( if retract_fact(FactId, Cause, !.S ^ xs_wm, WM) then
        !S ^ xs_wm := WM,
        emit_event(removal_event(FactId, Cause), !Log)
    else
        true
    ).

:- pred find_schema_by_name(map(uint32, schema)::in, intern_ref::in,
                            schema::out) is semidet.

find_schema_by_name(Schemas, Name, Schema) :-
    Match = (pred(S::in) is semidet :- schema_name_ref(S ^ s_name) = Name),
    list.find_first_match(Match, map.values(Schemas), Schema).

%-----------------------------------------------------------------------------%

    % `FN_HYDRATION_CALL(target_schema, corr, svc, body_json)`, deferred, and refused at
    % load: `FN_HYDRATION_CALL` is a `none` row of [RDSC.4a.9.5]. It does not dispatch.
    % The cooldown [LHYD.11.2] runs first; over budget [LHYD.7.4] it asserts a `CallError`;
    % otherwise it runs the supersede sweeps [LHYD.6.3.1].
    %
:- pred hydration_call(exec_ctx::in, activation::in, fire_id::in,
                       intern_ref::in, correlation::in, intern_ref::in,
                       kwargs::in, maybe(list(expr))::in, bind_frame::in,
                       effect_log::in, effect_log::out,
                       exec_state::in, exec_state::out) is det.

hydration_call(Ctx, Activation, Fire, Target, Correlation, Service, Kwargs,
        Gate, Frame, !Log, !S) :-
    (
        Gate = yes(GateArgs),
        rhs_gate(Ctx, Activation, yes(e_call(fn_rate_allow, GateArgs)),
            GateVerdict, !S)
    ;
        Gate = no,
        GateVerdict = gv_admits
    ),
    (
        GateVerdict = gv_denies
    ;
        GateVerdict = gv_faulted(GateFault),
        abandon(Ctx, Activation, GateFault, !Log, !S)
    ;
        GateVerdict = gv_admits,
        hydration_call_admitted(Ctx, Activation, Fire, Target, Correlation,
            Service, Kwargs, Gate, Frame, !Log, !S)
    ).

:- pred hydration_call_admitted(exec_ctx::in, activation::in, fire_id::in,
                       intern_ref::in, correlation::in, intern_ref::in,
                       kwargs::in, maybe(list(expr))::in, bind_frame::in,
                       effect_log::in, effect_log::out,
                       exec_state::in, exec_state::out) is det.

hydration_call_admitted(Ctx, Activation, Fire, Target, Correlation, Service,
        Kwargs, Gate, Frame, !Log, !S) :-
    EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
    resolve_correlation(EvalCtx, Correlation, Resolved, !S),
    ( if
        first_raised(
            first_fault(EvalCtx, correlation_exprs(Correlation) ++
                assoc_list.values(kwarg_list(Kwargs))),
            first_unrepresentable(EvalCtx,
                assoc_list.values(kwarg_list(Kwargs))))
            = yes(Fault)
    then
        abandon(Ctx, Activation, Fault, !Log, !S)
    else if
        Resolved = yes(Corr),
        call_body(EvalCtx, kwarg_list(Kwargs), Body)
    then
        CorrRef = correlation_ref(!.S ^ xs_interns, Corr),
        ( if hydrated_count(Ctx, !.S) >= Ctx ^ xc_hydration_budget then
            % `ts` reads the wall sample as `now()` does [LTIM.2.8.3].
            MaybeWall = Ctx ^ xc_wall,
            (
                MaybeWall = yes(Wall),
                assert_call_error(Ctx, CorrRef, "budget_exhausted",
                    "hydration global budget exceeded (LHYD.7.4)", Wall,
                    !Log, !S)
            ;
                MaybeWall = no,
                abandon(Ctx, Activation, raised(rf_domain, no_origin), !Log,
                    !S)
            )
        else
            sweep_by_ref(Ctx, Target, "hydrated_corr", CorrRef, !Log, !S),
            sweep_by_name(Ctx, "HydrationComplete", "corr", CorrRef, !Log, !S),
            _ = Fire, _ = Service, _ = Body, _ = Kwargs, _ = Gate
        )
    else
        true
    ).

:- func correlation_ref(intern_table, correlation) = intern_ref.

correlation_ref(_, correlated(Ref)) = Ref.
correlation_ref(IT, correlated_expr(_)) = empty_ref(IT).

    % A sweep whose slot is named by literal text, looked up without being added.
    %
:- pred sweep_by_ref(exec_ctx::in, intern_ref::in, string::in, intern_ref::in,
                     effect_log::in, effect_log::out,
                     exec_state::in, exec_state::out) is det.

sweep_by_ref(Ctx, SchemaRef, SlotName, CorrRef, !Log, !S) :-
    ( if interned(!.S ^ xs_interns, SlotName, SlotRef) then
        corr_sweep(Ctx, SchemaRef, SlotRef, str(CorrRef), !Log, !S)
    else
        true
    ).

    % The same, with the schema named by literal text too.
    %
:- pred sweep_by_name(exec_ctx::in, string::in, string::in, intern_ref::in,
                      effect_log::in, effect_log::out,
                      exec_state::in, exec_state::out) is det.

sweep_by_name(Ctx, SchemaName, SlotName, CorrRef, !Log, !S) :-
    ( if interned(!.S ^ xs_interns, SchemaName, SchemaRef) then
        sweep_by_ref(Ctx, SchemaRef, SlotName, CorrRef, !Log, !S)
    else
        true
    ).

    % Facts in working memory carrying a non-empty `hydrated_corr` [LHYD.7.4].
    %
:- func hydrated_count(exec_ctx, exec_state) = int.

hydrated_count(Ctx, S) = Count :-
    ( if interned(S ^ xs_interns, "hydrated_corr", SlotRef) then
        Count = list.foldl(hydrated_in_schema(S, SlotRef),
            map.values(Ctx ^ xc_schemas), 0)
    else
        Count = 0
    ).

:- func hydrated_in_schema(exec_state, intern_ref, schema, int) = int.

hydrated_in_schema(S, SlotRef, Schema, Acc) = Acc + N :-
    ( if slot_by_name(Schema, SlotRef, Slot) then
        Facts = facts_of_schema(S ^ xs_wm, Schema ^ s_id),
        N = list.length(list.filter(hydrated_slot(S, Slot ^ sc_index), Facts))
    else
        N = 0
    ).

:- pred hydrated_slot(exec_state::in, slot_index::in, fact::in) is semidet.

hydrated_slot(S, Index, Fact) :-
    array.semidet_lookup(Fact ^ f_slots, slot_index_int(Index), str(Ref)),
    not expand(S ^ xs_interns, Ref, "").

    % The budget rejection, as a fact: slots by name, `ts` the step's wall sample
    % [LFAC.9.2].
    %
:- pred assert_call_error(exec_ctx::in, intern_ref::in, string::in, string::in,
                          int64::in, effect_log::in, effect_log::out,
                          exec_state::in, exec_state::out) is det.

    % [RTCT.7]: `cache_cap` counts live keys, so only a new key breaches it, and is named
    % first; replacing a short value with a long one can breach `cache_bytes_cap`.
    %
cache_capped(Caps, Before, After, Cap) :-
    ( if
        Caps ^ cc_keys > 0u32,
        cache_size(After) > cache_size(Before),
        cache_size(After) > uint32.cast_to_int(Caps ^ cc_keys)
    then
        Cap = cap_cache
    else
        Caps ^ cc_bytes > 0u64,
        uint64.det_from_int(cache_bytes(After)) > Caps ^ cc_bytes,
        Cap = cap_cache_bytes
    ).

no_cache_caps = cache_caps(0u32, 0u64).

contract_cache_caps(no) = no_cache_caps.
contract_cache_caps(yes(RT)) =
    cache_caps(RT ^ c_cache_cap, RT ^ c_cache_bytes_cap).

    % [RTCT.7]: `wm_max` for a fact a rule produces; only an insert can breach it. The
    % node capacities and `agenda_cap` are `ds.engine.settle_actions`'s.
    %
:- pred wm_capped(exec_ctx::in, assert_result::in, wm::in) is semidet.

wm_capped(Ctx, Candidate, WM) :-
    Ctx ^ xc_contract = yes(RT),
    RT ^ c_wm_max > 0u32,
    Candidate = inserted(_),
    lerr_9_10_capacity_count(WM, Ctx ^ xc_fault_schemas)
        > uint32.cast_to_int(RT ^ c_wm_max).

assert_call_error(Ctx, CorrRef, Code, Message, Wall, !Log, !S) :-
    ( if
        interned(!.S ^ xs_interns, "CallError", NameRef),
        find_schema_by_name(Ctx ^ xc_schemas, NameRef, Schema)
    then
        intern(Code, CodeRef, !.S ^ xs_interns, IT0),
        intern(Message, MessageRef, IT0, IT1),
        !S ^ xs_interns := IT1,
        Named = [
            "corr"    - str(CorrRef),
            "code"    - str(CodeRef),
            "message" - str(MessageRef),
            "ts"      - int(Wall)
        ],
        Values = list.map(call_error_slot(!.S ^ xs_interns, Named),
            slot_commons(Schema)),
        % The deadline is the schema's [LCRS.4.2.1].
        assert_fact(Schema, Values, Ctx ^ xc_now,
            schema_deadline(Schema, Ctx ^ xc_now), tms_none, live,
            Candidate, !.S ^ xs_wm, WM),
        ( if wm_capped(Ctx, Candidate, WM) then
            Result = rejected(cap_wm_max)
        else
            Result = Candidate,
            !S ^ xs_wm := WM
        ),
        (
            ( Result = inserted(FactId)
            ; Result = replaced(_, FactId)
            ),
            emit_event(se_fact_assert(FactId, Schema ^ s_id, Values,
                recorded_ttl(schema_deadline(Schema, Ctx ^ xc_now),
                    Ctx ^ xc_now)), !Log)
        ;
            Result = noop(_),
            % No event: nothing entered working memory.
            list.foldl(emit_metric, noop_counted(!.S ^ xs_interns, Schema),
                !Log)
        ;
            Result = rejected(Cap),
            % Ends the firing, as for `emit`.
            emit_event(se_engine_error(ee_contract_breach(Cap),
                wm_breach_site(Ctx, WM)), !Log),
            !S ^ xs_capped := bool.yes
        ;
            Result = invalid(Index, Reason),
            % Does not end the firing. No activation on the site: the engine
            % asserts the `CallError`, not a rule's action.
            emit_event(se_engine_error(ee_slot_invalid(Index, Reason),
                schema_slot_site(Schema, Index)), !Log)
        ;
            % The host door's refusals, unreachable here.
            Result = refused_halted(_),
            true
        ;
            Result = refused_unregistered(_),
            true
        ;
            Result = refused_arity(_, _),
            true
        ;
            Result = refused_time_range(_),
            true
        ;
            Result = refused_encoding(_),
            true
        ;
            Result = refused_tz_row(_),
            true
        ;
            Result = refused_ttl_range,
            true
        )
    else
        % No `CallError` schema: a malformed artefact.
        true
    ).

:- func call_error_slot(intern_table, assoc_list(string, ds_value),
                        slot_common) = ds_value.

call_error_slot(IT, Named, Slot) = Value :-
    ( if
        expand(IT, Slot ^ sc_name, Name),
        assoc_list.search(Named, Name, Known)
    then
        Value = Known
    else
        Value = zero_of(Slot ^ sc_kind)
    ).

    % The event, once the message has been rendered.
    %
:- type message_event == (func(string) = stream_event).

%-----------------------------------------------------------------------------%

    % `AEMT`. A `publish` is `publish_verb`: it asserts nothing ([LTIE.4.3]).
    %
:- pred assert_verb(exec_ctx::in, activation::in, fire_id::in, schema_id::in,
                    list(slot_assign)::in, assert_mode::in, maybe(expr)::in,
                    bind_frame::in, effect_log::in, effect_log::out,
                    exec_state::in, exec_state::out) is det.

assert_verb(Ctx, Activation, Fire, SchemaId, Slots, Mode, Retain, Frame,
        !Log, !S) :-
    ( if map.search(Ctx ^ xc_schemas, schema_id_value(SchemaId), Schema) then
    ( if
        % The engine fills `ts` with the wall sample before any slot value is
        % evaluated [LFAC.9.2]; with none, a DOMAIN fault [LTIM.2.8.3].
        has_ts_slot(!.S ^ xs_interns, Schema),
        Ctx ^ xc_wall = no
    then
        abandon(Ctx, Activation, raised(rf_domain, no_origin), !Log, !S)
    else if
        % A fault in a slot or in `retain:` abandons before the assert [LERR.1].
        assign_fault(eval_context(Ctx, Activation, !.S, Frame),
            list.length(slot_commons(Schema)), Slots, Retain) = yes(Fault)
    then
        abandon(Ctx, Activation, Fault, !Log, !S)
    else if
        window_for(Schema, Retain, eval_context(Ctx, Activation, !.S, Frame))
            = yes(Window),
        ltim_1_1_5_deadline_past_range(Ctx ^ xc_now, Window)
    then
        % [LTIM.1.1.5]: a deadline past the `Time` range. After the evaluation faults,
        % before the slots are judged.
        abandon(Ctx, Activation, raised(rf_not_representable, no_origin),
            !Log, !S)
    else
        % Slots first: an interpolated one interns.
        slot_values(Ctx, Activation, Schema, Frame, Slots, Values, !S),
        EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
        Deadline = deadline_for(Schema, Retain, EvalCtx, Ctx ^ xc_now),
        Linkage = ( if Mode = logical then tms_derived else tms_none ),

        assert_fact(Schema, Values, Ctx ^ xc_now, Deadline, Linkage, live,
            Candidate, !.S ^ xs_wm, WM),
        % [LSTR.11.3], [LSER.13.14], [RTCT.7], in the host path's order. Any of them
        % ends the firing.
        ( if
            not Candidate = invalid(_, _),
            lstr_11_3_over_capacity(!.S ^ xs_interns, Schema, Values,
                CapN, CapLen)
        then
            Result = rejected(cap_value_capacity),
            CapacityBound = yes(fault_bound(uint32.cast_to_uint64(CapN),
                CapLen))
        else if
            lser_13_14_over_capacity(Ctx ^ xc_sdecls, !.S ^ xs_interns,
                !.S ^ xs_series, Ctx ^ xc_now, Schema, !.S ^ xs_wm, WM,
                Candidate, SeriesCap, SeriesReached)
        then
            Result = rejected(cap_series),
            CapacityBound = yes(fault_bound(uint32.cast_to_uint64(SeriesCap),
                SeriesReached))
        else if wm_capped(Ctx, Candidate, WM) then
            Result = rejected(cap_wm_max),
            CapacityBound = no
        else
            Result = Candidate,
            CapacityBound = no,
            !S ^ xs_wm := WM
        ),

        (
            Result = noop(Existing),
            % No fact event, and dwell is not reset [LFAC.2.5.1]. Counted first
            % [NMET.4.1]; the verb marker and the justification [IRET.12.3] remain.
            list.foldl(emit_metric, noop_counted(!.S ^ xs_interns, Schema),
                !Log),
            noop_events(Fire, SchemaId, Existing, Mode, Activation, !Log, !S)
        ;
            Result = rejected(Cap),
            % [RTCT.7]: no fact entered, the actions before this stand, and the
            % firing ends.
            (
                CapacityBound = yes(_),
                CapSite = no_site ^ fs_bound := CapacityBound
            ;
                CapacityBound = no,
                CapSite = wm_breach_site(Ctx, WM)
            ),
            emit_event(se_engine_error(ee_contract_breach(Cap), CapSite),
                !Log),
            rhs_cap_pump_status(Cap, !Log),
            !S ^ xs_capped := bool.yes
        ;
            Result = invalid(Index, Reason),
            ( if rarc_5_2_7_type_error(Reason) then
                % [RARC.5.2.7]: names the schema, the slot and the value's tag, and
                % abandons the activation.
                Actual = ( if list.index0(Values, Index, V) then
                               yes(value_tag(V))
                           else
                               no ),
                abandon(Ctx, Activation,
                    raised(rf_type_error,
                        fault_origin(no, yes(schema_name_ref(Schema ^ s_name)),
                            slot_name_at(Schema, Index), Actual)),
                    !Log, !S)
            else
                % A refusal it does not cover: the fact does not enter, and the
                % firing goes on.
                emit_event(se_engine_error(ee_slot_invalid(Index, Reason),
                    slot_site(Ctx, Activation, Schema, Index)), !Log)
            )
        ;
            Result = inserted(FactId),
            assert_events(Fire, SchemaId, Values, Deadline, Ctx ^ xc_now,
                FactId, no, Mode, Activation, !Log, !S),
            note_activation_fact(Schema, FactId, !S)
        ;
            Result = replaced(Old, FactId),
            assert_events(Fire, SchemaId, Values, Deadline, Ctx ^ xc_now,
                FactId, yes(Old), Mode, Activation, !Log, !S),
            note_activation_fact(Schema, FactId, !S)
        ;
            % The host door's refusals, unreachable here.
            Result = refused_halted(_),
            true
        ;
            Result = refused_unregistered(_),
            true
        ;
            Result = refused_arity(_, _),
            true
        ;
            Result = refused_time_range(_),
            true
        ;
            Result = refused_encoding(_),
            true
        ;
            Result = refused_tz_row(_),
            true
        ;
            Result = refused_ttl_range,
            true
        )
    )
    else
        % Unreachable: every action's schema id comes from the list `en_schemas` is
        % built from. The event's kind is arbitrary.
        emit_event(se_engine_error(ee_expr_fault(rf_div_zero),
            activation_site(Ctx, Activation)), !Log)
    ).

noop_counted(Interns, Schema) = Counted :-
    ( if expand(Interns, schema_name_ref(Schema ^ s_name), Name) then
        Counted = [counter("ds.facts.noop_reassert_suppressed_total",
            [{"schema", Name}])]
    else
        Counted = []
    ).

    % What a no-op assertion still owes: the verb marker and, for `logical`, the
    % justification, once its action has settled (`ds.tms.defer`). No `se_fact_assert`:
    % that records an assert arriving at the host's door [RFCS.6.7].
    %
:- pred noop_events(fire_id::in, schema_id::in, fact_id::in, assert_mode::in,
                    activation::in, effect_log::in, effect_log::out,
                    exec_state::in, exec_state::out) is det.

noop_events(_Fire, SchemaId, FactId, Mode, _Activation, !Log, !S) :-
    (
        Mode = logical,
        defer(FactId, no, !.S ^ xs_tms, TMS),
        !S ^ xs_tms := TMS
    ;
        Mode = plain
    ),
    emit_event(se_emit(FactId, SchemaId), !Log).

:- pred assert_events(fire_id::in, schema_id::in, list(ds_value)::in,
                      maybe(instant)::in, instant::in,
                      fact_id::in, maybe(fact_id)::in, assert_mode::in,
                      activation::in, effect_log::in, effect_log::out,
                      exec_state::in, exec_state::out) is det.

assert_events(_Fire, SchemaId, Values, Deadline, Asserted, FactId, Superseded,
        Mode, _Activation, !Log, !S) :-
    emit_event(se_fact_assert(FactId, SchemaId, Values,
        recorded_ttl(Deadline, Asserted)), !Log),
    % [RFCS.6a.4], [LFAC.2.5.3]: the FactEmit, then the withdrawal it caused, then the
    % verb's markers. `ds.wm` has already removed the old fact.
    (
        Superseded = yes(Old),
        emit_event(se_fact_withdraw(Old, rc_supersede), !Log)
    ;
        Superseded = no
    ),
    (
        Mode = logical,
        % The firing activation's token is the justifier [RLOW.7.1.4], registered
        % once the action has settled, since the emit may itself end the match
        % [LLOG.15.1]. No event of its own [RFCS.6a.3].
        defer(FactId, yes, !.S ^ xs_tms, TMS),
        !S ^ xs_tms := TMS
    ;
        Mode = plain
    ),
    emit_event(se_emit(FactId, SchemaId), !Log).

    % `APUB`, the `publish` verb. It SENDS UPSTREAM AND ASSERTS NOTHING in this
    % tier ([LTIE.4.3]): no working memory, no truth maintenance, no deadline,
    % no fact id, and no bound on working memory or a series ([LTIE.4.8]).
    %
    % ITS VALUES ARE JUDGED AS AN `emit`'S ([LTIE.4.8]), in libds's order
    % (`ds_rete_publish_values`, then `bridge_publish`):
    %
    %   1. `ts` with no wall value: a DOMAIN ComputationError, the activation
    %      abandoned ([LFAC.9.2], [LTIM.2.8.3]), as for an `emit`;
    %   2. a fault in a slot value abandons the activation ([LERR.1]);
    %   3. the values as a fact would store them (`ds.wm.stored_slots`), then
    %      `slot_fault`: a kind the slot does not admit, `null` where it is not
    %      `T?`, or a NaN, is [RARC.5.2.7]'s TypeError and abandons the
    %      activation; the other reasons are no rule's to reach (libds refuses
    %      an over-limit Json where it is built), and keep `ee_slot_invalid`,
    %      as for an `emit`;
    %   4. a `String` over its slot's `capacity` is refused as a bound's
    %      refusal, and the firing ends ([LSTR.11.3]), as at a refused `emit`.
    %
    % A refused `publish` sends nothing. Otherwise the event carries the
    % values (the view, [NCBK.2.5]) and their FactExternal ([NCBK.10.1]).
    %
:- pred publish_verb(exec_ctx::in, activation::in, schema_id::in,
                     list(slot_assign)::in, bind_frame::in,
                     effect_log::in, effect_log::out,
                     exec_state::in, exec_state::out) is det.

publish_verb(Ctx, Activation, SchemaId, Slots, Frame, !Log, !S) :-
    ( if map.search(Ctx ^ xc_schemas, schema_id_value(SchemaId), Schema) then
        ( if
            has_ts_slot(!.S ^ xs_interns, Schema),
            Ctx ^ xc_wall = no
        then
            abandon(Ctx, Activation, raised(rf_domain, no_origin), !Log, !S)
        else if
            assign_fault(eval_context(Ctx, Activation, !.S, Frame),
                list.length(slot_commons(Schema)), Slots, no) = yes(Fault)
        then
            abandon(Ctx, Activation, Fault, !Log, !S)
        else
            slot_values(Ctx, Activation, Schema, Frame, Slots, Given, !S),
            Values = stored_slots(Schema, Given),
            ( if slot_fault(Schema, Values, Index, Reason) then
                ( if rarc_5_2_7_type_error(Reason) then
                    % The tag as the `emit` path names it: the value given.
                    Actual = ( if list.index0(Given, Index, V) then
                                   yes(value_tag(V))
                               else
                                   no ),
                    abandon(Ctx, Activation,
                        raised(rf_type_error,
                            fault_origin(no,
                                yes(schema_name_ref(Schema ^ s_name)),
                                slot_name_at(Schema, Index), Actual)),
                        !Log, !S)
                else
                    emit_event(se_engine_error(ee_slot_invalid(Index, Reason),
                        slot_site(Ctx, Activation, Schema, Index)), !Log)
                )
            else if
                lstr_11_3_over_capacity(!.S ^ xs_interns, Schema, Values,
                    CapN, CapLen)
            then
                CapSite = no_site ^ fs_bound :=
                    yes(fault_bound(uint32.cast_to_uint64(CapN), CapLen)),
                emit_event(se_engine_error(
                    ee_contract_breach(cap_value_capacity), CapSite), !Log),
                rhs_cap_pump_status(cap_value_capacity, !Log),
                !S ^ xs_capped := bool.yes
            else
                External = publish_external(
                    eval_context(Ctx, Activation, !.S, Frame), Schema, Values),
                emit_event(se_publish(SchemaId, Values, External), !Log)
            )
        )
    else
        % A schema id that names no schema: unreachable by construction, as in
        % `assert_verb`, whose comment says why the event is mislabelled.
        emit_event(se_engine_error(ee_expr_fault(rf_div_zero),
            activation_site(Ctx, Activation)), !Log)
    ).

    % A rule's `emit` or `publish` of a `String` past its slot's `capacity`
    % [LSTR.11.3], or its `emit` of a sample past its series' `capacity`
    % [LSER.13.14], is DS_ERR_CONTRACT_BREACH, the status the pump returns, as
    % libds's does; the pump goes on. `wm_max` is the realtime contract's
    % [NRTM.3.1], which binds nothing in this edition, so its refusal reports no
    % status here.
    %
:- pred rhs_cap_pump_status(cap::in, effect_log::in, effect_log::out) is det.

rhs_cap_pump_status(Cap, !Log) :-
    ( if
        ( Cap = cap_value_capacity
        ; Cap = cap_series
        )
    then
        emit_pump_status(ps_contract_breach(Cap), !Log)
    else
        true
    ).

    % THE FactExternal A `publish` CARRIES ([NCBK.10.1], RFCS.23.1), built
    % from its values, as libds's `bridge_publish` packs its view: the schema
    % and the values in declaration order, `asserted_at` the instant of the
    % `publish` -- the step's held wall sample, absent with no wall value
    % ([RFCS.23.5]) -- and a fact reference inlining its target while it is
    % live ([RFCS.23.4]). `no` for values that do not encode: the event is
    % still emitted, as libds's is with no bytes when the pack fails.
    %
:- func publish_external(eval_ctx, schema, list(ds_value))
    = maybe(fact_external).

publish_external(EvalCtx, Schema, Values) = External :-
    Env = fx_env(EvalCtx ^ ec_schemas, EvalCtx ^ ec_interns, EvalCtx ^ ec_wm,
        EvalCtx ^ ec_wall),
    ( if
        fact_external_of_slots(Env, Schema, array.from_list(Values),
            EvalCtx ^ ec_wall, FE)
    then
        External = yes(FE)
    else
        External = no
    ).

:- func deadline_for(schema, maybe(expr), eval_ctx, instant) = maybe(instant).

deadline_for(Schema, Retain, EvalCtx, Now) = Deadline :-
    ( if window_for(Schema, Retain, EvalCtx) = yes(Window) then
        Deadline = yes(add(Now, Window))
    else
        Deadline = no
    ).

    % The window added to the entry stamp: the `retain:` override, which applies even on
    % a `logical` schema [RHIM.6.2], else a `ttl` schema's own TTL, else none.
    %
:- func window_for(schema, maybe(expr), eval_ctx) = maybe(duration).

window_for(Schema, Retain, EvalCtx) = Window :-
    ( if
        Retain = yes(Expr),
        eval(Expr, EvalCtx, ev_ok(V)),
        ttl_nanos(V, Ns)
    then
        Window = yes(duration_from_ns(Ns))
    else if Schema ^ s_lifecycle = lc_ttl(_, Ttl) then
        Window = yes(Ttl)
    else
        Window = no
    ).

    % Evaluate each slot assignment into the schema's slot array, threading the table
    % an interpolated slot interns into. An unassigned slot takes the zero of its type:
    % the compiler writes `null` for an omitted nullable one [LGRA.13.11].
    %
:- pred slot_values(exec_ctx::in, activation::in, schema::in, bind_frame::in,
                    list(slot_assign)::in, list(ds_value)::out,
                    exec_state::in, exec_state::out) is det.

slot_values(Ctx, Activation, Schema, Frame, Slots, Values, !S) :-
    list.map_foldl(value_for(Ctx, Activation, Slots, Frame), slot_commons(Schema),
        Values, !S).

:- pred value_for(exec_ctx::in, activation::in, list(slot_assign)::in, bind_frame::in,
                  slot_common::in, ds_value::out,
                  exec_state::in, exec_state::out) is det.

value_for(Ctx, Activation, Slots, Frame, Common, Value, !S) :-
    EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
    ( if
        list.find_first_match(assigns_to(Common ^ sc_index), Slots,
            slot_assign(_, Expr))
    then
        ( if interpolation(Expr) then
            interpolated_slot(Expr, EvalCtx, Common, Value, !S)
        else
            plain_slot(Expr, EvalCtx, Common, Value, !S)
        )
    else if
        % `ts` is the firing's wall sample [LFAC.9.2], [LTIM.2.8.4].
        expand(!.S ^ xs_interns, Common ^ sc_name, "ts"),
        Ctx ^ xc_wall = yes(Wall)
    then
        Value = int(Wall)
    else if Common ^ sc_kind = k_string then
        % An unassigned `String` is the interned empty string [RHIM.2.4]; `zero_of`
        % has no table.
        intern("", EmptyRef, !.S ^ xs_interns, Interns),
        !S ^ xs_interns := Interns,
        Value = str(EmptyRef)
    else
        Value = zero_of(Common ^ sc_kind)
    ).

    % Whether a schema declares `ts` [LFAC.9.1], by name.
    %
:- pred has_ts_slot(intern_table::in, schema::in) is semidet.

has_ts_slot(IT, Schema) :-
    interned(IT, "ts", Ref),
    slot_by_name(Schema, Ref, _).

:- pred interpolation(expr::in) is semidet.

interpolation(E) :-
    untainted(E) = e_interp(_).

    % Render, then intern, since the result becomes a fact slot.
    %
:- pred interpolated_slot(expr::in, eval_ctx::in, slot_common::in,
                          ds_value::out, exec_state::in, exec_state::out) is det.

interpolated_slot(Expr, EvalCtx, Common, Value, !S) :-
    eval_text(Expr, EvalCtx, Text),
    (
        Text = text_ok(Rendered),
        intern(Rendered, Ref, !.S ^ xs_interns, IT),
        !S ^ xs_interns := IT,
        Value = str(Ref)
    ;
        % Unreached: `assert_verb` abandons on a slot fault first.
        Text = text_fault(_),
        Value = zero_of(Common ^ sc_kind)
    ).

:- pred plain_slot(expr::in, eval_ctx::in, slot_common::in, ds_value::out,
                   exec_state::in, exec_state::out) is det.

plain_slot(Expr, EvalCtx, Common, Value, !S) :-
    eval(Expr, EvalCtx, Outcome),
    (
        Outcome = ev_ok(V),
        ( if V = text(Computed) then
            intern(Computed, Ref, !.S ^ xs_interns, IT),
            !S ^ xs_interns := IT,
            Value = str(Ref)
        else
            % A `Time` becomes its UTC nanoseconds [LTIM.1.1.3].
            Value = stored_value(V)
        )
    ;
        % Unreached: `assert_verb` abandons on a slot fault first.
        Outcome = ev_fault(_),
        Value = zero_of(Common ^ sc_kind)
    ).

    % The first fault among an emit's slot assignments, then its `retain:`, in wire
    % order. An assign whose slot index names no slot of `Width` is ARTEFACT_LIED as it
    % is reached, before its expression is evaluated [RDSC.4a.9.1].
    %
:- func assign_fault(eval_ctx, int, list(slot_assign), maybe(expr))
    = maybe(raised).

assign_fault(EvalCtx, _, [], Retain) = first_fault(EvalCtx, maybe_expr(Retain)).
assign_fault(EvalCtx, Width, [slot_assign(Ix, E) | Slots], Retain) = Found :-
    ( if slot_index_int(Ix) >= Width then
        Found = yes(raised(rf_artefact_lied, no_origin))
    else if expr_fault(EvalCtx, E, Fault) then
        Found = yes(raised_in(E, EvalCtx, Fault))
    else
        Found = assign_fault(EvalCtx, Width, Slots, Retain)
    ).

:- pred assigns_to(slot_index::in, slot_assign::in) is semidet.

assigns_to(Ix, slot_assign(Ix, _)).

:- func maybe_expr(maybe(expr)) = list(expr).

maybe_expr(no) = [].
maybe_expr(yes(E)) = [E].

    % A `String`'s `null` is left to unreached fault paths and `call_error_slot`;
    % `value_for` builds the real one.
    %
:- func zero_of(slot_kind) = ds_value.

zero_of(k_int) = int(0i64).
zero_of(k_float) = float(0.0).
zero_of(k_bool) = bool(no).
zero_of(k_json) = json(j_null).
zero_of(k_string) = null.
zero_of(k_bytes) = bytes(bitmap.init(0)).
zero_of(k_schema(_)) = null.
zero_of(k_time) = int(0i64).
zero_of(k_date) = int(0i64).
zero_of(k_duration) = int(0i64).

%-----------------------------------------------------------------------------%

:- pred call_verb(exec_ctx::in, activation::in, fire_id::in, intern_ref::in,
                  correlation::in, kwargs::in, maybe(list(expr))::in,
                  bind_frame::in, effect_log::in, effect_log::out,
                  exec_state::in, exec_state::out) is det.

call_verb(Ctx, Activation, Fire, Service, Correlation, Kwargs, Gate, Frame,
        !Log, !S) :-
    % The per-call cooldown gate [IRET.25.5.1] runs before the call's arguments are
    % touched. Denied, the call is not issued and the firing's other actions run; a
    % faulted gate argument abandons the activation [LERR.1].
    (
        Gate = yes(GateArgs),
        rhs_gate(Ctx, Activation, yes(e_call(fn_rate_allow, GateArgs)),
            GateVerdict, !S)
    ;
        Gate = no,
        GateVerdict = gv_admits
    ),
    (
        GateVerdict = gv_denies
    ;
        GateVerdict = gv_faulted(GateFault),
        abandon(Ctx, Activation, GateFault, !Log, !S)
    ;
        GateVerdict = gv_admits,
        call_verb_admitted(Ctx, Activation, Fire, Service, Correlation,
            Kwargs, Gate, Frame, !Log, !S)
    ).

:- pred call_verb_admitted(exec_ctx::in, activation::in, fire_id::in,
                  intern_ref::in, correlation::in, kwargs::in,
                  maybe(list(expr))::in, bind_frame::in,
                  effect_log::in, effect_log::out,
                  exec_state::in, exec_state::out) is det.

call_verb_admitted(Ctx, Activation, Fire, Service, Correlation, Kwargs, Gate,
        Frame, !Log, !S) :-
    EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
    Pairs = kwarg_list(Kwargs),
    % A fault abandons the activation [LERR.1]: the correlation first, then the
    % kwargs in call order. A value no call argument can carry is not a fault
    % [NCBK.6.10]: `call_args` fails, and the firing goes on.
    ( if
        first_fault(EvalCtx, correlation_exprs(Correlation) ++
            assoc_list.values(Pairs)) = yes(Fault)
    then
        abandon(Ctx, Activation, Fault, !Log, !S)
    else
    % Resolved once, at dispatch, and into both the event and the recorded action, since
    % the record cannot encode the expression. `""` is the empty correlation [LRST.1.2]:
    % issued, and it sweeps nothing.
    resolve_correlation(EvalCtx, Correlation, Resolved, !S),
    ( if
        Resolved = yes(Corr),
        call_args(EvalCtx, Pairs, Args)
    then
        lcrs_6_2_1_call_supersede(Ctx, Service, Corr, !Log, !S),
        acted(se_call_issued(Fire, Service, Corr, Args, co_call_verb),
            a_call(Service, Corr, Kwargs, Gate), !Log)
    else
        % The call is not issued, and the firing's other actions run. A NaN argument,
        % when that is the refusal (`nan_refusal`), sets the pump's status [LEXP.4.2].
        % A kwarg with no value counts `ds.calls.arg_error_total{service}` [NMET.4.1],
        % and no other refusal does.
        ( if
            Resolved = yes(_),
            some_kwarg_null(EvalCtx, Pairs),
            expand(!.S ^ xs_interns, Service, ServiceName)
        then
            emit_metric(counter("ds.calls.arg_error_total",
                [{"service", ServiceName}]), !Log)
        else if
            Resolved = yes(_),
            nan_refusal(EvalCtx, Pairs)
        then
            emit_pump_status(ps_nan_rejected, !Log)
        else
            true
        )
    )
    ).

    % The call is refused for a NaN `Float` argument and for nothing else [LEXP.4.2]:
    % every kwarg is one `call_arg` takes, or a NaN, and at least one is a NaN.
    %
:- pred nan_refusal(eval_ctx::in, assoc_list(string, expr)::in) is semidet.

nan_refusal(EvalCtx, Pairs) :-
    list.map(arg_or_nan(EvalCtx), Pairs, Kinds),
    list.member(is_nan, Kinds).

:- type arg_kind
    --->    is_arg
    ;       is_nan.

:- pred arg_or_nan(eval_ctx::in, pair(string, expr)::in, arg_kind::out)
    is semidet.

arg_or_nan(EvalCtx, Pair, Kind) :-
    ( if call_arg(EvalCtx, Pair, _) then
        Kind = is_arg
    else
        Pair = _ - Expr,
        not interpolation(Expr),
        eval(Expr, EvalCtx, ev_ok(float(F))),
        float.is_nan(F),
        Kind = is_nan
    ).

    % Whether a kwarg's value is `null` [LNUL.11.1].
    %
:- pred some_kwarg_null(eval_ctx::in, assoc_list(string, expr)::in)
    is semidet.

some_kwarg_null(EvalCtx, Pairs) :-
    list.find_first_match(
        ( pred(P::in) is semidet :-
            P = _ - Expr,
            not interpolation(Expr),
            eval(Expr, EvalCtx, Outcome),
            Outcome = ev_ok(null)
        ), Pairs, _).

    % A call supersedes its prior answers as it is issued, and only then: the live
    % facts of the service's response schema whose `corr` is the call's correlation,
    % then `CallError`'s, before the call's own record. A `no response` service, or one
    % no `ServiceDef` names, sweeps `CallError` alone.
    %
:- pred lcrs_6_2_1_call_supersede(exec_ctx::in, intern_ref::in,
    correlation::in, effect_log::in, effect_log::out,
    exec_state::in, exec_state::out) is det.

lcrs_6_2_1_call_supersede(Ctx, Service, Corr, !Log, !S) :-
    ( if
        Corr = correlated(CorrRef),
        expand(!.S ^ xs_interns, CorrRef, CorrText),
        CorrText \= ""
    then
        ( if
            expand(!.S ^ xs_interns, Service, ServiceName),
            map.search(Ctx ^ xc_service_responses, ServiceName, Response),
            Response \= ""
        then
            sweep_by_name(Ctx, Response, "corr", CorrRef, !Log, !S)
        else
            true
        ),
        sweep_by_name(Ctx, "CallError", "corr", CorrRef, !Log, !S)
    else
        true
    ).

    % A call's typed arguments [NCBK.6.10], [RFCS.23.2], one per kwarg in the artefact's
    % order, by name [RDSC.4a.9.4]. Fails, and the call is not issued, on a NaN Float,
    % `null` [LNUL.11.1] or a ratio. A fact is its FactExternal [RFCS.23.1]; a Time and a
    % Duration cross as their nanosecond Int.
    %
:- pred call_args(eval_ctx::in, assoc_list(string, expr)::in, list(arg)::out)
    is semidet.

call_args(EvalCtx, Pairs, Args) :-
    list.map(call_arg(EvalCtx), Pairs, Args).

:- pred call_arg(eval_ctx::in, pair(string, expr)::in, arg::out) is semidet.

call_arg(EvalCtx, Name - Expr, arg(Name, Value)) :-
    ( if interpolation(Expr) then
        eval_text(Expr, EvalCtx, text_ok(Text)),
        Value = av_string(Text)
    else
        eval(Expr, EvalCtx, ev_ok(V)),
        arg_value(EvalCtx, V, Value)
    ).

:- pred arg_value(eval_ctx::in, ds_value::in, arg_value::out) is semidet.

arg_value(_, int(I), av_int(I)).
arg_value(_, float(F), av_float(F)) :-
    not float.is_nan(F).
arg_value(Ctx, str(Ref), av_string(S)) :-
    expand(Ctx ^ ec_interns, Ref, S).
arg_value(_, text(S), av_string(S)).
arg_value(_, bool(B), av_bool(B)).
arg_value(_, json(J), av_json(Text)) :-
    json_text(J, Text).
arg_value(_, bytes(B), av_bytes(bitmap_bytes(B))).
arg_value(_, duration(D), av_int(int64.cast_from_uint64(duration_ns(D)))).
arg_value(_, time(T), av_int(utc_ns(T))).
arg_value(Ctx, fact_ref(Id), av_encoded_fact(FE)) :-
    fact_external_of(Ctx, Id, FE).
    % No arm for `null`: a kwarg with no value prevents the call [LNUL.11.1].

:- func bitmap_bytes(bitmap) = list(uint8).

bitmap_bytes(B) = list.map(
    (func(I) = uint8.cast_from_int(B ^ bitmap.byte(I))),
    0 .. (bitmap.det_num_bytes(B) - 1)).

    % A live fact as it leaves the engine: its FactExternal [RFCS.23.1], with no
    % `event_id` [RFCS.23.5] and fields in declaration order [RFCS.23.4]. A fact this
    % firing asserted is not stamped yet, and takes the step's wall sample, the stamp it
    % is about to get.
    %
:- pred fact_external_of(eval_ctx::in, fact_id::in, fact_external::out)
    is semidet.

fact_external_of(Ctx, Id, FE) :-
    fact_external_in(fx_env(Ctx ^ ec_schemas, Ctx ^ ec_interns, Ctx ^ ec_wm,
        Ctx ^ ec_wall), Id, FE).

recorded_external_bytes(Schemas, Interns, WM, Wall, Id, Bytes) :-
    fact_external_in(fx_env(Schemas, Interns, WM, Wall), Id, FE),
    encode_fact_external(FE, Bytes).

    % What packing a fact reads, so a recorder packs as `call` and `publish` do.
    %
:- type fx_env
    --->    fx_env(
                fx_schemas :: map(uint32, schema),
                fx_interns :: intern_table,
                fx_wm      :: wm,
                fx_wall    :: maybe(int64)
            ).

:- pred fact_external_in(fx_env::in, fact_id::in, fact_external::out)
    is semidet.

fact_external_in(Env, Id, FE) :-
    lookup_fact(Env ^ fx_wm, Id, Fact),
    (
        Fact ^ f_stamp = yes(fact_stamp(_, Wall))
    ;
        Fact ^ f_stamp = no,
        Wall = Env ^ fx_wall
    ),
    map.search(Env ^ fx_schemas, schema_id_value(Fact ^ f_schema), Schema),
    fact_external_of_slots(Env, Schema, Fact ^ f_slots, Wall, FE).

    % A schema's slot values as a FactExternal, `Wall` its `asserted_at`: a live
    % fact's and a `publish`'s values, one encoding.
    %
:- pred fact_external_of_slots(fx_env::in, schema::in, array(ds_value)::in,
                               maybe(int64)::in, fact_external::out)
    is semidet.

fact_external_of_slots(Env, Schema, Slots,
        Wall, fact_external(Name, Hash, Fields, Wall)) :-
    schema_name_and_hash(Env ^ fx_interns, Schema, Name, Hash),
    list.map(slot_field(Env, Slots), slot_commons(Schema), Fields).

:- pred slot_field(fx_env::in, array(ds_value)::in, slot_common::in,
                   arg::out) is semidet.

slot_field(Env, Slots, SC, arg(Name, Value)) :-
    expand(Env ^ fx_interns, SC ^ sc_name, Name),
    array.semidet_lookup(Slots, slot_index_int(SC ^ sc_index), V),
    slot_arg_value(Env, V, Value).

    % A slot value as a field [RFCS.23.2]. A fact reference is the referenced fact,
    % inlined [RFCS.23.4], or `null` if its target has left working memory. A Float
    % slot's NaN is a value, unlike a NaN call argument.
    %
:- pred slot_arg_value(fx_env::in, ds_value::in, arg_value::out) is semidet.

slot_arg_value(_, int(I), av_int(I)).
slot_arg_value(_, float(F), av_float(F)).
slot_arg_value(Env, str(Ref), av_string(S)) :-
    expand(Env ^ fx_interns, Ref, S).
slot_arg_value(_, text(S), av_string(S)).
slot_arg_value(_, bool(B), av_bool(B)).
slot_arg_value(_, json(J), av_json(Text)) :-
    json_text(J, Text).
slot_arg_value(_, bytes(B), av_bytes(bitmap_bytes(B))).
slot_arg_value(_, time(T), av_int(utc_ns(T))).
slot_arg_value(_, null, av_null).
slot_arg_value(Env, fact_ref(Id), Value) :-
    ( if lookup_fact(Env ^ fx_wm, Id, _) then
        fact_external_in(Env, Id, FE),
        Value = av_fact_ref(FE)
    else
        Value = av_null
    ).

:- func correlation_exprs(correlation) = list(expr).

correlation_exprs(correlated(_)) = [].
correlation_exprs(correlated_expr(E)) = [E].

    % The intern ref a string value names, without adding to the table. Fails for a
    % computed string with none, which no slot holds.
    %
:- pred string_ref(intern_table::in, ds_value::in, intern_ref::out) is semidet.

string_ref(_, str(Ref), Ref).
string_ref(IT, text(S), Ref) :-
    interned(IT, S, Ref).

    % A correlation as it will be dispatched, interned; `no` when a computed one will
    % not render, or is not a String [LRST.1.4.1].
    %
:- pred resolve_correlation(eval_ctx::in, correlation::in,
                            maybe(correlation)::out,
                            exec_state::in, exec_state::out) is det.

resolve_correlation(_, correlated(Ref), yes(correlated(Ref)), !S).
resolve_correlation(EvalCtx, correlated_expr(E), Resolved, !S) :-
    ( if E = e_lit(null) then
        % No correlation at all, which the compiler does not write [LCRS.3.1].
        Resolved = no
    else if untainted(E) = e_interp(_) then
        eval_text(E, EvalCtx, Text),
        (
            Text = text_fault(_),
            Resolved = no
        ;
            Text = text_ok(S),
            intern(S, Ref, !.S ^ xs_interns, IT),
            !S ^ xs_interns := IT,
            Resolved = yes(correlated(Ref))
        )
    else
        eval(E, EvalCtx, Outcome),
        ( if Outcome = ev_ok(str(Ref)) then
            Resolved = yes(correlated(Ref))
        else if Outcome = ev_ok(text(S)) then
            intern(S, Ref, !.S ^ xs_interns, IT),
            !S ^ xs_interns := IT,
            Resolved = yes(correlated(Ref))
        else
            Resolved = no
        )
    ).

:- pred kwarg_ok(eval_ctx::in, pair(string, expr)::in) is semidet.

kwarg_ok(EvalCtx, _Key - Expr) :-
    ( if interpolation(Expr) then
        eval_text(Expr, EvalCtx, text_ok(_))
    else
        eval(Expr, EvalCtx, ev_ok(_))
    ).

    % A hydration call's body. Fails on a kwarg that will not render. Keys stay in the
    % artefact's order, which the compiler sorts by name [RLOW.7.3.1].
    %
:- pred call_body(eval_ctx::in, assoc_list(string, expr)::in, string::out)
    is semidet.

call_body(EvalCtx, Pairs, Body) :-
    list.map(kwarg_json(EvalCtx), Pairs, Fields),
    Body = "{" ++ string.join_list(",", Fields) ++ "}".

:- pred kwarg_json(eval_ctx::in, pair(string, expr)::in, string::out)
    is semidet.

kwarg_json(EvalCtx, Key - Expr, Field) :-
    ( if interpolation(Expr) then
        eval_text(Expr, EvalCtx, text_ok(Text)),
        Rendered = string_value_json(Text)
    else
        eval(Expr, EvalCtx, ev_ok(V)),
        json_scalar(EvalCtx, V, Rendered)
    ),
    Field = string_value_json(Key) ++ ":" ++ Rendered.

    % [IDSP.13.4]'s table. A `String` writes U+0008 and U+000C as `\u0008` and `\u000c`;
    % a `Json` value's strings write `\b` and `\f` [LGRA.5.8.7a]. A Time is its `utc_ns`
    % and a Duration its nanoseconds, bare integers. No arm for `null` or `bytes`.
    %
:- pred json_scalar(eval_ctx::in, ds_value::in, string::out) is semidet.

json_scalar(Ctx, str(Ref), Out) :-
    expand(Ctx ^ ec_interns, Ref, S),
    Out = string_value_json(S).
json_scalar(_, text(S), string_value_json(S)).
json_scalar(_, int(I), bare_int(I)).
json_scalar(_, float(F), bare_float(F)).
json_scalar(_, bool(B), bare_bool(B)).
json_scalar(_, duration(D), bare_int(int64.cast_from_uint64(duration_ns(D)))).
json_scalar(_, time(T), bare_int(utc_ns(T))).
json_scalar(_, json(J), Text) :-
    json_text(J, Text).

%-----------------------------------------------------------------------------%

    % A non-finite Float in a cached value: at the top, or a leaf of a `Json` tree.
    %
:- pred cache_value_nonfinite(eval_ctx::in, expr::in) is semidet.

cache_value_nonfinite(EvalCtx, ValueExpr) :-
    E = unwrapped_cache_value(ValueExpr),
    not interpolation(E),
    eval(E, EvalCtx, Outcome),
    Outcome = ev_ok(V),
    (
        V = float(F),
        float.is_nan_or_inf(F)
    ;
        V = json(J),
        not json_text(J, _)
    ).

:- pred cache_set_verb(exec_ctx::in, activation::in, expr::in, expr::in,
                       maybe(expr)::in, bind_frame::in, effect_log::in, effect_log::out,
                       exec_state::in, exec_state::out) is det.

cache_set_verb(Ctx, Activation, KeyExpr, ValueExpr, TtlExpr, Frame, !Log, !S) :-
    EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
    ( if
        % These abandon the activation [LERR.1], in order: a fault in the key or the
        % value; a value with no JSON spelling; a fault in the TTL; a value over a Json
        % limit [LGRA.5.8.6]; a deadline past the `Time` range [LTIM.1.1.5].
        first_raised(
            first_fault(EvalCtx, [KeyExpr, unwrapped_cache_value(ValueExpr)]),
            first_raised(
                first_uncacheable(EvalCtx,
                    [unwrapped_cache_value(ValueExpr)]),
                first_raised(
                    first_fault(EvalCtx, maybe_expr(TtlExpr)),
                    first_raised(
                        json_over_limit(EvalCtx, ValueExpr),
                        cache_deadline_past_range(Ctx, EvalCtx, TtlExpr)))))
            = yes(Fault)
    then
        % `ds.json.nonfinite_total{verb}` [NMET.4.1], only when that is the refusal.
        ( if
            first_fault(EvalCtx, [KeyExpr, unwrapped_cache_value(ValueExpr)])
                = no,
            cache_value_nonfinite(EvalCtx, ValueExpr)
        then
            emit_metric(counter("ds.json.nonfinite_total",
                [{"verb", "cache"}]), !Log)
        else
            true
        ),
        abandon(Ctx, Activation, Fault, !Log, !S)
    else if
        cache_key(Ctx, EvalCtx, KeyExpr, Key),
        cache_value(EvalCtx, ValueExpr, Json)
    then
        % The cache holds JSON text [IDSP.7], interned here. Counted in bytes.
        intern(Json, Ref, !.S ^ xs_interns, IT),
        !S ^ xs_interns := IT,
        Expires = cache_deadline(Ctx, EvalCtx, TtlExpr),
        cache_put(Key, str(Ref), string.count_utf8_code_units(Json), Expires,
            !.S ^ xs_cache, NewCache),
        % [RTCT.7]: refused at the write, so the cache never holds more than its caps.
        ( if
            cache_capped(Ctx ^ xc_cache_caps, !.S ^ xs_cache, NewCache,
                Breached)
        then
            % The firing stops here [LSTO.4.7.5], the pump goes on, and it returns the
            % breach.
            emit_event(se_engine_error(ee_contract_breach(Breached),
                cache_breach_site(Ctx, Activation, Ctx ^ xc_cache_caps,
                    Breached, NewCache)),
                !Log),
            emit_pump_status(ps_contract_breach(Breached), !Log),
            !S ^ xs_capped := bool.yes
        else
            !S ^ xs_cache := NewCache,
            % [NCBK.2.3] carries the TTL, not the deadline.
            Ttl = maybe.map_maybe((func(At) = diff(At, Ctx ^ xc_now)), Expires),
            emit_event(se_cache_set(Key, Json, Ttl), !Log)
        )
    else
        % A key that did not render.
        true
    ).

    % A cache value a rule built past one of [LGRA.5.8.6]'s tree limits, the text being
    % the engine's own serialization: NOT_REPRESENTABLE.
    %
:- func json_over_limit(eval_ctx, expr) = maybe(raised).

json_over_limit(EvalCtx, Expr) = Found :-
    Value = unwrapped_cache_value(Expr),
    ( if
        eval(Value, EvalCtx, ev_ok(V)),
        value_over_limit(EvalCtx, V)
    then
        Found = yes(raised_in(Value, EvalCtx, rf_not_representable))
    else
        Found = no
    ).

:- pred value_over_limit(eval_ctx::in, ds_value::in) is semidet.

value_over_limit(EvalCtx, str(Ref)) :-
    expand(EvalCtx ^ ec_interns, Ref, S),
    string.count_utf8_code_units(S) > max_string_bytes.
value_over_limit(_, text(S)) :-
    string.count_utf8_code_units(S) > max_string_bytes.
value_over_limit(_, json(J)) :-
    limit_breach(J) = yes(_).

    % A cached value's `ds_json_value` wrapper has no evaluator arm: this reads through
    % it, the one position the compiler emits it.
    %
:- func unwrapped_cache_value(expr) = expr.

unwrapped_cache_value(Expr) =
    ( if untainted(Expr) = e_call(fn_json_value, [Inner]) then Inner else Expr ).

:- pred cache_value(eval_ctx::in, expr::in, string::out) is semidet.

cache_value(EvalCtx, Expr, Json) :-
    eval(unwrapped_cache_value(Expr), EvalCtx, Outcome),
    (
        Outcome = ev_ok(V)
    ;
        % Unreached: `cache_set_verb` abandons on a faulted value first.
        Outcome = ev_fault(_),
        V = null
    ),
    json_value_text(EvalCtx, V, Json).

    % A `null` is stored as `null` [LNUL.11.1], the only value the default arm meets.
    %
:- pred json_value_text(eval_ctx::in, ds_value::in, string::out) is semidet.

json_value_text(Ctx, V, Text) :-
    ( if V = float(F) then
        not float.is_nan_or_inf(F),
        Text = bare_float(F)
    else if json_scalar(Ctx, V, Rendered) then
        Text = Rendered
    else
        Text = "null"
    ).

:- pred cache_delete_verb(exec_ctx::in, activation::in, expr::in,
                          bind_frame::in, effect_log::in, effect_log::out,
                          exec_state::in, exec_state::out) is det.

cache_delete_verb(Ctx, Activation, KeyExpr, Frame, !Log, !S) :-
    EvalCtx = eval_context(Ctx, Activation, !.S, Frame),
    ( if first_fault(EvalCtx, [KeyExpr]) = yes(Fault) then
        abandon(Ctx, Activation, Fault, !Log, !S)
    else if cache_key(Ctx, EvalCtx, KeyExpr, Key) then
        cache_delete(Key, !.S ^ xs_cache, NewCache),
        !S ^ xs_cache := NewCache,
        emit_event(se_cache_delete(Key), !Log)
    else
        % A key that did not render.
        true
    ).

:- pred cache_key(exec_ctx::in, eval_ctx::in, expr::in, string::out) is semidet.

cache_key(_Ctx, EvalCtx, Expr, Key) :-
    eval_text(Expr, EvalCtx, text_ok(Key)).

    % [LTIM.1.1.5]: the firing's sample plus the TTL would pass INT64_MAX, so
    % NOT_REPRESENTABLE, with no origin.
    %
:- func cache_deadline_past_range(exec_ctx, eval_ctx, maybe(expr))
    = maybe(raised).

cache_deadline_past_range(Ctx, EvalCtx, Ttl) = Found :-
    ( if
        Ttl = yes(Expr),
        eval(Expr, EvalCtx, ev_ok(V)),
        ttl_nanos(V, Ns),
        ltim_1_1_5_deadline_past_range(Ctx ^ xc_now, duration_from_ns(Ns))
    then
        Found = yes(raised(rf_not_representable, no_origin))
    else
        Found = no
    ).

:- func cache_deadline(exec_ctx, eval_ctx, maybe(expr)) = maybe(instant).

cache_deadline(Ctx, EvalCtx, Ttl) = Deadline :-
    ( if
        Ttl = yes(Expr),
        eval(Expr, EvalCtx, ev_ok(V)),
        ttl_nanos(V, Ns),
        Ns > 0u64
    then
        Deadline = yes(add(Ctx ^ xc_now, duration_from_ns(Ns)))
    else
        % No expiry: `0` is the sentinel [IDSP.7], and a negative TTL or one of another
        % kind takes it too.
        Deadline = no
    ).

    % A TTL as nanoseconds: the wire carries a bare `lit_int` or a `duration`. Guarded
    % before the cast, which would wrap a negative.
    %
:- pred ttl_nanos(ds_value::in, uint64::out) is semidet.

ttl_nanos(duration(D), duration_ns(D)).
ttl_nanos(int(I), uint64.cast_from_int64(I)) :-
    I > 0i64.

%-----------------------------------------------------------------------------%

    % `ALOG`. A value the renderer cannot render faults, and abandons the activation.
    % The log category is the rule name [RLOW.7.7.1].
    %
:- pred message_verb(exec_ctx::in, activation::in, expr::in,
                     message_event::in, action::in,
                     bind_frame::in, effect_log::in, effect_log::out,
                     exec_state::in, exec_state::out) is det.

message_verb(Ctx, Activation, Message, MkEvent, Action, Frame, !Log, !S) :-
    MessageCtx = eval_context(Ctx, Activation, !.S, Frame),
    eval_text(Message, MessageCtx, Text),
    (
        Text = text_ok(Rendered),
        acted(MkEvent(Rendered), Action, !Log)
    ;
        Text = text_fault(Fault),
        % A FAULT ABANDONS THE ACTIVATION, not just the message [LERR.1].
        abandon(Ctx, Activation, raised_in(Message, MessageCtx, Fault),
            !Log, !S)
    ).

%-----------------------------------------------------------------------------%

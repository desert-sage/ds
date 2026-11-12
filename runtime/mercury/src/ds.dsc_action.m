% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.dsc_action -- decoding the TerminalNode-inline action list.
%
% `emit` and `withdraw` have action kinds of their own. The other verbs ride as
% ACTION_CALL, and the verb is the builtin code of the `CallExpr` it carries.
%
% `emit` is sparse (`SlotAssign`); `FN_PUBLISH` is positional, dense in schema
% declaration order. Schema names are resolved later, by `resolve_action`.
%-----------------------------------------------------------------------------%

:- module ds.dsc_action.
:- interface.

:- import_module ds.action.
:- import_module ds.builtins.
:- import_module ds.expr.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.schema.
:- import_module ds.wire.

:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%

    % A decoded action, with its schema still named.
    %
:- type inline_action
    --->    ia_assert(
                iaa_mode   :: assert_mode,
                iaa_schema :: intern_ref,
                iaa_slots  :: list(slot_assign),
                iaa_retain :: maybe(expr)
            )
            % `ACTION_ASSERT` / `ACTION_LOGICAL_ASSERT`.

    ;       ia_publish(
                iap_schema :: intern_ref,
                iap_args   :: list(expr),
                iap_retain :: maybe(expr)
            )
            % `FN_PUBLISH`, the schema name stripped from the front.
            % `iap_retain` is the wire's `ttl_override`; the resolved
            % `a_publish` drops it, since a `publish` takes no lifetime
            % ([LTIE.4.9]).

    ;       ia_call(
                iac_service :: intern_ref,
                iac_corr    :: expr,
                iac_kwargs  :: kwargs,
                iac_gate    :: maybe(list(expr))
            )
            % `iac_gate` is the per-call cooldown ([IRET.25.5.1]): the
            % `FN_RATE_ALLOW` arguments of the `IF(FN_RATE_ALLOW(...),
            % FN_CALL(...), null)` the call arrives wrapped in.

    ;       ia_cache_set(expr, expr, maybe(expr))
    ;       ia_cache_delete(expr)
    ;       ia_log(log_level, expr)

    ;       ia_bind(bind_index, expr)
            % A runtime `let`: `ACTION_CALL` whose `expr` is a `BindExpr`.

    ;       ia_hydration_call(
                iah_target  :: intern_ref,
                iah_corr    :: expr,
                iah_service :: intern_ref,
                iah_body    :: kwargs,
                iah_gate    :: maybe(list(expr))
            )
            % `verb` builds none: `FN_HYDRATION_CALL` has no handler while
            % hydration is deferred.

    ;       ia_withdraw(int)
            % `ACTION_WITHDRAW`: a zero-based token position, field 6.

    ;       ia_withdraw_by_id(expr)
            % `ACTION_WITHDRAW_BY_ID`: the expression, field 7, reads the fact
            % reference the capture fact carries ([IRET.10.7]).

    ;       ia_operands_not_admitted(
                iana_op   :: builtin_fn,
                iana_args :: list(expr),
                iana_gate :: maybe(list(expr))
            )
            % A verb or mechanism whose operands its op does not admit: it loads
            % ([RDSC.4a.9.3]), and running it raises `ARTEFACT_LIED`. A `publish`
            % whose value count is not its schema's is found at `resolve_action`.
            % A gate that denies means nothing is raised.

    ;       ia_internal(builtin_fn, list(expr)).
            % The retracts, which the compiler lowers into the list and the
            % language has no verb for.

:- type action_result
    --->    ia_ok(inline_action, intern_table)
    ;       ia_error(load_error_kind, string).       % kind, clause id

:- pred decode_action(reader::in, bind_scope::in, intern_table::in,
                      action_result::out) is det.

:- type resolve_result
    --->    ra_ok(action)
    ;       ra_error(load_error_kind, string).

    % Names to `schema_id`, and publish's positional arguments to slot assignments.
    %
:- pred resolve_action(inline_action::in, list(schema)::in, intern_table::in,
                       resolve_result::out) is det.

:- pred find_schema(list(schema)::in, intern_ref::in, schema::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.dsc_expr.
:- import_module ds.value.

:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module pair.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%

    % Accumulated first, since proto3 permits any field order. `ds.dsc_judge` has
    % refused a singular message arriving twice ([RDSC.9.5]).
    %
:- type act_acc
    --->    act_acc(
                aa_kind   :: uint32,
                aa_expr   :: maybe(reader),
                aa_schema :: string,
                aa_assign :: list(reader),      % reverse encounter order
                aa_ttl    :: maybe(reader),
                aa_withdraw :: uint32,          % field 6; 0 when absent
                aa_withdraw_id :: maybe(reader) % field 7
            ).

decode_action(R, Scope, IT0, Result) :-
    Blank = act_acc(0u32, no, "", [], no, 0u32, no),
    fold_fields(R, action_field, Blank, Folded),
    (
        Folded = ff_ok(A),
        interpret(A, Scope, IT0, Result)
    ;
        Folded = ff_bad_field,
        Result = ia_error(lek_decode, "RDSC.11.1")
    ;
        Folded = ff_wire(_),
        Result = ia_error(lek_decode, "RFCS.19.1")
    ).

:- pred action_field(uint32::in, field_value::in, act_acc::in, act_acc::out)
    is semidet.

action_field(Num, Value, A0, A) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), A = A0 ^ aa_kind := uint32.cast_from_uint64(V)
    else if Num = 2u32 then
        Value = fv_bytes(Sub), A = A0 ^ aa_expr := yes(Sub)
    else if Num = 3u32 then
        Value = fv_bytes(Sub), reader_string(Sub, S),
        A = A0 ^ aa_schema := S
    else if Num = 4u32 then
        Value = fv_bytes(Sub), A = A0 ^ aa_assign := [Sub | A0 ^ aa_assign]
    else if Num = 5u32 then
        Value = fv_bytes(Sub), A = A0 ^ aa_ttl := yes(Sub)
    else if Num = 6u32 then
        Value = fv_varint(V), A = A0 ^ aa_withdraw := uint32.cast_from_uint64(V)
    else if Num = 7u32 then
        Value = fv_bytes(Sub), A = A0 ^ aa_withdraw_id := yes(Sub)
    else
        A = A0
    ).

%-----------------------------------------------------------------------------%

    % ACTION_CALL = 0, ACTION_ASSERT = 1, ACTION_LOGICAL_ASSERT = 2,
    % ACTION_WITHDRAW = 3, ACTION_WITHDRAW_BY_ID = 4. proto3 omits a zero, so a
    % call carries no `kind`, and a withdraw with no field 6 is position 0.
    %
:- pred interpret(act_acc::in, bind_scope::in, intern_table::in,
                  action_result::out) is det.

interpret(A, Scope, IT0, Result) :-
    Kind = A ^ aa_kind,
    ( if Kind = 1u32 then
        assert_action(plain, A, Scope, IT0, Result)
    else if Kind = 2u32 then
        assert_action(logical, A, Scope, IT0, Result)
    else if Kind = 0u32 then
        call_action(A, Scope, IT0, Result)
    else if Kind = 3u32 then
        % [RDSC.4a.9.1]: 0..254, with no marker.
        ( if wire_fact_index(A ^ aa_withdraw, token_fact(Position)) then
            Result = ia_ok(ia_withdraw(Position), IT0)
        else
            Result = ia_error(lek_semantic, "RDSC.4a.9.1")
        )
    else if Kind = 4u32 then
        withdraw_by_id_action(A, Scope, IT0, Result)
    else
        Result = ia_error(lek_semantic, "RDSC.4a.3")
    ).

:- pred withdraw_by_id_action(act_acc::in, bind_scope::in, intern_table::in,
                              action_result::out) is det.

withdraw_by_id_action(A, Scope, IT0, Result) :-
    (
        A ^ aa_withdraw_id = no,
        % [RDSC.11.3]: a withdraw aimed at nothing has no meaning.
        Result = ia_error(lek_semantic, "RDSC.11.3")
    ;
        A ^ aa_withdraw_id = yes(Sub),
        decode_expr(Sub, Scope, IT0, XR),
        (
            XR = xr_ok(E, IT1),
            Result = ia_ok(ia_withdraw_by_id(E), IT1)
        ;
            XR = xr_error(K, C),
            Result = ia_error(K, C)
        )
    ).

%-----------------------------------------------------------------------------%
% ACTION_ASSERT / ACTION_LOGICAL_ASSERT -- `emit`
%-----------------------------------------------------------------------------%

:- pred assert_action(assert_mode::in, act_acc::in, bind_scope::in,
                      intern_table::in, action_result::out) is det.

assert_action(Mode, A, Scope, IT0, Result) :-
    ( if A ^ aa_schema = "" then
        Result = ia_error(lek_dangling, "RDSC.8.7")
    else
        intern(A ^ aa_schema, SchemaRef, IT0, IT1),
        decode_assigns(list.reverse(A ^ aa_assign), Scope, [], IT1, AsgRes),
        (
            AsgRes = as_error(K, C),
            Result = ia_error(K, C)
        ;
            AsgRes = as_ok(Slots, IT2),
            decode_opt_expr(A ^ aa_ttl, Scope, IT2, TtlRes),
            (
                TtlRes = oe_error(K, C),
                Result = ia_error(K, C)
            ;
                TtlRes = oe_ok(Ttl, IT3),
                Result = ia_ok(ia_assert(Mode, SchemaRef, Slots, Ttl), IT3)
            )
        )
    ).

:- type assigns_result
    --->    as_ok(list(slot_assign), intern_table)
    ;       as_error(load_error_kind, string).

:- pred decode_assigns(list(reader)::in, bind_scope::in, list(slot_assign)::in,
                       intern_table::in, assigns_result::out) is det.

decode_assigns([], _, Acc, IT, as_ok(list.reverse(Acc), IT)).
decode_assigns([R | Rs], Scope, Acc, IT0, Result) :-
    decode_one_assign(R, Scope, IT0, One),
    (
        One = sa_error(K, C),
        Result = as_error(K, C)
    ;
        One = sa_ok(S, IT1),
        decode_assigns(Rs, Scope, [S | Acc], IT1, Result)
    ).

:- type one_assign_result
    --->    sa_ok(slot_assign, intern_table)
    ;       sa_error(load_error_kind, string).

    % `SlotAssign { uint32 slot_index = 1; Expr expr = 2; }`
    %
:- pred decode_one_assign(reader::in, bind_scope::in, intern_table::in,
                          one_assign_result::out) is det.

decode_one_assign(R, Scope, IT0, Result) :-
    fold_fields(R, assign_field, {0u32, no}, Folded),
    (
        Folded = ff_ok({Ix, MaybeExpr}),
        ( if MaybeExpr = no then
            Result = sa_error(lek_semantic, "RDSC.11.3")
        else if
            MaybeExpr = yes(Sub),
            wire_slot_strict(Ix, SlotIx)
        then
            decode_expr(Sub, Scope, IT0, XR),
            (
                XR = xr_ok(E, IT1),
                Result = sa_ok(slot_assign(SlotIx, E), IT1)
            ;
                XR = xr_error(K, C),
                Result = sa_error(K, C)
            )
        else
            Result = sa_error(lek_semantic, "RDSC.4a.9.1")
        )
    ;
        Folded = ff_bad_field,
        Result = sa_error(lek_decode, "RDSC.11.1")
    ;
        Folded = ff_wire(_),
        Result = sa_error(lek_decode, "RFCS.19.1")
    ).

:- pred assign_field(uint32::in, field_value::in,
                     {uint32, maybe(reader)}::in,
                     {uint32, maybe(reader)}::out)
    is semidet.

assign_field(Num, Value, {Ix0, E0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), Acc = {uint32.cast_from_uint64(V), E0}
    else if Num = 2u32 then
        Value = fv_bytes(Sub), Acc = {Ix0, yes(Sub)}
    else
        Acc = {Ix0, E0}
    ).

%-----------------------------------------------------------------------------%
% ACTION_CALL
%-----------------------------------------------------------------------------%

:- pred call_action(act_acc::in, bind_scope::in, intern_table::in,
                    action_result::out) is det.

call_action(A, Scope, IT0, Result) :-
    (
        A ^ aa_expr = no,
        % A wholly empty `Action` decodes as kind 0, so it reaches this arm.
        Result = ia_error(lek_semantic, "RDSC.11.3")
    ;
        A ^ aa_expr = yes(Sub),
        decode_expr(Sub, Scope, IT0, XR),
        (
            XR = xr_error(K, C),
            Result = ia_error(K, C)
        ;
            XR = xr_ok(E, IT1),
            decode_opt_expr(A ^ aa_ttl, Scope, IT1, TtlRes),
            (
                TtlRes = oe_error(K, C),
                Result = ia_error(K, C)
            ;
                TtlRes = oe_ok(Ttl, IT2),
                classify(E, Ttl, IT2, Result)
            )
        )
    ).

:- pred classify(expr::in, maybe(expr)::in, intern_table::in,
                 action_result::out) is det.

classify(E0, Ttl, IT, Result) :-
    % A verb's call is stamped tainted when an argument reads a `Json` leaf; its
    % arguments are classified at their own nodes.
    E = untainted(E0),
    (
        E = e_bind(Ix, Bound),
        Result = ia_ok(ia_bind(Ix, Bound), IT)
    ;
        E = e_call(Fn, Args),
        verb(Fn, Args, Ttl, IT, Result)
    ;
        E = e_if(Cond, Then, Else),
        % The per-call cooldown ([IRET.25.5.1]) is the only conditional action.
        ( if
            untainted(Cond) = e_call(fn_rate_allow, GateArgs),
            untainted(Then) = e_call(CallFn, CallArgs),
            ( CallFn = fn_call ; CallFn = fn_hydration_call ),
            Else = e_lit(null)
        then
            verb(CallFn, CallArgs, Ttl, IT, CallResult),
            ( if CallResult = ia_ok(ia_call(Svc, Corr, Kwargs, no), IT1) then
                Result = ia_ok(ia_call(Svc, Corr, Kwargs, yes(GateArgs)), IT1)
            else if
                CallResult = ia_ok(ia_operands_not_admitted(Op, Args, no), IT1)
            then
                Result = ia_ok(ia_operands_not_admitted(Op, Args,
                    yes(GateArgs)), IT1)
            else if
                CallResult = ia_ok(
                    ia_hydration_call(Target, Corr, Svc, Kwargs, no), IT1)
            then
                Result = ia_ok(ia_hydration_call(Target, Corr, Svc, Kwargs,
                    yes(GateArgs)), IT1)
            else
                Result = CallResult
            )
        else
            Result = ia_error(lek_semantic, "RDSC.11.1")
        )
    ;
        ( E = e_lit(_) ; E = e_slot(_, _) ; E = e_slot_named(_, _)
        ; E = e_json_path(_, _) ; E = e_json_path_expr(_, _)
        ; E = e_binop(_, _, _) ; E = e_unop(_, _) ; E = e_interp(_)
        ; E = e_agg(_) ; E = e_now ; E = e_entry_stamp(_)
        ; E = e_coalesce(_, _) ; E = e_bind_ref(_)
        ; E = e_is_test(_, _, _)
        ; E = e_tainted(_)
          % Unreachable: `untainted` removed every wrapper above.
        ),
        Result = ia_error(lek_semantic, "RDSC.11.1")
    ).

    % Any call at an action's top with no arm here has no handler at that site
    % ([RDSC.4a.9.3]).
    %
:- pred verb(builtin_fn::in, list(expr)::in, maybe(expr)::in, intern_table::in,
             action_result::out) is det.

verb(Fn, Args, Ttl, IT, Result) :-
    ( if
        rdsc_4a_9_3_verb(Fn),
        not rdsc_4a_9_3_verb_admits(Fn, Args)
    then
        Result = ia_ok(ia_operands_not_admitted(Fn, Args, no), IT)
    else if Fn = fn_log, Args = [e_lit(int(N)), _RuleName, Msg] then
        % The middle argument is the rule name, which the terminal knows.
        ( if log_level(N, Level) then
            Result = ia_ok(ia_log(Level, Msg), IT)
        else
            Result = ia_error(lek_semantic, "RDSC.4a.3")
        )
    else if Fn = fn_publish, Args = [e_lit(str(Schema)) | Slots] then
        Result = ia_ok(ia_publish(Schema, Slots, Ttl), IT)
    else if Fn = fn_call, Args = [e_lit(str(Svc)), Corr | Operands] then
        % The kwargs are the call's own operands ([RLOW.7.3.1]). An odd count is
        % not admitted above; a name not a string literal is malformed.
        ( if pairs(Operands, IT, [], Pairs) then
            Result = ia_ok(ia_call(Svc, Corr, make_kwargs(Pairs), no), IT)
        else
            Result = ia_error(lek_decode, "RDSC.11.1")
        )
    else if Fn = fn_cache_set, Args = [Key, Val, TtlArg] then
        Result = ia_ok(ia_cache_set(Key, Val, yes(TtlArg)), IT)
    else if Fn = fn_cache_delete, Args = [Key] then
        Result = ia_ok(ia_cache_delete(Key), IT)
    else if internal_action(Fn) then
        Result = ia_ok(ia_internal(Fn, Args), IT)
    else
        Result = ia_error(lek_fn_not_found, "RDSC.4a.9.3")
    ).

    %@spec [RDSC.4a.9.3]
:- pred rdsc_4a_9_3_verb(builtin_fn::in) is semidet.

rdsc_4a_9_3_verb(fn_log).
rdsc_4a_9_3_verb(fn_publish).
rdsc_4a_9_3_verb(fn_call).
rdsc_4a_9_3_verb(fn_cache_set).
rdsc_4a_9_3_verb(fn_cache_delete).
rdsc_4a_9_3_verb(fn_retract_token_fact).
rdsc_4a_9_3_verb(fn_retract_corr).

    %@spec [RDSC.4a.9.3]
:- pred rdsc_4a_9_3_verb_admits(builtin_fn::in, list(expr)::in) is semidet.

rdsc_4a_9_3_verb_admits(Fn, Args) :-
    rdsc_4a_9_5_admits(Fn, list.length(Args)).

:- pred internal_action(builtin_fn::in) is semidet.

internal_action(fn_retract_token_fact).
internal_action(fn_retract_corr).

%-----------------------------------------------------------------------------%
% Helpers
%-----------------------------------------------------------------------------%

    % A literal, or an expression evaluated once at dispatch. A `null` is decoded
    % as the expression it is, and `ds.exec.resolve_correlation` refuses the call.
    %
:- func correlation_of(intern_table, expr) = correlation.

correlation_of(_, CorrExpr) = Correlation :-
    ( if CorrExpr = e_lit(str(Ref)) then
        Correlation = correlated(Ref)
    else
        Correlation = correlated_expr(CorrExpr)
    ).

    % `"k1", v1, "k2", v2, ...` -> pairs. Fails on an odd length.
    %
:- pred pairs(list(expr)::in, intern_table::in,
              assoc_list(string, expr)::in, assoc_list(string, expr)::out)
    is semidet.

pairs([], _, Acc, list.reverse(Acc)).
pairs([e_lit(str(Ref)), V | Rest], IT, Acc, Out) :-
    expand(IT, Ref, Name),
    pairs(Rest, IT, [Name - V | Acc], Out).

:- type opt_expr_result
    --->    oe_ok(maybe(expr), intern_table)
    ;       oe_error(load_error_kind, string).

    % `ttl_override`, field 5 [LDTL.4.1].
    %
:- pred decode_opt_expr(maybe(reader)::in, bind_scope::in, intern_table::in,
                        opt_expr_result::out) is det.

decode_opt_expr(no, _, IT, oe_ok(no, IT)).
decode_opt_expr(yes(R), Scope, IT0, Result) :-
    decode_expr(R, Scope, IT0, XR),
    (
        XR = xr_ok(E, IT1),
        Result = oe_ok(yes(E), IT1)
    ;
        XR = xr_error(K, C),
        Result = oe_error(K, C)
    ).

%-----------------------------------------------------------------------------%
% Resolution -- names to ids, and publish's positional args to assignments
%-----------------------------------------------------------------------------%

resolve_action(IA, Schemas, IT, Result) :-
    (
        IA = ia_assert(Mode, SchemaRef, Slots, Ttl),
        ( if find_schema(Schemas, SchemaRef, Schema) then
            Result = ra_ok(a_emit(Schema ^ s_id, Slots, Mode, Ttl))
        else
            Result = ra_error(lek_dangling, "RDSC.8.7")
        )
    ;
        IA = ia_publish(SchemaRef, Args, _Ttl),
        ( if find_schema(Schemas, SchemaRef, Schema) then
            positional_slots(slot_commons(Schema), Args, [], Slots, Ok),
            ( if
                not list.same_length(Args, slot_commons(Schema))
            then
                % One value per slot ([IRET.27.5]); any other count loads and
                % raises when it runs ([RDSC.4a.9.3]).
                Result = ra_ok(a_operands_not_admitted(fn_publish,
                    [e_lit(str(SchemaRef)) | Args], no))
            else if
                Ok = yes
            then
                Result = ra_ok(a_publish(Schema ^ s_id, Slots))
            else
                % Unreachable: the lengths are equal.
                Result = ra_error(lek_dangling, "RDSC.8.7")
            )
        else
            Result = ra_error(lek_dangling, "RDSC.8.7")
        )
    ;
        IA = ia_call(Svc, CorrExpr, Kwargs, Gate),
        Result = ra_ok(a_call(Svc, correlation_of(IT, CorrExpr), Kwargs, Gate))
    ;
        IA = ia_cache_set(Key, Val, Ttl),
        Result = ra_ok(a_cache_set(Key, Val, Ttl))
    ;
        IA = ia_cache_delete(Key),
        Result = ra_ok(a_cache_delete(Key))
    ;
        IA = ia_log(Level, Msg),
        Result = ra_ok(a_log(Level, Msg))
    ;
        IA = ia_withdraw(Position),
        Result = ra_ok(a_withdraw(Position))
    ;
        IA = ia_withdraw_by_id(Fact),
        Result = ra_ok(a_withdraw_by_id(Fact))
    ;
        IA = ia_operands_not_admitted(Fn, Args, Gate),
        Result = ra_ok(a_operands_not_admitted(Fn, Args, Gate))
    ;
        IA = ia_internal(Fn, Args),
        ( if Fn = fn_retract_token_fact then
            Result = ra_ok(a_retract_token_fact(Args))
        else if Fn = fn_retract_corr then
            Result = ra_ok(a_retract_corr(Args))
        else
            Result = ra_error(lek_semantic, "RDSC.4a.3")
        )
    ;
        IA = ia_hydration_call(Target, CorrExpr, Svc, Kwargs, Gate),
        Result = ra_ok(a_hydration_call(Target,
            correlation_of(IT, CorrExpr), Svc, Kwargs, Gate))
    ;
        IA = ia_bind(Ix, E),
        Result = ra_ok(a_bind(Ix, E))
    ).

    % The i-th argument is the i-th slot in declaration order, its index from
    % `sc_index`. `no` says there were more arguments than slots.
    %
:- pred positional_slots(list(slot_common)::in, list(expr)::in,
                         list(slot_assign)::in, list(slot_assign)::out,
                         bool::out) is det.

positional_slots(_, [], Acc, list.reverse(Acc), yes).
positional_slots([], [_ | _], Acc, list.reverse(Acc), no).
positional_slots([Slot | Slots], [Arg | Args], Acc, Out, Ok) :-
    positional_slots(Slots, Args, [slot_assign(Slot ^ sc_index, Arg) | Acc],
                     Out, Ok).

find_schema([S | Ss], Name, Found) :-
    ( if schema_name_ref(S ^ s_name) = Name then
        Found = S
    else
        find_schema(Ss, Name, Found)
    ).

%-----------------------------------------------------------------------------%
:- end_module ds.dsc_action.
%-----------------------------------------------------------------------------%

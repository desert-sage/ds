% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.action -- the RHS action verbs, and the fire steps beside them.
%
% No verb takes a synchronous result from the integrator, which lets the
% rule-evaluation core be a pure function returning an effect list.
%-----------------------------------------------------------------------------%

:- module ds.action.
:- interface.

:- import_module ds.builtins.
:- import_module ds.expr.
:- import_module ds.id.
:- import_module assoc_list.
:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%
% Canonically-ordered arguments
%-----------------------------------------------------------------------------%

    % In wire order, which the compiler sorts by name ([RLOW.7.3.1]) and nothing
    % here re-sorts. Evaluation runs in it, so it decides which kwarg's fault is
    % raised.
    %
:- type kwargs.

:- func make_kwargs(assoc_list(string, expr)) = kwargs.
:- func kwarg_list(kwargs) = assoc_list(string, expr).

%-----------------------------------------------------------------------------%
% Pieces
%-----------------------------------------------------------------------------%

    % `SlotAssign` carries a name on the wire; the loader resolves it to this
    % index.
    %
:- type slot_assign
    --->    slot_assign(
                sa_slot  :: slot_index,
                sa_value :: expr
            ).

    % Whether an `emit` registers its firing activation as a TMS justifier: an
    % adapter's assert of a `logical` schema's fact does not ([LLOG.15.1]).
    %
:- type assert_mode
    --->    plain
    ;       logical.

    % The engine never mints one: the compiler's `fn_gensym` bind survives
    % replay as engine state.
    %
:- type correlation
    --->    correlated(intern_ref)
    ;       correlated_expr(expr).
            % `as <expr>`, evaluated once, at dispatch ([IRET.25.5.1]).

    % The log category is the rule name, derived from the terminal.
    %
:- type log_level
    --->    log_debug           % 0
    ;       log_info            % 1
    ;       log_warning         % 2
    ;       log_error           % 3
    ;       log_critical.       % 4

    % `FN_LOG`'s first argument. There is no sentinel: 0 is DEBUG.
    %
:- pred log_level(int64::in, log_level::out) is semidet.

%-----------------------------------------------------------------------------%
% The verbs
%-----------------------------------------------------------------------------%

:- type action
    --->    a_emit(
                ae_schema :: schema_id,
                ae_slots  :: list(slot_assign),
                ae_mode   :: assert_mode,
                ae_retain :: maybe(expr)
            )
            % `ACTION_ASSERT` / `ACTION_LOGICAL_ASSERT`. The compiler emits
            % `retain: <dur>` as a slot assignment named `retain`, which the
            % schema does not declare.

    ;       a_publish(
                ap_schema :: schema_id,
                ap_slots  :: list(slot_assign)
            )
            % `FN_PUBLISH`, as an `ACTION_CALL`. It sends upstream and asserts
            % nothing in this tier ([LTIE.4.3]), and takes no lifetime
            % ([LTIE.4.9]); its values are judged as an `emit`'s ([LTIE.4.8]).

    ;       a_call(
                ac_service     :: intern_ref,
                ac_correlation :: correlation,
                ac_kwargs      :: kwargs,
                ac_gate        :: maybe(list(expr))
            )
            % `FN_CALL`. `ac_gate` is the per-call cooldown ([IRET.25.5.1]): the
            % `FN_RATE_ALLOW` arguments of the `IfExpr` the compiler wraps a
            % `cooldown:` call in. `ds.exec.call_verb` runs it before the call's
            % own arguments.

    ;       a_cache_set(
                acs_key   :: expr,
                acs_value :: expr,
                acs_ttl   :: maybe(expr)
            )
            % `ACHT`. `ttl_id = 0` means no expiry.

    ;       a_cache_delete(
                acd_key :: expr
            )
            % `ACDL`.

    ;       a_log(
                al_level   :: log_level,
                al_message :: expr
            )
            % `ALOG`.

    %-------------------------------------------------------------------------%
    % Below, what the compiler lowered into the action list: this type is a
    % step of a fire, not an RHS verb.
    %-------------------------------------------------------------------------%

    ;       a_bind(
                ab_index :: bind_index,
                ab_value :: expr
            )
            % A runtime `let` [IRET.9.4]. Binds need not form a prefix of the
            % list: nothing in the format says they do.

    ;       a_retract_token_fact(
                artf_args :: list(expr)
            )
            % `FN_RETRACT_TOKEN_FACT`.

    ;       a_retract_corr(
                arc_args :: list(expr)
            )
            % `FN_RETRACT_CORR`: the supersedure sweep before a correlated
            % `call`.

    ;       a_hydration_call(
                ahc_target  :: intern_ref,
                ahc_corr    :: correlation,
                ahc_service :: intern_ref,
                ahc_body    :: kwargs,
                ahc_gate    :: maybe(list(expr))
            )
            % `FN_HYDRATION_CALL`: the budget gate, supersedure sweep and series
            % skip as one step. Its body is a `ds_json_build(...)` call, decoded
            % to `kwargs`, since this runtime has no evaluator for that builtin.
            % `ahc_gate` is the per-call cooldown, as `ac_gate` is.

    ;       a_withdraw(
                aw_position :: int
            )
            % `withdraw <binding>` ([IRET.10.5]): a zero-based position in the
            % firing token. A fact already gone is a no-op, and the actions
            % after it still run.

    ;       a_withdraw_by_id(
                awi_fact :: expr
            )
            % `withdraw <binding>` in a nested body ([IRET.10.7]): the expression
            % gives a fact reference captured when the outer rule fired. A
            % reference to a fact no longer live is a no-op; a meaningful change
            % makes a new fact ([LFAC.2.5.3]), so its successor is not reached.

    ;       a_operands_not_admitted(
                ana_op   :: builtin_fn,
                ana_args :: list(expr),
                ana_gate :: maybe(list(expr))
            ).
            % A verb or mechanism whose operands its op does not admit, loaded
            % because [RDSC.4a.9.3] forbids the check at load. Running it
            % evaluates the operands and raises `ARTEFACT_LIED`, or the fault
            % of an operand; a gate that denies stops it before either.

    % An action list is in emission order, with no sequence field: reordering
    % one changes rule semantics [IRET.10].

%-----------------------------------------------------------------------------%
% The error policy
%-----------------------------------------------------------------------------%

    % [LNUL.11.1]'s table, verb by verb. Nothing in `ds.exec` consults this.
    %
:- type arg_error_policy
    --->    degrade
    ;       substitute
    ;       abort.

:- func arg_error_policy(action) = arg_error_policy.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module pair.
:- import_module string.

%-----------------------------------------------------------------------------%

:- type kwargs ---> kwargs(assoc_list(string, expr)).

make_kwargs(Pairs) = kwargs(Pairs).

kwarg_list(kwargs(Ps)) = Ps.

%-----------------------------------------------------------------------------%

log_level(0i64, log_debug).
log_level(1i64, log_info).
log_level(2i64, log_warning).
log_level(3i64, log_error).
log_level(4i64, log_critical).

%-----------------------------------------------------------------------------%

arg_error_policy(a_log(_, _)) = degrade.

arg_error_policy(a_emit(_, _, _, _)) = substitute.
arg_error_policy(a_publish(_, _)) = substitute.

arg_error_policy(a_call(_, _, _, _)) = abort.

    % The rest are not verbs, so the table doesn't reach them.

arg_error_policy(a_bind(_, _)) = substitute.
arg_error_policy(a_withdraw(_)) = abort.
arg_error_policy(a_withdraw_by_id(_)) = abort.
arg_error_policy(a_retract_token_fact(_)) = abort.
arg_error_policy(a_retract_corr(_)) = abort.
arg_error_policy(a_hydration_call(_, _, _, _, _)) = abort.
arg_error_policy(a_operands_not_admitted(_, _, _)) = abort.
arg_error_policy(a_cache_set(_, _, _)) = substitute.
arg_error_policy(a_cache_delete(_)) = substitute.

%-----------------------------------------------------------------------------%

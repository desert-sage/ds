% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.libcall -- a call to a `math` or `distance` member, rewritten to its row.
%
% Runs before the file is resolved, so every later phase sees one spelling, the
% [LEXP.17.2] row. The file's own import lines are the whole input. A bare `sin`
% with no import names no row and is refused later. An interpolation site holds no
% call, so it needs no rewrite. Idempotent.
%-----------------------------------------------------------------------------%

:- module dsc.libcall.
:- interface.

:- import_module dsc.ast.

:- import_module list.
:- import_module map.

%-----------------------------------------------------------------------------%

    % The `math` / `distance` bindings a file's import lines make: each bare
    % member's binding to its row, and each whole-module binding to the module.
    %
    %@helper
:- type libcall_scope
    --->    libcall_scope(
                lcs_members :: map(string, string),
                lcs_modules :: map(string, string),

                    % Each bare binding of a `math` constant to its qualified
                    % name. Read in a unit body only.
                lcs_consts  :: map(string, string)
            ).

    %@spec [LIMP.3.3.4]
:- func limp_3_3_4_scope(list(ast_decl)) = libcall_scope.

    %@spec [LIMP.3.3.4]
    %@spec [LGRA.22.9]
:- func limp_3_3_4_rewrite_file(ast_file) = ast_file.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.builtins.
:- import_module dsc.expr.
:- import_module dsc.imports.
:- import_module dsc.token.

:- import_module maybe.
:- import_module string.

%-----------------------------------------------------------------------------%

limp_3_3_4_scope(Decls) =
    list.foldl(lc_import, Decls, libcall_scope(map.init, map.init, map.init)).

    %@spec [LIMP.3.3.4]
:- pred limp_3_3_4_math_constant(string::in) is semidet.

limp_3_3_4_math_constant("pi").
limp_3_3_4_math_constant("e").
limp_3_3_4_math_constant("tau").

    %@helper
:- func lc_import(ast_decl, libcall_scope) = libcall_scope.

lc_import(Decl, S0) = S :-
    ( if
        Decl = ad_import(I),
        Lib = library_name(I ^ ai_path),
        limp_3_3_4_builtin_module(Lib)
    then
        (
            I ^ ai_form = aif_qualified(_, Binding),
            S = S0 ^ lcs_modules := map.set(S0 ^ lcs_modules, Binding, Lib)
        ;
            I ^ ai_form = aif_selective(Items),
            S = list.foldl(lc_member(Lib), Items, S0)
        )
    else
        S = S0
    ).

    %@helper
:- func lc_member(string, ast_import_item, libcall_scope) = libcall_scope.

lc_member(Lib, Item, S0) = S :-
    Name = Item ^ aii_name ^ id_name,
    Row = Lib ++ "." ++ Name,
    ( if lgra_22_7_builtin_fn(Row) then
        S = S0 ^ lcs_members := map.set(S0 ^ lcs_members,
            Item ^ aii_binding, Row)
    else if Lib = "math", limp_3_3_4_math_constant(Name) then
        S = S0 ^ lcs_consts := map.set(S0 ^ lcs_consts,
            Item ^ aii_binding, Row)
    else
        S = S0
    ).

limp_3_3_4_rewrite_file(File) = File ^ af_decls := Decls :-
    S = limp_3_3_4_scope(File ^ af_decls),
    ( if
        map.is_empty(S ^ lcs_members),
        map.is_empty(S ^ lcs_modules),
        map.is_empty(S ^ lcs_consts)
    then
        Decls = File ^ af_decls
    else
        Decls = list.map(lc_decl(S), File ^ af_decls)
    ).

%-----------------------------------------------------------------------------%
% Expressions
%-----------------------------------------------------------------------------%

    %@helper
:- func libcall_expr(libcall_scope, lgra_9_3_1_expr) = lgra_9_3_1_expr.

libcall_expr(S, E0) = E :-
    (
        ( E0 = ex_int(_, _)
        ; E0 = ex_float(_, _)
        ; E0 = ex_string(_, _)
        ; E0 = ex_unit(_, _, _)
        ; E0 = ex_bool(_, _)
        ; E0 = ex_null(_)
        ; E0 = ex_name(_)
        ),
        E = E0
    ;
        E0 = ex_unary(Op, X, P),
        E = ex_unary(Op, libcall_expr(S, X), P)
    ;
        E0 = ex_not(X, P),
        E = ex_not(libcall_expr(S, X), P)
    ;
        E0 = ex_binary(Op, L, R, P),
        E = ex_binary(Op, libcall_expr(S, L), libcall_expr(S, R), P)
    ;
        E0 = ex_compare(L, Steps, P),
        E = ex_compare(libcall_expr(S, L), list.map(lc_step(S), Steps), P)
    ;
        E0 = ex_is(X, N, Subject, P),
        E = ex_is(libcall_expr(S, X), N, Subject, P)
    ;
        E0 = ex_slot(X, F, P),
        E = ex_slot(libcall_expr(S, X), F, P)
    ;
        E0 = ex_index(X, I, P),
        E = ex_index(libcall_expr(S, X), libcall_expr(S, I), P)
    ;
        E0 = ex_call(Callee, Args0, P),
        Args = list.map(libcall_expr(S), Args0),
        ( if lgra_22_9_member_row(S, Callee, Row, RowPos) then
            E = ex_call(ex_name(ident(Row, RowPos)), Args, P)
        else
            E = ex_call(libcall_expr(S, Callee), Args, P)
        )
    ;
        E0 = ex_cast(X, T, N, P),
        E = ex_cast(libcall_expr(S, X), T, N, P)
    ;
        E0 = ex_match(X, Sense, Pattern, Flags, P),
        E = ex_match(libcall_expr(S, X), Sense, Pattern, Flags, P)
    ).

    %@spec [LGRA.22.9]
:- pred lgra_22_9_member_row(libcall_scope::in, lgra_9_3_1_expr::in,
                             string::out, pos::out) is semidet.

lgra_22_9_member_row(S, Callee, Row, Pos) :-
    (
        Callee = ex_name(Id),
        map.search(S ^ lcs_members, Id ^ id_name, Row),
        Pos = Id ^ id_pos
    ;
        Callee = ex_slot(ex_name(Module), Member, _),
        map.search(S ^ lcs_modules, Module ^ id_name, Lib),
        Row = Lib ++ "." ++ Member ^ id_name,
        lgra_22_7_builtin_fn(Row),
        Pos = Module ^ id_pos
    ).

    %@helper
:- func lc_step(libcall_scope, lgra_9_3_2_compare_step)
    = lgra_9_3_2_compare_step.

lc_step(S, Step) = Step ^ cs_right := libcall_expr(S, Step ^ cs_right).

    %@helper
:- func lc_maybe(libcall_scope, maybe(lgra_9_3_1_expr))
    = maybe(lgra_9_3_1_expr).

lc_maybe(_, no) = no.
lc_maybe(S, yes(E)) = yes(libcall_expr(S, E)).

%-----------------------------------------------------------------------------%
% Declarations
%-----------------------------------------------------------------------------%

    %@helper
:- func lc_decl(libcall_scope, ast_decl) = ast_decl.

lc_decl(S, D0) = D :-
    (
        ( D0 = ad_schema(_)
        ; D0 = ad_opaque(_)
        ; D0 = ad_import(_)
        ),
        D = D0
    ;
        D0 = ad_rule(R),
        D = ad_rule(lc_rule(S, R))
    ;
        D0 = ad_const(C),
        D = ad_const(lc_const(S, C))
    ;
        D0 = ad_series(Sr),
        D = ad_series(lc_series(S, Sr))
    ;
        D0 = ad_service(Sv),
        D = ad_service(lc_service(S, Sv))
    ;
        D0 = ad_unit(U),
        D = ad_unit(lc_unit(S, U))
    ;
        D0 = ad_test(T),
        D = ad_test(lc_test(S, T))
    ;
        D0 = ad_initial(I),
        D = ad_initial(I ^ ain_items := list.map(lc_test_initial(S),
            I ^ ain_items))
    ).

    %@helper
:- func lc_const(libcall_scope, ast_const) = ast_const.

lc_const(S, C) = C ^ acn_form := Form :-
    (
        C ^ acn_form = acf_value(Ann, E),
        Form = acf_value(Ann, libcall_expr(S, E))
    ;
        C ^ acn_form = acf_colon_literal(E),
        Form = acf_colon_literal(libcall_expr(S, E))
    ).

    %@helper
:- func lc_series(libcall_scope, ast_series) = ast_series.

lc_series(S, Sr) = (Sr ^ asr_opts := list.map(lc_block_kwarg(S),
        Sr ^ asr_opts))
    ^ asr_lines := list.map(lc_series_line(S), Sr ^ asr_lines).

    %@helper
:- func lc_block_kwarg(libcall_scope, ast_block_kwarg) = ast_block_kwarg.

lc_block_kwarg(S, K) =
    ( if K = abk_persist(E, P) then abk_persist(libcall_expr(S, E), P)
    else K ).

    %@helper
:- func lc_series_line(libcall_scope, ast_series_line) = ast_series_line.

lc_series_line(S, L) = (L ^ asl_time := lc_time_model(S, L ^ asl_time))
    ^ asl_accuracy := lc_accuracy(S, L ^ asl_accuracy).

    %@helper
:- func lc_time_model(libcall_scope, ast_time_model) = ast_time_model.

lc_time_model(_, atm_all_time(P)) = atm_all_time(P).
lc_time_model(S, atm_sliding(E, P)) = atm_sliding(libcall_expr(S, E), P).
lc_time_model(S, atm_tumbling(E, P)) = atm_tumbling(libcall_expr(S, E), P).
lc_time_model(S, atm_sample(E, P)) = atm_sample(libcall_expr(S, E), P).

    %@helper
:- func lc_accuracy(libcall_scope, maybe(ast_accuracy)) = maybe(ast_accuracy).

lc_accuracy(_, no) = no.
lc_accuracy(S, yes(A0)) = yes(A) :-
    (
        ( A0 = aac_exact(_)
        ; A0 = aac_bound_deterministic(_)
        ),
        A = A0
    ;
        A0 = aac_tolerance(E, P),
        A = aac_tolerance(libcall_expr(S, E), P)
    ;
        A0 = aac_confidence(E, P),
        A = aac_confidence(libcall_expr(S, E), P)
    ;
        A0 = aac_delta(E, P),
        A = aac_delta(libcall_expr(S, E), P)
    ).

    %@helper
:- func lc_service(libcall_scope, ast_service_decl) = ast_service_decl.

lc_service(S, Sv) = (Sv ^ asv_kwargs := list.map(lc_service_kwarg(S),
        Sv ^ asv_kwargs))
    ^ asv_hydration := list.map(lc_hydration_field(S), Sv ^ asv_hydration).

    %@helper
:- func lc_service_kwarg(libcall_scope, ast_service_kwarg)
    = ast_service_kwarg.

lc_service_kwarg(S, K) = K ^ ask_modifiers := list.map(
    ( func(M) = ( if M = akm_default(E, P) then
            akm_default(libcall_expr(S, E), P) else M ) ),
    K ^ ask_modifiers).

    %@helper
:- func lc_hydration_field(libcall_scope, ast_hydration_field)
    = ast_hydration_field.

lc_hydration_field(S, F0) = F :-
    (
        ( F0 = ahy_hydrates(_, _)
        ; F0 = ahy_filter_fields(_, _)
        ),
        F = F0
    ;
        F0 = ahy_max_window(E, P),
        F = ahy_max_window(libcall_expr(S, E), P)
    ;
        F0 = ahy_max_limit(E, P),
        F = ahy_max_limit(libcall_expr(S, E), P)
    ).

    %@helper
:- func lc_unit(libcall_scope, ast_unit) = ast_unit.

lc_unit(S, U0) = U :-
    (
        ( U0 = au_dimension(_, _, _, _, _)
        ; U0 = au_scalar(_, _, _, _, _)
        ),
        U = U0
    ;
        U0 = au_symbol(_, _, Body, _, _, _, _, _),
        U = U0 ^ auy_body := luni_4_3_unit_body(S, Body)
    ;
        U0 = au_formula(_, _, Lines, _),
        U = U0 ^ auf_lines := list.map(
            ( func(L) = L ^ afl_body := libcall_expr(S, L ^ afl_body) ),
            Lines)
    ;
        U0 = au_fx_pair(_, _, _, _, Where, _, _, _),
        U = U0 ^ aux_where := libcall_expr(S, Where)
    ).

    % `dsc.quantity` reads a body as a closed vocabulary, so an imported `pi`
    % becomes the name it admits, `math.pi`.
    %
    %@spec [LUNI.4.3]
:- func luni_4_3_unit_body(libcall_scope, ast_unit_body) = ast_unit_body.

luni_4_3_unit_body(_, aub_base) = aub_base.
luni_4_3_unit_body(S, aub_affine(E)) =
    aub_affine(lc_unit_const(S, libcall_expr(S, E))).
luni_4_3_unit_body(S, aub_tier2(To, From, P)) =
    aub_tier2(lc_unit_const(S, libcall_expr(S, To)),
        lc_unit_const(S, libcall_expr(S, From)), P).

    % Over the shapes a unit body admits; anything else there is refused.
    %
    %@helper
:- func lc_unit_const(libcall_scope, lgra_9_3_1_expr) = lgra_9_3_1_expr.

lc_unit_const(S, E0) = E :-
    ( if
        E0 = ex_name(Id),
        map.search(S ^ lcs_consts, Id ^ id_name, Qualified)
    then
        E = ex_name(ident(Qualified, Id ^ id_pos))
    else if
        E0 = ex_slot(ex_name(Module), Member, _),
        map.search(S ^ lcs_modules, Module ^ id_name, "math"),
        limp_3_3_4_math_constant(Member ^ id_name)
    then
        E = ex_name(ident("math." ++ Member ^ id_name, Module ^ id_pos))
    else if E0 = ex_unary(Op, X, P) then
        E = ex_unary(Op, lc_unit_const(S, X), P)
    else if E0 = ex_binary(Op, L, R, P) then
        E = ex_binary(Op, lc_unit_const(S, L), lc_unit_const(S, R), P)
    else if E0 = ex_call(Callee, Args, P) then
        E = ex_call(Callee, list.map(lc_unit_const(S), Args), P)
    else
        E = E0
    ).

%-----------------------------------------------------------------------------%
% Rules
%-----------------------------------------------------------------------------%

    %@helper
:- func lc_rule(libcall_scope, ast_rule) = ast_rule.

lc_rule(S, R) = (R ^ ar_lhs := list.map(lc_lhs_clause(S), R ^ ar_lhs))
    ^ ar_rhs := lc_rhs(S, R ^ ar_rhs).

    %@helper
:- func lc_lhs_clause(libcall_scope, ast_lhs_clause) = ast_lhs_clause.

lc_lhs_clause(S, alc_pattern(P)) = alc_pattern(lc_pattern(S, P)).
lc_lhs_clause(S, alc_then(T)) = alc_then(lc_then_step(S, T)).

    %@helper
:- func lc_pattern(libcall_scope, ast_pattern) = ast_pattern.

lc_pattern(S, ap_simple(B)) = ap_simple(lc_body(S, B)).
lc_pattern(S, ap_negated(B, P)) = ap_negated(lc_body(S, B), P).
lc_pattern(S, ap_sequence(L, Head, Steps, P)) =
    ap_sequence(L, lc_body(S, Head), list.map(lc_then_step(S), Steps), P).

    %@helper
:- func lc_then_step(libcall_scope, ast_then_step) = ast_then_step.

lc_then_step(S, T) = T ^ ats_body := lc_body(S, T ^ ats_body).

    %@helper
:- func lc_body(libcall_scope, ast_pattern_body) = ast_pattern_body.

lc_body(S, B) = (B ^ apb_where := lc_maybe(S, B ^ apb_where))
    ^ apb_capture := lc_capture(S, B ^ apb_capture).

    %@helper
:- func lc_capture(libcall_scope, maybe(ast_capture)) = maybe(ast_capture).

lc_capture(_, no) = no.
lc_capture(S, yes(C)) =
    yes(C ^ acap_match := libcall_expr(S, C ^ acap_match)).

    %@helper
:- func lc_rhs(libcall_scope, ast_rule_rhs) = ast_rule_rhs.

lc_rhs(S, Rhs) = ast_rule_rhs(
    list.map(lc_let_decl(S), Rhs ^ arr_lets),
    list.map(lc_action(S), Rhs ^ arr_actions),
    list.map(lc_after(S), Rhs ^ arr_afters)).

    %@helper
:- func lc_let_decl(libcall_scope, ast_let_decl) = ast_let_decl.

lc_let_decl(S, D) = D ^ ald_bindings := list.map(lc_let_binding(S),
    D ^ ald_bindings).

    %@helper
:- func lc_let_binding(libcall_scope, ast_let_binding) = ast_let_binding.

lc_let_binding(S, alb_simple(Id, Ann, E, P)) =
    alb_simple(Id, Ann, libcall_expr(S, E), P).
lc_let_binding(S, alb_capture(Ids, E, P)) =
    alb_capture(Ids, libcall_expr(S, E), P).

    %@helper
:- func lc_action(libcall_scope, ast_action) = ast_action.

lc_action(S, A) = ast_action(A ^ aac_head,
    list.map(lc_action_arg(S), A ^ aac_args),
    lc_action_block(S, A ^ aac_block),
    lc_maybe(S, A ^ aac_as),
    A ^ aac_pos).

    %@helper
:- func lc_action_arg(libcall_scope, ast_action_arg) = ast_action_arg.

lc_action_arg(S, aaa_kwarg(Id, E, P)) = aaa_kwarg(Id, libcall_expr(S, E), P).
lc_action_arg(_, aaa_flag(Id)) = aaa_flag(Id).

    %@helper
:- func lc_action_block(libcall_scope, ast_action_block) = ast_action_block.

lc_action_block(_, aab_none) = aab_none.
lc_action_block(S, aab_kwargs(Args)) =
    aab_kwargs(list.map(lc_action_arg(S), Args)).
lc_action_block(S, aab_call(Args, Conts)) =
    aab_call(list.map(lc_action_arg(S), Args),
        list.map(lc_continuation(S), Conts)).

    %@helper
:- func lc_continuation(libcall_scope, ast_continuation) = ast_continuation.

lc_continuation(S, acont_on(E, As, P)) =
    acont_on(libcall_expr(S, E), list.map(lc_action(S), As), P).
lc_continuation(S, acont_timeout(E, As, P)) =
    acont_timeout(libcall_expr(S, E), list.map(lc_action(S), As), P).
lc_continuation(S, acont_error(Code, As, P)) =
    acont_error(Code, list.map(lc_action(S), As), P).

    %@helper
:- func lc_after(libcall_scope, ast_after_clause) = ast_after_clause.

lc_after(S, A) = ast_after_clause(
    libcall_expr(S, A ^ aaf_duration),
    lc_maybe(S, A ^ aaf_as),
    list.map(lc_action(S), A ^ aaf_actions),
    list.map(lc_after(S), A ^ aaf_nested),
    A ^ aaf_pos).

%-----------------------------------------------------------------------------%
% Tests
%-----------------------------------------------------------------------------%

    %@helper
:- func lc_test(libcall_scope, ast_test) = ast_test.

lc_test(S, T) = (T ^ tst_name := libcall_expr(S, T ^ tst_name))
    ^ tst_sections := list.map(lc_test_section(S), T ^ tst_sections).

    %@helper
:- func lc_test_section(libcall_scope, ast_test_section) = ast_test_section.

lc_test_section(S, tsec_initial(Is, P)) =
    tsec_initial(list.map(lc_test_initial(S), Is), P).
lc_test_section(S, tsec_inputs(Ats, P)) =
    tsec_inputs(list.map(lc_test_at(S), Ats), P).
lc_test_section(S, tsec_responses(Stubs, P)) =
    tsec_responses(list.map(lc_test_stub(S), Stubs), P).
lc_test_section(S, tsec_produces(As, P)) =
    tsec_produces(list.map(lc_test_assertion(S), As), P).
lc_test_section(S, tsec_until(E, P)) = tsec_until(libcall_expr(S, E), P).

    %@helper
:- func lc_test_initial(libcall_scope, ast_test_initial) = ast_test_initial.

lc_test_initial(S, tini_fact(F)) = tini_fact(lc_test_fact(S, F)).
lc_test_initial(S, tini_cache(K, V, P)) =
    tini_cache(libcall_expr(S, K), libcall_expr(S, V), P).

    %@helper
:- func lc_test_fact(libcall_scope, ast_test_fact) = ast_test_fact.

lc_test_fact(S, F) =
    F ^ tfa_args := list.map(lc_action_arg(S), F ^ tfa_args).

    %@helper
:- func lc_test_at(libcall_scope, ast_test_at) = ast_test_at.

lc_test_at(S, At) = (At ^ tat_when := libcall_expr(S, At ^ tat_when))
    ^ tat_facts := list.map(lc_test_fact(S), At ^ tat_facts).

    %@helper
:- func lc_test_stub(libcall_scope, ast_test_stub) = ast_test_stub.

lc_test_stub(S, St) = ast_test_stub(St ^ tstb_service,
    list.map(lc_action_arg(S), St ^ tstb_args),
    lc_maybe(S, St ^ tstb_corr),
    lc_maybe(S, St ^ tstb_after),
    list.map(lc_test_reply(S), St ^ tstb_replies),
    St ^ tstb_pos).

    %@helper
:- func lc_test_reply(libcall_scope, ast_test_reply) = ast_test_reply.

lc_test_reply(S, trep_fact(F)) = trep_fact(lc_test_fact(S, F)).
lc_test_reply(_, trep_no_response(P)) = trep_no_response(P).

    %@helper
:- func lc_test_assertion(libcall_scope, ast_test_assertion)
    = ast_test_assertion.

lc_test_assertion(S, A) = A ^ tas_head := lc_test_head(S, A ^ tas_head).

    %@helper
:- func lc_test_head(libcall_scope, ast_test_head) = ast_test_head.

lc_test_head(S, H0) = H :-
    (
        ( H0 = thd_activated(_)
        ; H0 = thd_recorded(_)
        ; H0 = thd_wm_empty
        ),
        H = H0
    ;
        H0 = thd_emitted(T, Args, W),
        H = thd_emitted(T, list.map(lc_action_arg(S), Args),
            lc_test_where(S, W))
    ;
        H0 = thd_published(T, Args, W),
        H = thd_published(T, list.map(lc_action_arg(S), Args),
            lc_test_where(S, W))
    ;
        H0 = thd_retracted(T, Args),
        H = thd_retracted(T, list.map(lc_action_arg(S), Args))
    ;
        H0 = thd_called(Svc, E),
        H = thd_called(Svc, lc_maybe(S, E))
    ;
        H0 = thd_cached(K, V),
        H = thd_cached(libcall_expr(S, K), lc_maybe(S, V))
    ;
        H0 = thd_cache_deleted(K),
        H = thd_cache_deleted(libcall_expr(S, K))
    ;
        H0 = thd_logged(L, E),
        H = thd_logged(L, lc_maybe(S, E))
    ;
        H0 = thd_wm_has(T, Args),
        H = thd_wm_has(T, list.map(lc_action_arg(S), Args))
    ;
        H0 = thd_wm_count(T, E),
        H = thd_wm_count(T, libcall_expr(S, E))
    ).

    %@helper
:- func lc_test_where(libcall_scope, maybe(ast_test_where))
    = maybe(ast_test_where).

lc_test_where(_, no) = no.
lc_test_where(S, yes(W)) =
    yes(W ^ twh_predicate := libcall_expr(S, W ^ twh_predicate)).

%-----------------------------------------------------------------------------%
:- end_module dsc.libcall.
%-----------------------------------------------------------------------------%

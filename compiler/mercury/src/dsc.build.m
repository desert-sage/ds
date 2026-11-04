% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.build -- the CST to the AST.
%
% `det` with no error arm: anything that would need a diagnostic belongs to a
% later phase.
%-----------------------------------------------------------------------------%

:- module dsc.build.
:- interface.

:- import_module dsc.ast.
:- import_module dsc.cst.

%-----------------------------------------------------------------------------%

    %@helper
:- pred build_file(file::in, ast_file::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.expr.
:- import_module dsc.token.

:- import_module list.
:- import_module maybe.
:- import_module string.

%-----------------------------------------------------------------------------%

build_file(file(Use, Decls), ast_file(AstUse, AstDecls)) :-
    (
        Use = no,
        AstUse = no
    ;
        Use = yes(use_decl(Base, Lines, Pos)),
        AstUse = yes(ast_use(Base, list.map(build_setting, Lines), Pos))
    ),
    list.map(build_decl, Decls, AstDecls).

    %@helper
:- func build_setting(setting_line) = ast_setting.

build_setting(setting_line(Cap, Value)) = ast_setting(Cap, Value).

    %@helper
:- pred build_decl(top_decl::in, ast_decl::out) is det.

build_decl(td_schema(S), ad_schema(build_schema(S))).
build_decl(td_rule(R), ad_rule(build_rule(R))).
build_decl(td_const(C), ad_const(build_const(C))).
build_decl(td_series(S), ad_series(build_series(S))).
build_decl(td_service(S), ad_service(build_service_decl(S))).
build_decl(td_unit(U), ad_unit(build_unit(U))).
build_decl(td_opaque(O), ad_opaque(build_opaque(O))).
build_decl(td_test(T), ad_test(build_test(T))).
build_decl(td_initial(lgra_24_1_initial_block(Items, P)),
    ad_initial(ast_initial(list.condense(list.map(build_test_initial, Items)),
        P))).
build_decl(td_import(I), ad_import(build_import(I))).

%-----------------------------------------------------------------------------%
% Tests -- [LTSL]
%-----------------------------------------------------------------------------%

    % Built as the file's own; `dsc.driver` marks a companion's.
    %
    %@helper
:- func build_test(ltsl_2_1_test_decl) = ast_test.

build_test(ltsl_2_1_test_decl(Name, Sections, Pos)) =
    ast_test(Name, list.map(build_test_section, Sections), Pos, no).

    %@helper
:- func build_test_section(ltsl_2_3_section) = ast_test_section.

build_test_section(ts_initial(Items, P)) =
    tsec_initial(list.condense(list.map(build_test_initial, Items)), P).
build_test_section(ts_inputs(Blocks, P)) =
    tsec_inputs(list.map(build_test_at, Blocks), P).
build_test_section(ts_responses(Stubs, P)) =
    tsec_responses(list.map(build_test_stub, Stubs), P).
build_test_section(ts_produces(As, P)) =
    tsec_produces(list.map(build_test_assertion, As), P).
build_test_section(ts_until(E, P)) = tsec_until(E, P).

    %@helper
:- func build_test_initial(ltsl_5_2_initial_item) = list(ast_test_initial).

build_test_initial(ti_fact(F)) = [tini_fact(build_test_fact(F))].
build_test_initial(ti_cache(K, V, P)) = [tini_cache(K, V, P)].
build_test_initial(ti_cache_block(Seeds, _)) =
    list.map(( func(ltsl_5_2_seed(K, V, P)) = tini_cache(K, V, P) ), Seeds).

    %@helper
:- func build_test_fact(ltsl_4_1_fact) = ast_test_fact.

build_test_fact(ltsl_4_1_fact(S, Args, P)) =
    ast_test_fact(build_type_ref(S), list.map(build_action_arg, Args), P).

    %@helper
:- func build_test_at(ltsl_3_3_at_block) = ast_test_at.

build_test_at(ltsl_3_3_at_block(When, Facts, P)) =
    ast_test_at(When, list.map(build_test_fact, Facts), P).

    %@helper
:- func build_test_stub(ltsl_7_2_stub) = ast_test_stub.

build_test_stub(ltsl_7_2_stub(Svc, Args, Corr, After, Replies, P)) =
    ast_test_stub(build_service_ref(Svc), list.map(build_action_arg, Args),
        Corr, After, list.map(build_test_reply, Replies), P).

    %@helper
:- func build_test_reply(ltsl_7_3_reply) = ast_test_reply.

build_test_reply(tr_fact(F)) = trep_fact(build_test_fact(F)).
build_test_reply(tr_no_response(P)) = trep_no_response(P).

    %@helper
:- func build_test_assertion(ltsl_8_2_assertion) = ast_test_assertion.

build_test_assertion(ltsl_8_2_assertion(Never, Head, P)) =
    ast_test_assertion(Never, build_test_head(Head), P).

    %@helper
:- func build_test_head(ltsl_8_2_head) = ast_test_head.

build_test_head(th_activated(R)) = thd_activated(R).
build_test_head(th_emitted(S, Args, W)) =
    thd_emitted(build_type_ref(S), list.map(build_action_arg, Args),
        build_test_where(W)).
build_test_head(th_published(S, Args, W)) =
    thd_published(build_type_ref(S), list.map(build_action_arg, Args),
        build_test_where(W)).
build_test_head(th_retracted(S, Args)) =
    thd_retracted(build_type_ref(S), list.map(build_action_arg, Args)).
build_test_head(th_recorded(K)) = thd_recorded(K).
build_test_head(th_called(Svc, Corr)) = thd_called(build_service_ref(Svc), Corr).
build_test_head(th_cached(K, V)) = thd_cached(K, V).
build_test_head(th_cache_deleted(K)) = thd_cache_deleted(K).
build_test_head(th_logged(L, M)) = thd_logged(L, M).
build_test_head(th_wm_has(S, Args)) =
    thd_wm_has(build_type_ref(S), list.map(build_action_arg, Args)).
build_test_head(th_wm_count(S, N)) = thd_wm_count(build_type_ref(S), N).
build_test_head(th_wm_empty) = thd_wm_empty.

    %@helper
:- func build_test_where(maybe(ltsl_8_4_where)) = maybe(ast_test_where).

build_test_where(no) = no.
build_test_where(yes(ltsl_8_4_where(B, P))) = yes(ast_test_where(B, P)).

%-----------------------------------------------------------------------------%
% Units
%-----------------------------------------------------------------------------%

    %@helper
:- func build_unit(luni_4_unit_decl) = ast_unit.

build_unit(ud_dimension(N, S, B, P)) = au_dimension(N, S, B, P, "").
build_unit(ud_scalar(N, S, L, P)) = au_scalar(N, S, L, P, "").
build_unit(ud_symbol(Sym, Dim, Body, L, As, P)) =
    au_symbol(Sym, Dim, build_unit_body(Body), L, As, P, "",
        decl_ref("", Dim ^ id_name)).
build_unit(ud_formula(N, Ms, Ls, P)) =
    au_formula(N, list.map(build_formula_modifier, Ms),
        list.map(build_formula_line, Ls), P).
build_unit(ud_fx_pair(N, F, T, V, W, Num, Den, P)) =
    au_fx_pair(N, F, T, V, W, Num, Den, P).

    %@helper
:- func build_unit_body(luni_4_3_unit_body) = ast_unit_body.

build_unit_body(ub_base) = aub_base.
build_unit_body(ub_affine(E)) = aub_affine(E).
build_unit_body(ub_tier2(luni_4_3_tier2(To, From, P))) =
    aub_tier2(To, From, P).

    %@helper
:- func build_formula_modifier(luni_4_5_modifier) = ast_formula_modifier.

build_formula_modifier(fm_inverting(P)) = afm_inverting(P).
build_formula_modifier(fm_implicit(P)) = afm_implicit(P).

    %@helper
:- func build_formula_line(luni_4_5_formula_line) = ast_formula_line.

build_formula_line(luni_4_5_formula_line(N, Param, PType, Ret, Body, P)) =
    ast_formula_line(N, Param, PType, Ret, Body, P).

%-----------------------------------------------------------------------------%
% Imports
%-----------------------------------------------------------------------------%

    %@helper
:- func build_import(limp_2_1_1_import_decl) = ast_import.

build_import(limp_2_1_1_qualified(Path, Alias, Pos)) =
    ast_import(Path, aif_qualified(Alias, Binding), Pos) :-
    Binding = binding_of(Alias, dotted(Path)).
build_import(limp_2_1_1_selective(Path, Items, Pos)) =
    ast_import(Path, aif_selective(list.map(build_import_item, Items)), Pos).

    %@helper
:- func build_import_item(limp_2_1_1_import_item) = ast_import_item.

build_import_item(limp_2_1_1_import_item(Name, Alias, Pos)) =
    ast_import_item(Name, Alias, binding_of(Alias, Name ^ id_name), Pos).

    %@helper
:- func binding_of(maybe(ident), string) = string.

binding_of(no, Derived) = Derived.
binding_of(yes(Alias), _) = Alias ^ id_name.

    %@helper
:- func dotted(list(ident)) = string.

dotted(Segments) =
    string.join_list(".", list.map((func(I) = I ^ id_name), Segments)).

%-----------------------------------------------------------------------------%
% Opaque types
%-----------------------------------------------------------------------------%

    %@helper
:- func build_opaque(lopq_2_1_opaque_decl) = ast_opaque.

build_opaque(O) = ast_opaque(O ^ op_name, O ^ op_repr, O ^ op_pos, "").

%-----------------------------------------------------------------------------%
% Services
%-----------------------------------------------------------------------------%

    %@helper
:- func build_service_decl(service_decl) = ast_service_decl.

build_service_decl(S) =
    ast_service_decl(S ^ sv_name, S ^ sv_doc,
        list.map(build_service_kwarg, S ^ sv_kwargs),
        build_response(S ^ sv_response),
        list.map(build_hydration_field, S ^ sv_hydration), S ^ sv_pos).

    %@helper
:- func build_response(response_decl) = ast_response.

build_response(rd_schema(Id)) = ar_schema(Id).
build_response(rd_none(P)) = ar_none(P).
build_response(rd_absent) = ar_absent.

    %@helper
:- func build_service_kwarg(service_kwarg) = ast_service_kwarg.

build_service_kwarg(K) =
    ast_service_kwarg(K ^ sk_name, K ^ sk_type,
        list.map(build_kwarg_modifier, K ^ sk_modifiers), K ^ sk_pos, []).

    %@helper
:- func build_kwarg_modifier(kwarg_modifier) = ast_kwarg_modifier.

build_kwarg_modifier(km_default(E, P)) = akm_default(E, P).
build_kwarg_modifier(km_literal(P)) = akm_literal(P).
build_kwarg_modifier(km_required(P)) = akm_required(P).

    %@helper
:- func build_hydration_field(hydration_field) = ast_hydration_field.

build_hydration_field(hy_hydrates(Ns, P)) = ahy_hydrates(Ns, P).
build_hydration_field(hy_max_window(E, P)) = ahy_max_window(E, P).
build_hydration_field(hy_max_limit(E, P)) = ahy_max_limit(E, P).
build_hydration_field(hy_filter_fields(Fs, P)) =
    ahy_filter_fields(list.map(build_filter_field, Fs), P).

    %@helper
:- func build_filter_field(filter_field) = ast_filter_field.

build_filter_field(F) =
    ast_filter_field(F ^ ff_name,
        list.map(func(filter_op(Op, _)) = Op, F ^ ff_ops), F ^ ff_pos).

%-----------------------------------------------------------------------------%
% Constants and series
%-----------------------------------------------------------------------------%

    %@helper
:- func build_const(lgra_4_1_const_decl) = ast_const.

build_const(C) = ast_const(C ^ cd_name, build_const_form(C ^ cd_form),
                           C ^ cd_pos, []).

    %@helper
:- func build_const_form(lgra_4_1_const_form) = ast_const_form.

build_const_form(cf_value(Ann, E)) = acf_value(build_annotation(Ann), E).
build_const_form(cf_colon_literal(E)) = acf_colon_literal(E).

    %@helper
:- func build_series(lgra_7_1_series_decl) = ast_series.

build_series(S) = ast_series(build_slot_ref(S ^ sr_slot),
                             list.map(build_block_kwarg, S ^ sr_opts),
                             S ^ sr_doc,
                             list.map(build_series_line, S ^ sr_lines),
                             S ^ sr_pos).

    %@helper
:- func build_slot_ref(lgra_7_3_slot_ref) = ast_slot_ref.

build_slot_ref(lgra_7_3_slot_ref(Schema, Slot)) = ast_slot_ref(Schema, Slot).

    %@helper
:- func build_block_kwarg(lgra_7_1_block_kwarg) = ast_block_kwarg.

build_block_kwarg(bk_persist(E, P)) = abk_persist(E, P).
build_block_kwarg(bk_by(By, P)) = abk_by(build_by(By), P).
build_block_kwarg(bk_capacity(N, P)) = abk_capacity(N, P).
build_block_kwarg(bk_nulls(N, P)) = abk_nulls(N, P).

    %@helper
:- func build_by(lgra_7_1_by_value) = ast_by_value.

build_by(by_name(N)) = aby_name(N).
build_by(by_none(P)) = aby_none(P).

    %@helper
:- func build_series_line(lgra_7_1_series_line) = ast_series_line.

build_series_line(L) = ast_series_line(L ^ sl_aggs,
                                       build_time_model(L ^ sl_time),
                                       build_accuracy(L ^ sl_accuracy),
                                       L ^ sl_gap, L ^ sl_as, L ^ sl_pos).

    %@helper
:- func build_time_model(lgra_7_1_time_model) = ast_time_model.

build_time_model(tm_all_time(P)) = atm_all_time(P).
build_time_model(tm_sliding(E, P)) = atm_sliding(E, P).
build_time_model(tm_tumbling(E, P)) = atm_tumbling(E, P).
build_time_model(tm_sample(E, P)) = atm_sample(E, P).

    %@helper
:- func build_accuracy(maybe(lgra_7_1_accuracy)) = maybe(ast_accuracy).

build_accuracy(no) = no.
build_accuracy(yes(ac_exact(P))) = yes(aac_exact(P)).
build_accuracy(yes(ac_tolerance(E, P))) = yes(aac_tolerance(E, P)).
build_accuracy(yes(ac_confidence(E, P))) = yes(aac_confidence(E, P)).
build_accuracy(yes(ac_delta(E, P))) = yes(aac_delta(E, P)).
build_accuracy(yes(ac_bound_deterministic(P))) = yes(aac_bound_deterministic(P)).

%-----------------------------------------------------------------------------%
% Schemas
%-----------------------------------------------------------------------------%

    %@helper
:- func build_schema(lgra_5_1_schema_decl) = ast_schema.

build_schema(S) = ast_schema(S ^ sd_name, Lifecycle, Source, S ^ sd_doc,
                             Fields, S ^ sd_pos, author_declared,
                             S ^ sd_name ^ id_name) :-
    lscp_1_4_lifecycle(S ^ sd_lifecycle, Lifecycle, Source),
    Fields = list.map(build_field, S ^ sd_fields).

    %@spec [LSCP.1.4]
:- pred lscp_1_4_lifecycle(maybe(lgra_5_2_lifecycle)::in, ast_lifecycle::out,
                           scope_source::out) is det.

lscp_1_4_lifecycle(no, al_explicit, scope_defaulted).
lscp_1_4_lifecycle(yes(Written), Lifecycle, Source) :-
    (
        Written = lc_explicit,
        Lifecycle = al_explicit,
        Source = scope_written
    ;
        Written = lc_activation,
        Lifecycle = al_activation,
        Source = scope_written
    ;
        Written = lc_logical(Amb),
        Lifecycle = al_logical(build_ambient(Amb)),
        Source = scope_written
    ;
        Written = lc_ttl(Span, Amb),
        Lifecycle = al_ttl(Span, build_ambient(Amb)),
        Source = scope_written
    ;
        % The refused spellings keep the lifecycle they spell, so the schema's
        % slots are still checked against it, and the provenance says which
        % spelling `validate` has to refuse.
        Written = lc_unprefixed(Inner),
        lscp_1_4_lifecycle(yes(Inner), Lifecycle, _),
        Source = scope_unprefixed
    ;
        Written = lc_bare_ambient,
        Lifecycle = al_logical(aa_ambient),
        Source = scope_bare_ambient
    ).

    %@helper
:- func build_ambient(ambient) = ast_ambient.

build_ambient(ambient) = aa_ambient.
build_ambient(not_ambient) = aa_not_ambient.

%-----------------------------------------------------------------------------%
% Rules
%-----------------------------------------------------------------------------%

    %@helper
:- func build_rule(lgra_6_1_rule_decl) = ast_rule.

build_rule(R) = ast_rule(R ^ rd_name,
                         list.map(build_modifier, R ^ rd_modifiers),
                         R ^ rd_doc,
                         list.map(build_lhs_clause, R ^ rd_lhs),
                         build_rhs(R ^ rd_rhs),
                         R ^ rd_pos,
                         author_declared).

    %@helper
:- func build_rhs(lgra_6_1_rule_rhs) = ast_rule_rhs.

build_rhs(R) = ast_rule_rhs(list.map(build_let, R ^ rr_lets),
                            list.map(build_action, R ^ rr_actions),
                            list.map(build_after, R ^ rr_afters)).

    %@helper
:- func build_let(lgra_6_1_let_decl) = ast_let_decl.

build_let(L) = ast_let_decl(list.map(build_binding, L ^ ld_bindings),
                            L ^ ld_pos).

    %@helper
:- func build_binding(lgra_6_1_let_binding) = ast_let_binding.

build_binding(lb_simple(N, Ann, E, P)) =
    alb_simple(N, build_annotation(Ann), E, P).
build_binding(lb_capture(Ns, E, P)) = alb_capture(Ns, E, P).

    %@helper
:- func build_annotation(maybe(lgra_6_7_2_annotation)) = maybe(ast_annotation).

build_annotation(no) = no.
build_annotation(yes(lgra_6_7_2_annotation(T, N))) =
    yes(ast_annotation(T, N)).

    %@helper
:- func build_action(lgra_10_1_action) = ast_action.

build_action(A) = ast_action(build_action_head(A ^ ac_head),
                             list.map(build_action_arg, A ^ ac_args),
                             build_action_block(A ^ ac_block),
                             A ^ ac_as,
                             A ^ ac_pos).

    %@helper
:- func build_action_block(lgra_10_1_action_block) = ast_action_block.

build_action_block(ab_none) = aab_none.
build_action_block(ab_kwargs(Args)) =
    aab_kwargs(list.map(build_action_arg, Args)).
build_action_block(ab_call(Args, Conts)) =
    aab_call(list.map(build_action_arg, Args),
        list.map(build_continuation, Conts)).

    %@helper
:- func build_continuation(lcco_2_1_continuation) = ast_continuation.

build_continuation(cont_on(E, As, P)) =
    acont_on(E, list.map(build_action, As), P).
build_continuation(cont_timeout(E, As, P)) =
    acont_timeout(E, list.map(build_action, As), P).
build_continuation(cont_error(Pat, As, P)) =
    acont_error(Pat, list.map(build_action, As), P).

    %@helper
:- func build_action_head(lgra_10_1_action_head) = ast_action_head.

build_action_head(ah_log(L, S)) = aah_log(L, S).
build_action_head(ah_call(R)) = aah_call(build_service_ref(R)).
build_action_head(ah_emit(R)) = aah_emit(build_type_ref(R)).
build_action_head(ah_publish(R)) = aah_publish(build_type_ref(R)).
build_action_head(ah_cache) = aah_cache.
build_action_head(ah_cache_delete) = aah_cache_delete.
build_action_head(ah_record_event(R)) = aah_record_event(build_type_ref(R)).
build_action_head(ah_withdraw(N)) = aah_withdraw(N).

    %@helper
:- func build_service_ref(lgra_10_1_service_ref) = ast_service_ref.

build_service_ref(sr_bare(P)) = asr_bare(P).

    %@helper
:- func build_action_arg(lgra_10_3_1_action_arg) = ast_action_arg.

build_action_arg(aa_kwarg(N, E, P)) = aaa_kwarg(N, E, P).
build_action_arg(aa_flag(N)) = aaa_flag(N).

    %@helper
:- func build_after(ltac_2_1_after_clause) = ast_after_clause.

build_after(A) = ast_after_clause(A ^ af_duration, A ^ af_as,
                                  list.map(build_action, A ^ af_actions),
                                  list.map(build_after, A ^ af_nested),
                                  A ^ af_pos).

    %@helper
:- func build_modifier(lgra_6_1_rule_modifier) = ast_rule_modifier.

build_modifier(rm_cooldown(S, P)) = arm_cooldown(S, P).
build_modifier(rm_by(rk_none, P)) = arm_by(ark_none, P).
build_modifier(rm_by(rk_paths(Paths), P)) =
    arm_by(ark_paths(list.map(build_key_path, Paths)), P).

    %@helper
:- func build_key_path(lgra_6_1_key_path) = ast_key_path.

build_key_path(key_path(B, S)) = ast_key_path(B, S).

    %@helper
:- func build_lhs_clause(lgra_8_1_lhs_clause) = ast_lhs_clause.

build_lhs_clause(lc_pattern(P)) = alc_pattern(build_pattern(P)).
build_lhs_clause(lc_then(S)) = alc_then(build_then_step(S)).

    % `no (P)` and `no P` become one node.
    %
    %@helper
:- func build_pattern(lgra_8_1_pattern) = ast_pattern.

build_pattern(pat_simple(B)) = ap_simple(build_body(B)).
build_pattern(pat_negated(B, _Parens, P)) = ap_negated(build_body(B), P).
build_pattern(pat_sequence(L, Head, Steps, P)) =
    ap_sequence(build_latest(L), build_body(Head),
        list.map(build_then_step, Steps), P).

    %@helper
:- func build_latest(sequence_latest) = ast_sequence_latest.

build_latest(sl_latest) = asl_latest.
build_latest(sl_plain) = asl_plain.

    %@helper
:- func build_then_step(lgra_8_5_2_then_step) = ast_then_step.

build_then_step(lgra_8_5_2_then_step(L, B, W, P)) =
    ast_then_step(build_latest(L), build_body(B), W, P).

    %@helper
:- func build_body(lgra_8_1_pattern_body) = ast_pattern_body.

build_body(B) = ast_pattern_body(build_type_ref(B ^ pb_type), B ^ pb_binding,
                                 B ^ pb_within, B ^ pb_where,
                                 build_capture(B ^ pb_capture), B ^ pb_pos).

    %@helper
:- func build_capture(maybe(lreg_4_1_capture)) = maybe(ast_capture).

build_capture(no) = no.
build_capture(yes(lreg_4_1_capture(Ns, M, P))) = yes(ast_capture(Ns, M, P)).

    %@helper
:- func build_type_ref(lgra_8_1_type_ref) = ast_type_ref.

build_type_ref(tr_bare(N)) = atr_bare(N).
build_type_ref(tr_qualified(Path, N)) = atr_qualified(Path, N).

%-----------------------------------------------------------------------------%
% Slots
%-----------------------------------------------------------------------------%

    %@helper
:- func build_field(lgra_5_7_1_field_decl) = ast_field.

build_field(F) = ast_field(F ^ fd_name, F ^ fd_type,
                           F ^ fd_nullable, F ^ fd_capacity,
                           list.map(build_marker, F ^ fd_markers),
                           F ^ fd_tolerance, F ^ fd_doc, F ^ fd_pos, no).


    %@helper
:- func build_marker(slot_marker) = ast_marker.

build_marker(sm_key(P)) = am_key(P).
build_marker(sm_mutable(P)) = am_mutable(P).
build_marker(sm_sampled(P)) = am_sampled(P).
build_marker(sm_retained(P)) = am_retained(P).

%-----------------------------------------------------------------------------%
:- end_module dsc.build.
%-----------------------------------------------------------------------------%

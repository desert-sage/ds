% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.cst -- the concrete syntax tree: what the grammar produced, with source
% positions attached and nothing desugared. `build` lowers it to the AST.
%
% The tree is wider than the clauses admit: a form refused by code has to parse
% for `validate` to refuse it, naming what the author wrote.
%-----------------------------------------------------------------------------%
:- module dsc.cst.
:- interface.
:- import_module dsc.expr.
:- import_module dsc.token.
:- import_module bool.
:- import_module list.
:- import_module maybe.
:- import_module string.
%-----------------------------------------------------------------------------%
    %@helper
:- type file
    --->    file(
                f_use   :: maybe(use_decl),
                f_decls :: list(top_decl)
            ).
    % The lines stay in source order, so a repeated capability stays visible.
    %
    %@helper
:- type use_decl
    --->    use_decl(
                u_base     :: ident,
                u_settings :: list(setting_line),
                u_pos      :: pos
            ).

    %@helper
:- type setting_line
    --->    setting_line(
                sl_cap   :: ident,
                sl_value :: bool
            ).
    % `td_import` shares the list so an import after a declaration stays visible.
    %
    %@helper
:- type top_decl
    --->    td_schema(lgra_5_1_schema_decl)
    ;       td_rule(lgra_6_1_rule_decl)
    ;       td_const(lgra_4_1_const_decl)
    ;       td_series(lgra_7_1_series_decl)
    ;       td_service(service_decl)
    ;       td_unit(luni_4_unit_decl)
    ;       td_opaque(lopq_2_1_opaque_decl)
    ;       td_test(ltsl_2_1_test_decl)
    ;       td_initial(lgra_24_1_initial_block)
    ;       td_import(limp_2_1_1_import_decl).

    % The parser takes any number of these anywhere; `validate` checks placement.
    %
    %@spec [LGRA.24.1]
:- type lgra_24_1_initial_block
    --->    lgra_24_1_initial_block(
                ib_items :: list(ltsl_5_2_initial_item),
                ib_pos   :: pos
            ).
%-----------------------------------------------------------------------------%
% Tests -- [LTSL]
%-----------------------------------------------------------------------------%

    % Sections stay in source order, undeduplicated: the check that refuses a
    % repeated section reports both.
    %
    %@spec [LTSL.2.1]
    %@spec [LTSL.2.3]
:- type ltsl_2_1_test_decl
    --->    ltsl_2_1_test_decl(
                tsd_name     :: lgra_9_3_1_expr,
                tsd_sections :: list(ltsl_2_3_section),
                tsd_pos      :: pos
            ).

    %@spec [LTSL.2.3]
:- type ltsl_2_3_section
    --->    ts_initial(list(ltsl_5_2_initial_item), pos)
    ;       ts_inputs(list(ltsl_3_3_at_block), pos)
    ;       ts_responses(list(ltsl_7_2_stub), pos)
    ;       ts_produces(list(ltsl_8_2_assertion), pos)
    ;       ts_until(lgra_9_3_1_expr, pos).

    %@spec [LTSL.5.2]
    %@spec [LTSL.5.3]
:- type ltsl_5_2_initial_item
    --->    ti_fact(ltsl_4_1_fact)
    ;       ti_cache(lgra_9_3_1_expr, lgra_9_3_1_expr, pos)
    ;       ti_cache_block(list(ltsl_5_2_seed), pos).

    %@spec [LTSL.5.2]
:- type ltsl_5_2_seed
    --->    ltsl_5_2_seed(
                sd_key   :: lgra_9_3_1_expr,
                sd_value :: lgra_9_3_1_expr,
                sd_pos   :: pos
            ).

    %@spec [LTSL.4.1]
:- type ltsl_4_1_fact
    --->    ltsl_4_1_fact(
                tf_schema :: lgra_8_1_type_ref,
                tf_args   :: list(lgra_10_3_1_action_arg),
                tf_pos    :: pos
            ).

    %@spec [LTSL.3.3]
:- type ltsl_3_3_at_block
    --->    ltsl_3_3_at_block(
                ab_when  :: lgra_9_3_1_expr,
                ab_facts :: list(ltsl_4_1_fact),
                ab_pos   :: pos
            ).

    %@spec [LTSL.7.2]
:- type ltsl_7_2_stub
    --->    ltsl_7_2_stub(
                st_service :: lgra_10_1_service_ref,
                st_args    :: list(lgra_10_3_1_action_arg),
                st_corr    :: maybe(lgra_9_3_1_expr),
                st_after   :: maybe(lgra_9_3_1_expr),
                st_replies :: list(ltsl_7_3_reply),
                st_pos     :: pos
            ).

    %@spec [LTSL.7.3]
    %@spec [LTSL.7.5]
:- type ltsl_7_3_reply
    --->    tr_fact(ltsl_4_1_fact)
    ;       tr_no_response(pos).

    %@spec [LTSL.8.2]
    %@spec [LTSL.8.3]
:- type ltsl_8_2_assertion
    --->    ltsl_8_2_assertion(
                ta_never :: bool,
                ta_head  :: ltsl_8_2_head,
                ta_pos   :: pos
            ).

    %@spec [LTSL.8.2]
    %@spec [LTSL.8.4]
:- type ltsl_8_2_head
    --->    th_activated(ident)
    ;       th_emitted(lgra_8_1_type_ref, list(lgra_10_3_1_action_arg),
                       maybe(ltsl_8_4_where))
    ;       th_published(lgra_8_1_type_ref, list(lgra_10_3_1_action_arg),
                         maybe(ltsl_8_4_where))
    ;       th_retracted(lgra_8_1_type_ref, list(lgra_10_3_1_action_arg))
    ;       th_recorded(ident)
    ;       th_called(lgra_10_1_service_ref, maybe(lgra_9_3_1_expr))
    ;       th_cached(lgra_9_3_1_expr, maybe(lgra_9_3_1_expr))
    ;       th_cache_deleted(lgra_9_3_1_expr)
    ;       th_logged(lgra_10_1_1_log_level, maybe(lgra_9_3_1_expr))
    ;       th_wm_has(lgra_8_1_type_ref, list(lgra_10_3_1_action_arg))
    ;       th_wm_count(lgra_8_1_type_ref, lgra_9_3_1_expr)
    ;       th_wm_empty.

    %@spec [LTSL.8.4]
:- type ltsl_8_4_where
    --->    ltsl_8_4_where(
                tw_binding   :: ident,
                tw_predicate :: lgra_9_3_1_expr
            ).
%-----------------------------------------------------------------------------%
% Units -- [LUNI.4]
%-----------------------------------------------------------------------------%

    %@spec [LUNI.4]
    %@spec [LUNI.4.1]
    %@spec [LUNI.4.2]
    %@spec [LUNI.4.3]
    %@spec [LUNI.4.5]
    %@spec [LUNI.4.6]
:- type luni_4_unit_decl
    --->    ud_dimension(
                udd_name    :: ident,
                udd_storage :: ident,
                udd_base    :: ident,
                udd_pos     :: pos
            )
    ;       ud_scalar(
                uds_name    :: ident,
                uds_storage :: ident,
                uds_label   :: maybe(string),
                uds_pos     :: pos
            )
    ;       ud_symbol(
                udy_symbol    :: ident,
                udy_dimension :: ident,
                udy_body      :: luni_4_3_unit_body,
                udy_label     :: maybe(string),
                udy_aliases   :: list(ident),
                udy_pos       :: pos
            )
    ;       ud_formula(
                udf_name      :: ident,
                udf_modifiers :: list(luni_4_5_modifier),
                udf_lines     :: list(luni_4_5_formula_line),
                udf_pos       :: pos
            )
    ;       ud_fx_pair(
                udx_name  :: ident,
                udx_from  :: ident,
                udx_to    :: ident,
                udx_via   :: ident,
                udx_where :: lgra_9_3_1_expr,
                udx_num   :: ident,
                udx_den   :: ident,
                udx_pos   :: pos
            ).

    %@spec [LUNI.4.3]
:- type luni_4_3_unit_body
    --->    ub_base
    ;       ub_affine(lgra_9_3_1_expr)
    ;       ub_tier2(luni_4_3_tier2).

    %@spec [LUNI.4.3]
:- type luni_4_3_tier2
    --->    luni_4_3_tier2(
                t2_to_base   :: lgra_9_3_1_expr,
                t2_from_base :: lgra_9_3_1_expr,
                t2_pos       :: pos
            ).

    %@spec [LUNI.4.5]
:- type luni_4_5_modifier
    --->    fm_inverting(pos)
    ;       fm_implicit(pos).

    % `<fn>(<param>: <unit>): <ret> = <expr>`.
    %
    %@spec [LUNI.4.5]
:- type luni_4_5_formula_line
    --->    luni_4_5_formula_line(
                fl_name       :: ident,
                fl_param      :: ident,
                fl_param_type :: ident,
                fl_return     :: ident,
                fl_body       :: lgra_9_3_1_expr,
                fl_pos        :: pos
            ).
%-----------------------------------------------------------------------------%
% Imports -- [LIMP.2.1.1]
%-----------------------------------------------------------------------------%

    %@spec [LIMP.2.1.1]
    %@spec [LIMP.2.1.4]
    %@spec [LIMP.2.1.7]
    %@spec [LIMP.2.4.3]
:- type limp_2_1_1_import_decl
    --->    limp_2_1_1_qualified(
                iq_path  :: list(ident),
                iq_alias :: maybe(ident),
                iq_pos   :: pos
            )
    ;       limp_2_1_1_selective(
                is_path  :: list(ident),
                is_names :: list(limp_2_1_1_import_item),
                is_pos   :: pos
            ).

    %@spec [LIMP.2.1.1]
:- type limp_2_1_1_import_item
    --->    limp_2_1_1_import_item(
                ii_name  :: ident,
                ii_alias :: maybe(ident),
                ii_pos   :: pos
            ).
%-----------------------------------------------------------------------------%
% Opaque types -- [LOPQ.2.1]
%-----------------------------------------------------------------------------%
    % `opaque type <Name> over <repr>`.
    %
    %@spec [LOPQ.2.1]
:- type lopq_2_1_opaque_decl
    --->    lopq_2_1_opaque_decl(
                op_name :: ident,
                op_repr :: ident,
                op_pos  :: pos
            ).
%-----------------------------------------------------------------------------%
% Services -- [LGRA.23]
%-----------------------------------------------------------------------------%

    %@helper
:- type service_decl
    --->    service_decl(
                sv_name      :: list(ident),
                sv_doc       :: maybe(string),
                sv_kwargs    :: list(service_kwarg),
                sv_response  :: response_decl,
                sv_hydration :: list(hydration_field),
                sv_pos       :: pos
            ).

    % `rd_absent` is a declaration with neither `response T` nor `no response`,
    % which `validate` refuses.
    %
    %@helper
:- type response_decl
    --->    rd_schema(ident)
    ;       rd_none(pos)
    ;       rd_absent.
    %@helper
:- type service_kwarg
    --->    service_kwarg(
                sk_name      :: ident,
                sk_type      :: ident,
                sk_modifiers :: list(kwarg_modifier),
                sk_pos       :: pos
            ).
    %@helper
:- type kwarg_modifier
    --->    km_default(lgra_9_3_1_expr, pos)
    ;       km_literal(pos)
    ;       km_required(pos).
    %@helper
:- type hydration_field
    --->    hy_hydrates(list(ident), pos)
    ;       hy_max_window(lgra_9_3_1_expr, pos)
    ;       hy_max_limit(lgra_9_3_1_expr, pos)
    ;       hy_filter_fields(list(filter_field), pos).
    %@helper
:- type filter_field
    --->    filter_field(
                ff_name :: ident,
                ff_ops  :: list(filter_op),
                ff_pos  :: pos
            ).
    %@helper
:- type filter_op
    --->    filter_op(lgra_9_3_2_compare_op, pos).
%-----------------------------------------------------------------------------%
% Constants -- [LGRA.4.1]
%-----------------------------------------------------------------------------%
    %@spec [LGRA.4.1]
:- type lgra_4_1_const_decl
    --->    lgra_4_1_const_decl(
                cd_name :: ident,
                cd_form :: lgra_4_1_const_form,
                cd_pos  :: pos
            ).
    % `cf_colon_literal` is `const NAME: <literal>`, which `validate` refuses.
    %
    %@spec [LGRA.4.1]
:- type lgra_4_1_const_form
    --->    cf_value(maybe(lgra_6_7_2_annotation), lgra_9_3_1_expr)
    ;       cf_colon_literal(lgra_9_3_1_expr).
%-----------------------------------------------------------------------------%
% Series -- [LGRA.7.1]
%-----------------------------------------------------------------------------%
    %@spec [LGRA.7.1]
    %@spec [LGRA.7.2]
:- type lgra_7_1_series_decl
    --->    lgra_7_1_series_decl(
                sr_slot  :: lgra_7_3_slot_ref,
                sr_opts  :: list(lgra_7_1_block_kwarg),
                sr_doc   :: maybe(string),
                sr_lines :: list(lgra_7_1_series_line),
                sr_pos   :: pos
            ).
    %@spec [LGRA.7.3]
:- type lgra_7_3_slot_ref
    --->    lgra_7_3_slot_ref(
                sf_schema :: maybe(ident),
                sf_slot   :: ident
            ).
    %@spec [LGRA.7.1]
:- type lgra_7_1_block_kwarg
    --->    bk_persist(lgra_9_3_1_expr, pos)
    ;       bk_by(lgra_7_1_by_value, pos)
    ;       bk_capacity(positioned, pos)    % the INT_LIT
    ;       bk_nulls(ident, pos).   % `skip`, `hold` or `zero`
    %@helper
:- type lgra_7_1_by_value
    --->    by_name(ident)
    ;       by_none(pos).
    %@spec [LGRA.7.1]
    %@spec [LGRA.7.6]
:- type lgra_7_1_series_line
    --->    lgra_7_1_series_line(
                sl_aggs     :: list(ident),
                sl_time     :: lgra_7_1_time_model,
                sl_accuracy :: maybe(lgra_7_1_accuracy),
                sl_gap      :: maybe(lgra_7_6a_gap_policy),
                sl_as       :: maybe(ident),
                sl_pos      :: pos
            ).
    %@spec [LGRA.7.1]
:- type lgra_7_1_time_model
    --->    tm_all_time(pos)
    ;       tm_sliding(lgra_9_3_1_expr, pos)
    ;       tm_tumbling(lgra_9_3_1_expr, pos)
    ;       tm_sample(lgra_9_3_1_expr, pos).
    %@spec [LGRA.7.1]
    %@spec [LGRA.7.10.1]
:- type lgra_7_1_accuracy
    --->    ac_exact(pos)
    ;       ac_tolerance(lgra_9_3_1_expr, pos)
    ;       ac_confidence(lgra_9_3_1_expr, pos)
    ;       ac_delta(lgra_9_3_1_expr, pos)
    ;       ac_bound_deterministic(pos).
%-----------------------------------------------------------------------------%
% Schemas -- [LGRA.5.1]
%-----------------------------------------------------------------------------%
    %@spec [LGRA.5.1]
    %@spec [LGRA.5.6]
:- type lgra_5_1_schema_decl
    --->    lgra_5_1_schema_decl(
                sd_name      :: ident,
                sd_lifecycle :: maybe(lgra_5_2_lifecycle),
                sd_doc       :: maybe(string),
                sd_fields    :: list(lgra_5_7_1_field_decl),
                sd_pos       :: pos
            ).
    % An omitted `scope` is defaulted in `build`, not here.
    %
    %@spec [LGRA.5.2]
:- type lgra_5_2_lifecycle
    --->    lc_explicit
    ;       lc_activation
    ;       lc_logical(ambient)
    ;       lc_ttl(list(positioned), ambient)
            % The duration is held as its tokens.
    ;       lc_unprefixed(lgra_5_2_lifecycle)
            % `schema Foo logical:` / `schema Foo ttl <dur>:` with no `scope`.
    ;       lc_bare_ambient.
            % `scope ambient`.
    %@helper
:- type ambient
    --->    ambient
    ;       not_ambient.
    %@spec [LGRA.5.7.1]
:- type lgra_5_7_1_field_decl
    --->    lgra_5_7_1_field_decl(
                fd_name      :: ident,
                fd_type      :: ident,
                fd_nullable  :: nullability,
                fd_capacity  :: maybe(positioned),   % the INT_LIT
                fd_markers   :: list(slot_marker),
                fd_tolerance :: maybe(positioned),
                fd_doc       :: maybe(string),
                fd_pos       :: pos
            ).
    %@helper
:- type slot_marker
    --->    sm_key(pos)
    ;       sm_mutable(pos)
    ;       sm_sampled(pos)
    ;       sm_retained(pos).
%-----------------------------------------------------------------------------%
% Rules -- [LGRA.6.1], [LGRA.8.1]
%-----------------------------------------------------------------------------%
    %@spec [LGRA.6.1]
:- type lgra_6_1_rule_decl
    --->    lgra_6_1_rule_decl(
                rd_name      :: ident,
                rd_modifiers :: list(lgra_6_1_rule_modifier),
                rd_doc       :: maybe(string),
                rd_lhs       :: list(lgra_8_1_lhs_clause),
                rd_rhs       :: lgra_6_1_rule_rhs,
                rd_pos       :: pos
            ).
    %@spec [LGRA.6.1]
:- type lgra_6_1_rule_modifier
    --->    rm_cooldown(list(positioned), pos)
    ;       rm_by(lgra_6_1_rate_key, pos).

    %@spec [LGRA.6.1]
:- type lgra_6_1_rate_key
    --->    rk_none
    ;       rk_paths(list(lgra_6_1_key_path)).

    %@helper
:- type lgra_6_1_key_path
    --->    key_path(kp_binding :: ident, kp_slot :: ident).
    %@helper
:- type lgra_8_1_lhs_clause
    --->    lc_pattern(lgra_8_1_pattern)
    ;       lc_then(lgra_8_5_2_then_step).
            % A `then` line with no pattern above it to fold into: first in the
            % rule, or after a `no`.
    %@spec [LGRA.8.1]
    %@spec [LGRA.8.4.1]
    %@spec [LGRA.8.5.2]
:- type lgra_8_1_pattern
    --->    pat_simple(lgra_8_1_pattern_body)
    ;       pat_negated(lgra_8_1_pattern_body, negation_parens, pos)
    ;       pat_sequence(
                sq_latest :: sequence_latest,
                sq_head   :: lgra_8_1_pattern_body,
                sq_steps  :: list(lgra_8_5_2_then_step),
                sq_pos    :: pos
            ).
    % A one-line sequence's trailing `where` is its last step's, in `ts_body`.

    % Recorded so a diagnostic does not suggest parens to an author who wrote them.
    %
    %@helper
:- type negation_parens
    --->    np_parenthesised
    ;       np_bare.
    %@helper
:- type sequence_latest
    --->    sl_latest
    ;       sl_plain.
    %@spec [LGRA.8.5.2]
    %@spec [LGRA.8.5.7]
:- type lgra_8_5_2_then_step
    --->    lgra_8_5_2_then_step(
                ts_latest :: sequence_latest,
                ts_body   :: lgra_8_1_pattern_body,
                ts_within :: list(positioned),
                ts_pos    :: pos
            ).
    %@spec [LGRA.8.1]
    %@spec [LGRA.8.6]
:- type lgra_8_1_pattern_body
    --->    lgra_8_1_pattern_body(
                pb_type    :: lgra_8_1_type_ref,
                pb_binding :: maybe(ident),
                pb_within  :: maybe(list(positioned)),
                pb_where   :: maybe(lgra_9_3_1_expr),
                pb_capture :: maybe(lreg_4_1_capture),
                pb_pos     :: pos
            ).
    % The whole condition stays in `pb_where`, since the match gates. This adds
    % the names and the match they destructure: the leftmost conjunct as written.
    %
    %@spec [LREG.4.1]
:- type lreg_4_1_capture
    --->    lreg_4_1_capture(
                cap_names :: list(ident),
                cap_match :: lgra_9_3_1_expr,
                cap_pos   :: pos
            ).
    % `plant.sensors.Reading` is `tr_qualified([plant, sensors], Reading)`.
    %
    %@spec [LGRA.8.1]
:- type lgra_8_1_type_ref
    --->    tr_bare(ident)
    ;       tr_qualified(list(ident), ident).
%-----------------------------------------------------------------------------%
% The rule body -- [LGRA.6.1], [LGRA.10.1], [LTAC.2.1]
%-----------------------------------------------------------------------------%
    %@spec [LGRA.6.1]
    %@spec [LTAC.2.1]
:- type lgra_6_1_rule_rhs
    --->    lgra_6_1_rule_rhs(
                rr_lets    :: list(lgra_6_1_let_decl),
                rr_actions :: list(lgra_10_1_action),
                rr_afters  :: list(ltac_2_1_after_clause)
            ).
    %@spec [LGRA.6.1]
    %@spec [LGRA.6.7.4]
:- type lgra_6_1_let_decl
    --->    lgra_6_1_let_decl(
                ld_bindings :: list(lgra_6_1_let_binding),
                ld_pos      :: pos
            ).
    %@spec [LGRA.6.1]
    %@spec [LGRA.6.7.2]
:- type lgra_6_1_let_binding
    --->    lb_simple(
                lb_name  :: ident,
                lb_type  :: maybe(lgra_6_7_2_annotation),
                lb_value :: lgra_9_3_1_expr,
                lb_pos   :: pos
            )
    ;       lb_capture(
                lc_names :: list(ident),
                lc_value :: lgra_9_3_1_expr,
                lc_pos   :: pos
            ).
    %@spec [LGRA.6.7.2]
    %@spec [LGRA.6.7.3]
:- type lgra_6_7_2_annotation
    --->    lgra_6_7_2_annotation(
                an_type     :: ident,
                an_nullable :: nullability
            ).
    %@spec [LGRA.10.1]
    %@spec [LGRA.10.2]
:- type lgra_10_1_action
    --->    lgra_10_1_action(
                ac_head  :: lgra_10_1_action_head,
                ac_args  :: list(lgra_10_3_1_action_arg),
                ac_block :: lgra_10_1_action_block,
                ac_as    :: maybe(lgra_9_3_1_expr),
                    % `call ... as <expr>`, from the call line or the `as` line
                    % closing its block.
                ac_pos   :: pos
            ).
    % Only `ab_call` holds continuations, so one on an `emit` has no representation.
    %
    %@spec [LCCO.2.1]
    %@spec [LGRA.10.1]
    %@spec [LGRA.10.8]
:- type lgra_10_1_action_block
    --->    ab_none
    ;       ab_kwargs(list(lgra_10_3_1_action_arg))
    ;       ab_call(
                cb_kwargs :: list(lgra_10_3_1_action_arg),
                cb_conts  :: list(lcco_2_1_continuation)
            ).
    %@spec [LCCO.2.1]
    %@spec [LCCO.2.3]
:- type lcco_2_1_continuation
    --->    cont_on(lgra_9_3_1_expr, list(lgra_10_1_action), pos)
    ;       cont_timeout(lgra_9_3_1_expr, list(lgra_10_1_action), pos)
    ;       cont_error(maybe(list(ident)), list(lgra_10_1_action), pos).
    % `ah_withdraw`'s `ident` is a binding, not a schema name.
    %
    %@spec [LGRA.10.1]
:- type lgra_10_1_action_head
    --->    ah_log(lgra_10_1_1_log_level, string)
    ;       ah_call(lgra_10_1_service_ref)
    ;       ah_emit(lgra_8_1_type_ref)
    ;       ah_publish(lgra_8_1_type_ref)
    ;       ah_cache
    ;       ah_cache_delete
    ;       ah_record_event(lgra_8_1_type_ref)
    ;       ah_withdraw(ident).
    %@spec [LGRA.10.1]
:- type lgra_10_1_service_ref
    --->    sr_bare(list(ident)).
    %@spec [LGRA.10.3.1]
:- type lgra_10_3_1_action_arg
    --->    aa_kwarg(ident, lgra_9_3_1_expr, pos)
    ;       aa_flag(ident).
    % `af_duration` is always an `ex_unit`: the parser takes one `UNIT_LIT` token.
    %
    %@spec [LTAC.2.1]
    %@spec [LGRA.6.1]
    %@spec [LTAC.2.2]
:- type ltac_2_1_after_clause
    --->    ltac_2_1_after_clause(
                af_duration :: lgra_9_3_1_expr,
                af_as       :: maybe(lgra_9_3_1_expr),
                af_actions  :: list(lgra_10_1_action),
                af_nested   :: list(ltac_2_1_after_clause),
                af_pos      :: pos
            ).
%-----------------------------------------------------------------------------%
:- end_module dsc.cst.
%-----------------------------------------------------------------------------%

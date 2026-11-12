% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.ast -- the abstract syntax tree, the compiler's alone.
%
% The CST with a schema's lifecycle defaulted (`as_scope` records whether the
% author wrote it), import bindings computed, and a `cache:` block flattened.
%-----------------------------------------------------------------------------%
:- module dsc.ast.
:- interface.
:- import_module assoc_list.
:- import_module bool.
:- import_module dsc.expr.
:- import_module dsc.token.
:- import_module list.
:- import_module maybe.
:- import_module string.
%-----------------------------------------------------------------------------%
    %@helper
:- type ast_file
    --->    ast_file(
                af_use   :: maybe(ast_use),
                af_decls :: list(ast_decl)
            ).
    % The lines are what the author wrote; `dsc.dialect` computes the settings.
    %
    %@helper
:- type ast_use
    --->    ast_use(
                au_base     :: ident,
                au_settings :: list(ast_setting),
                au_pos      :: pos
            ).

    %@helper
:- type ast_setting
    --->    ast_setting(
                as_cap   :: ident,
                as_value :: bool
            ).
    %@helper
:- type ast_decl
    --->    ad_schema(ast_schema)
    ;       ad_rule(ast_rule)
    ;       ad_const(ast_const)
    ;       ad_series(ast_series)
    ;       ad_service(ast_service_decl)
    ;       ad_unit(ast_unit)
    ;       ad_opaque(ast_opaque)
    ;       ad_test(ast_test)
    ;       ad_initial(ast_initial)
    ;       ad_import(ast_import).

    %@helper
:- type ast_initial
    --->    ast_initial(
                ain_items :: list(ast_test_initial),
                ain_pos   :: pos
            ).
%-----------------------------------------------------------------------------%
% Tests -- [LTSL]
%-----------------------------------------------------------------------------%

    %@helper
:- type ast_test
    --->    ast_test(
                tst_name     :: lgra_9_3_1_expr,
                tst_sections :: list(ast_test_section),
                tst_pos      :: pos,
                tst_file     :: maybe(string)
                    % `yes` for a test read from its module's companion
                    % `.dstest`, naming that file. Its positions are in that
                    % file, so they are not ordered against the `.ds`'s.
            ).
    %@helper
:- type ast_test_section
    --->    tsec_initial(list(ast_test_initial), pos)
    ;       tsec_inputs(list(ast_test_at), pos)
    ;       tsec_responses(list(ast_test_stub), pos)
    ;       tsec_produces(list(ast_test_assertion), pos)
    ;       tsec_until(lgra_9_3_1_expr, pos).
    %@helper
:- type ast_test_initial
    --->    tini_fact(ast_test_fact)
    ;       tini_cache(lgra_9_3_1_expr, lgra_9_3_1_expr, pos).
    %@helper
:- type ast_test_fact
    --->    ast_test_fact(
                tfa_schema :: ast_type_ref,
                tfa_args   :: list(ast_action_arg),
                tfa_pos    :: pos
            ).
    %@helper
:- type ast_test_at
    --->    ast_test_at(
                tat_when  :: lgra_9_3_1_expr,
                tat_facts :: list(ast_test_fact),
                tat_pos   :: pos
            ).
    %@helper
:- type ast_test_stub
    --->    ast_test_stub(
                tstb_service :: ast_service_ref,
                tstb_args    :: list(ast_action_arg),
                tstb_corr    :: maybe(lgra_9_3_1_expr),
                tstb_after   :: maybe(lgra_9_3_1_expr),
                tstb_replies :: list(ast_test_reply),
                tstb_pos     :: pos
            ).
    %@helper
:- type ast_test_reply
    --->    trep_fact(ast_test_fact)
    ;       trep_no_response(pos).
    %@helper
:- type ast_test_assertion
    --->    ast_test_assertion(
                tas_never :: bool,
                tas_head  :: ast_test_head,
                tas_pos   :: pos
            ).
    %@helper
:- type ast_test_head
    --->    thd_activated(ident)
    ;       thd_emitted(ast_type_ref, list(ast_action_arg),
                        maybe(ast_test_where))
    ;       thd_published(ast_type_ref, list(ast_action_arg),
                          maybe(ast_test_where))
    ;       thd_retracted(ast_type_ref, list(ast_action_arg))
    ;       thd_recorded(ident)
    ;       thd_called(ast_service_ref, maybe(lgra_9_3_1_expr))
    ;       thd_cached(lgra_9_3_1_expr, maybe(lgra_9_3_1_expr))
    ;       thd_cache_deleted(lgra_9_3_1_expr)
    ;       thd_logged(lgra_10_1_1_log_level, maybe(lgra_9_3_1_expr))
    ;       thd_wm_has(ast_type_ref, list(ast_action_arg))
    ;       thd_wm_count(ast_type_ref, lgra_9_3_1_expr)
    ;       thd_wm_empty.
    %@helper
:- type ast_test_where
    --->    ast_test_where(
                twh_binding   :: ident,
                twh_predicate :: lgra_9_3_1_expr
            ).
%-----------------------------------------------------------------------------%
% Units
%-----------------------------------------------------------------------------%

    %@helper
:- type ast_unit
    --->    au_dimension(
                aud_name    :: ident,
                aud_storage :: ident,
                aud_base    :: ident,
                aud_pos     :: pos,
                aud_file    :: string
                    % The library declaring it, `""` for the program's own file.
                    % `dsc.imports.limp_1_5_tree` writes a library's. So for
                    % `aus_file`, `auy_file` and `aop_file`.
            )
    ;       au_scalar(
                aus_name    :: ident,
                aus_storage :: ident,
                aus_label   :: maybe(string),
                aus_pos     :: pos,
                aus_file    :: string
            )
    ;       au_symbol(
                auy_symbol    :: ident,
                auy_dimension :: ident,
                auy_body      :: ast_unit_body,
                auy_label     :: maybe(string),
                auy_aliases   :: list(ident),
                auy_pos       :: pos,
                auy_file      :: string,
                auy_dim_ref   :: decl_ref
                    % The declaration `auy_dimension` names, as the declaring
                    % file resolves it: by `limp_1_5_tree` for a library, by
                    % `dsc.resolve` for the program's own file.
            )
    ;       au_formula(
                auf_name      :: ident,
                auf_modifiers :: list(ast_formula_modifier),
                auf_lines     :: list(ast_formula_line),
                auf_pos       :: pos
            )
    ;       au_fx_pair(
                aux_name  :: ident,
                aux_from  :: ident,
                aux_to    :: ident,
                aux_via   :: ident,
                aux_where :: lgra_9_3_1_expr,
                aux_num   :: ident,
                aux_den   :: ident,
                aux_pos   :: pos
            ).
    %@helper
:- type ast_unit_body
    --->    aub_base
    ;       aub_affine(lgra_9_3_1_expr)
    ;       aub_tier2(lgra_9_3_1_expr, lgra_9_3_1_expr, pos).
    %@helper
:- type ast_formula_modifier
    --->    afm_inverting(pos)
    ;       afm_implicit(pos).
    %@helper
:- type ast_formula_line
    --->    ast_formula_line(
                afl_name       :: ident,
                afl_param      :: ident,
                afl_param_type :: ident,
                afl_return     :: ident,
                afl_body       :: lgra_9_3_1_expr,
                afl_pos        :: pos
            ).
%-----------------------------------------------------------------------------%
% Imports
%-----------------------------------------------------------------------------%

    % A binding is the alias if there is one, else the dotted path entire
    % (qualified) or the imported name (selective). The alias stays beside it.
    %
    %@helper
:- type ast_import
    --->    ast_import(
                ai_path :: list(ident),
                ai_form :: ast_import_form,
                ai_pos  :: pos
            ).
    %@helper
:- type ast_import_form
    --->    aif_qualified(
                aiq_alias   :: maybe(ident),
                aiq_binding :: string
            )
    ;       aif_selective(list(ast_import_item)).
    %@helper
:- type ast_import_item
    --->    ast_import_item(
                aii_name    :: ident,
                aii_alias   :: maybe(ident),
                aii_binding :: string,
                aii_pos     :: pos
            ).
%-----------------------------------------------------------------------------%
% Opaque types
%-----------------------------------------------------------------------------%
    %@helper
:- type ast_opaque
    --->    ast_opaque(
                aop_name :: ident,
                aop_repr :: ident,
                aop_pos  :: pos,
                aop_file :: string
            ).
%-----------------------------------------------------------------------------%
% Services
%-----------------------------------------------------------------------------%
    %@helper
:- type ast_service_decl
    --->    ast_service_decl(
                asv_name      :: list(ident),
                asv_doc       :: maybe(string),
                asv_kwargs    :: list(ast_service_kwarg),
                asv_response  :: ast_response,
                asv_hydration :: list(ast_hydration_field),
                asv_pos       :: pos
            ).

    %@helper
:- type ast_response
    --->    ar_schema(ident)
    ;       ar_none(pos)
    ;       ar_absent.
    %@helper
:- type ast_service_kwarg
    --->    ast_service_kwarg(
                ask_name      :: ident,
                ask_type      :: ident,
                ask_modifiers :: list(ast_kwarg_modifier),
                ask_pos       :: pos,
                ask_units     :: assoc_list(string, decl_ref)
                    % The declaration its type and each unit suffix of its
                    % `default` mean in a library, from
                    % `dsc.imports.limp_1_5_kwarg`.
            ).
    %@helper
:- type ast_kwarg_modifier
    --->    akm_default(lgra_9_3_1_expr, pos)
    ;       akm_literal(pos)
    ;       akm_required(pos).
    %@helper
:- type ast_hydration_field
    --->    ahy_hydrates(list(ident), pos)
    ;       ahy_max_window(lgra_9_3_1_expr, pos)
    ;       ahy_max_limit(lgra_9_3_1_expr, pos)
    ;       ahy_filter_fields(list(ast_filter_field), pos).
    %@helper
:- type ast_filter_field
    --->    ast_filter_field(
                aff_name :: ident,
                aff_ops  :: list(lgra_9_3_2_compare_op),
                aff_pos  :: pos
            ).
%-----------------------------------------------------------------------------%
% Constants and series
%-----------------------------------------------------------------------------%
    %@helper
:- type ast_const
    --->    ast_const(
                acn_name :: ident,
                acn_form :: ast_const_form,
                acn_pos  :: pos,
                acn_units :: assoc_list(string, decl_ref),
                    % The declaration each unit suffix in a library's constant
                    % means in that library, from
                    % `dsc.imports.limp_1_5_const`. Empty for the program's own
                    % file and for a `units.core` unit, which every file has.
                acn_library :: string
                    % The library declaring it, or "" for the program's own
                    % file, from `dsc.imports.limp_1_5_const`. Two libraries can
                    % hold one text at one position, so this tells them apart.
            ).
    %@helper
:- type ast_const_form
    --->    acf_value(maybe(ast_annotation), lgra_9_3_1_expr)
    ;       acf_colon_literal(lgra_9_3_1_expr).
    %@helper
:- type ast_series
    --->    ast_series(
                asr_slot  :: ast_slot_ref,
                asr_opts  :: list(ast_block_kwarg),
                asr_doc   :: maybe(string),
                asr_lines :: list(ast_series_line),
                asr_pos   :: pos
            ).
    %@helper
:- type ast_slot_ref
    --->    ast_slot_ref(asf_schema :: maybe(ident), asf_slot :: ident).
    %@helper
:- type ast_block_kwarg
    --->    abk_persist(lgra_9_3_1_expr, pos)
    ;       abk_by(ast_by_value, pos)
    ;       abk_capacity(positioned, pos)   % the INT_LIT
    ;       abk_nulls(ident, pos).  % `skip`, `hold` or `zero`
    %@helper
:- type ast_by_value
    --->    aby_name(ident)
    ;       aby_none(pos).
    % The `gap` default is not applied here: `gap` is valid only on an aggregation
    % that integrates over time, which `build` does not know.
    %
    %@helper
:- type ast_series_line
    --->    ast_series_line(
                asl_aggs     :: list(ident),
                asl_time     :: ast_time_model,
                asl_accuracy :: maybe(ast_accuracy),
                asl_gap      :: maybe(lgra_7_6a_gap_policy),
                asl_as       :: maybe(ident),
                asl_pos      :: pos
            ).
    %@helper
:- type ast_time_model
    --->    atm_all_time(pos)
    ;       atm_sliding(lgra_9_3_1_expr, pos)
    ;       atm_tumbling(lgra_9_3_1_expr, pos)
    ;       atm_sample(lgra_9_3_1_expr, pos).
    %@helper
:- type ast_accuracy
    --->    aac_exact(pos)
    ;       aac_tolerance(lgra_9_3_1_expr, pos)
    ;       aac_confidence(lgra_9_3_1_expr, pos)
    ;       aac_delta(lgra_9_3_1_expr, pos)
    ;       aac_bound_deterministic(pos).
%-----------------------------------------------------------------------------%
% Schemas
%-----------------------------------------------------------------------------%
    %@helper
:- type ast_schema
    --->    ast_schema(
                as_name      :: ident,
                as_lifecycle :: ast_lifecycle,
                as_scope     :: scope_source,
                as_doc       :: maybe(string),
                as_fields    :: list(ast_field),
                as_pos       :: pos,
                as_origin    :: decl_origin,
                    % The schema's own name, the one an artefact writes.
                    % `as_name` is its `NAME`, what its declaring file
                    % calls it; a library's own name is `path.NAME`, set where
                    % the library is parsed (`dsc.imports`).
                as_own       :: string
            ).
    % A builtin schema's slots may be reserved words, which bind only what an
    % author declares.
    %
    %@helper
:- type decl_origin
    --->    author_declared
    ;       compiler_injected.
    % Where the lifecycle came from.
    %
    %@helper
:- type scope_source
    --->    scope_written
    ;       scope_defaulted
    ;       scope_unprefixed        % a refused spelling
    ;       scope_bare_ambient.     % the refused `scope ambient`
    %@helper
:- type ast_lifecycle
    --->    al_explicit
    ;       al_internal
            % `explicit`, except that only the engine asserts its facts. No
            % author can write it: `dsc.driver` sets it on the two builtin fault
            % schemas.
    ;       al_activation
    ;       al_logical(ast_ambient)
    ;       al_ttl(list(positioned), ast_ambient).
    %@helper
:- type ast_ambient
    --->    aa_ambient
    ;       aa_not_ambient.
%-----------------------------------------------------------------------------%
% Rules
%-----------------------------------------------------------------------------%

    %@helper
:- type ast_rule
    --->    ast_rule(
                ar_name      :: ident,
                ar_modifiers :: list(ast_rule_modifier),
                ar_doc       :: maybe(string),
                ar_lhs       :: list(ast_lhs_clause),
                ar_rhs       :: ast_rule_rhs,
                ar_pos       :: pos,
                ar_origin    :: decl_origin
                    % `compiler_injected` for a dstest oracle rule.
            ).
    %@helper
:- type ast_rule_modifier
    --->    arm_cooldown(list(positioned), pos)
    ;       arm_by(ast_rate_key, pos).
    %@helper
:- type ast_rate_key
    --->    ark_none
    ;       ark_paths(list(ast_key_path)).
    %@helper
:- type ast_key_path
    --->    ast_key_path(akp_binding :: ident, akp_slot :: ident).
    %@helper
:- type ast_lhs_clause
    --->    alc_pattern(ast_pattern)
    ;       alc_then(ast_then_step).
    %@helper
:- type ast_pattern
    --->    ap_simple(ast_pattern_body)
    ;       ap_negated(ast_pattern_body, pos)
    ;       ap_sequence(
                asq_latest :: ast_sequence_latest,
                asq_head   :: ast_pattern_body,
                asq_steps  :: list(ast_then_step),
                asq_pos    :: pos
            ).
    %@helper
:- type ast_sequence_latest
    --->    asl_latest
    ;       asl_plain.
    %@helper
:- type ast_then_step
    --->    ast_then_step(
                ats_latest :: ast_sequence_latest,
                ats_body   :: ast_pattern_body,
                ats_within :: list(positioned),
                ats_pos    :: pos
            ).
    %@helper
:- type ast_pattern_body
    --->    ast_pattern_body(
                apb_type    :: ast_type_ref,
                apb_binding :: maybe(ident),
                apb_within  :: maybe(list(positioned)),
                apb_where   :: maybe(lgra_9_3_1_expr),
                apb_capture :: maybe(ast_capture),
                    % The capture list over `apb_where`, the whole condition
                    % either way.
                apb_pos     :: pos
            ).
    %@helper
:- type ast_capture
    --->    ast_capture(
                acap_names :: list(ident),
                acap_match :: lgra_9_3_1_expr,
                acap_pos   :: pos
            ).
    %@helper
:- type ast_type_ref
    --->    atr_bare(ident)
    ;       atr_qualified(list(ident), ident).
%-----------------------------------------------------------------------------%
% The rule body
%-----------------------------------------------------------------------------%

    %@helper
:- type ast_rule_rhs
    --->    ast_rule_rhs(
                arr_lets    :: list(ast_let_decl),
                arr_actions :: list(ast_action),
                arr_afters  :: list(ast_after_clause)
            ).
    %@helper
:- type ast_let_decl
    --->    ast_let_decl(
                ald_bindings :: list(ast_let_binding),
                ald_pos      :: pos
            ).
    %@helper
:- type ast_let_binding
    --->    alb_simple(ident, maybe(ast_annotation), lgra_9_3_1_expr, pos)
    ;       alb_capture(list(ident), lgra_9_3_1_expr, pos).
    %@helper
:- type ast_annotation
    --->    ast_annotation(aan_type :: ident, aan_nullable :: nullability).
    %@helper
:- type ast_action
    --->    ast_action(
                aac_head  :: ast_action_head,
                aac_args  :: list(ast_action_arg),
                aac_block :: ast_action_block,
                aac_as    :: maybe(lgra_9_3_1_expr),
                aac_pos   :: pos
            ).
    %@helper
:- type ast_action_block
    --->    aab_none
    ;       aab_kwargs(list(ast_action_arg))
    ;       aab_call(list(ast_action_arg), list(ast_continuation)).
    %@helper
:- type ast_continuation
    --->    acont_on(lgra_9_3_1_expr, list(ast_action), pos)
    ;       acont_timeout(lgra_9_3_1_expr, list(ast_action), pos)
    ;       acont_error(maybe(list(ident)), list(ast_action), pos).
    %@helper
:- type ast_action_head
    --->    aah_log(lgra_10_1_1_log_level, string)
    ;       aah_call(ast_service_ref)
    ;       aah_emit(ast_type_ref)
    ;       aah_publish(ast_type_ref)
    ;       aah_cache
    ;       aah_cache_delete
    ;       aah_record_event(ast_type_ref)
    ;       aah_withdraw(ident).
            % A binding, not a schema.
    %@helper
:- type ast_service_ref
    --->    asr_bare(list(ident)).
    %@helper
:- type ast_action_arg
    --->    aaa_kwarg(ident, lgra_9_3_1_expr, pos)
    ;       aaa_flag(ident).
    %@helper
:- type ast_after_clause
    --->    ast_after_clause(
                aaf_duration :: lgra_9_3_1_expr,
                aaf_as       :: maybe(lgra_9_3_1_expr),
                aaf_actions  :: list(ast_action),
                aaf_nested   :: list(ast_after_clause),
                aaf_pos      :: pos
            ).

%-----------------------------------------------------------------------------%
% Slots
%-----------------------------------------------------------------------------%
    %@helper
:- type ast_field
    --->    ast_field(
                af_name      :: ident,
                af_type      :: ident,
                af_nullable  :: nullability,
                af_capacity  :: maybe(positioned),   % the INT_LIT
                af_markers   :: list(ast_marker),
                af_tolerance :: maybe(positioned),
                af_doc       :: maybe(string),
                af_pos       :: pos,
                af_decl      :: maybe(decl_ref)
                    % The unit or opaque type a library's slot names, as that
                    % library resolves it. `no` for the program's
                    % own file, a builtin, a schema, and a `units.core` type,
                    % which `af_type` finds in any file: read it through
                    % `dsc.resolve.slot_entry`.
            ).
    %@helper
:- type ast_marker
    --->    am_key(pos)
    ;       am_mutable(pos)
    ;       am_sampled(pos)
    ;       am_retained(pos).
%-----------------------------------------------------------------------------%
:- end_module dsc.ast.
%-----------------------------------------------------------------------------%

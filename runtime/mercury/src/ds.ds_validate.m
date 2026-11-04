% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% GENERATED from specs/registry/validate.ebnf by scripts/spec/gen_ebnf_registry.py. Do not edit.
:- module ds.ds_validate.
:- interface.

:- type ds_validate
    --->    ds_validate_unspecified
    ;       ds_validate_hard_keyword_name
    ;       ds_validate_name_collision
    ;       ds_validate_reserved_builtin_name
    ;       ds_validate_reserved_meta_kwarg
    ;       ds_validate_reserved_type_name
    ;       ds_validate_duplicate_type_name
    ;       ds_validate_slot_type_alias
    ;       ds_validate_legacy_as_colon
    ;       ds_validate_legacy_schema_lifecycle
    ;       ds_validate_bare_ambient_scope_retired
    ;       ds_validate_coercion_form_removed
    ;       ds_validate_const_colon_literal_retired
    ;       ds_validate_ambiguous_library
    ;       ds_validate_import_after_decl
    ;       ds_validate_import_before_use
    ;       ds_validate_import_cycle
    ;       ds_validate_import_name_collision
    ;       ds_validate_library_parse_failed
    ;       ds_validate_unknown_import_name
    ;       ds_validate_unknown_library
    ;       ds_validate_unknown_qualified_const
    ;       ds_validate_unknown_qualifier
    ;       ds_validate_use_not_first
    ;       ds_validate_binding_shadows_library
    ;       ds_validate_dialect_bad_name
    ;       ds_validate_dialect_dependency
    ;       ds_validate_dialect_duplicate_name
    ;       ds_validate_dialect_incomplete
    ;       ds_validate_unknown_dialect
    ;       ds_validate_unknown_capability
    ;       ds_validate_capability_duplicate
    ;       ds_validate_capability_constraint
    ;       ds_validate_capability_disabled
    ;       ds_validate_use_in_test
    ;       ds_validate_import_of_program
    ;       ds_validate_not_a_program
    ;       ds_validate_dialect_unknown_capability
    ;       ds_validate_capability_deferred
    ;       ds_validate_ambiguous_companion_slot
    ;       ds_validate_companion_slot_collision
    ;       ds_validate_duplicate_schema
    ;       ds_validate_duplicate_slot
    ;       ds_validate_identity_role_non_logical
    ;       ds_validate_identity_role_required
    ;       ds_validate_no_series_for_companion_slot
    ;       ds_validate_unknown_schema
    ;       ds_validate_unknown_slot
    ;       ds_validate_bad_lifecycle_flag
    ;       ds_validate_tolerance_bad_type
    ;       ds_validate_tolerance_literal_type
    ;       ds_validate_tolerance_non_logical
    ;       ds_validate_tolerance_on_key
    ;       ds_validate_tolerance_ttl_schema
    ;       ds_validate_logical_emit_self_ending
    ;       ds_validate_capacity_bad_type
    ;       ds_validate_capacity_not_positive
    ;       ds_validate_missing_slot
    ;       ds_validate_capacity_literal_exceeded
    ;       ds_validate_initial_bad_scope
    ;       ds_validate_schema_too_many_slots
    ;       ds_validate_initial_not_const
    ;       ds_validate_initial_placement
    ;       ds_validate_as_non_equatable_type
    ;       ds_validate_as_softfail_expression
    ;       ds_validate_as_empty_key
    ;       ds_validate_call_as_not_string
    ;       ds_validate_bad_type
    ;       ds_validate_cast_identity
    ;       ds_validate_cast_nullability
    ;       ds_validate_cast_undefined
    ;       ds_validate_cast_unsupported
    ;       ds_validate_nullable_key
    ;       ds_validate_nullable_unnarrowed
    ;       ds_validate_type_mismatch
    ;       ds_validate_unknown_type
    ;       ds_validate_null_literal_comparison
    ;       ds_validate_closed_set_literal
    ;       ds_validate_bad_arity
    ;       ds_validate_bad_operand_type
    ;       ds_validate_bad_path
    ;       ds_validate_bitwise_type
    ;       ds_validate_div_by_zero
    ;       ds_validate_formula_ambiguous
    ;       ds_validate_interp_bad_format
    ;       ds_validate_interp_bad_path
    ;       ds_validate_interp_inert_position
    ;       ds_validate_interp_nullable_key
    ;       ds_validate_interp_unit_non_unit
    ;       ds_validate_interp_unsupported
    ;       ds_validate_nan_value
    ;       ds_validate_negative_shift
    ;       ds_validate_predicate_unsatisfiable
    ;       ds_validate_unknown_function
    ;       ds_validate_unknown_member
    ;       ds_validate_retired_builtin_spelling
    ;       ds_validate_now_multipattern_unsupported
    ;       ds_validate_bit_field_range
    ;       ds_validate_expression_too_deep
    ;       ds_validate_bad_unit_dimension
    ;       ds_validate_currency_cross_compare
    ;       ds_validate_currency_implicit_round
    ;       ds_validate_currency_round_arg_not_string
    ;       ds_validate_currency_round_no_mode
    ;       ds_validate_currency_round_to_unit
    ;       ds_validate_currency_unknown_round_mode
    ;       ds_validate_dim_ambiguous
    ;       ds_validate_dim_mismatch
    ;       ds_validate_fx_pair_field_not_int
    ;       ds_validate_fx_pair_selector
    ;       ds_validate_fx_pair_unknown
    ;       ds_validate_fx_pair_unknown_dim
    ;       ds_validate_fx_pair_unknown_field
    ;       ds_validate_fx_pair_unknown_schema
    ;       ds_validate_unit_body_not_affine
    ;       ds_validate_unit_import_collision
    ;       ds_validate_unit_local_shadows_import
    ;       ds_validate_unit_unknown_dimension
    ;       ds_validate_unit_unknown_symbol
    ;       ds_validate_unknown_unit
    ;       ds_validate_currency_round_to_arity
    ;       ds_validate_unit_tier2_bad_body
    ;       ds_validate_dim_agg_unannotated
    ;       ds_validate_complex_not_in_v1
    ;       ds_validate_finance_deferred
    ;       ds_validate_unit_literal_not_whole
    ;       ds_validate_unit_import_alias
    ;       ds_validate_unit_body_missing
    ;       ds_validate_const_annotation_mismatch
    ;       ds_validate_const_bad_annotation
    ;       ds_validate_const_not_foldable
    ;       ds_validate_duplicate_constant
    ;       ds_validate_duplicate_let
    ;       ds_validate_let_bad_annotation
    ;       ds_validate_let_dim_mismatch
    ;       ds_validate_let_impure_embedded
    ;       ds_validate_let_no_slot
    ;       ds_validate_let_shadows_binding
    ;       ds_validate_let_shadows_constant
    ;       ds_validate_unknown_const
    ;       ds_validate_let_type_mismatch
    ;       ds_validate_duplicate_binding
    ;       ds_validate_dwell_ttl_schema
    ;       ds_validate_interior_latest
    ;       ds_validate_then_after_negation
    ;       ds_validate_then_no_predecessor
    ;       ds_validate_unknown_binding
    ;       ds_validate_within_no_ts_slot
    ;       ds_validate_zero_within
    ;       ds_validate_bad_interval_component
    ;       ds_validate_interval_inverted
    ;       ds_validate_interval_mixed_operands
    ;       ds_validate_interval_no_ordering
    ;       ds_validate_interval_rel_non_interval
    ;       ds_validate_date_needs_tz
    ;       ds_validate_date_subday_arithmetic
    ;       ds_validate_time_needs_tz_context
    ;       ds_validate_unknown_time_format
    ;       ds_validate_unreferenced_binding
    ;       ds_validate_rate_key_required
    ;       ds_validate_rate_key_bad_path
    ;       ds_validate_ts_not_time
    ;       ds_validate_ts_read_only
    ;       ds_validate_ts_marked
    ;       ds_validate_negated_binding_out_of_scope
    ;       ds_validate_rule_too_many_patterns
    ;       ds_validate_call_cool_inside_rule_cool
    ;       ds_validate_call_rate_mod
    ;       ds_validate_rule_cycle
    ;       ds_validate_rule_defeat
    ;       ds_validate_ambient_emit_forbidden
    ;       ds_validate_rule_wide_rate_window
    ;       ds_validate_duplicate_rule
    ;       ds_validate_rate_negative_duration
    ;       ds_validate_after_nonpositive_duration
    ;       ds_validate_bad_kwarg
    ;       ds_validate_bad_log_level
    ;       ds_validate_continuation_chain_too_deep
    ;       ds_validate_duplicate_kwarg
    ;       ds_validate_dynamic_ident_kwarg
    ;       ds_validate_error_pattern_too_deep
    ;       ds_validate_error_pattern_unknown_family
    ;       ds_validate_missing_kwarg
    ;       ds_validate_retain_non_ttl
    ;       ds_validate_retain_unwired
    ;       ds_validate_ttl_ambient_not_in_v1
    ;       ds_validate_ttl_zero
    ;       ds_validate_unknown_service
    ;       ds_validate_no_response_continuation
    ;       ds_validate_no_response_timeout
    ;       ds_validate_fact_kwarg_not_binding
    ;       ds_validate_record_event_retired
    ;       ds_validate_call_response_retired
    ;       ds_validate_duplicate_service
    ;       ds_validate_kwarg_quantity_not_whole
    ;       ds_validate_nested_continued_call_as
    ;       ds_validate_hydrate_bad_limit
    ;       ds_validate_hydrate_filter_unsupported
    ;       ds_validate_hydrate_nocooldown
    ;       ds_validate_hydrate_no_retain
    ;       ds_validate_hydrate_target_no_corr
    ;       ds_validate_hydrate_target_corr_not_key
    ;       ds_validate_nolinscan_series_unbounded
    ;       ds_validate_series_agg_not_supported
    ;       ds_validate_series_agg_time_model_mismatch
    ;       ds_validate_series_agg_type_mismatch
    ;       ds_validate_series_ambiguous_slot
    ;       ds_validate_series_bad_identity_slot
    ;       ds_validate_series_duplicate_agg_needs_label
    ;       ds_validate_series_duplicate_decl
    ;       ds_validate_series_duplicate_kwarg
    ;       ds_validate_series_gap_hold_no_clock
    ;       ds_validate_series_gap_on_non_integral
    ;       ds_validate_series_gap_skip_logical
    ;       ds_validate_series_invalid_quantile
    ;       ds_validate_series_no_exact_backing
    ;       ds_validate_series_no_identity_slot
    ;       ds_validate_series_realtime_unbounded_backing
    ;       ds_validate_series_unknown_schema
    ;       ds_validate_series_unknown_slot
    ;       ds_validate_nonfact_where_multipattern
    ;       ds_validate_series_capacity_below_sample
    ;       ds_validate_series_nonpositive_window
    ;       ds_validate_series_nulls_required
    ;       ds_validate_series_nulls_on_non_nullable
    ;       ds_validate_series_nulls_zero_non_numeric
    ;       ds_validate_regex_binding_length_mismatch
    ;       ds_validate_regex_let_negated
    ;       ds_validate_regex_name_mismatch
    ;       ds_validate_regex_non_string_operand
    ;       ds_validate_regex_on_bytes
    ;       ds_validate_regex_syntax_error
    ;       ds_validate_regex_unknown_flag
    ;       ds_validate_regex_unsupported_feature
    ;       ds_validate_regex_where_has_captures
    ;       ds_validate_regex_capture_not_match
    ;       ds_validate_regex_capture_in_let
    ;       ds_validate_opaque_no_op
    ;       ds_validate_opaque_type_mismatch
    ;       ds_validate_opaque_unsupported_repr
    ;       ds_validate_duplicate_opaque_type
    ;       ds_validate_compile_contract_incomplete
    ;       ds_validate_compile_dsrt_without_realtime
    ;       ds_validate_compile_missing_dsrt
    ;       ds_validate_rt_series_unbounded
    ;       ds_validate_rt_string_series
    ;       ds_validate_rule_not_lowered
    ;       ds_validate_realtime_deferred
    ;       ds_validate_test_bad_timestamp
    ;       ds_validate_test_unknown_rule
    ;       ds_validate_test_mixed_time_mode
    ;       ds_validate_test_non_literal
    ;       ds_validate_test_stub_unkeyed
    ;       ds_validate_test_unknown_schema
    ;       ds_validate_test_unknown_slot
    ;       ds_validate_test_no_produces
    ;       ds_validate_test_duplicate_section
    ;       ds_validate_test_no_inputs_or_until
    ;       ds_validate_test_recorded_retired
    ;       ds_validate_test_stub_reply_type
    ;       ds_validate_test_stub_no_response_mismatch
    ;       ds_validate_test_companion_decl
    ;       ds_validate_test_published_where
    ;       ds_validate_json_literal_refused
    ;       ds_validate_bytes_conversion_retired
    ;       ds_validate_unordered_type
    ;       ds_validate_nolinscan_join_anchor_a
    ;       ds_validate_nolinscan_join_anchor_b
    ;       ds_validate_nolinscan_join_anchor_c
    ;       ds_validate_nolinscan_json_path
    ;       ds_validate_nolinscan_json_slot
    ;       ds_validate_nolinscan_novel_string
    ;       ds_validate_nolinscan_string_order
    ;       ds_validate_nolinscan_unbounded_regex
    ;       ds_validate_nolinscan_unbounded_string_op
    ;       ds_validate_nolinscan_capture_join_key
    ;       ds_validate_rt_schema_too_wide
    ;       ds_validate_bad_flag
    ;       ds_validate_withdraw_scope
    ;       ds_validate_withdraw_emit_same_schema
    ;       ds_validate_internal_emit_forbidden
    ;       ds_validate_withdrawn_binding_used
    ;       ds_validate_service_duplicate_hydration_field
    ;       ds_validate_service_kwarg_default_type
    ;       ds_validate_unit_formula_pair_arity
    ;       ds_validate_service_no_response_decl
    ;       ds_validate_service_response_not_schema
    ;       ds_validate_service_response_not_ttl
    ;       ds_validate_service_response_no_corr
    ;       ds_validate_corr_role_conflict
    ;       ds_validate_answer_emit_forbidden
    ;       ds_validate_publish_modifier.

:- func ds_validate_code(ds_validate) = int.
:- func ds_validate_name(ds_validate) = string.

:- implementation.

ds_validate_code(ds_validate_unspecified) = 0.
ds_validate_code(ds_validate_hard_keyword_name) = 1000.
ds_validate_code(ds_validate_name_collision) = 1001.
ds_validate_code(ds_validate_reserved_builtin_name) = 1002.
ds_validate_code(ds_validate_reserved_meta_kwarg) = 1004.
ds_validate_code(ds_validate_reserved_type_name) = 1006.
ds_validate_code(ds_validate_duplicate_type_name) = 1007.
ds_validate_code(ds_validate_slot_type_alias) = 1008.
ds_validate_code(ds_validate_legacy_as_colon) = 1009.
ds_validate_code(ds_validate_legacy_schema_lifecycle) = 1010.
ds_validate_code(ds_validate_bare_ambient_scope_retired) = 1011.
ds_validate_code(ds_validate_coercion_form_removed) = 1012.
ds_validate_code(ds_validate_const_colon_literal_retired) = 1013.
ds_validate_code(ds_validate_ambiguous_library) = 1100.
ds_validate_code(ds_validate_import_after_decl) = 1101.
ds_validate_code(ds_validate_import_before_use) = 1102.
ds_validate_code(ds_validate_import_cycle) = 1103.
ds_validate_code(ds_validate_import_name_collision) = 1104.
ds_validate_code(ds_validate_library_parse_failed) = 1105.
ds_validate_code(ds_validate_unknown_import_name) = 1106.
ds_validate_code(ds_validate_unknown_library) = 1107.
ds_validate_code(ds_validate_unknown_qualified_const) = 1108.
ds_validate_code(ds_validate_unknown_qualifier) = 1109.
ds_validate_code(ds_validate_use_not_first) = 1110.
ds_validate_code(ds_validate_binding_shadows_library) = 1111.
ds_validate_code(ds_validate_dialect_bad_name) = 1201.
ds_validate_code(ds_validate_dialect_dependency) = 1202.
ds_validate_code(ds_validate_dialect_duplicate_name) = 1203.
ds_validate_code(ds_validate_dialect_incomplete) = 1205.
ds_validate_code(ds_validate_unknown_dialect) = 1210.
ds_validate_code(ds_validate_unknown_capability) = 1214.
ds_validate_code(ds_validate_capability_duplicate) = 1215.
ds_validate_code(ds_validate_capability_constraint) = 1216.
ds_validate_code(ds_validate_capability_disabled) = 1217.
ds_validate_code(ds_validate_use_in_test) = 1218.
ds_validate_code(ds_validate_import_of_program) = 1219.
ds_validate_code(ds_validate_not_a_program) = 1220.
ds_validate_code(ds_validate_dialect_unknown_capability) = 1221.
ds_validate_code(ds_validate_capability_deferred) = 1222.
ds_validate_code(ds_validate_ambiguous_companion_slot) = 1300.
ds_validate_code(ds_validate_companion_slot_collision) = 1301.
ds_validate_code(ds_validate_duplicate_schema) = 1303.
ds_validate_code(ds_validate_duplicate_slot) = 1304.
ds_validate_code(ds_validate_identity_role_non_logical) = 1306.
ds_validate_code(ds_validate_identity_role_required) = 1307.
ds_validate_code(ds_validate_no_series_for_companion_slot) = 1309.
ds_validate_code(ds_validate_unknown_schema) = 1311.
ds_validate_code(ds_validate_unknown_slot) = 1312.
ds_validate_code(ds_validate_bad_lifecycle_flag) = 1313.
ds_validate_code(ds_validate_tolerance_bad_type) = 1314.
ds_validate_code(ds_validate_tolerance_literal_type) = 1315.
ds_validate_code(ds_validate_tolerance_non_logical) = 1316.
ds_validate_code(ds_validate_tolerance_on_key) = 1317.
ds_validate_code(ds_validate_tolerance_ttl_schema) = 1318.
ds_validate_code(ds_validate_logical_emit_self_ending) = 1319.
ds_validate_code(ds_validate_capacity_bad_type) = 1320.
ds_validate_code(ds_validate_capacity_not_positive) = 1321.
ds_validate_code(ds_validate_missing_slot) = 1322.
ds_validate_code(ds_validate_capacity_literal_exceeded) = 1323.
ds_validate_code(ds_validate_initial_bad_scope) = 1324.
ds_validate_code(ds_validate_schema_too_many_slots) = 1325.
ds_validate_code(ds_validate_initial_not_const) = 1713.
ds_validate_code(ds_validate_initial_placement) = 1914.
ds_validate_code(ds_validate_as_non_equatable_type) = 1400.
ds_validate_code(ds_validate_as_softfail_expression) = 1401.
ds_validate_code(ds_validate_as_empty_key) = 1416.
ds_validate_code(ds_validate_call_as_not_string) = 1417.
ds_validate_code(ds_validate_bad_type) = 1402.
ds_validate_code(ds_validate_cast_identity) = 1404.
ds_validate_code(ds_validate_cast_nullability) = 1405.
ds_validate_code(ds_validate_cast_undefined) = 1406.
ds_validate_code(ds_validate_cast_unsupported) = 1407.
ds_validate_code(ds_validate_nullable_key) = 1408.
ds_validate_code(ds_validate_nullable_unnarrowed) = 1410.
ds_validate_code(ds_validate_type_mismatch) = 1411.
ds_validate_code(ds_validate_unknown_type) = 1412.
ds_validate_code(ds_validate_null_literal_comparison) = 1414.
ds_validate_code(ds_validate_closed_set_literal) = 1415.
ds_validate_code(ds_validate_bad_arity) = 1500.
ds_validate_code(ds_validate_bad_operand_type) = 1501.
ds_validate_code(ds_validate_bad_path) = 1502.
ds_validate_code(ds_validate_bitwise_type) = 1503.
ds_validate_code(ds_validate_div_by_zero) = 1504.
ds_validate_code(ds_validate_formula_ambiguous) = 1505.
ds_validate_code(ds_validate_interp_bad_format) = 1507.
ds_validate_code(ds_validate_interp_bad_path) = 1508.
ds_validate_code(ds_validate_interp_inert_position) = 1509.
ds_validate_code(ds_validate_interp_nullable_key) = 1519.
ds_validate_code(ds_validate_interp_unit_non_unit) = 1510.
ds_validate_code(ds_validate_interp_unsupported) = 1511.
ds_validate_code(ds_validate_nan_value) = 1512.
ds_validate_code(ds_validate_negative_shift) = 1513.
ds_validate_code(ds_validate_predicate_unsatisfiable) = 1514.
ds_validate_code(ds_validate_unknown_function) = 1515.
ds_validate_code(ds_validate_unknown_member) = 1520.
ds_validate_code(ds_validate_retired_builtin_spelling) = 1521.
ds_validate_code(ds_validate_now_multipattern_unsupported) = 1517.
ds_validate_code(ds_validate_bit_field_range) = 1523.
ds_validate_code(ds_validate_expression_too_deep) = 1524.
ds_validate_code(ds_validate_bad_unit_dimension) = 1600.
ds_validate_code(ds_validate_currency_cross_compare) = 1601.
ds_validate_code(ds_validate_currency_implicit_round) = 1602.
ds_validate_code(ds_validate_currency_round_arg_not_string) = 1603.
ds_validate_code(ds_validate_currency_round_no_mode) = 1604.
ds_validate_code(ds_validate_currency_round_to_unit) = 1605.
ds_validate_code(ds_validate_currency_unknown_round_mode) = 1606.
ds_validate_code(ds_validate_dim_ambiguous) = 1607.
ds_validate_code(ds_validate_dim_mismatch) = 1608.
ds_validate_code(ds_validate_fx_pair_field_not_int) = 1609.
ds_validate_code(ds_validate_fx_pair_selector) = 1610.
ds_validate_code(ds_validate_fx_pair_unknown) = 1611.
ds_validate_code(ds_validate_fx_pair_unknown_dim) = 1612.
ds_validate_code(ds_validate_fx_pair_unknown_field) = 1613.
ds_validate_code(ds_validate_fx_pair_unknown_schema) = 1614.
ds_validate_code(ds_validate_unit_body_not_affine) = 1615.
ds_validate_code(ds_validate_unit_import_collision) = 1616.
ds_validate_code(ds_validate_unit_local_shadows_import) = 1617.
ds_validate_code(ds_validate_unit_unknown_dimension) = 1618.
ds_validate_code(ds_validate_unit_unknown_symbol) = 1619.
ds_validate_code(ds_validate_unknown_unit) = 1620.
ds_validate_code(ds_validate_currency_round_to_arity) = 1621.
ds_validate_code(ds_validate_unit_tier2_bad_body) = 1622.
ds_validate_code(ds_validate_dim_agg_unannotated) = 1624.
ds_validate_code(ds_validate_complex_not_in_v1) = 1625.
ds_validate_code(ds_validate_finance_deferred) = 1626.
ds_validate_code(ds_validate_unit_literal_not_whole) = 1627.
ds_validate_code(ds_validate_unit_import_alias) = 1628.
ds_validate_code(ds_validate_unit_body_missing) = 1629.
ds_validate_code(ds_validate_const_annotation_mismatch) = 1700.
ds_validate_code(ds_validate_const_bad_annotation) = 1701.
ds_validate_code(ds_validate_const_not_foldable) = 1702.
ds_validate_code(ds_validate_duplicate_constant) = 1703.
ds_validate_code(ds_validate_duplicate_let) = 1704.
ds_validate_code(ds_validate_let_bad_annotation) = 1705.
ds_validate_code(ds_validate_let_dim_mismatch) = 1706.
ds_validate_code(ds_validate_let_impure_embedded) = 1707.
ds_validate_code(ds_validate_let_no_slot) = 1708.
ds_validate_code(ds_validate_let_shadows_binding) = 1709.
ds_validate_code(ds_validate_let_shadows_constant) = 1710.
ds_validate_code(ds_validate_unknown_const) = 1711.
ds_validate_code(ds_validate_let_type_mismatch) = 1712.
ds_validate_code(ds_validate_duplicate_binding) = 1800.
ds_validate_code(ds_validate_dwell_ttl_schema) = 1802.
ds_validate_code(ds_validate_interior_latest) = 1803.
ds_validate_code(ds_validate_then_after_negation) = 1805.
ds_validate_code(ds_validate_then_no_predecessor) = 1806.
ds_validate_code(ds_validate_unknown_binding) = 1808.
ds_validate_code(ds_validate_within_no_ts_slot) = 1809.
ds_validate_code(ds_validate_zero_within) = 1810.
ds_validate_code(ds_validate_bad_interval_component) = 1811.
ds_validate_code(ds_validate_interval_inverted) = 1812.
ds_validate_code(ds_validate_interval_mixed_operands) = 1813.
ds_validate_code(ds_validate_interval_no_ordering) = 1814.
ds_validate_code(ds_validate_interval_rel_non_interval) = 1815.
ds_validate_code(ds_validate_date_needs_tz) = 1816.
ds_validate_code(ds_validate_date_subday_arithmetic) = 1817.
ds_validate_code(ds_validate_time_needs_tz_context) = 1818.
ds_validate_code(ds_validate_unknown_time_format) = 1819.
ds_validate_code(ds_validate_unreferenced_binding) = 1820.
ds_validate_code(ds_validate_rate_key_required) = 1821.
ds_validate_code(ds_validate_rate_key_bad_path) = 1822.
ds_validate_code(ds_validate_ts_not_time) = 1823.
ds_validate_code(ds_validate_ts_read_only) = 1824.
ds_validate_code(ds_validate_ts_marked) = 1825.
ds_validate_code(ds_validate_negated_binding_out_of_scope) = 1826.
ds_validate_code(ds_validate_rule_too_many_patterns) = 1827.
ds_validate_code(ds_validate_call_cool_inside_rule_cool) = 1901.
ds_validate_code(ds_validate_call_rate_mod) = 1902.
ds_validate_code(ds_validate_rule_cycle) = 1903.
ds_validate_code(ds_validate_rule_defeat) = 1904.
ds_validate_code(ds_validate_ambient_emit_forbidden) = 1909.
ds_validate_code(ds_validate_rule_wide_rate_window) = 1911.
ds_validate_code(ds_validate_duplicate_rule) = 1912.
ds_validate_code(ds_validate_rate_negative_duration) = 1913.
ds_validate_code(ds_validate_after_nonpositive_duration) = 2001.
ds_validate_code(ds_validate_bad_kwarg) = 2002.
ds_validate_code(ds_validate_bad_log_level) = 2003.
ds_validate_code(ds_validate_continuation_chain_too_deep) = 2004.
ds_validate_code(ds_validate_duplicate_kwarg) = 2020.
ds_validate_code(ds_validate_dynamic_ident_kwarg) = 2005.
ds_validate_code(ds_validate_error_pattern_too_deep) = 2008.
ds_validate_code(ds_validate_error_pattern_unknown_family) = 2026.
ds_validate_code(ds_validate_missing_kwarg) = 2009.
ds_validate_code(ds_validate_retain_non_ttl) = 2010.
ds_validate_code(ds_validate_retain_unwired) = 2011.
ds_validate_code(ds_validate_ttl_ambient_not_in_v1) = 2012.
ds_validate_code(ds_validate_ttl_zero) = 2013.
ds_validate_code(ds_validate_unknown_service) = 2015.
ds_validate_code(ds_validate_no_response_continuation) = 2016.
ds_validate_code(ds_validate_no_response_timeout) = 2022.
ds_validate_code(ds_validate_fact_kwarg_not_binding) = 2017.
ds_validate_code(ds_validate_record_event_retired) = 2018.
ds_validate_code(ds_validate_call_response_retired) = 2019.
ds_validate_code(ds_validate_duplicate_service) = 2021.
ds_validate_code(ds_validate_kwarg_quantity_not_whole) = 2024.
ds_validate_code(ds_validate_nested_continued_call_as) = 2025.
ds_validate_code(ds_validate_hydrate_bad_limit) = 2100.
ds_validate_code(ds_validate_hydrate_filter_unsupported) = 2101.
ds_validate_code(ds_validate_hydrate_nocooldown) = 2102.
ds_validate_code(ds_validate_hydrate_no_retain) = 2103.
ds_validate_code(ds_validate_hydrate_target_no_corr) = 2104.
ds_validate_code(ds_validate_hydrate_target_corr_not_key) = 2105.
ds_validate_code(ds_validate_nolinscan_series_unbounded) = 2200.
ds_validate_code(ds_validate_series_agg_not_supported) = 2201.
ds_validate_code(ds_validate_series_agg_time_model_mismatch) = 2202.
ds_validate_code(ds_validate_series_agg_type_mismatch) = 2203.
ds_validate_code(ds_validate_series_ambiguous_slot) = 2204.
ds_validate_code(ds_validate_series_bad_identity_slot) = 2205.
ds_validate_code(ds_validate_series_duplicate_agg_needs_label) = 2210.
ds_validate_code(ds_validate_series_duplicate_decl) = 2211.
ds_validate_code(ds_validate_series_duplicate_kwarg) = 2212.
ds_validate_code(ds_validate_series_gap_hold_no_clock) = 2213.
ds_validate_code(ds_validate_series_gap_on_non_integral) = 2214.
ds_validate_code(ds_validate_series_gap_skip_logical) = 2215.
ds_validate_code(ds_validate_series_invalid_quantile) = 2216.
ds_validate_code(ds_validate_series_no_exact_backing) = 2220.
ds_validate_code(ds_validate_series_no_identity_slot) = 2221.
ds_validate_code(ds_validate_series_realtime_unbounded_backing) = 2222.
ds_validate_code(ds_validate_series_unknown_schema) = 2223.
ds_validate_code(ds_validate_series_unknown_slot) = 2224.
ds_validate_code(ds_validate_nonfact_where_multipattern) = 2227.
ds_validate_code(ds_validate_series_capacity_below_sample) = 2229.
ds_validate_code(ds_validate_series_nonpositive_window) = 2230.
ds_validate_code(ds_validate_series_nulls_required) = 2231.
ds_validate_code(ds_validate_series_nulls_on_non_nullable) = 2232.
ds_validate_code(ds_validate_series_nulls_zero_non_numeric) = 2233.
ds_validate_code(ds_validate_regex_binding_length_mismatch) = 2300.
ds_validate_code(ds_validate_regex_let_negated) = 2301.
ds_validate_code(ds_validate_regex_name_mismatch) = 2303.
ds_validate_code(ds_validate_regex_non_string_operand) = 2305.
ds_validate_code(ds_validate_regex_on_bytes) = 2306.
ds_validate_code(ds_validate_regex_syntax_error) = 2307.
ds_validate_code(ds_validate_regex_unknown_flag) = 2308.
ds_validate_code(ds_validate_regex_unsupported_feature) = 2309.
ds_validate_code(ds_validate_regex_where_has_captures) = 2310.
ds_validate_code(ds_validate_regex_capture_not_match) = 2311.
ds_validate_code(ds_validate_regex_capture_in_let) = 2313.
ds_validate_code(ds_validate_opaque_no_op) = 2400.
ds_validate_code(ds_validate_opaque_type_mismatch) = 2401.
ds_validate_code(ds_validate_opaque_unsupported_repr) = 2402.
ds_validate_code(ds_validate_duplicate_opaque_type) = 2403.
ds_validate_code(ds_validate_compile_contract_incomplete) = 2500.
ds_validate_code(ds_validate_compile_dsrt_without_realtime) = 2501.
ds_validate_code(ds_validate_compile_missing_dsrt) = 2502.
ds_validate_code(ds_validate_rt_series_unbounded) = 2503.
ds_validate_code(ds_validate_rt_string_series) = 2504.
ds_validate_code(ds_validate_rule_not_lowered) = 2505.
ds_validate_code(ds_validate_realtime_deferred) = 2506.
ds_validate_code(ds_validate_test_bad_timestamp) = 2600.
ds_validate_code(ds_validate_test_unknown_rule) = 2602.
ds_validate_code(ds_validate_test_mixed_time_mode) = 2603.
ds_validate_code(ds_validate_test_non_literal) = 2604.
ds_validate_code(ds_validate_test_stub_unkeyed) = 2605.
ds_validate_code(ds_validate_test_unknown_schema) = 2606.
ds_validate_code(ds_validate_test_unknown_slot) = 2607.
ds_validate_code(ds_validate_test_no_produces) = 2608.
ds_validate_code(ds_validate_test_duplicate_section) = 2609.
ds_validate_code(ds_validate_test_no_inputs_or_until) = 2610.
ds_validate_code(ds_validate_test_recorded_retired) = 2611.
ds_validate_code(ds_validate_test_stub_reply_type) = 2612.
ds_validate_code(ds_validate_test_stub_no_response_mismatch) = 2613.
ds_validate_code(ds_validate_test_companion_decl) = 2614.
ds_validate_code(ds_validate_test_published_where) = 2615.
ds_validate_code(ds_validate_json_literal_refused) = 2704.
ds_validate_code(ds_validate_bytes_conversion_retired) = 2705.
ds_validate_code(ds_validate_unordered_type) = 2706.
ds_validate_code(ds_validate_nolinscan_join_anchor_a) = 2801.
ds_validate_code(ds_validate_nolinscan_join_anchor_b) = 2802.
ds_validate_code(ds_validate_nolinscan_join_anchor_c) = 2803.
ds_validate_code(ds_validate_nolinscan_json_path) = 2804.
ds_validate_code(ds_validate_nolinscan_json_slot) = 2805.
ds_validate_code(ds_validate_nolinscan_novel_string) = 2807.
ds_validate_code(ds_validate_nolinscan_string_order) = 2808.
ds_validate_code(ds_validate_nolinscan_unbounded_regex) = 2809.
ds_validate_code(ds_validate_nolinscan_unbounded_string_op) = 2810.
ds_validate_code(ds_validate_nolinscan_capture_join_key) = 2811.
ds_validate_code(ds_validate_rt_schema_too_wide) = 2903.
ds_validate_code(ds_validate_bad_flag) = 2906.
ds_validate_code(ds_validate_withdraw_scope) = 3002.
ds_validate_code(ds_validate_withdraw_emit_same_schema) = 3003.
ds_validate_code(ds_validate_internal_emit_forbidden) = 3004.
ds_validate_code(ds_validate_withdrawn_binding_used) = 3005.
ds_validate_code(ds_validate_service_duplicate_hydration_field) = 3100.
ds_validate_code(ds_validate_service_kwarg_default_type) = 3101.
ds_validate_code(ds_validate_unit_formula_pair_arity) = 3102.
ds_validate_code(ds_validate_service_no_response_decl) = 3103.
ds_validate_code(ds_validate_service_response_not_schema) = 3104.
ds_validate_code(ds_validate_service_response_not_ttl) = 3105.
ds_validate_code(ds_validate_service_response_no_corr) = 3106.
ds_validate_code(ds_validate_corr_role_conflict) = 3107.
ds_validate_code(ds_validate_answer_emit_forbidden) = 3108.
ds_validate_code(ds_validate_publish_modifier) = 3109.

ds_validate_name(ds_validate_unspecified) = "DS_VALIDATE_UNSPECIFIED".
ds_validate_name(ds_validate_hard_keyword_name) = "DS_VALIDATE_HARD_KEYWORD_NAME".
ds_validate_name(ds_validate_name_collision) = "DS_VALIDATE_NAME_COLLISION".
ds_validate_name(ds_validate_reserved_builtin_name) = "DS_VALIDATE_RESERVED_BUILTIN_NAME".
ds_validate_name(ds_validate_reserved_meta_kwarg) = "DS_VALIDATE_RESERVED_META_KWARG".
ds_validate_name(ds_validate_reserved_type_name) = "DS_VALIDATE_RESERVED_TYPE_NAME".
ds_validate_name(ds_validate_duplicate_type_name) = "DS_VALIDATE_DUPLICATE_TYPE_NAME".
ds_validate_name(ds_validate_slot_type_alias) = "DS_VALIDATE_SLOT_TYPE_ALIAS".
ds_validate_name(ds_validate_legacy_as_colon) = "DS_VALIDATE_LEGACY_AS_COLON".
ds_validate_name(ds_validate_legacy_schema_lifecycle) = "DS_VALIDATE_LEGACY_SCHEMA_LIFECYCLE".
ds_validate_name(ds_validate_bare_ambient_scope_retired) = "DS_VALIDATE_BARE_AMBIENT_SCOPE_RETIRED".
ds_validate_name(ds_validate_coercion_form_removed) = "DS_VALIDATE_COERCION_FORM_REMOVED".
ds_validate_name(ds_validate_const_colon_literal_retired) = "DS_VALIDATE_CONST_COLON_LITERAL_RETIRED".
ds_validate_name(ds_validate_ambiguous_library) = "DS_VALIDATE_AMBIGUOUS_LIBRARY".
ds_validate_name(ds_validate_import_after_decl) = "DS_VALIDATE_IMPORT_AFTER_DECL".
ds_validate_name(ds_validate_import_before_use) = "DS_VALIDATE_IMPORT_BEFORE_USE".
ds_validate_name(ds_validate_import_cycle) = "DS_VALIDATE_IMPORT_CYCLE".
ds_validate_name(ds_validate_import_name_collision) = "DS_VALIDATE_IMPORT_NAME_COLLISION".
ds_validate_name(ds_validate_library_parse_failed) = "DS_VALIDATE_LIBRARY_PARSE_FAILED".
ds_validate_name(ds_validate_unknown_import_name) = "DS_VALIDATE_UNKNOWN_IMPORT_NAME".
ds_validate_name(ds_validate_unknown_library) = "DS_VALIDATE_UNKNOWN_LIBRARY".
ds_validate_name(ds_validate_unknown_qualified_const) = "DS_VALIDATE_UNKNOWN_QUALIFIED_CONST".
ds_validate_name(ds_validate_unknown_qualifier) = "DS_VALIDATE_UNKNOWN_QUALIFIER".
ds_validate_name(ds_validate_use_not_first) = "DS_VALIDATE_USE_NOT_FIRST".
ds_validate_name(ds_validate_binding_shadows_library) = "DS_VALIDATE_BINDING_SHADOWS_LIBRARY".
ds_validate_name(ds_validate_dialect_bad_name) = "DS_VALIDATE_DIALECT_BAD_NAME".
ds_validate_name(ds_validate_dialect_dependency) = "DS_VALIDATE_DIALECT_DEPENDENCY".
ds_validate_name(ds_validate_dialect_duplicate_name) = "DS_VALIDATE_DIALECT_DUPLICATE_NAME".
ds_validate_name(ds_validate_dialect_incomplete) = "DS_VALIDATE_DIALECT_INCOMPLETE".
ds_validate_name(ds_validate_unknown_dialect) = "DS_VALIDATE_UNKNOWN_DIALECT".
ds_validate_name(ds_validate_unknown_capability) = "DS_VALIDATE_UNKNOWN_CAPABILITY".
ds_validate_name(ds_validate_capability_duplicate) = "DS_VALIDATE_CAPABILITY_DUPLICATE".
ds_validate_name(ds_validate_capability_constraint) = "DS_VALIDATE_CAPABILITY_CONSTRAINT".
ds_validate_name(ds_validate_capability_disabled) = "DS_VALIDATE_CAPABILITY_DISABLED".
ds_validate_name(ds_validate_use_in_test) = "DS_VALIDATE_USE_IN_TEST".
ds_validate_name(ds_validate_import_of_program) = "DS_VALIDATE_IMPORT_OF_PROGRAM".
ds_validate_name(ds_validate_not_a_program) = "DS_VALIDATE_NOT_A_PROGRAM".
ds_validate_name(ds_validate_dialect_unknown_capability) = "DS_VALIDATE_DIALECT_UNKNOWN_CAPABILITY".
ds_validate_name(ds_validate_capability_deferred) = "DS_VALIDATE_CAPABILITY_DEFERRED".
ds_validate_name(ds_validate_ambiguous_companion_slot) = "DS_VALIDATE_AMBIGUOUS_COMPANION_SLOT".
ds_validate_name(ds_validate_companion_slot_collision) = "DS_VALIDATE_COMPANION_SLOT_COLLISION".
ds_validate_name(ds_validate_duplicate_schema) = "DS_VALIDATE_DUPLICATE_SCHEMA".
ds_validate_name(ds_validate_duplicate_slot) = "DS_VALIDATE_DUPLICATE_SLOT".
ds_validate_name(ds_validate_identity_role_non_logical) = "DS_VALIDATE_IDENTITY_ROLE_NON_LOGICAL".
ds_validate_name(ds_validate_identity_role_required) = "DS_VALIDATE_IDENTITY_ROLE_REQUIRED".
ds_validate_name(ds_validate_no_series_for_companion_slot) = "DS_VALIDATE_NO_SERIES_FOR_COMPANION_SLOT".
ds_validate_name(ds_validate_unknown_schema) = "DS_VALIDATE_UNKNOWN_SCHEMA".
ds_validate_name(ds_validate_unknown_slot) = "DS_VALIDATE_UNKNOWN_SLOT".
ds_validate_name(ds_validate_bad_lifecycle_flag) = "DS_VALIDATE_BAD_LIFECYCLE_FLAG".
ds_validate_name(ds_validate_tolerance_bad_type) = "DS_VALIDATE_TOLERANCE_BAD_TYPE".
ds_validate_name(ds_validate_tolerance_literal_type) = "DS_VALIDATE_TOLERANCE_LITERAL_TYPE".
ds_validate_name(ds_validate_tolerance_non_logical) = "DS_VALIDATE_TOLERANCE_NON_LOGICAL".
ds_validate_name(ds_validate_tolerance_on_key) = "DS_VALIDATE_TOLERANCE_ON_KEY".
ds_validate_name(ds_validate_tolerance_ttl_schema) = "DS_VALIDATE_TOLERANCE_TTL_SCHEMA".
ds_validate_name(ds_validate_logical_emit_self_ending) = "DS_VALIDATE_LOGICAL_EMIT_SELF_ENDING".
ds_validate_name(ds_validate_capacity_bad_type) = "DS_VALIDATE_CAPACITY_BAD_TYPE".
ds_validate_name(ds_validate_capacity_not_positive) = "DS_VALIDATE_CAPACITY_NOT_POSITIVE".
ds_validate_name(ds_validate_missing_slot) = "DS_VALIDATE_MISSING_SLOT".
ds_validate_name(ds_validate_capacity_literal_exceeded) = "DS_VALIDATE_CAPACITY_LITERAL_EXCEEDED".
ds_validate_name(ds_validate_initial_bad_scope) = "DS_VALIDATE_INITIAL_BAD_SCOPE".
ds_validate_name(ds_validate_schema_too_many_slots) = "DS_VALIDATE_SCHEMA_TOO_MANY_SLOTS".
ds_validate_name(ds_validate_initial_not_const) = "DS_VALIDATE_INITIAL_NOT_CONST".
ds_validate_name(ds_validate_initial_placement) = "DS_VALIDATE_INITIAL_PLACEMENT".
ds_validate_name(ds_validate_as_non_equatable_type) = "DS_VALIDATE_AS_NON_EQUATABLE_TYPE".
ds_validate_name(ds_validate_as_softfail_expression) = "DS_VALIDATE_AS_SOFTFAIL_EXPRESSION".
ds_validate_name(ds_validate_as_empty_key) = "DS_VALIDATE_AS_EMPTY_KEY".
ds_validate_name(ds_validate_call_as_not_string) = "DS_VALIDATE_CALL_AS_NOT_STRING".
ds_validate_name(ds_validate_bad_type) = "DS_VALIDATE_BAD_TYPE".
ds_validate_name(ds_validate_cast_identity) = "DS_VALIDATE_CAST_IDENTITY".
ds_validate_name(ds_validate_cast_nullability) = "DS_VALIDATE_CAST_NULLABILITY".
ds_validate_name(ds_validate_cast_undefined) = "DS_VALIDATE_CAST_UNDEFINED".
ds_validate_name(ds_validate_cast_unsupported) = "DS_VALIDATE_CAST_UNSUPPORTED".
ds_validate_name(ds_validate_nullable_key) = "DS_VALIDATE_NULLABLE_KEY".
ds_validate_name(ds_validate_nullable_unnarrowed) = "DS_VALIDATE_NULLABLE_UNNARROWED".
ds_validate_name(ds_validate_type_mismatch) = "DS_VALIDATE_TYPE_MISMATCH".
ds_validate_name(ds_validate_unknown_type) = "DS_VALIDATE_UNKNOWN_TYPE".
ds_validate_name(ds_validate_null_literal_comparison) = "DS_VALIDATE_NULL_LITERAL_COMPARISON".
ds_validate_name(ds_validate_closed_set_literal) = "DS_VALIDATE_CLOSED_SET_LITERAL".
ds_validate_name(ds_validate_bad_arity) = "DS_VALIDATE_BAD_ARITY".
ds_validate_name(ds_validate_bad_operand_type) = "DS_VALIDATE_BAD_OPERAND_TYPE".
ds_validate_name(ds_validate_bad_path) = "DS_VALIDATE_BAD_PATH".
ds_validate_name(ds_validate_bitwise_type) = "DS_VALIDATE_BITWISE_TYPE".
ds_validate_name(ds_validate_div_by_zero) = "DS_VALIDATE_DIV_BY_ZERO".
ds_validate_name(ds_validate_formula_ambiguous) = "DS_VALIDATE_FORMULA_AMBIGUOUS".
ds_validate_name(ds_validate_interp_bad_format) = "DS_VALIDATE_INTERP_BAD_FORMAT".
ds_validate_name(ds_validate_interp_bad_path) = "DS_VALIDATE_INTERP_BAD_PATH".
ds_validate_name(ds_validate_interp_inert_position) = "DS_VALIDATE_INTERP_INERT_POSITION".
ds_validate_name(ds_validate_interp_nullable_key) = "DS_VALIDATE_INTERP_NULLABLE_KEY".
ds_validate_name(ds_validate_interp_unit_non_unit) = "DS_VALIDATE_INTERP_UNIT_NON_UNIT".
ds_validate_name(ds_validate_interp_unsupported) = "DS_VALIDATE_INTERP_UNSUPPORTED".
ds_validate_name(ds_validate_nan_value) = "DS_VALIDATE_NAN_VALUE".
ds_validate_name(ds_validate_negative_shift) = "DS_VALIDATE_NEGATIVE_SHIFT".
ds_validate_name(ds_validate_predicate_unsatisfiable) = "DS_VALIDATE_PREDICATE_UNSATISFIABLE".
ds_validate_name(ds_validate_unknown_function) = "DS_VALIDATE_UNKNOWN_FUNCTION".
ds_validate_name(ds_validate_unknown_member) = "DS_VALIDATE_UNKNOWN_MEMBER".
ds_validate_name(ds_validate_retired_builtin_spelling) = "DS_VALIDATE_RETIRED_BUILTIN_SPELLING".
ds_validate_name(ds_validate_now_multipattern_unsupported) = "DS_VALIDATE_NOW_MULTIPATTERN_UNSUPPORTED".
ds_validate_name(ds_validate_bit_field_range) = "DS_VALIDATE_BIT_FIELD_RANGE".
ds_validate_name(ds_validate_expression_too_deep) = "DS_VALIDATE_EXPRESSION_TOO_DEEP".
ds_validate_name(ds_validate_bad_unit_dimension) = "DS_VALIDATE_BAD_UNIT_DIMENSION".
ds_validate_name(ds_validate_currency_cross_compare) = "DS_VALIDATE_CURRENCY_CROSS_COMPARE".
ds_validate_name(ds_validate_currency_implicit_round) = "DS_VALIDATE_CURRENCY_IMPLICIT_ROUND".
ds_validate_name(ds_validate_currency_round_arg_not_string) = "DS_VALIDATE_CURRENCY_ROUND_ARG_NOT_STRING".
ds_validate_name(ds_validate_currency_round_no_mode) = "DS_VALIDATE_CURRENCY_ROUND_NO_MODE".
ds_validate_name(ds_validate_currency_round_to_unit) = "DS_VALIDATE_CURRENCY_ROUND_TO_UNIT".
ds_validate_name(ds_validate_currency_unknown_round_mode) = "DS_VALIDATE_CURRENCY_UNKNOWN_ROUND_MODE".
ds_validate_name(ds_validate_dim_ambiguous) = "DS_VALIDATE_DIM_AMBIGUOUS".
ds_validate_name(ds_validate_dim_mismatch) = "DS_VALIDATE_DIM_MISMATCH".
ds_validate_name(ds_validate_fx_pair_field_not_int) = "DS_VALIDATE_FX_PAIR_FIELD_NOT_INT".
ds_validate_name(ds_validate_fx_pair_selector) = "DS_VALIDATE_FX_PAIR_SELECTOR".
ds_validate_name(ds_validate_fx_pair_unknown) = "DS_VALIDATE_FX_PAIR_UNKNOWN".
ds_validate_name(ds_validate_fx_pair_unknown_dim) = "DS_VALIDATE_FX_PAIR_UNKNOWN_DIM".
ds_validate_name(ds_validate_fx_pair_unknown_field) = "DS_VALIDATE_FX_PAIR_UNKNOWN_FIELD".
ds_validate_name(ds_validate_fx_pair_unknown_schema) = "DS_VALIDATE_FX_PAIR_UNKNOWN_SCHEMA".
ds_validate_name(ds_validate_unit_body_not_affine) = "DS_VALIDATE_UNIT_BODY_NOT_AFFINE".
ds_validate_name(ds_validate_unit_import_collision) = "DS_VALIDATE_UNIT_IMPORT_COLLISION".
ds_validate_name(ds_validate_unit_local_shadows_import) = "DS_VALIDATE_UNIT_LOCAL_SHADOWS_IMPORT".
ds_validate_name(ds_validate_unit_unknown_dimension) = "DS_VALIDATE_UNIT_UNKNOWN_DIMENSION".
ds_validate_name(ds_validate_unit_unknown_symbol) = "DS_VALIDATE_UNIT_UNKNOWN_SYMBOL".
ds_validate_name(ds_validate_unknown_unit) = "DS_VALIDATE_UNKNOWN_UNIT".
ds_validate_name(ds_validate_currency_round_to_arity) = "DS_VALIDATE_CURRENCY_ROUND_TO_ARITY".
ds_validate_name(ds_validate_unit_tier2_bad_body) = "DS_VALIDATE_UNIT_TIER2_BAD_BODY".
ds_validate_name(ds_validate_dim_agg_unannotated) = "DS_VALIDATE_DIM_AGG_UNANNOTATED".
ds_validate_name(ds_validate_complex_not_in_v1) = "DS_VALIDATE_COMPLEX_NOT_IN_V1".
ds_validate_name(ds_validate_finance_deferred) = "DS_VALIDATE_FINANCE_DEFERRED".
ds_validate_name(ds_validate_unit_literal_not_whole) = "DS_VALIDATE_UNIT_LITERAL_NOT_WHOLE".
ds_validate_name(ds_validate_unit_import_alias) = "DS_VALIDATE_UNIT_IMPORT_ALIAS".
ds_validate_name(ds_validate_unit_body_missing) = "DS_VALIDATE_UNIT_BODY_MISSING".
ds_validate_name(ds_validate_const_annotation_mismatch) = "DS_VALIDATE_CONST_ANNOTATION_MISMATCH".
ds_validate_name(ds_validate_const_bad_annotation) = "DS_VALIDATE_CONST_BAD_ANNOTATION".
ds_validate_name(ds_validate_const_not_foldable) = "DS_VALIDATE_CONST_NOT_FOLDABLE".
ds_validate_name(ds_validate_duplicate_constant) = "DS_VALIDATE_DUPLICATE_CONSTANT".
ds_validate_name(ds_validate_duplicate_let) = "DS_VALIDATE_DUPLICATE_LET".
ds_validate_name(ds_validate_let_bad_annotation) = "DS_VALIDATE_LET_BAD_ANNOTATION".
ds_validate_name(ds_validate_let_dim_mismatch) = "DS_VALIDATE_LET_DIM_MISMATCH".
ds_validate_name(ds_validate_let_impure_embedded) = "DS_VALIDATE_LET_IMPURE_EMBEDDED".
ds_validate_name(ds_validate_let_no_slot) = "DS_VALIDATE_LET_NO_SLOT".
ds_validate_name(ds_validate_let_shadows_binding) = "DS_VALIDATE_LET_SHADOWS_BINDING".
ds_validate_name(ds_validate_let_shadows_constant) = "DS_VALIDATE_LET_SHADOWS_CONSTANT".
ds_validate_name(ds_validate_unknown_const) = "DS_VALIDATE_UNKNOWN_CONST".
ds_validate_name(ds_validate_let_type_mismatch) = "DS_VALIDATE_LET_TYPE_MISMATCH".
ds_validate_name(ds_validate_duplicate_binding) = "DS_VALIDATE_DUPLICATE_BINDING".
ds_validate_name(ds_validate_dwell_ttl_schema) = "DS_VALIDATE_DWELL_TTL_SCHEMA".
ds_validate_name(ds_validate_interior_latest) = "DS_VALIDATE_INTERIOR_LATEST".
ds_validate_name(ds_validate_then_after_negation) = "DS_VALIDATE_THEN_AFTER_NEGATION".
ds_validate_name(ds_validate_then_no_predecessor) = "DS_VALIDATE_THEN_NO_PREDECESSOR".
ds_validate_name(ds_validate_unknown_binding) = "DS_VALIDATE_UNKNOWN_BINDING".
ds_validate_name(ds_validate_within_no_ts_slot) = "DS_VALIDATE_WITHIN_NO_TS_SLOT".
ds_validate_name(ds_validate_zero_within) = "DS_VALIDATE_ZERO_WITHIN".
ds_validate_name(ds_validate_bad_interval_component) = "DS_VALIDATE_BAD_INTERVAL_COMPONENT".
ds_validate_name(ds_validate_interval_inverted) = "DS_VALIDATE_INTERVAL_INVERTED".
ds_validate_name(ds_validate_interval_mixed_operands) = "DS_VALIDATE_INTERVAL_MIXED_OPERANDS".
ds_validate_name(ds_validate_interval_no_ordering) = "DS_VALIDATE_INTERVAL_NO_ORDERING".
ds_validate_name(ds_validate_interval_rel_non_interval) = "DS_VALIDATE_INTERVAL_REL_NON_INTERVAL".
ds_validate_name(ds_validate_date_needs_tz) = "DS_VALIDATE_DATE_NEEDS_TZ".
ds_validate_name(ds_validate_date_subday_arithmetic) = "DS_VALIDATE_DATE_SUBDAY_ARITHMETIC".
ds_validate_name(ds_validate_time_needs_tz_context) = "DS_VALIDATE_TIME_NEEDS_TZ_CONTEXT".
ds_validate_name(ds_validate_unknown_time_format) = "DS_VALIDATE_UNKNOWN_TIME_FORMAT".
ds_validate_name(ds_validate_unreferenced_binding) = "DS_VALIDATE_UNREFERENCED_BINDING".
ds_validate_name(ds_validate_rate_key_required) = "DS_VALIDATE_RATE_KEY_REQUIRED".
ds_validate_name(ds_validate_rate_key_bad_path) = "DS_VALIDATE_RATE_KEY_BAD_PATH".
ds_validate_name(ds_validate_ts_not_time) = "DS_VALIDATE_TS_NOT_TIME".
ds_validate_name(ds_validate_ts_read_only) = "DS_VALIDATE_TS_READ_ONLY".
ds_validate_name(ds_validate_ts_marked) = "DS_VALIDATE_TS_MARKED".
ds_validate_name(ds_validate_negated_binding_out_of_scope) = "DS_VALIDATE_NEGATED_BINDING_OUT_OF_SCOPE".
ds_validate_name(ds_validate_rule_too_many_patterns) = "DS_VALIDATE_RULE_TOO_MANY_PATTERNS".
ds_validate_name(ds_validate_call_cool_inside_rule_cool) = "DS_VALIDATE_CALL_COOL_INSIDE_RULE_COOL".
ds_validate_name(ds_validate_call_rate_mod) = "DS_VALIDATE_CALL_RATE_MOD".
ds_validate_name(ds_validate_rule_cycle) = "DS_VALIDATE_RULE_CYCLE".
ds_validate_name(ds_validate_rule_defeat) = "DS_VALIDATE_RULE_DEFEAT".
ds_validate_name(ds_validate_ambient_emit_forbidden) = "DS_VALIDATE_AMBIENT_EMIT_FORBIDDEN".
ds_validate_name(ds_validate_rule_wide_rate_window) = "DS_VALIDATE_RULE_WIDE_RATE_WINDOW".
ds_validate_name(ds_validate_duplicate_rule) = "DS_VALIDATE_DUPLICATE_RULE".
ds_validate_name(ds_validate_rate_negative_duration) = "DS_VALIDATE_RATE_NEGATIVE_DURATION".
ds_validate_name(ds_validate_after_nonpositive_duration) = "DS_VALIDATE_AFTER_NONPOSITIVE_DURATION".
ds_validate_name(ds_validate_bad_kwarg) = "DS_VALIDATE_BAD_KWARG".
ds_validate_name(ds_validate_bad_log_level) = "DS_VALIDATE_BAD_LOG_LEVEL".
ds_validate_name(ds_validate_continuation_chain_too_deep) = "DS_VALIDATE_CONTINUATION_CHAIN_TOO_DEEP".
ds_validate_name(ds_validate_duplicate_kwarg) = "DS_VALIDATE_DUPLICATE_KWARG".
ds_validate_name(ds_validate_dynamic_ident_kwarg) = "DS_VALIDATE_DYNAMIC_IDENT_KWARG".
ds_validate_name(ds_validate_error_pattern_too_deep) = "DS_VALIDATE_ERROR_PATTERN_TOO_DEEP".
ds_validate_name(ds_validate_error_pattern_unknown_family) = "DS_VALIDATE_ERROR_PATTERN_UNKNOWN_FAMILY".
ds_validate_name(ds_validate_missing_kwarg) = "DS_VALIDATE_MISSING_KWARG".
ds_validate_name(ds_validate_retain_non_ttl) = "DS_VALIDATE_RETAIN_NON_TTL".
ds_validate_name(ds_validate_retain_unwired) = "DS_VALIDATE_RETAIN_UNWIRED".
ds_validate_name(ds_validate_ttl_ambient_not_in_v1) = "DS_VALIDATE_TTL_AMBIENT_NOT_IN_V1".
ds_validate_name(ds_validate_ttl_zero) = "DS_VALIDATE_TTL_ZERO".
ds_validate_name(ds_validate_unknown_service) = "DS_VALIDATE_UNKNOWN_SERVICE".
ds_validate_name(ds_validate_no_response_continuation) = "DS_VALIDATE_NO_RESPONSE_CONTINUATION".
ds_validate_name(ds_validate_no_response_timeout) = "DS_VALIDATE_NO_RESPONSE_TIMEOUT".
ds_validate_name(ds_validate_fact_kwarg_not_binding) = "DS_VALIDATE_FACT_KWARG_NOT_BINDING".
ds_validate_name(ds_validate_record_event_retired) = "DS_VALIDATE_RECORD_EVENT_RETIRED".
ds_validate_name(ds_validate_call_response_retired) = "DS_VALIDATE_CALL_RESPONSE_RETIRED".
ds_validate_name(ds_validate_duplicate_service) = "DS_VALIDATE_DUPLICATE_SERVICE".
ds_validate_name(ds_validate_kwarg_quantity_not_whole) = "DS_VALIDATE_KWARG_QUANTITY_NOT_WHOLE".
ds_validate_name(ds_validate_nested_continued_call_as) = "DS_VALIDATE_NESTED_CONTINUED_CALL_AS".
ds_validate_name(ds_validate_hydrate_bad_limit) = "DS_VALIDATE_HYDRATE_BAD_LIMIT".
ds_validate_name(ds_validate_hydrate_filter_unsupported) = "DS_VALIDATE_HYDRATE_FILTER_UNSUPPORTED".
ds_validate_name(ds_validate_hydrate_nocooldown) = "DS_VALIDATE_HYDRATE_NOCOOLDOWN".
ds_validate_name(ds_validate_hydrate_no_retain) = "DS_VALIDATE_HYDRATE_NO_RETAIN".
ds_validate_name(ds_validate_hydrate_target_no_corr) = "DS_VALIDATE_HYDRATE_TARGET_NO_CORR".
ds_validate_name(ds_validate_hydrate_target_corr_not_key) = "DS_VALIDATE_HYDRATE_TARGET_CORR_NOT_KEY".
ds_validate_name(ds_validate_nolinscan_series_unbounded) = "DS_VALIDATE_NOLINSCAN_SERIES_UNBOUNDED".
ds_validate_name(ds_validate_series_agg_not_supported) = "DS_VALIDATE_SERIES_AGG_NOT_SUPPORTED".
ds_validate_name(ds_validate_series_agg_time_model_mismatch) = "DS_VALIDATE_SERIES_AGG_TIME_MODEL_MISMATCH".
ds_validate_name(ds_validate_series_agg_type_mismatch) = "DS_VALIDATE_SERIES_AGG_TYPE_MISMATCH".
ds_validate_name(ds_validate_series_ambiguous_slot) = "DS_VALIDATE_SERIES_AMBIGUOUS_SLOT".
ds_validate_name(ds_validate_series_bad_identity_slot) = "DS_VALIDATE_SERIES_BAD_IDENTITY_SLOT".
ds_validate_name(ds_validate_series_duplicate_agg_needs_label) = "DS_VALIDATE_SERIES_DUPLICATE_AGG_NEEDS_LABEL".
ds_validate_name(ds_validate_series_duplicate_decl) = "DS_VALIDATE_SERIES_DUPLICATE_DECL".
ds_validate_name(ds_validate_series_duplicate_kwarg) = "DS_VALIDATE_SERIES_DUPLICATE_KWARG".
ds_validate_name(ds_validate_series_gap_hold_no_clock) = "DS_VALIDATE_SERIES_GAP_HOLD_NO_CLOCK".
ds_validate_name(ds_validate_series_gap_on_non_integral) = "DS_VALIDATE_SERIES_GAP_ON_NON_INTEGRAL".
ds_validate_name(ds_validate_series_gap_skip_logical) = "DS_VALIDATE_SERIES_GAP_SKIP_LOGICAL".
ds_validate_name(ds_validate_series_invalid_quantile) = "DS_VALIDATE_SERIES_INVALID_QUANTILE".
ds_validate_name(ds_validate_series_no_exact_backing) = "DS_VALIDATE_SERIES_NO_EXACT_BACKING".
ds_validate_name(ds_validate_series_no_identity_slot) = "DS_VALIDATE_SERIES_NO_IDENTITY_SLOT".
ds_validate_name(ds_validate_series_realtime_unbounded_backing) = "DS_VALIDATE_SERIES_REALTIME_UNBOUNDED_BACKING".
ds_validate_name(ds_validate_series_unknown_schema) = "DS_VALIDATE_SERIES_UNKNOWN_SCHEMA".
ds_validate_name(ds_validate_series_unknown_slot) = "DS_VALIDATE_SERIES_UNKNOWN_SLOT".
ds_validate_name(ds_validate_nonfact_where_multipattern) = "DS_VALIDATE_NONFACT_WHERE_MULTIPATTERN".
ds_validate_name(ds_validate_series_capacity_below_sample) = "DS_VALIDATE_SERIES_CAPACITY_BELOW_SAMPLE".
ds_validate_name(ds_validate_series_nonpositive_window) = "DS_VALIDATE_SERIES_NONPOSITIVE_WINDOW".
ds_validate_name(ds_validate_series_nulls_required) = "DS_VALIDATE_SERIES_NULLS_REQUIRED".
ds_validate_name(ds_validate_series_nulls_on_non_nullable) = "DS_VALIDATE_SERIES_NULLS_ON_NON_NULLABLE".
ds_validate_name(ds_validate_series_nulls_zero_non_numeric) = "DS_VALIDATE_SERIES_NULLS_ZERO_NON_NUMERIC".
ds_validate_name(ds_validate_regex_binding_length_mismatch) = "DS_VALIDATE_REGEX_BINDING_LENGTH_MISMATCH".
ds_validate_name(ds_validate_regex_let_negated) = "DS_VALIDATE_REGEX_LET_NEGATED".
ds_validate_name(ds_validate_regex_name_mismatch) = "DS_VALIDATE_REGEX_NAME_MISMATCH".
ds_validate_name(ds_validate_regex_non_string_operand) = "DS_VALIDATE_REGEX_NON_STRING_OPERAND".
ds_validate_name(ds_validate_regex_on_bytes) = "DS_VALIDATE_REGEX_ON_BYTES".
ds_validate_name(ds_validate_regex_syntax_error) = "DS_VALIDATE_REGEX_SYNTAX_ERROR".
ds_validate_name(ds_validate_regex_unknown_flag) = "DS_VALIDATE_REGEX_UNKNOWN_FLAG".
ds_validate_name(ds_validate_regex_unsupported_feature) = "DS_VALIDATE_REGEX_UNSUPPORTED_FEATURE".
ds_validate_name(ds_validate_regex_where_has_captures) = "DS_VALIDATE_REGEX_WHERE_HAS_CAPTURES".
ds_validate_name(ds_validate_regex_capture_not_match) = "DS_VALIDATE_REGEX_CAPTURE_NOT_MATCH".
ds_validate_name(ds_validate_regex_capture_in_let) = "DS_VALIDATE_REGEX_CAPTURE_IN_LET".
ds_validate_name(ds_validate_opaque_no_op) = "DS_VALIDATE_OPAQUE_NO_OP".
ds_validate_name(ds_validate_opaque_type_mismatch) = "DS_VALIDATE_OPAQUE_TYPE_MISMATCH".
ds_validate_name(ds_validate_opaque_unsupported_repr) = "DS_VALIDATE_OPAQUE_UNSUPPORTED_REPR".
ds_validate_name(ds_validate_duplicate_opaque_type) = "DS_VALIDATE_DUPLICATE_OPAQUE_TYPE".
ds_validate_name(ds_validate_compile_contract_incomplete) = "DS_VALIDATE_COMPILE_CONTRACT_INCOMPLETE".
ds_validate_name(ds_validate_compile_dsrt_without_realtime) = "DS_VALIDATE_COMPILE_DSRT_WITHOUT_REALTIME".
ds_validate_name(ds_validate_compile_missing_dsrt) = "DS_VALIDATE_COMPILE_MISSING_DSRT".
ds_validate_name(ds_validate_rt_series_unbounded) = "DS_VALIDATE_RT_SERIES_UNBOUNDED".
ds_validate_name(ds_validate_rt_string_series) = "DS_VALIDATE_RT_STRING_SERIES".
ds_validate_name(ds_validate_rule_not_lowered) = "DS_VALIDATE_RULE_NOT_LOWERED".
ds_validate_name(ds_validate_realtime_deferred) = "DS_VALIDATE_REALTIME_DEFERRED".
ds_validate_name(ds_validate_test_bad_timestamp) = "DS_VALIDATE_TEST_BAD_TIMESTAMP".
ds_validate_name(ds_validate_test_unknown_rule) = "DS_VALIDATE_TEST_UNKNOWN_RULE".
ds_validate_name(ds_validate_test_mixed_time_mode) = "DS_VALIDATE_TEST_MIXED_TIME_MODE".
ds_validate_name(ds_validate_test_non_literal) = "DS_VALIDATE_TEST_NON_LITERAL".
ds_validate_name(ds_validate_test_stub_unkeyed) = "DS_VALIDATE_TEST_STUB_UNKEYED".
ds_validate_name(ds_validate_test_unknown_schema) = "DS_VALIDATE_TEST_UNKNOWN_SCHEMA".
ds_validate_name(ds_validate_test_unknown_slot) = "DS_VALIDATE_TEST_UNKNOWN_SLOT".
ds_validate_name(ds_validate_test_no_produces) = "DS_VALIDATE_TEST_NO_PRODUCES".
ds_validate_name(ds_validate_test_duplicate_section) = "DS_VALIDATE_TEST_DUPLICATE_SECTION".
ds_validate_name(ds_validate_test_no_inputs_or_until) = "DS_VALIDATE_TEST_NO_INPUTS_OR_UNTIL".
ds_validate_name(ds_validate_test_recorded_retired) = "DS_VALIDATE_TEST_RECORDED_RETIRED".
ds_validate_name(ds_validate_test_stub_reply_type) = "DS_VALIDATE_TEST_STUB_REPLY_TYPE".
ds_validate_name(ds_validate_test_stub_no_response_mismatch) = "DS_VALIDATE_TEST_STUB_NO_RESPONSE_MISMATCH".
ds_validate_name(ds_validate_test_companion_decl) = "DS_VALIDATE_TEST_COMPANION_DECL".
ds_validate_name(ds_validate_test_published_where) = "DS_VALIDATE_TEST_PUBLISHED_WHERE".
ds_validate_name(ds_validate_json_literal_refused) = "DS_VALIDATE_JSON_LITERAL_REFUSED".
ds_validate_name(ds_validate_bytes_conversion_retired) = "DS_VALIDATE_BYTES_CONVERSION_RETIRED".
ds_validate_name(ds_validate_unordered_type) = "DS_VALIDATE_UNORDERED_TYPE".
ds_validate_name(ds_validate_nolinscan_join_anchor_a) = "DS_VALIDATE_NOLINSCAN_JOIN_ANCHOR_A".
ds_validate_name(ds_validate_nolinscan_join_anchor_b) = "DS_VALIDATE_NOLINSCAN_JOIN_ANCHOR_B".
ds_validate_name(ds_validate_nolinscan_join_anchor_c) = "DS_VALIDATE_NOLINSCAN_JOIN_ANCHOR_C".
ds_validate_name(ds_validate_nolinscan_json_path) = "DS_VALIDATE_NOLINSCAN_JSON_PATH".
ds_validate_name(ds_validate_nolinscan_json_slot) = "DS_VALIDATE_NOLINSCAN_JSON_SLOT".
ds_validate_name(ds_validate_nolinscan_novel_string) = "DS_VALIDATE_NOLINSCAN_NOVEL_STRING".
ds_validate_name(ds_validate_nolinscan_string_order) = "DS_VALIDATE_NOLINSCAN_STRING_ORDER".
ds_validate_name(ds_validate_nolinscan_unbounded_regex) = "DS_VALIDATE_NOLINSCAN_UNBOUNDED_REGEX".
ds_validate_name(ds_validate_nolinscan_unbounded_string_op) = "DS_VALIDATE_NOLINSCAN_UNBOUNDED_STRING_OP".
ds_validate_name(ds_validate_nolinscan_capture_join_key) = "DS_VALIDATE_NOLINSCAN_CAPTURE_JOIN_KEY".
ds_validate_name(ds_validate_rt_schema_too_wide) = "DS_VALIDATE_RT_SCHEMA_TOO_WIDE".
ds_validate_name(ds_validate_bad_flag) = "DS_VALIDATE_BAD_FLAG".
ds_validate_name(ds_validate_withdraw_scope) = "DS_VALIDATE_WITHDRAW_SCOPE".
ds_validate_name(ds_validate_withdraw_emit_same_schema) = "DS_VALIDATE_WITHDRAW_EMIT_SAME_SCHEMA".
ds_validate_name(ds_validate_internal_emit_forbidden) = "DS_VALIDATE_INTERNAL_EMIT_FORBIDDEN".
ds_validate_name(ds_validate_withdrawn_binding_used) = "DS_VALIDATE_WITHDRAWN_BINDING_USED".
ds_validate_name(ds_validate_service_duplicate_hydration_field) = "DS_VALIDATE_SERVICE_DUPLICATE_HYDRATION_FIELD".
ds_validate_name(ds_validate_service_kwarg_default_type) = "DS_VALIDATE_SERVICE_KWARG_DEFAULT_TYPE".
ds_validate_name(ds_validate_unit_formula_pair_arity) = "DS_VALIDATE_UNIT_FORMULA_PAIR_ARITY".
ds_validate_name(ds_validate_service_no_response_decl) = "DS_VALIDATE_SERVICE_NO_RESPONSE_DECL".
ds_validate_name(ds_validate_service_response_not_schema) = "DS_VALIDATE_SERVICE_RESPONSE_NOT_SCHEMA".
ds_validate_name(ds_validate_service_response_not_ttl) = "DS_VALIDATE_SERVICE_RESPONSE_NOT_TTL".
ds_validate_name(ds_validate_service_response_no_corr) = "DS_VALIDATE_SERVICE_RESPONSE_NO_CORR".
ds_validate_name(ds_validate_corr_role_conflict) = "DS_VALIDATE_CORR_ROLE_CONFLICT".
ds_validate_name(ds_validate_answer_emit_forbidden) = "DS_VALIDATE_ANSWER_EMIT_FORBIDDEN".
ds_validate_name(ds_validate_publish_modifier) = "DS_VALIDATE_PUBLISH_MODIFIER".

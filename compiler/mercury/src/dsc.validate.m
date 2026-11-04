% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.validate -- everything schema-dependent and cross-declaration, over a
% `resolved_file`.
%-----------------------------------------------------------------------------%

:- module dsc.validate.
:- interface.

:- import_module dsc.ast.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.resolve.
:- import_module dsc.token.

:- import_module list.

%-----------------------------------------------------------------------------%

    %@helper
:- type validate_result
    --->    validate_ok(list(diagnostic))
            % No error. The list is the warnings.
    ;       validate_errors(list(diagnostic)).
            % At least one error; warnings ride along in source order.

    % One module, against the program's settings it carries (`rf_program`).
    %
    %@helper
:- pred validate_file(resolved_file::in, validate_result::out) is det.

    % The schemas that must carry a `hydrated_corr` slot, sorted and without
    % duplicates. `HydratedSample` is not among them: `dsc.builtins` declares the
    % slot on it.
    %
    %@spec [RHIM.2.2]
:- func rhim_2_2_hydration_targets(resolved_file) = list(string).

    % Every finance construct a file writes, each `DS_VALIDATE_FINANCE_DEFERRED`.
    %
    %@helper
:- func finance_deferred(ast_file) = list(diagnostic).

    %@helper
:- func decl_pos(ast_decl) = pos.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.builtins.
:- import_module ds.capability.
:- import_module dsc.capability.
:- import_module dsc.dialect.
:- import_module dsc.expr.
:- import_module dsc.reserved.
:- import_module dsc.cycle.
:- import_module dsc.dstest.
:- import_module dsc.series.
:- import_module dsc.strlit.
:- import_module dsc.quantity.
:- import_module dsc.typecheck.
:- import_module dsc.types.
:- import_module dsc.uniname.
:- import_module ds.
:- import_module ds.i64.
:- import_module ds.id.
:- import_module ds.re2.

:- import_module bool.

:- import_module char.
:- import_module float.
:- import_module int.
:- import_module int64.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module set.
:- import_module solutions.
:- import_module string.
:- import_module uint32.

%-----------------------------------------------------------------------------%

validate_file(RF, Result) :-
    File = RF ^ rf_ast,
    limp_2_3_2_placement(File ^ af_decls, File ^ af_use, PlacementErrors),
    lgra_3_2_use_first(File ^ af_decls, File ^ af_use, UsePlacementErrors),
    lgra_24_2_initial(RF, InitialErrors),
    list.foldl(lgra_5_10_schema(RF), File ^ af_decls, [], RevSchemaErrors),
    list.foldl(lgra_6_6_7_rate_mods, File ^ af_decls, [], RevRateMods),
    list.foldl(lgra_13_5_series_windows(RF), File ^ af_decls, [],
        RevSeriesWindows),
    list.foldl(lgra_2_8_11_time_expr_names(RF), File ^ af_decls, [],
        RevTimeNames),
    list.foldl(lgra_23_2_service_residue(RF), File ^ af_decls, [],
        RevKwargMods),
    list.foldl(luni_4_5_formula_arity, File ^ af_decls, RevKwargMods,
        RevFormulaArity),
    list.foldl(llex_9_5_reserved_words, File ^ af_decls, [], RevKeywords),
    list.foldl(lgra_4_1_colon_literal, File ^ af_decls, [], RevColonConsts),
    list.foldl(const_inert_strings, File ^ af_decls, RevColonConsts,
        RevConstStrings),
    lgra_4_1_consts(RF, File ^ af_decls, ConstErrors),
    luni_4_3_unit_decls(RF, File ^ af_decls, UnitDeclErrors),
    list.foldl(lopq_10_1_representation, File ^ af_decls, [], RevOpaqueRepr),
    list.foldl(lgra_9_8_3_json_refused, File ^ af_decls, [], RevJson),
    lexp_7_3b_actions(RF, ActionErrors),
    lcrs_4_3_3_call_response_retired(RF, SiblingResponseErrors),
    lcyc_3_1_rule_graph(RF, CycleErrors),
    DialectErrors = ldia_3_4_1_gate(RF),
    lser_7_1_declarations(RF, SeriesErrors),
    HydratedCorrErrors = lhyd_4_1_7_declared_hydrated_corr(RF),
    lnls_3_nolinscan(RF, NolinscanErrors),
    Errors = PlacementErrors ++ UsePlacementErrors ++ InitialErrors
        ++ reverse(RevSchemaErrors)
        ++ reverse(RevRateMods) ++ reverse(RevSeriesWindows)
        ++ reverse(RevTimeNames)
        ++ reverse(RevFormulaArity)
        ++ reverse(RevKeywords)
        ++ reverse(RevConstStrings) ++ ConstErrors
        ++ UnitDeclErrors ++ reverse(RevOpaqueRepr) ++ reverse(RevJson)
        ++ ActionErrors ++ SiblingResponseErrors
        ++ CycleErrors ++ DialectErrors ++ SeriesErrors ++ HydratedCorrErrors
        ++ NolinscanErrors,
    % A deferred capability stands alone ([LCAP.2.1.5]): the `use` line's own
    % diagnostics are the whole answer. Severity decides the rest.
    ( if
        list.member(Deferred, DialectErrors),
        ( Deferred ^ dg_code = dc_validate(dv_realtime_deferred)
        ; Deferred ^ dg_code = dc_validate(dv_capability_deferred)
        )
    then
        Result = validate_errors(DialectErrors)
    else if list.find_first_match(is_error, Errors, _) then
        Result = validate_errors(Errors)
    else
        Result = validate_ok(Errors)
    ).

    %@helper
:- pred is_error(diagnostic::in) is semidet.

is_error(D) :-
    D ^ dg_severity = sev_error.

%-----------------------------------------------------------------------------%
% Import placement -- [LIMP.2.3.2], [LIMP.2.3.3]
%-----------------------------------------------------------------------------%

    % Both checks run on every import: an import can fail both.
    %
    %@spec [LIMP.9.3]
    %@spec [LIMP.2.3.2]
    %@spec [LIMP.2.3.3]
:- pred limp_2_3_2_placement(list(ast_decl)::in, maybe(ast_use)::in,
                             list(diagnostic)::out) is det.

limp_2_3_2_placement(Decls, MaybeUse, Errors) :-
    list.foldl2(check_placement(MaybeUse), Decls, no, _, [], RevErrors),
    Errors = reverse(RevErrors).

    % The accumulator is the first non-import declaration, once one is seen.
    %
    %@helper
:- pred check_placement(maybe(ast_use)::in, ast_decl::in,
                        maybe(pos)::in, maybe(pos)::out,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

check_placement(MaybeUse, Decl, !FirstDecl, !Errors) :-
    ( if Decl = ad_import(Import) then
        Pos = Import ^ ai_pos,
        (
            !.FirstDecl = yes(DeclPos),
            D = with_hint(error_with(dv_import_after_decl, Pos,
                "imports must cluster at the top of the file; this one "
                    ++ "follows a declaration ([LIMP.2.3.2])",
                DeclPos, "first non-import declaration here"),
                "move the import above the first schema, const, rule or "
                    ++ "service declaration"),
            !:Errors = [D | !.Errors]
        ;
            !.FirstDecl = no
        ),
        (
            MaybeUse = yes(Use),
            UsePos = Use ^ au_pos,
            ( if before(Pos, UsePos) then
                D2 = with_hint(error_with(dv_import_before_use, Pos,
                    "`use <dialect>` must precede every import "
                        ++ "([LIMP.2.3.3])",
                    UsePos, "`use` directive here"),
                    "move the `use` line to the top of the file"),
                !:Errors = [D2 | !.Errors]
            else
                true
            )
        ;
            MaybeUse = no
        )
    else if Decl = ad_schema(S), S ^ as_origin = compiler_injected then
        % A builtin schema `dsc.driver` put at the head of the list.
        true
    else
        (
            !.FirstDecl = yes(_)
        ;
            !.FirstDecl = no,
            !:FirstDecl = yes(decl_pos(Decl))
        )
    ).

%-----------------------------------------------------------------------------%
% `use` placement -- [LGRA.3.2]
%-----------------------------------------------------------------------------%

    %@spec [LGRA.3.2]
:- pred lgra_3_2_use_first(list(ast_decl)::in, maybe(ast_use)::in,
                           list(diagnostic)::out) is det.

lgra_3_2_use_first(Decls, MaybeUse, Errors) :-
    (
        MaybeUse = no,
        Errors = []
    ;
        MaybeUse = yes(Use),
        UsePos = Use ^ au_pos,
        ( if
            list.find_first_match(import_before(UsePos), Decls, _)
        then
            % [LIMP.2.3.3]'s, not ours.
            Errors = []
        else if
            list.find_first_match(counts_before(UsePos), Decls, First)
        then
            Errors = [with_hint(error_with(dv_use_not_first, UsePos,
                "`use <dialect>` must be the file's first statement "
                    ++ "([LGRA.3.2])",
                decl_pos(First), "this declaration precedes it"),
                "move the `use` line above every declaration in the file")]
        else
            Errors = []
        )
    ).

    %@helper
:- pred import_before(pos::in, ast_decl::in) is semidet.

import_before(UsePos, ad_import(Import)) :-
    before(Import ^ ai_pos, UsePos).

    % An injected schema or rule, or a companion's test, does not count: their
    % positions are not ordered against the `use` line ([LTSL.2.4]).
    %
    %@helper
:- pred counts_before(pos::in, ast_decl::in) is semidet.

counts_before(UsePos, Decl) :-
    not Decl = ad_import(_),
    not (
        Decl = ad_schema(S),
        S ^ as_origin = compiler_injected
    ),
    not (
        Decl = ad_rule(R),
        R ^ ar_origin = compiler_injected
    ),
    not (
        Decl = ad_test(T),
        T ^ tst_file = yes(_)
    ),
    before(decl_pos(Decl), UsePos).

    %@helper
:- pred before(pos::in, pos::in) is semidet.

before(pos(LineA, ColA), pos(LineB, ColB)) :-
    ( LineA < LineB
    ; LineA = LineB,
      ColA < ColB
    ).

decl_pos(ad_schema(S)) = S ^ as_pos.
decl_pos(ad_rule(R)) = R ^ ar_pos.
decl_pos(ad_const(C)) = C ^ acn_pos.
decl_pos(ad_series(S)) = S ^ asr_pos.
decl_pos(ad_service(S)) = S ^ asv_pos.
decl_pos(ad_opaque(O)) = O ^ aop_pos.
decl_pos(ad_unit(U)) = unit_pos(U).
decl_pos(ad_test(T)) = T ^ tst_pos.
decl_pos(ad_initial(B)) = B ^ ain_pos.
decl_pos(ad_import(I)) = I ^ ai_pos.

    %@helper
:- func unit_pos(ast_unit) = pos.

unit_pos(au_dimension(_, _, _, P, _)) = P.
unit_pos(au_scalar(_, _, _, P, _)) = P.
unit_pos(au_symbol(_, _, _, _, _, P, _, _)) = P.
unit_pos(au_formula(_, _, _, P)) = P.
unit_pos(au_fx_pair(_, _, _, _, _, _, _, P)) = P.

%-----------------------------------------------------------------------------%
% The `initial:` block -- [LGRA.24.2]
%-----------------------------------------------------------------------------%
%
% A fact item is checked as an `emit` is, in an environment with no binding and
% no `let`.

    %@spec [LGRA.24.2]
:- pred lgra_24_2_initial(resolved_file::in, list(diagnostic)::out) is det.

lgra_24_2_initial(RF, Errors) :-
    Decls = RF ^ rf_ast ^ af_decls,
    list.foldl3(lgra_24_2_placement, Decls, no, _, no, _, [], RevPlacement),
    Blocks = list.filter_map(initial_block_of, Decls),
    list.foldl(lgra_24_2_block(RF), Blocks, [], RevItems),
    Errors = reverse(RevPlacement) ++ reverse(RevItems).

    %@helper
:- func initial_block_of(ast_decl) = ast_initial is semidet.

initial_block_of(ad_initial(B)) = B.

    % The accumulators are the first block's position and the first author rule's.
    %
    %@spec [LGRA.24.2]
:- pred lgra_24_2_placement(ast_decl::in, maybe(pos)::in, maybe(pos)::out,
                            maybe(pos)::in, maybe(pos)::out,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_24_2_placement(Decl, !FirstBlock, !FirstRule, !Errors) :-
    ( if Decl = ad_initial(B) then
        Pos = B ^ ain_pos,
        (
            !.FirstBlock = yes(First),
            !:Errors = [with_hint(error_with(dv_initial_placement, Pos,
                "a file holds at most one `initial` block ([LGRA.24.2])",
                First, "the file's first `initial` block"),
                "move these items into the first block") | !.Errors]
        ;
            !.FirstBlock = no,
            !:FirstBlock = yes(Pos)
        ),
        (
            !.FirstRule = yes(RulePos),
            !:Errors = [with_hint(error_with(dv_initial_placement, Pos,
                "an `initial` block comes before every rule in its file "
                    ++ "([LGRA.24.2])",
                RulePos, "a rule precedes it here"),
                "move the block above the file's first rule") | !.Errors]
        ;
            !.FirstRule = no
        )
    else if Decl = ad_rule(R), R ^ ar_origin = author_declared then
        (
            !.FirstRule = no,
            !:FirstRule = yes(R ^ ar_pos)
        ;
            !.FirstRule = yes(_)
        )
    else
        true
    ).

    %@helper
:- pred lgra_24_2_block(resolved_file::in, ast_initial::in,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_24_2_block(RF, B, !Errors) :-
    Scope = rule_scope(ident("initial", B ^ ain_pos), map.init, map.init,
        map.init, map.init, map.init),
    Env = type_env(RF, Scope, da_reported, set.init),
    list.foldl(lgra_24_2_item(RF, Env), B ^ ain_items, !Errors).

    %@spec [LGRA.24.2]
:- pred lgra_24_2_item(resolved_file::in, type_env::in, ast_test_initial::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_24_2_item(RF, Env, Item, !Errors) :-
    (
        Item = tini_fact(F),
        lgra_24_2_fact(RF, Env, F, !Errors)
    ;
        Item = tini_cache(Key, Value, _),
        ( if ltsl_4_1_string_constant(RF, Key, _) then
            true
        else
            !:Errors = [lgra_24_2_not_const(expr_start(Key),
                "a cache item's key is a string with no interpolation site")
                | !.Errors]
        ),
        lgra_24_2_value(RF, Value, !Errors)
    ).

    %@spec [LGRA.24.2]
:- pred lgra_24_2_fact(resolved_file::in, type_env::in, ast_test_fact::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_24_2_fact(RF, Env, F, !Errors) :-
    Ref = F ^ tfa_schema,
    Args = F ^ tfa_args,
    ( if lgra_22_4_schema_of(RF, Ref, Schema) then
        Name = Schema ^ as_name ^ id_name,
        ( if Schema ^ as_lifecycle = al_explicit then
            true
        else
            !:Errors = [with_hint(error_at(dv_initial_bad_scope, F ^ tfa_pos,
                "`initial` places a fact of `" ++ Name ++ "`, which is not "
                    ++ "`scope explicit`; a block places only explicit facts "
                    ++ "([LGRA.24.2])"),
                "a logical fact needs an activation to justify it, a ttl one "
                    ++ "a deadline; declare `" ++ Name
                    ++ "` `scope explicit`, or assert it from a rule")
                | !.Errors]
        ),
        list.foldl(lgra_24_2_arg(RF, Env, Schema), Args, !Errors),
        lgra_13_11_missing_slots("initial", Schema, Args, F ^ tfa_pos, !Errors)
    else
        lgra_22_4_schema_ref(RF, "initial", Ref, !Errors)
    ).

    %@helper
:- pred lgra_24_2_arg(resolved_file::in, type_env::in, ast_schema::in,
                      ast_action_arg::in,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_24_2_arg(RF, Env, Schema, Arg, !Errors) :-
    (
        Arg = aaa_flag(Flag),
        !:Errors = [lgra_24_2_not_const(Flag ^ id_pos,
            "`" ++ Flag ^ id_name ++ "` has no value")
            | !.Errors]
    ;
        Arg = aaa_kwarg(Name, Value, _),
        ( if
            Name ^ id_name = "ts",
            find_slot(Schema ^ as_fields, "ts", _)
        then
            !:Errors = [with_hint(error_at(dv_ts_read_only, Name ^ id_pos,
                "`initial` writes `ts` of `" ++ Schema ^ as_name ^ id_name
                    ++ "`, which the engine fills when the block places the "
                    ++ "fact ([LFAC.9.2], [LGRA.24.3])"),
                "drop `ts:`") | !.Errors]
        else if not find_slot(Schema ^ as_fields, Name ^ id_name, _) then
            check_kwarg(Env, "initial", Schema, Arg, !Errors)
        else if not ltsl_4_1_constant(RF, Value, _) then
            lgra_24_2_value(RF, Value, !Errors)
        else if
            ltsl_4_1_constant(RF, Value, Folded),
            find_slot(Schema ^ as_fields, Name ^ id_name, Field),
            not luni_7_2_storage_value(RF, Field, Folded, _)
        then
            !:Errors = [lgra_24_2_not_const(expr_start(Value),
                "`" ++ Name ^ id_name ++ "` stores whole numbers of its unit, "
                    ++ "and this value rounds to no `Int` ([LUNI.7.2])")
                | !.Errors]
        else
            check_kwarg(Env, "initial", Schema, Arg, !Errors)
        )
    ).

    %@spec [LGRA.24.2]
:- pred lgra_24_2_value(resolved_file::in, lgra_9_3_1_expr::in,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_24_2_value(RF, Value, !Errors) :-
    ( if ltsl_4_1_constant(RF, Value, _) then
        true
    else if
        Value = ex_name(Id),
        map.contains(RF ^ rf_consts, Id ^ id_name)
    then
        !:Errors = [lgra_24_2_not_const(Id ^ id_pos,
            "`" ++ Id ^ id_name ++ "` is a `const` whose value does not fold "
                ++ "to a constant: it is NaN, it traps, or it needs a "
                ++ "conversion or a value the engine makes at run time "
                ++ "([LEXP.8.8])")
            | !.Errors]
    else
        !:Errors = [lgra_24_2_not_const(expr_start(Value),
            "a value in a block is a literal or the name of a `const`")
            | !.Errors]
    ).

    %@helper
:- func lgra_24_2_not_const(pos, string) = diagnostic.

lgra_24_2_not_const(Pos, What) =
    with_hint(error_at(dv_initial_not_const, Pos,
        What ++ " ([LGRA.24.2], [LTSL.4.1])"),
        "write the value as a literal, or name a `const` that holds it").

%-----------------------------------------------------------------------------%
% Slot markers and tolerance -- [LGRA.5.10], [LGRA.5.9], [LFAC.1.7]
%-----------------------------------------------------------------------------%
%
% Every rule here keys on the base lifecycle: `ambient` is transparent.

    %@spec [LGRA.5.10]
:- pred lgra_5_10_schema(resolved_file::in, ast_decl::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_5_10_schema(RF, Decl, !Errors) :-
    ( if Decl = ad_schema(S) then
        list.foldl(lgra_5_10_slot(RF, S ^ as_lifecycle), S ^ as_fields,
            !Errors),
        list.foldl(lfac_9_1_ts_time, S ^ as_fields, !Errors),
        list.foldl(lnul_8_10_nullable_key, S ^ as_fields, !Errors),
        list.foldl(luni_14_9_complex_slot(RF), S ^ as_fields, !Errors),
        lgra_13_4_slot_names(S, !Errors),
        lscp_1_6_spelling(S, !Errors),
        lgra_5_11_slot_count(S, !Errors)
    else
        true
    ).

    % A schema the compiler declares is `dsc.rete.lgra_8_7_index_overflows`'.
    %
    %@spec [LGRA.5.11]
:- pred lgra_5_11_slot_count(ast_schema::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_5_11_slot_count(S, !Errors) :-
    Count = list.length(S ^ as_fields),
    ( if Count > rdsc_4a_9_1_index_count then
        !:Errors = [with_hint(error_at(dv_schema_too_many_slots,
            S ^ as_name ^ id_pos,
            "schema `" ++ S ^ as_name ^ id_name ++ "` has "
                ++ string.int_to_string(Count)
                ++ " slots, past the 255 a schema may hold ([LGRA.5.11])"),
            "split it into schemas of 255 slots or fewer") | !.Errors]
    else
        true
    ).

    %@spec [LSCP.1.6]
    %@spec [LSCP.1.7]
:- pred lscp_1_6_spelling(ast_schema::in,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

lscp_1_6_spelling(S, !Errors) :-
    Name = S ^ as_name ^ id_name,
    Pos = S ^ as_name ^ id_pos,
    Scope = S ^ as_scope,
    (
        ( Scope = scope_written
        ; Scope = scope_defaulted
        )
    ;
        Scope = scope_unprefixed,
        ( if S ^ as_lifecycle = al_ttl(_, _) then
            Form = "ttl <duration>"
        else
            Form = "logical"
        ),
        !:Errors = [with_hint(error_at(dv_legacy_schema_lifecycle, Pos,
            "`schema " ++ Name ++ " " ++ Form ++ ":` is the retired v1 form; "
                ++ "a lifecycle is written on a `scope` clause ([LSCP.1.6])"),
            "write `schema " ++ Name ++ " scope " ++ Form ++ ":`") | !.Errors]
    ;
        Scope = scope_bare_ambient,
        !:Errors = [with_hint(error_at(dv_bare_ambient_scope_retired, Pos,
            "`schema " ++ Name ++ " scope ambient:`: `ambient` modifies a base "
                ++ "lifecycle and is not a scope of its own ([LSCP.1.7])"),
            "write `schema " ++ Name ++ " scope logical ambient:`, and give "
                ++ "every slot a `key` or `mutable` marker ([LGRA.5.10])")
            | !.Errors]
    ).

%-----------------------------------------------------------------------------%
% The retired value-introducer colon -- [LGRA.4.1]
%-----------------------------------------------------------------------------%

    %@spec [LGRA.4.1]
:- pred lgra_4_1_colon_literal(ast_decl::in,
                               list(diagnostic)::in, list(diagnostic)::out)
                               is det.

lgra_4_1_colon_literal(Decl, !Errors) :-
    ( if
        Decl = ad_const(Const),
        Const ^ acn_form = acf_colon_literal(_)
    then
        Name = Const ^ acn_name ^ id_name,
        !:Errors = [with_hint(error_at(dv_const_colon_literal_retired,
            Const ^ acn_pos,
            "`const " ++ Name ++ ": <value>` is retired: `:` introduces a "
                ++ "type annotation and `=` introduces the value "
                ++ "([LGRA.4.1])"),
            "write `const " ++ Name ++ " = <value>`, or `const " ++ Name
                ++ ": <type> = <value>` to annotate it too") | !.Errors]
    else
        true
    ).

    % A `{path}` in a `const` value's string is inert ([LGRA.2.9.6.8]).
    %
    %@helper
:- pred const_inert_strings(ast_decl::in,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

const_inert_strings(Decl, !Errors) :-
    ( if
        Decl = ad_const(Const),
        ( Const ^ acn_form = acf_value(_, Value)
        ; Const ^ acn_form = acf_colon_literal(Value)
        )
    then
        list.foldl(inert_string, inert_strings(Value), !Errors)
    else
        true
    ).

    %@spec [LOPQ.10.1]
:- pred lopq_10_1_representation(ast_decl::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
    is det.

lopq_10_1_representation(Decl, !Errors) :-
    ( if
        Decl = ad_opaque(Opaque),
        Repr = Opaque ^ aop_repr ^ id_name,
        Repr \= "Bytes"
    then
        !:Errors = [with_hint(error_at(dv_opaque_unsupported_repr,
            Opaque ^ aop_repr ^ id_pos,
            "`opaque type " ++ Opaque ^ aop_name ^ id_name ++ " over " ++ Repr
                ++ "`: `Bytes` is the only admitted representation "
                ++ "([LOPQ.10.1])"),
            "declare it `over Bytes`") | !.Errors]
    else
        true
    ).

    % Every `json()` call in a rule, a `const` value or a service kwarg's `default`.
    % Not a `test` block's value: a test scenario has a wire form for one
    % (`tv_json`).
    %
    %@spec [LGRA.9.8.3]
:- pred lgra_9_8_3_json_refused(ast_decl::in,
                                list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_9_8_3_json_refused(Decl, !Errors) :-
    ( if Decl = ad_rule(Rule) then
        Exprs = rule_expressions(Rule)
    else if
        Decl = ad_const(Const),
        ( Const ^ acn_form = acf_value(_, Value)
        ; Const ^ acn_form = acf_colon_literal(Value)
        )
    then
        Exprs = [Value]
    else if Decl = ad_service(Service) then
        Exprs = list.condense(list.map(kwarg_defaults,
            Service ^ asv_kwargs))
    else
        Exprs = []
    ),
    list.foldl(json_calls, Exprs, !Errors).

    %@helper
:- func kwarg_defaults(ast_service_kwarg) = list(lgra_9_3_1_expr).

kwarg_defaults(Kwarg) =
    list.filter_map(
        ( func(M) = E is semidet :- M = akm_default(E, _) ),
        Kwarg ^ ask_modifiers).

    %@helper
:- pred json_calls(lgra_9_3_1_expr::in,
                   list(diagnostic)::in, list(diagnostic)::out) is det.

json_calls(E, !Errors) :-
    ( if
        E = ex_call(ex_name(Callee), _, Pos),
        Callee ^ id_name = "json"
    then
        !:Errors = [with_hint(error_at(dv_json_literal_refused, Pos,
            "`json(...)` is not admitted in this edition of DS: the artefact "
                ++ "has no form for a `Json` literal ([LGRA.9.8.3])"),
            "a `Json` value reaches a rule from a fact's `Json` slot or a "
                ++ "call's response") | !.Errors]
    else
        true
    ),
    list.foldl(json_calls, expr_children(E), !Errors).

%-----------------------------------------------------------------------------%
% Unit declarations -- [LUNI.4.3], [LUNI.4.5], [LUNI.4.6]
%-----------------------------------------------------------------------------%
%
% The checks that resolve names stand down for a file with a whole-library import.

    % The count alone: `dsc.typecheck` reads the two lines' directions.
    %
    %@spec [LUNI.4.5]
:- pred luni_4_5_formula_arity(ast_decl::in,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

luni_4_5_formula_arity(Decl, !Errors) :-
    ( if
        Decl = ad_unit(au_formula(Name, _, Lines, Pos)),
        list.length(Lines) \= 2
    then
        !:Errors = [with_hint(error_at(dv_unit_formula_pair_arity, Pos,
            "`unit formula " ++ Name ^ id_name ++ "` declares "
                ++ string.from_int(list.length(Lines)) ++ " formula lines; "
                ++ "a formula declares exactly two ([LUNI.4.5])"),
            "write one line converting each way") | !.Errors]
    else
        true
    ).

    %@spec [LUNI.4.3]
:- pred luni_4_3_unit_decls(resolved_file::in, list(ast_decl)::in,
                             list(diagnostic)::out) is det.

luni_4_3_unit_decls(RF, Decls, Errors) :-
    Opaque = ( if list.member(D, Decls), whole_library_import(D) then yes
        else no ),
    list.foldl(unit_decl_checks(RF, Opaque), Decls, [], RevErrors0),
    luni_4_3_body_missing(RF, Decls, RevErrors0, RevErrors),
    Errors = reverse(RevErrors).

    % [LUNI.4.3]: "The base unit of a dimension is the one its `unit dimension`
    % names as `base`, and of a `unit scalar` group ([LUNI.4.2]) the first
    % declared. ... A `unit_inline` with no `=` declares the base unit. The
    % compiler **must** refuse a `unit_inline` with no `=` that declares any
    % other unit, with `DS_VALIDATE_UNIT_BODY_MISSING`."
    %
    % ⚠ "FIRST DECLARED" IS IN RESOLUTION ORDER. Every library a file imports
    % resolves before the file, so a unit any import declares on a scalar group
    % comes before each unit this file declares on it, and this file's own come
    % in source order. `Seen` starts as the groups the imports give a unit to.
    %
    % ⚠ AN IMPORTED UNIT IS ONE `Decls` DOES NOT DECLARE, NOT ONE WITH A FILE.
    % A library is validated as it is written, and `dsc.imports.limp_1_5_tree`
    % has already given its own units its name, so `auy_file \= ""` would count
    % a library's own units as imported and refuse each scalar group's base.
    %
    % ⚠ ONLY A GROUP THIS FILE CAN SEE IS JUDGED. A unit whose dimension link
    % names no declaration in `rf_units` -- one a whole-library import provides,
    % which projects no names, or one declared nowhere, which
    % `dv_unit_unknown_dimension` refuses -- has no base to compare with, and
    % passes here.
    %
    %@spec [LUNI.4.3]
:- pred luni_4_3_body_missing(resolved_file::in, list(ast_decl)::in,
                              list(diagnostic)::in, list(diagnostic)::out)
    is det.

luni_4_3_body_missing(RF, Decls, !Errors) :-
    Own = set.list_to_set(list.filter_map(
        ( func(D) = Ref is semidet :-
            D = ad_unit(au_symbol(Symbol, _, _, _, _, _, File, _)),
            Ref = decl_ref(File, Symbol ^ id_name)
        ), Decls)),
    Imported = set.list_to_set(list.filter_map(
        ( func(U) = DimRef is semidet :-
            U = au_symbol(Symbol, _, _, _, _, _, File, DimRef),
            not set.member(decl_ref(File, Symbol ^ id_name), Own)
        ), RF ^ rf_units)),
    list.foldl2(body_missing_decl(RF), Decls, Imported, _, !Errors).

    %@helper
:- pred body_missing_decl(resolved_file::in, ast_decl::in,
                          set(decl_ref)::in, set(decl_ref)::out,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

body_missing_decl(RF, Decl, !Seen, !Errors) :-
    ( if
        Decl = ad_unit(au_symbol(Symbol, Dimension, Body, _, _, _, _, DimRef))
    then
        ( if
            Body = aub_base,
            luni_4_3_not_base(RF, !.Seen, DimRef, Symbol ^ id_name, Base)
        then
            !:Errors = [with_hint(error_at(dv_unit_body_missing,
                Symbol ^ id_pos,
                "`unit " ++ Symbol ^ id_name ++ ": " ++ Dimension ^ id_name
                    ++ "` has no `=`, and only the base unit omits it: "
                    ++ Base ++ " ([LUNI.4.3])"),
                "write its conversion to the base unit, `= x * <factor>`, or "
                    ++ "`= x` if it equals the base") | !.Errors]
        else
            true
        ),
        set.insert(DimRef, !Seen)
    else
        true
    ).

    % The unit `Name` is not the base of the group `DimRef` names, and what
    % the base is, said for a diagnostic. Fails where it is the base, and where
    % `DimRef` names no declaration in scope.
    %
    %@helper
:- pred luni_4_3_not_base(resolved_file::in, set(decl_ref)::in, decl_ref::in,
                          string::in, string::out) is semidet.

luni_4_3_not_base(RF, Seen, DimRef, Name, Base) :-
    DimRef = decl_ref(File, GroupName),
    list.find_first_match(
        ( pred(U::in) is semidet :-
            ( U = au_dimension(N, _, _, _, File)
            ; U = au_scalar(N, _, _, _, File)
            ),
            N ^ id_name = GroupName
        ), RF ^ rf_units, Group),
    (
        Group = au_dimension(_, _, BaseId, _, _),
        BaseId ^ id_name \= Name,
        Base = "`" ++ GroupName ++ "`'s base is `" ++ BaseId ^ id_name ++ "`"
    ;
        Group = au_scalar(_, _, _, _, _),
        set.member(DimRef, Seen),
        Base = "scalar group `" ++ GroupName
            ++ "`'s base is the first unit declared in it"
    ).

    %@helper
:- pred whole_library_import(ast_decl::in) is semidet.

whole_library_import(ad_import(Import)) :-
    Import ^ ai_form = aif_qualified(_, _).

    %@helper
:- pred unit_decl_checks(resolved_file::in, bool::in, ast_decl::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

unit_decl_checks(RF, Opaque, Decl, !Errors) :-
    ( if Decl = ad_unit(Unit) then
        (
            Unit = au_symbol(Symbol, Dimension, Body, _, _, _, _, _),
            ( if
                Opaque = no,
                not dimension_or_scalar(RF, Dimension ^ id_name)
            then
                !:Errors = [with_hint(error_at(dv_unit_unknown_dimension,
                    Dimension ^ id_pos,
                    "`unit " ++ Symbol ^ id_name ++ ": " ++ Dimension ^ id_name
                        ++ "`: `" ++ Dimension ^ id_name ++ "` is not a "
                        ++ "declared or imported unit dimension ([LUNI.4.3])"),
                    "declare `unit dimension " ++ Dimension ^ id_name
                        ++ " ...`, or import it") | !.Errors]
            else
                true
            ),
            luni_4_3_affine(Symbol, Body, !Errors),
            luni_4_3_tier2_body(Symbol, Body, !Errors)
        ;
            Unit = au_formula(Name, _, Lines, _),
            ( if Opaque = no then
                list.foldl(luni_4_5_formula_line(RF, Name), Lines, !Errors)
            else
                true
            ),
            list.foldl(lgra_9_8_11_formula_body(RF), Lines, !Errors)
        ;
            Unit = au_fx_pair(Name, From, To, Via, Selector, Num, Den, _),
            luni_4_6_fx_pair(RF, Opaque, Name, From, To, Via, Selector, Num,
                Den, !Errors)
        ;
            ( Unit = au_dimension(_, _, _, _, _)
            ; Unit = au_scalar(_, _, _, _, _)
            )
        )
    else
        true
    ).

    %@helper
:- pred dimension_or_scalar(resolved_file::in, string::in) is semidet.

dimension_or_scalar(RF, Name) :-
    map.search(RF ^ rf_types, Name, Entry),
    ( Entry = te_unit(uk_dimension, _)
    ; Entry = te_unit(uk_scalar, _)
    ).

    %@spec [LUNI.4.3]
:- pred luni_4_3_affine(ident::in, ast_unit_body::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

luni_4_3_affine(Symbol, Body, !Errors) :-
    ( if Body = aub_affine(Expr), affine_degree(Expr) < 0 then
        !:Errors = [with_hint(error_at(dv_unit_body_not_affine,
            Symbol ^ id_pos,
            "`unit " ++ Symbol ^ id_name ++ "`'s conversion is not affine in "
                ++ "`x`: it does not reduce to `a*x + b` ([LUNI.4.3])"),
            "a tier-1 body uses `x`, numbers, `+ - * /`, `**` and `math`'s "
                ++ "`pi` (`from math import pi`); a non-affine same-dimension "
                ++ "conversion is written as a tier-2 `to_base:` / "
                ++ "`from_base:` block") | !.Errors]
    else
        true
    ).

    %@spec [LUNI.4.3]
:- pred luni_4_3_tier2_body(ident::in, ast_unit_body::in,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

luni_4_3_tier2_body(Symbol, Body, !Errors) :-
    ( if Body = aub_tier2(To, From, _) then
        tier2_direction(Symbol, "to_base", To, !Errors),
        tier2_direction(Symbol, "from_base", From, !Errors)
    else
        true
    ).

    %@helper
:- pred tier2_direction(ident::in, string::in, lgra_9_3_1_expr::in,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

tier2_direction(Symbol, Direction, Expr, !Errors) :-
    ( if luni_4_3_tier2_outside(Expr, Outside) then
        ( if
            Outside = ex_call(ex_name(Fn), _, _),
            Fn ^ id_name = "log"
        then
            Hint = "the natural log is `ln`; `log` is the action verb"
        else
            Hint = "a tier-2 body uses `x`, numbers, `+ - * /`, `**`, `abs` "
                ++ "of one argument, and `math`'s `pi`, `sqrt`, `ln`, "
                ++ "`log10`, `log2` and `exp`, reached through the file's "
                ++ "import of `math`"
        ),
        !:Errors = [with_hint(error_at(dv_unit_tier2_bad_body,
            expr_start(Outside),
            "`unit " ++ Symbol ^ id_name ++ "`'s `" ++ Direction
                ++ ":` uses something outside the tier-2 vocabulary "
                ++ "([LUNI.4.3])"),
            Hint) | !.Errors]
    else
        true
    ).

    % The degree of `x` in a tier-1 body, or -1 where it is not affine.
    %
    %@helper
:- func affine_degree(lgra_9_3_1_expr) = int.

affine_degree(Expr) = Degree :-
    ( if Expr = ex_name(Id) then
        ( if Id ^ id_name = "x" then
            Degree = 1
        else if Id ^ id_name = "math.pi" then
            Degree = 0
        else
            Degree = -1
        )
    else if Expr = ex_unary(_, Inner, _) then
        Degree = affine_degree(Inner)
    else if Expr = ex_binary(Op, Left, Right, _) then
        L = affine_degree(Left),
        R = affine_degree(Right),
        ( if ( L < 0 ; R < 0 ) then
            Degree = -1
        else if ( Op = bo_add ; Op = bo_sub ) then
            Degree = int.max(L, R)
        else if Op = bo_mul then
            ( if L + R > 1 then Degree = -1 else Degree = L + R )
        else if Op = bo_div then
            ( if R = 0 then Degree = L else Degree = -1 )
        else if Op = bo_pow then
            ( if L = 0, R = 0 then Degree = 0 else Degree = -1 )
        else
            Degree = -1
        )
    else if
        list.member(Name, expr_names(Expr)),
        Name ^ id_name = "x"
    then
        Degree = -1
    else
        Degree = 0
    ).

    %@spec [LUNI.4.5]
:- pred luni_4_5_formula_line(resolved_file::in, ident::in,
                               ast_formula_line::in,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

luni_4_5_formula_line(RF, Formula, Line, !Errors) :-
    list.foldl(formula_symbol(RF, Formula),
        [Line ^ afl_param_type, Line ^ afl_return], !Errors).

    %@helper
:- pred formula_symbol(resolved_file::in, ident::in, ident::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

formula_symbol(RF, Formula, Symbol, !Errors) :-
    Name = Symbol ^ id_name,
    ( if
        ( map.search(RF ^ rf_types, Name, Entry),
          Entry = te_unit(uk_symbol(_), _)
        ; map.contains(RF ^ rf_unit_alias, Name)
        )
    then
        true
    else
        !:Errors = [with_hint(error_at(dv_unit_unknown_symbol, Symbol ^ id_pos,
            "`unit formula " ++ Formula ^ id_name ++ "`: `" ++ Name ++ "` is "
                ++ "not a declared or imported unit symbol ([LUNI.4.5])"),
            "a formula's parameter and return types are unit symbols, not "
                ++ "dimensions") | !.Errors]
    ).

    % A formula is inlined where it is called, so a body that reached itself would
    % not finish lowering.
    %
    %@spec [LGRA.9.8.11]
:- pred lgra_9_8_11_formula_body(resolved_file::in, ast_formula_line::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_9_8_11_formula_body(RF, Line, !Errors) :-
    lgra_9_8_11_body_calls(RF, Line ^ afl_name, Line ^ afl_body, !Errors).

    %@helper
:- pred lgra_9_8_11_body_calls(resolved_file::in, ident::in, lgra_9_3_1_expr::in,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_9_8_11_body_calls(RF, Function, E, !Errors) :-
    ( if
        E = ex_call(ex_name(Id), _, _),
        not lgra_22_7_builtin_fn(Id ^ id_name),
        lgra_9_8_11_formula_function(RF, Id ^ id_name, _)
    then
        !:Errors = [with_hint(error_at(dv_unknown_function, Id ^ id_pos,
            "`" ++ Function ^ id_name ++ "`'s body calls `" ++ Id ^ id_name
                ++ "`, a formula's function: every call in a formula's body is "
                ++ "to a built-in ([LGRA.9.8.11])"),
            "the builtins are: "
                ++ string.join_list(", ", admitted_builtin_names))
            | !.Errors]
    else
        true
    ),
    list.foldl(lgra_9_8_11_body_calls(RF, Function), expr_children(E), !Errors).

    %@spec [LUNI.4.6]
:- pred luni_4_6_fx_pair(resolved_file::in, bool::in, ident::in, ident::in,
                          ident::in, ident::in, lgra_9_3_1_expr::in, ident::in,
                          ident::in,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

luni_4_6_fx_pair(RF, Opaque, Name, From, To, Via, Selector, Num, Den,
        !Errors) :-
    Pair = "`unit fx_pair " ++ Name ^ id_name ++ "`",
    ( if Opaque = no then
        list.foldl(fx_dimension(RF, Pair), [From, To], !Errors)
    else
        true
    ),
    ( if
        map.search(RF ^ rf_types, Via ^ id_name, ViaEntry),
        ViaEntry = te_schema(Schema)
    then
        list.foldl(fx_field(Pair, Schema), [Num, Den], !Errors)
    else if Opaque = no then
        !:Errors = [with_hint(error_at(dv_fx_pair_unknown_schema, Via ^ id_pos,
            Pair ++ ": `via " ++ Via ^ id_name ++ "` names no declared schema "
                ++ "([LUNI.4.6])"),
            "declare the schema whose facts publish the rate") | !.Errors]
    else
        true
    ),
    ( if fx_selector(Selector) then
        true
    else
        !:Errors = [with_hint(error_at(dv_fx_pair_selector, Via ^ id_pos,
            Pair ++ ": the `where` selector is an equality match of slots "
                ++ "against strings, joined by `and` ([LUNI.4.6])"),
            "select the rate fact by `slot == \"value\"` terms only")
            | !.Errors]
    ).

    %@helper
:- pred fx_dimension(resolved_file::in, string::in, ident::in,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

fx_dimension(RF, Pair, Dimension, !Errors) :-
    ( if
        map.search(RF ^ rf_types, Dimension ^ id_name, Entry),
        Entry = te_unit(uk_dimension, _)
    then
        true
    else
        !:Errors = [with_hint(error_at(dv_fx_pair_unknown_dim,
            Dimension ^ id_pos,
            Pair ++ ": `" ++ Dimension ^ id_name ++ "` is not a declared "
                ++ "`unit dimension` ([LUNI.4.6])"),
            "declare `unit dimension " ++ Dimension ^ id_name ++ " ...`")
            | !.Errors]
    ).

    %@helper
:- pred fx_field(string::in, ast_schema::in, ident::in,
                 list(diagnostic)::in, list(diagnostic)::out) is det.

fx_field(Pair, Schema, Slot, !Errors) :-
    Name = Slot ^ id_name,
    ( if find_schema_field(Schema ^ as_fields, Name, Field) then
        ( if Field ^ af_type ^ id_name = "Int" then
            true
        else
            !:Errors = [with_hint(error_at(dv_fx_pair_field_not_int,
                Slot ^ id_pos,
                Pair ++ ": the rate slot `" ++ Name ++ "` is `"
                    ++ Field ^ af_type ^ id_name ++ "`, and a rate is an exact "
                    ++ "integer fraction ([LUNI.4.6])"),
                "declare `" ++ Name ++ ": Int`") | !.Errors]
        )
    else
        !:Errors = [with_hint(error_at(dv_fx_pair_unknown_field, Slot ^ id_pos,
            Pair ++ ": `" ++ Schema ^ as_name ^ id_name ++ "` has no slot `"
                ++ Name ++ "` ([LUNI.4.6])"),
            "name the two `Int` slots that carry the rate") | !.Errors]
    ).

    %@helper
:- pred find_schema_field(list(ast_field)::in, string::in, ast_field::out)
    is semidet.

find_schema_field([F | Fs], Name, Found) :-
    ( if F ^ af_name ^ id_name = Name then
        Found = F
    else
        find_schema_field(Fs, Name, Found)
    ).

    %@helper
:- pred fx_selector(lgra_9_3_1_expr::in) is semidet.

fx_selector(Expr) :-
    ( if Expr = ex_binary(bo_and, Left, Right, _) then
        fx_selector(Left),
        fx_selector(Right)
    else
        Expr = ex_compare(ex_name(_), [Step], _),
        Step ^ cs_op = co_eq,
        Step ^ cs_right = ex_string(_, _)
    ).

    % The annotation mismatch is checked only where the value is a literal.
    %
    %@spec [LGRA.4.1]
:- pred lgra_4_1_consts(resolved_file::in, list(ast_decl)::in,
                        list(diagnostic)::out) is det.

lgra_4_1_consts(RF, Decls, Errors) :-
    Consts = list.filter_map(const_of, Decls),
    list.foldl2(last_declared, Consts, 0, _, map.init, Last),
    const_checks(RF, Last, Consts, 0, [], RevErrors),
    Errors = reverse(RevErrors).

    %@helper
:- func const_of(ast_decl) = ast_const is semidet.

const_of(ad_const(C)) = C.

    % Each `const` name, with the index of the last `const` declaring it.
    %
    %@helper
:- pred last_declared(ast_const::in, int::in, int::out,
                      map(string, int)::in, map(string, int)::out) is det.

last_declared(Const, I, I + 1, !Last) :-
    map.set(const_name(Const), I, !Last).

    %@helper
:- pred const_checks(resolved_file::in, map(string, int)::in,
                     list(ast_const)::in, int::in,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

const_checks(_, _, [], _, !Errors).
const_checks(RF, Last, [Const | Later], I, !Errors) :-
    ( if Const ^ acn_form = acf_value(MaybeAnnotation, Expr) then
        list.foldl(const_forward(Last, I), expr_names(Expr), !Errors),
        list.foldl(const_runtime(Const), expr_runtime_reads(Expr), !Errors),
        list.foldl(ltim_14_3_const_raises(Const),
            ltim_14_3_raising_calls(RF, Expr), !Errors),
        (
            MaybeAnnotation = yes(Annotation),
            const_annotation(RF, Const, Annotation, Expr, !Errors)
        ;
            MaybeAnnotation = no
        )
    else
        true
    ),
    const_checks(RF, Last, Later, I + 1, !Errors).

    %@helper
:- func const_name(ast_const) = string.

const_name(C) = C ^ acn_name ^ id_name.

    %@helper
:- pred const_forward(map(string, int)::in, int::in, ident::in,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

const_forward(Last, I, Id, !Errors) :-
    Name = Id ^ id_name,
    ( if map.search(Last, Name, J), J >= I then
        !:Errors = [with_hint(error_at(dv_unknown_const, Id ^ id_pos,
            "`" ++ Name ++ "` is not a constant yet: a `const` reads only the "
                ++ "constants declared above it ([LGRA.13.3])"),
            "move `const " ++ Name ++ "` above the one that reads it")
            | !.Errors]
    else
        true
    ).

    %@helper
:- func expr_runtime_reads(lgra_9_3_1_expr) = list(pair(string, pos)).

expr_runtime_reads(Expr) = Reads :-
    ( if
        Expr = ex_call(ex_name(Callee), _, Pos),
        runtime_read_function(Callee ^ id_name)
    then
        Here = [("`" ++ Callee ^ id_name ++ "()`") - Pos]
    else if Expr = ex_match(_, _, _, _, Pos) then
        Here = [("a regex match") - Pos]
    else
        Here = []
    ),
    Reads = Here ++ list.condense(list.map(expr_runtime_reads,
        expr_children(Expr))).

    %@helper
:- pred runtime_read_function(string::in) is semidet.

runtime_read_function("now").
runtime_read_function("monotonic_ns").
runtime_read_function("cached").

    % Every `calendar` call in the expression whose arguments fold and whose fold
    % raises.
    %
    %@spec [LTIM.14.3]
:- func ltim_14_3_raising_calls(resolved_file, lgra_9_3_1_expr) = list(pos).

ltim_14_3_raising_calls(RF, Expr) = Positions :-
    ( if ltim_14_3_calendar_raises(RF, Expr) then
        Here = [expr_start(Expr)]
    else
        Here = []
    ),
    Positions = Here ++ list.condense(list.map(ltim_14_3_raising_calls(RF),
        expr_children(Expr))).

    %@helper
:- pred ltim_14_3_const_raises(ast_const::in, pos::in,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

ltim_14_3_const_raises(Const, Pos, !Errors) :-
    !:Errors = [with_hint(error_at(dv_const_not_foldable, Pos,
        "`const " ++ const_name(Const) ++ "`'s `calendar` call names no "
            ++ "value: a field is out of its range, or the value is out of "
            ++ "its type's range, so it has nothing to fold to ([LTIM.14.3], "
            ++ "[LTIM.14.2])"),
        "correct the fields; a call outside a `const` raises when the rule "
            ++ "runs instead") | !.Errors].

    %@helper
:- pred const_runtime(ast_const::in, pair(string, pos)::in,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

const_runtime(Const, What - Pos, !Errors) :-
    !:Errors = [with_hint(error_at(dv_const_not_foldable, Pos,
        "`const " ++ const_name(Const) ++ "` reads " ++ What ++ ", which "
            ++ "needs a runtime value; a constant folds at compile time "
            ++ "([LGRA.13.3])"),
        "bind the runtime value with a `let` in the rule that needs it")
        | !.Errors].

    %@helper
:- pred const_annotation(resolved_file::in, ast_const::in, ast_annotation::in,
                         lgra_9_3_1_expr::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

const_annotation(RF, Const, Annotation, Expr, !Errors) :-
    TypeId = Annotation ^ aan_type,
    TypeName = TypeId ^ id_name,
    Name = const_name(Const),
    ( if const_field_type(TypeName) then
        ( if
            literal_kind(Expr, Kind),
            not literal_fits(TypeName, Kind)
        then
            !:Errors = [with_hint(error_at(dv_const_annotation_mismatch,
                TypeId ^ id_pos,
                "`const " ++ Name ++ ": " ++ TypeName ++ "` is given a `"
                    ++ Kind ++ "` literal ([LGRA.4.1])"),
                "a `const` annotation is checked against its value; change "
                    ++ "one of the two") | !.Errors]
        else
            true
        )
    else if
        map.search(RF ^ rf_types, TypeName, Entry),
        Entry = te_unit(UnitKind, _),
        UnitKind \= uk_dimension
    then
        true
    else
        !:Errors = [with_hint(error_at(dv_const_bad_annotation,
            TypeId ^ id_pos,
            "`const " ++ Name ++ ": " ++ TypeName ++ "`: `" ++ TypeName
                ++ "` is not a type a constant can have ([LGRA.4.1])"),
            "annotate a builtin scalar type or a canonical unit symbol")
            | !.Errors]
    ).

    %@helper
:- pred const_field_type(string::in) is semidet.

const_field_type("String").
const_field_type("Int").
const_field_type("Float").
const_field_type("Bool").
const_field_type("Json").
const_field_type("Bytes").
const_field_type("Time").
const_field_type("Date").
const_field_type("Duration").

    %@helper
:- pred literal_kind(lgra_9_3_1_expr::in, string::out) is semidet.

literal_kind(ex_string(_, _), "String").
literal_kind(ex_int(_, _), "Int").
literal_kind(ex_float(_, _), "Float").
literal_kind(ex_bool(_, _), "Bool").

    %@helper
:- pred literal_fits(string::in, string::in) is semidet.

literal_fits(Type, Kind) :-
    ( Type = Kind
    ; Type = "Float", Kind = "Int"
    ).

%-----------------------------------------------------------------------------%
% Reserved words are not names -- [LLEX.9.5]
%-----------------------------------------------------------------------------%
%
% One check and [LLEX.9.7]'s five codes. `dsc.resolve` refuses a builtin function
% name on a pattern or `let` binding, and a builtin type name on a schema, unit or
% opaque type, first. A compiler-injected schema is not checked.

    %@spec [LLEX.9.5]
    %@spec [LSER.6.6.1]
    %@spec [LGRA.4.4]
    %@spec [LLEX.9.7]
:- pred llex_9_5_reserved_words(ast_decl::in,
                                list(diagnostic)::in, list(diagnostic)::out)
                                is det.

llex_9_5_reserved_words(Decl, !Errors) :-
    ( if Decl = ad_schema(S), S ^ as_origin = compiler_injected then
        true
    else
        list.foldl(llex_9_5_name, decl_name_sites(Decl), !Errors)
    ).

    %@helper
:- type name_site
    --->    ns_slot
    ;       ns_binding
    ;       ns_schema
    ;       ns_rule
    ;       ns_const
    ;       ns_service_kwarg
    ;       ns_opaque.

    % Every name a declaration introduces, with the kind of site it is. `let` and
    % capture names are bindings.
    %
    %@helper
:- func decl_name_sites(ast_decl) = list(pair(name_site, ident)).

decl_name_sites(ad_schema(S)) =
    [ns_schema - S ^ as_name
        | list.map((func(F) = ns_slot - F ^ af_name), S ^ as_fields)].
decl_name_sites(ad_rule(R)) =
    [ns_rule - R ^ ar_name
        | list.map((func(I) = ns_binding - I),
            list.condense(list.map(clause_bindings, R ^ ar_lhs))
                ++ list.condense(list.map(bound_let_names,
                    rule_let_bindings(R))))].
decl_name_sites(ad_const(C)) = [ns_const - C ^ acn_name].
decl_name_sites(ad_opaque(O)) = [ns_opaque - O ^ aop_name].
decl_name_sites(ad_service(V)) =
    list.map((func(K) = ns_service_kwarg - K ^ ask_name), V ^ asv_kwargs).
decl_name_sites(ad_series(_)) = [].
decl_name_sites(ad_unit(_)) = [].
decl_name_sites(ad_test(_)) = [].
decl_name_sites(ad_initial(_)) = [].
decl_name_sites(ad_import(_)) = [].

    %@helper
:- func bound_let_names(ast_let_binding) = list(ident).

bound_let_names(alb_simple(Id, _, _, _)) = [Id].
bound_let_names(alb_capture(Ids, _, _)) = Ids.

    % The call/emit control-plane modifiers [LLEX.9.7] gives its own code.
    %
    %@helper
:- pred control_plane_modifier(string::in) is semidet.

control_plane_modifier("cooldown").
control_plane_modifier("retain").
control_plane_modifier("nocooldown").
control_plane_modifier("as").

    %@helper
:- func clause_bindings(ast_lhs_clause) = list(ident).

clause_bindings(alc_pattern(P)) = pattern_bindings(P).
clause_bindings(alc_then(S)) = step_binding(S).

    %@helper
:- func pattern_bindings(ast_pattern) = list(ident).

pattern_bindings(ap_simple(B)) = body_binding(B).
pattern_bindings(ap_negated(B, _)) = body_binding(B).
pattern_bindings(ap_sequence(_, Head, Steps, _)) =
    body_binding(Head)
        ++ list.condense(list.map(step_binding, Steps)).

    %@helper
:- func step_binding(ast_then_step) = list(ident).

step_binding(Step) = body_binding(Step ^ ats_body).

    %@helper
:- func body_binding(ast_pattern_body) = list(ident).

body_binding(Body) =
    ( if Body ^ apb_binding = yes(Id) then [Id] else [] ).

    %@helper
:- pred llex_9_5_name(pair(name_site, ident)::in,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

llex_9_5_name(Site - Id, !Errors) :-
    Word = Id ^ id_name,
    ( if corpus_still_names(Site, Word) then
        true
    else if control_plane_modifier(Word) then
        !:Errors = [with_hint(error_at(dv_reserved_meta_kwarg, Id ^ id_pos,
            "`" ++ Word ++ "` is an engine control-plane modifier and cannot "
                ++ "be a " ++ site_name(Site) ++ " name ([LLEX.9.5])"),
            "a call or emit site reads it as the modifier first, so a value "
                ++ "under this name would be silently dropped -- rename it")
            | !.Errors]
    else if llex_9_6_reserved_word(Word, By) then
        !:Errors = [reserved_row(Site, Id, By) | !.Errors]
    else if quantile_fn(Word) then
        ( if Site = ns_slot then
            !:Errors = [companion_collision(Id, "percentile") | !.Errors]
        else
            !:Errors = [keyword_name(Site, Id) | !.Errors]
        )
    else
        true
    ).

    %@helper
:- pred corpus_still_names(name_site::in, string::in) is semidet.

corpus_still_names(ns_slot, "response").
corpus_still_names(ns_service_kwarg, "field").

    %@helper
:- func reserved_row(name_site, ident, reserved_by) = diagnostic.

reserved_row(Site, Id, By) = D :-
    Word = Id ^ id_name,
    What = site_name(Site),
    ( if By = rb_type, ( Site = ns_schema ; Site = ns_opaque ) then
        Is = ( if Word = "Schema" then "is the kind `Schema`"
               else "is a builtin type name" ),
        D = with_hint(error_at(dv_reserved_type_name, Id ^ id_pos,
            "`" ++ Word ++ "` " ++ Is ++ " and cannot name "
                ++ ( if Site = ns_opaque then "an " else "a " ) ++ What
                ++ " ([LLEX.9.5], [LGRA.22.7])"),
            "choose a different " ++ What ++ " name")
    else if By = rb_builtin, ( Site = ns_binding ; Site = ns_const ) then
        D = with_hint(error_at(dv_reserved_builtin_name, Id ^ id_pos,
            "`" ++ Word ++ "` is a builtin function name and cannot be a "
                ++ What ++ " name: value-namespace resolution runs binding, "
                ++ "constant, builtin, so it would shadow the builtin "
                ++ "([LLEX.9.5], [LGRA.22.7])"),
            "choose a different " ++ What ++ " name")
    else if By = rb_aggregation, Site = ns_slot then
        D = companion_collision(Id, "aggregation")
    else if By = rb_alias, Site = ns_slot then
        D = companion_collision(Id, "companion alias")
    else
        D = keyword_name(Site, Id)
    ).

    %@helper
:- func companion_collision(ident, string) = diagnostic.

companion_collision(Id, Kind) =
    with_hint(error_at(dv_companion_slot_collision, Id ^ id_pos,
        "`" ++ Id ^ id_name ++ "` is a reserved " ++ Kind ++ " name: "
            ++ "`<binding>." ++ Id ^ id_name ++ "` reads the companion form, "
            ++ "so a slot under it would name two things ([LSER.6.6.1])"),
        "rename the slot; the reservation holds whether or not the schema "
            ++ "declares a series").

    %@helper
:- func keyword_name(name_site, ident) = diagnostic.

keyword_name(Site, Id) =
    with_hint(error_at(dv_hard_keyword_name, Id ^ id_pos,
        "`" ++ Id ^ id_name ++ "` is a reserved word and cannot be a "
            ++ site_name(Site) ++ " name ([LLEX.9.5])"),
        "rename it -- DS has no quoted-identifier form").

    %@helper
:- func site_name(name_site) = string.

site_name(ns_slot) = "slot".
site_name(ns_binding) = "binding".
site_name(ns_schema) = "schema".
site_name(ns_rule) = "rule".
site_name(ns_const) = "constant".
site_name(ns_service_kwarg) = "service kwarg".
site_name(ns_opaque) = "opaque type".

%-----------------------------------------------------------------------------%
% Slot names are unique within a schema -- [LGRA.13.4]
%-----------------------------------------------------------------------------%

    %@spec [LGRA.13.4]
:- pred lgra_13_4_slot_names(ast_schema::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_13_4_slot_names(Schema, !Errors) :-
    list.foldl2(slot_name_once(Schema ^ as_name), Schema ^ as_fields,
        map.init, _, !Errors).

    %@helper
:- pred slot_name_once(ident::in, ast_field::in, map(string, pos)::in,
                       map(string, pos)::out,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

slot_name_once(SchemaName, Field, !Seen, !Errors) :-
    Name = Field ^ af_name ^ id_name,
    ( if map.search(!.Seen, Name, Prior) then
        !:Errors = [with_hint(error_with(dv_duplicate_slot,
            Field ^ af_name ^ id_pos,
            "schema `" ++ SchemaName ^ id_name ++ "` declares `" ++ Name
                ++ "` twice ([LGRA.13.4])",
            Prior, "first declared here"),
            "slot names are unique within a schema -- rename one, or delete "
                ++ "this line") | !.Errors]
    else
        map.det_insert(Name, Field ^ af_name ^ id_pos, !Seen)
    ).

    %@helper
:- func after_clauses(list(ast_after_clause)) = list(ast_after_clause).

after_clauses([]) = [].
after_clauses([A | As]) =
    [A | after_clauses(A ^ aaf_nested)] ++ after_clauses(As).

%-----------------------------------------------------------------------------%
% One rate modifier of each kind -- [LGRA.6.6.7]
%-----------------------------------------------------------------------------%

    % A rule carries at most one of each. `DS_PARSE_DUP_RATE_MOD` is a front-end code
    % raised here ([LCDB.7.8]).
    %
    %@spec [LGRA.6.6.7]
    %@spec [LCDB.7.8]
    %@spec [LCDB.5.2]
    %@spec [LCDB.5.3]
:- pred lgra_6_6_7_rate_mods(ast_decl::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_6_6_7_rate_mods(Decl, !Errors) :-
    ( if Decl = ad_rule(Rule) then
        list.foldl2(rate_mod_once, Rule ^ ar_modifiers, set.init, _, !Errors),
        list.foldl(lcdb_5_5_negative, Rule ^ ar_modifiers, !Errors)
    else
        true
    ).

    % A window written as a `time` const is judged by its folded value, the
    % value the lowering gives it, so `sliding Z` with `const Z = 0_s` is
    % refused. Zero is legal on a rate modifier ([LGRA.6.6.7]), hence the
    % separate code.
    %
    %@spec [LGRA.13.5]
:- pred lgra_13_5_series_windows(resolved_file::in, ast_decl::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_13_5_series_windows(RF, Decl, !Errors) :-
    ( if Decl = ad_series(S) then
        list.foldl(lgra_13_5_line(RF), S ^ asr_lines, !Errors)
    else
        true
    ).

%-----------------------------------------------------------------------------%
% A NAME in a `time_expr` -- [LGRA.2.8.11]
%-----------------------------------------------------------------------------%

    % Every `time_expr` position the declaration holds, judged here and nowhere
    % else: a schema's `ttl`, a pattern's and a `then` step's `within`, a rule's
    % `cooldown`, a call's `cooldown:` and `timeout`, and a series line's
    % `sliding` or `tumbling`. A position holding a `UNIT_LIT`, or a span the
    % parse or another check refuses, holds no NAME.
    %
    %@spec [LGRA.2.8.11]
:- pred lgra_2_8_11_time_expr_names(resolved_file::in, ast_decl::in,
                                    list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_2_8_11_time_expr_names(RF, Decl, !Errors) :-
    list.foldl(lgra_2_8_11_name(RF), decl_time_expr_names(Decl), !Errors).

    % A `Duration` const is read as the literal of its value ([LGRA.2.8.1]); any
    % other NAME is refused by what it names. A const whose own declaration is
    % refused types as nothing, and is that declaration's to report.
    %
    %@spec [LGRA.2.8.11]
:- pred lgra_2_8_11_name(resolved_file::in, ident::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_2_8_11_name(RF, Id, !Errors) :-
    Name = Id ^ id_name,
    Pos = Id ^ id_pos,
    ( if map.contains(RF ^ rf_consts, Name) then
        Scope = rule_scope(ident("const", Pos), map.init, map.init, map.init,
            map.init, map.init),
        Env = type_env(RF, Scope, da_reported, set.init),
        ( if
            type_of_expr(Env, ex_name(Id)) = ty_known(Known),
            Known ^ dt_leaf \= lk_duration
        then
            ( if Known ^ dt_dim = dim(_, _) then
                !:Errors = [with_hint(error_at(dv_bad_unit_dimension, Pos,
                    "`" ++ Name ++ "` is a quantity of another dimension, and a "
                        ++ "duration here is a `time` value ([LGRA.2.8.11])"),
                    "give the constant a time unit, like `30_s`")
                    | !.Errors]
            else
                !:Errors = [with_hint(error_at(dv_type_mismatch, Pos,
                    "`" ++ Name ++ "` is a constant of type `"
                        ++ leaf_name(Known ^ dt_leaf) ++ "`, and a duration "
                        ++ "here names a `Duration` constant ([LGRA.2.8.11])"),
                    "give the constant a time unit, like `30_s`")
                    | !.Errors]
            )
        else
            true
        )
    else
        !:Errors = [with_hint(error_at(dv_unknown_const, Pos,
            "`" ++ Name ++ "` names no constant, and a NAME in a duration "
                ++ "position names a `Duration` constant ([LGRA.2.8.11])"),
            "write a duration literal, like `30_s`, or declare `const "
                ++ Name ++ " = 30_s`")
            | !.Errors]
    ).

    %@helper
:- func decl_time_expr_names(ast_decl) = list(ident).

decl_time_expr_names(Decl) = Names :-
    ( if Decl = ad_schema(S), S ^ as_lifecycle = al_ttl(Span, _) then
        Names = span_name(Span)
    else if Decl = ad_series(Series) then
        Names = list.condense(list.map(line_time_name, Series ^ asr_lines))
    else if Decl = ad_rule(R) then
        Windows = list.condense(list.map(clause_windows, R ^ ar_lhs)),
        Names = list.condense(list.map(window_time_name, Windows))
            ++ list.condense(list.map(modifier_time_name, R ^ ar_modifiers))
            ++ list.condense(list.map(action_time_names, rule_actions(R)))
    else
        Names = []
    ).

    % A span is a `time_expr` NAME when it is one `NAME` token.
    %
    %@helper
:- func span_name(list(positioned)) = list(ident).

span_name(Span) =
    ( if Span = [Tok], Tok ^ tk_tok = name(Name) then
        [ident(Name, Tok ^ tk_pos)]
    else
        []
    ).

    %@helper
:- func window_time_name({window_site, list(positioned)}) = list(ident).

window_time_name({_, Span}) = span_name(Span).

    %@helper
:- func expr_time_name(lgra_9_3_1_expr) = list(ident).

expr_time_name(E) = ( if E = ex_name(Id) then [Id] else [] ).

    %@helper
:- func line_time_name(ast_series_line) = list(ident).

line_time_name(Line) = Names :-
    Time = Line ^ asl_time,
    ( if
        ( Time = atm_sliding(E, _)
        ; Time = atm_tumbling(E, _)
        )
    then
        Names = expr_time_name(E)
    else
        Names = []
    ).

    %@helper
:- func modifier_time_name(ast_rule_modifier) = list(ident).

modifier_time_name(arm_cooldown(Span, _)) = span_name(Span).
modifier_time_name(arm_by(_, _)) = [].

    % A call's `cooldown:` and the duration of each of its `timeout`s. The
    % calls nested in a continuation are `rule_actions`'s own.
    %
    %@helper
:- func action_time_names(ast_action) = list(ident).

action_time_names(Action) = Names :-
    ( if Action ^ aac_head = aah_call(_) then
        Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
        Cooldowns = list.condense(list.map(cooldown_time_name, Args)),
        ( if Action ^ aac_block = aab_call(_, Continuations) then
            Timeouts = list.condense(list.map(timeout_time_name,
                Continuations))
        else
            Timeouts = []
        ),
        Names = Cooldowns ++ Timeouts
    else
        Names = []
    ).

    %@helper
:- func cooldown_time_name(ast_action_arg) = list(ident).

cooldown_time_name(Arg) =
    ( if Arg = aaa_kwarg(Name, E, _), Name ^ id_name = "cooldown" then
        expr_time_name(E)
    else
        []
    ).

    %@helper
:- func timeout_time_name(ast_continuation) = list(ident).

timeout_time_name(Cont) =
    ( if Cont = acont_timeout(E, _, _) then expr_time_name(E) else [] ).

    %@helper
:- pred lgra_13_5_line(resolved_file::in, ast_series_line::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_13_5_line(RF, Line, !Errors) :-
    Time = Line ^ asl_time,
    ( if
        ( Time = atm_sliding(E, _), What = "a window duration"
        ; Time = atm_tumbling(E, _), What = "a window duration"
        ; Time = atm_sample(E, _), What = "a sample count"
        ),
        nonpositive_measure(RF, Time, E)
    then
        !:Errors = [with_hint(error_at(dv_series_nonpositive_window,
            expr_start(E),
            What ++ " in a series declaration must be positive, and this "
                ++ "one is zero or negative ([LGRA.13.5])"),
            "a window with nothing in it has no answer; give it a length")
            | !.Errors]
    else
        true
    ).

    %@helper
:- pred nonpositive_measure(resolved_file::in, ast_time_model::in,
                            lgra_9_3_1_expr::in) is semidet.

nonpositive_measure(RF, Time, E) :-
    ( if nonpositive_literal(E) then
        true
    else
        not Time = atm_sample(_, _),
        E = ex_name(_),
        lgra_2_8_1_time_value_ns(RF, E, Ns),
        Ns =< 0i64
    ).

    %@helper
:- pred nonpositive_literal(lgra_9_3_1_expr::in) is semidet.

nonpositive_literal(E) :-
    (
        E = ex_int(I, _),
        I =< 0i64
    ;
        E = ex_unit(Magnitude, _, _),
        zero_magnitude(Magnitude)
    ;
        E = ex_unary(uo_neg, Inner, _),
        ( Inner = ex_int(_, _)
        ; Inner = ex_unit(_, _, _)
        )
    ).

    %@helper
:- pred zero_magnitude(string::in) is semidet.

zero_magnitude(Text) :-
    Digits = list.filter(char.is_digit, string.to_char_list(Text)),
    Digits = [_ | _],
    list.all_true(( pred(C::in) is semidet :- C = '0' ), Digits).

    % The parser takes the modifier's span whole, so `cooldown -5_min` arrives with
    % its `-` as the span's first token.
    %
    %@spec [LCDB.5.5]
:- pred lcdb_5_5_negative(ast_rule_modifier::in,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

lcdb_5_5_negative(Modifier, !Errors) :-
    ( Modifier = arm_cooldown(Span, _)
    ; Modifier = arm_by(_, _), Span = []
    ),
    rate_mod_name(Modifier, Name, _),
    ( if Span = [First | _], First ^ tk_tok = minus then
        !:Errors = [with_hint(error_at(dv_rate_negative_duration,
            First ^ tk_pos,
            "`" ++ Name ++ "` takes a duration of zero or more, and this one "
                ++ "is negative ([LCDB.5.5])"),
            "`" ++ Name ++ " 0_s` is the degenerate no-op; a negative one does "
                ++ "not exist") | !.Errors]
    else
        true
    ).

    %@helper
:- pred rate_mod_once(ast_rule_modifier::in, set(string)::in, set(string)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

rate_mod_once(Modifier, !Seen, !Errors) :-
    rate_mod_name(Modifier, Name, Pos),
    ( if set.contains(!.Seen, Name) then
        !:Errors = [with_hint(front_error_at(parse_dup_rate_mod, Pos,
            "`" ++ Name ++ "` is given twice on this rule ([LGRA.6.6.7])"),
            "one `cooldown` and one `by:` at most; their order is free "
                ++ "([LGRA.6.6.2])") | !.Errors]
    else
        set.insert(Name, !Seen)
    ).

    % What the grammar of [LGRA.23.1] does not carry for one `service` declaration.
    %
    %@spec [LGRA.23.2]
:- pred lgra_23_2_service_residue(resolved_file::in, ast_decl::in,
                                  list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_23_2_service_residue(RF, Decl, !Errors) :-
    ( if Decl = ad_service(Service) then
        list.foldl(kwarg_modifiers_once, Service ^ asv_kwargs, !Errors),
        list.foldl(lgra_23_2_kwarg_type(RF), Service ^ asv_kwargs, !Errors),
        list.foldl(lgra_23_2_default_type(RF), Service ^ asv_kwargs, !Errors),
        list.foldl2(lgra_23_2_hydration_field_once, Service ^ asv_hydration,
            set.init, _, !Errors),
        lgra_23_2_response(RF, Service, !Errors)
    else
        true
    ).

    % `Schema` is tested by name: the kind is in no type map.
    %
    %@spec [LGRA.23.2]
:- pred lgra_23_2_response(resolved_file::in, ast_service_decl::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_23_2_response(RF, Service, !Errors) :-
    Name = dotted(Service ^ asv_name),
    Response = Service ^ asv_response,
    (
        Response = ar_absent,
        !:Errors = [with_hint(error_at(dv_service_no_response_decl,
            Service ^ asv_pos,
            "service `" ++ Name ++ "` does not declare its response; its "
                ++ "last line must be `response T` or `no response` "
                ++ "([LGRA.23.2])"),
            "write `response T` naming the `ttl` schema its responses are "
                ++ "facts of, or `no response` if it never answers")
            | !.Errors]
    ;
        Response = ar_none(_)
    ;
        Response = ar_schema(Id),
        Type = Id ^ id_name,
        ( if
            map.search(RF ^ rf_types, Type, Entry),
            Entry = te_schema(Schema)
        then
            lcrs_4_3_2_response_schema(Name, Id, Schema, !Errors)
        else if
            ( Type = "Schema"
            ; map.search(RF ^ rf_types, Type, _)
            )
        then
            !:Errors = [with_hint(error_at(dv_service_response_not_schema,
                Id ^ id_pos,
                "service `" ++ Name ++ "`: `response " ++ Type ++ "` names "
                    ++ "a type that is not a schema; a response is a fact "
                    ++ "([LGRA.23.2])"),
                "name a `ttl` schema declaring `corr: String`")
                | !.Errors]
        else
            !:Errors = [error_at(dv_unknown_type, Id ^ id_pos,
                "service `" ++ Name ++ "`: `response " ++ Type ++ "` names "
                    ++ "no type ([LGRA.22.7])")
                | !.Errors]
        )
    ).

    %@spec [LCRS.4.3.2]
:- pred lcrs_4_3_2_response_schema(string::in, ident::in, ast_schema::in,
                                   list(diagnostic)::in, list(diagnostic)::out)
    is det.

lcrs_4_3_2_response_schema(Service, Id, Schema, !Errors) :-
    Type = Id ^ id_name,
    ( if Schema ^ as_lifecycle = al_ttl(_, _) then
        true
    else
        !:Errors = [with_hint(error_with(dv_service_response_not_ttl,
            Id ^ id_pos,
            "service `" ++ Service ++ "`: response schema `" ++ Type
                ++ "` is not `ttl` ([LCRS.4.3.2])",
            Schema ^ as_pos, "`" ++ Type ++ "` declared here"),
            "every response is its own fact; declare `" ++ Type
                ++ "` with `ttl <duration>`")
            | !.Errors]
    ),
    ( if
        list.find_first_match(
            ( pred(F::in) is semidet :-
                F ^ af_name ^ id_name = "corr",
                F ^ af_type ^ id_name = "String",
                F ^ af_nullable = non_null
            ), Schema ^ as_fields, _)
    then
        true
    else
        !:Errors = [with_hint(error_with(dv_service_response_no_corr,
            Id ^ id_pos,
            "service `" ++ Service ++ "`: response schema `" ++ Type
                ++ "` does not declare `corr: String` ([LCRS.4.3.2])",
            Schema ^ as_pos, "`" ++ Type ++ "` declared here"),
            "add the slot `corr: String`; the compiler does not add it")
            | !.Errors]
    ).

    % A unit alias is in `rf_unit_alias`, not `rf_types`, and is not unknown.
    %
    %@spec [LGRA.23.2]
    %@spec [LGRA.5.7.1]
:- pred lgra_23_2_kwarg_type(resolved_file::in, ast_service_kwarg::in,
                             list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_23_2_kwarg_type(RF, Kwarg, !Errors) :-
    Id = Kwarg ^ ask_type,
    Type = Id ^ id_name,
    ( if
        Type \= "Schema",
        not map.contains(RF ^ rf_types, Type),
        not map.contains(RF ^ rf_unit_alias, Type)
    then
        !:Errors = [with_hint(error_at(dv_unknown_type, Id ^ id_pos,
            "kwarg `" ++ Kwarg ^ ask_name ^ id_name ++ ": " ++ Type
                ++ "`: unknown type `" ++ Type ++ "` ([LGRA.23.2], "
                ++ "[LGRA.5.7.1])"),
            "a kwarg's type is a builtin, a declared unit symbol, dimension "
                ++ "or scalar-group name, a schema, or the kind `Schema`")
            | !.Errors]
    else
        true
    ).

    %@helper
:- pred kwarg_modifiers_once(ast_service_kwarg::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

kwarg_modifiers_once(Kwarg, !Errors) :-
    list.foldl2(modifier_once(Kwarg ^ ask_name ^ id_name),
        Kwarg ^ ask_modifiers, set.init, _, !Errors).

    %@spec [LGRA.23.2]
:- pred lgra_23_2_hydration_field_once(ast_hydration_field::in,
                                       set(string)::in, set(string)::out,
                                       list(diagnostic)::in,
                                       list(diagnostic)::out) is det.

lgra_23_2_hydration_field_once(Field, !Seen, !Errors) :-
    hydration_field_kind(Field, Kind, Pos),
    ( if set.contains(!.Seen, Kind) then
        !:Errors = [with_hint(error_at(dv_service_duplicate_hydration_field,
            Pos, "`" ++ Kind ++ ":` is given twice in one `hydration:` block "
                ++ "([LGRA.23.2])"),
            "keep one `" ++ Kind ++ ":` line") | !.Errors]
    else
        set.insert(Kind, !Seen)
    ).

    %@helper
:- pred hydration_field_kind(ast_hydration_field::in, string::out, pos::out)
    is det.

hydration_field_kind(ahy_hydrates(_, P), "hydrates", P).
hydration_field_kind(ahy_max_window(_, P), "max_window", P).
hydration_field_kind(ahy_max_limit(_, P), "max_limit", P).
hydration_field_kind(ahy_filter_fields(_, P), "filter_fields", P).

    %@spec [LGRA.23.2]
:- pred lgra_23_2_default_type(resolved_file::in, ast_service_kwarg::in,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_23_2_default_type(RF, Kwarg, !Errors) :-
    Type = Kwarg ^ ask_type ^ id_name,
    ( if
        list.find_first_match(is_default_modifier, Kwarg ^ ask_modifiers, Mod),
        Mod = akm_default(E, Pos),
        map.search(RF ^ rf_types, Type, Entry),
        lgra_23_2_default_misfit(RF, Type, Entry, E, Why)
    then
        !:Errors = [with_hint(error_at(dv_service_kwarg_default_type, Pos,
            "kwarg `" ++ Kwarg ^ ask_name ^ id_name ++ ": " ++ Type
                ++ "`: " ++ Why ++ " ([LGRA.23.2])"),
            "a call that omits the kwarg receives the default "
                ++ "([LADP.8.5.1], [LADP.8.5.2])") | !.Errors]
    else
        true
    ).

    % Why a `default` does not fit a kwarg of the type `Entry` names. Fails
    % when it fits.
    %
    %@spec [LGRA.23.2]
:- pred lgra_23_2_default_misfit(resolved_file::in, string::in,
                                 type_entry::in, lgra_9_3_1_expr::in,
                                 string::out) is semidet.

lgra_23_2_default_misfit(RF, Type, Entry, E, Why) :-
    (
        Entry = te_builtin(_),
        ( if scalar_default_type(Type) then
            not default_literal_of(Type, E),
            not ( Type = "Float", default_literal_of("Int", E) ),
            Why = "its `default` is not a `" ++ Type ++ "` literal"
        else
            Why = "a `" ++ Type ++ "` kwarg takes no `default`; only an "
                ++ "`Int`, `Float`, `String` or `Bool` kwarg does"
        )
    ;
        Entry = te_schema(_),
        Why = "a schema-typed kwarg takes no `default`, because no literal "
            ++ "has a schema type"
    ;
        Entry = te_opaque(_),
        Why = "an opaque-typed kwarg takes no `default`, because no literal "
            ++ "has an opaque type ([LOPQ.3.3])"
    ;
        Entry = te_unit(uk_symbol(Dimension), _),
        quantity_misfit(RF, Dimension, yes(Type), E, Why)
    ;
        Entry = te_unit(uk_dimension, Declared),
        quantity_misfit(RF, Declared, no, E, Why)
    ;
        Entry = te_unit(uk_scalar, Declared),
        quantity_misfit(RF, Declared, no, E, Why)
    ).

    % Why a `default` is not a quantity of `Dimension` -- expressible in `Unit`
    % as a whole number where the dimension needs one. Fails when it is.
    %
    %@helper
:- pred quantity_misfit(resolved_file::in, decl_ref::in, maybe(string)::in,
                        lgra_9_3_1_expr::in, string::out) is semidet.

quantity_misfit(RF, Dimension, Unit, E, Why) :-
    ( if quantity_literal(E, _, _, Suffix) then
        ( if luni_3_1_7_unit_of(RF, Suffix, Given, _) then
            ( if Given \= Dimension then
                Why = "its `default` is a `" ++ Given ^ dr_name
                    ++ "` quantity, and the kwarg's dimension is `"
                    ++ Dimension ^ dr_name ++ "`"
            else
                Unit = yes(UnitName),
                ( if
                    quantity_base(RF, E, Base),
                    ladp_8_5_2_in_unit(RF, UnitName, Base, Value)
                then
                    whole_number_dimension(RF, Dimension),
                    not is_whole(Value),
                    Why = "its `default` is not a whole number of `"
                        ++ UnitName ++ "`, and a `" ++ Dimension ^ dr_name
                        ++ "` value is held as a whole number"
                else
                    Why = "its `default` cannot be expressed in `" ++ UnitName
                        ++ "`: a conversion is needed that is not a tier-1 "
                        ++ "linear body ([LUNI.4.3])"
                )
            )
        else
            Why = "its `default`'s unit `" ++ llex_12_5_symbol_of(Suffix)
                ++ "` is not a declared unit symbol"
        )
    else
        Why = "its `default` is not a quantity of `" ++ Dimension ^ dr_name
            ++ "`; write it with a unit"
    ).

    %@helper
:- pred is_default_modifier(ast_kwarg_modifier::in) is semidet.

is_default_modifier(akm_default(_, _)).

    %@helper
:- pred scalar_default_type(string::in) is semidet.

scalar_default_type("Int").
scalar_default_type("Float").
scalar_default_type("String").
scalar_default_type("Bool").

    % A literal of the scalar builtin `Type`, a number optionally negated.
    %
    %@helper
:- pred default_literal_of(string::in, lgra_9_3_1_expr::in) is semidet.

default_literal_of(Type, E) :-
    ( if E = ex_unary(uo_neg, Inner, _) then
        Literal = Inner
    else
        Literal = E
    ),
    (
        Type = "Int",
        Literal = ex_int(_, _)
    ;
        Type = "Float",
        Literal = ex_float(_, _)
    ;
        Type = "String",
        E = ex_string(_, _)
    ;
        Type = "Bool",
        E = ex_bool(_, _)
    ).

    %@helper
:- pred modifier_once(string::in, ast_kwarg_modifier::in,
                      set(string)::in, set(string)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

modifier_once(Name, Mod, !Seen, !Errors) :-
    Modifier = modifier_name(Mod),
    ( if set.contains(!.Seen, Modifier) then
        !:Errors = [front_error_at(parse_kwarg_modifier_duplicate,
            modifier_pos(Mod),
            "kwarg `" ++ Name ++ "`: `" ++ Modifier ++ "` is given twice")
            | !.Errors]
    else
        set.insert(Modifier, !Seen)
    ).

    %@helper
:- func modifier_name(ast_kwarg_modifier) = string.

modifier_name(akm_default(_, _)) = "default".
modifier_name(akm_literal(_)) = "literal".
modifier_name(akm_required(_)) = "required".

    %@helper
:- func modifier_pos(ast_kwarg_modifier) = pos.

modifier_pos(akm_default(_, P)) = P.
modifier_pos(akm_literal(P)) = P.
modifier_pos(akm_required(P)) = P.

    %@helper
:- pred rate_mod_name(ast_rule_modifier::in, string::out, pos::out) is det.

rate_mod_name(arm_cooldown(_, Pos), "cooldown", Pos).
rate_mod_name(arm_by(_, Pos), "by", Pos).

%-----------------------------------------------------------------------------%
% A slot named `ts` is a `Time` -- [LFAC.9.1]
%-----------------------------------------------------------------------------%

    %@spec [LFAC.9.1]
:- pred lfac_9_1_ts_time(ast_field::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

lfac_9_1_ts_time(Field, !Errors) :-
    ( if
        Field ^ af_name ^ id_name = "ts",
        not (
            Field ^ af_type ^ id_name = "Time",
            Field ^ af_nullable = non_null
        )
    then
        Written = Field ^ af_type ^ id_name
            ++ ( if Field ^ af_nullable = nullable then "?" else "" ),
        !:Errors = [with_hint(error_at(dv_ts_not_time, Field ^ af_type ^ id_pos,
            "slot `ts` is declared `" ++ Written ++ "`; a slot named `ts` is "
                ++ "a `Time`, and not nullable ([LFAC.9.1])"),
            "declare `ts: Time` -- the engine fills it on every fact "
                ++ "([LFAC.9.2]) -- or give the slot another name")
            | !.Errors]
    else
        true
    ).

    %@spec [LUNI.14.9]
:- pred luni_14_9_complex_slot(resolved_file::in, ast_field::in,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

luni_14_9_complex_slot(RF, Field, !Errors) :-
    Type = Field ^ af_type,
    ( if
        Type ^ id_name = "complex",
        not map.contains(RF ^ rf_types, "complex")
    then
        !:Errors = [with_hint(error_at(dv_complex_not_in_v1, Type ^ id_pos,
            "slot `" ++ Field ^ af_name ^ id_name ++ "` is typed `complex`, "
                ++ "and complex numbers are not in this edition of DS "
                ++ "([LUNI.14.9])"),
            "store the real and imaginary parts as two `Float` slots")
            | !.Errors]
    else
        true
    ).

    % `key` only: a `mutable` slot may be nullable.
    %
    %@spec [LNUL.8.10]
:- pred lnul_8_10_nullable_key(ast_field::in,
                               list(diagnostic)::in, list(diagnostic)::out)
                               is det.

lnul_8_10_nullable_key(Field, !Errors) :-
    ( if
        Field ^ af_nullable = nullable,
        list.member(Marker, Field ^ af_markers),
        Marker = am_key(_)
    then
        !:Errors = [with_hint(error_at(dv_nullable_key,
            Field ^ af_name ^ id_pos,
            "`" ++ Field ^ af_name ^ id_name ++ "` is a `key` slot and may "
                ++ "not be nullable ([LNUL.8.10])"),
            "identity needs total equality, and two null-keyed facts are "
                ++ "distinct identities that never coalesce -- drop the `?`, "
                ++ "or move the slot out of the key and mark it `mutable`")
            | !.Errors]
    else
        true
    ).

    %@spec [LGRA.5.10]
:- pred lgra_5_10_slot(resolved_file::in, ast_lifecycle::in, ast_field::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_5_10_slot(RF, Lifecycle, Field, !Errors) :-
    Markers = Field ^ af_markers,
    Name = Field ^ af_name ^ id_name,
    Pos = Field ^ af_pos,
    ( if Name = "ts" then
        % `ts` is the engine's slot: require-all does not reach it.
        list.foldl(lfac_9_1_ts_marked, Markers, !Errors)
    else if Lifecycle = al_logical(_) then
        ( if has_identity_marker(Markers) then
            true
        else
            D = with_hint(error_at(dv_identity_role_required, Pos,
                "slot `" ++ Name ++ "`: every slot of a `logical` schema must "
                    ++ "be marked `key` or `mutable` ([LGRA.5.10] / "
                    ++ "[LFAC.1.7.4])"),
                "`key` slots form the schema's identity key; `mutable` slots "
                    ++ "are payload"),
            !:Errors = [D | !.Errors]
        )
    else
        list.foldl(reject_identity_marker(Name), Markers, !Errors)
    ),
    lgra_5_9_4_tolerance(RF, Lifecycle, Field, !Errors),
    lstr_11_1_capacity(Field, !Errors).

%-----------------------------------------------------------------------------%
% Capacity -- [LSTR.11.1]
%-----------------------------------------------------------------------------%

    % `capacity N` on a slot: `String` only, and `N >= 1`. `dsc.lower` encodes an `N`
    % above a `uint32` as no capacity.
    %
    %@spec [LSTR.11.1]
:- pred lstr_11_1_capacity(ast_field::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lstr_11_1_capacity(Field, !Errors) :-
    ( if Field ^ af_capacity = yes(Lit) then
        Name = Field ^ af_name ^ id_name,
        Type = Field ^ af_type ^ id_name,
        Pos = Lit ^ tk_pos,
        ( if Type \= "String" then
            !:Errors = [with_hint(error_at(dv_capacity_bad_type, Pos,
                "slot `" ++ Name ++ "`: `capacity` bounds a `String` slot's "
                    ++ "length, and this slot is `" ++ Type ++ "` "
                    ++ "([LSTR.11.1])"),
                "drop the `capacity`") | !.Errors]
        else if Lit ^ tk_tok = int_lit(N), N < 1i64 then
            !:Errors = [error_at(dv_capacity_not_positive, Pos,
                "slot `" ++ Name ++ "`: `capacity " ++ int64_to_string(N)
                    ++ "` must be at least 1 ([LSTR.11.1])") | !.Errors]
        else
            true
        )
    else
        true
    ).

    %@spec [LFAC.9.1]
:- pred lfac_9_1_ts_marked(ast_marker::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lfac_9_1_ts_marked(Marker, !Errors) :-
    ( if identity_marker(Marker, Word) then
        !:Errors = [with_hint(error_at(dv_ts_marked, marker_pos(Marker),
            "slot `ts` is marked `" ++ Word ++ "`; `ts` is the engine's slot, "
                ++ "outside identity and the no-op test, and takes no marker "
                ++ "([LFAC.9.1])"),
            "drop the `" ++ Word ++ "` marker from `ts`; if the fact needs a "
                ++ "time in its identity, declare it as another `Time` slot")
            | !.Errors]
    else
        true
    ).

    %@helper
:- pred has_identity_marker(list(ast_marker)::in) is semidet.

has_identity_marker([M | Ms]) :-
    ( if identity_marker(M, _) then
        true
    else
        has_identity_marker(Ms)
    ).

    % Only two of the four markers are identity roles.
    %
    %@helper
:- pred identity_marker(ast_marker::in, string::out) is semidet.

identity_marker(am_key(_), "key").
identity_marker(am_mutable(_), "mutable").

    %@helper
:- pred reject_identity_marker(string::in, ast_marker::in,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

reject_identity_marker(Slot, Marker, !Errors) :-
    ( if identity_marker(Marker, Word) then
        D = error_at(dv_identity_role_non_logical, marker_pos(Marker),
            "slot `" ++ Slot ++ "`: the `" ++ Word ++ "` identity marker is "
                ++ "legal only on a `logical` base ([LGRA.5.10]); other "
                ++ "lifecycles carry no identity key ([LFAC.1.7.6])"),
        !:Errors = [D | !.Errors]
    else
        true
    ).

    %@helper
:- func marker_pos(ast_marker) = pos.

marker_pos(am_key(P)) = P.
marker_pos(am_mutable(P)) = P.
marker_pos(am_sampled(P)) = P.
marker_pos(am_retained(P)) = P.

%-----------------------------------------------------------------------------%
% Tolerance -- [LGRA.5.9]
%-----------------------------------------------------------------------------%
%
% One slot yields at most one tolerance diagnostic. [LGRA.5.9.7]'s non-negative
% literal is the grammar's: no signed literal token exists.

    %@spec [LGRA.5.9.4]
    %@spec [LGRA.5.9.5]
    %@spec [LGRA.5.9.6]
    %@spec [LGRA.5.9.10]
:- pred lgra_5_9_4_tolerance(resolved_file::in, ast_lifecycle::in,
                           ast_field::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_5_9_4_tolerance(RF, Lifecycle, Field, !Errors) :-
    ( if
        Field ^ af_tolerance = yes(Lit),
        D = tolerance_refusal(RF, Lifecycle, Field, Lit)
    then
        !:Errors = [D | !.Errors]
    else
        true
    ).

    %@helper
:- func tolerance_refusal(resolved_file, ast_lifecycle, ast_field, positioned)
    = diagnostic.
    %@helper
:- mode tolerance_refusal(in, in, in, in) = out is semidet.

tolerance_refusal(RF, Lifecycle, Field, Lit) = D :-
        Name = Field ^ af_name ^ id_name,
        Pos = Lit ^ tk_pos,
        ( if lgra_5_9_10_on_key(Field) then
            D = with_hint(error_at(dv_tolerance_on_key, Pos,
                "slot `" ++ Name ++ "`: `tolerance` is admissible only on a "
                    ++ "`mutable` slot ([LGRA.5.9.10]); identity is exact"),
                "drop the tolerance, or make the slot `mutable`")
        else if Lifecycle = al_ttl(_, _) then
            D = error_at(dv_tolerance_ttl_schema, Pos,
                "slot `" ++ Name ++ "`: `tolerance` is legal on `logical` "
                    ++ "schemas only; a `ttl` fact does not dedup, so there "
                    ++ "is no reassertion to suppress ([LGRA.5.9.5])")
        else if not Lifecycle = al_logical(_) then
            D = error_at(dv_tolerance_non_logical, Pos,
                "slot `" ++ Name ++ "`: `tolerance` is legal on `logical` "
                    ++ "schemas only ([LGRA.5.9.5])")
        else if not lgra_5_9_4_typed(RF, Field) then
            D = with_hint(error_at(dv_tolerance_bad_type, Pos,
                "slot `" ++ Name ++ "`: `tolerance` is legal on `Float`, "
                    ++ "`Int`, and a slot typed by a base or tier-1 unit "
                    ++ "only ([LGRA.5.9.4])"),
                "a tier-2 unit has no scale to convert a difference by, and "
                    ++ "a dimension names no unit to read it in ([LUNI.7.4])")
        else if not lgra_5_9_6_literal_matches(RF, Field, Lit ^ tk_tok) then
            D = with_hint(error_at(dv_tolerance_literal_type, Pos,
                "slot `" ++ Name ++ "`: the tolerance literal's type must "
                    ++ "match the slot's ([LGRA.5.9.6])"),
                "`tolerance 0` is universally legal as explicit "
                    ++ "exact-equality ([LGRA.5.9.8])")
        else
            fail
        ).

    %@spec [LGRA.5.9.10]
:- pred lgra_5_9_10_on_key(ast_field::in) is semidet.

lgra_5_9_10_on_key(Field) :-
    has_key_marker(Field ^ af_markers).

    %@helper
:- pred has_key_marker(list(ast_marker)::in) is semidet.

has_key_marker([M | Ms]) :-
    ( if M = am_key(_) then
        true
    else
        has_key_marker(Ms)
    ).

    % `Float`, `Int`, or a base or tier-1 unit symbol, which
    % `dsc.lower.tolerance_of` converts ([LUNI.7.4]).
    %
    %@spec [LGRA.5.9.4]
:- pred lgra_5_9_4_typed(resolved_file::in, ast_field::in) is semidet.

lgra_5_9_4_typed(RF, Field) :-
    ( Field ^ af_type ^ id_name = "Float"
    ; Field ^ af_type ^ id_name = "Int"
    ; slot_entry(RF, Field, Entry),
      Entry = te_unit(uk_symbol(_), Unit),
      lgra_5_9_4_scaled_unit(RF, Unit)
    ).

    %@spec [LGRA.5.9.6]
    %@spec [LGRA.5.9.8]
:- pred lgra_5_9_6_literal_matches(resolved_file::in, ast_field::in, token::in) is semidet.

lgra_5_9_6_literal_matches(RF, Field, Tok) :-
    TypeName = Field ^ af_type ^ id_name,
    ( if TypeName = "Int" then
        Tok = int_lit(_)
    else if TypeName = "Float" then
        ( Tok = float_lit(_)
        ; Tok = int_lit(0i64)
        )
    else
        slot_entry(RF, Field, Entry),
        Entry = te_unit(uk_symbol(_), _),
        ( Tok = float_lit(_) ; Tok = int_lit(_) )
    ).

%-----------------------------------------------------------------------------%
% Action arguments -- [LGRA.10.3.2], [LEXP.7.3b]
%-----------------------------------------------------------------------------%

    %@spec [LGRA.10.3.2]
    %@spec [LEXP.7.3b]
:- pred lexp_7_3b_actions(resolved_file::in, list(diagnostic)::out) is det.

lexp_7_3b_actions(RF, Errors) :-
    % Rules and scopes correspond by position (`llet_12_4_rule_scopes`).
    Rules = list.filter_map(rule_of, RF ^ rf_ast ^ af_decls),
    Nested = list.map_corresponding(rule_errors(RF), Rules, RF ^ rf_scopes),
    Errors = list.condense(Nested).

    % A hydration target that declares `hydrated_corr` at a type other than `String`,
    % `String?` included. Imported schemas are checked too.
    %
    %@spec [LHYD.4.1.7]
:- func lhyd_4_1_7_declared_hydrated_corr(resolved_file) = list(diagnostic).

lhyd_4_1_7_declared_hydrated_corr(RF) = Errors :-
    Targets = rhim_2_2_hydration_targets(RF),
    Schemas = list.condense(list.map(snd, RF ^ rf_library_modules))
        ++ list.filter_map(schema_of, RF ^ rf_ast ^ af_decls),
    Errors = list.filter_map(wrong_hydrated_corr(Targets), Schemas).

    %@helper
:- func schema_of(ast_decl) = ast_schema is semidet.

schema_of(ad_schema(S)) = S.

    %@helper
:- func wrong_hydrated_corr(list(string), ast_schema) = diagnostic is semidet.

wrong_hydrated_corr(Targets, S) = D :-
    Name = S ^ as_name ^ id_name,
    list.member(S ^ as_own, Targets),
    list.find_first_match(
        ( pred(F::in) is semidet :- F ^ af_name ^ id_name = "hydrated_corr" ),
        S ^ as_fields, Field),
    not (
        Field ^ af_type ^ id_name = "String",
        Field ^ af_nullable = non_null
    ),
    Declared = Field ^ af_type ^ id_name
        ++ ( if Field ^ af_nullable = nullable then "?" else "" ),
    D = with_hint(error_at(dv_type_mismatch, Field ^ af_type ^ id_pos,
        "schema `" ++ Name ++ "` carries hydrated facts, so its `hydrated_corr` "
            ++ "must be `String`; it is declared `" ++ Declared
            ++ "` ([LHYD.4.1.7])"),
        "declare `hydrated_corr: String`, or drop the slot -- the compiler "
            ++ "supplies it").

rhim_2_2_hydration_targets(RF) = Targets :-
    Rules = list.filter_map(rule_of, RF ^ rf_ast ^ af_decls),
    PerRule = list.map_corresponding(rule_hydration_targets(RF), Rules,
        RF ^ rf_scopes),
    Targets = list.sort_and_remove_dups(list.condense(PerRule)).

    %@helper
:- func rule_hydration_targets(resolved_file, ast_rule, rule_scope)
    = list(string).

rule_hydration_targets(RF, Rule, Scope) = Read :-
    Env = type_env(RF, Scope, da_reported, set.init),
    Read = list.condense(list.map(hydrated_corr_reads(Env),
        rule_expressions(Rule))).

    %@helper
:- func hydrated_corr_reads(type_env, lgra_9_3_1_expr) = list(string).

hydrated_corr_reads(Env, Expr) = Here ++ Below :-
    ( if
        Expr = ex_slot(Base, Field, _),
        Field ^ id_name = "hydrated_corr",
        type_of_expr(Env, Base) = ty_known(BaseType),
        BaseType ^ dt_leaf = lk_fact(SchemaName)
    then
        Here = [SchemaName]
    else
        Here = []
    ),
    Below = list.condense(list.map(hydrated_corr_reads(Env),
        expr_children(Expr))).

    %@helper
:- func rule_of(ast_decl) = ast_rule is semidet.

rule_of(ad_rule(R)) = R.

    %@helper
:- func rule_errors(resolved_file, ast_rule, rule_scope) = list(diagnostic).

rule_errors(RF, Rule, Scope) = Errors :-
    % The narrowed set starts empty: [LNUL.5.2] stops narrowing at the arrow.
    Env = type_env(RF, Scope, da_reported, set.init),
    lthe_4_8_followers(Rule ^ ar_lhs, pd_start, [], RevFollowers),
    list.foldl(lthe_4_5_sequence_ts(RF), Rule ^ ar_lhs, [], RevTs),
    Scoped = scoped_actions(Env, Rule),
    list.foldl(
        ( pred({E, A}::in, Es0::in, Es::out) is det :-
            action_strings(E, A, Es0, Es)
        ), Scoped, [], RevStrings),
    list.foldl(typed_expr(RF, Env), rule_predicates(Rule), [], RevPredicates),
    list.foldl(luni_8_4_let_binding(RF, Env), rule_let_bindings(Rule),
        [], RevLets),
    list.foldl(
        ( pred({E, A}::in, Es0::in, Es::out) is det :-
            lgra_10_3_2_action(RF, E, A, Es0, Es)
        ), Scoped, [], RevActions),
    SelfEnding = list.condense(list.map(llog_11_9_self_ending(RF),
        Rule ^ ar_rhs ^ arr_afters))
        ++ llog_11_9_emit_after_withdraw(RF, Scope, Rule)
        ++ llog_11_9_self_replacing(RF, Rule),
    list.foldl(lgra_10_3_5_duplicate_kwarg, rule_actions(Rule), [],
        RevDuplicateKwargs),
    list.foldl(lcrs_8_1_call_rate, rule_actions(Rule), [], RevRates0),
    list.foldl(lrst_1_3_legacy_as_colon, rule_actions(Rule), RevRates0,
        RevRates),
    list.foldl(lsco_4_5_9_withdraw_scope(Scope), rule_actions(Rule),
        [], RevWithdrawScope),
    lcyc_3_3_3_withdraw_emit(RF, Scope, Rule, WithdrawEmit0),
    withdrawn_binding_used(Rule, WithdrawnUsed),
    WithdrawEmit = WithdrawEmit0 ++ WithdrawnUsed,
    list.foldl(lgra_10_1_1_log_level, rule_actions(Rule), [], RevLevels),
    lcco_11_1_on_predicates(Env, Rule, [], RevResponseFields0),
    list.foldl(lcrs_17_2_no_response_continuation(RF), rule_actions(Rule),
        RevResponseFields0, RevResponseFields1),
    list.foldl(lgra_10_1_5_record_event, rule_actions(Rule),
        RevResponseFields1, RevResponseFields),
    list.foldl(ladp_8_2_3_service(RF), rule_actions(Rule), [], RevServices),
    llet_12_3_forward_refs(Rule, ForwardRefs),
    inert_interpolation(Rule, Inert),
    list.foldl(lgra_2_9_6_8_cached_key(Env), rule_expressions(Rule),
        [], RevCachedKeys),
    lgra_2_9_6_9_interp_unsupported(Scope, Rule, InterpUnsupported),
    list.foldl(
        ( pred({E, A}::in, Es0::in, Es::out) is det :-
            lrst_1_4_call_key(RF, E, A, Es0, Es)
        ), Scoped, [], RevCallKeys),
    list.foldl(lrst_1_4_after_key(RF, Env),
        after_clauses(Rule ^ ar_rhs ^ arr_afters), [], RevAfterKeys),
    lgra_8_6_unreferenced_bindings(Rule, Unreferenced),
    lgra_8_6_negated_binding_scope(Rule, NegatedScope),
    lexp_9_6_1_nonfact_where(Rule, NonFact0),
    ltim_2_6_2_clock_where(Env, Rule, Clock),
    lreg_7_2_rule_regex(Rule, Regex0),
    lreg_4_1_capture_order(Rule, CaptureOrder),
    Regex = Regex0 ++ CaptureOrder,
    NonFact = Clock ++ NonFact0,
    list.foldl(lexp_10_2_2_zero_divisor(Env), rule_expressions(Rule),
        [], RevZeroDivisors0),
    list.foldl(lexp_3_7_4_bit_field_range(Env), rule_expressions(Rule),
        RevZeroDivisors0, RevZeroDivisors),
    list.foldl(lcst_4_6_1_coercion_call(RF), rule_expressions(Rule),
        [], RevCoercions),
    list.foldl(llet_10_5_let_slot(Scope), rule_expressions(Rule),
        [], RevLetSlots),
    list.foldl(ltac_7_1_after_duration,
        after_clauses(Rule ^ ar_rhs ^ arr_afters), [], RevAfterDurations),
    list.foldl(
        ( pred({E, A}::in, Es0::in, Es::out) is det :-
            ldtl_3_2_retain(RF, E, A, Es0, Es)
        ), Scoped, [], RevRetains),
    list.foldl(lcco_11_2_unsatisfiable, rule_actions(Rule), [], RevUnsatisfiable),
    list.foldl(lthe_4_7_zero_within(RF), Rule ^ ar_lhs, [], RevZeroWithin),
    list.foldl(lgra_9_8_2_embedded_read, rule_let_bindings(Rule),
        [], RevEmbeddedReads),
    list.foldl(lecc_1_4_error_depth, rule_actions(Rule), [], RevErrorDepth),
    list.foldl(lecc_6_4_error_family, rule_actions(Rule), [], RevErrorFamily),
    lcco_10_2_chain_depth(Rule, ChainDepth),
    lcco_3_8_nested_continued_as(Rule, NestedAs),
    call_cooldown_inside_rule(Rule, CallCooldowns),
    lcdb_7_9_rule_wide_window(RF, Rule, RuleWide),
    lcdb_3_3_4_rate_key(RF, Rule, RateKey),
    lnls_3_3_anchors(RF, Rule, Anchors),
    list.foldl(lcst_4_5_1_redundant_cast(Env), rule_expressions(Rule),
        [], RevRedundantCasts),
    % Source order: a rule's LHS precedes its RHS.
    Errors = reverse(RevFollowers) ++ reverse(RevTs)
        ++ reverse(RevPredicates) ++ Regex
        ++ reverse(RevZeroDivisors) ++ reverse(RevCoercions)
        ++ reverse(RevLetSlots)
        ++ NonFact
        ++ Unreferenced ++ NegatedScope ++ ForwardRefs ++ Inert
        ++ reverse(RevCachedKeys)
        ++ reverse(RevLets)
        ++ reverse(RevStrings) ++ InterpUnsupported
        ++ reverse(RevDuplicateKwargs)
        ++ reverse(RevActions) ++ SelfEnding ++ reverse(RevRates)
        ++ reverse(RevLevels) ++ reverse(RevResponseFields)
        ++ reverse(RevServices) ++ reverse(RevCallKeys)
        ++ reverse(RevAfterKeys) ++ reverse(RevAfterDurations)
        ++ reverse(RevRetains) ++ reverse(RevUnsatisfiable)
        ++ reverse(RevZeroWithin)
        ++ reverse(RevEmbeddedReads)
        ++ reverse(RevErrorDepth) ++ reverse(RevErrorFamily)
        ++ ChainDepth ++ NestedAs ++ CallCooldowns
        ++ reverse(RevRedundantCasts)
        ++ reverse(RevWithdrawScope) ++ WithdrawEmit ++ RuleWide ++ RateKey
        ++ Anchors.

    % Every lifecycle but `logical` needs a `by:` when rate-limited. A path through a
    % negated binding names no binding: only a positive pattern binds a fact.
    %
    %@spec [LCDB.3.3.4]
:- pred lcdb_3_3_4_rate_key(resolved_file::in, ast_rule::in,
                            list(diagnostic)::out) is det.

lcdb_3_3_4_rate_key(RF, Rule, Errors) :-
    Mods = Rule ^ ar_modifiers,
    Bodies = list.condense(list.map(positive_bodies, Rule ^ ar_lhs)),
    ( if list.find_first_match(is_rate_key, Mods, arm_by(Key, _)) then
        (
            Key = ark_none,
            Errors = []
        ;
            Key = ark_paths(Paths),
            Errors = list.filter_map(lcdb_3_3_4_bad_path(RF, Bodies), Paths)
        )
    else if
        list.find_first_match(is_rate_window, Mods, _),
        list.find_first_match(binds_unkeyed(RF), Bodies, Unkeyed)
    then
        Name = Rule ^ ar_name,
        Errors = [with_hint(error_at(dv_rate_key_required, Name ^ id_pos,
            "rule `" ++ Name ^ id_name ++ "` is rate-limited and binds `"
                ++ type_ref_name(Unkeyed ^ apb_type) ++ "`, which has no "
                ++ "declared identity, so its activation key must be "
                ++ "declared ([LCDB.3.3.4])"),
            "add `by: <binding>.<slot>` naming what one activation is per, "
                ++ "or `by: none` for one window across all of them")]
    else
        Errors = []
    ).

    %@helper
:- pred is_rate_key(ast_rule_modifier::in) is semidet.

is_rate_key(arm_by(_, _)).

    %@helper
:- pred is_rate_window(ast_rule_modifier::in) is semidet.

is_rate_window(arm_cooldown(_, _)).

    %@helper
:- pred binds_unkeyed(resolved_file::in, ast_pattern_body::in) is semidet.

binds_unkeyed(RF, Body) :-
    lgra_22_4_schema_of(RF, Body ^ apb_type, Schema),
    Schema ^ as_lifecycle \= al_logical(_).

    %@helper
:- func type_ref_name(ast_type_ref) = string.

type_ref_name(atr_bare(Id)) = Id ^ id_name.
type_ref_name(atr_qualified(_, Id)) = Id ^ id_name.

    %@spec [LCDB.3.3.4]
:- func lcdb_3_3_4_bad_path(resolved_file, list(ast_pattern_body),
                            ast_key_path) = diagnostic is semidet.

lcdb_3_3_4_bad_path(RF, Bodies, Path) = Diagnostic :-
    B = Path ^ akp_binding,
    S = Path ^ akp_slot,
    Text = B ^ id_name ++ "." ++ S ^ id_name,
    ( if
        list.find_first_match(
            (pred(Body::in) is semidet :-
                Body ^ apb_binding = yes(Id), Id ^ id_name = B ^ id_name),
            Bodies, Bound)
    then
        lgra_22_4_schema_of(RF, Bound ^ apb_type, Schema),
        not list.find_first_match(
            (pred(F::in) is semidet :- F ^ af_name ^ id_name = S ^ id_name),
            Schema ^ as_fields, _),
        Diagnostic = with_hint(error_at(dv_rate_key_bad_path, S ^ id_pos,
            "`by: " ++ Text ++ "`: `" ++ type_ref_name(Bound ^ apb_type)
                ++ "` has no slot `"
                ++ S ^ id_name ++ "` ([LCDB.3.3.4])"),
            "name a slot the schema declares")
    else
        Diagnostic = with_hint(error_at(dv_rate_key_bad_path, B ^ id_pos,
            "`by: " ++ Text ++ "`: `" ++ B ^ id_name ++ "` is not a binding "
                ++ "of a positive pattern in this rule ([LCDB.3.3.4])"),
            "a key path starts at a pattern binding: `Hot h` binds `h`")
    ).

    % Fires when each positive pattern is a `logical` schema with no `key` slot or a
    % schema with no slot at all. Any other lifecycle is [LCDB.3.3.4]'s refusal.
    %
    %@spec [LCDB.7.9]
    %@spec [LCDB.3.3.3]
:- pred lcdb_7_9_rule_wide_window(resolved_file::in, ast_rule::in,
                                  list(diagnostic)::out) is det.

lcdb_7_9_rule_wide_window(RF, Rule, Warnings) :-
    ( if
        list.find_first_match(is_rate_window, Rule ^ ar_modifiers, _),
        not list.find_first_match(is_rate_key, Rule ^ ar_modifiers, _),
        list.all_true(contributes_no_key(RF),
            list.condense(list.map(positive_bodies, Rule ^ ar_lhs)))
    then
        Name = Rule ^ ar_name,
        Warnings = [with_hint(warning_at(dv_rule_wide_rate_window,
            Name ^ id_pos,
            "rule `" ++ Name ^ id_name ++ "` has an empty activation key, so "
                ++ "its `cooldown` is one window for every "
                ++ "activation ([LCDB.7.9])"),
            "declare a `key` slot on a matched `logical` schema to rate-limit "
                ++ "per entity")]
    else
        Warnings = []
    ).

    %@helper
:- func positive_bodies(ast_lhs_clause) = list(ast_pattern_body).

positive_bodies(alc_then(S)) = [S ^ ats_body].
positive_bodies(alc_pattern(ap_simple(B))) = [B].
positive_bodies(alc_pattern(ap_negated(_, _))) = [].
positive_bodies(alc_pattern(ap_sequence(_, Head, Steps, _))) =
    [Head | list.map((func(S) = S ^ ats_body), Steps)].

    % Under `linear_scan: false`, every pattern after the first is anchored to an
    % earlier one by a full-key equality. A singleton is pinned by construction. A
    % `no` pattern whose `where` references no earlier binding is an existence test
    % and needs no anchor.
    %
    %@spec [LNLS.3.3]
    %@spec [LNLS.3.3a]
    %@spec [LNLS.3.3b]
    %@spec [LNLS.3.3c]
    %@spec [LREG.4.8]
:- pred lnls_3_3_anchors(resolved_file::in, ast_rule::in,
                         list(diagnostic)::out) is det.

lnls_3_3_anchors(RF, Rule, Errors) :-
    Items = list.condense(list.map(anchor_items, Rule ^ ar_lhs)),
    ( if
        not enabled(RF ^ rf_program, cap_linear_scan),
        Items = [_, _ | _]
    then
        list.foldl2(anchor_body(RF), Items, anchor_walk([], [], [], 0, no), _,
            [], RevErrors),
        Errors = reverse(RevErrors)
    else
        Errors = []
    ).

    %@helper
:- func anchor_items(ast_lhs_clause) = list(pair(ast_pattern_body, bool)).

anchor_items(alc_then(S)) = [S ^ ats_body - no].
anchor_items(alc_pattern(ap_simple(B))) = [B - no].
anchor_items(alc_pattern(ap_negated(B, _))) = [B - yes].
anchor_items(alc_pattern(ap_sequence(_, Head, Steps, _))) =
    [Head - no | list.map((func(S) = S ^ ats_body - no), Steps)].

    % `aw_blind`: an earlier pattern's schema did not resolve, or was `ttl`, so a
    % later pattern is not refused for lacking an anchor.
:- type anchor_walk
    --->    anchor_walk(
                aw_earlier :: list(pair(string, ast_schema)),
                aw_names   :: list(string),
                aw_captures :: list(string),
                aw_seen    :: int,
                aw_blind   :: bool
            ).

    %@helper
:- pred anchor_body(resolved_file::in, pair(ast_pattern_body, bool)::in,
                    anchor_walk::in, anchor_walk::out,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

anchor_body(RF, Body - Negated, !Walk, !Errors) :-
    Pos = Body ^ apb_pos,
    First = ( if !.Walk ^ aw_seen = 0 then yes else no ),
    !Walk ^ aw_seen := !.Walk ^ aw_seen + 1,
    ( if
        Negated = yes,
        not references_any(Body ^ apb_where, !.Walk ^ aw_names),
        not references_any(Body ^ apb_where, !.Walk ^ aw_captures)
    then
        true
    else if
        lgra_22_4_schema_of(RF, Body ^ apb_type, Schema)
    then
        ( if Schema ^ as_lifecycle = al_ttl(_, _) then
            !:Errors = [with_hint(error_at(dv_nolinscan_join_anchor_b, Pos,
                "`" ++ Schema ^ as_name ^ id_name ++ "` is `ttl`, and under "
                    ++ "`+nolinscan` a rule of several patterns joins only "
                    ++ "`logical` schemas ([LNLS.3.3b])"),
                "`ttl` facts accumulate under one key, so nothing bounds the "
                    ++ "join; match it in a single-pattern rule") | !.Errors],
            ( if Negated = no then !Walk ^ aw_blind := yes else true )
        else if First = yes then
            true
        else
            Earlier = !.Walk ^ aw_earlier,
            % An unbound pattern is still paired with every earlier one: two
            % singletons need no equality.
            (
                Body ^ apb_binding = no,
                Pairs = list.map((func(Prior) = {pair.snd(Prior), []}),
                    Earlier)
            ;
                Body ^ apb_binding = yes(Id),
                Pairs = list.map(
                    (func(Prior) =
                        {pair.snd(Prior), key_equalities(Id ^ id_name,
                            pair.fst(Prior), Body ^ apb_where)}),
                    Earlier)
            ),
            ( if
                list.member({Other2, Eqs}, Pairs),
                anchored(Schema, Other2, Eqs)
            then
                true
            else if !.Walk ^ aw_blind = yes then
                true
            else if
                Body ^ apb_binding = yes(Self),
                lreg_4_8_capture_key_slot(Schema, Self ^ id_name,
                    !.Walk ^ aw_captures, Body ^ apb_where, Pairs, KeySlot)
            then
                !:Errors = [with_hint(error_at(dv_nolinscan_capture_join_key,
                    Pos,
                    "this pattern's `key` slot `" ++ KeySlot ++ "` is equated "
                        ++ "to a capture an earlier pattern bound, with no "
                        ++ "`key` slot equality anchoring it; under "
                        ++ "`linear_scan: false` a capture is not a join key "
                        ++ "until its fan-out is measured ([LREG.4.8])"),
                    "anchor this pattern on `key` slots of an earlier one "
                        ++ "(the capture may stay as a further constraint), "
                        ++ "or set `linear_scan: true`")
                    | !.Errors]
            else if
                list.find_first_map(nullable_anchor(Schema), Pairs,
                    {Other3, Slot})
            then
                Singleton = ( if schema_keys(Schema) = [] then Schema
                    else Other3 ),
                !:Errors = [with_hint(error_at(dv_nolinscan_join_anchor_c, Pos,
                    "this pattern's anchor rests on `" ++ Slot ++ "`, a "
                        ++ "nullable slot of the singleton `"
                        ++ Singleton ^ as_name ^ id_name ++ "`: under "
                        ++ "`+nolinscan` a singleton slot standing in for a "
                        ++ "`key` slot must be non-nullable, as a `key` slot "
                        ++ "is ([LNLS.3.3], [LNUL.8.10])"),
                    "drop the `?` from `" ++ Slot ++ "`") | !.Errors]
            else if list.member({_, Eqs2}, Pairs), Eqs2 = [_ | _] then
                !:Errors = [with_hint(error_at(dv_nolinscan_join_anchor_a, Pos,
                    "this pattern compares slots with an earlier one, but "
                        ++ "under `+nolinscan` the equalities must pin the "
                        ++ "whole declared `key` of both schemas, one per "
                        ++ "`key` slot ([LNLS.3.3a])"),
                    "equate every `key` slot of this schema with a `key` "
                        ++ "slot of the earlier one") | !.Errors]
            else
                !:Errors = [with_hint(error_at(dv_nolinscan_join_anchor_c, Pos,
                    "this pattern is not anchored to an earlier one: under "
                        ++ "`+nolinscan` every pattern after the first, "
                        ++ "negated or not, must pin its full declared `key` "
                        ++ "to an earlier pattern's ([LNLS.3.3], "
                        ++ "[LNLS.3.3c])"),
                    "add `where` equalities between the `key` slots of this "
                        ++ "pattern and an earlier one") | !.Errors]
            )
        ),
        ( if
            Negated = no,
            Body ^ apb_binding = yes(Named)
        then
            !Walk ^ aw_names := [Named ^ id_name | !.Walk ^ aw_names],
            ( if Schema ^ as_lifecycle = al_logical(_) then
                !Walk ^ aw_earlier := !.Walk ^ aw_earlier
                    ++ [Named ^ id_name - Schema]
            else
                true
            )
        else
            true
        )
    else
        ( if Negated = no then
            !Walk ^ aw_blind := yes,
            ( if Body ^ apb_binding = yes(Unseen) then
                !Walk ^ aw_names := [Unseen ^ id_name | !.Walk ^ aw_names]
            else
                true
            )
        else
            true
        )
    ),
    ( if Negated = no, Body ^ apb_capture = yes(Capture) then
        !Walk ^ aw_captures := list.map(id_text, Capture ^ acap_names)
            ++ !.Walk ^ aw_captures
    else
        true
    ).

    % The first `key` slot of `Schema` that a top-level conjunct of the `where` equates
    % to a capture an earlier pattern bound, when every other `key` slot is pinned to
    % an earlier pattern: the capture is what completes the anchor.
    %
    %@spec [LREG.4.8]
:- pred lreg_4_8_capture_key_slot(ast_schema::in, string::in,
    list(string)::in, maybe(lgra_9_3_1_expr)::in,
    list({ast_schema, list(pair(string, string))})::in, string::out)
    is semidet.

lreg_4_8_capture_key_slot(Schema, This, Captures, yes(Where), Pairs, Slot) :-
    Equated = list.filter_map(capture_equality(This, Captures),
        conjuncts(Where)),
    list.filter((pred(K::in) is semidet :- list.member(K, Equated)),
        schema_keys(Schema), Captured, Rest),
    Captured = [Slot | _],
    (
        Rest = []
    ;
        Rest = [_ | _],
        list.member({Other, Eqs}, Pairs),
        lreg_4_8_rest_pinned(Rest, Other, Eqs)
    ).

    %@helper
:- pred lreg_4_8_rest_pinned(list(string)::in, ast_schema::in,
                             list(pair(string, string))::in) is semidet.

lreg_4_8_rest_pinned(Rest, Other, Eqs) :-
    Other ^ as_lifecycle = al_logical(_),
    OtherKeys = schema_keys(Other),
    list.all_true(
        (pred(K::in) is semidet :-
            list.member(K - B, Eqs),
            ( OtherKeys = [] ; list.member(B, OtherKeys) )),
        Rest).

    %@helper
:- func capture_equality(string, list(string), lgra_9_3_1_expr) = string
    is semidet.

capture_equality(This, Captures, E) = Slot :-
    E = ex_compare(L, [lgra_9_3_2_compare_step(co_eq, R, _)], _),
    ( if
        L = ex_slot(ex_name(A), S, _), A ^ id_name = This,
        R = ex_name(C), list.member(C ^ id_name, Captures)
    then
        Slot = S ^ id_name
    else
        R = ex_slot(ex_name(A), S, _), A ^ id_name = This,
        L = ex_name(C), list.member(C ^ id_name, Captures),
        Slot = S ^ id_name
    ).

    %@helper
:- pred references_any(maybe(lgra_9_3_1_expr)::in, list(string)::in)
    is semidet.

references_any(yes(Where), Names) :-
    list.member(Id, expr_names(Where)),
    list.member(Id ^ id_name, Names).

    % The anchor between this pattern's schema and an earlier one's, given the
    % equalities as `(a, b)`. A singleton slot standing in for a key slot must be
    % non-nullable.
    %
    %@helper
:- pred anchored(ast_schema::in, ast_schema::in,
                 list(pair(string, string))::in) is semidet.

anchored(This, Other, Eqs) :-
    anchor_shape(This, Other, Eqs),
    not nullable_singleton_slot(This, Other, Eqs, _).

    %@helper
:- pred nullable_singleton_slot(ast_schema::in, ast_schema::in,
                                list(pair(string, string))::in, string::out)
    is nondet.

nullable_singleton_slot(This, Other, Eqs, Slot) :-
    ThisKeys = schema_keys(This),
    OtherKeys = schema_keys(Other),
    (
        ThisKeys = [],
        OtherKeys = [_ | _],
        list.member(Slot - K, Eqs),
        list.member(K, OtherKeys),
        nullable_field(This, Slot)
    ;
        ThisKeys = [_ | _],
        OtherKeys = [],
        list.member(K - Slot, Eqs),
        list.member(K, ThisKeys),
        nullable_field(Other, Slot)
    ).

    % The earlier pattern whose anchor rests on a nullable singleton slot, and the
    % least such slot, so the diagnostic is deterministic.
    %
    %@helper
:- pred nullable_anchor(ast_schema::in,
                        {ast_schema, list(pair(string, string))}::in,
                        {ast_schema, string}::out) is semidet.

nullable_anchor(Schema, {Other, Eqs}, {Other, Slot}) :-
    anchor_shape(Schema, Other, Eqs),
    solutions(nullable_singleton_slot(Schema, Other, Eqs), [Slot | _]).

    %@helper
:- pred nullable_field(ast_schema::in, string::in) is semidet.

nullable_field(Schema, Name) :-
    list.find_first_match(
        (pred(F::in) is semidet :- F ^ af_name ^ id_name = Name),
        Schema ^ as_fields, Field),
    Field ^ af_nullable = nullable.

    %@helper
:- pred anchor_shape(ast_schema::in, ast_schema::in,
                     list(pair(string, string))::in) is semidet.

anchor_shape(This, Other, Eqs) :-
    This ^ as_lifecycle = al_logical(_),
    Other ^ as_lifecycle = al_logical(_),
    ThisKeys = schema_keys(This),
    OtherKeys = schema_keys(Other),
    (
        ThisKeys = [],
        OtherKeys = []
    ;
        ThisKeys = [],
        OtherKeys = [_ | _],
        list.all_true(
            (pred(K::in) is semidet :- list.member(_ - K, Eqs)), OtherKeys)
    ;
        ThisKeys = [_ | _],
        OtherKeys = [],
        list.all_true(
            (pred(K::in) is semidet :- list.member(K - _, Eqs)), ThisKeys)
    ;
        ThisKeys = [_ | _],
        OtherKeys = [_ | _],
        full_key_anchor(This, Other, Eqs)
    ).

    %@helper
:- func key_equalities(string, string, maybe(lgra_9_3_1_expr))
    = list(pair(string, string)).

key_equalities(_, _, no) = [].
key_equalities(This, Other, yes(Where)) =
    list.filter_map(slot_equality(This, Other), conjuncts(Where)).

    %@helper
:- func slot_equality(string, string, lgra_9_3_1_expr) = pair(string, string)
    is semidet.

slot_equality(This, Other, E) = Pair :-
    E = ex_compare(ex_slot(ex_name(A), SA, _),
        [lgra_9_3_2_compare_step(co_eq, ex_slot(ex_name(B), SB, _), _)], _),
    ( if A ^ id_name = This, B ^ id_name = Other then
        Pair = SA ^ id_name - SB ^ id_name
    else
        A ^ id_name = Other,
        B ^ id_name = This,
        Pair = SB ^ id_name - SA ^ id_name
    ).

    %@helper
:- pred full_key_anchor(ast_schema::in, ast_schema::in,
                        list(pair(string, string))::in) is semidet.

full_key_anchor(This, Other, Eqs) :-
    This ^ as_lifecycle = al_logical(_),
    Other ^ as_lifecycle = al_logical(_),
    ThisKeys = schema_keys(This),
    OtherKeys = schema_keys(Other),
    ThisKeys = [_ | _],
    OtherKeys = [_ | _],
    KeyEqs = list.filter(
        (pred(A - B::in) is semidet :-
            list.member(A, ThisKeys), list.member(B, OtherKeys)),
        Eqs),
    list.all_true(
        (pred(K::in) is semidet :- list.member(K - _, KeyEqs)), ThisKeys),
    list.all_true(
        (pred(K::in) is semidet :- list.member(_ - K, KeyEqs)), OtherKeys).

    %@helper
:- func schema_keys(ast_schema) = list(string).

schema_keys(S) = list.map((func(F) = F ^ af_name ^ id_name),
    list.filter(is_key_field, S ^ as_fields)).

    %@helper
:- pred is_key_field(ast_field::in) is semidet.

is_key_field(F) :-
    list.member(M, F ^ af_markers),
    M = am_key(_).

    %@helper
:- pred contributes_no_key(resolved_file::in, ast_pattern_body::in) is semidet.

contributes_no_key(RF, Body) :-
    lgra_22_4_schema_of(RF, Body ^ apb_type, Schema),
    (
        Schema ^ as_fields = []
    ;
        Schema ^ as_lifecycle = al_logical(_),
        not list.find_first_match(is_key_field, Schema ^ as_fields, _)
    ).

    %@spec [LCST.4.5.1]
:- pred lcst_4_5_1_redundant_cast(type_env::in, lgra_9_3_1_expr::in,
                                  list(diagnostic)::in, list(diagnostic)::out)
                                  is det.

lcst_4_5_1_redundant_cast(Env, E, !Errors) :-
    ( if
        E = ex_cast(Operand, Target, Written, Pos),
        lcst_4_5_1_identity_cast(Env, Operand, Target, Written)
    then
        !:Errors = [with_hint(warning_at(dv_cast_identity, Pos,
            "`::" ++ Target ^ id_name ++ "` is redundant: the value is already `"
                ++ Target ^ id_name ++ "` ([LCST.4.5.1])"),
            "drop the cast") | !.Errors]
    else
        true
    ),
    list.foldl(lcst_4_5_1_redundant_cast(Env), expr_children(E), !Errors).

%-----------------------------------------------------------------------------%
% `+nolinscan` -- [LNLS.3.1], [LNLS.3.6] to [LNLS.3.10]
%-----------------------------------------------------------------------------%
%
% Each refuses a construct whose cost grows with data rather than with a
% compile-time constant.

    % The String slots already reported for a missing bound ([LNLS.3.10]), and the
    % schemas already reported for a `Json` slot.
:- type lnls_seen
    --->    lnls_seen(
                ls_slots   :: set(pair(string, string)),
                ls_schemas :: set(string)
            ).

    %@spec [LNLS.3.1]
    %@spec [LNLS.3.6]
    %@spec [LNLS.3.7]
    %@spec [LNLS.3.8]
    %@spec [LNLS.3.9]
    %@spec [LNLS.3.10]
:- pred lnls_3_nolinscan(resolved_file::in, list(diagnostic)::out) is det.

lnls_3_nolinscan(RF, Errors) :-
    ( if not enabled(RF ^ rf_program, cap_linear_scan) then
        Decls = RF ^ rf_ast ^ af_decls,
        Declared = list.filter_map(author_schema, Decls),
        list.foldl2(lnls_3_1_declared, Declared,
            lnls_seen(set.init, set.init), Seen0, [], RevJson),
        Rules = list.filter_map(rule_of, Decls),
        Paired = list.map_corresponding((func(R, S) = R - S), Rules,
            RF ^ rf_scopes),
        list.foldl2(lnls_rule(RF), Paired, Seen0, _, [], RevRules),
        Errors = reverse(RevJson) ++ reverse(RevRules)
    else
        Errors = []
    ).

    %@helper
:- func author_schema(ast_decl) = ast_schema is semidet.

author_schema(ad_schema(S)) = S :-
    S ^ as_origin = author_declared.

    % A schema declared here is reported at its slot; one declared elsewhere, at the
    % first pattern that uses it (`lnls_body`).
    %
    %@helper
:- pred lnls_3_1_declared(ast_schema::in, lnls_seen::in, lnls_seen::out,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

lnls_3_1_declared(Schema, !Seen, !Errors) :-
    ( if list.find_first_match(json_field, Schema ^ as_fields, Field) then
        Name = Schema ^ as_name ^ id_name,
        !Seen ^ ls_schemas := set.insert(!.Seen ^ ls_schemas, Name),
        !:Errors = [json_slot_error(Name, Field ^ af_name ^ id_name,
            Field ^ af_type ^ id_pos) | !.Errors]
    else
        true
    ).

    %@helper
:- pred json_field(ast_field::in) is semidet.

json_field(F) :-
    F ^ af_type ^ id_name = "Json".

    %@helper
:- func json_slot_error(string, string, pos) = diagnostic.

json_slot_error(Schema, Slot, Pos) =
    with_hint(error_at(dv_nolinscan_json_slot, Pos,
        "`nolinscan`: schema `" ++ Schema ++ "` slot `" ++ Slot
            ++ "` has type `Json`, which requires unbounded allocation "
            ++ "([LNLS.3.1])"),
        "remove the slot or change its type").

    %@helper
:- pred lnls_rule(resolved_file::in, pair(ast_rule, rule_scope)::in,
                  lnls_seen::in, lnls_seen::out,
                  list(diagnostic)::in, list(diagnostic)::out) is det.

lnls_rule(RF, Rule - Scope, !Seen, !Errors) :-
    Env = type_env(RF, Scope, da_reported, set.init),
    Bodies = list.condense(list.map(lnls_bodies, Rule ^ ar_lhs)),
    list.foldl2(lnls_body(RF), Bodies, !Seen, !Errors),
    list.foldl2(lnls_expr(Env), rule_expressions(Rule), !Seen, !Errors).

    %@helper
:- func lnls_bodies(ast_lhs_clause) = list(ast_pattern_body).

lnls_bodies(alc_pattern(ap_simple(B))) = [B].
lnls_bodies(alc_pattern(ap_negated(B, _))) = [B].
lnls_bodies(alc_pattern(ap_sequence(_, Head, Steps, _))) =
    [Head | list.map((func(S) = S ^ ats_body), Steps)].
lnls_bodies(alc_then(Step)) = [Step ^ ats_body].

    % [LNLS.3.1] for a schema this file uses but did not declare.
    %
    %@helper
:- pred lnls_body(resolved_file::in, ast_pattern_body::in,
                  lnls_seen::in, lnls_seen::out,
                  list(diagnostic)::in, list(diagnostic)::out) is det.

lnls_body(RF, Body, !Seen, !Errors) :-
    ( if
        lgra_22_4_schema_of(RF, Body ^ apb_type, Schema)
    then
        Head = dsc.resolve.type_ref_name(Body ^ apb_type),
        Name = Schema ^ as_name ^ id_name,
        ( if
            Schema ^ as_origin = author_declared,
            not set.member(Name, !.Seen ^ ls_schemas),
            list.find_first_match(json_field, Schema ^ as_fields, Field)
        then
            !Seen ^ ls_schemas := set.insert(!.Seen ^ ls_schemas, Name),
            !:Errors = [json_slot_error(Name, Field ^ af_name ^ id_name,
                Head ^ id_pos) | !.Errors]
        else
            true
        )
    else
        true
    ).

    %@helper
:- pred lnls_expr(type_env::in, lgra_9_3_1_expr::in,
                  lnls_seen::in, lnls_seen::out,
                  list(diagnostic)::in, list(diagnostic)::out) is det.

lnls_expr(Env, E, !Seen, !Errors) :-
    ( if
        E = ex_match(Operand, _, _, _, Pos),
        string_slot(Env, Operand, _, Schema, Slot)
    then
        unbounded_string(Env, dv_nolinscan_unbounded_regex, "~", Schema, Slot,
            Pos, !Seen, !Errors),
        Children = expr_children(E)
    else if
        E = ex_compare(First, Steps, _)
    then
        lnls_compare(Env, First, Steps, !Seen, !Errors),
        Children = expr_children(E)
    else if
        json_traversal(Env, E, Pos, Rest)
    then
        % The outermost traversal of a path is reported and its base not walked.
        !:Errors = [with_hint(error_at(dv_nolinscan_json_path, Pos,
            "`nolinscan`: this traverses a `Json` value, which requires "
                ++ "unbounded allocation ([LNLS.3.9])"),
            "carry the value in a typed slot instead") | !.Errors],
        Children = Rest
    else
        Children = expr_children(E)
    ),
    list.foldl2(lnls_expr(Env), Children, !Seen, !Errors).

    % A read of a `String` slot of a fact binding: the binding, its schema and the
    % slot.
    %
    %@helper
:- pred string_slot(type_env::in, lgra_9_3_1_expr::in,
                    string::out, string::out, string::out) is semidet.

string_slot(Env, E, Binding, Schema, Slot) :-
    E = ex_slot(Base, Field, _),
    Base = ex_name(B),
    type_of_expr(Env, Base) = ty_known(BaseType),
    BaseType ^ dt_leaf = lk_fact(Schema),
    type_of_expr(Env, E) = ty_known(Type),
    Type ^ dt_leaf = lk_string,
    Binding = B ^ id_name,
    Slot = Field ^ id_name.

    % One diagnostic per slot, across [LNLS.3.7] and [LNLS.3.10].
    %
    %@helper
:- pred unbounded_string(type_env::in, ds_validate::in, string::in, string::in,
                         string::in, pos::in, lnls_seen::in, lnls_seen::out,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

unbounded_string(Env, Code, Op, Schema, Slot, Pos, !Seen, !Errors) :-
    Key = Schema - Slot,
    ( if set.member(Key, !.Seen ^ ls_slots) then
        true
    else if lstr_11_4_declares_capacity(Env, Schema, Slot) then
        true
    else
        !Seen ^ ls_slots := set.insert(!.Seen ^ ls_slots, Key),
        ( if Code = dv_nolinscan_unbounded_regex then
            Clause = "[LNLS.3.7]"
        else
            Clause = "[LNLS.3.10]"
        ),
        !:Errors = [with_hint(error_at(Code, Pos,
            "`nolinscan`: `" ++ Op ++ "` on slot `" ++ Slot ++ "` of `"
                ++ Schema ++ "` costs O(length) with no bound on the length ("
                ++ Clause ++ ")"),
            "declare the slot `" ++ Slot ++ ": String capacity <N>` "
                ++ "([LSTR.11.1]) to bound it") | !.Errors]
    ).

    %@spec [LSTR.11.4]
:- pred lstr_11_4_declares_capacity(type_env::in, string::in, string::in)
    is semidet.

lstr_11_4_declares_capacity(Env, Schema, Slot) :-
    map.search(Env ^ te_file ^ rf_types, Schema, te_schema(S)),
    list.find_first_match(
        (pred(F::in) is semidet :- F ^ af_name ^ id_name = Slot),
        S ^ as_fields, Field),
    Field ^ af_capacity = yes(_).

    % An ordering between two operands: [LNLS.3.8] when both are `String`
    % slots of DIFFERENT bindings, [LNLS.3.10] when a `String` slot is
    % ordered within one pattern. A chain is its adjacent pairs.
    %
    %@helper
:- pred lnls_compare(type_env::in, lgra_9_3_1_expr::in,
                     list(lgra_9_3_2_compare_step)::in,
                     lnls_seen::in, lnls_seen::out,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

lnls_compare(_, _, [], !Seen, !Errors).
lnls_compare(Env, Left, [Step | Steps], !Seen, !Errors) :-
    Op = Step ^ cs_op,
    Right = Step ^ cs_right,
    Pos = Step ^ cs_pos,
    ( if ordering_op(Op, Spelling) then
        ( if
            string_slot(Env, Left, LB, _, _),
            string_slot(Env, Right, RB, _, _),
            LB \= RB
        then
            !:Errors = [with_hint(error_at(dv_nolinscan_string_order, Pos,
                "`nolinscan`: `" ++ Spelling ++ "` orders `String` slots of "
                    ++ "`" ++ LB ++ "` and `" ++ RB ++ "`, a linear comparison "
                    ++ "that prevents join indexing ([LNLS.3.8])"),
                "use `==`, or a numeric slot for ordering") | !.Errors]
        else if string_slot(Env, Left, _, Schema, Slot) then
            unbounded_string(Env, dv_nolinscan_unbounded_string_op, Spelling,
                Schema, Slot, Pos, !Seen, !Errors)
        else if string_slot(Env, Right, _, Schema, Slot) then
            unbounded_string(Env, dv_nolinscan_unbounded_string_op, Spelling,
                Schema, Slot, Pos, !Seen, !Errors)
        else
            true
        )
    else
        true
    ),
    lnls_compare(Env, Right, Steps, !Seen, !Errors).

    %@helper
:- pred ordering_op(lgra_9_3_2_compare_op::in, string::out) is semidet.

ordering_op(co_lt, "<").
ordering_op(co_le, "<=").
ordering_op(co_gt, ">").
ordering_op(co_ge, ">=").

    % `<base>.key` or `<base>[...]` where the base is a `Json` value. `Rest` is the
    % subscript.
    %
    %@helper
:- pred json_traversal(type_env::in, lgra_9_3_1_expr::in, pos::out,
                       list(lgra_9_3_1_expr)::out) is semidet.

json_traversal(Env, E, Pos, Rest) :-
    ( if E = ex_slot(Base0, _, Pos0) then
        Base = Base0,
        Pos = Pos0,
        Rest = []
    else
        E = ex_index(Base, Index, Pos),
        Rest = [Index]
    ),
    type_of_expr(Env, Base) = ty_known(BaseType),
    BaseType ^ dt_leaf = lk_json.

%-----------------------------------------------------------------------------%
% Continuation shape -- [LECC.1.4], [LCCO.10.2]
%-----------------------------------------------------------------------------%

    %@spec [LECC.1.4]
:- pred lecc_1_4_error_depth(ast_action::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

lecc_1_4_error_depth(Action, !Errors) :-
    ( if Action ^ aac_block = aab_call(_, Continuations) then
        list.foldl(error_pattern_depth, Continuations, !Errors)
    else
        true
    ).

    %@helper
:- pred error_pattern_depth(ast_continuation::in,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

error_pattern_depth(Continuation, !Errors) :-
    ( if
        Continuation = acont_error(yes(Segments), _, Pos),
        list.length(Segments) > 4
    then
        !:Errors = [with_hint(error_at(dv_error_pattern_too_deep, Pos,
            "`error " ++ string.join_list(".", list.map(id_text, Segments))
                ++ ":` has " ++ string.from_int(list.length(Segments))
                ++ " segments, and a code has at most four ([LECC.1.4])"),
            "match the family or a shorter prefix, e.g. `adapter.throttled`")
            | !.Errors]
    else
        true
    ).

    %@spec [LECC.6.4]
:- pred lecc_6_4_error_family(ast_action::in,
                              list(diagnostic)::in, list(diagnostic)::out) is det.

lecc_6_4_error_family(Action, !Errors) :-
    ( if Action ^ aac_block = aab_call(_, Continuations) then
        list.foldl(error_pattern_family, Continuations, !Errors)
    else
        true
    ).

    %@helper
:- pred error_pattern_family(ast_continuation::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

error_pattern_family(Continuation, !Errors) :-
    ( if
        Continuation = acont_error(yes([First | Rest]), _, Pos),
        not lecc_2_2_family(id_text(First))
    then
        !:Errors = [with_hint(error_at(dv_error_pattern_unknown_family, Pos,
            "`error " ++ string.join_list(".",
                list.map(id_text, [First | Rest]))
                ++ ":` names the family `" ++ id_text(First)
                ++ "`, and the families are `request`, `internal` and "
                ++ "`adapter` ([LECC.2.2])"),
            "an adapter reports under `adapter`, e.g. `adapter.throttled`")
            | !.Errors]
    else
        true
    ).

    %@spec [LECC.2.2]
:- pred lecc_2_2_family(string::in) is semidet.

lecc_2_2_family("request").
lecc_2_2_family("internal").
lecc_2_2_family("adapter").

    % Depth counts a `call` that carries continuations. `dsc.rete`'s recursion relies
    % on this check.
    %
    %@spec [LCCO.10.2]
:- pred lcco_10_2_chain_depth(ast_rule::in, list(diagnostic)::out) is det.

lcco_10_2_chain_depth(Rule, Errors) :-
    Rhs = Rule ^ ar_rhs,
    Top = Rhs ^ arr_actions ++ list.condense(list.map(
        (func(A) = A ^ aaf_actions), after_clauses(Rhs ^ arr_afters))),
    list.foldl(chain_depth(0), Top, [], RevErrors),
    Errors = list.reverse(RevErrors).

    %@helper
:- pred chain_depth(int::in, ast_action::in,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

chain_depth(Depth, Action, !Errors) :-
    ( if
        Action ^ aac_block = aab_call(_, Continuations),
        Continuations = [_ | _]
    then
        Here = Depth + 1,
        ( if Here > 2, Action ^ aac_head = aah_call(Ref) then
            !:Errors = [with_hint(error_at(dv_continuation_chain_too_deep,
                Action ^ aac_pos,
                "`call " ++ service_text(Ref) ++ "` is a third level of "
                    ++ "continuation chaining; the cap is two ([LCCO.10.2])"),
                "split the chain into sibling rules that match on the "
                    ++ "correlation ([LCCO.10.4])") | !.Errors]
        else
            true
        ),
        list.foldl(chain_depth(Here),
            list.condense(list.map(continuation_body, Continuations)), !Errors)
    else
        true
    ).

    % `dsc.rete` relies on this check: it stops on a nested continued call with no
    % literal `as`.
    %
    %@spec [LCCO.3.8]
:- pred lcco_3_8_nested_continued_as(ast_rule::in, list(diagnostic)::out)
    is det.

lcco_3_8_nested_continued_as(Rule, Errors) :-
    Rhs = Rule ^ ar_rhs,
    list.foldl(nested_continued_as(no), Rhs ^ arr_actions, [], RevErrors0),
    list.foldl(nested_continued_as(yes),
        list.condense(list.map((func(A) = A ^ aaf_actions),
            after_clauses(Rhs ^ arr_afters))),
        RevErrors0, RevErrors),
    Errors = list.reverse(RevErrors).

    %@helper
:- pred nested_continued_as(bool::in, ast_action::in,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

nested_continued_as(Synthesized, Action, !Errors) :-
    ( if
        Action ^ aac_block = aab_call(_, Continuations),
        Continuations = [_ | _]
    then
        ( if
            Synthesized = yes,
            Action ^ aac_head = aah_call(Ref),
            not literal_as(Action)
        then
            !:Errors = [with_hint(error_at(dv_nested_continued_call_as,
                Action ^ aac_pos,
                "`call " ++ service_text(Ref) ++ "` carries a continuation "
                    ++ "inside an `after` or continuation body, so its "
                    ++ "correlation must be a string-literal `as` "
                    ++ "([LCCO.3.8])"),
                "add `as \"<key>\"` to the call, or move it into a rule of "
                    ++ "its own") | !.Errors]
        else
            true
        ),
        list.foldl(nested_continued_as(yes),
            list.condense(list.map(continuation_body, Continuations)), !Errors)
    else
        true
    ).

    %@helper
:- pred literal_as(ast_action::in) is semidet.

literal_as(Action) :-
    ( if Action ^ aac_as = yes(E0) then
        E = E0
    else
        hyd_kwarg(Action ^ aac_args ++ block_args(Action ^ aac_block), "as",
            E, _)
    ),
    E = ex_string(Text, _),
    literal_value(Text, _).

    % [RLOW.4.6.6.5]: a per-call `cooldown:` in a rule that carries a rule-level one.
    %
    %@helper
:- pred call_cooldown_inside_rule(ast_rule::in, list(diagnostic)::out) is det.

call_cooldown_inside_rule(Rule, Errors) :-
    ( if Rule ^ ar_modifiers = [_ | _] then
        Errors = list.filter_map(call_cooldown, rule_actions(Rule))
    else
        Errors = []
    ).

    %@helper
:- func call_cooldown(ast_action) = diagnostic is semidet.

call_cooldown(Action) = D :-
    Action ^ aac_head = aah_call(Ref),
    Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
    hyd_kwarg(Args, "cooldown", _, Pos),
    D = with_hint(error_at(dv_call_cool_inside_rule_cool, Pos,
        "`call " ++ service_text(Ref) ++ "` carries `cooldown:` inside a rule "
            ++ "that is already rate-limited; the two trackers overlap "
            ++ "([RLOW.4.6.6.5])"),
        "keep one: the rule's `cooldown` or the call's, "
            ++ "in a rule of its own").

%-----------------------------------------------------------------------------%
% `within` windows -- [LTHE.4.7]
%-----------------------------------------------------------------------------%

    % A `const` window is judged by its folded value.
    %
    %@spec [LTHE.4.7]
    %@spec [LTIM.2.7.1]
:- pred lthe_4_7_zero_within(resolved_file::in, ast_lhs_clause::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

lthe_4_7_zero_within(RF, Clause, !Errors) :-
    list.foldl(zero_window(RF), clause_windows(Clause), !Errors).

    %@helper
:- type window_site
    --->    ws_positive
    ;       ws_negated
    ;       ws_then_step.

    %@helper
:- func clause_windows(ast_lhs_clause)
    = list({window_site, list(positioned)}).

clause_windows(alc_then(Step)) = [{ws_then_step, Step ^ ats_within}].
clause_windows(alc_pattern(ap_simple(Body))) = body_window(ws_positive, Body).
clause_windows(alc_pattern(ap_negated(Body, _))) =
    body_window(ws_negated, Body).
clause_windows(alc_pattern(ap_sequence(_, Head, Steps, _))) =
    body_window(ws_positive, Head)
        ++ list.map((func(S) = {ws_then_step, S ^ ats_within}), Steps).

    %@helper
:- func body_window(window_site, ast_pattern_body)
    = list({window_site, list(positioned)}).

body_window(Site, Body) =
    ( if Body ^ apb_within = yes(Span) then [{Site, Span}] else [] ).

    %@helper
:- pred zero_window(resolved_file::in, {window_site, list(positioned)}::in,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

zero_window(RF, {Site, Span}, !Errors) :-
    ( if
        Span = [Tok],
        lgra_2_8_1_time_expr_ns(RF, Span, Ns),
        Ns =< 0i64
    then
        !:Errors = [with_hint(error_at(dv_zero_within, Tok ^ tk_pos,
            zero_window_reason(Site)), "use a positive duration")
            | !.Errors]
    else
        true
    ).

    %@helper
:- func zero_window_reason(window_site) = string.

zero_window_reason(ws_positive) =
    "a `within` window of zero admits no fact, since no fact is less than "
        ++ "zero past its entry stamp, so the pattern never matches "
        ++ "([LTIM.2.7.1])".
zero_window_reason(ws_negated) =
    "a `within` window of zero under `no` blocks on no fact, so the "
        ++ "condition always holds ([LTIM.2.7.1])".
zero_window_reason(ws_then_step) =
    "a `within` window of zero admits no pair of distinct instants, "
        ++ "so nothing can ever match it ([LTHE.4.7])".

%-----------------------------------------------------------------------------%
% Read functions in a `let` -- [LGRA.9.8.2]
%-----------------------------------------------------------------------------%

    % The `let` half only: a `cached()` embedded in a `let`'s right-hand side.
    %
    %@spec [LGRA.9.8.2]
:- pred lgra_9_8_2_embedded_read(ast_let_binding::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
                                 is det.

lgra_9_8_2_embedded_read(Binding, !Errors) :-
    Rhs = let_expression(Binding),
    ( if
        Rhs = ex_call(ex_name(Callee), Args, _),
        read_function(Callee ^ id_name)
    then
        Embedded = list.condense(list.map(read_calls, Args))
    else
        Embedded = read_calls(Rhs)
    ),
    list.foldl(embedded_read, Embedded, !Errors).

    %@helper
:- pred read_function(string::in) is semidet.

read_function("cached").

    %@helper
:- func read_calls(lgra_9_3_1_expr) = list(ident).

read_calls(E) = Here ++ list.condense(list.map(read_calls, expr_children(E))) :-
    ( if E = ex_call(ex_name(Callee), _, _), read_function(Callee ^ id_name) then
        Here = [Callee]
    else
        Here = []
    ).

    %@helper
:- pred embedded_read(ident::in, list(diagnostic)::in, list(diagnostic)::out)
    is det.

embedded_read(Callee, !Errors) :-
    Name = Callee ^ id_name,
    !:Errors = [with_hint(error_at(dv_let_impure_embedded, Callee ^ id_pos,
        "`" ++ Name ++ "()` is embedded in this `let`'s right-hand side, and a "
            ++ "read function is the whole RHS or nothing ([LGRA.9.8.2])"),
        "bind it on its own -- `let x = " ++ Name ++ "(...)` -- and use `x` "
            ++ "in the larger expression") | !.Errors].

%-----------------------------------------------------------------------------%
% A named kwarg of an action's arguments
%-----------------------------------------------------------------------------%

    %@helper
:- pred hyd_kwarg(list(ast_action_arg)::in, string::in, lgra_9_3_1_expr::out,
                  pos::out) is semidet.

hyd_kwarg([Arg | Args], Name, Value, Pos) :-
    ( if Arg = aaa_kwarg(Id, V, P), Id ^ id_name = Name then
        Value = V,
        Pos = P
    else
        hyd_kwarg(Args, Name, Value, Pos)
    ).

%-----------------------------------------------------------------------------%
% Unsatisfiable continuation predicates -- [LCCO.11.2]
%-----------------------------------------------------------------------------%
%
% Literal bounds on one spelled path, and one path equal to two different string
% literals. A bound through a `const`, an arithmetic side or a chained comparison
% is skipped.

    %@helper
:- type sat_bound
    --->    sat_bound(float, bool).     % the value, and whether it is strict

    %@helper
:- type sat_path
    --->    sat_path(
                sp_lo :: maybe(sat_bound),
                sp_hi :: maybe(sat_bound)
            ).

    %@helper
:- type sat_state
    --->    sat_state(
                ss_bounds   :: map(string, sat_path),
                ss_strings  :: map(string, string),
                ss_conflict :: maybe(string)
            ).

    %@spec [LCCO.11.2]
:- pred lcco_11_2_unsatisfiable(ast_action::in,
                                list(diagnostic)::in, list(diagnostic)::out)
                                is det.

lcco_11_2_unsatisfiable(Action, !Errors) :-
    ( if Action ^ aac_block = aab_call(_, Continuations) then
        list.foldl(unsatisfiable_on, Continuations, !Errors)
    else
        true
    ).

    %@helper
:- pred unsatisfiable_on(ast_continuation::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

unsatisfiable_on(Continuation, !Errors) :-
    ( if
        Continuation = acont_on(Predicate, _, Pos),
        list.foldl(constrain, conjuncts(Predicate),
            sat_state(map.init, map.init, no), Final),
        ( if Final ^ ss_conflict = yes(Text0) then
            Text = Text0
        else
            list.find_first_map(empty_range,
                map.to_assoc_list(Final ^ ss_bounds), Text)
        )
    then
        !:Errors = [with_hint(error_at(dv_predicate_unsatisfiable, Pos,
            "this `on` predicate can never match: " ++ Text
                ++ " ([LCCO.11.2])"),
            "the clause body is dead code; widen the bounds, or split the "
                ++ "constraints across separate `on` clauses") | !.Errors]
    else
        true
    ).

    %@helper
:- func conjuncts(lgra_9_3_1_expr) = list(lgra_9_3_1_expr).

conjuncts(E) =
    ( if E = ex_binary(bo_and, L, R, _) then
        conjuncts(L) ++ conjuncts(R)
    else
        [E]
    ).

    %@helper
:- pred constrain(lgra_9_3_1_expr::in, sat_state::in, sat_state::out) is det.

constrain(Conjunct, !State) :-
    ( if Conjunct = ex_compare(Left, [lgra_9_3_2_compare_step(Op, Right, _)], _)
    then
        ( if path_key(Left, Key), numeric_literal(Right, N) then
            tighten(Key, Op, N, !State)
        else if path_key(Right, Key), numeric_literal(Left, N) then
            tighten(Key, flipped(Op), N, !State)
        else if Op = co_eq, path_key(Left, Key), Right = ex_string(S, _) then
            equal_string(Key, S, !State)
        else if Op = co_eq, path_key(Right, Key), Left = ex_string(S, _) then
            equal_string(Key, S, !State)
        else
            true
        )
    else
        true
    ).

    %@helper
:- pred path_key(lgra_9_3_1_expr::in, string::out) is semidet.

path_key(ex_name(Id), Id ^ id_name).
path_key(ex_slot(Base, Field, _), Key) :-
    path_key(Base, BaseKey),
    Key = BaseKey ++ "." ++ Field ^ id_name.

    %@helper
:- pred numeric_literal(lgra_9_3_1_expr::in, float::out) is semidet.

numeric_literal(ex_int(I, _), i64.to_float(I)).
numeric_literal(ex_float(F, _), F).
numeric_literal(ex_unary(uo_neg, Inner, _), N) :-
    numeric_literal(Inner, Positive),
    N = -Positive.

    %@helper
:- func flipped(lgra_9_3_2_compare_op) = lgra_9_3_2_compare_op.

flipped(co_eq) = co_eq.
flipped(co_ne) = co_ne.
flipped(co_lt) = co_gt.
flipped(co_le) = co_ge.
flipped(co_gt) = co_lt.
flipped(co_ge) = co_le.

    %@helper
:- pred tighten(string::in, lgra_9_3_2_compare_op::in, float::in,
                sat_state::in, sat_state::out) is det.

tighten(Key, Op, N, !State) :-
    ( if map.search(!.State ^ ss_bounds, Key, Found) then
        Path0 = Found
    else
        Path0 = sat_path(no, no)
    ),
    ( if Op = co_eq then
        Path = sat_path(lower(Path0 ^ sp_lo, sat_bound(N, no)),
            upper(Path0 ^ sp_hi, sat_bound(N, no)))
    else if Op = co_gt then
        Path = Path0 ^ sp_lo := lower(Path0 ^ sp_lo, sat_bound(N, yes))
    else if Op = co_ge then
        Path = Path0 ^ sp_lo := lower(Path0 ^ sp_lo, sat_bound(N, no))
    else if Op = co_lt then
        Path = Path0 ^ sp_hi := upper(Path0 ^ sp_hi, sat_bound(N, yes))
    else if Op = co_le then
        Path = Path0 ^ sp_hi := upper(Path0 ^ sp_hi, sat_bound(N, no))
    else
        Path = Path0
    ),
    !State ^ ss_bounds := map.set(!.State ^ ss_bounds, Key, Path).

    %@helper
:- func lower(maybe(sat_bound), sat_bound) = maybe(sat_bound).

lower(no, New) = yes(New).
lower(yes(sat_bound(P, PS)), sat_bound(N, NS)) =
    ( if ( N > P ; N = P, NS = yes ) then
        yes(sat_bound(N, NS))
    else
        yes(sat_bound(P, PS))
    ).

    %@helper
:- func upper(maybe(sat_bound), sat_bound) = maybe(sat_bound).

upper(no, New) = yes(New).
upper(yes(sat_bound(P, PS)), sat_bound(N, NS)) =
    ( if ( N < P ; N = P, NS = yes ) then
        yes(sat_bound(N, NS))
    else
        yes(sat_bound(P, PS))
    ).

    %@helper
:- pred equal_string(string::in, string::in, sat_state::in, sat_state::out)
    is det.

equal_string(Key, S, !State) :-
    ( if
        map.search(!.State ^ ss_strings, Key, Prior),
        Prior \= S,
        !.State ^ ss_conflict = no
    then
        !State ^ ss_conflict := yes("`" ++ Key ++ "` cannot equal both \""
            ++ Prior ++ "\" and \"" ++ S ++ "\"")
    else
        true
    ),
    !State ^ ss_strings := map.set(!.State ^ ss_strings, Key, S).

    %@helper
:- pred empty_range(pair(string, sat_path)::in, string::out) is semidet.

empty_range(Key - sat_path(yes(sat_bound(L, LS)), yes(sat_bound(H, HS))),
        Text) :-
    ( if L > H then
        Text = "`" ++ Key ++ "` is bounded below by "
            ++ string.float_to_string(L) ++ " and above by "
            ++ string.float_to_string(H)
    else
        L = H,
        ( LS = yes ; HS = yes ),
        Text = "`" ++ Key ++ "` is bounded to the empty range at "
            ++ string.float_to_string(L)
    ).

%-----------------------------------------------------------------------------%
% Literal refusals over every rule expression
%-----------------------------------------------------------------------------%
%
% Syntactic walks: the typing walk does not reach every position.

    % A dividend whose type is unknown is refused.
    %
    %@spec [LEXP.10.2.2]
:- pred lexp_10_2_2_zero_divisor(type_env::in, lgra_9_3_1_expr::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
                                 is det.

lexp_10_2_2_zero_divisor(Env, E, !Errors) :-
    ( if
        E = ex_binary(Op, Dividend, Divisor, Pos),
        ( Op = bo_div, Spelled = "/"
        ; Op = bo_floordiv, Spelled = "//"
        ; Op = bo_mod, Spelled = "%"
        ),
        Divisor = ex_int(0i64, _),
        not (
            type_of_expr(Env, Dividend) = ty_known(K),
            K ^ dt_leaf = lk_float
        )
    then
        !:Errors = [error_at(dv_div_by_zero, Pos,
            "`" ++ Spelled ++ " 0` divides an `Int` by a literal zero, which "
                ++ "is undefined ([LEXP.10.2.2])") | !.Errors]
    else
        true
    ),
    list.foldl(lexp_10_2_2_zero_divisor(Env), expr_children(E), !Errors).

    % An argument is constant when `dsc.dstest` folds it to an `Int`. On an `Int`
    % receiver only: `.bits` on a fact binding is a slot read.
    %
    %@spec [LEXP.3.7.4]
:- pred lexp_3_7_4_bit_field_range(type_env::in, lgra_9_3_1_expr::in,
                                   list(diagnostic)::in, list(diagnostic)::out)
                                   is det.

lexp_3_7_4_bit_field_range(Env, E, !Errors) :-
    ( if
        E = ex_call(ex_slot(Receiver, Method, _), Args, Pos),
        Name = Method ^ id_name,
        ( Name = "bits" ; Name = "sign_extend" ; Name = "swap_bytes" ),
        type_of_expr(Env, Receiver) = ty_known(K),
        K ^ dt_leaf = lk_int,
        Constants = list.map(constant_argument(Env ^ te_file), Args),
        lexp_3_7_3_outside_domain(Name, Constants, Why)
    then
        !:Errors = [with_hint(error_at(dv_bit_field_range, Pos,
            "`." ++ Name ++ "(...)` " ++ Why ++ " ([LEXP.3.7.3], "
                ++ "[LEXP.3.7.4])"),
            "a field is 1 to 64 bits wide and lies within bits 0 to 63; "
                ++ "`swap_bytes` takes a width of 16, 32 or 64")
            | !.Errors]
    else
        true
    ),
    list.foldl(lexp_3_7_4_bit_field_range(Env), expr_children(E), !Errors).

    %@helper
:- func constant_argument(resolved_file, lgra_9_3_1_expr) = maybe(int64).

constant_argument(RF, Arg) =
    ( if lexp_8_8_int_constant(RF, Arg, I) then yes(I) else no ).

    % `no` is a run-time argument.
    %
    %@helper
:- pred lexp_3_7_3_outside_domain(string::in, list(maybe(int64))::in,
                                  string::out) is semidet.

lexp_3_7_3_outside_domain(Name, Constants, Why) :-
    ( if Name = "bits", Constants = [MaybeLo, MaybeW] then
        ( if MaybeLo = yes(Lo), Lo < 0i64 then
            Why = "starts its field below bit 0"
        else if MaybeLo = yes(Lo), Lo > 63i64 then
            Why = "starts its field past bit 63"
        else if MaybeW = yes(W), W < 1i64 then
            Why = "has a field narrower than 1 bit"
        else if MaybeW = yes(W), W > 64i64 then
            Why = "has a field wider than the 64-bit pattern"
        else
            MaybeLo = yes(Lo),
            MaybeW = yes(W),
            Lo + W > 64i64,
            Why = "has a field that runs past bit 63"
        )
    else if Name = "sign_extend", Constants = [yes(W)] then
        ( W < 1i64 ; W > 64i64 ),
        Why = "takes a width from 1 to 64"
    else
        Name = "swap_bytes",
        Constants = [yes(W)],
        not ( W = 16i64 ; W = 32i64 ; W = 64i64 ),
        Why = "takes a width of 16, 32 or 64"
    ).

    %@spec [LCST.4.6.1]
:- pred lcst_4_6_1_coercion_call(resolved_file::in, lgra_9_3_1_expr::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
                                 is det.

lcst_4_6_1_coercion_call(RF, E, !Errors) :-
    ( if
        E = ex_call(ex_name(Id), _, _),
        lcst_4_6_1_coercion_head(RF, Id ^ id_name, Rewrite)
    then
        !:Errors = [with_hint(error_at(dv_coercion_form_removed, Id ^ id_pos,
            "`" ++ Id ^ id_name ++ "(<expr>)` is removed; the postfix `::` "
                ++ "cast is the only conversion form ([LCST.4.6.1])"),
            "write `<expr>::" ++ Rewrite ++ "`") | !.Errors]
    else
        true
    ),
    list.foldl(lcst_4_6_1_coercion_call(RF), expr_children(E), !Errors).

    % A method call on a `let` is not a slot access, though it parses as one: the
    % callee's own `.` is skipped.
    %
    %@spec [LLET.10.5]
:- pred llet_10_5_let_slot(rule_scope::in, lgra_9_3_1_expr::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

llet_10_5_let_slot(Scope, E, !Errors) :-
    ( if E = ex_call(ex_slot(Receiver, _, _), Args, _) then
        list.foldl(llet_10_5_let_slot(Scope), [Receiver | Args], !Errors)
    else
        ( if
            E = ex_slot(ex_name(Id), Field, _),
            map.contains(Scope ^ rsc_lets, Id ^ id_name),
            not map.contains(Scope ^ rsc_bindings, Id ^ id_name),
            not lgra_9_6_2_zero_arg_member(Field ^ id_name)
        then
            !:Errors = [with_hint(error_at(dv_let_no_slot, Field ^ id_pos,
                "`" ++ Id ^ id_name ++ "` is a `let` binding and has no slot `"
                    ++ Field ^ id_name ++ "`: `let` binds an expression, not "
                    ++ "a fact ([LLET.10.5])"),
                "bind the fact in a pattern if its slots are wanted")
                | !.Errors]
        else
            true
        ),
        list.foldl(llet_10_5_let_slot(Scope), expr_children(E), !Errors)
    ).

    % `ltac_2_1_parse_after` takes one `UNIT_LIT` token, so nothing reaches
    % `dsc.rete.duration_ns_of` that it would lower to a 0 ns timer.
    %
    %@spec [LTAC.7.1]
    %@spec [LTAC.2.2]
:- pred ltac_7_1_after_duration(ast_after_clause::in,
                                list(diagnostic)::in, list(diagnostic)::out)
                                is det.

ltac_7_1_after_duration(After, !Errors) :-
    Duration = After ^ aaf_duration,
    ( if Duration = ex_unit(Magnitude, Suffix, Pos) then
        Symbol = llex_12_5_symbol_of(Suffix),
        ( if luni_10_2_time_unit(Symbol, Multiplier) then
            ( if luni_3_1_5_magnitude_ns(Magnitude, Multiplier) =< 0i64 then
                !:Errors = [with_hint(error_at(dv_after_nonpositive_duration,
                    Pos, "an `after` delay must be positive ([LTAC.7.1])"),
                    "use a positive duration, like `30_s` or `5_min`")
                    | !.Errors]
            else
                true
            )
        else
            !:Errors = [with_hint(error_at(dv_bad_unit_dimension, Pos,
                "an `after` delay takes a time-unit suffix, and `" ++ Symbol
                    ++ "` in `" ++ Magnitude ++ Suffix ++ "` is not a time "
                    ++ "unit ([LTAC.2.2], [LLEX.12.8])"),
                "the time units are `ns`, `µs`, `ms`, `s`, `min`, `h` and `d`")
                | !.Errors]
        )
    else
        !:Errors = [error_at(dv_bad_unit_dimension, After ^ aaf_pos,
            "an `after` delay is a time-unit literal ([LTAC.2.2])")
            | !.Errors]
    ).

    % Without `dynamic_ttl`, "compile-time constant" is read as a duration literal:
    % `retain: HALF_MINUTE` is refused. With it, the expression is typed.
    %
    %@spec [LDTL.3.2]
    %@spec [LDTL.4.1]
:- pred ldtl_3_2_retain(resolved_file::in, type_env::in, ast_action::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

ldtl_3_2_retain(RF, Env, Action, !Errors) :-
    ( if
        fact_verb(Action ^ aac_head, Verb, Ref),
        ldtl_4_1_retain_override(Verb, "retain"),
        Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
        list.find_first_match(retain_kwarg, Args, aaa_kwarg(Name, Value, _)),
        lgra_22_4_schema_of(RF, Ref, Schema)
    then
        Target = Schema ^ as_name ^ id_name,
        ( if Schema ^ as_lifecycle = al_ttl(Span, _) then
            ( if ldtl_dynamic_ttl_file(RF) then
                ValueType = type_of_expr(Env, Value),
                ( if
                    ValueType = ty_known(Known),
                    Known ^ dt_leaf \= lk_duration
                then
                    !:Errors = [with_hint(error_at(dv_type_mismatch,
                        Name ^ id_pos,
                        "`retain:` on `" ++ Verb ++ " " ++ Target ++ "` has "
                            ++ "type `" ++ leaf_name(Known ^ dt_leaf)
                            ++ "`, and a per-emit TTL is a `Duration` "
                            ++ "([LDTL.4.1])"),
                        "write a duration, like `retain: 30_s`")
                        | !.Errors]
                else
                    !:Errors = list.reverse(lnul_5_1_concrete(Env, Value,
                        ValueType, Name ^ id_pos, "`retain:`")) ++ !.Errors
                )
            else if same_duration(Span, Value) then
                true
            else
                !:Errors = [ldia_5_1_disabled_at(RF ^ rf_program,
                    cap_dynamic_ttl,
                    "`retain:` on `" ++ Verb ++ " " ++ Target
                        ++ "`, which overrides the schema TTL at runtime "
                        ++ "([LDTL.3.2]),",
                    Name ^ id_pos)
                    | !.Errors]
            )
        else
            !:Errors = [with_hint(error_at(dv_retain_non_ttl, Name ^ id_pos,
                "`retain:` on `" ++ Verb ++ " " ++ Target ++ "` has nothing to "
                    ++ "override: a per-emit TTL applies only to a "
                    ++ "`ttl`-lifecycle schema ([LDTL.4.1])"),
                "declare `" ++ Target ++ "` `scope ttl <dur>`, or remove the "
                    ++ "`retain:` kwarg") | !.Errors]
        )
    else
        true
    ).

    %@helper
:- pred retain_kwarg(ast_action_arg::in) is semidet.

retain_kwarg(aaa_kwarg(Name, _, _)) :-
    Name ^ id_name = "retain".

    %@helper
:- pred ldtl_dynamic_ttl_file(resolved_file::in) is semidet.

ldtl_dynamic_ttl_file(RF) :-
    enabled(RF ^ rf_program, cap_dynamic_ttl).

    %@helper
:- pred same_duration(list(positioned)::in, lgra_9_3_1_expr::in) is semidet.

same_duration(Span, Value) :-
    Span = [Tok],
    Tok ^ tk_tok = unit_lit(TtlMagnitude, TtlSuffix),
    luni_10_2_time_unit(llex_12_5_symbol_of(TtlSuffix), TtlMultiplier),
    Value = ex_unit(Magnitude, Suffix, _),
    luni_10_2_time_unit(llex_12_5_symbol_of(Suffix), Multiplier),
    luni_3_1_5_magnitude_ns(Magnitude, Multiplier)
        = luni_3_1_5_magnitude_ns(TtlMagnitude, TtlMultiplier).

    % `rsc_lets` is a map, so this walks the bindings in source order and refuses a
    % name bound only at or after the binding that reads it.
    %
    %@spec [LLET.12.3]
    %@spec [LLET.10.1]
    %@spec [LLET.10.6]
:- pred llet_12_3_forward_refs(ast_rule::in, list(diagnostic)::out) is det.

llet_12_3_forward_refs(Rule, Errors) :-
    forward_refs(rule_let_bindings(Rule), [], RevErrors),
    Errors = reverse(RevErrors).

    %@helper
:- pred forward_refs(list(ast_let_binding)::in,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

forward_refs([], !Errors).
forward_refs([Binding | Later], !Errors) :-
    NotYet = set.list_to_set(list.map(id_text,
        list.condense(list.map(bound_let_names, [Binding | Later])))),
    list.foldl(forward_name(NotYet), expr_names(let_expression(Binding)),
        !Errors),
    forward_refs(Later, !Errors).

    %@helper
:- func expr_names(lgra_9_3_1_expr) = list(ident).

expr_names(Expr) = Names :-
    ( if Expr = ex_name(Id) then Here = [Id] else Here = [] ),
    Names = Here ++ list.condense(list.map(expr_names, expr_children(Expr))).

    %@helper
:- pred forward_name(set(string)::in, ident::in,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

forward_name(NotYet, Id, !Errors) :-
    Name = Id ^ id_name,
    ( if set.contains(NotYet, Name) then
        !:Errors = [with_hint(error_at(dv_unknown_binding, Id ^ id_pos,
            "`" ++ Name ++ "` is not bound yet: a `let` reads only the `let`s "
                ++ "above it ([LLET.12.3])"),
            "move `let " ++ Name ++ "` above the binding that reads it")
            | !.Errors]
    else
        true
    ).

    % Each `on` predicate, at any depth, is typed as a `where` is, in the
    % environment its body is typed in, so an unknown slot is the typing's own
    % refusal. Only a service whose response this file resolves: with none,
    % `response` is unbound.
    %
    %@spec [LCCO.11.1]
    %@spec [LCCO.6.2]
:- pred lcco_11_1_on_predicates(type_env::in, ast_rule::in,
                                list(diagnostic)::in, list(diagnostic)::out)
    is det.

lcco_11_1_on_predicates(Env, Rule, !Errors) :-
    list.foldl(on_predicates(Env), scoped_actions(Env, Rule), !Errors).

    %@helper
:- pred on_predicates(type_env::in, {type_env, ast_action}::in,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

on_predicates(Base, {_, Action}, !Errors) :-
    ( if
        Action ^ aac_block = aab_call(_, Continuations),
        call_response_name(Base ^ te_file, Action, _)
    then
        list.foldl(on_predicate(Base, Action), Continuations, !Errors)
    else
        true
    ).

    %@helper
:- pred on_predicate(type_env::in, ast_action::in, ast_continuation::in,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

on_predicate(Base, Action, Continuation, !Errors) :-
    ( if Continuation = acont_on(Predicate, _, _) then
        typed_expr(Base ^ te_file, continuation_env(Base, Action, Continuation),
            Predicate, !Errors)
    else
        true
    ).

%-----------------------------------------------------------------------------%
% `CallResponse` is refused -- [LCRS.4.3.3]
%-----------------------------------------------------------------------------%

    %@spec [LCRS.4.3.3]
:- pred lcrs_4_3_3_call_response_retired(resolved_file::in,
                                         list(diagnostic)::out) is det.

lcrs_4_3_3_call_response_retired(RF, Errors) :-
    Decls = RF ^ rf_ast ^ af_decls,
    Declared = list.filter_map(
        ( func(D) = S ^ as_name is semidet :-
            D = ad_schema(S),
            S ^ as_name ^ id_name = "CallResponse"
        ), Decls),
    Rules = list.filter_map(rule_of, Decls),
    Named = list.filter_map(
        ( func(B) = Id is semidet :-
            B ^ apb_type = atr_bare(Id),
            Id ^ id_name = "CallResponse"
        ), list.condense(list.map(response_rule_bodies, Rules))),
    Errors = list.map(call_response_retired, Declared ++ Named).

    %@helper
:- func call_response_retired(ident) = diagnostic.

call_response_retired(Id) =
    with_hint(error_at(dv_call_response_retired, Id ^ id_pos,
        "`CallResponse` is retired: a call's response is a fact of the "
            ++ "service's own response schema ([LCRS.4.3.3])"),
        "match the schema the service's `response T` line names, with "
            ++ "`corr` equal to the call's correlation ([LCRS.5.5])").

    %@helper
:- func response_rule_bodies(ast_rule) = list(ast_pattern_body).

response_rule_bodies(Rule) =
    list.condense(list.map(response_clause_bodies, Rule ^ ar_lhs)).

    %@helper
:- func response_clause_bodies(ast_lhs_clause) = list(ast_pattern_body).

response_clause_bodies(alc_then(Step)) = [Step ^ ats_body].
response_clause_bodies(alc_pattern(ap_simple(Body))) = [Body].
response_clause_bodies(alc_pattern(ap_negated(Body, _))) = [Body].
response_clause_bodies(alc_pattern(ap_sequence(_, Head, Steps, _))) =
    [Head | list.map((func(S) = S ^ ats_body), Steps)].

    % Only a service this file resolves. An `error` continuation stays legal.
    %
    %@spec [LCRS.17.2]
:- pred lcrs_17_2_no_response_continuation(resolved_file::in, ast_action::in,
                                           list(diagnostic)::in,
                                           list(diagnostic)::out) is det.

lcrs_17_2_no_response_continuation(RF, Action, !Errors) :-
    ( if
        Action ^ aac_head = aah_call(Ref),
        Action ^ aac_block = aab_call(_, Continuations),
        called_service(RF, Ref, Service),
        Service ^ asv_response = ar_none(_)
    then
        list.foldl(no_response_on(service_text(Ref)), Continuations, !Errors)
    else
        true
    ).

    %@helper
:- pred no_response_on(string::in, ast_continuation::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

no_response_on(Service, Continuation, !Errors) :-
    (
        Continuation = acont_on(_, _, Pos),
        !:Errors = [with_hint(error_at(dv_no_response_continuation, Pos,
            "`" ++ Service ++ "` declares `no response`, so nothing comes back "
                ++ "for an `on` clause to continue on ([LCRS.17.2])"),
            "`error:` still applies; declare `response T` if the service "
                ++ "answers")
            | !.Errors]
    ;
        Continuation = acont_timeout(_, _, Pos),
        !:Errors = [with_hint(error_at(dv_no_response_timeout, Pos,
            "`" ++ Service ++ "` declares `no response`, so a `timeout` would "
                ++ "fire on every call that does not fail ([LCRS.17.2])"),
            "`error:` covers failure, and `after` covers a delay")
            | !.Errors]
    ;
        Continuation = acont_error(_, _, _)
    ).

    %@helper
:- pred called_service(resolved_file::in, ast_service_ref::in,
                       ast_service_decl::out) is semidet.

called_service(RF, asr_bare(Path), Service) :-
    map.search(RF ^ rf_services, dotted(Path), Service).

    % No hint: the clause has the message name no replacement.
    %
    %@spec [LGRA.10.1.5]
:- pred lgra_10_1_5_record_event(ast_action::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_10_1_5_record_event(Action, !Errors) :-
    ( if Action ^ aac_head = aah_record_event(_) then
        !:Errors = [error_at(dv_record_event_retired, Action ^ aac_pos,
            "`record_event` is retired and is not an action ([LGRA.10.1.5])")
            | !.Errors]
    else
        true
    ).

    %@spec [LGRA.10.1.1]
:- pred lgra_10_1_1_log_level(ast_action::in,
                              list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_10_1_1_log_level(Action, !Errors) :-
    ( if Action ^ aac_head = aah_log(ll_unknown(Name), _) then
        !:Errors = [with_hint(error_at(dv_bad_log_level, Action ^ aac_pos,
            "`log " ++ Name ++ "`: `" ++ Name ++ "` is not a log level "
                ++ "([LGRA.10.1.1])"),
            "the levels are debug, info, warning, error and critical, in any "
                ++ "case") | !.Errors]
    else
        true
    ).

%-----------------------------------------------------------------------------%
% Regex -- [LREG.2], [LREG.3.3], [LREG.4.2], [LREG.5], [LREG.7], [LREG.8.4]
%-----------------------------------------------------------------------------%
%
% RE2 (`ds.re2`) answers every question about a pattern; nothing here reads one.

    %@helper
:- pred lreg_7_2_rule_regex(ast_rule::in, list(diagnostic)::out) is det.

lreg_7_2_rule_regex(Rule, Errors) :-
    Everywhere = list.condense(list.map(expr_matches, rule_expressions(Rule))),
    list.foldl(lreg_7_1_pattern, Everywhere, [], RevPatterns),
    Captures = rule_captures(Rule),
    CaptureMatches = list.map((func(C) = C ^ acap_match), Captures),
    % A capture's own match is the one `where` match that may capture.
    Wheres = list.filter(
        (pred(M::in) is semidet :- not list.member(M, CaptureMatches)),
        list.condense(list.map(expr_matches, rule_predicates(Rule)))),
    list.foldl(lreg_2_3_where_captures, Wheres, [], RevWheres),
    list.foldl(lreg_4_1_where_capture, Captures, [], RevCaptures),
    list.foldl(lreg_4_1_let, rule_let_bindings(Rule), [], RevLets),
    Errors = reverse(RevPatterns) ++ reverse(RevWheres)
        ++ reverse(RevCaptures) ++ reverse(RevLets).

    %@helper
:- func rule_captures(ast_rule) = list(ast_capture).

rule_captures(Rule) =
    list.condense(list.map(clause_captures, Rule ^ ar_lhs)).

    %@helper
:- func clause_captures(ast_lhs_clause) = list(ast_capture).

clause_captures(alc_then(S)) = body_captures(S ^ ats_body).
clause_captures(alc_pattern(ap_simple(B))) = body_captures(B).
clause_captures(alc_pattern(ap_negated(B, _))) = body_captures(B).
clause_captures(alc_pattern(ap_sequence(_, Head, Steps, _))) =
    body_captures(Head)
        ++ list.condense(list.map((func(S) = body_captures(S ^ ats_body)),
            Steps)).

    %@helper
:- func body_captures(ast_pattern_body) = list(ast_capture).

body_captures(B) = ( if B ^ apb_capture = yes(C) then [C] else [] ).

    %@helper
:- func expr_matches(lgra_9_3_1_expr) = list(lgra_9_3_1_expr).

expr_matches(Expr) = Matches :-
    ( if Expr = ex_match(_, _, _, _, _) then Here = [Expr] else Here = [] ),
    Matches = Here ++ list.condense(list.map(expr_matches,
        expr_children(Expr))).

    %@helper
:- func match_groups(string, string) = maybe(list(maybe(string))).

match_groups(Pattern, Flags) =
    ( if re2_compile(Pattern, lreg_5_2_flags(Flags)) = re2_valid(Groups) then
        yes(Groups)
    else
        no
    ).

    %@spec [LREG.5.2]
    %@spec [LREG.10.9]
:- func lreg_5_2_flags(string) = re2_flags.

lreg_5_2_flags(Flags) =
    re2_flags(has_flag(Flags, 'i'), has_flag(Flags, 'm'),
        has_flag(Flags, 's')).

    %@helper
:- func has_flag(string, char) = bool.

has_flag(Flags, C) = ( if string.contains_char(Flags, C) then yes else no ).

    %@spec [LREG.7.1]
    %@spec [LREG.7.2]
    %@spec [LREG.8.1]
    %@spec [LREG.8.4]
    %@spec [LREG.10.10]
:- pred lreg_7_1_pattern(lgra_9_3_1_expr::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

lreg_7_1_pattern(Match, !Errors) :-
    ( if Match = ex_match(_, _, Pattern, Flags, Pos) then
        lreg_5_3_flags(Flags, Pos, !Errors),
        Compiled = re2_compile(Pattern, lreg_5_2_flags(Flags)),
        (
            Compiled = re2_valid(_)
        ;
            Compiled = re2_invalid(Message),
            ( if lreg_8_4_unsupported(Message, Feature) then
                !:Errors = [with_hint(error_at(dv_regex_unsupported_feature,
                    Pos, "`/" ++ Pattern ++ "/` uses " ++ Feature
                        ++ ", which RE2 does not support ([LREG.8.4])"),
                    "RE2 has no backreferences, lookaround, possessive "
                        ++ "quantifiers or atomic groups; shape the value "
                        ++ "upstream instead") | !.Errors]
            else
                !:Errors = [error_at(dv_regex_syntax_error, Pos,
                    "`/" ++ Pattern ++ "/` is not a valid RE2 pattern: "
                        ++ Message ++ " ([LREG.7.1])") | !.Errors]
            )
        )
    else
        true
    ).

    % The construct RE2 refused, in the author's terms, read off RE2's own message.
    %
    %@helper
:- pred lreg_8_4_unsupported(string::in, string::out) is semidet.

lreg_8_4_unsupported(Message, Feature) :-
    ( if string.remove_prefix("invalid perl operator: ", Message, Arg) then
        ( if string.prefix(Arg, "(?=") then
            Feature = "a positive lookahead `(?=...)`"
        else if string.prefix(Arg, "(?!") then
            Feature = "a negative lookahead `(?!...)`"
        else if string.prefix(Arg, "(?<=") then
            Feature = "a positive lookbehind `(?<=...)`"
        else if string.prefix(Arg, "(?<!") then
            Feature = "a negative lookbehind `(?<!...)`"
        else
            string.prefix(Arg, "(?>"),
            Feature = "an atomic group `(?>...)`"
        )
    else if string.remove_prefix("invalid escape sequence: \\", Message, Arg)
    then
        ( if string.index(Arg, 0, D), char.is_digit(D), D \= ('0') then
            Feature = "a backreference `\\" ++ Arg ++ "`"
        else
            string.prefix(Arg, "k"),
            Feature = "a named backreference `\\k<...>`"
        )
    else
        string.remove_prefix("bad repetition operator: ", Message, Arg),
        ( Arg = "*+"
        ; Arg = "++"
        ; Arg = "?+"
        ; string.suffix(Arg, "}+")
        ),
        Feature = "a possessive quantifier `" ++ Arg ++ "`"
    ).

    %@spec [LREG.5.3]
    %@spec [LREG.5.4]
:- pred lreg_5_3_flags(string::in, pos::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

lreg_5_3_flags(Flags, Pos, !Errors) :-
    Chars = string.to_char_list(Flags),
    ( if first_unknown_flag(Chars, Bad) then
        !:Errors = [with_hint(error_at(dv_regex_unknown_flag, Pos,
            "`" ++ string.from_char(Bad) ++ "` is not a regex flag "
                ++ "([LREG.5.4])"),
            "the flags are `i`, `m` and `s`") | !.Errors]
    else if has_repeat(Chars) then
        !:Errors = [error_at(dv_regex_unknown_flag, Pos,
            "`/" ++ Flags ++ "` repeats a flag; each of `i`, `m`, `s` may "
                ++ "appear once ([LREG.5.3])") | !.Errors]
    else
        true
    ).

    %@helper
:- pred has_repeat(list(char)::in) is semidet.

has_repeat([C | Cs]) :-
    ( if list.member(C, Cs) then true else has_repeat(Cs) ).

    %@helper
:- pred first_unknown_flag(list(char)::in, char::out) is semidet.

first_unknown_flag([C | Cs], Bad) :-
    ( if ( C = 'i' ; C = 'm' ; C = 's' ) then
        first_unknown_flag(Cs, Bad)
    else
        Bad = C
    ).

    %@spec [LREG.2.1]
    %@spec [LREG.2.3]
    %@spec [LREG.2.4]
    %@spec [LREG.10.1]
    %@spec [LREG.10.3]
:- pred lreg_2_3_where_captures(lgra_9_3_1_expr::in,
                                list(diagnostic)::in, list(diagnostic)::out)
    is det.

lreg_2_3_where_captures(Match, !Errors) :-
    ( if
        Match = ex_match(_, Sense, Pattern, Flags, Pos),
        match_groups(Pattern, Flags) = yes([_ | _])
    then
        (
            Sense = ms_match,
            Hint = "use `(?:...)` to group without capturing, or bind the "
                ++ "captures with `where (name, ...) = s ~ /pattern/`",
            Clause = "[LREG.2.3]"
        ;
            Sense = ms_not_match,
            Hint = "a pattern that must not match has nothing to capture; "
                ++ "use `(?:...)`",
            Clause = "[LREG.2.4]"
        ),
        !:Errors = [with_hint(error_at(dv_regex_where_has_captures, Pos,
            "`/" ++ Pattern ++ "/` has capturing groups, and a `where` "
                ++ "pattern captures nothing (" ++ Clause ++ ")"), Hint)
            | !.Errors]
    else
        true
    ).

    %@spec [LREG.4.1]
    %@spec [LREG.2.5]
:- pred lreg_4_1_let(ast_let_binding::in,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

lreg_4_1_let(Binding, !Errors) :-
    (
        Binding = alb_simple(Id, _, Expr, _),
        list.foldl(lreg_4_1_let_match(Id ^ id_name), expr_matches(Expr),
            !Errors)
    ;
        Binding = alb_capture(Ids, _, BindingPos),
        Names = string.join_list(", ", list.map(id_text, Ids)),
        !:Errors = [with_hint(error_at(dv_regex_capture_in_let, BindingPos,
            "`let (" ++ Names ++ ")`: a capture binds in the pattern's "
                ++ "`where`, never in a `let` ([LREG.4.1])"),
            "move it to the pattern: `where (" ++ Names
                ++ ") = s ~ /pattern/`") | !.Errors]
    ).

    %@helper
:- pred lreg_4_1_let_match(string::in, lgra_9_3_1_expr::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lreg_4_1_let_match(Name, Match, !Errors) :-
    ( if Match = ex_match(_, Sense, _, _, Pos) then
        (
            Sense = ms_not_match,
            !:Errors = [lreg_2_5_negated(Pos) | !.Errors]
        ;
            Sense = ms_match,
            !:Errors = [with_hint(error_at(dv_regex_capture_in_let, Pos,
                "`let " ++ Name ++ "`: a regex match is written in a "
                    ++ "pattern's `where`, never in a `let` ([LREG.4.1])"),
                "gate on it with `where s ~ /pattern/`, or bind its groups "
                    ++ "with `where (name, ...) = s ~ /pattern/`")
                | !.Errors]
        )
    else
        true
    ).

    %@spec [LREG.4.1]
    %@spec [LREG.4.2]
    %@spec [LREG.3.2]
    %@spec [LREG.2.4]
    %@spec [LREG.10.4]
:- pred lreg_4_1_where_capture(ast_capture::in,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

lreg_4_1_where_capture(ast_capture(Ids, Expr, CapPos), !Errors) :-
    ( if Expr = ex_match(_, ms_match, Pattern, Flags, Pos) then
        ( if match_groups(Pattern, Flags) = yes(Groups) then
            NIds = list.length(Ids),
            NGroups = list.length(Groups),
            ( if NIds \= NGroups then
                !:Errors = [with_hint(error_at(
                    dv_regex_binding_length_mismatch, Pos,
                    "the binding form names " ++ int_to_string(NIds)
                        ++ " but `/" ++ Pattern ++ "/` captures "
                        ++ int_to_string(NGroups) ++ " ([LREG.4.2])"),
                    "one name per capturing group; `(?:...)` groups "
                        ++ "without capturing") | !.Errors]
            else
                lreg_3_3_names(Ids, Groups, Pos, !Errors)
            )
        else
            true
        )
    else if Expr = ex_match(_, ms_not_match, _, _, Pos) then
        !:Errors = [with_hint(error_at(dv_regex_capture_not_match, Pos,
            "`!~` captures nothing, so it has no binding form ([LREG.2.4])"),
            "drop the capture list: `where s !~ /pattern/`") | !.Errors]
    else
        !:Errors = [with_hint(error_at(dv_regex_capture_not_match, CapPos,
            "a `where (...)` binding form destructures a regex match, and "
                ++ "what follows its `=` is not one ([LREG.4.1])"),
            "write `where (name, ...) = s ~ /pattern/`, with any further "
                ++ "condition after `and`") | !.Errors]
    ).

    %@helper
:- func lreg_2_5_negated(pos) = diagnostic.

lreg_2_5_negated(Pos) =
    with_hint(error_at(dv_regex_let_negated, Pos,
        "`!~` produces no captures and is not legal in `let` ([LREG.2.5])"),
        "use `where s !~ /pattern/`").

    %@spec [LREG.3.3]
    %@spec [LREG.3.1]
    %@spec [LREG.10.5]
:- pred lreg_3_3_names(list(ident)::in, list(maybe(string))::in, pos::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

lreg_3_3_names(Ids, Groups, Pos, !Errors) :-
    ( if Ids = [Id | IdsRest], Groups = [Group | GroupsRest] then
        ( if Group = yes(Named), Named \= Id ^ id_name then
            !:Errors = [with_hint(error_at(dv_regex_name_mismatch, Pos,
                "the capture `(?<" ++ Named ++ ">...)` sits where the binding "
                    ++ "form names `" ++ Id ^ id_name ++ "` ([LREG.3.3])"),
                "rename one of them so the two agree") | !.Errors]
        else
            true
        ),
        lreg_3_3_names(IdsRest, GroupsRest, Pos, !Errors)
    else
        true
    ).

%-----------------------------------------------------------------------------%
% Correlation keys -- [LRST.1.4], [LRST.1.5], [LRST.1.5.1]
%-----------------------------------------------------------------------------%

    %@helper
:- pred lrst_1_4_call_key(resolved_file::in, type_env::in, ast_action::in,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

lrst_1_4_call_key(RF, Env, Action, !Errors) :-
    lrst_1_4_as_key(RF, Env, as_call, Action ^ aac_pos, Action ^ aac_as,
        !Errors).

    %@helper
:- pred lrst_1_4_after_key(resolved_file::in, type_env::in,
                           ast_after_clause::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lrst_1_4_after_key(RF, Env, After, !Errors) :-
    lrst_1_4_as_key(RF, Env, as_after, After ^ aaf_pos, After ^ aaf_as,
        !Errors).

    % Which `as` a key belongs to. They share every rule but the type
    % ([LRST.1.4.1]).
    %
    %@helper
:- type as_site
    --->    as_call
    ;       as_after.

    % [LRST.1.5]'s two causes have two codes: a `Json` sub-path is
    % `DS_VALIDATE_AS_SOFTFAIL_EXPRESSION`, and a `T?` slot
    % `DS_VALIDATE_NULLABLE_UNNARROWED`.
    %
    %@spec [LRST.1.2]
    %@spec [LRST.1.4]
    %@spec [LRST.1.4.1]
    %@spec [LRST.1.5]
:- pred lrst_1_4_as_key(resolved_file::in, type_env::in, as_site::in, pos::in,
                        maybe(lgra_9_3_1_expr)::in,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

lrst_1_4_as_key(RF, Env, Site, Pos, MaybeKey, !Errors) :-
    (
        MaybeKey = no
    ;
        MaybeKey = yes(Key),
        ( if Key = ex_string("", _) then
            !:Errors = [with_hint(error_at(dv_as_empty_key, Pos,
                "`as \"\"` declares no key: an empty key supersedes nothing "
                    ++ "([LRST.1.2])"),
                "drop the `as`, or key on a value that names the restart")
                | !.Errors]
        else if Key = ex_string(Text, StringPos) then
            list.foldl(lrst_1_5_1_segment(Env, StringPos),
                interp_site_paths(string.to_char_list(Text)), !Errors)
        else if json_subpath(Env, Key) then
            !:Errors = [lrst_1_5_softfail(Pos, "a `Json` sub-path")
                | !.Errors]
        else
            typed_expr(RF, Env, Key, !Errors),
            Type = type_of_expr(Env, Key),
            ( if
                Site = as_call,
                Type = ty_known(Known),
                Known ^ dt_leaf \= lk_string
            then
                !:Errors = [with_hint(error_at(dv_call_as_not_string, Pos,
                    "this `call`'s `as` key is a `" ++ leaf_name(Known ^ dt_leaf)
                        ++ "`; a call's key is its correlation, which is a "
                        ++ "`String` ([LRST.1.4.1])"),
                    "write the key as text, for example `as \"{...}\"`")
                    | !.Errors]
            else if Type = ty_known(Known), Known ^ dt_leaf = lk_json then
                !:Errors = [with_hint(error_at(dv_as_non_equatable_type, Pos,
                    "this `as` key is a `Json` value, which has no defined "
                        ++ "equality to key on ([LRST.1.4])"),
                    "project a typed leaf first, and key on that")
                    | !.Errors]
            else if
                Type = ty_known(Known),
                lrst_1_4_key_type(Known ^ dt_leaf) = no
            then
                !:Errors = [with_hint(error_at(dv_as_non_equatable_type, Pos,
                    "this `as` key is a `" ++ leaf_name(Known ^ dt_leaf)
                        ++ "`; a key is a String, Int, Float, Bool, Date, "
                        ++ "Time, Duration or Bytes ([LRST.1.4])"),
                    "key on a scalar slot of the fact instead")
                    | !.Errors]
            else
                !:Errors = lnul_5_1_concrete(Env, Key, Type, Pos,
                    "an `as` correlation key") ++ !.Errors
            )
        )
    ).

    %@spec [LRST.1.4]
:- func lrst_1_4_key_type(leaf_kind) = bool.

lrst_1_4_key_type(lk_int) = yes.
lrst_1_4_key_type(lk_float) = yes.
lrst_1_4_key_type(lk_bool) = yes.
lrst_1_4_key_type(lk_string) = yes.
lrst_1_4_key_type(lk_bytes) = yes.
lrst_1_4_key_type(lk_time) = yes.
lrst_1_4_key_type(lk_date) = yes.
lrst_1_4_key_type(lk_duration) = yes.
lrst_1_4_key_type(lk_json) = no.
lrst_1_4_key_type(lk_interval(_)) = no.
lrst_1_4_key_type(lk_fact(_)) = no.
lrst_1_4_key_type(lk_opaque(_)) = no.

    % A bracket-indexed path is skipped: `interp_access` does not model indexing.
    %
    %@spec [LRST.1.5.1]
:- pred lrst_1_5_1_segment(type_env::in, pos::in, list(char)::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lrst_1_5_1_segment(Env, Pos, Path, !Errors) :-
    ( if
        interp_path(Path, Leading),
        interp_binding(Env, Leading),
        Segments = string.split_at_char('.', string.from_char_list(Path)),
        interp_access(Pos, Segments, Expr),
        ( json_subpath(Env, Expr)
        ; type_of_expr(Env, Expr) = ty_known(Known),
          Known ^ dt_null = nullable
        )
    then
        !:Errors = [lrst_1_5_softfail(Pos,
            "`{" ++ string.from_char_list(Path) ++ "}`") | !.Errors]
    else
        true
    ).

    %@spec [LGRA.2.9.6.8]
:- pred lgra_2_9_6_8_cached_key(type_env::in, lgra_9_3_1_expr::in,
                                list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_2_9_6_8_cached_key(Env, Expr, !Errors) :-
    ( if
        Expr = ex_call(ex_name(Callee), [ex_string(Text, Pos) | _], _),
        Callee ^ id_name = "cached"
    then
        list.foldl(cached_key_segment(Env, Pos),
            interp_site_paths(string.to_char_list(Text)), !Errors)
    else
        true
    ),
    list.foldl(lgra_2_9_6_8_cached_key(Env), expr_children(Expr), !Errors).

    %@helper
:- pred cached_key_segment(type_env::in, pos::in, list(char)::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

cached_key_segment(Env, Pos, Path, !Errors) :-
    ( if
        interp_path(Path, Leading),
        interp_binding(Env, Leading),
        Segments = string.split_at_char('.', string.from_char_list(Path)),
        interp_access(Pos, Segments, Expr),
        ( json_subpath(Env, Expr)
        ; type_of_expr(Env, Expr) = ty_known(Known),
          Known ^ dt_null = nullable
        )
    then
        !:Errors = [with_hint(error_at(dv_interp_nullable_key, Pos,
            "`{" ++ string.from_char_list(Path) ++ "}` in a `cached(...)` "
                ++ "key can be absent, and an absent segment renders as the "
                ++ "empty string, so two entities would share one cache entry "
                ++ "([LGRA.2.9.6.8])"),
            "key on a non-nullable slot")
            | !.Errors]
    else
        true
    ).

    %@helper
:- func lrst_1_5_softfail(pos, string) = diagnostic.

lrst_1_5_softfail(Pos, What) =
    with_hint(error_at(dv_as_softfail_expression, Pos,
        What ++ " in an `as` correlation key can be absent, and a key must "
            ++ "be non-nullable so per-fact identity is defined ([LRST.1.5])"),
        "project it to a guaranteed-present value first, or key on a "
            ++ "non-nullable slot").

    %@helper
:- pred json_subpath(type_env::in, lgra_9_3_1_expr::in) is semidet.

json_subpath(Env, ex_slot(Base, _, _)) :-
    ( if
        type_of_expr(Env, Base) = ty_known(Known),
        Known ^ dt_leaf = lk_json
    then
        true
    else
        json_subpath(Env, Base)
    ).

    % The site bodies of an interpolated string, the format stripped.
    %
    %@helper
:- func interp_site_paths(list(char)) = list(list(char)).

interp_site_paths(Chars) =
    list.filter_map(site_path, lgra_2_9_6_7_pieces(Chars)).

    %@helper
:- func site_path(piece) = list(char) is semidet.

site_path(p_site(Body)) = Path :-
    site_split(Body, Path, _).

%-----------------------------------------------------------------------------%
% `then` followers -- [LTHE.4.5], [LTHE.4.8], [LTHE.4.9], [LTHE.5.4]
%-----------------------------------------------------------------------------%
%
% A follower is a `then` step: one folded into the pattern above it, or an
% `alc_then` the parser could not fold because nothing positive sat above it.

    % What the previous LHS clause offers a `then` below it.
    %
    %@helper
:- type predecessor
    --->    pd_start
    ;       pd_fact
    ;       pd_negated.

    %@spec [LTHE.4.8]
    %@spec [LTHE.4.9]
    %@spec [LTHE.5.4]
:- pred lthe_4_8_followers(list(ast_lhs_clause)::in, predecessor::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lthe_4_8_followers([], _, !Errors).
lthe_4_8_followers([C | Cs], Prev, !Errors) :-
    (
        C = alc_pattern(ap_simple(_)),
        Next = pd_fact
    ;
        C = alc_pattern(ap_negated(_, _)),
        Next = pd_negated
    ;
        C = alc_pattern(ap_sequence(Latest, _, Steps, Pos)),
        ( if Latest = asl_latest, Prev \= pd_start then
            !:Errors = [with_hint(error_at(dv_interior_latest, Pos,
                "`latest` pins only a rule's first pattern ([LTHE.5.4]); "
                    ++ "this sequence is not the first clause"),
                "move the sequence to the top of the rule, or drop `latest`")
                | !.Errors]
        else
            true
        ),
        list.foldl(lthe_5_4_step_latest, Steps, !Errors),
        Next = pd_fact
    ;
        C = alc_then(Step),
        Name = body_label(Step ^ ats_body),
        (
            Prev = pd_negated,
            !:Errors = [with_hint(error_at(dv_then_after_negation,
                Step ^ ats_pos,
                "`then " ++ Name ++ "` follows a negated pattern, which "
                    ++ "binds no fact to read `ts` from ([LTHE.4.9])"),
                "put a positive pattern between the `no` and the `then`")
                | !.Errors]
        ;
            Prev = pd_start,
            !:Errors = [with_hint(error_at(dv_then_no_predecessor,
                Step ^ ats_pos,
                "`then " ++ Name ++ "` has no pattern before it to follow "
                    ++ "([LTHE.4.8])"),
                "a sequence opens with an ordinary pattern; `then` joins "
                    ++ "the next one to it")
                | !.Errors]
        ;
            Prev = pd_fact
        ),
        lthe_5_4_step_latest(Step, !Errors),
        Next = pd_fact
    ),
    lthe_4_8_followers(Cs, Next, !Errors).

    %@helper
:- pred lthe_5_4_step_latest(ast_then_step::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

lthe_5_4_step_latest(Step, !Errors) :-
    (
        Step ^ ats_latest = asl_latest,
        !:Errors = [with_hint(error_at(dv_interior_latest, Step ^ ats_pos,
            "`then latest " ++ body_label(Step ^ ats_body) ++ "`: `latest` "
                ++ "modifies only the first pattern of a sequence "
                ++ "([LTHE.5.4])"),
            "drop this `latest`; to pin the anchor, write `latest` before "
                ++ "the sequence's first pattern")
            | !.Errors]
    ;
        Step ^ ats_latest = asl_plain
    ).

    %@helper
:- func body_label(ast_pattern_body) = string.

body_label(Body) = Label :-
    (
        Body ^ apb_type = atr_bare(Id),
        Label = Id ^ id_name
    ;
        Body ^ apb_type = atr_qualified(_, Id),
        Label = Id ^ id_name
    ).

    % Presence only: a `ts` of the wrong type is `lfac_9_1_ts_time`'s.
    %
    %@spec [LTHE.4.5]
:- pred lthe_4_5_sequence_ts(resolved_file::in, ast_lhs_clause::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

lthe_4_5_sequence_ts(RF, Clause, !Errors) :-
    (
        ( Clause = alc_pattern(ap_simple(_))
        ; Clause = alc_pattern(ap_negated(_, _))
        )
    ;
        Clause = alc_pattern(ap_sequence(_, Head, Steps, _)),
        lthe_4_5_body_ts(RF, Head, !Errors),
        list.foldl((pred(S::in, E0::in, E::out) is det :-
            lthe_4_5_body_ts(RF, S ^ ats_body, E0, E)), Steps, !Errors)
    ;
        Clause = alc_then(Step),
        lthe_4_5_body_ts(RF, Step ^ ats_body, !Errors)
    ).

    %@helper
:- pred lthe_4_5_body_ts(resolved_file::in, ast_pattern_body::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

lthe_4_5_body_ts(RF, Body, !Errors) :-
    ( if
        lgra_22_4_schema_of(RF, Body ^ apb_type, Schema),
        not declares_ts(Schema ^ as_fields)
    then
        Name = type_ref_name(Body ^ apb_type),
        !:Errors = [with_hint(error_at(dv_within_no_ts_slot, Body ^ apb_pos,
            "schema `" ++ Name ++ "` is in a `then` sequence and declares "
                ++ "no `ts` slot ([LTHE.4.5])"),
            "the sequence compares each step's `ts` with its predecessor's; "
                ++ "add `ts: Time` to schema `" ++ Name ++ "`")
            | !.Errors]
    else
        true
    ).

    %@helper
:- pred declares_ts(list(ast_field)::in) is semidet.

declares_ts(Fields) :-
    list.member(F, Fields),
    F ^ af_name ^ id_name = "ts".

%-----------------------------------------------------------------------------%
% Finance is not in 1.0.0 -- LUNI.13.11
%-----------------------------------------------------------------------------%
%
% Importing `units.currency`, a `unit fx_pair` declaration, `.to_currency(...)`,
% and the `.round(...)` / `.round_to(...)` methods, on any receiver. Runs on the
% built AST, before any library loads. Interpolation bodies are not walked.

finance_deferred(Ast) =
    list.condense(list.map(finance_in_decl, Ast ^ af_decls)).

    %@helper
:- func finance_in_decl(ast_decl) = list(diagnostic).

finance_in_decl(Decl) = Ds :-
    ( if
        Decl = ad_import(I),
        list.map(( func(Id) = Id ^ id_name ), I ^ ai_path) =
            ["units", "currency"]
    then
        Ds = [finance_refusal(I ^ ai_pos,
            "the `units.currency` library is finance")]
    else if
        Decl = ad_unit(U),
        U = au_fx_pair(Id, _, _, _, _, _, _, _)
    then
        Ds = [finance_refusal(Id ^ id_pos,
            "a `unit fx_pair` declaration is finance")]
    else if Decl = ad_rule(R) then
        Ds = list.condense(list.map(finance_in_expr, rule_expressions(R)))
    else if
        Decl = ad_const(C),
        ( C ^ acn_form = acf_value(_, E)
        ; C ^ acn_form = acf_colon_literal(E)
        )
    then
        Ds = finance_in_expr(E)
    else
        Ds = []
    ).

    %@helper
:- func finance_in_expr(lgra_9_3_1_expr) = list(diagnostic).

finance_in_expr(E) = Here ++ Below :-
    ( if
        E = ex_call(ex_slot(_, Method, _), _, _),
        finance_method(Method ^ id_name)
    then
        Here = [finance_refusal(Method ^ id_pos,
            "`." ++ Method ^ id_name ++ "(...)` is finance")]
    else
        Here = []
    ),
    Below = list.condense(list.map(finance_in_expr, expr_children(E))).

    %@helper
:- pred finance_method(string::in) is semidet.

finance_method("round").
finance_method("round_to").
finance_method("to_currency").

    %@helper
:- func finance_refusal(pos, string) = diagnostic.

finance_refusal(Pos, What) =
    with_hint(error_at(dv_finance_deferred, Pos,
        What ++ ", and finance is not in this edition of DS"),
        "currency, exchange-rate pairs and currency rounding return in a "
            ++ "later release; `round(x)` the function is not finance and "
            ++ "is available").

%-----------------------------------------------------------------------------%
% A rule's expressions
%-----------------------------------------------------------------------------%

    % Every expression a rule carries, in the positions an author writes one.
    %
    %@helper
:- func rule_expressions(ast_rule) = list(lgra_9_3_1_expr).

rule_expressions(Rule) =
    rule_predicates(Rule)
        ++ list.map(let_expression, rule_let_bindings(Rule))
        ++ list.condense(list.map(action_expressions, Rule ^ ar_rhs ^ arr_actions))
        ++ list.condense(list.map(after_expressions, Rule ^ ar_rhs ^ arr_afters)).

    %@helper
:- func let_expression(ast_let_binding) = lgra_9_3_1_expr.

let_expression(alb_simple(_, _, E, _)) = E.
let_expression(alb_capture(_, E, _)) = E.

    %@helper
:- func action_expressions(ast_action) = list(lgra_9_3_1_expr).

action_expressions(Action) = Exprs :-
    Block = Action ^ aac_block,
    (
        Block = aab_none,
        BlockExprs = []
    ;
        Block = aab_kwargs(Args),
        BlockExprs = list.filter_map(kwarg_value, Args)
    ;
        Block = aab_call(Args, Continuations),
        BlockExprs = list.filter_map(kwarg_value, Args)
            ++ list.condense(list.map(continuation_expressions, Continuations))
    ),
    Exprs = list.filter_map(kwarg_value, Action ^ aac_args) ++ BlockExprs
        ++ optional(Action ^ aac_as).

    %@helper
:- func kwarg_value(ast_action_arg) = lgra_9_3_1_expr is semidet.

kwarg_value(aaa_kwarg(_, E, _)) = E.

    %@helper
:- func continuation_expressions(ast_continuation) = list(lgra_9_3_1_expr).

continuation_expressions(acont_on(E, Actions, _)) =
    [E | list.condense(list.map(action_expressions, Actions))].
continuation_expressions(acont_timeout(E, Actions, _)) =
    [E | list.condense(list.map(action_expressions, Actions))].
continuation_expressions(acont_error(_, Actions, _)) =
    list.condense(list.map(action_expressions, Actions)).

    %@helper
:- func after_expressions(ast_after_clause) = list(lgra_9_3_1_expr).

after_expressions(After) =
    [After ^ aaf_duration]
        ++ optional(After ^ aaf_as)
        ++ list.condense(list.map(action_expressions, After ^ aaf_actions))
        ++ list.condense(list.map(after_expressions, After ^ aaf_nested)).

%-----------------------------------------------------------------------------%
% What a rule's names are used for -- [LGRA.8.6], [LEXP.9.6.1], [LUNI.9.2]
%-----------------------------------------------------------------------------%

    % The reference set over-approximates: a reference this walk missed would refuse
    % a legal program, so it takes every name the rule could be using one through.
    %
    %@spec [LGRA.8.6]
:- pred lgra_8_6_unreferenced_bindings(ast_rule::in, list(diagnostic)::out)
    is det.

lgra_8_6_unreferenced_bindings(Rule, Errors) :-
    Refs = rule_references(Rule),
    Written = list.condense(list.map(clause_bindings, Rule ^ ar_lhs)),
    Captured = list.condense(list.map((func(C) = C ^ acap_names),
        rule_captures(Rule))),
    Errors = list.filter_map(unreferenced(Rule, Refs), Written)
        ++ list.filter_map(unreferenced_capture(Rule, Refs), Captured).

    % Every `where` but the pattern's own, a `let` and an action. A name also bound
    % positively, by a `let` or by a capture is another check's. `withdraw a` is not
    % counted: [LGRA.10.1] has its own code.
    %
    %@spec [LGRA.8.6]
:- pred lgra_8_6_negated_binding_scope(ast_rule::in, list(diagnostic)::out)
    is det.

lgra_8_6_negated_binding_scope(Rule, Errors) :-
    Lhs = Rule ^ ar_lhs,
    Negated = list.map(id_text, list.condense(list.map(negated_binding, Lhs))),
    Other = list.map(id_text,
        list.condense(list.map(body_binding,
            list.condense(list.map(positive_bodies, Lhs))))
        ++ list.condense(list.map(bound_let_names, rule_let_bindings(Rule)))
        ++ list.condense(list.map((func(C) = C ^ acap_names),
            rule_captures(Rule)))),
    Names = set.difference(set.list_to_set(Negated), set.list_to_set(Other)),
    Rhs = Rule ^ ar_rhs,
    Sites = list.condense(list.map(negated_scope_clause_sites, Lhs))
        ++ list.condense(list.map(
            (func(B) = expr_sites(let_expression(B))),
            rule_let_bindings(Rule)))
        ++ list.condense(list.map(action_sites, Rhs ^ arr_actions))
        ++ list.condense(list.map(after_sites, Rhs ^ arr_afters)),
    Errors = list.filter_map(negated_out_of_scope(Names), Sites).

    %@helper
:- func negated_binding(ast_lhs_clause) = list(ident).

negated_binding(Clause) =
    ( if Clause = alc_pattern(ap_negated(B, _)) then body_binding(B) else [] ).

    %@helper
:- func negated_scope_clause_sites(ast_lhs_clause) = list({string, pos}).

negated_scope_clause_sites(alc_then(S)) = where_sites(S ^ ats_body).
negated_scope_clause_sites(alc_pattern(ap_simple(B))) = where_sites(B).
negated_scope_clause_sites(alc_pattern(ap_negated(B, _))) = Sites :-
    Own = list.map(id_text, body_binding(B)),
    Sites = list.filter(
        ( pred(Site::in) is semidet :-
            Site = {Name, _},
            not list.member(Name, Own)
        ), where_sites(B)).
negated_scope_clause_sites(alc_pattern(ap_sequence(_, Head, Steps, _))) =
    where_sites(Head)
        ++ list.condense(list.map((func(S) = where_sites(S ^ ats_body)),
            Steps)).

    %@helper
:- func where_sites(ast_pattern_body) = list({string, pos}).

where_sites(Body) =
    ( if Body ^ apb_where = yes(E) then expr_sites(E) else [] ).

    %@helper
:- func action_sites(ast_action) = list({string, pos}).

action_sites(Action) = Log ++ Args ++ As ++ Block :-
    ( if Action ^ aac_head = aah_log(_, Text) then
        Log = text_sites(Text, Action ^ aac_pos)
    else
        Log = []
    ),
    Args = list.condense(list.map(arg_sites, Action ^ aac_args)),
    ( if Action ^ aac_as = yes(AsE) then As = expr_sites(AsE) else As = [] ),
    B = Action ^ aac_block,
    (
        B = aab_none,
        Block = []
    ;
        B = aab_kwargs(Kwargs),
        Block = list.condense(list.map(arg_sites, Kwargs))
    ;
        B = aab_call(Kwargs, Continuations),
        Block = list.condense(list.map(arg_sites, Kwargs))
            ++ list.condense(list.map(continuation_sites, Continuations))
    ).

    %@helper
:- func arg_sites(ast_action_arg) = list({string, pos}).

arg_sites(aaa_kwarg(_, E, _)) = expr_sites(E).
arg_sites(aaa_flag(_)) = [].

    %@helper
:- func continuation_sites(ast_continuation) = list({string, pos}).

continuation_sites(acont_on(E, Actions, _)) =
    expr_sites(E) ++ list.condense(list.map(action_sites, Actions)).
continuation_sites(acont_timeout(E, Actions, _)) =
    expr_sites(E) ++ list.condense(list.map(action_sites, Actions)).
continuation_sites(acont_error(_, Actions, _)) =
    list.condense(list.map(action_sites, Actions)).

    %@helper
:- func after_sites(ast_after_clause) = list({string, pos}).

after_sites(After) =
    expr_sites(After ^ aaf_duration)
        ++ ( if After ^ aaf_as = yes(AsE) then expr_sites(AsE) else [] )
        ++ list.condense(list.map(action_sites, After ^ aaf_actions))
        ++ list.condense(list.map(after_sites, After ^ aaf_nested)).

    %@helper
:- func expr_sites(lgra_9_3_1_expr) = list({string, pos}).

expr_sites(E) = Here ++ list.condense(list.map(expr_sites, expr_children(E))) :-
    ( if E = ex_name(Id) then
        Here = [{Id ^ id_name, Id ^ id_pos}]
    else if E = ex_string(Text, Pos) then
        Here = text_sites(Text, Pos)
    else
        Here = []
    ).

    % The leading name of each interpolation site in `Text`, at `Pos`.
    %
    %@helper
:- func text_sites(string, pos) = list({string, pos}).

text_sites(Text, Pos) =
    list.filter_map(
        ( func(Piece) = {Lead, Pos} is semidet :-
            Piece = p_site(Body),
            site_split(Body, Path, _),
            lgra_2_9_6_1_path(Path, Lead)
        ), lgra_2_9_6_7_pieces(string.to_char_list(Text))).

    %@helper
:- func negated_out_of_scope(set(string), {string, pos}) = diagnostic
    is semidet.

negated_out_of_scope(Names, Site) = D :-
    Site = {Name, Pos},
    set.contains(Names, Name),
    D = with_hint(error_at(dv_negated_binding_out_of_scope, Pos,
        "`" ++ Name ++ "` is a negated pattern's binding, which is in scope "
            ++ "in that pattern's own `where` alone: it names a fact whose "
            ++ "absence the pattern tests, so there is nothing here to read "
            ++ "([LGRA.8.6])"),
        "read it only in the `no` pattern's own `where`, or bind the fact in "
            ++ "a positive pattern if the rule needs its slots").

    %@helper
:- func unreferenced_capture(ast_rule, set(string), ident) = diagnostic
    is semidet.

unreferenced_capture(Rule, Refs, Id) = D :-
    not set.member(Id ^ id_name, Refs),
    D = with_hint(error_at(dv_unreferenced_binding, Id ^ id_pos,
        "capture `" ++ Id ^ id_name ++ "` in rule `"
            ++ Rule ^ ar_name ^ id_name ++ "` is never referenced "
            ++ "([LGRA.8.6])"),
        "use it, or make the group non-capturing with `(?:...)` and drop "
            ++ "the name").

    % A `where` may read the captures of its own pattern and of every earlier one.
    % Pattern bindings are not checked here.
    %
    %@spec [LGRA.8.6]
:- pred lreg_4_1_capture_order(ast_rule::in, list(diagnostic)::out) is det.

lreg_4_1_capture_order(Rule, Errors) :-
    AllCaptured = set.list_to_set(list.map(id_text, list.condense(
        list.map((func(C) = C ^ acap_names), rule_captures(Rule))))),
    list.foldl2(capture_order_clause(AllCaptured), Rule ^ ar_lhs,
        set.init, _, [], RevErrors),
    Errors = reverse(RevErrors).

    %@helper
:- pred capture_order_clause(set(string)::in, ast_lhs_clause::in,
                             set(string)::in, set(string)::out,
                             list(diagnostic)::in, list(diagnostic)::out)
    is det.

capture_order_clause(All, Clause, !Bound, !Errors) :-
    (
        Clause = alc_then(S),
        capture_order_body(All, S ^ ats_body, !Bound, !Errors)
    ;
        Clause = alc_pattern(P),
        (
            P = ap_simple(B),
            capture_order_body(All, B, !Bound, !Errors)
        ;
            P = ap_negated(B, _),
            capture_order_body(All, B, !Bound, !Errors)
        ;
            P = ap_sequence(_, Head, Steps, _),
            capture_order_body(All, Head, !Bound, !Errors),
            list.foldl2(
                (pred(S::in, B0::in, B1::out, E0::in, E1::out) is det :-
                    capture_order_body(All, S ^ ats_body, B0, B1, E0, E1)),
                Steps, !Bound, !Errors)
        )
    ).

    %@helper
:- pred capture_order_body(set(string)::in, ast_pattern_body::in,
                           set(string)::in, set(string)::out,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

capture_order_body(All, Body, !Bound, !Errors) :-
    ( if Body ^ apb_capture = yes(C) then
        set.insert_list(list.map(id_text, C ^ acap_names), !Bound)
    else
        true
    ),
    capture_order_expr(All, !.Bound, Body ^ apb_where, !Errors).

    %@helper
:- pred capture_order_expr(set(string)::in, set(string)::in,
                           maybe(lgra_9_3_1_expr)::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

capture_order_expr(_, _, no, !Errors).
capture_order_expr(All, Bound, yes(E), !Errors) :-
    list.foldl(
        (pred(Id::in, E0::in, E1::out) is det :-
            Name = Id ^ id_name,
            ( if set.contains(All, Name), not set.contains(Bound, Name) then
                E1 = [with_hint(error_at(dv_unknown_binding, Id ^ id_pos,
                    "capture `" ++ Name ++ "` is read before the pattern "
                        ++ "that binds it ([LGRA.8.6])"),
                    "a `where` reads the captures of its own pattern and of "
                        ++ "earlier ones; move this pattern below it")
                    | E0]
            else
                E1 = E0
            )),
        expr_names(E), !Errors).

    %@helper
:- func unreferenced(ast_rule, set(string), ident) = diagnostic is semidet.

unreferenced(Rule, Refs, Id) = D :-
    not set.member(Id ^ id_name, Refs),
    D = with_hint(error_at(dv_unreferenced_binding, Id ^ id_pos,
        "pattern binding `" ++ Id ^ id_name ++ "` in rule `"
            ++ Rule ^ ar_name ^ id_name ++ "` is never referenced "
            ++ "([LGRA.8.6])"),
        "omit it -- a pattern with no binding is well-formed ([LGRA.8.1])").

    %@helper
:- func rule_references(ast_rule) = set(string).

rule_references(Rule) = Refs :-
    list.foldl(lhs_references, Rule ^ ar_lhs, set.init, Refs0),
    list.foldl(modifier_references, Rule ^ ar_modifiers, Refs0, Refs1),
    Rhs = Rule ^ ar_rhs,
    list.foldl(let_references, Rhs ^ arr_lets, Refs1, Refs2),
    list.foldl(action_references, Rhs ^ arr_actions, Refs2, Refs3),
    list.foldl(after_references, Rhs ^ arr_afters, Refs3, Refs).

    %@helper
:- pred lhs_references(ast_lhs_clause::in, set(string)::in, set(string)::out)
    is det.

lhs_references(alc_then(S), !Refs) :-
    step_references(S, !Refs).
lhs_references(alc_pattern(P), !Refs) :-
    (
        P = ap_simple(B),
        body_references(B, !Refs)
    ;
        P = ap_negated(B, _),
        body_references(B, !Refs)
    ;
        P = ap_sequence(_, Head, Steps, _),
        body_references(Head, !Refs),
        list.foldl(step_references, Steps, !Refs)
    ).

    %@helper
:- pred step_references(ast_then_step::in, set(string)::in, set(string)::out)
    is det.

step_references(Step, !Refs) :-
    body_references(Step ^ ats_body, !Refs),
    token_references(Step ^ ats_within, !Refs).

    %@helper
:- pred body_references(ast_pattern_body::in, set(string)::in,
                        set(string)::out) is det.

body_references(Body, !Refs) :-
    ( if Body ^ apb_within = yes(Toks) then
        token_references(Toks, !Refs)
    else
        true
    ),
    maybe_expr_references(Body ^ apb_where, !Refs).

    %@helper
:- pred maybe_expr_references(maybe(lgra_9_3_1_expr)::in, set(string)::in,
                              set(string)::out) is det.

maybe_expr_references(no, !Refs).
maybe_expr_references(yes(E), !Refs) :-
    expr_references(E, !Refs).

    %@helper
:- pred modifier_references(ast_rule_modifier::in, set(string)::in,
                            set(string)::out) is det.

modifier_references(arm_cooldown(Toks, _), !Refs) :-
    token_references(Toks, !Refs).
modifier_references(arm_by(ark_none, _), !Refs).
modifier_references(arm_by(ark_paths(Paths), _), !Refs) :-
    list.foldl((pred(P::in, R0::in, R::out) is det :-
            set.insert(P ^ akp_binding ^ id_name, R0, R)),
        Paths, !Refs).

    %@helper
:- pred let_references(ast_let_decl::in, set(string)::in, set(string)::out)
    is det.

let_references(Decl, !Refs) :-
    list.foldl(let_binding_references, Decl ^ ald_bindings, !Refs).

    %@helper
:- pred let_binding_references(ast_let_binding::in, set(string)::in,
                               set(string)::out) is det.

let_binding_references(alb_simple(_, _, E, _), !Refs) :-
    expr_references(E, !Refs).
let_binding_references(alb_capture(_, E, _), !Refs) :-
    expr_references(E, !Refs).

    %@helper
:- pred action_references(ast_action::in, set(string)::in, set(string)::out)
    is det.

action_references(Action, !Refs) :-
    ( if Action ^ aac_head = aah_log(_, Text) then
        interpolation_references(Text, !Refs)
    else
        true
    ),
    % `withdraw t` carries its binding in the head, as a bare `ident`.
    ( if Action ^ aac_head = aah_withdraw(Binding) then
        set.insert(Binding ^ id_name, !Refs)
    else
        true
    ),
    list.foldl(arg_references, Action ^ aac_args, !Refs),
    maybe_expr_references(Action ^ aac_as, !Refs),
    ( if Action ^ aac_as = yes(ex_string(AsText, _)) then
        interpolation_references(AsText, !Refs)
    else
        true
    ),
    Block = Action ^ aac_block,
    (
        Block = aab_none
    ;
        Block = aab_kwargs(Args),
        list.foldl(arg_references, Args, !Refs)
    ;
        Block = aab_call(Args, Continuations),
        list.foldl(arg_references, Args, !Refs),
        list.foldl(continuation_references, Continuations, !Refs)
    ).

    %@helper
:- pred arg_references(ast_action_arg::in, set(string)::in, set(string)::out)
    is det.

arg_references(aaa_kwarg(_, E, _), !Refs) :-
    expr_references(E, !Refs).
arg_references(aaa_flag(_), !Refs).

    %@helper
:- pred continuation_references(ast_continuation::in, set(string)::in,
                                set(string)::out) is det.

continuation_references(acont_on(E, Actions, _), !Refs) :-
    expr_references(E, !Refs),
    list.foldl(action_references, Actions, !Refs).
continuation_references(acont_timeout(E, Actions, _), !Refs) :-
    expr_references(E, !Refs),
    list.foldl(action_references, Actions, !Refs).
continuation_references(acont_error(_, Actions, _), !Refs) :-
    list.foldl(action_references, Actions, !Refs).

    %@helper
:- pred after_references(ast_after_clause::in, set(string)::in,
                         set(string)::out) is det.

after_references(After, !Refs) :-
    expr_references(After ^ aaf_duration, !Refs),
    maybe_expr_references(After ^ aaf_as, !Refs),
    list.foldl(action_references, After ^ aaf_actions, !Refs),
    list.foldl(after_references, After ^ aaf_nested, !Refs).

    %@helper
:- pred expr_references(lgra_9_3_1_expr::in, set(string)::in,
                        set(string)::out) is det.

expr_references(E, !Refs) :-
    ( if E = ex_name(Id) then
        set.insert(Id ^ id_name, !Refs)
    else if E = ex_string(Text, _) then
        interpolation_references(Text, !Refs)
    else
        true
    ),
    list.foldl(expr_references, expr_children(E), !Refs).

    %@helper
:- pred token_references(list(positioned)::in, set(string)::in,
                         set(string)::out) is det.

token_references(Toks, !Refs) :-
    list.foldl(token_reference, Toks, !Refs).

    %@helper
:- pred token_reference(positioned::in, set(string)::in, set(string)::out)
    is det.

token_reference(P, !Refs) :-
    ( if P ^ tk_tok = name(N) then
        set.insert(N, !Refs)
    else
        true
    ).

    %@helper
:- pred interpolation_references(string::in, set(string)::in,
                                 set(string)::out) is det.

interpolation_references(Text, !Refs) :-
    Pieces = lgra_2_9_6_7_pieces(string.to_char_list(Text)),
    list.foldl(piece_references, Pieces, !Refs).

    %@helper
:- pred piece_references(piece::in, set(string)::in, set(string)::out) is det.

piece_references(Piece, !Refs) :-
    ( if Piece = p_site(Body) then
        set.insert_list(site_names(Body), !Refs)
    else
        true
    ).

    %@helper
:- func expr_children(lgra_9_3_1_expr) = list(lgra_9_3_1_expr).

expr_children(ex_int(_, _)) = [].
expr_children(ex_float(_, _)) = [].
expr_children(ex_string(_, _)) = [].
expr_children(ex_unit(_, _, _)) = [].
expr_children(ex_bool(_, _)) = [].
expr_children(ex_null(_)) = [].
expr_children(ex_name(_)) = [].
expr_children(ex_unary(_, E, _)) = [E].
expr_children(ex_not(E, _)) = [E].
expr_children(ex_binary(_, L, R, _)) = [L, R].
expr_children(ex_compare(First, Steps, _)) =
    [First | list.map(step_right, Steps)].
expr_children(ex_is(E, _, _, _)) = [E].
expr_children(ex_slot(E, _, _)) = [E].
expr_children(ex_index(E, I, _)) = [E, I].
expr_children(ex_call(Callee, Args, _)) = [Callee | Args].
expr_children(ex_cast(E, _, _, _)) = [E].
expr_children(ex_match(E, _, _, _, _)) = [E].

    %@helper
:- func step_right(lgra_9_3_2_compare_step) = lgra_9_3_1_expr.

step_right(Step) = Step ^ cs_right.

    % `cached(key)` alone: a time-dependent read is `ltim_2_6_2_clock_where`'s.
    % Positive patterns only, in the count and in the walk.
    %
    %@spec [LEXP.9.6.1]
:- pred lexp_9_6_1_nonfact_where(ast_rule::in, list(diagnostic)::out) is det.

lexp_9_6_1_nonfact_where(Rule, Errors) :-
    Positive = list.foldl(positive_count, Rule ^ ar_lhs, 0),
    ( if
        Positive > 1,
        first_nonfact(positive_wheres(Rule ^ ar_lhs)) = yes(Read - Pos)
    then
        Errors = [with_hint(error_at(dv_nonfact_where_multipattern, Pos,
            "rule `" ++ Rule ^ ar_name ^ id_name ++ "`: this `where` reads `"
                ++ Read ++ "`, whose value is not a function of the matched "
                ++ "facts, on a rule with " ++ string.from_int(Positive)
                ++ " positive patterns; the join test would be retained and "
                ++ "could stop the rule firing ([LEXP.9.6.1])"),
            "give the gated check its own single-positive-pattern rule; if "
                ++ "the read only feeds an action, a `let` on the right-hand "
                ++ "side carries it, but a `let` cannot decide whether the "
                ++ "rule fires")]
    else
        Errors = []
    ).

    % The classifiers are `dsc.typecheck`'s, which the lowering's re-drive uses too. A
    % simple positive pattern's `within` counts; a `then` step's is between facts.
    % `dwell` is a reserved word, so every `.dwell` read is the alias.
    %
    %@spec [LTIM.2.6.2]
    %@spec [LTIM.2.6.1]
    %@spec [LTIM.2.4.1]
:- pred ltim_2_6_2_clock_where(type_env::in, ast_rule::in,
                               list(diagnostic)::out) is det.

ltim_2_6_2_clock_where(Env, Rule, Errors) :-
    Positive = list.foldl(positive_count, Rule ^ ar_lhs, 0),
    ( if
        Positive > 1,
        first_pattern_within(Rule ^ ar_lhs) = yes(Pos)
    then
        Errors = [with_hint(error_at(dv_now_multipattern_unsupported, Pos,
            "rule `" ++ Rule ^ ar_name ^ id_name ++ "`: this pattern's "
                ++ "`within` window depends on the clock, on a rule with "
                ++ string.from_int(Positive) ++ " positive patterns; v1 "
                ++ "re-evaluates a clock-dependent condition only on a "
                ++ "single-positive-pattern rule ([LTIM.2.7.1], [LTIM.2.6.2])"),
            "give the windowed pattern its own single-pattern rule, or, to "
                ++ "order two facts, write `X then Y within <dur>`, whose "
                ++ "window is between the facts and needs no clock")]
    else if
        Positive > 1,
        first_time_read(Env, positive_wheres(Rule ^ ar_lhs)) = yes(Read - Pos)
    then
        Errors = [with_hint(error_at(dv_now_multipattern_unsupported, Pos,
            "rule `" ++ Rule ^ ar_name ^ id_name ++ "`: this `where` reads `"
                ++ Read ++ "`, whose answer can change with no change to the "
                ++ "matched facts, on a rule with "
                ++ string.from_int(Positive) ++ " positive patterns; v1 "
                ++ "re-evaluates a time-dependent condition only on a "
                ++ "single-positive-pattern rule ([LTIM.2.4.1], [LTIM.2.6.2])"),
            "give the time-dependent check its own single-pattern rule")]
    else
        Errors = []
    ).

    %@helper
:- func first_pattern_within(list(ast_lhs_clause)) = maybe(pos).

first_pattern_within([]) = no.
first_pattern_within([C | Cs]) = Found :-
    ( if
        C = alc_pattern(ap_simple(Body)),
        Body ^ apb_within = yes([Tok | _])
    then
        Found = yes(Tok ^ tk_pos)
    else
        Found = first_pattern_within(Cs)
    ).

    %@helper
:- func first_time_read(type_env, list(lgra_9_3_1_expr))
    = maybe(pair(string, pos)).

first_time_read(_, []) = no.
first_time_read(Env, [E | Es]) = Found :-
    ( if time_read(Env, E, Read, Pos) then
        Found = yes(Read - Pos)
    else if first_time_read(Env, expr_children(E)) = yes(Inner) then
        Found = yes(Inner)
    else
        Found = first_time_read(Env, Es)
    ).

    %@helper
:- pred time_read(type_env::in, lgra_9_3_1_expr::in, string::out, pos::out)
    is semidet.

time_read(Env, E, Read, Pos) :-
    ( if
        E = ex_call(ex_name(Id), [], CallPos),
        ( Id ^ id_name = "now" ; Id ^ id_name = "monotonic_ns" )
    then
        Read = Id ^ id_name ++ "()",
        Pos = CallPos
    else if
        E = ex_slot(_, Id, SlotPos),
        Id ^ id_name = "dwell"
    then
        Read = "dwell",
        Pos = SlotPos
    else if
        ltim_2_4_1_series_read(Env, E)
    then
        ( if E = ex_slot(_, Id, SlotPos) then
            Read = Id ^ id_name,
            Pos = SlotPos
        else if E = ex_call(ex_name(Id), _, CallPos) then
            Read = Id ^ id_name ++ "(...)",
            Pos = CallPos
        else
            fail
        )
    else
        ltim_2_4_1_zone_read(Env, E),
        E = ex_call(ex_slot(_, Member, _), _, CallPos),
        Read = "." ++ Member ^ id_name ++ "(...)",
        Pos = CallPos
    ).

    %@helper
:- func positive_count(ast_lhs_clause, int) = int.

positive_count(alc_then(_), N) = N + 1.
positive_count(alc_pattern(ap_simple(_)), N) = N + 1.
positive_count(alc_pattern(ap_negated(_, _)), N) = N.
positive_count(alc_pattern(ap_sequence(_, _, Steps, _)), N) =
    N + 1 + list.length(Steps).

    %@helper
:- func positive_wheres(list(ast_lhs_clause)) = list(lgra_9_3_1_expr).

positive_wheres(Clauses) =
    list.condense(list.map(clause_positive_wheres, Clauses)).

    %@helper
:- func clause_positive_wheres(ast_lhs_clause) = list(lgra_9_3_1_expr).

clause_positive_wheres(alc_then(S)) = step_where(S).
clause_positive_wheres(alc_pattern(ap_simple(B))) = optional(B ^ apb_where).
clause_positive_wheres(alc_pattern(ap_negated(_, _))) = [].
clause_positive_wheres(alc_pattern(ap_sequence(_, Head, Steps, _))) =
    optional(Head ^ apb_where)
        ++ list.condense(list.map(step_where, Steps)).

    %@helper
:- func step_where(ast_then_step) = list(lgra_9_3_1_expr).

step_where(Step) = optional(Step ^ ats_body ^ apb_where).

    %@helper
:- func optional(maybe(lgra_9_3_1_expr)) = list(lgra_9_3_1_expr).

optional(no) = [].
optional(yes(E)) = [E].

    %@helper
:- func first_nonfact(list(lgra_9_3_1_expr)) = maybe(pair(string, pos)).

first_nonfact([]) = no.
first_nonfact([E | Es]) = Found :-
    ( if E = ex_call(ex_name(Id), _, Pos), Id ^ id_name = "cached" then
        Found = yes("cached(...)" - Pos)
    else if first_nonfact(expr_children(E)) = yes(Inner) then
        Found = yes(Inner)
    else
        Found = first_nonfact(Es)
    ).

    % The gate is a value whose dimension cannot be stated: `luni_9_1_agg_type` types
    % `integral` `ty_unknown`, and so does arithmetic over it. Any unit symbol answers
    % it.
    %
    %@spec [LUNI.9.2]
:- pred luni_9_2_unannotated(type_env::in, ident::in, lgra_9_3_1_expr::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

luni_9_2_unannotated(Env, Name, Expr, !Errors) :-
    ( if
        type_of_expr(Env, Expr) = ty_unknown,
        first_unit_changing_read(Env, [Expr]) = yes({Agg, Unit, At})
    then
        !:Errors = [with_hint(error_at(dv_dim_agg_unannotated, At,
            "`let " ++ Name ^ id_name ++ "` reads `" ++ Agg ++ "` of a `"
                ++ Unit ++ "` slot, which changes its dimension, and carries "
                ++ "no annotation ([LUNI.9.2])"),
            "declare a compound `unit dimension` for the result and annotate "
                ++ "the `let` with one of its units: `let " ++ Name ^ id_name
                ++ ": <unit> = ...`") | !.Errors]
    else
        true
    ).

    %@helper
:- func first_unit_changing_read(type_env, list(lgra_9_3_1_expr))
    = maybe({string, string, pos}).

first_unit_changing_read(_, []) = no.
first_unit_changing_read(Env, [E | Es]) = Found :-
    ( if
        luni_9_2_unit_changing_read(Env, E, Agg, Unit),
        ( E = ex_slot(_, _, At) ; E = ex_call(_, _, At) )
    then
        Found = yes({Agg, Unit, At})
    else if first_unit_changing_read(Env, expr_children(E)) = yes(Inner) then
        Found = yes(Inner)
    else
        Found = first_unit_changing_read(Env, Es)
    ).

    % A `let` RHS, walked in the environment its annotation earns it.
    %
    %@spec [LUNI.8.4]
:- pred luni_8_4_let_binding(resolved_file::in, type_env::in,
                             ast_let_binding::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

luni_8_4_let_binding(RF, Env, Binding, !Errors) :-
    (
        Binding = alb_simple(Name, Annotation, Expr, Pos),
        (
            Annotation = yes(Ann),
            Walk = Env ^ te_ambiguity := da_annotated,
            Concrete = lnul_5_1_annotation(Name, Ann, Pos),
            Declared = yes(Ann)
        ;
            Annotation = no,
            Walk = Env,
            Concrete = no,
            Declared = no
        )
    ;
        Binding = alb_capture(_, Expr, _),
        Walk = Env,
        Concrete = no,
        Declared = no
    ),
    typed_expr(RF, Walk, Expr, !Errors),
    (
        Declared = yes(Annotated),
        luni_8_6_annotation(Walk, Annotated, Expr, !Errors)
    ;
        Declared = no,
        ( if Binding = alb_simple(Bound, _, _, _) then
            luni_9_2_unannotated(Walk, Bound, Expr, !Errors)
        else
            true
        )
    ),
    (
        Concrete = yes(Described - At),
        !:Errors = lnul_5_1_concrete(Walk, Expr, type_of_expr(Walk, Expr), At,
            Described) ++ !.Errors
    ;
        Concrete = no
    ).

    % `ty_error` on the RHS is not "untyped": `typed_expr` has reported it.
    %
    %@spec [LUNI.8.6]
    %@spec [LUNI.7.5]
:- pred luni_8_6_annotation(type_env::in, ast_annotation::in,
                             lgra_9_3_1_expr::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

luni_8_6_annotation(Env, Ann, Expr, !Errors) :-
    Id = Ann ^ aan_type,
    Name = Id ^ id_name,
    Types = Env ^ te_file ^ rf_types,
    RHS = type_of_expr(Env, Expr),
    ( if map.search(Env ^ te_file ^ rf_unit_alias, Name, Canonical) then
        !:Errors = [with_hint(error_at(dv_let_bad_annotation, Id ^ id_pos,
            "`" ++ Name ++ "` is an alias, and a `let` annotation takes the "
                ++ "canonical unit symbol (LUNI.8.6, [LUNI.7.5])"),
            "write `" ++ Canonical ^ id_name ++ "`") | !.Errors]
    else if
        map.search(Types, Name, te_unit(Kind, _)),
        ( Kind = uk_dimension ; Kind = uk_scalar )
    then
        !:Errors = [with_hint(error_at(dv_let_bad_annotation, Id ^ id_pos,
            "`" ++ Name ++ "` names a dimension, and a `let` annotation takes "
                ++ "a unit symbol (LUNI.8.6)"),
            "write one of the dimension's units, which pins its scale")
            | !.Errors]
    else if map.search(Types, Name, te_unit(uk_symbol(Declared), _)) then
        luni_8_6_unit_annotation(Env, Id, Declared, Expr, RHS, !Errors)
    else if luni_8_6_checked_scalar(Name, Declared) then
        luni_8_6_scalar_annotation(Env, Id, Declared, Expr, RHS, !Errors)
    else if map.contains(Types, Name) then
        !:Errors = [with_hint(error_at(dv_let_bad_annotation, Id ^ id_pos,
            "`" ++ Name ++ "` is a type a `let` cannot be annotated with "
                ++ "(LUNI.8.6)"),
            "a `let` annotation names String, Int, Float, Bool, Json, Time, "
                ++ "Date, Duration or a unit symbol") | !.Errors]
    else
        !:Errors = [with_hint(error_at(dv_unknown_type, Id ^ id_pos,
            "unknown type `" ++ Name ++ "` in a `let` annotation "
                ++ "([LGRA.5.7.1])"),
            "a `let` annotation names String, Int, Float, Bool, Json, Time, "
                ++ "Date, Duration or a unit symbol") | !.Errors]
    ).

    % A typed `let` is [LUNI.4.5]'s assignment boundary, so one `implicit`
    % formula bridges. A plain `Float` or `Int` takes the unit ([LUNI.8.5]).
    %
    %@spec [LUNI.4.5]
:- pred luni_8_6_unit_annotation(type_env::in, ident::in, decl_ref::in,
                                 lgra_9_3_1_expr::in, lexp_7_type::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
    is det.

luni_8_6_unit_annotation(Env, Id, Declared, Expr, RHS, !Errors) :-
    Name = Id ^ id_name,
    (
        RHS = ty_known(Known),
        ( if Known ^ dt_dim = dim(Actual, _) then
            ( if Actual = Declared then
                true
            else
                luni_8_6_bridge(Env, Id, Actual, Declared, Name, !Errors)
            )
        else if
            ( Known ^ dt_leaf = lk_float ; Known ^ dt_leaf = lk_int )
        then
            true
        else
            !:Errors = [luni_8_6_type_mismatch(Id, leaf_name(Known ^ dt_leaf))
                | !.Errors]
        )
    ;
        RHS = ty_unknown,
        ( if
            ( luni_8_4_answered(Env, Expr)
            ; luni_9_2_answered(Env, Expr)
            )
        then
            true
        else
            !:Errors = [luni_8_6_untyped(Id) | !.Errors]
        )
    ;
        RHS = ty_error(_)
    ).

    % `integral` over a unit-carrying slot types `ty_unknown`; any unit symbol
    % answers it.
    %
    %@spec [LUNI.9.2]
:- pred luni_9_2_answered(type_env::in, lgra_9_3_1_expr::in) is semidet.

luni_9_2_answered(Env, Expr) :-
    first_unit_changing_read(Env, [Expr]) = yes(_).

    % A product or quotient of two dimensions: `ty_unknown` under the
    % annotation, and walked without it, its only diagnostics are the ambiguity.
    %
    %@spec [LUNI.8.4]
:- pred luni_8_4_answered(type_env::in, lgra_9_3_1_expr::in) is semidet.

luni_8_4_answered(Env, Expr) :-
    type_of_expr(Env ^ te_ambiguity := da_reported, Expr) = ty_error(Es),
    Es = [_ | _],
    list.all_true(
        ( pred(D::in) is semidet :-
            D ^ dg_code = dc_validate(dv_dim_ambiguous) ),
        Es).

    %@helper
:- pred luni_8_6_scalar_annotation(type_env::in, ident::in, leaf_kind::in,
                                   lgra_9_3_1_expr::in, lexp_7_type::in,
                                   list(diagnostic)::in, list(diagnostic)::out)
    is det.

luni_8_6_scalar_annotation(Env, Id, Declared, Expr, RHS, !Errors) :-
    Name = Id ^ id_name,
    (
        RHS = ty_known(Known),
        ( if
            ( Declared = lk_float ; Declared = lk_int ),
            Known ^ dt_dim = dim(Actual, _)
        then
            % No formula bridges to a unitless target: `bridges_pair` reads
            % both ends as dimensions.
            !:Errors = [with_hint(error_at(dv_let_dim_mismatch, Id ^ id_pos,
                "the annotation is `" ++ Name ++ "`, which carries no unit, "
                    ++ "and the value is `" ++ Actual ^ dr_name ++ "` (LUNI.8.6)"),
                "an annotation never drops a unit -- annotate with the "
                    ++ "unit, or strip it with `::" ++ Name ++ "`") | !.Errors]
        else if Known ^ dt_leaf \= Declared then
            !:Errors = [luni_8_6_type_mismatch(Id, leaf_name(Known ^ dt_leaf))
                | !.Errors]
        else
            true
        )
    ;
        RHS = ty_unknown,
        ( if luni_8_4_answered(Env, Expr) then
            !:Errors = [with_hint(error_at(dv_let_dim_mismatch, Id ^ id_pos,
                "the annotation is `" ++ Name ++ "`, which carries no unit, "
                    ++ "and the value combines two dimensions ([LUNI.8.4])"),
                "annotate with the result's unit, or strip the operands "
                    ++ "with `::Float`") | !.Errors]
        else if
            first_unit_changing_read(Env, [Expr]) = yes({Agg, Unit, _})
        then
            !:Errors = [with_hint(error_at(dv_let_dim_mismatch, Id ^ id_pos,
                "the annotation is `" ++ Name ++ "`, which carries no unit, "
                    ++ "and the value reads `" ++ Agg ++ "` of a `" ++ Unit
                    ++ "` slot ([LUNI.9.2])"),
                "annotate with a unit of a compound `unit dimension` you "
                    ++ "declare for the result") | !.Errors]
        else
            !:Errors = [luni_8_6_untyped(Id) | !.Errors]
        )
    ;
        RHS = ty_error(_)
    ).

    %@helper
:- pred luni_8_6_bridge(type_env::in, ident::in, decl_ref::in, decl_ref::in,
                        string::in,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

luni_8_6_bridge(Env, Id, Actual, Declared, Name, !Errors) :-
    Bridge = luni_4_5_implicit_bridge(Env, Actual, Declared),
    (
        Bridge = bridge_one
    ;
        Bridge = bridge_ambiguous,
        !:Errors = [with_hint(error_at(dv_formula_ambiguous, Id ^ id_pos,
            "two `implicit` formulas bridge `" ++ Actual ^ dr_name ++ "` and `"
                ++ Declared ^ dr_name ++ "`, so this annotation has no unique "
                ++ "conversion ([LUNI.4.5])"),
            "drop `implicit` from all but one of them") | !.Errors]
    ;
        Bridge = bridge_none,
        !:Errors = [with_hint(error_at(dv_let_dim_mismatch, Id ^ id_pos,
            "the annotation is `" ++ Name ++ "` (" ++ Declared ^ dr_name
                ++ ") and the value is `" ++ Actual ^ dr_name ++ "` (LUNI.8.6)"),
            "an annotation asserts a unit, it does not convert one -- "
                ++ "change the annotation, or convert the value with `::`")
            | !.Errors]
    ).

    %@helper
:- func luni_8_6_type_mismatch(ident, string) = diagnostic.

luni_8_6_type_mismatch(Id, Actual) =
    with_hint(error_at(dv_let_type_mismatch, Id ^ id_pos,
        "the annotation is `" ++ Id ^ id_name ++ "` and the value is `"
            ++ Actual ++ "` (LUNI.8.6)"),
        "an annotation asserts the type, it does not convert -- change the "
            ++ "annotation, or convert the value with `::" ++ Id ^ id_name
            ++ "`").

    %@helper
:- func luni_8_6_untyped(ident) = diagnostic.

luni_8_6_untyped(Id) =
    with_hint(error_at(dv_let_type_mismatch, Id ^ id_pos,
        "the annotation is `" ++ Id ^ id_name ++ "`, and the compiler cannot "
            ++ "determine the value's type to check it against (LUNI.8.6)"),
        "drop the annotation, or convert the value with `::"
            ++ Id ^ id_name ++ "`").

    %@helper
:- pred luni_8_6_checked_scalar(string::in, leaf_kind::out) is semidet.

luni_8_6_checked_scalar("String", lk_string).
luni_8_6_checked_scalar("Int", lk_int).
luni_8_6_checked_scalar("Float", lk_float).
luni_8_6_checked_scalar("Bool", lk_bool).
luni_8_6_checked_scalar("Json", lk_json).
luni_8_6_checked_scalar("Time", lk_time).
luni_8_6_checked_scalar("Date", lk_date).
luni_8_6_checked_scalar("Duration", lk_duration).

    %@spec [LNUL.5.1]
:- func lnul_5_1_annotation(ident, ast_annotation, pos)
    = maybe(pair(string, pos)).

lnul_5_1_annotation(Name, Ann, Pos) = Concrete :-
    (
        Ann ^ aan_nullable = non_null,
        Concrete = yes(("the RHS of `let " ++ Name ^ id_name ++ ": "
            ++ Ann ^ aan_type ^ id_name ++ "`") - Pos)
    ;
        Ann ^ aan_nullable = nullable,
        Concrete = no
    ).

    % In source order, which `rsc_lets`, a map, does not keep.
    %
    %@helper
:- func rule_let_bindings(ast_rule) = list(ast_let_binding).

rule_let_bindings(Rule) =
    list.condense(list.map(let_bindings_of, Rule ^ ar_rhs ^ arr_lets)).

    %@helper
:- func let_bindings_of(ast_let_decl) = list(ast_let_binding).

let_bindings_of(Decl) = Decl ^ ald_bindings.

    %@helper
:- pred action_strings(type_env::in, ast_action::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

action_strings(Env, Action, !Errors) :-
    Pos = Action ^ aac_pos,
    ( if Action ^ aac_head = aah_log(_, Text) then
        lgra_2_9_4_check_escapes(Text, Pos, !Errors),
        check_interpolation(Env, Text, Pos, !Errors)
    else
        true
    ),
    Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
    Eligible = ( if lgra_2_9_6_8_eligible(Action ^ aac_head) then yes else no ),
    list.foldl(arg_strings(Env, Eligible), Args, !Errors),
    % A string inside a non-string `as` is an operand, so inert.
    ( if Action ^ aac_as = yes(ex_string(AsText, AsPos)) then
        lgra_2_9_4_check_escapes(AsText, AsPos, !Errors),
        check_interpolation(Env, AsText, AsPos, !Errors)
    else if Action ^ aac_as = yes(AsExpr) then
        list.foldl(inert_string, inert_strings(AsExpr), !Errors)
    else
        true
    ).

    % `record_event` is refused as retired ([LGRA.10.1.5]); its arguments are
    % still checked as an `emit`'s.
    %
    %@spec [LGRA.2.9.6.8]
:- pred lgra_2_9_6_8_eligible(ast_action_head::in) is semidet.

lgra_2_9_6_8_eligible(aah_log(_, _)).
lgra_2_9_6_8_eligible(aah_call(_)).
lgra_2_9_6_8_eligible(aah_emit(_)).
lgra_2_9_6_8_eligible(aah_publish(_)).
lgra_2_9_6_8_eligible(aah_record_event(_)).

    % A pure `let` inlines into its segment ([LLET.12.5]), so the value kind is
    % its RHS's. The one kind refused here is a fact cast to `Json`.
    %
    %@spec [LGRA.2.9.6.9]
:- pred lgra_2_9_6_9_interp_unsupported(rule_scope::in, ast_rule::in,
                                        list(diagnostic)::out) is det.

lgra_2_9_6_9_interp_unsupported(Scope, Rule, Errors) :-
    Lets = list.foldl(simple_let, rule_let_bindings(Rule), map.init),
    Strings = list.condense(list.map(action_interp_strings,
        rule_actions(Rule))),
    Errors = list.condense(list.map(
        ( func({Text, Pos}) = unsupported_sites(Scope, Lets,
            interp_site_names(string.to_char_list(Text)), Pos) ),
        Strings)).

    %@helper
:- func simple_let(ast_let_binding, map(string, lgra_9_3_1_expr))
    = map(string, lgra_9_3_1_expr).

simple_let(Binding, Lets0) = Lets :-
    ( if Binding = alb_simple(Name, _, Rhs, _) then
        map.set(Name ^ id_name, Rhs, Lets0, Lets)
    else
        Lets = Lets0
    ).

    %@helper
:- func action_interp_strings(ast_action) = list({string, pos}).

action_interp_strings(Action) = Strings :-
    ( if Action ^ aac_head = aah_log(_, LogText) then
        Log = [{LogText, Action ^ aac_pos}]
    else
        Log = []
    ),
    Kwargs = list.filter_map(
        ( func(Arg) = {KwText, KwPos} is semidet :-
            Arg = aaa_kwarg(_, ex_string(KwText, KwPos), _)
        ), Action ^ aac_args ++ block_args(Action ^ aac_block)),
    ( if Action ^ aac_as = yes(ex_string(AsText, AsPos)) then
        As = [{AsText, AsPos}]
    else
        As = []
    ),
    Strings = Log ++ Kwargs ++ As.

    % The sites that are one bare name, format split off, in NFC as the lexer
    % gives a `let` its name.
    %
    %@helper
:- func interp_site_names(list(char)) = list(string).

interp_site_names(Chars) =
    list.filter_map(site_bare_name, lgra_2_9_6_7_pieces(Chars)).

    %@helper
:- func site_bare_name(piece) = string is semidet.

site_bare_name(p_site(Body)) = Name :-
    site_split(Body, Path, _),
    Path = [First | More],
    name_start(First),
    list.all_true(name_continue, More),
    Name = lnam_2_4_1_nfc(string.from_char_list(Path)).

    %@helper
:- func unsupported_sites(rule_scope, map(string, lgra_9_3_1_expr),
                          list(string), pos) = list(diagnostic).

unsupported_sites(Scope, Lets, Names, Pos) = list.filter_map(
    ( func(Name) = Diagnostic is semidet :-
        let_value(Lets, Name, 0, Rhs),
        unwired_kind(Scope, Rhs, What),
        Diagnostic = with_hint(error_at(dv_interp_unsupported, Pos,
            "`{" ++ Name ++ "}`: interpolating " ++ What
                ++ " is not supported yet ([LGRA.2.9.6.9])"),
            "bind the rendered form to a slot and interpolate that, or "
                ++ "branch in the rule")
    ), Names).

    % A `let`'s RHS, through `let`s that only name another. The depth bound
    % stops a cycle, which [LLET.12.3] refuses elsewhere.
    %
    %@helper
:- pred let_value(map(string, lgra_9_3_1_expr)::in, string::in, int::in,
                  lgra_9_3_1_expr::out) is semidet.

let_value(Lets, Name, Depth, Rhs) :-
    Depth =< map.count(Lets),
    map.search(Lets, Name, Rhs0),
    ( if Rhs0 = ex_name(Next), map.contains(Lets, Next ^ id_name) then
        let_value(Lets, Next ^ id_name, Depth + 1, Rhs)
    else
        Rhs = Rhs0
    ).

    %@helper
:- pred unwired_kind(rule_scope::in, lgra_9_3_1_expr::in, string::out)
    is semidet.

unwired_kind(Scope, Rhs, What) :-
    Rhs = ex_cast(ex_name(Binding), Target, _, _),
    Target ^ id_name = "Json",
    map.contains(Scope ^ rsc_bindings, Binding ^ id_name),
    What = "a `fact::Json` result".

    % On an eligible verb the argument's own string is interpolated; a string
    % nested in its expression, and every string on another verb, is inert.
    %
    %@helper
:- pred arg_strings(type_env::in, bool::in, ast_action_arg::in,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

arg_strings(Env, Eligible, Arg, !Errors) :-
    ( if
        Eligible = yes,
        Arg = aaa_kwarg(_, ex_string(Text, Pos), _)
    then
        lgra_2_9_4_check_escapes(Text, Pos, !Errors),
        check_interpolation(Env, Text, Pos, !Errors)
    else if Arg = aaa_kwarg(_, Expr, _) then
        ( if Expr = ex_string(Text, Pos) then
            lgra_2_9_4_check_escapes(Text, Pos, !Errors)
        else
            true
        ),
        list.foldl(inert_string, inert_strings(Expr), !Errors)
    else
        true
    ).

    %@helper
:- pred typed_expr(resolved_file::in, type_env::in, lgra_9_3_1_expr::in,
                   list(diagnostic)::in, list(diagnostic)::out) is det.

typed_expr(_RF, Env, Expr, !Errors) :-
    Type = type_of_expr(Env, Expr),
    (
        Type = ty_error(Diagnostics),
        !:Errors = reverse(Diagnostics) ++ !.Errors
    ;
        ( Type = ty_known(_)
        ; Type = ty_unknown
        )
    ).

    %@helper
:- func rule_predicates(ast_rule) = list(lgra_9_3_1_expr).

rule_predicates(Rule) =
    list.condense(list.map(clause_predicates, Rule ^ ar_lhs)).

    %@helper
:- func clause_predicates(ast_lhs_clause) = list(lgra_9_3_1_expr).

clause_predicates(alc_then(S)) = step_predicates(S).
clause_predicates(alc_pattern(P)) = pattern_predicates(P).

    %@helper
:- func pattern_predicates(ast_pattern) = list(lgra_9_3_1_expr).

pattern_predicates(ap_simple(B)) = body_predicates(B).
pattern_predicates(ap_negated(B, _)) = body_predicates(B).
pattern_predicates(ap_sequence(_, Head, Steps, _)) =
    body_predicates(Head)
        ++ list.condense(list.map(step_predicates, Steps)).

    %@helper
:- func step_predicates(ast_then_step) = list(lgra_9_3_1_expr).

step_predicates(Step) = body_predicates(Step ^ ats_body).

    %@helper
:- func body_predicates(ast_pattern_body) = list(lgra_9_3_1_expr).

body_predicates(Body) =
    ( if Body ^ apb_where = yes(W) then [W] else [] ).


    % Every action in the rule, inside `after` blocks and continuations too.
    %
    %@helper
:- func rule_actions(ast_rule) = list(ast_action).

rule_actions(Rule) = Body :-
    Rhs = Rule ^ ar_rhs,
    Body = nested_actions(Rhs ^ arr_actions)
        ++ list.condense(list.map(after_actions, Rhs ^ arr_afters)).

    % `rule_actions`, each action paired with the scope it is read in, in
    % `nested_actions`'s order. An `error:` body adds the `CallError` as
    % `error` ([LCCO.8.4]), and an `on` body its response as `response`, typed
    % by the service's response schema ([LCCO.6.2]). A nested continuation is
    % scoped from the rule, not from the body it is written in ([LCCO.6.2]).
    %
    %@helper
:- func scoped_actions(type_env, ast_rule) = list({type_env, ast_action}).

scoped_actions(Env, Rule) = Scoped :-
    Rhs = Rule ^ ar_rhs,
    Scoped = scoped_list(Env, Env, Rhs ^ arr_actions)
        ++ list.condense(list.map(scoped_after(Env), Rhs ^ arr_afters)).

    %@helper
:- func scoped_after(type_env, ast_after_clause) = list({type_env, ast_action}).

scoped_after(Env, After) =
    scoped_list(Env, Env, After ^ aaf_actions)
        ++ list.condense(list.map(scoped_after(Env), After ^ aaf_nested)).

    % `Actions` in `Env`, and their calls' continuation bodies in a scope
    % built from `Base`.
    %
    %@helper
:- func scoped_list(type_env, type_env, list(ast_action))
    = list({type_env, ast_action}).

scoped_list(Base, Env, Actions) =
    list.map((func(A) = {Env, A}), Actions)
        ++ list.condense(list.map(scoped_continuations(Base), Actions)).

    %@helper
:- func scoped_continuations(type_env, ast_action)
    = list({type_env, ast_action}).

scoped_continuations(Base, Action) = Scoped :-
    ( if Action ^ aac_block = aab_call(_, Continuations) then
        Scoped = list.condense(list.map(scoped_continuation(Base, Action),
            Continuations))
    else
        Scoped = []
    ).

    %@helper
:- func scoped_continuation(type_env, ast_action, ast_continuation)
    = list({type_env, ast_action}).

scoped_continuation(Base, Call, Continuation) =
    scoped_list(Base, continuation_env(Base, Call, Continuation),
        continuation_body(Continuation)).

    % The scope a continuation of `Call` is read in: `Base`, the rule's, and
    % the one fact the clause matched. A `response` the file cannot resolve
    % leaves `Base` as it is, and a read of it is refused as unknown.
    %
    % ⚠ THE SCHEMA'S OWN NAME ([LIMP.13.1]), as `dsc.rete` binds it: an import
    % alias names the schema it stands for, which `fact_schema` finds by its
    % own name.
    %
    %@helper
:- func continuation_env(type_env, ast_action, ast_continuation) = type_env.

continuation_env(Base, Call, acont_on(_, _, Pos)) =
    ( if call_response_name(Base ^ te_file, Call, Name) then
        env_with_binding(Base, "response", Name, Pos)
    else
        Base
    ).
continuation_env(Base, _, acont_timeout(_, _, _)) = Base.
continuation_env(Base, _, acont_error(_, _, Pos)) =
    env_with_binding(Base, "error", "CallError", Pos).

    % The own name of the schema a call's service answers with, as the file
    % declaring the service resolves it (`rf_response_names`).
    %
    %@helper
:- pred call_response_name(resolved_file::in, ast_action::in, string::out)
    is semidet.

call_response_name(RF, Call, Name) :-
    Call ^ aac_head = aah_call(asr_bare(Path)),
    map.search(RF ^ rf_response_names, dotted(Path), Name).

    %@helper
:- func after_actions(ast_after_clause) = list(ast_action).

after_actions(After) =
    nested_actions(After ^ aaf_actions)
        ++ list.condense(list.map(after_actions, After ^ aaf_nested)).

    %@helper
:- func nested_actions(list(ast_action)) = list(ast_action).

nested_actions(Actions) =
    Actions ++ list.condense(list.map(continuation_actions, Actions)).

    %@helper
:- func continuation_actions(ast_action) = list(ast_action).

continuation_actions(Action) = Nested :-
    ( if Action ^ aac_block = aab_call(_, Continuations) then
        Nested = nested_actions(
            list.condense(list.map(continuation_body, Continuations)))
    else
        Nested = []
    ).

    %@helper
:- func continuation_body(ast_continuation) = list(ast_action).

continuation_body(acont_on(_, Actions, _)) = Actions.
continuation_body(acont_timeout(_, Actions, _)) = Actions.
continuation_body(acont_error(_, Actions, _)) = Actions.

    %@spec [LGRA.10.3.5]
:- pred lgra_10_3_5_duplicate_kwarg(ast_action::in,
                                    list(diagnostic)::in, list(diagnostic)::out)
                                    is det.

lgra_10_3_5_duplicate_kwarg(Action, !Errors) :-
    Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
    list.foldl2(repeated_kwarg, Args, set.init, _, !Errors).

    %@helper
:- pred repeated_kwarg(ast_action_arg::in, set(string)::in, set(string)::out,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

repeated_kwarg(Arg, !Seen, !Errors) :-
    ( if Arg = aaa_kwarg(Name, _, _) then
        Written = Name ^ id_name,
        ( if set.member(Written, !.Seen) then
            !:Errors = [with_hint(error_at(dv_duplicate_kwarg, Name ^ id_pos,
                "kwarg `" ++ Written ++ "` is named twice in one action "
                    ++ "([LGRA.10.3.5])"),
                "give each kwarg once; the artefact orders kwargs by name, "
                    ++ "so a second value cannot mean anything")
                | !.Errors]
        else
            set.insert(Written, !Seen)
        )
    else
        true
    ).

    %@spec [LGRA.10.3.2]
:- pred lgra_10_3_2_action(resolved_file::in, type_env::in, ast_action::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_10_3_2_action(RF, Env, Action, !Errors) :-
    Head = Action ^ aac_head,
    ( if fact_verb(Head, Verb, Ref) then
        Args0 = Action ^ aac_args ++ block_args(Action ^ aac_block),
        ltie_4_9_publish_modifier(Verb, Args0, Args, !Errors),
        ( if lgra_22_4_schema_of(RF, Ref, Schema) then
            llog_11_1_lifecycle_flag(RF, Verb, type_ref_name(Ref), Schema, Args,
                !Errors),
            lfac_9_3_ts_written(Verb, Schema, Args, Checked, !Errors),
            list.foldl(check_kwarg(Env, Verb, Schema), Checked, !Errors),
            lgra_13_11_missing_slots(Verb, Schema, Args, Action ^ aac_pos,
                !Errors)
        else
            % The driver injects `CallError` only for a program that has a
            % `call` or matches one, so a bare one may reach here unresolved.
            ( if
                ( Verb = "emit" ; Verb = "publish" ),
                Ref = atr_bare(Id),
                Id ^ id_name = "CallError"
            then
                !:Errors = [lcrs_4_3_4_refused(Verb, Id, "CallError")
                    | !.Errors]
            else
                lgra_22_4_schema_ref(RF, Verb, Ref, !Errors)
            )
        )
    else if Head = aah_call(asr_bare(Path)) then
        lgra_10_3_3_call_kwargs(RF, Env, Path, Action, !Errors)
    else if lgra_10_3_3_fixed_verb(Head, Verb, Allowed, Required) then
        lgra_10_3_3_fixed_kwargs(Verb, Allowed, Required, Action, !Errors),
        lgra_10_3_7_cache_key(Verb, Action, !Errors)
    else
        true
    ).

    % [LTIE.4.9]: `logical` and `retain:` on a `publish`. Each is refused and
    % then dropped from what the later checks see, so it draws one diagnostic.
    %
    %@spec [LTIE.4.9]
:- pred ltie_4_9_publish_modifier(string::in, list(ast_action_arg)::in,
                                  list(ast_action_arg)::out,
                                  list(diagnostic)::in, list(diagnostic)::out)
    is det.

ltie_4_9_publish_modifier(Verb, Args, Kept, !Errors) :-
    ( if Verb = "publish" then
        list.foldl2(publish_modifier, Args, [], RevKept, !Errors),
        Kept = list.reverse(RevKept)
    else
        Kept = Args
    ).

    %@helper
:- pred publish_modifier(ast_action_arg::in,
                         list(ast_action_arg)::in, list(ast_action_arg)::out,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

publish_modifier(Arg, !Kept, !Errors) :-
    ( if
        (
            Arg = aaa_flag(Id),
            Id ^ id_name = "logical",
            What = "`logical`"
        ;
            Arg = aaa_kwarg(Id, _, _),
            Id ^ id_name = "retain",
            What = "`retain:`"
        )
    then
        !:Errors = [with_hint(error_at(dv_publish_modifier, Id ^ id_pos,
            "`publish` takes no " ++ What ++ ": it asserts nothing in this "
                ++ "tier, and the receiving tier's schema gives the fact its "
                ++ "lifetime ([LTIE.4.9], [LTIE.9.4])"),
            "drop " ++ What ++ "; to keep the fact here too, write an `emit` "
                ++ "beside the `publish` ([LTIE.4.3])") | !.Errors]
    else
        !:Kept = [Arg | !.Kept]
    ).

    %@spec [LGRA.13.11]
:- pred lgra_13_11_missing_slots(string::in, ast_schema::in,
                                 list(ast_action_arg)::in, pos::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_13_11_missing_slots(Verb, Schema, Args, Pos, !Errors) :-
    Given = list.filter_map(
        ( func(A) = N ^ id_name is semidet :- A = aaa_kwarg(N, _, _) ), Args),
    list.foldl(missing_slot(Verb, Schema ^ as_name ^ id_name, Given, Pos),
        Schema ^ as_fields, !Errors).

    %@helper
:- pred missing_slot(string::in, string::in, list(string)::in, pos::in,
                     ast_field::in,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

missing_slot(Verb, SchemaName, Given, Pos, Field, !Errors) :-
    Name = Field ^ af_name ^ id_name,
    ( if
        Field ^ af_nullable = non_null,
        Name \= "ts",
        not list.member(Name, Given)
    then
        !:Errors = [with_hint(error_at(dv_missing_slot, Pos,
            "`" ++ Verb ++ " " ++ SchemaName ++ "` gives no value for `"
                ++ Name ++ "`, which is not nullable ([LGRA.13.11])"),
            "write `" ++ Name ++ ": <value>`, or declare the slot `"
                ++ Field ^ af_type ^ id_name ++ "?` if it may be absent")
            | !.Errors]
    else
        true
    ).

    % `Checked` is the arguments `check_kwarg` still judges: a refused `ts:` is
    % left out, and on a schema with no `ts` slot it stays, as an unknown slot.
    %
    %@spec [LFAC.9.3]
:- pred lfac_9_3_ts_written(string::in, ast_schema::in,
                            list(ast_action_arg)::in, list(ast_action_arg)::out,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

lfac_9_3_ts_written(Verb, Schema, Args, Checked, !Errors) :-
    ( if
        ( Verb = "emit" ; Verb = "publish" ),
        list.member(F, Schema ^ as_fields),
        F ^ af_name ^ id_name = "ts"
    then
        list.foldl2(ts_write_refused(Verb, Schema ^ as_name ^ id_name), Args,
            [], RevChecked, !Errors),
        Checked = list.reverse(RevChecked)
    else
        Checked = Args
    ).

    %@helper
:- pred ts_write_refused(string::in, string::in, ast_action_arg::in,
                         list(ast_action_arg)::in, list(ast_action_arg)::out,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

ts_write_refused(Verb, Target, Arg, !Checked, !Errors) :-
    ( if Arg = aaa_kwarg(Name, _, _), Name ^ id_name = "ts" then
        !:Errors = [with_hint(error_at(dv_ts_read_only, Name ^ id_pos,
            "`" ++ Verb ++ " " ++ Target ++ "` writes `ts`, which the engine "
                ++ "fills and an author may only read ([LFAC.9.3])"),
            "drop `ts:` -- the fact gets the step's wall-clock sample "
                ++ "([LFAC.9.2])") | !.Errors]
    else
        !:Checked = [Arg | !.Checked]
    ).

%-----------------------------------------------------------------------------%
% The fixed-inventory verbs
%-----------------------------------------------------------------------------%

    %@spec [LGRA.10.3.3]
:- pred lgra_10_3_3_fixed_verb(ast_action_head::in, string::out,
                               list(string)::out, list(string)::out) is semidet.

lgra_10_3_3_fixed_verb(aah_log(_, _), "log", [], []).
lgra_10_3_3_fixed_verb(aah_cache, "cache", ["key", "value", "ttl"],
    ["key", "value"]).
lgra_10_3_3_fixed_verb(aah_cache_delete, "cache_delete", ["key"], ["key"]).
lgra_10_3_3_fixed_verb(aah_withdraw(_), "withdraw", [], []).

    %@spec [LGRA.10.3.3]
    %@spec [LGRA.10.3.4]
    %@spec [LGRA.13.9]
:- pred lgra_10_3_3_fixed_kwargs(string::in, list(string)::in, list(string)::in,
                                 ast_action::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
                                 is det.

lgra_10_3_3_fixed_kwargs(Verb, Allowed, Required, Action, !Errors) :-
    Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
    list.foldl(fixed_arg_admitted(Verb, Allowed), Args, !Errors),
    list.foldl(fixed_kwarg_required(Verb, Args, Action ^ aac_pos), Required,
        !Errors).

    %@helper
:- pred fixed_arg_admitted(string::in, list(string)::in, ast_action_arg::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

fixed_arg_admitted(Verb, Allowed, Arg, !Errors) :-
    (
        Arg = aaa_kwarg(Name, _, _),
        ( if list.member(Name ^ id_name, Allowed) then
            true
        else
            !:Errors = [with_hint(error_at(dv_bad_kwarg, Name ^ id_pos,
                "`" ++ Verb ++ "` has no kwarg `" ++ Name ^ id_name
                    ++ "` ([LGRA.10.3.3])"), admitted_hint(Verb, Allowed))
                | !.Errors]
        )
    ;
        Arg = aaa_flag(Flag),
        !:Errors = [error_at(dv_bad_flag, Flag ^ id_pos,
            "`" ++ Verb ++ "` takes no flags, and `" ++ Flag ^ id_name
                ++ "` is one ([LGRA.10.3.3])") | !.Errors]
    ).

    %@helper
:- pred fixed_kwarg_required(string::in, list(ast_action_arg)::in, pos::in,
                             string::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

fixed_kwarg_required(Verb, Args, Pos, Name, !Errors) :-
    ( if has_kwarg(Args, Name) then
        true
    else
        !:Errors = [error_at(dv_missing_kwarg, Pos,
            "`" ++ Verb ++ "` requires `" ++ Name ++ ":` ([LGRA.10.3.3])")
            | !.Errors]
    ).

    %@helper
:- func admitted_hint(string, list(string)) = string.

admitted_hint(Verb, []) = "`" ++ Verb ++ "` takes no kwargs at all".
admitted_hint(_, [A | As]) =
    "it takes " ++ string.join_list(", ",
        list.map(kwarg_spelling, [A | As])).

    %@helper
:- func kwarg_spelling(string) = string.

kwarg_spelling(Name) = "`" ++ Name ++ ":`".

    % An interpolated key also takes [LGRA.2.9.6.8]'s inert-position code, from
    % `arg_strings`. This check keeps `dsc.rete`'s non-literal key arms, which
    % are `unexpected/2`, unreachable.
    %
    %@spec [LGRA.10.3.7]
:- pred lgra_10_3_7_cache_key(string::in, ast_action::in,
                              list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_10_3_7_cache_key(Verb, Action, !Errors) :-
    Head = Action ^ aac_head,
    ( if ( Head = aah_cache ; Head = aah_cache_delete ) then
        list.foldl(cache_key_arg(Verb, Action ^ aac_pos),
            Action ^ aac_args ++ block_args(Action ^ aac_block), !Errors)
    else
        true
    ).

    %@helper
:- pred cache_key_arg(string::in, pos::in, ast_action_arg::in,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

cache_key_arg(Verb, Pos, Arg, !Errors) :-
    ( if
        Arg = aaa_kwarg(Name, Value, _),
        Name ^ id_name = "key",
        not lgra_10_3_7_string_lit(Value)
    then
        !:Errors = [with_hint(error_at(dv_dynamic_ident_kwarg, Pos,
            "`" ++ Verb ++ "`: `key:` is given a value computed at the "
                ++ "firing, and a cache key is a literal ([LGRA.10.3.7])"),
            "write the key itself, as a string with no `{...}`") | !.Errors]
    else
        true
    ).

    %@helper
:- pred lgra_10_3_7_string_lit(lgra_9_3_1_expr::in) is semidet.

lgra_10_3_7_string_lit(ex_string(Text, _)) :-
    not has_site(lgra_2_9_6_7_pieces(string.to_char_list(Text))).

    %@spec [LGRA.10.3.4]
:- pred lgra_10_3_4_flag(string::in, ident::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_10_3_4_flag(Verb, Flag, !Errors) :-
    ( if lgra_10_3_4_admitted_flag(Verb, Flag ^ id_name) then
        true
    else
        !:Errors = [with_hint(error_at(dv_bad_flag, Flag ^ id_pos,
            "`" ++ Verb ++ "` has no flag `" ++ Flag ^ id_name
                ++ "` ([LGRA.10.3.4])"), admitted_flag_hint(Verb))
            | !.Errors]
    ).

    %@helper
:- pred lgra_10_3_4_admitted_flag(string::in, string::in) is semidet.

lgra_10_3_4_admitted_flag("emit", "logical").
lgra_10_3_4_admitted_flag("publish", "logical").
lgra_10_3_4_admitted_flag("call", "nocooldown").

    %@helper
:- func admitted_flag_hint(string) = string.

admitted_flag_hint(Verb) = Hint :-
    ( if Verb = "call" then
        Hint = "`call`'s only flag is `nocooldown`"
    else if ( Verb = "emit" ; Verb = "publish" ) then
        Hint = "`" ++ Verb ++ "`'s only flag is `logical`"
    else
        Hint = "`" ++ Verb ++ "` takes no flags"
    ).

%-----------------------------------------------------------------------------%
% The `call` row of the action-argument inventory
%-----------------------------------------------------------------------------%

    %@spec [LGRA.10.3.3]
    %@spec [LGRA.10.3.4]
:- pred lgra_10_3_3_call_kwargs(resolved_file::in, type_env::in,
                                list(ident)::in, ast_action::in,
                                list(diagnostic)::in, list(diagnostic)::out)
                                is det.

lgra_10_3_3_call_kwargs(RF, Env, Path, Action, !Errors) :-
    Spelling = dotted(Path),
    Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
    list.foldl(lcrs_6_3_3_retain_unwired(Spelling), Args, !Errors),
    ( if map.search(RF ^ rf_services, Spelling, Service) then
        Declared = Service ^ asv_kwargs,
        list.foldl(call_kwarg_known(Spelling, Declared, Path), Args, !Errors),
        list.foldl(call_kwarg_required(Spelling, Args, Action ^ aac_pos),
            Declared, !Errors),
        list.foldl(lgra_10_7_literal_kwarg(Spelling, Declared), Args, !Errors),
        list.foldl(call_kwarg_value(Env, Spelling, Declared), Args, !Errors)
    else
        % `ladp_8_2_3_service` reports an unresolved service.
        true
    ).

    %@spec [LCRS.6.3.3]
:- pred lcrs_6_3_3_retain_unwired(string::in, ast_action_arg::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

lcrs_6_3_3_retain_unwired(Spelling, Arg, !Errors) :-
    ( if Arg = aaa_kwarg(Name, _, _), Name ^ id_name = "retain" then
        !:Errors = [with_hint(error_at(dv_retain_unwired, Name ^ id_pos,
            "`call " ++ Spelling ++ "`: no call honours `retain:` "
                ++ "([LCRS.6.3.3])"),
            "a response lives by its schema's TTL ([LCRS.6.6.1])")
            | !.Errors]
    else
        true
    ).

    %@helper
:- pred call_kwarg_known(string::in, list(ast_service_kwarg)::in,
                         list(ident)::in, ast_action_arg::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

call_kwarg_known(Spelling, Declared, _Path, Arg, !Errors) :-
    (
        Arg = aaa_flag(Flag),
        lgra_10_3_4_flag("call", Flag, !Errors)
    ;
        Arg = aaa_kwarg(Name, _, _),
        Written = Name ^ id_name,
        ( if Written = "cooldown" then
            true
        else if Written = "retain" then
            % `lcrs_6_3_3_retain_unwired` has refused it.
            true
        else if declares_kwarg(Declared, Written) then
            true
        else
            !:Errors = [with_hint(error_at(dv_bad_kwarg, Name ^ id_pos,
                "`call " ++ Spelling ++ "`: the service declares no kwarg `"
                    ++ Written ++ "` ([LGRA.10.3.3])"),
                declared_kwargs_hint(Declared)) | !.Errors]
        )
    ).

    % A kwarg with a `default` is never missing ([LADP.8.5.1]).
    %
    %@helper
:- pred call_kwarg_required(string::in, list(ast_action_arg)::in, pos::in,
                            ast_service_kwarg::in,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

call_kwarg_required(Spelling, Args, Pos, Kwarg, !Errors) :-
    ( if
        list.member(akm_required(_), Kwarg ^ ask_modifiers),
        not list.find_first_match(is_default_modifier, Kwarg ^ ask_modifiers,
            _),
        not has_kwarg(Args, Kwarg ^ ask_name ^ id_name)
    then
        !:Errors = [with_hint(error_at(dv_missing_kwarg, Pos,
            "`call " ++ Spelling ++ "`: the service requires `"
                ++ Kwarg ^ ask_name ^ id_name ++ ":` ([LGRA.13.9])"),
            "it is declared `kwarg " ++ Kwarg ^ ask_name ^ id_name ++ ": "
                ++ Kwarg ^ ask_type ^ id_name ++ " required`") | !.Errors]
    else
        true
    ).

    %@spec [LGRA.10.7]
:- pred lgra_10_7_literal_kwarg(string::in, list(ast_service_kwarg)::in,
                                ast_action_arg::in,
                                list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_10_7_literal_kwarg(Spelling, Declared, Arg, !Errors) :-
    ( if
        Arg = aaa_kwarg(Name, Value, _),
        list.find_first_match(
            ( pred(K::in) is semidet :- K ^ ask_name ^ id_name = Name ^ id_name ),
            Declared, Kwarg),
        list.find_first_match(
            ( pred(M::in) is semidet :- M = akm_literal(_) ),
            Kwarg ^ ask_modifiers, _),
        not lgra_10_7_literal(Value)
    then
        !:Errors = [with_hint(error_at(dv_dynamic_ident_kwarg, Name ^ id_pos,
            "`call " ++ Spelling ++ "`: the service declares `"
                ++ Name ^ id_name ++ "` `literal`, and it is given a value "
                ++ "computed at the firing ([LGRA.10.7])"),
            "write the value itself -- a number, a string with no `{...}`, "
                ++ "a unit literal or `true`/`false`") | !.Errors]
    else
        true
    ).

    % [LGRA.9.7.1]'s literal, with the `-` a kwarg's `default` admits
    % ([LGRA.23.1]), and no interpolation site in a string.
    %
    %@helper
:- pred lgra_10_7_literal(lgra_9_3_1_expr::in) is semidet.

lgra_10_7_literal(ex_int(_, _)).
lgra_10_7_literal(ex_float(_, _)).
lgra_10_7_literal(ex_unit(_, _, _)).
lgra_10_7_literal(ex_bool(_, _)).
lgra_10_7_literal(ex_string(Text, _)) :-
    not has_site(lgra_2_9_6_7_pieces(string.to_char_list(Text))).
lgra_10_7_literal(ex_unary(Op, Operand, _)) :-
    Op = uo_neg,
    ( Operand = ex_int(_, _) ; Operand = ex_float(_, _)
    ; Operand = ex_unit(_, _, _) ).

    % `lnul_5_1_concrete` applies to every kwarg: `ask_type` has no `?`, so a
    % service declares no nullable one. [LOPQ.3.2] is checked here.
    %
    %@helper
:- pred call_kwarg_value(type_env::in, string::in,
                         list(ast_service_kwarg)::in, ast_action_arg::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

call_kwarg_value(Env, Spelling, Declared, Arg, !Errors) :-
    ( if
        Arg = aaa_kwarg(Name, Value, Pos),
        % A NAME as `cooldown:` is `lgra_2_8_11_name`'s to judge.
        not ( Name ^ id_name = "cooldown", Value = ex_name(_) )
    then
        ValueType = type_of_expr(Env, Value),
        ( if ValueType = ty_error(ValueErrors) then
            !:Errors = list.reverse(ValueErrors) ++ !.Errors
        else
            !:Errors = list.reverse(lnul_5_1_concrete(Env, Value, ValueType,
                Pos, "the `call " ++ Spelling ++ "` kwarg `"
                    ++ Name ^ id_name ++ ":`")) ++ !.Errors
        ),
        ( if find_service_kwarg(Declared, Name ^ id_name, FactKwarg) then
            ladp_8_6_1_fact_kwarg(Env, Spelling, FactKwarg, Value, ValueType,
                Pos, !Errors),
            ladp_8_5_3_not_whole(Env, Spelling, FactKwarg, Value, Pos, !Errors)
        else
            true
        ),
        ( if
            ValueType = ty_known(Actual),
            find_service_kwarg(Declared, Name ^ id_name, Kwarg),
            map.search(kwarg_scope(Env ^ te_file, Kwarg) ^ rf_types,
                Kwarg ^ ask_type ^ id_name, Entry),
            Wanted = luni_7_1_slot_type(Env ^ te_file ^ rf_unit_storage, Entry,
                nullable)
        then
            ( if
                Wanted ^ dt_leaf = lk_opaque(Sealed),
                Actual ^ dt_leaf \= lk_opaque(Sealed)
            then
                !:Errors = [error_at(dv_opaque_type_mismatch, Pos,
                    "`call " ++ Spelling ++ "`: `" ++ Name ^ id_name
                        ++ ":` takes an opaque `" ++ Sealed ^ dr_name
                        ++ "`, and the "
                        ++ "value is " ++ leaf_name(Actual ^ dt_leaf)
                        ++ " ([LOPQ.3.2])") | !.Errors]
            else
                true
            ),
            ladp_8_5_2_written_dimension(Env, Spelling, Name, Pos, Wanted,
                Actual, !Errors),
            ladp_8_5_4_kwarg_type(Spelling, Name, Kwarg ^ ask_type, Pos,
                Wanted, Actual, !Errors)
        else
            true
        )
    else
        true
    ).

    % A quantity given to an `Int` or `Float` kwarg is [LADP.8.5.2]'s, which
    % converts it. An `Interval` matches whatever its element.
    %
    %@spec [LADP.8.5.4]
:- pred ladp_8_5_4_kwarg_type(string::in, ident::in, ident::in, pos::in,
                              ds_type::in, ds_type::in,
                              list(diagnostic)::in, list(diagnostic)::out)
    is det.

ladp_8_5_4_kwarg_type(Spelling, Name, Declared, Pos, Wanted, Actual,
        !Errors) :-
    ( if
        lgra_22_8_builtin(Declared ^ id_name),
        not (
            ( Wanted ^ dt_leaf = lk_int ; Wanted ^ dt_leaf = lk_float ),
            Actual ^ dt_dim \= dimensionless
        ),
        not same_leaf_kind(Wanted ^ dt_leaf, Actual ^ dt_leaf)
    then
        !:Errors = [with_hint(error_at(dv_type_mismatch, Pos,
            "`call " ++ Spelling ++ "`: `" ++ Name ^ id_name
                ++ ":` is declared `" ++ Declared ^ id_name
                ++ "` and the value is `" ++ leaf_name(Actual ^ dt_leaf)
                ++ "`. A kwarg's declared type is its contract, and the "
                ++ "value is not converted ([LADP.8.5.4])"),
            "convert explicitly with `::" ++ Declared ^ id_name
                ++ "` ([LCST.4.1])") | !.Errors]
    else
        true
    ).

    %@spec [LGRA.22.8]
:- pred lgra_22_8_builtin(string::in) is semidet.

lgra_22_8_builtin("Bool").
lgra_22_8_builtin("Bytes").
lgra_22_8_builtin("Date").
lgra_22_8_builtin("Duration").
lgra_22_8_builtin("Float").
lgra_22_8_builtin("Int").
lgra_22_8_builtin("Interval").
lgra_22_8_builtin("Json").
lgra_22_8_builtin("String").
lgra_22_8_builtin("Time").

    %@helper
:- pred same_leaf_kind(leaf_kind::in, leaf_kind::in) is semidet.

same_leaf_kind(A, B) :-
    ( A = B
    ; A = lk_interval(_), B = lk_interval(_)
    ).

    % A binding whose schema this file cannot type is admitted: an imported
    % head with no library environment types as unknown.
    %
    %@spec [LADP.8.6.1]
    %@spec [LGRA.23.2]
:- pred ladp_8_6_1_fact_kwarg(type_env::in, string::in, ast_service_kwarg::in,
                              lgra_9_3_1_expr::in, lexp_7_type::in, pos::in,
                              list(diagnostic)::in, list(diagnostic)::out)
    is det.

ladp_8_6_1_fact_kwarg(Env, Spelling, Kwarg, Value, ValueType, Pos, !Errors) :-
    Declared = Kwarg ^ ask_type ^ id_name,
    ( if
        ( Declared = "Schema"
        ; map.search(Env ^ te_file ^ rf_types, Declared, te_schema(_))
        )
    then
        ( if
            Value = ex_name(B),
            map.search(Env ^ te_scope ^ rsc_bindings, B ^ id_name, _),
            (
                Declared = "Schema"
            ;
                ValueType \= ty_known(_)
            ;
                ValueType = ty_known(T),
                T ^ dt_leaf = lk_fact(Fact),
                limp_13_1_fact_own(Env, Fact)
                    = limp_13_1_own_of(Env ^ te_file, Declared)
            )
        then
            true
        else
            Want = ( if Declared = "Schema" then "a binding of any schema"
                     else "a binding of `" ++ Declared ++ "`" ),
            !:Errors = [with_hint(error_at(dv_fact_kwarg_not_binding, Pos,
                "`call " ++ Spelling ++ "`: `" ++ Kwarg ^ ask_name ^ id_name
                    ++ ":` is declared `" ++ Declared ++ "` and takes "
                    ++ Want ++ " ([LADP.8.6.1])"),
                "match the fact in the rule's LHS and pass its binding; no "
                    ++ "form constructs a schema value inline")
                | !.Errors]
        )
    else
        true
    ).

    % `known_quantity` is the fold `dsc.rete` lowers the value with. A value it
    % does not know is judged at the call ([RLOW.7.3.9]).
    %
    %@spec [LADP.8.5.3]
:- pred ladp_8_5_3_not_whole(type_env::in, string::in, ast_service_kwarg::in,
                             lgra_9_3_1_expr::in, pos::in,
                             list(diagnostic)::in, list(diagnostic)::out)
    is det.

ladp_8_5_3_not_whole(Env, Spelling, Kwarg, Value, Pos, !Errors) :-
    RF = Env ^ te_file,
    Scope = kwarg_scope(RF, Kwarg),
    Unit = Kwarg ^ ask_type ^ id_name,
    ( if
        map.search(Scope ^ rf_types, Unit, te_unit(uk_symbol(Dimension), _)),
        whole_number_dimension(RF, Dimension),
        known_quantity(RF, let_rhs_named(Env), pattern_binding_named(Env),
            Value, Dimension, Base),
        ladp_8_5_2_in_unit(Scope, Unit, Base, InUnit),
        not is_whole(InUnit)
    then
        !:Errors = [with_hint(error_at(dv_kwarg_quantity_not_whole, Pos,
            "`call " ++ Spelling ++ "`: `" ++ Kwarg ^ ask_name ^ id_name
                ++ ":` takes a whole number of `" ++ Unit ++ "`, and this "
                ++ "value is not one ([LADP.8.5.3])"),
            "a `" ++ Dimension ^ dr_name
                ++ "` value is never truncated or rounded; "
                ++ "pass a whole number of `" ++ Unit ++ "`") | !.Errors]
    else
        true
    ).

    %@helper
:- pred pattern_binding_named(type_env::in, string::in) is semidet.

pattern_binding_named(Env, Name) :-
    map.search(Env ^ te_scope ^ rsc_bindings, Name, _).

    %@helper
:- pred let_rhs_named(type_env::in, string::in, lgra_9_3_1_expr::out)
    is semidet.

let_rhs_named(Env, Name, Rhs) :-
    map.search(Env ^ te_scope ^ rsc_let_exprs, Name, Rhs).

    % A plain number on a unit-typed kwarg passes, taken in the kwarg's unit.
    % The bridge is checked here and applied by call lowering.
    %
    %@spec [LADP.8.5.2]
:- pred ladp_8_5_2_written_dimension(type_env::in, string::in, ident::in,
                                     pos::in, ds_type::in, ds_type::in,
                                     list(diagnostic)::in,
                                     list(diagnostic)::out) is det.

ladp_8_5_2_written_dimension(Env, Spelling, Name, Pos, Wanted, Actual,
        !Errors) :-
    ( if
        Wanted ^ dt_dim = dim(WantedDim, _),
        luni_8_2_quantity_dimension(Actual, ActualDim),
        ActualDim \= WantedDim
    then
        Bridge = luni_4_5_implicit_bridge(Env, ActualDim, WantedDim),
        (
            Bridge = bridge_one
        ;
            Bridge = bridge_ambiguous,
            !:Errors = [with_hint(error_at(dv_formula_ambiguous, Pos,
                "`call " ++ Spelling ++ "`: two `implicit` formulas bridge `"
                    ++ ActualDim ^ dr_name ++ "` and `" ++ WantedDim ^ dr_name
                    ++ "`, so `"
                    ++ Name ^ id_name ++ ":` has no unique conversion "
                    ++ "([LUNI.4.5])"),
                "drop `implicit` from all but one of them") | !.Errors]
        ;
            Bridge = bridge_none,
            !:Errors = [with_hint(error_at(dv_dim_mismatch, Pos,
                "`call " ++ Spelling ++ "`: `" ++ Name ^ id_name
                    ++ ":` takes a `" ++ WantedDim ^ dr_name
                    ++ "` quantity, and the value is `"
                    ++ ActualDim ^ dr_name ++ "` ([LADP.8.5.2])"),
                "a service receives a plain number, and the kwarg's declared "
                    ++ "type says which; pass a quantity of its dimension")
                | !.Errors]
        )
    else
        true
    ).

    %@helper
:- pred find_service_kwarg(list(ast_service_kwarg)::in, string::in,
                           ast_service_kwarg::out) is semidet.

find_service_kwarg([K | Ks], Name, Found) :-
    ( if K ^ ask_name ^ id_name = Name then
        Found = K
    else
        find_service_kwarg(Ks, Name, Found)
    ).

    %@helper
:- pred declares_kwarg(list(ast_service_kwarg)::in, string::in) is semidet.

declares_kwarg([K | Ks], Name) :-
    ( if K ^ ask_name ^ id_name = Name then true else declares_kwarg(Ks, Name) ).

    %@helper
:- func declared_kwargs_hint(list(ast_service_kwarg)) = string.

declared_kwargs_hint([]) = "the service declares no kwargs".
declared_kwargs_hint([K | Ks]) =
    "it declares " ++ string.join_list(", ",
        list.map(kwarg_name_text, [K | Ks])).

    %@helper
:- func kwarg_name_text(ast_service_kwarg) = string.

kwarg_name_text(K) = "`" ++ K ^ ask_name ^ id_name ++ ":`".

    %@spec [LHYD.12.7]
:- pred lhyd_12_7_hydration_endpoint(list(ident)::in) is semidet.

lhyd_12_7_hydration_endpoint(Path) :-
    list.last(Path, Method),
    string.prefix(Method ^ id_name, "hydrate_").

    %@helper
:- pred fact_verb(ast_action_head::in, string::out, ast_type_ref::out)
    is semidet.

fact_verb(aah_emit(Ref), "emit", Ref).
fact_verb(aah_publish(Ref), "publish", Ref).

%-----------------------------------------------------------------------------%
% String escapes
%-----------------------------------------------------------------------------%

    % `dsc.lex` leaves strings raw, so escapes are first read here. A
    % `DS_PARSE_*` code, though `validate` reports it.
    %
    %@spec [LGRA.2.9.4]
:- pred lgra_2_9_4_check_escapes(string::in, pos::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_2_9_4_check_escapes(Text, Pos, !Errors) :-
    ( if
        lgra_2_9_4_decode(string.to_char_list(Text)) = bad_escape(Reason)
    then
        D = with_hint(front_error_at(parse_bad_escape, Pos,
            "invalid escape sequence: " ++ Reason ++ " ([LGRA.2.9.4])"),
            "the escapes are `\\\"`, `\\'`, `\\\\`, `\\n`, `\\t`, `\\r`, "
                ++ "`\\xHH`, `\\uHHHH` and `\\UHHHHHHHH` ([LGRA.2.9.1]), "
                ++ "naming any character but U+0000 ([LSTR.1.1])"),
        !:Errors = [D | !.Errors]
    else
        true
    ).

%-----------------------------------------------------------------------------%
% String interpolation
%-----------------------------------------------------------------------------%

    %@helper
:- pred check_interpolation(type_env::in, string::in, pos::in,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

check_interpolation(Env, Text, Pos, !Errors) :-
    lgra_2_9_6_7_scan_interp(Env,
        lgra_2_9_6_7_pieces(string.to_char_list(Text)), Pos, !Errors).

    %@spec [LGRA.2.9.6.7]
:- pred lgra_2_9_6_7_scan_interp(type_env::in, list(piece)::in, pos::in,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_2_9_6_7_scan_interp(_, [], _, !Errors).
lgra_2_9_6_7_scan_interp(Env, [Piece | Pieces], Pos, !Errors) :-
    (
        Piece = p_text(_)
    ;
        Piece = p_empty,
        !:Errors = [with_hint(error_at(dv_interp_bad_path, Pos,
            "an empty `{}` in a string is an interpolation with no path "
                ++ "([LGRA.2.9.6.9])"),
            "write `{{}}` for literal braces, or name what to interpolate")
            | !.Errors]
    ;
        Piece = p_site(Body),
        lgra_2_9_6_1_check_site(Env, Body, Pos, !Errors)
    ;
        Piece = p_unclosed(_),
        !:Errors = [error_at(dv_interp_bad_path, Pos,
            "an unclosed `{` in a string; `{{` escapes a literal brace "
                ++ "([LGRA.2.9.6.7])") | !.Errors]
    ),
    lgra_2_9_6_7_scan_interp(Env, Pieces, Pos, !Errors).

    % [LGRA.2.9.6.6]'s whitespace has no arm: `path_tail` fails on a space, so
    % it is refused as a bad path.
    %
    %@spec [LGRA.2.9.6.1]
    %@spec [LGRA.2.9.6.2]
    %@spec [LGRA.2.9.6.6]
    %@spec [LGRA.2.9.6.9]
:- pred lgra_2_9_6_1_check_site(type_env::in, list(char)::in, pos::in,
                   list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_2_9_6_1_check_site(Env, Site, Pos, !Errors) :-
    Path = take_to_colon(Site),
    ( if list.append(Path, [':' | Format], Site) then
        luni_11_2_format(Env, Path, Format, Pos, !Errors)
    else
        true
    ),
    ( if interp_path(Path, Leading) then
        ( if
            interp_binding(Env, Leading),
            Segments0 = string.split_at_char('.', string.from_char_list(Path)),
            interp_access(Pos, Segments0, Whole),
            lgra_2_9_6_11_whole_json(Env, Whole, 0)
        then
            !:Errors = [with_hint(error_at(dv_interp_unsupported, Pos,
                "`{" ++ string.from_char_list(Path) ++ "}` interpolates a "
                    ++ "whole `Json` value, which is not a leaf "
                    ++ "([LGRA.2.9.6.11])"),
                "interpolate a path into it that reads a leaf, such as "
                    ++ "`{" ++ string.from_char_list(Path) ++ ".field}`")
                | !.Errors]
        else if interp_binding(Env, Leading) then
            lopq_3_3_interpolated(Env, Path, Pos, !Errors)
        else if
            Segments = string.split_at_char('.', string.from_char_list(Path)),
            interp_access(Pos, Segments, Member),
            lgra_2_9_6_2_library_member(Env, Member)
        then
            ( if type_of_expr(Env, Member) = ty_error(TypeErrors) then
                !:Errors = TypeErrors ++ !.Errors
            else
                lopq_3_3_interpolated(Env, Path, Pos, !Errors)
            )
        else
            !:Errors = [with_hint(error_at(dv_unknown_binding, Pos,
                "`{" ++ string.from_char_list(Path) ++ "}`: `" ++ Leading
                    ++ "` is not an in-scope value-binding ([LGRA.2.9.6.2])"),
                "interpolation takes a pattern binding, a `const` or a `let`; "
                    ++ "a computed value is bound with a `let` first "
                    ++ "([LGRA.2.9.6.9])") | !.Errors]
        )
    else
        !:Errors = [with_hint(error_at(dv_interp_bad_path, Pos,
            "`{" ++ string.from_char_list(Path) ++ "}` is not a valid "
                ++ "interpolation path ([LGRA.2.9.6.9])"),
            "the body is `NAME ( '.' NAME | '[' INT ']' )*` -- a name or a "
                ++ "path, never an expression") | !.Errors]
    ).

    % The kind checks need a known type. Otherwise the runtime refuses a kind
    % its primitive cannot render ([LGRA.2.9.6.10], [IRET.9.6]).
    %
    %@spec [LUNI.11.2]
    %@spec [LGRA.2.9.6.3]
    %@spec [LGRA.2.9.6.5]
    %@spec [LUNI.14.9]
:- pred luni_11_2_format(type_env::in, list(char)::in, list(char)::in,
                          pos::in, list(diagnostic)::in,
                          list(diagnostic)::out) is det.

luni_11_2_format(Env, Path, Format, Pos, !Errors) :-
    Spec = string.from_char_list(Format),
    Site = "`{" ++ string.from_char_list(Path) ++ ":" ++ Spec ++ "}`",
    ( if
        Segments = string.split_at_char('.', string.from_char_list(Path)),
        interp_access(Pos, Segments, Expr),
        type_of_expr(Env, Expr) = ty_known(Known0)
    then
        Known = yes(Known0)
    else
        Known = no
    ),
    Read = lgra_2_9_6_1_format(Format),
    (
        Read = spec_bad(Why),
        !:Errors = [with_hint(error_at(dv_interp_bad_format, Pos,
            Site ++ " is not a valid format spec: " ++ Why
                ++ " ([LGRA.2.9.6.1])"),
            "a spec is `[<|>][+][0][width][.precision][type]` with type one "
                ++ "of `d f s x X b u`, or a timestamp pattern of "
                ++ "`%Y %m %d %H %M %S %f %z %%` and literal text")
            | !.Errors]
    ;
        Read = spec_ok(F),
        ( if
            F = if_num(CF),
            CF ^ nf_type = yes(T),
            ( T = 'i' ; T = 'j' )
        then
            !:Errors = [with_hint(error_at(dv_complex_not_in_v1, Pos,
                Site ++ ": `" ++ string.char_to_string(T) ++ "` formats a "
                    ++ "complex number, and complex numbers are not in this "
                    ++ "edition of DS ([LUNI.14.9])"),
                "drop the type for the canonical form, or use `f`")
                | !.Errors]
        else
            list.foldl(
                (pred(Why::in, E0::in, E::out) is det :-
                    E = [error_at(dv_interp_bad_format, Pos,
                        Site ++ ": " ++ Why) | E0]),
                lgra_2_9_6_5_refusals(F, Known), !Errors),
            ( if
                F = if_num(NF),
                NF ^ nf_type = yes('u'),
                Known = yes(K),
                K ^ dt_dim = dimensionless
            then
                !:Errors = [with_hint(error_at(dv_interp_unit_non_unit, Pos,
                    Site ++ ": `u` prints a unit label, and this value has no "
                        ++ "unit ([LUNI.11.2])"),
                    "use a numeric spec such as `:.2f`, or interpolate a "
                        ++ "unit-typed slot") | !.Errors]
            else
                true
            )
        )
    ).

    %@spec [LGRA.2.9.6.4]
:- func lgra_2_9_6_5_refusals(interp_format, maybe(ds_type)) = list(string).

lgra_2_9_6_5_refusals(if_time(_), Known) = Refusals :-
    ( if Known = yes(K), K ^ dt_leaf \= lk_time then
        Refusals = ["a timestamp spec applies to a `Time`, and this value is "
            ++ "not one ([LGRA.2.9.6.4])"]
    else
        Refusals = []
    ).
lgra_2_9_6_5_refusals(if_num(NF), Known) = Refusals :-
    Leaf = ( if Known = yes(K) then yes(K ^ dt_leaf) else no ),
    Textual = ( if ( Leaf = yes(lk_string) ; Leaf = yes(lk_bool) )
                then yes else no ),
    Type = NF ^ nf_type,
    Integer = ( if Type = yes(T), integer_spec_type(T) then yes else no ),
    Refusals = list.condense([
        ( if NF ^ nf_align = yes(_), NF ^ nf_width = no then
            ["an alignment needs a width ([LGRA.2.9.6.5])"] else [] ),
        ( if NF ^ nf_zero = yes, NF ^ nf_align = yes('<') then
            ["zero padding cannot be left-aligned ([LGRA.2.9.6.5])"] else [] ),
        ( if Textual = yes, ( NF ^ nf_plus = yes ; NF ^ nf_zero = yes ) then
            ["a sign or zero padding applies to a number, and this value is "
                ++ "a `String` or a `Bool` ([LGRA.2.9.6.5])"] else [] ),
        ( if Integer = yes, NF ^ nf_precision = yes(_) then
            ["`d`, `x`, `X` and `b` take no precision ([LGRA.2.9.6.5])"]
          else [] ),
        ( if Type = yes('f'), NF ^ nf_precision = yes(P), P > 20u32 then
            ["`f` takes a precision of at most 20 ([LGRA.2.9.6.5]); for more "
                ++ "places, write the value with no type, in its canonical "
                ++ "form ([LDET.3.2.7])"]
          else [] ),
        ( if Type = yes(T2), Leaf = yes(L), not type_takes(T2, L) then
            ["`" ++ string.char_to_string(T2) ++ "` does not take "
                ++ leaf_phrase(L) ++ " ([LGRA.2.9.6.5])"]
          else [] ),
        ( if
            Type = no,
            NF ^ nf_precision = yes(_),
            Leaf = yes(L3),
            L3 \= lk_string
        then
            ["a precision with no type applies only to a `String`, and this "
                ++ "value is " ++ leaf_phrase(L3) ++ ": write `f` for decimal "
                ++ "places, or no precision for the canonical form "
                ++ "([LGRA.2.9.6.5])"]
          else [] )
    ]).

    %@helper
:- pred integer_spec_type(char::in) is semidet.

integer_spec_type('d').
integer_spec_type('x').
integer_spec_type('X').
integer_spec_type('b').

    % `u`'s unit is checked by the caller. `i` and `j` never reach here:
    % `luni_11_2_format` refuses them first.
    %
    %@helper
:- pred type_takes(char::in, leaf_kind::in) is semidet.

type_takes(T, Leaf) :-
    ( integer_spec_type(T), Leaf = lk_int
    ; T = 'f', ( Leaf = lk_float ; Leaf = lk_int )
    ; T = 's', Leaf = lk_string
    ; T = 'u', ( Leaf = lk_float ; Leaf = lk_int )
    ; ( T = 'i' ; T = 'j' ), Leaf \= lk_bool
    ).

    %@helper
:- func leaf_phrase(leaf_kind) = string.

leaf_phrase(Leaf) =
    ( if Leaf = lk_int then "an `Int`"
    else if Leaf = lk_float then "a `Float`"
    else if Leaf = lk_bool then "a `Bool`"
    else if Leaf = lk_string then "a `String`"
    else if Leaf = lk_time then "a `Time`"
    else if Leaf = lk_date then "a `Date`"
    else if Leaf = lk_duration then "a `Duration`"
    else "this value's type"
    ).

    % A string directly under `cached` is eligible, so it is skipped here; its
    % segments are `lgra_2_9_6_8_cached_key`'s.
    %
    %@helper
:- pred inert_interpolation(ast_rule::in, list(diagnostic)::out) is det.

inert_interpolation(Rule, Errors) :-
    Exprs = rule_predicates(Rule)
        ++ list.map(let_expression, rule_let_bindings(Rule)),
    Strings = list.condense(list.map(inert_strings, Exprs)),
    list.foldl(inert_string, Strings, [], RevErrors),
    Errors = reverse(RevErrors).

    %@helper
:- func inert_strings(lgra_9_3_1_expr) = list(pair(string, pos)).

inert_strings(Expr) = Strings :-
    ( if Expr = ex_string(Text, Pos) then
        Strings = [Text - Pos]
    else if
        Expr = ex_call(ex_name(Callee), Args, _),
        Callee ^ id_name = "cached"
    then
        Strings = list.condense(list.map(inert_strings,
            list.filter((pred(A::in) is semidet :- not A = ex_string(_, _)),
                Args)))
    else
        Strings = list.condense(list.map(inert_strings, expr_children(Expr)))
    ).

    %@helper
:- pred inert_string(pair(string, pos)::in,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

inert_string(Text - Pos, !Errors) :-
    ( if
        list.find_first_match((pred(P::in) is semidet :- interp_path(P, _)),
            interp_site_paths(string.to_char_list(Text)), Path)
    then
        !:Errors = [with_hint(error_at(dv_interp_inert_position, Pos,
            "`{" ++ string.from_char_list(Path) ++ "}` is in a string that "
                ++ "is not an action argument, where it would ship as literal "
                ++ "text ([LGRA.2.9.6.8])"),
            "interpolate in the action, or write `{{` for a literal brace")
            | !.Errors]
    else
        true
    ).

    % A site's body has no expression node, so `interp_access` rebuilds the
    % access chain to type it.
    %
    %@spec [LOPQ.3.3]
:- pred lopq_3_3_interpolated(type_env::in, list(char)::in, pos::in,
                              list(diagnostic)::in, list(diagnostic)::out)
                              is det.

lopq_3_3_interpolated(Env, Path, Pos, !Errors) :-
    ( if
        Segments = string.split_at_char('.', string.from_char_list(Path)),
        interp_access(Pos, Segments, Expr),
        type_of_expr(Env, Expr) = ty_known(Known),
        Known ^ dt_leaf = lk_opaque(Sealed)
    then
        !:Errors = [with_hint(error_at(dv_opaque_no_op, Pos,
            "`{" ++ string.from_char_list(Path) ++ "}` interpolates an opaque `"
                ++ Sealed ^ dr_name
                ++ "`, whose representation is sealed ([LOPQ.3.3])"),
            "an opaque value has no string form in a rule; log a slot the "
                ++ "adapter derived from it instead") | !.Errors]
    else
        true
    ).

    % A `Json` or `Json?` slot read off a pattern binding with no path after
    % it, followed through `let`s as [LLET.12.5] inlines them.
    %
    %@spec [LGRA.2.9.6.11]
:- pred lgra_2_9_6_11_whole_json(type_env::in, lgra_9_3_1_expr::in, int::in)
    is semidet.

lgra_2_9_6_11_whole_json(Env, E, Depth) :-
    Scope = Env ^ te_scope,
    ( if
        E = ex_name(Name),
        map.search(Scope ^ rsc_let_exprs, Name ^ id_name, Rhs)
    then
        Depth =< map.count(Scope ^ rsc_let_exprs),
        lgra_2_9_6_11_whole_json(Env, Rhs, Depth + 1)
    else
        E = ex_slot(ex_name(Binding), _, _),
        map.contains(Scope ^ rsc_bindings, Binding ^ id_name),
        type_of_expr(Env, E) = ty_known(Known),
        Known ^ dt_leaf = lk_json
    ).

    % Fails on a body with bracket indexing, which reads a `Json` path.
    %
    %@helper
:- pred interp_access(pos::in, list(string)::in,
                      lgra_9_3_1_expr::out) is semidet.

interp_access(Pos, [Head | Tail], Expr) :-
    not string.contains_char(Head, '['),
    list.foldl(interp_field(Pos), Tail, ex_name(ident(Head, Pos)), Expr).

    %@helper
:- pred interp_field(pos::in, string::in,
                     lgra_9_3_1_expr::in, lgra_9_3_1_expr::out) is semidet.

interp_field(Pos, Field, Base, ex_slot(Base, ident(Field, Pos), Pos)) :-
    not string.contains_char(Field, '[').

    %@helper
:- func take_to_colon(list(char)) = list(char).

take_to_colon(Body) = Path :-
    site_split(Body, Path, _).

    %@helper
:- pred interp_path(list(char)::in, string::out) is semidet.

interp_path(Chars, Leading) :-
    lgra_2_9_6_1_path(Chars, Leading).

    % Unlike the value namespace elsewhere, not a builtin function's name.
    %
    %@helper
:- pred interp_binding(type_env::in, string::in) is semidet.

interp_binding(Env, Name) :-
    Scope = Env ^ te_scope,
    ( map.contains(Scope ^ rsc_bindings, Name)
    ; map.contains(Scope ^ rsc_captures, Name)
    ; map.contains(Scope ^ rsc_lets, Name)
    ; map.contains(Env ^ te_file ^ rf_consts, Name)
    ).

    % The chain, or a shorter chain it extends, is an imported library's
    % member; the tail is access on its value (`lib.CONST.utc`).
    %
    %@spec [LGRA.2.9.6.2]
:- pred lgra_2_9_6_2_library_member(type_env::in, lgra_9_3_1_expr::in)
    is semidet.

lgra_2_9_6_2_library_member(Env, Expr) :-
    ( lgra_22_9_library_member(Env ^ te_file, Expr, _, _)
    ; Expr = ex_slot(Base, _, _),
      lgra_2_9_6_2_library_member(Env, Base)
    ).

%-----------------------------------------------------------------------------%
% Schema references outside a pattern head
%-----------------------------------------------------------------------------%

    % As `dsc.resolve`'s `lgra_22_4_pattern_head` does, this trusts a
    % selectively imported name and a library that did not load.
    %
    %@spec [LGRA.22.4]
    %@spec [LIMP.4.3.2]
:- pred lgra_22_4_schema_ref(resolved_file::in, string::in, ast_type_ref::in,
                             list(diagnostic)::in, list(diagnostic)::out)
    is det.

lgra_22_4_schema_ref(RF, Site, atr_bare(Id), !Errors) :-
    Name = Id ^ id_name,
    ( if schema_in_scope(RF, Name) then
        true
    else
        D = with_hint(error_at(dv_unknown_schema, Id ^ id_pos,
            "`" ++ Site ++ " " ++ Name ++ "`: unknown schema `" ++ Name
                ++ "` ([LGRA.22.4])"),
            "declare it in this file, or bring it into scope with "
                ++ "`from <lib> import " ++ Name ++ "`"),
        !:Errors = [D | !.Errors]
    ).
lgra_22_4_schema_ref(RF, Site, atr_qualified(Path, Id), !Errors) :-
    Qualifier = string.join_list(".", list.map((func(I) = I ^ id_name), Path)),
    Spelled = Qualifier ++ "." ++ Id ^ id_name,
    ( if not qualified_import(RF ^ rf_ast ^ af_decls, Qualifier) then
        !:Errors = [with_hint(error_at(dv_unknown_qualifier, Id ^ id_pos,
            "`" ++ Site ++ " " ++ Spelled ++ "`: library `"
                ++ Qualifier ++ "` is not in scope"),
            "add `import " ++ Qualifier ++ "` above the first declaration")
            | !.Errors]
    else if
        limp_4_3_2_not_exported(RF ^ rf_qualified_surface,
            RF ^ rf_qualified_schemas, Path, Id)
    then
        !:Errors = [with_hint(error_at(dv_unknown_schema, Id ^ id_pos,
            "`" ++ Site ++ " " ++ Spelled ++ "`: library `"
                ++ Qualifier ++ "` exports no schema `" ++ Id ^ id_name
                ++ "` ([LIMP.4.3.2])"),
            "a leading `_` keeps a name library-internal ([LIMP.4.3.1])")
            | !.Errors]
    else
        true
    ).

    %@helper
:- pred qualified_import(list(ast_decl)::in, string::in) is semidet.

qualified_import([D | Ds], Binding) :-
    ( if
        D = ad_import(Import),
        Import ^ ai_form = aif_qualified(_, Binding)
    then
        true
    else
        qualified_import(Ds, Binding)
    ).

    %@helper
:- pred schema_in_scope(resolved_file::in, string::in) is semidet.

schema_in_scope(RF, Name) :-
    ( if map.search(RF ^ rf_types, Name, Entry) then
        Entry = te_schema(_)
    else
        selectively_imported(RF ^ rf_ast ^ af_decls, Name)
    ).

    %@helper
:- pred selectively_imported(list(ast_decl)::in, string::in) is semidet.

selectively_imported([D | Ds], Name) :-
    ( if
        D = ad_import(Import),
        Import ^ ai_form = aif_selective(Items),
        binds_name(Items, Name)
    then
        true
    else
        selectively_imported(Ds, Name)
    ).

    %@helper
:- pred binds_name(list(ast_import_item)::in, string::in) is semidet.

binds_name([Item | Items], Name) :-
    ( if Item ^ aii_binding = Name then true else binds_name(Items, Name) ).

%-----------------------------------------------------------------------------%
% The emit lifecycle flag
%-----------------------------------------------------------------------------%

    % The refusals that the flag cannot answer come first, since adding or
    % removing `logical` would not make those emits legal.
    %
    %@spec [LLOG.11.1]
    %@spec [LSCP.2.6.1]
    %@spec [LCRS.4.3.4]
:- pred llog_11_1_lifecycle_flag(resolved_file::in, string::in, ident::in,
                                 ast_schema::in, list(ast_action_arg)::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
    is det.

llog_11_1_lifecycle_flag(RF, Verb, SchemaId, Schema, Args, !Errors) :-
    ( if
        ( Verb = "emit" ; Verb = "publish" )
    then
        Name = Schema ^ as_name ^ id_name,
        Pos = SchemaId ^ id_pos,
        Lifecycle = Schema ^ as_lifecycle,
        ( if Lifecycle = al_internal then
            D = with_hint(error_at(dv_internal_emit_forbidden, Pos,
                "`" ++ Verb ++ " " ++ Name ++ "`: `" ++ Name ++ "` is a "
                    ++ "built-in fault schema, and only the engine asserts "
                    ++ "its facts ([LSCP.2.6.1], [LERR.9.4])"),
                "match it in a rule's patterns, and `withdraw` the fact to "
                    ++ "acknowledge the fault"),
            !:Errors = [D | !.Errors]
        else if ambient_schema(Lifecycle) then
            D = with_hint(error_at(dv_ambient_emit_forbidden, Pos,
                "`" ++ Verb ++ " " ++ Name ++ "`: schema `" ++ Name
                    ++ "` declares the `ambient` permissions modifier, and "
                    ++ "rule code cannot emit an ambient schema "
                    ++ "([LSCP.2.5.1])"),
                "ambient schemas are populated from outside rule logic; to "
                    ++ "trigger something, emit a request schema and let the "
                    ++ "adapter react"),
            !:Errors = [D | !.Errors]
        else if lcrs_4_3_4_answer_schema(RF, Schema ^ as_own) then
            !:Errors = [lcrs_4_3_4_refused(Verb, SchemaId, Name) | !.Errors]
        else if Verb = "publish" then
            % [LLOG.11.1] names `emit`: a `publish` asserts nothing here
            % ([LTIE.4.3]), so it neither needs nor admits `logical`, which
            % `ltie_4_9_publish_modifier` has refused and taken out of `Args`.
            true
        else if has_flag(Args, "logical"), not Lifecycle = al_logical(_) then
            D = error_at(dv_bad_lifecycle_flag, Pos,
                "`" ++ Verb ++ " " ++ Name ++ " logical`: schema `" ++ Name
                    ++ "` has lifecycle `" ++ lifecycle_name(Lifecycle)
                    ++ "`, not `logical` ([LFAC.1.2.5])"),
            !:Errors = [D | !.Errors]
        else if not has_flag(Args, "logical"), Lifecycle = al_logical(_) then
            D = with_hint(error_at(dv_bad_lifecycle_flag, Pos,
                "`" ++ Verb ++ " " ++ Name ++ "`: schema `" ++ Name
                    ++ "` is declared `logical` ([LLOG.11.1])"),
                "write `" ++ Verb ++ " " ++ Name ++ " logical` -- the lifetime "
                    ++ "is a property of the schema and the emit has to say so"),
            !:Errors = [D | !.Errors]
        else
            true
        )
    else
        true
    ).

    % `Name` is the schema's own ([LIMP.13.1]), as `dsc.rete`'s
    % `call_response_schema` resolves a response. `rf_response_names` holds the
    % file's services and its import closure's, and `rf_program_responses` what
    % a library's importer declares.
    %
    %@spec [LCRS.4.3.4]
:- pred lcrs_4_3_4_answer_schema(resolved_file::in, string::in) is semidet.

lcrs_4_3_4_answer_schema(RF, Name) :-
    ( Name = "CallError"
    ; list.member(Name, map.values(RF ^ rf_response_names))
    ; list.member(Name, RF ^ rf_program_responses)
    ).

    %@spec [LCRS.4.3.4]
:- func lcrs_4_3_4_refused(string, ident, string) = diagnostic.

lcrs_4_3_4_refused(Verb, SchemaId, Name) =
    with_hint(error_at(dv_answer_emit_forbidden, SchemaId ^ id_pos,
        "`" ++ Verb ++ " " ++ Name ++ "`: a `" ++ Name ++ "` is a call's "
            ++ "answer, which the adapter asserts and a rule does not "
            ++ "([LCRS.4.3.4])"),
        "a rule may match an answer; to produce a fact of the same shape, "
            ++ "declare a schema of its own and match both").

    % A continuation body inside the `after` is not one of these: it runs in
    % the rule the response fact matches ([LCCO.6]).
    %
    %@spec [LLOG.11.9]
:- func llog_11_9_self_ending(resolved_file, ast_after_clause)
    = list(diagnostic).

llog_11_9_self_ending(RF, After) =
    list.filter_map(llog_11_9_logical_emit(RF), After ^ aaf_actions)
        ++ list.condense(list.map(llog_11_9_self_ending(RF),
            After ^ aaf_nested)).

    %@helper
:- func llog_11_9_logical_emit(resolved_file, ast_action) = diagnostic
    is semidet.

llog_11_9_logical_emit(RF, Action) = D :-
    llog_11_9_logical_emit_head(RF, Action, Verb, SchemaId),
    Name = SchemaId ^ id_name,
    D = with_hint(error_at(dv_logical_emit_self_ending, SchemaId ^ id_pos,
        "`" ++ Verb ++ " " ++ Name ++ " logical` in an `after` body: the "
            ++ "body runs in the follow-up rule, whose only pattern is the "
            ++ "timer it retracts, so the fact would be withdrawn as it is "
            ++ "made ([LLOG.11.9])"),
        "emit a `ttl` fact from the `after` body, and let a second rule "
            ++ "joining it to the condition that should keep the fact alive "
            ++ "emit the `logical` one").

    %@helper
:- pred llog_11_9_logical_emit_head(resolved_file::in, ast_action::in,
    string::out, ident::out) is semidet.

llog_11_9_logical_emit_head(RF, Action, Verb, SchemaId) :-
    fact_verb(Action ^ aac_head, Verb, Ref),
    ( Verb = "emit" ; Verb = "publish" ),
    has_flag(Action ^ aac_args ++ block_args(Action ^ aac_block), "logical"),
    lgra_22_4_schema_of(RF, Ref, Schema),
    Schema ^ as_lifecycle = al_logical(_),
    ( Ref = atr_bare(SchemaId)
    ; Ref = atr_qualified(_, SchemaId)
    ).

    % The top-level actions only, in source order, so not `rule_actions`: a
    % nested body runs in a rule of its own. A `withdraw` of a name the rule
    % does not bind is refused where it is resolved, and starts nothing here.
    %
    %@spec [LLOG.11.9]
:- func llog_11_9_emit_after_withdraw(resolved_file, rule_scope, ast_rule)
    = list(diagnostic).

llog_11_9_emit_after_withdraw(RF, Scope, Rule) = Errors :-
    list.foldl2(llog_11_9_after_withdraw_step(RF, Scope),
        Rule ^ ar_rhs ^ arr_actions, no, _, [], Rev),
    Errors = list.reverse(Rev).

    %@helper
:- pred llog_11_9_after_withdraw_step(resolved_file::in, rule_scope::in,
    ast_action::in, maybe({string, pos})::in, maybe({string, pos})::out,
    list(diagnostic)::in, list(diagnostic)::out) is det.

llog_11_9_after_withdraw_step(RF, Scope, Action, !Withdrawn, !Errors) :-
    ( if
        !.Withdrawn = yes({Binding, At}),
        llog_11_9_logical_emit_head(RF, Action, Verb, SchemaId)
    then
        Name = SchemaId ^ id_name,
        !:Errors = [with_hint(error_at(dv_logical_emit_self_ending,
            SchemaId ^ id_pos,
            "`" ++ Verb ++ " " ++ Name ++ " logical` after `withdraw "
                ++ Binding ++ "` on line " ++ string.from_int(At ^ p_line)
                ++ ": the `withdraw` ends the match that would justify the "
                ++ "fact, so it would be withdrawn as it is made "
                ++ "([LLOG.11.9])"),
            "emit it before the `withdraw`, or emit a `ttl` or `explicit` "
                ++ "fact, or a `logical` one that another rule's join "
                ++ "justifies") | !.Errors]
    else if
        !.Withdrawn = no,
        Action ^ aac_head = aah_withdraw(Id),
        map.contains(Scope ^ rsc_bindings, Id ^ id_name)
    then
        !:Withdrawn = yes({Id ^ id_name, Action ^ aac_pos})
    else
        true
    ).

    % Only a `logical` schema has an identity, so only an emit into one
    % replaces anything. A logical schema with no key holds one fact. A
    % replacement only run-time values decide is [LLOG.15.1]'s.
    %
    %@spec [LLOG.11.9]
:- func llog_11_9_self_replacing(resolved_file, ast_rule) = list(diagnostic).

llog_11_9_self_replacing(RF, Rule) = Errors :-
    Bodies = list.condense(list.map(positive_bodies, Rule ^ ar_lhs)),
    list.foldl2(llog_11_9_self_replacing_step(RF, Bodies),
        Rule ^ ar_rhs ^ arr_actions, no, _, [], Rev),
    Errors = list.reverse(Rev).

    %@helper
:- pred llog_11_9_self_replacing_step(resolved_file::in,
    list(ast_pattern_body)::in, ast_action::in,
    maybe({string, pos})::in, maybe({string, pos})::out,
    list(diagnostic)::in, list(diagnostic)::out) is det.

llog_11_9_self_replacing_step(RF, Bodies, Action, !Replaced, !Errors) :-
    ( if replaced_binding(RF, Bodies, Action, Binding, SchemaId) then
        ( if llog_11_9_logical_emit_head(RF, Action, Verb, _) then
            Name = SchemaId ^ id_name,
            !:Errors = [with_hint(error_at(dv_logical_emit_self_ending,
                SchemaId ^ id_pos,
                "`" ++ Verb ++ " " ++ Name ++ " logical` replaces the fact `"
                    ++ Binding ++ "` matched: its key is `" ++ Binding
                    ++ "`'s, and it gives a slot a literal the pattern "
                    ++ "refuses, so the match ends here and the fact would be "
                    ++ "withdrawn as it is made ([LLOG.11.9])"),
                "emit a fact of another key, or a `ttl` fact that a second "
                    ++ "rule's join turns into the `logical` one")
                | !.Errors]
        else
            % A plain emit is `llog_11_1_lifecycle_flag`'s.
            true
        ),
        ( if !.Replaced = no then
            !:Replaced = yes({Binding, Action ^ aac_pos})
        else
            true
        )
    else if
        !.Replaced = yes({Ended, At}),
        llog_11_9_logical_emit_head(RF, Action, LaterVerb, LaterId)
    then
        LaterName = LaterId ^ id_name,
        !:Errors = [with_hint(error_at(dv_logical_emit_self_ending,
            LaterId ^ id_pos,
            "`" ++ LaterVerb ++ " " ++ LaterName ++ " logical` after the emit "
                ++ "on line " ++ string.from_int(At ^ p_line)
                ++ ", which replaces the fact `" ++ Ended ++ "` matched: the "
                ++ "match ended there, so the fact would be withdrawn as it is "
                ++ "made ([LLOG.11.9])"),
            "emit it before the replacing emit, or emit a `ttl` or `explicit` "
                ++ "fact, or a `logical` one that another rule's join "
                ++ "justifies") | !.Errors]
    else
        true
    ).

    %@helper
:- pred replaced_binding(resolved_file::in, list(ast_pattern_body)::in,
    ast_action::in, string::out, ident::out) is semidet.

replaced_binding(RF, Bodies, Action, Binding, SchemaId) :-
    fact_verb(Action ^ aac_head, "emit", Ref),
    lgra_22_4_schema_of(RF, Ref, Schema),
    Schema ^ as_lifecycle = al_logical(_),
    ( Ref = atr_bare(SchemaId)
    ; Ref = atr_qualified(_, SchemaId)
    ),
    Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
    Keys = schema_keys(Schema),
    list.find_first_map(
        ( pred(Body::in, B::out) is semidet :-
            Body ^ apb_binding = yes(BId),
            B = BId ^ id_name,
            lgra_22_4_schema_of(RF, Body ^ apb_type, Schema),
            list.all_true(key_from_binding(B, Args), Keys),
            Body ^ apb_where = yes(Where),
            llog_11_9_literal_breaks(B, Where, Keys, Args)
        ), Bodies, Binding).

    %@helper
:- pred key_from_binding(string::in, list(ast_action_arg)::in, string::in)
    is semidet.

key_from_binding(Binding, Args, Key) :-
    list.find_first_match(
        ( pred(A::in) is semidet :-
            A = aaa_kwarg(Name, _, _),
            Name ^ id_name = Key
        ), Args, aaa_kwarg(_, Value, _)),
    Value = ex_slot(ex_name(Base), Slot, _),
    Base ^ id_name = Binding,
    Slot ^ id_name = Key.

    %@helper
:- pred ambient_schema(ast_lifecycle::in) is semidet.

ambient_schema(al_logical(aa_ambient)).
ambient_schema(al_ttl(_, aa_ambient)).

    %@helper
:- pred has_flag(list(ast_action_arg)::in, string::in) is semidet.

has_flag([Arg | Args], Name) :-
    ( if Arg = aaa_flag(Id), Id ^ id_name = Name then
        true
    else
        has_flag(Args, Name)
    ).

    %@helper
:- func lifecycle_name(ast_lifecycle) = string.

lifecycle_name(al_explicit) = "explicit".
lifecycle_name(al_internal) = "internal".
lifecycle_name(al_activation) = "activation".
lifecycle_name(al_logical(_)) = "logical".
lifecycle_name(al_ttl(_, _)) = "ttl".

%-----------------------------------------------------------------------------%
% The `call` rate contract
%-----------------------------------------------------------------------------%

    %@spec [LCRS.8.1]
:- pred lcrs_8_1_call_rate(ast_action::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lcrs_8_1_call_rate(Action, !Errors) :-
    ( if
        Action ^ aac_head = aah_call(Ref),
        Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
        not has_flag(Args, "nocooldown"),
        not has_kwarg(Args, "cooldown")
    then
        !:Errors = [with_hint(error_at(dv_call_rate_mod, Action ^ aac_pos,
            "`call " ++ service_text(Ref) ++ "` states neither `cooldown: "
                ++ "<duration>` nor `nocooldown` ([LCRS.8.1])"),
            "every `call` opts into one or the other; a silent default would "
                ++ "leave the call rate unbounded") | !.Errors]
    else
        true
    ).

    % `lgra_10_3_1_parse_args` reads `as: X` as a kwarg called `as`.
    %
    %@spec [LRST.1.3]
:- pred lrst_1_3_legacy_as_colon(ast_action::in,
                                 list(diagnostic)::in, list(diagnostic)::out)
    is det.

lrst_1_3_legacy_as_colon(Action, !Errors) :-
    ( if
        Action ^ aac_head = aah_call(_),
        Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
        list.find_first_match(
            ( pred(A::in) is semidet :-
                A = aaa_kwarg(N, _, _), N ^ id_name = "as" ),
            Args, aaa_kwarg(Name, _, _))
    then
        !:Errors = [with_hint(error_at(dv_legacy_as_colon, Name ^ id_pos,
            "`as:` is not a `call` argument: the correlation is the `as` "
                ++ "clause, with no colon ([LRST.1.3])"),
            "write `as` followed by the expression, as in `as \"fc-daily\"` "
                ++ "([LRST.1.1])") | !.Errors]
    else
        true
    ).

%-----------------------------------------------------------------------------%
% `withdraw`
%-----------------------------------------------------------------------------%

    % Only `head_local` is checked: an imported or qualified head carries no
    % schema here, so its lifecycle is unknown.
    %
    %@spec [LSCO.4.5.9]
    %@spec [LLOG.11.8]
    %@spec [LSCP.2.6.1]
:- pred lsco_4_5_9_withdraw_scope(rule_scope::in, ast_action::in,
                                  list(diagnostic)::in, list(diagnostic)::out)
                                  is det.

lsco_4_5_9_withdraw_scope(Scope, Action, !Errors) :-
    ( if
        Action ^ aac_head = aah_withdraw(Binding),
        map.search(Scope ^ rsc_bindings, Binding ^ id_name, PB),
        PB ^ pb_head = head_local(Schema),
        Schema ^ as_lifecycle \= al_explicit,
        Schema ^ as_lifecycle \= al_internal
    then
        !:Errors = [with_hint(error_at(dv_withdraw_scope, Action ^ aac_pos,
            "`withdraw " ++ Binding ^ id_name ++ "` names a `"
                ++ lifecycle_word(Schema ^ as_lifecycle) ++ "` fact; only an "
                ++ "`explicit` one, or a fault fact, may be withdrawn "
                ++ "([LSCO.4.5.9], [LSCP.2.6.1])"),
            "a `logical` fact is retracted when its justification ends and a "
                ++ "`ttl` fact when it expires -- withdrawing one by hand "
                ++ "races the mechanism that owns it") | !.Errors]
    else
        true
    ).

    %@helper
:- func lifecycle_word(ast_lifecycle) = string.

lifecycle_word(al_explicit) = "explicit".
lifecycle_word(al_internal) = "internal".
lifecycle_word(al_activation) = "activation".
lifecycle_word(al_logical(_)) = "logical".
lifecycle_word(al_ttl(_, _)) = "ttl".

    %@spec [LCYC.3.3.3]
:- pred lcyc_3_3_3_withdraw_emit(resolved_file::in, rule_scope::in,
                                 ast_rule::in, list(diagnostic)::out) is det.

lcyc_3_3_3_withdraw_emit(RF, Scope, Rule, Errors) :-
    Actions = rule_actions(Rule),
    list.filter_map(emitted_schema(RF), Actions, Emitted),
    list.foldl(withdraw_of_emitted(Scope, Emitted), Actions, [], Rev),
    Errors = reverse(Rev).

    % The schema an `emit` names: the schema, not its spelling, since a
    % library's `X` is not this file's `X`. A `publish` names none here: it
    % asserts nothing in this tier ([LTIE.4.3]), so a rule that publishes `X`
    % and withdraws a binding of `X` matches nothing it makes, and is no SCC
    % [LCYC.3.1.1] refuses.
    %
    %@helper
:- pred emitted_schema(resolved_file::in, ast_action::in, ast_schema::out)
    is semidet.

emitted_schema(RF, Action, Schema) :-
    Action ^ aac_head = aah_emit(Ref),
    lgra_22_4_schema_of(RF, Ref, Schema).

    %@helper
:- pred withdraw_of_emitted(rule_scope::in, list(ast_schema)::in,
                            ast_action::in,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

withdraw_of_emitted(Scope, Emitted, Action, !Errors) :-
    ( if
        Action ^ aac_head = aah_withdraw(Binding),
        map.search(Scope ^ rsc_bindings, Binding ^ id_name, PB),
        PB ^ pb_head = head_local(Schema),
        Name = Schema ^ as_name ^ id_name,
        list.member(Schema, Emitted)
    then
        !:Errors = [with_hint(
            error_at(dv_withdraw_emit_same_schema, Action ^ aac_pos,
                "`withdraw " ++ Binding ^ id_name ++ "` names a `" ++ Name
                    ++ "`, which this rule also emits ([LCYC.3.3.3])"),
            "split the emit and the withdraw into separate rules, or "
                ++ "withdraw a binding of a different schema") | !.Errors]
    else
        true
    ).

    % A `withdraw` in a nested body starts a count for that body alone; to the
    % outer walk it is a reference. `action_references` counts a second
    % `withdraw b` as one. Reported at the action or `after` clause: the walk
    % keeps names, not positions.
    %
    %@helper
:- pred withdrawn_binding_used(ast_rule::in, list(diagnostic)::out) is det.

withdrawn_binding_used(Rule, Errors) :-
    Rhs = Rule ^ ar_rhs,
    withdrawn_body(Rhs ^ arr_actions, Rhs ^ arr_afters, [], Rev),
    Errors = list.reverse(Rev).

    %@helper
:- pred withdrawn_body(list(ast_action)::in, list(ast_after_clause)::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

withdrawn_body(Actions, Afters, !Errors) :-
    list.foldl2(withdrawn_step, Actions, map.init, Withdrawn, !Errors),
    list.foldl(withdrawn_after(Withdrawn), Afters, !Errors),
    list.foldl(withdrawn_continuations, Actions, !Errors),
    list.foldl(withdrawn_after_body, Afters, !Errors).

    %@helper
:- pred withdrawn_continuations(ast_action::in,
                                list(diagnostic)::in, list(diagnostic)::out)
    is det.

withdrawn_continuations(Action, !Errors) :-
    ( if Action ^ aac_block = aab_call(_, Conts) then
        list.foldl(
            ( pred(Cont::in, E0::in, E::out) is det :-
                withdrawn_body(cont_body_actions(Cont), [], E0, E) ),
            Conts, !Errors)
    else
        true
    ).

    %@helper
:- pred withdrawn_after_body(ast_after_clause::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

withdrawn_after_body(After, !Errors) :-
    withdrawn_body(After ^ aaf_actions, After ^ aaf_nested, !Errors).

    %@helper
:- func cont_body_actions(ast_continuation) = list(ast_action).

cont_body_actions(acont_on(_, Actions, _)) = Actions.
cont_body_actions(acont_timeout(_, Actions, _)) = Actions.
cont_body_actions(acont_error(_, Actions, _)) = Actions.

    %@helper
:- pred withdrawn_step(ast_action::in,
                       map(string, pos)::in, map(string, pos)::out,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

withdrawn_step(Action, !Withdrawn, !Errors) :-
    action_references(Action, set.init, Refs),
    withdrawn_refs(!.Withdrawn, Refs, Action ^ aac_pos, !Errors),
    ( if
        Action ^ aac_head = aah_withdraw(Binding),
        not map.contains(!.Withdrawn, Binding ^ id_name)
    then
        map.det_insert(Binding ^ id_name, Action ^ aac_pos, !Withdrawn)
    else
        true
    ).

    %@helper
:- pred withdrawn_after(map(string, pos)::in, ast_after_clause::in,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

withdrawn_after(Withdrawn, After, !Errors) :-
    after_references(After, set.init, Refs),
    withdrawn_refs(Withdrawn, Refs, After ^ aaf_pos, !Errors).

    %@helper
:- pred withdrawn_refs(map(string, pos)::in, set(string)::in, pos::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

withdrawn_refs(Withdrawn, Refs, Pos, !Errors) :-
    list.foldl(
        ( pred(Name - At::in, E0::in, E::out) is det :-
            ( if set.contains(Refs, Name) then
                E = [with_hint(error_at(dv_withdrawn_binding_used, Pos,
                    "`" ++ Name ++ "` is referred to after `withdraw " ++ Name
                        ++ "` on line " ++ string.from_int(At ^ p_line)
                        ++ " (LGRA.10.1.3)"),
                    "a withdrawn fact is gone for the rest of the rule's "
                        ++ "actions; read what you need before the `withdraw`")
                    | E0]
            else
                E = E0
            ) ),
        map.to_assoc_list(Withdrawn), !Errors).

%-----------------------------------------------------------------------------%
% Service resolution
%-----------------------------------------------------------------------------%

    % `rf_services` holds every service of the closure under its own name
    % ([LGRA.10.1.6]), so a path whose head names a library is a plain lookup.
    %
    %@spec [LADP.8.2.3]
    %@spec [LCRS.10.4.2]
    %@spec [LCRS.10.4.4]
:- pred ladp_8_2_3_service(resolved_file::in, ast_action::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

ladp_8_2_3_service(RF, Action, !Errors) :-
    ( if
        Action ^ aac_head = aah_call(asr_bare(Path)),
        Spelling = dotted(Path),
        not map.contains(RF ^ rf_services, Spelling)
    then
        !:Errors = [with_hint(error_at(dv_unknown_service, Action ^ aac_pos,
            "unknown service `" ++ Spelling ++ "`"), known_services(RF))
            | !.Errors]
    else
        true
    ).

    %@helper
:- func known_services(resolved_file) = string.

known_services(RF) = Text :-
    Known = map.keys(RF ^ rf_services),
    (
        Known = [],
        Text = "neither this file nor any library it imports declares a "
            ++ "`service`"
    ;
        Known = [_ | _],
        Text = "known: " ++ string.join_list(", ",
            list.map(backticked, Known))
    ).

    %@helper
:- func backticked(string) = string.

backticked(S) = "`" ++ S ++ "`".

    %@helper
:- pred has_kwarg(list(ast_action_arg)::in, string::in) is semidet.

has_kwarg([Arg | Args], Name) :-
    ( if Arg = aaa_kwarg(Id, _, _), Id ^ id_name = Name then
        true
    else
        has_kwarg(Args, Name)
    ).

    %@helper
:- func service_text(ast_service_ref) = string.

service_text(asr_bare(Path)) = dotted(Path).

    %@helper
:- func dotted(list(ident)) = string.

dotted(Ids) = string.join_list(".", list.map(id_text, Ids)).

    %@helper
:- func id_text(ident) = string.

id_text(Id) = Id ^ id_name.

    %@helper
:- func block_args(ast_action_block) = list(ast_action_arg).

block_args(aab_none) = [].
block_args(aab_kwargs(Args)) = Args.
block_args(aab_call(Args, _)) = Args.

    %@helper
:- pred check_kwarg(type_env::in, string::in, ast_schema::in,
                    ast_action_arg::in,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

check_kwarg(Env, Verb, Schema, Arg, !Errors) :-
    (
        Arg = aaa_flag(Flag),
        lgra_10_3_4_flag(Verb, Flag, !Errors)
    ;
        Arg = aaa_kwarg(Name, Value, Pos),
        ( if ldtl_4_1_retain_override(Verb, Name ^ id_name) then
            true
        else if find_slot(Schema ^ as_fields, Name ^ id_name, Slot) then
            lexp_7_3b_kwarg_type(Env, Verb, Schema, Slot, Value, Pos, !Errors),
            luni_13_5_2_implicit_round(Env, Slot, Value, Pos, !Errors),
            lstr_11_2_literal_capacity(Slot, Value, !Errors)
        else
            D = error_at(dv_bad_kwarg, Name ^ id_pos,
                "`" ++ Verb ++ " " ++ Schema ^ as_name ^ id_name
                    ++ "`: the schema has no slot `" ++ Name ^ id_name ++ "`"),
            !:Errors = [D | !.Errors]
        )
    ).

    %@spec [LDTL.4.1]
:- pred ldtl_4_1_retain_override(string::in, string::in) is semidet.

ldtl_4_1_retain_override("emit", "retain").

    % The intermediate is found by shape: a currency slot and a `Float ×
    % currency` product type alike ([LUNI.8.7.3]).
    %
    %@spec [LUNI.13.5.2]
:- pred luni_13_5_2_implicit_round(type_env::in, ast_field::in,
                                    lgra_9_3_1_expr::in, pos::in,
                                    list(diagnostic)::in, list(diagnostic)::out)
    is det.

luni_13_5_2_implicit_round(Env, Slot, Value, Pos, !Errors) :-
    ( if
        currency_slot(Env, Slot),
        fractional_currency(Env, Value)
    then
        !:Errors = [with_hint(error_at(dv_currency_implicit_round, Pos,
            "`" ++ Slot ^ af_name ^ id_name ++ "` is a currency slot and this "
                ++ "value is a fractional-currency intermediate; it is not "
                ++ "rounded implicitly ([LUNI.13.5.2])"),
            "round it explicitly: `(...).round(\"half_even\")`") | !.Errors]
    else
        true
    ).

    %@helper
:- pred currency_slot(type_env::in, ast_field::in) is semidet.

currency_slot(Env, Slot) :-
    TypeName = Slot ^ af_type ^ id_name,
    ( string.prefix(TypeName, "currency_")
    ; slot_entry(Env ^ te_file, Slot, Entry),
      Entry = te_unit(uk_symbol(Dimension), _),
      string.prefix(Dimension ^ dr_name, "currency_")
    ).

    %@helper
:- pred fractional_currency(type_env::in, lgra_9_3_1_expr::in) is semidet.

fractional_currency(Env, Expr) :-
    ( if Expr = ex_call(ex_slot(_, Method, _), _, _) then
        Method ^ id_name = "to_currency"
    else if Expr = ex_binary(Op, Left, Right, _) then
        ( if ( Op = bo_mul ; Op = bo_div ) then
            ( float_scaled_currency(Env, Left, Right)
            ; float_scaled_currency(Env, Right, Left)
            ; fractional_currency(Env, Left)
            ; fractional_currency(Env, Right)
            )
        else
            ( Op = bo_add ; Op = bo_sub ),
            ( fractional_currency(Env, Left)
            ; fractional_currency(Env, Right)
            )
        )
    else
        fail
    ).

    %@helper
:- pred float_scaled_currency(type_env::in, lgra_9_3_1_expr::in,
                              lgra_9_3_1_expr::in) is semidet.

float_scaled_currency(Env, Factor, Amount) :-
    type_of_expr(Env, Factor) = ty_known(FactorType),
    FactorType ^ dt_leaf = lk_float,
    FactorType ^ dt_dim = dimensionless,
    type_of_expr(Env, Amount) = ty_known(AmountType),
    AmountType ^ dt_dim = dim(Dimension, _),
    string.prefix(Dimension ^ dr_name, "currency_").

    %@helper
:- pred find_slot(list(ast_field)::in, string::in, ast_field::out) is semidet.

find_slot([F | Fs], Name, Found) :-
    ( if F ^ af_name ^ id_name = Name then
        Found = F
    else
        find_slot(Fs, Name, Found)
    ).

    % A value whose known leaf kind differs from its slot's is
    % DS_VALIDATE_TYPE_MISMATCH ([RARC.5.2.7]). Not checked: a unit-typed
    % slot, or a quantity into an `Int` or `Float` slot ([LUNI.8]'s); an
    % opaque side ([LOPQ.2.3]'s arm below); two fact references, since
    % `dsc.typecheck` spells a schema two ways; and a value that does not
    % type, `null` and a `Json` projection among them.
    %
    %@spec [LEXP.7.3b]
    %@spec [RARC.5.2.7]
    %@spec [LOPQ.2.3]
:- pred lexp_7_3b_kwarg_type(type_env::in, string::in, ast_schema::in,
                         ast_field::in, lgra_9_3_1_expr::in, pos::in,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

lexp_7_3b_kwarg_type(Env, Verb, Schema, Slot, Value, Pos, !Errors) :-
    ValueType = type_of_expr(Env, Value),
    (
        ValueType = ty_error(ValueErrors),
        !:Errors = reverse(ValueErrors) ++ !.Errors
    ;
        ( ValueType = ty_unknown
        ; ValueType = ty_known(_)
        )
    ),
    % No narrowing is consulted: [LNUL.5.2] stops the flow at the arrow.
    ( if
        slot_entry(Env ^ te_file, Slot, Entry0),
        Declared0 = luni_7_1_slot_type(Env ^ te_file ^ rf_unit_storage, Entry0,
            Slot ^ af_nullable),
        Declared0 ^ dt_null = non_null
    then
        !:Errors = reverse(lnul_5_1_concrete(Env, Value, ValueType, Pos,
            "a `" ++ Verb ++ "` value into the non-nullable slot `"
                ++ Slot ^ af_name ^ id_name ++ "`")) ++ !.Errors
    else
        true
    ),
    ( if
        slot_entry(Env ^ te_file, Slot, Entry),
        Declared = luni_7_1_slot_type(Env ^ te_file ^ rf_unit_storage, Entry,
            Slot ^ af_nullable),
        Declared ^ dt_dim = dimensionless,
        ValueType = ty_known(Actual),
        rarc_5_2_7_provable_mismatch(Declared, Actual)
    then
        D = with_hint(error_at(dv_type_mismatch, Pos,
            "`" ++ Verb ++ " " ++ Schema ^ as_name ^ id_name ++ "`: slot `"
                ++ Slot ^ af_name ^ id_name ++ "` is declared `"
                ++ Slot ^ af_type ^ id_name ++ "` and the value is `"
                ++ leaf_name(Actual ^ dt_leaf) ++ "`. A slot takes a value "
                ++ "of its declared type, with no implicit conversion; "
                ++ "promotion is an operator rule and stops at a slot "
                ++ "([RARC.5.2.7], [LEXP.7.3b])"),
            "convert explicitly where a cast exists ([LCST.4.1])"),
        !:Errors = [D | !.Errors]
    else
        true
    ),
    % [LOPQ.2.3]'s assignment position. Apart from the check above, whose hint
    % to cast would be wrong for an opaque type.
    ( if
        slot_entry(Env ^ te_file, Slot, OEntry),
        ODeclared = luni_7_1_slot_type(Env ^ te_file ^ rf_unit_storage, OEntry,
            Slot ^ af_nullable),
        ValueType = ty_known(OActual),
        ( ODeclared ^ dt_leaf = lk_opaque(_)
        ; OActual ^ dt_leaf = lk_opaque(_)
        ),
        OActual ^ dt_leaf \= ODeclared ^ dt_leaf
    then
        O = with_hint(error_at(dv_opaque_type_mismatch, Pos,
            "`" ++ Verb ++ " " ++ Schema ^ as_name ^ id_name ++ "`: slot `"
                ++ Slot ^ af_name ^ id_name ++ "` is declared `"
                ++ Slot ^ af_type ^ id_name
                ++ "` and the value is a "
                ++ "different type. An opaque type is nominal and distinct "
                ++ "from every other opaque type and from its own "
                ++ "representation ([LOPQ.2.3])"),
            "assign a value of the slot's own opaque type"),
        !:Errors = [O | !.Errors]
    else
        true
    ).

    % Both leaf kinds known and not one kind (`same_leaf_kind`, so an
    % `Interval` matches an `Interval`), outside the cases
    % `lexp_7_3b_kwarg_type` leaves unchecked.
    %
    %@spec [RARC.5.2.7]
:- pred rarc_5_2_7_provable_mismatch(ds_type::in, ds_type::in) is semidet.

rarc_5_2_7_provable_mismatch(Declared, Actual) :-
    DLeaf = Declared ^ dt_leaf,
    ALeaf = Actual ^ dt_leaf,
    not DLeaf = lk_opaque(_),
    not ALeaf = lk_opaque(_),
    not ( DLeaf = lk_fact(_), ALeaf = lk_fact(_) ),
    not (
        ( DLeaf = lk_int ; DLeaf = lk_float ),
        Actual ^ dt_dim \= dimensionless
    ),
    not same_leaf_kind(DLeaf, ALeaf).

    %@helper
:- func leaf_name(leaf_kind) = string.

leaf_name(lk_int) = "Int".
leaf_name(lk_float) = "Float".
leaf_name(lk_string) = "String".
leaf_name(lk_bool) = "Bool".
leaf_name(lk_bytes) = "Bytes".
leaf_name(lk_json) = "Json".
leaf_name(lk_time) = "Time".
leaf_name(lk_date) = "Date".
leaf_name(lk_duration) = "Duration".
leaf_name(lk_interval(_)) = "Interval".
leaf_name(lk_fact(Name)) = Name.
leaf_name(lk_opaque(Name)) = Name ^ dr_name.

%-----------------------------------------------------------------------------%
:- end_module dsc.validate.
%-----------------------------------------------------------------------------%

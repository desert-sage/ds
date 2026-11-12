% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.dstest -- `test` declarations to the `T*` / `O*` test atoms.
%
% Two entry points:
%
%   * `rtim_14_11_oracle_rules` runs on a module's AST before `resolve`: an
%     `emitted` / `published` `where` is a rule, and goes through the pipeline
%     as one.
%   * `rlow_17_1_lower_tests` runs after `validate`, once per module, and
%     produces the test IR `dsc.encode` writes.
%
% Tests are numbered across the artefact, by module in `module_id` order, so
% both take the number of the module's first test.
%
% A unit literal (`2.0_c`) as a constructed value is refused: it is a `Float` in
% the slot's canonical unit only after a conversion this module does not do.
%-----------------------------------------------------------------------------%

:- module dsc.dstest.
:- interface.

% The parent for the child's sake: `test_value` is `ds.value`'s.
:- import_module ds.
:- import_module ds.chrono.
:- import_module ds.value.
:- import_module dsc.ast.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.expr.
:- import_module dsc.resolve.
:- import_module dsc.token.

:- import_module bool.
:- import_module int64.
:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%

    %@helper
:- type test_slot
    --->    test_slot(
                tsl_name  :: string,
                tsl_value :: test_value
            ).

    %@helper
:- type test_polarity
    --->    tp_pos
    ;       tp_never.

    %@helper
:- type test_fact_ir
    --->    test_fact_ir(
                tfi_initial :: bool,
                tfi_when    :: uint64,
                tfi_schema  :: string,
                tfi_slots   :: list(test_slot),
                tfi_order   :: uint32
            ).

    % The literal and not its JSON text, which the interpreter renders.
    %
    %@helper
:- type test_seed_ir
    --->    test_seed_ir(
                tsi_key   :: string,
                tsi_value :: test_value
            ).

    %@helper
:- type test_reply_ir
    --->    test_reply_ir(
                tri_schema :: string,
                tri_slots  :: list(test_slot)
            ).

    %@helper
:- type test_stub_ir
    --->    test_stub_ir(
                tbi_id          :: uint32,
                tbi_service     :: string,
                tbi_corr        :: string,      % "" = keyed by arguments
                tbi_args        :: list(test_slot),
                tbi_after       :: uint64,
                tbi_no_response :: bool,
                tbi_replies     :: list(test_reply_ir)
            ).

    %@helper
:- type test_oracle_ir
    --->    toi_activated(test_polarity, string)
    ;       toi_emitted(test_polarity, string, list(test_slot), bool)
    ;       toi_published(test_polarity, string, list(test_slot), bool)
            % The `bool` is `has_where`.
    ;       toi_called(test_polarity, string, maybe(string))
    ;       toi_cached(test_polarity, string, maybe(test_value))
    ;       toi_cache_deleted(test_polarity, string)
    ;       toi_logged(test_polarity, uint32, maybe(string))
            % `LogSeverity`'s number, 0..4.
    ;       toi_retracted(test_polarity, string, list(test_slot))
    ;       toi_wm_has(test_polarity, string, list(test_slot))
    ;       toi_wm_count(test_polarity, string, uint32)
    ;       toi_wm_empty(test_polarity).

    %@helper
:- type test_ir
    --->    test_ir(
                ti_id       :: uint32,
                ti_name     :: string,
                ti_until    :: uint64,
                ti_absolute :: bool,
                ti_facts    :: list(test_fact_ir),
                ti_seeds    :: list(test_seed_ir),
                ti_stubs    :: list(test_stub_ir),
                ti_oracles  :: list(test_oracle_ir)
            ).

    %@helper
:- type test_outcome
    --->    tests_lowered(list(test_ir))
    ;       tests_rejected(list(diagnostic)).

    %@helper
:- type initial_item_ir
    --->    ii_fact(string, list(test_slot))
            % The schema as the artefact carries it, and the slots in source
            % order.
    ;       ii_seed(string, test_value).

    % A literal, or the name of a `const` whose value is one.
    %
    %@spec [LTSL.4.1]
:- pred ltsl_4_1_constant(resolved_file::in, lgra_9_3_1_expr::in,
                          test_value::out) is semidet.

    %@spec [LTSL.4.1]
:- pred ltsl_4_1_string_constant(resolved_file::in, lgra_9_3_1_expr::in,
                                 string::out) is semidet.

    % The `Int` an expression folds to, written in place or through a `const`.
    %
    %@spec [LEXP.8.8]
:- pred lexp_8_8_int_constant(resolved_file::in, lgra_9_3_1_expr::in,
                              int64::out) is semidet.

    % The nanoseconds of the `Duration` an expression folds to.
    %
    %@spec [LEXP.8.8]
:- pred lexp_8_8_duration_ns(resolved_file::in, lgra_9_3_1_expr::in,
                             int64::out) is semidet.

    % Whether an expression has a value at compile time.
    %
    %@spec [LEXP.8.8.1]
:- pred lexp_8_8_1_folds(resolved_file::in, lgra_9_3_1_expr::in) is semidet.

    %@spec [LEXP.7.1a]
:- pred lexp_7_1a_folds_to_string(resolved_file::in, lgra_9_3_1_expr::in)
    is semidet.

    % The type a right-hand side's folded value has, as an annotation names it.
    %
    %@spec [LGRA.4.1]
:- pred lgra_4_1_folded_kind(resolved_file::in, lgra_9_3_1_expr::in,
                             string::out) is semidet.

    % A folded `const`, in the shape a read lowers to. A `String` is not yet
    % interned.
    %
    %@spec [RLOW.6.1.8]
:- type rlow_6_1_8_literal
    --->    rl_value(ds_value)
    ;       rl_string(string).

    % The literal a read of `Const` lowers to, in the scope of the file declaring
    % it. Fails for a `const` that does not fold, which `dsc.validate` has refused.
    %
    %@spec [RLOW.6.1.8]
:- pred rlow_6_1_8_const_literal(resolved_file::in, ast_const::in,
                                 rlow_6_1_8_literal::out) is semidet.

    %@helper
:- type ltim_14_3_calendar
    --->    lc_time
    ;       lc_date.

    % A `calendar.time` or `calendar.date` call whose arguments all fold: the
    % value or the fault, `ds.chrono`'s, as the engine evaluates the call.
    %
    %@spec [LTIM.14.3]
:- pred ltim_14_3_calendar_fold(resolved_file::in, lgra_9_3_1_expr::in,
                                ltim_14_3_calendar::out,
                                ltim_14_2_answer::out) is semidet.

    %@spec [LTIM.14.3]
:- pred ltim_14_3_calendar_raises(resolved_file::in, lgra_9_3_1_expr::in)
    is semidet.

    % A `UNIT_LIT` of a time unit, or a NAME bound to a `const` folding to a
    % `Duration`. Signed: whether zero is a window is each position's rule.
    %
    %@spec [LGRA.2.8.1]
:- pred lgra_2_8_1_time_expr_ns(resolved_file::in, list(positioned)::in,
                                int64::out) is semidet.

    % The same `time_expr`, over a parsed expression: an `ex_unit` of a time
    % unit, or an `ex_name` bound to a `const` folding to a `Duration`.
    % `lgra_2_8_1_time_expr_ns` is this over the one token, so a token span
    % and an expression read a const alike.
    %
    %@spec [LGRA.2.8.1]
:- pred lgra_2_8_1_time_value_ns(resolved_file::in, lgra_9_3_1_expr::in,
                                 int64::out) is semidet.

    % A folded value as the slot stores it: a `Float` in an `Int`-stored unit
    % slot is rounded ties to even, as `dsc.rete.luni_7_2_storage_cast` rounds
    % one. Fails where the rounding has no `Int`.
    %
    %@spec [LUNI.7.2]
:- pred luni_7_2_storage_value(resolved_file::in, ast_field::in,
                               test_value::in, test_value::out) is semidet.

    % The module's `validate_file` has passed: every schema resolves and every
    % value folds.
    %
    %@spec [LGRA.24.3]
:- func lgra_24_3_initial_items(resolved_file) = list(initial_item_ir).

    % A module's AST with one internal rule appended per `emitted` / `published`
    % assertion carrying a `where`. The `int` is the `test_id` of its first test.
    %
    %@spec [RTIM.14.11]
    %@spec [RTIM.14.12]
:- func rtim_14_11_oracle_rules(int, ast_file) = ast_file.

    % The same, less the rules of a companion's tests. `dsc.driver` checks a
    % refused module again with these, to tell which diagnostics a companion's
    % oracle rule raised.
    %
    %@spec [RCLI.1.9]
:- func rcli_1_9_module_oracle_rules(int, ast_file) = ast_file.

    %@spec [RLOW.17.1]
:- func rlow_17_1_test_count(ast_file) = int.

    % The next `test_id`, and the next `stub_id`, unique in the artefact.
    %
    %@helper
:- type test_counters.

    %@helper
:- func first_test_counters = test_counters.

    % `$dstest_oracle_<t>_<i>`: the `test_id`, and the assertion's 0-based
    % position among its `produces` assertions. `$` is no `NAME` character, so
    % no author rule can share it.
    %
    %@spec [RTIM.14.13]
:- func rtim_14_13_oracle_rule_name(int, int) = string.

    %@spec [RTIM.14.13]
:- func rtim_14_13_oracle_prefix = string.

    % Against the names of every rule the module sees: its own, and its import
    % closure's. A test from the module's companion reports in that file.
    %
    %@spec [RLOW.17.1]
    %@spec [RLOW.17.3]
    %@spec [LTSL.2.4]
:- pred rlow_17_1_lower_tests(resolved_file::in, list(string)::in,
                              test_counters::in, test_counters::out,
                              test_outcome::out) is det.

    %@spec [LSTR.11.2]
:- pred lstr_11_2_literal_capacity(ast_field::in, lgra_9_3_1_expr::in,
                                   list(diagnostic)::in, list(diagnostic)::out)
    is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.core_math.
:- import_module ds.format.
:- import_module ds.schema.
:- import_module dsc.builtins.
:- import_module dsc.exact.
:- import_module dsc.quantity.
:- import_module dsc.strlit.
:- import_module dsc.types.

:- import_module char.
:- import_module float.
:- import_module int.
:- import_module integer.
:- import_module map.
:- import_module require.
:- import_module string.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%
% The oracle rules -- [RTIM.14.11]
%-----------------------------------------------------------------------------%

rtim_14_13_oracle_rule_name(TestPos, Idx) =
    rtim_14_13_oracle_prefix ++ string.int_to_string(TestPos) ++ "_"
        ++ string.int_to_string(Idx).

rtim_14_13_oracle_prefix = "$dstest_oracle_".

    % Appending puts a module's oracle rules after its own rules only, so
    % `dsc.rete.rlow_4_2_1_lower_rules` lowers them in a second pass, after every
    % author rule ([RLOW.14.3]). The RHS is one `log debug`, which the interpreter
    % suppresses: a rule needs an action.
    %
rtim_14_11_oracle_rules(FirstId, Ast) =
    Ast ^ af_decls := Ast ^ af_decls
        ++ oracle_rules(every_test, FirstId, tests_of(Ast)).

rcli_1_9_module_oracle_rules(FirstId, Ast) =
    Ast ^ af_decls := Ast ^ af_decls
        ++ oracle_rules(module_tests, FirstId, tests_of(Ast)).

rlow_17_1_test_count(Ast) = list.length(tests_of(Ast)).

    %@helper
:- type oracle_tests
    --->    every_test
    ;       module_tests.

    %@helper
:- func tests_of(ast_file) = list(ast_test).

tests_of(Ast) = list.filter_map(test_of, Ast ^ af_decls).

    %@helper
:- func test_of(ast_decl) = ast_test is semidet.

test_of(ad_test(T)) = T.

    %@helper
:- func oracle_rules(oracle_tests, int, list(ast_test)) = list(ast_decl).

oracle_rules(_, _, []) = [].
oracle_rules(Which, TestPos, [T | Ts]) =
        Rules ++ oracle_rules(Which, TestPos + 1, Ts) :-
    ( if Which = module_tests, T ^ tst_file = yes(_) then
        Rules = []
    else
        Rules = oracle_rules_of(TestPos, 0, assertions_of(T))
    ).

    %@helper
:- func oracle_rules_of(int, int, list(ast_test_assertion)) = list(ast_decl).

oracle_rules_of(_, _, []) = [].
oracle_rules_of(TestPos, Idx, [A | As]) = Rules :-
    Rest = oracle_rules_of(TestPos, Idx + 1, As),
    % Only an `emitted` head: a `published` one's `where` is refused
    % ([LTSL.8.4]; `ltsl_8_2_assertion`), so no rule is built for it.
    ( if A ^ tas_head = thd_emitted(Schema, _, yes(Where)) then
        Pos = A ^ tas_pos,
        Body = ast_pattern_body(Schema, yes(Where ^ twh_binding), no,
            yes(Where ^ twh_predicate), no, Pos),
        Rhs = ast_rule_rhs([],
            [ast_action(aah_log(ll_debug, "dstest oracle"), [], aab_none, no,
                Pos)],
            []),
        RuleName = ident(rtim_14_13_oracle_rule_name(TestPos, Idx), Pos),
        Rule = ast_rule(RuleName, [], no, [alc_pattern(ap_simple(Body))], Rhs,
            Pos, compiler_injected),
        Rules = [ad_rule(Rule) | Rest]
    else
        Rules = Rest
    ).

    % The index into this list is the `<i>` of the oracle rule's name, and the
    % interpreter counts a case's `O*` atoms the same way.
    %
    %@helper
:- func assertions_of(ast_test) = list(ast_test_assertion).

assertions_of(T) = list.condense(list.filter_map(produces_of, T ^ tst_sections)).

    % Named funcs: a `func` lambda in `filter_map`'s semidet position does not
    % pass the mode check.
    %
    %@helper
:- func produces_of(ast_test_section) = list(ast_test_assertion) is semidet.

produces_of(tsec_produces(As, _)) = As.

    %@helper
:- func initial_of(ast_test_section) = list(ast_test_initial) is semidet.

initial_of(tsec_initial(Is, _)) = Is.

    %@helper
:- func inputs_of(ast_test_section) = list(ast_test_at) is semidet.

inputs_of(tsec_inputs(Bs, _)) = Bs.

    %@helper
:- func responses_of(ast_test_section) = list(ast_test_stub) is semidet.

responses_of(tsec_responses(Ss, _)) = Ss.

    %@helper
:- func until_of(ast_test_section) = lgra_9_3_1_expr is semidet.

until_of(tsec_until(U, _)) = U.

    %@helper
:- func initial_fact_of(ast_test_initial) = ast_test_fact is semidet.

initial_fact_of(tini_fact(F)) = F.

    %@helper
:- func initial_seed_of(ast_test_initial)
    = {lgra_9_3_1_expr, lgra_9_3_1_expr, pos} is semidet.

initial_seed_of(tini_cache(K, V, P)) = {K, V, P}.

    %@helper
:- func reply_fact_of(ast_test_reply) = ast_test_fact is semidet.

reply_fact_of(trep_fact(F)) = F.

%-----------------------------------------------------------------------------%
% Lowering -- [RLOW.17]
%-----------------------------------------------------------------------------%

:- type test_counters
    --->    counters(
                c_test :: uint32,
                c_stub :: uint32
            ).

first_test_counters = counters(1u32, 1u32).

rlow_17_1_lower_tests(RF, RuleNames, !Counters, Outcome) :-
    list.foldl3(lower_test(RF, RuleNames), tests_of(RF ^ rf_ast),
        !Counters, [], RevIRs, [], RevErrors),
    (
        RevErrors = [],
        Outcome = tests_lowered(list.reverse(RevIRs))
    ;
        RevErrors = [_ | _],
        Outcome = tests_rejected(list.reverse(RevErrors))
    ).

    %@helper
:- pred lower_test(resolved_file::in, list(string)::in, ast_test::in,
                   test_counters::in, test_counters::out,
                   list(test_ir)::in, list(test_ir)::out,
                   list(diagnostic)::in, list(diagnostic)::out) is det.

lower_test(RF, RuleNames, T, !Counters, !IRs, !Errors) :-
    lower_one_test(RF, RuleNames, T, !Counters, !IRs, [], Errors),
    (
        T ^ tst_file = yes(File),
        !:Errors = list.map(rcli_1_9_in_file(File), Errors) ++ !.Errors
    ;
        T ^ tst_file = no,
        !:Errors = Errors ++ !.Errors
    ).

    % `Errors` is reversed; the reverse in `rlow_17_1_lower_tests` restores it.
    %
    %@helper
:- pred lower_one_test(resolved_file::in, list(string)::in, ast_test::in,
                       test_counters::in, test_counters::out,
                       list(test_ir)::in, list(test_ir)::out,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

lower_one_test(RF, RuleNames, T, !Counters, !IRs, !Errors) :-
    TestId = !.Counters ^ c_test,
    !Counters ^ c_test := TestId + 1u32,
    Sections = T ^ tst_sections,
    Initial = list.condense(list.filter_map(initial_of, Sections)),
    Blocks = list.condense(list.filter_map(inputs_of, Sections)),
    Stubs = list.condense(list.filter_map(responses_of, Sections)),
    Untils = list.filter_map(until_of, Sections),

    ( if string_literal(T ^ tst_name, Name0) then
        Name = Name0
    else
        Name = "",
        !:Errors = [error_at(dv_test_non_literal, T ^ tst_pos,
            "a test's name must be a string literal ([LTSL.2.3])")
            | !.Errors]
    ),

    ltsl_2_3_block_shape(T, Name, !Errors),

    Coordinates = list.map((func(B) = B ^ tat_when), Blocks) ++ Untils,
    Absolute = ( if list.any_true(is_absolute, Coordinates) then yes else no ),
    ( if
        list.any_true(is_absolute, Coordinates),
        list.any_true((pred(E::in) is semidet :- not is_absolute(E)),
            Coordinates)
    then
        !:Errors = [error_at(dv_test_mixed_time_mode, T ^ tst_pos,
            "test \"" ++ Name ++ "\" mixes relative and absolute timeline "
            ++ "coordinates; a test must use one mode throughout "
            ++ "([LTSL.3.2])") | !.Errors]
    else
        true
    ),
    (
        Untils = [],
        Until = 0u64
    ;
        Untils = [U | _],
        ltsl_3_1_coordinate(RF, U, Until, !Errors)
    ),

    % One `source_order` counter across the `initial` facts and the timeline.
    InitialFacts = list.filter_map(initial_fact_of, Initial),
    list.foldl3(ltsl_5_3_initial_fact(RF), InitialFacts, 0u32, Order1,
        [], RevInit, !Errors),
    list.foldl3(ltsl_3_3_block(RF), Blocks, Order1, _, [], RevInputs, !Errors),
    Facts = list.reverse(RevInit) ++ list.reverse(RevInputs),

    Seeds0 = list.filter_map(initial_seed_of, Initial),
    list.foldl2(ltsl_5_2_seed(RF), Seeds0, [], RevSeeds, !Errors),

    list.foldl3(ltsl_7_2_stub(RF), Stubs, !Counters, [], RevStubs, !Errors),

    list.foldl2(ltsl_8_2_assertion(RF, RuleNames, Name), assertions_of(T),
        [], RevOracles, !Errors),

    IR = test_ir(TestId, Name, Until, Absolute, Facts, list.reverse(RevSeeds),
        list.reverse(RevStubs), list.reverse(RevOracles)),
    !:IRs = [IR | !.IRs].

%-----------------------------------------------------------------------------%
% Block shape -- [LTSL.2.3]
%-----------------------------------------------------------------------------%

    %@spec [LTSL.2.3]
:- pred ltsl_2_3_block_shape(ast_test::in, string::in,
                             list(diagnostic)::in, list(diagnostic)::out)
    is det.

ltsl_2_3_block_shape(T, Name, !Errors) :-
    Kinds = list.map(section_kind, T ^ tst_sections),
    ( if list.member(sk_produces, Kinds) then
        true
    else
        !:Errors = [error_at(dv_test_no_produces, T ^ tst_pos,
            "test \"" ++ Name ++ "\" has no `produces` section; a test must "
                ++ "state what it expects ([LTSL.2.3])") | !.Errors]
    ),
    ( if ( list.member(sk_inputs, Kinds) ; list.member(sk_until, Kinds) ) then
        true
    else
        !:Errors = [error_at(dv_test_no_inputs_or_until, T ^ tst_pos,
            "test \"" ++ Name ++ "\" has neither `inputs` nor `until`; with "
                ++ "no inputs it must supply `until` to advance the clock "
                ++ "([LTSL.2.3])") | !.Errors]
    ),
    list.foldl2(ltsl_2_3_once(Name), T ^ tst_sections, [], _, !Errors).

    %@spec [LTSL.2.3]
:- pred ltsl_2_3_once(string::in, ast_test_section::in,
                      list(section_kind)::in, list(section_kind)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_2_3_once(Name, S, !Seen, !Errors) :-
    Kind = section_kind(S),
    ( if list.member(Kind, !.Seen) then
        !:Errors = [error_at(dv_test_duplicate_section, section_pos(S),
            "test \"" ++ Name ++ "\" repeats the `" ++ section_keyword(Kind)
                ++ "` section; each section keyword appears at most once "
                ++ "([LTSL.2.3])") | !.Errors]
    else
        !:Seen = [Kind | !.Seen]
    ).

    %@helper
:- type section_kind
    --->    sk_initial
    ;       sk_inputs
    ;       sk_responses
    ;       sk_produces
    ;       sk_until.

    %@helper
:- func section_kind(ast_test_section) = section_kind.

section_kind(tsec_initial(_, _)) = sk_initial.
section_kind(tsec_inputs(_, _)) = sk_inputs.
section_kind(tsec_responses(_, _)) = sk_responses.
section_kind(tsec_produces(_, _)) = sk_produces.
section_kind(tsec_until(_, _)) = sk_until.

    %@helper
:- func section_pos(ast_test_section) = pos.

section_pos(tsec_initial(_, P)) = P.
section_pos(tsec_inputs(_, P)) = P.
section_pos(tsec_responses(_, P)) = P.
section_pos(tsec_produces(_, P)) = P.
section_pos(tsec_until(_, P)) = P.

    %@helper
:- func section_keyword(section_kind) = string.

section_keyword(sk_initial) = "initial".
section_keyword(sk_inputs) = "inputs".
section_keyword(sk_responses) = "responses".
section_keyword(sk_produces) = "produces".
section_keyword(sk_until) = "until".

%-----------------------------------------------------------------------------%
% The timeline -- [LTSL.3]
%-----------------------------------------------------------------------------%

    % Anything but a duration literal; `ltsl_3_1_coordinate` refuses what is not
    % a folding `calendar.time` call.
    %
    %@helper
:- pred is_absolute(lgra_9_3_1_expr::in) is semidet.

is_absolute(E) :-
    not duration_literal_ns(E, _).

    % A duration offset in relative mode, epoch nanoseconds in absolute mode. An
    % instant before the epoch is refused: `when_ns` and `until_ns` are `uint64`.
    %
    %@spec [LTSL.3.1]
    %@spec [LTSL.3.2]
    %@spec [LTSL.3.7]
:- pred ltsl_3_1_coordinate(resolved_file::in, lgra_9_3_1_expr::in,
                            uint64::out,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_3_1_coordinate(RF, E, Ns, !Errors) :-
    ( if duration_literal_ns(E, D) then
        Ns = D
    else if ltim_14_3_calendar_fold(RF, E, lc_time, Answer) then
        (
            Answer = calendar_value(Utc),
            ( if Utc >= 0i64 then
                Ns = uint64.cast_from_int64(Utc)
            else
                Ns = 0u64,
                !:Errors = [error_at(dv_test_bad_timestamp, expr_start(E),
                    "an absolute timeline coordinate is at or after "
                    ++ "1970-01-01T00:00:00Z, which is all `when_ns` can "
                    ++ "carry ([LTSL.3.7])") | !.Errors]
            )
        ;
            ( Answer = calendar_domain
            ; Answer = calendar_not_representable
            ),
            Ns = 0u64,
            !:Errors = [error_at(dv_test_bad_timestamp, expr_start(E),
                "this `calendar.time` coordinate names no instant: a field is "
                ++ "out of its range, or the instant is out of the `Time` "
                ++ "range ([LTSL.3.7], [LTIM.14.2])") | !.Errors]
        )
    else
        Ns = 0u64,
        !:Errors = [with_hint(error_at(dv_test_bad_timestamp, expr_start(E),
            "a timeline coordinate is a duration literal or a "
            ++ "`calendar.time` call whose arguments are constants "
            ++ "([LTSL.3.1], [LTSL.3.7])"),
            "`at 5_s:` for a relative test, or `at calendar.time(2026, 6, 18, "
            ++ "14, 0, 0):` for an absolute one, after `import calendar`")
            | !.Errors]
    ).

    % `dsc.libcall` has rewritten every spelling of the name to its [LEXP.17.2]
    % row.
    %
    %@spec [LTIM.14.3]
ltim_14_3_calendar_fold(RF, E, Kind, Answer) :-
    E = ex_call(ex_name(Fn), Args, _),
    list.map(folded_int(RF), Args, Is),
    calendar_answer(Fn ^ id_name, Is, Kind, Answer).

    %@helper
:- pred calendar_answer(string::in, list(int64)::in, ltim_14_3_calendar::out,
                        ltim_14_2_answer::out) is semidet.

calendar_answer(Fn, Is, Kind, Answer) :-
    ( if Fn = "calendar.date", Is = [Y, Mo, D] then
        Kind = lc_date,
        Answer = ltim_14_2_date(Y, Mo, D)
    else
        Fn = "calendar.time",
        ( if Is = [Y, Mo, D] then
            Fields = [Y, Mo, D, 0i64, 0i64, 0i64, 0i64]
        else if Is = [Y, Mo, D, H, Mi, S] then
            Fields = [Y, Mo, D, H, Mi, S, 0i64]
        else
            Is = [_, _, _, _, _, _, _],
            Fields = Is
        ),
        Fields = [FY, FMo, FD, FH, FMi, FS, FNs],
        Kind = lc_time,
        Answer = ltim_14_2_time(FY, FMo, FD, FH, FMi, FS, FNs)
    ).

ltim_14_3_calendar_raises(RF, E) :-
    ltim_14_3_calendar_fold(RF, E, _, Answer),
    ( Answer = calendar_domain
    ; Answer = calendar_not_representable
    ).

    %@helper
:- pred folded_int(resolved_file::in, lgra_9_3_1_expr::in, int64::out)
    is semidet.

folded_int(RF, E, I) :-
    ltsl_4_1_fold(RF, E, f_int(I), map.init, _).

%-----------------------------------------------------------------------------%
% Facts -- [LTSL.4.1], [LTSL.5.3], [LTSL.6]
%-----------------------------------------------------------------------------%

    %@spec [LTSL.5.3]
:- pred ltsl_5_3_initial_fact(resolved_file::in, ast_test_fact::in,
                              uint32::in, uint32::out,
                              list(test_fact_ir)::in, list(test_fact_ir)::out,
                              list(diagnostic)::in, list(diagnostic)::out)
    is det.

ltsl_5_3_initial_fact(RF, F, !Order, !Facts, !Errors) :-
    ltsl_4_1_fact(RF, yes, 0u64, F, !Order, !Facts, !Errors).

    %@spec [LTSL.3.3]
:- pred ltsl_3_3_block(resolved_file::in, ast_test_at::in,
                       uint32::in, uint32::out,
                       list(test_fact_ir)::in, list(test_fact_ir)::out,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_3_3_block(RF, Block, !Order, !Facts, !Errors) :-
    ltsl_3_1_coordinate(RF, Block ^ tat_when, When, !Errors),
    list.foldl3(ltsl_4_1_fact(RF, no, When), Block ^ tat_facts, !Order, !Facts,
        !Errors).

    %@spec [LTSL.4.1]
:- pred ltsl_4_1_fact(resolved_file::in, bool::in, uint64::in,
                      ast_test_fact::in,
                      uint32::in, uint32::out,
                      list(test_fact_ir)::in, list(test_fact_ir)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_4_1_fact(RF, Initial, When, F, !Order, !Facts, !Errors) :-
    rlow_17_3_schema_slots(RF, F ^ tfa_schema, F ^ tfa_args, Schema, Slots,
        !Errors),
    !:Facts = [test_fact_ir(Initial, When, Schema, Slots, !.Order)
        | !.Facts],
    !:Order = !.Order + 1u32.

    % In codepoints of the decoded text. A literal with a site or a bad escape is
    % not checked.
    %
lstr_11_2_literal_capacity(Slot, Value, !Errors) :-
    ( if
        Slot ^ af_capacity = yes(CapTok),
        CapTok ^ tk_tok = int_lit(Cap),
        Value = ex_string(Text, Pos),
        constant_codepoints(Text, Len),
        int64.from_int(Len) > Cap
    then
        !:Errors = [with_hint(error_at(dv_capacity_literal_exceeded, Pos,
            "slot `" ++ Slot ^ af_name ^ id_name ++ "` has `capacity "
                ++ int64_to_string(Cap) ++ "`, and this literal is "
                ++ string.int_to_string(Len) ++ " codepoints ([LSTR.11.2])"),
            "shorten the literal, or raise the slot's `capacity`")
            | !.Errors]
    else
        true
    ).

    %@helper
:- pred constant_codepoints(string::in, int::out) is semidet.

constant_codepoints(Text, Len) :-
    Pieces = lgra_2_9_6_7_pieces(string.to_char_list(Text)),
    list.foldl(add_text_piece, Pieces, 0, Len).

    %@helper
:- pred add_text_piece(piece::in, int::in, int::out) is semidet.

add_text_piece(p_text(Raw), N0, N) :-
    lgra_2_9_4_decode(Raw) = decoded(Chars),
    N = N0 + list.length(Chars).

    % `Name` is the one the artefact carries the schema under, the library's
    % declaration, as `dsc.rete` names a pattern's schema.
    %
    %@spec [RLOW.17.3]
:- pred rlow_17_3_schema_slots(resolved_file::in, ast_type_ref::in,
                               list(ast_action_arg)::in, string::out,
                               list(test_slot)::out,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

rlow_17_3_schema_slots(RF, Ref, Args, Name, Slots, !Errors) :-
    ( if lgra_22_4_schema_of(RF, Ref, S) then
        Name = S ^ as_own,
        Fields = list.map((func(Fd) = Fd ^ af_name ^ id_name), S ^ as_fields),
        list.foldl2(checked_slot(RF, type_ref_text(Ref), Fields,
            S ^ as_fields), Args, [], RevSlots, !Errors),
        list.foldl(fact_capacity(S ^ as_fields), Args, !Errors),
        Slots = list.reverse(RevSlots)
    else
        Name = type_ref_text(Ref),
        Slots = [],
        !:Errors = [error_at(dv_test_unknown_schema, type_ref_name(Ref) ^ id_pos,
            "a test names the unknown schema `" ++ type_ref_text(Ref)
            ++ "` ([RLOW.17.3])") | !.Errors]
    ).

    %@helper
:- pred fact_capacity(list(ast_field)::in, ast_action_arg::in,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

fact_capacity(Fields, Arg, !Errors) :-
    ( if
        Arg = aaa_kwarg(Name, E, _),
        list.find_first_match(
            (pred(F::in) is semidet :- F ^ af_name ^ id_name = Name ^ id_name),
            Fields, Field)
    then
        lstr_11_2_literal_capacity(Field, E, !Errors)
    else
        true
    ).

    %@helper
:- pred checked_slot(resolved_file::in, string::in, list(string)::in,
                     list(ast_field)::in, ast_action_arg::in,
                     list(test_slot)::in, list(test_slot)::out,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

checked_slot(RF, Schema, Fields, AstFields, Arg, !Slots, !Errors) :-
    ( if
        Arg = aaa_kwarg(Name, _, _),
        not list.member(Name ^ id_name, Fields)
    then
        !:Errors = [error_at(dv_test_unknown_slot, Name ^ id_pos,
            "schema `" ++ Schema ++ "` has no slot `" ++ Name ^ id_name
            ++ "` ([RLOW.17.3])") | !.Errors]
    else if lfac_9_3_test_ts(Schema, Arg, !Errors) then
        true
    else if
        Arg = aaa_kwarg(SlotName, E, _),
        list.find_first_match(
            ( pred(Fd::in) is semidet :-
                Fd ^ af_name ^ id_name = SlotName ^ id_name ),
            AstFields, Field)
    then
        ltsl_4_1_literal(RF, E, MaybeV, !Errors),
        (
            MaybeV = yes(V0),
            ( if luni_7_2_storage_value(RF, Field, V0, V) then
                !:Slots = [test_slot(SlotName ^ id_name, V) | !.Slots]
            else
                !:Errors = [error_at(dv_test_non_literal, expr_start(E),
                    "`" ++ SlotName ^ id_name ++ "` stores whole numbers of "
                    ++ "its unit, and this value rounds to no `Int` "
                    ++ "([LUNI.7.2])") | !.Errors]
            )
        ;
            MaybeV = no
        )
    else
        literal_slot(RF, Arg, !Slots, !Errors)
    ).

    % Succeeds, having reported, when the argument writes `ts`. By name alone: a
    % reply's schema is not bound here, so there is no field list to consult.
    %
    %@spec [LFAC.9.3]
:- pred lfac_9_3_test_ts(string::in, ast_action_arg::in,
                         list(diagnostic)::in, list(diagnostic)::out) is semidet.

lfac_9_3_test_ts(Schema, Arg, !Errors) :-
    Arg = aaa_kwarg(Name, _, _),
    Name ^ id_name = "ts",
    !:Errors = [with_hint(error_at(dv_ts_read_only, Name ^ id_pos,
        "a test's `" ++ Schema ++ "` fact writes `ts`, which the test clock "
            ++ "fills at the step's `at` coordinate ([LFAC.9.3])"),
        "drop `ts:` and place the fact with `at <time>:` ([LFAC.9.2])")
        | !.Errors].

    % Schema unchecked: a stub's argument keys and a reply's slots.
    %
    %@helper
:- pred literal_slot(resolved_file::in, ast_action_arg::in,
                     list(test_slot)::in, list(test_slot)::out,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

literal_slot(RF, aaa_kwarg(Name, E, _), !Slots, !Errors) :-
    ltsl_4_1_literal(RF, E, MaybeV, !Errors),
    (
        MaybeV = yes(V),
        !:Slots = [test_slot(Name ^ id_name, V) | !.Slots]
    ;
        MaybeV = no
    ).
literal_slot(_, aaa_flag(Name), !Slots, !Errors) :-
    !:Errors = [error_at(dv_test_non_literal, Name ^ id_pos,
        "`" ++ Name ^ id_name ++ "` has no value; a test gives every slot a "
        ++ "literal ([LTSL.4.1])") | !.Errors].

%-----------------------------------------------------------------------------%
% Literals -- [LTSL.4.1]
%-----------------------------------------------------------------------------%

    % `det` with a `maybe`: a `semidet` check that added a diagnostic and failed
    % would report nothing.
    %
    %@spec [LTSL.4.1]
:- pred ltsl_4_1_literal(resolved_file::in, lgra_9_3_1_expr::in,
                         maybe(test_value)::out,
                         list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_4_1_literal(RF, E, MaybeV, !Errors) :-
    ( if E = ex_name(_), ltsl_4_1_constant(RF, E, V) then
        MaybeV = yes(V)
    else if E = ex_int(I, _) then
        MaybeV = yes(tv_int(I))
    else if E = ex_unary(uo_neg, ex_int(I, _), _) then
        MaybeV = yes(tv_int(-I))
    else if E = ex_float(F, _) then
        MaybeV = yes(tv_float(F))
    else if E = ex_unary(uo_neg, ex_float(F, _), _) then
        % `neg`, not Mercury's unary `-`: `0.0 - F` loses `-0.0`.
        MaybeV = yes(tv_float(neg(F)))
    else if E = ex_bool(B, _) then
        MaybeV = yes(tv_bool(B))
    else if duration_literal_ns(E, Ns) then
        MaybeV = yes(tv_duration(Ns))
    else if E = ex_string(_, _) then
        string_literal_checked(E, MaybeS, !Errors),
        MaybeV = maybe.map_maybe((func(S) = tv_string(S)), MaybeS)
    else if
        E = ex_call(ex_name(Fn), [Arg], _),
        Fn ^ id_name = "json",
        Arg = ex_string(_, _)
    then
        % Not `string_literal_checked`: a `json()` argument's braces are literal.
        json_literal_checked(Arg, MaybeS, !Errors),
        MaybeV = maybe.map_maybe((func(S) = tv_json(S)), MaybeS)
    else
        MaybeV = no,
        !:Errors = [error_at(dv_test_non_literal, expr_start(E),
            "a test value must be an Int, Float, String, Bool or duration "
            ++ "literal, json(\"...\") over a string literal, or the name of "
            ++ "a `const` whose value is one ([LTSL.4.1])")
            | !.Errors]
    ).

    % `LIMIT * 2` written as the value is refused; a `const` declared `= LIMIT * 2`
    % folds.
    %
ltsl_4_1_constant(RF, E, V) :-
    leaf_or_const(RF, E, F, map.init, _),
    folded_value(F) = V.

ltsl_4_1_string_constant(RF, E, S) :-
    ltsl_4_1_constant(RF, E, tv_string(S)).

lexp_8_8_int_constant(RF, E, I) :-
    ltsl_4_1_fold(RF, E, f_int(I), map.init, _).

lexp_8_8_duration_ns(RF, E, Ns) :-
    ltsl_4_1_fold(RF, E, F, map.init, _),
    F = f_duration(_),
    folded_value(F) = tv_duration(U),
    Ns = int64.cast_from_uint64(U).

lexp_8_8_1_folds(RF, E) :-
    ltsl_4_1_fold(RF, E, _, map.init, _).

lexp_7_1a_folds_to_string(RF, E) :-
    ltsl_4_1_fold(RF, E, f_string(_), map.init, _).

lgra_4_1_folded_kind(RF, E, folded_kind(F)) :-
    ltsl_4_1_fold(RF, E, F, map.init, _).

    %@helper
:- func folded_kind(folded) = string.

folded_kind(f_int(_)) = "Int".
folded_kind(f_float(_)) = "Float".
folded_kind(f_bool(_)) = "Bool".
folded_kind(f_string(_)) = "String".
folded_kind(f_duration(_)) = "Duration".
folded_kind(f_json(_)) = "Json".
folded_kind(f_time(_)) = "Time".
folded_kind(f_date(_)) = "Date".

rlow_6_1_8_const_literal(RF, Const, Literal) :-
    const_folded(RF, Const, F, map.init, _),
    folded_literal(F, Literal).

    %@helper
:- pred folded_literal(folded::in, rlow_6_1_8_literal::out) is semidet.

folded_literal(f_int(I), rl_value(int(I))).
folded_literal(f_float(X), rl_value(float(X))).
folded_literal(f_bool(B), rl_value(bool(B))).
folded_literal(f_string(S), rl_string(S)).
folded_literal(f_date(Days), rl_value(int(Days))).
folded_literal(f_duration(R), rl_value(int(int64.cast_from_uint64(U)))) :-
    folded_value(f_duration(R)) = tv_duration(U).
folded_literal(f_time(Utc), rl_value(time(ds_time(Utc, 0i64)))).

lgra_2_8_1_time_expr_ns(RF, [Tok], Ns) :-
    T = Tok ^ tk_tok,
    (
        T = unit_lit(Magnitude, Suffix),
        E = ex_unit(Magnitude, Suffix, Tok ^ tk_pos)
    ;
        T = name(Name),
        E = ex_name(ident(Name, Tok ^ tk_pos))
    ),
    lgra_2_8_1_time_value_ns(RF, E, Ns).

lgra_2_8_1_time_value_ns(RF, E, Ns) :-
    (
        E = ex_unit(Magnitude, Suffix, _),
        luni_10_2_time_unit(llex_12_5_symbol_of(Suffix), Multiplier),
        luni_3_1_5_magnitude_ns(Magnitude, Multiplier, Ns)
    ;
        E = ex_name(_),
        ltsl_4_1_constant(RF, E, tv_duration(U)),
        Ns = int64.cast_from_uint64(U)
    ).

    % The same value the runtime computes, operation by operation ([LDET.3.3a.8]):
    % each step's exact result is rounded to the nearest double, as the engine
    % rounds, never with the host's floating point.
    %
    % An expression that would make a NaN, or that the engine would trap on, does
    % not fold.
    %
    %@helper
:- type folded
    --->    f_int(int64)
    ;       f_float(float)                  % finite or infinite, never NaN
    ;       f_bool(bool)
    ;       f_string(string)
    ;       f_duration(rational)            % nanoseconds
    ;       f_json(string)
    ;       f_time(int64)                   % UTC nanoseconds, at offset 0
    ;       f_date(int64).                  % days since the epoch

    % What each `const` read so far folded to. `fe_pending` is a `const` being
    % folded, so meeting one is a cycle, which does not fold. A `const` is folded
    % once, so a chain costs its length. The key holds `acn_library`, so one text
    % at one position in two libraries is two entries.
    %
    %@helper
:- type fold_entry
    --->    fe_pending
    ;       fe_done(folded).

    %@helper
:- type fold_memo == map(ast_const, fold_entry).

    % A transcendental or `pow` has no exact value to fold to: its value is
    % `ds.core_math`'s, the function both runtimes compute.
    %
    %@spec [LEXP.8.8]
:- pred ltsl_4_1_fold(resolved_file::in, lgra_9_3_1_expr::in, folded::out,
                      fold_memo::in, fold_memo::out) is semidet.

ltsl_4_1_fold(RF, E, F, !Memo) :-
    ( if leaf_or_const(RF, E, Leaf, !Memo) then
        F = Leaf
    else if
        % Before the unary arm: a minus on a unit literal negates its number
        % before the unit converts it. A time literal is a `Duration`.
        quantity_literal(E, Negated, Magnitude, Suffix),
        Symbol = llex_12_5_symbol_of(Suffix),
        not luni_10_2_time_unit(Symbol, _)
    then
        fold_unit_literal(RF, Negated, Magnitude, Symbol, F, !Memo)
    else if E = ex_cast(Operand, Target, non_null, _) then
        ltsl_4_1_fold(RF, Operand, F0, !Memo),
        ( if lcst_4_5_2_folded_cast(RF, Target ^ id_name, Operand, F0, F1) then
            F = F1
        else if
            luni_3_1_7_unit_of(RF, Target ^ id_name, _, _),
            not carries_unit(RF, 64, Operand)
        then
            rlow_6_1_10_assertion_of(RF, Target ^ id_name, Assertion),
            rlow_6_1_10_folded(RF, Assertion, F0, F, !Memo)
        else
            identity_cast(RF, Target ^ id_name, F0),
            F = F0
        )
    else if
        E = ex_name(Id),
        lexp_4_1_math_constant_value(Id ^ id_name, X)
    then
        not float.is_nan(X),
        F = f_float(X)
    else if E = ex_unary(Op, Inner, _) then
        ltsl_4_1_fold(RF, Inner, F0, !Memo),
        fold_unary(Op, F0, F)
    else if E = ex_not(Inner, _) then
        ltsl_4_1_fold(RF, Inner, f_bool(B), !Memo),
        F = f_bool(bool.not(B))
    else if E = ex_binary(Op, L, R, _) then
        ltsl_4_1_fold(RF, L, FL, !Memo),
        ltsl_4_1_fold(RF, R, FR, !Memo),
        fold_binary(Op, FL, FR, F)
    else if E = ex_compare(First, Steps, _) then
        ltsl_4_1_fold(RF, First, F0, !Memo),
        fold_chain(RF, F0, Steps, yes, B, !Memo),
        F = f_bool(B)
    else
        E = ex_call(ex_name(Fn), Args, _),
        fold_args(RF, Args, Folded, !Memo),
        ( if list.map(folded_int_of, Folded, Is),
            calendar_answer(Fn ^ id_name, Is, Kind, Answer)
        then
            Answer = calendar_value(V),
            (
                Kind = lc_time,
                F = f_time(V)
            ;
                Kind = lc_date,
                F = f_date(V)
            )
        else if
            ( rounding_builtin(Fn ^ id_name)
            ; Fn ^ id_name = "math.sign"
            ),
            Args = [Arg],
            carries_unit(RF, 64, Arg)
        then
            fold_unit_of(RF, 64, Arg, Dimension, Unit),
            Folded = [F0],
            rlow_6_1_9_folded(RF, Fn ^ id_name, Dimension, Unit, F0, F, !Memo)
        else
            fold_builtin(Fn ^ id_name, Folded, F)
        )
    ).

    %@helper
:- pred folded_int_of(folded::in, int64::out) is semidet.

folded_int_of(f_int(I), I).

    %@helper
:- pred fold_args(resolved_file::in, list(lgra_9_3_1_expr)::in,
                  list(folded)::out, fold_memo::in, fold_memo::out) is semidet.

fold_args(_, [], [], !Memo).
fold_args(RF, [E | Es], [F | Fs], !Memo) :-
    ltsl_4_1_fold(RF, E, F, !Memo),
    fold_args(RF, Es, Fs, !Memo).

    % A literal, or a read of a `const`, in place or through a library.
    %
    %@helper
:- pred leaf_or_const(resolved_file::in, lgra_9_3_1_expr::in, folded::out,
                      fold_memo::in, fold_memo::out) is semidet.

leaf_or_const(RF, E, F, !Memo) :-
    ( if literal_leaf(E, F0) then
        F = F0
    else
        const_read(RF, E, Scope, Const),
        const_folded(Scope, Const, F, !Memo)
    ).

    %@helper
:- pred literal_leaf(lgra_9_3_1_expr::in, folded::out) is semidet.

literal_leaf(E, F) :-
    ( if E = ex_int(I, _) then
        F = f_int(I)
    else if E = ex_unary(uo_neg, ex_int(I, _), _) then
        F = f_int(-I)
    else if E = ex_float(X, _) then
        F = f_float(X)
    else if E = ex_unary(uo_neg, ex_float(X, _), _) then
        F = f_float(neg(X))
    else if E = ex_bool(B, _) then
        F = f_bool(B)
    else if duration_literal_ns(E, Ns) then
        F = f_duration(dsc.exact.from_int64(int64.cast_from_uint64(Ns)))
    else if E = ex_string(_, _) then
        string_lit(E) = sl_ok(S),
        F = f_string(S)
    else
        E = ex_call(ex_name(Fn), [ex_string(Text, _)], _),
        Fn ^ id_name = "json",
        lgra_2_9_4_decode(string.to_char_list(Text)) = decoded(Chars),
        F = f_json(string.from_char_list(Chars))
    ).

    % The `const` a name or a library member reads, and the scope its value is
    % folded in, the declaring file's ([LIMP.1.5]).
    %
    %@helper
:- pred const_read(resolved_file::in, lgra_9_3_1_expr::in, resolved_file::out,
                   ast_const::out) is semidet.

const_read(RF, E, Scope, Const) :-
    ( if E = ex_name(Id) then
        map.search(RF ^ rf_consts, Id ^ id_name, Const),
        Scope = const_scope(RF, Const)
    else
        lgra_22_9_library_member(RF, E, Path, Member),
        LibKey = string.join_list(".",
            list.map((func(I) = I ^ id_name), Path)) ++ ";" ++ Member ^ id_name,
        map.search(RF ^ rf_qualified_consts, LibKey, Const),
        Scope = const_scope(RF, Const)
    ).

    %@helper
:- pred const_value(ast_const::in, lgra_9_3_1_expr::out) is det.

const_value(Const, Value) :-
    Form = Const ^ acn_form,
    (
        Form = acf_value(_, Value)
    ;
        Form = acf_colon_literal(Value)
    ).

    % What a `const` holds, for every read of it: an `Int` under `: Float` holds
    % the `Float`.
    %
    %@spec [LEXP.8.8.1]
:- pred const_folded(resolved_file::in, ast_const::in, folded::out,
                     fold_memo::in, fold_memo::out) is semidet.

const_folded(Scope, Const, F, !Memo) :-
    ( if map.search(!.Memo, Const, Entry) then
        Entry = fe_done(F)
    else
        const_value(Const, Value),
        map.det_insert(Const, fe_pending, !Memo),
        ltsl_4_1_fold(Scope, Value, F0, !Memo),
        ( if
            Const ^ acn_form = acf_value(yes(Annotation), _),
            Annotation ^ aan_type ^ id_name = "Float",
            F0 = f_int(I)
        then
            F = f_float(int_to_float(I))
        else
            F = F0
        ),
        map.det_update(Const, fe_done(F), !Memo)
    ).

    %@helper
:- pred fold_unary(lgra_9_5_1_unary_op::in, folded::in, folded::out)
    is semidet.

fold_unary(uo_neg, f_int(I), f_int(dsc.exact.wrap_int64(
    -integer.from_int64(I)))).
fold_unary(uo_neg, f_float(X), f_float(neg(X))).
    % No `uo_neg` over a `Duration`: `dsc.typecheck` refuses it.
fold_unary(uo_pos, F, F) :-
    ( F = f_int(_) ; F = f_float(_) ; F = f_duration(_) ).
fold_unary(uo_bitnot, f_int(I), f_int(\ I)).

    % A unit literal other than a time one, as `dsc.rete` lowers it. A tier-2 unit
    % is its `to_base` body at `x = magnitude`, folded one operation at a time.
    %
    %@helper
:- pred fold_unit_literal(resolved_file::in, bool::in, string::in, string::in,
                          folded::out, fold_memo::in, fold_memo::out)
    is semidet.

fold_unit_literal(RF, Negated, Magnitude, Symbol, F, !Memo) :-
    ( if
        (
            Negated = no,
            luni_4_3_unit_literal(RF, Magnitude, Symbol, V)
        ;
            Negated = yes,
            luni_4_3_negated_unit_literal(RF, Magnitude, Symbol, V)
        )
    then
        (
            V = int(I),
            F = f_int(I)
        ;
            V = float(X),
            not float.is_nan(X),
            F = f_float(X)
        )
    else
        luni_4_3_tier2_to_base(RF, Symbol, ToBase),
        dsc.exact.from_decimal(string.replace_all(Magnitude, "_", ""), Exact),
        dsc.exact.to_float(Exact, X0),
        X = ( if Negated = yes then -X0 else X0 ),
        ltsl_4_1_fold(RF, with_x(X, ToBase), F, !Memo)
    ).

    % `dsc.validate` has checked the body's vocabulary, so these are the only
    % nodes `x` can sit in.
    %
    %@helper
:- func with_x(float, lgra_9_3_1_expr) = lgra_9_3_1_expr.

with_x(X, E) = R :-
    ( if E = ex_name(Id), Id ^ id_name = "x" then
        R = ex_float(X, Id ^ id_pos)
    else if E = ex_unary(Op, Inner, P) then
        R = ex_unary(Op, with_x(X, Inner), P)
    else if E = ex_binary(Op, L, Right, P) then
        R = ex_binary(Op, with_x(X, L), with_x(X, Right), P)
    else if E = ex_call(Callee, Args, P) then
        R = ex_call(Callee, list.map(with_x(X), Args), P)
    else
        R = E
    ).

    % A cast that converts, as `dsc.rete` lowers it and the engine evaluates it.
    % A `Float` quantity cast to `Int` strips the unit and keeps its number
    % ([LUNI.8.5]). A `String` is folded only as a literal ([LEXP.8.8]), so none
    % parses here.
    %
    %@spec [LCST.4.5.2]
:- pred lcst_4_5_2_folded_cast(resolved_file::in, string::in,
                               lgra_9_3_1_expr::in, folded::in, folded::out)
    is semidet.

lcst_4_5_2_folded_cast(RF, Target, Operand, F0, F) :-
    ( if F0 = f_duration(R), Target = "Int" then
        F = f_int(dsc.exact.truncate_wrapping_int64(R))
    else if
        F0 = f_duration(_),
        ( Target = "Duration"
        ; luni_10_2_time_unit(Target, _)
        ; map.search(RF ^ rf_types, Target, te_unit(uk_symbol(TargetDim), _)),
          TargetDim = time_dimension
        )
    then
        F = F0
    else if F0 = f_duration(R), Target = "String" then
        F = f_string(ltim_8_4_render_duration(
            dsc.exact.truncate_wrapping_int64(R)))
    else if F0 = f_time(Utc), Target = "String" then
        F = f_string(render_iso8601(Utc, 0i64))
    else if F0 = f_date(Days), Target = "String" then
        ltim_1_2_2_date_in_range(Days),
        F = f_string(ltim_8_2_1_render_date(Days))
    else if F0 = f_int(I), Target = "String" then
        F = f_string(bare_int(I))
    else if F0 = f_float(X), Target = "String" then
        F = f_string(bare_float(X))
    else if F0 = f_bool(B), Target = "String" then
        F = f_string(bare_bool(B))
    else if F0 = f_int(I), Target = "Float" then
        F = f_float(int_to_float(I))
    else if F0 = f_float(X), Target = "Int" then
        ( if
            known_quantity(RF,
                ( pred(_::in, _::out) is semidet :- fail ),
                ( pred(_::in) is semidet :- fail ),
                Operand, _, _)
        then
            F = F0
        else
            not float.is_inf(X),
            integer.to_int64(dsc.exact.truncate_integer(exact(X)), I),
            F = f_int(I)
        )
    else
        fail
    ).

    % A number asserted into a unit, the value `dsc.rete` lowers it to: one
    % operation at a time, each rounded once ([LUNI.2.7.1]), and the time row's
    % `FN_DURATION_MUL`, which does not fold past the range.
    %
    %@spec [RLOW.6.1.10]
:- pred rlow_6_1_10_folded(resolved_file::in, rlow_6_1_10_assertion::in,
                           folded::in, folded::out,
                           fold_memo::in, fold_memo::out) is semidet.

rlow_6_1_10_folded(_, asn_base, F, F, !Memo) :-
    ( F = f_int(_)
    ; F = f_float(_)
    ).
rlow_6_1_10_folded(_, asn_affine(Slope, Offset), f_float(X), F, !Memo) :-
    ( if Slope = 1.0 then
        Scaled = X
    else
        fold_float_binary(bo_mul, Slope, X, f_float(Scaled))
    ),
    ( if Offset = 0.0 then
        F = f_float(Scaled)
    else
        fold_float_binary(bo_add, Scaled, Offset, F)
    ).
rlow_6_1_10_folded(RF, asn_tier2(ToBase), f_float(X), F, !Memo) :-
    ltsl_4_1_fold(RF, with_x(X, ToBase), F, !Memo).
rlow_6_1_10_folded(_, asn_int(P, R, Q, Time), f_int(N), F, !Memo) :-
    rlow_7_3_9_mul_add_folded(N, P, integer.from_int64(R), Shifted),
    ( if Q = 1i64 then
        Whole = Shifted
    else
        % `FN_INT_DIV_EXACT`: a result that is not a whole number of base
        % units raises when the lowering runs, and does not fold.
        Shifted mod Q = 0i64,
        Whole = Shifted div Q
    ),
    F = f_int(( if Time = yes, Whole < 0i64 then 0i64 else Whole )).
rlow_6_1_10_folded(RF, asn_int_tier2(ToBase, Time), f_int(N), F, !Memo) :-
    ltsl_4_1_fold(RF, with_x(int_to_float(N), ToBase), f_float(Y), !Memo),
    fold_math_builtin("round", [f_float(Y)], f_int(Stored)),
    F = f_int(( if Time = yes, Stored < 0i64 then 0i64 else Stored )).
rlow_6_1_10_folded(_, asn_duration(Factor), f_int(N), F, !Memo) :-
    rlow_6_1_6_checked_fold(dsc.exact.mul(dsc.exact.from_int64(N),
        dsc.exact.from_int64(Factor)), F).

    % `round`, `math.floor`, `math.ceil`, `math.trunc` and `math.sign` of a
    % quantity, the value `dsc.rete.rlow_6_1_9_in_unit` lowers it to: out of the
    % base unit and back, each operation rounded once, for a `float64`
    % dimension; on integer storage, the rounding of the exact `(Q·x - R) / P`
    % taken back as `n::<unit>` is for a tier-1 unit, and a tier-2 unit out
    % through its `from_base` as a `Float`. A unit with no conversion to bake,
    % and a result the lowering would raise on, do not fold.
    %
    %@spec [RLOW.6.1.9]
:- pred rlow_6_1_9_folded(resolved_file::in, string::in, decl_ref::in,
                          maybe(string)::in, folded::in, folded::out,
                          fold_memo::in, fold_memo::out) is semidet.

rlow_6_1_9_folded(RF, Fn, Dimension, Unit, F0, F, !Memo) :-
    ( if whole_number_dimension(RF, Dimension) then
        (
            F0 = f_int(X)
        ;
            F0 = f_duration(R0),
            X = dsc.exact.truncate_wrapping_int64(R0)
        ),
        ( if Unit = yes(Name) then
            rlow_6_1_10_assertion_of(RF, Name, Asn)
        else
            Asn = asn_base
        ),
        (
            Asn = asn_base,
            ( if Fn = "math.sign" then
                fold_math_builtin("math.sign", [f_int(X)], F)
            else
                F = F0
            )
        ;
            Asn = asn_int(P, R, Q, _),
            rlow_6_1_9_tier1_folded(RF, Fn, P, Q, R, X, Asn, F, !Memo)
        ;
            Asn = asn_duration(P),
            rlow_6_1_9_tier1_folded(RF, Fn, P, 1i64, 0i64, X, Asn, F, !Memo)
        ;
            Asn = asn_int_tier2(_, _),
            Unit = yes(TierName),
            luni_4_3_tier2_from_base(RF, TierName, FromBase),
            ltsl_4_1_fold(RF, with_x(int_to_float(X), FromBase), f_float(Y),
                !Memo),
            ( if Fn = "math.sign" then
                fold_math_builtin("math.sign", [f_float(Y)], F)
            else
                fold_math_builtin(Fn, [f_float(Y)], f_int(I)),
                rlow_6_1_10_folded(RF, Asn, f_int(I), F, !Memo)
            )
        )
        % No arm for `asn_affine` or `asn_tier2`: `rlow_6_1_10_assertion_of`
        % gives them on `float64` storage alone, so on integer storage the
        % fold fails there.
    else
        F0 = f_float(X),
        ( if Unit = yes(Name) then
            rlow_7_3_9_conversion(RF, Dimension, Name, Conv),
            fold_out_of_base(RF, Conv, X, Y, !Memo),
            rlow_6_1_10_assertion_of(RF, Name, Back)
        else
            Y = X,
            Back = asn_base
        ),
        ( if Fn = "math.sign" then
            fold_math_builtin("math.sign", [f_float(Y)], F)
        else
            fold_math_builtin(Fn, [f_float(Y)], f_int(I)),
            rlow_6_1_10_folded(RF, Back, f_float(int_to_float(I)), F, !Memo)
        )
    ).

    % A tier-1 unit's rounding or sign on integer storage, as
    % `dsc.rete.rlow_6_1_9_tier1` lowers it: the numerator `Q·x - R`, negated
    % where `P` is negative, rounded over `|P|`, and the integer taken back by
    % `Back`, the unit's own assertion.
    %
    %@spec [RLOW.6.1.9]
:- pred rlow_6_1_9_tier1_folded(resolved_file::in, string::in, int64::in,
                                int64::in, int64::in, int64::in,
                                rlow_6_1_10_assertion::in, folded::out,
                                fold_memo::in, fold_memo::out) is semidet.

rlow_6_1_9_tier1_folded(RF, Fn, P, Q, R, X, Back, F, !Memo) :-
    NegR = -integer.from_int64(R),
    ( if Fn = "math.sign" then
        rlow_7_3_9_mul_add_folded(X, Q, NegR, Numerator),
        fold_math_builtin("math.sign", [f_int(Numerator)], f_int(S)),
        F = f_int(( if P < 0i64 then -S else S ))
    else
        ( if P < 0i64 then
            rlow_7_3_9_mul_add_folded(X, -Q, integer.from_int64(R), Signed),
            Divisor = -P
        else
            rlow_7_3_9_mul_add_folded(X, Q, NegR, Signed),
            Divisor = P
        ),
        rlow_6_1_10_folded(RF, Back, f_int(rounded_multiple(Fn, Signed,
            Divisor)), F, !Memo)
    ).

    % `M·X + A` as `FN_INT_MUL_ADD_CHECKED` computes it: fails where the
    % product, or then the sum, leaves the `Int` range, so a conversion that
    % would raise does not fold ([RLOW.6.1.10], [LDET.3.3a.8]). `A` is exact,
    % so the sum is checked against the range and never formed by a wrap.
    %
    %@spec [RLOW.7.3.9]
:- pred rlow_7_3_9_mul_add_folded(int64::in, int64::in, integer::in,
                                  int64::out) is semidet.

rlow_7_3_9_mul_add_folded(X, M, A, S) :-
    integer.to_int64(integer.from_int64(M) * integer.from_int64(X), Product),
    integer.to_int64(integer.from_int64(Product) + A, S).

    % A base-unit value in a unit, as `dsc.rete.rlow_7_3_9_converted` lowers it.
    %
    %@spec [RLOW.7.3.9]
:- pred fold_out_of_base(resolved_file::in, rlow_7_3_9_conversion::in,
                         float::in, float::out,
                         fold_memo::in, fold_memo::out) is semidet.

fold_out_of_base(_, cv_none, X, X, !Memo).
fold_out_of_base(_, cv_affine(Offset, Slope), X, Y, !Memo) :-
    ( if Offset = 0.0 then
        Shifted = X
    else
        fold_float_binary(bo_sub, X, Offset, f_float(Shifted))
    ),
    ( if Slope = 1.0 then
        Y = Shifted
    else
        fold_float_binary(bo_div, Shifted, Slope, f_float(Y))
    ).
fold_out_of_base(RF, cv_from_base(Body), X, Y, !Memo) :-
    ltsl_4_1_fold(RF, with_x(X, Body), f_float(Y), !Memo).
    % No clause for `cv_int` or `cv_int_from_base`: they are integer storage's,
    % which `rlow_6_1_9_folded` takes through its own arm, so no `Float`
    % reaches them.

    % The multiple of `F` that rounding `X` in a unit of `F` base units picks:
    % `X div F` and `X mod F` floor, as `//` and `%` do ([LEXP.7.5],
    % [LEXP.7.6]), and `round` takes ties to the even multiple.
    %
    %@helper
:- func rounded_multiple(string, int64, int64) = int64.

rounded_multiple(Fn, X, F) = M :-
    Q = X div F,
    R = X mod F,
    ( if Fn = "math.floor" then
        M = Q
    else if Fn = "math.ceil" then
        M = ( if R > 0i64 then Q + 1i64 else Q )
    else if Fn = "math.trunc" then
        M = ( if X < 0i64, R > 0i64 then Q + 1i64 else Q )
    else if R > F - R then
        M = Q + 1i64
    else if R < F - R then
        M = Q
    else
        M = Q + Q mod 2i64
    ).

    % The unit a foldable quantity's static type names ([LUNI.8.9]), `no` for a
    % value in its dimension's base unit: a literal's, a cast's target, and, for
    % an operation, its left operand's when the left one has a dimension
    % ([LUNI.8.1]). Fails where it cannot tell, and the call does not fold.
    %
    %@helper
:- pred fold_unit_of(resolved_file::in, int::in, lgra_9_3_1_expr::in,
                     decl_ref::out, maybe(string)::out) is semidet.

fold_unit_of(RF, Depth, E, Dimension, Unit) :-
    ( if quantity_literal(E, _, _, Suffix) then
        luni_3_1_7_unit_of(RF, Suffix, Dimension, Canonical),
        Unit = yes(Canonical ^ dr_name)
    else if const_read(RF, E, Scope, Const) then
        Depth > 0,
        const_value(Const, Value),
        fold_unit_of(Scope, Depth - 1, Value, Dimension, Unit)
    else if E = ex_cast(_, Target, _, _) then
        luni_3_1_7_unit_of(RF, Target ^ id_name, Dimension, Canonical),
        Unit = yes(Canonical ^ dr_name)
    else if E = ex_unary(_, Inner, _) then
        fold_unit_of(RF, Depth, Inner, Dimension, Unit)
    else if E = ex_binary(Op, L, R, _) then
        ( if carries_unit(RF, Depth, L) then
            not ( Op = bo_div, carries_unit(RF, Depth, R) ),
            fold_unit_of(RF, Depth, L, Dimension, Unit)
        else
            Op = bo_mul,
            fold_unit_of(RF, Depth, R, Dimension, Unit)
        )
    else
        E = ex_call(ex_name(Fn), [Arg | _], _),
        ( rounding_builtin(Fn ^ id_name)
        ; Fn ^ id_name = "abs"
        ; Fn ^ id_name = "min"
        ; Fn ^ id_name = "max"
        ),
        fold_unit_of(RF, Depth, Arg, Dimension, Unit)
    ).

    % Whether a foldable expression has a dimension. The folder holds a bare
    % number either way, and `::<unit>` keeps a quantity's value and converts a
    % number's ([LUNI.8.5]). The quotient of two quantities is a number
    % ([LUNI.8.1]). `Depth` stops a cycle of `const`s.
    %
    %@helper
:- pred carries_unit(resolved_file::in, int::in, lgra_9_3_1_expr::in)
    is semidet.

carries_unit(RF, Depth, E) :-
    (
        E = ex_unit(_, _, _)
    ;
        Depth > 0,
        const_read(RF, E, Scope, Const),
        const_value(Const, Value),
        carries_unit(Scope, Depth - 1, Value)
    ;
        E = ex_cast(_, Target, _, _),
        luni_3_1_7_unit_of(RF, Target ^ id_name, _, _)
    ;
        E = ex_unary(_, Inner, _),
        carries_unit(RF, Depth, Inner)
    ;
        E = ex_binary(Op, L, R, _),
        ( if Op = bo_div then
            ( if carries_unit(RF, Depth, L) then
                not carries_unit(RF, Depth, R)
            else
                carries_unit(RF, Depth, R)
            )
        else
            ( carries_unit(RF, Depth, L)
            ; carries_unit(RF, Depth, R)
            )
        )
    ;
        E = ex_call(_, Args, _),
        list.any_true(carries_unit(RF, Depth), Args)
    ).

    % A cast the runtime does not perform: the value is the stored number.
    %
    %@helper
:- pred identity_cast(resolved_file::in, string::in, folded::in) is semidet.

identity_cast(RF, Target, F) :-
    ( if luni_3_1_7_unit_of(RF, Target, _, _) then
        ( F = f_int(_)
        ; F = f_float(_)
        )
    else
        ( Target = "Float", F = f_float(_)
        ; Target = "Int", F = f_int(_)
        )
    ).

luni_7_2_storage_value(RF, Field, V0, V) :-
    ( if
        V0 = tv_float(X),
        slot_entry(RF, Field, Entry),
        Type = luni_7_1_slot_type(RF ^ rf_unit_storage, Entry, non_null),
        Type ^ dt_leaf = lk_int,
        Type ^ dt_dim = dim(_, _)
    then
        not float.is_inf(X),
        integer.to_int64(round_half_even(exact(X)), I),
        V = tv_int(I)
    else
        V = V0
    ).

    %@helper
:- pred fold_chain(resolved_file::in, folded::in,
                   list(lgra_9_3_2_compare_step)::in, bool::in, bool::out,
                   fold_memo::in, fold_memo::out) is semidet.

fold_chain(_, _, [], B, B, !Memo).
fold_chain(RF, Left, [Step | Steps], B0, B, !Memo) :-
    ltsl_4_1_fold(RF, Step ^ cs_right, Right, !Memo),
    fold_compare(Step ^ cs_op, Left, Right, Holds),
    fold_chain(RF, Right, Steps, bool.and(B0, Holds), B, !Memo).

    %@helper
:- pred fold_binary(lgra_9_3_1_binary_op::in, folded::in, folded::in,
                    folded::out) is semidet.

fold_binary(Op, FL, FR, F) :-
    ( if FL = f_int(A), FR = f_int(B) then
        fold_int_binary(Op, A, B, F)
    else if float_operand(FL, A), float_operand(FR, B) then
        fold_float_binary(Op, A, B, F)
    else if ltim_4_1_fold_temporal(Op, FL, FR, F0) then
        F = F0
    else if FL = f_duration(D), FR = f_float(X) then
        fold_float_scale(Op, whole_ns_float(D), X, F)
    else if FL = f_float(X), FR = f_duration(D), Op = bo_mul then
        fold_float_scale(Op, X, whole_ns_float(D), F)
    else if FL = f_duration(A), FR = f_duration(B) then
        IA = dsc.exact.truncate_wrapping_int64(A),
        IB = dsc.exact.truncate_wrapping_int64(B),
        (
            Op = bo_add,
            rlow_6_1_6_checked_fold(dsc.exact.add(A, B), F)
        ;
            Op = bo_sub,
            F = f_duration(rlow_6_1_6_saturated(wrapped_ns(dsc.exact.sub(A, B))))
        ;
            % As on two `Int`s ([RLOW.6.1.6]).
            Op = bo_div,
            fold_int_binary(bo_div, IA, IB, F)
        ;
            Op = bo_floordiv,
            fold_int_binary(bo_floordiv, IA, IB, F)
        ;
            Op = bo_mod,
            fold_int_binary(bo_mod, IA, IB, f_int(M)),
            F = f_duration(dsc.exact.from_int64(M))
        )
    else if FL = f_duration(D), FR = f_int(N), Op = bo_mul then
        rlow_6_1_6_checked_fold(dsc.exact.mul(D, dsc.exact.from_int64(N)), F)
    else if FL = f_int(N), FR = f_duration(D), Op = bo_mul then
        rlow_6_1_6_checked_fold(dsc.exact.mul(dsc.exact.from_int64(N), D), F)
    else if FL = f_duration(D), FR = f_int(N),
        ( Op = bo_div ; Op = bo_floordiv )
    then
        % As `dsc.rete` lowers it. A zero `n` traps and does not fold.
        N \= 0i64,
        dsc.exact.divide(D, dsc.exact.from_int64(N), Q),
        F = f_duration(rlow_6_1_6_saturated(
            dsc.exact.from_integer(dsc.exact.floor_integer(Q))))
    else
        FL = f_bool(A),
        FR = f_bool(B),
        (
            Op = bo_and,
            F = f_bool(bool.and(A, B))
        ;
            Op = bo_or,
            F = f_bool(bool.or(A, B))
        )
    ).

    % `FN_DURATION_ADD` and `FN_DURATION_MUL` as the engine evaluates them on
    % `Duration` operands: a negative result is `0`, and one above 2^63 - 1 raises
    % and does not fold ([LTIM.4.1.1]).
    %
    %@spec [RLOW.6.1.6]
:- pred rlow_6_1_6_checked_fold(rational::in, folded::out) is semidet.

rlow_6_1_6_checked_fold(R, F) :-
    I = dsc.exact.floor_integer(R),
    ( if I < integer.zero then
        F = f_duration(dsc.exact.from_int64(0i64))
    else
        integer.to_int64(I, N),
        F = f_duration(dsc.exact.from_int64(N))
    ).

    %@helper
:- func whole_ns_float(rational) = float.

whole_ns_float(R) = int_to_float(dsc.exact.truncate_wrapping_int64(R)).

    % The `Float` operation over the nanoseconds, its result rounded ties to even
    % to a whole `Duration` and saturated at zero. A non-finite result, or one
    % outside `Int`, raises and does not fold ([LTIM.4.1.1]).
    %
    %@spec [RLOW.6.1.6]
:- pred fold_float_scale(lgra_9_3_1_binary_op::in, float::in, float::in,
                         folded::out) is semidet.

fold_float_scale(Op, A, B, F) :-
    ( Op = bo_mul ; Op = bo_div ; Op = bo_floordiv ),
    fold_float_binary(Op, A, B, f_float(X)),
    not float.is_inf(X),
    integer.to_int64(round_half_even(exact(X)), N),
    F = f_duration(rlow_6_1_6_saturated(dsc.exact.from_int64(N))).

    % A `Duration` is an `Int` of nanoseconds, so its arithmetic wraps as `Int`
    % arithmetic does ([LEXP.7.13.1]).
    %
    %@helper
:- func wrapped_ns(rational) = rational.

wrapped_ns(R) = dsc.exact.from_int64(dsc.exact.truncate_wrapping_int64(R)).

    % `Time` and `Date` arithmetic, as the engine evaluates it: a result outside
    % the type's range raises and does not fold ([LTIM.1.1.5], [LTIM.1.2.2]), and
    % a `Date` moves only by whole days ([LTIM.4.2.2]). `Time - Time` and
    % `Date - Date` are `Duration`s, and an earlier first operand is `0`
    % ([RLOW.6.1.6], [LTIM.1.3.1]).
    %
    %@spec [LTIM.4.1]
    %@spec [LTIM.4.2.3]
:- pred ltim_4_1_fold_temporal(lgra_9_3_1_binary_op::in, folded::in, folded::in,
                               folded::out) is semidet.

ltim_4_1_fold_temporal(bo_add, f_time(T), f_duration(D), f_time(Sum)) :-
    exact_int64(integer.from_int64(T) + whole_ns(D), Sum).
ltim_4_1_fold_temporal(bo_add, f_duration(D), f_time(T), f_time(Sum)) :-
    exact_int64(whole_ns(D) + integer.from_int64(T), Sum).
ltim_4_1_fold_temporal(bo_sub, f_time(T), f_duration(D), f_time(Diff)) :-
    exact_int64(integer.from_int64(T) - whole_ns(D), Diff).
ltim_4_1_fold_temporal(bo_sub, f_time(A), f_time(B), f_duration(R)) :-
    Exact = integer.from_int64(A) - integer.from_int64(B),
    ( if exact_int64(Exact, Ns) then
        R = rlow_6_1_6_saturated(dsc.exact.from_int64(Ns))
    else
        A < B,
        R = dsc.exact.from_int64(0i64)
    ).
ltim_4_1_fold_temporal(bo_add, f_date(Days), f_duration(D), f_date(Shifted)) :-
    ltim_4_2_3_shift(Days, D, 1i64, Shifted).
ltim_4_1_fold_temporal(bo_sub, f_date(Days), f_duration(D), f_date(Shifted)) :-
    ltim_4_2_3_shift(Days, D, -1i64, Shifted).
ltim_4_1_fold_temporal(bo_sub, f_date(A), f_date(B), f_duration(R)) :-
    ltim_1_2_2_date_in_range(A),
    ltim_1_2_2_date_in_range(B),
    ( if A =< B then
        R = dsc.exact.from_int64(0i64)
    else
        exact_int64((integer.from_int64(A) - integer.from_int64(B))
            * integer.from_int64(ns_per_day), Ns),
        R = dsc.exact.from_int64(Ns)
    ).

    %@helper
:- pred ltim_4_2_3_shift(int64::in, rational::in, int64::in, int64::out)
    is semidet.

ltim_4_2_3_shift(Days, D, Sign, Shifted) :-
    integer.to_int64(whole_ns(D), Ns),
    Ns rem ns_per_day = 0i64,
    ltim_1_2_2_date_in_range(Days),
    Shifted = Days + Sign * (Ns // ns_per_day),
    ltim_1_2_2_date_in_range(Shifted).

    %@helper
:- func ns_per_day = int64.

ns_per_day = 86400000000000i64.

    %@helper
:- func whole_ns(rational) = integer.

whole_ns(R) = dsc.exact.truncate_integer(R).

    %@helper
:- pred exact_int64(integer::in, int64::out) is semidet.

exact_int64(I, N) :-
    integer.to_int64(I, N).

    % The value the lowering's `FN_MAX(<op>, 0)` gives.
    %
    %@spec [RLOW.6.1.6]
:- func rlow_6_1_6_saturated(rational) = rational.

rlow_6_1_6_saturated(R) =
    ( if dsc.exact.sign(R) < 0 then dsc.exact.from_int64(0i64) else R ).

    % Exact, then wrapped. `/` is a `Float`. A zero divisor traps and does not
    % fold.
    %
    %@helper
:- pred fold_int_binary(lgra_9_3_1_binary_op::in, int64::in, int64::in,
                        folded::out) is semidet.

fold_int_binary(Op, A, B, F) :-
    IA = integer.from_int64(A),
    IB = integer.from_int64(B),
    (
        Op = bo_add,
        F = f_int(dsc.exact.wrap_int64(IA + IB))
    ;
        Op = bo_sub,
        F = f_int(dsc.exact.wrap_int64(IA - IB))
    ;
        Op = bo_mul,
        F = f_int(dsc.exact.wrap_int64(IA * IB))
    ;
        Op = bo_div,
        B \= 0i64,
        fold_float_binary(bo_div, int_to_float(A), int_to_float(B), F)
    ;
        Op = bo_floordiv,
        B \= 0i64,
        F = f_int(dsc.exact.wrap_int64(integer.div(IA, IB)))
    ;
        Op = bo_mod,
        B \= 0i64,
        F = f_int(dsc.exact.wrap_int64(integer.mod(IA, IB)))
    ;
        Op = bo_pow,
        ( if B >= 0i64 then
            F = f_int(wrapping_pow(IA, IB))
        else
            float_pow(int_to_float(A), int_to_float(B), X),
            F = f_float(X)
        )
    ;
        Op = bo_bitand,
        F = f_int(A /\ B)
    ;
        Op = bo_bitor,
        F = f_int(A \/ B)
    ;
        Op = bo_bitxor,
        F = f_int(int64.xor(A, B))
    ;
        Op = bo_shl,
        B >= 0i64,
        ( if B >= 64i64 then
            F = f_int(0i64)
        else
            F = f_int(dsc.exact.wrap_int64(IA * integer.pow(integer.two,
                integer.from_int64(B))))
        )
    ;
        Op = bo_shr,
        B >= 0i64,
        ( if B >= 64i64 then
            F = f_int(( if A < 0i64 then -1i64 else 0i64 ))
        else
            F = f_int(dsc.exact.wrap_int64(integer.div(IA,
                integer.pow(integer.two, integer.from_int64(B)))))
        )
    ).

    % Modulo 2^64, by squaring.
    %
    %@helper
:- func wrapping_pow(integer, integer) = int64.

wrapping_pow(Base, Exponent) = dsc.exact.wrap_int64(Power) :-
    Modulus = integer.pow(integer.two, integer.integer(64)),
    pow_mod(integer.mod(Base, Modulus), Exponent, Modulus, integer.one, Power).

    %@helper
:- pred pow_mod(integer::in, integer::in, integer::in, integer::in,
                integer::out) is det.

pow_mod(Base, Exponent, Modulus, Acc, Power) :-
    ( if integer.is_zero(Exponent) then
        Power = Acc
    else
        Acc1 = ( if integer.is_zero(integer.mod(Exponent, integer.two)) then
            Acc else integer.mod(Acc * Base, Modulus) ),
        pow_mod(integer.mod(Base * Base, Modulus), Exponent // integer.two,
            Modulus, Acc1, Power)
    ).

    %@helper
:- pred float_operand(folded::in, float::out) is semidet.

float_operand(f_float(X), X).
float_operand(f_int(I), int_to_float(I)).

    %@helper
:- func int_to_float(int64) = float.

int_to_float(I) = X :-
    ( if dsc.exact.to_float(dsc.exact.from_int64(I), X0) then
        X = X0
    else
        unexpected($pred, "an Int has no nearest double")
    ).

    % Each rounded once to the nearest double. A NaN result fails.
    %
    %@helper
:- pred fold_float_binary(lgra_9_3_1_binary_op::in, float::in, float::in,
                          folded::out) is semidet.

fold_float_binary(Op, A, B, F) :-
    (
        Op = bo_add,
        f_add(A, B, X)
    ;
        Op = bo_sub,
        f_add(A, neg(B), X)
    ;
        Op = bo_mul,
        f_mul(A, B, X)
    ;
        Op = bo_div,
        f_div(A, B, X)
    ;
        Op = bo_floordiv,
        % A zero divisor gives `a / b`, as `lexp_7_5_float_floordiv` answers it.
        ( if is_zero_float(B) then
            f_div(A, B, X)
        else
            f_divmod(A, B, _, X)
        )
    ;
        Op = bo_mod,
        f_divmod(A, B, X, _)
    ;
        Op = bo_pow,
        float_pow(A, B, X)
    ),
    F = f_float(X).

    %@helper
:- func exact(float) = rational.

exact(X) = R :-
    ( if dsc.exact.from_float(X, R0) then
        R = R0
    else
        unexpected($pred, "not a finite double")
    ).

    % The nearest double, ties to even, as IEEE 754 rounds an overflow. An exact
    % zero is the zero `ZeroNegative` gives; a non-zero value underflowing to zero
    % keeps its own sign, since `dsc.exact.to_float` gives a zero none.
    %
    %@helper
:- func rounded(rational, bool) = float.

rounded(R, ZeroNegative) = X :-
    S = dsc.exact.sign(R),
    Negative = ( if S < 0 then yes else no ),
    ( if S = 0 then
        X = signed(ZeroNegative, 0.0)
    else if dsc.exact.to_float(R, X0) then
        X = ( if is_zero_float(X0) then signed(Negative, 0.0) else X0 )
    else
        X = signed(Negative, float.infinity)
    ).

    % A zero is built, not negated, so nothing folds `-0.0` to `0.0` on the way.
    %
    %@helper
:- func neg(float) = float.

neg(X) =
    ( if is_zero_float(X) then
        ( if dsc.exact.sign_bit(X) = yes then 0.0
        else float.unchecked_quotient(-1.0, float.infinity) )
    else
        -X
    ).

    % An exact zero sum is `+0.0` unless both operands are `-0.0`.
    %
    %@helper
:- pred f_add(float::in, float::in, float::out) is semidet.

f_add(A, B, X) :-
    ( if float.is_inf(A), float.is_inf(B) then
        dsc.exact.sign_bit(A) = dsc.exact.sign_bit(B),
        X = A
    else if float.is_inf(A) then
        X = A
    else if float.is_inf(B) then
        X = B
    else
        Zero = bool.and(dsc.exact.sign_bit(A), dsc.exact.sign_bit(B)),
        X = rounded(dsc.exact.add(exact(A), exact(B)), Zero)
    ).

    %@helper
:- pred f_mul(float::in, float::in, float::out) is semidet.

f_mul(A, B, X) :-
    Negative = bool.xor(dsc.exact.sign_bit(A), dsc.exact.sign_bit(B)),
    ( if ( float.is_inf(A) ; float.is_inf(B) ) then
        not is_zero_float(A),
        not is_zero_float(B),
        X = signed(Negative, float.infinity)
    else
        X = rounded(dsc.exact.mul(exact(A), exact(B)), Negative)
    ).

    %@helper
:- pred f_div(float::in, float::in, float::out) is semidet.

f_div(A, B, X) :-
    Negative = bool.xor(dsc.exact.sign_bit(A), dsc.exact.sign_bit(B)),
    ( if float.is_inf(A) then
        not float.is_inf(B),
        X = signed(Negative, float.infinity)
    else if float.is_inf(B) then
        X = signed(Negative, 0.0)
    else if is_zero_float(B) then
        not is_zero_float(A),
        X = signed(Negative, float.infinity)
    else
        dsc.exact.divide(exact(A), exact(B), Q),
        X = rounded(Q, Negative)
    ).

    %@helper
:- pred is_zero_float(float::in) is semidet.

is_zero_float(X) :-
    X = 0.0.

    %@helper
:- func signed(bool, float) = float.

signed(Negative, Magnitude) =
    ( if Negative = yes then neg(Magnitude) else Magnitude ).

    % As `ds.eval`'s `float_divmod` and libds's `ds_f64_floordiv` /
    % `ds_f64_floormod` compose them, each operation rounded once.
    %
    %@helper
:- pred f_divmod(float::in, float::in, float::out, float::out) is semidet.

f_divmod(A, B, Mod, FloorDiv) :-
    not is_zero_float(B),
    not float.is_inf(A),
    ( if float.is_inf(B) then
        Raw = A
    else
        Quot = dsc.exact.truncate_integer(
            det_divide(exact(A), exact(B))),
        Raw = rounded(dsc.exact.sub(exact(A),
            dsc.exact.mul(exact(B), dsc.exact.from_integer(Quot))),
            dsc.exact.sign_bit(A))
    ),
    f_add(A, neg(Raw), Diff),
    f_div(Diff, B, Div0),
    ( if not is_zero_float(Raw) then
        ( if dsc.exact.sign_bit(B) \= dsc.exact.sign_bit(Raw) then
            f_add(Raw, B, Mod),
            f_add(Div0, -1.0, Div)
        else
            Mod = Raw,
            Div = Div0
        )
    else
        Mod = signed(dsc.exact.sign_bit(B), 0.0),
        Div = Div0
    ),
    ( if not is_zero_float(Div) then
        ( if float.is_inf(Div) then
            FloorDiv = Div
        else
            Floor = rounded(dsc.exact.from_integer(
                dsc.exact.floor_integer(exact(Div))), dsc.exact.sign_bit(Div)),
            ( if
                dsc.exact.compare_rational(
                    dsc.exact.sub(exact(Div), exact(Floor)),
                    half) = (>)
            then
                f_add(Floor, 1.0, FloorDiv)
            else
                FloorDiv = Floor
            )
        )
    else
        f_div(A, B, Q),
        FloorDiv = signed(dsc.exact.sign_bit(Q), 0.0)
    ).

    %@helper
:- func half = rational.

half = R :-
    ( if dsc.exact.divide(dsc.exact.from_int64(1i64),
            dsc.exact.from_int64(2i64), R0) then
        R = R0
    else
        unexpected($pred, "1 / 2")
    ).

    %@helper
:- func det_divide(rational, rational) = rational.

det_divide(A, B) = Q :-
    ( if dsc.exact.divide(A, B, Q0) then
        Q = Q0
    else
        unexpected($pred, "a zero divisor")
    ).

    %@helper
:- pred float_pow(float::in, float::in, float::out) is semidet.

float_pow(A, B, X) :-
    X = core_math.pow(A, B),
    not float.is_nan(X).

    % As the engine's `val_cmp` answers them.
    %
    %@helper
:- pred fold_compare(lgra_9_3_2_compare_op::in, folded::in, folded::in,
                     bool::out) is semidet.

fold_compare(Op, L, R, Holds) :-
    ( if L = f_int(A), R = f_int(B) then
        compare(Order, A, B)
    else if float_operand(L, A), float_operand(R, B) then
        float_order(A, B, Order)
    else if L = f_string(A), R = f_string(B) then
        compare(Order, A, B)
    else if L = f_bool(A), R = f_bool(B) then
        Order = bool_order(A, B)
    else if L = f_time(A), R = f_time(B) then
        compare(Order, A, B)
    else if L = f_date(A), R = f_date(B) then
        compare(Order, A, B)
    else
        L = f_duration(A),
        R = f_duration(B),
        Order = dsc.exact.compare_rational(A, B)
    ),
    Holds = ordered(Op, Order).

    % Neither is NaN. `-0.0` equals `0.0`.
    %
    %@helper
:- pred float_order(float::in, float::in, comparison_result::out) is det.

float_order(A, B, Order) :-
    ( if
        float.is_inf(A),
        float.is_inf(B),
        dsc.exact.sign_bit(A) = dsc.exact.sign_bit(B)
    then
        Order = (=)
    else if float.is_inf(A) then
        Order = ( if dsc.exact.sign_bit(A) = yes then (<) else (>) )
    else if float.is_inf(B) then
        Order = ( if dsc.exact.sign_bit(B) = yes then (>) else (<) )
    else
        Order = dsc.exact.compare_rational(exact(A), exact(B))
    ).

    %@helper
:- func bool_order(bool, bool) = comparison_result.

bool_order(no, no) = (=).
bool_order(no, yes) = (<).
bool_order(yes, no) = (>).
bool_order(yes, yes) = (=).

    %@helper
:- func ordered(lgra_9_3_2_compare_op, comparison_result) = bool.

ordered(co_eq, O) = ( if O = (=) then yes else no ).
ordered(co_ne, O) = ( if O = (=) then no else yes ).
ordered(co_lt, O) = ( if O = (<) then yes else no ).
ordered(co_le, O) = ( if O = (>) then no else yes ).
ordered(co_gt, O) = ( if O = (>) then yes else no ).
ordered(co_ge, O) = ( if O = (<) then no else yes ).

    % `Fn` is the [LEXP.17.2] row, however the file spells it (`dsc.libcall`). A
    % NaN does not fold, and a pole's infinity does.
    %
    %@helper
:- pred fold_builtin(string::in, list(folded)::in, folded::out) is semidet.

fold_builtin(Fn, Args, F) :-
    ( if Args = [V], float_operand(V, X), transcendental(Fn, X, R) then
        not float.is_nan(R),
        F = f_float(R)
    else if Fn = "math.atan2", Args = [VY, VX] then
        float_operand(VY, Y),
        float_operand(VX, X),
        R = core_math.atan2(Y, X),
        not float.is_nan(R),
        F = f_float(R)
    else if Fn = "math.fma", Args = [VX, VY, VZ] then
        % One rounding: never `f_mul` then an add.
        float_operand(VX, X),
        float_operand(VY, Y),
        float_operand(VZ, Z),
        R = core_math.fma(X, Y, Z),
        not float.is_nan(R),
        F = f_float(R)
    else if Args = [V], lexp_3_6_1_factor(Fn, K) then
        float_operand(V, X),
        f_mul(X, K, R),
        F = f_float(R)
    else if Fn = "distance.great_circle" then
        list.map(float_operand, Args, Fs),
        lexp_5_11_2_great_circle(Fs, R),
        F = f_float(R)
    else if distance(Fn, D) then
        list.map(float_operand, Args, Fs),
        fold_distance(D, Fs, R),
        F = f_float(R)
    else
        fold_math_builtin(Fn, Args, F)
    ).

    % A tie of `min` or `max` gives the first operand, and the winner keeps its
    % own kind, as `ds.eval.pick` chooses.
    %
    %@helper
:- pred fold_math_builtin(string::in, list(folded)::in, folded::out)
    is semidet.

fold_math_builtin(Fn, Args, F) :-
    ( if Fn = "abs", Args = [f_int(I)] then
        F = f_int(dsc.exact.wrap_int64(integer.abs(integer.from_int64(I))))
    else if Fn = "abs", Args = [f_float(X)] then
        % Not `float.abs`, whose answer for a zero is a comparison's.
        F = f_float(( if dsc.exact.sign_bit(X) = yes then neg(X) else X ))
    else if Fn = "abs", Args = [f_duration(R)] then
        F = f_duration(R)
    else if Fn = "math.sign", Args = [f_int(I)] then
        F = f_int(( if I > 0i64 then 1i64 else if I < 0i64 then -1i64
            else 0i64 ))
    else if Fn = "math.sign", Args = [f_float(X)] then
        F = f_int(( if X > 0.0 then 1i64 else if X < 0.0 then -1i64
            else 0i64 ))
    else if rounding_builtin(Fn), Args = [f_int(I)] then
        F = f_int(I)
    else if rounding_builtin(Fn), Args = [f_float(X)] then
        not float.is_inf(X),
        integer.to_int64(rounded_integer(Fn, exact(X)), I),
        F = f_int(I)
    else if Fn = "math.sqrt", Args = [V] then
        float_operand(V, A),
        f_sqrt(A, X),
        F = f_float(X)
    else if Fn = "math.pow", Args = [L, R] then
        fold_binary(bo_pow, L, R, F)
    else
        Args = [A, B],
        ( if Fn = "min" then Op = co_le
        else Fn = "max", Op = co_ge ),
        ( if A = f_duration(_), B = f_duration(_) then
            true
        else
            float_operand(A, _),
            float_operand(B, _)
        ),
        fold_compare(Op, A, B, Holds),
        F = ( if Holds = yes then A else B )
    ).

    %@helper
:- pred f_sqrt(float::in, float::out) is semidet.

f_sqrt(A, X) :-
    ( if is_zero_float(A) then
        X = A
    else if float.is_inf(A) then
        dsc.exact.sign_bit(A) = no,
        X = A
    else
        dsc.exact.sqrt_to_float(exact(A), X)
    ).

    %@helper
:- pred transcendental(string::in, float::in, float::out) is semidet.

transcendental("math.exp", X, core_math.exp(X)).
transcendental("math.ln", X, core_math.ln(X)).
transcendental("math.log2", X, core_math.log2(X)).
transcendental("math.log10", X, core_math.log10(X)).
transcendental("math.sin", X, core_math.sin(X)).
transcendental("math.cos", X, core_math.cos(X)).
transcendental("math.tan", X, core_math.tan(X)).
transcendental("math.asin", X, core_math.asin(X)).
transcendental("math.acos", X, core_math.acos(X)).
transcendental("math.atan", X, core_math.atan(X)).
transcendental("math.sinh", X, core_math.sinh(X)).
transcendental("math.cosh", X, core_math.cosh(X)).
transcendental("math.tanh", X, core_math.tanh(X)).

    %@spec [LEXP.3.6.1]
:- pred lexp_3_6_1_factor(string::in, float::out) is semidet.

lexp_3_6_1_factor(Fn, K) :-
    dsc.exact.to_float(dsc.exact.pi, Pi),
    (
        Fn = "math.degrees",
        f_div(180.0, Pi, K)
    ;
        Fn = "math.radians",
        f_div(Pi, 180.0, K)
    ).

    % Every operation rounded once and associated as written, as the engines'
    % FN_GREAT_CIRCLE runs it. A comparison with a NaN fails, so each range test
    % refuses one.
    %
    %@spec [LEXP.5.11.2]
    %@spec [LEXP.5.11.3]
:- pred lexp_5_11_2_great_circle(list(float)::in, float::out) is semidet.

lexp_5_11_2_great_circle(Fs, D) :-
    Fs = [Lat1, Lon1, Lat2, Lon2],
    Lat1 >= -90.0, Lat1 =< 90.0,
    Lat2 >= -90.0, Lat2 =< 90.0,
    Lon1 >= -180.0, Lon1 =< 180.0,
    Lon2 >= -180.0, Lon2 =< 180.0,
    lexp_3_6_1_factor("math.radians", K),
    f_mul(Lat1, K, Phi1),
    f_mul(Lat2, K, Phi2),
    f_add(Lat2, neg(Lat1), DLat),
    f_mul(DLat, K, DPhi),
    f_add(Lon2, neg(Lon1), DLon),
    f_mul(DLon, K, DLam),
    f_div(DPhi, 2.0, HalfPhi),
    f_div(DLam, 2.0, HalfLam),
    S = core_math.sin(HalfPhi),
    T = core_math.sin(HalfLam),
    f_mul(S, S, SS),
    f_mul(core_math.cos(Phi1), core_math.cos(Phi2), CC),
    f_mul(T, T, TT),
    f_mul(CC, TT, CCTT),
    f_add(SS, CCTT, A),
    AC = ( if A < 0.0 then 0.0 else if A > 1.0 then 1.0 else A ),
    f_sqrt(AC, RootA),
    f_add(1.0, neg(AC), OneLess),
    f_sqrt(OneLess, RootRest),
    f_mul(2.0, core_math.atan2(RootA, RootRest), Angle),
    f_mul(6371008.8, Angle, D).

    %@helper
:- type distance
    --->    d_euclidean
    ;       d_manhattan
    ;       d_chebyshev
    ;       d_cosine
    ;       d_hypotenuse.

    %@helper
:- pred distance(string::in, distance::out) is semidet.

distance("distance.euclidean", d_euclidean).
distance("distance.manhattan", d_manhattan).
distance("distance.chebyshev", d_chebyshev).
distance("distance.cosine", d_cosine).
distance("distance.hypotenuse", d_hypotenuse).

    % As `ds.eval.geometric_value` composes it, each operation rounded once.
    %
    % A Chebyshev distance of zero does not fold: its zero's sign is whatever the
    % engine's `abs` and `max` make of it.
    %
    %@helper
:- pred fold_distance(distance::in, list(float)::in, float::out) is semidet.

fold_distance(D, Fs, X) :-
    (
        D = d_hypotenuse,
        N = list.length(Fs),
        ( N = 2 ; N = 3 ),
        sum_of_squares(Fs, Sum),
        f_sqrt(Sum, X)
    ;
        D = d_cosine,
        two_points(Fs, As, Bs),
        dot(As, Bs, Dot),
        dot(As, As, NormA),
        dot(Bs, Bs, NormB),
        f_sqrt(NormA, RootA),
        f_sqrt(NormB, RootB),
        f_mul(RootA, RootB, Denominator),
        f_div(Dot, Denominator, Quotient),
        f_add(1.0, neg(Quotient), X)
    ;
        D = d_euclidean,
        two_points(Fs, As, Bs),
        differences(As, Bs, Ds),
        sum_of_squares(Ds, Sum),
        f_sqrt(Sum, X)
    ;
        D = d_manhattan,
        two_points(Fs, As, Bs),
        differences(As, Bs, Ds),
        sum(Ds, 0.0, X)
    ;
        D = d_chebyshev,
        two_points(Fs, As, Bs),
        differences(As, Bs, Ds),
        X = list.foldl(float.max, Ds, 0.0),
        not is_zero_float(X)
    ).

    %@helper
:- pred two_points(list(float)::in, list(float)::out, list(float)::out)
    is semidet.

two_points(Fs, As, Bs) :-
    N = list.length(Fs),
    ( N = 4 ; N = 6 ),
    list.det_split_list(N // 2, Fs, As, Bs).

    %@helper
:- pred differences(list(float)::in, list(float)::in, list(float)::out)
    is semidet.

differences([], [], []).
differences([A | As], [B | Bs], [D | Ds]) :-
    f_add(A, neg(B), Diff),
    D = ( if dsc.exact.sign_bit(Diff) = yes then neg(Diff) else Diff ),
    differences(As, Bs, Ds).

    %@helper
:- pred sum_of_squares(list(float)::in, float::out) is semidet.

sum_of_squares(Xs, Sum) :-
    list.map((pred(X::in, S::out) is semidet :- f_mul(X, X, S)), Xs, Squares),
    sum(Squares, 0.0, Sum).

    %@helper
:- pred sum(list(float)::in, float::in, float::out) is semidet.

sum([], Acc, Acc).
sum([X | Xs], Acc0, Acc) :-
    f_add(Acc0, X, Acc1),
    sum(Xs, Acc1, Acc).

    % With no `0.0` seed.
    %
    %@helper
:- pred dot(list(float)::in, list(float)::in, float::out) is semidet.

dot(As, Bs, Dot) :-
    As = [A | As1],
    Bs = [B | Bs1],
    f_mul(A, B, First),
    dot_rest(As1, Bs1, First, Dot).

    %@helper
:- pred dot_rest(list(float)::in, list(float)::in, float::in, float::out)
    is semidet.

dot_rest([], [], Acc, Acc).
dot_rest([A | As], [B | Bs], Acc0, Acc) :-
    f_mul(A, B, P),
    f_add(Acc0, P, Acc1),
    dot_rest(As, Bs, Acc1, Acc).

    %@helper
:- pred rounding_builtin(string::in) is semidet.

rounding_builtin("math.floor").
rounding_builtin("math.ceil").
rounding_builtin("math.trunc").
rounding_builtin("round").

    %@helper
:- func rounded_integer(string, rational) = integer.

rounded_integer(Fn, R) =
    ( if Fn = "math.floor" then dsc.exact.floor_integer(R)
    else if Fn = "math.ceil" then -dsc.exact.floor_integer(dsc.exact.negate(R))
    else if Fn = "math.trunc" then dsc.exact.truncate_integer(R)
    else round_half_even(R) ).

    %@helper
:- func round_half_even(rational) = integer.

round_half_even(R) = N :-
    Floor = dsc.exact.floor_integer(R),
    Order = dsc.exact.compare_rational(
        dsc.exact.sub(R, dsc.exact.from_integer(Floor)), half),
    ( if Order = (<) then
        N = Floor
    else if Order = (>) then
        N = Floor + integer.one
    else if integer.is_zero(integer.mod(Floor, integer.two)) then
        N = Floor
    else
        N = Floor + integer.one
    ).

    % A `Duration` that is not a whole, non-negative number of nanoseconds does
    % not fold. A test value has no form for a `Time`, a `Date` or `null`.
    %
    %@helper
:- func folded_value(folded) = test_value is semidet.

folded_value(f_int(I)) = tv_int(I).
folded_value(f_float(X)) = tv_float(X).
folded_value(f_bool(B)) = tv_bool(B).
folded_value(f_string(S)) = tv_string(S).
folded_value(f_json(S)) = tv_json(S).
folded_value(f_duration(R)) = tv_duration(uint64.cast_from_int64(I)) :-
    I = dsc.exact.truncate_wrapping_int64(R),
    R = dsc.exact.from_int64(I),
    I >= 0i64.

    %@helper
:- pred string_literal_checked(lgra_9_3_1_expr::in, maybe(string)::out,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

string_literal_checked(E, MaybeS, !Errors) :-
    R = string_lit(E),
    (
        R = sl_ok(S),
        MaybeS = yes(S)
    ;
        R = sl_bad_escape(Reason),
        MaybeS = no,
        !:Errors = [front_error_at(parse_bad_escape, expr_start(E),
            "invalid escape sequence: " ++ Reason ++ " ([LGRA.2.9.4])")
            | !.Errors]
    ;
        R = sl_site,
        MaybeS = no,
        !:Errors = [error_at(dv_test_non_literal, expr_start(E),
            "an interpolated string is not a literal; a test's strings are "
            ++ "constant ([LTSL.4.1])") | !.Errors]
    ;
        R = sl_not_string,
        MaybeS = no,
        !:Errors = [error_at(dv_test_non_literal, expr_start(E),
            "a string literal is needed here ([LTSL.4.1])") | !.Errors]
    ).

    %@helper
:- pred json_literal_checked(lgra_9_3_1_expr::in, maybe(string)::out,
                             list(diagnostic)::in, list(diagnostic)::out)
    is det.

json_literal_checked(E, MaybeS, !Errors) :-
    ( if E = ex_string(Text, _) then
        Decoded = lgra_2_9_4_decode(string.to_char_list(Text)),
        (
            Decoded = decoded(Chars),
            MaybeS = yes(string.from_char_list(Chars))
        ;
            Decoded = bad_escape(Reason),
            MaybeS = no,
            !:Errors = [front_error_at(parse_bad_escape, expr_start(E),
                "invalid escape sequence: " ++ Reason ++ " ([LGRA.2.9.4])")
                | !.Errors]
        )
    else
        MaybeS = no,
        !:Errors = [error_at(dv_test_non_literal, expr_start(E),
            "a string literal is needed here ([LTSL.4.1])") | !.Errors]
    ).

    %@helper
:- type string_lit
    --->    sl_ok(string)
    ;       sl_site
    ;       sl_bad_escape(string)
    ;       sl_not_string.

    % What `dsc.rete`'s `literal_string` makes of the same text in a rule.
    %
    %@helper
:- func string_lit(lgra_9_3_1_expr) = string_lit.

string_lit(E) = R :-
    ( if E = ex_string(Text, _) then
        ( if has_site(lgra_2_9_6_7_pieces(string.to_char_list(Text))) then
            R = sl_site
        else
            Decoded = lgra_2_9_4_decode(string.to_char_list(
                brace_escapes(Text))),
            (
                Decoded = decoded(Chars),
                R = sl_ok(string.from_char_list(Chars))
            ;
                Decoded = bad_escape(Reason),
                R = sl_bad_escape(Reason)
            )
        )
    else
        R = sl_not_string
    ).

    %@helper
:- pred string_literal(lgra_9_3_1_expr::in, string::out) is semidet.

string_literal(E, S) :-
    string_lit(E) = sl_ok(S).

    %@helper
:- func brace_escapes(string) = string.

brace_escapes(Text) =
    string.replace_all(string.replace_all(Text, "{{", "{"), "}}", "}").

    %@helper
:- pred duration_literal_ns(lgra_9_3_1_expr::in, uint64::out) is semidet.

duration_literal_ns(ex_unit(Magnitude, Suffix, _), Ns) :-
    luni_10_2_time_unit(llex_12_5_symbol_of(Suffix), Multiplier),
    luni_3_1_5_magnitude_ns(Magnitude, Multiplier, N),
    N >= 0i64,
    Ns = uint64.cast_from_int64(N).

%-----------------------------------------------------------------------------%
% `initial:` cache seeds -- [LTSL.5.2]
%-----------------------------------------------------------------------------%

    %@spec [LTSL.5.2]
:- pred ltsl_5_2_seed(resolved_file::in,
                      {lgra_9_3_1_expr, lgra_9_3_1_expr, pos}::in,
                      list(test_seed_ir)::in, list(test_seed_ir)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_5_2_seed(RF, {K, V, _}, !Seeds, !Errors) :-
    string_literal_checked(K, MaybeKey, !Errors),
    ltsl_4_1_literal(RF, V, MaybeValue, !Errors),
    ( if MaybeKey = yes(Key), MaybeValue = yes(Value) then
        !:Seeds = [test_seed_ir(Key, Value) | !.Seeds]
    else
        true
    ).

%-----------------------------------------------------------------------------%
% The ruleset's `initial:` block -- [LGRA.24.3]
%-----------------------------------------------------------------------------%

    % The `filter_map`s cannot drop an item: every item has passed
    % `dsc.validate.lgra_24_2_initial`.
    %
lgra_24_3_initial_items(RF) =
    list.filter_map(initial_item(RF), list.condense(list.map(
        ( func(B) = B ^ ain_items ),
        list.filter_map(initial_block, RF ^ rf_ast ^ af_decls)))).

    %@helper
:- func initial_block(ast_decl) = ast_initial is semidet.

initial_block(ad_initial(B)) = B.

    %@helper
:- func initial_item(resolved_file, ast_test_initial) = initial_item_ir
    is semidet.

initial_item(RF, tini_fact(F)) = ii_fact(S ^ as_own, Slots) :-
    lgra_22_4_schema_of(RF, F ^ tfa_schema, S),
    Slots = list.filter_map(initial_slot(RF, S ^ as_fields), F ^ tfa_args).
initial_item(RF, tini_cache(K, V, _)) = ii_seed(Key, Value) :-
    ltsl_4_1_string_constant(RF, K, Key),
    ltsl_4_1_constant(RF, V, Value).

    %@helper
:- func initial_slot(resolved_file, list(ast_field), ast_action_arg)
    = test_slot is semidet.

initial_slot(RF, Fields, aaa_kwarg(Name, E, _)) = test_slot(Name ^ id_name, V) :-
    ltsl_4_1_constant(RF, E, V0),
    ( if
        list.find_first_match(
            ( pred(Fd::in) is semidet :- Fd ^ af_name ^ id_name = Name ^ id_name ),
            Fields, Field)
    then
        luni_7_2_storage_value(RF, Field, V0, V)
    else
        V = V0
    ).

%-----------------------------------------------------------------------------%
% `responses:` -- [LTSL.7]
%-----------------------------------------------------------------------------%

    %@spec [LTSL.7.2]
    %@spec [LTSL.7.4]
    %@spec [LTSL.7.5]
:- pred ltsl_7_2_stub(resolved_file::in, ast_test_stub::in,
                      test_counters::in, test_counters::out,
                      list(test_stub_ir)::in, list(test_stub_ir)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_7_2_stub(RF, Stub, !Counters, !Stubs, !Errors) :-
    StubId = !.Counters ^ c_stub,
    !Counters ^ c_stub := StubId + 1u32,
    list.foldl2(literal_slot(RF), Stub ^ tstb_args, [], RevArgs, !Errors),
    Args = list.reverse(RevArgs),
    (
        Stub ^ tstb_corr = no,
        Corr = ""
    ;
        Stub ^ tstb_corr = yes(CorrE),
        string_literal_checked(CorrE, MaybeCorr, !Errors),
        Corr = maybe.maybe_default("", MaybeCorr)
    ),
    (
        Stub ^ tstb_after = no,
        After = 0u64
    ;
        Stub ^ tstb_after = yes(AfterE),
        ( if duration_literal_ns(AfterE, A) then
            After = A
        else
            After = 0u64,
            !:Errors = [error_at(dv_test_non_literal, expr_start(AfterE),
                "`after` takes a duration literal ([LTSL.7.4])") | !.Errors]
        )
    ),
    ( if Stub ^ tstb_corr = no, Stub ^ tstb_args = [] then
        !:Errors = [error_at(dv_test_stub_unkeyed, Stub ^ tstb_pos,
            "`for call " ++ spelled_service(Stub ^ tstb_service)
            ++ "` must key the call by correlation (`as \"...\"`) or by "
            ++ "arguments (`slot: val`) ([LTSL.7.2])") | !.Errors]
    else
        true
    ),
    NoResponse = ( if list.any_true(( pred(R::in) is semidet :-
                        R = trep_no_response(_) ), Stub ^ tstb_replies)
                   then yes else no ),
    ReplyFacts = list.filter_map(reply_fact_of, Stub ^ tstb_replies),
    ltsl_7_3_reply_types(RF, Stub, ReplyFacts, !Errors),
    list.foldl2(ltsl_7_3_reply(RF), ReplyFacts, [], RevReplies, !Errors),
    !:Stubs = [test_stub_ir(StubId, spelled_service(Stub ^ tstb_service), Corr,
        Args, After, NoResponse, list.reverse(RevReplies)) | !.Stubs].

    % A stub for a service the file does not resolve has no response to hold the
    % reply to.
    %
    %@spec [LTSL.7.3]
    %@spec [LTSL.7.5]
:- pred ltsl_7_3_reply_types(resolved_file::in, ast_test_stub::in,
                             list(ast_test_fact)::in,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_7_3_reply_types(RF, Stub, Replies, !Errors) :-
    Svc = spelled_service(Stub ^ tstb_service),
    ( if
        map.search(RF ^ rf_services, service_key(Stub ^ tstb_service),
            Service)
    then
        Response = Service ^ asv_response,
        (
            Response = ar_schema(T0),
            % `T0` is the spelling in the file that declares the service.
            ( if
                map.search(RF ^ rf_response_names,
                    service_key(Stub ^ tstb_service), Own)
            then
                T = Own
            else
                T = T0 ^ id_name
            ),
            list.foldl(reply_of(RF, Svc, T), Replies, !Errors)
        ;
            Response = ar_none(_),
            (
                Replies = []
            ;
                Replies = [R | _],
                !:Errors = [with_hint(error_at(
                    dv_test_stub_no_response_mismatch,
                    type_ref_name(R ^ tfa_schema) ^ id_pos,
                    "`" ++ Svc ++ "` declares `no response`, so its stub "
                        ++ "replies nothing ([LTSL.7.5])"),
                    "write `no response` as the stub's only line")
                    | !.Errors]
            )
        ;
            Response = ar_absent
        )
    else
        true
    ).

    %@helper
:- pred reply_of(resolved_file::in, string::in, string::in, ast_test_fact::in,
                 list(diagnostic)::in, list(diagnostic)::out) is det.

reply_of(RF, Svc, T, R, !Errors) :-
    % This file's scope says which schema the reference names. `CallError` and a
    % name resolving to no schema are held to `T` by the name it ends in.
    Name = type_ref_name(R ^ tfa_schema),
    ( if lgra_22_4_schema_of(RF, R ^ tfa_schema, Resolved) then
        Schema = Resolved ^ as_own
    else
        Schema = Name ^ id_name
    ),
    ( if ( Schema = T ; Name ^ id_name = "CallError" ) then
        true
    else
        !:Errors = [with_hint(error_at(dv_test_stub_reply_type,
            Name ^ id_pos,
            "a reply to `" ++ Svc ++ "` is a `" ++ T ++ "` or a `CallError`, "
                ++ "not a `" ++ type_ref_text(R ^ tfa_schema) ++ "` "
                ++ "([LTSL.7.3])"),
            "`" ++ Svc ++ "` declares `response " ++ T ++ "`") | !.Errors]
    ).

    %@helper
:- func service_key(ast_service_ref) = string.

service_key(asr_bare(Path)) = dotted(Path).

    %@spec [LTSL.7.3]
:- pred ltsl_7_3_reply(resolved_file::in, ast_test_fact::in,
                       list(test_reply_ir)::in, list(test_reply_ir)::out,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_7_3_reply(RF, F, !Replies, !Errors) :-
    list.foldl2(reply_slot(RF, type_ref_text(F ^ tfa_schema)), F ^ tfa_args,
        [], RevSlots, !Errors),
    ( if lgra_22_4_schema_of(RF, F ^ tfa_schema, Resolved) then
        Schema = Resolved ^ as_own
    else
        Schema = type_ref_text(F ^ tfa_schema)
    ),
    !:Replies = [test_reply_ir(Schema, list.reverse(RevSlots)) | !.Replies].

    %@helper
:- pred reply_slot(resolved_file::in, string::in, ast_action_arg::in,
                   list(test_slot)::in, list(test_slot)::out,
                   list(diagnostic)::in, list(diagnostic)::out) is det.

reply_slot(RF, Schema, Arg, !Slots, !Errors) :-
    ( if lfac_9_3_test_ts(Schema, Arg, !Errors) then
        true
    else
        literal_slot(RF, Arg, !Slots, !Errors)
    ).

    %@helper
:- func spelled_service(ast_service_ref) = string.

spelled_service(asr_bare(Path)) = dotted(Path).

    %@helper
:- func dotted(list(ident)) = string.

dotted(Ids) = string.join_list(".", list.map((func(I) = I ^ id_name), Ids)).

%-----------------------------------------------------------------------------%
% `produces:` -- [LTSL.8]
%-----------------------------------------------------------------------------%

    %@spec [LTSL.8.2]
    %@spec [LTSL.8.3]
    %@spec [LTSL.8.4]
:- pred ltsl_8_2_assertion(resolved_file::in, list(string)::in, string::in,
                           ast_test_assertion::in,
                           list(test_oracle_ir)::in, list(test_oracle_ir)::out,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

ltsl_8_2_assertion(RF, RuleNames, TestName, A, !Oracles, !Errors) :-
    Pol = ( if A ^ tas_never = yes then tp_never else tp_pos ),
    Head = A ^ tas_head,
    (
        Head = thd_activated(Rule),
        ( if list.member(Rule ^ id_name, RuleNames) then
            true
        else
            !:Errors = [error_at(dv_test_unknown_rule, Rule ^ id_pos,
                "test \"" ++ TestName ++ "\" asserts `activated "
                ++ Rule ^ id_name ++ "` and no such rule exists "
                ++ "([RLOW.17.3])") | !.Errors]
        ),
        MaybeOracle = yes(toi_activated(Pol, Rule ^ id_name))
    ;
        % `Args` is empty when `Where` is set: the parser refuses a head with both.
        Head = thd_emitted(S, Args, Where),
        rlow_17_3_schema_slots(RF, S, Args, Name, Slots, !Errors),
        MaybeOracle = yes(toi_emitted(Pol, Name, Slots, has_where(Where)))
    ;
        % [LTSL.8.4]: "The compiler must refuse a `where` predicate on a
        % `published` head, with or without `never`, with
        % `DS_VALIDATE_TEST_PUBLISHED_WHERE`": the predicate is a rule over
        % working memory ([RTIM.14.11]), and a `publish` puts nothing there
        % ([LTIE.4.3]), so it could never hold. `oracle_rules_of` builds no
        % rule for one.
        Head = thd_published(S, Args, Where),
        rlow_17_3_schema_slots(RF, S, Args, Name, Slots, !Errors),
        (
            Where = yes(W),
            !:Errors = [with_hint(error_at(dv_test_published_where,
                W ^ twh_binding ^ id_pos,
                "test \"" ++ TestName ++ "\" asserts `published` with a "
                    ++ "`where`, which is a rule over working memory, and a "
                    ++ "`publish` asserts nothing there ([LTSL.8.4], "
                    ++ "[LTIE.4.3])"),
                "match the published fact by slot arguments, as `published "
                    ++ Name ++ " slot: value`") | !.Errors],
            MaybeOracle = no
        ;
            Where = no,
            MaybeOracle = yes(toi_published(Pol, Name, Slots, no))
        )
    ;
        Head = thd_retracted(S, Args),
        rlow_17_3_schema_slots(RF, S, Args, Name, Slots, !Errors),
        MaybeOracle = yes(toi_retracted(Pol, Name, Slots))
    ;
        Head = thd_recorded(_),
        !:Errors = [with_hint(error_at(dv_test_recorded_retired, A ^ tas_pos,
            "`recorded` is retired and is not an assertion head ([LTSL.8.2])"),
            "assert the call with `called`") | !.Errors],
        MaybeOracle = no
    ;
        Head = thd_called(Svc, MaybeCorr),
        (
            MaybeCorr = no,
            Corr = no
        ;
            MaybeCorr = yes(CorrE),
            string_literal_checked(CorrE, Corr, !Errors)
        ),
        MaybeOracle = yes(toi_called(Pol, spelled_service(Svc), Corr))
    ;
        Head = thd_cached(KeyE, MaybeValue),
        string_literal_checked(KeyE, MaybeKey, !Errors),
        (
            MaybeValue = no,
            Value = no
        ;
            MaybeValue = yes(ValueE),
            ltsl_4_1_literal(RF, ValueE, Value, !Errors)
        ),
        MaybeOracle = yes(toi_cached(Pol, maybe.maybe_default("", MaybeKey),
            Value))
    ;
        Head = thd_cache_deleted(KeyE),
        string_literal_checked(KeyE, MaybeKey, !Errors),
        MaybeOracle = yes(toi_cache_deleted(Pol,
            maybe.maybe_default("", MaybeKey)))
    ;
        Head = thd_logged(Level, MaybeMsg),
        ( if log_level_number(Level, N) then
            LevelN = N
        else
            LevelN = 0u32,
            !:Errors = [error_at(dv_bad_log_level, A ^ tas_pos,
                "unknown log level; the levels are debug, info, warning, "
                ++ "error and critical ([LGRA.10.1.1])") | !.Errors]
        ),
        (
            MaybeMsg = no,
            Msg = no
        ;
            MaybeMsg = yes(MsgE),
            string_literal_checked(MsgE, Msg, !Errors)
        ),
        MaybeOracle = yes(toi_logged(Pol, LevelN, Msg))
    ;
        Head = thd_wm_has(S, Args),
        rlow_17_3_schema_slots(RF, S, Args, Name, Slots, !Errors),
        MaybeOracle = yes(toi_wm_has(Pol, Name, Slots))
    ;
        Head = thd_wm_count(S, CountE),
        rlow_17_3_schema_slots(RF, S, [], Name, _, !Errors),
        ( if CountE = ex_int(C, _), C >= 0i64, C =< 4294967295i64 then
            Count = uint32.cast_from_int(int64.cast_to_int(C))
        else
            Count = 0u32,
            !:Errors = [error_at(dv_test_non_literal, expr_start(CountE),
                "`wm count` takes a non-negative Int literal ([LTSL.8.6])")
                | !.Errors]
        ),
        MaybeOracle = yes(toi_wm_count(Pol, Name, Count))
    ;
        Head = thd_wm_empty,
        MaybeOracle = yes(toi_wm_empty(Pol))
    ),
    (
        MaybeOracle = yes(Oracle),
        !:Oracles = [Oracle | !.Oracles]
    ;
        MaybeOracle = no
    ).

    %@helper
:- func has_where(maybe(ast_test_where)) = bool.

has_where(no) = no.
has_where(yes(_)) = yes.

    % `LogSeverity`, 0-based, as `FN_LOG`'s level operand carries it.
    %
    %@helper
:- pred log_level_number(lgra_10_1_1_log_level::in, uint32::out) is semidet.

log_level_number(ll_debug, 0u32).
log_level_number(ll_info, 1u32).
log_level_number(ll_warning, 2u32).
log_level_number(ll_error, 3u32).
log_level_number(ll_critical, 4u32).

%-----------------------------------------------------------------------------%
:- end_module dsc.dstest.
%-----------------------------------------------------------------------------%

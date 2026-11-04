% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.rete -- rules to the Rete network: AlphaNode, BetaNode, TerminalNode, and
% the rule group.
%
% Builds the runtime's own raw nodes (`ds.network`, `ds.expr`, `ds.dsc_action`),
% which `dsc.encode` writes. `rule_group` is this module's: the loader folds
% those atoms into `ds.rules.rule_meta` and exports no raw form.
%
% A rule is lowered whole or not at all: anything not lowered makes it a
% `rule_skip`, and `dsc.driver` refuses the compile with
% `DS_VALIDATE_RULE_NOT_LOWERED`.
%
% Per pattern the alpha is interned before the beta; the terminal comes last. A
% skipped rule consumes no id.
%-----------------------------------------------------------------------------%

:- module dsc.rete.
:- interface.

:- import_module ds.
:- import_module ds.intern.
:- import_module ds.network.
:- import_module ds.schema.
:- import_module ds.series.

:- import_module dsc.resolve.
:- import_module dsc.token.

:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module uint64.

%-----------------------------------------------------------------------------%

    % One rule's metadata atoms, [RDSC.8.1]'s `rule_group`.
    %
    %@helper
:- type rule_group
    --->    rule_group(
                rg_rule     :: string,
                rg_cooldown :: maybe(uint64),
                rg_pos      :: pos,
                rg_display  :: string
                    % The RuleDebugName template; empty means no RuleDebugName atom.
            ).

    % Everything the rules contribute to the artefact, each list in emission
    % order.
    %
    % The nodes are bundle-global; rule groups and spans are per module
    % ([RDSC.8.1]).
    %
    %@helper
:- type rete_network
    --->    rete_network(
                rn_series :: list(series_decl),
                    % The series backend atoms, one per backing a lowered rule
                    % reads, in declaration order ([RDSC.5a.2]).
                rn_modules :: list(module_rules),
                    % Each module's rule groups and spans, in `module_id` order.
                rn_alphas :: list(raw_alpha),
                rn_betas  :: list(raw_beta),
                rn_terms  :: list(raw_terminal),
                rn_schemas :: list(schema)
                    % The compiler-owned schemas the network matches on --
                    % `$ClockTick` and the `after` timers -- which go ahead
                    % of the file's own ([LTAC.3.2]).
            ).

    % One module's share of the rule metadata.
    %
    %@helper
:- type module_rules
    --->    module_rules(
                mr_clip   :: uint32,
                mr_groups :: list(rule_group),
                mr_spans  :: list(node_span)
                    % One per beta or terminal attributed to a source construct
                    % in this module ([RDSC.14.3.6]).
            ).

    % A node and where its construct was written -- [RDSC.14.3.3].
    %
    %@helper
:- type node_span
    --->    node_span(
                ns_node :: uint32,
                ns_pos  :: pos
            ).

    %@helper
:- func no_rules = rete_network.

    % A rule this module did not lower, which module it is in, where, and why.
    %
    %@helper
:- type rule_skip
    --->    rule_skip(
                rsk_clip :: uint32,
                rsk_pos  :: pos,
                rsk_why  :: string
            ).

    % Every rule of every module, as network nodes: the modules in the order
    % given, each one's rules in source order.
    %
    % The order of `Modules` is the firing order ([LDET.5.4]): libraries first,
    % leaves first, the importing file last. A terminal's ordinal is its
    % position in `rn_terms`.
    %
    % The intern table is the one `dsc.lower` built the schemas against.
    %
    %@spec [RLOW.4.2.1]
    %@spec [RLOW.13.1]
    %@spec [RLOW.13.2]
    %@spec [RDSC.4a.1]
    %@spec [RDSC.4a.3]
    %@spec [RDSC.4a.5]
:- pred rlow_4_2_1_lower_rules(list(pair(uint32, resolved_file))::in,
                               list(schema)::in,
                               intern_table::in, intern_table::out,
                               rete_network::out, list(rule_skip)::out) is det.

    % A node of the lowered network holding an `Expr` nested deeper than
    % [RDSC.11.3] allows: the module and position of the construct it was
    % lowered from, where one is known, and the depth of its deepest `Expr`.
    %
    %@helper
:- type rdsc_11_3_too_deep
    --->    rdsc_11_3_too_deep(
                td_site  :: maybe(pair(uint32, pos)),
                td_depth :: int
            ).

    % Measured on the lowered network, as `dsc.encode` writes it, with the nesting
    % the encoding adds (a verb's operands below its `CallExpr`, a gated call below
    % an `IfExpr`). The outermost `Expr` of a test, an action or an assignment is
    % at depth 0, each operand one deeper, an interpolation's parts included.
    % `e_tainted` is a field of the node it wraps, not a node.
    %
    % A node's site is its span ([RDSC.14.3.6]), else its rule group's position.
    %
    %@spec [RDSC.11.3]
:- func rdsc_11_3_too_deep_nodes(intern_table, rete_network)
    = list(rdsc_11_3_too_deep).

    % A rule or a schema of the lowered network past its byte index space
    % ([RDSC.4a.9.1]), with the site of the rule it belongs to where one is
    % known, its name, and its count.
    %
    %@helper
:- type index_overflow
    --->    too_many_patterns(maybe(pair(uint32, pos)), string, int)
            % A rule built with more than 255 patterns ([LGRA.8.7]).
    ;       too_many_slots(maybe(pair(uint32, pos)), string, int).
            % A schema the compiler declared with more than 255 slots
            % ([LGRA.5.11]).

    % Measured on the lowered network. A rule's patterns are the betas from its
    % terminal to the root, negated ones included. A schema's slots are those of
    % each schema in `rn_schemas`, and its site is the first rule that asserts
    % into it. The program's own schemas are
    % `dsc.validate.lgra_5_11_slot_count`'s.
    %
    %@spec [LGRA.8.7]
    %@spec [LGRA.5.11]
:- func lgra_8_7_index_overflows(intern_table, rete_network)
    = list(index_overflow).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.action.
:- import_module ds.builtins.
:- import_module ds.capability.
:- import_module ds.chrono.
:- import_module ds.dsc_action.
:- import_module ds.expr.
:- import_module ds.i64.
:- import_module ds.id.
:- import_module ds.re2.
:- import_module ds.value.

:- import_module dsc.ast.
:- import_module dsc.builtins.
:- import_module dsc.capability.
:- import_module dsc.cast.
:- import_module dsc.dstest.
:- import_module dsc.exact.
:- import_module dsc.expr.
:- import_module dsc.lex.
:- import_module dsc.quantity.
:- import_module dsc.series.
:- import_module dsc.strlit.
:- import_module dsc.typecheck.
:- import_module dsc.types.

:- import_module assoc_list.
:- import_module map.
:- import_module bool.
:- import_module char.
:- import_module float.
:- import_module math.
:- import_module int.
:- import_module int64.
:- import_module require.
:- import_module set.
:- import_module string.
:- import_module uint32.
:- import_module unit.

%-----------------------------------------------------------------------------%

no_rules = rete_network([], [], [], [], [], []).

    % A step that either produced its value or names why the rule is skipped.
    %
    %@helper
:- type lowered(T)
    --->    done(T)
    ;       skipped(string).

    % The bundle so far. Every list is reversed.
    %
    % `bd_shared` is [IRET.6.6]'s alpha sharing, keyed by the schema and the
    % tests.
    %
    % `bd_synthetic` holds the schemas a lowering names as it builds them: the
    % capture fact and timeout timer of a continued call one level in.
    %
    %@helper
:- type build
    --->    build(
                bd_next   :: uint32,
                bd_shared :: assoc_list({schema_name, list(alpha_test)},
                                        uint32),
                bd_alphas :: list(raw_alpha),
                bd_betas  :: list(raw_beta),
                bd_terms  :: list(raw_terminal),
                bd_groups :: list(rule_group),
                bd_spans  :: list(node_span),
                bd_synthetic :: list(schema)
            ).

    % The items a lowering step consed onto one of the build's reversed lists,
    % newest first.
    %
    %@helper
:- func pushed_since(list(T), list(T)) = list(T).

pushed_since(Base, Now) = Pushed :-
    N = list.length(Now) - list.length(Base),
    ( if
        N >= 0,
        list.split_list(N, Now, Pushed0, Rest),
        Rest = Base
    then
        Pushed = Pushed0
    else
        unexpected($pred, "the build list is not its base with items pushed")
    ).

rlow_4_2_1_lower_rules(Modules, Schemas, !IT, Network, Skips) :-
    % Asked for once over every module's rules: `$ClockTick` is one schema.
    % Rules and scopes correspond by position.
    RuleEnvs = list.condense(list.map(
        ( func(_ - RF) = assoc_list.from_corresponding_lists(
            list.filter_map(rule_of, RF ^ rf_ast ^ af_decls),
            list.map(rule_type_env(RF), RF ^ rf_scopes)) ),
        Modules)),
    ltac_3_2_synthetic_schemas(Schemas, RuleEnvs, Synthetic, !IT),
    % [RLOW.14.3]: every module's author rules, then every module's oracle
    % rules.
    list.foldl4(lower_module(Schemas, rlow_14_3_author), Modules,
        build(1u32, [], [], [], [], [], [], []), B0, !IT, [], RevAuthors,
        [], RevSkips0),
    list.foldl4(lower_module(Schemas, rlow_14_3_oracle), Modules,
        B0, B, !IT, [], RevOracles, RevSkips0, RevSkips),
    RevModules = list.reverse(rlow_14_3_merge_modules(
        list.reverse(RevAuthors), list.reverse(RevOracles))),
    Betas = list.reverse(B ^ bd_betas),
    Terms = list.reverse(B ^ bd_terms),
    IT = !.IT,
    Refs = series_refs(IT, Betas, Terms),
    Series = list.condense(list.map(
        ( func(_ - RF) = rdsc_5a_2_backends(RF, Schemas, IT, Refs) ),
        Modules)),
    Network = rete_network(Series, list.reverse(RevModules),
        list.reverse(B ^ bd_alphas), Betas, Terms,
        Synthetic ++ list.reverse(B ^ bd_synthetic)),
    Skips = list.reverse(RevSkips).

    % The two passes of [RLOW.14.3]: a rule the author wrote, and an oracle
    % rule `dsc.dstest` synthesized for a test ([RTIM.14.11]), told apart by
    % the name only the second can have ([RTIM.14.13]).
    %
    %@spec [RLOW.14.3]
:- type rlow_14_3_pass
    --->    rlow_14_3_author
    ;       rlow_14_3_oracle.

    %@spec [RLOW.14.3]
:- pred rlow_14_3_in_pass(rlow_14_3_pass::in, ast_rule::in) is semidet.

rlow_14_3_in_pass(Pass, Rule) :-
    Oracle = ( if
        Rule ^ ar_origin = compiler_injected,
        string.prefix(Rule ^ ar_name ^ id_name, rtim_14_13_oracle_prefix)
    then yes else no ),
    (
        Pass = rlow_14_3_author,
        Oracle = no
    ;
        Pass = rlow_14_3_oracle,
        Oracle = yes
    ).

    % One module's share of each pass as one `module_rules`: its author groups
    % then its oracle groups, and the spans likewise ([RDSC.8.1]).
    %
    %@spec [RLOW.14.3]
:- func rlow_14_3_merge_modules(list(module_rules), list(module_rules))
    = list(module_rules).

rlow_14_3_merge_modules(Authors, Oracles) =
    list.map_corresponding(
        ( func(A, O) = module_rules(A ^ mr_clip, A ^ mr_groups ++ O ^ mr_groups,
            A ^ mr_spans ++ O ^ mr_spans) ),
        Authors, Oracles).

    % One module's rules of one pass into the shared build. The groups and spans
    % start empty and are taken off as this module's.
    %
    %@helper
:- pred lower_module(list(schema)::in, rlow_14_3_pass::in,
                     pair(uint32, resolved_file)::in,
                     build::in, build::out,
                     intern_table::in, intern_table::out,
                     list(module_rules)::in, list(module_rules)::out,
                     list(rule_skip)::in, list(rule_skip)::out) is det.

lower_module(Schemas, Pass, Clip - RF, !B, !IT, !Modules, !Skips) :-
    Rules = list.filter_map(rule_of, RF ^ rf_ast ^ af_decls),
    B0 = (!.B ^ bd_groups := []) ^ bd_spans := [],
    % Rules and scopes correspond by position, so the pair is made first.
    InPass = list.filter(
        ( pred(RS::in) is semidet :-
            RS = R - _,
            rlow_14_3_in_pass(Pass, R)
        ),
        assoc_list.from_corresponding_lists(Rules, RF ^ rf_scopes)),
    list.foldl3(lower_rule(Clip, RF, Schemas), InPass, B0, B1, !IT, !Skips),
    !:Modules = [module_rules(Clip, list.reverse(B1 ^ bd_groups),
        list.reverse(B1 ^ bd_spans)) | !.Modules],
    !:B = B1.

    % Prepend a span for a node attributed to a source construct. A node the
    % compiler made itself (a capture view, a continuation's response pattern, a
    % timer beta) has none. Called from the beta and terminal builders only: no
    % alpha has a span.
    %
    %@spec [RDSC.14.3.4]
    %@spec [RDSC.14.3.5]
    %@spec [RDSC.14.3.6]
:- func rdsc_14_3_6_span(uint32, maybe(pos), list(node_span)) = list(node_span).

rdsc_14_3_6_span(_, no, Spans) = Spans.
rdsc_14_3_6_span(Node, yes(Pos), Spans) = [node_span(Node, Pos) | Spans].

    %@helper
:- func rule_of(ast_decl) = ast_rule is semidet.

rule_of(ad_rule(R)) = R.

    % One rule, committed whole or skipped whole. The build and the intern
    % table are both discarded on a skip, so a skipped rule leaves no node, no
    % id and no string behind.
    %
    %@helper
:- pred lower_rule(uint32::in, resolved_file::in, list(schema)::in,
                   pair(ast_rule, rule_scope)::in,
                   build::in, build::out,
                   intern_table::in, intern_table::out,
                   list(rule_skip)::in, list(rule_skip)::out) is det.

lower_rule(Clip, RF, Schemas, Rule - Scope, !B, !IT, !Skips) :-
    try_rule(RF, Schemas, Rule, Scope, !.B, !.IT, Result),
    (
        Result = done({B, IT}),
        !:B = B,
        !:IT = IT
    ;
        Result = skipped(Why),
        !:Skips = [rule_skip(Clip, Rule ^ ar_pos, Why) | !.Skips]
    ).

    %@helper
:- func positive_body(ast_lhs_clause) = ast_pattern_body is semidet.

positive_body(alc_pattern(ap_simple(B))) = B.

    % A negated pattern carrying `within`, anywhere in the LHS: `$ClockTick` is
    % declared for one whether or not its tick is built.
    %
    %@helper
:- pred ast_negated_within(ast_rule::in) is semidet.

ast_negated_within(Rule) :-
    list.find_first_match((pred(C::in) is semidet :-
        C = alc_pattern(ap_negated(B, _)),
        B ^ apb_within = yes(_)), Rule ^ ar_lhs, _).

    %@helper
:- pred emits_logical(list(ast_action)::in) is semidet.

emits_logical(Actions) :-
    list.find_first_match((pred(A::in) is semidet :-
        ( A ^ aac_head = aah_emit(_) ; A ^ aac_head = aah_publish(_) ),
        list.member("logical", action_flags(A))), Actions, _).

    % A `now()` or `monotonic_ns()` call ([LGRA.9.8.10]), or a `dwell` companion
    % ([LEXP.9.5.1]).
    %
    %@helper
:- pred reads_clock(lgra_9_3_1_expr::in) is semidet.

reads_clock(E) :-
    ( if
        E = ex_call(ex_name(Fn), [], _),
        ( Fn ^ id_name = "now" ; Fn ^ id_name = "monotonic_ns" )
    then
        true
    else if E = ex_slot(_, Field, _), Field ^ id_name = "dwell" then
        true
    else
        list.find_first_match(reads_clock, ast_children(E), _)
    ).

    % A `where` is time-dependent when it reads the clock, a series, or a zone
    % other than `"UTC"`. All three move off the pattern's beta into the fire
    % guard, behind the `$ClockTick` re-driver ([LSER.8.1.1]). No pattern matches
    % `TimeZoneOffset`, so only the tick re-reads a zone guard.
    %
    %@spec [LTIM.2.4.1]
:- pred ltim_2_4_1_time_dependent(type_env::in, lgra_9_3_1_expr::in)
    is semidet.

ltim_2_4_1_time_dependent(Env, E) :-
    ( reads_clock(E)
    ; reads_series(Env, E)
    ; reads_zone(Env, E)
    ).

    %@helper
:- pred reads_zone(type_env::in, lgra_9_3_1_expr::in) is semidet.

reads_zone(Env, E) :-
    ( if ltim_2_4_1_zone_read(Env, E) then
        true
    else
        list.find_first_match(reads_zone(Env), ast_children(E), _)
    ).

    %@helper
:- pred reads_series(type_env::in, lgra_9_3_1_expr::in) is semidet.

reads_series(Env, E) :-
    ( if ltim_2_4_1_series_read(Env, E) then
        true
    else
        list.find_first_match(reads_series(Env), ast_children(E), _)
    ).

    %@helper
:- func ast_children(lgra_9_3_1_expr) = list(lgra_9_3_1_expr).

ast_children(ex_int(_, _)) = [].
ast_children(ex_float(_, _)) = [].
ast_children(ex_string(_, _)) = [].
ast_children(ex_unit(_, _, _)) = [].
ast_children(ex_bool(_, _)) = [].
ast_children(ex_null(_)) = [].
ast_children(ex_name(_)) = [].
ast_children(ex_unary(_, E, _)) = [E].
ast_children(ex_not(E, _)) = [E].
ast_children(ex_binary(_, L, R, _)) = [L, R].
ast_children(ex_compare(F, Steps, _)) =
    [F | list.map((func(S) = S ^ cs_right), Steps)].
ast_children(ex_is(E, _, _, _)) = [E].
ast_children(ex_slot(E, _, _)) = [E].
ast_children(ex_index(E, I, _)) = [E, I].
ast_children(ex_call(C, Args, _)) = [C | Args].
ast_children(ex_cast(E, _, _, _)) = [E].
ast_children(ex_match(E, _, _, _, _)) = [E].

    %@helper
:- func rule_type_env(resolved_file, rule_scope) = type_env.

rule_type_env(RF, Scope) = type_env(RF, Scope, da_reported, set.init).

    %@helper
:- pred try_rule(resolved_file::in, list(schema)::in, ast_rule::in,
                 rule_scope::in, build::in, intern_table::in,
                 lowered({build, intern_table})::out) is det.

try_rule(RF, Schemas, Rule, Scope, B0, IT0, Result) :-
    Env = rule_type_env(RF, Scope),
    Name = Rule ^ ar_name ^ id_name,
    Rhs = Rule ^ ar_rhs,
    rlow_9_2_1_patterns(RF, Name, Schemas, IT0, Rule ^ ar_lhs, 0, 0, PatsRes),
    (
        PatsRes = skipped(Why),
        Result = skipped(Why)
    ;
        PatsRes = done(Pats0),
        rate_windows(RF, Rule ^ ar_modifiers, no, RateRes),
        (
            RateRes = skipped(Why),
            Result = skipped(Why)
        ;
            RateRes = done(Cool),
            NowWhere = now_reeval_plan(Env, Pats0, Rhs ^ arr_actions),
            WithinTick = within_reeval_index(Pats0, NowWhere,
                Rhs ^ arr_actions),
            Pats = shift_for_tick(WithinTick, Pats0),
            (
                NowWhere = yes(Plan),
                ChainPats = drop_reeval(Plan, Pats)
            ;
                NowWhere = no,
                ChainPats = Pats
            ),
            rlow_5_1_chain(RF, yes(Env), ChainPats, WithinTick, ChainPats,
                0, 0u32, B0, B1, IT0, IT1, ChainRes),
            (
                ChainRes = skipped(Why),
                Result = skipped(Why)
            ;
                ChainRes = done(LastBeta),
                Lets = list.condense(list.map(let_bindings, Rhs ^ arr_lets)),
                % The captures open the RHS scope: a `let` and an action
                % may read any of them ([LREG.4.1]).
                rlow_4_5_1_lets(RF, yes(Env), Pats, Lets, bound_count(Lets), 0,
                    all_captures(Pats), [], LetRes, IT1, IT1a),
                ( if LetRes = done({Defs, Binds}) then
                    % [LCCO.3.4]: one `fn_gensym` per call with no `as`
                    % ([LCRS.3.1]), straight after the `let` binds and ahead of
                    % the `after` clauses'.
                    call_corr_binds(
                        lcrs_3_1_generated_calls(Rhs ^ arr_actions),
                        list.length(Binds), CorrBinds, CorrDefs, CorrIxs,
                        BindCount),
                    Frame = corr_frame(CorrIxs),
                    LetDefs = Defs ++ CorrDefs,
                    Ctx = ctx(RF, Pats, no, LetDefs, yes(Env)),
                    Outer = lcco_3_2_outer_actions(Name, Frame,
                        Rhs ^ arr_actions),
                    lower_actions(Ctx, Schemas, Outer, IT1a, IT1b, [],
                        ActsRes0),
                    (
                        ActsRes0 = done(Authored0),
                        rlow_4_6_6_1_call_gates(RF, Name, Pats, Outer,
                            Authored0, GateRes, IT1b, IT2),
                        (
                            GateRes = done(Authored),
                            ActsRes = done(Binds ++ CorrBinds ++ Authored)
                        ;
                            GateRes = skipped(GateWhy),
                            ActsRes = skipped(GateWhy)
                        )
                    ;
                        ActsRes0 = skipped(ActWhy),
                        ActsRes = skipped(ActWhy),
                        IT2 = IT1b
                    )
                else if LetRes = skipped(LetWhy) then
                    LetDefs = [],
                    Frame = no_corr_frame,
                    ActsRes = skipped(LetWhy),
                    IT2 = IT1a,
                    BindCount = 0
                else
                    unexpected($pred, "a lowered result is done or skipped")
                ),
                (
                    ActsRes = skipped(Why),
                    Result = skipped(Why)
                ;
                    ActsRes = done(RuleActions),
                    OuterCtx = ctx(RF, Pats, no, LetDefs, yes(Env)),
                    lcco_5_2_capture_emits(OuterCtx, Schemas, Name, Frame,
                        Rhs ^ arr_actions, CaptureRes, IT2, IT2c),
                    lcco_7_2_timer_emits(OuterCtx, Name, Frame,
                        Rhs ^ arr_actions, TimerRes, IT2c, IT2t),
                    ( if
                        CaptureRes = done(CaptureEmits),
                        TimerRes = done(TimerEmits)
                    then
                        TimeoutEmits = CaptureEmits ++ TimerEmits,
                        EmitSkip = no
                    else if CaptureRes = skipped(CaptureWhy) then
                        TimeoutEmits = [],
                        EmitSkip = yes(CaptureWhy)
                    else if TimerRes = skipped(TimerWhy) then
                        TimeoutEmits = [],
                        EmitSkip = yes(TimerWhy)
                    else
                        unexpected($pred, "both emits lowered")
                    ),
                    ltac_3_1_afters(RF, Env, Schemas, Name, Pats, LetDefs,
                        BindCount, Rhs ^ arr_afters, 0, [], AfterRes,
                        B1, B1a, IT2t, IT2a),
                    (
                        AfterRes = skipped(Why),
                        Result = skipped(Why)
                    ;
                        AfterRes = done({TimerAsserts, TotalBinds}),
                        now_reeval_tail(RF, yes(Env), Pats, NowWhere,
                            LastBeta,
                            TailRes, B1a, B1b, IT2a, IT2b),
                        (
                            TailRes = skipped(Why),
                            Result = skipped(Why)
                        ;
                            TailRes = done({Parent, NowGuard}),
                            Actions = RuleActions ++ TimeoutEmits
                                ++ TimerAsserts,
                            intern(Name, RuleRef, IT2b, IT),
                            Gate = rlow_4_6_1_rate_guard(Name, Pats,
                                rate_key(Rule ^ ar_modifiers), Cool, IT),
                            Guard = rdsc_4a_8_2_1_fire_guard(NowGuard, Gate),
                            TermId = B1b ^ bd_next,
                            Term = raw_terminal(det_node_id(TermId),
                                Parent, RuleRef, TotalBinds, Guard,
                                list.length(Actions), Actions),
                            Group = rule_group(Name, Cool,
                                Rule ^ ar_pos,
                                rdsc_6_8_4_display(Name, Pats, IT)),
                            % [RLOW.14.7]: the rule's own terminal, then what
                            % it induced. The `after` follow-ups were lowered
                            % first, so their terminals and groups go back in
                            % behind this rule's; node ids stay as allocated.
                            FollowTerms = pushed_since(B1 ^ bd_terms,
                                B1b ^ bd_terms),
                            FollowGroups = pushed_since(B1 ^ bd_groups,
                                B1b ^ bd_groups),
                            BParent = (((B1b ^ bd_next := TermId + 1u32)
                                ^ bd_terms := FollowTerms
                                    ++ [Term | B1 ^ bd_terms])
                                ^ bd_groups := FollowGroups
                                    ++ [Group | B1 ^ bd_groups])
                                ^ bd_spans := rdsc_14_3_6_span(TermId,
                                    yes(Rule ^ ar_pos), B1b ^ bd_spans),
                            lcco_3_1_siblings(RF, Env, Schemas, Name, Pats,
                                Frame, Rhs ^ arr_actions, SibRes,
                                BParent, B, IT, ITs),
                            (
                                SibRes = done(unit),
                                (
                                    EmitSkip = no,
                                    Result = done({B, ITs})
                                ;
                                    EmitSkip = yes(EmitWhy),
                                    Result = skipped(EmitWhy)
                                )
                            ;
                                SibRes = skipped(SibWhy),
                                Result = skipped(SibWhy)
                            )
                        )
                    )
                )
            )
        )
    ).

%-----------------------------------------------------------------------------%
% Clock-driven re-evaluation -- [LTIM.2.4]
%-----------------------------------------------------------------------------%

    % What the engine clock re-drives on a rule's only positive pattern: its
    % index, the time-dependent `where` ([LTIM.2.4.1]), and its `within` window
    % if no `logical` emit hangs on it. Each moves off the pattern's beta into
    % the terminal's fire guard, behind a `$ClockTick` beta.
:- type reeval_plan
    --->    reeval_plan(
                rp_index  :: int,
                rp_where  :: maybe(lgra_9_3_1_expr),
                rp_within :: maybe(uint64)
            ).

    % The plan for a rule with one positive pattern, if anything on that
    % pattern reads the clock. A second positive pattern is refused before
    % lowering ([LTIM.2.6.2]). A rate modifier changes nothing here
    % ([LTIM.2.4.2]). A window that justifies a `logical` emit stays on the beta
    % (`within_reeval_index`).
    %
    %@helper
:- func now_reeval_plan(type_env, list(pat), list(ast_action))
    = maybe(reeval_plan).

now_reeval_plan(Env, Pats, Actions) = Found :-
    ( if
        list.filter((pred(P::in) is semidet :- P ^ pt_negated = no), Pats,
            [Only]),
        MovedWhere = ( if Only ^ pt_where = yes(W),
                          ltim_2_4_1_time_dependent(Env, W)
                       then yes(W) else no ),
        MovedWithin = ( if Only ^ pt_within = yes(Ns),
                           not emits_logical(Actions)
                        then yes(Ns) else no ),
        ( MovedWhere = yes(_) ; MovedWithin = yes(_) ),
        pat_index(Pats, Only, 0, Ix)
    then
        Found = yes(reeval_plan(Ix, MovedWhere, MovedWithin))
    else
        Found = no
    ).

    %@helper
:- pred pat_index(list(pat)::in, pat::in, int::in, int::out) is semidet.

pat_index([P | Ps], Wanted, N, Ix) :-
    ( if P = Wanted then
        Ix = N
    else
        pat_index(Ps, Wanted, N + 1, Ix)
    ).

    % The patterns the beta chain is built from: what the plan moves leaves its
    % pattern's beta.
    %
    %@helper
:- func drop_reeval(reeval_plan, list(pat)) = list(pat).

drop_reeval(Plan, Pats) = drop_reeval_at(Plan, Plan ^ rp_index, Pats).

    %@helper
:- func drop_reeval_at(reeval_plan, int, list(pat)) = list(pat).

drop_reeval_at(_, _, []) = [].
drop_reeval_at(Plan, Ix, [P | Ps]) = [Q | drop_reeval_at(Plan, Ix - 1, Ps)] :-
    ( if Ix = 0 then
        Q1 = ( if Plan ^ rp_where = yes(_) then P ^ pt_where := no else P ),
        Q = ( if Plan ^ rp_within = yes(_) then Q1 ^ pt_within := no
              else Q1 )
    else
        Q = P
    ).

    % A `$ClockTick` beta at the tail of the chain, after the `after`
    % follow-ups' nodes, and what the plan moved as the terminal's fire guard,
    % lowered against the token rather than a beta's right side: the window
    % first, then the `where`. The matched fact keeps its token position; the
    % tick joins after it.
    %
    %@helper
:- pred now_reeval_tail(resolved_file::in, maybe(type_env)::in, list(pat)::in,
                        maybe(reeval_plan)::in, uint32::in,
                        lowered({uint32, maybe(expr)})::out,
                        build::in, build::out,
                        intern_table::in, intern_table::out) is det.

now_reeval_tail(_, _, _, no, Last, done({Last, no}), !B, !IT).
now_reeval_tail(RF, Env, Pats, yes(Plan), Last, Result, !B, !IT) :-
    intern(clock_tick_name, TickRef, !IT),
    alpha_for(make_schema_name(TickRef), [], TickAlpha, !B),
    TickId = !.B ^ bd_next,
    !:B = (!.B ^ bd_next := TickId + 1u32)
        ^ bd_betas := [raw_beta(det_node_id(TickId), TickAlpha, Last, [], no)
            | !.B ^ bd_betas],
    ( if
        Plan ^ rp_within = yes(Ns),
        list.index0(Pats, Plan ^ rp_index, P)
    then
        Window = [ltim_2_7_1_window(token_fact(P ^ pt_token), Ns)]
    else
        Window = []
    ),
    MovedWhere = Plan ^ rp_where,
    (
        MovedWhere = yes(W),
        rlow_6_1_1_expr(ctx(RF, Pats, no, all_captures(Pats), Env), W,
            WhereRes0, !IT),
        (
            WhereRes0 = done(WhereExpr),
            WhereRes = done([WhereExpr])
        ;
            WhereRes0 = skipped(Why0),
            WhereRes = skipped(Why0)
        )
    ;
        MovedWhere = no,
        WhereRes = done([])
    ),
    (
        WhereRes = done(Where),
        Conjuncts = Window ++ Where,
        (
            Conjuncts = [],
            % Unreachable: a plan moves a `where` or a window.
            Result = done({TickId, no})
        ;
            Conjuncts = [First | Rest],
            Guard = list.foldl(
                ( func(C, Acc) = e_binop(op_and, Acc, C) ), Rest, First),
            Result = done({TickId, yes(Guard)})
        )
    ;
        WhereRes = skipped(Why),
        Result = skipped(Why)
    ).

    % The pattern a `within` re-driver goes in front of: the rule's only
    % positive pattern, carrying a `within` window, on a rule with no
    % clock-reading `where`, whose RHS emits or publishes a `logical` fact
    % the window justifies ([LTIM.2.7.1]). The window stays a join test on the
    % pattern's beta, so a token that ages out of it retracts ([LTIM.2.7.2]).
    %
    %@helper
:- func within_reeval_index(list(pat), maybe(reeval_plan), list(ast_action))
    = maybe(int).

within_reeval_index(Pats, NowWhere, Actions) = Found :-
    ( if
        NowWhere = no,
        list.filter((pred(P::in) is semidet :- P ^ pt_negated = no), Pats,
            [Only]),
        Only ^ pt_within = yes(_),
        emits_logical(Actions),
        pat_index(Pats, Only, 0, Ix)
    then
        Found = yes(Ix)
    else
        Found = no
    ).

    % The head-inserted tick takes a token position of its own, so the
    % re-driven pattern and every positive pattern after it move up one.
    %
    %@helper
:- func shift_for_tick(maybe(int), list(pat)) = list(pat).

shift_for_tick(no, Pats) = Pats.
shift_for_tick(yes(Ix), Pats) = shift_from(Ix, Pats).

    %@helper
:- func shift_from(int, list(pat)) = list(pat).

shift_from(_, []) = [].
shift_from(Ix, [P | Ps]) = [Q | shift_from(Ix - 1, Ps)] :-
    ( if Ix =< 0, P ^ pt_negated = no then
        Q = P ^ pt_token := P ^ pt_token + 1
    else
        Q = P
    ).

    % The `$ClockTick` beta in front of a re-driven pattern's beta, for the
    % positive pattern `within_reeval_index` names, and for a negated pattern
    % carrying `within` with no positive pattern after it: a NOT beta re-tests
    % only when a fact arrives or leaves, so a blocker ageing out of the window
    % needs a fresh left token each pump.
    %
    %@helper
:- pred within_tick(maybe(int)::in, int::in, pat::in, list(pat)::in,
                    uint32::in, uint32::out,
                    build::in, build::out,
                    intern_table::in, intern_table::out) is det.

within_tick(TickBefore, K, P, Rest, Prev0, Prev, !B, !IT) :-
    ( if
        ( TickBefore = yes(K)
        ; P ^ pt_negated = yes,
          P ^ pt_within = yes(_),
          not list.find_first_match((pred(Q::in) is semidet :-
              Q ^ pt_negated = no), Rest, _)
        )
    then
        intern(clock_tick_name, TickRef, !IT),
        alpha_for(make_schema_name(TickRef), [], TickAlpha, !B),
        Prev = !.B ^ bd_next,
        !:B = (!.B ^ bd_next := Prev + 1u32)
            ^ bd_betas := [raw_beta(det_node_id(Prev), TickAlpha, Prev0, [], no)
                | !.B ^ bd_betas]
    else
        Prev = Prev0
    ).

    % The AST twin of `within_reeval_index`, for declaring `$ClockTick`.
    %
    %@helper
:- pred ast_within_reeval(type_env::in, ast_rule::in) is semidet.

ast_within_reeval(Env, Rule) :-
    not ast_now_reeval(Env, Rule),
    not list.find_first_match((pred(C::in) is semidet :-
        C = alc_pattern(ap_sequence(_, _, _, _))), Rule ^ ar_lhs, _),
    list.filter_map(positive_body, Rule ^ ar_lhs) = [Only],
    Only ^ apb_within = yes(_),
    emits_logical(Rule ^ ar_rhs ^ arr_actions).

    % The AST twin of `now_reeval_plan`, for declaring `$ClockTick` before any
    % rule is lowered. The twins must agree, or a rule is re-driven by a
    % `$ClockTick` nothing declared.
    %
    %@helper
:- pred ast_now_reeval(type_env::in, ast_rule::in) is semidet.

ast_now_reeval(Env, Rule) :-
    not list.find_first_match((pred(C::in) is semidet :-
        C = alc_pattern(ap_sequence(_, _, _, _))), Rule ^ ar_lhs, _),
    list.filter_map(positive_body, Rule ^ ar_lhs) = [Only],
    (
        Only ^ apb_where = yes(W),
        ltim_2_4_1_time_dependent(Env, W)
    ;
        Only ^ apb_within = yes(_),
        not emits_logical(Rule ^ ar_rhs ^ arr_actions)
    ).

%-----------------------------------------------------------------------------%
% `after` -- [LTAC.3]
%-----------------------------------------------------------------------------%

    %@helper
:- pred after_ns(ast_after_clause::in, int64::out) is semidet.

after_ns(A, Ns) :-
    Ns = duration_ns_of(A ^ aaf_duration),
    Ns > 0i64.

    % Each top-level `after <dur>:` as [LTAC.3.1] rewrites it: a timer emit for
    % the parent's RHS ([LTAC.3.3]) and a follow-up rule `$<rule>_after_<key>`
    % ([LTAC.3.4]).
    %
    % The follow-up: a root beta on the timer, a `$ClockTick` beta under it,
    % `now() >= fire_at` as the fire guard, and a retract of the timer (token
    % fact 0) after the body. Its nodes are allocated before the parent's
    % terminal.
    %
    % A body reading a parent binding is captured ([LTAC.3.5]): the timer and a
    % `$CaptureBindings_<rule>_after_<key>` fact carry one correlation. The
    % follow-up adds a third beta joining that fact on `corr` (token position
    % 2), reads each captured slot through a view named for the parent binding,
    % and retracts it after the timer.
    %
    % The bind indices continue after the parent's own `let` binds; the count
    % after the last clause is the parent terminal's `bind_count`.
    %
    % A nested `after` ([LTAC.6.2.2]) emits its timer in the enclosing
    % follow-up's RHS, after the body and before the timer retract. Children are
    % lowered first. A tree shares the top-level clause's one capture fact: a
    % nested timer forwards the correlation off its parent's timer (token fact
    % 0, slot 1), and only a clause with nothing nested under it retracts the
    % capture.
    %
    % `as <key>` ([LTAC.2.2.1], [LRST.2.1]) makes the key the timer's `corr`,
    % with a sweep of the clause's own timer schema on that key ahead of the
    % emit. The key is evaluated where the emit runs.
    %
    %@spec [LTAC.6.2.1]
    %@spec [LTAC.3.1]
    %@spec [LTAC.3.3]
    %@spec [LTAC.3.4]
    %@spec [LTAC.3.5]
    %@spec [LTAC.3.6]
    %@spec [LTAC.6.2.2]
    %@spec [LRST.2.1]
    %@spec [LRST.2.2]
:- pred ltac_3_1_afters(resolved_file::in, type_env::in, list(schema)::in,
                        string::in, list(pat)::in, list(let_def)::in, int::in,
                        list(ast_after_clause)::in, int::in,
                        list(list(inline_action))::in,
                        lowered({list(inline_action), int})::out,
                        build::in, build::out,
                        intern_table::in, intern_table::out) is det.

ltac_3_1_afters(_, _, _, _, _, _, BindNext, [], _, Asserts,
        done({list.condense(list.reverse(Asserts)), BindNext}), !B, !IT).
ltac_3_1_afters(RF, Env, Schemas, Rule, Pats, Defs, BindNext, [A | As], Key,
        Asserts, Result, !B, !IT) :-
    KeyText = string.from_int(Key),
    Parents = list.filter_map(positive_binding, Pats),
    CapRes = body_captures(Parents, tree_actions(A)),
    (
        CapRes = skipped(CapWhy),
        Result = skipped(CapWhy)
    ;
        CapRes = done(Caps),
        (
            % The capture fact and the timer carry one value: `capture_join`
            % joins on it.
            lrst_4_5_top_after_corr(RF, Env, Pats, Defs, BindNext, A, Caps,
                CorrRes, !IT),
            (
                CorrRes = skipped(CorrWhy),
                Result = skipped(CorrWhy)
            ;
                CorrRes = done({TopCorrE, Lead, NextBind}),
            ( if Caps = [] then
                CaptureRes = done(no)
            else
                capture_parts(RF, Pats, capture_schema_name(Rule, KeyText), 2,
                    Caps, TopCorrE,
                    PartsRes, !IT),
                (
                    PartsRes = done(yes({Assert, CaptureRef, ViewPats})),
                    CaptureRes = done(yes({TopCorrE, Assert, CaptureRef,
                        ViewPats}))
                ;
                    PartsRes = done(no),
                    CaptureRes = done(no)
                ;
                    PartsRes = skipped(PartsWhy),
                    CaptureRes = skipped(PartsWhy)
                )
            ),
            (
                CaptureRes = skipped(CaptureWhy),
                Result = skipped(CaptureWhy)
            ;
                CaptureRes = done(Capture),
                after_clause(RF, Env, Schemas, Rule, site_top(Pats, Defs),
                    Capture, KeyText, A, ClauseRes, !B, !IT),
                (
                    ClauseRes = skipped(ClauseWhy),
                    Result = skipped(ClauseWhy)
                ;
                    ClauseRes = done(ClauseActions),
                    ltac_3_1_afters(RF, Env, Schemas, Rule, Pats, Defs, NextBind,
                        As, Key + 1, [Lead ++ ClauseActions | Asserts],
                        Result, !B, !IT)
                )
                )
            )
        )
    ).

    % The correlation a TOP-LEVEL `after` clause carries, the actions that
    % have to run before its emit, and the next free bind index: the `as` key's
    % value ([LTAC.3.5]), else this activation's `fn_gensym` if the body
    % captures, else the empty string.
    %
    % A key whose static type `lrst_1_4_key_kind` cannot name skips the tree: its
    % `corr` slot would have no declared type.
    %
    %@spec [LTAC.3.5]
    %@spec [LRST.4.5]
:- pred lrst_4_5_top_after_corr(resolved_file::in, type_env::in, list(pat)::in,
                       list(let_def)::in, int::in, ast_after_clause::in,
                       list(capture)::in,
                       lowered({expr, list(inline_action), int})::out,
                       intern_table::in, intern_table::out) is det.

lrst_4_5_top_after_corr(RF, Env, Pats, Defs, BindNext, A, Caps, Result, !IT) :-
    ( if A ^ aaf_as = yes(Key) then
        ( if lrst_1_4_key_kind(Env, Key, _) then
            rlow_6_1_1_expr(ctx(RF, Pats, no, Defs, yes(Env)), Key, KeyRes,
                !IT),
            (
                KeyRes = done(KeyE),
                Result = done({KeyE, [], BindNext})
            ;
                KeyRes = skipped(KeyWhy),
                Result = skipped(KeyWhy)
            )
        else
            Result = skipped(lrst_1_4_untyped_key)
        )
    else if Caps = [_ | _] then
        ( if bind_index(BindNext + 1, BindNext, Ix) then
            Result = done({e_bind_ref(Ix), [ia_bind(Ix, e_call(fn_gensym, []))],
                BindNext + 1})
        else
            unexpected($pred, "a capture's bind index is in range")
        )
    else
        intern("", EmptyRef, !IT),
        Result = done({e_lit(str(EmptyRef)), [], BindNext})
    ).

    % Where a clause's timer emit runs: in the parent rule's RHS, with its
    % bindings and `let`s, or in an enclosing follow-up's, with neither.
    %
    %@helper
:- type clause_site
    --->    site_top(list(pat), list(let_def))
    ;       site_nested.

    % A tree's shared capture: the top-level clause's correlation, its capture
    % emit, the capture schema, and the view patterns the bodies read through.
    %
    %@helper
:- type after_capture == maybe({expr, inline_action, intern_ref, list(pat)}).

    % One clause, after every clause nested in it: the actions its emit site
    % gains -- the supersede sweep, the timer emit and, at the top level, the
    % capture emit.
    %
    %@helper
:- pred after_clause(resolved_file::in, type_env::in, list(schema)::in,
                     string::in, clause_site::in, after_capture::in, string::in,
                     ast_after_clause::in,
                     lowered(list(inline_action))::out,
                     build::in, build::out,
                     intern_table::in, intern_table::out) is det.

after_clause(RF, Env, Schemas, Rule, Site, Capture, KeyText, A, Result, !B,
        !IT) :-
    ( if after_ns(A, Ns) then
        intern(timer_schema_name(Rule, KeyText), TimerRef, !IT),
        clause_corr(RF, Env, Site, Capture, TimerRef, A, CorrRes, !IT),
        (
            CorrRes = skipped(CorrWhy),
            Result = skipped(CorrWhy)
        ;
            CorrRes = done({CorrE, Supersede}),
            B0 = !.B,
            nested_clauses(RF, Env, Schemas, Rule, Capture, KeyText,
                A ^ aaf_nested, 0, [], ChildRes, !B, !IT),
            (
                ChildRes = skipped(ChildWhy),
                Result = skipped(ChildWhy)
            ;
                ChildRes = done(ChildActions),
                % [RLOW.14.7]: the follow-up's own terminal, then what its
                % nested clauses induced, then its body's call siblings. The
                % nested clauses were lowered first, so their terminals and
                % groups come off the build here and go back in behind this
                % follow-up's; node ids stay as allocated.
                Nested = nested_items(
                    pushed_since(B0 ^ bd_terms, !.B ^ bd_terms),
                    pushed_since(B0 ^ bd_groups, !.B ^ bd_groups)),
                !:B = (!.B ^ bd_terms := B0 ^ bd_terms)
                    ^ bd_groups := B0 ^ bd_groups,
                follow_up(RF, Env, Schemas, Rule, Capture, KeyText, TimerRef,
                    A, ChildActions, Nested, FollowRes, !B, !IT),
                (
                    FollowRes = skipped(FollowWhy),
                    Result = skipped(FollowWhy)
                ;
                    FollowRes = done(unit),
                    % [LTAC.3.3]: `fire_at: monotonic_ns() + <dur>`.
                    TimerEmit = ia_assert(plain, TimerRef, [
                        slot_assign(det_slot(0),
                            e_binop(op_add, ltim_2_2_1_monotonic_ns,
                                e_lit(int(Ns)))),
                        slot_assign(det_slot(1), CorrE)], no),
                    ( if
                        Site = site_top(_, _),
                        Capture = yes({_, CaptureAssert, _, _})
                    then
                        Tail = [CaptureAssert]
                    else
                        Tail = []
                    ),
                    Result = done(Supersede ++ [TimerEmit] ++ Tail)
                )
            )
        )
    else
        Result = skipped("an `after` whose duration is not a single time "
            ++ "literal")
    ).

    % A clause's `corr`, and the sweep that goes ahead of its emit. Under a
    % capture the top level carries the gensym and a nested clause forwards
    % its parent timer's; otherwise an `as` key, or `""`.
    %
    %@helper
:- pred clause_corr(resolved_file::in, type_env::in, clause_site::in,
                    after_capture::in, intern_ref::in, ast_after_clause::in,
                    lowered({expr, list(inline_action)})::out,
                    intern_table::in, intern_table::out) is det.

clause_corr(RF, Env, Site, Capture, TimerRef, A, Result, !IT) :-
    ( if Capture = yes({TopCorr, _, CaptureRef, _}) then
        (
            Site = site_top(_, _),
            % `TopCorr` is the `as` key where the clause has one.
            ( if A ^ aaf_as = yes(_) then
                intern("corr", CorrSlotRef, !IT),
                % [LRST.4.5]: both facts. A surviving snapshot would join the
                % surviving follow-up and run the body twice.
                Result = done({TopCorr, [
                    ia_internal(fn_retract_corr,
                        [e_lit(str(TimerRef)), e_lit(str(CorrSlotRef)),
                         TopCorr]),
                    ia_internal(fn_retract_corr,
                        [e_lit(str(CaptureRef)), e_lit(str(CorrSlotRef)),
                         TopCorr])]})
            else
                Result = done({TopCorr, []})
            )
        ;
            Site = site_nested,
            Result = done({e_slot(token_fact(0), slot(det_slot(1))), []})
        )
    else if A ^ aaf_as = yes(Key) then
        (
            Site = site_top(EvalPats, EvalDefs),
            KeyEnv = yes(Env)
        ;
            Site = site_nested,
            EvalPats = [],
            EvalDefs = [],
            % A capture view's scope, which the rule's environment does not
            % type.
            KeyEnv = no
        ),
        ( if lrst_1_4_key_kind(Env, Key, _) then
            rlow_6_1_1_expr(ctx(RF, EvalPats, no, EvalDefs, KeyEnv), Key,
                KeyRes, !IT),
            (
                KeyRes = done(KeyE),
                intern("corr", CorrSlotRef, !IT),
                Result = done({KeyE, [ia_internal(fn_retract_corr,
                    [e_lit(str(TimerRef)), e_lit(str(CorrSlotRef)), KeyE])]})
            ;
                KeyRes = skipped(KeyWhy),
                Result = skipped(KeyWhy)
            )
        else
            Result = skipped(lrst_1_4_untyped_key)
        )
    else
        intern("", EmptyRef, !IT),
        Result = done({e_lit(str(EmptyRef)), []})
    ).

    % The slot kind an `as` key is stored under: its static type. Fails for a
    % key the rule's environment cannot type: a nested clause's key, which reads
    % a capture view's bindings.
    %
    %@spec [LRST.1.4]
:- pred lrst_1_4_key_kind(type_env::in, lgra_9_3_1_expr::in, slot_kind::out)
    is semidet.

lrst_1_4_key_kind(Env, Key, Kind) :-
    type_of_expr(Env, Key) = ty_known(Type),
    lrst_1_4_leaf_kind(Type ^ dt_leaf, Kind).

    %@spec [LRST.1.4]
:- pred lrst_1_4_leaf_kind(leaf_kind::in, slot_kind::out) is semidet.

lrst_1_4_leaf_kind(lk_string, k_string).
lrst_1_4_leaf_kind(lk_int, k_int).
lrst_1_4_leaf_kind(lk_float, k_float).
lrst_1_4_leaf_kind(lk_bool, k_bool).
lrst_1_4_leaf_kind(lk_date, k_date).
lrst_1_4_leaf_kind(lk_time, k_time).
lrst_1_4_leaf_kind(lk_duration, k_duration).
lrst_1_4_leaf_kind(lk_bytes, k_bytes).

    %@helper
:- func lrst_1_4_untyped_key = string.

lrst_1_4_untyped_key =
    "an `after` `as` key whose type this compiler cannot see ([LRST.1.4]; "
        ++ "a nested clause's key over a capture view), so its "
        ++ "timer's `corr` slot has no type to declare".

    % The kind of the `corr` slot a top-level clause's timer, its capture fact
    % and every nested timer that forwards it declare: the `as` key's kind, else
    % `String`.
    %
    %@helper
:- func top_corr_kind(type_env, ast_after_clause) = slot_kind.

top_corr_kind(Env, A) = Kind :-
    ( if
        A ^ aaf_as = yes(Key),
        lrst_1_4_key_kind(Env, Key, KeyKind)
    then
        Kind = KeyKind
    else
        Kind = k_string
    ).

    %@helper
:- pred nested_clauses(resolved_file::in, type_env::in, list(schema)::in,
                       string::in,
                       after_capture::in, string::in,
                       list(ast_after_clause)::in, int::in,
                       list(list(inline_action))::in,
                       lowered(list(inline_action))::out,
                       build::in, build::out,
                       intern_table::in, intern_table::out) is det.

nested_clauses(_, _, _, _, _, _, [], _, RevActs,
        done(list.condense(list.reverse(RevActs))), !B, !IT).
nested_clauses(RF, Env, Schemas, Rule, Capture, Parent, [A | As], Index,
        RevActs, Result, !B, !IT) :-
    Key = Parent ++ "_" ++ string.from_int(Index),
    after_clause(RF, Env, Schemas, Rule, site_nested, Capture, Key, A,
        ClauseRes, !B, !IT),
    (
        ClauseRes = skipped(Why),
        Result = skipped(Why)
    ;
        ClauseRes = done(Acts),
        nested_clauses(RF, Env, Schemas, Rule, Capture, Parent, As, Index + 1,
            [Acts | RevActs], Result, !B, !IT)
    ).

    % The terminals and rule groups a clause's nested clauses pushed, newest
    % first, held off the build until the clause's own follow-up is in.
    %
    %@helper
:- type nested_items
    --->    nested_items(
                ni_terms  :: list(raw_terminal),
                ni_groups :: list(rule_group)
            ).

    % A clause's follow-up rule `$<rule>_after_<key>`: the timer and tick
    % betas, the capture beta when the tree captures, and a terminal running
    % the body, the nested clauses' emits, and the retracts. Its terminal and
    % rule group are pushed together, then what its nested clauses induced
    % (`Nested`), then its body's continuation siblings ([RLOW.14.7]).
    %
    % Only a clause with nothing nested under it retracts the capture: every
    % level joins the same capture fact.
    %
    % The body is lowered in the rule's typing environment: the capture's views
    % keep the bindings' names.
    %
    %@helper
:- pred follow_up(resolved_file::in, type_env::in, list(schema)::in,
                  string::in, after_capture::in, string::in, intern_ref::in,
                  ast_after_clause::in, list(inline_action)::in,
                  nested_items::in, lowered(unit)::out,
                  build::in, build::out,
                  intern_table::in, intern_table::out) is det.

follow_up(RF, Env, Schemas, Rule, Capture, KeyText, TimerRef, A, ChildActions,
        Nested, Result, !B, !IT) :-
    intern(clock_tick_name, TickRef, !IT),
    alpha_for(make_schema_name(TimerRef), [], TimerAlpha, !B),
    alpha_for(make_schema_name(TickRef), [], TickAlpha, !B),
    Root = !.B ^ bd_next,
    Tick = Root + 1u32,
    !:B = (!.B ^ bd_next := Tick + 1u32)
        ^ bd_betas := [
            raw_beta(det_node_id(Tick), TickAlpha, Root, [], no),
            raw_beta(det_node_id(Root), TimerAlpha, 0u32, [], no)
            | !.B ^ bd_betas],
    (
        Capture = no,
        Parent = Tick,
        BodyPats = [],
        CaptureTail = []
    ;
        Capture = yes({_, _, CaptureRef, ViewPats}),
        alpha_for(make_schema_name(CaptureRef), [], CaptureAlpha, !B),
        CaptureBeta = !.B ^ bd_next,
        CorrJoin = e_binop(op_eq,
            e_slot(candidate, slot(det_slot(0))),
            e_slot(token_fact(0), slot(det_slot(1)))),
        !:B = (!.B ^ bd_next := CaptureBeta + 1u32)
            ^ bd_betas := [raw_beta(det_node_id(CaptureBeta),
                CaptureAlpha, Tick, [CorrJoin], no)
                | !.B ^ bd_betas],
        Parent = CaptureBeta,
        BodyPats = ViewPats,
        ( if A ^ aaf_nested = [] then
            CaptureTail = [ia_internal(fn_retract_token_fact,
                [e_lit(int(2i64))])]
        else
            CaptureTail = []
        )
    ),
    % [LTAC.6.1.3]: the body is stripped and its continuations become siblings,
    % as `one_pattern_sibling` does for an `on` body.
    FollowName = "$" ++ Rule ++ "_after_" ++ KeyText,   % [LTAC.8.1]
    % One `fn_gensym` per plain `call` with no `as` or a computed one
    % ([LCRS.3.1]), from index 0: nothing else in the terminal binds.
    call_corr_binds(lcrs_3_1_generated_calls(A ^ aaf_actions),
        0, CorrBinds, CorrDefs, CorrIxs, BindCount),
    BodyCtx = ctx(RF, BodyPats, no, CorrDefs, yes(Env)),
    lower_actions(BodyCtx, Schemas,
        lcco_3_2_outer_actions(FollowName, corr_frame(CorrIxs),
            A ^ aaf_actions),
        !IT, [],
        BodyRes0),
    (
        BodyRes0 = done(Body0),
        lcco_10_3_inner_emits(BodyCtx, Schemas, FollowName, A ^ aaf_actions,
            InnerRes, !B, !IT),
        (
            InnerRes = done(InnerEmits),
            BodyRes = done(Body0 ++ InnerEmits)
        ;
            InnerRes = skipped(InnerWhy),
            BodyRes = skipped(InnerWhy)
        )
    ;
        BodyRes0 = skipped(Why0),
        BodyRes = skipped(Why0)
    ),
    (
        BodyRes = done(Body),
        intern(FollowName, FollowRef, !IT),
        Actions = CorrBinds ++ Body ++ ChildActions
            ++ [ia_internal(fn_retract_token_fact, [e_lit(int(0i64))])]
            ++ CaptureTail,
        TermId = !.B ^ bd_next,
        % [LTAC.3.4], [LTAC.5.3]: `monotonic_ns() >= t.fire_at`.
        Term = raw_terminal(det_node_id(TermId), Parent, FollowRef, BindCount,
            yes(e_binop(op_ge, ltim_2_2_1_monotonic_ns,
                e_slot(token_fact(0), slot(det_slot(0))))),
            list.length(Actions), Actions),
        % The group is pushed with the terminal: libds takes a terminal's ordinal
        % from the TerminalNode sequence and the Mercury loader from the
        % `rule_group` sequence ([LDET.5.4]), so the two lists are in one order.
        !:B = ((!.B ^ bd_next := TermId + 1u32)
            ^ bd_terms := Nested ^ ni_terms ++ [Term | !.B ^ bd_terms])
            ^ bd_groups := Nested ^ ni_groups
                ++ [rule_group(FollowName, no, A ^ aaf_pos, "")
                    | !.B ^ bd_groups],
        siblings_of_calls(RF, Env, Schemas, FollowName, BodyPats,
            no_corr_frame, continued_calls(FollowName, A ^ aaf_actions),
            SibRes, !B, !IT),
        (
            SibRes = done(unit),
            Result = done(unit)
        ;
            SibRes = skipped(SibWhy),
            Result = skipped(SibWhy)
        )
    ;
        BodyRes = skipped(Why),
        Result = skipped(Why)
    ).

    % A clause's actions and every nested clause's, in source order: what the
    % one capture fact of the tree must carry.
    %
    %@helper
:- func tree_actions(ast_after_clause) = list(ast_action).

tree_actions(A) =
    A ^ aaf_actions ++ list.condense(list.map(tree_actions, A ^ aaf_nested)).

    % The capture fact's assertion, its schema's ref, and one view of the
    % capture schema per captured parent binding: the parent binding's name, and
    % a schema holding that binding's captured slots under their parent names at
    % their capture indices. The follow-up body is lowered against the views.
    %
    %@helper
:- pred capture_parts(resolved_file::in, list(pat)::in, string::in, int::in,
                      list(capture)::in, expr::in,
                      lowered(maybe({inline_action, intern_ref, list(pat)}))::out,
                      intern_table::in, intern_table::out) is det.

capture_parts(RF, Pats, CaptureName, Position, Caps, CorrE, Result, !IT) :-
    intern(CaptureName, CaptureRef, !IT),
    capture_values(RF, Pats, Caps, 1, [], [], ValuesRes, !IT),
    (
        ValuesRes = done({Assigns, Views}),
        Assert = ia_assert(plain, CaptureRef,
            [slot_assign(det_slot(0), CorrE) | Assigns], no),
        Bindings = list.remove_dups(assoc_list.keys(Views)),
        ViewPats = list.map(view_pat(CaptureRef, Views, Position), Bindings),
        Result = done(yes({Assert, CaptureRef, ViewPats}))
    ;
        ValuesRes = skipped(Why),
        Result = skipped(Why)
    ).

    %@helper
:- pred capture_values(resolved_file::in, list(pat)::in, list(capture)::in,
                       int::in, list(slot_assign)::in,
                       assoc_list(string, plain_slot)::in,
                       lowered({list(slot_assign),
                                assoc_list(string, plain_slot)})::out,
                       intern_table::in, intern_table::out) is det.

capture_values(_, _, [], _, RevAssigns, RevViews,
        done({list.reverse(RevAssigns), list.reverse(RevViews)}), !IT).
capture_values(RF, Pats, [C | Cs], N, RevAssigns, RevViews, Result, !IT) :-
    ( if capture_value(RF, Pats, C, Value, Kind, Nullable, !IT) then
        % The view slot is named by the path it answers: the parent slot's name,
        % the whole `Json` path, or the empty name for the fact itself. No
        % author name can collide: an identifier holds neither `.` nor `[`, and
        % is never empty.
        intern(C ^ cap_slot, ViewRef, !IT),
        Assign = slot_assign(det_slot(N), Value),
        View = plain_slot(slot_common(ViewRef, Kind, det_slot(N), Nullable,
            no, no, no, unbounded)),
        capture_values(RF, Pats, Cs, N + 1, [Assign | RevAssigns],
            [C ^ cap_binding - View | RevViews], Result, !IT)
    else
        Result = skipped("an `after` body reads `" ++ C ^ cap_binding
            ++ ( if C ^ cap_slot = "" then "" else "." ++ C ^ cap_slot )
            ++ "`, which is not a slot this compiler can capture")
    ).

    % The value one capture snapshots at parent fire time, and the kind and
    % nullability of its capture slot -- `capture_slots` declares the same.
    %
    %@helper
:- pred capture_value(resolved_file::in, list(pat)::in, capture::in,
                      expr::out, slot_kind::out, nullable::out,
                      intern_table::in, intern_table::out) is semidet.

capture_value(RF, Pats, C, Value, Kind, Nullable, !IT) :-
    binding_index(Pats, C ^ cap_binding, 0, K, P),
    Ctx = ctx(RF, Pats, no, [], no),
    fact_of(Ctx, K, P, done(Fact)),
    Shape = capture_shape(C),
    (
        Shape = cs_fact,
        ( if
            % A view forwards its reference: in a body nested two deep the fact
            % under the binding is the outer capture fact, and the view's
            % empty-named slot holds the parent's fact.
            interned(!.IT, "", FactRef),
            slot_by_name(P ^ pt_schema, FactRef, Carried)
        then
            Value = e_slot(Fact, slot(Carried ^ sc_index)),
            Kind = Carried ^ sc_kind
        else
            Value = e_slot(Fact, whole_fact),
            Kind = k_schema(P ^ pt_schema ^ s_name)
        ),
        Nullable = non_null
    ;
        Shape = cs_slot,
        interned(!.IT, C ^ cap_slot, SlotRef),
        slot_by_name(P ^ pt_schema, SlotRef, Common),
        Value = e_slot(Fact, slot(Common ^ sc_index)),
        Kind = Common ^ sc_kind,
        Nullable = Common ^ sc_nullable
    ;
        Shape = cs_path(Segs),
        Segs = [Head | _],
        interned(!.IT, Head ^ id_name, HeadRef),
        slot_by_name(P ^ pt_schema, HeadRef, HeadSlot),
        HeadSlot ^ sc_kind = k_json,
        rlow_6_3_1_path(Ctx, K, P, Segs, done(Value), !IT),
        Kind = k_string,
        Nullable = non_null
    ).

    %@helper
:- func view_pat(intern_ref, assoc_list(string, plain_slot), int, string)
    = pat.

view_pat(CaptureRef, Views, Position, Binding) =
    pat(Binding,
        synthetic_schema(CaptureRef, list.filter_map(view_for(Binding), Views)),
        no, Position, no, no, no, no, [], no).

    %@helper
:- func view_for(string, pair(string, plain_slot)) = plain_slot is semidet.

view_for(Binding, Binding - Slot) = Slot.

    %@helper
:- func positive_binding(pat) = string is semidet.

positive_binding(P) = P ^ pt_binding :-
    P ^ pt_negated = no.

    % The bindings a call's continuation bodies may read of the patterns
    % `Pats` ([LCCO.10.3]): every positive one but a sibling's own `response`
    % or `error`. [LCCO.6.2] binds each "in the body of the clause that matched
    % it, and not in a continuation of a call made inside that body", so an
    % inner `on` body's `response` is its own answer and never a capture of
    % the outer one. Both words are reserved ([LLEX.9.6]), so no pattern an
    % author writes is left out, and at a rule's top level this is every
    % positive binding.
    %
    % ⚠ ONE ANSWER FOR THE THREE PLACES THAT ASK. The capture fact an inner
    % call's terminal asserts (`lcco_5_2_capture_emits`), its schema
    % (`inner_schemas`) and the join its siblings make (`siblings_of_calls`)
    % each read the parents; two that disagreed would emit a fact nothing
    % reads or join one nobody asserts.
    %
    %@spec [LCCO.6.2]
:- func lcco_6_2_parents(list(pat)) = list(string).

lcco_6_2_parents(Pats) =
    list.filter(( pred(B::in) is semidet :- B \= "response", B \= "error" ),
        list.filter_map(positive_binding, Pats)).

    % [LTAC.3.2]'s `$Timer_<rule>_<key>`, a synthetic name ([LLEX.10.6.1]).
    %
    %@helper
:- func timer_schema_name(string, string) = string.

timer_schema_name(Rule, Key) = "$Timer_" ++ Rule ++ "_" ++ Key.

    % [LTAC.3.5]'s `$CaptureBindings_<rule>_after_<key>`.
    %
    %@helper
:- func capture_schema_name(string, string) = string.

capture_schema_name(Rule, Key) =
    "$CaptureBindings_" ++ Rule ++ "_after_" ++ Key.

    % What an `after` body reads of a parent binding: one capture slot each.
    % `cap_slot` is the path after the binding, in three shapes:
    %
    %   * a slot name -- `m.zone` -- captured as that slot, `m_zone`;
    %   * a `Json` path -- `w.payload.user.id`, `e.payload.tags[0]` -- captured
    %     as the `json_path` read at parent fire time, flattened to
    %     `w_payload_user_id` as [LCCO.5.5] names a nested path;
    %   * empty -- a bare `m` -- captured as the fact itself, `m_FACTREF`.
    %
    % A path capture is `String`-typed and a fact capture schema-typed.
    %
    %@helper
:- type capture
    --->    capture(
                cap_binding :: string,
                cap_slot    :: string
            ).

    % Which of the three shapes a capture is.
    %
    %@helper
:- type capture_shape
    --->    cs_fact
    ;       cs_slot
    ;       cs_path(list(ident)).

    %@helper
:- func capture_shape(capture) = capture_shape.

capture_shape(C) = Shape :-
    Tail = C ^ cap_slot,
    ( if Tail = "" then
        Shape = cs_fact
    else if
        ( string.contains_char(Tail, '.')
        ; string.contains_char(Tail, '[')
        )
    then
        Shape = cs_path(path_segments(Tail))
    else
        Shape = cs_slot
    ).

    % `payload.tags[0].x` as `payload`, `tags`, `[0]`, `x`.
    %
    %@helper
:- func path_segments(string) = list(ident).

path_segments(Text) =
    list.condense(list.map(dotted_piece, string.split_at_char('.', Text))).

    %@helper
:- func dotted_piece(string) = list(ident).

dotted_piece(Piece) = Segs :-
    ( if string.sub_string_search(Piece, "[", Open), Open > 0 then
        string.split(Piece, Open, Name, Brackets),
        Segs = [ident(Name, pos(0, 0)) | bracket_pieces(Brackets)]
    else if string.prefix(Piece, "[") then
        Segs = bracket_pieces(Piece)
    else
        Segs = [ident(Piece, pos(0, 0))]
    ).

    %@helper
:- func bracket_pieces(string) = list(ident).

bracket_pieces(Text) = Segs :-
    ( if string.sub_string_search(Text, "]", Close) then
        string.split(Text, Close + 1, One, Rest),
        Segs = [ident(One, pos(0, 0)) | bracket_pieces(Rest)]
    else
        Segs = []
    ).

    % A capture's slot name on the capture fact: [LCCO.5.5]'s flattening, every
    % segment joined with `_`, and `_FACTREF` for the fact itself.
    %
    %@helper
:- func capture_slot_name(capture) = string.

capture_slot_name(C) = Name :-
    Shape = capture_shape(C),
    (
        Shape = cs_fact,
        Name = C ^ cap_binding ++ "_FACTREF"
    ;
        Shape = cs_slot,
        Name = C ^ cap_binding ++ "_" ++ C ^ cap_slot
    ;
        Shape = cs_path(Segs),
        Name = string.join_list("_",
            [C ^ cap_binding | list.map((func(I) = I ^ id_name), Segs)])
    ).

    % What an `after` body reads of the parent's positive bindings, interpolation
    % sites included, in source order and once each, or why a read cannot be
    % captured.
    %
    %@helper
:- func body_captures(list(string), list(ast_action)) = lowered(list(capture)).

body_captures(Parents, Actions) = Result :-
    list.foldl(action_captures(Parents), Actions, done([]), RevRes),
    (
        RevRes = done(Rev),
        Result = done(list.reverse(Rev))
    ;
        RevRes = skipped(Why),
        Result = skipped(Why)
    ).

    %@helper
:- pred action_captures(list(string)::in, ast_action::in,
                        lowered(list(capture))::in,
                        lowered(list(capture))::out) is det.

action_captures(Parents, Action, !Acc) :-
    ( if Action ^ aac_head = aah_log(_, Text) then
        text_captures(Parents, Text, !Acc)
    else if
        Action ^ aac_head = aah_withdraw(Withdrawn),
        list.member(Withdrawn ^ id_name, Parents)
    then
        % [IRET.10.7]: the capture carries the withdrawn fact as a reference.
        add_capture(capture(Withdrawn ^ id_name, ""), !Acc)
    else
        true
    ),
    AsExprs = ( if Action ^ aac_as = yes(AsE) then [AsE] else [] ),
    list.foldl(expr_captures(Parents),
        assoc_list.values(action_kwargs(Action)) ++ AsExprs, !Acc),
    % A nested continuation body's reads are this action's: the outer capture
    % carries the value forward ([LCCO.10.3]).
    ( if Action ^ aac_block = aab_call(_, Conts), Conts = [_ | _] then
        list.foldl(action_captures(Parents),
            list.condense(list.map(cont_body, Conts)), !Acc)
    else
        true
    ).

    %@helper
:- pred expr_captures(list(string)::in, lgra_9_3_1_expr::in,
                      lowered(list(capture))::in,
                      lowered(list(capture))::out) is det.

expr_captures(Parents, Expr, !Acc) :-
    ( if !.Acc = skipped(_) then
        true
    else if
        Expr = ex_slot(ex_name(Root), Slot, _),
        list.member(Root ^ id_name, Parents)
    then
        add_capture(capture(Root ^ id_name, Slot ^ id_name), !Acc)
    else if
        ( Expr = ex_slot(_, _, _) ; Expr = ex_index(_, _, _) ),
        slot_chain(Expr, Root, Segs),
        list.member(Root ^ id_name, Parents)
    then
        % A path through a parent's slot, captured whole as the `json_path`
        % read. `capture_value` refuses one whose head is not a `Json` slot.
        add_capture(capture(Root ^ id_name, json_path_text(Segs)), !Acc)
    else if
        ( Expr = ex_slot(_, _, _) ; Expr = ex_index(_, _, _) ),
        expr_root(Expr, Deep),
        list.member(Deep, Parents)
    then
        !:Acc = skipped("an `after` body reads a path through `" ++ Deep
            ++ "` that is not a slot path, which needs a capture shape that "
            ++ "is not built")
    else if Expr = ex_name(Bare), list.member(Bare ^ id_name, Parents) then
        % The fact itself, as a fact reference ([LTAC.3.5]).
        add_capture(capture(Bare ^ id_name, ""), !Acc)
    else if Expr = ex_string(Text, _) then
        text_captures(Parents, Text, !Acc)
    else
        list.foldl(expr_captures(Parents), ast_children(Expr), !Acc)
    ).

    %@helper
:- pred expr_root(lgra_9_3_1_expr::in, string::out) is semidet.

expr_root(ex_name(Id), Id ^ id_name).
expr_root(ex_slot(Inner, _, _), Root) :-
    expr_root(Inner, Root).
expr_root(ex_index(Inner, _, _), Root) :-
    expr_root(Inner, Root).

    %@helper
:- pred text_captures(list(string)::in, string::in,
                      lowered(list(capture))::in,
                      lowered(list(capture))::out) is det.

text_captures(Parents, Text, !Acc) :-
    list.foldl(segment_captures(Parents),
        segments(string.to_char_list(Text)), !Acc).

    %@helper
:- pred segment_captures(list(string)::in, segment::in,
                         lowered(list(capture))::in,
                         lowered(list(capture))::out) is det.

segment_captures(_, seg_text(_), !Acc).
segment_captures(Parents, seg_site(Body), !Acc) :-
    ( if split_colon(Body, PathChars, _) then
        Path = string.from_char_list(PathChars)
    else
        Path = string.from_char_list(Body)
    ),
    Parts = string.split_at_char('.', Path),
    ( if Parts = [Head, Slot], list.member(Head, Parents) then
        add_capture(capture(Head, Slot), !Acc)
    else if Parts = [Head1, _, _ | _], list.member(Head1, Parents) then
        add_capture(capture(Head1,
            string.join_list(".", list.det_tail(Parts))), !Acc)
    else if Parts = [Head2 | _], list.member(Head2, Parents) then
        ( if !.Acc = skipped(_) then
            true
        else
            !:Acc = skipped("an `after` body interpolates `" ++ Path
                ++ "`, which needs a capture shape that is not built")
        )
    else
        true
    ).

    %@helper
:- pred add_capture(capture::in, lowered(list(capture))::in,
                    lowered(list(capture))::out) is det.

add_capture(C, done(Rev), done(Out)) :-
    ( if list.member(C, Rev) then Out = Rev else Out = [C | Rev] ).
add_capture(_, skipped(Why), skipped(Why)).

    % A rule's positive pattern bindings with the own name of the schema each
    % names ([LIMP.13.1]), for the capture schemas, which are declared before
    % any rule is lowered.
    %
    %@helper
:- func lhs_binding_heads(resolved_file, ast_rule)
    = assoc_list(string, string).

lhs_binding_heads(RF, Rule) =
    list.condense(list.map(clause_binding_heads(RF), Rule ^ ar_lhs)).

    %@helper
:- func clause_binding_heads(resolved_file, ast_lhs_clause)
    = assoc_list(string, string).

clause_binding_heads(RF, C) = Heads :-
    ( if C = alc_pattern(ap_simple(Body)) then
        Heads = body_binding_head(RF, Body)
    else if C = alc_pattern(ap_sequence(_, Head, Steps, _)) then
        Heads = body_binding_head(RF, Head)
            ++ list.condense(list.map(step_binding_head(RF), Steps))
    else
        Heads = []
    ).

    %@helper
:- func step_binding_head(resolved_file, ast_then_step)
    = assoc_list(string, string).

step_binding_head(RF, Step) = body_binding_head(RF, Step ^ ats_body).

    %@helper
:- func body_binding_head(resolved_file, ast_pattern_body)
    = assoc_list(string, string).

body_binding_head(RF, Body) =
    ( if
        Body ^ apb_binding = yes(Id),
        Body ^ apb_type = atr_bare(Head)
    then
        [Id ^ id_name - limp_13_1_own_of(RF, Head ^ id_name)]
    else
        []
    ).

    % The capture schema for one clause: `corr` of the given kind, then one
    % slot per capture with the parent slot's kind and nullability. Fails when
    % a capture names no slot of its binding's schema.
    %
    %@helper
:- pred capture_schema(list(schema)::in, assoc_list(string, string)::in,
                       string::in, slot_kind::in, list(capture)::in,
                       schema::out,
                       intern_table::in, intern_table::out) is semidet.

capture_schema(Schemas, Heads, CaptureName, CorrKind, Caps, Schema, !IT) :-
    intern(CaptureName, NameRef, !IT),
    intern("corr", CorrRef, !IT),
    capture_slots(Schemas, Heads, Caps, 1, Slots, !IT),
    Schema = synthetic_schema(NameRef,
        [plain_slot(slot_common(CorrRef, CorrKind, det_slot(0), non_null,
            no, no, no, unbounded)) | Slots]).

    %@helper
:- pred capture_slots(list(schema)::in, assoc_list(string, string)::in,
                      list(capture)::in, int::in, list(plain_slot)::out,
                      intern_table::in, intern_table::out) is semidet.

capture_slots(_, _, [], _, [], !IT).
capture_slots(Schemas, Heads, [C | Cs], N, [Slot | Slots], !IT) :-
    assoc_list.search(Heads, C ^ cap_binding, Head),
    schema_named(!.IT, Schemas, Head, ParentSchema),
    Shape = capture_shape(C),
    (
        Shape = cs_fact,
        Kind = k_schema(ParentSchema ^ s_name),
        Nullable = non_null
    ;
        Shape = cs_slot,
        interned(!.IT, C ^ cap_slot, ParentSlotRef),
        slot_by_name(ParentSchema, ParentSlotRef, Common),
        Kind = Common ^ sc_kind,
        Nullable = Common ^ sc_nullable
    ;
        Shape = cs_path(Segs),
        Segs = [PathHead | _],
        interned(!.IT, PathHead ^ id_name, PathHeadRef),
        slot_by_name(ParentSchema, PathHeadRef, HeadSlot),
        HeadSlot ^ sc_kind = k_json,
        Kind = k_string,
        Nullable = non_null
    ),
    intern(capture_slot_name(C), SlotRef, !IT),
    Slot = plain_slot(slot_common(SlotRef, Kind, det_slot(N), Nullable,
        no, no, no, unbounded)),
    capture_slots(Schemas, Heads, Cs, N + 1, Slots, !IT).

    %@helper
:- func det_slot(int) = slot_index.

det_slot(N) = Ix :-
    ( if slot_index(uint32.det_from_int(N), Found) then
        Ix = Found
    else
        unexpected($pred, "a synthetic slot index is in range")
    ).

    % The compiler-owned schemas: `$ClockTick` when any rule needs a tick, then
    % rule by rule one `$Timer_<rule>_<key>` per clause, nested key paths
    % included, followed by one `$CaptureBindings_<rule>_after_<key>` per
    % top-level clause whose body reads a parent binding ([LTAC.3.5]), then the
    % timeout timers and the call capture schemas. All are `explicit`, and
    % declared whether or not their rule lowers.
    %
    %@spec [LTAC.3.2]
:- pred ltac_3_2_synthetic_schemas(list(schema)::in,
                                   assoc_list(ast_rule, type_env)::in,
                                   list(schema)::out,
                                   intern_table::in, intern_table::out) is det.

ltac_3_2_synthetic_schemas(FileSchemas, RuleEnvs, Schemas, !IT) :-
    Rules = assoc_list.keys(RuleEnvs),
    HasAfter = ( if list.find_first_match((pred(R::in) is semidet :-
        R ^ ar_rhs ^ arr_afters = [_ | _]), Rules, _) then yes else no ),
    HasTimeout = ( if list.find_first_match(has_timeout_call, Rules, _)
        then yes else no ),
    HasNowReeval = ( if list.find_first_match((pred((R - Env)::in) is semidet :-
            ast_now_reeval(Env, R)), RuleEnvs, _)
        then yes else no ),
    HasWithinReeval = ( if list.find_first_match(
            (pred((R - Env)::in) is semidet :- ast_within_reeval(Env, R)),
            RuleEnvs, _)
        then yes else no ),
    HasNegatedWithin = ( if list.find_first_match(ast_negated_within, Rules, _)
        then yes else no ),
    ( if
        ( HasAfter = yes ; HasTimeout = yes ; HasNowReeval = yes
        ; HasWithinReeval = yes ; HasNegatedWithin = yes )
    then
        intern(clock_tick_name, TickRef, !IT),
        Tick = synthetic_schema(TickRef, []),
        list.foldl2(rule_timers(FileSchemas), RuleEnvs, [], RevTimers, !IT),
        list.foldl2(rule_timeout_timers(FileSchemas), RuleEnvs, RevTimers,
            RevAll, !IT),
        Clocked = [Tick | list.reverse(RevAll)]
    else
        Clocked = []
    ),
    % [LCCO.5.2]'s capture schemas: a call's capture needs no clock.
    list.foldl2(rule_cont_captures(FileSchemas), RuleEnvs, [], RevCaptures,
        !IT),
    Schemas = Clocked ++ list.reverse(RevCaptures).

    % One `$CaptureBindings_<rule>_c<N>` per continued call that needs
    % [LCCO.5.2]'s capture fact: `corr`, then a slot per read named
    % `<binding>_<slot>` ([LCCO.5.5]).
    %
    %@helper
:- pred rule_cont_captures(list(schema)::in, pair(ast_rule, type_env)::in,
                           list(schema)::in, list(schema)::out,
                           intern_table::in, intern_table::out) is det.

rule_cont_captures(FileSchemas, Rule - Env, !Acc, !IT) :-
    Name = Rule ^ ar_name ^ id_name,
    Heads = lhs_binding_heads(Env ^ te_file, Rule),
    list.foldl2(
        ( pred(C::in, A0::in, A::out, I0::in, I::out) is det :-
            ( if
                cont_captures(assoc_list.keys(Heads), C) = done(Caps),
                needs_capture_fact(C, Caps),
                capture_schema(FileSchemas, Heads,
                    cont_capture_name(Name, C ^ cc_index), k_string, Caps, S,
                    I0, I1)
            then
                A = [S | A0],
                I = I1
            else
                A = A0,
                I = I0
            )
        ), continued_calls(Name, Rule ^ ar_rhs ^ arr_actions), !Acc, !IT).

    % Whether any call in the rule carries a `timeout`, at the top level or
    % one level in ([LCCO.10.1], [LTAC.6.1.3]).
    %
    %@helper
:- pred has_timeout_call(ast_rule::in) is semidet.

has_timeout_call(Rule) :-
    Rhs = Rule ^ ar_rhs,
    list.find_first_match(call_awaits_timeout,
        Rhs ^ arr_actions ++ list.condense(list.map(tree_actions,
            Rhs ^ arr_afters)), _).

    %@helper
:- pred call_awaits_timeout(ast_action::in) is semidet.

call_awaits_timeout(A) :-
    A ^ aac_block = aab_call(_, Conts),
    ( list.find_first_match(is_timeout, Conts, _)
    ; list.find_first_match(call_awaits_timeout,
        list.condense(list.map(cont_body, Conts)), _)
    ).

    % One `$Timer_<rule>_timeout_<N>` per `timeout` clause ([LCCO.7.2],
    % [LCCO.7.3]), after every rule's `after` timers. Each carries its own
    % clause body's reads, typed from the rule's heads.
    %
    %@helper
:- pred rule_timeout_timers(list(schema)::in, pair(ast_rule, type_env)::in,
                            list(schema)::in, list(schema)::out,
                            intern_table::in, intern_table::out) is det.

rule_timeout_timers(FileSchemas, Rule - Env, !Acc, !IT) :-
    Name = Rule ^ ar_name ^ id_name,
    Heads = lhs_binding_heads(Env ^ te_file, Rule),
    Calls = continued_calls(Name, Rule ^ ar_rhs ^ arr_actions),
    list.foldl2(
        call_timer_schemas(Name, Calls,
            head_timer_slots(FileSchemas, Heads)),
        Calls, !Acc, !IT).

    % The timer schemas of one call's `timeout` clauses, newest first on
    % `Acc`, numbered as `timeout_emit` numbers their timers. `Slots` gives
    % a clause body's capture slots from index 2.
    %
    %@helper
:- pred call_timer_schemas(string::in, list(continued_call)::in,
                           pred(list(ast_action), list(plain_slot),
                                intern_table, intern_table)::
                               in(pred(in, out, in, out) is det),
                           continued_call::in,
                           list(schema)::in, list(schema)::out,
                           intern_table::in, intern_table::out) is det.

call_timer_schemas(Name, Calls, Slots, C, !Acc, !IT) :-
    Base = timeout_base(Calls, C ^ cc_index),
    Bodies = list.filter_map(timeout_body, C ^ cc_conts),
    list.foldl3(
        ( pred(Body::in, K::in, K1::out, A0::in, A::out, I0::in, I::out)
                is det :-
            K1 = K + 1,
            Slots(Body, CapSlots, I0, I1),
            timer_schema(timeout_timer_name(Name, Base + K), CapSlots, S,
                I1, I),
            A = [S | A0]
        ), Bodies, 0, _, !Acc, !IT).

    %@helper
:- func timeout_body(ast_continuation) = list(ast_action) is semidet.

timeout_body(acont_timeout(_, Body, _)) = Body.

    % A top-level clause body's capture slots, from index 2. A read that
    % names no slot of its binding's schema gives none; the rule does not
    % lower then.
    %
    %@helper
:- pred head_timer_slots(list(schema)::in, assoc_list(string, string)::in,
                         list(ast_action)::in, list(plain_slot)::out,
                         intern_table::in, intern_table::out) is det.

head_timer_slots(FileSchemas, Heads, Body, Slots, !IT) :-
    ( if
        body_captures(assoc_list.keys(Heads), Body) = done(Caps),
        capture_slots(FileSchemas, Heads, Caps, 2, Slots0, !.IT, IT1)
    then
        Slots = Slots0,
        !:IT = IT1
    else
        Slots = []
    ).

    % One level in, a clause body's capture slots, from index 2, with the
    % kinds `capture_values` gives over the body's patterns.
    %
    %@helper
:- pred pat_timer_slots(resolved_file::in, list(pat)::in, list(ast_action)::in,
                        list(plain_slot)::out,
                        intern_table::in, intern_table::out) is det.

pat_timer_slots(RF, Pats, Body, Slots, !IT) :-
    ( if
        body_captures(lcco_6_2_parents(Pats), Body) = done(Caps),
        capture_values(RF, Pats, Caps, 2, [], [], done({_, Views}), !IT)
    then
        list.map_foldl(capture_fact_slot,
            assoc_list.from_corresponding_lists(Caps, assoc_list.values(Views)),
            Slots, !IT)
    else
        Slots = []
    ).

    % [LCCO.7.2]'s timer schema: [LTAC.3.2]'s `fire_at` and `corr`, then the
    % clause body's capture slots, named as [LCCO.5.5] names a capture slot.
    %
    %@helper
:- pred timer_schema(string::in, list(plain_slot)::in, schema::out,
                     intern_table::in, intern_table::out) is det.

timer_schema(Name, CapSlots, Schema, !IT) :-
    intern(Name, NameRef, !IT),
    intern("fire_at", FireRef, !IT),
    intern("corr", CorrRef, !IT),
    Schema = synthetic_schema(NameRef,
        [plain_slot(slot_common(FireRef, k_int, det_slot(0), non_null,
            no, no, no, unbounded)),
         plain_slot(slot_common(CorrRef, k_string, det_slot(1), non_null,
            no, no, no, unbounded))
         | CapSlots]).

    %@helper
:- pred rule_timers(list(schema)::in, pair(ast_rule, type_env)::in,
                    list(schema)::in, list(schema)::out,
                    intern_table::in, intern_table::out) is det.

rule_timers(FileSchemas, Rule - Env, !Acc, !IT) :-
    Name = Rule ^ ar_name ^ id_name,
    Heads = lhs_binding_heads(Env ^ te_file, Rule),
    timers_under(Env, assoc_list.keys(Heads), Name, "", no,
        Rule ^ ar_rhs ^ arr_afters, 0, !Acc, !IT),
    list.foldl3(clause_capture_schema(FileSchemas, Env, Heads, Name),
        Rule ^ ar_rhs ^ arr_afters, 0, _, !Acc, !IT).

    %@helper
:- pred clause_capture_schema(list(schema)::in, type_env::in,
                              assoc_list(string, string)::in,
                              string::in, ast_after_clause::in,
                              int::in, int::out,
                              list(schema)::in, list(schema)::out,
                              intern_table::in, intern_table::out) is det.

clause_capture_schema(FileSchemas, Env, Heads, Rule, A, Index, Index + 1, !Acc,
        !IT) :-
    ( if
        body_captures(assoc_list.keys(Heads), tree_actions(A)) = done(Caps),
        Caps = [_ | _],
        capture_schema(FileSchemas, Heads,
            capture_schema_name(Rule, string.from_int(Index)),
            top_corr_kind(Env, A), Caps, Schema, !.IT, IT1)
    then
        !:Acc = [Schema | !.Acc],
        !:IT = IT1
    else
        true
    ).

    % One `$Timer_<rule>_<key>` per clause, nested ones included, with a `corr`
    % slot of the kind its clause stores. `Forwarded` carries the top-level kind
    % down a capturing tree, and is `no` everywhere else.
    %
    %@helper
:- pred timers_under(type_env::in, list(string)::in, string::in, string::in,
                     maybe(slot_kind)::in, list(ast_after_clause)::in,
                     int::in, list(schema)::in, list(schema)::out,
                     intern_table::in, intern_table::out) is det.

timers_under(_, _, _, _, _, [], _, !Acc, !IT).
timers_under(Env, Parents, Rule, Parent, Forwarded, [A | As], Index, !Acc,
        !IT) :-
    Key = ( if Parent = "" then string.from_int(Index)
        else Parent ++ "_" ++ string.from_int(Index) ),
    (
        Forwarded = yes(CorrKind),
        ChildForwarded = Forwarded
    ;
        Forwarded = no,
        CorrKind = top_corr_kind(Env, A),
        ( if
            Parent = "",
            body_captures(Parents, tree_actions(A)) = done([_ | _])
        then
            ChildForwarded = yes(CorrKind)
        else
            ChildForwarded = no
        )
    ),
    intern(timer_schema_name(Rule, Key), NameRef, !IT),
    intern("fire_at", FireRef, !IT),
    intern("corr", CorrRef, !IT),
    !:Acc = [synthetic_schema(NameRef,
        [plain_slot(slot_common(FireRef, k_int, det_slot(0), non_null,
            no, no, no, unbounded)),
         plain_slot(slot_common(CorrRef, CorrKind, det_slot(1), non_null,
            no, no, no, unbounded))]) | !.Acc],
    timers_under(Env, Parents, Rule, Key, ChildForwarded, A ^ aaf_nested, 0,
        !Acc, !IT),
    timers_under(Env, Parents, Rule, Parent, Forwarded, As, Index + 1, !Acc,
        !IT).

    % The id is not on the wire -- the join key is the name -- so a synthetic
    % schema takes zero, and the loader numbers it by arrival like any other.
    %
    %@helper
:- func synthetic_schema(intern_ref, list(plain_slot)) = schema.

synthetic_schema(NameRef, Slots) =
    schema(make_schema_id(0u32), make_schema_name(NameRef), lc_explicit(Slots),
        no, no).

    % The per-call cooldown gate ([IRET.25.5.1]): each `call` carrying
    % `cooldown: <dur>` is issued only if `FN_RATE_ALLOW("<rule>#call<N>",
    % key..., <dur>_ns)` admits it, N counting the rule's `cooldown:` calls from
    % 0 in source order, hydration calls included ([LHYD.11.2]).
    %
    % The key is [LCRS.8.2]'s. The window is the last argument ([IRET.10.4]).
    %
    % The pairing is positional: the k-th `ia_call` or `ia_hydration_call` is the
    % k-th `call`, and a count that disagrees leaves the rule unlowered.
    %
    %@spec RLOW.4.6.6.1
:- pred rlow_4_6_6_1_call_gates(resolved_file::in, string::in, list(pat)::in,
                                list(ast_action)::in, list(inline_action)::in,
                                lowered(list(inline_action))::out,
                                intern_table::in, intern_table::out) is det.

rlow_4_6_6_1_call_gates(RF, Rule, Pats, Actions, Lowered, Result, !IT) :-
    Calls = list.filter((pred(A::in) is semidet :-
        A ^ aac_head = aah_call(_)), Actions),
    call_gates(RF, Rule, list.condense(list.map(key_vars, Pats)), Calls, 0,
        Lowered, [], Result, !IT).

:- pred call_gates(resolved_file::in, string::in, list(expr)::in,
                   list(ast_action)::in, int::in,
                   list(inline_action)::in, list(inline_action)::in,
                   lowered(list(inline_action))::out,
                   intern_table::in, intern_table::out) is det.

call_gates(_, _, _, Calls, _, [], Acc, Result, !IT) :-
    (
        Calls = [],
        Result = done(list.reverse(Acc))
    ;
        Calls = [_ | _],
        Result = skipped("a `call` lowered to no call action")
    ).
call_gates(RF, Rule, Keys, Calls, N, [IA | IAs], Acc, Result, !IT) :-
    ( if
        ( IA = ia_call(_, _, _, _) ; IA = ia_hydration_call(_, _, _, _, _) )
    then
        (
            Calls = [],
            Result = skipped("a call action no `call` lowered to")
        ;
            Calls = [Call | Rest],
            Cool = call_cooldown(RF, Call),
            (
                Cool = cool_unfolded,
                Result = skipped("a call's `cooldown:` is neither a duration "
                    ++ "literal nor a `time` const")
            ;
                Cool = cool_gate(Ns),
                Tracker = Rule ++ "#call" ++ string.from_int(N),
                intern(Tracker, TrackerRef, !IT),
                GateArgs = [e_lit(str(TrackerRef)) | Keys]
                    ++ [e_lit(int(int64.cast_from_uint64(Ns)))],
                ( if IA = ia_call(Svc, Corr, Kwargs, _) then
                    Gated = ia_call(Svc, Corr, Kwargs, yes(GateArgs))
                else if IA = ia_hydration_call(Tgt, Corr, Svc, Kwargs, _) then
                    Gated = ia_hydration_call(Tgt, Corr, Svc, Kwargs,
                        yes(GateArgs))
                else
                    Gated = IA
                ),
                call_gates(RF, Rule, Keys, Rest, N + 1, IAs, [Gated | Acc],
                    Result, !IT)
            ;
                Cool = cool_none,
                call_gates(RF, Rule, Keys, Rest, N, IAs, [IA | Acc], Result,
                    !IT)
            )
        )
    else
        call_gates(RF, Rule, Keys, Calls, N, IAs, [IA | Acc], Result, !IT)
    ).

    % What a `call`'s `cooldown:` asks of its gate.
    %
    %@helper
:- type call_cool
    --->    cool_none               % no `cooldown:`, or one of zero
    ;       cool_gate(uint64)       % a window above zero, in nanoseconds
    ;       cool_unfolded.          % a `cooldown:` that is no `time_expr`

    % A `call`'s `cooldown:` window. `cooldown: 0_s` and `nocooldown` gate
    % nothing. The window is a `time_expr` ([LGRA.2.8.2]), read as `within`
    % reads one (`lgra_2_8_1_time_value_ns`), so `cooldown: W` with `const W
    % = 30_s` is `cooldown: 30_s`. Anything else leaves the rule unlowered:
    % lowering it as no gate would drop the rate limit [LCRS.8.1] asked for.
    %
    %@helper
:- func call_cooldown(resolved_file, ast_action) = call_cool.

call_cooldown(RF, Action) = Cool :-
    ( if find_kwarg(action_kwargs(Action), "cooldown", E) then
        ( if lgra_2_8_1_time_value_ns(RF, E, Ns) then
            ( if Ns > 0i64 then
                Cool = cool_gate(uint64.cast_from_int64(Ns))
            else
                Cool = cool_none
            )
        else
            Cool = cool_unfolded
        )
    else
        Cool = cool_none
    ).

%-----------------------------------------------------------------------------%
% Call continuations -- [LCCO.3], [LCCO.7]
%-----------------------------------------------------------------------------%

    % A top-level `call` and its continuations, with the correlation they
    % share and the call's index among the rule's calls.
    %
    %@helper
:- type continued_call
    --->    continued_call(
                cc_corr  :: string,
                cc_index :: int,
                cc_conts :: list(ast_continuation),
                cc_action :: ast_action
            ).

    % Every continuation-bearing call among the rule's top-level actions.
    % The correlation is the author's `as "<literal>"` when there is one, else
    % `$<rule>_c<N>` with N the call's source-order index among ALL the
    % rule's calls ([LCCO.3.4]).
    %
    %@helper
:- func continued_calls(string, list(ast_action)) = list(continued_call).

continued_calls(Rule, Actions) = continued_from(Rule, Actions, 0).

    %@helper
:- func continued_from(string, list(ast_action), int) = list(continued_call).

continued_from(_, [], _) = [].
continued_from(Rule, [A | As], N) = Calls :-
    ( if A ^ aac_head = aah_call(_) then
        ( if A ^ aac_block = aab_call(_, Conts), Conts = [_ | _] then
            Calls = [continued_call(call_corr(Rule, N, A), N, Conts, A)
                | continued_from(Rule, As, N + 1)]
        else
            Calls = continued_from(Rule, As, N + 1)
        )
    else
        Calls = continued_from(Rule, As, N)
    ).

    % The correlation the siblings and the timeout timer join on: the author's
    % `as` literal, decoded ([LCCO.3.4]), else the generated form. The siblings
    % of a computed `as` join the capture fact on `corr` instead
    % (`needs_capture_fact`).
    %
    %@helper
:- func call_corr(string, int, ast_action) = string.

call_corr(Rule, N, A) =
    ( if
        author_as(A) = yes(ex_string(Text, _)),
        literal_corr(Text, Corr)
    then
        Corr
    else
        "$" ++ Rule ++ "_c" ++ string.from_int(N)
    ).

    % The author's correlation: the `as` clause, or an `as:` kwarg, which
    % `rlow_7_3_1_call` reads in that order.
    %
    %@helper
:- func author_as(ast_action) = maybe(lgra_9_3_1_expr).

author_as(A) =
    ( if A ^ aac_as = yes(E) then
        yes(E)
    else if find_kwarg(action_kwargs(A), "as", E) then
        yes(E)
    else
        no
    ).

    % A string with no interpolation site, as the outer call's lowering reads
    % it: `{{` / `}}` collapsed, then the [LGRA.2.9.1] escapes decoded.
    %
    %@helper
:- pred literal_corr(string::in, string::out) is semidet.

literal_corr(Text, Corr) :-
    Chars = string.to_char_list(Text),
    not text_has_site(Chars),
    unescape(string.to_char_list(brace_escapes(Text))) = done(Decoded),
    Corr = string.from_char_list(Decoded).

    % A continued call whose correlation is the author's and not a literal.
    %
    %@helper
:- pred computed_as(continued_call::in) is semidet.

computed_as(C) :-
    author_as(C ^ cc_action) = yes(E),
    computed_as_expr(E).

    % An author's `as` that is not a plain string literal, so its value is
    % known only when the call fires.
    %
    %@helper
:- pred computed_as_expr(lgra_9_3_1_expr::in) is semidet.

computed_as_expr(E) :-
    not ( E = ex_string(Text, _), literal_corr(Text, _) ).

    % The computed key `Key`, or `Generated` when the key renders `""`. The call,
    % its capture fact and its timeout timer all carry this one expression, so
    % they hold one value.
    %
    %@spec [LRST.1.2]
:- pred lrst_1_2_empty_key_corr(expr::in, expr::in, expr::out,
                                intern_table::in, intern_table::out) is det.

lrst_1_2_empty_key_corr(Key, Generated, Corr, !IT) :-
    intern("", EmptyRef, !IT),
    Corr = e_if(e_binop(op_eq, e_interp([fp_value(canonical_prim(Key))]),
            e_lit(str(EmptyRef))),
        Generated, Key).

    % The lowering-only call `with_generated_as` wraps a computed `as` in, for
    % `rlow_7_3_1_plain_call`. A synthetic name ([LLEX.10.6.1]), made after
    % validation.
    %
    %@helper
:- func corr_or_name = string.

corr_or_name = "$corr_or".

    % A continued call the author did not correlate, so `call_corr` generated
    % its correlation ([LCCO.3.4]).
    %
    %@helper
:- pred generated_corr(continued_call::in) is semidet.

generated_corr(C) :-
    author_as(C ^ cc_action) = no.

    % A continued call the author correlated with a plain string literal, so a
    % sibling may embed its correlation. `constant_corr`, `computed_as` and
    % `generated_corr` partition the continued calls.
    %
    %@helper
:- pred constant_corr(continued_call::in) is semidet.

constant_corr(C) :-
    author_as(C ^ cc_action) = yes(ex_string(Text, _)),
    literal_corr(Text, _).

    % [LCCO.3.4]'s `$<outer_rule_name>_c<N>_`: everything before `<u>`.
    %
    %@helper
:- func generated_corr_prefix(string, int) = string.

generated_corr_prefix(Rule, N) =
    "$" ++ Rule ++ "_c" ++ string.from_int(N) ++ "_".

    % [LCCO.3.4]'s whole `$<outer_rule_name>_c<N>_<u>`, `<u>` read from the
    % bind holding this activation's `fn_gensym`.
    %
    %@helper
:- func generated_corr_expr(string, int, bind_index) = expr.

generated_corr_expr(Rule, N, Ix) =
    e_interp([fp_text(generated_corr_prefix(Rule, N)),
        fp_value(canonical_prim(e_bind_ref(Ix)))]).

    % The synthetic `let` name ([LLEX.10.6.1]) the correlation resolves against.
    %
    %@helper
:- func corr_let_name(int) = string.

corr_let_name(N) = "$corr_c" ++ string.from_int(N).

    % The indices `call_corr_binds` allocated in a terminal's bind frame, one for
    % every call with no `as` or a computed one ([LCRS.3.1]). A continued call
    % one level in carries a literal `as` ([LCCO.3.8]) and is built with
    % `no_corr_frame`.
    %
    %@helper
:- type corr_frame
    --->    corr_frame(assoc_list(int, bind_index))
    ;       no_corr_frame.

    % Whether this call gets [LCCO.5.2]'s capture fact: because its bodies read a
    % parent binding, or because its correlation is not a constant. A `const`
    % `as` gets one: `constant_corr` recognises a plain literal only.
    %
    %@helper
:- pred needs_capture_fact(continued_call::in, list(capture)::in) is semidet.

needs_capture_fact(C, Caps) :-
    ( if Caps = [_ | _] then
        true
    else
        not constant_corr(C)
    ).

    % What a call's continuation bodies read of the parent's positive
    % bindings ([LCCO.5.1]), in source order, once each.
    %
    %@helper
:- func cont_captures(list(string), continued_call) = lowered(list(capture)).

cont_captures(Parents, C) =
    body_captures(Parents, list.condense(list.map(cont_body, C ^ cc_conts))).

    %@helper
:- func cont_body(ast_continuation) = list(ast_action).

cont_body(acont_on(_, Body, _)) = Body.
cont_body(acont_error(_, Body, _)) = Body.
cont_body(acont_timeout(_, Body, _)) = Body.

    %@helper
:- func cont_capture_name(string, int) = string.

cont_capture_name(Rule, N) =
    "$CaptureBindings_" ++ Rule ++ "_c" ++ string.from_int(N).   % [LCCO.5.2]

    % [LCCO.5.3]'s lifetime. An `on` matches the response schema, an `error`
    % matches `CallError`, and a `timeout` waits on both. No `timeout` sibling
    % joins the capture ([LCCO.7.2]); the largest `timeout` keeps it live for a
    % late answer until the last deadline ([LCCO.7.3]).
    %
    %@helper
:- func capture_ttl_ns(resolved_file, intern_table, list(schema),
                       continued_call) = maybe(int64).

capture_ttl_ns(RF, IT, Schemas, C) = Ttl :-
    Retains = ( if
                    find_kwarg(action_kwargs(C ^ cc_action), "retain", R),
                    duration_ns_of(R) > 0i64
                then [duration_ns_of(R)] else [] ),
    Timeouts = list.filter_map(
        ( func(Cont) = Ns is semidet :-
            Cont = acont_timeout(D, _, _),
            lgra_2_8_1_time_value_ns(RF, D, Ns)
        ), C ^ cc_conts),
    ( if
        list.find_first_match(awaits_response, C ^ cc_conts, _),
        response_schema(RF, IT, Schemas, C, Response, _),
        Response ^ s_lifecycle = lc_ttl(_, RespTtl)
    then
        RespTtls = [int64.cast_from_uint64(duration_ns(RespTtl))]
    else
        RespTtls = []
    ),
    Matched = RespTtls
        ++ matched_ttl(IT, Schemas, "CallError", awaits_error, C),
    Windows = Matched ++ Retains ++ Timeouts,
    (
        Windows = [],
        Ttl = no
    ;
        Windows = [W | Ws],
        Ttl = yes(list.foldl(int64.max, Ws, W))
    ).

    % The TTL of the builtin `Schema`, as one window, when one of the call's
    % continuations matches it.
    %
    %@helper
:- func matched_ttl(intern_table, list(schema), string,
                    pred(ast_continuation), continued_call) = list(int64).
:- mode matched_ttl(in, in, in, in(pred(in) is semidet), in) = out is det.

matched_ttl(IT, Schemas, Name, Awaits, C) = Ttls :-
    ( if
        list.find_first_match(Awaits, C ^ cc_conts, _),
        schema_named(IT, Schemas, Name, Schema),
        Schema ^ s_lifecycle = lc_ttl(_, Ttl)
    then
        Ttls = [int64.cast_from_uint64(duration_ns(Ttl))]
    else
        Ttls = []
    ).

    %@helper
:- pred awaits_response(ast_continuation::in) is semidet.

awaits_response(acont_on(_, _, _)).
awaits_response(acont_timeout(_, _, _)).

    %@helper
:- pred awaits_error(ast_continuation::in) is semidet.

awaits_error(acont_error(_, _, _)).
awaits_error(acont_timeout(_, _, _)).

    % One assert per call `needs_capture_fact` admits, after the rule's authored
    % actions, beside the timeout timer.
    %
    %@spec [LCCO.5.2]
    %@spec [LCCO.5.3]
    %@spec [LCCO.5.5]
    %@spec [LCCO.5.6]
:- pred lcco_5_2_capture_emits(ctx::in, list(schema)::in, string::in,
                               corr_frame::in, list(ast_action)::in,
                               lowered(list(inline_action))::out,
                               intern_table::in, intern_table::out) is det.

lcco_5_2_capture_emits(Ctx, Schemas, Rule, Frame, Actions, Result, !IT) :-
    Parents = lcco_6_2_parents(Ctx ^ cx_pats),
    list.foldl2(capture_emit(Ctx, Schemas, Rule, Frame, Parents),
        continued_calls(Rule, Actions), done([]), RevRes, !IT),
    (
        RevRes = done(Rev),
        Result = done(list.reverse(Rev))
    ;
        RevRes = skipped(Why),
        Result = skipped(Why)
    ).

    %@helper
:- pred capture_emit(ctx::in, list(schema)::in, string::in, corr_frame::in,
                     list(string)::in, continued_call::in,
                     lowered(list(inline_action))::in,
                     lowered(list(inline_action))::out,
                     intern_table::in, intern_table::out) is det.

capture_emit(Ctx, Schemas, Rule, Frame, Parents, C, Acc, Result, !IT) :-
    ( if Acc = skipped(_) then
        Result = Acc
    else if cont_captures(Parents, C) = done(Caps), needs_capture_fact(C, Caps)
    then
        lcco_3_4_call_corr(Ctx, Rule, Frame, C, CorrRes, !IT),
        (
            CorrRes = done(CorrE),
            capture_parts(Ctx ^ cx_rf, Ctx ^ cx_pats,
                cont_capture_name(Rule, C ^ cc_index), 1, Caps, CorrE,
                PartsRes, !IT),
            ( if
                PartsRes = done(yes({ia_assert(Mode, Ref, Assigns, _), _, _})),
                Acc = done(Emits)
            then
                Retain = ( if capture_ttl_ns(Ctx ^ cx_rf, !.IT, Schemas, C)
                                = yes(Ns)
                           then yes(e_lit(int(Ns))) else no ),
                Result = done([ia_assert(Mode, Ref, Assigns, Retain) | Emits])
            else if PartsRes = skipped(Why) then
                Result = skipped(Why)
            else
                Result = Acc
            )
        ;
            CorrRes = skipped(Why2),
            Result = skipped(Why2)
        )
    else if cont_captures(Parents, C) = skipped(Why3) then
        Result = skipped(Why3)
    else
        Result = Acc
    ).

    % A `call` with continuations one level in gets from the terminal that makes
    % it what a top-level call gets from its rule: its capture fact and its
    % timeout timer, after the body's actions and before the body releases its
    % own capture, which these asserts read through the views. The schemas go
    % onto `bd_synthetic` here.
    %
    %@spec [LCCO.10.3]
    %@spec [LCCO.5.2]
    %@spec [LCCO.7.2]
:- pred lcco_10_3_inner_emits(ctx::in, list(schema)::in, string::in,
                              list(ast_action)::in,
                              lowered(list(inline_action))::out,
                              build::in, build::out,
                              intern_table::in, intern_table::out) is det.

lcco_10_3_inner_emits(Ctx, Schemas, Name, Body, Result, !B, !IT) :-
    lcco_5_2_capture_emits(Ctx, Schemas, Name, no_corr_frame, Body,
        CaptureRes, !IT),
    lcco_7_2_timer_emits(Ctx, Name, no_corr_frame, Body, TimerRes, !IT),
    Parents = lcco_6_2_parents(Ctx ^ cx_pats),
    InnerCalls = continued_calls(Name, Body),
    list.foldl2(
        inner_schemas(Ctx ^ cx_rf, Ctx ^ cx_pats, Name, Parents, InnerCalls),
        InnerCalls, done([]), SchemasRes, !IT),
    ( if
        CaptureRes = done(CaptureEmits),
        TimerRes = done(TimerEmits),
        SchemasRes = done(RevSchemas)
    then
        !B ^ bd_synthetic := RevSchemas ++ !.B ^ bd_synthetic,
        Result = done(CaptureEmits ++ TimerEmits)
    else if CaptureRes = skipped(CaptureWhy) then
        Result = skipped(CaptureWhy)
    else if TimerRes = skipped(TimerWhy) then
        Result = skipped(TimerWhy)
    else if SchemasRes = skipped(SchemasWhy) then
        Result = skipped(SchemasWhy)
    else
        unexpected($pred, "every part lowered")
    ).

    % The schemas one inner call's emits name, newest first on `Acc`: its
    % capture fact's where `needs_capture_fact` gives it one, then a timer per
    % `timeout` clause, as `rule_timeout_timers` declares them at the top
    % level.
    %
    %@helper
:- pred inner_schemas(resolved_file::in, list(pat)::in, string::in,
                      list(string)::in, list(continued_call)::in,
                      continued_call::in,
                      lowered(list(schema))::in, lowered(list(schema))::out,
                      intern_table::in, intern_table::out) is det.

inner_schemas(RF, Pats, Name, Parents, Calls, C, Acc, Result, !IT) :-
    CapsRes = cont_captures(Parents, C),
    ( if Acc = skipped(_) then
        Result = Acc
    else if CapsRes = skipped(Why) then
        Result = skipped(Why)
    else
        ( if
            CapsRes = done(Caps),
            needs_capture_fact(C, Caps)
        then
            capture_fact_schema(RF, Pats,
                cont_capture_name(Name, C ^ cc_index), Caps, CapRes, !IT)
        else
            CapRes = done([])
        ),
        call_timer_schemas(Name, Calls, pat_timer_slots(RF, Pats), C, [],
            Timers, !IT),
        ( if
            CapRes = done(Captures),
            Acc = done(Rev)
        then
            Result = done(Timers ++ Captures ++ Rev)
        else if CapRes = skipped(CapWhy) then
            Result = skipped(CapWhy)
        else
            unexpected($pred, "the accumulator is done")
        )
    ).

    % The capture schema whose assert `capture_parts` builds over `Pats`. One
    % level in, a parent binding may be a view of the outer capture fact, which
    % no head names, so `capture_schema` does not serve.
    %
    %@helper
:- pred capture_fact_schema(resolved_file::in, list(pat)::in, string::in,
                            list(capture)::in, lowered(list(schema))::out,
                            intern_table::in, intern_table::out) is det.

capture_fact_schema(RF, Pats, CaptureName, Caps, Result, !IT) :-
    capture_values(RF, Pats, Caps, 1, [], [], ValuesRes, !IT),
    (
        ValuesRes = done({_, Views}),
        intern(CaptureName, NameRef, !IT),
        intern("corr", CorrRef, !IT),
        list.map_foldl(capture_fact_slot,
            assoc_list.from_corresponding_lists(Caps,
                assoc_list.values(Views)), Slots, !IT),
        Result = done([synthetic_schema(NameRef,
            [plain_slot(slot_common(CorrRef, k_string, det_slot(0), non_null,
                no, no, no, unbounded)) | Slots])])
    ;
        ValuesRes = skipped(Why),
        Result = skipped(Why)
    ).

    %@helper
:- pred capture_fact_slot(pair(capture, plain_slot)::in, plain_slot::out,
                          intern_table::in, intern_table::out) is det.

capture_fact_slot(C - plain_slot(View), plain_slot(Slot), !IT) :-
    intern(capture_slot_name(C), Ref, !IT),
    Slot = View ^ sc_name := Ref.

    % One `fn_gensym` bind per call whose correlation is generated, by the
    % call's source-order index among the terminal's calls, allocated from
    % `BindNext` upward in that terminal's bind frame: the bind actions, the
    % `let` defs the injected site resolves against, the index map the
    % emitters read, and the next free index.
    %
    % One bind per call: `fn_gensym` advances a counter on every evaluation
    % ([IARC.11.3]), and the call, its capture fact and its timeout timer carry
    % one value. The Mercury runtime answers `FN_GENSYM` only as a whole bind's
    % expression (`ds.exec`).
    %
    %@helper
:- pred call_corr_binds(list(int)::in, int::in,
                        list(inline_action)::out, list(let_def)::out,
                        assoc_list(int, bind_index)::out, int::out) is det.

call_corr_binds([], BindNext, [], [], [], BindNext).
call_corr_binds([N | Ns], BindNext, Binds, Defs, Ixs, Total) :-
    ( if bind_index(BindNext + 1, BindNext, Ix) then
        call_corr_binds(Ns, BindNext + 1, Binds0, Defs0, Ixs0, Total),
        Binds = [ia_bind(Ix, e_call(fn_gensym, [])) | Binds0],
        Defs = [let_bound(corr_let_name(N), Ix) | Defs0],
        Ixs = [N - Ix | Ixs0]
    else
        unexpected($pred, "a call correlation's bind index is in range")
    ).

    % The source-order indices, among a terminal's calls, of the calls that need
    % a correlation minted there: each call without a literal `as`. A continued
    % call in a synthesized body is never among them: `dsc.validate`'s
    % `lcco_3_8_nested_continued_as` requires a literal `as` of it.
    %
    %@spec [LCRS.3.1]
    %@spec [LCCO.3.4]
    %@spec [LCCO.3.7]
:- func lcrs_3_1_generated_calls(list(ast_action)) = list(int).

lcrs_3_1_generated_calls(Actions) = generated_from(Actions, 0).

    %@helper
:- func generated_from(list(ast_action), int) = list(int).

generated_from([], _) = [].
generated_from([A | As], N) = Ns :-
    ( if A ^ aac_head = aah_call(_) then
        Rest = generated_from(As, N + 1),
        % A computed `as` needs the bind for a key that renders `""` ([LRST.1.2]).
        % A literal `as` is never `""` (DS_VALIDATE_AS_EMPTY_KEY).
        ( if author_as(A) = yes(E), not computed_as_expr(E) then
            Ns = Rest
        else
            Ns = [N | Rest]
        )
    else
        Ns = generated_from(As, N)
    ).

    % The correlation a continued call carries, as an expression over the
    % outer rule's bindings: the author's computed `as` evaluated, the
    % per-activation form [LCCO.3.4] gives a generated one, else the author's
    % literal.
    %
    %@spec [LCCO.3.4]
:- pred lcco_3_4_call_corr(ctx::in, string::in, corr_frame::in,
                       continued_call::in, lowered(expr)::out,
                       intern_table::in, intern_table::out) is det.

lcco_3_4_call_corr(Ctx, Rule, Frame, C, Result, !IT) :-
    ( if
        computed_as(C),
        author_as(C ^ cc_action) = yes(AsExpr)
    then
        rlow_6_1_1_expr(Ctx, AsExpr, KeyRes, !IT),
        (
            KeyRes = done(KeyE),
            lrst_1_2_empty_key_corr(KeyE,
                generated_corr_expr(Rule, C ^ cc_index,
                    frame_bind($pred, Frame, C ^ cc_index)),
                CorrE, !IT),
            Result = done(CorrE)
        ;
            KeyRes = skipped(Why),
            Result = skipped(Why)
        )
    else if generated_corr(C) then
        Result = done(generated_corr_expr(Rule, C ^ cc_index,
            frame_bind($pred, Frame, C ^ cc_index)))
    else
        intern(C ^ cc_corr, CorrRef, !IT),
        Result = done(e_lit(str(CorrRef)))
    ).

    %@helper
:- func frame_bind(string, corr_frame, int) = bind_index.

frame_bind(Pred, Frame, N) = Ix :-
    ( if
        Frame = corr_frame(Ixs),
        assoc_list.search(Ixs, N, Ix0)
    then
        Ix = Ix0
    else
        unexpected(Pred, "a call with no literal `as` has a correlation bind: "
            ++ "a continued call in a synthesized body is refused by "
            ++ "dsc.validate's lcco_3_8_nested_continued_as ([LCCO.3.8])")
    ).

    % The outer rule keeps each `call` stripped of its continuations, with the
    % generated correlation injected as its `as` when the author gave none.
    %
    %@spec [LCCO.3.2]
    %@spec [LCCO.3.4]
    %@spec [LCCO.3.5]
:- func lcco_3_2_outer_actions(string, corr_frame, list(ast_action))
    = list(ast_action).

lcco_3_2_outer_actions(Rule, Frame, Actions) =
    outer_from(Rule, Frame, Actions, 0).

    %@helper
:- func outer_from(string, corr_frame, list(ast_action), int)
    = list(ast_action).

outer_from(_, _, [], _) = [].
outer_from(Rule, Frame, [A | As], N) = Out :-
    ( if A ^ aac_head = aah_call(_) then
        ( if A ^ aac_block = aab_call(Args, [_ | _]) then
            Bare = A ^ aac_block := aab_kwargs(Args),
            Out = [with_generated_as(Rule, Frame, N, Bare)
                | outer_from(Rule, Frame, As, N + 1)]
        else
            Out = [with_generated_as(Rule, Frame, N, A)
                | outer_from(Rule, Frame, As, N + 1)]
        )
    else
        Out = [A | outer_from(Rule, Frame, As, N)]
    ).

    % The call, with [LCCO.3.4]'s `$<rule>_c<N>_{<bind>}` as its `as` when
    % the author wrote none and the frame holds a bind for it. A computed
    % `as` with a bind keeps the key and gains the generated value as its
    % fallback ([LRST.1.2]), wrapped in `$corr_or(<key>, <generated>)`,
    % which `rlow_7_3_1_plain_call` lowers to `lrst_1_2_empty_key_corr`.
    %
    %@helper
:- func with_generated_as(string, corr_frame, int, ast_action) = ast_action.

with_generated_as(Rule, Frame, N, A) =
    ( if
        Frame = corr_frame(Ixs),
        assoc_list.search(Ixs, N, _)
    then
        ( if author_as(A) = yes(Key) then
            ( if computed_as_expr(Key) then
                A ^ aac_as := yes(ex_call(
                    ex_name(ident(corr_or_name, A ^ aac_pos)),
                    [Key, generated_as(Rule, N, A ^ aac_pos)], A ^ aac_pos))
            else
                A
            )
        else
            A ^ aac_as := yes(generated_as(Rule, N, A ^ aac_pos))
        )
    else
        A
    ).

    % [LCCO.3.4]'s `$<rule>_c<N>_<u>`, as the lowering-only call
    % `$corr_gen(<prefix>, <bind>)` the call's `as` lowers from
    % (`rlow_7_3_1_corr`). Not an interpolated string: a `{` opens no site before
    % `$` ([LLEX.10.6.1]).
    %
    %@helper
:- func generated_as(string, int, pos) = lgra_9_3_1_expr.

generated_as(Rule, N, Pos) =
    ex_call(ex_name(ident(corr_gen_name, Pos)),
        [ex_string(generated_corr_prefix(Rule, N), Pos),
         ex_name(ident(corr_let_name(N), Pos))], Pos).

    %@helper
:- func corr_gen_name = string.

corr_gen_name = "$corr_gen".

    % After its immediate actions, the outer rule emits one
    % `$Timer_<outer>_timeout_<N>` per `timeout` clause, with `fire_at` the
    % monotonic clock plus the duration and `corr` the call's correlation,
    % `<N>` counted across the rule's calls ([LCCO.4.1]).
    %
    %@spec [LCCO.7.2]
    %@spec [LCCO.7.3]
:- pred lcco_7_2_timer_emits(ctx::in, string::in, corr_frame::in,
                             list(ast_action)::in,
                             lowered(list(inline_action))::out,
                             intern_table::in, intern_table::out) is det.

lcco_7_2_timer_emits(Ctx, Rule, Frame, Actions, Result, !IT) :-
    Calls = continued_calls(Rule, Actions),
    list.foldl2(timeout_emit(Ctx, Rule, Frame, Calls), Calls, done([]),
        RevRes, !IT),
    (
        RevRes = done(Rev),
        Result = done(list.reverse(Rev))
    ;
        RevRes = skipped(Why),
        Result = skipped(Why)
    ).

    % The timers of one call's `timeout` clauses, each with the call's
    % correlation, a computed `as` evaluated like the call's own. The duration
    % is a `time_expr` ([LGRA.2.8.2]), read as `within` reads one, so
    % `timeout W:` with `const W = 5_s` arms a 5 s timer. Anything else leaves
    % the rule unlowered, since a sibling with no timer would never fire.
    %
    % A re-fire with the same evaluated key supersedes the prior timers
    % ([LRST.2.2]), so each emit is preceded by the retraction of that
    % clause's timers on the same `corr`, as an `after ... as` timer's is. A
    % generated correlation never collides ([LCCO.3.4]), so nothing sweeps it.
    %
    %@helper
:- pred timeout_emit(ctx::in, string::in, corr_frame::in,
                     list(continued_call)::in, continued_call::in,
                     lowered(list(inline_action))::in,
                     lowered(list(inline_action))::out,
                     intern_table::in, intern_table::out) is det.

timeout_emit(Ctx, Rule, Frame, Calls, Call, Acc, Result, !IT) :-
    Timeouts = list.filter(is_timeout, Call ^ cc_conts),
    ( if Acc = done(Rev0), Timeouts = [_ | _] then
        lcco_3_4_call_corr(Ctx, Rule, Frame, Call, CorrRes, !IT),
        (
            CorrRes = done(CorrE),
            Supersede = ( if author_as(Call ^ cc_action) = yes(_) then yes
                          else no ),
            list.foldl3(clause_timer(Ctx, Rule, CorrE, Supersede), Timeouts,
                timeout_base(Calls, Call ^ cc_index), _, done(Rev0), Result,
                !IT)
        ;
            CorrRes = skipped(Why),
            Result = skipped(Why)
        )
    else
        Result = Acc
    ).

    % One `timeout` clause's timer, numbered `N`, onto the reversed emits.
    %
    % [LCCO.7.2]: after `fire_at` and `corr`, the timer carries a snapshot of
    % every outer binding its body reads, from the same expressions as the
    % capture fact's ([LCCO.5.4]), so the sibling reads the timer alone and
    % fires at the first pump at or past the deadline, however late.
    %
    %@helper
:- pred clause_timer(ctx::in, string::in, expr::in, bool::in,
                     ast_continuation::in, int::in, int::out,
                     lowered(list(inline_action))::in,
                     lowered(list(inline_action))::out,
                     intern_table::in, intern_table::out) is det.

clause_timer(Ctx, Rule, CorrE, Supersede, Timeout, N, N + 1, Acc, Result,
        !IT) :-
    ( if
        Acc = done(Rev),
        Timeout = acont_timeout(DurExpr, Body, _)
    then
        ( if lgra_2_8_1_time_value_ns(Ctx ^ cx_rf, DurExpr, Ns) then
            ( if Ns > 0i64 then
                timer_captures(Ctx, Body, CapsRes, !IT),
                (
                    CapsRes = done(CapAssigns),
                    intern(timeout_timer_name(Rule, N), TimerRef, !IT),
                    % On the monotonic clock ([LTIM.2.8.2]), like `after`'s
                    % timer.
                    Assert = ia_assert(plain, TimerRef, [
                        slot_assign(det_slot(0), e_binop(op_add,
                            ltim_2_2_1_monotonic_ns, e_lit(int(Ns)))),
                        slot_assign(det_slot(1), CorrE) | CapAssigns], no),
                    (
                        Supersede = yes,
                        intern("corr", CorrSlotRef, !IT),
                        Sweep = ia_internal(fn_retract_corr,
                            [e_lit(str(TimerRef)), e_lit(str(CorrSlotRef)),
                             CorrE]),
                        Result = done([Assert, Sweep | Rev])
                    ;
                        Supersede = no,
                        Result = done([Assert | Rev])
                    )
                ;
                    CapsRes = skipped(Why),
                    Result = skipped(Why)
                )
            else
                Result = Acc
            )
        else
            Result = skipped("a `timeout`'s duration is neither a duration "
                ++ "literal nor a `time` const")
        )
    else
        Result = Acc
    ).

    % The slot assigns of a `timeout` body's reads on its timer, from index 2,
    % over the patterns that make the call: `pat_timer_slots` declares the
    % same slots one level in, and `head_timer_slots` at the top level.
    %
    %@helper
:- pred timer_captures(ctx::in, list(ast_action)::in,
                       lowered(list(slot_assign))::out,
                       intern_table::in, intern_table::out) is det.

timer_captures(Ctx, Body, Result, !IT) :-
    CapsRes = body_captures(lcco_6_2_parents(Ctx ^ cx_pats), Body),
    (
        CapsRes = done(Caps),
        capture_values(Ctx ^ cx_rf, Ctx ^ cx_pats, Caps, 2, [], [], ValuesRes,
            !IT),
        (
            ValuesRes = done({Assigns, _}),
            Result = done(Assigns)
        ;
            ValuesRes = skipped(Why),
            Result = skipped(Why)
        )
    ;
        CapsRes = skipped(Why2),
        Result = skipped(Why2)
    ).

    %@helper
:- pred is_timeout(ast_continuation::in) is semidet.

is_timeout(acont_timeout(_, _, _)).

    % How many `timeout` clauses a call carries.
    %
    %@helper
:- func timeout_count(continued_call) = int.

timeout_count(Call) = list.length(list.filter(is_timeout, Call ^ cc_conts)).

    % [LCCO.4.1]'s `<N>` for the first `timeout` clause of the call at
    % `Index`: the `timeout` clauses of the rule's calls before it, so the
    % numbering runs across the rule's calls in source order, as the
    % siblings' does (`siblings_from`).
    %
    %@helper
:- func timeout_base(list(continued_call), int) = int.

timeout_base(Calls, Index) =
    list.foldl(
        ( func(C, N) =
            ( if C ^ cc_index < Index then N + timeout_count(C) else N ) ),
        Calls, 0).

    %@helper
:- func timeout_timer_name(string, int) = string.

timeout_timer_name(Rule, N) =
    "$Timer_" ++ Rule ++ "_timeout_" ++ string.from_int(N).   % [LLEX.10.6.1]

    % One sibling rule per continuation, allocated after the outer rule's
    % terminal. `<n>` counts per kind ([LCCO.4.1]):
    %
    %   * `on <pred>:`, `$<rule>_response_<n>`: the response schema, joined on
    %     the correlation and the predicate ([LCCO.3.3]);
    %   * `error [<code>]:`, `$<rule>_error_<n>`: `CallError`, joined on the
    %     correlation and, with a code, `ds_error_code_matches`;
    %   * `timeout <dur>:`, `$<rule>_timeout_<n>`: the clause's timer on the
    %     correlation, the clock tick, then NOT the response schema and NOT
    %     `CallError` on the correlation, guarded on `monotonic_ns() >=
    %     fire_at`, retracting the timer after the body; and its two discharge
    %     rules, `_answered` and `_failed` ([LCCO.7.6]).
    %
    % `<n>` counts across the rule: `siblings_from` carries the counters from
    % one call to the next, and a timeout's timer, its sibling and its
    % discharge rules share its `<n>`.
    %
    % A depth-two call reaches this from `one_pattern_sibling`, `timeout_sibling`
    % and `follow_up`, with `no_corr_frame`.
    %
    %@spec [LCCO.3.1]
    %@spec [LCCO.3.3]
    %@spec [LCCO.5.1]
    %@spec [LCCO.5.4]
    %@spec [LCCO.10.1]
    %@spec [LCCO.10.3]
    %@spec [LTAC.6.1.3]
:- pred lcco_3_1_siblings(resolved_file::in, type_env::in, list(schema)::in,
                          string::in, list(pat)::in, corr_frame::in,
                          list(ast_action)::in, lowered(unit)::out,
                          build::in, build::out,
                          intern_table::in, intern_table::out) is det.

lcco_3_1_siblings(RF, Env, Schemas, Rule, Pats, Frame, Actions, Result, !B,
        !IT) :-
    siblings_of_calls(RF, Env, Schemas, Rule, Pats, Frame,
        continued_calls(Rule, Actions), Result, !B, !IT).

    % Every sibling body is lowered in the rule's typing environment `Env`
    % with its own fact bound, `response` or `error`, as `dsc.validate`'s
    % `scoped_actions` types it.
    %
    %@helper
:- pred siblings_of_calls(resolved_file::in, type_env::in, list(schema)::in,
                          string::in, list(pat)::in, corr_frame::in,
                          list(continued_call)::in,
                          lowered(unit)::out,
                          build::in, build::out,
                          intern_table::in, intern_table::out) is det.

siblings_of_calls(RF, Env, Schemas, Rule, Pats, Frame, Calls, Result, !B,
        !IT) :-
    siblings_from(RF, Env, Schemas, Rule, Pats, Frame, Calls, {0, 0, 0},
        Result, !B, !IT).

    % `siblings_of_calls` with [LCCO.4.1]'s three counters carried from call
    % to call: `<N>` is "the source-order index among clauses of that same
    % kind within the outer rule", so a rule's second continued call goes on
    % counting where its first stopped, and two calls' `on` clauses are
    % `$<rule>_response_0` and `_1`, not both `_0`.
    %
    %@helper
:- pred siblings_from(resolved_file::in, type_env::in, list(schema)::in,
                      string::in, list(pat)::in, corr_frame::in,
                      list(continued_call)::in, {int, int, int}::in,
                      lowered(unit)::out,
                      build::in, build::out,
                      intern_table::in, intern_table::out) is det.

siblings_from(_, _, _, _, _, _, [], _, done(unit), !B, !IT).
siblings_from(RF, Env, Schemas, Rule, Pats, Frame, [Call | Calls], Counts0,
        Result, !B, !IT) :-
    Parents = lcco_6_2_parents(Pats),
    CapsRes = cont_captures(Parents, Call),
    ( if Frame = no_corr_frame, not constant_corr(Call) then
        unexpected($pred, "a continued call in a synthesized body has a "
            ++ "literal `as`: dsc.validate's lcco_3_8_nested_continued_as "
            ++ "refuses one without ([LCCO.3.8])")
    else
        (
            CapsRes = skipped(Why),
            Result = skipped(Why)
        ;
            CapsRes = done(Caps),
            Capture = sibling_capture(RF, Pats, Rule, Call, Caps),
            sibling_rules(RF, Env, Schemas, Rule, Call, Capture,
                Call ^ cc_conts, Counts0, One, !B, !IT),
            (
                One = done(Counts1),
                siblings_from(RF, Env, Schemas, Rule, Pats, Frame, Calls,
                    Counts1, Result, !B, !IT)
            ;
                One = skipped(Why2),
                Result = skipped(Why2)
            )
        )
    ).

    % What a sibling needs of its call's capture fact ([LCCO.5.2]): the schema
    % name and what was captured, from which the views at the sibling's own
    % token position are built.
    %
    %@helper
:- type sibling_capture
    --->    sibling_capture(
                scap_rf       :: resolved_file,
                scap_pats     :: list(pat),
                scap_name   :: string,
                scap_captures :: list(capture)
            ).

    %@helper
:- func sibling_capture(resolved_file, list(pat), string, continued_call,
                        list(capture)) = maybe(sibling_capture).

sibling_capture(RF, Pats, Rule, Call, Caps) =
    ( if needs_capture_fact(Call, Caps) then
        yes(sibling_capture(RF, Pats, cont_capture_name(Rule, Call ^ cc_index),
            Caps))
    else
        no
    ).

    % Each sibling's body ends by retracting the capture fact at its token
    % position ([LSCP.2.4.1]). The compiler emits this retract: no artefact can
    % tell an engine a schema is activation-scoped. The first completion releases
    % it, so of two `on` clauses matching one response only the first fires.
    %
    %@spec [LCCO.5.0]
:- func lcco_5_0_release(int) = inline_action.

lcco_5_0_release(Position) =
    ia_internal(fn_retract_token_fact, [e_lit(int(int64.from_int(Position)))]).

    % The capture's alpha, a beta joining it under `Parent` on `corr` against
    % `TokenCorr`, and the views of the parent bindings at `Position`
    % ([LCCO.5.4]).
    %
    %@helper
:- pred capture_join(sibling_capture::in, uint32::in, expr::in, int::in,
                     lowered({uint32, list(pat)})::out,
                     build::in, build::out,
                     intern_table::in, intern_table::out) is det.

capture_join(SC, Parent, TokenCorr, Position, Result, !B, !IT) :-
    intern("", Empty, !IT),
    capture_parts(SC ^ scap_rf, SC ^ scap_pats, SC ^ scap_name, Position,
        SC ^ scap_captures, e_lit(str(Empty)), PartsRes, !IT),
    (
        PartsRes = done(yes({_, CaptureRef, Views})),
        alpha_for(make_schema_name(CaptureRef), [], CaptureAlpha, !B),
        CaptureBeta = !.B ^ bd_next,
        Join = e_binop(op_eq, e_slot(candidate, slot(det_slot(0))), TokenCorr),
        !:B = (!.B ^ bd_next := CaptureBeta + 1u32)
            ^ bd_betas := [raw_beta(det_node_id(CaptureBeta), CaptureAlpha,
                Parent, [Join], no) | !.B ^ bd_betas],
        Result = done({CaptureBeta, Views})
    ;
        PartsRes = done(no),
        Result = skipped("a continuation capture this compiler cannot build")
    ;
        PartsRes = skipped(Why),
        Result = skipped(Why)
    ).

    % [LCCO.7.2]: the views of the parent bindings a `timeout` body reads, on
    % the clause's timer at token position 0. The slots are the ones
    % `clause_timer` asserts, from index 2, computed by the same
    % `capture_values` over the same patterns.
    %
    %@helper
:- pred timer_views(sibling_capture::in, intern_ref::in, list(ast_action)::in,
                    lowered(list(pat))::out,
                    intern_table::in, intern_table::out) is det.

timer_views(SC, TimerRef, Body, Result, !IT) :-
    CapsRes = body_captures(lcco_6_2_parents(SC ^ scap_pats), Body),
    (
        CapsRes = done(Caps),
        capture_values(SC ^ scap_rf, SC ^ scap_pats, Caps, 2, [], [],
            ValuesRes, !IT),
        (
            ValuesRes = done({_, Views}),
            Bindings = list.remove_dups(assoc_list.keys(Views)),
            Result = done(list.map(view_pat(TimerRef, Views, 0), Bindings))
        ;
            ValuesRes = skipped(Why),
            Result = skipped(Why)
        )
    ;
        CapsRes = skipped(Why2),
        Result = skipped(Why2)
    ).

    % [LCCO.7.2]: on a call with one `timeout` clause, the sibling releases
    % the call's capture fact on the timer's `corr` ([LSCP.2.4.1]), since it
    % joins none. `FN_RETRACT_CORR` labels the withdrawal `SUPERSEDED`; a
    % capture fact's withdrawal is never recorded ([RFCS.6a.5]), so the label
    % binds nothing ([RFCS.7a.2]).
    %
    %@spec [LCCO.7.2]
:- pred lcco_7_2_release(sibling_capture::in, expr::in, inline_action::out,
                         intern_table::in, intern_table::out) is det.

lcco_7_2_release(SC, CorrE, Release, !IT) :-
    intern(SC ^ scap_name, CaptureRef, !IT),
    intern("corr", CorrSlotRef, !IT),
    Release = ia_internal(fn_retract_corr,
        [e_lit(str(CaptureRef)), e_lit(str(CorrSlotRef)), CorrE]).

    %@helper
:- pred sibling_rules(resolved_file::in, type_env::in, list(schema)::in,
                      string::in, continued_call::in,
                      maybe(sibling_capture)::in, list(ast_continuation)::in,
                      {int, int, int}::in, lowered({int, int, int})::out,
                      build::in, build::out,
                      intern_table::in, intern_table::out) is det.

sibling_rules(_, _, _, _, _, _, [], Counts, done(Counts), !B, !IT).
sibling_rules(RF, Env, Schemas, Rule, Call, Capture, [Cont | Conts],
        {NResp, NErr, NTime}, Result, !B, !IT) :-
    intern(Call ^ cc_corr, CorrRef, !IT),
    CorrLit = e_lit(str(CorrRef)),
    (
        Cont = acont_on(Pred, Body, Pos),
        Name = "$" ++ Rule ++ "_response_" ++ string.from_int(NResp),   % [LCCO.4.1]
        ( if
            response_schema(RF, !.IT, Schemas, Call, Response, CorrIx),
            Call ^ cc_action ^ aac_head = aah_call(Ref),
            call_response_schema(RF, Ref, ResponseName)
        then
            Pat = pat("response", Response, no, 0, no, no, no, no, [], no),
            % [LCCO.6.2]: the predicate is typed as a `where` is, and the body
            % sees the same fact, both with `response` bound to the response
            % schema by its own name, as `dsc.validate` types them
            % (`continuation_env`). Without it a typed lowering --
            % `Date` and `Duration` arithmetic ([RLOW.6.1.5], [RLOW.6.1.6]), a
            % bridged comparison, a cast -- has no type to read.
            ResponseEnv = env_with_binding(Env, "response", ResponseName, Pos),
            rlow_6_1_1_expr(ctx(RF, [Pat], yes(0), [], yes(ResponseEnv)), Pred,
                PredRes, !IT),
            (
                PredRes = done(PredE),
                one_pattern_sibling(RF, Env, ResponseEnv, Schemas, Name, Pat,
                    CorrIx, corr_tests(Call, CorrIx, CorrLit) ++ [PredE],
                    Capture, Body, Pos, StepRes, !B, !IT)
            ;
                PredRes = skipped(Why),
                StepRes = skipped(Why)
            )
        else
            StepRes = skipped("no response schema with a `corr` slot for an "
                ++ "`on` sibling")
        ),
        Next = {NResp + 1, NErr, NTime}
    ;
        Cont = acont_error(Code, Body, Pos),
        Name = "$" ++ Rule ++ "_error_" ++ string.from_int(NErr),
        ( if schema_named(!.IT, Schemas, "CallError", Error) then
            Pat = pat("error", Error, no, 0, no, no, no, no, [], no),
            CorrTests = corr_tests(Call, det_slot(0), CorrLit),
            ( if Code = yes(Path), Path = [_ | _] then
                intern(string.join_list(".",
                    list.map((func(I) = I ^ id_name), Path)), CodeRef, !IT),
                Tests = CorrTests ++ [e_call(fn_error_code_matches,
                    [e_slot(candidate, slot(det_slot(1))), e_lit(str(CodeRef))])]
            else
                Tests = CorrTests
            ),
            % [LCCO.8.4]: the body reads the `CallError` as `error`.
            one_pattern_sibling(RF, Env,
                env_with_binding(Env, "error", "CallError", Pos), Schemas,
                Name, Pat, det_slot(0), Tests, Capture, Body, Pos, StepRes,
                !B, !IT)
        else
            StepRes = skipped("no `CallError` schema for an `error` sibling")
        ),
        Next = {NResp, NErr + 1, NTime}
    ;
        Cont = acont_timeout(_, Body, Pos),
        Name = "$" ++ Rule ++ "_timeout_" ++ string.from_int(NTime),
        timeout_sibling(RF, Env, Schemas, Rule, Call, Capture, Name, NTime,
            CorrLit, Body, Pos, TimeoutRes, !B, !IT),
        (
            TimeoutRes = done(_),
            lcco_7_6_discharge(RF, Schemas, Rule, Call, NTime, CorrLit, Pos,
                StepRes, !B, !IT)
        ;
            TimeoutRes = skipped(TimeoutWhy),
            StepRes = skipped(TimeoutWhy)
        ),
        Next = {NResp, NErr, NTime + 1}
    ),
    (
        StepRes = done(_),
        sibling_rules(RF, Env, Schemas, Rule, Call, Capture, Conts, Next,
            Result, !B, !IT)
    ;
        StepRes = skipped(Why2),
        Result = skipped(Why2)
    ).

    % The candidate's `corr` equals the call's literal correlation. Only an
    % author's literal may be embedded: `cc_corr` of a generated correlation is
    % not the value the response carries.
    %
    %@helper
:- func corr_tests(continued_call, slot_index, expr) = list(expr).

corr_tests(Call, CorrIx, CorrLit) = Tests :-
    ( if constant_corr(Call) then
        Tests = [e_binop(op_eq, e_slot(candidate, slot(CorrIx)), CorrLit)]
    else
        Tests = []
    ).

    % The called service's response schema and where it keeps `corr`. Fails for a
    % `no response` service.
    %
    %@helper
:- pred response_schema(resolved_file::in, intern_table::in, list(schema)::in,
                        continued_call::in, schema::out, slot_index::out)
    is semidet.

response_schema(RF, IT, Schemas, Call, Response, CorrIx) :-
    Call ^ cc_action ^ aac_head = aah_call(Ref),
    call_response_schema(RF, Ref, Name),
    schema_named(IT, Schemas, Name, Response),
    corr_index(IT, Response, CorrIx).

    % A sibling over one pattern: the root beta carries the tests, and the body
    % sees the pattern's binding at token position 0 and, with a capture, the
    % parent bindings at position 1 ([LCCO.5.1]).
    %
    % `Env` is the rule's environment and `BodyEnv` the body's, which binds
    % the pattern too. An inner call's continuations are built from `Env`:
    % they see the rule's bindings and their own fact, not this one
    % ([LCCO.6.2]).
    %
    %@helper
:- pred one_pattern_sibling(resolved_file::in, type_env::in, type_env::in,
                            list(schema)::in, string::in, pat::in,
                            slot_index::in,
                            list(expr)::in, maybe(sibling_capture)::in,
                            list(ast_action)::in,
                            pos::in, lowered(unit)::out,
                            build::in, build::out,
                            intern_table::in, intern_table::out) is det.

one_pattern_sibling(RF, Env, BodyEnv, Schemas, Name, Pat, CorrIx, Tests,
        Capture, Body, Pos, Result, !B, !IT) :-
    alpha_for(Pat ^ pt_schema ^ s_name, [], Alpha, !B),
    Root = !.B ^ bd_next,
    !:B = (!.B ^ bd_next := Root + 1u32)
        ^ bd_betas := [raw_beta(det_node_id(Root), Alpha, 0u32, Tests, no)
            | !.B ^ bd_betas],
    (
        Capture = no,
        JoinRes = done({Root, []}),
        CaptureTail = []
    ;
        Capture = yes(SC),
        capture_join(SC, Root, e_slot(token_fact(0), slot(CorrIx)), 1,
            JoinRes, !B, !IT),
        CaptureTail = [lcco_5_0_release(1)]
    ),
    (
        JoinRes = done({Parent, Views}),
        % [LCCO.10.1]: a sibling's body is lowered as a rule's RHS is. The
        % recursion terminates because `dsc.validate`'s `lcco_10_2_chain_depth`
        % caps the chain.
        SibPats = [Pat | Views],
        call_corr_binds(lcrs_3_1_generated_calls(Body), 0,
            CorrBinds, CorrDefs, CorrIxs, BindCount),
        BodyCtx = ctx(RF, SibPats, no, CorrDefs, yes(BodyEnv)),
        lower_actions(BodyCtx, Schemas,
            lcco_3_2_outer_actions(Name, corr_frame(CorrIxs), Body),
            !IT, [], BodyRes),
        (
            BodyRes = done(Actions),
            lcco_10_3_inner_emits(BodyCtx, Schemas, Name, Body, InnerRes,
                !B, !IT),
            (
                InnerRes = done(InnerEmits),
                push_sibling(Name, Parent, no, BindCount,
                    CorrBinds ++ Actions ++ InnerEmits ++ CaptureTail, Pos,
                    !B, !IT),
                siblings_of_calls(RF, Env, Schemas, Name, SibPats,
                    no_corr_frame, continued_calls(Name, Body), Result,
                    !B, !IT)
            ;
                InnerRes = skipped(InnerWhy),
                Result = skipped(InnerWhy)
            )
        ;
            BodyRes = skipped(Why),
            Result = skipped(Why)
        )
    ;
        JoinRes = skipped(Why2),
        Result = skipped(Why2)
    ).

    % The timeout sibling: timer, clock tick, then NOT the service's response
    % schema and NOT `CallError` on the correlation. It joins no capture fact:
    % the body reads the parent bindings from the timer at position 0, which
    % carries what the body reads ([LCCO.7.2]).
    %
    % [LCCO.7.3]: the clause's own timer, `N` as [LCCO.4.1] counts it, so two
    % clauses fire at their own durations. On a call with more than one
    % `timeout` clause the firing does not release the capture fact: a late
    % answer's `on` or `error` sibling still joins it, and it ends by such a
    % match, supersedure or its [LCCO.5.3] lifetime. With one clause the
    % firing is the activation's last completion path, and releases the
    % capture on the timer's `corr` ([LSCP.2.4.1]).
    %
    %@helper
:- pred timeout_sibling(resolved_file::in, type_env::in, list(schema)::in,
                        string::in, continued_call::in,
                        maybe(sibling_capture)::in, string::in, int::in,
                        expr::in, list(ast_action)::in, pos::in,
                        lowered(unit)::out,
                        build::in, build::out,
                        intern_table::in, intern_table::out) is det.

timeout_sibling(RF, Env, Schemas, Rule, Call, Capture, Name, N, CorrLit, Body,
        Pos, Result, !B, !IT) :-
    intern(timeout_timer_name(Rule, N), TimerRef, !IT),
    intern(clock_tick_name, TickRef, !IT),
    ( if
        schema_named(!.IT, Schemas, "CallError", Error),
        response_schema(RF, !.IT, Schemas, Call, Response, RespIx)
    then
        alpha_for(make_schema_name(TimerRef), [], TimerAlpha, !B),
        alpha_for(make_schema_name(TickRef), [], TickAlpha, !B),
        alpha_for(Response ^ s_name, [], ResponseAlpha, !B),
        alpha_for(Error ^ s_name, [], ErrorAlpha, !B),
        TimerCorrE = e_slot(token_fact(0), slot(det_slot(1))),
        % A per-activation correlation: the NOT nodes compare against the
        % timer's own `corr` slot.
        ( if not constant_corr(Call) then
            TimerTests = [],
            CorrE = TimerCorrE
        else
            TimerTests = [e_binop(op_eq, e_slot(candidate, slot(det_slot(1))),
                CorrLit)],
            CorrE = CorrLit
        ),
        ErrCorr = e_binop(op_eq, e_slot(candidate, slot(det_slot(0))), CorrE),
        TimerB = !.B ^ bd_next,
        TickB = TimerB + 1u32,
        !:B = (!.B ^ bd_next := TimerB + 2u32)
            ^ bd_betas := [
                raw_beta(det_node_id(TickB), TickAlpha, TimerB, [], no),
                raw_beta(det_node_id(TimerB), TimerAlpha, 0u32, TimerTests, no)
                | !.B ^ bd_betas],
        (
            Capture = no,
            JoinRes = done({TickB, []}),
            CaptureTail = []
        ;
            Capture = yes(SC),
            timer_views(SC, TimerRef, Body, ViewsRes, !IT),
            (
                ViewsRes = done(Views0),
                JoinRes = done({TickB, Views0})
            ;
                ViewsRes = skipped(ViewsWhy),
                JoinRes = skipped(ViewsWhy)
            ),
            ( if timeout_count(Call) =< 1 then
                lcco_7_2_release(SC, TimerCorrE, Release, !IT),
                CaptureTail = [Release]
            else
                CaptureTail = []
            )
        ),
        (
            JoinRes = done({Above, Views}),
            NotResp = !.B ^ bd_next,
            NotErr = NotResp + 1u32,
            !:B = (!.B ^ bd_next := NotResp + 2u32)
                ^ bd_betas := [
                    raw_beta(det_node_id(NotErr), ErrorAlpha, NotResp,
                        [ErrCorr], yes),
                    raw_beta(det_node_id(NotResp), ResponseAlpha, Above,
                        [e_binop(op_eq, e_slot(candidate, slot(RespIx)),
                            CorrE)], yes)
                    | !.B ^ bd_betas],
            call_corr_binds(lcrs_3_1_generated_calls(Body), 0,
                CorrBinds, CorrDefs, CorrIxs, BindCount),
            BodyCtx = ctx(RF, Views, no, CorrDefs, yes(Env)),
            lower_actions(BodyCtx, Schemas,
                lcco_3_2_outer_actions(Name, corr_frame(CorrIxs), Body),
                !IT, [], BodyRes),
            (
                BodyRes = done(Actions),
                Guard = e_binop(op_ge, ltim_2_2_1_monotonic_ns,
                    e_slot(token_fact(0), slot(det_slot(0)))),
                lcco_10_3_inner_emits(BodyCtx, Schemas, Name, Body, InnerRes,
                    !B, !IT),
                (
                    InnerRes = done(InnerEmits),
                    % The release reads the timer's `corr`, so the timer
                    % leaves last: no action reads a fact after an earlier
                    % one retracted it, as [LGRA.10.1.3] holds an authored
                    % RHS. libds reads a token's facts in place.
                    push_sibling(Name, NotErr, yes(Guard), BindCount,
                        CorrBinds ++ Actions ++ InnerEmits ++ CaptureTail
                        ++ [ia_internal(fn_retract_token_fact,
                            [e_lit(int(0i64))])],
                        Pos, !B, !IT),
                    siblings_of_calls(RF, Env, Schemas, Name, Views,
                        no_corr_frame, continued_calls(Name, Body), Result,
                        !B, !IT)
                ;
                    InnerRes = skipped(InnerWhy),
                    Result = skipped(InnerWhy)
                )
            ;
                BodyRes = skipped(Why),
                Result = skipped(Why)
            )
        ;
            JoinRes = skipped(Why2),
            Result = skipped(Why2)
        )
    else
        Result = skipped("no `CallError` schema, or no response schema with "
            ++ "a `corr` slot, for a `timeout` sibling")
    ).

    % Two rules per `timeout` clause, `$<outer>_timeout_<N>_answered` and
    % `_failed`: the clause's timer joined on its own `corr` with the response
    % schema or with `CallError`, retracting the timer and nothing else. So no
    % `timeout` body runs once the call is answered, whether or not an `on` or
    % `error` clause matched. Neither releases the capture fact, which an `on`
    % or `error` sibling of the same answer joins. A literal correlation is
    % also tested at the timer.
    %
    %@spec [LCCO.7.6]
:- pred lcco_7_6_discharge(resolved_file::in, list(schema)::in, string::in,
                           continued_call::in, int::in, expr::in, pos::in,
                           lowered(unit)::out, build::in, build::out,
                           intern_table::in, intern_table::out) is det.

lcco_7_6_discharge(RF, Schemas, Rule, Call, N, CorrLit, Pos, Result, !B,
        !IT) :-
    intern(timeout_timer_name(Rule, N), TimerRef, !IT),
    ( if
        schema_named(!.IT, Schemas, "CallError", Error),
        response_schema(RF, !.IT, Schemas, Call, Response, RespIx)
    then
        Base = "$" ++ Rule ++ "_timeout_" ++ string.from_int(N),
        discharge_rule(TimerRef, Call, CorrLit, Response ^ s_name, RespIx,
            Base ++ "_answered", Pos, !B, !IT),
        discharge_rule(TimerRef, Call, CorrLit, Error ^ s_name, det_slot(0),
            Base ++ "_failed", Pos, !B, !IT),
        Result = done(unit)
    else
        Result = skipped("no `CallError` schema, or no response schema with "
            ++ "a `corr` slot, for a `timeout`'s discharge rules")
    ).

    % One discharge rule: the timer, then the answer on `corr`, and the
    % timer's retraction.
    %
    %@helper
:- pred discharge_rule(intern_ref::in, continued_call::in, expr::in,
                       schema_name::in, slot_index::in, string::in, pos::in,
                       build::in, build::out,
                       intern_table::in, intern_table::out) is det.

discharge_rule(TimerRef, Call, CorrLit, Answer, AnswerCorrIx, Name, Pos, !B,
        !IT) :-
    alpha_for(make_schema_name(TimerRef), [], TimerAlpha, !B),
    alpha_for(Answer, [], AnswerAlpha, !B),
    ( if constant_corr(Call) then
        TimerTests = [e_binop(op_eq, e_slot(candidate, slot(det_slot(1))),
            CorrLit)]
    else
        TimerTests = []
    ),
    TimerB = !.B ^ bd_next,
    JoinB = TimerB + 1u32,
    !:B = (!.B ^ bd_next := TimerB + 2u32)
        ^ bd_betas := [
            raw_beta(det_node_id(JoinB), AnswerAlpha, TimerB,
                [e_binop(op_eq, e_slot(candidate, slot(AnswerCorrIx)),
                    e_slot(token_fact(0), slot(det_slot(1))))], no),
            raw_beta(det_node_id(TimerB), TimerAlpha, 0u32, TimerTests, no)
            | !.B ^ bd_betas],
    push_sibling(Name, JoinB, no, 0,
        [ia_internal(fn_retract_token_fact, [e_lit(int(0i64))])], Pos, !B,
        !IT).

    %@helper
:- pred push_sibling(string::in, uint32::in, maybe(expr)::in, int::in,
                     list(inline_action)::in, pos::in,
                     build::in, build::out,
                     intern_table::in, intern_table::out) is det.

push_sibling(Name, Parent, Guard, Binds, Actions, Pos, !B, !IT) :-
    intern(Name, NameRef, !IT),
    TermId = !.B ^ bd_next,
    Term = raw_terminal(det_node_id(TermId), Parent, NameRef, Binds, Guard,
        list.length(Actions), Actions),
    !:B = ((!.B ^ bd_next := TermId + 1u32)
        ^ bd_terms := [Term | !.B ^ bd_terms])
        ^ bd_groups := [rule_group(Name, no, Pos, "") | !.B ^ bd_groups].

%-----------------------------------------------------------------------------%
% `let` -- [RLOW.4.5], [LGRA.9.8.4]
%-----------------------------------------------------------------------------%

    % A `let` name as the expressions after it see it.
    %
    %@helper
:- type let_def
    --->    let_inline(string, lgra_9_3_1_expr)
            % Pure: its expression is lowered again at every use site.
    ;       let_bound(string, bind_index)
            % Sync-impure: evaluated once into the bind frame.
    ;       let_lowered(string, expr)
            % A `unit formula`'s parameter while its body is lowered at a call
            % site ([LGRA.9.8.11]): the argument, lowered in the caller's scope.
    ;       let_capture(string, lgra_9_3_1_expr, string, string, int).
            % [LREG.4.1]'s capture: name, the match's subject, pattern, flags
            % and the 1-based group.

    %@helper
:- func let_bindings(ast_let_decl) = list(ast_let_binding).

let_bindings(D) = D ^ ald_bindings.

    %@helper
:- func bound_count(list(ast_let_binding)) = int.

bound_count(Lets) = list.length(list.filter(is_bound_let, Lets)).

    %@helper
:- pred is_bound_let(ast_let_binding::in) is semidet.

is_bound_let(alb_simple(_, _, E, _)) :-
    sync_impure_call(E).

    % [LGRA.9.8.4]'s sync-impure tier: the whole right-hand side is a call of a
    % sync-impure builtin at one of its arities.
    %
    %@helper
:- pred sync_impure_call(lgra_9_3_1_expr::in) is semidet.

sync_impure_call(ex_call(ex_name(Fn), Args, _)) :-
    lgra_9_8_4_sync_impure(Fn ^ id_name, Arities),
    list.member(list.length(Args), Arities).

    % The rule's `let`s, in source order: each pure one becomes a definition
    % inlined at its uses ([RLOW.4.5.2.1]), each sync-impure one a BIND action
    % at the head of the RHS and a BIND_REF at its uses ([RLOW.4.5.3.1]). A `let`
    % sees only the `let`s before it ([LLET.10.1]).
    %
    %@spec [RLOW.4.5.1]
    %@spec [RLOW.4.5.2.1]
    %@spec [RLOW.4.5.3.1]
:- pred rlow_4_5_1_lets(resolved_file::in, maybe(type_env)::in, list(pat)::in,
                        list(ast_let_binding)::in, int::in,
                        int::in, list(let_def)::in, list(inline_action)::in,
                        lowered({list(let_def), list(inline_action)})::out,
                        intern_table::in, intern_table::out) is det.

rlow_4_5_1_lets(_, _, _, [], _, _, Defs, Binds,
        done({Defs, list.reverse(Binds)}), !IT).
rlow_4_5_1_lets(RF, Env, Pats, [L | Ls], Total, Next, Defs, Binds, Result,
        !IT) :-
    (
        L = alb_capture(_, _, _),
        Result = skipped("a capture `let` is refused ([LREG.4.1])")
    ;
        L = alb_simple(Id, Annotation, E, _),
        Name = Id ^ id_name,
        ( if sync_impure_call(E) then
            rlow_6_1_1_expr(ctx(RF, Pats, no, Defs, Env), E, CallRes, !IT),
            ( if
                CallRes = done(Call),
                bind_index(Total, Next, Ix)
            then
                rlow_4_5_1_lets(RF, Env, Pats, Ls, Total, Next + 1,
                    Defs ++ [let_bound(Name, Ix)], [ia_bind(Ix, Call) | Binds],
                    Result, !IT)
            else if CallRes = skipped(Why) then
                Result = skipped(Why)
            else
                unexpected($pred, "a bind index is counted before it is used")
            )
        else
            Value = luni_4_5_1_let_value(RF, Env, Annotation, E),
            rlow_4_5_1_lets(RF, Env, Pats, Ls, Total, Next,
                Defs ++ [let_inline(Name, Value)], Binds, Result, !IT)
        )
    ).

    % A typed `let`'s value, at [LUNI.4.5.1]'s assignment boundary 1: when the
    % annotation is a unit whose dimension is not the value's, and exactly one
    % `implicit` formula converts the value's to the annotation's, that formula's
    % call. Otherwise the value as written.
    %
    %@spec [LUNI.4.5.1]
:- func luni_4_5_1_let_value(resolved_file, maybe(type_env),
                             maybe(ast_annotation), lgra_9_3_1_expr)
    = lgra_9_3_1_expr.

luni_4_5_1_let_value(RF, MaybeEnv, Annotation, E) = Value :-
    ( if
        Annotation = yes(Ann),
        MaybeEnv = yes(Env),
        map.search(RF ^ rf_types, Ann ^ aan_type ^ id_name,
            te_unit(uk_symbol(TargetDim), _)),
        type_of_expr(Env ^ te_ambiguity := da_annotated, E) = ty_known(VType),
        VType ^ dt_dim = dim(SourceDim, _),
        SourceDim \= TargetDim,
        luni_4_5_implicit_line(RF, SourceDim, TargetDim, Line)
    then
        Value = formula_call_of(Line, E)
    else
        Value = E
    ).

    %@helper
:- func formula_call_of(ast_formula_line, lgra_9_3_1_expr) = lgra_9_3_1_expr.

formula_call_of(Line, E) =
    ex_call(ex_name(Line ^ afl_name), [E], expr_start(E)).

    % A `let` by name, with the definitions before it -- the scope its own
    % expression is lowered in.
    %
    %@helper
:- pred let_named(list(let_def)::in, string::in, list(let_def)::in,
                  let_def::out, list(let_def)::out) is semidet.

let_named([D | Ds], Name, Before, Found, Scope) :-
    ( if
        ( D = let_inline(Name, _)
        ; D = let_bound(Name, _)
        ; D = let_lowered(Name, _)
        ; D = let_capture(Name, _, _, _, _)
        )
    then
        Found = D,
        Scope = list.reverse(Before)
    else
        let_named(Ds, Name, [D | Before], Found, Scope)
    ).

    % [LREG.4.1]'s capture list as definitions, group N for the Nth name.
    %
    %@spec [LREG.4.1]
    %@spec [LREG.4.2]
:- func lreg_4_1_capture_defs(maybe(ast_capture)) = list(let_def).

lreg_4_1_capture_defs(no) = [].
lreg_4_1_capture_defs(yes(ast_capture(Names, Match, _))) = Defs :-
    ( if Match = ex_match(Subject, ms_match, Pattern, Flags, _) then
        list.map_foldl(
            (pred(Id::in, D::out, G0::in, G::out) is det :-
                D = let_capture(Id ^ id_name, Subject, Pattern, Flags, G0),
                G = G0 + 1),
            Names, Defs, 1, _)
    else
        Defs = []
    ).

    %@helper
:- func all_captures(list(pat)) = list(let_def).

all_captures(Pats) = list.condense(list.map((func(P) = P ^ pt_captures), Pats)).

    % The captures pattern K's `where` may read: its own and every earlier
    % pattern's ([LGRA.8.6]'s ladder).
    %
    %@helper
:- func captures_through(list(pat), int) = list(let_def).

captures_through(Pats, K) = all_captures(list.take_upto(K + 1, Pats)).

    % One read of a capture. The subject is lowered where the capture is read:
    % every position that may read it has the capture's own pattern in scope.
    %
    %@spec [LREG.4.1]
    %@spec [LREG.4.4]
    %@spec [LREG.4.7]
:- pred lreg_4_1_capture_expr(ctx::in, lgra_9_3_1_expr::in, string::in,
                              string::in, int::in, lowered(expr)::out,
                              intern_table::in, intern_table::out) is det.

lreg_4_1_capture_expr(Ctx, Subject, Pattern, Flags, Group, Result, !IT) :-
    rlow_6_1_1_expr(Ctx, Subject, SubjectRes, !IT),
    (
        SubjectRes = done(SubjectE),
        intern(Pattern, PatternRef, !IT),
        intern(Flags, FlagsRef, !IT),
        Result = done(e_call(fn_regex_capture,
            [SubjectE, e_lit(str(PatternRef)), e_lit(str(FlagsRef)),
                e_lit(int(int64.from_int(Group)))]))
    ;
        SubjectRes = skipped(Why),
        Result = skipped(Why)
    ).

%-----------------------------------------------------------------------------%
% Patterns -- [RLOW.5.1], [RLOW.5.5]
%-----------------------------------------------------------------------------%

    % One pattern, resolved against the artefact's schemas.
    %
    %@helper
:- type pat
    --->    pat(
                pt_binding :: string,
                pt_schema  :: schema,
                pt_negated :: bool,
                pt_token   :: int,
                    % The fact's position in the activation token. A negated
                    % pattern contributes no fact, so the positions skip it.
                pt_where   :: maybe(lgra_9_3_1_expr),
                pt_within  :: maybe(uint64),
                pt_latest  :: bool,
                    % `latest` on a sequence's anchor ([RLOW.5.6.5.2]).
                pt_follows :: maybe({int, uint64}),
                    % A `then` step: the source index of the positive pattern
                    % it follows, and the step's window ([RLOW.5.6.1]).
                pt_captures :: list(let_def),
                    % [LREG.4.1]'s captures from this pattern's `where`. A `where`
                    % sees those of its own pattern and every earlier one; the
                    % RHS sees them all.
                pt_pos     :: maybe(pos)
                    % For the beta's LineSpan atom ([RDSC.14.3.6]); `no` for a
                    % synthetic pattern.
            ).

    % A pattern as the LHS writes it, before resolution: its body, whether it
    % is negated, whether it is a sequence anchor under `latest`, and a
    % `then` step's window tokens.
    %
    %@helper
:- type pat_spec
    --->    pat_spec(
                ps_body    :: ast_pattern_body,
                ps_negated :: bool,
                ps_latest  :: bool,
                ps_window  :: maybe(list(positioned))
            ).

    % The LHS as a flat list of patterns, a `then` sequence unrolled into its
    % anchor and one pattern per step.
    %
    %@helper
:- pred pat_specs(list(ast_lhs_clause)::in, list(pat_spec)::in,
                  lowered(list(pat_spec))::out) is det.

pat_specs([], Acc, done(list.reverse(Acc))).
pat_specs([C | Cs], Acc, Result) :-
    (
        C = alc_then(_),
        Result = skipped("a `then` step with no pattern before it")
    ;
        C = alc_pattern(P),
        (
            P = ap_simple(Body),
            pat_specs(Cs, [pat_spec(Body, no, no, no) | Acc], Result)
        ;
            P = ap_negated(Body, _),
            pat_specs(Cs, [pat_spec(Body, yes, no, no) | Acc], Result)
        ;
            P = ap_sequence(Latest, Head, Steps, _),
            Anchor = pat_spec(Head, no,
                ( if Latest = asl_latest then yes else no ), no),
            StepSpecs = list.map((func(S) = pat_spec(S ^ ats_body, no, no,
                yes(S ^ ats_within))), Steps),
            pat_specs(Cs, list.reverse(StepSpecs) ++ [Anchor | Acc], Result)
        )
    ).

    % An omitted binding gets the synthetic name `$<rule>_pat<N>`, N the
    % pattern's source index over every pattern, negated included.
    %
    %@spec [RLOW.9.2.1]
:- pred rlow_9_2_1_patterns(resolved_file::in, string::in, list(schema)::in,
                            intern_table::in,
                            list(ast_lhs_clause)::in, int::in, int::in,
                            lowered(list(pat))::out) is det.

rlow_9_2_1_patterns(RF, Rule, Schemas, IT, Clauses, _, _, Result) :-
    pat_specs(Clauses, [], SpecsRes),
    (
        SpecsRes = done(Specs),
        spec_pats(RF, Rule, Schemas, IT, Specs, 0, 0, no, Result)
    ;
        SpecsRes = skipped(Why),
        Result = skipped(Why)
    ).

    %@helper
:- pred spec_pats(resolved_file::in, string::in, list(schema)::in,
                  intern_table::in,
                  list(pat_spec)::in, int::in, int::in, maybe(int)::in,
                  lowered(list(pat))::out) is det.

spec_pats(_, _, _, _, [], _, _, _, done([])).
spec_pats(RF, Rule, Schemas, IT, [Spec | Specs], Index, Token, LastPositive,
        Result) :-
    Body = Spec ^ ps_body,
    Negated = Spec ^ ps_negated,
    Window = Spec ^ ps_window,
    WithinToks = Body ^ apb_within,
    ( if WithinToks = yes(Toks), not duration_tokens_ns(RF, Toks, _) then
        Result = skipped("a `within` whose duration is neither a duration "
            ++ "literal nor a `time` const")
    else if
        Window = yes(WinToks),
        not ( duration_tokens_ns(RF, WinToks, _), LastPositive = yes(_) )
    then
        Result = skipped("a `then` step whose window or predecessor this "
            ++ "compiler cannot read")
    else if head_schema_name(RF, Body ^ apb_type, HeadName) then
        ( if schema_named(IT, Schemas, HeadName, Schema) then
            (
                Body ^ apb_binding = yes(Id),
                Binding = Id ^ id_name
            ;
                Body ^ apb_binding = no,
                Binding = "$" ++ Rule ++ "_pat" ++ string.from_int(Index)
            ),
            (
                Negated = yes,
                Position = -1,
                NextToken = Token
            ;
                Negated = no,
                Position = Token,
                NextToken = Token + 1
            ),
            ( if WithinToks = yes(Toks2), duration_tokens_ns(RF, Toks2, Ns)
            then
                Within = yes(Ns)
            else
                Within = no
            ),
            ( if
                Window = yes(WinToks2),
                duration_tokens_ns(RF, WinToks2, WinNs),
                LastPositive = yes(From)
            then
                Follows = yes({From, WinNs})
            else
                Follows = no
            ),
            Pat = pat(Binding, Schema, Negated, Position, Body ^ apb_where,
                Within, Spec ^ ps_latest, Follows,
                lreg_4_1_capture_defs(Body ^ apb_capture),
                yes(Body ^ apb_pos)),
            NextPositive = ( if Negated = no then yes(Index)
                else LastPositive ),
            spec_pats(RF, Rule, Schemas, IT, Specs, Index + 1, NextToken,
                NextPositive, RestRes),
            (
                RestRes = done(Pats),
                Result = done([Pat | Pats])
            ;
                RestRes = skipped(Why),
                Result = skipped(Why)
            )
        else
            Result = skipped("the schema `" ++ HeadName
                ++ "` is not in this artefact")
        )
    else
        Result = skipped("a pattern head naming no schema")
    ).

    % The schema a pattern head names, by the name the artefact carries it under:
    % the library's own declaration, whatever the importer called it
    % ([LIMP.4.1.1]).
    %
    %@helper
:- pred head_schema_name(resolved_file::in, ast_type_ref::in, string::out)
    is semidet.

head_schema_name(RF, atr_bare(Head), Name) :-
    ( if map.search(RF ^ rf_types, Head ^ id_name, te_schema(Declared)) then
        Name = Declared ^ as_own
    else
        Name = Head ^ id_name
    ).
head_schema_name(RF, atr_qualified(Lib, Head), Name) :-
    Key = string.join_list(".", list.map((func(I) = I ^ id_name), Lib))
        ++ ";" ++ Head ^ id_name,
    ( if map.search(RF ^ rf_qualified_schemas, Key, Declared) then
        Name = Declared ^ as_own
    else
        Name = Head ^ id_name
    ).

    % The artefact schema an `emit` / `publish` / `record_event` names.
    %
    %@helper
:- pred action_schema(ctx::in, intern_table::in, list(schema)::in,
                      ast_type_ref::in, schema::out) is semidet.

action_schema(Ctx, IT, Schemas, Ref, Schema) :-
    head_schema_name(Ctx ^ cx_rf, Ref, Name),
    schema_named(IT, Schemas, Name, Schema).

    %@helper
:- pred schema_named(intern_table::in, list(schema)::in, string::in,
                     schema::out) is semidet.

schema_named(IT, [S | Ss], Name, Found) :-
    ( if expand(IT, schema_name_ref(S ^ s_name), Name) then
        Found = S
    else
        schema_named(IT, Ss, Name, Found)
    ).

    % The beta chain, one beta per pattern, left parent the previous beta.
    % Returns the last beta's id, which the terminal hangs off.
    %
    %@spec [RLOW.5.1]
    %@spec [RLOW.5.3]
    %@spec [RLOW.5.5]
    %@spec [RDSC.4a.6]
    %@spec [RDSC.4a.7]
:- pred rlow_5_1_chain(resolved_file::in, maybe(type_env)::in, list(pat)::in,
                       maybe(int)::in, list(pat)::in, int::in, uint32::in,
                       build::in, build::out,
                       intern_table::in, intern_table::out,
                       lowered(uint32)::out) is det.

rlow_5_1_chain(_, _, _, _, [], _, Prev, !B, !IT, Result) :-
    ( if Prev = 0u32 then
        Result = skipped("a rule with no pattern is not lowered")
    else
        Result = done(Prev)
    ).
rlow_5_1_chain(RF, Env, All, TickBefore, [P | Ps], K, Prev0, !B, !IT,
        Result) :-
    Where = P ^ pt_where,
    (
        Where = no,
        WhereRes = done({[], []})
    ;
        Where = yes(W),
        rlow_6_1_1_expr(ctx(RF, All, yes(K), captures_through(All, K), Env),
            W, ExprRes, !IT),
        (
            ExprRes = done(E),
            WhereRes = done(rlow_5_2_1_split_alpha(
                alpha_scope_of(RF, P ^ pt_schema, !.IT), E))
        ;
            ExprRes = skipped(Why),
            WhereRes = skipped(Why)
        )
    ),
    (
        WhereRes = skipped(Why2),
        Result = skipped(Why2)
    ;
        WhereRes = done({Tests, Join0}),
        rlow_5_4_1_within(P, Within),
        Join = Within ++ rlow_5_6_1_follows(!.IT, All, P) ++ Join0,
        alpha_for(P ^ pt_schema ^ s_name, Tests, AlphaId, !B),
        within_tick(TickBefore, K, P, Ps, Prev0, Prev, !B, !IT),
        BetaId = !.B ^ bd_next,
        Beta = raw_beta(det_node_id(BetaId), AlphaId, Prev, Join,
            P ^ pt_negated),
        !:B = (((!.B ^ bd_next := BetaId + 1u32)
            ^ bd_betas := [Beta | !.B ^ bd_betas])
            ^ bd_spans := rdsc_14_3_6_span(BetaId, P ^ pt_pos,
                !.B ^ bd_spans)),
        iret_7_10_2_latest(RF, Env, All, K, P, BetaId, Tail, !B, !IT),
        (
            Tail = done(NextPrev),
            rlow_5_1_chain(RF, Env, All, TickBefore, Ps, K + 1, NextPrev,
                !B, !IT, Result)
        ;
            Tail = skipped(TailWhy),
            Result = skipped(TailWhy)
        )
    ).

    % `within <dur>` as the join test `(monotonic_ns() - entry_stamp(cand)) <
    % window_ns`, first on the beta, before the pattern's residual `where`.
    %
    %@spec [RLOW.5.4.1]
    %@spec [LTIM.2.7.1]
:- pred rlow_5_4_1_within(pat::in, list(expr)::out) is det.

rlow_5_4_1_within(P, Tests) :-
    ( if P ^ pt_within = yes(Ns) then
        Tests = [ltim_2_7_1_window(candidate, Ns)]
    else
        Tests = []
    ).

    % The window test on the fact `Fact` names: the join's candidate on a beta, or
    % its token position in a fire guard.
    %
    %@spec [LTIM.2.7.1]
:- func ltim_2_7_1_window(fact_index, uint64) = expr.

ltim_2_7_1_window(Fact, Ns) =
    e_binop(op_lt,
        e_binop(op_sub, ltim_2_2_1_monotonic_ns, e_entry_stamp(Fact)),
        e_lit(int(int64.cast_from_uint64(Ns)))).

    %@spec [LTIM.2.2.1]
:- func ltim_2_2_1_monotonic_ns = expr.

ltim_2_2_1_monotonic_ns = e_call(fn_monotonic_ns, []).

    % A `then` step's join test: the candidate strictly after its predecessor,
    % and no later than the window ([RLOW.5.6.1]) --
    %
    %     (cand.ts > from.ts) and ((cand.ts - from.ts) < window_ns)
    %
    %@spec [RLOW.5.6.1]
    %@spec [RLOW.5.6.2]
    %@spec [RLOW.5.6.3]
    %@spec [RLOW.5.6.5.5]
    %@spec [LTHE.4.3]
    %@spec [LTHE.5.2]
:- func rlow_5_6_1_follows(intern_table, list(pat), pat) = list(expr).

rlow_5_6_1_follows(IT, All, P) = Tests :-
    ( if
        P ^ pt_follows = yes({FromK, Ns}),
        list.index0(All, FromK, From),
        ts_index(IT, P ^ pt_schema, ThisTs),
        ts_index(IT, From ^ pt_schema, FromTs)
    then
        Cand = e_slot(candidate, slot(ThisTs)),
        Prior = e_slot(token_fact(From ^ pt_token), slot(FromTs)),
        Tests = [e_binop(op_and,
            e_binop(op_gt, Cand, Prior),
            e_binop(op_lt, e_binop(op_sub, Cand, Prior),
                e_lit(int(int64.cast_from_uint64(Ns)))))]
    else
        Tests = []
    ).

    %@helper
:- pred ts_index(intern_table::in, schema::in, slot_index::out) is semidet.

ts_index(IT, Schema, Ix) :-
    interned(IT, "ts", Ref),
    slot_by_name(Schema, Ref, Common),
    Ix = Common ^ sc_index.

    % [LCRS.4.3.2] leaves the slot's position to the author.
    %
    %@helper
:- pred corr_index(intern_table::in, schema::in, slot_index::out) is semidet.

corr_index(IT, Schema, Ix) :-
    interned(IT, "corr", Ref),
    slot_by_name(Schema, Ref, Common),
    Ix = Common ^ sc_index.

    % `latest` on a sequence anchor: a NOT beta after the sequence's last join,
    % where the anchor `d` and every follower are on the token, over the anchor's
    % alpha. Its candidate `f` is another fact of the anchor's schema, and the NOT
    % blocks the match when `f` would itself complete the sequence with the same
    % followers ([LTHE.2.5.3]). With `m` the first follower:
    %
    %     d.ts < f.ts,   f.ts < m.ts,   m.ts - f.ts < T,
    %     f passes the anchor's `where` (and its `within`),
    %     f passes the first follower's `where`, with `f` in `d`'s place,
    %     f passes each later follower's `where` that reads the anchor,
    %       with `f` in `d`'s place.
    %
    % A later `where` that does not read the anchor holds of the token whichever
    % anchor is in place, so it is left out of the test.
    %
    % Each follower's `where` is compiled with the anchor moved after it
    % (`swap_anchor`): `f` stands in for the anchor as the candidate, and the
    % followers are on the token.
    %
    %@spec [IRET.7.10.2]
    %@spec [LTHE.2.5.3]
    %@spec [LTHE.4.3]
    %@spec [LTHE.5.1]
:- pred iret_7_10_2_latest(resolved_file::in, maybe(type_env)::in,
                           list(pat)::in, int::in, pat::in,
                           uint32::in, lowered(uint32)::out,
                           build::in, build::out,
                           intern_table::in, intern_table::out) is det.

iret_7_10_2_latest(RF, Env, All, K, P, BetaId, Result, !B, !IT) :-
    ( if
        P ^ pt_follows = yes(_),
        chain_start(All, K, AK),
        AK < K,
        list.index0(All, AK, Anchor),
        Anchor ^ pt_latest = yes,
        chain_end(All, K) = K
    then
        ( if
            list.index0(All, AK + 1, First),
            First ^ pt_follows = yes({AK, Ns}),
            ts_index(!.IT, Anchor ^ pt_schema, ATs),
            ts_index(!.IT, First ^ pt_schema, MTs)
        then
            latest_guard(RF, Env, All, AK, Anchor, First, K, ATs, MTs, Ns,
                GuardRes, !IT),
            (
                GuardRes = done({AlphaTests, Join}),
                alpha_for(Anchor ^ pt_schema ^ s_name, AlphaTests, AlphaId,
                    !B),
                GuardId = !.B ^ bd_next,
                NotBeta = raw_beta(det_node_id(GuardId), AlphaId, BetaId,
                    Join, yes),
                !:B = (!.B ^ bd_next := GuardId + 1u32)
                    ^ bd_betas := [NotBeta | !.B ^ bd_betas],
                Result = done(GuardId)
            ;
                GuardRes = skipped(Why),
                Result = skipped(Why)
            )
        else
            Result = skipped("a `latest` anchor whose first follower or `ts` "
                ++ "this compiler cannot read")
        )
    else
        Result = done(BetaId)
    ).

    % The NOT's alpha tests and join test, or why it cannot be built. `First`
    % is the first follower, and `LastK` the index of the sequence's last
    % step, after whose join the NOT hangs.
    %
    %@helper
:- pred latest_guard(resolved_file::in, maybe(type_env)::in, list(pat)::in,
                     int::in, pat::in, pat::in, int::in,
                     slot_index::in, slot_index::in, uint64::in,
                     lowered({list(alpha_test), list(expr)})::out,
                     intern_table::in, intern_table::out) is det.

latest_guard(RF, Env, All, AK, Anchor, First, LastK, ATs, MTs, Ns, Result,
        !IT) :-
    F = e_slot(candidate, slot(ATs)),
    D = e_slot(token_fact(Anchor ^ pt_token), slot(ATs)),
    M = e_slot(token_fact(First ^ pt_token), slot(MTs)),
    Times = [e_binop(op_gt, F, D), e_binop(op_gt, M, F),
        e_binop(op_lt, e_binop(op_sub, M, F),
            e_lit(int(int64.cast_from_uint64(Ns))))],
    rlow_5_4_1_within(Anchor, AnchorWithin),
    maybe_where(ctx(RF, All, yes(AK), captures_through(All, AK), Env),
        Anchor ^ pt_where, AnchorRes, !IT),
    follower_wheres(RF, Env, All, Anchor, AK, AK + 1, LastK, FollowerRes,
        !IT),
    ( if
        AnchorRes = done(AnchorWhere),
        FollowerRes = done(FollowerWhere)
    then
        (
            AnchorWhere = [],
            AlphaTests = [],
            AnchorJoin = []
        ;
            AnchorWhere = [AW | _],
            {AlphaTests, AnchorJoin} = rlow_5_2_1_split_alpha(
                alpha_scope_of(RF, Anchor ^ pt_schema, !.IT), AW)
        ),
        Result = done({AlphaTests,
            AnchorWithin ++ Times ++ AnchorJoin ++ FollowerWhere})
    else if AnchorRes = skipped(Why) then
        Result = skipped(Why)
    else if FollowerRes = skipped(Why) then
        Result = skipped(Why)
    else
        unexpected($pred, "both `where`s lowered and neither did")
    ).

    % The followers' `where`s from index `I` to `LastK`, each compiled with the
    % anchor as the candidate: the first follower's always, a later step's only
    % when it reads the anchor.
    %
    %@helper
:- pred follower_wheres(resolved_file::in, maybe(type_env)::in,
                        list(pat)::in, pat::in, int::in, int::in, int::in,
                        lowered(list(expr))::out,
                        intern_table::in, intern_table::out) is det.

follower_wheres(RF, Env, All, Anchor, AK, I, LastK, Result, !IT) :-
    ( if I > LastK then
        Result = done([])
    else if list.index0(All, I, Q) then
        ( if
            ( I = AK + 1
            ; step_reads_anchor(RF, All, Anchor, I, !.IT)
            )
        then
            Swapped = swap_anchor(All, AK, I),
            maybe_where(ctx(RF, Swapped, yes(I), captures_through(Swapped, I),
                Env), Q ^ pt_where, QRes, !IT)
        else
            QRes = done([])
        ),
        follower_wheres(RF, Env, All, Anchor, AK, I + 1, LastK, RestRes,
            !IT),
        ( if
            QRes = done(QWhere),
            RestRes = done(RestWhere)
        then
            Result = done(QWhere ++ RestWhere)
        else if QRes = skipped(Why) then
            Result = skipped(Why)
        else if RestRes = skipped(Why) then
            Result = skipped(Why)
        else
            unexpected($pred, "both lowered and neither did")
        )
    else
        unexpected($pred, "a sequence step past the pattern list")
    ).

    %@helper
:- pred maybe_where(ctx::in, maybe(lgra_9_3_1_expr)::in,
                    lowered(list(expr))::out,
                    intern_table::in, intern_table::out) is det.

maybe_where(_, no, done([]), !IT).
maybe_where(Ctx, yes(W), Result, !IT) :-
    rlow_6_1_1_expr(Ctx, W, Res, !IT),
    (
        Res = done(E),
        Result = done([E])
    ;
        Res = skipped(Why),
        Result = skipped(Why)
    ).

    % `All` with the anchor at `AK` moved to just after the step at `I`, so
    % that the anchor -- now at index `I` -- is the candidate of a context
    % whose `cx_right` is `I`, and the step and every pattern before it read
    % from the token.
    %
    %@helper
:- func swap_anchor(list(pat), int, int) = list(pat).

swap_anchor(All, AK, I) = Swapped :-
    ( if
        I > AK,
        list.split_list(AK, All, Before, [Anchor | After0]),
        list.split_list(I - AK, After0, Mid, Rest)
    then
        Swapped = Before ++ Mid ++ [Anchor | Rest]
    else
        unexpected($pred, "no step after the anchor at that index")
    ).

    % The index of the sequence's first pattern, walking `then` steps back
    % from `K`: the anchor, when `K` is in a sequence.
    %
    %@helper
:- pred chain_start(list(pat)::in, int::in, int::out) is det.

chain_start(All, K, Start) :-
    ( if
        list.index0(All, K, Q),
        Q ^ pt_follows = yes({From, _}),
        From < K
    then
        chain_start(All, From, Start)
    else
        Start = K
    ).

    % The index of the sequence's last step, walking forward from `K` while
    % the next pattern follows this one.
    %
    %@helper
:- func chain_end(list(pat), int) = int.

chain_end(All, K) = End :-
    ( if
        list.index0(All, K + 1, Q),
        Q ^ pt_follows = yes({K, _})
    then
        End = chain_end(All, K + 1)
    else
        End = K
    ).

    % Whether the `then` step at index `I` has a `where` that reads the anchor's
    % token position, read off the lowered test.
    %
    %@helper
:- pred step_reads_anchor(resolved_file::in, list(pat)::in, pat::in, int::in,
                          intern_table::in) is semidet.

step_reads_anchor(RF, All, Anchor, I, IT) :-
    list.index0(All, I, Q),
    Q ^ pt_where = yes(W),
    rlow_6_1_1_expr(ctx(RF, All, yes(I), captures_through(All, I), no),
        W, done(E), IT, _),
    reads_fact(token_fact(Anchor ^ pt_token), E).

    %@helper
:- pred reads_fact(fact_index::in, expr::in) is semidet.

reads_fact(Fact, E) :-
    (
        E = e_slot(Fact, _)
    ;
        E = e_slot_named(Fact, _)
    ;
        E = e_json_path(Fact, _)
    ;
        E = e_entry_stamp(Fact)
    ;
        E = e_agg(Spec),
        Spec ^ ag_id_fact = Fact
    ;
        list.member(Child, expr_children(E)),
        reads_fact(Fact, Child)
    ).

    % [IRET.6.6]: one alpha per (schema, tests), allocated on first use.
    %
    %@helper
:- pred alpha_for(schema_name::in, list(alpha_test)::in, uint32::out,
                  build::in, build::out) is det.

alpha_for(Schema, Tests, Id, !B) :-
    ( if assoc_list.search(!.B ^ bd_shared, {Schema, Tests}, Found) then
        Id = Found
    else
        Id = !.B ^ bd_next,
        Alpha = raw_alpha(det_node_id(Id), Schema, Tests),
        !:B = ((!.B ^ bd_next := Id + 1u32)
            ^ bd_alphas := [Alpha | !.B ^ bd_alphas])
            ^ bd_shared := [{Schema, Tests} - Id | !.B ^ bd_shared]
    ).

    % The slots whose comparison against a literal stays in the join test
    % ([IRET.6.4]): nullable ones, since `null` is Kleene and an alpha test is
    % two-valued, and `Json` ones, whose comparison can raise.
    %
    %@helper
:- func undecided_slots(schema) = list(slot_index).

undecided_slots(S) = list.filter_map(undecided_index, slot_commons(S)).

    %@helper
:- func undecided_index(slot_common) = slot_index is semidet.

undecided_index(C) = C ^ sc_index :-
    ( C ^ sc_nullable = nullable
    ; C ^ sc_kind = k_json
    ).

    % What a pattern's `where` may hoist onto its alpha node, read once per
    % pattern: the slots a comparison cannot be decided on (RLOW.5.2.1), the
    % slots a `~` may be hoisted on (RLOW.5.2.2), and the intern table that
    % reads a hoisted regex's pattern and flags back.
    %
    %@helper
:- type alpha_scope
    --->    alpha_scope(
                as_undecided :: list(slot_index),
                as_regex     :: list(slot_index),
                as_interns   :: intern_table
            ).

    %@helper
:- func alpha_scope_of(resolved_file, schema, intern_table) = alpha_scope.

alpha_scope_of(RF, S, IT) =
    alpha_scope(undecided_slots(S), rlow_5_2_2_regex_slots(RF, S), IT).

    % The slots a `s.x ~ /p/f` conjunct may become an alpha regex test on: a
    % non-nullable `String` ([IRET.6.4]), with a declared `capacity` under
    % `linear_scan: false` ([IRET.6.2.1]).
    %
    %@spec [RLOW.5.2.2]
:- func rlow_5_2_2_regex_slots(resolved_file, schema) = list(slot_index).

rlow_5_2_2_regex_slots(RF, S) = Slots :-
    Bounded = ( if not enabled(RF ^ rf_program, cap_linear_scan)
                then yes else no ),
    list.filter_map(regex_index(Bounded), slot_commons(S), Slots).

    %@helper
:- pred regex_index(bool::in, slot_common::in, slot_index::out) is semidet.

regex_index(Bounded, C, Ix) :-
    Ix = C ^ sc_index,
    C ^ sc_kind = k_string,
    C ^ sc_nullable = non_null,
    ( Bounded = no
    ; C ^ sc_capacity = at_most(_)
    ).

    % A lowered `where`, split into alpha tests and the residual join tests.
    %
    % Admits `<candidate slot> <cmp> <literal>`, either operand order, and
    % [RLOW.5.2.2]'s `~`, out of a top-level `and` chain. The residual is the
    % original expression when nothing hoists, and rebuilt left-nested otherwise.
    %
    %@spec [RLOW.5.2.1]
:- func rlow_5_2_1_split_alpha(alpha_scope, expr)
    = {list(alpha_test), list(expr)}.

rlow_5_2_1_split_alpha(Scope, E) = {Tests, Join} :-
    Conjuncts = and_conjuncts(E),
    list.foldl2(classify_conjunct(Scope), Conjuncts, [], RevTests,
        [], RevRest),
    Tests = list.reverse(RevTests),
    Rest = list.reverse(RevRest),
    ( if Tests = [] then
        Join = [E]
    else if Rest = [First | More] then
        Rebuilt = list.foldl((func(Next, Acc) = e_binop(op_and, Acc, Next)),
            More, First),
        % [IRET.9.6]: an operation with a tainted operand is tainted.
        ( if list.member(Part, Rest), Part = e_tainted(_) then
            Join = [e_tainted(Rebuilt)]
        else
            Join = [Rebuilt]
        )
    else
        Join = []
    ).

    % Splits through a provenance wrapper, each conjunct keeping its own: a
    % `Json` projection taints every node above it ([IRET.9.6]).
    %
    %@helper
:- func and_conjuncts(expr) = list(expr).

and_conjuncts(E) =
    ( if untainted(E) = e_binop(op_and, L, R) then
        and_conjuncts(L) ++ and_conjuncts(R)
    else
        [E]
    ).

    %@helper
:- pred classify_conjunct(alpha_scope::in, expr::in,
                          list(alpha_test)::in, list(alpha_test)::out,
                          list(expr)::in, list(expr)::out) is det.

classify_conjunct(Scope, E, !Tests, !Rest) :-
    ( if alpha_test_of(Scope, E, Test) then
        !:Tests = [Test | !.Tests]
    else
        !:Rest = [E | !.Rest]
    ).

    %@helper
:- pred alpha_test_of(alpha_scope::in, expr::in, alpha_test::out)
    is semidet.

alpha_test_of(Scope, E, Test) :-
    ( if E = e_binop(Op0, L, R) then
        alpha_cmp(Op0),
        ( if L = e_slot(candidate, slot(Ix0)) then
            Ix = Ix0, Lit0 = R, Op = Op0
        else
            R = e_slot(candidate, slot(Ix)),
            Lit0 = L,
            Op = flip(Op0)
        ),
        Lit0 = e_lit(Value),
        alpha_literal_of(Value, Lit),
        not list.member(Ix, Scope ^ as_undecided),
        ( if Op = op_eq then
            Test = at_eq(Ix, Lit)
        else
            Test = at_cmp(Ix, Op, Lit)
        )
    else
        rlow_5_2_2_regex_test(Scope, E, Test)
    ).

    % `s.x ~ /p/f` as an alpha regex test, read back off the lowered conjunct.
    % `!~` stays in the join test: an alpha test has no negation.
    %
    % The flags go into the pattern as `(?f:p)`: `AlphaTest` has no flags field.
    % The wrapped pattern is validated again: an unterminated `\Q` swallows the
    % group's closing `)`, and both runtimes would refuse the artefact at load
    % ([IRET.6.3]), so such a conjunct stays on the beta.
    %
    %@spec [RLOW.5.2.2]
:- pred rlow_5_2_2_regex_test(alpha_scope::in, expr::in, alpha_test::out)
    is semidet.

rlow_5_2_2_regex_test(Scope, E, at_regex(Ix, Pattern)) :-
    E = e_call(fn_regex_match, [e_slot(candidate, slot(Ix)),
        e_lit(str(PatternRef)), e_lit(str(FlagsRef))]),
    list.member(Ix, Scope ^ as_regex),
    expand(Scope ^ as_interns, PatternRef, P),
    expand(Scope ^ as_interns, FlagsRef, Flags),
    Pattern = rlow_5_2_2_pattern(P, Flags),
    re2_compile(Pattern, re2_flags_of_letters("")) = re2_valid(_).

    %@spec [RLOW.5.2.2]
:- func rlow_5_2_2_pattern(string, string) = string.

rlow_5_2_2_pattern(P, Flags) =
    ( if Flags = "" then P else "(?" ++ Flags ++ ":" ++ P ++ ")" ).

    %@helper
:- pred alpha_cmp(binop::in) is semidet.

alpha_cmp(op_eq).
alpha_cmp(op_ne).
alpha_cmp(op_lt).
alpha_cmp(op_gt).
alpha_cmp(op_le).
alpha_cmp(op_ge).

    %@helper
:- func flip(binop) = binop.

flip(Op) =
    ( if Op = op_lt then op_gt
    else if Op = op_gt then op_lt
    else if Op = op_le then op_ge
    else if Op = op_ge then op_le
    else Op ).

    %@helper
:- pred alpha_literal_of(ds_value::in, alpha_literal::out) is semidet.

alpha_literal_of(int(I), al_int(I)).
alpha_literal_of(float(F), al_float(F)).
alpha_literal_of(str(R), al_string(R)).
alpha_literal_of(bool(B), al_bool(B)).

%-----------------------------------------------------------------------------%
% Rule-header rate modifiers -- [RLOW.4.6]
%-----------------------------------------------------------------------------%

    %@helper
:- pred rate_windows(resolved_file::in, list(ast_rule_modifier)::in,
                     maybe(uint64)::in, lowered(maybe(uint64))::out) is det.

rate_windows(_, [], Cool, done(Cool)).
rate_windows(RF, [M | Ms], Cool, Result) :-
    (
        M = arm_cooldown(Toks, _),
        ( if lgra_2_8_2_rate_window_ns(RF, Toks, Ns) then
            rate_windows(RF, Ms, yes(Ns), Result)
        else
            Result = skipped("the `cooldown` is neither a duration literal "
                ++ "nor a `time` const")
        )
    ;
        % The key, not a window: `rlow_4_6_1_rate_guard` reads it.
        M = arm_by(_, _),
        rate_windows(RF, Ms, Cool, Result)
    ).

    % A `cooldown` window, which may be zero ([LCDB.5.6]).
    %
    %@spec [LGRA.2.8.2]
:- pred lgra_2_8_2_rate_window_ns(resolved_file::in, list(positioned)::in,
                                  uint64::out) is semidet.

lgra_2_8_2_rate_window_ns(RF, Toks, Ns) :-
    lgra_2_8_1_time_expr_ns(RF, Toks, Value),
    Value >= 0i64,
    Ns = uint64.cast_from_int64(Value).

    % A `within` window, a pattern's or a `then` step's, in nanoseconds.
    %
    %@helper
:- pred duration_tokens_ns(resolved_file::in, list(positioned)::in,
                           uint64::out) is semidet.

duration_tokens_ns(RF, Toks, Ns) :-
    lgra_2_8_1_time_expr_ns(RF, Toks, Value),
    Value > 0i64,
    Ns = uint64.cast_from_int64(Value).

    % The condition the clock re-drives and the cooldown's rate gate. Both are
    % `BINOP_AND`, the condition left and the gate right, which is how a runtime
    % tells them apart.
    %
    %@spec [RDSC.4a.8.2.1]
:- func rdsc_4a_8_2_1_fire_guard(maybe(expr), maybe(expr)) = maybe(expr).

rdsc_4a_8_2_1_fire_guard(no, Gate) = Gate.
rdsc_4a_8_2_1_fire_guard(yes(Cond), no) = yes(Cond).
rdsc_4a_8_2_1_fire_guard(yes(Cond), yes(Gate)) =
    yes(e_binop(op_and, Cond, Gate)).

    % `ds_rate_allow(rule, key..., cool_ns)` as the terminal's `fire_guard`, when
    % the rule has a `cooldown`. The key is [LCDB.3.3.4]'s `by:` where the rule
    % writes one, otherwise [LCDB.3.3.3]'s composition (`key_vars`).
    %
    %@spec [RLOW.4.6.1]
    %@spec [RLOW.4.6.2.2]
    %@spec [LCDB.3.3.4]
:- func rlow_4_6_1_rate_guard(string, list(pat), maybe(ast_rate_key),
                              maybe(uint64), intern_table) = maybe(expr).

rlow_4_6_1_rate_guard(_, _, _, no, _) = no.
rlow_4_6_1_rate_guard(Rule, Pats, RateKey, yes(CoolNs), IT) = Guard :-
    ( if interned(IT, Rule, Ref) then
        RuleLit = e_lit(str(Ref))
    else
        unexpected($pred, "the rule name was interned by the caller")
    ),
    (
        RateKey = no,
        Keys = list.condense(list.map(key_vars, Pats))
    ;
        RateKey = yes(ark_none),
        Keys = []
    ;
        RateKey = yes(ark_paths(Paths)),
        Keys = list.map(lcdb_3_3_4_key_var(IT, Pats), Paths)
    ),
    Guard = yes(e_call(fn_rate_allow,
        [RuleLit | Keys] ++ [e_lit(int(int64.cast_from_uint64(CoolNs)))])).

    %@spec [LCDB.3.3.4]
:- func lcdb_3_3_4_key_var(intern_table, list(pat), ast_key_path) = expr.

lcdb_3_3_4_key_var(IT, Pats, Path) = Var :-
    B = Path ^ akp_binding ^ id_name,
    S = Path ^ akp_slot ^ id_name,
    ( if
        list.find_first_match(
            (pred(P::in) is semidet :-
                P ^ pt_binding = B, P ^ pt_negated = no),
            Pats, Pat),
        list.find_first_match((pred(C::in) is semidet :-
                expand(IT, C ^ sc_name, S)),
            slot_commons(Pat ^ pt_schema), Common)
    then
        Var = e_slot(token_fact(Pat ^ pt_token), slot(Common ^ sc_index))
    else
        unexpected($pred, "`by: " ++ B ++ "." ++ S ++ "` passed validate")
    ).

    %@helper
:- func rate_key(list(ast_rule_modifier)) = maybe(ast_rate_key).

rate_key([]) = no.
rate_key([M | Ms]) =
    ( if M = arm_by(Key, _) then yes(Key) else rate_key(Ms) ).

    %@helper
:- func key_vars(pat) = list(expr).

key_vars(P) = Vars :-
    ( if P ^ pt_negated = yes then
        Vars = []
    else
        Life = P ^ pt_schema ^ s_lifecycle,
        ( if Life = lc_logical(Logical, _) then
            Indices = list.filter_map(key_index, Logical)
        else
            % [LCDB.3.3.3]: another lifecycle's fact contributes nothing.
            Indices = []
        ),
        Vars = list.map((func(Ix) = e_slot(token_fact(P ^ pt_token), slot(Ix))),
            Indices)
    ).

    %@helper
:- func key_index(logical_slot) = slot_index is semidet.

key_index(L) = L ^ ls_common ^ sc_index :-
    L ^ ls_role = role_key.

%-----------------------------------------------------------------------------%
% The display name -- [RDSC.6.8]
%-----------------------------------------------------------------------------%

    % `rule(b={b.key}, ...)`, one placeholder per positive pattern: the first
    % declared `key` slot of a `logical` schema, else the schema's first slot.
    % Empty when no pattern contributes one, which omits the atom.
    %
    %@spec [RDSC.6.8.4]
    %@spec [RDSC.6.8.5]
    %@spec [RDSC.6.8.6]
    %@spec [RDSC.6.8.9]
:- func rdsc_6_8_4_display(string, list(pat), intern_table) = string.

rdsc_6_8_4_display(Rule, Pats, IT) = Template :-
    Parts = list.filter_map(placeholder(IT), Pats),
    (
        Parts = [],
        Template = ""
    ;
        Parts = [_ | _],
        Template = Rule ++ "(" ++ string.join_list(", ", Parts) ++ ")"
    ).

    %@helper
:- func placeholder(intern_table, pat) = string is semidet.

placeholder(IT, P) = Part :-
    P ^ pt_negated = no,
    Schema = P ^ pt_schema,
    ( if
        Schema ^ s_lifecycle = lc_logical(Logical, _),
        list.find_first_match((pred(L::in) is semidet :-
            L ^ ls_role = role_key), Logical, Key)
    then
        KeyRef = Key ^ ls_common ^ sc_name
    else
        % A schema with no slots contributes no entry ([RDSC.6.8.5]).
        slot_commons(Schema) = [First | _],
        KeyRef = First ^ sc_name
    ),
    expand(IT, KeyRef, KeyName),
    B = P ^ pt_binding,
    Part = B ++ "={" ++ B ++ "." ++ KeyName ++ "}".

%-----------------------------------------------------------------------------%
% Expressions -- [RLOW.6]
%-----------------------------------------------------------------------------%

    % The patterns in scope, which one is the beta's right-side candidate --
    % `yes(K)` inside pattern K's `where`, `no` in the RHS -- and the `let`s in
    % scope, which in a `where` is none ([LLET.10.4]).
    %
    %@helper
:- type ctx
    --->    ctx(
                cx_rf    :: resolved_file,
                cx_pats  :: list(pat),
                cx_right :: maybe(int),
                cx_lets  :: list(let_def),
                cx_env   :: maybe(type_env)
                    % The rule's typing environment, where the lowering has
                    % one: a `::` cast dispatches on its operand's static type.
                    % A follow-up's and a sibling's body carry the rule's, with
                    % `error` or `response` bound where they read one. The lock
                    % and `latest` twins, a formula body and a tier-2 unit
                    % literal carry none, and a cast there is left unlowered.
            ).

    %@spec [RLOW.6.1.1]
    %@spec [RLOW.6.1.2]
    %@spec [RLOW.6.1.3]
    %@spec [RLOW.6.3.1]
    %@spec [RLOW.6.3.2]
    %@spec [RLOW.4.4.1]
    %@spec [RLOW.5.4.1]
    %@spec [RLOW.9.3.2]
    %@spec [RDSC.4a.9.1]
    %@spec [IRET.9.6]
:- pred rlow_6_1_1_expr(ctx::in, lgra_9_3_1_expr::in, lowered(expr)::out,
                   intern_table::in, intern_table::out) is det.

rlow_6_1_1_expr(Ctx, Expr, Result0, !IT) :-
    rlow_6_1_1_expr_inner(Ctx, Expr, Result, !IT),
    (
        Result = skipped(_),
        Result0 = Result
    ;
        Result = done(E),
        Result0 = done(provflag1_stamp(Expr, E))
    ).

    % Stamp the provenance flag on one lowered node ([IRET.9.6]). The source test
    % reads the lowered node; the sinks read the AST, since an identity cast
    % leaves no node. `e_interp` is stamped where it is built
    % (`iret_9_6_interp_stamp`).
    %
    %@helper
:- func provflag1_stamp(lgra_9_3_1_expr, expr) = expr.

provflag1_stamp(Ast, E) = Stamped :-
    ( if
        not provflag1_clears(Ast),
        not E = e_tainted(_),
        ( provflag1_projection(E)
        ; list.member(Child, expr_children(E)),
          Child = e_tainted(_)
        )
    then
        Stamped = e_tainted(E)
    else
        Stamped = E
    ).

    % The two constructs that end provenance: each establishes the type.
    %
    %@helper
:- pred provflag1_clears(lgra_9_3_1_expr::in) is semidet.

provflag1_clears(ex_cast(_, _, _, _)).
provflag1_clears(ex_binary(bo_coalesce, _, _, _)).

    % A `Json` projection, the one source. The whole `Json` value is not one:
    % `j.body` lowers to a plain `e_slot`. `len(j.a)` and `has(j.a)` absorb the
    % `FN_JSON_PATH` node, so they count.
    %
    %@helper
:- pred provflag1_projection(expr::in) is semidet.

provflag1_projection(e_call(fn_json_path, _)).
provflag1_projection(e_call(fn_json_len, _)).
provflag1_projection(e_call(fn_json_has, _)).

    %@helper
:- pred rlow_6_1_1_expr_inner(ctx::in, lgra_9_3_1_expr::in,
                   lowered(expr)::out,
                   intern_table::in, intern_table::out) is det.

rlow_6_1_1_expr_inner(Ctx, Expr, Result, !IT) :-
    (
        Expr = ex_int(I, _),
        Result = done(e_lit(int(I)))
    ;
        Expr = ex_float(F, _),
        Result = done(e_lit(float(F)))
    ;
        Expr = ex_bool(B, _),
        Result = done(e_lit(bool(B)))
    ;
        Expr = ex_null(_),
        Result = done(e_lit(null))
    ;
        Expr = ex_string(Text, _),
        Right = Ctx ^ cx_right,
        (
            Right = no,
            rlow_6_4_1_message(Ctx, Text, Result, !IT)
        ;
            Right = yes(_),
            ( if text_has_site(string.to_char_list(Text)) then
                Result = skipped("a string with an interpolation site in a "
                    ++ "`where` is not lowered")
            else
                literal_string(Text, Result, !IT)
            )
        )
    ;
        Expr = ex_unit(Magnitude, Suffix, _),
        ( if
            luni_10_2_time_unit(llex_12_5_symbol_of(Suffix), Multiplier)
        then
            Result = done(e_lit(int(
                luni_3_1_5_magnitude_ns(Magnitude, Multiplier))))
        else if
            luni_4_3_unit_literal(Ctx ^ cx_rf, Magnitude,
                llex_12_5_symbol_of(Suffix), Value)
        then
            Result = done(e_lit(Value))
        else
            luni_4_3_tier2_literal(Ctx, no, Magnitude,
                llex_12_5_symbol_of(Suffix), Result, !IT)
        )
    ;
        Expr = ex_name(Id),
        ( if let_named(Ctx ^ cx_lets, Id ^ id_name, [], Def, Scope) then
            (
                Def = let_bound(_, Ix),
                Result = done(e_bind_ref(Ix))
            ;
                Def = let_inline(_, Inlined),
                rlow_6_1_1_expr(Ctx ^ cx_lets := Scope, Inlined, Result, !IT)
            ;
                Def = let_lowered(_, Lowered),
                Result = done(Lowered)
            ;
                Def = let_capture(_, Subject, Pattern, Flags, Group),
                lreg_4_1_capture_expr(Ctx ^ cx_lets := Scope, Subject, Pattern,
                    Flags, Group, Result, !IT)
            )
        else if binding_index(Ctx ^ cx_pats, Id ^ id_name, 0, K, P) then
            fact_of(Ctx, K, P, FactRes),
            (
                FactRes = done(Fact),
                ( if
                    % A capture view's empty-named slot: the parent fact.
                    interned(!.IT, "", FactRef),
                    slot_by_name(P ^ pt_schema, FactRef, Captured)
                then
                    Result = done(e_slot(Fact, slot(Captured ^ sc_index)))
                else
                    Result = done(e_slot(Fact, whole_fact))
                )
            ;
                FactRes = skipped(Why),
                Result = skipped(Why)
            )
        else if lexp_4_1_math_constant_value(Id ^ id_name, Value) then
            Result = done(e_lit(float(Value)))
        else if
            map.search(Ctx ^ cx_rf ^ rf_consts, Id ^ id_name, Const),
            Const ^ acn_form = acf_value(_, ConstExpr)
        then
            lgra_13_3_const(limp_1_5_const_ctx(Ctx, Const), ConstExpr, Result,
                !IT)
        else
            Result = skipped("the name `" ++ Id ^ id_name
                ++ "` (a constant or a `let`) is not lowered yet")
        )
    ;
        Expr = ex_slot(_, _, _),
        ( if lgra_22_9_library_member(Ctx ^ cx_rf, Expr, LibPath, LibMember)
        then
            % A library member ([LGRA.22.9]): a constant inlines with none of the
            % importer's constants in scope.
            LibKey = string.join_list(".",
                list.map((func(I) = I ^ id_name), LibPath))
                ++ ";" ++ LibMember ^ id_name,
            ( if
                map.search(Ctx ^ cx_rf ^ rf_qualified_consts, LibKey, LibConst),
                LibConst ^ acn_form = acf_value(_, LibConstExpr)
            then
                lgra_13_3_const(
                    limp_1_5_const_ctx(Ctx, LibConst)
                        ^ cx_rf ^ rf_consts := map.init,
                    LibConstExpr, Result, !IT)
            else
                Result = skipped("`" ++ string.replace_all(LibKey, ";", ".")
                    ++ "` is a library member that is not a constant, and is "
                    ++ "not lowered")
            )
        else if
            Expr = ex_slot(DateExpr, DateComponent, _),
            ltim_6_6_fn(DateComponent ^ id_name, DateFn),
            Ctx ^ cx_env = yes(DateEnv),
            type_of_expr(DateEnv, DateExpr) = ty_known(DateType),
            DateType ^ dt_leaf = lk_date
        then
            % [LTIM.6.6]: a Date's component is that component of its midnight in
            % UTC. The multiply goes through `Float` because an `Int` multiply
            % wraps. It is exact: 86_400 * 10^9 = 2^16 * 1_318_359_375, and
            % `d * 1_318_359_375` is below 2^53 for every Date.
            lower_args(Ctx, [DateExpr], [], DateRes, !IT),
            intern("UTC", DateUtcRef, !IT),
            Result = with_args(DateRes,
                ( func(Es) = e_call(DateFn,
                    [e_call(fn_float_to_int,
                        [e_binop(op_mul, e_call(fn_int_to_float, Es),
                            e_lit(float(86400000000000.0)))]),
                     e_lit(str(DateUtcRef))]) ))
        else if
            Expr = ex_slot(Zoned, TimeComponent, _),
            ltim_6_5_zone(Zoned, TimeArg, ZoneArg),
            ltim_6_5_fn(TimeComponent ^ id_name, ComponentFn)
        then
            % [LTIM.6.5]: a component read on `t.utc` or `t.local(tz)` is that
            % component's builtin over the instant and the zone.
            (
                ZoneArg = no,
                intern("UTC", UtcRef, !IT),
                lower_args(Ctx, [TimeArg], [], ArgsRes, !IT),
                Result = with_args(ArgsRes,
                    ( func(Es) = e_call(ComponentFn, Es ++ [e_lit(str(UtcRef))]) ))
            ;
                ZoneArg = yes(TzArg),
                lower_args(Ctx, [TimeArg, TzArg], [], ArgsRes, !IT),
                Result = with_args(ArgsRes,
                    ( func(Es) = e_call(ComponentFn, Es) ))
            )
        else if
            Expr = ex_slot(IntervalExpr, Component, _),
            interval_parts(Ctx, IntervalExpr, StartCtx - Start, EndCtx - End),
            ( Component ^ id_name = "start"
            ; Component ^ id_name = "end"
            ; Component ^ id_name = "duration"
            )
        then
            lint_6_1_component(Component ^ id_name, StartCtx - Start,
                EndCtx - End, Result, !IT)
        else if
            Expr = ex_slot(Receiver, Member, _),
            Ctx ^ cx_env = yes(MemberEnv),
            type_of_expr(MemberEnv, Receiver) = ty_known(ReceiverType),
            lgra_9_6_2_member_fn(ReceiverType ^ dt_leaf, Member ^ id_name, Fn)
        then
            lower_args(Ctx, [Receiver], [], ArgsRes, !IT),
            Result = with_args(ArgsRes, ( func(Es) = e_call(Fn, Es) ))
        else if
            slot_chain(Expr, BId, Segs),
            binding_index(Ctx ^ cx_pats, BId ^ id_name, 0, K, P)
        then
            rlow_6_3_1_path(Ctx, K, P, Segs, Result, !IT)
        else
            Result = skipped("a path that does not start at a pattern "
                ++ "binding is not lowered yet")
        )
    ;
        Expr = ex_index(_, _, _),
        ( if
            slot_chain(Expr, BId, Segs),
            binding_index(Ctx ^ cx_pats, BId ^ id_name, 0, K, P)
        then
            rlow_6_3_1_path(Ctx, K, P, Segs, Result, !IT)
        else
            Result = skipped("an index that is not an integer literal on a "
                ++ "binding's `Json` path is not lowered yet")
        )
    ;
        Expr = ex_unary(Op, Operand, _),
        ( if
            % [LUNI.3.3]: a minus on a unit literal negates the literal's number
            % before the unit's formula converts it.
            Op = uo_neg,
            Operand = ex_unit(Magnitude, Suffix, _),
            not luni_10_2_time_unit(llex_12_5_symbol_of(Suffix), _)
        then
            ( if
                luni_4_3_negated_unit_literal(Ctx ^ cx_rf, Magnitude,
                    llex_12_5_symbol_of(Suffix), Value)
            then
                Result = done(e_lit(Value))
            else
                luni_4_3_tier2_literal(Ctx, yes, Magnitude,
                    llex_12_5_symbol_of(Suffix), Result, !IT)
            )
        else
            rlow_6_1_1_expr(Ctx, Operand, OpRes, !IT),
            (
                OpRes = done(E),
                (
                    Op = uo_pos,
                    Result = done(E)
                ;
                    Op = uo_neg,
                    Result = done(e_unop(op_neg, E))
                ;
                    Op = uo_bitnot,
                    Result = done(e_unop(op_bitnot, E))
                )
            ;
                OpRes = skipped(Why),
                Result = skipped(Why)
            )
        )
    ;
        Expr = ex_not(Operand, _),
        rlow_6_1_1_expr(Ctx, Operand, OpRes, !IT),
        (
            OpRes = done(E),
            Result = done(e_unop(op_not, E))
        ;
            OpRes = skipped(Why),
            Result = skipped(Why)
        )
    ;
        Expr = ex_binary(Op, L, R, _),
        ( if ( Op = bo_in ; Op = bo_contains ; Op = bo_overlaps ) then
            lint_3_1_1_relation(Ctx, Op, L, R, Result, !IT)
        else
            rlow_6_1_1_expr(Ctx, L, LRes, !IT),
            rlow_6_1_1_expr(Ctx, R, RRes, !IT),
            ( if LRes = done(LE), RRes = done(RE) then
                ( if rlow_6_1_5_date_arith(Ctx, Op, L, R, DateFn) then
                    Result = done(e_call(DateFn, [LE, RE]))
                else if rlow_6_1_6_saturating(Ctx, Op, L, R, IntOp) then
                    Result = done(rlow_6_1_6_saturate(Ctx, Expr,
                        e_binop(IntOp, LE, RE)))
                else
                    Result = binary(Op, LE, RE)
                )
            else if LRes = skipped(LWhy) then
                Result = skipped(LWhy)
            else if RRes = skipped(RWhy) then
                Result = skipped(RWhy)
            else
                unexpected($pred, "both operands lowered")
            )
        )
    ;
        Expr = ex_compare(First, Steps, _),
        ( if
            Steps = [lgra_9_3_2_compare_step(Op, Second, _)],
            ( Op = co_eq ; Op = co_ne ),
            interval_parts(Ctx, First, S1, E1),
            interval_parts(Ctx, Second, S2, E2)
        then
            lint_5_1_equality(Op, S1, E1, S2, E2, Result, !IT)
        else
            rlow_6_1_1_expr(Ctx, First, FirstRes, !IT),
            (
                FirstRes = done(FE),
                rlow_6_2_1_chain(Ctx, First, FE, Steps, no, Result, !IT)
            ;
                FirstRes = skipped(Why),
                Result = skipped(Why)
            )
        )
    ;
        Expr = ex_is(Operand, Negation, Subject, _),
        ( if is_subject_of(Subject, WireSubject) then
            rlow_6_1_1_expr(Ctx, Operand, OpRes, !IT),
            (
                OpRes = done(E),
                Negated = ( if Negation = is_negated then yes else no ),
                Result = done(e_is_test(E, WireSubject, Negated))
            ;
                OpRes = skipped(Why),
                Result = skipped(Why)
            )
        else
            Result = skipped("an `is` test on that subject is not lowered yet")
        )
    ;
        Expr = ex_call(Callee, Args, _),
        ( if Callee = ex_name(Fn), Fn ^ id_name = "now", Args = [] then
            Result = done(e_now)
        else if
            Callee = ex_name(Fn), Fn ^ id_name = "monotonic_ns", Args = []
        then
            Result = done(ltim_2_2_1_monotonic_ns)
        else if Callee = ex_name(Fn), Fn ^ id_name = "cached", Args = [Key] then
            % [LSTO.4.3]: an interpolated key lowers as a message does, in a
            % `where` too (`dsc.validate.inert_strings`).
            ( if
                Key = ex_string(KeyText, _),
                text_has_site(string.to_char_list(KeyText))
            then
                rlow_6_4_1_message(Ctx, KeyText, KeyRes, !IT)
            else
                rlow_6_1_1_expr(Ctx, Key, KeyRes, !IT)
            ),
            (
                KeyRes = done(KeyE),
                Result = done(e_call(fn_cache_get, [KeyE]))
            ;
                KeyRes = skipped(Why),
                Result = skipped(Why)
            )
        else if
            % [LGRA.9.8.11]'s formula functions, after the builtins of the same
            % spelling.
            Callee = ex_name(Fn),
            not lgra_22_7_builtin_fn(Fn ^ id_name),
            lgra_9_8_11_formula_function(Ctx ^ cx_rf, Fn ^ id_name, Line),
            Args = [Arg]
        then
            lgra_9_8_11_formula_call(Ctx, Line, Arg, Result, !IT)
        else if
            % `count_of(e.tag, "error")`: the second argument is the value.
            Callee = ex_name(Fn),
            value_series_call_shape(Ctx, Fn ^ id_name, Args, CursorArg,
                ValueArg)
        then
            lser_16_6_1_value_call(Ctx, Fn, CursorArg, ValueArg, Result, !IT)
        else if
            % `count(t.state)` lowers as the companion read `t.state.count` does.
            Callee = ex_name(Fn),
            Args = [CursorArg],
            agg_builtin(Fn ^ id_name, _, _),
            cursor_parts(CursorArg, Root, Components),
            binding_index(Ctx ^ cx_pats, Root, 0, K, P),
            P ^ pt_negated = no
        then
            rlow_8_3_1_companion(Ctx, K, P, Components ++ [Fn], Result, !IT)
        else if Callee = ex_name(Fn), scalar_call(Fn ^ id_name, Args) then
            ( if Fn ^ id_name = "distance.great_circle" then
                list.map2(lexp_5_11_1_degree_arg(Ctx), Args, InDegrees,
                    Degrees)
            else
                InDegrees = Args,
                Degrees = list.map((func(_) = da_as_is), Args)
            ),
            lower_args(Ctx, InDegrees, [], ArgsRes0, !IT),
            (
                ArgsRes0 = done(ArgEs0),
                ArgsRes = lexp_5_11_1_in_degrees(Degrees, ArgEs0)
            ;
                ArgsRes0 = skipped(_),
                ArgsRes = ArgsRes0
            ),
            (
                ArgsRes = done(ArgEs),
                ( if
                    ( Fn ^ id_name = "len" ; Fn ^ id_name = "has" ),
                    % Through the provenance wrapper, which
                    % `provflag1_projection` puts back on the result.
                    ArgEs = [ArgE], untainted(ArgE) = e_call(fn_json_path,
                        PathArgs)
                then
                    % `len` and `has` over a Json path keep the path's arguments
                    % and switch the builtin: the runtime walks to the node.
                    JsonFn = ( if Fn ^ id_name = "len" then fn_json_len
                        else fn_json_has ),
                    Result = done(e_call(JsonFn, PathArgs))
                else if scalar_fn(Fn ^ id_name, list.length(Args), Op) then
                    Result = done(e_call(Op, ltim_14_1_operands(Op, ArgEs)))
                else
                    Result = skipped("a function call is not lowered yet")
                )
            ;
                ArgsRes = skipped(Why),
                Result = skipped(Why)
            )
        else if Callee = ex_slot(Receiver, Method, _) then
            luni_13_5_method_call(Ctx, Receiver, Method, Args, Result, !IT)
        else
            Result = skipped("a function call is not lowered yet")
        )
    ;
        Expr = ex_cast(Operand, Target, _, _),
        ( if Operand = ex_null(_) then
            % [LCST.4.2.3]: `null::T?` is `null`.
            Result = done(e_lit(null))
        else if
            Ctx ^ cx_env = yes(Env),
            lcst_4_cast_pair(Env, Operand, Target, Kind, To)
        then
            rlow_6_1_1_expr(Ctx, Operand, OperandRes, !IT),
            (
                OperandRes = done(OperandE),
                ( if Kind = ck_time, To = ct_string then
                    % [LCST.4.5.9]: `FN_TO_STRING` with no format, at the value's
                    % own offset ([LTIM.8.2.4]).
                    Result = done(e_call(fn_to_string, [OperandE]))
                else if
                    Kind = ck_int,
                    To = ct_unit(_, _),
                    type_of_expr(Env, Expr) = ty_known(CastType),
                    CastType ^ dt_leaf = lk_duration
                then
                    Result = done(lcst_4_5_2_time_unit(Ctx, Expr, OperandE))
                else
                    Result = lcst_4_5_2_lower(Kind, To, OperandE)
                )
            ;
                OperandRes = skipped(Why),
                Result = skipped(Why)
            )
        else
            Result = skipped("a `::` cast whose operand has no static type "
                ++ "here is not lowered yet")
        )
    ;
        Expr = ex_match(Subject, Sense, Pattern, Flags, _),
        % [LREG.1.2], [LREG.1.3]: `s ~ /p/f` is `FN_REGEX_MATCH(s, p, f)`, `!~`
        % its `not`.
        ( if
            re2_compile(Pattern, re2_flags_of_letters(Flags)) = re2_valid(_)
        then
            rlow_6_1_1_expr(Ctx, Subject, SubjectRes, !IT),
            (
                SubjectRes = done(SubjectE),
                intern(Pattern, PatternRef, !IT),
                intern(Flags, FlagsRef, !IT),
                Match = e_call(fn_regex_match,
                    [SubjectE, e_lit(str(PatternRef)), e_lit(str(FlagsRef))]),
                (
                    Sense = ms_match,
                    Result = done(Match)
                ;
                    Sense = ms_not_match,
                    Result = done(e_unop(op_not, Match))
                )
            ;
                SubjectRes = skipped(Why),
                Result = skipped(Why)
            )
        else
            Result = skipped("a regex pattern RE2 does not accept")
        )
    ).

    % A `::` cast, by its `(source, target)` pair: an identity cast is its operand
    % ([LCST.4.5.1]), and so is a unit-tag strip or assert ([LUNI.8.5]); every
    % other defined pair is one conversion builtin over the operand.
    %
    %@spec [LCST.4.5.2]
    %@spec [LCST.4.2.2]
:- func lcst_4_5_2_lower(lcst_4_5_2_kind, lcst_4_1_6_target, expr)
    = lowered(expr).

lcst_4_5_2_lower(Kind, To, E) = Result :-
    ( if lcst_4_5_2_classify(Kind, To) = cc_identity then
        Result = done(E)
    else if
        ( Kind = ck_unit(_, _)
        ; Kind = ck_dimension(_, _)
        ),
        ( To = ct_float
        ; To = ct_int
        )
    then
        Result = done(E)
    else if
        ( Kind = ck_float
        ; Kind = ck_int
        ),
        To = ct_unit(_, _)
    then
        Result = done(E)
    else if Kind = ck_duration, To = ct_int then
        % A `Duration` is held as its nanoseconds ([RDSC.5.5.8]).
        Result = done(E)
    else if cast_fn(Kind, To, Fn) then
        Result = done(e_call(Fn, [E]))
    else if Kind = ck_fact(_), To = ct_json then
        % [LCST.4.5.2] defines no shape for this cast.
        Result = skipped("a `fact::Json` cast has no defined shape")
    else
        Result = skipped("a `::` conversion with no builtin in the reference "
            ++ "is not lowered")
    ).

    % `n::s`, an `Int` asserted into a `time` unit: a negative `Int` gives `0_s`
    % ([LTIM.1.3.1]). A literal is folded; anything else saturates.
    %
    %@spec [LCST.4.5.2]
:- func lcst_4_5_2_time_unit(ctx, lgra_9_3_1_expr, expr) = expr.

lcst_4_5_2_time_unit(Ctx, Expr, E) = Saturated :-
    ( if E = e_lit(int(N)) then
        Saturated = e_lit(int(int64.max(N, 0i64)))
    else if E = e_unop(op_neg, e_lit(int(_))) then
        Saturated = e_lit(int(0i64))
    else
        Saturated = rlow_6_1_6_saturate(Ctx, Expr, E)
    ).

    %@helper
:- pred cast_fn(lcst_4_5_2_kind::in, lcst_4_1_6_target::in, builtin_fn::out)
    is semidet.

cast_fn(ck_float, ct_string, fn_float_to_string).
cast_fn(ck_int, ct_string, fn_int_to_string).
cast_fn(ck_bool, ct_string, fn_bool_to_string).
cast_fn(ck_int, ct_float, fn_int_to_float).
cast_fn(ck_float, ct_int, fn_float_to_int).
cast_fn(ck_string, ct_int, fn_string_to_int).
cast_fn(ck_string, ct_float, fn_string_to_float).
cast_fn(ck_string, ct_bool, fn_string_to_bool).
    % `Time -> String` is the `ex_cast` arm's.
cast_fn(ck_date, ct_string, fn_to_string).
cast_fn(ck_duration, ct_string, fn_duration_to_string).

    % The interval relations over their endpoints, as the clauses define them
    % ([LINT.3.1.1], [LINT.3.2.1], [LINT.4.1]):
    %
    %     t in i          i.start <= t  and  t < i.end
    %     i1 contains i2  i1.start <= i2.start  and  i2.end <= i1.end
    %     i1 overlaps i2  i1.start < i1.end  and  i2.start < i2.end
    %                       and  i1.start < i2.end  and  i2.start < i1.end
    %
    % Only a `..` construction is an operand, in place or through a pure `let`:
    % neither runtime has an interval value.
    %
    %@spec [LINT.3.1.1]
    %@spec [LINT.3.2.1]
    %@spec [LINT.4.1]
    %@spec [RLOW.6.1.7]
:- pred lint_3_1_1_relation(ctx::in, lgra_9_3_1_binary_op::in,
                            lgra_9_3_1_expr::in, lgra_9_3_1_expr::in,
                            lowered(expr)::out,
                            intern_table::in, intern_table::out) is det.

lint_3_1_1_relation(Ctx, Op, L, R, Result, !IT) :-
    ( if
        Op = bo_in,
        interval_parts(Ctx, R, RStart, REnd)
    then
        lower_pairs([Ctx - L, RStart, REnd], [], LowRes, !IT),
        ( if LowRes = done([Point, Start, End]) then
            Result = done(rlow_6_1_7_check([Start, End], e_binop(op_and,
                e_binop(op_le, Start, Point), e_binop(op_lt, Point, End))))
        else if LowRes = skipped(Why) then
            Result = skipped(Why)
        else
            unexpected($pred, "three operands lowered")
        )
    else if
        ( Op = bo_contains ; Op = bo_overlaps ),
        interval_parts(Ctx, L, LStart, LEnd),
        interval_parts(Ctx, R, RStart, REnd)
    then
        lower_pairs([LStart, LEnd, RStart, REnd], [], LowRes, !IT),
        ( if LowRes = done([S1, E1, S2, E2]) then
            ( if Op = bo_contains then
                Result = done(rlow_6_1_7_check([S1, E1, S2, E2],
                    e_binop(op_and,
                        e_binop(op_le, S1, S2), e_binop(op_le, E2, E1))))
            else
                Overlap = e_binop(op_and,
                    e_binop(op_and,
                        e_binop(op_lt, S1, E1), e_binop(op_lt, S2, E2)),
                    e_binop(op_and,
                        e_binop(op_lt, S1, E2), e_binop(op_lt, S2, E1))),
                Result = done(rlow_6_1_7_check([S1, E1, S2, E2], Overlap))
            )
        else if LowRes = skipped(Why) then
            Result = skipped(Why)
        else
            unexpected($pred, "four endpoints lowered")
        )
    else
        Result = skipped("an interval operand that is not a `..` "
            ++ "construction is not lowered: neither runtime has an interval "
            ++ "value")
    ).

    % A `..` construction's endpoints, each with the context it is lowered in.
    %
    %@helper
:- pred interval_parts(ctx::in, lgra_9_3_1_expr::in,
                       pair(ctx, lgra_9_3_1_expr)::out,
                       pair(ctx, lgra_9_3_1_expr)::out) is semidet.

interval_parts(Ctx, ex_binary(bo_interval, Start, End, _), Ctx - Start,
        Ctx - End).
interval_parts(Ctx, ex_name(Id), Start, End) :-
    let_named(Ctx ^ cx_lets, Id ^ id_name, [], Def, Scope),
    Def = let_inline(_, Inlined),
    interval_parts(Ctx ^ cx_lets := Scope, Inlined, Start, End).

    % A component of a `..` construction, inside the interval's check, so `.start`
    % and `.end` lower both endpoints. A `Date` interval's `duration` is
    % `FN_DATE_DIFF` ([RLOW.6.1.5]), by the typing environment; with none it falls
    % back to `-`.
    %
    %@spec [LINT.6.1]
    %@spec [LINT.6.2]
    %@spec [RLOW.6.1.7]
:- pred lint_6_1_component(string::in, pair(ctx, lgra_9_3_1_expr)::in,
                           pair(ctx, lgra_9_3_1_expr)::in, lowered(expr)::out,
                           intern_table::in, intern_table::out) is det.

lint_6_1_component(Component, StartCtx - Start, EndCtx - End, Result, !IT) :-
    lower_pairs([StartCtx - Start, EndCtx - End], [], PairRes, !IT),
    ( if PairRes = done([StartE, EndE]) then
        ( if Component = "start" then
            Value = StartE
        else if Component = "end" then
            Value = EndE
        else if
            ( lint_6_2_date_endpoint(StartCtx, Start)
            ; lint_6_2_date_endpoint(EndCtx, End)
            )
        then
            Value = e_call(fn_date_diff, [EndE, StartE])
        else
            % `Time - Time`, which saturates at `0_s` ([RLOW.6.1.6]), keeping a
            % `null`: the endpoints have no one expression to type.
            Diff = e_binop(op_sub, EndE, StartE),
            Value = e_if(e_is_test(Diff, is_null, no), Diff,
                e_call(fn_max, [Diff, e_lit(int(0i64))]))
        ),
        Result = done(rlow_6_1_7_check([StartE, EndE], Value))
    else if PairRes = skipped(Why) then
        Result = skipped(Why)
    else
        Result = skipped("an interval component this compiler cannot lower")
    ).

    %@helper
:- pred lint_6_2_date_endpoint(ctx::in, lgra_9_3_1_expr::in) is semidet.

lint_6_2_date_endpoint(Ctx, Start) :-
    Ctx ^ cx_env = yes(Env),
    type_of_expr(Env, Start) = ty_known(Type),
    Type ^ dt_leaf = lk_date.

    %@spec [LINT.5.1]
    %@spec [LINT.5.3]
    %@spec [RLOW.6.1.7]
:- pred lint_5_1_equality(lgra_9_3_2_compare_op::in,
                          pair(ctx, lgra_9_3_1_expr)::in,
                          pair(ctx, lgra_9_3_1_expr)::in,
                          pair(ctx, lgra_9_3_1_expr)::in,
                          pair(ctx, lgra_9_3_1_expr)::in, lowered(expr)::out,
                          intern_table::in, intern_table::out) is det.

lint_5_1_equality(Op, S1, E1, S2, E2, Result, !IT) :-
    lower_pairs([S1, S2, E1, E2], [], PartsRes, !IT),
    ( if PartsRes = done([LS, RS, LE, RE]) then
        Equal = e_binop(op_and, e_binop(op_eq, LS, RS),
            e_binop(op_eq, LE, RE)),
        ( if Op = co_ne then
            Value = e_unop(op_not, Equal)
        else
            Value = Equal
        ),
        Result = done(rlow_6_1_7_check([LS, LE, RS, RE], Value))
    else if PartsRes = skipped(Why) then
        Result = skipped(Why)
    else
        Result = skipped("an interval equality this compiler cannot lower")
    ).

    % `FN_INTERVAL_CHECK(s1, e1, v)`, or `(s1, e1, s2, e2, v)`. The check encloses
    % `v`: a `false` conjunct beside it would absorb its fault ([LNUL.4.2]).
    %
    %@spec [RLOW.6.1.7]
:- func rlow_6_1_7_check(list(expr), expr) = expr.

rlow_6_1_7_check(Endpoints, Value) =
    e_call(fn_interval_check, Endpoints ++ [Value]).

    %@helper
:- pred lower_pairs(list(pair(ctx, lgra_9_3_1_expr))::in, list(expr)::in,
                    lowered(list(expr))::out,
                    intern_table::in, intern_table::out) is det.

lower_pairs([], Rev, done(list.reverse(Rev)), !IT).
lower_pairs([C - E | Rest], Rev, Result, !IT) :-
    rlow_6_1_1_expr(C, E, Res, !IT),
    (
        Res = done(X),
        lower_pairs(Rest, [X | Rev], Result, !IT)
    ;
        Res = skipped(Why),
        Result = skipped(Why)
    ).

    %@helper
    % `Date ± Duration` and `Date - Date` lower to their own builtins, by
    % `dsc.typecheck`'s operand types. A context with no typing environment lowers
    % them to Int arithmetic.
    %
    %@spec [RLOW.6.1.5]
:- pred rlow_6_1_5_date_arith(ctx::in, lgra_9_3_1_binary_op::in,
                              lgra_9_3_1_expr::in, lgra_9_3_1_expr::in,
                              builtin_fn::out) is semidet.

rlow_6_1_5_date_arith(Ctx, Op, L, R, Fn) :-
    Ctx ^ cx_env = yes(Env),
    type_of_expr(Env, L) = ty_known(LType),
    LType ^ dt_leaf = lk_date,
    type_of_expr(Env, R) = ty_known(RType),
    RLeaf = RType ^ dt_leaf,
    (
        Op = bo_add,
        RLeaf = lk_duration,
        Fn = fn_date_add_duration
    ;
        Op = bo_sub,
        (
            RLeaf = lk_duration,
            Fn = fn_date_sub_duration
        ;
            RLeaf = lk_date,
            Fn = fn_date_diff
        )
    ).

    % The integer operation of each saturating row, by `dsc.typecheck`'s operand
    % types. `dur / n` is `op_floordiv`: `/` is always a `Float` ([LEXP.7.4]). With
    % no typing environment the row lowers to the bare integer operation.
    %
    %@spec [RLOW.6.1.6]
:- pred rlow_6_1_6_saturating(ctx::in, lgra_9_3_1_binary_op::in,
                              lgra_9_3_1_expr::in, lgra_9_3_1_expr::in,
                              binop::out) is semidet.

rlow_6_1_6_saturating(Ctx, Op, L, R, IntOp) :-
    Ctx ^ cx_env = yes(Env),
    type_of_expr(Env, L) = ty_known(LType),
    type_of_expr(Env, R) = ty_known(RType),
    LLeaf = LType ^ dt_leaf,
    RLeaf = RType ^ dt_leaf,
    (
        Op = bo_sub,
        ( LLeaf = lk_time, RLeaf = lk_time
        ; LLeaf = lk_duration, RLeaf = lk_duration
        ),
        IntOp = op_sub
    ;
        Op = bo_mul,
        ( LLeaf = lk_int, RLeaf = lk_duration
        ; LLeaf = lk_duration, RLeaf = lk_int
        ),
        IntOp = op_mul
    ;
        Op = bo_div,
        LLeaf = lk_duration,
        RLeaf = lk_int,
        IntOp = op_floordiv
    ).

    % `FN_MAX(X, 0)` over a saturating row's integer operation `X`. `FN_MAX` faults
    % on a `null` argument, so a nullable row is `IF(X is null, X, FN_MAX(X, 0))`
    % ([LNUL.4.1]).
    %
    %@helper
:- func rlow_6_1_6_saturate(ctx, lgra_9_3_1_expr, expr) = expr.

rlow_6_1_6_saturate(Ctx, Expr, X) = Saturated :-
    Max = e_call(fn_max, [X, e_lit(int(0i64))]),
    ( if
        Ctx ^ cx_env = yes(Env),
        type_of_expr(Env, Expr) = ty_known(Type),
        Type ^ dt_null = non_null
    then
        Saturated = Max
    else
        Saturated = e_if(e_is_test(X, is_null, no), X, Max)
    ).

:- func binary(lgra_9_3_1_binary_op, expr, expr) = lowered(expr).

binary(bo_or, L, R) = done(e_binop(op_or, L, R)).
binary(bo_and, L, R) = done(e_binop(op_and, L, R)).
binary(bo_coalesce, L, R) = done(e_coalesce(L, R)).
binary(bo_in, _, _) = unexpected($pred, "`in` is lint_3_1_1_relation's").
binary(bo_contains, _, _) =
    unexpected($pred, "`contains` is lint_3_1_1_relation's").
binary(bo_overlaps, _, _) =
    unexpected($pred, "`overlaps` is lint_3_1_1_relation's").
binary(bo_interval, _, _) = skipped("an interval is not lowered yet").
binary(bo_bitor, L, R) = done(e_binop(op_bit_or, L, R)).
binary(bo_bitxor, L, R) = done(e_binop(op_bit_xor, L, R)).
binary(bo_bitand, L, R) = done(e_binop(op_bit_and, L, R)).
binary(bo_shl, L, R) = done(e_binop(op_shl, L, R)).
binary(bo_shr, L, R) = done(e_binop(op_shr, L, R)).
binary(bo_add, L, R) = done(e_binop(op_add, L, R)).
binary(bo_sub, L, R) = done(e_binop(op_sub, L, R)).
binary(bo_mul, L, R) = done(e_binop(op_mul, L, R)).
binary(bo_div, L, R) = done(e_binop(op_div, L, R)).
binary(bo_floordiv, L, R) = done(e_binop(op_floordiv, L, R)).
binary(bo_mod, L, R) = done(e_binop(op_rem, L, R)).
binary(bo_pow, L, R) = done(e_call(fn_pow, [L, R])).

    %@helper
:- pred scalar_call(string::in, list(lgra_9_3_1_expr)::in) is semidet.

scalar_call(Name, Args) :-
    ( scalar_fn(Name, list.length(Args), _)
    ; Name = "len", Args = [_]
    ; Name = "has", Args = [_]
    ).

    % The scalar builtin table, arity-dispatched where the name is overloaded. A
    % `math` or `distance` member goes by its [LEXP.17.2] row, the name
    % `dsc.libcall` gives every call that reaches it ([LIMP.3.3.4]).
    %
    %@helper
:- pred scalar_fn(string::in, int::in, builtin_fn::out) is semidet.

scalar_fn("math.sqrt", 1, fn_sqrt).
scalar_fn("math.exp", 1, fn_exp).
scalar_fn("math.ln", 1, fn_ln).
scalar_fn("math.log2", 1, fn_log2).
scalar_fn("math.log10", 1, fn_log10).
scalar_fn("math.sin", 1, fn_sin).
scalar_fn("math.cos", 1, fn_cos).
scalar_fn("math.tan", 1, fn_tan).
scalar_fn("math.asin", 1, fn_asin).
scalar_fn("math.acos", 1, fn_acos).
scalar_fn("math.atan", 1, fn_atan).
scalar_fn("math.atan2", 2, fn_atan2).
scalar_fn("math.sinh", 1, fn_sinh).
scalar_fn("math.cosh", 1, fn_cosh).
scalar_fn("math.tanh", 1, fn_tanh).
scalar_fn("math.floor", 1, fn_floor).
scalar_fn("math.ceil", 1, fn_ceil).
scalar_fn("math.trunc", 1, fn_trunc).
scalar_fn("math.sign", 1, fn_sign).
scalar_fn("abs", 1, fn_abs).
scalar_fn("round", _, fn_round).
scalar_fn("math.pow", 2, fn_pow).
scalar_fn("math.fma", 3, fn_fma).
scalar_fn("min", _, fn_min).
scalar_fn("max", _, fn_max).
scalar_fn("math.degrees", 1, fn_degrees).
scalar_fn("math.radians", 1, fn_radians).
scalar_fn("distance.great_circle", 4, fn_great_circle).
scalar_fn("len", 1, fn_str_length).
scalar_fn("distance.euclidean", 4, fn_euclidean_2d).
scalar_fn("distance.euclidean", 6, fn_euclidean_3d).
scalar_fn("distance.manhattan", 4, fn_manhattan_2d).
scalar_fn("distance.manhattan", 6, fn_manhattan_3d).
scalar_fn("distance.chebyshev", 4, fn_chebyshev_2d).
scalar_fn("distance.chebyshev", 6, fn_chebyshev_3d).
scalar_fn("distance.cosine", 4, fn_cosine_2d).
scalar_fn("distance.cosine", 6, fn_cosine_3d).
scalar_fn("distance.hypotenuse", 2, fn_hypotenuse_2d).
scalar_fn("distance.hypotenuse", 3, fn_hypotenuse_3d).
scalar_fn("calendar.time", 3, fn_calendar_time).
scalar_fn("calendar.time", 6, fn_calendar_time).
scalar_fn("calendar.time", 7, fn_calendar_time).
scalar_fn("calendar.date", 3, fn_calendar_date).

    % `FN_CALENDAR_TIME` takes seven operands always; the omitted fields are 0.
    %
    %@spec [LTIM.14.1]
:- func ltim_14_1_operands(builtin_fn, list(expr)) = list(expr).

ltim_14_1_operands(Op, Es) = Operands :-
    ( if Op = fn_calendar_time then
        Operands = Es ++ list.duplicate(7 - list.length(Es), e_lit(int(0i64)))
    else
        Operands = Es
    ).

    % What a `distance.great_circle` argument needs before the call.
    %
    %@helper
:- type degree_arg
    --->    da_as_is
    ;       da_convert(rlow_7_3_9_conversion)
    ;       da_unconvertible.
            % An `angle` with no `degree` in scope to convert it by.

    % An angle known at compile time is folded into a `degree` literal; any other
    % is converted when the call is evaluated ([RLOW.7.3.9]). Anything else is
    % degrees already.
    %
    %@spec [LEXP.5.11.1]
:- pred lexp_5_11_1_degree_arg(ctx::in, lgra_9_3_1_expr::in,
                               lgra_9_3_1_expr::out, degree_arg::out) is det.

lexp_5_11_1_degree_arg(Ctx, Arg, InDegrees, Degree) :-
    RF = Ctx ^ cx_rf,
    % The file's `angle`, else `units.si`'s, which [LEXP.5.11.1] reads in degrees.
    Angle = ( if map.search(RF ^ rf_types, "angle", te_unit(uk_scalar, Bound))
              then Bound
              else decl_ref("units.si", "angle") ),
    ( if
        known_quantity(RF, let_rhs_of(Ctx), shadows_const(Ctx), Arg,
            Angle, Base),
        in_unit_literal(RF, "degree", Angle, Base, expr_start(Arg), Literal)
    then
        InDegrees = Literal,
        Degree = da_as_is
    else if argument_quantity_of(Ctx, Arg, Angle) then
        InDegrees = Arg,
        ( if rlow_7_3_9_conversion(RF, Angle, "degree", Conv) then
            Degree = da_convert(Conv)
        else
            Degree = da_unconvertible
        )
    else
        InDegrees = Arg,
        Degree = da_as_is
    ).

    %@helper
:- func lexp_5_11_1_in_degrees(list(degree_arg), list(expr))
    = lowered(list(expr)).

lexp_5_11_1_in_degrees([], _) = done([]).
lexp_5_11_1_in_degrees([_ | _], []) = done([]).
lexp_5_11_1_in_degrees([D | Ds], [E | Es]) = Result :-
    (
        D = da_as_is,
        Head = done(E)
    ;
        D = da_convert(Conv),
        Head = rlow_7_3_9_converted(Conv, E)
    ;
        D = da_unconvertible,
        Head = skipped("an `angle` argument to `distance.great_circle` with "
            ++ "no `degree` in scope to convert it by ([LEXP.5.11.1]); "
            ++ "import `degree` from `units.si`")
    ),
    Tail = lexp_5_11_1_in_degrees(Ds, Es),
    ( if Head = done(H), Tail = done(T) then
        Result = done([H | T])
    else if Head = skipped(Why) then
        Result = skipped(Why)
    else if Tail = skipped(Why) then
        Result = skipped(Why)
    else
        unexpected($pred, "both done or one skipped")
    ).

    % The zero-argument members with a builtin of their own.
    %
    %@spec [LGRA.9.6.2]
    %@spec [LEXP.3.7.1]
    %@spec [LTIM.3.1.1]
:- pred lgra_9_6_2_member_fn(leaf_kind::in, string::in, builtin_fn::out)
    is semidet.

lgra_9_6_2_member_fn(lk_int, "bit_count", fn_bit_count).
lgra_9_6_2_member_fn(lk_int, "bit_length", fn_bit_length).
lgra_9_6_2_member_fn(lk_int, "leading_zeros", fn_leading_zeros).
lgra_9_6_2_member_fn(lk_int, "trailing_zeros", fn_trailing_zeros).
lgra_9_6_2_member_fn(lk_time, "utc", fn_utc).

    % The members with an argument list and a builtin of their own, and how many
    % arguments each takes.
    %
    %@spec [LGRA.9.6.2]
    %@spec [LTIM.3.2.1]
    %@spec [LTIM.7.1]
    %@spec [LEXP.3.7.3]
:- pred lgra_9_6_2_member_call_fn(leaf_kind::in, string::in, int::out,
                                  builtin_fn::out) is semidet.

lgra_9_6_2_member_call_fn(lk_time, "local", 1, fn_local).
lgra_9_6_2_member_call_fn(lk_time, "floor", 1, fn_floor_time).
lgra_9_6_2_member_call_fn(lk_int, "bits", 2, fn_bits).
lgra_9_6_2_member_call_fn(lk_int, "sign_extend", 1, fn_sign_extend).
lgra_9_6_2_member_call_fn(lk_int, "swap_bytes", 1, fn_swap_bytes).

    % `<receiver>.<method>(<args>)`: the receiver is the first argument on the
    % wire. [LUNI.13.5]'s roundings carry the mode as its code and `round_to`'s
    % unit as its size in base units. `.to_currency` inlines the pair, which has
    % no atom. A `round_to` unit that is no integer scale of the base stays
    % unlowered.
    %
    %@spec [LUNI.13.5]
    %@spec [LUNI.13.6]
    %@spec [LUNI.13.4]
    %@spec [LTIM.8.1.2]
:- pred luni_13_5_method_call(ctx::in, lgra_9_3_1_expr::in, ident::in,
                          list(lgra_9_3_1_expr)::in, lowered(expr)::out,
                          intern_table::in, intern_table::out) is det.

luni_13_5_method_call(Ctx, Receiver, Method, Args, Result, !IT) :-
    Name = Method ^ id_name,
    ( if
        Name = "round",
        Args = [ex_string(Mode, _)],
        round_mode_code(Mode, Code)
    then
        lower_args(Ctx, [Receiver], [], ArgsRes, !IT),
        Result = with_args(ArgsRes,
            ( func(Es) = e_call(fn_currency_round,
                Es ++ [e_lit(int(int64.from_int(Code)))]) ))
    else if
        Name = "round_to",
        Args = [ex_name(Unit), ex_string(Mode, _)],
        round_mode_code(Mode, Code),
        unit_scale(Ctx ^ cx_rf, Unit ^ id_name, Scale)
    then
        lower_args(Ctx, [Receiver], [], ArgsRes, !IT),
        Result = with_args(ArgsRes,
            ( func(Es) = e_call(fn_currency_round_to,
                Es ++ [e_lit(int(Scale)), e_lit(int(int64.from_int(Code)))]) ))
    else if
        Name = "to_currency",
        Args = [ex_name(PairId)],
        fx_pair_of(Ctx ^ cx_rf, PairId ^ id_name, Pair),
        Pair = au_fx_pair(_, _, _, Via, Selector, NumSlot, DenSlot, _),
        fx_selector(Selector, SelectorPairs)
    then
        % (amount, pair, via, num, den, [slot, value]...).
        list.foldl2(intern_name_lit,
            [PairId ^ id_name, limp_13_1_own_of(Ctx ^ cx_rf, Via ^ id_name),
                NumSlot ^ id_name, DenSlot ^ id_name],
            [], NameLits, !IT),
        list.foldl2(selector_lits, SelectorPairs, done([]), SelectorRes, !IT),
        lower_args(Ctx, [Receiver], [], ArgsRes, !IT),
        ( if
            ArgsRes = done(Es),
            SelectorRes = done(SelectorLits)
        then
            Result = done(e_call(fn_currency_convert,
                Es ++ list.reverse(NameLits) ++ SelectorLits))
        else if ArgsRes = skipped(Why) then
            Result = skipped(Why)
        else if SelectorRes = skipped(Why2) then
            Result = skipped(Why2)
        else
            Result = skipped("a method call is not lowered yet")
        )
    else if
        Name = "to_string",
        Args = [_],
        Ctx ^ cx_env = yes(Env),
        type_of_expr(Env, Receiver) = ty_known(ReceiverType),
        ( ReceiverType ^ dt_leaf = lk_time
        ; ReceiverType ^ dt_leaf = lk_date
        )
    then
        % One builtin: the runtime tells them apart by the tag every `Time`
        % carries ([LTIM.1.1.3]).
        lower_args(Ctx, [Receiver | Args], [], ArgsRes, !IT),
        Result = with_args(ArgsRes,
            ( func(Es) = e_call(fn_to_string, Es) ))
    else if
        Name = "to_string",
        Args = [],
        Ctx ^ cx_env = yes(Env),
        type_of_expr(Env, Receiver) = ty_known(ReceiverType),
        ReceiverType ^ dt_leaf = lk_duration
    then
        % A builtin of its own: a `Duration` and a `Date` are both an untagged
        % Int at run time.
        lower_args(Ctx, [Receiver], [], ArgsRes, !IT),
        Result = with_args(ArgsRes,
            ( func(Es) = e_call(fn_duration_to_string, Es) ))
    else if
        Name = "date",
        Args = [_],
        Ctx ^ cx_env = yes(Env),
        type_of_expr(Env, Receiver) = ty_known(ReceiverType),
        ReceiverType ^ dt_leaf = lk_time
    then
        lower_args(Ctx, [Receiver | Args], [], ArgsRes, !IT),
        Result = with_args(ArgsRes,
            ( func(Es) = e_call(fn_time_date, Es) ))
    else if
        Ctx ^ cx_env = yes(Env),
        type_of_expr(Env, Receiver) = ty_known(ReceiverType),
        lgra_9_6_2_member_call_fn(ReceiverType ^ dt_leaf, Name, Arity, Fn),
        list.length(Args, NArgs),
        NArgs = Arity
    then
        lower_args(Ctx, [Receiver | Args], [], ArgsRes, !IT),
        Result = with_args(ArgsRes, ( func(Es) = e_call(Fn, Es) ))
    else if
        ( Name = "add_months", ShiftFn = fn_add_months
        ; Name = "add_years", ShiftFn = fn_add_years
        ),
        Args = [_]
    then
        % One builtin over a `Time` and a `Date` ([LTIM.4.3.1]), told apart by
        % the tag.
        lower_args(Ctx, [Receiver | Args], [], ArgsRes, !IT),
        Result = with_args(ArgsRes,
            ( func(Es) = e_call(ShiftFn, Es) ))
    else
        Result = skipped("a method call is not lowered yet")
    ).

    % The two members that give a `Time` a zone: the instant, and the zone
    % argument, `no` for `t.utc`.
    %
    %@helper
:- pred ltim_6_5_zone(lgra_9_3_1_expr::in, lgra_9_3_1_expr::out,
                      maybe(lgra_9_3_1_expr)::out) is semidet.

ltim_6_5_zone(Zoned, T, Zone) :-
    (
        Zoned = ex_slot(T, Member, _),
        Member ^ id_name = "utc",
        Zone = no
    ;
        Zoned = ex_call(ex_slot(T, Member, _), [Tz], _),
        Member ^ id_name = "local",
        Zone = yes(Tz)
    ).

    %@helper
:- pred ltim_6_5_fn(string::in, builtin_fn::out) is semidet.

ltim_6_5_fn("hour", fn_hour).
ltim_6_5_fn("minute", fn_minute).
ltim_6_5_fn("second", fn_second).
ltim_6_5_fn("day", fn_day).
ltim_6_5_fn("month", fn_month).
ltim_6_5_fn("year", fn_year).
ltim_6_5_fn("day_of_week", fn_day_of_week).

    %@helper
:- pred ltim_6_6_fn(string::in, builtin_fn::out) is semidet.

ltim_6_6_fn("day", fn_day).
ltim_6_6_fn("month", fn_month).
ltim_6_6_fn("year", fn_year).
ltim_6_6_fn("day_of_week", fn_day_of_week).

    % A call to a `unit formula`'s function, inlined. The argument is lowered in
    % the caller's scope; the body with the parameter bound to it and nothing else
    % in scope, as written and not folded ([LUNI.4.5]). Only base units on both
    % ends are lowered: a value is held in its dimension's base unit
    % ([LUNI.4.3]).
    %
    %@spec [LGRA.9.8.11]
    %@spec [LUNI.4.5]
:- pred lgra_9_8_11_formula_call(ctx::in, ast_formula_line::in,
                                 lgra_9_3_1_expr::in, lowered(expr)::out,
                                 intern_table::in, intern_table::out) is det.

lgra_9_8_11_formula_call(Ctx, Line, Arg, Result, !IT) :-
    RF = Ctx ^ cx_rf,
    Param = Line ^ afl_param_type ^ id_name,
    Return = Line ^ afl_return ^ id_name,
    ( if
        luni_4_3_base_unit(RF, Param),
        luni_4_3_base_unit(RF, Return)
    then
        rlow_6_1_1_expr(Ctx, Arg, ArgRes, !IT),
        (
            ArgRes = done(ArgE),
            BodyCtx = ((Ctx ^ cx_pats := []) ^ cx_env := no)
                ^ cx_lets := [let_lowered(Line ^ afl_param ^ id_name, ArgE)],
            rlow_6_1_1_expr(BodyCtx, Line ^ afl_body, Result, !IT)
        ;
            ArgRes = skipped(Why),
            Result = skipped(Why)
        )
    else
        Result = skipped("`" ++ Line ^ afl_name ^ id_name ++ "` converts `"
            ++ Param ++ "` to `" ++ Return ++ "`, and a `unit formula` whose "
            ++ "units are not their dimensions' bases is not lowered yet")
    ).

    % A `const` read, as its RHS, lowered with no binding, `let` or right side in
    % scope: a name inside it is another const. Inlined, not folded.
    %
    %@helper
:- pred lgra_13_3_const(ctx::in, lgra_9_3_1_expr::in, lowered(expr)::out,
                        intern_table::in, intern_table::out) is det.

lgra_13_3_const(Ctx, ConstExpr, Result, !IT) :-
    ConstCtx = ((Ctx ^ cx_lets := []) ^ cx_pats := []) ^ cx_right := no,
    rlow_6_1_1_expr(ConstCtx, ConstExpr, Result, !IT).

    % Lowering a constant's value reads its unit literals in the file declaring
    % it.
    %
    %@spec [LIMP.1.5]
:- func limp_1_5_const_ctx(ctx, ast_const) = ctx.

limp_1_5_const_ctx(Ctx0, Const) = Ctx :-
    Ctx1 = Ctx0 ^ cx_rf := const_scope(Ctx0 ^ cx_rf, Const),
    ( if Ctx1 ^ cx_env = yes(Env) then
        Ctx = Ctx1 ^ cx_env :=
            yes(Env ^ te_file := const_scope(Env ^ te_file, Const))
    else
        Ctx = Ctx1
    ).

    % `<magnitude>_<unit>` for a tier-2 unit: the unit's `to_base` expression at
    % `x = magnitude`, lowered and not folded ([LDET.3.3a.7]).
    %
    %@spec [LUNI.4.3]
    %@spec [LUNI.3.3]
:- pred luni_4_3_tier2_literal(ctx::in, bool::in, string::in, string::in,
                               lowered(expr)::out,
                               intern_table::in, intern_table::out) is det.

luni_4_3_tier2_literal(Ctx, Negated, Magnitude, Symbol, Result, !IT) :-
    RF = Ctx ^ cx_rf,
    ( if
        luni_4_3_tier2_to_base(RF, Symbol, ToBase),
        dsc.exact.from_decimal(string.replace_all(Magnitude, "_", ""), Exact),
        dsc.exact.to_float(Exact, X0)
    then
        ( if Negated = yes then X = -X0 else X = X0 ),
        BodyCtx = ((Ctx ^ cx_pats := []) ^ cx_env := no)
            ^ cx_lets := [let_lowered("x", e_lit(float(X)))],
        rlow_6_1_1_expr(BodyCtx, ToBase, Result, !IT)
    else
        Result = skipped("a unit literal whose unit has no tier-1 or tier-2 "
            ++ "conversion is not lowered yet")
    ).

    % A declared `unit fx_pair`, by name, from every unit in scope.
    %
    %@helper
:- pred fx_pair_of(resolved_file::in, string::in, ast_unit::out) is semidet.

fx_pair_of(RF, Name, Pair) :-
    list.find_first_match(
        ( pred(U::in) is semidet :-
            U = au_fx_pair(PairName, _, _, _, _, _, _, _),
            PairName ^ id_name = Name
        ), RF ^ rf_units, Pair).

    % The selector's `(slot, "value")` equalities in declaration order
    % ([LUNI.4.6]).
    %
    %@helper
:- pred fx_selector(lgra_9_3_1_expr::in, list({string, string})::out)
    is semidet.

fx_selector(Expr, Pairs) :-
    ( if Expr = ex_binary(bo_and, Left, Right, _) then
        fx_selector(Left, LeftPairs),
        fx_selector(Right, RightPairs),
        Pairs = LeftPairs ++ RightPairs
    else
        Expr = ex_compare(Lhs, [lgra_9_3_2_compare_step(co_eq,
            ex_string(Value, _), _)], _),
        ( Lhs = ex_name(SlotId) ; Lhs = ex_slot(_, SlotId, _) ),
        Pairs = [{SlotId ^ id_name, Value}]
    ).

    %@helper
:- pred intern_name_lit(string::in, list(expr)::in, list(expr)::out,
                        intern_table::in, intern_table::out) is det.

intern_name_lit(Name, Lits, [e_lit(str(Ref)) | Lits], !IT) :-
    intern(Name, Ref, !IT).

    %@helper
:- pred selector_lits({string, string}::in, lowered(list(expr))::in,
                      lowered(list(expr))::out,
                      intern_table::in, intern_table::out) is det.

selector_lits({Slot, Value}, Acc, Result, !IT) :-
    (
        Acc = done(Lits),
        intern(Slot, SlotRef, !IT),
        literal_string(Value, ValueRes, !IT),
        (
            ValueRes = done(ValueE),
            Result = done(Lits ++ [e_lit(str(SlotRef)), ValueE])
        ;
            ValueRes = skipped(Why),
            Result = skipped(Why)
        )
    ;
        Acc = skipped(Why2),
        Result = skipped(Why2)
    ).

    %@helper
:- func with_args(lowered(list(expr)), (func(list(expr)) = expr))
    = lowered(expr).

with_args(done(Es), Build) = done(Build(Es)).
with_args(skipped(Why), _) = skipped(Why).

    % libds's `ds_currency_round_mode_t`: wire-visible and append-only.
    %
    %@helper
:- pred round_mode_code(string::in, int::out) is semidet.

round_mode_code("half_even", 0).
round_mode_code("half_up", 1).
round_mode_code("half_down", 2).
round_mode_code("ceiling", 3).
round_mode_code("floor", 4).
round_mode_code("truncate", 5).

    % A unit symbol's size in its dimension's base units: 1 for the base, `N` for
    % `= x * N` or `= N * x` with a positive integer `N`.
    %
    %@helper
:- pred unit_scale(resolved_file::in, string::in, int64::out) is semidet.

unit_scale(RF, Name0, Scale) :-
    ( if map.search(RF ^ rf_unit_alias, Name0, Canonical) then
        Name = Canonical ^ id_name
    else
        Name = Name0
    ),
    list.find_first_match(
        ( pred(U::in) is semidet :-
            U = au_symbol(Symbol, _, _, _, _, _, _, _),
            Symbol ^ id_name = Name
        ), RF ^ rf_units, Decl),
    Decl = au_symbol(_, _, Body, _, _, _, _, _),
    (
        Body = aub_base,
        Scale = 1i64
    ;
        Body = aub_affine(Affine),
        (
            Affine = ex_binary(bo_mul, ex_name(X), ex_int(Scale, _), _)
        ;
            Affine = ex_binary(bo_mul, ex_int(Scale, _), ex_name(X), _)
        ),
        X ^ id_name = "x",
        Scale > 0i64
    ).

    %@helper
:- pred lower_args(ctx::in, list(lgra_9_3_1_expr)::in, list(expr)::in,
                   lowered(list(expr))::out,
                   intern_table::in, intern_table::out) is det.

lower_args(_, [], Acc, done(list.reverse(Acc)), !IT).
lower_args(Ctx, [A | As], Acc, Result, !IT) :-
    rlow_6_1_1_expr(Ctx, A, ARes, !IT),
    (
        ARes = done(E),
        lower_args(Ctx, As, [E | Acc], Result, !IT)
    ;
        ARes = skipped(Why),
        Result = skipped(Why)
    ).

    % `a < b <= c` is `and(lt(a, b), le(b, c))`, left-nested beyond two. Each step's
    % left operand is carried as written too, for `luni_4_5_2_step`.
    %
    %@spec [RLOW.6.2.1]
:- pred rlow_6_2_1_chain(ctx::in, lgra_9_3_1_expr::in, expr::in,
                       list(lgra_9_3_2_compare_step)::in,
                       maybe(expr)::in, lowered(expr)::out,
                       intern_table::in, intern_table::out) is det.

rlow_6_2_1_chain(_, _, _, [], Acc, Result, !IT) :-
    (
        Acc = yes(E),
        Result = done(E)
    ;
        Acc = no,
        Result = skipped("a comparison with no operator")
    ).
rlow_6_2_1_chain(Ctx, LeftAst, Left, [Step | Steps], Acc, Result, !IT) :-
    rlow_6_1_1_expr(Ctx, Step ^ cs_right, RightRes, !IT),
    (
        RightRes = done(Right),
        ( if
            luni_4_5_2_step(Ctx, LeftAst, Step ^ cs_right, Step ^ cs_op,
                Line, Op)
        then
            lgra_9_8_11_formula_call(Ctx, Line, LeftAst, LeftRes, !IT),
            (
                LeftRes = done(Converted),
                CmpRes = done(e_binop(compare_op(Op), Converted, Right))
            ;
                LeftRes = skipped(LeftWhy),
                CmpRes = skipped(LeftWhy)
            )
        else
            CmpRes = done(e_binop(compare_op(Step ^ cs_op), Left, Right))
        ),
        (
            CmpRes = done(Cmp),
            (
                Acc = no,
                Next = Cmp
            ;
                Acc = yes(Prior),
                Next = e_binop(op_and, Prior, Cmp)
            ),
            rlow_6_2_1_chain(Ctx, Step ^ cs_right, Right, Steps, yes(Next),
                Result, !IT)
        ;
            CmpRes = skipped(Why),
            Result = skipped(Why)
        )
    ;
        RightRes = skipped(Why),
        Result = skipped(Why)
    ).

    % A comparison between two dimensions that exactly one `implicit` formula
    % bridges converts the left operand into the right's dimension. For an
    % `inverting` formula the operator flips. Fails, and the step compares as
    % written, when the two sides share a dimension, when either has none, or with
    % no typing environment.
    %
    %@spec [LUNI.4.5.2]
:- pred luni_4_5_2_step(ctx::in, lgra_9_3_1_expr::in, lgra_9_3_1_expr::in,
                        lgra_9_3_2_compare_op::in, ast_formula_line::out,
                        lgra_9_3_2_compare_op::out) is semidet.

luni_4_5_2_step(Ctx, LeftAst, RightAst, Op0, Line, Op) :-
    Ctx ^ cx_env = yes(Env),
    type_of_expr(Env, LeftAst) = ty_known(LType),
    LType ^ dt_dim = dim(LeftDim, _),
    type_of_expr(Env, RightAst) = ty_known(RType),
    RType ^ dt_dim = dim(RightDim, _),
    LeftDim \= RightDim,
    luni_4_5_implicit_formula(Ctx ^ cx_rf, LeftDim, RightDim, Line, Inverting),
    (
        Inverting = yes,
        Op = luni_4_5_2_flip(Op0)
    ;
        Inverting = no,
        Op = Op0
    ).

    %@helper
:- func luni_4_5_2_flip(lgra_9_3_2_compare_op) = lgra_9_3_2_compare_op.

luni_4_5_2_flip(co_eq) = co_eq.
luni_4_5_2_flip(co_ne) = co_ne.
luni_4_5_2_flip(co_lt) = co_gt.
luni_4_5_2_flip(co_le) = co_ge.
luni_4_5_2_flip(co_gt) = co_lt.
luni_4_5_2_flip(co_ge) = co_le.

    %@helper
:- func compare_op(lgra_9_3_2_compare_op) = binop.

compare_op(co_eq) = op_eq.
compare_op(co_ne) = op_ne.
compare_op(co_lt) = op_lt.
compare_op(co_le) = op_le.
compare_op(co_gt) = op_gt.
compare_op(co_ge) = op_ge.

    %@helper
:- pred is_subject_of(dsc.expr.is_subject::in, ds.expr.is_subject::out)
    is semidet.

is_subject_of(dsc.expr.is_null, ds.expr.is_null).
is_subject_of(is_bool(yes), is_true).
is_subject_of(is_bool(no), is_false).
is_subject_of(is_inf(inf_positive), is_inf).
is_subject_of(is_inf(inf_negative), is_neg_inf).
is_subject_of(dsc.expr.is_nan, ds.expr.is_nan).
is_subject_of(is_tag(Id), Subject) :-
    tag_subject(Id ^ id_name, Subject).

    %@helper
:- pred tag_subject(string::in, ds.expr.is_subject::out) is semidet.

tag_subject("Int", is_int).
tag_subject("Float", is_float).
tag_subject("Bool", ds.expr.is_bool).
tag_subject("String", is_string).
tag_subject("Bytes", is_bytes).
tag_subject("Json", is_json).

    % The pattern a binding names, and its source index.
    %
    %@helper
:- pred binding_index(list(pat)::in, string::in, int::in, int::out, pat::out)
    is semidet.

binding_index([P | Ps], Name, I, K, Found) :-
    ( if P ^ pt_binding = Name then
        K = I,
        Found = P
    else
        binding_index(Ps, Name, I + 1, K, Found)
    ).

    % Which fact a read of pattern K is: the candidate inside K's own `where`, a
    % token position otherwise.
    %
    %@helper
:- pred fact_of(ctx::in, int::in, pat::in, lowered(fact_index)::out) is det.

fact_of(Ctx, K, P, Result) :-
    Right = Ctx ^ cx_right,
    ( if Right = yes(K) then
        Result = done(candidate)
    else if Right = yes(R), K > R then
        Result = skipped("a `where` reads a pattern that has not joined yet")
    else if P ^ pt_negated = yes then
        Result = skipped("a negated pattern's binding is read outside its "
            ++ "own `where`")
    else
        Result = done(token_fact(P ^ pt_token))
    ).

%-----------------------------------------------------------------------------%
% Strings -- [LGRA.2.9.1] escapes, [RLOW.6.4] interpolation
%-----------------------------------------------------------------------------%

    %@helper
:- pred literal_string(string::in, lowered(expr)::out,
                       intern_table::in, intern_table::out) is det.

literal_string(Text, Result, !IT) :-
    Unescaped = unescape(string.to_char_list(brace_escapes(Text))),
    (
        Unescaped = done(Chars),
        intern(string.from_char_list(Chars), Ref, !IT),
        Result = done(e_lit(str(Ref)))
    ;
        Unescaped = skipped(Why),
        Result = skipped(Why)
    ).

    % An interpolation-eligible string: a literal when it has no site, else an
    % `InterpExpr`: its literal runs as text primitives, adjacent ones merged, and
    % each site as a `ValuePrim` or a `TimePrim` with its spec resolved into the
    % primitive's fields. A site with no spec is a `ValuePrim` with every field at
    % zero.
    %
    %@spec [RLOW.6.4.1]
    %@spec [RLOW.6.4.2]
    %@spec [RLOW.6.4.4]
    %@spec [RLOW.13.6]
:- pred rlow_6_4_1_message(ctx::in, string::in, lowered(expr)::out,
                         intern_table::in, intern_table::out) is det.

rlow_6_4_1_message(Ctx, Text, Result, !IT) :-
    Segments = segments(string.to_char_list(Text)),
    ( if list.all_true((pred(S::in) is semidet :- S = seg_text(_)), Segments)
    then
        literal_string(Text, Result, !IT)
    else
        lower_segments(Ctx, Segments, [], PrimsRes, !IT),
        (
            PrimsRes = done(Prims),
            Result = done(iret_9_6_interp_stamp(e_interp(merge_text(Prims))))
        ;
            PrimsRes = skipped(Why),
            Result = skipped(Why)
        )
    ).

    % Both runtimes read the flag on the interpolation node, stamped when any
    % segment's value is a `Json` projection. Here because a segment's value is
    % built by `rlow_6_3_1_path` and never passes through `rlow_6_1_1_expr`.
    %
    %@spec [IRET.9.6]
:- func iret_9_6_interp_stamp(expr) = expr.

iret_9_6_interp_stamp(E) = Stamped :-
    ( if
        list.member(Child, expr_children(E)),
        ( provflag1_projection(Child)
        ; Child = e_tainted(_)
        )
    then
        Stamped = e_tainted(E)
    else
        Stamped = E
    ).

    %@helper
:- type segment
    --->    seg_text(list(char))
    ;       seg_site(list(char)).

    % A string's runs and sites, as `dsc.strlit` reads them.
    %
    %@helper
:- func segments(list(char)) = list(segment).

segments(Chars) = list.map(piece_segment, lgra_2_9_6_7_pieces(Chars)).

    %@helper
:- func piece_segment(piece) = segment.

piece_segment(p_text(Text)) = seg_text(Text).
piece_segment(p_site(Body)) = seg_site(Body).
piece_segment(p_empty) = seg_text(['{', '}']).
piece_segment(p_unclosed(Text)) = seg_text(Text).

    %@helper
:- pred text_has_site(list(char)::in) is semidet.

text_has_site(Chars) :-
    has_site(lgra_2_9_6_7_pieces(Chars)).

    % `{{` and `}}` collapsed, for a string that has no sites.
    %
    %@helper
:- func brace_escapes(string) = string.

brace_escapes(Text) =
    string.replace_all(string.replace_all(Text, "{{", "{"), "}}", "}").

    %@helper
:- pred lower_segments(ctx::in, list(segment)::in, list(format_prim)::in,
                       lowered(list(format_prim))::out,
                       intern_table::in, intern_table::out) is det.

lower_segments(_, [], Acc, done(list.reverse(Acc)), !IT).
lower_segments(Ctx, [S | Ss], Acc, Result, !IT) :-
    (
        S = seg_text(Chars),
        Unescaped = unescape(Chars),
        (
            Unescaped = done(Text),
            lower_segments(Ctx, Ss, [fp_text(string.from_char_list(Text)) | Acc],
                Result, !IT)
        ;
            Unescaped = skipped(Why),
            Result = skipped(Why)
        )
    ;
        S = seg_site(Body),
        site(Ctx, Body, SiteRes, !IT),
        (
            SiteRes = done(P),
            lower_segments(Ctx, Ss, [P | Acc], Result, !IT)
        ;
            SiteRes = skipped(Why),
            Result = skipped(Why)
        )
    ).

    % Adjacent text primitives as one, and an empty one dropped.
    %
    %@helper
:- func merge_text(list(format_prim)) = list(format_prim).

merge_text([]) = [].
merge_text([P | Ps]) = Out :-
    Rest = merge_text(Ps),
    ( if P = fp_text("") then
        Out = Rest
    else if P = fp_text(A), Rest = [fp_text(B) | Rest1] then
        Out = [fp_text(A ++ B) | Rest1]
    else
        Out = [P | Rest]
    ).

    %@helper
:- pred site(ctx::in, list(char)::in, lowered(format_prim)::out,
             intern_table::in, intern_table::out) is det.

site(Ctx, Body, Result, !IT) :-
    ( if split_colon(Body, PathChars, SpecChars) then
        Path = string.from_char_list(PathChars),
        Spec = yes(SpecChars)
    else
        Path = string.from_char_list(Body),
        Spec = no
    ),
    site_value(Ctx, Path, ValueRes, !IT),
    (
        ValueRes = done(Value),
        (
            Spec = no,
            Result = done(fp_value(canonical_prim(
                lgra_2_9_6_10_temporal_text(Ctx, Path, Value))))
        ;
            Spec = yes(SpecText),
            Read = lgra_2_9_6_1_format(SpecText),
            (
                Read = spec_ok(Format),
                ( if
                    Format = if_num(NF),
                    NF ^ nf_type = yes('u')
                then
                    luni_11_4_label_prim(Ctx, Path, NF, Result, !IT)
                else
                    Result = done(rlow_6_4_resolve(Format, Value))
                )
            ;
                Read = spec_bad(Why),
                Result = skipped("a format spec that does not parse: " ++ Why)
            )
        )
    ;
        ValueRes = skipped(Why),
        Result = skipped(Why)
    ).

    % A temporal site with no type is the String its own `to_string` builtin gives,
    % the `Time` through `FN_UTC`. Any other site, or one of a type not seen here,
    % is its value unchanged.
    %
    %@spec [LGRA.2.9.6.10]
:- func lgra_2_9_6_10_temporal_text(ctx, string, expr) = expr.

lgra_2_9_6_10_temporal_text(Ctx, Path, Value) = Text :-
    ( if
        Ctx ^ cx_env = yes(Env),
        site_expr(string.to_char_list(Path), Expr),
        type_of_expr(Env, Expr) = ty_known(Type)
    then
        Leaf = Type ^ dt_leaf,
        ( if Leaf = lk_time then
            Text = e_call(fn_to_string, [e_call(fn_utc, [Value])])
        else if Leaf = lk_date then
            Text = e_call(fn_to_string, [Value])
        else if Leaf = lk_duration then
            Text = e_call(fn_duration_to_string, [Value])
        else
            Text = Value
        )
    else
        Text = Value
    ).

    %@helper
:- func canonical_prim(expr) = value_prim.

canonical_prim(Value) =
    value_prim(Value, align_default, no, no, 0u32, no, ft_canonical).

    % `{x:u}`: the unit's label, as a String literal under the spec's alignment,
    % width and precision. A site with no known unit symbol is not lowered.
    %
    %@spec [LUNI.11.4]
:- pred luni_11_4_label_prim(ctx::in, string::in, num_format::in,
                             lowered(format_prim)::out,
                             intern_table::in, intern_table::out) is det.

luni_11_4_label_prim(Ctx, Path, NF, Result, !IT) :-
    ( if
        Ctx ^ cx_env = yes(Env),
        site_expr(string.to_char_list(Path), Expr),
        type_of_expr(Env, Expr) = ty_known(Type),
        Type ^ dt_dim = dim(_, yes(Symbol))
    then
        Decoded = unescape(string.to_char_list(
            unit_label(Ctx ^ cx_rf ^ rf_units, Symbol))),
        (
            Decoded = done(LabelChars),
            intern(string.from_char_list(LabelChars), Ref, !IT),
            Result = done(fp_value(value_prim(e_lit(str(Ref)),
                align_of(NF ^ nf_align), no, no, wire_count(NF ^ nf_width),
                NF ^ nf_precision, ft_canonical)))
        ;
            Decoded = skipped(Why),
            Result = skipped(Why)
        )
    else
        Result = skipped("`u` on a value whose unit symbol is not known here")
    ).

    %@helper
:- func unit_label(list(ast_unit), decl_ref) = string.

unit_label([], Symbol) = Symbol ^ dr_name.
unit_label([U | Us], Symbol) = Label :-
    ( if
        U = au_symbol(ident(Name, _), _, _, yes(Declared), _, _, File, _),
        Symbol = decl_ref(File, Name)
    then
        Label = Declared
    else if
        U = au_scalar(ident(Name, _), _, yes(Declared), _, File),
        Symbol = decl_ref(File, Name)
    then
        Label = Declared
    else
        Label = unit_label(Us, Symbol)
    ).

    % A parsed spec as a primitive's fields. [LUNI.11.2]'s `i` and `j` are ignored
    % off a complex field.
    %
    %@helper
:- func rlow_6_4_resolve(interp_format, expr) = format_prim.

rlow_6_4_resolve(if_time(Pieces), Value) =
    fp_time(Value, list.map(time_item_of, Pieces)).
rlow_6_4_resolve(if_num(NF), Value) =
    fp_value(value_prim(Value, align_of(NF ^ nf_align), NF ^ nf_plus,
        NF ^ nf_zero, wire_count(NF ^ nf_width), NF ^ nf_precision,
        type_of_spec(NF ^ nf_type))).

    %@helper
:- func time_item_of(time_piece) = time_item.

time_item_of(tp_text(Text)) = ti_text(Text).
time_item_of(tp_dir(D)) = ti_field(Field) :-
    ( if D = 'Y' then Field = tf_year
    else if D = 'm' then Field = tf_month
    else if D = 'd' then Field = tf_day
    else if D = 'H' then Field = tf_hour
    else if D = 'M' then Field = tf_minute
    else if D = 'S' then Field = tf_second
    else if D = 'f' then Field = tf_microsecond
    else if D = 'z' then Field = tf_utc_offset
    else unexpected($pred, "a directive dsc.strlit does not admit")
    ).

    %@helper
:- func align_of(maybe(char)) = format_align.

align_of(no) = align_default.
align_of(yes(C)) = ( if C = ('<') then align_left else align_right ).

    %@helper
:- func wire_count(maybe(uint32)) = uint32.

wire_count(no) = 0u32.
wire_count(yes(N)) = N.

    %@helper
:- func type_of_spec(maybe(char)) = format_type.

type_of_spec(no) = ft_canonical.
type_of_spec(yes(C)) = Type :-
    ( if C = 'd' then Type = ft_d
    else if C = 'f' then Type = ft_f
    else if C = 's' then Type = ft_s
    else if C = 'x' then Type = ft_x_lower
    else if C = 'X' then Type = ft_x_upper
    else if C = 'b' then Type = ft_b
    else Type = ft_canonical     % `i` `j` -- see `rlow_6_4_resolve`
    ).

    % The value a site's body names: a `let`, a constant, a slot, or a longer path.
    %
    %@helper
:- pred site_value(ctx::in, string::in, lowered(expr)::out,
                   intern_table::in, intern_table::out) is det.

site_value(Ctx, Path, Result, !IT) :-
    ( if
        let_named(Ctx ^ cx_lets, Path, [], Def, Scope)
    then
        (
            Def = let_bound(_, Ix),
            Result = done(e_bind_ref(Ix))
        ;
            Def = let_lowered(_, Lowered),
            Result = done(Lowered)
        ;
            Def = let_capture(_, Subject, Pattern, Flags, Group),
            lreg_4_1_capture_expr(Ctx ^ cx_lets := Scope, Subject, Pattern,
                Flags, Group, Result, !IT)
        ;
            Def = let_inline(_, Inlined),
            LetCtx = Ctx ^ cx_lets := Scope,
            % `let v = b.slot` goes through the slot site, as `{b.slot}` would.
            ( if Inlined = ex_slot(ex_name(B), S, _) then
                site_value(LetCtx, B ^ id_name ++ "." ++ S ^ id_name, Result,
                    !IT)
            else
                rlow_6_1_1_expr(LetCtx, Inlined, Result, !IT)
            )
        )
    else if
        site_expr(string.to_char_list(Path), Expr),
        lgra_2_9_6_2_const_site(Ctx, Expr)
    then
        rlow_6_1_1_expr(Ctx, Expr, Result, !IT)
    else
        slot_value(Ctx, Path, Result, !IT)
    ).

    % A site naming a constant: the file's own, `{LIMIT}`, or an imported library's,
    % `{lib.LIMIT}`, with any tail that is access on its value. No binding or `let`
    % can share the root's name ([LLET.12.4], [LGRA.22.9]).
    %
    %@spec [LGRA.2.9.6.2]
:- pred lgra_2_9_6_2_const_site(ctx::in, lgra_9_3_1_expr::in) is semidet.

lgra_2_9_6_2_const_site(Ctx, Expr) :-
    ( Expr = ex_name(Id),
      map.contains(Ctx ^ cx_rf ^ rf_consts, Id ^ id_name)
    ; Expr = ex_slot(Base, _, _),
      ( lgra_22_9_library_member(Ctx ^ cx_rf, Expr, _, _)
      ; lgra_2_9_6_2_const_site(Ctx, Base)
      )
    ).

    % A binding path: `b.slot`, or a longer path.
    %
    %@helper
:- pred slot_value(ctx::in, string::in, lowered(expr)::out,
                   intern_table::in, intern_table::out) is det.

slot_value(Ctx, Path, Result, !IT) :-
    ( if
        string.split_at_char('.', Path) = [BName, SName],
        binding_index(Ctx ^ cx_pats, BName, 0, K, P),
        interned(!.IT, SName, SlotRef),
        slot_by_name(P ^ pt_schema, SlotRef, Common),
        fact_of(Ctx, K, P, done(Fact))
    then
        Result = done(iret_9_6_slot_read(Common,
            e_slot(Fact, slot(Common ^ sc_index))))
    else if
        string.split_at_char('.', Path) = [BName, Seg1 | Segs],
        binding_index(Ctx ^ cx_pats, BName, 0, K, P)
    then
        NoPos = pos(0, 0),
        rlow_6_3_1_path(Ctx, K, P,
            list.map((func(S) = ident(S, NoPos)), [Seg1 | Segs]), Result, !IT)
    else
        Result = skipped("an interpolation site that is not a binding path "
            ++ "or a `let` is not lowered yet")
    ).

    % `b.s1.s2...` as its root binding and the path after it. An integer-literal
    % index is a segment too, spelled `[N]`.
    %
    %@helper
:- pred slot_chain(lgra_9_3_1_expr::in, ident::out, list(ident)::out)
    is semidet.

slot_chain(ex_slot(Target, Seg, _), Root, Segs) :-
    ( if Target = ex_name(Id) then
        Root = Id,
        Segs = [Seg]
    else
        slot_chain(Target, Root, Inner),
        Segs = Inner ++ [Seg]
    ).
slot_chain(ex_index(Target, ex_int(N, _), Pos), Root, Segs) :-
    N >= 0i64,
    slot_chain(Target, Root, Inner),
    Segs = Inner ++ [ident("[" ++ string.int64_to_string(N) ++ "]", Pos)].

    % A `Json` path's text: names joined with `.`, an `[N]` segment appended with
    % none.
    %
    %@helper
:- func json_path_text(list(ident)) = string.

json_path_text(Segs) = string.append_list(path_texts(Segs)).

    %@helper
:- func path_texts(list(ident)) = list(string).

path_texts([]) = [].
path_texts([S | Ss]) = [S ^ id_name | list.map(joined_segment, Ss)].

    %@helper
:- func joined_segment(ident) = string.

joined_segment(S) = Text :-
    Name = S ^ id_name,
    ( if string.prefix(Name, "[") then
        Text = Name
    else
        Text = "." ++ Name
    ).

    % A path from a pattern binding: a declared slot ([RLOW.6.3.1]); a `Json`
    % slot followed by more names, which is a `json_path` call over the slot
    % and the rest of the path joined with `.` ([RLOW.6.3.3]); or, when the
    % head is not a slot, a companion read of up to three components.
    %
    %@spec [RLOW.6.3.1]
    %@spec [RLOW.6.3.3]
    %@spec [RLOW.13.5]
:- pred rlow_6_3_1_path(ctx::in, int::in, pat::in, list(ident)::in,
                        lowered(expr)::out,
                        intern_table::in, intern_table::out) is det.

rlow_6_3_1_path(Ctx, K, P, Segs, Result, !IT) :-
    ( if
        % A capture view's slot named by the whole path.
        Segs = [_, _ | _],
        interned(!.IT, json_path_text(Segs), WholeRef),
        slot_by_name(P ^ pt_schema, WholeRef, Snapshot)
    then
        fact_of(Ctx, K, P, SnapRes),
        (
            SnapRes = done(SnapFact),
            Result = done(iret_9_6_slot_read(Snapshot,
                e_slot(SnapFact, slot(Snapshot ^ sc_index))))
        ;
            SnapRes = skipped(SnapWhy),
            Result = skipped(SnapWhy)
        )
    else if
        Segs = [Head | Tail],
        interned(!.IT, Head ^ id_name, HeadRef),
        slot_by_name(P ^ pt_schema, HeadRef, Common)
    then
        fact_of(Ctx, K, P, FactRes),
        (
            FactRes = skipped(Why),
            Result = skipped(Why)
        ;
            FactRes = done(Fact),
            Var = e_slot(Fact, slot(Common ^ sc_index)),
            (
                Tail = [],
                Result = done(iret_9_6_slot_read(Common, Var))
            ;
                Tail = [_ | _],
                ( if Common ^ sc_kind = k_json then
                    intern(json_path_text(Tail), PathRef, !IT),
                    Result = done(e_call(fn_json_path,
                        [Var, e_lit(str(PathRef))]))
                else
                    Result = skipped("a path through a slot that is not "
                        ++ "`Json`")
                )
            )
        )
    else if lexp_9_5_2_dwell(Ctx, K, P, Segs, DwellRes) then
        Result = DwellRes
    else if list.length(Segs) =< 3 then
        rlow_8_3_1_companion(Ctx, K, P, Segs, Result, !IT)
    else
        Result = skipped("a path this compiler does not lower")
    ).

    % Provenance starts at every `Json` slot read. Here because an `e_slot` does not
    % carry its slot's kind.
    %
    %@spec [IRET.9.6]
:- func iret_9_6_slot_read(slot_common, expr) = expr.

iret_9_6_slot_read(Common, Var) =
    ( if Common ^ sc_kind = k_json then e_tainted(Var) else Var ).

    % `b.dwell` as `monotonic_ns() - entry_stamp(b)` ([LEXP.9.5.1]). The caller
    % answers a declared `dwell` slot first.
    %
    %@spec [LEXP.9.5.2]
    %@spec [RLOW.8.3.5]
:- pred lexp_9_5_2_dwell(ctx::in, int::in, pat::in, list(ident)::in,
                         lowered(expr)::out) is semidet.

lexp_9_5_2_dwell(Ctx, K, P, Segs, Result) :-
    Segs = [Field],
    Field ^ id_name = "dwell",
    fact_of(Ctx, K, P, FactRes),
    (
        FactRes = done(Fact),
        Result = done(e_binop(op_sub, ltim_2_2_1_monotonic_ns,
            e_entry_stamp(Fact)))
    ;
        FactRes = skipped(Why),
        Result = skipped(Why)
    ).

    %@helper
:- pred split_colon(list(char)::in, list(char)::out, list(char)::out)
    is semidet.

split_colon([C | Cs], Before, After) :-
    ( if C = (':') then
        Before = [],
        After = Cs
    else
        split_colon(Cs, Inner, After),
        Before = [C | Inner]
    ).

    %@helper
:- func unescape(list(char)) = lowered(list(char)).

unescape(Chars) = Result :-
    Decoded = lgra_2_9_4_decode(Chars),
    (
        Decoded = decoded(Text),
        Result = done(Text)
    ;
        Decoded = bad_escape(_),
        Result = skipped("an escape `validate` should have refused")
    ).

%-----------------------------------------------------------------------------%
% Actions -- [RLOW.7]
%-----------------------------------------------------------------------------%

    %@helper
:- pred lower_actions(ctx::in, list(schema)::in, list(ast_action)::in,
                      intern_table::in, intern_table::out,
                      list(inline_action)::in,
                      lowered(list(inline_action))::out) is det.

lower_actions(_, _, [], !IT, Acc, done(list.reverse(Acc))).
lower_actions(Ctx, Schemas, [A | As], !IT, Acc, Result) :-
    rlow_7_1_1_action(Ctx, Schemas, A, One, !IT),
    (
        One = done(IA),
        lower_actions(Ctx, Schemas, As, !IT, [IA | Acc], Result)
    ;
        One = skipped(Why),
        Result = skipped(Why)
    ).

    % One RHS action, as the runtime's decoded inline action. The verbs' wire shapes
    % are `ds.dsc_action.verb/5`'s.
    %
    %@spec [RLOW.7.1.1]
    %@spec [RLOW.7.1.3]
    %@spec [RLOW.7.2.1]
    %@spec [RLOW.7.3.1]
    %@spec [RLOW.7.7.1]
    %@spec [RLOW.13.8]
:- pred rlow_7_1_1_action(ctx::in, list(schema)::in, ast_action::in,
                     lowered(inline_action)::out,
                     intern_table::in, intern_table::out) is det.

rlow_7_1_1_action(Ctx, Schemas, Action, Result, !IT) :-
    Head = Action ^ aac_head,
    Kwargs = action_kwargs(Action),
    (
        Head = aah_log(Level0, Text),
        ( if log_level_of(Level0, Level) then
            rlow_6_4_1_message(Ctx, Text, MsgRes, !IT),
            (
                MsgRes = done(Msg),
                Result = done(ia_log(Level, Msg))
            ;
                MsgRes = skipped(Why),
                Result = skipped(Why)
            )
        else
            Result = skipped("an unknown log level")
        )
    ;
        Head = aah_emit(Ref),
        ( if action_schema(Ctx, !.IT, Schemas, Ref, Schema) then
            Mode = ( if has_flag(Action, "logical") then logical else plain ),
            emit_kwargs(Ctx, Schema, Kwargs, [], no, EmitRes, !IT),
            (
                EmitRes = done({Given, Retain}),
                Assigns = Given ++ lgra_13_11_null_fills(Schema, Given),
                Result = done(ia_assert(Mode, schema_name_ref(Schema ^ s_name),
                    Assigns, Retain))
            ;
                EmitRes = skipped(Why),
                Result = skipped(Why)
            )
        else
            Result = skipped("`emit` of a schema not in this artefact")
        )
    ;
        Head = aah_publish(Ref),
        ( if action_schema(Ctx, !.IT, Schemas, Ref, Schema) then
            publish_args(Ctx, schema_name_ref(Schema ^ s_name), Kwargs,
                slot_commons(Schema), [], ArgsRes, !IT),
            % NO `ttl_override`: a `publish` asserts nothing in this tier and
            % takes no lifetime ([LTIE.4.3]), and `retain:` on one is refused
            % before lowering ([LTIE.4.9], `dsc.validate.ltie_4_9_publish_modifier`).
            (
                ArgsRes = done(Args),
                Result = done(ia_publish(schema_name_ref(Schema ^ s_name),
                    Args, no))
            ;
                ArgsRes = skipped(Why),
                Result = skipped(Why)
            )
        else
            Result = skipped("`publish` of a schema not in this artefact")
        )
    ;
        Head = aah_call(Service),
        rlow_7_3_1_call(Ctx, Action, Service, Kwargs, Result, !IT)
    ;
        Head = aah_record_event(_),
        Result = skipped("`record_event` is retired ([LGRA.10.1.5])")
    ;
        Head = aah_cache,
        ( if
            find_kwarg(Kwargs, "key", ex_string(KeyText, _)),
            find_kwarg(Kwargs, "value", ValueExpr)
        then
            literal_string(KeyText, KeyRes, !IT),
            rlow_6_1_1_expr(Ctx, ValueExpr, ValueRes, !IT),
            ( if find_kwarg(Kwargs, "ttl", TtlExpr) then
                rlow_6_1_1_expr(Ctx, TtlExpr, TtlRes, !IT)
            else
                TtlRes = done(e_lit(int(0i64)))
            ),
            ( if
                KeyRes = done(Key),
                ValueRes = done(Value),
                TtlRes = done(Ttl)
            then
                Result = done(ia_cache_set(Key,
                    e_call(fn_json_value, [Value]), yes(Ttl)))
            else
                Result = skipped(first_skip([KeyRes, ValueRes, TtlRes]))
            )
        else
            unexpected($pred, "a `cache` with no literal `key:` or no "
                ++ "`value:` passed validate")
        )
    ;
        Head = aah_cache_delete,
        ( if find_kwarg(Kwargs, "key", ex_string(KeyText, _)) then
            literal_string(KeyText, KeyRes, !IT),
            (
                KeyRes = done(Key),
                Result = done(ia_cache_delete(Key))
            ;
                KeyRes = skipped(Why),
                Result = skipped(Why)
            )
        else
            unexpected($pred, "a `cache_delete` with no literal `key:` passed "
                ++ "validate")
        )
    ;
        Head = aah_withdraw(Binding),
        % `ACTION_WITHDRAW` by `b`'s token position ([RDSC.4a.8]). In a nested
        % body the binding is a capture view, and the withdraw is
        % `ACTION_WITHDRAW_BY_ID` reading the reference it carries ([IRET.10.7]).
        ( if
            binding_index(Ctx ^ cx_pats, Binding ^ id_name, 0, K, P),
            P ^ pt_negated = no
        then
            ( if
                interned(!.IT, "", FactRef),
                slot_by_name(P ^ pt_schema, FactRef, Carried),
                fact_of(Ctx, K, P, done(Fact))
            then
                Result = done(ia_withdraw_by_id(
                    e_slot(Fact, slot(Carried ^ sc_index))))
            else
                Result = done(ia_withdraw(P ^ pt_token))
            )
        else
            Result = skipped("`withdraw " ++ Binding ^ id_name ++ "` names "
                ++ "no positively-bound pattern")
        )
    ).

    %@helper
:- func first_skip(list(lowered(expr))) = string.

first_skip([]) = "".
first_skip([R | Rs]) =
    ( if R = skipped(Why) then Why else first_skip(Rs) ).

    % `call svc.method k: v ... [as <corr>]`. A per-call `cooldown:` is gated
    % afterwards (`rlow_4_6_6_1_call_gates`).
    %
    %@spec [RLOW.7.3.1]
:- pred rlow_7_3_1_call(ctx::in, ast_action::in, ast_service_ref::in,
                      assoc_list(string, lgra_9_3_1_expr)::in,
                      lowered(inline_action)::out,
                      intern_table::in, intern_table::out) is det.

rlow_7_3_1_call(Ctx, Action, Service, Written, Result, !IT) :-
    % [LUNI.4.5.1]'s boundary 4 first, across dimensions; then [LADP.8.5.3] into
    % the kwarg's unit.
    ladp_8_5_3_written_in_unit(Ctx, Service,
        list.map(luni_4_5_1_call_kwarg(Ctx, Service), Written), InUnit,
        Conversions),
    Kwargs = ladp_8_5_1_with_defaults(Ctx ^ cx_rf, Service, InUnit),
    ( if Action ^ aac_block = aab_call(_, [_ | _]) then
        unexpected($pred, "a call's continuations reach rlow_7_3_1_call "
            ++ "unstripped: every body is lowered through "
            ++ "lcco_3_2_outer_actions")
    else
        Service = asr_bare(Path),
        Names = list.map((func(I) = I ^ id_name), Path),
        rlow_7_3_1_plain_call(Ctx, Action, Kwargs, Conversions,
            string.join_list(".", Names), Result, !IT)
    ).

    % The declared defaults join the kwargs the author wrote. A written kwarg wins.
    %
    %@spec [LADP.8.5.1]
:- func ladp_8_5_1_with_defaults(resolved_file, ast_service_ref,
                                 assoc_list(string, lgra_9_3_1_expr))
    = assoc_list(string, lgra_9_3_1_expr).

ladp_8_5_1_with_defaults(RF, Service, Written) = Kwargs :-
    ( if declared_service(RF, Service, Decl) then
        Kwargs = Written ++ list.filter_map(omitted_default(RF, Written),
            Decl ^ asv_kwargs)
    else
        Kwargs = Written
    ).

    % A written `call` kwarg, at [LUNI.4.5.1]'s assignment boundary 4: when the
    % kwarg's unit type has another dimension than the value's, and exactly one
    % `implicit` formula converts between them, that formula's call. Otherwise the
    % kwarg as written.
    %
    %@spec [LUNI.4.5.1]
:- func luni_4_5_1_call_kwarg(ctx, ast_service_ref,
                              pair(string, lgra_9_3_1_expr))
    = pair(string, lgra_9_3_1_expr).

luni_4_5_1_call_kwarg(Ctx, Service, K - V) = K - Value :-
    RF = Ctx ^ cx_rf,
    ( if
        declared_service(RF, Service, Decl),
        list.find_first_match(
            ( pred(D::in) is semidet :- D ^ ask_name ^ id_name = K ),
            Decl ^ asv_kwargs, Kwarg),
        unit_dimension_of(kwarg_scope(RF, Kwarg), Kwarg ^ ask_type ^ id_name,
            TargetDim),
        Ctx ^ cx_env = yes(Env),
        type_of_expr(Env, V) = ty_known(VType),
        luni_8_2_quantity_dimension(VType, SourceDim),
        SourceDim \= TargetDim,
        luni_4_5_implicit_line(RF, SourceDim, TargetDim, Line)
    then
        Value = formula_call_of(Line, V)
    else
        Value = V
    ).

    %@helper
:- pred declared_service(resolved_file::in, ast_service_ref::in,
                         ast_service_decl::out) is semidet.

declared_service(RF, asr_bare(Path), Decl) :-
    map.search(RF ^ rf_services, ident_path(Path), Decl).

    %@helper
:- func ident_path(list(ident)) = string.

ident_path(Ids) =
    string.join_list(".", list.map((func(I) = I ^ id_name), Ids)).

    %@helper
:- func omitted_default(resolved_file, assoc_list(string, lgra_9_3_1_expr),
                        ast_service_kwarg)
    = pair(string, lgra_9_3_1_expr) is semidet.

omitted_default(RF, Written, Kwarg) = Name - Default :-
    Name = Kwarg ^ ask_name ^ id_name,
    not assoc_list.search(Written, Name, _),
    list.find_first_match(
        ( pred(M::in) is semidet :- M = akm_default(_, _) ),
        Kwarg ^ ask_modifiers, Mod),
    Mod = akm_default(Declared, _),
    Default = ladp_8_5_2_default(kwarg_scope(RF, Kwarg),
        Kwarg ^ ask_type ^ id_name, Declared).

    % The default folded to the number the service receives: in the kwarg's unit on
    % a unit-typed kwarg, the base value on a dimension-typed one, as written
    % otherwise. `RF` is the declaring file's (`dsc.resolve.kwarg_scope`).
    %
    %@spec [LADP.8.5.2]
:- func ladp_8_5_2_default(resolved_file, string, lgra_9_3_1_expr)
    = lgra_9_3_1_expr.

ladp_8_5_2_default(RF, Type, Declared) = Default :-
    ( if
        map.search(RF ^ rf_types, Type, te_unit(uk_symbol(Dimension), _)),
        quantity_base(RF, Declared, Base),
        in_unit_literal(RF, Type, Dimension, Base, expr_start(Declared),
            Literal)
    then
        Default = Literal
    else if
        map.search(RF ^ rf_types, Type, te_unit(Kind, Dimension)),
        ( Kind = uk_dimension ; Kind = uk_scalar ),
        quantity_base(RF, Declared, Base),
        Literal = base_literal(RF, Dimension, Base, expr_start(Declared))
    then
        Default = Literal
    else
        Default = Declared
    ).

    %@helper
:- func base_literal(resolved_file, decl_ref, rational, pos) = lgra_9_3_1_expr
    is semidet.

base_literal(RF, Dimension, Base, Pos) = Literal :-
    ( if whole_number_dimension(RF, Dimension) then
        Literal = ex_int(dsc.exact.truncate_wrapping_int64(Base), Pos)
    else
        dsc.exact.to_float(Base, F),
        Literal = ex_float(F, Pos)
    ).

    % A base-unit value as the literal a service receives on a kwarg of unit `Type`,
    % folded exactly and rounded once ([LDET.3.3a.7]). A whole-number value is
    % truncated: `dsc.validate` has refused one that is not whole.
    %
    %@helper
:- pred in_unit_literal(resolved_file::in, string::in, decl_ref::in,
                        rational::in, pos::in, lgra_9_3_1_expr::out)
    is semidet.

in_unit_literal(RF, Type, Dimension, Base, Pos, Literal) :-
    ladp_8_5_2_in_unit(RF, Type, Base, Value),
    ( if whole_number_dimension(RF, Dimension) then
        Literal = ex_int(dsc.exact.truncate_wrapping_int64(Value), Pos)
    else
        dsc.exact.to_float(Value, F),
        Literal = ex_float(F, Pos)
    ).

    % A quantity known at compile time is folded into a literal in the kwarg's unit;
    % any other of the kwarg's dimension is converted when the call is evaluated
    % ([RLOW.7.3.9]), which `kwarg_pairs` wraps around the lowered argument. A plain
    % number, or a value of a type not known here, is left as it lowers.
    %
    %@spec [LADP.8.5.3]
:- pred ladp_8_5_3_written_in_unit(ctx::in, ast_service_ref::in,
                                   assoc_list(string, lgra_9_3_1_expr)::in,
                                   assoc_list(string, lgra_9_3_1_expr)::out,
                                   assoc_list(string, kwarg_conversion)::out)
    is det.

ladp_8_5_3_written_in_unit(Ctx, Service, Written, Kwargs, Conversions) :-
    ( if declared_service(Ctx ^ cx_rf, Service, Decl) then
        list.map2(written_in_unit(Ctx, Decl ^ asv_kwargs), Written, Kwargs,
            MaybeConversions),
        Conversions = list.condense(MaybeConversions)
    else
        Kwargs = Written,
        Conversions = []
    ).

    % What `kwarg_pairs` does to a written kwarg's lowered value.
    %
    %@helper
:- type kwarg_conversion
    --->    kc_convert(rlow_7_3_9_conversion)
    ;       kc_unconvertible(string).

    %@helper
:- pred written_in_unit(ctx::in, list(ast_service_kwarg)::in,
                        pair(string, lgra_9_3_1_expr)::in,
                        pair(string, lgra_9_3_1_expr)::out,
                        assoc_list(string, kwarg_conversion)::out) is det.

written_in_unit(Ctx, Declared, Name - Expr, Name - Lowered, Conversion) :-
    RF = Ctx ^ cx_rf,
    ( if
        list.find_first_match(
            ( pred(K::in) is semidet :- K ^ ask_name ^ id_name = Name ),
            Declared, Kwarg),
        Type = Kwarg ^ ask_type ^ id_name,
        Scope = kwarg_scope(RF, Kwarg),
        map.search(Scope ^ rf_types, Type, te_unit(uk_symbol(Dimension), _))
    then
        ( if
            known_quantity(RF, let_rhs_of(Ctx), shadows_const(Ctx), Expr,
                Dimension, Base),
            ( if whole_number_dimension(RF, Dimension) then
                ladp_8_5_2_in_unit(Scope, Type, Base, Whole),
                is_whole(Whole)
            else
                true
            ),
            in_unit_literal(Scope, Type, Dimension, Base, expr_start(Expr),
                Literal)
        then
            Lowered = Literal,
            Conversion = []
        else if
            argument_quantity_of(Ctx, Expr, Dimension)
        then
            Lowered = Expr,
            ( if rlow_7_3_9_conversion(Scope, Dimension, Type, Conv) then
                ( if Conv = cv_none then
                    Conversion = []
                else
                    Conversion = [Name - kc_convert(Conv)]
                )
            else
                Conversion = [Name - kc_unconvertible("a quantity on the `"
                    ++ Type ++ "` kwarg `" ++ Name ++ ":` whose unit has no "
                    ++ "conversion from the base unit the compiler can bake "
                    ++ "([RLOW.7.3.9])")]
            )
        else
            Lowered = Expr,
            Conversion = []
        )
    else
        Lowered = Expr,
        Conversion = []
    ).

    %@helper
:- pred shadows_const(ctx::in, string::in) is semidet.

shadows_const(Ctx, Name) :-
    ( binding_index(Ctx ^ cx_pats, Name, 0, _, _)
    ; let_named(Ctx ^ cx_lets, Name, [], _, _)
    ).

    %@helper
:- pred let_rhs_of(ctx::in, string::in, lgra_9_3_1_expr::out) is semidet.

let_rhs_of(Ctx, Name, Rhs) :-
    Ctx ^ cx_env = yes(Env),
    map.search(Env ^ te_scope ^ rsc_let_exprs, Name, Rhs).

    % Whether a written argument is a quantity of `Dimension`, by its type; for
    % `time` a `Duration` too ([LTIM.1.3.2]).
    %
    %@helper
:- pred argument_quantity_of(ctx::in, lgra_9_3_1_expr::in, decl_ref::in)
    is semidet.

argument_quantity_of(Ctx, Expr, Dimension) :-
    ( if
        Expr = ex_name(Id),
        let_named(Ctx ^ cx_lets, Id ^ id_name, [], let_inline(_, Inlined),
            Scope)
    then
        argument_quantity_of(Ctx ^ cx_lets := Scope, Inlined, Dimension)
    else
        Ctx ^ cx_env = yes(Env),
        type_of_expr(Env, Expr) = ty_known(Type),
        ( Type ^ dt_dim = dim(Dimension, _)
        ; Dimension = time_dimension,
          Type ^ dt_leaf = lk_duration
        )
    ).

    % A call: the correlation (the `as` clause or an `as:` kwarg) and the body kwargs,
    % the meta-kwargs stripped.
    %
    %@helper
:- pred rlow_7_3_1_plain_call(ctx::in, ast_action::in,
                              assoc_list(string, lgra_9_3_1_expr)::in,
                              assoc_list(string, kwarg_conversion)::in,
                              string::in, lowered(inline_action)::out,
                              intern_table::in, intern_table::out) is det.

rlow_7_3_1_plain_call(Ctx, Action, Kwargs, Conversions, Service, Result,
        !IT) :-
    ( if
        list.find_first_match((pred(F::in) is semidet :-
            F \= "nocooldown"), action_flags(Action), _)
    then
        Result = skipped("a `call` flag other than `nocooldown`")
    else
        ( if
            Action ^ aac_as = yes(ex_call(ex_name(Or), [KeyAst, GenAst], _)),
            Or ^ id_name = corr_or_name
        then
            rlow_6_1_1_expr(Ctx, KeyAst, KeyRes, !IT),
            rlow_7_3_1_corr(Ctx, GenAst, GenRes, !IT),
            ( if KeyRes = done(KeyE), GenRes = done(GenE) then
                lrst_1_2_empty_key_corr(KeyE, GenE, Guarded, !IT),
                CorrRes = done(Guarded)
            else if KeyRes = skipped(KeyWhy) then
                CorrRes = skipped(KeyWhy)
            else if GenRes = skipped(GenWhy) then
                CorrRes = skipped(GenWhy)
            else
                unexpected($pred, "both lowered")
            )
        else if Action ^ aac_as = yes(AsExpr) then
            rlow_7_3_1_corr(Ctx, AsExpr, CorrRes, !IT)
        else if find_kwarg(Kwargs, "as", AsKwarg) then
            rlow_6_1_1_expr(Ctx, AsKwarg, CorrRes, !IT)
        else
            CorrRes = skipped("a `call` with no correlation: every call "
                ++ "carries one ([LCRS.3.1]), and this lowering path did not "
                ++ "generate it")
        ),
        Body = rlow_7_3_1_kwargs_by_name(list.filter(body_kwarg, Kwargs)),
        kwarg_pairs(Ctx, Conversions, Body, [], PairsRes, !IT),
        intern(Service, SvcRef, !IT),
        ( if CorrRes = done(Corr), PairsRes = done(Pairs) then
            Result = done(ia_call(SvcRef, Corr, make_kwargs(Pairs), no))
        else if CorrRes = skipped(Why) then
            Result = skipped(Why)
        else if PairsRes = skipped(Why) then
            Result = skipped(Why)
        else
            unexpected($pred, "both lowered")
        )
    ).

    % A call's `as`: `$corr_gen(<prefix>, <bind>)` as `generated_corr_expr`'s
    % interpolation, anything else as the expression it is.
    %
    %@helper
:- pred rlow_7_3_1_corr(ctx::in, lgra_9_3_1_expr::in, lowered(expr)::out,
                        intern_table::in, intern_table::out) is det.

rlow_7_3_1_corr(Ctx, AsExpr, Result, !IT) :-
    ( if
        AsExpr = ex_call(ex_name(Gen), [ex_string(Prefix, _), BindAst], _),
        Gen ^ id_name = corr_gen_name
    then
        rlow_6_1_1_expr(Ctx, BindAst, BindRes, !IT),
        (
            BindRes = done(Bind),
            Result = done(e_interp([fp_text(Prefix),
                fp_value(canonical_prim(Bind))]))
        ;
            BindRes = skipped(Why),
            Result = skipped(Why)
        )
    else
        rlow_6_1_1_expr(Ctx, AsExpr, Result, !IT)
    ).

    %@helper
:- pred call_response_schema(resolved_file::in, ast_service_ref::in,
                             string::out) is semidet.

call_response_schema(RF, asr_bare(Path), Name) :-
    map.search(RF ^ rf_response_names, service_spelling(Path), Name).

    %@helper
:- func service_spelling(list(ident)) = string.

service_spelling(Ids) =
    string.join_list(".", list.map((func(I) = I ^ id_name), Ids)).

    % A call's kwargs, sorted by name. This is also the evaluation order: both
    % runtimes evaluate them in wire order.
    %
    %@spec [RLOW.7.3.1]
:- func rlow_7_3_1_kwargs_by_name(assoc_list(string, lgra_9_3_1_expr))
    = assoc_list(string, lgra_9_3_1_expr).

rlow_7_3_1_kwargs_by_name(Kwargs) = Sorted :-
    list.sort((pred(A::in, B::in, R::out) is det :-
        A = N1 - _,
        B = N2 - _,
        compare(R, N1, N2)), Kwargs, Sorted).

    %@helper
:- pred body_kwarg(pair(string, lgra_9_3_1_expr)::in) is semidet.

body_kwarg(K - _) :-
    not ( K = "cooldown" ; K = "as" ; K = "retain" ).

    %@helper
:- func action_kwargs(ast_action) = assoc_list(string, lgra_9_3_1_expr).

action_kwargs(Action) = list.filter_map(kwarg_of, Action ^ aac_args
    ++ block_args(Action ^ aac_block)).

    %@helper
:- func block_args(ast_action_block) = list(ast_action_arg).

block_args(aab_none) = [].
block_args(aab_kwargs(Args)) = Args.
block_args(aab_call(Args, _)) = Args.

    %@helper
:- func kwarg_of(ast_action_arg) = pair(string, lgra_9_3_1_expr) is semidet.

kwarg_of(aaa_kwarg(Id, E, _)) = Id ^ id_name - E.

    %@helper
:- func action_flags(ast_action) = list(string).

action_flags(Action) = list.filter_map(flag_of, Action ^ aac_args
    ++ block_args(Action ^ aac_block)).

    %@helper
:- func flag_of(ast_action_arg) = string is semidet.

flag_of(aaa_flag(Id)) = Id ^ id_name.

    %@helper
:- pred has_flag(ast_action::in, string::in) is semidet.

has_flag(Action, Flag) :-
    list.member(Flag, action_flags(Action)).

    %@helper
:- pred find_kwarg(assoc_list(string, lgra_9_3_1_expr)::in, string::in,
                   lgra_9_3_1_expr::out) is semidet.

find_kwarg([K - V | Rest], Name, Found) :-
    ( if K = Name then Found = V else find_kwarg(Rest, Name, Found) ).

    %@helper
:- pred kwarg_pairs(ctx::in, assoc_list(string, kwarg_conversion)::in,
                    assoc_list(string, lgra_9_3_1_expr)::in,
                    assoc_list(string, expr)::in,
                    lowered(assoc_list(string, expr))::out,
                    intern_table::in, intern_table::out) is det.

kwarg_pairs(_, _, [], Acc, done(list.reverse(Acc)), !IT).
kwarg_pairs(Ctx, Conversions, [K - V | Rest], Acc, Result, !IT) :-
    rlow_6_1_1_expr(Ctx, V, VRes, !IT),
    (
        VRes = done(E0),
        ( if assoc_list.search(Conversions, K, Conversion) then
            (
                Conversion = kc_convert(Conv),
                ConvRes = rlow_7_3_9_converted(Conv, E0),
                (
                    ConvRes = done(E),
                    kwarg_pairs(Ctx, Conversions, Rest, [K - E | Acc],
                        Result, !IT)
                ;
                    ConvRes = skipped(Why),
                    Result = skipped(Why)
                )
            ;
                Conversion = kc_unconvertible(Why),
                Result = skipped(Why)
            )
        else
            kwarg_pairs(Ctx, Conversions, Rest, [K - E0 | Acc], Result, !IT)
        )
    ;
        VRes = skipped(Why),
        Result = skipped(Why)
    ).

    % A value into a schema slot by kwarg, at [LUNI.4.5.1]'s assignment boundary 3:
    % when the value's dimension is not the slot's and exactly one `implicit` formula
    % converts between them, that formula's call. Otherwise the value as it is.
    %
    %@spec [LUNI.4.5.1]
:- pred luni_4_5_1_slot_value(ctx::in, intern_ref::in, string::in,
                              lgra_9_3_1_expr::in, lowered(expr)::out,
                              intern_table::in, intern_table::out) is det.

luni_4_5_1_slot_value(Ctx, SchemaRef, SlotName, V, Result, !IT) :-
    RF = Ctx ^ cx_rf,
    ( if
        expand(!.IT, SchemaRef, SchemaName),
        map.search(RF ^ rf_types, SchemaName, te_schema(AstSchema)),
        list.find_first_match(
            ( pred(F::in) is semidet :- F ^ af_name ^ id_name = SlotName ),
            AstSchema ^ as_fields, Field),
        slot_entry(RF, Field, Entry),
        entry_dimension(RF, Entry, TargetDim),
        Ctx ^ cx_env = yes(Env),
        type_of_expr(Env, V) = ty_known(VType),
        VType ^ dt_dim = dim(SourceDim, _),
        SourceDim \= TargetDim,
        luni_4_5_implicit_line(RF, SourceDim, TargetDim, Line)
    then
        lgra_9_8_11_formula_call(Ctx, Line, V, Result, !IT)
    else
        rlow_6_1_1_expr(Ctx, V, Result, !IT)
    ).

    % The dimension a unit name's slot type carries.
    %
    %@helper
:- pred unit_dimension_of(resolved_file::in, string::in, decl_ref::out)
    is semidet.

unit_dimension_of(RF, UnitName, Dimension) :-
    map.search(RF ^ rf_types, UnitName, Entry),
    entry_dimension(RF, Entry, Dimension).

    %@helper
:- pred entry_dimension(resolved_file::in, type_entry::in, decl_ref::out)
    is semidet.

entry_dimension(RF, Entry, Dimension) :-
    Type = luni_7_1_slot_type(RF ^ rf_unit_storage, Entry, non_null),
    Type ^ dt_dim = dim(Dimension, _).

    % The one `implicit` formula line converting `From` to `To`. A formula reached
    % through two import paths is one, by name; two formulas fail.
    %
    %@spec [LUNI.4.5]
:- pred luni_4_5_implicit_line(resolved_file::in, decl_ref::in, decl_ref::in,
                               ast_formula_line::out) is semidet.

luni_4_5_implicit_line(RF, From, To, Line) :-
    luni_4_5_implicit_formula(RF, From, To, Line, _).

    % The same line, and whether its formula is `inverting` ([LUNI.4.5.2]).
    %
    %@spec [LUNI.4.5]
:- pred luni_4_5_implicit_formula(resolved_file::in, decl_ref::in, decl_ref::in,
                                  ast_formula_line::out, bool::out) is semidet.

luni_4_5_implicit_formula(RF, From, To, Line, Inverting) :-
    Candidates = list.filter_map(
        ( func(U) = {Name ^ id_name, L, Inv} is semidet :-
            U = au_formula(Name, Modifiers, Lines, _),
            list.find_first_match(
                ( pred(M::in) is semidet :- M = afm_implicit(_) ),
                Modifiers, _),
            Inv = ( if
                    list.find_first_match(
                        ( pred(M::in) is semidet :- M = afm_inverting(_) ),
                        Modifiers, _)
                then yes else no ),
            list.find_first_match(
                ( pred(L0::in) is semidet :-
                    unit_dimension_of(RF, L0 ^ afl_param_type ^ id_name, From),
                    unit_dimension_of(RF, L0 ^ afl_return ^ id_name, To)
                ), Lines, L)
        ), RF ^ rf_units),
    list.remove_dups(list.map(( func({N, _, _}) = N ), Candidates)) = [_],
    Candidates = [{_, Line, Inverting} | _].

    % A base-unit value in the kwarg's unit: the tier-1 body's inverse, `(base -
    % Offset) / Slope`, or a tier-2 unit's `from_base`, for a `float64` dimension,
    % and `FN_INT_DIV_EXACT` for a whole-number one.
    %
    %@spec [RLOW.7.3.9]
:- func rlow_7_3_9_converted(rlow_7_3_9_conversion, expr) = lowered(expr).

rlow_7_3_9_converted(cv_none, E) = done(E).
rlow_7_3_9_converted(cv_affine(Offset, Slope), E) = done(Converted) :-
    Shifted = ( if Offset = 0.0 then E
                else e_binop(op_sub, E, e_lit(float(Offset))) ),
    Converted = ( if Slope = 1.0 then Shifted
                  else e_binop(op_div, Shifted, e_lit(float(Slope))) ).
rlow_7_3_9_converted(cv_div_exact(Factor), E) =
    done(e_call(fn_int_div_exact, [E, e_lit(int(Factor))])).
rlow_7_3_9_converted(cv_from_base(Body), E) = luni_4_3_from_base(Body, E).

    % A tier-2 unit's `from_base` body with its `x` the lowered base-unit value,
    % nothing folded or reassociated ([LUNI.4.3]). `x` may occur more than once:
    % nothing the argument reads can change within one evaluation of the call's
    % arguments.
    %
    %@spec [LUNI.4.3]
    %@spec [RLOW.7.3.9]
:- func luni_4_3_from_base(lgra_9_3_1_expr, expr) = lowered(expr).

luni_4_3_from_base(Body, X) = Result :-
    ( if Body = ex_name(Id) then
        ( if Id ^ id_name = "x" then
            Result = done(X)
        else if
            Id ^ id_name = "math.pi",
            dsc.exact.to_float(dsc.exact.pi, Pi)
        then
            Result = done(e_lit(float(Pi)))
        else
            Result = skipped(tier2_unlowered("the name `" ++ Id ^ id_name
                ++ "`"))
        )
    else if Body = ex_int(I, _) then
        Result = done(e_lit(int(I)))
    else if Body = ex_float(F, _) then
        Result = done(e_lit(float(F)))
    else if Body = ex_unary(uo_neg, Operand, _) then
        Result = map_done((func(V) = e_unop(op_neg, V)),
            luni_4_3_from_base(Operand, X))
    else if Body = ex_unary(uo_pos, Operand, _) then
        Result = luni_4_3_from_base(Operand, X)
    else if
        Body = ex_binary(Op, L, R, _),
        ( Op = bo_add ; Op = bo_sub ; Op = bo_mul ; Op = bo_div
        ; Op = bo_pow )
    then
        LRes = luni_4_3_from_base(L, X),
        RRes = luni_4_3_from_base(R, X),
        ( if LRes = done(LE), RRes = done(RE) then
            Result = binary(Op, LE, RE)
        else if LRes = skipped(Why) then
            Result = skipped(Why)
        else if RRes = skipped(Why) then
            Result = skipped(Why)
        else
            unexpected($pred, "neither operand done nor skipped")
        )
    else if
        Body = ex_call(ex_name(FnId), [Arg], _),
        luni_4_3_tier2_fn(FnId ^ id_name, Fn)
    then
        Result = map_done((func(V) = e_call(Fn, [V])),
            luni_4_3_from_base(Arg, X))
    else
        Result = skipped(tier2_unlowered("an expression outside "
            ++ "[LUNI.4.3]'s tier-2 vocabulary"))
    ).

    %@helper
:- func tier2_unlowered(string) = string.

tier2_unlowered(What) =
    "a tier-2 unit's `from_base` holds " ++ What
        ++ ", so the call on its kwarg is not lowered ([RLOW.7.3.9])".

    %@helper
:- func map_done((func(expr) = expr), lowered(expr)) = lowered(expr).

map_done(F, done(E)) = done(F(E)).
map_done(_, skipped(Why)) = skipped(Why).

    % A nullable slot an `emit` omits takes `null`: an unassigned slot reads in both
    % runtimes as the zero of its declared type.
    %
    %@spec LGRA.13.11
:- func lgra_13_11_null_fills(schema, list(slot_assign)) = list(slot_assign).

lgra_13_11_null_fills(Schema, Given) = Fills :-
    list.filter_map(
        ( pred(C::in, slot_assign(C ^ sc_index, e_lit(null))::out) is semidet :-
            C ^ sc_nullable = nullable,
            not (
                list.member(SA, Given),
                SA ^ sa_slot = C ^ sc_index
            )
        ),
        slot_commons(Schema), Fills).

    % `retain:` is the per-emit TTL override ([LDTL.4.1]); every other kwarg a sparse
    % slot assignment in source order.
    %
    %@helper
:- pred emit_kwargs(ctx::in, schema::in,
                    assoc_list(string, lgra_9_3_1_expr)::in,
                    list(slot_assign)::in, maybe(expr)::in,
                    lowered({list(slot_assign), maybe(expr)})::out,
                    intern_table::in, intern_table::out) is det.

emit_kwargs(_, _, [], Acc, Retain, done({list.reverse(Acc), Retain}), !IT).
emit_kwargs(Ctx, Schema, [K - V | Rest], Acc, Retain, Result, !IT) :-
    luni_4_5_1_slot_value(Ctx, schema_name_ref(Schema ^ s_name), K, V, VRes,
        !IT),
    (
        VRes = skipped(Why),
        Result = skipped(Why)
    ;
        VRes = done(E),
        ( if K = "retain" then
            emit_kwargs(Ctx, Schema, Rest, Acc, yes(E), Result, !IT)
        else if
            interned(!.IT, K, Ref),
            slot_by_name(Schema, Ref, Common)
        then
            Stored = luni_7_2_storage_cast(Ctx, Common, V, E),
            emit_kwargs(Ctx, Schema, Rest,
                [slot_assign(Common ^ sc_index, Stored) | Acc], Retain, Result,
                !IT)
        else
            Result = skipped("`emit` names a slot the schema does not declare")
        )
    ).

    % A dimensioned `Float` into an `Int` slot is rounded by `FN_ROUND`, ties to even.
    %
    %@spec [LUNI.7.2]
:- func luni_7_2_storage_cast(ctx, slot_common, lgra_9_3_1_expr, expr) = expr.

luni_7_2_storage_cast(Ctx, Common, Written, E) = Stored :-
    ( if
        Common ^ sc_kind = k_int,
        Ctx ^ cx_env = yes(Env),
        type_of_expr(Env, Written) = ty_known(Type),
        Type ^ dt_leaf = lk_float,
        Type ^ dt_dim = dim(_, _)
    then
        Stored = e_call(fn_round, [E])
    else
        Stored = E
    ).

    % `publish`'s arguments, dense in declaration order: the kwarg for a slot,
    % or a fill for one the `publish` omits: `null` for a nullable slot, else the
    % zero of the slot's own kind, and `null` for the kinds `ds.exec.zero_of` also
    % fills with `null`.
    %
    %@helper
:- pred publish_args(ctx::in, intern_ref::in,
                     assoc_list(string, lgra_9_3_1_expr)::in,
                     list(slot_common)::in, list(expr)::in,
                     lowered(list(expr))::out,
                     intern_table::in, intern_table::out) is det.

publish_args(_, _, _, [], Acc, done(list.reverse(Acc)), !IT).
publish_args(Ctx, SchemaName, Kwargs, [C | Cs], Acc, Result, !IT) :-
    ( if
        expand(!.IT, C ^ sc_name, "ts")
    then
        % `ts` is the firing's wall sample ([LFAC.9.2]), and `FN_PUBLISH` is
        % positional.
        VRes = done(e_now)
    else if
        expand(!.IT, C ^ sc_name, Name),
        find_kwarg(Kwargs, Name, V)
    then
        luni_4_5_1_slot_value(Ctx, SchemaName, Name, V, VRes0, !IT),
        (
            VRes0 = done(E0),
            VRes = done(luni_7_2_storage_cast(Ctx, C, V, E0))
        ;
            VRes0 = skipped(_),
            VRes = VRes0
        )
    else if C ^ sc_nullable = nullable then
        VRes = done(e_lit(null))
    else if C ^ sc_kind = k_string then
        intern("", Empty, !IT),
        VRes = done(e_lit(str(Empty)))
    else if int_represented(C ^ sc_kind) then
        VRes = done(e_lit(int(0i64)))
    else if C ^ sc_kind = k_float then
        VRes = done(e_lit(float(0.0)))
    else if C ^ sc_kind = k_bool then
        VRes = done(e_lit(bool(no)))
    else
        VRes = done(e_lit(null))
    ),
    (
        VRes = done(E),
        publish_args(Ctx, SchemaName, Kwargs, Cs, [E | Acc], Result, !IT)
    ;
        VRes = skipped(Why),
        Result = skipped(Why)
    ).

    %@helper
:- pred log_level_of(lgra_10_1_1_log_level::in, log_level::out) is semidet.

log_level_of(ll_debug, log_debug).
log_level_of(ll_info, log_info).
log_level_of(ll_warning, log_warning).
log_level_of(ll_error, log_error).
log_level_of(ll_critical, log_critical).

%-----------------------------------------------------------------------------%
% Series -- [RLOW.8]
%-----------------------------------------------------------------------------%

    % A companion read, `t.mean` or `t.label.mean`, as the series builtin:
    %
    %     ds_series_<agg>(schema, slot, id_slot, <id value>, window_ns [, N])
    %
    % the argument shape `ds.eval.series_key_of` reads.
    %
    %@spec [RLOW.8.3.1]
    %@spec [RLOW.8.3.2]
    %@spec [RLOW.8.3.3]
    %@spec [RLOW.8.3.4]
    %@spec [RLOW.8.3.6]
    %@spec [RLOW.8.1.4]
    %@spec [RLOW.8.2.1]
:- pred rlow_8_3_1_companion(ctx::in, int::in, pat::in, list(ident)::in,
                             lowered(expr)::out,
                             intern_table::in, intern_table::out) is det.

rlow_8_3_1_companion(Ctx, K, P, Components, Result, !IT) :-
    RF = Ctx ^ cx_rf,
    ( if
        expand(!.IT, schema_name_ref(P ^ pt_schema ^ s_name), SchemaName),
        list.last(Components, AggId),
        Outcome = lser_6_11_1_cursor(RF, SchemaName, Components,
            AggId ^ id_pos),
        Outcome = cursor_resolved(Obs, Agg),
        agg_builtin(Agg, Fn, Extra),
        series_target_of(RF, SchemaName, Obs ^ so_slot, Series),
        line_at(Series ^ asr_lines, Obs ^ so_pos, Line)
    then
        Slot = Obs ^ so_slot,
        IdSlot = identity_slot(RF, SchemaName, Series),
        fact_of(Ctx, K, P, FactRes),
        ( if IdSlot = "" then
            intern("", EmptyRef, !IT),
            IdRes = done(e_lit(str(EmptyRef)))
        else if
            FactRes = done(Fact),
            interned(!.IT, IdSlot, IdRef),
            slot_by_name(P ^ pt_schema, IdRef, IdCommon)
        then
            IdRes = done(e_slot(Fact, slot(IdCommon ^ sc_index)))
        else if FactRes = skipped(Why) then
            IdRes = skipped(Why)
        else
            IdRes = skipped("the series identity slot is not on the schema")
        ),
        (
            IdRes = done(IdE),
            ( if line_window_ns(RF, Line ^ asl_time, Window) then
                intern(SchemaName, SchemaRef, !IT),
                intern(Slot, SlotRef, !IT),
                intern(IdSlot, IdSlotRef, !IT),
                Result = done(e_call(Fn, [e_lit(str(SchemaRef)),
                    e_lit(str(SlotRef)), e_lit(str(IdSlotRef)), IdE,
                    e_lit(int(Window))] ++ Extra))
            else
                Result = skipped("the series window is neither a duration "
                    ++ "literal nor a `time` const")
            )
        ;
            IdRes = skipped(Why2),
            Result = skipped(Why2)
        )
    else
        Result = skipped("a companion read this compiler cannot lower")
    ).

    % `count_of(cursor, value)` and `contains(cursor, value)`: the companion read's
    % arguments, then the value sixth.
    %
    %@spec [LSER.16.6.1]
    %@spec [LSER.16.7.1]
:- pred lser_16_6_1_value_call(ctx::in, ident::in, lgra_9_3_1_expr::in,
                               lgra_9_3_1_expr::in, lowered(expr)::out,
                               intern_table::in, intern_table::out) is det.

lser_16_6_1_value_call(Ctx, Fn, CursorArg, ValueArg, Result, !IT) :-
    ( if
        cursor_parts(CursorArg, Root, Components),
        binding_index(Ctx ^ cx_pats, Root, 0, K, P)
    then
        rlow_8_3_1_companion(Ctx, K, P, Components ++ [Fn], ReadRes, !IT),
        ( if
            ReadRes = done(e_call(Op, [Schema, Slot, IdSlot, Id, Declared]))
        then
            rlow_6_1_1_expr(Ctx, ValueArg, ValueRes, !IT),
            (
                ValueRes = done(Value),
                Result = done(e_call(Op,
                    [Schema, Slot, IdSlot, Id, Declared, Value]))
            ;
                ValueRes = skipped(Why),
                Result = skipped(Why)
            )
        else if ReadRes = skipped(Why3) then
            Result = skipped(Why3)
        else
            Result = skipped("a series call this compiler cannot lower")
        )
    else
        Result = skipped("a series call whose cursor is not a pattern binding")
    ).

    %@helper
:- pred value_series_call_shape(ctx::in, string::in,
                                list(lgra_9_3_1_expr)::in,
                                lgra_9_3_1_expr::out, lgra_9_3_1_expr::out)
    is semidet.

value_series_call_shape(Ctx, Name, Args, CursorArg, ValueArg) :-
    ( Name = "count_of" ; Name = "contains" ),
    Args = [CursorArg, ValueArg],
    cursor_parts(CursorArg, Root, _),
    binding_index(Ctx ^ cx_pats, Root, 0, _, P),
    P ^ pt_negated = no.

    %@helper
:- pred cursor_parts(lgra_9_3_1_expr::in, string::out, list(ident)::out)
    is semidet.

cursor_parts(Expr, Root, Components) :-
    (
        Expr = ex_name(Id),
        Root = Id ^ id_name,
        Components = []
    ;
        Expr = ex_slot(Inner, Field, _),
        cursor_parts(Inner, Root, Leading),
        Components = Leading ++ [Field]
    ).

    %@helper
:- pred series_row_id(ctx::in, int::in, pat::in, string::in,
                      lowered(expr)::out,
                      intern_table::in, intern_table::out) is det.

series_row_id(Ctx, K, P, IdSlot, Result, !IT) :-
    ( if IdSlot = "" then
        intern("", EmptyRef, !IT),
        Result = done(e_lit(str(EmptyRef)))
    else
        fact_of(Ctx, K, P, FactRes),
        ( if
            FactRes = done(Fact),
            interned(!.IT, IdSlot, IdRef),
            slot_by_name(P ^ pt_schema, IdRef, IdCommon)
        then
            Result = done(e_slot(Fact, slot(IdCommon ^ sc_index)))
        else if FactRes = skipped(Why) then
            Result = skipped(Why)
        else
            Result = skipped("the series identity slot is not on the schema")
        )
    ).

    %@helper
:- pred agg_builtin(string::in, builtin_fn::out, list(expr)::out) is semidet.

agg_builtin(Agg, Fn, Extra) :-
    ( if percentile_n(Agg, N) then
        Fn = fn_series_percentile,
        Extra = [e_lit(int(int64.from_int(N)))]
    else
        agg_fn(Agg, Fn),
        Extra = []
    ).

    %@helper
:- pred agg_fn(string::in, builtin_fn::out) is semidet.

agg_fn("mean", fn_series_mean).
agg_fn("median", fn_series_median).
agg_fn("stdev", fn_series_stdev).
agg_fn("pstdev", fn_series_pstdev).
agg_fn("variance", fn_series_variance).
agg_fn("pvariance", fn_series_pvariance).
agg_fn("rate", fn_series_rate).
agg_fn("direction", fn_series_direction).
agg_fn("min", fn_series_min).
agg_fn("max", fn_series_max).
agg_fn("count", fn_series_count).
agg_fn("count_distinct", fn_series_count_distinct).
agg_fn("sum", fn_series_sum).
agg_fn("first", fn_series_first).
agg_fn("last", fn_series_last).
agg_fn("integral", fn_series_integral).
agg_fn("active_fraction", fn_series_active_fraction).
agg_fn("bool_and", fn_series_bool_and).
agg_fn("bool_or", fn_series_bool_or).
agg_fn("onset_rate", fn_series_onset_rate).
agg_fn("count_of", fn_series_count_of).
agg_fn("contains", fn_series_contains).

    %@helper
:- pred percentile_n(string::in, int::out) is semidet.

percentile_n(Agg, N) :-
    string.remove_prefix("p", Agg, Digits),
    Digits \= "",
    string.all_match(char.is_digit, Digits),
    string.to_int(Digits, N),
    N >= 1,
    N =< 99.

    %@helper
:- pred series_target_of(resolved_file::in, string::in, string::in,
                         ast_series::out) is semidet.

series_target_of(RF, SchemaName, Slot, Series) :-
    list.find_first_match(targets(RF, SchemaName, Slot), RF ^ rf_ast ^ af_decls,
        Decl),
    Decl = ad_series(Series).

    %@helper
:- pred targets(resolved_file::in, string::in, string::in, ast_decl::in)
    is semidet.

targets(RF, SchemaName, Slot, ad_series(S)) :-
    S ^ asr_slot ^ asf_slot ^ id_name = Slot,
    declared_target(RF, S, SchemaName).

    %@helper
:- func schemas_declaring(resolved_file, string) = list(string).

schemas_declaring(RF, Slot) =
    list.filter_map(declaring(Slot), RF ^ rf_ast ^ af_decls).

    %@helper
:- func declaring(string, ast_decl) = string is semidet.

declaring(Slot, ad_schema(S)) = S ^ as_own :-
    list.find_first_match((pred(F::in) is semidet :-
        F ^ af_name ^ id_name = Slot), S ^ as_fields, _).

    %@helper
:- pred line_at(list(ast_series_line)::in, pos::in, ast_series_line::out)
    is semidet.

line_at(Lines, Pos, Line) :-
    list.find_first_match((pred(L::in) is semidet :- L ^ asl_pos = Pos),
        Lines, Line).

    % A `sliding` or `tumbling` duration is a `time_expr` ([LGRA.2.8.2]), read
    % as `within` reads one. Fails on one that is no `time_expr`.
    %
    %@helper
:- pred line_window_ns(resolved_file::in, ast_time_model::in, int64::out)
    is semidet.

line_window_ns(_, atm_all_time(_), 0i64).
line_window_ns(_, atm_sample(_, _), 0i64).
line_window_ns(RF, atm_sliding(E, _), Ns) :-
    lgra_2_8_1_time_value_ns(RF, E, Ns).
line_window_ns(RF, atm_tumbling(E, _), Ns) :-
    lgra_2_8_1_time_value_ns(RF, E, Ns).

    %@helper
:- func duration_ns_of(lgra_9_3_1_expr) = int64.

duration_ns_of(E) = Ns :-
    ( if
        E = ex_unit(Magnitude, Suffix, _),
        luni_10_2_time_unit(llex_12_5_symbol_of(Suffix), Multiplier)
    then
        Ns = luni_3_1_5_magnitude_ns(Magnitude, Multiplier)
    else
        Ns = 0i64
    ).

    % `by: <slot>`, `by: none` as the empty name, else a `logical` schema's one `key`
    % slot, else a slot named `entity_id`.
    %
    %@helper
:- func identity_slot(resolved_file, string, ast_series) = string.

identity_slot(RF, SchemaName, Series) = IdSlot :-
    ( if
        list.find_first_match((pred(O::in) is semidet :- O = abk_by(_, _)),
            Series ^ asr_opts, abk_by(By, _))
    then
        (
            By = aby_name(Id),
            IdSlot = Id ^ id_name
        ;
            By = aby_none(_),
            IdSlot = ""
        )
    else if
        map.search(RF ^ rf_types, SchemaName, te_schema(Schema)),
        Schema ^ as_lifecycle = al_logical(_),
        list.filter(is_key_field, Schema ^ as_fields) = [KeyField]
    then
        IdSlot = KeyField ^ af_name ^ id_name
    else if
        map.search(RF ^ rf_types, SchemaName, te_schema(Schema2)),
        list.find_first_match((pred(F::in) is semidet :-
            F ^ af_name ^ id_name = "entity_id"), Schema2 ^ as_fields, _)
    then
        IdSlot = "entity_id"
    else
        IdSlot = ""
    ).

    %@helper
:- pred is_key_field(ast_field::in) is semidet.

is_key_field(F) :-
    list.find_first_match((pred(M::in) is semidet :- M = am_key(_)),
        F ^ af_markers, _).

    % Every `(schema, slot, builtin)` a lowered rule reads, from the network itself:
    % a series builtin call's first two arguments are its schema and slot literals.
    %
    %@helper
:- func series_refs(intern_table, list(raw_beta), list(raw_terminal))
    = list({string, string, builtin_fn}).

series_refs(IT, Betas, Terms) = Refs :-
    BetaExprs = list.condense(list.map(beta_exprs, Betas)),
    TermExprs = list.condense(list.map(term_exprs, Terms)),
    list.foldl(collect_series_calls(IT), BetaExprs ++ TermExprs, [], Refs).

    %@helper
:- func beta_exprs(raw_beta) = list(expr).

beta_exprs(raw_beta(_, _, _, Tests, _)) = Tests.

    %@helper
:- func term_exprs(raw_terminal) = list(expr).

term_exprs(raw_terminal(_, _, _, _, Guard, _, Actions)) =
    maybe_to_list(Guard) ++ list.condense(list.map(action_exprs, Actions)).

    %@helper
:- func maybe_to_list(maybe(expr)) = list(expr).

maybe_to_list(no) = [].
maybe_to_list(yes(E)) = [E].

    %@helper
:- func gate_args(maybe(list(expr))) = list(expr).

gate_args(no) = [].
gate_args(yes(Args)) = Args.

    %@helper
:- func action_exprs(inline_action) = list(expr).

action_exprs(ia_assert(_, _, Slots, Ttl)) =
    list.map(assign_value, Slots) ++ maybe_to_list(Ttl).
action_exprs(ia_publish(_, Args, Ttl)) = Args ++ maybe_to_list(Ttl).
action_exprs(ia_call(_, Corr, Kwargs, Gate)) =
    gate_args(Gate) ++ [Corr | list.map(kwarg_value, kwarg_list(Kwargs))].
action_exprs(ia_cache_set(K, V, Ttl)) = [K, V | maybe_to_list(Ttl)].
action_exprs(ia_cache_delete(K)) = [K].
action_exprs(ia_log(_, M)) = [M].
action_exprs(ia_withdraw(_)) = [].
action_exprs(ia_withdraw_by_id(E)) = [E].
action_exprs(ia_bind(_, E)) = [E].
action_exprs(ia_hydration_call(_, Corr, _, Kwargs, Gate)) =
    gate_args(Gate) ++ [Corr | list.map(kwarg_value, kwarg_list(Kwargs))].
action_exprs(ia_internal(_, Args)) = Args.
    % Never lowered: only a decoder builds it ([RDSC.4a.9.3]).
action_exprs(ia_operands_not_admitted(_, Args, Gate)) = gate_args(Gate) ++ Args.

    %@helper
:- func assign_value(slot_assign) = expr.

assign_value(slot_assign(_, E)) = E.

%-----------------------------------------------------------------------------%
% [RDSC.11.3] -- an `Expr` nested past the format's limit
%-----------------------------------------------------------------------------%

rdsc_11_3_too_deep_nodes(IT, Net) =
    list.filter_map(rdsc_11_3_beta(Net), Net ^ rn_betas)
        ++ list.filter_map(rdsc_11_3_terminal(IT, Net), Net ^ rn_terms).

    %@spec [RDSC.11.3]
:- func rdsc_11_3_max_depth = int.

rdsc_11_3_max_depth = 48.

%-----------------------------------------------------------------------------%
% [LGRA.8.7], [LGRA.5.11] -- a rule or a schema past the byte index space
%-----------------------------------------------------------------------------%

lgra_8_7_index_overflows(IT, Net) =
    list.filter_map(lgra_8_7_terminal(IT, Net, Parents), Net ^ rn_terms)
        ++ list.filter_map(lgra_5_11_schema(IT, Net), Net ^ rn_schemas) :-
    Parents = list.foldl(
        ( func(B, M) = map.set(M, node_id_value(Id), Parent) :-
            B = raw_beta(Id, _, Parent, _, _) ),
        Net ^ rn_betas, map.init).

    %@helper
:- func lgra_8_7_terminal(intern_table, rete_network, map(uint32, uint32),
    raw_terminal) = index_overflow is semidet.

lgra_8_7_terminal(IT, Net, Parents,
        raw_terminal(Id, Parent, Rule, _, _, _, _))
        = too_many_patterns(Site, Name, Count) :-
    Count = chain_length(Parents, map.count(Parents), Parent, 0),
    Count > rdsc_4a_9_1_index_count,
    ( if node_site(Net, node_id_value(Id)) = yes(Span) then
        Site = yes(Span)
    else
        Site = rule_site(IT, Net, Rule)
    ),
    Name = ( if expand(IT, Rule, N) then N else "" ).

    % The betas from `Beta` to the root. `Bound`, the number of betas, stops a chain
    % that has met a parent twice.
    %
    %@helper
:- func chain_length(map(uint32, uint32), int, uint32, int) = int.

chain_length(Parents, Bound, Beta, Acc) = Length :-
    ( if
        Beta \= 0u32,
        Acc < Bound,
        map.search(Parents, Beta, Parent)
    then
        Length = chain_length(Parents, Bound, Parent, Acc + 1)
    else if Beta \= 0u32, Acc < Bound then
        Length = Acc + 1
    else
        Length = Acc
    ).

    %@helper
:- func lgra_5_11_schema(intern_table, rete_network, schema) = index_overflow
    is semidet.

lgra_5_11_schema(IT, Net, S) = too_many_slots(Site, Name, Count) :-
    Count = list.length(slot_commons(S)),
    Count > rdsc_4a_9_1_index_count,
    Ref = schema_name_ref(S ^ s_name),
    Name = ( if expand(IT, Ref, N) then N else "" ),
    ( if
        list.find_first_match(
            ( pred(T::in) is semidet :-
                T = raw_terminal(_, _, _, _, _, _, Actions),
                list.find_first_match(
                    ( pred(A::in) is semidet :- A = ia_assert(_, Ref, _, _) ),
                    Actions, _) ),
            Net ^ rn_terms, Asserter),
        Asserter = raw_terminal(_, _, Rule, _, _, _, _)
    then
        Site = rule_site(IT, Net, Rule)
    else
        Site = no
    ).

    %@helper
:- func rdsc_11_3_beta(rete_network, raw_beta) = rdsc_11_3_too_deep
    is semidet.

rdsc_11_3_beta(Net, raw_beta(Id, _, _, Tests, _)) =
        rdsc_11_3_too_deep(node_site(Net, node_id_value(Id)), Depth) :-
    Depth = deepest(0, Tests),
    Depth > rdsc_11_3_max_depth.

    %@helper
:- func rdsc_11_3_terminal(intern_table, rete_network, raw_terminal)
    = rdsc_11_3_too_deep is semidet.

rdsc_11_3_terminal(IT, Net, raw_terminal(Id, _, Rule, _, Guard, _, Actions))
        = rdsc_11_3_too_deep(Site, Depth) :-
    Depth = list.foldl(int.max, list.map(action_depth, Actions),
        deepest(0, maybe_to_list(Guard))),
    Depth > rdsc_11_3_max_depth,
    ( if node_site(Net, node_id_value(Id)) = yes(Span) then
        Site = yes(Span)
    else
        Site = rule_site(IT, Net, Rule)
    ).

    % The deepest `Expr` an action writes, as `dsc.encode.rdsc_4a_8_action` nests it;
    % -1 when it writes none.
    %
    %@helper
:- func action_depth(inline_action) = int.

action_depth(IA) = Depth :-
    (
        IA = ia_assert(_, _, Slots, Ttl),
        Depth = deepest(0, list.map(assign_value, Slots) ++ maybe_to_list(Ttl))
    ;
        IA = ia_publish(_, Args, Ttl),
        Depth = int.max(deepest(1, Args), deepest(0, maybe_to_list(Ttl)))
    ;
        IA = ia_call(_, Corr, Kwargs, Gate),
        Depth = int.max(deepest(2, gate_args(Gate)),
            deepest(gate_offset(Gate) + 1,
                [Corr | list.map(kwarg_value, kwarg_list(Kwargs))]))
    ;
        IA = ia_cache_set(K, V, Ttl),
        Depth = deepest(1, [K, V | maybe_to_list(Ttl)])
    ;
        IA = ia_cache_delete(K),
        Depth = deepest(1, [K])
    ;
        IA = ia_log(_, Message),
        Depth = deepest(1, [Message])
    ;
        IA = ia_bind(_, Bound),
        Depth = deepest(1, [Bound])
    ;
        IA = ia_hydration_call(_, Corr, _, Body, Gate),
        Depth = int.max(deepest(2, gate_args(Gate)),
            int.max(deepest(gate_offset(Gate) + 1, [Corr]),
                deepest(gate_offset(Gate) + 2,
                    list.map(kwarg_value, kwarg_list(Body)))))
    ;
        IA = ia_withdraw(_),
        Depth = -1
    ;
        IA = ia_withdraw_by_id(Fact),
        Depth = deepest(0, [Fact])
    ;
        IA = ia_internal(_, Args),
        Depth = deepest(1, Args)
    ;
        IA = ia_operands_not_admitted(_, Args, Gate),
        Depth = int.max(deepest(2, gate_args(Gate)),
            deepest(gate_offset(Gate) + 1, Args))
    ).

    %@helper
:- func gate_offset(maybe(list(expr))) = int.

gate_offset(no) = 0.
gate_offset(yes(_)) = 1.

    %@helper
:- func deepest(int, list(expr)) = int.

deepest(Start, Exprs) =
    list.foldl(int.max, list.map(( func(E) = Start + expr_depth(E) ), Exprs),
        -1).

    %@helper
:- func expr_depth(expr) = int.

expr_depth(E) = Depth :-
    ( if E = e_tainted(Inner) then
        Depth = expr_depth(Inner)
    else
        Children = expr_children(E),
        (
            Children = [],
            Depth = 0
        ;
            Children = [_ | _],
            Depth = 1 + list.foldl(int.max, list.map(expr_depth, Children), 0)
        )
    ).

    %@helper
:- func node_site(rete_network, uint32) = maybe(pair(uint32, pos)).

node_site(Net, Node) = Site :-
    IsNode = ( pred(S0::in) is semidet :- S0 ^ ns_node = Node ),
    ( if
        list.find_first_match(
            ( pred(M0::in) is semidet :-
                list.find_first_match(IsNode, M0 ^ mr_spans, _) ),
            Net ^ rn_modules, M),
        list.find_first_match(IsNode, M ^ mr_spans, S)
    then
        Site = yes(M ^ mr_clip - S ^ ns_pos)
    else
        Site = no
    ).

    %@helper
:- func rule_site(intern_table, rete_network, intern_ref)
    = maybe(pair(uint32, pos)).

rule_site(IT, Net, Ref) = Site :-
    ( if
        expand(IT, Ref, Name),
        IsRule = ( pred(G0::in) is semidet :- G0 ^ rg_rule = Name ),
        list.find_first_match(
            ( pred(M0::in) is semidet :-
                list.find_first_match(IsRule, M0 ^ mr_groups, _) ),
            Net ^ rn_modules, M),
        list.find_first_match(IsRule, M ^ mr_groups, G)
    then
        Site = yes(M ^ mr_clip - G ^ rg_pos)
    else
        Site = no
    ).

    %@helper
:- func kwarg_value(pair(string, expr)) = expr.

kwarg_value(_ - E) = E.

    %@helper
:- pred collect_series_calls(intern_table::in, expr::in,
                             list({string, string, builtin_fn})::in,
                             list({string, string, builtin_fn})::out) is det.

collect_series_calls(IT, E, !Refs) :-
    ( if
        E = e_call(Fn, [e_lit(str(SchemaRef)), e_lit(str(SlotRef)) | _]),
        expand(IT, SchemaRef, Schema),
        expand(IT, SlotRef, Slot),
        not list.member({Schema, Slot, Fn}, !.Refs)
    then
        !:Refs = [{Schema, Slot, Fn} | !.Refs]
    else
        true
    ),
    list.foldl(collect_series_calls(IT), expr_children(E), !Refs).

    % The backend atoms: for each `series` declaration in source order, the backing
    % of every observation whose aggregation a lowered rule reads, or of every
    % observation when a rule reads `count`, once per backing and window
    % ([RDSC.5a.8.1]). No rule absorbs a sample ([RLOW.13.9]).
    %
    %@spec [RDSC.5a.2]
    %@spec [RDSC.5a.3]
    %@spec [RLOW.8.1.1]
    %@spec [RLOW.8.1.2]
    %@spec [RLOW.8.3.7]
    %@spec [RLOW.13.9]
:- func rdsc_5a_2_backends(resolved_file, list(schema), intern_table,
                           list({string, string, builtin_fn}))
    = list(series_decl).

rdsc_5a_2_backends(RF, Schemas, IT, Refs) =
    list.condense(list.map(declaration_backends(RF, Schemas, IT, Refs),
        list.filter_map(series_of, RF ^ rf_ast ^ af_decls))).

    %@helper
:- func series_of(ast_decl) = ast_series is semidet.

series_of(ad_series(S)) = S.

    %@helper
:- func declaration_backends(resolved_file, list(schema), intern_table,
                             list({string, string, builtin_fn}), ast_series)
    = list(series_decl).

declaration_backends(RF, Schemas, IT, Refs, Series) = Decls :-
    Slot = Series ^ asr_slot ^ asf_slot ^ id_name,
    ( if
        declared_target(RF, Series, SchemaName),
        schema_named(IT, Schemas, SchemaName, Schema),
        interned(IT, Slot, SlotRef),
        slot_by_name(Schema, SlotRef, Common)
    then
        Read = list.filter_map(read_on(SchemaName, Slot), Refs),
        WantsCount = ( if list.member(fn_series_count, Read) then yes
            else no ),
        Lines = Series ^ asr_lines,
        Pairs = rdsc_8_4_backing_order(
            list.map(line_backings(RF, Read, WantsCount), Lines)),
        ( if Pairs = [] then
            Decls = []
        else
            IdSlot = identity_slot(RF, SchemaName, Series),
            Persist = persist_ns(Series ^ asr_opts),
            MaxSamples = lsmp_5_1_sample_bound(Lines),
            Capacity = lser_13_14_capacity(Series ^ asr_opts),
            Element = element_of(Common ^ sc_kind),
            {Time, Gap} = lsig_2_3_6_integral_line(Lines),
            Needed = list.map(pair.fst, Pairs),
            Nulls = lnul_8_6_policy(Series ^ asr_opts),
            Decls = list.map(
                (func(P) = backend(Needed, SchemaName, Slot, IdSlot, Element,
                        Window, Persist, MaxSamples, Capacity, Time, Gap,
                        Nulls, Backing) :-
                    P = Backing - Window),
                Pairs)
        )
    else
        Decls = []
    ).

    %@helper
:- func read_on(string, string, {string, string, builtin_fn}) = builtin_fn
    is semidet.

read_on(SchemaName, Slot, {SchemaName, Slot, Fn}) = Fn.

    %@helper
:- pred declared_target(resolved_file::in, ast_series::in, string::out)
    is semidet.

declared_target(RF, Series, SchemaName) :-
    Ref = Series ^ asr_slot,
    Qualifier = Ref ^ asf_schema,
    (
        Qualifier = yes(Id),
        SchemaName = limp_13_1_own_of(RF, Id ^ id_name)
    ;
        Qualifier = no,
        schemas_declaring(RF, Ref ^ asf_slot ^ id_name) = [SchemaName]
    ).

    % The backings one line selects, each with the line's window, in the
    % order of its aggregations: those a lowered rule reads, or all of them
    % when a rule reads `count`.
    %
    %@helper
:- func line_backings(resolved_file, list(builtin_fn), bool, ast_series_line)
    = list(pair(backing, uint64)).

line_backings(RF, Read, WantsCount, Line) = Pairs :-
    Kind = time_kind(Line ^ asl_time),
    % 0 is an unwindowed backing. A line whose window is no `time_expr` gets
    % its backing at 0 when a rule reads `count`, and a rule that reads the
    % line itself is left unlowered (`rlow_8_3_1_companion`). No clause gives
    % such a window a code, so it is not refused.
    ( if
        line_window_ns(RF, Line ^ asl_time, Ns),
        Ns > 0i64
    then
        Window = uint64.cast_from_int64(Ns)
    else
        Window = 0u64
    ),
    Pairs = list.filter_map(
        (func(AggId) = Pair is semidet :-
            Agg = AggId ^ id_name,
            agg_builtin(Agg, Fn, _),
            ( WantsCount = yes ; list.member(Fn, Read) ),
            Pair = lser_18_1_backing(Agg, Kind) - Window),
        Line ^ asl_aggs).

    % Each line adds the (backing, window) pairs it is the first to select, in
    % [RDSC.8.1]'s `series_atom` alternation, after those of the lines before it.
    %
    %@spec [RDSC.8.4]
:- func rdsc_8_4_backing_order(list(list(pair(backing, uint64))))
    = list(pair(backing, uint64)).

rdsc_8_4_backing_order(PerLine) = list.foldl(
    (func(Line, Acc) = Acc ++ Fresh :-
        Ranked = list.sort_and_remove_dups(list.map(
            (func(P) = {rdsc_8_1_series_atom_rank(B), W, B} :- P = B - W),
            Line)),
        Fresh = list.filter_map(
            (func({_, W, B}) = P is semidet :-
                P = B - W,
                not list.member(P, Acc)),
            Ranked)),
    PerLine, []).

    %@spec [RDSC.8.1]
:- func rdsc_8_1_series_atom_rank(backing) = int.

rdsc_8_1_series_atom_rank(bk_welford) = 0.
rdsc_8_1_series_atom_rank(bk_ring_buffer) = 1.
rdsc_8_1_series_atom_rank(bk_monotonic_deque) = 2.
rdsc_8_1_series_atom_rank(bk_fifo_deque) = 3.
rdsc_8_1_series_atom_rank(bk_reservoir) = 4.
rdsc_8_1_series_atom_rank(bk_interval_pulse) = 5.
rdsc_8_1_series_atom_rank(bk_numeric_integral) = 6.

    %@helper
:- type time_kind
    --->    tk_all_time
    ;       tk_sliding
    ;       tk_tumbling
    ;       tk_sample.

    %@helper
:- func time_kind(ast_time_model) = time_kind.

time_kind(atm_all_time(_)) = tk_all_time.
time_kind(atm_sliding(_, _)) = tk_sliding.
time_kind(atm_tumbling(_, _)) = tk_tumbling.
time_kind(atm_sample(_, _)) = tk_sample.

    % [LSER.18.1]'s backing column.
    %
    %@spec [LSER.18.1]
    %@spec [LSIG.2.1]
    %@spec [LSIG.1.3.2]
    %@spec [LSIG.1.5.2]
:- func lser_18_1_backing(string, time_kind) = backing.

lser_18_1_backing(Agg, Kind) = Backing :-
    ( if Agg = "active_fraction" then
        Backing = bk_interval_pulse
    else if Agg = "integral" then
        Backing = bk_numeric_integral
    else if Agg = "onset_rate" then
        Backing = bk_ring_buffer
    else if Kind = tk_sample then
        Backing = bk_reservoir
    else if ( percentile_n(Agg, _) ; Agg = "median" ) then
        Backing = bk_ring_buffer
    else if ( Agg = "count_distinct" ; Agg = "count_of" ; Agg = "contains" )
    then
        Backing = bk_ring_buffer
    else if ( Agg = "min" ; Agg = "max" ), Kind = tk_sliding then
        Backing = bk_monotonic_deque
    else if
        ( Agg = "first" ; Agg = "bool_and" ; Agg = "bool_or" ),
        ( Kind = tk_sliding ; Kind = tk_tumbling )
    then
        Backing = bk_fifo_deque
    else if Agg = "last", Kind = tk_sliding then
        Backing = bk_fifo_deque
    else if
        ( Agg = "mean" ; Agg = "sum" ; Agg = "count" ; Agg = "stdev"
        ; Agg = "pstdev" ; Agg = "variance" ; Agg = "pvariance"
        ; Agg = "rate" ; Agg = "direction" ),
        Kind = tk_sliding
    then
        Backing = bk_ring_buffer
    else
        Backing = bk_welford
    ).

    % The block's `capacity: N`, or 0 when none is declared. One above a `uint32`
    % reads as none.
    %
    %@spec [LSER.13.14]
:- func lser_13_14_capacity(list(ast_block_kwarg)) = uint32.

lser_13_14_capacity(Opts) = Cap :-
    ( if
        list.find_first_match((pred(O::in) is semidet :-
            O = abk_capacity(_, _)), Opts, abk_capacity(Tok, _)),
        Tok ^ tk_tok = int_lit(N),
        N >= 1i64,
        N =< 4294967295i64
    then
        Cap = uint32.det_from_int(int64.cast_to_int(N))
    else
        Cap = 0u32
    ).

    %@helper
:- func persist_ns(list(ast_block_kwarg)) = uint64.

persist_ns(Opts) = Ns :-
    ( if
        list.find_first_match((pred(O::in) is semidet :-
            O = abk_persist(_, _)), Opts, abk_persist(E, _)),
        duration_ns_of(E) > 0i64
    then
        Ns = uint64.cast_from_int64(duration_ns_of(E))
    else
        Ns = 0u64
    ).

    % The first `sample <n>` line's `n`.
    %
    %@spec [LSMP.5.1]
:- func lsmp_5_1_sample_bound(list(ast_series_line)) = uint32.

lsmp_5_1_sample_bound([]) = 0u32.
lsmp_5_1_sample_bound([L | Ls]) =
    ( if L ^ asl_time = atm_sample(ex_int(N, _), _), N > 0i64 then
        uint32.det_from_int(int64.cast_to_int(N))
    else
        lsmp_5_1_sample_bound(Ls)
    ).

    %@helper
:- func element_of(slot_kind) = element_type.

element_of(Kind) = Element :-
    ( if Kind = k_float then Element = el_float
    else if int_represented(Kind) then Element = el_int
    else if Kind = k_string then Element = el_string
    else if Kind = k_bool then Element = el_bool
    else Element = el_unspecified
    ).

    % SeriesBackendNumericIntegral's time model and gap policy, from the `integral`
    % line; `hold` is the default gap ([LSIG.3.1]).
    %
    %@spec [LSIG.2.3.6]
    %@spec [LSIG.3.1]
:- func lsig_2_3_6_integral_line(list(ast_series_line)) = {time_model, gap_policy}.

lsig_2_3_6_integral_line([]) = {tm_unspecified, gp_hold}.
lsig_2_3_6_integral_line([L | Ls]) = Result :-
    ( if
        list.find_first_match((pred(A::in) is semidet :-
            A ^ id_name = "integral"), L ^ asl_aggs, _)
    then
        Kind = time_kind(L ^ asl_time),
        Time = ( if Kind = tk_sliding then tm_sliding
            else if Kind = tk_all_time then tm_all_time
            else if Kind = tk_tumbling then tm_tumbling
            else tm_unspecified ),
        MaybeGap = L ^ asl_gap,
        (
            MaybeGap = no,
            Gap = gp_hold
        ;
            MaybeGap = yes(G),
            Gap = gap_of(G)
        ),
        Result = {Time, Gap}
    else
        Result = lsig_2_3_6_integral_line(Ls)
    ).

    %@helper
:- func gap_of(lgra_7_6a_gap_policy) = gap_policy.

gap_of(dsc.expr.gp_hold(_)) = ds.series.gp_hold.
gap_of(dsc.expr.gp_zero(_)) = ds.series.gp_zero.
gap_of(dsc.expr.gp_skip(_)) = ds.series.gp_skip.

    %@helper
    % The declaration's `nulls:` option as the wire carries it.
    %
    %@spec [LNUL.8.6]
:- func lnul_8_6_policy(list(ast_block_kwarg)) = null_policy.

lnul_8_6_policy([]) = np_unspecified.
lnul_8_6_policy([Opt | Opts]) = Policy :-
    ( if Opt = abk_nulls(Word, _) then
        ( if Word ^ id_name = "skip" then
            Policy = np_skip
        else if Word ^ id_name = "hold" then
            Policy = np_hold
        else
            Policy = np_zero
        )
    else
        Policy = lnul_8_6_policy(Opts)
    ).

:- func backend(list(backing), string, string, string, element_type, uint64,
                uint64, uint32, uint32, time_model, gap_policy, null_policy,
                backing)
    = series_decl.

backend(Needed, Schema, Slot, IdSlot, Element0, Window, Persist, Max0, Capacity,
        Time0, Gap0, Nulls, Backing) = Decl :-
    ElementNeeded = ( if
        ( list.member(bk_ring_buffer, Needed)
        ; list.member(bk_fifo_deque, Needed)
        ; list.member(bk_numeric_integral, Needed)
        )
    then Element0 else el_unspecified ),
    ( if
        ( Backing = bk_ring_buffer ; Backing = bk_fifo_deque
        ; Backing = bk_numeric_integral )
    then
        Element = ElementNeeded
    else
        Element = el_unspecified
    ),
    % A declared `capacity` rides as `max_samples` on every backing that retains
    % samples. SeriesBackendReservoir keeps its `sample <n>`.
    ( if Backing = bk_welford then
        Max = 0u32
    else if Backing = bk_reservoir then
        Max = Max0
    else if Capacity \= 0u32 then
        Max = Capacity
    else
        Max = Max0
    ),
    ( if Backing = bk_numeric_integral then
        Time = Time0, Gap = Gap0
    else
        Time = tm_unspecified, Gap = gp_unspecified
    ),
    Decl = series_decl(Backing, Schema, Slot, IdSlot, Element, Window, Persist,
        Max, Time, Gap, Nulls).

%-----------------------------------------------------------------------------%

    %@helper
:- func det_node_id(uint32) = node_id.

det_node_id(U) = Id :-
    ( if node_id(U, Found) then
        Id = Found
    else
        unexpected($pred, "node id 0 is reserved and never allocated")
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.rete.
%-----------------------------------------------------------------------------%

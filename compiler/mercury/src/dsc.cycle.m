% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.cycle -- the rule dependency graph, and the cycles in it.
%
% Of [LCYC.3.2.2]'s edge forms, `emit`, `call` and `withdraw` are built; the
% cache edge is not. A cycle is refused only in an SCC [LCYC.3.1.1] does not
% admit. `publish` makes no edge, because it asserts nothing in this tier
% ([LTIE.4.3]), and a `ttl` breaks no cycle ([LCYC.6.2]). A rule's edges to
% itself on a schema it both emits and withdraws a binding of are left out:
% `dsc.validate` reports that SCC ([LCYC.3.3.3]).
%-----------------------------------------------------------------------------%

:- module dsc.cycle.
:- interface.

:- import_module dsc.ast.
:- import_module dsc.diag.
:- import_module dsc.expr.
:- import_module dsc.validate_codes.
:- import_module dsc.resolve.

:- import_module list.
:- import_module pair.

%-----------------------------------------------------------------------------%

    % Reports the first cycle found, not every cycle.
    %
    %@spec [LCYC.3.1]
:- pred lcyc_3_1_rule_graph(resolved_file::in, list(diagnostic)::out) is det.

    % The same check over a whole compilation unit: every library whose rules
    % join the artefact ([LIMP.7.5]), leaves first, then the file (named "").
    % A schema is keyed by its own name ([LIMP.13.1]), not as a module spells
    % it; a name that resolves to no schema makes no edge. Each diagnostic
    % comes with the module of the rule it is placed at, "" for the file, so
    % the caller names it as [RCLI.1.9] says.
    %
    %@spec [LCYC.6.3]
:- pred lcyc_6_3_unit_graph(list(pair(string, resolved_file))::in,
                            list(pair(string, diagnostic))::out) is det.

    % The `where` of the pattern binding `Binding` requires a literal of some
    % slot not in `Keys`, and the emit's arguments give that slot a literal
    % that differs from it. The caller checks that the emit's key slots are
    % `Binding`'s own.
    %
    %@spec [LLOG.11.9]
    %@spec [LCYC.6.1.2]
:- pred llog_11_9_literal_breaks(string::in, lgra_9_3_1_expr::in,
                                 list(string)::in, list(ast_action_arg)::in)
    is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.token.
:- import_module ds.
:- import_module ds.i64.

:- import_module assoc_list.
:- import_module bool.
:- import_module float.
:- import_module map.
:- import_module maybe.
:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%
% The graph
%-----------------------------------------------------------------------------%

    %@helper
:- type edge
    --->    edge(
                ed_from   :: string,
                ed_to     :: string,
                ed_schema :: string,
                ed_kind   :: edge_kind,
                ed_defeat :: bool   % an `emit` into a negated pattern
            ).

    %@helper
:- type edge_kind
    --->    ek_emit
    ;       ek_withdraw.

    %@helper
:- type match
    --->    match(
                mt_schema  :: string,
                mt_negated :: bool,
                mt_where   :: maybe(lgra_9_3_1_expr)
            ).

    %@helper
:- type emission
    --->    emission(
                em_schema :: string,
                em_args   :: list(ast_action_arg)
            ).

    % An `emit` as written, before either graph keys it.
    %
    %@helper
:- type emitted
    --->    emitted(
                et_ref  :: ast_type_ref,
                et_args :: list(ast_action_arg)
            ).

    %@helper
:- type rule_node
    --->    rule_node(
                rn_name         :: ident,
                rn_matches      :: list(match),
                rn_emits        :: list(emission),
                rn_withdraws    :: list(string), % the withdrawn bindings' schemas
                rn_cache_writes :: list(cache_key), % `cache`, `cache_delete`
                rn_cache_reads  :: list(cache_key), % `cached()` in a where / let
                rn_emit_withdraw :: list(string)  % [LCYC.3.3.3]'s schemas
            ).

    % A cache key as [LCYC.3.1.1] compares them: a literal string, or anything
    % else, which "is the same key as every other". An interpolated string is
    % not a literal.
    %
    %@helper
:- type cache_key
    --->    ck_literal(string)
    ;       ck_any.

%-----------------------------------------------------------------------------%

lcyc_3_1_rule_graph(RF, Diagnostics) :-
    Nodes = rule_nodes(RF, RF ^ rf_ast ^ af_decls),
    Diagnostics = list.map(pair.snd, refused_cycle(Nodes)).

    % Searches only the refused SCCs' internal edges, so an admitted cycle is
    % never reported. Each diagnostic comes with the name of the rule node it
    % is placed at (`cycle_pos`).
    %
    %@helper
:- func refused_cycle(list(rule_node)) = list(pair(string, diagnostic)).

refused_cycle(Nodes) = Diagnostics :-
    Edges = lcyc_3_2_2_edges(Nodes),
    Names = list.map(node_name, Nodes),
    Refused = refused_sccs(Nodes, adjacency(Edges), Names),
    Internal = list.filter(internal_to(Refused), Edges),
    ( if find_cycle(adjacency(Internal), Names, Cycle) then
        % `cycle_pos` places the diagnostic at the first edge's rule.
        Rule = ( if Cycle = [First | _] then First ^ ed_from else "" ),
        Diagnostics = [Rule - lcyc_3_3_2_cycle_diagnostic(Nodes, Cycle)]
    else
        Diagnostics = []
    ).

%-----------------------------------------------------------------------------%
% The compilation unit -- [LCYC.6.3]
%-----------------------------------------------------------------------------%

lcyc_6_3_unit_graph(Modules, Diagnostics) :-
    Nodes = list.condense(list.map(unit_nodes, Modules)),
    Owners = list.condense(list.map(unit_owners, Modules)),
    Diagnostics = list.map(
        ( func(Rule - D) = Owner - D :-
            ( if assoc_list.search(Owners, Rule, Module) then
                Owner = Module
            else
                Owner = ""
            )
        ), refused_cycle(Nodes)).

    % Each rule node's key, as `unit_node` names it, with its module.
    %
    %@helper
:- func unit_owners(pair(string, resolved_file)) = list(pair(string, string)).

unit_owners(Module - RF) =
    list.filter_map(
        ( func(D) = unit_rule_name(Module, R) - Module is semidet :-
            D = ad_rule(R) ),
        RF ^ rf_ast ^ af_decls).

    % One module's rules as graph nodes, every name replaced by its key: the
    % rule by `module:rule` (the file's by its bare name), each schema by its
    % own name.
    %
    %@helper
:- func unit_nodes(pair(string, resolved_file)) = list(rule_node).

unit_nodes(Module - RF) =
    list.filter_map(unit_node(Module, RF), RF ^ rf_ast ^ af_decls).

    %@helper
:- func unit_node(string, resolved_file, ast_decl) = rule_node is semidet.

unit_node(Module, RF, ad_rule(R)) =
        rule_node(Name,
            list.filter_map(unit_match(RF), unit_bodies(R)),
            Emits
                ++ list.condense(list.map(lcyc_3_2_2_unit_outcomes(RF),
                    rhs_actions(R))),
            Withdraws,
            cache_writes_of(R), cache_reads_of(R),
            lcyc_3_3_3_emit_withdraw(Emits, Withdraws)) :-
    Id = R ^ ar_name,
    Name = Id ^ id_name := unit_rule_name(Module, R),
    Emits = list.filter_map(unit_emission(RF), action_emissions(R)),
    Withdraws = list.filter_map(unit_body_key(RF), withdrawn_bodies(R)).

    % A call emits its response by the schema's own name, whether or not the
    % calling file binds one to it.
    %
    %@spec [LCYC.3.2.2]
:- func lcyc_3_2_2_unit_outcomes(resolved_file, ast_action) = list(emission).

lcyc_3_2_2_unit_outcomes(RF, Action) = Outcomes :-
    ( if Action ^ aac_head = aah_call(Ref) then
        Args = lcyc_3_2_2_call_args(Action),
        CallError = list.filter_map(unit_emission(RF),
            [lcyc_3_2_2_call_error(Action)]),
        ( if
            map.search(RF ^ rf_response_names, service_key(Ref), Response)
        then
            Outcomes = [emission(Response, Args) | CallError]
        else
            Outcomes = CallError
        )
    else
        Outcomes = []
    ).

    %@helper
:- func unit_body_key(resolved_file, ast_pattern_body) = string is semidet.

unit_body_key(RF, Body) = Schema ^ as_own :-
    lgra_22_4_schema_of(RF, Body ^ apb_type, Schema).

    %@helper
:- func unit_rule_name(string, ast_rule) = string.

unit_rule_name(Module, R) =
    ( if Module = "" then R ^ ar_name ^ id_name
      else Module ++ ":" ++ R ^ ar_name ^ id_name ).

    % Every pattern body of a rule, qualified heads included, with whether it
    % is negated.
    %
    %@helper
:- func unit_bodies(ast_rule) = list(pair(ast_pattern_body, bool)).

unit_bodies(Rule) = list.condense(list.map(clause_bodies, Rule ^ ar_lhs)).

    %@helper
:- func clause_bodies(ast_lhs_clause) = list(pair(ast_pattern_body, bool)).

clause_bodies(alc_pattern(ap_simple(B))) = [B - no].
clause_bodies(alc_pattern(ap_negated(B, _))) = [B - yes].
clause_bodies(alc_pattern(ap_sequence(_, Head, Steps, _))) =
    [Head - no | list.map(( func(S) = S ^ ats_body - no ), Steps)].
clause_bodies(alc_then(S)) = [S ^ ats_body - no].

    %@helper
:- func unit_match(resolved_file, pair(ast_pattern_body, bool)) = match
    is semidet.

unit_match(RF, Body - Negated) =
        match(Schema ^ as_own, Negated, Body ^ apb_where) :-
    lgra_22_4_schema_of(RF, Body ^ apb_type, Schema).

    %@helper
:- func unit_emission(resolved_file, emitted) = emission is semidet.

unit_emission(RF, emitted(Ref, Args)) = emission(Schema ^ as_own, Args) :-
    lgra_22_4_schema_of(RF, Ref, Schema).

    %@helper
:- func node_name(rule_node) = string.

node_name(Node) = Node ^ rn_name ^ id_name.

    %@helper
:- func rule_nodes(resolved_file, list(ast_decl)) = list(rule_node).

rule_nodes(_, []) = [].
rule_nodes(RF, [D | Ds]) = Nodes :-
    ( if D = ad_rule(R) then
        Withdraws = list.filter_map(file_body_schema, withdrawn_bodies(R)),
        EmitWithdraw = lcyc_3_3_3_emit_withdraw(
            list.filter_map(file_emission, action_emissions(R)), Withdraws),
        Nodes = [rule_node(R ^ ar_name, matches_of(R),
            list.filter_map(file_emission, emissions_of(RF, R)),
            Withdraws, cache_writes_of(R), cache_reads_of(R), EmitWithdraw)
            | rule_nodes(RF, Ds)]
    else
        Nodes = rule_nodes(RF, Ds)
    ).

    % The schemas the rule `emit`s and withdraws a binding of. A call's
    % outcomes are not `emit`s, as `dsc.validate`'s `lcyc_3_3_3_withdraw_emit`
    % reads them; a `publish` makes no edge here, so its schema needs no entry.
    %
    %@spec [LCYC.3.3.3]
:- func lcyc_3_3_3_emit_withdraw(list(emission), list(string)) = list(string).

lcyc_3_3_3_emit_withdraw(Emits, Withdraws) =
    list.filter(
        ( pred(S::in) is semidet :-
            list.any_true(( pred(E::in) is semidet :- E ^ em_schema = S ),
                Emits)
        ), Withdraws).

    %@helper
:- func file_body_schema(ast_pattern_body) = string is semidet.

file_body_schema(Body) = Id ^ id_name :-
    Body ^ apb_type = atr_bare(Id).

%-----------------------------------------------------------------------------%
% Edges -- [LCYC.3.2.2]
%-----------------------------------------------------------------------------%

    % An `emit` into a `no` pattern is an edge, labelled so that a cycle through
    % it gets [LCYC.3.4.1]'s diagnostic.
    %
    %@spec [LCYC.3.2.1]
    %@spec [LCYC.3.2.2]
:- func lcyc_3_2_2_edges(list(rule_node)) = list(edge).

lcyc_3_2_2_edges(Nodes) =
    list.condense(list.map(edges_from(Nodes), Nodes)).

    %@helper
:- func edges_from(list(rule_node), rule_node) = list(edge).

edges_from(Nodes, From) =
    list.negated_filter(lcyc_3_3_3_reported(From),
        list.condense(list.map(edges_for_emission(Nodes, From), From ^ rn_emits))
        ++ list.condense(list.map(lcyc_3_2_2_withdraw_edges(Nodes, From),
            From ^ rn_withdraws))).

    % A rule's edge to itself on a schema it both `emit`s and withdraws a
    % binding of: the one-rule SCC that `dsc.validate` reports at the RHS, as
    % DS_VALIDATE_WITHDRAW_EMIT_SAME_SCHEMA, rather than as a graph cycle. Its
    % edges to other rules stay, so a cycle through them is still found.
    %
    %@spec [LCYC.3.3.3]
:- pred lcyc_3_3_3_reported(rule_node::in, edge::in) is semidet.

lcyc_3_3_3_reported(From, Edge) :-
    Edge ^ ed_to = Edge ^ ed_from,
    list.member(Edge ^ ed_schema, From ^ rn_emit_withdraw).

    % Never a defeat edge: a withdraw into `no X` enables the target. No literal
    % break applies: a withdraw carries no slot values.
    %
    %@spec [LCYC.3.2.2]
:- func lcyc_3_2_2_withdraw_edges(list(rule_node), rule_node, string)
    = list(edge).

lcyc_3_2_2_withdraw_edges(Nodes, From, Schema) =
    list.filter_map(withdraw_edge_to(From, Schema), Nodes).

    %@helper
:- func withdraw_edge_to(rule_node, string, rule_node) = edge is semidet.

withdraw_edge_to(From, Schema, To) =
        edge(node_name(From), node_name(To), Schema, ek_withdraw, no) :-
    list.any_true(on_schema(Schema), To ^ rn_matches).

    %@helper
:- func edges_for_emission(list(rule_node), rule_node, emission) = list(edge).

edges_for_emission(Nodes, From, Emission) =
    list.filter_map(edge_to(From, Emission), Nodes).

    %@helper
:- func edge_to(rule_node, emission, rule_node) = edge is semidet.

edge_to(From, Emission, To) = Edge :-
    Schema = Emission ^ em_schema,
    matching(To ^ rn_matches, Schema, Negated),
    not lcyc_6_1_dropped_edge(To, Schema, Emission),
    Edge = edge(node_name(From), node_name(To), Schema, ek_emit, Negated).

    % Whether the rule matches the schema at all, and whether any such pattern
    % is negated. A rule matching a schema both ways has one edge, a defeat.
    %
    %@helper
:- pred matching(list(match)::in, string::in, bool::out) is semidet.

matching(Matches, Schema, Negated) :-
    OnSchema = list.filter(on_schema(Schema), Matches),
    OnSchema = [_ | _],
    ( if list.any_true(is_negated, OnSchema) then
        Negated = yes
    else
        Negated = no
    ).

    %@helper
:- pred on_schema(string::in, match::in) is semidet.

on_schema(Schema, Match) :-
    Match ^ mt_schema = Schema.

    %@helper
:- pred is_negated(match::in) is semidet.

is_negated(Match) :-
    Match ^ mt_negated = yes.

%-----------------------------------------------------------------------------%
% The literal break -- [LCYC.6.1]
%-----------------------------------------------------------------------------%

    %@spec [LCYC.6.1]
    %@spec [LCYC.6.1.1]
    %@spec [LCYC.6.1.2]
    %@spec [LCYC.6.1.3]
:- pred lcyc_6_1_dropped_edge(rule_node::in, string::in, emission::in)
    is semidet.

lcyc_6_1_dropped_edge(To, Schema, Emission) :-
    Positive = list.filter(positive_on(Schema), To ^ rn_matches),
    Positive = [_ | _],
    list.all_true(broken_by(Emission), Positive).

    %@helper
:- pred positive_on(string::in, match::in) is semidet.

positive_on(Schema, Match) :-
    Match ^ mt_schema = Schema,
    Match ^ mt_negated = no.

    %@helper
:- pred broken_by(emission::in, match::in) is semidet.

broken_by(Emission, Match) :-
    Match ^ mt_where = yes(Where),
    equality_constraints(Where, [], Constraints),
    Constraints = [_ | _],
    list.any_true(violated_by(Emission), Constraints).

    %@helper
:- type constraint
    --->    constraint(
                ct_slot  :: string,
                ct_value :: literal
            ).

    % A literal's value without its position. `lcyc_6_1_2_differ` compares these.
    %
    %@helper
:- type literal
    --->    lit_int(int64)
    ;       lit_float(float)
    ;       lit_string(string)
    ;       lit_bool(bool).

    %@helper
:- pred violated_by(emission::in, constraint::in) is semidet.

violated_by(Emission, Constraint) :-
    emitted_literal(Emission ^ em_args, Constraint ^ ct_slot, Emitted),
    lcyc_6_1_2_differ(Emitted, Constraint ^ ct_value).

    % A pair that is not comparable does not differ, so its edge stays. An Int
    % and a Float compare as `==` does ([LEXP.7.3]), through `ds.i64.to_float`,
    % the promotion the runtime's `compare_values` uses. Floats compare as IEEE
    % `==`, so `0.0` equals `-0.0`. Two Ints compare exactly ([LDET.3.2.2]).
    %
    %@spec [LCYC.6.1.2]
:- pred lcyc_6_1_2_differ(literal::in, literal::in) is semidet.

lcyc_6_1_2_differ(A, B) :-
    (
        A = lit_int(I),
        (
            B = lit_int(J),
            I \= J
        ;
            B = lit_float(G),
            not float_equal(ds.i64.to_float(I), G)
        )
    ;
        A = lit_float(F),
        (
            B = lit_float(G),
            not float_equal(F, G)
        ;
            B = lit_int(J),
            not float_equal(F, ds.i64.to_float(J))
        )
    ;
        A = lit_string(S),
        B = lit_string(T),
        S \= T
    ;
        A = lit_bool(X),
        B = lit_bool(Y),
        X \= Y
    ).

    %@helper
:- pred float_equal(float::in, float::in) is semidet.

float_equal(F, G) :-
    F =< G,
    G =< F.

    %@helper
:- pred emitted_literal(list(ast_action_arg)::in, string::in, literal::out)
    is semidet.

emitted_literal([Arg | Args], Slot, Value) :-
    ( if
        Arg = aaa_kwarg(Name, Expr, _),
        Name ^ id_name = Slot,
        literal_of(Expr, Found)
    then
        Value = Found
    else
        emitted_literal(Args, Slot, Value)
    ).

    % Every `binding.slot == <literal>` in a `where`, including the conjuncts of
    % an `and`. An equality under an `or` promises nothing, so it is not read.
    %
    %@helper
:- pred equality_constraints(lgra_9_3_1_expr::in, list(constraint)::in,
                             list(constraint)::out) is det.

equality_constraints(Expr, !Constraints) :-
    ( if Expr = ex_binary(bo_and, Left, Right, _) then
        equality_constraints(Left, !Constraints),
        equality_constraints(Right, !Constraints)
    else if
        Expr = ex_compare(Left, [Step], _),
        Step ^ cs_op = co_eq,
        Left = ex_slot(_, SlotIdent, _),
        literal_of(Step ^ cs_right, Value)
    then
        !:Constraints = [constraint(SlotIdent ^ id_name, Value) | !.Constraints]
    else
        true
    ).

llog_11_9_literal_breaks(Binding, Where, Keys, Args) :-
    binding_constraints(Binding, Where, [], Constraints),
    list.any_true(
        ( pred(C::in) is semidet :-
            not list.member(C ^ ct_slot, Keys),
            emitted_literal(Args, C ^ ct_slot, Emitted),
            lcyc_6_1_2_differ(Emitted, C ^ ct_value)
        ), Constraints).

    % `equality_constraints`, on `Binding`'s own slots only.
    %
    %@helper
:- pred binding_constraints(string::in, lgra_9_3_1_expr::in,
                            list(constraint)::in, list(constraint)::out) is det.

binding_constraints(Binding, Expr, !Constraints) :-
    ( if Expr = ex_binary(bo_and, Left, Right, _) then
        binding_constraints(Binding, Left, !Constraints),
        binding_constraints(Binding, Right, !Constraints)
    else if
        Expr = ex_compare(Left, [Step], _),
        Step ^ cs_op = co_eq,
        Left = ex_slot(ex_name(Base), SlotIdent, _),
        Base ^ id_name = Binding,
        literal_of(Step ^ cs_right, Value)
    then
        !:Constraints = [constraint(SlotIdent ^ id_name, Value) | !.Constraints]
    else
        true
    ).

    %@helper
:- pred literal_of(lgra_9_3_1_expr::in, literal::out) is semidet.

literal_of(ex_int(I, _), lit_int(I)).
literal_of(ex_float(F, _), lit_float(F)).
literal_of(ex_string(S, _), lit_string(S)).
literal_of(ex_bool(B, _), lit_bool(B)).

%-----------------------------------------------------------------------------%
% Reading a rule
%-----------------------------------------------------------------------------%

    % A qualified head makes no match in the file's graph; the unit's graph
    % resolves it.
    %
    %@helper
:- func matches_of(ast_rule) = list(match).

matches_of(Rule) = list.condense(list.map(clause_matches, Rule ^ ar_lhs)).

    %@helper
:- func clause_matches(ast_lhs_clause) = list(match).

clause_matches(alc_pattern(P)) = pattern_matches(P).
clause_matches(alc_then(S)) = step_matches(S).

    %@helper
:- func pattern_matches(ast_pattern) = list(match).

pattern_matches(ap_simple(B)) = body_matches(B, no).
pattern_matches(ap_negated(B, _)) = body_matches(B, yes).
pattern_matches(ap_sequence(_, Head, Steps, _)) =
    body_matches(Head, no)
        ++ list.condense(list.map(step_matches, Steps)).

    %@helper
:- func step_matches(ast_then_step) = list(match).

step_matches(Step) = body_matches(Step ^ ats_body, no).

    %@helper
:- func body_matches(ast_pattern_body, bool) = list(match).

body_matches(Body, Negated) = Matches :-
    ( if Body ^ apb_type = atr_bare(Id) then
        Matches = [match(Id ^ id_name, Negated, Body ^ apb_where)]
    else
        Matches = []
    ).

    %@helper
:- func emissions_of(resolved_file, ast_rule) = list(emitted).

emissions_of(RF, Rule) =
    action_emissions(Rule)
        ++ list.condense(list.map(lcyc_3_2_2_call_outcomes(RF),
            rhs_actions(Rule))).

    %@helper
:- func action_emissions(ast_rule) = list(emitted).

action_emissions(Rule) = list.filter_map(action_emission, rhs_actions(Rule)).

    % A call is read as emitting its outcomes: one fact of the response schema
    % and one `CallError`, each with `corr` set to the call's literal `as`, so
    % the literal break ([LCYC.6.1]) sees the correlation. A service this file
    % does not resolve produces the `CallError` alone. The response is written
    % as each name the file binds to its schema.
    %
    %@spec [LCYC.3.2.2]
    %@spec [LCYC.2.4.2]
:- func lcyc_3_2_2_call_outcomes(resolved_file, ast_action) = list(emitted).

lcyc_3_2_2_call_outcomes(RF, Action) = Outcomes :-
    ( if Action ^ aac_head = aah_call(Ref) then
        CallError = lcyc_3_2_2_call_error(Action),
        ( if
            map.search(RF ^ rf_response_names, service_key(Ref), Response)
        then
            Outcomes = list.map(
                ( func(Bound) = emitted(Bound, lcyc_3_2_2_call_args(Action)) ),
                lcyc_3_2_2_bindings(RF, Response, Action ^ aac_pos))
                ++ [CallError]
        else
            Outcomes = [CallError]
        )
    else
        Outcomes = []
    ).

    %@helper
:- func lcyc_3_2_2_call_args(ast_action) = list(ast_action_arg).

lcyc_3_2_2_call_args(Action) = Args :-
    ( if Action ^ aac_as = yes(ex_string(Corr, Pos)) then
        Args = [aaa_kwarg(ident("corr", Pos), ex_string(Corr, Pos), Pos)]
    else
        Args = []
    ).

    %@helper
:- func lcyc_3_2_2_call_error(ast_action) = emitted.

lcyc_3_2_2_call_error(Action) =
    emitted(atr_bare(ident("CallError", Action ^ aac_pos)),
        lcyc_3_2_2_call_args(Action)).

    % Each bare name the file binds to the schema whose own name is `Own`.
    %
    %@helper
:- func lcyc_3_2_2_bindings(resolved_file, string, pos) = list(ast_type_ref).

lcyc_3_2_2_bindings(RF, Own, Pos) = list.filter(
    ( pred(Bound::in) is semidet :-
        lgra_22_4_schema_of(RF, Bound, Schema),
        Schema ^ as_own = Own
    ),
    list.map(( func(Name) = atr_bare(ident(Name, Pos)) ),
        map.keys(RF ^ rf_types))).

    %@helper
:- func cache_writes_of(ast_rule) = list(cache_key).

cache_writes_of(Rule) = list.filter_map(action_cache_key, rhs_actions(Rule)).

    % A missing `key:` is `dsc.validate`'s refusal; here it counts as any key.
    %
    %@helper
:- func action_cache_key(ast_action) = cache_key is semidet.

action_cache_key(Action) = Key :-
    ( Action ^ aac_head = aah_cache
    ; Action ^ aac_head = aah_cache_delete
    ),
    ( if key_arg(action_args(Action), KeyExpr) then
        Key = cache_key_of(KeyExpr)
    else
        Key = ck_any
    ).

    %@helper
:- func action_args(ast_action) = list(ast_action_arg).

action_args(Action) =
    ( if Action ^ aac_block = aab_kwargs(BlockArgs) then
        Action ^ aac_args ++ BlockArgs
    else
        Action ^ aac_args
    ).

    %@helper
:- pred key_arg(list(ast_action_arg)::in, lgra_9_3_1_expr::out) is semidet.

key_arg([Arg | Args], Expr) :-
    ( if Arg = aaa_kwarg(Name, E, _), Name ^ id_name = "key" then
        Expr = E
    else
        key_arg(Args, Expr)
    ).

    %@helper
:- func cache_key_of(lgra_9_3_1_expr) = cache_key.

cache_key_of(Expr) =
    ( if
        Expr = ex_string(Text, _),
        not string.contains_char(Text, '{')
    then
        ck_literal(Text)
    else
        ck_any
    ).

    % Every `cached(k)` in a `where` or a `let`, the only places [LSTO.4.3.1b]
    % admits it.
    %
    %@helper
:- func cache_reads_of(ast_rule) = list(cache_key).

cache_reads_of(Rule) =
    list.condense(list.map(expr_cached_keys, Wheres ++ Lets)) :-
    Wheres = list.filter_map(body_where,
        list.map(pair.fst, unit_bodies(Rule))),
    Lets = list.condense(list.map(let_exprs, Rule ^ ar_rhs ^ arr_lets)).

    %@helper
:- func body_where(ast_pattern_body) = lgra_9_3_1_expr is semidet.

body_where(Body) = Where :-
    Body ^ apb_where = yes(Where).

    %@helper
:- func let_exprs(ast_let_decl) = list(lgra_9_3_1_expr).

let_exprs(Decl) = list.map(binding_expr, Decl ^ ald_bindings).

    %@helper
:- func binding_expr(ast_let_binding) = lgra_9_3_1_expr.

binding_expr(alb_simple(_, _, Expr, _)) = Expr.
binding_expr(alb_capture(_, Expr, _)) = Expr.

    %@helper
:- func expr_cached_keys(lgra_9_3_1_expr) = list(cache_key).

expr_cached_keys(ex_int(_, _)) = [].
expr_cached_keys(ex_float(_, _)) = [].
expr_cached_keys(ex_string(_, _)) = [].
expr_cached_keys(ex_unit(_, _, _)) = [].
expr_cached_keys(ex_bool(_, _)) = [].
expr_cached_keys(ex_null(_)) = [].
expr_cached_keys(ex_name(_)) = [].
expr_cached_keys(ex_unary(_, E, _)) = expr_cached_keys(E).
expr_cached_keys(ex_not(E, _)) = expr_cached_keys(E).
expr_cached_keys(ex_binary(_, L, R, _)) =
    expr_cached_keys(L) ++ expr_cached_keys(R).
expr_cached_keys(ex_compare(L, Steps, _)) =
    expr_cached_keys(L) ++ list.condense(list.map(step_cached_keys, Steps)).
expr_cached_keys(ex_is(E, _, _, _)) = expr_cached_keys(E).
expr_cached_keys(ex_slot(E, _, _)) = expr_cached_keys(E).
expr_cached_keys(ex_index(E, I, _)) =
    expr_cached_keys(E) ++ expr_cached_keys(I).
expr_cached_keys(ex_call(F, Args, _)) =
    cached_call_key(F, Args) ++ expr_cached_keys(F)
        ++ list.condense(list.map(expr_cached_keys, Args)).
expr_cached_keys(ex_cast(E, _, _, _)) = expr_cached_keys(E).
expr_cached_keys(ex_match(E, _, _, _, _)) = expr_cached_keys(E).

    %@helper
:- func step_cached_keys(lgra_9_3_2_compare_step) = list(cache_key).

step_cached_keys(Step) = expr_cached_keys(Step ^ cs_right).

    %@helper
:- func cached_call_key(lgra_9_3_1_expr, list(lgra_9_3_1_expr))
    = list(cache_key).

cached_call_key(Callee, Args) =
    ( if Callee = ex_name(Id), Id ^ id_name = "cached" then
        ( if Args = [KeyExpr | _] then
            [cache_key_of(KeyExpr)]
        else
            [ck_any]
        )
    else
        []
    ).

    % The key `rf_services` files a called service under.
    %
    %@helper
:- func service_key(ast_service_ref) = string.

service_key(asr_bare(Path)) = dotted_ids(Path).

    %@helper
:- func dotted_ids(list(ident)) = string.

dotted_ids(Ids) = string.join_list(".", list.map((func(I) = I ^ id_name), Ids)).

    % A binding no pattern declares is `dsc.validate`'s refusal.
    %
    %@helper
:- func withdrawn_bodies(ast_rule) = list(ast_pattern_body).

withdrawn_bodies(Rule) =
    list.filter_map(withdrawn_body(list.map(pair.fst, unit_bodies(Rule))),
        rhs_actions(Rule)).

    %@helper
:- func withdrawn_body(list(ast_pattern_body), ast_action) = ast_pattern_body
    is semidet.

withdrawn_body(Bodies, Action) = Body :-
    Action ^ aac_head = aah_withdraw(Binding),
    list.find_first_match(binds(Binding ^ id_name), Bodies, Body).

    %@helper
:- pred binds(string::in, ast_pattern_body::in) is semidet.

binds(Name, Body) :-
    Body ^ apb_binding = yes(Id),
    Id ^ id_name = Name.

    % The RHS's actions, its `after` clauses' actions and every `call`'s
    % continuation bodies, nested ones included, in source order.
    %
    %@helper
:- func rhs_actions(ast_rule) = list(ast_action).

rhs_actions(Rule) =
    with_continuations(Rule ^ ar_rhs ^ arr_actions
        ++ list.condense(list.map(after_actions, Rule ^ ar_rhs ^ arr_afters))).

    %@helper
:- func after_actions(ast_after_clause) = list(ast_action).

after_actions(After) =
    After ^ aaf_actions
        ++ list.condense(list.map(after_actions, After ^ aaf_nested)).

    %@helper
:- func with_continuations(list(ast_action)) = list(ast_action).

with_continuations(Actions) =
    list.condense(list.map(action_and_bodies, Actions)).

    %@helper
:- func action_and_bodies(ast_action) = list(ast_action).

action_and_bodies(Action) = [Action | Nested] :-
    ( if Action ^ aac_block = aab_call(_, Continuations) then
        Nested = with_continuations(
            list.condense(list.map(continuation_actions, Continuations)))
    else
        Nested = []
    ).

    %@helper
:- func continuation_actions(ast_continuation) = list(ast_action).

continuation_actions(acont_on(_, Actions, _)) = Actions.
continuation_actions(acont_timeout(_, Actions, _)) = Actions.
continuation_actions(acont_error(_, Actions, _)) = Actions.

    % A qualified `emit` makes no edge in the file's graph, as a qualified head
    % makes none.
    %
    %@helper
:- func file_emission(emitted) = emission is semidet.

file_emission(emitted(atr_bare(Id), Args)) = emission(Id ^ id_name, Args).

    %@helper
:- func action_emission(ast_action) = emitted is semidet.

action_emission(Action) = emitted(Ref, Args) :-
    Action ^ aac_head = aah_emit(Ref),
    Block = Action ^ aac_block,
    (
        Block = aab_kwargs(BlockArgs),
        Args = Action ^ aac_args ++ BlockArgs
    ;
        ( Block = aab_none
        ; Block = aab_call(_, _)
        ),
        Args = Action ^ aac_args
    ).

%-----------------------------------------------------------------------------%
% The admission -- [LCYC.3.1.1]
%-----------------------------------------------------------------------------%
%
% The SCCs are those of the graph after the literal break, but the first
% condition is over schemas: an `emit` whose edge was dropped still emits its
% schema. Of the second condition only the cache needs code: `then`, `latest`
% and a `call`'s outcomes are matches and emissions the first condition reads.

    % name -> the SCC containing it, for every rule in an SCC this clause does
    % not admit.
    %
    %@helper
:- func refused_sccs(list(rule_node), map(string, list(edge)), list(string))
    = map(string, set(string)).

refused_sccs(Nodes, Adjacency, Names) = Refused :-
    Reach = list.foldl(add_reach(Adjacency), Names, map.init),
    Refused = list.foldl(add_refused(Nodes, Reach), Names, map.init).

    % Every rule reachable from `Name` by one edge or more. `Name` is in it
    % exactly when `Name` is on a cycle.
    %
    %@helper
:- func add_reach(map(string, list(edge)), string, map(string, set(string)))
    = map(string, set(string)).

add_reach(Adjacency, Name, Reach0) = Reach :-
    Set = reachable(Adjacency, successors(Adjacency, Name), set.init),
    map.set(Name, Set, Reach0, Reach).

    %@helper
:- func reachable(map(string, list(edge)), list(string), set(string))
    = set(string).

reachable(_, [], Seen) = Seen.
reachable(Adjacency, [Name | Names], Seen) =
    ( if set.contains(Seen, Name) then
        reachable(Adjacency, Names, Seen)
    else
        reachable(Adjacency, successors(Adjacency, Name) ++ Names,
            set.insert(Seen, Name))
    ).

    %@helper
:- func successors(map(string, list(edge)), string) = list(string).

successors(Adjacency, Name) =
    ( if map.search(Adjacency, Name, Edges) then
        list.map(edge_target, Edges)
    else
        []
    ).

    %@helper
:- func edge_target(edge) = string.

edge_target(Edge) = Edge ^ ed_to.

    %@helper
:- func add_refused(list(rule_node), map(string, set(string)), string,
                    map(string, set(string))) = map(string, set(string)).

add_refused(Nodes, Reach, Name, Refused0) = Refused :-
    ( if
        map.search(Reach, Name, Mine),
        set.contains(Mine, Name),
        Scc = set.filter(reaches(Reach, Name), Mine),
        not lcyc_3_1_1_admitted(Nodes, Scc)
    then
        map.set(Name, Scc, Refused0, Refused)
    else
        Refused = Refused0
    ).

    %@helper
:- pred reaches(map(string, set(string))::in, string::in, string::in)
    is semidet.

reaches(Reach, Target, From) :-
    map.search(Reach, From, Set),
    set.contains(Set, Target).

    %@spec [LCYC.3.1.1]
:- pred lcyc_3_1_1_admitted(list(rule_node)::in, set(string)::in) is semidet.

lcyc_3_1_1_admitted(Nodes, Scc) :-
    InScc = list.filter(named_in(Scc), Nodes),
    Emitted = set.list_to_set(list.condense(list.map(emitted_schemas, InScc))),
    Matched = set.list_to_set(list.condense(list.map(matched_schemas, InScc))),
    set.is_empty(set.intersect(Emitted, Matched)),
    not lcyc_3_1_1_consumes_cache(InScc).

    % Decides whether an SCC is admitted; it adds no edge.
    %
    %@spec [LCYC.3.1.1]
:- pred lcyc_3_1_1_consumes_cache(list(rule_node)::in) is semidet.

lcyc_3_1_1_consumes_cache(InScc) :-
    Writes = list.condense(list.map(rule_cache_writes, InScc)),
    Reads = list.condense(list.map(rule_cache_reads, InScc)),
    list.member(Write, Writes),
    list.member(Read, Reads),
    same_cache_key(Write, Read).

    %@helper
:- func rule_cache_writes(rule_node) = list(cache_key).

rule_cache_writes(Node) = Node ^ rn_cache_writes.

    %@helper
:- func rule_cache_reads(rule_node) = list(cache_key).

rule_cache_reads(Node) = Node ^ rn_cache_reads.

    %@helper
:- pred same_cache_key(cache_key::in, cache_key::in) is semidet.

same_cache_key(A, B) :-
    ( A = ck_any
    ; B = ck_any
    ; A = ck_literal(K), B = ck_literal(K)
    ).

    %@helper
:- pred named_in(set(string)::in, rule_node::in) is semidet.

named_in(Scc, Node) :-
    set.contains(Scc, node_name(Node)).

    %@helper
:- func emitted_schemas(rule_node) = list(string).

emitted_schemas(Node) = list.map(emission_schema, Node ^ rn_emits).

    %@helper
:- func emission_schema(emission) = string.

emission_schema(Emission) = Emission ^ em_schema.

    %@helper
:- func matched_schemas(rule_node) = list(string).

matched_schemas(Node) = list.map(match_schema, Node ^ rn_matches).

    %@helper
:- func match_schema(match) = string.

match_schema(Match) = Match ^ mt_schema.

    %@helper
:- pred internal_to(map(string, set(string))::in, edge::in) is semidet.

internal_to(Refused, Edge) :-
    map.search(Refused, Edge ^ ed_from, Scc),
    set.contains(Scc, Edge ^ ed_to).

%-----------------------------------------------------------------------------%
% Finding a cycle
%-----------------------------------------------------------------------------%

    %@helper
:- func adjacency(list(edge)) = map(string, list(edge)).

adjacency(Edges) = list.foldl(add_edge, Edges, map.init).

    %@helper
:- func add_edge(edge, map(string, list(edge))) = map(string, list(edge)).

add_edge(Edge, Map0) = Map :-
    From = Edge ^ ed_from,
    ( if map.search(Map0, From, Existing) then
        map.det_update(From, Existing ++ [Edge], Map0, Map)
    else
        map.det_insert(From, [Edge], Map0, Map)
    ).

    % One search per rule, in source order: the cycle reported is the one
    % through the earliest rule.
    %
    %@helper
:- pred find_cycle(map(string, list(edge))::in, list(string)::in,
                   list(edge)::out) is semidet.

find_cycle(Adjacency, [Name | Names], Cycle) :-
    ( if path_back(Adjacency, Name, Name, [], set.init, Found) then
        Cycle = Found
    else
        find_cycle(Adjacency, Names, Cycle)
    ).

    % A non-empty path from `Current` back to `Target`, as the edges taken.
    %
    %@helper
:- pred path_back(map(string, list(edge))::in, string::in, string::in,
                  list(edge)::in, set(string)::in, list(edge)::out) is semidet.

path_back(Adjacency, Target, Current, Acc, Seen, Cycle) :-
    map.search(Adjacency, Current, Edges),
    try_edges(Adjacency, Target, Edges, Acc, Seen, Cycle).

    %@helper
:- pred try_edges(map(string, list(edge))::in, string::in, list(edge)::in,
                  list(edge)::in, set(string)::in, list(edge)::out) is semidet.

try_edges(Adjacency, Target, [Edge | Edges], Acc, Seen, Cycle) :-
    To = Edge ^ ed_to,
    ( if To = Target then
        Cycle = list.reverse([Edge | Acc])
    else if not set.contains(Seen, To) then
        ( if
            path_back(Adjacency, Target, To, [Edge | Acc],
                set.insert(Seen, To), Found)
        then
            Cycle = Found
        else
            try_edges(Adjacency, Target, Edges, Acc, Seen, Cycle)
        )
    else
        try_edges(Adjacency, Target, Edges, Acc, Seen, Cycle)
    ).

%-----------------------------------------------------------------------------%
% The diagnostic
%-----------------------------------------------------------------------------%

    %@spec [LCYC.3.3.2]
    %@spec [LCYC.3.4.1]
    %@spec [LCYC.3.4.2]
:- func lcyc_3_3_2_cycle_diagnostic(list(rule_node), list(edge)) = diagnostic.

lcyc_3_3_2_cycle_diagnostic(Nodes, Cycle) = Diagnostic :-
    Pos = cycle_pos(Nodes, Cycle),
    ( if list.any_true(is_defeat, Cycle) then
        Diagnostic = with_hint(error_at(dv_rule_defeat, Pos,
            "rules " ++ rule_list(Cycle) ++ " defeat each other: "
                ++ defeat_story(Cycle)
                ++ " -- each rule's firing makes the other's condition "
                ++ "impossible, and the engine's behaviour here is not "
                ++ "defined ([LCYC.3.4.1])"),
            "one of the two has to stop depending on the other's absence")
    else
        Diagnostic = with_hint(error_at(dv_rule_cycle, Pos,
            "cycle in rule graph: " ++ cycle_story(Cycle)
                ++ " ([LCYC.3.1])"),
            "the emitted facts feed back round to the rule that started "
                ++ "them; restructure so the chain ends")
    ).

    %@helper
:- pred is_defeat(edge::in) is semidet.

is_defeat(Edge) :-
    Edge ^ ed_defeat = yes.

    %@helper
:- func cycle_pos(list(rule_node), list(edge)) = pos.

cycle_pos(Nodes, Cycle) = Pos :-
    ( if
        Cycle = [First | _],
        find_node(Nodes, First ^ ed_from, Node)
    then
        Pos = Node ^ rn_name ^ id_pos
    else
        % Unreachable: every edge was built from a node in this list.
        Pos = pos(1, 0)
    ).

    %@helper
:- pred find_node(list(rule_node)::in, string::in, rule_node::out) is semidet.

find_node([Node | Nodes], Name, Found) :-
    ( if node_name(Node) = Name then
        Found = Node
    else
        find_node(Nodes, Name, Found)
    ).

    % `a (emits Y) -> b (emits Z) -> c (emits X) -> a`
    %
    %@helper
:- func cycle_story(list(edge)) = string.

cycle_story([]) = "".
cycle_story([Edge | Edges]) =
    "`" ++ Edge ^ ed_from ++ "` (" ++ verb(Edge ^ ed_kind) ++ " "
        ++ Edge ^ ed_schema ++ ") -> "
        ++ ( if Edges = [] then "`" ++ Edge ^ ed_to ++ "`"
             else cycle_story(Edges) ).

    %@helper
:- func verb(edge_kind) = string.

verb(ek_emit) = "emits".
verb(ek_withdraw) = "withdraws".

    %@helper
:- func defeat_story(list(edge)) = string.

defeat_story([]) = "".
defeat_story([Edge | Edges]) = Story :-
    (
        Edge ^ ed_defeat = yes,
        This = "`" ++ Edge ^ ed_to ++ "` requires `no " ++ Edge ^ ed_schema
            ++ "` to fire and `" ++ Edge ^ ed_from ++ "` emits it"
    ;
        Edge ^ ed_defeat = no,
        This = "`" ++ Edge ^ ed_from ++ "` " ++ verb(Edge ^ ed_kind) ++ " "
            ++ Edge ^ ed_schema ++ " for `" ++ Edge ^ ed_to ++ "`"
    ),
    ( if Edges = [] then
        Story = This
    else
        Story = This ++ "; " ++ defeat_story(Edges)
    ).

    %@helper
:- func rule_list(list(edge)) = string.

rule_list(Cycle) =
    string.join_list(" and ",
        list.map(quoted, list.sort_and_remove_dups(
            list.map(func(E) = E ^ ed_from, Cycle)))).

    %@helper
:- func quoted(string) = string.

quoted(S) = "`" ++ S ++ "`".

%-----------------------------------------------------------------------------%
:- end_module dsc.cycle.
%-----------------------------------------------------------------------------%

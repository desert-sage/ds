% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.network -- the Rete network: alpha filters, beta joins, terminals.
%
% A resolved node holds the nodes it references, not ids, so a `node_id` naming
% no node is unrepresentable. Mercury terms are shared, so the DAG stays one in
% memory. A `left_parent_id` cycle cannot be built, so `resolve_network` refuses
% it: a pass making no progress with nodes left over is the cycle.
%-----------------------------------------------------------------------------%

:- module ds.network.
:- interface.

:- import_module ds.dsc_action.
:- import_module ds.expr.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.schema.
:- import_module ds.value.
:- import_module bool.
:- import_module list.
:- import_module maybe.
:- import_module set.

%-----------------------------------------------------------------------------%
% Alpha nodes
%-----------------------------------------------------------------------------%

    % `AlphaLiteral`: no null arm.
    %
:- type alpha_literal
    --->    al_int(int64)
    ;       al_float(float)
    ;       al_string(intern_ref)
    ;       al_bool(bool).

:- func alpha_literal_value(alpha_literal) = ds_value.

:- type alpha_test
    --->    at_eq(slot_index, alpha_literal)
    ;       at_cmp(slot_index, binop, alpha_literal)
            % Only the six comparisons appear.
    ;       at_regex(slot_index, string).
            % RE2's syntax ([LREG.8.1]), with flags folded in as `(?f:p)`
            % (RLOW.5.2.2). Held as the source pattern.

    % Admits a fact passing all its tests [RDSC.4a.6].
    %
:- type alpha_node
    --->    alpha_node(
                an_id     :: node_id,
                an_schema :: schema_name,
                an_tests  :: list(alpha_test)
            ).

%-----------------------------------------------------------------------------%
% Beta nodes
%-----------------------------------------------------------------------------%

:- type beta_node
    --->    beta_node(
                bn_id       :: node_id,

                bn_right    :: alpha_node,

                bn_parent   :: maybe(beta_node),
                            % `no` is a root beta [RDSC.4a.7].

                bn_tests    :: list(expr),
                            % Over (left_token, right_candidate_fact). Empty is
                            % unconditional.

                bn_negative :: bool
            ).

    % The root betas, in encounter order.
    %
:- func root_betas(network) = list(beta_node).

%-----------------------------------------------------------------------------%
% Terminal nodes
%-----------------------------------------------------------------------------%

:- type terminal_node
    --->    terminal_node(
                tn_id       :: node_id,
                tn_parent   :: beta_node,
                tn_rule     :: intern_ref,

                tn_binds    :: int,
                            % `bind_count`: the valid range of `bind_ref`.

                tn_guard    :: maybe(expr),
                            % `fire_guard`, evaluated once before the actions.

                tn_inline   :: int,
                            % how many `TerminalNode.actions` were on the wire

                tn_inline_actions :: list(inline_action)
                            % decoded, in wire order, which is execution order
            ).

%-----------------------------------------------------------------------------%
% The network
%-----------------------------------------------------------------------------%

:- type network.

:- func empty_network = network.

:- func alpha_nodes(network) = list(alpha_node).
:- func beta_nodes(network) = list(beta_node).
:- func terminal_nodes(network) = list(terminal_node).

%-----------------------------------------------------------------------------%
% Resolution
%-----------------------------------------------------------------------------%

    % The wire forms, with cross-references still bare `uint32`s, accumulated and
    % resolved in one sweep at the end [RDSC.8.3].
    %
:- type raw_alpha
    --->    raw_alpha(node_id, schema_name, list(alpha_test)).

:- type raw_beta
    --->    raw_beta(node_id, uint32, uint32, list(expr), bool).
            % id, right_alpha_id, left_parent_id (0 = root), tests, is_negative

:- type raw_terminal
    --->    raw_terminal(node_id, uint32, intern_ref, int,
                         maybe(expr), int, list(inline_action)).
            % id, parent_beta_id, rule_name, bind_count, fire_guard,
            % inline_action_count, inline_actions

:- type network_result
    --->    network_ok(network)
    ;       network_error(load_error_kind, string).

    % Takes the raw nodes in encounter order and returns them in it.
    %
:- pred resolve_network(list(raw_alpha)::in, list(raw_beta)::in,
                        list(raw_terminal)::in, network_result::out) is det.

%-----------------------------------------------------------------------------%
% Fault-fact sites
%-----------------------------------------------------------------------------%

    % [LERR.9.6]: a terminal is a fault handler's when some alpha on its chain is
    % over a fault schema, and then it and every node on the chain are sites. The
    % engine suppresses their fault facts, and the compiler leaves them out of the
    % site count below.
    %
    %@spec [LERR.9.6]
:- func lerr_9_6_handler_sites(network, intern_table) = set(uint32).

    % [LERR.9.10], RDSC.3.10: the fault-fact site count, one per node that can raise
    % a `ComputationError` plus one per node that can raise a `TypeError`, handlers'
    % sites excluded. Alpha nodes are never sites: every fault an alpha test raises is
    % an EngineError ([LERR.9.1]).
    %
    % An over-count on purpose: the pool has no refusal path, so only an under-count
    % is a defect. "Can be raised" is read off the operations (`expr_may_raise`),
    % conservatively for every builtin call.
    %
    %@spec [LERR.9.10]
:- func lerr_9_10_fault_fact_sites(network, intern_table) = int.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.action.

:- import_module int.
:- import_module map.
:- import_module pair.
:- import_module uint32.

%-----------------------------------------------------------------------------%

:- type network
    --->    network(
                nw_alphas    :: list(alpha_node),
                nw_betas     :: list(beta_node),
                nw_terminals :: list(terminal_node)
            ).

empty_network = network([], [], []).

alpha_nodes(N) = N ^ nw_alphas.
beta_nodes(N) = N ^ nw_betas.
terminal_nodes(N) = N ^ nw_terminals.

root_betas(N) = list.filter(is_root, N ^ nw_betas).

:- pred is_root(beta_node::in) is semidet.

is_root(B) :-
    B ^ bn_parent = no.

alpha_literal_value(al_int(I)) = int(I).
alpha_literal_value(al_float(F)) = float(F).
alpha_literal_value(al_string(R)) = str(R).
alpha_literal_value(al_bool(B)) = bool(B).

%-----------------------------------------------------------------------------%
% Resolution
%-----------------------------------------------------------------------------%

resolve_network(RawAlphas, RawBetas, RawTerms, Result) :-
    % Node ids are bundle-global across the three atom types [RDSC.4a.3].
    Ids = list.map(raw_alpha_id, RawAlphas) ++
          list.map(raw_beta_id, RawBetas) ++
          list.map(raw_term_id, RawTerms),
    ( if has_duplicate(Ids) then
        Result = network_error(lek_retp_invalid, "RDSC.4a.3")
    else
        AlphaMap = list.foldl(add_alpha, RawAlphas, map.init),
        resolve_betas(RawBetas, AlphaMap, Result0),
        (
            Result0 = rb_error(Kind, Clause),
            Result = network_error(Kind, Clause)
        ;
            Result0 = rb_ok(Betas, BetaMap),
            resolve_terminals(RawTerms, BetaMap, [], TermResult),
            (
                TermResult = rt_error(Kind, Clause),
                Result = network_error(Kind, Clause)
            ;
                TermResult = rt_ok(Terms),
                Alphas = list.map(build_alpha, RawAlphas),
                Result = network_ok(network(Alphas, Betas, Terms))
            )
        )
    ).

:- func raw_alpha_id(raw_alpha) = node_id.
:- func raw_beta_id(raw_beta) = node_id.
:- func raw_term_id(raw_terminal) = node_id.

raw_alpha_id(raw_alpha(Id, _, _)) = Id.
raw_beta_id(raw_beta(Id, _, _, _, _)) = Id.
raw_term_id(raw_terminal(Id, _, _, _, _, _, _)) = Id.

:- pred has_duplicate(list(node_id)::in) is semidet.

has_duplicate(Ids) :-
    list.length(Ids, Emitted),
    Distinct = set.count(set.list_to_set(Ids)) : int,
    Distinct < Emitted.

:- func build_alpha(raw_alpha) = alpha_node.

build_alpha(raw_alpha(Id, Schema, Tests)) = alpha_node(Id, Schema, Tests).

:- func add_alpha(raw_alpha, map(uint32, alpha_node)) =
    map(uint32, alpha_node).

add_alpha(Raw, M) =
    map.set(M, node_id_value(raw_alpha_id(Raw)), build_alpha(Raw)).

%-----------------------------------------------------------------------------%

:- type beta_result
    --->    rb_ok(list(beta_node), map(uint32, beta_node))
    ;       rb_error(load_error_kind, string).

    % Repeated passes: a recursive walk would not end on a cycle. Each pass resolves
    % every beta whose parent is resolved.
    %
:- pred resolve_betas(list(raw_beta)::in, map(uint32, alpha_node)::in,
                      beta_result::out) is det.

resolve_betas(Raws, AlphaMap, Result) :-
    % A `node_id` naming no node is `DS_ERR_RETP_INDEX_OOB` [RDSC.11.1].
    ( if list.find_first_match(bad_alpha_ref(AlphaMap), Raws, _) then
        Result = rb_error(lek_retp_index_oob, "RDSC.11.1")
    else
        BetaIds = set.list_to_set(list.map(raw_beta_id, Raws)),
        ( if list.find_first_match(bad_parent_ref(BetaIds), Raws, _) then
            Result = rb_error(lek_retp_index_oob, "RDSC.11.1")
        else
            beta_passes(Raws, AlphaMap, map.init, Passes),
            (
                Passes = bp_cycle,
                Result = rb_error(lek_semantic, "RDSC.4a.5")
            ;
                Passes = bp_ok(Final),
                % Encounter order, restored: the passes resolve parents first.
                ( if reorder(Raws, Final, Ordered) then
                    Result = rb_ok(Ordered, Final)
                else
                    % Unreachable: the loop ends with every raw beta in the map.
                    Result = rb_error(lek_retp_index_oob, "RDSC.11.1")
                )
            )
        )
    ).

:- pred reorder(list(raw_beta)::in, map(uint32, beta_node)::in,
                list(beta_node)::out) is semidet.

reorder([], _, []).
reorder([Raw | Raws], Final, [Node | Nodes]) :-
    map.search(Final, node_id_value(raw_beta_id(Raw)), Node),
    reorder(Raws, Final, Nodes).

:- pred bad_alpha_ref(map(uint32, alpha_node)::in, raw_beta::in) is semidet.

bad_alpha_ref(AlphaMap, raw_beta(_, RightId, _, _, _)) :-
    not map.contains(AlphaMap, RightId).

:- pred bad_parent_ref(set(node_id)::in, raw_beta::in) is semidet.

bad_parent_ref(BetaIds, raw_beta(_, _, ParentId, _, _)) :-
    ParentId \= 0u32,
    node_id(ParentId, Parent),
    not set.contains(BetaIds, Parent).

:- type beta_pass_result
    --->    bp_ok(map(uint32, beta_node))
    ;       bp_cycle.

:- pred beta_passes(list(raw_beta)::in, map(uint32, alpha_node)::in,
                    map(uint32, beta_node)::in, beta_pass_result::out) is det.

beta_passes([], _, Done, bp_ok(Done)).
beta_passes(Pending @ [_ | _], AlphaMap, Done0, Result) :-
    beta_pass(Pending, AlphaMap, Done0, Done1, 0, Built, [], Stuck),
    ( if Built = 0 then
        Result = bp_cycle
    else
        beta_passes(list.reverse(Stuck), AlphaMap, Done1, Result)
    ).

:- pred beta_pass(list(raw_beta)::in, map(uint32, alpha_node)::in,
                  map(uint32, beta_node)::in, map(uint32, beta_node)::out,
                  int::in, int::out,
                  list(raw_beta)::in, list(raw_beta)::out) is det.

beta_pass([], _, !Done, !Built, !Stuck).
beta_pass([Raw | Raws], AlphaMap, !Done, !Built, !Stuck) :-
    Raw = raw_beta(Id, RightId, ParentId, Tests, Negative),
    ( if
        map.search(AlphaMap, RightId, Alpha),
        resolve_parent(ParentId, !.Done, Parent)
    then
        Node = beta_node(Id, Alpha, Parent, Tests, Negative),
        map.set(node_id_value(Id), Node, !Done),
        !:Built = !.Built + 1
    else
        !:Stuck = [Raw | !.Stuck]
    ),
    beta_pass(Raws, AlphaMap, !Done, !Built, !Stuck).

    % Failure means "not yet": dangling parents are excluded before the passes.
    %
:- pred resolve_parent(uint32::in, map(uint32, beta_node)::in,
                       maybe(beta_node)::out) is semidet.

resolve_parent(ParentId, Done, Parent) :-
    ( if ParentId = 0u32 then
        Parent = no
    else
        map.search(Done, ParentId, P),
        Parent = yes(P)
    ).

%-----------------------------------------------------------------------------%

:- type terminal_result
    --->    rt_ok(list(terminal_node))
    ;       rt_error(load_error_kind, string).

:- pred resolve_terminals(list(raw_terminal)::in, map(uint32, beta_node)::in,
                          list(terminal_node)::in, terminal_result::out) is det.

resolve_terminals([], _, Acc, rt_ok(list.reverse(Acc))).
resolve_terminals([Raw | Raws], BetaMap, Acc, Result) :-
    Raw = raw_terminal(Id, ParentId, Rule, Binds, Guard, Inline,
        InlineActions),
    ( if map.search(BetaMap, ParentId, Parent) then
        Node = terminal_node(Id, Parent, Rule, Binds, Guard, Inline,
            InlineActions),
        resolve_terminals(Raws, BetaMap, [Node | Acc], Result)
    else
        % Includes `parent_beta_id = 0`.
        Result = rt_error(lek_retp_index_oob, "RDSC.11.1")
    ).

%-----------------------------------------------------------------------------%
% Fault-fact sites
%-----------------------------------------------------------------------------%

lerr_9_6_handler_sites(Net, IT) = list.foldl(
    ( func(T, Acc) =
        ( if chain_on_fault_schema(IT, yes(T ^ tn_parent)) then
            set.union(Acc, set.insert(chain_nodes(yes(T ^ tn_parent)),
                node_id_value(T ^ tn_id)))
        else
            Acc
        )
    ), terminal_nodes(Net), set.init).

:- pred chain_on_fault_schema(intern_table::in, maybe(beta_node)::in)
    is semidet.

chain_on_fault_schema(IT, yes(B)) :-
    ( if
        expand(IT, schema_name_ref(B ^ bn_right ^ an_schema), Name),
        lerr_9_4_fault_schema_name(Name)
    then
        true
    else
        chain_on_fault_schema(IT, B ^ bn_parent)
    ).

:- func chain_nodes(maybe(beta_node)) = set(uint32).

chain_nodes(no) = set.init.
chain_nodes(yes(B)) =
    set.insert_list(chain_nodes(B ^ bn_parent),
        [node_id_value(B ^ bn_id), node_id_value(B ^ bn_right ^ an_id)]).

lerr_9_10_fault_fact_sites(Net, IT) = BetaSites + TermSites :-
    Handlers = lerr_9_6_handler_sites(Net, IT),
    BetaSites = list.foldl(
        ( func(B, N) =
            ( if set.member(node_id_value(B ^ bn_id), Handlers) then
                N
            else
                N + site_count(exprs_may_raise(B ^ bn_tests))
            )
        ), beta_nodes(Net), 0),
    TermSites = list.foldl(
        ( func(T, N) =
            ( if set.member(node_id_value(T ^ tn_id), Handlers) then
                N
            else
                N + site_count(terminal_may_raise(T))
            )
        ), terminal_nodes(Net), 0).

:- type may_raise
    --->    may_raise(
                mr_computation :: bool,
                mr_type        :: bool
            ).

:- func no_raise = may_raise.
:- func raises_type = may_raise.
:- func raises_both = may_raise.

no_raise = may_raise(no, no).
raises_type = may_raise(no, yes).
raises_both = may_raise(yes, yes).

:- func either_raise(may_raise, may_raise) = may_raise.

either_raise(may_raise(C1, T1), may_raise(C2, T2)) =
    may_raise(bool.or(C1, C2), bool.or(T1, T2)).

    % One site per schema the node can raise: each latches on its own `(node, rule)`
    % ([LERR.9.5]).
    %
:- func site_count(may_raise) = int.

site_count(may_raise(C, T)) = count_yes(C) + count_yes(T).

:- func count_yes(bool) = int.

count_yes(yes) = 1.
count_yes(no) = 0.

:- func exprs_may_raise(list(expr)) = may_raise.

exprs_may_raise(Es) =
    list.foldl(( func(E, Acc) = either_raise(Acc, expr_may_raise(E)) ),
        Es, no_raise).

    % TypeError is any operation over a value ([IRET.9.6]); a leaf operates on
    % nothing. ComputationError is the TrapKinds: `/`, `//`, `%`, the shifts, and
    % calls. `+ - *` and unary minus cannot trap ([LEXP.7.13.1], [LEXP.4.2]). Every
    % call, Json path, interpolation and aggregation counts as raising both. `is`
    % is total ([LNUL.4.9]) and `??` adds nothing of its own.
    %
:- func expr_may_raise(expr) = may_raise.

expr_may_raise(e_lit(_)) = no_raise.
expr_may_raise(e_slot(_, _)) = no_raise.
expr_may_raise(e_slot_named(_, _)) = raises_type.
expr_may_raise(e_json_path(_, _)) = raises_both.
expr_may_raise(e_json_path_expr(_, _)) = raises_both.
expr_may_raise(e_binop(Op, A, B)) =
    either_raise(binop_may_raise(Op), exprs_may_raise([A, B])).
expr_may_raise(e_unop(_, A)) = either_raise(raises_type, expr_may_raise(A)).
expr_may_raise(e_interp(_)) = raises_both.
expr_may_raise(e_agg(_)) = raises_both.
expr_may_raise(e_call(_, _)) = raises_both.
expr_may_raise(e_now) = no_raise.
expr_may_raise(e_entry_stamp(_)) = no_raise.
expr_may_raise(e_if(C, T, E)) =
    either_raise(raises_type, exprs_may_raise([C, T, E])).
expr_may_raise(e_coalesce(A, B)) = exprs_may_raise([A, B]).
expr_may_raise(e_bind(_, E)) = expr_may_raise(E).
expr_may_raise(e_bind_ref(_)) = no_raise.
expr_may_raise(e_tainted(E)) = expr_may_raise(E).
expr_may_raise(e_is_test(E, _, _)) = expr_may_raise(E).

:- func binop_may_raise(binop) = may_raise.

binop_may_raise(op_add) = raises_type.
binop_may_raise(op_sub) = raises_type.
binop_may_raise(op_mul) = raises_type.
binop_may_raise(op_div) = raises_both.
binop_may_raise(op_floordiv) = raises_both.
binop_may_raise(op_rem) = raises_both.
binop_may_raise(op_eq) = raises_type.
binop_may_raise(op_ne) = raises_type.
binop_may_raise(op_lt) = raises_type.
binop_may_raise(op_le) = raises_type.
binop_may_raise(op_gt) = raises_type.
binop_may_raise(op_ge) = raises_type.
binop_may_raise(op_and) = raises_type.
binop_may_raise(op_or) = raises_type.
binop_may_raise(op_bit_and) = raises_type.
binop_may_raise(op_bit_or) = raises_type.
binop_may_raise(op_bit_xor) = raises_type.
binop_may_raise(op_shl) = raises_both.
binop_may_raise(op_shr) = raises_both.

:- func terminal_may_raise(terminal_node) = may_raise.

terminal_may_raise(T) =
    list.foldl(( func(A, Acc) = either_raise(Acc, action_may_raise(A)) ),
        T ^ tn_inline_actions, exprs_may_raise(maybe_exprs(T ^ tn_guard))).

:- func maybe_exprs(maybe(expr)) = list(expr).

maybe_exprs(no) = [].
maybe_exprs(yes(E)) = [E].

    % An assert is itself a site, not only its values ([RARC.5.2.7]), so an `emit` or
    % a `publish` counts as raising both.
    %
:- func action_may_raise(inline_action) = may_raise.

action_may_raise(ia_assert(_, _, Slots, Retain)) =
    either_raise(raises_both,
        exprs_may_raise(list.map(( func(S) = S ^ sa_value ), Slots)
            ++ maybe_exprs(Retain))).
action_may_raise(ia_publish(_, Args, _)) =
    either_raise(raises_both, exprs_may_raise(Args)).
    % A `publish`'s `ttl_override` is not evaluated ([LTIE.4.3]; see
    % `ds.action.a_publish`), so it raises nothing.
action_may_raise(ia_call(_, Corr, Kwargs, Gate)) =
    exprs_may_raise(gate_exprs(Gate) ++ [Corr | kwarg_exprs(Kwargs)]).
action_may_raise(ia_cache_set(Key, Value, Ttl)) =
    exprs_may_raise([Key, Value | maybe_exprs(Ttl)]).
action_may_raise(ia_cache_delete(Key)) = expr_may_raise(Key).
action_may_raise(ia_log(_, Message)) = expr_may_raise(Message).
action_may_raise(ia_bind(_, E)) = expr_may_raise(E).
action_may_raise(ia_hydration_call(_, Corr, _, Body, Gate)) =
    exprs_may_raise(gate_exprs(Gate) ++ [Corr | kwarg_exprs(Body)]).
action_may_raise(ia_internal(_, _)) = raises_both.
    % Its operands are evaluated before ARTEFACT_LIED is raised.
action_may_raise(ia_operands_not_admitted(_, Args, Gate)) =
    exprs_may_raise(gate_exprs(Gate) ++ Args).
action_may_raise(ia_withdraw(_)) = no_raise.
action_may_raise(ia_withdraw_by_id(Fact)) = expr_may_raise(Fact).

:- func kwarg_exprs(kwargs) = list(expr).

kwarg_exprs(Kwargs) = list.map(( func(_ - E) = E ), kwarg_list(Kwargs)).

    % The per-call cooldown's `FN_RATE_ALLOW` arguments ([IRET.25.5.1]).
    %
:- func gate_exprs(maybe(list(expr))) = list(expr).

gate_exprs(no) = [].
gate_exprs(yes(Args)) = Args.

%-----------------------------------------------------------------------------%

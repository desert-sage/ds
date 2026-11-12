% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.match -- alpha dispatch, beta joins, NOT nodes.
%
% Incremental, since the timetag counter is observable: recomputing the match
% set from working memory would consume it differently.
%
%   right activate    a fact enters an alpha  -> positive betas may mint tokens,
%                                                negative betas may block them
%   right deactivate  a fact leaves an alpha  -> positive betas lose tokens,
%                                                negative betas may unblock
%   left activate     a token arrives         -> join against the right memory
%   left deactivate   a token withdraws       -> its descendants withdraw
%
% A positive join admits only on `true`. A negated join is unblocked only by a
% definite `false` [LNUL.4.7]: `true`, `null` and a fault all keep the block.
%-----------------------------------------------------------------------------%

:- module ds.match.
:- interface.

:- import_module bool.
:- import_module ds.cache.
:- import_module ds.chrono.
:- import_module ds.eval.
:- import_module ds.fact.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.network.
:- import_module ds.schema.
:- import_module ds.series.
:- import_module ds.token.
:- import_module ds.wm.
:- import_module list.
:- import_module maybe.
:- import_module map.
:- import_module pair.

%-----------------------------------------------------------------------------%
% The network index
%-----------------------------------------------------------------------------%

    % The network inverted for propagation, built once at load: the resolved
    % network points from a node to its inputs.
    %
:- type net_index.

:- func build_index(network, list(schema)) = net_index.

%-----------------------------------------------------------------------------%
% The match state
%-----------------------------------------------------------------------------%

:- type rete_state.

:- func init_rete = rete_state.

:- type match_ctx
    --->    match_ctx(
                mc_wm      :: wm,
                mc_schemas :: map(uint32, schema),
                mc_interns :: intern_table,
                mc_now     :: instant,
                            % the monotonic clock's held sample ([LTIM.2.8.2])
                mc_wall    :: maybe(int64),
                            % the wall clock's held sample ([LTIM.2.8.3])
                mc_cache   :: cache,
                            % `cached(key)` is legal in a `where` [LSTO.4.3.1b]
                mc_series  :: series_state
            ).

    % What changed, in both directions: a NOT node turns an assert into a
    % retracted activation and a retract into a new one. Also the faults raised
    % on the way, in propagation order, and the expired cache keys the tests read,
    % in the order first read, each once ([NSTG.2.4.2]).
    %
:- type match_delta
    --->    match_delta(
                md_added   :: list(activation),
                md_removed :: list(activation),
                md_faults  :: list(match_fault),
                md_expired :: list(string)
            ).

    % A matching-time fault and the node whose test raised it, which is its
    % identity: no activation exists yet ([RDSC.14.3], [LERR.9.11]).
    %
:- type match_fault
    --->    match_fault(
                mf_node      :: node_id,
                mf_site      :: match_site,
                mf_fault     :: runtime_fault,
                mf_origin    :: fault_origin,
                            % the fact, slot and value it was raised over
                mf_token     :: list(fact_id),
                mf_candidate :: fact_id
                            % The pair it was raised for ([LERR.1.4.12]). An
                            % alpha test's has no token, and the candidate is
                            % the fact it tested.
            ).

:- type match_site
    --->    ms_alpha
    ;       ms_beta.

    % [LERR.1.4.12]: of the faults one event's join tests raised, the ones that
    % reach the stream, in order. EngineErrors first, as raised, since they halt the
    % tier. A TypeError or ComputationError records for each pair the event derived,
    % live in `S`, the state after it, and once per pair. They are ordered by the
    % terminal ordinal of the rule the node belongs to (`OrdinalOf`; the least below
    % the node), then the pair's facts as [LDET.5.5] ranks a match, then the node's
    % depth, the shallower first.
    %
:- func lerr_1_4_12_derived(net_index, rete_state, (func(node_id) = maybe(K)),
                            list(match_fault)) = list(match_fault).

:- func no_delta = match_delta.

    % A fact entered working memory.
    %
:- pred fact_asserted(net_index::in, match_ctx::in, fact_id::in,
                      match_delta::out, rete_state::in, rete_state::out) is det.

    % Seed every negative root beta with the nil token, once, before the first
    % pump ([RDSC.4a.7], [IRET.7.9.1]): for a NOT node this is the event that fires
    % `no Noise` on an empty engine. At pump entry, so a fact asserted earlier is
    % already in its alpha memory. A positive root's nil token is `left_input`'s.
    %
:- pred seed_roots(net_index::in, match_ctx::in, match_delta::out,
                   rete_state::in, rete_state::out) is det.

    % A fact left working memory.
    %
:- pred fact_retracted(net_index::in, match_ctx::in, fact_id::in,
                       match_delta::out, rete_state::in, rete_state::out)
    is det.

%-----------------------------------------------------------------------------%
% Reading
%-----------------------------------------------------------------------------%

    % The facts currently in an alpha node's memory, in insertion order.
    %
:- func alpha_memory(rete_state, node_id) = list(fact_id).

    % The tokens a beta node currently outputs.
    %
:- func beta_memory(rete_state, node_id) = list(token).

    % Every beta node this state holds a memory for, for `ds.engine`'s
    % path-independence audit.
    %
:- func beta_nodes_with_memory(rete_state) = list(node_id).

    % How many matches a terminal node currently holds.
    %
:- func terminal_matches(rete_state, node_id) = int.

    % [NDBG.4.2]'s match trace, for one fact: the alpha nodes on its schema, in
    % artefact order, each with whether it admits the fact. Changes no state and
    % raises nothing.
    %
:- func alpha_trace(net_index, match_ctx, fact) = list(pair(alpha_node, bool)).

    % `ds_engine_mem`'s network counts ([NDBG.2.1]). No left memory is kept here, so
    % beta tokens is derived: a beta's left input is its parent's output, or a root's
    % one nil token.
    %
:- func alpha_node_count(net_index) = int.
:- func alpha_match_count(net_index, rete_state) = int.
:- func beta_node_count(net_index) = int.
:- func beta_token_count(net_index, rete_state) = int.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.builtins.
:- import_module ds.expr.
:- import_module ds.value.
:- import_module int.
:- import_module uint64.
:- import_module set.
:- import_module array.
:- import_module uint32.
:- import_module require.
:- import_module string.
:- import_module float.
:- import_module version_hash_table.

%-----------------------------------------------------------------------------%

:- type net_index
    --->    net_index(
                ni_alphas_of_schema :: map(uint32, list(alpha_node)),
                            % schema_id value -> the alphas dispatching on it

                ni_betas_of_alpha :: map(uint32, list(beta_node)),
                            % alpha node_id -> betas taking it as right input

                ni_children :: map(uint32, list(beta_node)),
                            % beta node_id -> betas taking it as left parent

                ni_terminals :: map(uint32, list(terminal_node)),
                            % beta node_id -> terminals it activates

                ni_alpha_keys :: map(uint32, list(uint32)),
                            % alpha node_id -> the candidate slots some beta
                            % joins on

                ni_roots :: list(beta_node),
                            % every negative beta with no left parent

                ni_join_keys :: map(uint32, join_key)
                            % beta node_id -> the decided equality it probes on
            ).

build_index(N, Schemas) = Index :-
    ByName = list.foldl(add_schema_name, Schemas, map.init),
    Keys = list.foldl(iret_7_5_1_join_key(Schemas), beta_nodes(N), map.init),
    Index = net_index(
        list.foldl(add_alpha_for_schema(ByName), alpha_nodes(N), map.init),
        map.map_values_only(deepest_first,
            list.foldl(add_beta_of_alpha, beta_nodes(N), map.init)),
        list.foldl(add_child, beta_nodes(N), map.init),
        list.foldl(add_terminal_of, terminal_nodes(N), map.init),
        list.foldl(add_alpha_key(Keys), beta_nodes(N), map.init),
        list.filter(is_root_beta, beta_nodes(N)),
        Keys).

:- pred is_root_beta(beta_node::in) is semidet.

is_root_beta(B) :-
    B ^ bn_parent = no,
    B ^ bn_negative = yes.

:- func add_alpha_key(map(uint32, join_key), beta_node,
                      map(uint32, list(uint32))) = map(uint32, list(uint32)).

add_alpha_key(Keys, B, M) = Out :-
    ( if
        map.search(Keys, node_id_value(B ^ bn_id), JK),
        Alpha = node_id_value(B ^ bn_right ^ an_id),
        Slot = slot_index_value(JK ^ jk_cand),
        Prior = ( if map.search(M, Alpha, P) then P else [] ),
        not list.member(Slot, Prior)
    then
        Out = map.set(M, Alpha, Prior ++ [Slot])
    else
        Out = M
    ).

    % Once per slot: a duplicated key would index a fact twice, and the join would
    % emit two identical tokens.

:- func alpha_keys_of(net_index, uint32) = list(uint32).

alpha_keys_of(Index, Key) =
    ( if map.search(Index ^ ni_alpha_keys, Key, Ks) then Ks else [] ).

:- func add_schema_name(schema, map(uint32, schema_id)) =
    map(uint32, schema_id).

add_schema_name(S, M) =
    map.set(M, intern_ref_value(schema_name_ref(S ^ s_name)), S ^ s_id).

:- func add_alpha_for_schema(map(uint32, schema_id), alpha_node,
                             map(uint32, list(alpha_node))) =
    map(uint32, list(alpha_node)).

add_alpha_for_schema(ByName, A, M) = Result :-
    ( if
        map.search(ByName, intern_ref_value(schema_name_ref(A ^ an_schema)),
            SchemaId)
    then
        Result = append_to(M, schema_id_value(SchemaId), A)
    else
        % Unreachable from a load: `ds.dsc.rdsc_8_7_alpha_schema_dangles` refuses it.
        Result = M
    ).

:- func add_beta_of_alpha(beta_node, map(uint32, list(beta_node))) =
    map(uint32, list(beta_node)).

add_beta_of_alpha(B, M) =
    append_to(M, node_id_value(B ^ bn_right ^ an_id), B).

    % [IRET.7.7]: a fact right-activates each chain deepest node first. In a
    % self-join a shallower first would build one match twice: its extensions meet
    % the fact at a deeper node, whose own right-activation extends them again.
    % Chains keep their order.
    %
:- func deepest_first(list(beta_node)) = list(beta_node).

deepest_first(Betas) = list.condense(list.map(order_chain, chains_of(Betas))).

:- func chains_of(list(beta_node)) = list(list(beta_node)).

chains_of([]) = [].
chains_of([B | Bs]) = [[B | Same] | chains_of(Rest)] :-
    Root = chain_root(B),
    list.filter(
        (pred(X::in) is semidet :- chain_root(X) = Root),
        Bs, Same, Rest).

:- func order_chain(list(beta_node)) = list(beta_node).

order_chain(L) = Sorted :-
    list.sort(deeper_first, L, Sorted).

:- pred deeper_first(beta_node::in, beta_node::in, comparison_result::out)
    is det.

deeper_first(A, B, R) :-
    compare(R, chain_depth(B), chain_depth(A)).

:- func chain_root(beta_node) = uint32.

chain_root(B) =
    ( if B ^ bn_parent = yes(P) then chain_root(P)
    else node_id_value(B ^ bn_id) ).

:- func chain_depth(beta_node) = int.

chain_depth(B) =
    ( if B ^ bn_parent = yes(P) then 1 + chain_depth(P) else 0 ).

:- func add_child(beta_node, map(uint32, list(beta_node))) =
    map(uint32, list(beta_node)).

add_child(B, M) = Result :-
    (
        B ^ bn_parent = yes(Parent),
        Result = append_to(M, node_id_value(Parent ^ bn_id), B)
    ;
        B ^ bn_parent = no,
        Result = M
    ).

:- func add_terminal_of(terminal_node, map(uint32, list(terminal_node))) =
    map(uint32, list(terminal_node)).

add_terminal_of(T, M) =
    append_to(M, node_id_value(T ^ tn_parent ^ bn_id), T).

:- func append_to(map(uint32, list(T)), uint32, T) = map(uint32, list(T)).

append_to(M, Key, V) =
    ( if map.search(M, Key, Prior) then
        map.set(M, Key, Prior ++ [V])
    else
        map.set(M, Key, [V])
    ).

%-----------------------------------------------------------------------------%

:- type rete_state
    --->    rete_state(
                rs_alpha :: map(uint32, alpha_mem),
                            % alpha node_id -> its facts, in insertion order

                rs_beta  :: map(uint32, list(token)),
                            % Beta node_id -> the tokens it outputs. A beta's left
                            % input is its parent's output, so no left memory is
                            % kept. A NOT node's blocked tokens are absent, so
                            % unblocking recomputes which of the parent's are
                            % missing.

                rs_term  :: map(uint32, int),
                            % terminal node_id -> how many matches it holds

                rs_next_tt :: uint64,
                            % the timetag counter [LDET.5.5]

                rs_alpha_of :: version_hash_table(fact_id, list(uint32)),
                            % Fact id -> the alpha memories holding it. Hashed,
                            % for [LNLS.4.7].

                rs_event :: bool,
                            % A fact is entering or leaving. Seeding is not an
                            % event.

                rs_held :: map(uint32, held)
                            % [LDET.5.5]: the matches the event completed, by node,
                            % awaiting their timetags at the event's end. Keyed on
                            % node id, so the artefact fixes the flush's order.
            ).

    % The full matches one completing join produced during an event.
    %
:- type held
    --->    held(beta_node, list(list(fact_id))).

init_rete = rete_state(map.init, map.init, map.init, 1u64,
    version_hash_table.init_default(fact_id_hash), no, map.init).

no_delta = match_delta([], [], [], []).

alpha_memory(S, Id) =
    ( if map.search(S ^ rs_alpha, node_id_value(Id), AM) then am_facts(AM)
      else [] ).

beta_memory(S, Id) =
    ( if map.search(S ^ rs_beta, node_id_value(Id), L) then L else [] ).

beta_nodes_with_memory(S) =
    list.filter_map(
        (func(K) = Id is semidet :- node_id(K, Id)),
        map.keys(S ^ rs_beta)).

terminal_matches(S, Id) =
    ( if map.search(S ^ rs_term, node_id_value(Id), N) then N else 0 ).

alpha_node_count(Index) = list.length(index_alphas(Index)).

alpha_match_count(Index, S) =
    list.foldl(
        (func(A, N) = N + list.length(alpha_memory(S, A ^ an_id))),
        index_alphas(Index), 0).

beta_node_count(Index) = list.length(index_betas(Index)).

beta_token_count(Index, S) =
    list.foldl((func(B, N) = N + left_memory_size(S, B)),
        index_betas(Index), 0).

:- func left_memory_size(rete_state, beta_node) = int.

left_memory_size(S, B) = Size :-
    (
        B ^ bn_parent = no,
        Size = 1
    ;
        B ^ bn_parent = yes(Parent),
        Size = list.length(beta_memory(S, Parent ^ bn_id))
    ).

:- func index_alphas(net_index) = list(alpha_node).

index_alphas(Index) = list.condense(map.values(Index ^ ni_alphas_of_schema)).

:- func index_betas(net_index) = list(beta_node).

index_betas(Index) = list.condense(map.values(Index ^ ni_betas_of_alpha)).

:- func count_matches(match_delta, map(uint32, int)) = map(uint32, int).

count_matches(Delta, M0) =
    list.foldl(bump(-1), Delta ^ md_removed,
        list.foldl(bump(1), Delta ^ md_added, M0)).

:- func bump(int, activation, map(uint32, int)) = map(uint32, int).

bump(By, Activation, M) = map.set(M, Key, Now) :-
    Key = node_id_value(Activation ^ ac_terminal),
    Now = ( if map.search(M, Key, Prior) then Prior else 0 ) + By.

%-----------------------------------------------------------------------------%
% Assertion
%-----------------------------------------------------------------------------%

fact_asserted(Index, Ctx, FactId, Delta, !S) :-
    !S ^ rs_event := yes,
    ( if lookup_fact(Ctx ^ mc_wm, FactId, Fact) then
        Alphas = alphas_for(Index, Fact ^ f_schema),
        enter_alphas(Index, Ctx, Fact, Alphas, no_delta, Delta0, !S)
    else
        Delta0 = no_delta
    ),
    flush_completions(Index, Ctx, Delta0, Delta, !S),
    !S ^ rs_term := count_matches(Delta, !.S ^ rs_term).

%-----------------------------------------------------------------------------%
% Completion order -- [LDET.5.5]
%-----------------------------------------------------------------------------%
%
% A match completes at the last positive join of its chain; a NOT node below
% passes a token unchanged, so the timetag stamped there orders the activation
% ([LDET.5.9]). One event can complete several matches of one rule along more
% than one path, so completions are held while it propagates and stamped when it
% ends, by the key (`ldet_5_5__before`). A fact id is its entry rank.

    % A positive join with no positive join below it.
    %
    %@helper
:- pred completes(net_index::in, beta_node::in) is semidet.

completes(Index, Beta) :-
    Beta ^ bn_negative = no,
    not has_positive_descendant(Index, Beta ^ bn_id).

    %@helper
:- pred has_positive_descendant(net_index::in, node_id::in) is semidet.

has_positive_descendant(Index, Id) :-
    list.member(Child, children_of(Index, Id)),
    (
        Child ^ bn_negative = no
    ;
        has_positive_descendant(Index, Child ^ bn_id)
    ).

    %@helper
:- pred hold(beta_node::in, list(fact_id)::in,
             rete_state::in, rete_state::out) is det.

hold(Beta, Facts, !S) :-
    Key = node_id_value(Beta ^ bn_id),
    ( if map.search(!.S ^ rs_held, Key, Found) then
        Found = held(B, Prior),
        Held = held(B, [Facts | Prior])
    else
        Held = held(Beta, [Facts])
    ),
    !S ^ rs_held := map.set(!.S ^ rs_held, Key, Held).

    %@helper
:- pred flush_completions(net_index::in, match_ctx::in,
                          match_delta::in, match_delta::out,
                          rete_state::in, rete_state::out) is det.

flush_completions(Index, Ctx, !Delta, !S) :-
    Held = !.S ^ rs_held,
    !S ^ rs_held := map.init,
    !S ^ rs_event := no,
    list.foldl2(flush_node(Index, Ctx), map.values(Held), !Delta, !S).

    %@helper
:- pred flush_node(net_index::in, match_ctx::in, held::in,
                   match_delta::in, match_delta::out,
                   rete_state::in, rete_state::out) is det.

flush_node(Index, Ctx, held(Beta, Tuples), !Delta, !S) :-
    list.sort(completion_order, Tuples, Sorted),
    list.foldl2(complete(Index, Ctx, Beta), Sorted, !Delta, !S).

    %@helper
:- pred complete(net_index::in, match_ctx::in, beta_node::in,
                 list(fact_id)::in, match_delta::in, match_delta::out,
                 rete_state::in, rete_state::out) is det.

complete(Index, Ctx, Beta, Facts, !Delta, !S) :-
    Token = token(Facts, make_timetag(!.S ^ rs_next_tt)),
    !S ^ rs_next_tt := !.S ^ rs_next_tt + 1u64,
    emit_token(Index, Ctx, Beta, Token, !Delta, !S).

    % [LDET.5.5]'s key: the latest entry rank, then the ranks in pattern order.
    %
    %@spec [LDET.5.5]
:- pred completion_order(list(fact_id)::in, list(fact_id)::in,
                         comparison_result::out) is det.

completion_order(A, B, R) :-
    RanksA = list.map(fact_id_value, A),
    RanksB = list.map(fact_id_value, B),
    compare(R0, latest_rank(RanksA), latest_rank(RanksB)),
    ( if R0 = (=) then
        compare(R, RanksA, RanksB)
    else
        R = R0
    ).

    %@helper
:- func latest_rank(list(uint64)) = uint64.

latest_rank(Ranks) =
    list.foldl((func(X, M) = ( if X > M then X else M )), Ranks, 0u64).

alpha_trace(Index, Ctx, Fact) =
    list.map(
        ( func(A) = A -
            ( if alpha_verdict(Ctx, A, Fact) = av_admit then yes else no ) ),
        alphas_for(Index, Fact ^ f_schema)).

:- func alphas_for(net_index, schema_id) = list(alpha_node).

alphas_for(Index, SchemaId) =
    ( if map.search(Index ^ ni_alphas_of_schema, schema_id_value(SchemaId), L)
    then L else [] ).

    % An alpha test's fault ends the dispatch: an EngineError halts the tier where
    % it is raised ([LERR.1.4.7]).
    %
:- pred enter_alphas(net_index::in, match_ctx::in, fact::in,
                     list(alpha_node)::in, match_delta::in, match_delta::out,
                     rete_state::in, rete_state::out) is det.

enter_alphas(_, _, _, [], !Delta, !S).
enter_alphas(Index, Ctx, Fact, [Alpha | Alphas], !Delta, !S) :-
    Verdict = alpha_verdict(Ctx, Alpha, Fact),
    (
        Verdict = av_admit,
        Key = node_id_value(Alpha ^ an_id),
        alpha_put(Key, am_add(alpha_keys_of(Index, Key), Fact,
            alpha_mem_of(!.S, Key)), !S),
        note_alpha_of(Fact ^ f_id, Key, !S),
        Betas = betas_of(Index, Alpha ^ an_id),
        list.foldl2(right_activate(Index, Ctx, Fact), Betas, !Delta, !S),
        enter_alphas(Index, Ctx, Fact, Alphas, !Delta, !S)
    ;
        Verdict = av_reject,
        enter_alphas(Index, Ctx, Fact, Alphas, !Delta, !S)
    ;
        Verdict = av_fault,
        !Delta ^ md_faults := !.Delta ^ md_faults ++
            [match_fault(Alpha ^ an_id, ms_alpha, rf_artefact_lied, no_origin,
                [], Fact ^ f_id)]
    ).

:- func betas_of(net_index, node_id) = list(beta_node).

betas_of(Index, AlphaId) =
    ( if map.search(Index ^ ni_betas_of_alpha, node_id_value(AlphaId), L)
    then L else [] ).

:- type alpha_verdict
    --->    av_admit
    ;       av_reject
    ;       av_fault.
            % ENGINE_FAULT_ARTEFACT_LIED, naming `$alpha_<id>`.

    % A fact is admitted iff it passes every test [RDSC.4a.6]. A test whose slot
    % index names no slot of the fact's schema ([RDSC.4a.9.1], [IRET.6.4]), or a
    % regex test whose subject is not a String ([RDSC.4a.6.2]), is a held fault: a
    % failing test decides the fact wherever it stands, so the fault is the verdict
    % only if none fails. A literal of the wrong type just fails its test.
    %
:- func alpha_verdict(match_ctx, alpha_node, fact) = alpha_verdict.

alpha_verdict(Ctx, Alpha, Fact) =
    alpha_scan(Ctx, Fact, Alpha ^ an_tests, no).

:- func alpha_scan(match_ctx, fact, list(alpha_test), bool) = alpha_verdict.

alpha_scan(_, _, [], Held) = Verdict :-
    (
        Held = yes,
        Verdict = av_fault
    ;
        Held = no,
        Verdict = av_admit
    ).
alpha_scan(Ctx, Fact, [Test | Tests], Held) = Verdict :-
    ( if rdsc_4a_9_1_names_no_slot(Fact, Test) then
        Verdict = alpha_scan(Ctx, Fact, Tests, yes)
    else if rdsc_4a_6_2_regex_subject_lies(Ctx, Fact, Test) then
        Verdict = alpha_scan(Ctx, Fact, Tests, yes)
    else if alpha_test_passes(Ctx, Fact, Test) then
        Verdict = alpha_scan(Ctx, Fact, Tests, Held)
    else
        Verdict = av_reject
    ).

    %@spec [RDSC.4a.9.1]
:- pred rdsc_4a_9_1_names_no_slot(fact::in, alpha_test::in) is semidet.

rdsc_4a_9_1_names_no_slot(Fact, Test) :-
    slot_index_int(alpha_test_slot(Test)) >= array.size(Fact ^ f_slots).

    % A regex test reading a slot the schema does not declare `String`, or whose
    % value is not a string. Asked only of a test whose slot exists.
    %
    %@spec [RDSC.4a.6.2]
:- pred rdsc_4a_6_2_regex_subject_lies(match_ctx::in, fact::in,
                                       alpha_test::in) is semidet.

rdsc_4a_6_2_regex_subject_lies(Ctx, Fact, Test) :-
    Test = at_regex(Slot, _),
    not (
        map.search(Ctx ^ mc_schemas, schema_id_value(Fact ^ f_schema),
            Schema),
        list.index0(slot_commons(Schema), slot_index_int(Slot), Common),
        Common ^ sc_kind = k_string,
        array.semidet_lookup(Fact ^ f_slots, slot_index_int(Slot), Value),
        ( Value = str(_)
        ; Value = text(_)
        )
    ).

:- func alpha_test_slot(alpha_test) = slot_index.

alpha_test_slot(at_eq(Slot, _)) = Slot.
alpha_test_slot(at_cmp(Slot, _, _)) = Slot.
alpha_test_slot(at_regex(Slot, _)) = Slot.

:- pred alpha_test_passes(match_ctx::in, fact::in, alpha_test::in) is semidet.

alpha_test_passes(Ctx, Fact, Test) :-
    (
        Test = at_eq(Slot, Lit),
        test_slot(Ctx, Fact, Slot, op_eq, Lit)
    ;
        Test = at_cmp(Slot, Op, Lit),
        test_slot(Ctx, Fact, Slot, Op, Lit)
    ;
        Test = at_regex(Slot, Pattern),
        test_regex(Ctx, Fact, Slot, Pattern)
    ).

    % `FN_REGEX_MATCH` over the slot with the test's pattern and no flags, through
    % the evaluator ([RDSC.4a.6], [RTIM.14.8]): flags are folded into the pattern as
    % `(?f:p)`. Compiled per match; `ds.dsc.invalid_alpha_regex` has refused an
    % invalid pattern at load.
    %
:- pred test_regex(match_ctx::in, fact::in, slot_index::in, string::in)
    is semidet.

test_regex(Ctx, Fact, Slot, Pattern) :-
    Expr = e_call(fn_regex_match,
        [e_slot(token_fact(0), slot(Slot)), e_lit(text(Pattern))]),
    eval(Expr, ctx_for(Ctx, [Fact ^ f_id], no), Outcome),
    admits(Outcome).

    % Through the evaluator ([RTIM.14.8]).
    %
:- pred test_slot(match_ctx::in, fact::in, slot_index::in, binop::in,
                  alpha_literal::in) is semidet.

test_slot(Ctx, Fact, Slot, Op, Lit) :-
    Expr = e_binop(Op, e_slot(token_fact(0), slot(Slot)),
        e_lit(alpha_literal_value(Lit))),
    eval(Expr, ctx_for(Ctx, [Fact ^ f_id], no), Outcome),
    admits(Outcome).

:- func ctx_for(match_ctx, list(fact_id), maybe(fact_id)) = eval_ctx.

ctx_for(Ctx, Token, Candidate) =
    % A node's test has no bind frame [RDSC.4a.9.6].
    eval_ctx(Token, Candidate, Ctx ^ mc_wm, Ctx ^ mc_schemas,
        Ctx ^ mc_interns, Ctx ^ mc_now, Ctx ^ mc_wall, map.init, 0,
        Ctx ^ mc_cache, Ctx ^ mc_series).

%-----------------------------------------------------------------------------%

:- pred right_activate(net_index::in, match_ctx::in, fact::in, beta_node::in,
                       match_delta::in, match_delta::out,
                       rete_state::in, rete_state::out) is det.

right_activate(Index, Ctx, Fact, Beta, !Delta, !S) :-
    Left = left_input(!.S, Beta),
    (
        Beta ^ bn_negative = no,
        list.foldl2(join_with(Index, Ctx, Fact, Beta), Left, !Delta, !S)
    ;
        Beta ^ bn_negative = yes,
        % Every left token is tested, not only the passing ones: each test can
        % record a fault.
        Passing = beta_memory(!.S, Beta ^ bn_id),
        list.foldl2(collect_blocked(Ctx, Beta, Fact), Left, [], BlockedRev,
            !Delta),
        Blocked = list.filter(
            (pred(T::in) is semidet :- list.member(T, BlockedRev)), Passing),
        list.foldl2(withdraw_token(Index, Ctx, Beta), Blocked, !Delta, !S)
    ).

:- pred collect_blocked(match_ctx::in, beta_node::in, fact::in, token::in,
                        list(token)::in, list(token)::out,
                        match_delta::in, match_delta::out) is det.

collect_blocked(Ctx, Beta, Fact, Token, !Blocked, !Delta) :-
    block_verdict(Ctx, Token, Fact, Beta ^ bn_tests, Blocks, Faults, Expired),
    add_faults(Beta, Token, Fact, Faults, !Delta),
    add_expired(Expired, !Delta),
    (
        Blocks = yes,
        !:Blocked = [Token | !.Blocked]
    ;
        Blocks = no
    ).

    % A beta's left input: its parent's output, or the nil token for a root
    % [RDSC.4a.7].
    %
:- func left_input(rete_state, beta_node) = list(token).

left_input(S, Beta) = Tokens :-
    (
        Beta ^ bn_parent = yes(Parent),
        Tokens = beta_memory(S, Parent ^ bn_id)
    ;
        Beta ^ bn_parent = no,
        Tokens = [nil_token(make_timetag(0u64))]
    ).

:- pred join_with(net_index::in, match_ctx::in, fact::in, beta_node::in,
                  token::in, match_delta::in, match_delta::out,
                  rete_state::in, rete_state::out) is det.

join_with(Index, Ctx, Fact, Beta, Left, !Delta, !S) :-
    join_verdict(Ctx, Left, Fact, Beta ^ bn_tests, Passes, Faults, Expired),
    add_faults(Beta, Left, Fact, Faults, !Delta),
    add_expired(Expired, !Delta),
    (
        Passes = yes,
        ( if
            !.S ^ rs_event = yes,
            completes(Index, Beta)
        then
            % [LDET.5.5]: held, and stamped when the event ends.
            hold(Beta, Left ^ t_facts ++ [Fact ^ f_id], !S)
        else
            mint(Left, Fact ^ f_id, New, !S),
            emit_token(Index, Ctx, Beta, New, !Delta, !S)
        )
    ;
        Passes = no
    ).

    % A token that completes a match during an event is not minted here: `complete`
    % stamps it from the same counter when the event ends.
    %
:- pred mint(token::in, fact_id::in, token::out,
             rete_state::in, rete_state::out) is det.

mint(Left, FactId, token(Facts, make_timetag(!.S ^ rs_next_tt)), !S) :-
    % Position i is the fact bound by the rule's i-th positive pattern.
    Facts = Left ^ t_facts ++ [FactId],
    !S ^ rs_next_tt := !.S ^ rs_next_tt + 1u64.

    % A positive join. The tests combine as an absorbing `and` ([IRET.7.6],
    % [LNUL.4.2]): a `false` rejects the pair and drops every fault. Otherwise the
    % pair yields one fault, the one [LNUL.4.2]'s order selects ([LERR.1.4.11]), so
    % the scan goes past every fault and `null` looking for a `false`.
    %
:- pred join_verdict(match_ctx::in, token::in, fact::in, list(expr)::in,
                     bool::out, list(held_fault)::out, list(string)::out)
    is det.

join_verdict(Ctx, Left, Fact, Tests, Passes, Faults, Expired) :-
    join_scan(Ctx, Left, Fact, Tests, yes, no, Passes, Faults, [], Expired).

:- type held_fault
    --->    held_fault(
                hf_fault  :: runtime_fault,
                hf_origin :: fault_origin
            ).

:- func raised_by(match_ctx, token, fact, expr, runtime_fault) = held_fault.

raised_by(Ctx, Left, Fact, Test, F) =
    held_fault(F, fault_origin(Test, test_ctx(Ctx, Left, Fact), F)).

:- pred join_scan(match_ctx::in, token::in, fact::in, list(expr)::in,
                  bool::in, maybe(held_fault)::in,
                  bool::out, list(held_fault)::out,
                  list(string)::in, list(string)::out) is det.

join_scan(_, _, _, [], AllTrue, Held, Passes, Faults, !Expired) :-
    (
        Held = yes(Fault),
        Passes = no,
        Faults = [Fault]
    ;
        Held = no,
        Passes = AllTrue,
        Faults = []
    ).
join_scan(Ctx, Left, Fact, [Test | Tests], AllTrue, Held, Passes, Faults,
        !Expired) :-
    test_outcome(Ctx, Left, Fact, Test, Outcome, !Expired),
    ( if Outcome = ev_ok(bool(no)) then
        Passes = no,
        Faults = []
    else if test_fault(Test, Outcome, F) then
        join_scan(Ctx, Left, Fact, Tests, no,
            yes(held_with(test_ctx(Ctx, Left, Fact), Held,
                raised_by(Ctx, Left, Fact, Test, F))),
            Passes, Faults, !Expired)
    else if admits(Outcome) then
        join_scan(Ctx, Left, Fact, Tests, AllTrue, Held, Passes, Faults,
            !Expired)
    else
        join_scan(Ctx, Left, Fact, Tests, no, Held, Passes, Faults, !Expired)
    ).

    % The fault selected once `F` joins the one held. The origin is part of
    % [LNUL.4.2]'s order. `ECtx` resolves the interned names the origins hold.
    %
:- func held_with(eval_ctx, maybe(held_fault), held_fault) = held_fault.

held_with(_, no, F) = F.
held_with(ECtx, yes(G), F) =
    ( if
        lnul_4_2_before(ECtx, located(F ^ hf_fault, F ^ hf_origin),
            located(G ^ hf_fault, G ^ hf_origin))
    then F
    else G
    ).

    % A negated join: does this fact block the token? [LNUL.4.7] Only a definite
    % `false` unblocks. The tests combine as the same absorbing `and` ([IRET.7.6]). A
    % value that is neither a Bool nor `null` keeps the block and raises nothing.
    %
:- pred block_verdict(match_ctx::in, token::in, fact::in, list(expr)::in,
                      bool::out, list(held_fault)::out, list(string)::out)
    is det.

block_verdict(Ctx, Left, Fact, Tests, Blocks, Faults, Expired) :-
    block_scan(Ctx, Left, Fact, Tests, no, Blocks, Faults, [], Expired).

:- pred block_scan(match_ctx::in, token::in, fact::in, list(expr)::in,
                   maybe(held_fault)::in,
                   bool::out, list(held_fault)::out,
                   list(string)::in, list(string)::out) is det.

block_scan(_, _, _, [], Held, yes, Faults, !Expired) :-
    (
        Held = yes(Fault),
        Faults = [Fault]
    ;
        Held = no,
        Faults = []
    ).
block_scan(Ctx, Left, Fact, [Test | Tests], Held, Blocks, Faults, !Expired) :-
    test_outcome(Ctx, Left, Fact, Test, Outcome, !Expired),
    ( if Outcome = ev_ok(bool(no)) then
        Blocks = no,
        Faults = []
    else if Outcome = ev_fault(F) then
        block_scan(Ctx, Left, Fact, Tests,
            yes(held_with(test_ctx(Ctx, Left, Fact), Held,
                raised_by(Ctx, Left, Fact, Test, F))), Blocks,
            Faults, !Expired)
    else
        block_scan(Ctx, Left, Fact, Tests, Held, Blocks, Faults, !Expired)
    ).

    % One join test, and the expired cache keys it read appended in reading order.
    %
:- pred test_outcome(match_ctx::in, token::in, fact::in, expr::in,
                     eval_outcome::out, list(string)::in, list(string)::out)
    is det.

test_outcome(Ctx, Left, Fact, Test, Outcome, !Expired) :-
    eval_noting_expiry(Test, test_ctx(Ctx, Left, Fact), Outcome, Read),
    !:Expired = !.Expired ++ Read.

:- func test_ctx(match_ctx, token, fact) = eval_ctx.

test_ctx(Ctx, Left, Fact) = ctx_for(Ctx, Left ^ t_facts, yes(Fact ^ f_id)).

    % Does any of these facts block the token? Every fact is tested, so every fault
    % is collected with the fact it was raised for.
    %
:- pred any_blocks(match_ctx::in, beta_node::in, token::in, list(fact)::in,
                   bool::out, list({fact, held_fault})::out, list(string)::out)
    is det.

any_blocks(_, _, _, [], no, [], []).
any_blocks(Ctx, Beta, Token, [Fact | Facts], Any, Faults, Expired) :-
    block_verdict(Ctx, Token, Fact, Beta ^ bn_tests, Blocks, Here, ReadHere),
    any_blocks(Ctx, Beta, Token, Facts, Rest, There, ReadThere),
    Any = bool.or(Blocks, Rest),
    Faults = list.map((func(F) = {Fact, F}), Here) ++ There,
    Expired = ReadHere ++ ReadThere.

:- pred add_expired(list(string)::in, match_delta::in, match_delta::out)
    is det.

add_expired(Keys, !Delta) :-
    list.foldl(
        ( pred(K::in, D0::in, D::out) is det :-
            ( if list.member(K, D0 ^ md_expired) then
                D = D0
            else
                D = D0 ^ md_expired := D0 ^ md_expired ++ [K]
            )
        ), Keys, !Delta).

:- pred add_faults(beta_node::in, token::in, fact::in, list(held_fault)::in,
                   match_delta::in, match_delta::out) is det.

add_faults(Beta, Token, Fact, Faults, !Delta) :-
    ( if Faults = [] then
        true
    else
        !Delta ^ md_faults := !.Delta ^ md_faults ++
            list.map(
                (func(held_fault(F, O)) =
                    match_fault(Beta ^ bn_id, ms_beta, F, O, Token ^ t_facts,
                        Fact ^ f_id)),
                Faults)
    ).

%-----------------------------------------------------------------------------%
% Match-time faults, once per derivation -- [LERR.1.4.12]
%-----------------------------------------------------------------------------%

lerr_1_4_12_derived(Index, S, OrdinalOf, Faults) = Halting ++ Derived :-
    list.filter(defers, Faults, Deferred, Halting),
    list.map_foldl(
        ( pred(MF::in, KeyMF::out, Seq0::in, Seq::out) is det :-
            KeyMF = {trap_key(Index, OrdinalOf, Seq0, MF), MF},
            Seq = Seq0 + 1 ),
        Deferred, Keyed, 0, _),
    list.sort(Keyed, Sorted),
    list.foldl2(keep_derived(Index, S), Sorted, no, _, [], RevDerived),
    Derived = list.reverse(RevDerived).

    %@helper
:- pred defers(match_fault::in) is semidet.

defers(MF) :-
    Class = expr_fault_class(MF ^ mf_fault),
    ( Class = fc_computation ; Class = fc_type ).

    % The order key: the terminal ordinal (`no`, a node no rule reaches,
    % first), the latest entry rank of the pair, its ranks in pattern order (a
    % prefix first), the node's depth, the node's id (two nodes tie on all of
    % these only where one serves two rules), and the order raised, so a pair
    % raised twice keeps its first.
    %
    %@helper
:- func trap_key(net_index, (func(node_id) = maybe(K)), int, match_fault)
    = {maybe(K), uint64, list(uint64), int, uint32, int}.

trap_key(Index, OrdinalOf, Seq, MF) =
        {Ordinal, latest_rank(Ranks), Ranks, Depth, node_id_value(Node), Seq} :-
    Node = MF ^ mf_node,
    Ranks = list.map(fact_id_value, MF ^ mf_token ++ [MF ^ mf_candidate]),
    Ordinal = node_ordinal(Index, OrdinalOf, Node),
    Depth = ( if beta_by_id(Index, Node, Beta) then beta_depth(Beta) else 0 ).

    %@helper
:- func node_ordinal(net_index, (func(node_id) = maybe(K)), node_id) = maybe(K).

node_ordinal(Index, OrdinalOf, Node) = Least :-
    Here = list.filter_map(
        ( func(T) = TO is semidet :- OrdinalOf(T ^ tn_id) = yes(TO) ),
        terminals_of(Index, Node)),
    Below = list.filter_map(
        ( func(C) = CO is semidet :-
            node_ordinal(Index, OrdinalOf, C ^ bn_id) = yes(CO) ),
        children_of(Index, Node)),
    list.sort(Here ++ Below, Ordinals),
    (
        Ordinals = [First | _],
        Least = yes(First)
    ;
        Ordinals = [],
        Least = no
    ).

    %@helper
:- func beta_depth(beta_node) = int.

beta_depth(Beta) =
    ( if Beta ^ bn_parent = yes(Parent) then 1 + beta_depth(Parent) else 0 ).

    %@helper
:- pred beta_by_id(net_index::in, node_id::in, beta_node::out) is semidet.

beta_by_id(Index, Node, Beta) :-
    list.find_first_match((pred(B::in) is semidet :- B ^ bn_id = Node),
        index_betas(Index), Beta).

    % Keep a fault whose pair is live in `S` and was not kept just before:
    % the candidate in the node's right memory, the token in its left input.
    %
    %@helper
:- pred keep_derived(net_index::in, rete_state::in,
    {T, match_fault}::in, maybe(match_fault)::in, maybe(match_fault)::out,
    list(match_fault)::in, list(match_fault)::out) is det.

keep_derived(Index, S, {_, MF}, Prev, yes(MF), !Kept) :-
    ( if
        not (
            Prev = yes(P),
            P ^ mf_node = MF ^ mf_node,
            P ^ mf_token = MF ^ mf_token,
            P ^ mf_candidate = MF ^ mf_candidate
        ),
        beta_by_id(Index, MF ^ mf_node, Beta),
        list.member(MF ^ mf_candidate,
            alpha_memory(S, Beta ^ bn_right ^ an_id)),
        list.member(Token, left_input(S, Beta)),
        Token ^ t_facts = MF ^ mf_token
    then
        !:Kept = [MF | !.Kept]
    else
        true
    ).

%-----------------------------------------------------------------------------%

:- pred emit_token(net_index::in, match_ctx::in, beta_node::in, token::in,
                   match_delta::in, match_delta::out,
                   rete_state::in, rete_state::out) is det.

emit_token(Index, Ctx, Beta, Token, !Delta, !S) :-
    Key = node_id_value(Beta ^ bn_id),
    !S ^ rs_beta := append_to(!.S ^ rs_beta, Key, Token),

    % Terminals first, then child betas.
    Terminals = terminals_of(Index, Beta ^ bn_id),
    list.foldl(add_activation(Token), Terminals, !Delta),

    Children = children_of(Index, Beta ^ bn_id),
    list.foldl2(left_activate(Index, Ctx, Token), Children, !Delta, !S).

:- func terminals_of(net_index, node_id) = list(terminal_node).

terminals_of(Index, BetaId) =
    ( if map.search(Index ^ ni_terminals, node_id_value(BetaId), L)
    then L else [] ).

:- func children_of(net_index, node_id) = list(beta_node).

children_of(Index, BetaId) =
    ( if map.search(Index ^ ni_children, node_id_value(BetaId), L)
    then L else [] ).

:- pred add_activation(token::in, terminal_node::in,
                       match_delta::in, match_delta::out) is det.

add_activation(Token, Terminal, !Delta) :-
    !Delta ^ md_added :=
        !.Delta ^ md_added ++ [activation(Terminal ^ tn_id, Token)].

:- pred left_activate(net_index::in, match_ctx::in, token::in, beta_node::in,
                      match_delta::in, match_delta::out,
                      rete_state::in, rete_state::out) is det.

left_activate(Index, Ctx, Token, Beta, !Delta, !S) :-
    Facts = right_candidates(Index, Ctx, !.S, Beta, Token),
    (
        Beta ^ bn_negative = no,
        list.foldl2(join_against(Index, Ctx, Beta, Token), Facts, !Delta, !S)
    ;
        Beta ^ bn_negative = yes,
        % A NOT node passes the token unchanged, when nothing blocks it.
        any_blocks(Ctx, Beta, Token, Facts, Blocked, Faults, Expired),
        list.foldl(
            ( pred(BF::in, D0::in, D::out) is det :-
                BF = {Blocker, HF},
                add_faults(Beta, Token, Blocker, [HF], D0, D) ),
            Faults, !Delta),
        add_expired(Expired, !Delta),
        (
            Blocked = no,
            emit_token(Index, Ctx, Beta, Token, !Delta, !S)
        ;
            Blocked = yes
        )
    ).

:- func right_facts(match_ctx, rete_state, beta_node) = list(fact).

right_facts(Ctx, S, Beta) =
    list.filter_map(resolve(Ctx),
        alpha_memory(S, Beta ^ bn_right ^ an_id)).

:- func resolve(match_ctx, fact_id) = fact is semidet.

resolve(Ctx, Id) = Fact :-
    lookup_fact(Ctx ^ mc_wm, Id, Fact).

:- pred join_against(net_index::in, match_ctx::in, beta_node::in, token::in,
                     fact::in, match_delta::in, match_delta::out,
                     rete_state::in, rete_state::out) is det.

join_against(Index, Ctx, Beta, Token, Fact, !Delta, !S) :-
    join_with(Index, Ctx, Fact, Beta, Token, !Delta, !S).

%-----------------------------------------------------------------------------%
% Seeding
%-----------------------------------------------------------------------------%

seed_roots(Index, Ctx, Delta, !S) :-
    list.foldl2(seed_root(Index, Ctx), Index ^ ni_roots, no_delta, Delta, !S).

    % The nil token may already be passing: a fact asserted and retracted before the
    % first pump emits it through `maybe_unblock`. So seeding is guarded, and
    % idempotent, which lets `audit_match_paths` seed a replay.
    %
    %@helper
:- pred seed_root(net_index::in, match_ctx::in, beta_node::in,
                  match_delta::in, match_delta::out,
                  rete_state::in, rete_state::out) is det.

seed_root(Index, Ctx, Beta, !Delta, !S) :-
    % The nil token `left_input` synthesises: tokens compare by value.
    Nil = nil_token(make_timetag(0u64)),
    ( if not_in(beta_memory(!.S, Beta ^ bn_id), Nil) then
        maybe_unblock(Index, Ctx, Beta, Nil, !Delta, !S)
    else
        true
    ).

%-----------------------------------------------------------------------------%
% Retraction
%-----------------------------------------------------------------------------%

fact_retracted(Index, Ctx, FactId, Delta, !S) :-
    % The fact is already gone from working memory. An event too: a `no` it releases
    % can complete matches at a later join.
    !S ^ rs_event := yes,
    list.foldl2(leave_alpha(Index, Ctx, FactId), alphas_of(!.S, FactId),
        no_delta, Delta0, !S),
    flush_completions(Index, Ctx, Delta0, Delta, !S),
    !S ^ rs_alpha_of := version_hash_table.delete(!.S ^ rs_alpha_of, FactId),
    !S ^ rs_term := count_matches(Delta, !.S ^ rs_term).

:- pred leave_alpha(net_index::in, match_ctx::in, fact_id::in, uint32::in,
                    match_delta::in, match_delta::out,
                    rete_state::in, rete_state::out) is det.

leave_alpha(Index, Ctx, FactId, AlphaKey, !Delta, !S) :-
    ( if
        map.search(!.S ^ rs_alpha, AlphaKey, AM),
        am_holds(AM, FactId),
        node_id(AlphaKey, AlphaId)
    then
        alpha_put(AlphaKey, am_remove(AM, FactId), !S),
        Betas = betas_of(Index, AlphaId),
        list.foldl2(right_deactivate(Index, Ctx, FactId), Betas, !Delta, !S)
    else
        true
    ).

:- pred right_deactivate(net_index::in, match_ctx::in, fact_id::in,
                         beta_node::in, match_delta::in, match_delta::out,
                         rete_state::in, rete_state::out) is det.

right_deactivate(Index, Ctx, FactId, Beta, !Delta, !S) :-
    (
        Beta ^ bn_negative = no,
        Doomed = list.filter(token_contains(FactId),
            beta_memory(!.S, Beta ^ bn_id)),
        list.foldl2(withdraw_token(Index, Ctx, Beta), Doomed, !Delta, !S)
    ;
        Beta ^ bn_negative = yes,
        Left = left_input(!.S, Beta),
        Passing = beta_memory(!.S, Beta ^ bn_id),
        Candidates = list.filter(not_in(Passing), Left),
        list.foldl2(maybe_unblock(Index, Ctx, Beta), Candidates, !Delta, !S)
    ).

:- pred token_contains(fact_id::in, token::in) is semidet.

token_contains(FactId, Token) :-
    list.member(FactId, Token ^ t_facts).

:- pred not_in(list(token)::in, token::in) is semidet.

not_in(Passing, Token) :-
    not list.member(Token, Passing).

:- pred maybe_unblock(net_index::in, match_ctx::in, beta_node::in, token::in,
                      match_delta::in, match_delta::out,
                      rete_state::in, rete_state::out) is det.

maybe_unblock(Index, Ctx, Beta, Token, !Delta, !S) :-
    Facts = right_candidates(Index, Ctx, !.S, Beta, Token),
    % The faults and expired cache keys are dropped: a retraction evaluates no join
    % test ([IRET.7.7], [IRET.7.9.3]). The blockers are not stored, so this re-tests
    % to decide, over pairs that were live before and so derive nothing
    % ([LERR.1.4.12]).
    any_blocks(Ctx, Beta, Token, Facts, Blocked, _, _),
    (
        Blocked = no,
        emit_token(Index, Ctx, Beta, Token, !Delta, !S)
    ;
        Blocked = yes
    ).

:- pred withdraw_token(net_index::in, match_ctx::in, beta_node::in, token::in,
                       match_delta::in, match_delta::out,
                       rete_state::in, rete_state::out) is det.

withdraw_token(Index, Ctx, Beta, Token, !Delta, !S) :-
    Key = node_id_value(Beta ^ bn_id),
    ( if map.search(!.S ^ rs_beta, Key, Tokens) then
        !S ^ rs_beta := map.set(!.S ^ rs_beta, Key,
            list.delete_all(Tokens, Token))
    else
        true
    ),

    Terminals = terminals_of(Index, Beta ^ bn_id),
    list.foldl(remove_activation(Token), Terminals, !Delta),

    Children = children_of(Index, Beta ^ bn_id),
    list.foldl2(left_deactivate(Index, Ctx, Token), Children, !Delta, !S).

:- pred remove_activation(token::in, terminal_node::in,
                          match_delta::in, match_delta::out) is det.

remove_activation(Token, Terminal, !Delta) :-
    !Delta ^ md_removed :=
        !.Delta ^ md_removed ++ [activation(Terminal ^ tn_id, Token)].

:- pred left_deactivate(net_index::in, match_ctx::in, token::in,
                        beta_node::in, match_delta::in, match_delta::out,
                        rete_state::in, rete_state::out) is det.

left_deactivate(Index, Ctx, Token, Beta, !Delta, !S) :-
    (
        Beta ^ bn_negative = no,
        % By prefix: two unrelated tokens can share a fact.
        Doomed = list.filter(extends(Token),
            beta_memory(!.S, Beta ^ bn_id)),
        list.foldl2(withdraw_token(Index, Ctx, Beta), Doomed, !Delta, !S)
    ;
        Beta ^ bn_negative = yes,
        ( if list.member(Token, beta_memory(!.S, Beta ^ bn_id)) then
            withdraw_token(Index, Ctx, Beta, Token, !Delta, !S)
        else
            true
        )
    ).

:- pred extends(token::in, token::in) is semidet.

extends(Parent, Child) :-
    list.append(Parent ^ t_facts, _, Child ^ t_facts).

%-----------------------------------------------------------------------------%


%-----------------------------------------------------------------------------%
% The alpha membership index
%-----------------------------------------------------------------------------%

:- func alphas_of(rete_state, fact_id) = list(uint32).

alphas_of(S, FactId) =
    ( if version_hash_table.search(S ^ rs_alpha_of, FactId, Keys) then Keys
      else [] ).

:- pred note_alpha_of(fact_id::in, uint32::in,
                      rete_state::in, rete_state::out) is det.

note_alpha_of(FactId, Key, !S) :-
    Prior = alphas_of(!.S, FactId),
    !S ^ rs_alpha_of :=
        version_hash_table.set(!.S ^ rs_alpha_of, FactId, [Key | Prior]).

:- pred drop_from_alpha(fact_id::in, uint32::in,
                        rete_state::in, rete_state::out) is det.

drop_from_alpha(FactId, Key, !S) :-
    ( if map.search(!.S ^ rs_alpha, Key, AM) then
        alpha_put(Key, am_remove(AM, FactId), !S)
    else
        true
    ).

%-----------------------------------------------------------------------------%
% Alpha memory
%-----------------------------------------------------------------------------%

    % An alpha node's facts, in insertion order, with O(1) add and O(1) amortized
    % remove [LNLS.4.7]. The order is what a join walks.
    %
:- type alpha_mem
    --->    alpha_mem(
                am_order :: fact_seq,
                            % removes lazily (`ds.wm.fact_seq`)

                am_held  :: version_hash_table(fact_id,
                                list(pair(uint32, ds_value))),
                            % The facts held, and what each was indexed under: at
                            % removal the fact is gone from working memory.

                am_index :: map(uint32, version_hash_table(ds_value, fact_seq))
                            % Candidate slot -> value -> the facts holding it, in
                            % insertion order, for the slots some beta joins on. A
                            % bucket that empties is deleted.
            ).

:- func am_init = alpha_mem.

am_init = alpha_mem(empty_fact_seq,
    version_hash_table.init_default(fact_id_hash), map.init).

:- func am_facts(alpha_mem) = list(fact_id).

am_facts(AM) = fact_seq_members(am_holds(AM), AM ^ am_order).

:- pred am_holds(alpha_mem::in, fact_id::in) is semidet.

am_holds(AM, FactId) :-
    version_hash_table.search(AM ^ am_held, FactId, _).

:- func am_add(list(uint32), fact, alpha_mem) = alpha_mem.

am_add(Keys, Fact, AM0) = AM :-
    ( if am_holds(AM0, Fact ^ f_id) then
        AM = AM0
    else
        AM = am_add_new(Keys, Fact, AM0)
    ).

:- func am_add_new(list(uint32), fact, alpha_mem) = alpha_mem.

am_add_new(Keys, Fact, AM0) = AM :-
    FactId = Fact ^ f_id,
    list.filter_map(
        (pred(K::in, (K - V)::out) is semidet :-
            array.semidet_lookup(Fact ^ f_slots, uint32.cast_to_int(K), V),
            % A NaN is not indexed: `==` never admits one, and a NaN does not
            % unify with itself, so no removal could clear its entry.
            not ( V = float(F), float.is_nan(F) )),
        Keys, KeyVals),
    AM = alpha_mem(
        fact_seq_add(FactId, AM0 ^ am_order),
        version_hash_table.set(AM0 ^ am_held, FactId, KeyVals),
        list.foldl(index_add(FactId), KeyVals, AM0 ^ am_index)).

:- func index_add(fact_id, pair(uint32, ds_value),
                  map(uint32, version_hash_table(ds_value, fact_seq)))
    = map(uint32, version_hash_table(ds_value, fact_seq)).

index_add(FactId, Slot - Value, M0) = M :-
    ByValue0 = ( if map.search(M0, Slot, B) then B
                 else version_hash_table.init_default(value_hash_int) ),
    Prior = ( if version_hash_table.search(ByValue0, Value, L) then L
              else empty_fact_seq ),
    M = map.set(M0, Slot,
        version_hash_table.set(ByValue0, Value, fact_seq_add(FactId, Prior))).

:- func am_remove(alpha_mem, fact_id) = alpha_mem.

am_remove(AM0, FactId) = AM :-
    ( if version_hash_table.search(AM0 ^ am_held, FactId, KeyVals) then
        Held = version_hash_table.delete(AM0 ^ am_held, FactId),
        IsLive = (pred(I::in) is semidet :-
            version_hash_table.search(Held, I, _)),
        index_del(IsLive, KeyVals, AM0 ^ am_index, Index),
        AM = alpha_mem(fact_seq_drop(IsLive, AM0 ^ am_order), Held, Index)
    else
        AM = AM0
    ).

    % `IsLive` already answers false for the fact.
    %
:- pred index_del(pred(fact_id)::in(pred(in) is semidet),
                  list(pair(uint32, ds_value))::in,
                  map(uint32, version_hash_table(ds_value, fact_seq))::in,
                  map(uint32, version_hash_table(ds_value, fact_seq))::out)
    is det.

index_del(_, [], !M).
index_del(IsLive, [Slot - Value | KeyVals], !M) :-
    ( if
        map.search(!.M, Slot, ByValue0),
        version_hash_table.search(ByValue0, Value, Seq0)
    then
        Seq = fact_seq_drop(IsLive, Seq0),
        ( if fact_seq_count(Seq) = 0 then
            ByValue = version_hash_table.delete(ByValue0, Value)
        else
            ByValue = version_hash_table.set(ByValue0, Value, Seq)
        ),
        !:M = map.det_update(!.M, Slot, ByValue)
    else
        true
    ),
    index_del(IsLive, KeyVals, !M).

    % For the add path: an empty memory allocates its tables.
:- func alpha_mem_of(rete_state, uint32) = alpha_mem.

alpha_mem_of(S, Key) =
    ( if map.search(S ^ rs_alpha, Key, AM) then AM else am_init ).

:- pred alpha_put(uint32::in, alpha_mem::in,
                  rete_state::in, rete_state::out) is det.

alpha_put(Key, AM, !S) :-
    !S ^ rs_alpha := map.set(!.S ^ rs_alpha, Key, AM).

%-----------------------------------------------------------------------------%
% The join index
%-----------------------------------------------------------------------------%

    % An equality between a candidate slot and a token slot, in either operand
    % order. A bucket is found by unification on `ds_value`: for a float that is IEEE
    % equality, and `value_hash_int` gives both zeros one hash.
    %
:- type join_key
    --->    join_key(
                jk_cand  :: slot_index,     % the slot on the arriving fact
                jk_fact  :: fact_index,     % which token fact carries the other
                jk_slot  :: slot_read       % and which of its slots
            ).

    % [IRET.7.5.1]: the beta's first usable equality, kept only where it is decided:
    % both its slots non-nullable and not `Json` by their declared schemas, so the
    % comparison answers `true` or `false` and raises nothing. Probing skips every
    % pair whose keys differ, which is sound only where the equality would have
    % answered a plain `false`; an undecided key's `null` or fault would be lost
    % ([IRET.7.6], [LERR.1.4.11]). A beta with no decided key joins against its whole
    % right memory. libds decides the same, once per node (rete/beta.c,
    % `eq_key_decided`). The index narrows the candidates; `join_against` still runs
    % the full `join_verdict`.
    %
    %@spec [IRET.7.5.1]
:- func iret_7_5_1_join_key(list(schema), beta_node, map(uint32, join_key))
    = map(uint32, join_key).

iret_7_5_1_join_key(Schemas, Beta, Keys) =
    ( if
        list.filter_map(usable_equality, Beta ^ bn_tests, [K | _]),
        decided_slot(Schemas, Beta ^ bn_right ^ an_schema, K ^ jk_cand),
        K ^ jk_fact = token_fact(I),
        list.index0(token_alphas(Beta), I, Alpha),
        K ^ jk_slot = slot(TokSlot),
        decided_slot(Schemas, Alpha ^ an_schema, TokSlot)
    then
        map.set(Keys, node_id_value(Beta ^ bn_id), K)
    else
        Keys
    ).

    % The slot of the named schema is neither nullable ([LNUL.3.1]) nor `Json`.
    %
:- pred decided_slot(list(schema)::in, schema_name::in, slot_index::in)
    is semidet.

decided_slot(Schemas, Name, Slot) :-
    list.find_first_match(
        ( pred(S::in) is semidet :- S ^ s_name = Name ), Schemas, Schema),
    list.find_first_match(
        ( pred(C::in) is semidet :- C ^ sc_index = Slot ),
        slot_commons(Schema), Common),
    Common ^ sc_nullable = non_null,
    Common ^ sc_kind \= k_json.

    % The alphas whose facts a token reaching this beta carries, in token order:
    % each positive ancestor's, the root's first. A NOT node adds no fact.
    %
:- func token_alphas(beta_node) = list(alpha_node).

token_alphas(Beta) =
    ( if Beta ^ bn_parent = yes(Parent) then
        token_alphas(Parent)
            ++ ( if Parent ^ bn_negative = no then [Parent ^ bn_right] else [] )
    else
        []
    ).

:- pred usable_equality(expr::in, join_key::out) is semidet.

usable_equality(e_binop(op_eq, L, R), Key) :-
    ( if
        L = e_slot(candidate, slot(CandL)),
        R = e_slot(TokFactL, TokSlotL),
        TokFactL \= candidate
    then
        Key = join_key(CandL, TokFactL, TokSlotL)
    else
        R = e_slot(candidate, slot(CandR)),
        L = e_slot(TokFactR, TokSlotR),
        TokFactR \= candidate,
        Key = join_key(CandR, TokFactR, TokSlotR)
    ).

    % The candidates a token could join with: the whole memory unless the shape is
    % an indexable equality, the slot is indexed and the token supplies a value.
    %
:- func right_candidates(net_index, match_ctx, rete_state, beta_node, token)
    = list(fact).

right_candidates(Index, Ctx, S, Beta, Token) = Facts :-
    ( if map.search(S ^ rs_alpha, node_id_value(Beta ^ bn_right ^ an_id), AM)
    then
        Facts = right_candidates_in(Index, Ctx, AM, Beta, Token)
    else
        Facts = []
    ).

:- func right_candidates_in(net_index, match_ctx, alpha_mem, beta_node, token)
    = list(fact).

right_candidates_in(Index, Ctx, AM, Beta, Token) = Facts :-
    ( if
        % Positive betas only: a negated pattern must also test the candidates
        % whose key makes the equality `null` [LNUL.4.7].
        Beta ^ bn_negative = no,
        map.search(Index ^ ni_join_keys, node_id_value(Beta ^ bn_id), JK),
        token_key_value(Ctx, Token, JK, Value),
        map.search(AM ^ am_index, slot_index_value(JK ^ jk_cand), ByValue)
    then
        % In insertion order, as `am_facts` returns the whole memory.
        Ids = ( if version_hash_table.search(ByValue, Value, Bucket)
                then fact_seq_members(am_holds(AM), Bucket)
                else [] ),
        Facts = list.filter_map(resolve(Ctx), Ids)
    else
        Facts = list.filter_map(resolve(Ctx), am_facts(AM))
    ).

:- pred token_key_value(match_ctx::in, token::in, join_key::in,
                        ds_value::out) is semidet.

token_key_value(Ctx, Token, JK, Value) :-
    JK ^ jk_fact = token_fact(I),
    list.index0(Token ^ t_facts, I, FactId),
    lookup_fact(Ctx ^ mc_wm, FactId, Fact),
    JK ^ jk_slot = slot(Slot),
    array.semidet_lookup(Fact ^ f_slots,
        uint32.cast_to_int(slot_index_value(Slot)), Value).

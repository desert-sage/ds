% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.fact_receive -- a FactExternal from another tier, asserted here
% (NCBK.10.4, RFCS.23.7).
%
% - Two phases, and the first changes nothing: every node is decoded, checked
%   and resolved before the first assert, since a conflict at any depth refuses
%   the whole record. The plan is post-order, RFCS.23.7's "innermost first".
%
% - The nesting cap first, over the whole record. Then per node: a schema name,
%   the schema, its hash, the field count, then each slot in declaration order.
%   The order decides which refusal a record gets.
%
% - RFCS.23.7's steps 1 to 3 are for nested nodes; the record's own fact is
%   asserted as a host's is. An earlier copy in the record counts as live, after
%   every fact that is live already. Of several equal live facts, the lowest
%   fact id. "Equal" is `ds.wm.unchanged`; the key comparison is the upsert's
%   (`ds.schema.project_identity`).
%
% - One FactExternal is one input: one sample, after the first phase admits the
%   record, and each fact a host assert inside that step. The fault facts are
%   asserted once, as the call ends.
%
% - Only a halt stops the second phase: what the asserts' door would refuse in a
%   value is judged in the plan (`plan_judged`), so the record is refused whole.
%
% - A record may name the engine's schemas, less the compiler-synthesised ones.
%-----------------------------------------------------------------------------%

:- module ds.fact_receive.
:- interface.

:- import_module ds.chrono.
:- import_module ds.engine.
:- import_module ds.events.
:- import_module ds.fact.
:- import_module ds.fault.
:- import_module ds.id.

:- import_module bitmap.
:- import_module list.
:- import_module maybe.

    % Why a record was refused before anything was asserted.
    %
:- type external_refusal
    --->    xr_parse                    % DS_ERR_PARSE
    ;       xr_schema_unknown           % DS_ERR_SCHEMA_UNKNOWN
    ;       xr_schema_hash_mismatch     % DS_ERR_SCHEMA_HASH_MISMATCH
    ;       xr_fact_ref_conflict        % DS_ERR_FACT_REF_CONFLICT
    ;       xr_slot_type_mismatch       % DS_ERR_SLOT_TYPE_MISMATCH
    ;       xr_nan_rejected             % DS_ERR_NAN_REJECTED
    ;       xr_json_limit               % DS_ERR_JSON_LIMIT
    ;       xr_time_range               % DS_ERR_TIME_RANGE
    ;       xr_inval                    % DS_ERR_INVAL
    ;       xr_contract_breach          % DS_ERR_CONTRACT_BREACH
    ;       xr_halted(engine_error).    % DS_ERR_ENGINE_HALTED

:- type external_result
    --->    ext_asserted
    ;       ext_refused(external_refusal)
            % The first phase refused the record: nothing changed.
    ;       ext_stopped(assert_result).
            % An assert of the second phase did not take its fact, because an
            % earlier one halted the engine, or the step's `initial` block refused
            % it ([LGRA.24.3]). The facts before it stand.

    % `Effects` are the asserts' own, in order. The delivery is bracketed
    % (`ds.events.host_input`, RFCS.24.1) from after its TICK to the end of its
    % asserts, before the fault-fact drain.
    %
:- pred assert_external(bitmap::in, external_result::out,
                        list(effect)::out, engine::in, engine::out) is det.

    % The same delivery, as a replayer makes it (RFCS.24.2): `Ttl` on the received
    % fact, and the handles of the facts asserted in RFCS.24.3's order.
    %
:- pred assert_external_with(bitmap::in, maybe(duration)::in,
                             external_result::out, list(fact_id)::out,
                             list(effect)::out, engine::in, engine::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module ds.fact_external.
:- import_module ds.intern.
:- import_module ds.json.
:- import_module ds.json_text.
:- import_module ds.kind.
:- import_module ds.schema.
:- import_module ds.value.
:- import_module ds.wire.
:- import_module ds.wm.

:- import_module array.
:- import_module bool.
:- import_module int.
:- import_module map.
:- import_module require.
:- import_module uint8.
:- import_module uint64.

%-----------------------------------------------------------------------------%
% The plan
%-----------------------------------------------------------------------------%

:- type pvalue
    --->    pv_value(ds_value)      % Int, Float, Bool, Bytes, Json, null
    ;       pv_string(string)       % interned when its fact is asserted
    ;       pv_ref(int)             % a fact reference: the node it names
    ;       pv_no_target(ds_value).
            % RFCS.23.7: KIND_NULL in a fact-reference slot, with the value the
            % slot stores: `null` if it is nullable, else a reference to id 0,
            % which names no fact.

:- type node
    --->    node(
                n_schema   :: schema,
                n_values   :: list(pvalue),      % declaration order
                n_live     :: maybe(fact_id),    % equal to this live fact
                n_same_as  :: maybe(int)         % equal to this earlier node
            ).

:- type plan
    --->    plan(
                p_nodes :: map(int, node),      % post-order index -> node
                p_count :: int
            ).

:- type planned(T)
    --->    planned(T, plan)
    ;       plan_refused(external_refusal).

:- type ctx
    --->    ctx(
                c_schemas :: list(schema),      % the schemas a record may name
                c_interns :: intern_table,
                c_wm      :: wm
            ).

%-----------------------------------------------------------------------------%

assert_external(Bytes, Result, Effects, !E) :-
    assert_external_with(Bytes, no, Result, _, Effects, !E).

assert_external_with(Bytes, Ttl, Result, Ids, Effects, !E) :-
    ( if engine_halted(!.E) = yes(Halt) then
        Result = ext_refused(xr_halted(Halt)),
        Ids = [],
        Effects = []
    else if
        decode_fact_external(Bytes, Raw),
        not nested_too_deep(Raw)
    then
        IT = engine_interns(!.E),
        Ctx = ctx(list.filter(receivable(IT), engine_schemas(!.E)), IT,
            engine_wm(!.E)),
        plan_node(Ctx, 0, yes, Raw, plan(map.init, 0), Planned0),
        ( if
            Planned0 = planned(Top0, Plan0),
            plan_judged(!.E, Ttl, Plan0, Top0, 0, Judged)
        then
            Planned = plan_refused(Judged)
        else if
            Planned0 = planned(_, _),
            nlfc_9_5_first_sample_out_of_range(!.E)
        then
            Planned = plan_refused(xr_time_range)
        else
            Planned = Planned0
        ),
        (
            Planned = plan_refused(Why),
            Result = ext_refused(Why),
            Ids = [],
            Effects = []
        ;
            Planned = planned(Top, Plan),
            input_step_begin(Tick, Raised, InitialRefused, !E),
            (
                InitialRefused = yes(Cap),
                % [LGRA.24.3]: the `initial` block refused this first step. Its
                % sample is recorded and nothing else.
                Result = ext_stopped(rejected(Cap)),
                Ids = [],
                input_step_end(Tick ++ lgra_24_3_after_input(Raised, []),
                    Effects, !E)
            ;
                InitialRefused = no,
                % A replayed window is from the input's sample; `plan_judged` has
                % held the deadline to the `Time` range.
                (
                    Ttl = yes(D),
                    Override = yes(add(engine_now(!.E), D))
                ;
                    Ttl = no,
                    Override = no
                ),
                assert_plan(Plan, Top, Override, 0, map.init, [], [], Result,
                    RevIds, Asserted, !E),
                Ids = list.reverse(RevIds),
                input_step_end(Tick ++ lgra_24_3_after_input(Raised,
                    [eff_input(hi_open(bitmap_list(Bytes)))]
                    ++ Asserted ++ [eff_input(hi_close)]), Effects, !E)
            )
        )
    else
        Result = ext_refused(xr_parse),
        Ids = [],
        Effects = []
    ).

:- func bitmap_list(bitmap) = list(uint8).

bitmap_list(BM) = list.map(
    (func(I) = uint8.cast_from_int(BM ^ bitmap.byte(I))),
    0 .. (bitmap.det_num_bytes(BM) - 1)).

    % RFCS.23.4's bound over the whole record, ahead of every check the plan makes.
    %
:- pred nested_too_deep(raw_fact_external::in) is semidet.

nested_too_deep(raw_too_deep).
nested_too_deep(raw_fact_external(_, _, Fields)) :-
    some [Arg, Sub] (
        list.member(Arg, Fields),
        Arg ^ ra_value = yes(fev_fact(Sub)),
        nested_too_deep(Sub)
    ).

:- pred receivable(intern_table::in, schema::in) is semidet.

receivable(IT, S) :-
    not synthetic(IT, S).

    % The first fact the record adds, from node `I` on, whose values refuse the
    % whole record, and why. `Ttl` reaches the received fact, `Top`, alone.
    %
    %@spec [NCBK.10.4]
:- pred plan_judged(engine::in, maybe(duration)::in, plan::in, int::in,
                    int::in, external_refusal::out) is semidet.

plan_judged(E, Ttl, Plan, Top, I, Why) :-
    map.search(Plan ^ p_nodes, I, Node),
    ( if I = Top then Window = Ttl else Window = no ),
    ( if
        Node ^ n_live = no,
        Node ^ n_same_as = no,
        ncbk_10_4_value_refused(E, Node ^ n_schema,
            list.map(planned_value, Node ^ n_values), Window, Refused)
    then
        Why = delivery_refusal_status(Refused)
    else
        plan_judged(E, Ttl, Plan, Top, I + 1, Why)
    ).

:- func delivery_refusal_status(delivery_refusal) = external_refusal.

delivery_refusal_status(dr_tz_row) = xr_inval.
delivery_refusal_status(dr_time_range) = xr_time_range.
delivery_refusal_status(dr_over_capacity) = xr_contract_breach.

%-----------------------------------------------------------------------------%
% The first phase: decode, check, resolve.
%-----------------------------------------------------------------------------%

:- pred plan_node(ctx::in, int::in, bool::in, raw_fact_external::in, plan::in,
                  planned(int)::out) is det.

plan_node(Ctx, Depth, Top, Raw, Plan0, Out) :-
    (
        Raw = raw_too_deep,
        % `assert_external_with` has already refused this (`nested_too_deep`).
        Out = plan_refused(xr_parse)
    ;
        Raw = raw_fact_external(Name, Hash, Fields),
        ( if Name = "" then
            Out = plan_refused(xr_parse)
        else if schema_named(Ctx, Name, Schema) then
            ( if
                schema_name_and_hash(Ctx ^ c_interns, Schema, _, Own),
                Own = Hash
            then
                Commons = slot_commons(Schema),
                ( if list.same_length(Fields, Commons) then
                    plan_slots(Ctx, Depth, Fields, Commons, Plan0, [],
                        SlotsOut),
                    (
                        SlotsOut = plan_refused(Why),
                        Out = plan_refused(Why)
                    ;
                        SlotsOut = planned(RevValues, Plan1),
                        Idx = Plan1 ^ p_count,
                        Node = node(Schema, list.reverse(RevValues), no, no),
                        Plan2 = plan(map.det_insert(Plan1 ^ p_nodes, Idx, Node),
                            Idx + 1),
                        (
                            Top = yes,
                            Out = planned(Idx, top_no_target(Ctx, Idx, Plan2))
                        ;
                            Top = no,
                            resolve(Ctx, Idx, Plan2, Out)
                        )
                    )
                else
                    Out = plan_refused(xr_parse)
                )
            else
                Out = plan_refused(xr_schema_hash_mismatch)
            )
        else
            Out = plan_refused(xr_schema_unknown)
        )
    ).

:- pred schema_named(ctx::in, string::in, schema::out) is semidet.

schema_named(Ctx, Name, Schema) :-
    list.find_first_match(named(Ctx ^ c_interns, Name), Ctx ^ c_schemas,
        Schema).

:- pred named(intern_table::in, string::in, schema::in) is semidet.

named(IT, Name, Schema) :-
    expand(IT, schema_name_ref(Schema ^ s_name), Name).

    % Each slot, in declaration order, takes the one field of its name. None,
    % or two, is malformed whatever the hash said.
    %
:- pred plan_slots(ctx::in, int::in, list(raw_arg)::in, list(slot_common)::in,
                   plan::in, list(pvalue)::in, planned(list(pvalue))::out)
    is det.

plan_slots(_, _, _, [], Plan, Acc, planned(Acc, Plan)).
plan_slots(Ctx, Depth, Fields, [SC | SCs], Plan0, Acc, Out) :-
    ( if
        expand(Ctx ^ c_interns, SC ^ sc_name, SlotName),
        list.filter(arg_named(SlotName), Fields) = [Arg]
    then
        plan_field(Ctx, Depth, SC, Arg, Plan0, FieldOut),
        (
            FieldOut = plan_refused(Why),
            Out = plan_refused(Why)
        ;
            FieldOut = planned(Value, Plan1),
            plan_slots(Ctx, Depth, Fields, SCs, Plan1, [Value | Acc], Out)
        )
    else
        Out = plan_refused(xr_parse)
    ).

:- pred arg_named(string::in, raw_arg::in) is semidet.

arg_named(Name, Arg) :-
    Arg ^ ra_name = Name.

    % A kind the slot does not take is the status the host assert would give; a
    % `oneof` member that is not the one the kind names is DS_ERR_PARSE.
    %
:- pred plan_field(ctx::in, int::in, slot_common::in, raw_arg::in, plan::in,
                   planned(pvalue)::out) is det.

plan_field(Ctx, Depth, SC, Arg, Plan0, Out) :-
    Value = Arg ^ ra_value,
    ( if kind_from_number(Arg ^ ra_kind, Kind) then
        (
            Kind = kind_null,
            ( if Value = no then
                ( if
                    % RFCS.23.7: a reference with no target, nullable or not.
                    SC ^ sc_kind = k_schema(_)
                then
                    ( if SC ^ sc_nullable = nullable then
                        Out = planned(pv_no_target(null), Plan0)
                    else
                        Out = planned(
                            pv_no_target(fact_ref(make_fact_id(0u64))), Plan0)
                    )
                else if SC ^ sc_nullable = nullable then
                    Out = planned(pv_value(null), Plan0)
                else
                    Out = plan_refused(xr_slot_type_mismatch)    % LNUL.3.1
                )
            else
                Out = plan_refused(xr_parse)
            )
        ;
            % RFCS.23.2: `kind_int` also carries a Time, Date or Duration slot's
            % integer (RDSC.5.5.8).
            Kind = kind_int,
            ( if not int_represented(SC ^ sc_kind) then
                Out = plan_refused(xr_slot_type_mismatch)
            else if Value = yes(fev_int(I)) then
                ( if
                    SC ^ sc_kind = k_date,
                    not ltim_1_2_2_date_in_range(I)
                then
                    Out = plan_refused(xr_time_range)
                else
                    Out = planned(pv_value(int(I)), Plan0)
                )
            else
                Out = plan_refused(xr_parse)
            )
        ;
            Kind = kind_float,
            ( if SC ^ sc_kind \= k_float then
                Out = plan_refused(xr_slot_type_mismatch)
            else if Value = yes(fev_float_bits(Bits)) then
                % `float_from_bits` reads a NaN as 0.0, so the bits decide.
                ( if nan_bits(Bits) then
                    Out = plan_refused(xr_nan_rejected)          % LEXP.4.2
                else
                    Out = planned(pv_value(float(float_from_bits(Bits))),
                        Plan0)
                )
            else
                Out = plan_refused(xr_parse)
            )
        ;
            Kind = kind_string,
            ( if SC ^ sc_kind \= k_string then
                Out = plan_refused(xr_slot_type_mismatch)
            else if Value = yes(fev_string(S)) then
                Out = planned(pv_string(S), Plan0)
            else
                Out = plan_refused(xr_parse)
            )
        ;
            Kind = kind_bool,
            ( if SC ^ sc_kind \= k_bool then
                Out = plan_refused(xr_slot_type_mismatch)
            else if Value = yes(fev_bool(B)) then
                Out = planned(pv_value(bool(B)), Plan0)
            else
                Out = plan_refused(xr_parse)
            )
        ;
            Kind = kind_json,
            ( if SC ^ sc_kind \= k_json then
                Out = plan_refused(xr_slot_type_mismatch)
            else if Value = yes(fev_json(Text)) then
                % The field's own text limit, not the host's (LGRA.5.8.6).
                ds.json_text.parse_with(ds.json_text.fx_limits, Text, Parsed),
                (
                    Parsed = refused(Why),
                    ( if Why = jr_limit(_) then
                        Out = plan_refused(xr_json_limit)
                    else
                        Out = plan_refused(xr_parse)
                    )
                ;
                    Parsed = parsed(J),
                    ( if J = j_null then
                        % A root-null document IS the canonical null
                        % (LNUL.3.4); a null slot travels as KIND_NULL.
                        Out = plan_refused(xr_slot_type_mismatch)
                    else
                        Out = planned(pv_value(json(J)), Plan0)
                    )
                )
            else
                Out = plan_refused(xr_parse)
            )
        ;
            Kind = kind_bytes,
            ( if SC ^ sc_kind \= k_bytes then
                Out = plan_refused(xr_slot_type_mismatch)
            else if Value = yes(fev_bytes(Bs)) then
                Out = planned(pv_value(bytes(bytes_bitmap(Bs))), Plan0)
            else
                Out = plan_refused(xr_parse)
            )
        ;
            Kind = kind_fact_ref,
            ( if SC ^ sc_kind = k_schema(RefName) then
                ( if Value = yes(fev_fact(Inner)) then
                    plan_node(Ctx, Depth + 1, no, Inner, Plan0, NodeOut),
                    (
                        NodeOut = plan_refused(Why),
                        Out = plan_refused(Why)
                    ;
                        NodeOut = planned(C, Plan1),
                        map.lookup(Plan1 ^ p_nodes, C, Target),
                        ( if Target ^ n_schema ^ s_name = RefName then
                            Out = planned(pv_ref(C), Plan1)
                        else
                            Out = plan_refused(xr_slot_type_mismatch)
                        )
                    )
                else
                    Out = plan_refused(xr_parse)
                )
            else
                Out = plan_refused(xr_slot_type_mismatch)
            )
        ;
            % A call argument's kind (RFCS.23.2): not a slot value.
            Kind = kind_encoded_fact,
            Out = plan_refused(xr_parse)
        )
    else
        Out = plan_refused(xr_parse)
    ).

:- func bytes_bitmap(list(uint8)) = bitmap.

bytes_bitmap(Bs) = BM :-
    fill_bytes(0, Bs, bitmap.init(list.length(Bs) * 8), BM).

:- pred fill_bytes(int::in, list(uint8)::in,
                   bitmap::bitmap_di, bitmap::bitmap_uo) is det.

fill_bytes(_, [], !BM).
fill_bytes(I, [B | Bs], !BM) :-
    bitmap.set_uint8(I, B, !BM),
    fill_bytes(I + 1, Bs, !BM).

%-----------------------------------------------------------------------------%
% RFCS.23.7 steps 1 to 3, for one nested node.
%-----------------------------------------------------------------------------%

:- pred resolve(ctx::in, int::in, plan::in, planned(int)::out) is det.

resolve(Ctx, Idx, Plan0, Out) :-
    map.lookup(Plan0 ^ p_nodes, Idx, X),
    ( if live_equal(Ctx, Plan0, X, Id) then
        % Step 1.
        Out = planned(Idx, set_node(Idx, X ^ n_live := yes(Id), Plan0))
    else if equal_earlier(Plan0, Idx, X, K) then
        % Step 1: one fact inlined twice.
        Out = planned(Idx, set_node(Idx, X ^ n_same_as := yes(K), Plan0))
    else if key_taken(Ctx, Plan0, Idx, X) then
        % Step 3.
        Out = plan_refused(xr_fact_ref_conflict)
    else
        % Step 2.
        Out = planned(Idx, Plan0)
    ).

:- func set_node(int, node, plan) = plan.

set_node(Idx, Node, Plan) =
    Plan ^ p_nodes := map.det_update(Plan ^ p_nodes, Idx, Node).

:- pred live_equal(ctx::in, plan::in, node::in, fact_id::out) is semidet.

live_equal(Ctx, Plan, X, Id) :-
    live_equal_fact(Ctx, Plan, X, Fact),
    Id = Fact ^ f_id.

:- pred live_equal_fact(ctx::in, plan::in, node::in, fact::out) is semidet.

live_equal_fact(Ctx, Plan, X, Fact) :-
    list.map(live_value(Ctx, Plan), X ^ n_values, Values),
    Schema = X ^ n_schema,
    Equal = list.filter(
        ( pred(F::in) is semidet :-
            Live = array.to_list(F ^ f_slots),
            Copy = array.from_list(
                copy_against(Ctx, X ^ n_values, Values, Live)),
            unchanged(Schema, F ^ f_slots, Copy)
        ),
        facts_of_schema(Ctx ^ c_wm, Schema ^ s_id)),
    Equal = [First | Rest],
    Fact = list.foldl(earlier, Rest, First).

    % The copy's values as compared with one live fact: a no-target slot takes
    % the live slot's value where that slot is null or its target has gone
    % (RFCS.23.7).
    %
:- func copy_against(ctx, list(pvalue), list(ds_value), list(ds_value))
    = list(ds_value).

copy_against(Ctx, Planned, Values, Live) = Out :-
    ( if
        Planned = [P | Ps],
        Values = [V | Vs],
        Live = [L | Ls]
    then
        ( if P = pv_no_target(_), live_no_target(Ctx, L) then
            Out = [L | copy_against(Ctx, Ps, Vs, Ls)]
        else
            Out = [V | copy_against(Ctx, Ps, Vs, Ls)]
        )
    else
        Out = []
    ).

:- pred live_no_target(ctx::in, ds_value::in) is semidet.

live_no_target(_, null).
live_no_target(Ctx, fact_ref(Id)) :-
    not lookup_fact(Ctx ^ c_wm, Id, _).

    % A no-target slot of the received fact takes the value an equal live fact's
    % slot holds, so the assert finds the two equal and is a no-op (RFCS.23.7).
    %
:- func top_no_target(ctx, int, plan) = plan.

top_no_target(Ctx, Idx, Plan) = Out :-
    map.lookup(Plan ^ p_nodes, Idx, X),
    ( if
        list.find_first_match(is_no_target, X ^ n_values, _),
        live_equal_fact(Ctx, Plan, X, Fact)
    then
        Values = taken_from_live(X ^ n_values, array.to_list(Fact ^ f_slots)),
        Out = set_node(Idx, X ^ n_values := Values, Plan)
    else
        Out = Plan
    ).

:- pred is_no_target(pvalue::in) is semidet.

is_no_target(pv_no_target(_)).

:- func taken_from_live(list(pvalue), list(ds_value)) = list(pvalue).

taken_from_live(Planned, Live) = Out :-
    ( if
        Planned = [P | Ps],
        Live = [L | Ls]
    then
        ( if P = pv_no_target(_) then
            Out = [pv_value(L) | taken_from_live(Ps, Ls)]
        else
            Out = [P | taken_from_live(Ps, Ls)]
        )
    else
        Out = Planned
    ).

:- func earlier(fact, fact) = fact.

earlier(A, B) =
    ( if fact_id_value(A ^ f_id) < fact_id_value(B ^ f_id) then A else B ).

    % A planned value as a live fact would hold it. FAILS where no live fact
    % can hold it: a String the intern table does not hold -- looked up, never
    % interned -- or a reference to a node this record has yet to assert.
    %
:- pred live_value(ctx::in, plan::in, pvalue::in, ds_value::out) is semidet.

live_value(_, _, pv_value(V), V).
live_value(Ctx, _, pv_string(S), str(Ref)) :-
    interned(Ctx ^ c_interns, S, Ref).
live_value(_, Plan, pv_ref(C), fact_ref(Id)) :-
    map.lookup(Plan ^ p_nodes, canon(Plan, C), Target),
    Target ^ n_live = yes(Id).
live_value(_, _, pv_no_target(V), V).

:- pred equal_earlier(plan::in, int::in, node::in, int::out) is semidet.

equal_earlier(Plan, Idx, X, K) :-
    list.find_first_match(equal_node(Plan, X), 0 .. (Idx - 1), K).

:- pred equal_node(plan::in, node::in, int::in) is semidet.

equal_node(Plan, X, K) :-
    map.lookup(Plan ^ p_nodes, K, Y),
    Y ^ n_schema ^ s_id = X ^ n_schema ^ s_id,
    Y ^ n_live = no,
    Y ^ n_same_as = no,
    pair_values(Plan, Y ^ n_values, X ^ n_values, VYs, VXs),
    unchanged(X ^ n_schema, array.from_list(VYs), array.from_list(VXs)).

    % Two planned value lists, as `unchanged` compares them: a String as its
    % text, which compares by content as an interned one would; a reference
    % pair as one id when the two resolve to one fact and two ids when not.
    %
:- pred pair_values(plan::in, list(pvalue)::in, list(pvalue)::in,
                    list(ds_value)::out, list(ds_value)::out) is semidet.

pair_values(_, [], [], [], []).
pair_values(Plan, [A | As], [B | Bs], [VA | VAs], [VB | VBs]) :-
    pair_value(Plan, A, B, VA, VB),
    pair_values(Plan, As, Bs, VAs, VBs).

:- pred pair_value(plan::in, pvalue::in, pvalue::in, ds_value::out,
                   ds_value::out) is det.

pair_value(Plan, A, B, VA, VB) :-
    VA = planned_value(A),
    ( if
        A = pv_ref(_),
        B = pv_ref(_),
        not planned_key_eq(Plan, A, B)
    then
        VB = fact_ref(make_fact_id(2u64))
    else
        VB = planned_value(B)
    ).

:- func planned_value(pvalue) = ds_value.

planned_value(pv_value(V)) = V.
planned_value(pv_string(S)) = text(S).
planned_value(pv_ref(_)) = fact_ref(make_fact_id(1u64)).
planned_value(pv_no_target(V)) = V.

    % Does a live fact, or a fact this record asserts ahead of this node, hold its
    % identity key? A key of no slots is the singleton, which every fact shares.
    %
:- pred key_taken(ctx::in, plan::in, int::in, node::in) is semidet.

key_taken(Ctx, Plan, Idx, X) :-
    X ^ n_schema ^ s_lifecycle = lc_logical(LSlots, _),
    Keys = key_indices(LSlots),
    (
        list.member(Fact, facts_of_schema(Ctx ^ c_wm, X ^ n_schema ^ s_id)),
        all [I] (
            list.member(I, Keys)
        =>
            live_key_eq(Ctx, Plan, list.det_index0(X ^ n_values, I),
                array.lookup(Fact ^ f_slots, I))
        )
    ;
        list.member(K, 0 .. (Idx - 1)),
        map.lookup(Plan ^ p_nodes, K, Y),
        Y ^ n_schema ^ s_id = X ^ n_schema ^ s_id,
        Y ^ n_live = no,
        Y ^ n_same_as = no,
        all [I] (
            list.member(I, Keys)
        =>
            planned_key_eq(Plan, list.det_index0(X ^ n_values, I),
                list.det_index0(Y ^ n_values, I))
        )
    ).

:- func key_indices(list(logical_slot)) = list(int).

key_indices([]) = [].
key_indices([S | Ss]) =
    ( if S ^ ls_role = role_key then
        [slot_index_int(S ^ ls_common ^ sc_index) | key_indices(Ss)]
    else
        key_indices(Ss)
    ).

:- pred live_key_eq(ctx::in, plan::in, pvalue::in, ds_value::in) is semidet.

live_key_eq(_, _, pv_value(V), Live) :-
    V = Live.
live_key_eq(Ctx, _, pv_string(S), Live) :-
    Live = str(Ref),
    expand(Ctx ^ c_interns, Ref, S).
live_key_eq(_, Plan, pv_ref(C), Live) :-
    map.lookup(Plan ^ p_nodes, canon(Plan, C), Target),
    Target ^ n_live = yes(Id),
    Live = fact_ref(Id).
live_key_eq(Ctx, _, pv_no_target(_), Live) :-
    live_no_target(Ctx, Live).

:- pred planned_key_eq(plan::in, pvalue::in, pvalue::in) is semidet.

planned_key_eq(_, pv_value(V), pv_value(W)) :-
    V = W.
planned_key_eq(_, pv_string(S), pv_string(T)) :-
    S = T.
planned_key_eq(Plan, pv_ref(A), pv_ref(B)) :-
    CA = canon(Plan, A),
    CB = canon(Plan, B),
    map.lookup(Plan ^ p_nodes, CA, NA),
    (
        NA ^ n_live = no,
        CA = CB
    ;
        NA ^ n_live = yes(IA),
        map.lookup(Plan ^ p_nodes, CB, NB),
        NB ^ n_live = yes(IA)
    ).
planned_key_eq(_, pv_no_target(V), pv_no_target(W)) :-
    V = W.

    % The node a reference resolves to: through `n_same_as` to the first node
    % that stands for that fact.
    %
:- func canon(plan, int) = int.

canon(Plan, I) =
    ( if
        map.search(Plan ^ p_nodes, I, Node),
        Node ^ n_same_as = yes(J)
    then
        canon(Plan, J)
    else
        I
    ).

%-----------------------------------------------------------------------------%
% The second phase: each fact the record adds, through the host assert.
%-----------------------------------------------------------------------------%

    % `Top` is the received fact's node, the plan's last, and the only one
    % `Override` reaches. `RevIds` collects, newest first, the handle of each
    % fact asserted -- a no-op's standing fact included. The plan judged each
    % reference once; these asserts do not judge one again ([RFCS.23.7]), so a
    % target an earlier assert removed stops nothing.
    %
:- pred assert_plan(plan::in, int::in, maybe(instant)::in, int::in,
                    map(int, fact_id)::in, list(fact_id)::in,
                    list(effect)::in, external_result::out,
                    list(fact_id)::out, list(effect)::out,
                    engine::in, engine::out) is det.

assert_plan(Plan, Top, Override, I, Done, RevIds0, Effects0, Result, RevIds,
        Effects, !E) :-
    ( if map.search(Plan ^ p_nodes, I, Node) then
        ( if
            ( Node ^ n_live = yes(_)
            ; Node ^ n_same_as = yes(_)
            )
        then
            assert_plan(Plan, Top, Override, I + 1, Done, RevIds0, Effects0,
                Result, RevIds, Effects, !E)
        else
            list.map_foldl(slot_value(Plan, Done), Node ^ n_values, Values,
                !E),
            ( if I = Top then Own = Override else Own = no ),
            host_assert_in_step(Node ^ n_schema, Values, Own, AR, Asserted,
                !E),
            Effects1 = Effects0 ++ Asserted,
            ( if ( AR = inserted(Id) ; AR = noop(Id) ; AR = replaced(_, Id) )
            then
                assert_plan(Plan, Top, Override, I + 1, map.set(Done, I, Id),
                    [Id | RevIds0], Effects1, Result, RevIds, Effects, !E)
            else
                Result = ext_stopped(AR),
                RevIds = RevIds0,
                Effects = Effects1
            )
        )
    else
        Result = ext_asserted,
        RevIds = RevIds0,
        Effects = Effects0
    ).

:- pred slot_value(plan::in, map(int, fact_id)::in, pvalue::in,
                   ds_value::out, engine::in, engine::out) is det.

slot_value(_, _, pv_value(V), V, !E).
slot_value(_, _, pv_no_target(V), V, !E).
slot_value(_, _, pv_string(S), str(Ref), !E) :-
    engine_intern(S, Ref, !E).
slot_value(Plan, Done, pv_ref(C), fact_ref(Id), !E) :-
    K = canon(Plan, C),
    ( if
        map.search(Plan ^ p_nodes, K, Target),
        Target ^ n_live = yes(Live)
    then
        Id = Live
    else if map.search(Done, K, Asserted) then
        Id = Asserted
    else
        % The plan is post-order, so a target was live or asserted by now. It may
        % since have gone ([RFCS.23.7]); the slot still names it.
        unexpected($pred, "a reference to a node not yet asserted")
    ).

%-----------------------------------------------------------------------------%
:- end_module ds.fact_receive.
%-----------------------------------------------------------------------------%

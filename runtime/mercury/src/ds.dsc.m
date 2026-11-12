% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.dsc -- the artefact loader.
%
% `load_dsc` is a pure function with no engine argument, so a load is atomic:
% everything is built in a staging structure and handed over whole. A failed load
% leaves no engine to spend ([RDSC.9.8]): `load_failed` carries no `program`.
%
% Rule metadata precedes the `TerminalNode` atoms it names, so it accumulates and
% resolves at the end ([RDSC.8.3]).
%-----------------------------------------------------------------------------%

:- module ds.dsc.
:- interface.

:- import_module ds.action.
:- import_module ds.atom.
:- import_module ds.capability.
:- import_module ds.contract.
:- import_module ds.series.
:- import_module ds.fault.
:- import_module ds.intern.
:- import_module ds.id.
:- import_module ds.network.
:- import_module ds.rules.
:- import_module ds.schema.
:- import_module ds.service.
:- import_module ds.value.
:- import_module maybe.
:- import_module assoc_list.
:- import_module bitmap.
:- import_module bool.
:- import_module list.
:- import_module map.
:- import_module uint32.
:- import_module uint8.

%-----------------------------------------------------------------------------%

    % A loaded artefact. Abstract: cross-references are resolved into terms at
    % construction, so it cannot represent a dangling one.
    %
:- type program.

:- type load_result
    --->    loaded(program)
    ;       load_failed(load_error).

:- pred load_dsc(bitmap::in, load_result::out) is det.

%-----------------------------------------------------------------------------%
% What a loaded artefact reports
%-----------------------------------------------------------------------------%

:- type dsc_header
    --->    dsc_header(
                dh_compiler_version :: string,  % the load gate [LDET.1.10]
                dh_sha256       :: list(uint8),
                dh_capabilities :: list(int),
                            % Field 13, as the wire carries it.
                dh_dialect_sha  :: list(uint8),
                dh_rt_config_sha :: list(uint8),
                            % 32 bytes on a `+realtime` DSC, otherwise none.
                dh_fault_fact_sites :: uint32
                            % [RDSC.3.10]; absent reads as 0.
            ).

:- func header(program) = dsc_header.

    % The `<major>.<minor>.` prefix a `compiler_version` must begin with to load
    % [LDET.1.10].
    %
:- func ds_version_series = string.

    % Whether `dsc_sha256` matches the bytes with that field zeroed [RDSC.3.6].
    % A recording's `StreamHeader.dsc_hash` is this field, copied ([RBND.3.1]).
    % Fails too on a bitmap that is not a whole number of bytes.
    %
:- pred verify_self_hash(bitmap::in, dsc_header::in) is semidet.

    % In encounter order.
    %
:- func atoms(program) = list(atom_id).

:- type skip
    --->    skip_named(atom_id, int)
            % An atom the loader steps over by name ([RDSC.9.4]), and its
            % offset: `DocString`, and the test and oracle atoms ([RDSC.7.6]).
    ;       skip_code(int).
            % A `CompiledCode` atom ([RDSC.4c.3]), and its offset.

    % In encounter order.
    %
:- func skips(program) = list(skip).

    % The atoms `skip_named` records, with their offsets.
    %
:- func skipped_at(program) = list({atom_id, int}).

    % In `module_id`-then-declaration order.
    %
:- func schemas(program) = list(schema).

:- func network(program) = network.

    % In terminal order, each list in emission order, with one entry per terminal
    % node.
    %
:- func action_lists(program) = assoc_list(node_id, list(action)).

:- func actions_for(program, node_id) = list(action).

    % In terminal order.
    %
:- func rule_metas(program) = list(rule_meta).

    % In emission order. A declared series nothing reads emits no atom.
    %
:- func series_decls(program) = list(series_decl).

    % It becomes the engine's table ([RTCT.12.4]).
    %
:- func interns(program) = intern_table.

    % [RTCT.6.6].
    %
:- func contract_of(program) = maybe(contract).

    % [LCRS.6.2.4]: the schemas whose host assert supersedes the live answers
    % with its `corr`, one per `ServiceDef` naming one.
    %
:- func response_schemas(program) = list(string).

    % [LCRS.6.2.1]: each service name and its response schema, `""` for `no
    % response`, in artefact order, for a call's own supersede. A service with no
    % name is left out.
    %
:- func service_responses(program) = assoc_list(string, string).

    % [LADP.8.2.1]: for a host; nothing the engine computes reads it.
    %
:- func service_kwargs(program) = assoc_list(string, list(service_kwarg)).

    % [NDBG.2.4]: one service the program declares.
    %
:- type svcd
    --->    svcd(
                sv_name        :: string,
                sv_response    :: string,
                sv_no_response :: bool,
                sv_kwargs      :: list(service_kwarg)
            ).

    % In artefact order, with no nameless ones.
    %
:- func declared_services(program) = list(svcd).

    % Of two `ServiceDef`s naming one service the later is found, as the call path
    % takes the later's response.
    %
:- pred search_service(program::in, string::in, svcd::out) is semidet.

    % One item of an `initial:` block ([LGRA.24]). Raw, not resolved into values:
    % a `String` value interns into the engine's table. One that does not fit is
    % dropped where `ds.engine.lgra_24_3_item` applies it.
    %
:- type initial_item
    --->    initial_fact(
                ifa_clip   :: uint32,
                ifa_schema :: string,
                ifa_slots  :: assoc_list(string, test_value),
                ifa_order  :: uint32
            )
    ;       initial_seed(
                ise_clip  :: uint32,
                ise_key   :: string,
                ise_value :: test_value,
                ise_order :: uint32
            ).

    % In [LGRA.24.3]'s order: by `module_id`, then `source_order`.
    %
:- func initial_items(program) = list(initial_item).

    % The CapabilityInfo atom ([RDSC.16.2]).
    %
:- type capb
    --->    capb(
                cb_enabled  :: settings,
                cb_requires :: settings
            ).

:- func capb_of(program) = capb.

    % [NLFC.10.1]: this runtime has them all.
    %
:- func build_capabilities = settings.

    % [NLFC.10.2].
    %
:- type admission
    --->    admit_either
    ;       admit_true_only
    ;       admit_false_only.

    % A capability with no entry admits either setting.
    %
:- type admission_policy == map(capability, admission).

    % `load_dsc` is this with the empty policy. Refused with `lek_not_admitted`,
    % in [RDSC.16.2.9]'s place.
    %
:- pred load_dsc_admitted(admission_policy::in, bitmap::in, load_result::out)
    is det.

%-----------------------------------------------------------------------------%
% Source attribution
%-----------------------------------------------------------------------------%

    % [RDSC.14.2]: the path is for display; `src_clip`, the `module_id`, is the
    % join.
    %
:- type ds_source
    --->    ds_source(
                src_clip :: uint32,
                src_file :: string,
                src_text :: string
            ).

    % [RDSC.14.3]: for beta and terminal nodes.
    %
:- type line_span
    --->    line_span(
                ls_node :: uint32,
                ls_line :: uint32,      % 1-based
                ls_col  :: uint32,      % 1-based
                ls_clip :: uint32
            ).

    % In artefact order.
    %
:- func sources(program) = list(ds_source).
:- func line_spans(program) = list(line_span).

    % The first in artefact order.
    %
:- pred line_span_for(program::in, uint32::in, line_span::out) is semidet.

:- pred source_file(program::in, uint32::in, string::out) is semidet.

    % [RDSC.5.7], in artefact order.
    %
:- func schema_sources(program) = assoc_list(string, source_pos).

:- pred schema_source_for(program::in, string::in, source_pos::out)
    is semidet.

    % Not counted by `skipped/1`: a `CompiledCode` atom is recognised and declined
    % ([RDSC.4c.3]).
    %
:- func skipped_code(program) = int.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.binding.
:- import_module ds.chrono.
:- import_module ds.dsc_action.
:- import_module ds.dsc_network.
:- import_module ds.json.
:- import_module pair.
:- import_module ds.dsc_rules.
:- import_module ds.expr.
:- import_module ds.builtins.
:- import_module ds.dsc_schema.
:- import_module ds.sha256.
:- import_module ds.version.
:- import_module set.
:- import_module ds.re2.
:- import_module ds.wire.
:- import_module int.
:- import_module int64.
:- import_module require.
:- import_module string.
:- import_module uint64.
:- import_module unit.

%-----------------------------------------------------------------------------%

:- type program
    --->    program(
                p_header  :: dsc_header,
                p_atoms   :: list(atom_id),
                p_skipped :: list(skip),
                p_schemas :: list(schema),
                p_network :: network,
                p_actions :: assoc_list(node_id, list(action)),
                p_rules :: list(rule_meta),
                p_series :: list(series_decl),
                p_interns :: intern_table,

                p_capb :: capb,

                p_contract :: maybe(contract),

                p_sources :: list(ds_source),
                p_spans   :: list(line_span),
                p_schema_sources :: assoc_list(string, source_pos),
                            % Not on `ds.schema.schema`, which the compiler
                            % shares: a position is attribution.

                p_services :: list(svcd),
                            % Nameless ones included.

                p_initial :: list(initial_item)
            ).

header(P) = P ^ p_header.
response_schemas(P) = list.filter(
    ( pred(R::in) is semidet :- R \= "" ),
    list.map(( func(S) = S ^ sv_response ), P ^ p_services)).
service_responses(P) = list.filter_map(
    ( func(S) = (S ^ sv_name - S ^ sv_response) is semidet :-
        S ^ sv_name \= "" ),
    P ^ p_services).
service_kwargs(P) = list.filter_map(
    ( func(S) = (S ^ sv_name - S ^ sv_kwargs) is semidet :-
        S ^ sv_name \= "" ),
    P ^ p_services).
declared_services(P) = list.filter(
    ( pred(S::in) is semidet :- S ^ sv_name \= "" ),
    P ^ p_services).
search_service(P, Name, Found) :-
    list.filter(( pred(S::in) is semidet :- S ^ sv_name = Name ),
        declared_services(P), Hits),
    list.last(Hits, Found).
atoms(P) = P ^ p_atoms.
skips(P) = P ^ p_skipped.
skipped_at(P) = list.filter_map(
    ( func(S) = {A, Offset} is semidet :-
        S = skip_named(A, Offset) ),
    P ^ p_skipped).
skipped_code(P) = list.length(list.filter(
    ( pred(S::in) is semidet :- S = skip_code(_) ), P ^ p_skipped)).
schemas(P) = P ^ p_schemas.
network(P) = P ^ p_network.
action_lists(P) = P ^ p_actions.
rule_metas(P) = P ^ p_rules.
series_decls(P) = P ^ p_series.
interns(P) = P ^ p_interns.
contract_of(P) = P ^ p_contract.
capb_of(P) = P ^ p_capb.
build_capabilities = set.list_to_set(all_capabilities).
sources(P) = P ^ p_sources.
line_spans(P) = P ^ p_spans.
initial_items(P) = P ^ p_initial.

line_span_for(P, Node, Span) :-
    list.find_first_match((pred(S::in) is semidet :- S ^ ls_node = Node),
        P ^ p_spans, Span).

source_file(P, Clip, File) :-
    list.find_first_match((pred(S::in) is semidet :- S ^ src_clip = Clip),
        P ^ p_sources, Source),
    File = Source ^ src_file.

schema_sources(P) = P ^ p_schema_sources.

schema_source_for(P, Name, Pos) :-
    assoc_list.search(schema_sources(P), Name, Pos).

%-----------------------------------------------------------------------------%
% Staging
%-----------------------------------------------------------------------------%

:- type staging
    --->    staging(
                st_header  :: maybe_header,
                st_atoms   :: list(atom_id),        % reverse encounter order
                st_skipped :: list(skip),           % reverse
                st_schema :: schema_staging,
                st_network :: network_staging,
                st_rules :: rules_staging,
                st_series :: list(series_decl),     % ARRIVAL order
                st_interns :: intern_table,

                st_sources :: list(ds_source),      % reverse
                st_spans   :: list(line_span),      % reverse
                st_schema_sources :: assoc_list(string, source_pos), % reverse
                st_services :: list(svcd),          % reverse
                st_initial :: list(initial_item),   % reverse

                st_capb    :: maybe(capb),
                            % Checked when it arrives ([RDSC.16.2.7]).

                st_policy  :: admission_policy,

                st_contract :: maybe(contract)
                            % The hash cross-check needs the network, which
                            % arrives later ([RTCT.6.4]).
            ).

:- type maybe_header
    --->    no_header
    ;       got_header(dsc_header).

:- func init_staging(admission_policy) = staging.

init_staging(Policy) = staging(no_header, [], [], init_schema_staging,
    init_network_staging, init_rules_staging, [],
    init_interns, [], [], [], [], [], no, Policy, no).

%-----------------------------------------------------------------------------%

load_dsc(BM, Result) :-
    load_dsc_admitted(map.init, BM, Result).

load_dsc_admitted(Policy, BM, Result) :-
    R0 = init_reader(BM),
    walk(BM, R0, init_staging(Policy), Result).

    % `BM` is for the self-hash check at the header [RDSC.3.6].
    %
:- pred walk(bitmap::in, reader::in, staging::in, load_result::out) is det.

walk(BM, R0, St0, Result) :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        commit(St0, Result)
    ;
        FrameResult = fr_error(AtomError, Offset),
        First = ( if St0 ^ st_header = no_header then yes else no ),
        Result = load_failed(frame_error(First, AtomError, Offset))
    ;
        FrameResult = fr_ok(Frame),
        dispatch(BM, Frame, St0, Step),
        (
            Step = continue(St1),
            walk(BM, R1, St1, Result)
        ;
            Step = fail_load(E),
            Result = load_failed(rdsc_9_5_names_atom(Frame, E))
        )
    ).

    %@spec [RDSC.9.5]
:- func rdsc_9_5_names_atom(frame, load_error) = load_error.

rdsc_9_5_names_atom(Frame, E) =
    ( if Frame ^ fr_atom = known(A), E ^ le_atom = no then
        E ^ le_atom := yes(atom_message(A))
    else
        E
    ).

:- type step
    --->    continue(staging)
    ;       fail_load(load_error).

%-----------------------------------------------------------------------------%

:- pred dispatch(bitmap::in, frame::in, staging::in, step::out) is det.

dispatch(BM, Frame, St0, Step) :-
    ( if
        St0 ^ st_header = no_header,
        Frame ^ fr_atom \= known(at_dsc_header)
    then
        % A number with no registry entry is no header either, and its frame is
        % malformed ([RDSC.11.1], [RFCS.19.3]): the first frame's code.
        ( if Frame ^ fr_atom = unknown(_) then
            Clause = "RDSC.11.1"
        else
            Clause = "RDSC.9.2"
        ),
        Step = fail_load(err(lek_bad_first_atom, Frame ^ fr_offset, Clause))
    else
        dispatch_atom(BM, Frame, St0, Step)
    ).

:- pred dispatch_atom(bitmap::in, frame::in, staging::in, step::out) is det.

dispatch_atom(BM, Frame, St0, Step) :-
    Offset = Frame ^ fr_offset,
    (
        % A number with no registry entry names no member of `Atom`'s oneof, so
        % the frame is malformed ([RDSC.11.1], [RFCS.19.3]).
        Frame ^ fr_atom = unknown(_),
        Step = fail_load(err(lek_malformed_field_number, Offset, "RDSC.11.1"))
    ;
        Frame ^ fr_atom = known(A),
        ( if A = at_dsc_header then
            % A second DscHeader is read and verified as the first was, and
            % replaces it ([RDSC.7.2]).
            (
                decode_header(Frame ^ fr_body, HeaderResult),
                (
                    HeaderResult = hr_ok(H),
                    Twice = ( if rdsc_9_5_sha256_twice(Frame ^ fr_body)
                              then yes else no ),
                    check_header(H, Twice, Offset, HeaderCheck),
                    (
                        HeaderCheck = yes,
                        % At the header, so a later atom's error never pre-empts
                        % it, and after `check_header`, so another series is
                        % refused as such: the order libds checks in.
                        ( if verify_self_hash(BM, H) then
                            Step = continue(record_atom(A,
                                St0 ^ st_header := got_header(H)))
                        else
                            Step = fail_load(err(lek_semantic, Offset,
                                "RDSC.3.6"))
                        )
                    ;
                        HeaderCheck = no,
                        Step = header_rejection(H, Twice, Offset)
                    )
                ;
                    HeaderResult = hr_wire(E),
                    Step = fail_load(err(lek_decode, Offset, "RDSC.11.1"))
                        `with_wire` E
                ;
                    HeaderResult = hr_bad_field,
                    Step = fail_load(err(lek_decode, Offset, "RDSC.11.1"))
                ;
                    HeaderResult = hr_bad_string,
                    Step = fail_load(err(lek_decode, Offset, "RDSC.9.12"))
                )
            )
        else if A = at_compiled_code then
            % Skipped whatever its `arch` ([RDSC.4c.3]), its body not decoded.
            Step = continue(St0 ^ st_skipped :=
                [skip_code(Offset) | St0 ^ st_skipped])
        else if A = at_capability_info then
            rdsc_16_2_capb(Frame ^ fr_body, Offset, St0, Step0),
            Step = rdsc_9_5_reason(Frame ^ fr_body, Step0)
        else
            decode_body(A, Frame ^ fr_body, St0, Offset, Step0),
            Step = rdsc_9_5_reason(Frame ^ fr_body, Step0)
        )
    ).

    % A known atom this loader does not read is recorded, not skipped.
    %
:- pred decode_body(atom_id::in, reader::in, staging::in, int::in, step::out)
    is det.

decode_body(A, Body, St0, Offset, Step) :-
    ( if schema_decoder(A, Decode) then
        Decode(Body, St0 ^ st_schema, St0 ^ st_interns, SchemaStep),
        (
            SchemaStep = ss_ok(Sg, IT),
            St1 = ((St0 ^ st_schema := Sg) ^ st_interns := IT),
            Step = continue(record_atom(A, St1))
        ;
            SchemaStep = ss_error(Kind, Clause),
            Step = fail_load(err(Kind, Offset, Clause))
        )
    else if network_decoder(A, DecodeNode) then
        DecodeNode(Body, St0 ^ st_network, St0 ^ st_interns, NodeStep),
        (
            NodeStep = ns_ok(Ng, IT),
            St1 = ((St0 ^ st_network := Ng) ^ st_interns := IT),
            Step = continue(record_atom(A, St1))
        ;
            NodeStep = ns_error(Kind, Clause),
            Step = fail_load(err(Kind, Offset, Clause))
        )
    else if rule_atom(A) then
        decode_rule_atom(A, Body, St0 ^ st_rules, St0 ^ st_interns, RuleStep),
        (
            RuleStep = rs_ok(Rg, IT),
            St1 = ((St0 ^ st_rules := Rg) ^ st_interns := IT),
            Step = continue(record_atom(A, St1))
        ;
            RuleStep = rs_error(Kind, Clause),
            Step = fail_load(err(Kind, Offset, Clause))
        )
    else if atom_of_backing(Backing, A) then
        ( if decode_backing(Backing, Body, Decl) then
            St1 = St0 ^ st_series := St0 ^ st_series ++ [Decl],
            Step = continue(record_atom(A, St1))
        else
            Step = fail_load(err(lek_decode, Offset, "RDSC.5a"))
        )
    else if A = at_realtime_contract then
        % [RTCT.6.5]. Its cross-check of `rt_config_sha256` against a
        % recomputation is not implemented.
        ( if decode_contract(Body, Contract) then
            Step = continue(record_atom(A,
                St0 ^ st_contract := yes(Contract)))
        else
            Step = fail_load(err(lek_contract_invalid, Offset, "RTCT.6.5"))
        )
    else if A = at_ds_source then
        decode_dsrc(Body, St0, Offset, Step)
    else if A = at_line_span then
        decode_span(Body, St0, Offset, Step)
    else if A = at_schema_source then
        decode_srcs(Body, St0, Offset, Step)
    else if A = at_service_def then
        decode_svcd(Body, St0, Offset, Step)
    else if A = at_initial_fact then
        lgra_24_3_decode_ifct(Body, St0, Offset, Step)
    else if A = at_initial_cache_seed then
        lgra_24_3_decode_icac(Body, St0, Offset, Step)
    else if rdsc_9_4_skipped_by_name(A) then
        Step = continue(record_atom(A, St0 ^ st_skipped :=
            [skip_named(A, Offset) | St0 ^ st_skipped]))
    else
        Step = continue(record_atom(A, St0))
    ).

    % The atoms [RDSC.9.4] lists for a loader to step over and log, but
    % `CompiledCode`, which `dispatch_atom` takes first ([RDSC.4c.3]), and
    % `RuleDebugName`, which this loader reads ([RDSC.6.8.4]).
    %
    %@spec [RDSC.9.4]
:- pred rdsc_9_4_skipped_by_name(atom_id::in) is semidet.

rdsc_9_4_skipped_by_name(at_doc_string).
rdsc_9_4_skipped_by_name(at_test_case).
rdsc_9_4_skipped_by_name(at_test_fact).
rdsc_9_4_skipped_by_name(at_test_cache_seed).
rdsc_9_4_skipped_by_name(at_test_response).
rdsc_9_4_skipped_by_name(at_test_reply).
rdsc_9_4_skipped_by_name(at_oracle_activated).
rdsc_9_4_skipped_by_name(at_oracle_emit).
rdsc_9_4_skipped_by_name(at_oracle_publish).
rdsc_9_4_skipped_by_name(at_oracle_call).
rdsc_9_4_skipped_by_name(at_oracle_cache_set).
rdsc_9_4_skipped_by_name(at_oracle_cache_delete).
rdsc_9_4_skipped_by_name(at_oracle_log).
rdsc_9_4_skipped_by_name(at_oracle_retract).
rdsc_9_4_skipped_by_name(at_oracle_working_memory).
rdsc_9_4_skipped_by_name(at_oracle_exclusive).

%-----------------------------------------------------------------------------%
% A ruleset's `initial:` block
%-----------------------------------------------------------------------------%
%
% A NaN is judged on what the decoded atom holds [RDSC.9.10]: the body is read
% whole first, so one that fails to decode is DECODE whatever NaN it carries, and
% a NaN a later member of its oneof replaces is not refused.

    % A `TestSlotLiteral`'s `value`: the member the oneof ends on, or `lit_nan`,
    % which `float_from_bits` would read as 0.0.
    %
:- type held_literal
    --->    lit_held(test_value)
    ;       lit_nan.

:- pred lgra_24_3_decode_ifct(reader::in, staging::in, int::in, step::out)
    is det.

lgra_24_3_decode_ifct(Body, St0, Offset, Step) :-
    fold_fields(Body, ifct_field, {0u32, "", [], 0u32}, Result),
    (
        Result = ff_ok({Clip, Schema, RevSlots, Order}),
        ( if rdsc_9_10_held_slots(list.reverse(RevSlots), Slots) then
            Item = initial_fact(Clip, Schema, Slots, Order),
            Step = continue(record_atom(at_initial_fact,
                St0 ^ st_initial := [Item | St0 ^ st_initial]))
        else
            Step = fail_load(err(lek_semantic, Offset, "RDSC.9.10"))
        )
    ;
        Result = ff_bad_field,
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1"))
    ;
        Result = ff_wire(E),
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1")) `with_wire` E
    ).

:- pred rdsc_9_10_held_slots(assoc_list(string, held_literal)::in,
    assoc_list(string, test_value)::out) is semidet.

rdsc_9_10_held_slots([], []).
rdsc_9_10_held_slots([Name - lit_held(V) | Held], [Name - V | Slots]) :-
    rdsc_9_10_held_slots(Held, Slots).

:- pred ifct_field(uint32::in, field_value::in,
    {uint32, string, assoc_list(string, held_literal), uint32}::in,
    {uint32, string, assoc_list(string, held_literal), uint32}::out)
    is semidet.

ifct_field(Num, Value, {Clip0, Schema0, Slots0, Order0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), Acc = {u32(V), Schema0, Slots0, Order0}
    else if Num = 2u32 then
        Value = fv_bytes(S), reader_string(S, Schema),
        Acc = {Clip0, Schema, Slots0, Order0}
    else if Num = 3u32 then
        Value = fv_bytes(S), test_slot_literal(S, NamedLit),
        Acc = {Clip0, Schema0, [NamedLit | Slots0], Order0}
    else if Num = 4u32 then
        Value = fv_varint(V), Acc = {Clip0, Schema0, Slots0, u32(V)}
    else
        Acc = {Clip0, Schema0, Slots0, Order0}
    ).

    % A seed with no value, or with two ([RDSC.9.5]), is DECODE.
    %
:- pred lgra_24_3_decode_icac(reader::in, staging::in, int::in, step::out)
    is det.

lgra_24_3_decode_icac(Body, St0, Offset, Step) :-
    fold_fields(Body, icac_field, {0u32, "", no, 0u32, no}, Result),
    (
        Result = ff_ok({Clip, Key, MaybeValue, Order, Twice}),
        (
            Twice = yes,
            Step = fail_load(err(lek_decode, Offset, "RDSC.9.5"))
        ;
            Twice = no,
            (
                MaybeValue = yes(Held),
                (
                    Held = lit_held(Value),
                    Item = initial_seed(Clip, Key, Value, Order),
                    Step = continue(record_atom(at_initial_cache_seed,
                        St0 ^ st_initial := [Item | St0 ^ st_initial]))
                ;
                    Held = lit_nan,
                    Step = fail_load(err(lek_semantic, Offset, "RDSC.9.10"))
                )
            ;
                MaybeValue = no,
                Step = fail_load(err(lek_decode, Offset, "RDSC.11.1"))
            )
        )
    ;
        Result = ff_bad_field,
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1"))
    ;
        Result = ff_wire(E),
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1")) `with_wire` E
    ).

    % The fifth member: a second `value` has been met. Kept, since a failing
    % handler would be [RDSC.11.1]'s refusal rather than [RDSC.9.5]'s.
    %
:- pred icac_field(uint32::in, field_value::in,
    {uint32, string, maybe(held_literal), uint32, bool}::in,
    {uint32, string, maybe(held_literal), uint32, bool}::out) is semidet.

icac_field(Num, Value, {Clip0, Key0, Value0, Order0, Twice0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), Acc = {u32(V), Key0, Value0, Order0, Twice0}
    else if Num = 2u32 then
        Value = fv_bytes(S), reader_string(S, Key),
        Acc = {Clip0, Key, Value0, Order0, Twice0}
    else if Num = 3u32, Value0 = yes(_) then
        Acc = {Clip0, Key0, Value0, Order0, yes}
    else if Num = 3u32 then
        Value = fv_bytes(S), test_slot_literal(S, NamedLit),
        NamedLit = _ - Lit,
        Acc = {Clip0, Key0, yes(Lit), Order0, Twice0}
    else if Num = 4u32 then
        Value = fv_varint(V), Acc = {Clip0, Key0, Value0, u32(V), Twice0}
    else
        Acc = {Clip0, Key0, Value0, Order0, Twice0}
    ).

    % Of two oneof members, the last wins. Fails on a body with none.
    %
:- pred test_slot_literal(reader::in, pair(string, held_literal)::out)
    is semidet.

test_slot_literal(R, Literal) :-
    fold_fields(R, literal_field, {"", no}, Result),
    Result = ff_ok({Name, yes(Lit)}),
    Literal = Name - Lit.

:- pred literal_field(uint32::in, field_value::in,
    {string, maybe(held_literal)}::in,
    {string, maybe(held_literal)}::out) is semidet.

literal_field(Num, Value, {Name0, Literal0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, Name),
        Acc = {Name, Literal0}
    else if Num = 2u32 then
        Value = fv_varint(V),
        Acc = {Name0, yes(lit_held(tv_int(int64.cast_from_uint64(V))))}
    else if Num = 3u32 then
        Value = fv_fixed64(Bits),
        ( if nan_bits(Bits) then
            Acc = {Name0, yes(lit_nan)}
        else
            Acc = {Name0, yes(lit_held(tv_float(float_from_bits(Bits))))}
        )
    else if Num = 4u32 then
        Value = fv_bytes(S), reader_string(S, Text),
        Acc = {Name0, yes(lit_held(tv_string(Text)))}
    else if Num = 5u32 then
        Value = fv_varint(V),
        Bool = ( if V = 0u64 then no else yes ),
        Acc = {Name0, yes(lit_held(tv_bool(Bool)))}
    else if Num = 6u32 then
        Value = fv_varint(V), Acc = {Name0, yes(lit_held(tv_duration(V)))}
    else if Num = 7u32 then
        Value = fv_bytes(S), reader_string(S, Text),
        Acc = {Name0, yes(lit_held(tv_json(Text)))}
    else
        Acc = {Name0, Literal0}
    ).

    % A stable sort: items with one key keep their arrival order.
    %
:- func lgra_24_3_order(list(initial_item)) = list(initial_item).

lgra_24_3_order(Items) = list.sort(
    ( func(A, B) = compare_keys(item_key(A), item_key(B)) ), Items).

:- func item_key(initial_item) = {uint32, uint32}.

item_key(initial_fact(Clip, _, _, Order)) = {Clip, Order}.
item_key(initial_seed(Clip, _, _, Order)) = {Clip, Order}.

:- func compare_keys({uint32, uint32}, {uint32, uint32}) = comparison_result.

compare_keys(A, B) = R :-
    compare(R, A, B).

    % Refused only for a body that does not parse. `hydration`, field 4, is not
    % read, but a body holding it twice is DECODE ([RDSC.9.5]).
    %
:- pred decode_svcd(reader::in, staging::in, int::in, step::out) is det.

decode_svcd(Body, St0, Offset, Step) :-
    fold_fields(Body, svcd_field, {"", "", no, []}, Result),
    (
        Result = ff_ok({Name, Response, NoResponse, RevKwargs}),
        ( if
            fold_fields(Body, rdsc_9_5_count_bytes(4u32), 0, ff_ok(N)),
            N > 1
        then
            Step = fail_load(err(lek_decode, Offset, "RDSC.9.5"))
        else
            Step = continue(record_atom(at_service_def, St0 ^ st_services :=
                [svcd(Name, Response, NoResponse, list.reverse(RevKwargs))
                    | St0 ^ st_services]))
        )
    ;
        Result = ff_bad_field,
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1"))
    ;
        Result = ff_wire(E),
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1")) `with_wire` E
    ).

    % `name` 1, `kwargs` 2 (in reverse), `response` 3, `no_response` 5.
    %
:- pred svcd_field(uint32::in, field_value::in,
    {string, string, bool, list(service_kwarg)}::in,
    {string, string, bool, list(service_kwarg)}::out) is semidet.

svcd_field(Num, Value, {Name0, Response0, NoResponse0, Kwargs0},
        {Name, Response, NoResponse, Kwargs}) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, Name),
        Response = Response0, NoResponse = NoResponse0, Kwargs = Kwargs0
    else if Num = 3u32 then
        Value = fv_bytes(S), reader_string(S, Response),
        Name = Name0, NoResponse = NoResponse0, Kwargs = Kwargs0
    else if Num = 5u32 then
        Value = fv_varint(V), NoResponse = nonzero(V),
        Name = Name0, Response = Response0, Kwargs = Kwargs0
    else if Num = 2u32 then
        Name = Name0, Response = Response0, NoResponse = NoResponse0,
        Value = fv_bytes(Sub),
        fold_fields(Sub, kwarg_field, {"", "", no, no, no, ""},
            ff_ok({Type, KName, Required, Literal, HasDefault, Text})),
        Kwargs = [service_kwarg(KName, Type, Required, Literal,
            rdsc_6a_2_4_default(HasDefault, Text)) | Kwargs0]
    else
        Name = Name0, Response = Response0, NoResponse = NoResponse0,
        Kwargs = Kwargs0
    ).

    % `ds_type` 1, `name` 2, `required` 3, `is_literal` 4, `has_default` 5,
    % `default_value` 6.
    %
:- pred kwarg_field(uint32::in, field_value::in,
    {string, string, bool, bool, bool, string}::in,
    {string, string, bool, bool, bool, string}::out) is semidet.

kwarg_field(Num, Value, {T0, N0, R0, L0, H0, D0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, T), Acc = {T, N0, R0, L0, H0, D0}
    else if Num = 2u32 then
        Value = fv_bytes(S), reader_string(S, N), Acc = {T0, N, R0, L0, H0, D0}
    else if Num = 3u32 then
        Value = fv_varint(V), Acc = {T0, N0, nonzero(V), L0, H0, D0}
    else if Num = 4u32 then
        Value = fv_varint(V), Acc = {T0, N0, R0, nonzero(V), H0, D0}
    else if Num = 5u32 then
        Value = fv_varint(V), Acc = {T0, N0, R0, L0, nonzero(V), D0}
    else if Num = 6u32 then
        Value = fv_bytes(S), reader_string(S, D), Acc = {T0, N0, R0, L0, H0, D}
    else
        Acc = {T0, N0, R0, L0, H0, D0}
    ).

:- func nonzero(uint64) = bool.

nonzero(V) = ( if V = 0u64 then no else yes ).

    % `has_default` decides: a text beside a false flag is ignored.
    %
    %@spec [RDSC.6a.2.4]
:- func rdsc_6a_2_4_default(bool, string) = kwarg_default.

rdsc_6a_2_4_default(HasDefault, Text) = Default :-
    (
        HasDefault = no,
        Default = no_default
    ;
        HasDefault = yes,
        ( if Text = "" then
            Default = default_unstated
        else
            Default = default_text(Text)
        )
    ).

    % The text is read only once the compression is known to be NONE, so a
    % compressed body is refused for its compression ([RDSC.4.5.1]), not for not
    % being UTF-8 ([RDSC.9.12]).
    %
:- pred decode_dsrc(reader::in, staging::in, int::in, step::out) is det.

decode_dsrc(Body, St0, Offset, Step) :-
    fold_fields(Body, dsrc_field, {"", 0u64, no, 0u32}, Result),
    (
        Result = ff_ok({File, Compression, Data, Clip}),
        ( if Compression \= 1u64 then
            Step = fail_load(err(lek_decompress, Offset, "RDSC.4.5.1"))
        else if text_of(Data, Text) then
            Step = continue(record_atom(at_ds_source, St0 ^ st_sources :=
                [ds_source(Clip, File, Text) | St0 ^ st_sources]))
        else
            Step = fail_load(err(lek_decode, Offset, "RDSC.9.12"))
        )
    ;
        Result = ff_bad_field,
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1"))
    ;
        Result = ff_wire(E),
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1")) `with_wire` E
    ).

    % `file` 1, `compression` 2, `data` 3, `module_id` 10.
    %
:- pred dsrc_field(uint32::in, field_value::in,
    {string, uint64, maybe(reader), uint32}::in,
    {string, uint64, maybe(reader), uint32}::out) is semidet.

dsrc_field(Num, Value, {File0, Comp0, Data0, Clip0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, File),
        Acc = {File, Comp0, Data0, Clip0}
    else if Num = 2u32 then
        Value = fv_varint(V), Acc = {File0, V, Data0, Clip0}
    else if Num = 3u32 then
        Value = fv_bytes(S), Acc = {File0, Comp0, yes(S), Clip0}
    else if Num = 10u32 then
        Value = fv_varint(V),
        Acc = {File0, Comp0, Data0, uint32.cast_from_uint64(V)}
    else
        Acc = {File0, Comp0, Data0, Clip0}
    ).

:- pred text_of(maybe(reader)::in, string::out) is semidet.

text_of(no, "").
text_of(yes(S), Text) :- reader_string(S, Text).

:- pred decode_span(reader::in, staging::in, int::in, step::out) is det.

decode_span(Body, St0, Offset, Step) :-
    fold_fields(Body, span_field, {0u32, 0u32, 0u32, 0u32}, Result),
    (
        Result = ff_ok({Node, Line, Col, Clip}),
        Step = continue(record_atom(at_line_span, St0 ^ st_spans :=
            [line_span(Node, Line, Col, Clip) | St0 ^ st_spans]))
    ;
        Result = ff_bad_field,
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1"))
    ;
        Result = ff_wire(E),
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1")) `with_wire` E
    ).

    % `node_id` 1, `ds_line` 4, `ds_col` 5, `module_id` 10.
    %
:- pred span_field(uint32::in, field_value::in,
    {uint32, uint32, uint32, uint32}::in,
    {uint32, uint32, uint32, uint32}::out) is semidet.

span_field(Num, Value, {Node0, Line0, Col0, Clip0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), Acc = {u32(V), Line0, Col0, Clip0}
    else if Num = 4u32 then
        Value = fv_varint(V), Acc = {Node0, u32(V), Col0, Clip0}
    else if Num = 5u32 then
        Value = fv_varint(V), Acc = {Node0, Line0, u32(V), Clip0}
    else if Num = 10u32 then
        Value = fv_varint(V), Acc = {Node0, Line0, Col0, u32(V)}
    else
        Acc = {Node0, Line0, Col0, Clip0}
    ).

    % A second SchemaSource for one schema replaces the first. One naming no schema
    % is refused at commit, `commit_resolved`.
    %
:- pred decode_srcs(reader::in, staging::in, int::in, step::out) is det.

decode_srcs(Body, St0, Offset, Step) :-
    fold_fields(Body, srcs_field, {"", 0u32, 0u32, 0u32}, Result),
    (
        Result = ff_ok({Name, Line, Col, Clip}),
        Others = list.filter(
            (pred(Entry::in) is semidet :- Entry = Prior - _, Prior \= Name),
            St0 ^ st_schema_sources),
        Step = continue(record_atom(at_schema_source, St0 ^ st_schema_sources :=
            [Name - source_pos(Line, Col, Clip) | Others]))
    ;
        Result = ff_bad_field,
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1"))
    ;
        Result = ff_wire(E),
        Step = fail_load(err(lek_decode, Offset, "RDSC.11.1")) `with_wire` E
    ).

    % `schema_name` 1, `line` 3, `col` 4, `module_id` 10.
    %
:- pred srcs_field(uint32::in, field_value::in,
    {string, uint32, uint32, uint32}::in,
    {string, uint32, uint32, uint32}::out) is semidet.

srcs_field(Num, Value, {Name0, Line0, Col0, Clip0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, Name),
        Acc = {Name, Line0, Col0, Clip0}
    else if Num = 3u32 then
        Value = fv_varint(V), Acc = {Name0, u32(V), Col0, Clip0}
    else if Num = 4u32 then
        Value = fv_varint(V), Acc = {Name0, Line0, u32(V), Clip0}
    else if Num = 10u32 then
        Value = fv_varint(V), Acc = {Name0, Line0, Col0, u32(V)}
    else
        Acc = {Name0, Line0, Col0, Clip0}
    ).

:- func u32(uint64) = uint32.

u32(V) = uint32.cast_from_uint64(V).

:- pred schema_decoder(atom_id, pred(reader, schema_staging, intern_table,
                                     schema_step)).
:- mode schema_decoder(in, out(pred(in, in, in, out) is det)) is semidet.

schema_decoder(at_schema_logical, decode_slog).
schema_decoder(at_schema_ttl, decode_sttl).
schema_decoder(at_slot, decode_slot).
schema_decoder(at_schema_def, decode_sdef).
schema_decoder(at_hydration, decode_hydr).

:- pred network_decoder(atom_id, pred(reader, network_staging, intern_table,
                                      network_step)).
:- mode network_decoder(in, out(pred(in, in, in, out) is det)) is semidet.

network_decoder(at_alpha_node, decode_alfa).
network_decoder(at_beta_node, decode_beta).
network_decoder(at_terminal_node, decode_term).

:- func record_atom(atom_id, staging) = staging.

record_atom(A, St) = St ^ st_atoms := [A | St ^ st_atoms].

:- func with_wire(step, wire_error) = step.

with_wire(Step, W) =
    ( if Step = fail_load(E) then
        fail_load(E ^ le_reason := yes(wire_reason(W)))
    else
        Step
    ).

    % The per-atom decoders keep no wire error, so the body's top-level fields are
    % read again for the first one. A failure inside a nested message has no
    % reason to give.
    %
    %@spec [RDSC.9.5]
:- func rdsc_9_5_reason(reader, step) = step.

rdsc_9_5_reason(Body, Step) =
    ( if
        Step = fail_load(E),
        E ^ le_kind = lek_decode,
        E ^ le_reason = no,
        fold_fields(Body, any_field, unit, ff_wire(W))
    then
        fail_load(E ^ le_reason := yes(wire_reason(W)))
    else
        Step
    ).

:- pred any_field(uint32::in, field_value::in, unit::in, unit::out) is semidet.

any_field(_, _, unit, unit).

:- func wire_reason(wire_error) = string.

wire_reason(we_truncated) = "the body ends mid-value".
wire_reason(we_varint_overlong) =
    "a varint is longer than ten bytes or carries bits above 64".
wire_reason(we_bad_wire_type(T)) =
    "wire type " ++ string.int_to_string(T) ++ " is not one DS writes".
wire_reason(we_field_overflow) = "a field number does not fit".
wire_reason(we_length_overflow) = "a declared length does not fit".

%-----------------------------------------------------------------------------%
% The header
%-----------------------------------------------------------------------------%

:- type header_result
    --->    hr_ok(dsc_header)
    ;       hr_wire(wire_error)
    ;       hr_bad_field
            % `compiler_version` in another wire type ([RDSC.11.4]).
    ;       hr_bad_string.
            % `compiler_version` not valid ([RDSC.9.12]).

:- pred decode_header(reader::in, header_result::out) is det.

decode_header(R0, Result) :-
    % An artefact with no field 3 fails the version gate.
    header_fields(R0, dsc_header("", [], [], [], [], 0u32), Result).

:- pred header_fields(reader::in, dsc_header::in, header_result::out) is det.

header_fields(R0, Acc, Result) :-
    next_field(F, R0, R1),
    (
        F = fields_end,
        Result = hr_ok(Acc)
    ;
        F = field_error(E),
        Result = hr_wire(E)
    ;
        F = field(Num, Value),
        ( if Num = 3u32 then
            ( if Value = fv_bytes(Sub) then
                ( if reader_string(Sub, CV) then
                    header_fields(R1, Acc ^ dh_compiler_version := CV, Result)
                else
                    Result = hr_bad_string
                )
            else
                Result = hr_bad_field
            )
        else
            Acc1 = apply_header_field(Num, Value, Acc),
            header_fields(R1, Acc1, Result)
        )
    ).

    % Field 3 is read by `header_fields`. Any field not read here is skipped,
    % as an unknown field in a known atom's body is [RFCS.16.3].
    %
:- func apply_header_field(uint32, field_value, dsc_header) = dsc_header.

apply_header_field(Num, Value, H0) = H :-
    ( if Num = 7u32, Value = fv_bytes(Sub) then
        H = H0 ^ dh_sha256 := reader_bytes(Sub)
    else if Num = 13u32 then
        % A packed run that does not decode leaves a 0, which `check_header`
        % refuses.
        H = H0 ^ dh_capabilities := H0 ^ dh_capabilities
            ++ enum_values(Value)
    else if Num = 10u32, Value = fv_bytes(Sub) then
        H = H0 ^ dh_dialect_sha := reader_bytes(Sub)
    else if Num = 11u32, Value = fv_bytes(Sub) then
        H = H0 ^ dh_rt_config_sha := reader_bytes(Sub)
    else if Num = 14u32, Value = fv_varint(Sites) then
        H = H0 ^ dh_fault_fact_sites := uint32.cast_from_uint64(Sites)
    else
        H = H0
    ).

%-----------------------------------------------------------------------------%
% CapabilityInfo
%-----------------------------------------------------------------------------%

    % What the build lacks is checked before the shape: a `requires` naming a later
    % capability is well-formed for its producer. A second CapabilityInfo replaces
    % the first ([RDSC.7.2]).
    %
:- pred rdsc_16_2_capb(reader::in, int::in, staging::in, step::out) is det.

rdsc_16_2_capb(Body, Offset, St0, Step) :-
    capb_fields(Body, [], Enabled, [], Requires, Decoded),
    ( if Decoded = no then
        Step = fail_load(err(lek_decode, Offset, "RDSC.16.2.2"))
    else if
        list.filter(
            ( pred(N::in) is semidet :-
                not (
                    capability_of_number(N, C),
                    set.contains(build_capabilities, C)
                )
            ), Requires, Lacking),
        Lacking = [_ | _]
    then
        Step = fail_load(err(lek_capability_absent(list.foldl(int.min,
            Lacking, int.max_int)), Offset, "RDSC.16.2.7"))
    else if
        ( not strictly_ascending(Enabled)
        ; not strictly_ascending(Requires)
        ; list.member(0, Enabled)
        ; list.member(0, Requires)
        ; list.member(R, Requires), not list.member(R, Enabled)
        )
    then
        Step = fail_load(err(lek_semantic, Offset, "RDSC.16.2.3"))
    else if
        list.find_first_match(
            ( pred(C::in) is semidet :-
                map.search(St0 ^ st_policy, C, Admit),
                not admits(Admit, setting_of(Enabled, C))
            ), all_capabilities, Refused)
    then
        Step = fail_load(err(lek_not_admitted(capability_number(Refused),
            setting_of(Enabled, Refused)), Offset, "NLFC.10.2"))
    else
        Capb = capb(to_settings(Enabled), to_settings(Requires)),
        Step = continue(record_atom(at_capability_info, St0 ^ st_capb := yes(Capb)))
    ).

:- func setting_of(list(int), capability) = bool.

setting_of(Enabled, C) =
    ( if list.member(capability_number(C), Enabled) then yes else no ).

:- pred admits(admission::in, bool::in) is semidet.

admits(admit_either, _).
admits(admit_true_only, yes).
admits(admit_false_only, no).

    % `enabled` 2 and `requires` 3, in arrival order.
    %
:- pred capb_fields(reader::in, list(int)::in, list(int)::out,
                    list(int)::in, list(int)::out, bool::out) is det.

capb_fields(R0, !Enabled, !Requires, Decoded) :-
    next_field(F, R0, R1),
    (
        F = fields_end,
        Decoded = yes
    ;
        F = field_error(_),
        Decoded = no
    ;
        F = field(Num, Value),
        ( if Num = 2u32 then
            !:Enabled = !.Enabled ++ enum_values(Value)
        else if Num = 3u32 then
            !:Requires = !.Requires ++ enum_values(Value)
        else
            true
        ),
        capb_fields(R1, !Enabled, !Requires, Decoded)
    ).

:- pred strictly_ascending(list(int)::in) is semidet.

strictly_ascending([]).
strictly_ascending([_]).
strictly_ascending([A, B | Rest]) :-
    A < B,
    strictly_ascending([B | Rest]).

    % Known numbers only: an unknown one can be in `enabled` alone, where nothing
    % here can act on it.
    %
:- func to_settings(list(int)) = settings.

to_settings(Ns) = set.list_to_set(list.filter_map(
    ( func(N) = C is semidet :- capability_of_number(N, C) ), Ns)).

ds_version_series = Series :-
    V = ds.version.ds_version,
    ( if series_prefix_len(V, N) then
        Series = string.left(V, N)
    else
        % Exact equality, rather than a prefix that matches every artefact.
        Series = V
    ).

:- pred series_prefix_len(string::in, int::out) is semidet.

series_prefix_len(V, N) :-
    string.sub_string_search(V, ".", I),
    string.sub_string_search_start(V, ".", I + 1, J),
    N = J + 1.

    % `Twice` is `rdsc_9_5_sha256_twice`. The order is `header_rejection`'s, and
    % sets the code of a header wrong in two ways.
    %
:- pred check_header(dsc_header::in, bool::in, int::in, bool::out) is det.

check_header(H, Twice, _Offset, Ok) :-
    ( if version_series_mismatch(H) then
        Ok = no
    else if rdsc_3_7_binding_incomplete(H) then
        Ok = no
    else if rbnd_1_3_capabilities_malformed(H) then
        Ok = no
    else if Twice = yes then
        Ok = no
    else if list.length(H ^ dh_sha256) \= 32 then
        Ok = no
    else
        % Only the length: `dispatch` calls `verify_self_hash` right after.
        Ok = yes
    ).

:- pred version_series_mismatch(dsc_header::in) is semidet.

version_series_mismatch(H) :-
    not string.prefix(H ^ dh_compiler_version, ds_version_series).

:- pred rdsc_3_7_binding_incomplete(dsc_header::in) is semidet.

rdsc_3_7_binding_incomplete(H) :-
    list.length(H ^ dh_dialect_sha) \= 32.

:- pred rbnd_1_3_capabilities_malformed(dsc_header::in) is semidet.

rbnd_1_3_capabilities_malformed(H) :-
    not capabilities_well_formed(H ^ dh_capabilities).

    % Whether a header body holds `dsc_sha256` more than once. The body has
    % decoded by the time this is asked.
    %
:- pred rdsc_9_5_sha256_twice(reader::in) is semidet.

rdsc_9_5_sha256_twice(Body) :-
    fold_fields(Body, rdsc_9_5_count(7u32), 0, ff_ok(N)),
    N > 1.

:- pred rdsc_9_5_count(uint32::in, uint32::in, field_value::in,
                       int::in, int::out) is semidet.

rdsc_9_5_count(Want, Num, _, N0, N) :-
    N = ( if Num = Want then N0 + 1 else N0 ).

    % The length-delimited occurrences only: a message field's.
    %
:- pred rdsc_9_5_count_bytes(uint32::in, uint32::in, field_value::in,
                             int::in, int::out) is semidet.

rdsc_9_5_count_bytes(Want, Num, Value, N0, N) :-
    N = ( if Num = Want, Value = fv_bytes(_) then N0 + 1 else N0 ).

:- func header_rejection(dsc_header, bool, int) = step.

header_rejection(H, Twice, Offset) = fail_load(E) :-
    ( if version_series_mismatch(H) then
        E = err(lek_version, Offset, "LDET.1.10")
    else if rdsc_3_7_binding_incomplete(H) then
        E = err(lek_binding_incomplete, Offset, "RDSC.3.7")
    else if rbnd_1_3_capabilities_malformed(H) then
        E = err(lek_semantic, Offset, "RBND.1.3")
    else if Twice = yes then
        E = err(lek_decode, Offset, "RDSC.9.5")
    else
        E = err(lek_semantic, Offset, "RDSC.3.6")
    ).

%-----------------------------------------------------------------------------%
% Errors
%-----------------------------------------------------------------------------%

:- func err(load_error_kind, int, string) = load_error.

err(Kind, Offset, Clause) =
        load_error(Kind, maybe.yes(Offset), maybe.no, C, maybe.no) :-
    ( if clause_id(Clause, C0) then
        C = C0
    else
        unexpected($pred, "malformed clause id: " ++ Clause)
    ).

    % [RDSC.11.1]'s Framing. Running out is `lek_truncated` in the outer frame and
    % `lek_decode` in a body. A malformed frame is `lek_bad_first_atom` first and
    % `lek_decode` later.
    %
:- func frame_error(bool, atom_error, int) = load_error.

frame_error(First, ae_wire(W), Offset) = outer_wire_error(First, W, Offset).
frame_error(First, ae_body(W), Offset) = body_wire_error(First, W, Offset).
frame_error(First, ae_bad_outer_tag(_), Offset) =
    malformed_frame(First, lek_decode, Offset).
frame_error(First, ae_bad_inner_type, Offset) =
    malformed_frame(First, lek_decode, Offset).
frame_error(First, ae_empty_atom, Offset) =
    malformed_frame(First, lek_empty_atom, Offset).

:- func outer_wire_error(bool, wire_error, int) = load_error.

outer_wire_error(_, we_truncated, Offset) =
    err(lek_truncated, Offset, "RDSC.11.1").
outer_wire_error(_, we_length_overflow, Offset) =
    err(lek_truncated, Offset, "RDSC.11.1").
outer_wire_error(First, we_varint_overlong, Offset) =
    malformed_frame(First, lek_decode, Offset).
outer_wire_error(First, we_bad_wire_type(_), Offset) =
    malformed_frame(First, lek_decode, Offset).
outer_wire_error(First, we_field_overflow, Offset) =
    malformed_frame(First, lek_decode, Offset).

:- func body_wire_error(bool, wire_error, int) = load_error.

body_wire_error(_, we_truncated, Offset) =
    err(lek_decode, Offset, "RDSC.11.1").
body_wire_error(_, we_length_overflow, Offset) =
    err(lek_decode, Offset, "RDSC.11.1").
body_wire_error(First, we_varint_overlong, Offset) =
    malformed_frame(First, lek_decode, Offset).
body_wire_error(First, we_bad_wire_type(_), Offset) =
    malformed_frame(First, lek_decode, Offset).
body_wire_error(First, we_field_overflow, Offset) =
    malformed_frame(First, lek_decode, Offset).

:- func malformed_frame(bool, load_error_kind, int) = load_error.

malformed_frame(yes, _, Offset) = err(lek_bad_first_atom, Offset, "RDSC.11.1").
malformed_frame(no, Later, Offset) = err(Later, Offset, "RDSC.11.1").

%-----------------------------------------------------------------------------%
% Commit
%-----------------------------------------------------------------------------%

    % The one place a `program` comes into existence.
    %
:- pred commit(staging::in, load_result::out) is det.

commit(St, Result) :-
    (
        St ^ st_header = no_header,
        % Reached only on empty input: `dispatch` refuses any other first atom.
        Result = load_failed(err(lek_truncated, 0, "RDSC.11.1"))
    ;
        St ^ st_header = got_header(H),
        ( if St ^ st_capb = no then
            Result = load_failed(err(lek_semantic, 0, "RDSC.16.2.4"))
        else if
            % [RTCT.6.3]: a `realtime` bundle carries its contract.
            St ^ st_capb = yes(Capb),
            set.contains(Capb ^ cb_enabled, cap_realtime),
            not list.member(at_realtime_contract, St ^ st_atoms)
        then
            Result = load_failed(err(lek_contract_missing, 0, "RTCT.6.3"))
        else if intern_cap_breached(St) = yes(Cap) then
            % The loader's, since the artefact's own strings intern as it loads.
            % Every other cap is the engine's.
            Result = load_failed(err(lek_contract_breach(Cap), 0, "RTCT.7"))
        else
            commit_resolved(St, H, Result)
        )
    ).

:- pred commit_resolved(staging::in, dsc_header::in, load_result::out) is det.

    % A SchemaSource is staged beside the schemas, so `resolve_schemas` does not
    % check what it names.
    %
commit_resolved(St, H, Result) :-
    ( if
        list.member(Name - _, St ^ st_schema_sources),
        not declares_schema(St ^ st_schema, Name)
    then
        Result = load_failed(err(lek_semantic, 0, "LFAC.1.1"))
    else
        commit_schemas(St, H, Result)
    ).

:- pred commit_schemas(staging::in, dsc_header::in, load_result::out) is det.

commit_schemas(St, H, Result) :-
    (
        % Schemas first: slot indices come from arrival order.
        resolve_schemas(St ^ st_schema, St ^ st_interns, Resolved),
        (
            Resolved = resolve_error(Kind, Clause),
            Result = load_failed(err(Kind, 0, Clause))
        ;
            Resolved = resolved(Schemas),
            % The offset is zero on a resolution failure: a dangling reference
            % has no byte offset.
            resolve_staged_network(St ^ st_network, NetResult),
            (
                NetResult = network_error(Kind, Clause),
                Result = load_failed(err(Kind, 0, Clause))
            ;
                NetResult = network_ok(Network),
                ( if
                    rdsc_8_7_alpha_schema_dangles(Schemas, alpha_nodes(Network))
                then
                    Result = load_failed(err(lek_dangling, 0, "RDSC.8.7"))
                else if
                    St ^ st_contract = yes(RtContract),
                    not contract_hash_ok(Network, RtContract)
                then
                    Result = load_failed(
                        err(lek_contract_invalid, 0, "RTCT.6.5"))
                else

                ( if
                    ( unevaluable_test(beta_nodes(Network))
                    ; unevaluable_guard(terminal_nodes(Network))
                    )
                then
                    Result = load_failed(
                        err(lek_fn_not_found, 0, "RDSC.4a.9.3"))
                else if
                    (
                        invalid_regex(St ^ st_interns, beta_nodes(Network))
                    ;
                        invalid_alpha_regex(alpha_nodes(Network))
                    )
                then
                    Result = load_failed(
                        err(lek_semantic, 0, "IRET.6.3"))
                else
                    resolve_rule_meta(St ^ st_rules,
                        terminal_nodes(Network), RulesResult),
                    (
                        RulesResult = rules_failed(Kind, Clause),
                        Result = load_failed(err(Kind, 0, Clause))
                    ;
                        RulesResult = rules_ok(Metas),
                        commit_ok(St, H, Schemas, Network, Metas, Result)
                    )
                )
                )
            )
        )
    ).

    %@spec [RDSC.8.7]
:- pred rdsc_8_7_alpha_schema_dangles(list(schema)::in, list(alpha_node)::in)
    is semidet.

rdsc_8_7_alpha_schema_dangles(Schemas, Alphas) :-
    list.find_first_match(
        ( pred(A::in) is semidet :-
            not (
                list.member(S, Schemas),
                S ^ s_name = A ^ an_schema
            ) ),
        Alphas, _).

:- type inline_result
    --->    inline_ok(assoc_list(node_id, list(action)))
    ;       inline_blocked(string).

:- func resolve_inline(list(schema), intern_table, list(terminal_node),
                       assoc_list(node_id, list(action))) = inline_result.

resolve_inline(_, _, [], Acc) = inline_ok(list.reverse(Acc)).
resolve_inline(Schemas, IT, [T | Ts], Acc) = Result :-
    resolve_all(T ^ tn_inline_actions, Schemas, IT, [], R),
    (
        R = ra_all_ok(As),
        Result = resolve_inline(Schemas, IT, Ts, [T ^ tn_id - As | Acc])
    ;
        R = ra_all_blocked(Why),
        Result = inline_blocked(Why)
    ).

:- pred commit_ok(staging::in, dsc_header::in, list(schema)::in, network::in,
                  list(rule_meta)::in, load_result::out) is det.

commit_ok(St, H, Schemas, Network, Metas, Result) :-
    InlineResult = resolve_inline(Schemas, St ^ st_interns,
                       terminal_nodes(Network), []),
    (
        InlineResult = inline_blocked(_Why),
        Result = load_failed(err(lek_semantic, 0, "RDSC.4a.3"))
    ;
        InlineResult = inline_ok(Inline),
        ( if
            list.member(_ - Actions, Inline),
            list.member(Action, Actions),
            list.member(Expr, action_exprs(Action)),
            calls_unimplemented(Expr)
        then
            Result = load_failed(err(lek_fn_not_found, 0, "RDSC.4a.9.3"))
        else
            commit_loaded(St, H, Schemas, Network, Metas, Inline, Result)
        )
    ).

:- pred commit_loaded(staging::in, dsc_header::in, list(schema)::in,
                      network::in, list(rule_meta)::in,
                      assoc_list(node_id, list(action))::in,
                      load_result::out) is det.

commit_loaded(St, H, Schemas, Network, Metas, Inline, Result) :-
    (
        St ^ st_capb = yes(Capb)
    ;
        % Unreachable: `commit` refused this.
        St ^ st_capb = no,
        Capb = capb(set.init, set.init)
    ),
    (
        Result = loaded(program(H,
            list.reverse(St ^ st_atoms),
            list.reverse(St ^ st_skipped),
            Schemas,
            Network,
            Inline,
            Metas,
            St ^ st_series,
            St ^ st_interns,
            Capb,
            St ^ st_contract,
            list.reverse(St ^ st_sources),
            list.reverse(St ^ st_spans),
            list.reverse(St ^ st_schema_sources),
            list.reverse(St ^ st_services),
            lgra_24_3_order(list.reverse(St ^ st_initial))))
    ).

actions_for(P, Term) = As :-
    ( if assoc_list.search(P ^ p_actions, Term, Found) then
        As = Found
    else
        % A node that is not a terminal.
        As = []
    ).

:- type resolve_all_result
    --->    ra_all_ok(list(action))
    ;       ra_all_blocked(string).

:- pred resolve_all(list(inline_action)::in, list(schema)::in,
                    intern_table::in, list(action)::in,
                    resolve_all_result::out) is det.

resolve_all([], _, _, Acc, ra_all_ok(list.reverse(Acc))).
resolve_all([IA | IAs], Schemas, IT, Acc, Result) :-
    resolve_action(IA, Schemas, IT, One),
    (
        One = ra_ok(A),
        resolve_all(IAs, Schemas, IT, [A | Acc], Result)
    ;
        One = ra_error(_, _),
        Result = ra_all_blocked(blocked_why(IA))
    ).

:- func blocked_why(inline_action) = string.

blocked_why(IA) = Why :-
    (
        IA = ia_internal(_, _),
        Why = "gensym standing alone as an action"
    ;
        IA = ia_operands_not_admitted(_, _, _),
        Why = "operands not admitted (unexpected: it resolves)"
    ;
        IA = ia_bind(_, _),
        Why = "runtime let (unexpected: binds resolve)"
    ;
        ( IA = ia_call(_, _, _, _)
        ; IA = ia_hydration_call(_, _, _, _, _)
        ),
        Why = "call (unexpected: calls resolve unconditionally)"
    ;
        ( IA = ia_assert(_, _, _, _) ; IA = ia_publish(_, _, _)
        ; IA = ia_cache_set(_, _, _)
        ; IA = ia_cache_delete(_) ; IA = ia_log(_, _) ; IA = ia_withdraw(_)
        ; IA = ia_withdraw_by_id(_)
        ),
        Why = "unresolved schema reference"
    ).

    % A match test that faults declines, so an unimplemented builtin in a positive
    % `where` would never fire and under `no` always would. Betas only: an alpha
    % test carries no expression.
    %
:- pred unevaluable_test(list(beta_node)::in) is semidet.

unevaluable_test(Betas) :-
    list.member(B, Betas),
    list.member(Test, B ^ bn_tests),
    calls_unimplemented(Test).

    % An op the compiler emits only as an action, gate, cache value or bind is
    % decoded as that structure and never reaches this walk, so anything it meets
    % is at an expression site, where only `implemented/1` answers. A verb met here
    % is refused, where libds, whose handlers run anywhere, loads it: [RDSC.4a.9.3]
    % admits both.
    %
:- pred calls_unimplemented(expr::in) is semidet.

calls_unimplemented(Expr) :-
    sub_expr(Expr, Sub),
    (
        Sub = e_call(Fn, _),
        not implemented(Fn)
    ;
        % Two node shapes this runtime has no reading for, both never emitted.
        Sub = e_json_path(_, _)
    ;
        Sub = e_agg(_)
    ).

    % Every expression an action evaluates, for the load check.
    %
:- func action_exprs(action) = list(expr).

action_exprs(a_emit(_, Slots, _, Retain)) =
    list.map(slot_assign_expr, Slots) ++ maybe_list(Retain).
action_exprs(a_publish(_, Slots)) =
    list.map(slot_assign_expr, Slots).
action_exprs(a_call(_, Correlation, Kwargs, Gate)) =
    maybe_gate(Gate) ++ correlation_list(Correlation)
        ++ assoc_list.values(kwarg_list(Kwargs)).
action_exprs(a_cache_set(Key, Value, Ttl)) =
    [Key, cache_value_expr(Value) | maybe_list(Ttl)].
action_exprs(a_cache_delete(Key)) = [Key].
action_exprs(a_log(_, Message)) = [Message].
action_exprs(a_bind(_, Bound)) = bind_exprs(Bound).
action_exprs(a_retract_token_fact(Args)) = Args.
action_exprs(a_retract_corr(Args)) = Args.
action_exprs(a_withdraw(_)) = [].
action_exprs(a_withdraw_by_id(Fact)) = [Fact].
action_exprs(a_hydration_call(_, Correlation, _, Kwargs, Gate)) =
    maybe_gate(Gate) ++ correlation_list(Correlation)
        ++ assoc_list.values(kwarg_list(Kwargs)).
action_exprs(a_operands_not_admitted(_, Args, Gate)) = maybe_gate(Gate) ++ Args.

    % The executor unwraps the compiler's `ds_json_value(<v>)` rather than
    % evaluating it.
    %
:- func cache_value_expr(expr) = expr.

cache_value_expr(E) =
    ( if untainted(E) = e_call(fn_json_value, [Inner]) then Inner else E ).

    % `ds_gensym()` at the top of a bind is the executor's.
    %
:- func bind_exprs(expr) = list(expr).

bind_exprs(E) =
    ( if untainted(E) = e_call(fn_gensym, Args) then Args else [E] ).

    % The rate gate, alone or on the right of an `AND` ([RDSC.4a.8.2.1]), is the
    % executor's; its arguments and the condition are expressions.
    %
:- func guard_exprs(expr) = list(expr).

guard_exprs(G) = Es :-
    ( if untainted(G) = e_call(fn_rate_allow, Args) then
        Es = Args
    else if
        untainted(G) = e_binop(op_and, Cond, Gate),
        untainted(Gate) = e_call(fn_rate_allow, Args)
    then
        Es = [Cond | Args]
    else
        Es = [G]
    ).

:- pred unevaluable_guard(list(terminal_node)::in) is semidet.

unevaluable_guard(Terms) :-
    list.member(T, Terms),
    T ^ tn_guard = yes(G),
    list.member(E, guard_exprs(G)),
    calls_unimplemented(E).

:- func slot_assign_expr(slot_assign) = expr.

slot_assign_expr(slot_assign(_, E)) = E.

:- func maybe_list(maybe(expr)) = list(expr).

maybe_list(no) = [].
maybe_list(yes(E)) = [E].

:- func maybe_gate(maybe(list(expr))) = list(expr).

maybe_gate(no) = [].
maybe_gate(yes(Args)) = Args.

:- func correlation_list(correlation) = list(expr).

correlation_list(correlated(_)) = [].
correlation_list(correlated_expr(E)) = [E].

:- pred sub_expr(expr::in, expr::out) is multi.

sub_expr(Expr, Expr).
sub_expr(Expr, Sub) :-
    Kids = expr_children(Expr),
    list.member(Kid, Kids),
    sub_expr(Kid, Sub).

    % A beta join test's regex builtin whose literal pattern RE2 refuses under its
    % literal flags ([IRET.6.3]). A non-literal pattern is skipped.
    %
:- pred invalid_regex(intern_table::in, list(beta_node)::in) is semidet.

invalid_regex(IT, Betas) :-
    list.member(B, Betas),
    list.member(Test, B ^ bn_tests),
    sub_expr(Test, Sub),
    Sub = e_call(Fn, [_, e_lit(str(PatRef)) | FlagArgs]),
    regex_fn(Fn),
    expand(IT, PatRef, Pattern),
    ( if
        FlagArgs = [e_lit(str(FlagRef)) | _],
        expand(IT, FlagRef, Found)
    then
        Letters = Found
    else
        Letters = ""
    ),
    re2_compile(Pattern, re2_flags_of_letters(Letters)) = re2_invalid(_).

    % No flags: the compiler folds them into the pattern ([RLOW.5.2.2]).
    %
:- pred invalid_alpha_regex(list(alpha_node)::in) is semidet.

invalid_alpha_regex(Alphas) :-
    list.member(A, Alphas),
    list.member(at_regex(_, Pattern), A ^ an_tests),
    re2_compile(Pattern, re2_flags_of_letters("")) = re2_invalid(_).

%-----------------------------------------------------------------------------%

verify_self_hash(BM, H) :-
    Stored = H ^ dh_sha256,
    list.length(Stored) = 32,
    bytes_of(BM, Bytes),
    zero_first_run(Bytes, Stored, Zeroed),
    sha256(Zeroed) = Stored.

:- pred bytes_of(bitmap::in, list(uint8)::out) is semidet.

bytes_of(BM, Bytes) :-
    N = bitmap.num_bytes(BM),
    bytes_loop(BM, 0, N, [], Rev),
    Bytes = list.reverse(Rev).

:- pred bytes_loop(bitmap::in, int::in, int::in,
                   list(uint8)::in, list(uint8)::out) is det.

bytes_loop(BM, I, N, !Acc) :-
    ( if I < N then
        !:Acc = [uint8.cast_from_int(bitmap.byte(I, BM)) | !.Acc],
        bytes_loop(BM, I + 1, N, !Acc)
    else
        true
    ).

    % Zero the first occurrence of the stored hash, found by value.
    %
:- pred zero_first_run(list(uint8)::in, list(uint8)::in, list(uint8)::out)
    is semidet.

zero_first_run(Bytes, Run, Zeroed) :-
    Len = list.length(Run),
    find_first(Bytes, Run, 0, At),
    list.det_split_list(At, Bytes, Before, Rest),
    list.det_split_list(Len, Rest, _, After),
    Zeroed = Before ++ list.duplicate(Len, 0u8) ++ After.

:- pred find_first(list(uint8)::in, list(uint8)::in, int::in, int::out)
    is semidet.

find_first(Bytes @ [_ | Tail], Run, I, At) :-
    ( if list.append(Run, _, Bytes) then
        At = I
    else
        find_first(Tail, Run, I + 1, At)
    ).

%-----------------------------------------------------------------------------%

    % A cap of zero is unset.
    %
:- func intern_cap_breached(staging) = maybe(cap).

intern_cap_breached(St) = Breach :-
    ( if
        St ^ st_contract = yes(C),
        C ^ c_intern_cap > 0u32,
        intern_count(St ^ st_interns) > uint32.cast_to_int(C ^ c_intern_cap)
    then
        Breach = yes(cap_intern)
    else if
        St ^ st_contract = yes(C2),
        C2 ^ c_intern_bytes_cap > 0u32,
        intern_bytes(St ^ st_interns)
            > uint32.cast_to_int(C2 ^ c_intern_bytes_cap)
    then
        Breach = yes(cap_intern_bytes)
    else
        Breach = no
    ).

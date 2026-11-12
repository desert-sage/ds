% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.encode -- a compiled program to `.dsc` atoms.
%
% The input is the runtime's own types, so each writer is the inverse of one
% decoder (`ds.dsc_schema`, `ds.dsc_network`, `ds.dsc_expr`, `ds.dsc_action`,
% `ds.dsc_rules`). Both sides share `ds.wire`'s framing, so a round trip cannot
% catch a framing bug; the runtime's format vectors pin that.
%-----------------------------------------------------------------------------%

:- module dsc.encode.
:- interface.

% Nothing here names `ds`: Mercury refuses a child module's imports without it.
:- import_module ds.
:- import_module ds.intern.
:- import_module ds.contract.
:- import_module ds.schema.
:- import_module ds.service.

:- import_module ds.capability.
:- import_module dsc.ast.
:- import_module dsc.capability.
:- import_module dsc.dstest.
:- import_module dsc.rete.
:- import_module dsc.token.
    % `use`, not `import`: only `resolved_file` is named, by
    % `rdsc_6a_2_4_kwargs`, and the module's other names stay out of scope.
:- use_module dsc.resolve.

:- import_module assoc_list.

:- import_module list.
:- import_module maybe.
:- import_module string.
:- import_module uint8.

%-----------------------------------------------------------------------------%

    %@helper
:- type binding
    --->    binding(
                bd_program  :: program_settings,
                bd_requires :: settings
            ).

    % One source module: the `module_id` its atoms carry, the display path the
    % DsSource names it by, and its verbatim text.
    %
    %@helper
:- type module_source
    --->    module_source(
                mod_clip   :: uint32,
                mod_file   :: string,
                mod_source :: string
            ).

    % One `service` declaration, the module that declared it, and its kwargs
    % already in ServiceDef's terms (`rdsc_6a_2_4_kwargs`), since this module is
    % handed no resolved file.
    %
    %@helper
:- type service_entry
    --->    service_entry(
                se_clip   :: uint32,
                se_decl   :: ast_service_decl,
                se_kwargs :: list(service_kwarg)
            ).

    %@spec [RDSC.6a.2.4]
:- func rdsc_6a_2_4_kwargs(dsc.resolve.resolved_file, ast_service_decl)
    = list(service_kwarg).

    % One docstring and the declaration it documents. `de_schema`, `de_slot` and
    % `de_rule` are `""` where the target kind does not populate them.
    %
    %@helper
:- type doc_entry
    --->    doc_entry(
                de_target :: doc_target,
                de_clip   :: uint32,
                de_schema :: string,
                de_slot   :: string,
                de_rule   :: string,
                de_text   :: string,
                de_pos    :: pos,
                de_origin :: decl_origin
                    % An injected builtin's `de_pos` is a line of the builtin's
                    % own text, not of the module's, so it orders nothing
                    % (`rdsc_14_4_6_declaration_order`).
            ).

    %@helper
:- type doc_target
    --->    dt_schema
    ;       dt_slot
    ;       dt_rule.

    %@spec [RDSC.1.1]
    %@spec [RDSC.14.1]
:- pred rdsc_1_1_encode(binding::in, intern_table::in, list(schema)::in,
                        assoc_list(string, pos)::in,
                        list(module_source)::in,
                        list(doc_entry)::in,
                        list(service_entry)::in,
                        uint32::in,
                        rete_network::in, maybe(contract)::in,
                        list(uint8)::out) is det.

    % `rdsc_1_1_encode` with each module's `initial:` items and tests, both keyed
    % by `module_id`.
    %
    %@spec [RDSC.8.1]
:- pred rdsc_1_1_encode_tests(binding::in, intern_table::in, list(schema)::in,
                              assoc_list(string, pos)::in,
                              list(module_source)::in,
                              list(doc_entry)::in,
                              list(service_entry)::in,
                              uint32::in,
                              rete_network::in, maybe(contract)::in,
                              assoc_list(uint32, list(initial_item_ir))::in,
                              assoc_list(uint32, list(test_ir))::in,
                              list(uint8)::out) is det.

    %@spec [RDSC.5.8.3]
:- func rdsc_5_8_3_proto_header = string.

    % Each schema's name and its `message` block, in the order given: the
    % SchemaDef atom's own rendering, which `dsc dump-schemas` writes.
    %
    %@spec [RDSC.5.8.3]
:- func rdsc_5_8_3_messages(intern_table, list(schema))
    = assoc_list(string, string).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.action.
:- import_module ds.atom.
:- import_module ds.builtins.
:- import_module ds.chrono.
:- import_module ds.dsc_action.
:- import_module ds.expr.
:- import_module ds.id.
:- import_module ds.network.
:- import_module ds.series.
:- import_module ds.float_text.
:- import_module ds.sha256.
:- import_module ds.value.
:- import_module ds.version.
:- import_module ds.wire.


:- import_module dsc.contract.
:- import_module dsc.strlit.
    % `use`, not `import`: `dsc.expr` and `ds.expr` both name a type
    % `is_subject`, and this module reads `ds.expr` unqualified.
:- use_module dsc.expr.
    % `use`, as `dsc.expr` is: the two modules' names are called qualified.
:- use_module dsc.exact.
:- use_module dsc.quantity.

:- import_module bool.
:- import_module float.
:- import_module int.
:- import_module int64.
    % `use`: `rf_types` is the one map read here, and `map.search` is called
    % qualified rather than overloading `assoc_list.search`.
:- use_module map.
:- import_module pair.
:- import_module require.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%
% The artefact
%-----------------------------------------------------------------------------%

    % [RDSC.3.6] hashes the artefact with `dsc_sha256` zeroed, so the header is
    % written twice: the field is 32 bytes either way.
    %
rdsc_1_1_encode(Binding, IT, Schemas, Positions, Modules, Docs, Svcs, FileClip,
        Network, MaybeContract, Bytes) :-
    rdsc_1_1_encode_tests(Binding, IT, Schemas, Positions, Modules, Docs, Svcs,
        FileClip, Network, MaybeContract, [], [], Bytes).

rdsc_1_1_encode_tests(Binding, IT, Schemas, Positions, Modules, Docs, Svcs,
        FileClip, Network, MaybeContract, Initials, Tests, Bytes) :-
    (
        MaybeContract = yes(Contract),
        RtSha = rt_config_sha256(Contract),
        Dsrt = rtct_6_2_dsrt(Contract, RtSha)
    ;
        MaybeContract = no,
        RtSha = [],
        Dsrt = init_builder
    ),
    % Every atom is a builder until here and the body is flattened once: the
    % wasm32 `dsc` has a fixed heap and no collector. `++` below copies only the
    % header.
    BodyB = concat_builders([rdsc_15_1_dial(Binding),
        rdsc_16_2_1_capb(Binding), Dsrt,
        concat_builders(list.map(
            rdsc_8_1_module_group(IT, Schemas, Positions, Docs, Svcs, Network,
                FileClip, Initials, Tests),
            Modules)),
        concat_builders(list.map(rdsc_4a_6_alfa(IT), Network ^ rn_alphas)),
        concat_builders(list.map(rdsc_4a_7_beta(IT), Network ^ rn_betas)),
        concat_builders(list.map(rdsc_4a_8_term(IT), Network ^ rn_terms)),
        % LineSpan closes the bundle-global network section, not a module group,
        % though each carries a `module_id`.
        concat_builders(list.map(
            ( func(M) = concat_builders(list.map(rdsc_14_3_1_span(M ^ mr_clip),
                M ^ mr_spans)) ),
            Network ^ rn_modules))]),
    Body = builder_bytes(BodyB),
    Sites = rdsc_3_10_fault_fact_sites(IT, Network),
    Draft = rdsc_3_1_header(Binding, list.duplicate(32, 0u8), RtSha, Sites)
        ++ Body,
    Bytes = rdsc_3_1_header(Binding, sha256(Draft), RtSha, Sites) ++ Body.

    % By the runtime's own definition, so the two counts are one computation. A
    % network that does not resolve is a compiler defect, and answering 0 would
    % under-size a pool with no refusal path, so it stops.
    %
    %@spec [RDSC.3.10]
:- func rdsc_3_10_fault_fact_sites(intern_table, rete_network) = uint32.

rdsc_3_10_fault_fact_sites(IT, Network) = Sites :-
    resolve_network(Network ^ rn_alphas, Network ^ rn_betas,
        Network ^ rn_terms, Result),
    (
        Result = network_ok(Net),
        Sites = uint32.det_from_int(lerr_9_10_fault_fact_sites(Net, IT))
    ;
        Result = network_error(_, Clause),
        unexpected($pred, "the compiler's own network does not resolve: "
            ++ Clause)
    ).

%-----------------------------------------------------------------------------%
% Framing -- [RFCS.19.1]
%-----------------------------------------------------------------------------%

    % The atoms this compiler emits. `ds.atom.atom_id` spans both formats; framing
    % takes this type, so a fact-stream atom is not spellable at a call site.
    %
    %@helper
:- type dsc_atom
    --->    da_dsc_header ; da_dialect_info ; da_capability_info ; da_realtime_contract
    ;       da_schema_ttl ; da_schema_logical ; da_slot ; da_hydration
    ;       da_schema_source ; da_schema_def ; da_ds_source ; da_doc_string ; da_line_span
    ;       da_rule_source ; da_rule_debug_name ; da_rule_cooldown ; da_service_def
    ;       da_alpha_node ; da_beta_node ; da_terminal_node
    ;       da_series_backend_welford_ewma ; da_series_backend_ring_buffer ; da_series_backend_monotonic_deque ; da_series_backend_fifo_deque ; da_series_backend_reservoir ; da_series_backend_interval_pulse
    ;       da_series_backend_numeric_integral
    ;       da_initial_fact ; da_initial_cache_seed
    ;       da_test_case ; da_test_fact ; da_test_cache_seed ; da_test_response ; da_test_reply
    ;       da_oracle_activated ; da_oracle_emit ; da_oracle_publish ; da_oracle_call ; da_oracle_cache_set ; da_oracle_cache_delete
    ;       da_oracle_log ; da_oracle_retract ; da_oracle_working_memory.

    %@spec [RDSC.8.8]
:- func rdsc_8_8_atom(dsc_atom) = atom_id.

rdsc_8_8_atom(da_dsc_header) = at_dsc_header.
rdsc_8_8_atom(da_dialect_info) = at_dialect_info.
rdsc_8_8_atom(da_capability_info) = at_capability_info.
rdsc_8_8_atom(da_realtime_contract) = at_realtime_contract.
rdsc_8_8_atom(da_schema_ttl) = at_schema_ttl.
rdsc_8_8_atom(da_schema_logical) = at_schema_logical.
rdsc_8_8_atom(da_slot) = at_slot.
rdsc_8_8_atom(da_hydration) = at_hydration.
rdsc_8_8_atom(da_schema_source) = at_schema_source.
rdsc_8_8_atom(da_schema_def) = at_schema_def.
rdsc_8_8_atom(da_ds_source) = at_ds_source.
rdsc_8_8_atom(da_doc_string) = at_doc_string.
rdsc_8_8_atom(da_line_span) = at_line_span.
rdsc_8_8_atom(da_rule_source) = at_rule_source.
rdsc_8_8_atom(da_rule_debug_name) = at_rule_debug_name.
rdsc_8_8_atom(da_rule_cooldown) = at_rule_cooldown.
rdsc_8_8_atom(da_service_def) = at_service_def.
rdsc_8_8_atom(da_alpha_node) = at_alpha_node.
rdsc_8_8_atom(da_beta_node) = at_beta_node.
rdsc_8_8_atom(da_terminal_node) = at_terminal_node.
rdsc_8_8_atom(da_series_backend_welford_ewma) = at_series_backend_welford_ewma.
rdsc_8_8_atom(da_series_backend_ring_buffer) = at_series_backend_ring_buffer.
rdsc_8_8_atom(da_series_backend_monotonic_deque) = at_series_backend_monotonic_deque.
rdsc_8_8_atom(da_series_backend_fifo_deque) = at_series_backend_fifo_deque.
rdsc_8_8_atom(da_series_backend_reservoir) = at_series_backend_reservoir.
rdsc_8_8_atom(da_series_backend_interval_pulse) = at_series_backend_interval_pulse.
rdsc_8_8_atom(da_series_backend_numeric_integral) = at_series_backend_numeric_integral.
rdsc_8_8_atom(da_initial_fact) = at_initial_fact.
rdsc_8_8_atom(da_initial_cache_seed) = at_initial_cache_seed.
rdsc_8_8_atom(da_test_case) = at_test_case.
rdsc_8_8_atom(da_test_fact) = at_test_fact.
rdsc_8_8_atom(da_test_cache_seed) = at_test_cache_seed.
rdsc_8_8_atom(da_test_response) = at_test_response.
rdsc_8_8_atom(da_test_reply) = at_test_reply.
rdsc_8_8_atom(da_oracle_activated) = at_oracle_activated.
rdsc_8_8_atom(da_oracle_emit) = at_oracle_emit.
rdsc_8_8_atom(da_oracle_publish) = at_oracle_publish.
rdsc_8_8_atom(da_oracle_call) = at_oracle_call.
rdsc_8_8_atom(da_oracle_cache_set) = at_oracle_cache_set.
rdsc_8_8_atom(da_oracle_cache_delete) = at_oracle_cache_delete.
rdsc_8_8_atom(da_oracle_log) = at_oracle_log.
rdsc_8_8_atom(da_oracle_retract) = at_oracle_retract.
rdsc_8_8_atom(da_oracle_working_memory) = at_oracle_working_memory.

    %@spec [RFCS.19.1]
    %@spec [RFCS.19.6]
:- pred rfcs_19_1_frame(dsc_atom::in, builder::in, builder::out) is det.

rfcs_19_1_frame(Atom, Body, Outer) :-
    put_message(atom_field(rdsc_8_8_atom(Atom)), Body, init_builder, Inner),
    put_message(1u32, Inner, init_builder, Outer).

%-----------------------------------------------------------------------------%
% DscHeader -- [RDSC.3]
%-----------------------------------------------------------------------------%

    % Fields ascending. Field 3 is the load gate: an empty stamp is a mismatch.
    %
    %@spec [RDSC.3.11]
    %@spec [RDSC.3.1]
    %@spec [RDSC.3.6]
    %@spec [RDSC.3.8]
    %@spec [RFCS.19.5]
:- func rdsc_3_1_header(binding, list(uint8), list(uint8), uint32)
    = list(uint8).

rdsc_3_1_header(Binding, Sha, RtSha, Sites) = Bytes :-
    put_string(3u32, ds_version, init_builder, H2),
    put_delimited(7u32, Sha, H2, H3),
    put_delimited(10u32, rbnd_4_2_dialect_sha(Binding ^ bd_program), H3, H5),
    % Empty unless `realtime` ([RDSC.3.8]), and then no field is written.
    (
        RtSha = [],
        H5a = H5
    ;
        RtSha = [_ | _],
        put_delimited(11u32, RtSha, H5, H5a)
    ),
    put_capabilities(13u32, Binding ^ bd_program ^ ps_enabled, H5a, H6a),
    put_uint32(14u32, Sites, H6a, H7),
    rfcs_19_1_frame(da_dsc_header, H7, Framed),
    Bytes = builder_bytes(Framed).

    % A packed `repeated Capability`, ascending. An empty set writes no field.
    %
    %@helper
:- pred put_capabilities(uint32::in, settings::in, builder::in, builder::out)
    is det.

put_capabilities(Field, Settings, !B) :-
    Caps = ascending(Settings),
    (
        Caps = []
    ;
        Caps = [_ | _],
        list.foldl(
            ( pred(C::in, B0::in, B1::out) is det :-
                put_varint(uint64.det_from_int(capability_number(C)), B0, B1)
            ), Caps, init_builder, Packed),
        put_delimited(Field, builder_bytes(Packed), !B)
    ).

    %@spec [RBND.4.2]
:- func rbnd_4_2_dialect_sha(program_settings) = list(uint8).

rbnd_4_2_dialect_sha(Program) = sha256(list.map(uint8.det_from_int, Units)) :-
    string.to_utf8_code_unit_list(
        rbnd_4_2_serialization(Program ^ ps_enabled), Units).

%-----------------------------------------------------------------------------%
% A schema's atoms -- [RDSC.5], in [RDSC.8.1]'s order
%-----------------------------------------------------------------------------%

    % `SchemaLogical` is not `logical`: `ttl` emits SchemaTtl, and every other
    % lifecycle SchemaLogical, whose field 3 says which.
    %
    %@spec [RDSC.5.1]
    %@spec [RDSC.5.2]
    %@spec [RDSC.8.1]
    %@spec [RDSC.8.4]
:- func rdsc_5_1_schema_atoms(intern_table, assoc_list(string, pos), schema)
    = builder.

rdsc_5_1_schema_atoms(IT, Positions, S) = Bytes :-
    Name = interned_text(IT, schema_name_ref(S ^ s_name)),
    Clip = rdsc_4_7_clip(S),
    Life = S ^ s_lifecycle,
    (
        Life = lc_ttl(Plain, Ttl),
        Lifecycle = rdsc_5_3_1_sttl(Name, duration_ns(Ttl), Clip),
        Commons = list.map(plain_common, Plain),
        SlotBytes = list.map(plain_slot_atom(IT, Name, Clip), Plain)
    ;
        Life = lc_explicit(Plain),
        Lifecycle = rdsc_5_4_1_slog(Name, no, slog_explicit, Clip),
        Commons = list.map(plain_common, Plain),
        SlotBytes = list.map(plain_slot_atom(IT, Name, Clip), Plain)
    ;
        Life = lc_activation(Plain),
        Lifecycle = rdsc_5_4_1_slog(Name, no, slog_activation, Clip),
        Commons = list.map(plain_common, Plain),
        SlotBytes = list.map(plain_slot_atom(IT, Name, Clip), Plain)
    ;
        Life = lc_logical(Logical, Ambient),
        Lifecycle = rdsc_5_4_1_slog(Name, Ambient, slog_logical, Clip),
        Commons = list.map(logical_common, Logical),
        SlotBytes = list.map(logical_slot_atom(IT, Name, Clip), Logical)
    ),
    % A slot's index is not on the wire: its position is its order of arrival,
    % so reordering these renumbers every fact body of the schema.
    Bytes = concat_builders([Lifecycle, concat_builders(SlotBytes),
        concat_builders(list.map(hydr_for(IT, Name, Clip), Commons)),
        rdsc_5_7_1_srcs(Name, Clip, Positions),
        rdsc_5_8_1_sdef(IT, Name, Clip, Commons)]).

    % Built from the same `slot_common` list as the Slot atoms ([RDSC.5.8.5]).
    %
    % `compression` is written, as 1: NONE is not the enum's zero, and an absent
    % field is UNSPECIFIED, which libds refuses.
    %
    %@spec [RDSC.4.4]
    %@spec [RDSC.5.8.1]
    %@spec [RDSC.5.8.2]
    %@spec [RDSC.5.8.3]
    %@spec [RDSC.5.8.4]
    %@spec [RDSC.5.8.5]
:- func rdsc_5_8_1_sdef(intern_table, string, uint32, list(slot_common))
    = builder.

rdsc_5_8_1_sdef(IT, Name, Clip, Commons) = Bytes :-
    put_string(1u32, Name, init_builder, B1),
    put_uint32(2u32, rdsc_4_4_compression_none, B1, B2),
    % [RDSC.5.8.3]: a synthetic schema's `proto_source` is empty.
    ( if synthetic_name(Name) then
        Proto = ""
    else
        Proto = rdsc_5_8_3_proto_source(IT, Name, Commons)
    ),
    put_string(3u32, Proto, B2, B3),
    rdsc_4_7_put_clip(Clip, B3, B4),
    rfcs_19_1_frame(da_schema_def, B4, Bytes).

    %@spec [RDSC.4.4]
:- func rdsc_4_4_compression_none = uint32.

rdsc_4_4_compression_none = 1u32.

    % A library's schema adds its path to the package, since a message name holds
    % no `.`: `units.currency.FxRate` is `FxRate` in
    % `ds.dsc.user.v1.units.currency`.
    %
    %@spec [RDSC.5.8.3]
:- func rdsc_5_8_3_proto_source(intern_table, string, list(slot_common))
    = string.

rdsc_5_8_3_proto_source(IT, Name, Commons) =
    "syntax = \"proto3\";\n"
        ++ "package " ++ rdsc_5_8_3_package(Name) ++ ";\n"
        ++ rdsc_5_8_3_message_of(IT, Name, Commons).

rdsc_5_8_3_proto_header =
    "syntax = \"proto3\";\n"
        ++ "package ds.dsc.user.v1;\n".

    %@helper
:- func rdsc_5_8_3_package(string) = string.

rdsc_5_8_3_package(Own) = Package :-
    ( if
        list.split_last(string.split_at_char('.', Own), Path, _),
        Path = [_ | _]
    then
        Package = "ds.dsc.user.v1." ++ string.join_list(".", Path)
    else
        Package = "ds.dsc.user.v1"
    ).

    %@helper
:- func rdsc_5_8_3_message_name(string) = string.

rdsc_5_8_3_message_name(Own) = Message :-
    ( if list.split_last(string.split_at_char('.', Own), _, Last) then
        Message = Last
    else
        Message = Own
    ).

rdsc_5_8_3_messages(IT, Schemas) =
    list.map(
        ( func(S) = Name - rdsc_5_8_3_message_of(IT, Name, slot_commons(S)) :-
            Name = interned_text(IT, schema_name_ref(S ^ s_name))
        ), Schemas).

    %@helper
:- func rdsc_5_8_3_message_of(intern_table, string, list(slot_common))
    = string.

rdsc_5_8_3_message_of(IT, Name, Commons) =
    "message " ++ rdsc_5_8_3_message_name(Name) ++ " {\n"
        ++ rdsc_5_8_3_fields(IT, Commons, 1)
        ++ "}\n".

    %@helper
:- func rdsc_5_8_3_fields(intern_table, list(slot_common), int) = string.

rdsc_5_8_3_fields(_, [], _) = "".
rdsc_5_8_3_fields(IT, [C | Cs], Number) =
    "  " ++ rdsc_5_8_3_label(C ^ sc_nullable)
        ++ rdsc_5_8_3_proto_type(C ^ sc_kind) ++ " "
        ++ interned_text(IT, C ^ sc_name) ++ " = "
        ++ string.from_int(Number) ++ ";\n"
        ++ rdsc_5_8_3_fields(IT, Cs, Number + 1).

    % `optional` gives a recorded fact body presence for the field, so `null` and
    % the type's zero are two states on the wire.
    %
    %@spec [RDSC.5.8.3]
:- func rdsc_5_8_3_label(nullable) = string.

rdsc_5_8_3_label(nullable) = "optional ".
rdsc_5_8_3_label(non_null) = "".

    % A fact-reference slot is `uint64`: the referenced fact's `fact_id`.
    %
    %@spec RDSC.5.8.3
:- func rdsc_5_8_3_proto_type(slot_kind) = string.

rdsc_5_8_3_proto_type(k_int)       = "int64".
rdsc_5_8_3_proto_type(k_float)     = "double".
rdsc_5_8_3_proto_type(k_string)    = "string".
rdsc_5_8_3_proto_type(k_bool)      = "bool".
rdsc_5_8_3_proto_type(k_json)      = "string".
rdsc_5_8_3_proto_type(k_bytes)     = "bytes".
rdsc_5_8_3_proto_type(k_schema(_)) = "uint64".
rdsc_5_8_3_proto_type(k_time)      = "int64".
rdsc_5_8_3_proto_type(k_date)      = "int64".
rdsc_5_8_3_proto_type(k_duration)  = "int64".

    % No atom without a position: an injected builtin has none to record.
    %
    %@spec [RDSC.5.7.1]
    %@spec [RDSC.5.7.2]
    %@spec [RDSC.5.7.4]
:- func rdsc_5_7_1_srcs(string, uint32, assoc_list(string, pos))
    = builder.

rdsc_5_7_1_srcs(Name, Clip, Positions) = Bytes :-
    ( if assoc_list.search(Positions, Name, Position) then
        put_string(1u32, Name, init_builder, B1),
        put_uint32(3u32, rdsc_5_7_3_line(Position), B1, B2),
        put_uint32(4u32, rdsc_5_7_3_col(Position), B2, B3),
        rdsc_4_7_put_clip(Clip, B3, B4),
        rfcs_19_1_frame(da_schema_source, B4, Bytes)
    else
        Bytes = init_builder
    ).

    %@helper
:- func plain_common(plain_slot) = slot_common.

plain_common(P) = P ^ ps_common.

    %@helper
:- func logical_common(logical_slot) = slot_common.

logical_common(L) = L ^ ls_common.

    %@helper
:- func plain_slot_atom(intern_table, string, uint32, plain_slot)
    = builder.

plain_slot_atom(IT, Name, Clip, P) =
    rdsc_5_5_1_slot_atom(IT, Name, P ^ ps_common, no_identity, Clip).

    %@helper
:- func logical_slot_atom(intern_table, string, uint32, logical_slot)
    = builder.

logical_slot_atom(IT, Name, Clip, L) =
    rdsc_5_5_1_slot_atom(IT, Name, L ^ ls_common,
        identity(L ^ ls_role, L ^ ls_tolerance), Clip).

    %@helper
:- func hydr_for(intern_table, string, uint32, slot_common) = builder.

hydr_for(IT, SchemaName, Clip, C) = Bytes :-
    Hydratable = C ^ sc_hydratable,
    (
        Hydratable = yes,
        Bytes = rdsc_5_6_1_hydr(SchemaName, interned_text(IT, C ^ sc_name),
            Clip)
    ;
        Hydratable = no,
        Bytes = init_builder
    ).

%-----------------------------------------------------------------------------%
% SchemaTtl, SchemaLogical, Hydration
%-----------------------------------------------------------------------------%

    %@spec [RDSC.5.3.1]
    %@spec [RDSC.5.3.3]
:- func rdsc_5_3_1_sttl(string, uint64, uint32) = builder.

rdsc_5_3_1_sttl(Name, Ns, Clip) = Bytes :-
    put_string(1u32, Name, init_builder, B1),
    put_uint64(2u32, Ns, B1, B2a),
    rdsc_4_7_put_clip(Clip, B2a, B2),
    rfcs_19_1_frame(da_schema_ttl, B2, Bytes).

    %@spec [RDSC.5.4.1]
    %@spec [RDSC.5.4.3]
:- func rdsc_5_4_1_slog(string, bool, slog_lifecycle, uint32) = builder.

rdsc_5_4_1_slog(Name, Ambient, Lifecycle, Clip) = Bytes :-
    put_string(1u32, Name, init_builder, B1),
    put_bool(2u32, Ambient, B1, B2a),
    put_uint32(3u32, slog_lifecycle_code(Lifecycle), B2a, B2b),
    rdsc_4_7_put_clip(Clip, B2b, B2),
    rfcs_19_1_frame(da_schema_logical, B2, Bytes).

    % `proto/schema_logical.proto`'s `SchemaLifecycle`, less `UNSPECIFIED`.
    %
    %@helper
:- type slog_lifecycle
    --->    slog_explicit
    ;       slog_logical
    ;       slog_activation.

    %@helper
:- func slog_lifecycle_code(slog_lifecycle) = uint32.

slog_lifecycle_code(slog_explicit) = 1u32.
slog_lifecycle_code(slog_logical) = 2u32.
slog_lifecycle_code(slog_activation) = 3u32.

    % Emitted after every Slot: both runtimes refuse a Hydration on arrival if its
    % Slot has not been seen.
    %
    %@spec [RDSC.5.6.1]
    %@spec [RDSC.5.6.3]
:- func rdsc_5_6_1_hydr(string, string, uint32) = builder.

rdsc_5_6_1_hydr(SchemaName, SlotName, Clip) = Bytes :-
    put_string(1u32, SchemaName, init_builder, B1),
    put_string(2u32, SlotName, B1, B2a),
    rdsc_4_7_put_clip(Clip, B2a, B2),
    rfcs_19_1_frame(da_hydration, B2, Bytes).

    % The series atoms are all in the file's group, since `series_decl` carries no
    % module. The runtime keys a backing by name, not by group.
    %
    %@spec [RDSC.8.1]
    %@spec [RDSC.8.6]
:- func rdsc_8_1_module_group(intern_table, list(schema),
                              assoc_list(string, pos), list(doc_entry),
                              list(service_entry),
                              rete_network, uint32,
                              assoc_list(uint32, list(initial_item_ir)),
                              assoc_list(uint32, list(test_ir)),
                              module_source) = builder.

rdsc_8_1_module_group(IT, Schemas, Positions, Docs, Svcs, Network, FileClip,
        Initials, Tests, Module) = Bytes :-
    Clip = Module ^ mod_clip,
    % A schema with no module joins the file's group; its atoms carry no
    % `module_id`.
    Mine = list.filter(
        ( pred(S::in) is semidet :-
            SchemaClip = rdsc_4_7_clip(S),
            ( SchemaClip = Clip
            ; SchemaClip = 0u32, Clip = FileClip
            )
        ), Schemas),
    ( if Clip = FileClip then
        Series = concat_builders(list.map(rdsc_5a_1_backend,
            Network ^ rn_series))
    else
        Series = init_builder
    ),
    Rules = concat_builders(list.map(
        ( func(M) = concat_builders(list.map(rdsc_6_5_1_rule_group(Clip),
                M ^ mr_groups)) ),
        list.filter(( pred(M::in) is semidet :- M ^ mr_clip = Clip ),
            Network ^ rn_modules))),
    MyDocs = rdsc_14_4_6_declaration_order(list.filter(
        ( pred(D::in) is semidet :-
            ( D ^ de_clip = Clip
            ; D ^ de_clip = 0u32, Clip = FileClip
            )
        ), Docs)),
    MySvcs = list.filter(
        ( pred(S::in) is semidet :-
            ( S ^ se_clip = Clip
            ; S ^ se_clip = 0u32, Clip = FileClip
            )
        ), Svcs),
    ( if assoc_list.search(Initials, Clip, Items) then
        MyInitial = concat_builders(list.map_corresponding(
            lgra_24_3_initial_atom(Clip), uint32_upto(0u32, list.length(Items)),
            Items))
    else
        MyInitial = init_builder
    ),
    ( if assoc_list.search(Tests, Clip, MyCases) then
        MyTests = concat_builders(list.map(rlow_17_1_test_group(Clip),
            MyCases))
    else
        MyTests = init_builder
    ),
    Bytes = concat_builders([rdsc_14_2_1_dsrc(Module),
        concat_builders(list.map(rdsc_5_1_schema_atoms(IT, Positions), Mine)),
        Series, Rules,
        concat_builders(list.map(
            ( func(S) = ladp_8_2_1_svcd(S ^ se_decl, S ^ se_kwargs,
                S ^ se_clip) ), MySvcs)),
        concat_builders(list.map(rdsc_14_4_1_docs, MyDocs)),
        MyInitial,
        MyTests]).

    % By `de_pos`, an injected builtin's doc first: its `de_pos` is a line of its
    % own text. The sort is stable, so the builtins keep their order.
    %
    %@spec [RDSC.14.4.6]
    %@spec [RDSC.8.4]
:- func rdsc_14_4_6_declaration_order(list(doc_entry)) = list(doc_entry).

rdsc_14_4_6_declaration_order(Docs) = list.sort(
    ( func(A, B) = R :-
        Ao = A ^ de_origin,
        Bo = B ^ de_origin,
        (
            Ao = compiler_injected,
            Bo = compiler_injected,
            R = (=)
        ;
            Ao = compiler_injected,
            Bo = author_declared,
            R = (<)
        ;
            Ao = author_declared,
            Bo = compiler_injected,
            R = (>)
        ;
            Ao = author_declared,
            Bo = author_declared,
            compare(R, A ^ de_pos, B ^ de_pos)
        )
    ), Docs).

    % The module's text verbatim, comments included. `compression` is written, as
    % in `rdsc_5_8_1_sdef`.
    %
    %@spec [RDSC.14.2.1]
    %@spec [RDSC.14.2.2]
    %@spec [RDSC.14.2.3]
    %@spec [RLOW.7.8.1]
:- func rdsc_14_2_1_dsrc(module_source) = builder.

    %@spec [LADP.8.2.1]
:- func ladp_8_2_1_svcd(ast_service_decl, list(service_kwarg), uint32)
    = builder.

ladp_8_2_1_svcd(Service, Declared, Clip) = Bytes :-
    put_string(1u32, dotted_service(Service ^ asv_name), init_builder, B1),
    % Sorted by name ([LGRA.23.2]); `string`'s order is UTF-8 byte order here.
    Kwargs = list.sort(
        ( func(A, B) = R :-
            compare(R, A ^ sk_name, B ^ sk_name)
        ), Declared),
    list.foldl(ladp_8_2_1_kwarg, Kwargs, B1, B2),
    % A declaration with neither form never reaches here: `validate` refuses it.
    Response = Service ^ asv_response,
    (
        Response = ar_schema(Resp),
        put_string(3u32, Resp ^ id_name, B2, B3)
    ;
        Response = ar_none(_),
        put_bool(5u32, yes, B2, B3)
    ;
        Response = ar_absent,
        B3 = B2
    ),
    % Field 4, the hydration block, is not written: the parser builds none.
    rdsc_4_7_put_clip(Clip, B3, B4),
    rfcs_19_1_frame(da_service_def, B4, Bytes).

    %@helper
:- pred ladp_8_2_1_kwarg(service_kwarg::in, builder::in, builder::out) is det.

ladp_8_2_1_kwarg(Kwarg, !B) :-
    put_string(1u32, Kwarg ^ sk_type, init_builder, K1),
    put_string(2u32, Kwarg ^ sk_name, K1, K2),
    put_bool(3u32, Kwarg ^ sk_required, K2, K3),
    put_bool(4u32, Kwarg ^ sk_literal, K3, K4),
    Default = Kwarg ^ sk_default,
    (
        Default = no_default,
        K6 = K4
    ;
        Default = default_unstated,
        put_bool(5u32, yes, K4, K6)
    ;
        Default = default_text(Text),
        put_bool(5u32, yes, K4, K5),
        put_string(6u32, Text, K5, K6)
    ),
    put_message(2u32, K6, !B).

rdsc_6a_2_4_kwargs(RF, Service) =
    list.map(service_kwarg_of(RF), Service ^ asv_kwargs).

    %@helper
:- func service_kwarg_of(dsc.resolve.resolved_file, ast_service_kwarg)
    = service_kwarg.

service_kwarg_of(RF, Kwarg) = service_kwarg(Kwarg ^ ask_name ^ id_name, Type,
        kwarg_has(Mods, mod_required), kwarg_has(Mods, mod_literal),
        Default) :-
    Spelled = Kwarg ^ ask_type ^ id_name,
    Type = rdsc_6a_2_7_ds_type(RF, Spelled),
    Mods = Kwarg ^ ask_modifiers,
    ( if
        list.find_first_match(
            ( pred(M::in) is semidet :- M = akm_default(_, _) ), Mods, Mod),
        Mod = akm_default(E, _)
    then
        ( if
            rdsc_6a_2_4_text(dsc.resolve.kwarg_scope(RF, Kwarg), Spelled, E,
                Text)
        then
            Default = default_text(Text)
        else
            Default = default_unstated
        )
    else
        Default = no_default
    ).

    %@spec [RDSC.6a.2.7]
:- func rdsc_6a_2_7_ds_type(dsc.resolve.resolved_file, string) = string.

rdsc_6a_2_7_ds_type(RF, Spelled) =
    ( if
        map.search(dsc.resolve.rf_types(RF), Spelled,
            dsc.resolve.te_schema(Schema))
    then
        Schema ^ as_own
    else
        Spelled
    ).

    % The quantity is `dsc.quantity`'s, the fold `dsc.rete` lowers an omitted kwarg
    % through and `dsc.validate` checks the default through, so the three agree.
    % `RF` is the declaring file's (`dsc.resolve.kwarg_scope`), for an imported
    % service too. `dsc.validate` has refused every default no arm fits.
    %
    %@spec [RDSC.6a.2.4]
:- pred rdsc_6a_2_4_text(dsc.resolve.resolved_file::in, string::in,
                         dsc.expr.lgra_9_3_1_expr::in, string::out)
    is semidet.

rdsc_6a_2_4_text(RF, Type, E, Text) :-
    ( if Type = "Int" then
        signed_int(E, I),
        Text = string.int64_to_string(I)
    else if Type = "Float" then
        ( if signed_float(E, F0) then
            F = F0
        else
            signed_int(E, I),
            dsc.exact.to_float(dsc.exact.from_int64(I), F)
        ),
        Text = ds.float_text.canonical(F)
    else if Type = "String" then
        E = dsc.expr.ex_string(Raw, _),
        literal_value(Raw, Value),
        Text = "\"" ++ string.replace_all(string.replace_all(Value,
            "\\", "\\\\"), "\"", "\\\"") ++ "\""
    else if Type = "Bool" then
        E = dsc.expr.ex_bool(B, _),
        ( B = yes, Text = "true"
        ; B = no, Text = "false"
        )
    else
        map.search(dsc.resolve.rf_types(RF), Type,
            dsc.resolve.te_unit(Kind, Declared)),
        dsc.quantity.quantity_base(RF, E, Base),
        (
            Kind = dsc.resolve.uk_symbol(Dimension),
            dsc.quantity.ladp_8_5_2_in_unit(RF, Type, Base, Value)
        ;
            Kind = dsc.resolve.uk_dimension,
            Dimension = Declared,
            Value = Base
        ;
            Kind = dsc.resolve.uk_scalar,
            Dimension = Declared,
            Value = Base
        ),
        ( if dsc.quantity.whole_number_dimension(RF, Dimension) then
            % Never wrapped ([LUNI.2.4.1]): one outside int64 states no text.
            dsc.exact.luni_2_4_1_whole_int64(Value, I),
            Text = string.int64_to_string(I)
        else
            dsc.exact.to_float(Value, F),
            Text = ds.float_text.canonical(F)
        )
    ).

    %@helper
:- pred signed_int(dsc.expr.lgra_9_3_1_expr::in, int64::out) is semidet.

signed_int(E, I) :-
    ( if
        E = dsc.expr.ex_unary(dsc.expr.uo_neg, dsc.expr.ex_int(N, _), _)
    then
        I = -N
    else
        E = dsc.expr.ex_int(I, _)
    ).

    %@helper
:- pred signed_float(dsc.expr.lgra_9_3_1_expr::in, float::out) is semidet.

signed_float(E, F) :-
    ( if
        E = dsc.expr.ex_unary(dsc.expr.uo_neg, dsc.expr.ex_float(X, _), _)
    then
        F = -X
    else
        E = dsc.expr.ex_float(F, _)
    ).

    %@helper
:- type kwarg_mod_kind
    --->    mod_required
    ;       mod_literal.

    %@helper
:- func kwarg_has(list(ast_kwarg_modifier), kwarg_mod_kind) = bool.

kwarg_has(Mods, Kind) =
    ( if
        list.find_first_match(
            ( pred(M::in) is semidet :-
                ( M = akm_required(_), Kind = mod_required
                ; M = akm_literal(_), Kind = mod_literal
                )
            ), Mods, _)
    then
        yes
    else
        no
    ).

    %@helper
:- func dotted_service(list(ident)) = string.

dotted_service(Segments) =
    string.join_list(".", list.map((func(I) = I ^ id_name), Segments)).

    % `Clip` is the module whose rule made the node, whose source the position
    % reads against.
    %
    %@spec [RDSC.14.3.1]
    %@spec [RDSC.14.3.2]
    %@spec [RDSC.14.3.3]
:- func rdsc_14_3_1_span(uint32, node_span) = builder.

rdsc_14_3_1_span(Clip, Span) = Bytes :-
    put_uint32(1u32, Span ^ ns_node, init_builder, B1),
    put_uint32(4u32, rdsc_5_7_3_line(Span ^ ns_pos), B1, B2),
    put_uint32(5u32, rdsc_5_7_3_col(Span ^ ns_pos), B2, B3),
    rdsc_4_7_put_clip(Clip, B3, B4),
    rfcs_19_1_frame(da_line_span, B4, Bytes).

    %@spec [RDSC.14.4.1]
    %@spec [RDSC.14.4.2]
    %@spec [RDSC.14.4.3]
:- func rdsc_14_4_1_docs(doc_entry) = builder.

rdsc_14_4_1_docs(Doc) = Bytes :-
    put_uint32(1u32, rdsc_14_4_3_target(Doc ^ de_target), init_builder, B1),
    % `module_id` is field 2 here and 10 elsewhere, so not `rdsc_4_7_put_clip`.
    put_uint32(2u32, Doc ^ de_clip, B1, B2),
    put_string(3u32, Doc ^ de_schema, B2, B3),
    put_string(4u32, Doc ^ de_slot, B3, B4),
    put_string(5u32, Doc ^ de_rule, B4, B5),
    put_string(6u32, Doc ^ de_text, B5, B6),
    put_uint32(7u32, rdsc_5_7_3_line(Doc ^ de_pos), B6, B7),
    put_uint32(8u32, rdsc_5_7_3_col(Doc ^ de_pos), B7, B8),
    rfcs_19_1_frame(da_doc_string, B8, Bytes).

    %@spec [RDSC.14.4.3]
:- func rdsc_14_4_3_target(doc_target) = uint32.

rdsc_14_4_3_target(dt_schema) = 2u32.
rdsc_14_4_3_target(dt_slot)   = 3u32.
rdsc_14_4_3_target(dt_rule)   = 4u32.

rdsc_14_2_1_dsrc(Module) = Bytes :-
    put_string(1u32, Module ^ mod_file, init_builder, B1),
    put_uint32(2u32, rdsc_4_4_compression_none, B1, B2),
    % Field 3 is `bytes`; `put_string` writes the UTF-8 under the same wire type.
    put_string(3u32, Module ^ mod_source, B2, B3),
    rdsc_4_7_put_clip(Module ^ mod_clip, B3, B4),
    rfcs_19_1_frame(da_ds_source, B4, Bytes).

    % `0` where the schema has no module, which `rdsc_4_7_put_clip` omits.
    %
    %@helper
:- func rdsc_4_7_clip(schema) = uint32.

rdsc_4_7_clip(S) =
    ( if S ^ s_module = yes(Module) then module_id_value(Module) else 0u32 ).

    % `dsc.token.pos`'s column is 0-based and the wire's 1-based.
    %
    %@spec [RDSC.5.7.3]
    %@spec [RDSC.6.7.3]
:- func rdsc_5_7_3_col(pos) = uint32.

rdsc_5_7_3_col(Position) = uint32.det_from_int(Position ^ p_col + 1).

    %@helper
:- func rdsc_5_7_3_line(pos) = uint32.

rdsc_5_7_3_line(Position) = uint32.det_from_int(Position ^ p_line).

    % Zero, the unset sentinel, is not written.
    %
    %@spec [RDSC.4.7]
:- pred rdsc_4_7_put_clip(uint32::in, builder::in, builder::out) is det.

rdsc_4_7_put_clip(Clip, !B) :-
    ( if Clip = 0u32 then
        true
    else
        put_uint32(10u32, Clip, !B)
    ).

%-----------------------------------------------------------------------------%
% Slot -- [RDSC.5.5]
%-----------------------------------------------------------------------------%

    %@helper
:- type identity
    --->    no_identity
    ;       identity(identity_role, tolerance).

    % Fields ascending ([RFCS.19.5]), so `rdsc_4_7_put_clip` (field 10) goes
    % between the role and `nullable`.
    %
    %@spec [RDSC.5.5.1]
    %@spec [RDSC.5.5.2]
    %@spec [RDSC.5.5.3]
    %@spec [RDSC.5.5.5]
    %@spec [RDSC.5.5.7]
    %@spec [RDSC.5.5.9]
    %@spec [RFCS.19.5]
:- func rdsc_5_5_1_slot_atom(intern_table, string, slot_common, identity,
                             uint32)
    = builder.

rdsc_5_5_1_slot_atom(IT, SchemaName, C, Identity, Clip) = Bytes :-
    put_string(1u32, SchemaName, init_builder, B1),
    put_string(2u32, interned_text(IT, C ^ sc_name), B1, B2),
    Kind = C ^ sc_kind,
    put_uint32(3u32, rdsc_5_5_4_slot_kind(Kind), B2, B3),
    (
        Kind = k_schema(Ref),
        put_string(4u32, interned_text(IT, schema_name_ref(Ref)), B3, B4)
    ;
        Kind = k_int,
        B4 = B3
    ;
        Kind = k_float,
        B4 = B3
    ;
        Kind = k_string,
        B4 = B3
    ;
        Kind = k_bool,
        B4 = B3
    ;
        Kind = k_json,
        B4 = B3
    ;
        Kind = k_bytes,
        B4 = B3
    ;
        Kind = k_time,
        B4 = B3
    ;
        Kind = k_date,
        B4 = B3
    ;
        Kind = k_duration,
        B4 = B3
    ),
    put_bool(5u32, C ^ sc_sampled, B4, B5),
    put_bool(6u32, C ^ sc_retained, B5, B6),
    (
        Identity = no_identity,
        B8 = B6
    ;
        Identity = identity(Role, Tolerance),
        put_tolerance(Tolerance, B6, B7),
        put_uint32(9u32, rdsc_5_5_7_identity_role(Role), B7, B8)
    ),
    rdsc_4_7_put_clip(Clip, B8, B9),
    Nullable = C ^ sc_nullable,
    (
        Nullable = nullable,
        put_bool(11u32, yes, B9, B10)
    ;
        Nullable = non_null,
        B10 = B9
    ),
    Capacity = C ^ sc_capacity,
    (
        Capacity = unbounded,
        B11 = B10
    ;
        Capacity = at_most(N),
        put_uint32(12u32, N, B10, B11)
    ),
    Units = C ^ sc_units,
    (
        Units = no,
        B13 = B11
    ;
        Units = yes(unit_conversion(To, From)),
        put_message(13u32, rdsc_4a_9_1_expr(IT, To), B11, B12),
        put_message(14u32, rdsc_4a_9_1_expr(IT, From), B12, B13)
    ),
    rfcs_19_1_frame(da_slot, B13, Bytes).

    % `within(0.0)` writes nothing and decodes as `exact`, so the round trip is
    % not the identity there.
    %
    %@helper
:- pred put_tolerance(tolerance::in, builder::in, builder::out) is det.

put_tolerance(exact, !B).
put_tolerance(within(F), !B) :-
    ( if put_double(7u32, F, !.B, Next) then
        !:B = Next
    else
        unexpected($pred, "tolerance is not representable as a double")
    ).

    %@spec [RDSC.5.5.4]
:- func rdsc_5_5_4_slot_kind(slot_kind) = uint32.

rdsc_5_5_4_slot_kind(k_int) = 1u32.
rdsc_5_5_4_slot_kind(k_float) = 2u32.
rdsc_5_5_4_slot_kind(k_string) = 3u32.
rdsc_5_5_4_slot_kind(k_bool) = 4u32.
rdsc_5_5_4_slot_kind(k_json) = 5u32.
rdsc_5_5_4_slot_kind(k_schema(_)) = 6u32.
rdsc_5_5_4_slot_kind(k_bytes) = 7u32.
rdsc_5_5_4_slot_kind(k_time) = 8u32.
rdsc_5_5_4_slot_kind(k_date) = 9u32.
rdsc_5_5_4_slot_kind(k_duration) = 10u32.

    %@spec [RDSC.5.5.7]
:- func rdsc_5_5_7_identity_role(identity_role) = uint32.

rdsc_5_5_7_identity_role(role_key) = 1u32.
rdsc_5_5_7_identity_role(role_mutable) = 2u32.
rdsc_5_5_7_identity_role(role_engine) = 3u32.

%-----------------------------------------------------------------------------%
% DialectInfo, CapabilityInfo -- [RDSC.15], [RDSC.16.2]
%-----------------------------------------------------------------------------%

    %@spec [RDSC.15.1]
    %@spec [RDSC.15.2]
    %@spec [RDSC.15.3]
    %@spec [RDSC.15.4]
:- func rdsc_15_1_dial(binding) = builder.

rdsc_15_1_dial(Binding) = Bytes :-
    put_string(1u32, Binding ^ bd_program ^ ps_dialect, init_builder, B),
    rfcs_19_1_frame(da_dialect_info, B, Bytes).

    % Always emitted, even with an empty body.
    %
    %@spec [RDSC.16.2.1]
    %@spec [RDSC.16.2.2]
    %@spec [RDSC.16.2.3]
    %@spec [RDSC.16.2.4]
    %@spec [RDSC.16.2.6]
:- func rdsc_16_2_1_capb(binding) = builder.

rdsc_16_2_1_capb(Binding) = Bytes :-
    put_capabilities(2u32, Binding ^ bd_program ^ ps_enabled, init_builder, B1),
    put_capabilities(3u32, Binding ^ bd_requires, B1, B2),
    rfcs_19_1_frame(da_capability_info, B2, Bytes).

%-----------------------------------------------------------------------------%
% RealtimeContract -- [RTCT.6], [RDSC.16.3]
%-----------------------------------------------------------------------------%

    % Fields are written when zero, but for `default_node_cap` and the two cache
    % caps. The per-node capacities take the smallest of the three encodings, ties
    % broken legacy, default-plus-overrides, packed.
    %
    %@spec [RTCT.6.1]
    %@spec [RTCT.6.2]
    %@spec [RTCT.6.3]
    %@spec [RTCT.6.4]
    %@spec [RTCT.6.7]
    %@spec [RTCT.6.7.1]
    %@spec [RTCT.6.7.2]
    %@spec [RTCT.6.7.3]
    %@spec [RTCT.6.7.4]
    %@spec [RTCT.6.7.5]
    %@spec [RTCT.6.8]
    %@spec [RTCT.6.8.1]
    %@spec [RDSC.16.3.1]
    %@spec [RDSC.16.3.2]
    %@spec [RDSC.16.3.5]
    %@spec [RDSC.3.8]
:- func rtct_6_2_dsrt(contract, list(uint8)) = builder.

rtct_6_2_dsrt(C, RtSha) = Bytes :-
    put_uint64_always(1u32, u32_64(C ^ c_wm_max), init_builder, B1),
    put_uint64_always(2u32, u32_64(C ^ c_agenda_cap), B1, B2),
    put_uint64_always(3u32, u32_64(C ^ c_max_fires), B2, B3),
    put_uint64_always(4u32, u32_64(C ^ c_token_pool_cap), B3, B4),
    put_uint64_always(5u32, u32_64(C ^ c_intern_cap), B4, B5),
    put_uint64_always(6u32, u32_64(C ^ c_intern_bytes_cap), B5, B6),
    put_uint64_always(7u32, C ^ c_pump_wcet_ns, B6, B7),
    {Encoding, NodeBytes} = node_encoding(C ^ c_nodes),
    ( if Encoding = legacy_nodes then
        put_bytes(NodeBytes, B7, B8)
    else
        B8 = B7
    ),
    list.foldl(put_series_cap, C ^ c_series, B8, B9),
    put_delimited(10u32, RtSha, B9, B10),
    ( if Encoding = compact_nodes then
        put_bytes(NodeBytes, B10, B11)
    else
        B11 = B10
    ),
    put_uint32(15u32, C ^ c_cache_cap, B11, B12),
    put_uint64(16u32, C ^ c_cache_bytes_cap, B12, B13),
    rfcs_19_1_frame(da_realtime_contract, B13, Bytes).

    %@helper
:- func u32_64(uint32) = uint64.

u32_64(V) = uint32.cast_to_uint64(V).

    %@helper
:- pred put_series_cap(series_cap::in, builder::in, builder::out) is det.

put_series_cap(S, !B) :-
    put_uint64_always(1u32, u32_64(S ^ sc_id), init_builder, S1),
    put_uint64_always(2u32, u32_64(S ^ sc_capacity), S1, S2),
    put_message(9u32, S2, !B).

    %@helper
:- type node_encoding
    --->    legacy_nodes
    ;       compact_nodes.

    %@helper
:- func node_encoding(list(node_cap)) = {node_encoding, list(uint8)}.

node_encoding(Nodes) = Choice :-
    (
        Nodes = [],
        Choice = {legacy_nodes, []}
    ;
        Nodes = [_ | _],
        Legacy = builder_bytes(list.foldl(legacy_node, Nodes, init_builder)),
        Default = dominant_capacity(Nodes),
        Overrides = default_overrides(Nodes, Default),
        Packed = packed_caps(Nodes),
        ( if
            list.length(Legacy) =< list.length(Overrides),
            list.length(Legacy) =< list.length(Packed)
        then
            Choice = {legacy_nodes, Legacy}
        else if list.length(Overrides) =< list.length(Packed) then
            Choice = {compact_nodes, Overrides}
        else
            Choice = {compact_nodes, Packed}
        )
    ).

    %@helper
:- func legacy_node(node_cap, builder) = builder.

legacy_node(N, B0) = B :-
    put_uint64_always(1u32, u32_64(N ^ nc_id), init_builder, N1),
    put_string_always(2u32, N ^ nc_kind, N1, N2),
    put_uint64_always(3u32, u32_64(N ^ nc_capacity), N2, N3),
    put_message(8u32, N3, B0, B).

    % The most frequent capacity, ties to the smallest: the default that
    % leaves the fewest overrides.
    %
    %@helper
:- func dominant_capacity(list(node_cap)) = uint32.

dominant_capacity(Nodes) = Default :-
    Caps = list.sort(list.map((func(N) = N ^ nc_capacity), Nodes)),
    list.foldl2(keep_most_frequent, runs(Caps), 0u32, Default, 0, _).

    % Strictly more frequent replaces, so a tie keeps the earlier -- smaller --
    % capacity.
    %
    %@helper
:- pred keep_most_frequent(pair(uint32, int)::in, uint32::in, uint32::out,
                           int::in, int::out) is det.

keep_most_frequent(Cap - Count, Best0, Best, Most0, Most) :-
    ( if Count > Most0 then
        Best = Cap, Most = Count
    else
        Best = Best0, Most = Most0
    ).

    %@helper
:- func runs(list(uint32)) = assoc_list(uint32, int).

runs([]) = [].
runs([C | Cs]) = Runs :-
    Rest = runs(Cs),
    ( if Rest = [C - N | Tail] then
        Runs = [C - (N + 1) | Tail]
    else
        Runs = [C - 1 | Rest]
    ).

    %@helper
:- func default_overrides(list(node_cap), uint32) = list(uint8).

default_overrides(Nodes, Default) = builder_bytes(B) :-
    put_uint64_always(11u32, uint64.det_from_int(list.length(Nodes)),
        init_builder, B1),
    put_uint32(12u32, Default, B1, B2),
    list.foldl((pred(N::in, BIn::in, BOut::out) is det :-
        ( if N ^ nc_capacity = Default then
            BOut = BIn
        else
            put_uint64_always(1u32, u32_64(N ^ nc_id), init_builder, O1),
            put_uint64_always(2u32, u32_64(N ^ nc_capacity), O1, O2),
            put_message(13u32, O2, BIn, BOut)
        )), Nodes, B2, B).

    %@helper
:- func packed_caps(list(node_cap)) = list(uint8).

packed_caps(Nodes) = builder_bytes(B) :-
    put_uint64_always(11u32, uint64.det_from_int(list.length(Nodes)),
        init_builder, B1),
    Varints = list.foldl((func(N, VB) = VB1 :-
        put_varint(u32_64(N ^ nc_capacity), VB, VB1)), Nodes, init_builder),
    put_message(14u32, Varints, B1, B).

%-----------------------------------------------------------------------------%
% Series backend atoms -- [RDSC.5a]
%-----------------------------------------------------------------------------%

    % `ds.series.decode_backing` reversed. Two layouts: the first arm puts
    % `window_ns` at 4; the second puts `element_type` at 4 and shifts the rest up
    % one, with `SeriesBackendIntervalPulse` leaving 4 a hole.
    %
    % `module_id`, field 10, is not written.
    %
    %@spec [RDSC.5a.1]
    %@spec [RDSC.5a.4.1]
    %@spec [RDSC.5a.4.2]
    %@spec [RDSC.5a.4.3]
    %@spec [RDSC.5a.4.4]
    %@spec [RDSC.5a.5.1]
    %@spec [RDSC.5a.5.2]
    %@spec [RDSC.5a.5.3]
    %@spec [RDSC.5a.7d.1]
    %@spec [RDSC.5a.7d.2]
    %@spec [RDSC.5a.7e.1]
    %@spec [RDSC.5a.7e.2]
    %@spec [RDSC.5a.7e.3]
    %@spec [RDSC.5a.7g.1]
    %@spec [RDSC.5a.7g.2]
    %@spec [RDSC.5a.7g.3]
    %@spec [RDSC.5a.8.2]
:- func rdsc_5a_1_backend(series_decl) = builder.

rdsc_5a_1_backend(D) = Bytes :-
    Backing = D ^ sd_backing,
    put_string(1u32, D ^ sd_schema, init_builder, B1),
    put_string(2u32, D ^ sd_slot, B1, B2),
    put_string(3u32, D ^ sd_id_slot, B2, B3),
    (
        ( Backing = bk_welford ; Backing = bk_monotonic_deque
        ; Backing = bk_reservoir ),
        put_uint64(4u32, D ^ sd_window, B3, B4),
        put_uint64(5u32, D ^ sd_persist, B4, B5),
        ( if Backing = bk_welford then
            B6 = B5
        else
            put_uint32(6u32, D ^ sd_max, B5, B6)
        ),
        Layout = B6
    ;
        ( Backing = bk_ring_buffer ; Backing = bk_fifo_deque
        ; Backing = bk_interval_pulse ; Backing = bk_numeric_integral ),
        ( if Backing = bk_interval_pulse then
            B4 = B3
        else
            put_uint32(4u32, element_number(D ^ sd_element), B3, B4)
        ),
        put_uint64(5u32, D ^ sd_window, B4, B5),
        put_uint64(6u32, D ^ sd_persist, B5, B6),
        put_uint32(7u32, D ^ sd_max, B6, B7),
        ( if Backing = bk_numeric_integral then
            put_uint32(8u32, time_model_number(D ^ sd_time), B7, B8),
            put_uint32(9u32, gap_policy_number(D ^ sd_gap), B8, Layout)
        else
            Layout = B7
        )
    ),
    % Field 11 on every layout: the `nulls:` policy, for a nullable source.
    ( if D ^ sd_nulls = np_unspecified then
        Body = Layout
    else
        put_uint32(11u32, null_policy_number(D ^ sd_nulls), Layout, Body)
    ),
    rfcs_19_1_frame(backing_atom(Backing), Body, Bytes).

    %@helper
:- func backing_atom(backing) = dsc_atom.

backing_atom(bk_welford) = da_series_backend_welford_ewma.
backing_atom(bk_ring_buffer) = da_series_backend_ring_buffer.
backing_atom(bk_monotonic_deque) = da_series_backend_monotonic_deque.
backing_atom(bk_fifo_deque) = da_series_backend_fifo_deque.
backing_atom(bk_reservoir) = da_series_backend_reservoir.
backing_atom(bk_interval_pulse) = da_series_backend_interval_pulse.
backing_atom(bk_numeric_integral) = da_series_backend_numeric_integral.

    %@helper
:- func element_number(element_type) = uint32.

element_number(el_unspecified) = 0u32.
element_number(el_float) = 1u32.
element_number(el_int) = 2u32.
element_number(el_string) = 3u32.
element_number(el_bool) = 4u32.

    %@helper
:- func time_model_number(time_model) = uint32.

time_model_number(tm_unspecified) = 0u32.
time_model_number(tm_sliding) = 1u32.
time_model_number(tm_all_time) = 2u32.
time_model_number(tm_tumbling) = 3u32.

    %@helper
:- func gap_policy_number(gap_policy) = uint32.

gap_policy_number(gp_unspecified) = 0u32.
gap_policy_number(gp_hold) = 1u32.
gap_policy_number(gp_zero) = 2u32.
gap_policy_number(gp_skip) = 3u32.

    %@helper
:- func null_policy_number(null_policy) = uint32.

null_policy_number(np_unspecified) = 0u32.
null_policy_number(np_skip) = 1u32.
null_policy_number(np_hold) = 2u32.
null_policy_number(np_zero) = 3u32.

%-----------------------------------------------------------------------------%
% The rule group -- [RDSC.6.5] .. [RDSC.6.8]
%-----------------------------------------------------------------------------%

    % `Clip` is the module that declared the rule.
    %
    %@spec [RDSC.6.5.1]
    %@spec [RDSC.6.5.2]
    %@spec [RDSC.6.5.3]
    %@spec [RDSC.6.5.4]
    %@spec [RDSC.6.7.1]
    %@spec [RDSC.6.7.2]
    %@spec [RDSC.6.8.1]
    %@spec [RDSC.6.8.2]
    %@spec [RDSC.6.8.3]
    %@spec [RDSC.6.8.7]
    %@spec [RDSC.6.2]
    %@spec [RDSC.8.3]
:- func rdsc_6_5_1_rule_group(uint32, rule_group) = builder.

rdsc_6_5_1_rule_group(Clip, G) = concat_builders([Cool, Source, Display]) :-
    Name = G ^ rg_rule,
    Cool = window_atom(da_rule_cooldown, Name, G ^ rg_cooldown, Clip),
    put_string(1u32, Name, init_builder, S1),
    Pos = G ^ rg_pos,
    put_uint32(3u32, rdsc_5_7_3_line(Pos), S1, S2),
    put_uint32(4u32, rdsc_5_7_3_col(Pos), S2, S3a),
    rdsc_4_7_put_clip(Clip, S3a, S3),
    rfcs_19_1_frame(da_rule_source, S3, Source),
    Template = G ^ rg_display,
    ( if Template = "" then
        Display = init_builder
    else
        put_string(1u32, Name, init_builder, D1),
        put_string(2u32, Template, D1, D2a),
        rdsc_4_7_put_clip(Clip, D2a, D2),
        rfcs_19_1_frame(da_rule_debug_name, D2, Display)
    ).

    %@helper
:- func window_atom(dsc_atom, string, maybe(uint64), uint32) = builder.

window_atom(_, _, no, _) = init_builder.
window_atom(Atom, Name, yes(Ns), Clip) = Bytes :-
    put_string(1u32, Name, init_builder, B1),
    put_uint64(2u32, Ns, B1, B2a),
    rdsc_4_7_put_clip(Clip, B2a, B2),
    rfcs_19_1_frame(Atom, B2, Bytes).

%-----------------------------------------------------------------------------%
% AlphaNode / BetaNode / TerminalNode -- [RDSC.4a]
%-----------------------------------------------------------------------------%

    %@spec [RDSC.4a.6]
    %@spec [RDSC.4a.2]
:- func rdsc_4a_6_alfa(intern_table, raw_alpha) = builder.

rdsc_4a_6_alfa(IT, raw_alpha(Id, Schema, Tests)) = Bytes :-
    put_uint32(1u32, node_id_value(Id), init_builder, B1),
    put_string(2u32, interned_text(IT, schema_name_ref(Schema)), B1, B2),
    list.foldl(put_alpha_test(IT), Tests, B2, B3),
    rfcs_19_1_frame(da_alpha_node, B3, Bytes).

    %@helper
:- pred put_alpha_test(intern_table::in, alpha_test::in,
                       builder::in, builder::out) is det.

put_alpha_test(IT, Test, !B) :-
    (
        Test = at_eq(Slot, Lit),
        Kind = 0u32, Op = 0u32, MaybeLit = yes(Lit), Pattern = ""
    ;
        Test = at_cmp(Slot, BinOp, Lit),
        Kind = 1u32, Op = alpha_cmp_op(BinOp), MaybeLit = yes(Lit), Pattern = ""
    ;
        Test = at_regex(Slot, Pattern),
        Kind = 2u32, Op = 0u32, MaybeLit = no
    ),
    put_uint32(1u32, Kind, init_builder, T1),
    put_uint32(2u32, slot_wire(Slot), T1, T2),
    put_uint32(3u32, Op, T2, T3),
    (
        MaybeLit = yes(L),
        put_message(4u32, alpha_literal_body(IT, L), T3, T4)
    ;
        MaybeLit = no,
        T4 = T3
    ),
    put_string(5u32, Pattern, T4, T5),
    put_message(3u32, T5, !B).

    %@helper
:- func alpha_cmp_op(binop) = uint32.

alpha_cmp_op(Op) = N :-
    ( if Op = op_eq then N = 0u32
    else if Op = op_ne then N = 1u32
    else if Op = op_lt then N = 2u32
    else if Op = op_gt then N = 3u32
    else if Op = op_le then N = 4u32
    else if Op = op_ge then N = 5u32
    else unexpected($pred, "an alpha test carries only a comparison")
    ).

    % A oneof, so the set member is written even at its zero.
    %
    %@helper
:- func alpha_literal_body(intern_table, alpha_literal) = builder.

alpha_literal_body(_, al_int(I)) = int_present(1u32, I, init_builder).
alpha_literal_body(_, al_float(F)) = double_present(2u32, F, init_builder).
alpha_literal_body(IT, al_string(Ref)) = B :-
    put_string_always(3u32, interned_text(IT, Ref), init_builder, B).
alpha_literal_body(_, al_bool(V)) = B :-
    put_uint64_always(4u32, bool_bit(V), init_builder, B).

    %@spec [RDSC.4a.7]
:- func rdsc_4a_7_beta(intern_table, raw_beta) = builder.

rdsc_4a_7_beta(IT, raw_beta(Id, Right, Parent, Tests, Negative)) = Bytes :-
    put_uint32(1u32, node_id_value(Id), init_builder, B1),
    put_uint32(2u32, Right, B1, B2),
    put_uint32(3u32, Parent, B2, B3),
    list.foldl((pred(E::in, BIn::in, BOut::out) is det :-
        put_message(4u32, rdsc_4a_9_1_expr(IT, E), BIn, BOut)), Tests, B3, B4),
    put_bool(5u32, Negative, B4, B5),
    rfcs_19_1_frame(da_beta_node, B5, Bytes).

    %@spec [RDSC.4a.8]
:- func rdsc_4a_8_term(intern_table, raw_terminal) = builder.

rdsc_4a_8_term(IT, Term) = Bytes :-
    Term = raw_terminal(Id, Parent, RuleRef, Binds, Guard, _, Actions),
    Rule = interned_text(IT, RuleRef),
    put_uint32(1u32, node_id_value(Id), init_builder, B1),
    put_uint32(2u32, Parent, B1, B2),
    put_string(3u32, Rule, B2, B3),
    put_uint32(4u32, uint32.det_from_int(Binds), B3, B4),
    list.foldl((pred(A::in, BIn::in, BOut::out) is det :-
        put_message(6u32, rdsc_4a_8_action(IT, Rule, A), BIn, BOut)),
        Actions, B4, B5),
    (
        Guard = yes(G),
        put_message(7u32, rdsc_4a_9_1_expr(IT, G), B5, B6)
    ;
        Guard = no,
        B6 = B5
    ),
    rfcs_19_1_frame(da_terminal_node, B6, Bytes).

%-----------------------------------------------------------------------------%
% Actions -- the inverse of `ds.dsc_action.verb/5`
%-----------------------------------------------------------------------------%

    % `emit` and the two withdraws are kinds of their own. Every other verb is
    % `ACTION_CALL`, kind 0, whose expression is a call to the verb's builtin.
    %
    %@spec [RDSC.4a.8]
:- func rdsc_4a_8_action(intern_table, string, inline_action) = builder.

rdsc_4a_8_action(IT, Rule, IA) = B :-
    (
        IA = ia_log(Level, Msg),
        B = call_action(call_expr(fn_log,
            [int_lit(log_level_number(Level)), str_lit(Rule),
             rdsc_4a_9_1_expr(IT, Msg)]), no, IT)
    ;
        IA = ia_assert(Mode, Schema, Slots, Ttl),
        Kind = ( if Mode = logical then 2u32 else 1u32 ),
        put_uint32(1u32, Kind, init_builder, A1),
        put_string(3u32, interned_text(IT, Schema), A1, A2),
        list.foldl(put_assign(IT), Slots, A2, A3),
        put_ttl(IT, Ttl, A3, B)
    ;
        IA = ia_publish(Schema, Args, Ttl),
        B = call_action(call_expr(fn_publish,
            [str_lit(interned_text(IT, Schema)) |
             list.map(rdsc_4a_9_1_expr(IT), Args)]), Ttl, IT)
    ;
        IA = ia_call(Service, Corr, Kwargs, Gate),
        Call = call_expr(fn_call,
            [str_lit(interned_text(IT, Service)), rdsc_4a_9_1_expr(IT, Corr) |
             kwarg_operands(IT, Kwargs)]),
        B = call_action(gated(IT, Gate, Call), no, IT)
    ;
        IA = ia_cache_set(Key, Value, MaybeTtl),
        (
            MaybeTtl = yes(Ttl),
            Args = [rdsc_4a_9_1_expr(IT, Key), rdsc_4a_9_1_expr(IT, Value),
                rdsc_4a_9_1_expr(IT, Ttl)]
        ;
            MaybeTtl = no,
            Args = [rdsc_4a_9_1_expr(IT, Key), rdsc_4a_9_1_expr(IT, Value)]
        ),
        B = call_action(call_expr(fn_cache_set, Args), no, IT)
    ;
        IA = ia_cache_delete(Key),
        B = call_action(call_expr(fn_cache_delete, [rdsc_4a_9_1_expr(IT, Key)]), no,
            IT)
    ;
        IA = ia_bind(Ix, Bound),
        B = call_action(rdsc_4a_9_1_expr(IT, e_bind(Ix, Bound)), no, IT)
    ;
        IA = ia_hydration_call(Target, Corr, Service, Body, Gate),
        Call = call_expr(fn_hydration_call,
            [str_lit(interned_text(IT, Target)), rdsc_4a_9_1_expr(IT, Corr),
             str_lit(interned_text(IT, Service)), json_build(IT, Body)]),
        B = call_action(gated(IT, Gate, Call), no, IT)
    ;
        IA = ia_withdraw(Position),
        % `ACTION_WITHDRAW`. Position 0 is omitted; a decoder reads absent as 0.
        put_uint32(1u32, 3u32, init_builder, W1),
        put_uint32(6u32, fact_index_wire(token_fact(Position)), W1, B)
    ;
        IA = ia_withdraw_by_id(Fact),
        % `ACTION_WITHDRAW_BY_ID`.
        put_uint32(1u32, 4u32, init_builder, W1),
        put_message(7u32, rdsc_4a_9_1_expr(IT, Fact), W1, B)
    ;
        IA = ia_internal(Fn, Args),
        B = call_action(call_expr(Fn, list.map(rdsc_4a_9_1_expr(IT), Args)), no, IT)
    ;
        IA = ia_operands_not_admitted(Fn, Args, Gate),
        % No lowering builds it. Written back as the call it was decoded from, so
        % the encoder stays the decoder's inverse.
        B = call_action(gated(IT, Gate,
            call_expr(Fn, list.map(rdsc_4a_9_1_expr(IT), Args))), no, IT)
    ).

    % `IF(FN_RATE_ALLOW(<gate>), <call>, null)`: the shape
    % `ds.dsc_action.classify` reads back.
    %
    %@helper
:- func gated(intern_table, maybe(list(expr)), builder) = builder.

gated(_, no, Call) = Call.
gated(IT, yes(GateArgs), Call) = If :-
    put_message(1u32, call_expr(fn_rate_allow,
        list.map(rdsc_4a_9_1_expr(IT), GateArgs)), init_builder, G1),
    put_message(2u32, Call, G1, G2),
    put_message(3u32, lit_body(IT, null), G2, G3),
    put_message(12u32, G3, init_builder, If).

    %@helper
:- func call_action(builder, maybe(expr), intern_table) = builder.

call_action(Expr, Ttl, IT) = B :-
    put_message(2u32, Expr, init_builder, A1),
    put_ttl(IT, Ttl, A1, B).

    %@helper
:- pred put_ttl(intern_table::in, maybe(expr)::in, builder::in, builder::out)
    is det.

put_ttl(_, no, !B).
put_ttl(IT, yes(Ttl), !B) :-
    put_message(5u32, rdsc_4a_9_1_expr(IT, Ttl), !B).

    %@helper
:- pred put_assign(intern_table::in, slot_assign::in,
                   builder::in, builder::out) is det.

put_assign(IT, slot_assign(Slot, Value), !B) :-
    put_uint32(1u32, slot_wire(Slot), init_builder, S1),
    put_message(2u32, rdsc_4a_9_1_expr(IT, Value), S1, S2),
    put_message(4u32, S2, !B).

    %@helper
:- func json_build(intern_table, kwargs) = builder.

json_build(IT, Kwargs) = call_expr(fn_json_build, kwarg_operands(IT, Kwargs)).

    %@helper
:- func kwarg_operands(intern_table, kwargs) = list(builder).

kwarg_operands(IT, Kwargs) =
    list.condense(list.map(kwarg_args(IT), kwarg_list(Kwargs))).

    %@helper
:- func kwarg_args(intern_table, pair(string, expr)) = list(builder).

kwarg_args(IT, K - V) = [str_lit(K), rdsc_4a_9_1_expr(IT, V)].

    %@helper
:- func log_level_number(log_level) = int64.

log_level_number(log_debug) = 0i64.
log_level_number(log_info) = 1i64.
log_level_number(log_warning) = 2i64.
log_level_number(log_error) = 3i64.
log_level_number(log_critical) = 4i64.

%-----------------------------------------------------------------------------%
% Expressions -- the inverse of `ds.dsc_expr`
%-----------------------------------------------------------------------------%

    % A oneof member is written even at its zero. `now` and `lit_null` carry a
    % meaningless `true`: the case is the signal.
    %
    %@spec [RDSC.4a.9.1]
    %@spec [RDSC.4a.9.3]
:- func rdsc_4a_9_1_expr(intern_table, expr) = builder.

rdsc_4a_9_1_expr(IT, E) = B :-
    (
        E = e_lit(V),
        B = lit_body(IT, V)
    ;
        E = e_slot(Fact, Read),
        put_uint32(1u32, fact_index_wire(Fact), init_builder, V1),
        put_uint32(2u32, slot_read_wire(Read), V1, V2),
        put_message(5u32, V2, init_builder, B)
    ;
        E = e_binop(Op, L, R),
        put_uint32(1u32, rete_binop(Op), init_builder, O1),
        put_message(2u32, rdsc_4a_9_1_expr(IT, L), O1, O2),
        put_message(3u32, rdsc_4a_9_1_expr(IT, R), O2, O3),
        put_message(6u32, O3, init_builder, B)
    ;
        E = e_unop(Op, X),
        put_uint32(1u32, rete_unop(Op), init_builder, U1),
        put_message(2u32, rdsc_4a_9_1_expr(IT, X), U1, U2),
        put_message(7u32, U2, init_builder, B)
    ;
        E = e_call(Fn, Args),
        B = call_expr(Fn, list.map(rdsc_4a_9_1_expr(IT), Args))
    ;
        E = e_interp(Prims),
        list.foldl((pred(P::in, CIn::in, COut::out) is det :-
            put_message(1u32, rlow_6_4_format_prim(IT, P), CIn, COut)),
            Prims, init_builder, C1),
        put_message(20u32, C1, init_builder, B)
    ;
        E = e_now,
        put_uint64_always(11u32, 1u64, init_builder, B)
    ;
        E = e_entry_stamp(Fact),
        put_uint64_always(21u32, u32_64(fact_index_wire(Fact)), init_builder,
            B)
    ;
        E = e_if(Cond, Then, Else),
        put_message(1u32, rdsc_4a_9_1_expr(IT, Cond), init_builder, I1),
        put_message(2u32, rdsc_4a_9_1_expr(IT, Then), I1, I2),
        put_message(3u32, rdsc_4a_9_1_expr(IT, Else), I2, I3),
        put_message(12u32, I3, init_builder, B)
    ;
        E = e_bind(Ix, Bound),
        put_uint32(1u32, uint32.det_from_int(bind_index_int(Ix)), init_builder,
            D1),
        put_message(2u32, rdsc_4a_9_1_expr(IT, Bound), D1, D2),
        put_message(13u32, D2, init_builder, B)
    ;
        E = e_bind_ref(Ix),
        put_uint64_always(14u32, uint64.det_from_int(bind_index_int(Ix)),
            init_builder, B)
    ;
        E = e_json_path_expr(Val, Path),
        put_message(1u32, rdsc_4a_9_1_expr(IT, Val), init_builder, J1),
        put_message(2u32, rdsc_4a_9_1_expr(IT, Path), J1, J2),
        put_message(15u32, J2, init_builder, B)
    ;
        E = e_coalesce(L, R),
        put_message(1u32, rdsc_4a_9_1_expr(IT, L), init_builder, K1),
        put_message(2u32, rdsc_4a_9_1_expr(IT, R), K1, K2),
        put_message(17u32, K2, init_builder, B)
    ;
        E = e_is_test(Operand, Subject, Negated),
        put_message(1u32, rdsc_4a_9_1_expr(IT, Operand), init_builder, T1),
        put_uint32(2u32, is_subject_number(Subject), T1, T2),
        put_bool(3u32, Negated, T2, T3),
        put_message(18u32, T3, init_builder, B)
    ;
        E = e_tainted(Inner),
        % A wrapper, not a node: the inner message carries `json_tainted` (19),
        % once however many wrappers are stacked, and in field order: before a
        % member numbered above 19, after one below ([RFCS.19.5]).
        Core = untainted(Inner),
        Member = rdsc_4a_9_1_expr(IT, Core),
        ( if rdsc_4a_9_1_member(Core) < 19u32 then
            put_bool(19u32, yes, Member, B)
        else
            put_bool(19u32, yes, init_builder, Flag),
            B = append_builder(Flag, Member)
        )
    ;
        ( E = e_slot_named(_, _)
        ; E = e_json_path(_, _)
        ; E = e_agg(_)
        ),
        % No Rete `Expr` arm: the named slot and the fact-rooted json path are
        % decoder conveniences, and an aggregation is a builtin call on the
        % wire. `dsc.rete` builds none of them.
        unexpected($pred, "an expression with no Rete wire form")
    ).

    % The `Expr.kind` field number `rdsc_4a_9_1_expr` writes, arm for arm.
    %
    %@spec [RDSC.4a.9.1]
    %@spec [RFCS.19.5]
:- func rdsc_4a_9_1_member(expr) = uint32.

rdsc_4a_9_1_member(E) = Field :-
    (
        E = e_lit(V),
        ( if V = int(_) then Field = 1u32
        else if V = float(_) then Field = 2u32
        else if V = str(_) then Field = 3u32
        else if V = bool(_) then Field = 4u32
        else if V = null then Field = 16u32
        else if V = time(_) then Field = 22u32
        else unexpected($pred, "a literal kind with no Rete wire form")
        )
    ;
        E = e_slot(_, _),
        Field = 5u32
    ;
        E = e_binop(_, _, _),
        Field = 6u32
    ;
        E = e_unop(_, _),
        Field = 7u32
    ;
        E = e_call(_, _),
        Field = 8u32
    ;
        E = e_now,
        Field = 11u32
    ;
        E = e_if(_, _, _),
        Field = 12u32
    ;
        E = e_bind(_, _),
        Field = 13u32
    ;
        E = e_bind_ref(_),
        Field = 14u32
    ;
        E = e_json_path_expr(_, _),
        Field = 15u32
    ;
        E = e_coalesce(_, _),
        Field = 17u32
    ;
        E = e_is_test(_, _, _),
        Field = 18u32
    ;
        E = e_interp(_),
        Field = 20u32
    ;
        E = e_entry_stamp(_),
        Field = 21u32
    ;
        E = e_tainted(_),
        unexpected($pred, "a provenance wrapper has no member")
    ;
        ( E = e_slot_named(_, _)
        ; E = e_json_path(_, _)
        ; E = e_agg(_)
        ),
        unexpected($pred, "an expression with no Rete wire form")
    ).

    % The text member is written even when empty, as a oneof member is. A
    % `ValuePrim`'s scalars are omitted at zero.
    %
    %@helper
:- func rlow_6_4_format_prim(intern_table, format_prim) = builder.

rlow_6_4_format_prim(_, fp_text(Text)) = B :-
    put_string_always(1u32, Text, init_builder, B).
rlow_6_4_format_prim(IT, fp_value(VP)) = B :-
    put_message(1u32, rdsc_4a_9_1_expr(IT, VP ^ vp_value), init_builder, V1),
    put_uint32(2u32, format_align_number(VP ^ vp_align), V1, V2),
    put_bool(3u32, VP ^ vp_plus, V2, V3),
    put_bool(4u32, VP ^ vp_zero, V3, V4),
    put_uint32(5u32, VP ^ vp_width, V4, V5),
    (
        VP ^ vp_precision = yes(Precision),
        put_bool(6u32, yes, V5, V6),
        put_uint32(7u32, Precision, V6, V7)
    ;
        VP ^ vp_precision = no,
        V7 = V5
    ),
    put_uint32(8u32, format_type_number(VP ^ vp_type), V7, V8),
    put_message(2u32, V8, init_builder, B).
rlow_6_4_format_prim(IT, fp_time(Value, Items)) = B :-
    put_message(1u32, rdsc_4a_9_1_expr(IT, Value), init_builder, T1),
    list.foldl((pred(I::in, TIn::in, TOut::out) is det :-
        put_message(2u32, time_item_body(I), TIn, TOut)), Items, T1, T2),
    put_message(3u32, T2, init_builder, B).

    %@helper
:- func time_item_body(time_item) = builder.

time_item_body(ti_text(Text)) = B :-
    put_string_always(1u32, Text, init_builder, B).
time_item_body(ti_field(Field)) = B :-
    put_uint32(2u32, time_field_number(Field), init_builder, B).

    %@helper
:- func format_align_number(format_align) = uint32.

format_align_number(align_default) = 0u32.
format_align_number(align_left) = 1u32.
format_align_number(align_right) = 2u32.

    %@helper
:- func format_type_number(format_type) = uint32.

format_type_number(ft_canonical) = 0u32.
format_type_number(ft_d) = 1u32.
format_type_number(ft_f) = 2u32.
format_type_number(ft_s) = 3u32.
format_type_number(ft_x_lower) = 4u32.
format_type_number(ft_x_upper) = 5u32.
format_type_number(ft_b) = 6u32.

    %@helper
:- func time_field_number(time_field) = uint32.

time_field_number(tf_year) = 1u32.
time_field_number(tf_month) = 2u32.
time_field_number(tf_day) = 3u32.
time_field_number(tf_hour) = 4u32.
time_field_number(tf_minute) = 5u32.
time_field_number(tf_second) = 6u32.
time_field_number(tf_microsecond) = 7u32.
time_field_number(tf_utc_offset) = 8u32.

    %@helper
:- func call_expr(builtin_fn, list(builder)) = builder.

call_expr(Fn, Args) = B :-
    list.foldl((pred(A::in, CIn::in, COut::out) is det :-
        put_message(2u32, A, CIn, COut)), Args, init_builder, C1),
    put_uint32(3u32, builtin_fn_wire(Fn), C1, C2),
    put_message(8u32, C2, init_builder, B).

    %@helper
:- func lit_body(intern_table, ds_value) = builder.

lit_body(IT, V) = B :-
    ( if V = int(I) then
        B = int_lit(I)
    else if V = float(F) then
        B = double_present(2u32, F, init_builder)
    else if V = str(Ref) then
        B = str_lit(interned_text(IT, Ref))
    else if V = bool(Bool) then
        put_uint64_always(4u32, bool_bit(Bool), init_builder, B)
    else if V = null then
        put_uint64_always(16u32, 1u64, init_builder, B)
    else if V = time(T) then
        B = int_present(22u32, utc_ns(T), init_builder)
    else
        unexpected($pred, "a literal kind with no Rete wire form")
    ).

    %@helper
:- func int_lit(int64) = builder.

int_lit(I) = int_present(1u32, I, init_builder).

    %@helper
:- func str_lit(string) = builder.

str_lit(S) = B :-
    put_string_always(3u32, S, init_builder, B).

    % An `int64` written even at zero: the varint of the two's-complement
    % value, not zigzag.
    %
    %@helper
:- func int_present(uint32, int64, builder) = builder.

int_present(Field, I, B0) = B :-
    put_tag(Field, wt_varint, B0, B1),
    put_varint(uint64.cast_from_int64(I), B1, B).

    % A `double` written even at +0.0, which `put_double` omits.
    %
    %@helper
:- func double_present(uint32, float, builder) = builder.

double_present(Field, F, B0) = B :-
    ( if put_double(Field, F, init_builder, Probe) then
        ( if builder_length(Probe) = 0 then
            put_tag(Field, wt_fixed64, B0, B1),
            put_bytes(list.duplicate(8, 0u8), B1, B)
        else
            put_bytes(builder_bytes(Probe), B0, B)
        )
    else
        unexpected($pred, "a literal is not representable as a double")
    ).

    %@helper
:- func bool_bit(bool) = uint64.

bool_bit(no) = 0u64.
bool_bit(yes) = 1u64.

    % An index of 255 or more would read as a marker, so it is not written.
    %
    %@helper
:- func fact_index_wire(fact_index) = uint32.

fact_index_wire(token_fact(N)) = Wire :-
    ( if N >= 0, N < rdsc_4a_9_1_index_count then
        Wire = uint32.det_from_int(N)
    else
        unexpected($pred, "a pattern index past the byte index space")
    ).
fact_index_wire(candidate) = rdsc_4a_9_1_marker.

    %@helper
:- func slot_read_wire(slot_read) = uint32.

slot_read_wire(slot(Ix)) = slot_wire(Ix).
slot_read_wire(whole_fact) = rdsc_4a_9_1_marker.

    %@helper
:- func slot_wire(slot_index) = uint32.

slot_wire(Ix) = Wire :-
    Wire = slot_index_value(Ix),
    ( if uint32.cast_to_int(Wire) < rdsc_4a_9_1_index_count then
        true
    else
        unexpected($pred, "a slot index past the byte index space")
    ).

    %@helper
:- func rete_binop(binop) = uint32.

rete_binop(op_add) = 0u32.
rete_binop(op_sub) = 1u32.
rete_binop(op_mul) = 2u32.
rete_binop(op_div) = 3u32.
rete_binop(op_floordiv) = 4u32.
rete_binop(op_rem) = 5u32.
rete_binop(op_eq) = 6u32.
rete_binop(op_ne) = 7u32.
rete_binop(op_lt) = 8u32.
rete_binop(op_gt) = 9u32.
rete_binop(op_le) = 10u32.
rete_binop(op_ge) = 11u32.
rete_binop(op_and) = 12u32.
rete_binop(op_or) = 13u32.
rete_binop(op_bit_and) = 14u32.
rete_binop(op_bit_or) = 15u32.
rete_binop(op_bit_xor) = 16u32.
rete_binop(op_shl) = 17u32.
rete_binop(op_shr) = 18u32.

    %@helper
:- func rete_unop(unop) = uint32.

rete_unop(op_not) = 0u32.
rete_unop(op_bitnot) = 1u32.
rete_unop(op_neg) = 2u32.
rete_unop(op_pos) = _ :-
    unexpected($pred, "unary `+` is dropped before the Rete tree").

    %@helper
:- func is_subject_number(is_subject) = uint32.

is_subject_number(is_null) = 1u32.
is_subject_number(is_true) = 2u32.
is_subject_number(is_false) = 3u32.
is_subject_number(is_inf) = 4u32.
is_subject_number(is_neg_inf) = 5u32.
is_subject_number(is_nan) = 6u32.
is_subject_number(is_int) = 7u32.
is_subject_number(is_float) = 8u32.
is_subject_number(is_bool) = 9u32.
is_subject_number(is_string) = 10u32.
is_subject_number(is_bytes) = 11u32.
is_subject_number(is_json) = 12u32.

%-----------------------------------------------------------------------------%

    % A ref not in the table is a compiler defect, so it aborts.
    %
    %@helper
:- func interned_text(intern_table, intern_ref) = string.

interned_text(IT, Ref) =
    ( if expand(IT, Ref, S) then
        S
    else
        unexpected($pred, "intern_ref is not in the compiler's own table")
    ).

%-----------------------------------------------------------------------------%
% Test atoms -- [RLOW.17], `proto/test_scenario.proto`, `test_oracle.proto`
%-----------------------------------------------------------------------------%

    % Every `TestFact` before any `TestCacheSeed`, initial and timeline alike.
    %
    %@spec [RLOW.17.1]
    %@spec [RLOW.17.2]
    %@spec [RDSC.8.1]
:- func rlow_17_1_test_group(uint32, test_ir) = builder.

rlow_17_1_test_group(Clip, T) = Bytes :-
    Id = T ^ ti_id,
    put_uint32(1u32, Id, init_builder, C1),
    put_string(2u32, T ^ ti_name, C1, C2),
    put_uint64(3u32, T ^ ti_until, C2, C3),
    put_uint32(4u32, Clip, C3, C4),
    put_bool(5u32, T ^ ti_absolute, C4, C5),
    rfcs_19_1_frame(da_test_case, C5, Case),
    Facts = concat_builders(list.map(test_fact_atom(Id), T ^ ti_facts)),
    Seeds = concat_builders(list.map(test_seed_atom(Id), T ^ ti_seeds)),
    Stubs = concat_builders(list.map(test_stub_atoms(Id), T ^ ti_stubs)),
    Oracles = concat_builders(list.map(test_oracle_atom(Id), T ^ ti_oracles)),
    Bytes = concat_builders([Case, Facts, Seeds, Stubs, Oracles]).

    % The value is a oneof member, so it is written even at its default.
    %
    %@helper
:- func test_slot_literal(test_slot) = builder.

test_slot_literal(test_slot(Name, V)) = B :-
    put_string(1u32, Name, init_builder, B0),
    (
        V = tv_int(I),
        B = int_present(2u32, I, B0)
    ;
        V = tv_float(F),
        B = double_present(3u32, F, B0)
    ;
        V = tv_string(S),
        put_string_always(4u32, S, B0, B)
    ;
        V = tv_bool(Bool),
        put_tag(5u32, wt_varint, B0, B1),
        put_varint(bool_bit(Bool), B1, B)
    ;
        V = tv_duration(Ns),
        put_uint64_always(6u32, Ns, B0, B)
    ;
        V = tv_json(J),
        put_string_always(7u32, J, B0, B)
    ).

    %@helper
:- pred put_slots(uint32::in, list(test_slot)::in, builder::in, builder::out)
    is det.

put_slots(_, [], !B).
put_slots(Field, [S | Ss], !B) :-
    put_message(Field, test_slot_literal(S), !B),
    put_slots(Field, Ss, !B).

    %@spec [LTSL.5.3]
    %@spec [LTSL.6.1]
:- func test_fact_atom(uint32, test_fact_ir) = builder.

test_fact_atom(Id, F) = Bytes :-
    put_uint32(1u32, Id, init_builder, B1),
    put_bool(2u32, F ^ tfi_initial, B1, B2),
    put_uint64(3u32, F ^ tfi_when, B2, B3),
    put_string(4u32, F ^ tfi_schema, B3, B4),
    put_slots(5u32, F ^ tfi_slots, B4, B5),
    put_uint32(6u32, F ^ tfi_order, B5, B6),
    rfcs_19_1_frame(da_test_fact, B6, Bytes).

    % The literal itself, not its JSON text.
    %
    %@spec [LTSL.5.2]
:- func test_seed_atom(uint32, test_seed_ir) = builder.

test_seed_atom(Id, S) = Bytes :-
    put_uint32(1u32, Id, init_builder, B1),
    put_string(2u32, S ^ tsi_key, B1, B2),
    put_message(3u32, test_slot_literal(test_slot("", S ^ tsi_value)), B2, B3),
    rfcs_19_1_frame(da_test_cache_seed, B3, Bytes).

    % The first item's `source_order`, 0, is omitted; a reader reads absent as 0.
    %
    %@spec [LGRA.24.3]
:- func lgra_24_3_initial_atom(uint32, uint32, initial_item_ir) = builder.

lgra_24_3_initial_atom(Clip, Order, Item) = Bytes :-
    (
        Item = ii_fact(Schema, Slots),
        put_uint32(1u32, Clip, init_builder, B1),
        put_string(2u32, Schema, B1, B2),
        put_slots(3u32, Slots, B2, B3),
        put_uint32(4u32, Order, B3, B4),
        rfcs_19_1_frame(da_initial_fact, B4, Bytes)
    ;
        Item = ii_seed(Key, Value),
        put_uint32(1u32, Clip, init_builder, B1),
        put_string(2u32, Key, B1, B2),
        put_message(3u32, test_slot_literal(test_slot("", Value)), B2, B3),
        put_uint32(4u32, Order, B3, B4),
        rfcs_19_1_frame(da_initial_cache_seed, B4, Bytes)
    ).

    %@spec [LTSL.7.2]
    %@spec [LTSL.7.3]
:- func test_stub_atoms(uint32, test_stub_ir) = builder.

test_stub_atoms(Id, S) = Bytes :-
    put_uint32(1u32, S ^ tbi_id, init_builder, B1),
    put_uint32(2u32, Id, B1, B2),
    put_string(3u32, S ^ tbi_service, B2, B3),
    put_string(4u32, S ^ tbi_corr, B3, B4),
    put_slots(5u32, S ^ tbi_args, B4, B5),
    put_uint64(6u32, S ^ tbi_after, B5, B6),
    put_bool(7u32, S ^ tbi_no_response, B6, B7),
    rfcs_19_1_frame(da_test_response, B7, Stub),
    Replies = concat_builders(list.map_corresponding(
        test_reply_atom(S ^ tbi_id),
        uint32_upto(0u32, list.length(S ^ tbi_replies)), S ^ tbi_replies)),
    Bytes = append_builder(Stub, Replies).

    %@helper
:- func uint32_upto(uint32, int) = list(uint32).

uint32_upto(From, N) =
    ( if N =< 0 then [] else [From | uint32_upto(From + 1u32, N - 1)] ).

    %@helper
:- func test_reply_atom(uint32, uint32, test_reply_ir) = builder.

test_reply_atom(StubId, Order, R) = Bytes :-
    put_uint32(1u32, StubId, init_builder, B1),
    put_string(2u32, R ^ tri_schema, B1, B2),
    put_slots(3u32, R ^ tri_slots, B2, B3),
    put_uint32(4u32, Order, B3, B4),
    rfcs_19_1_frame(da_test_reply, B4, Bytes).

    % `occurrence` (field 10) and `OracleEmit.where_expr_id` are never written.
    %
    %@spec [LTSL.8.2]
    %@spec [LTSL.8.3]
:- func test_oracle_atom(uint32, test_oracle_ir) = builder.

test_oracle_atom(Id, O) = Bytes :-
    (
        O = toi_activated(P, Rule),
        oracle_head(Id, P, B0),
        put_string(3u32, Rule, B0, B),
        Atom = da_oracle_activated
    ;
        O = toi_emitted(P, Schema, Slots, Where),
        oracle_match(Id, P, Schema, Slots, Where, B),
        Atom = da_oracle_emit
    ;
        O = toi_published(P, Schema, Slots, Where),
        oracle_match(Id, P, Schema, Slots, Where, B),
        Atom = da_oracle_publish
    ;
        O = toi_called(P, Service, MaybeCorr),
        oracle_head(Id, P, B0),
        put_string(3u32, Service, B0, B1),
        (
            MaybeCorr = yes(Corr),
            put_bool(4u32, yes, B1, B2),
            put_string(5u32, Corr, B2, B)
        ;
            MaybeCorr = no,
            B = B1
        ),
        Atom = da_oracle_call
    ;
        O = toi_cached(P, Key, MaybeValue),
        oracle_head(Id, P, B0),
        put_string(3u32, Key, B0, B1),
        (
            MaybeValue = yes(V),
            put_bool(4u32, yes, B1, B2),
            put_message(5u32, test_slot_literal(test_slot("", V)), B2, B)
        ;
            MaybeValue = no,
            B = B1
        ),
        Atom = da_oracle_cache_set
    ;
        O = toi_cache_deleted(P, Key),
        oracle_head(Id, P, B0),
        put_string(3u32, Key, B0, B),
        Atom = da_oracle_cache_delete
    ;
        O = toi_logged(P, Level, MaybeMsg),
        oracle_head(Id, P, B0),
        (
            MaybeMsg = yes(Msg),
            put_bool(4u32, yes, B0, B1),
            put_string(5u32, Msg, B1, B2)
        ;
            MaybeMsg = no,
            B2 = B0
        ),
        put_uint32(6u32, Level, B2, B),
        Atom = da_oracle_log
    ;
        O = toi_retracted(P, Schema, Slots),
        oracle_head(Id, P, B0),
        put_string(3u32, Schema, B0, B1),
        put_slots(4u32, Slots, B1, B),
        Atom = da_oracle_retract
    ;
        O = toi_wm_has(P, Schema, Slots),
        oracle_head(Id, P, B0),
        put_uint32(3u32, 1u32, B0, B1),                 % Mode HAS
        put_string(4u32, Schema, B1, B2),
        put_slots(5u32, Slots, B2, B),
        Atom = da_oracle_working_memory
    ;
        O = toi_wm_count(P, Schema, Count),
        oracle_head(Id, P, B0),
        put_uint32(3u32, 2u32, B0, B1),                 % Mode COUNT
        put_string(4u32, Schema, B1, B2),
        put_uint32(6u32, Count, B2, B),
        Atom = da_oracle_working_memory
    ;
        O = toi_wm_empty(P),
        oracle_head(Id, P, B0),
        put_uint32(3u32, 3u32, B0, B),                  % Mode EMPTY
        Atom = da_oracle_working_memory
    ),
    rfcs_19_1_frame(Atom, B, Bytes).

    %@helper
:- pred oracle_head(uint32::in, test_polarity::in, builder::out) is det.

oracle_head(Id, P, B) :-
    put_uint32(1u32, Id, init_builder, B1),
    put_uint32(2u32, ( if P = tp_pos then 1u32 else 2u32 ), B1, B).

    %@helper
:- pred oracle_match(uint32::in, test_polarity::in, string::in,
                     list(test_slot)::in, bool::in, builder::out) is det.

oracle_match(Id, P, Schema, Slots, Where, B) :-
    oracle_head(Id, P, B0),
    put_string(3u32, Schema, B0, B1),
    put_slots(4u32, Slots, B1, B2),
    put_bool(5u32, Where, B2, B).

%-----------------------------------------------------------------------------%
:- end_module dsc.encode.
%-----------------------------------------------------------------------------%

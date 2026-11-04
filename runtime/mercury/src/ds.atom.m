%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% ds.atom -- the unified atom registry, band geometry, and the frame walk.
%
% Generated in part: edit ds.atom.m.in, not ds.atom.m. Constructors, wire numbers
% and message names come from `proto/atom.proto`, written in by the atom
% extractor.
%
% A band decides only the unknown case [RFCS.16.2]. A known atom dispatches
% without it: DscHeader and the network nodes sit in the skip band.
%-----------------------------------------------------------------------------%

:- module ds.atom.
:- interface.

:- import_module ds.wire.

%-----------------------------------------------------------------------------%
% The registry
%-----------------------------------------------------------------------------%

    % `at_` and the body message in snake case.
    %
:- type atom_id
% BEGIN GENERATED constructors
    --->    at_fact_assert                      % 1     FactAssert
    ;       at_fact_retract                     % 2     FactRetract
    ;       at_clock_advance                    % 3     ClockAdvance
    ;       at_pump_boundary                    % 4     PumpBoundary
    ;       at_external_assert                  % 5     ExternalAssert
    ;       at_cache_seed                       % 6     CacheSeed
    ;       at_realtime_contract                % 128   RealtimeContract
    ;       at_series_backend_interval_pulse    % 129   SeriesBackendIntervalPulse
    ;       at_series_backend_numeric_integral  % 130   SeriesBackendNumericIntegral
    ;       at_initial_fact                     % 131   InitialFact
    ;       at_initial_cache_seed               % 132   InitialCacheSeed
    ;       at_schema_def                       % 256   SchemaDef
    ;       at_slot                             % 257   Slot
    ;       at_stream_header                    % 258   StreamHeader
    ;       at_rule_fire_annotation             % 261   RuleFireAnnotation
    ;       at_call_issued                      % 262   CallIssued
    ;       at_dsc_header                       % 263   DscHeader
    ;       at_dialect_info                     % 264   DialectInfo
    ;       at_capability_info                  % 265   CapabilityInfo
    ;       at_ds_source                        % 267   DsSource
    ;       at_alpha_node                       % 268   AlphaNode
    ;       at_beta_node                        % 269   BetaNode
    ;       at_terminal_node                    % 270   TerminalNode
    ;       at_oracle_activated                 % 287   OracleActivated
    ;       at_oracle_emit                      % 288   OracleEmit
    ;       at_oracle_publish                   % 289   OraclePublish
    ;       at_oracle_call                      % 290   OracleCall
    ;       at_oracle_cache_set                 % 291   OracleCacheSet
    ;       at_oracle_cache_delete              % 292   OracleCacheDelete
    ;       at_oracle_log                       % 294   OracleLog
    ;       at_oracle_retract                   % 296   OracleRetract
    ;       at_oracle_working_memory            % 297   OracleWorkingMemory
    ;       at_compiled_code                    % 298   CompiledCode
    ;       at_schema_logical                   % 299   SchemaLogical
    ;       at_schema_ttl                       % 300   SchemaTtl
    ;       at_hydration                        % 301   Hydration
    ;       at_schema_source                    % 302   SchemaSource
    ;       at_line_span                        % 303   LineSpan
    ;       at_doc_string                       % 304   DocString
    ;       at_rule_cooldown                    % 307   RuleCooldown
    ;       at_rule_source                      % 309   RuleSource
    ;       at_rule_debug_name                  % 310   RuleDebugName
    ;       at_service_def                      % 311   ServiceDef
    ;       at_series_backend_welford_ewma      % 312   SeriesBackendWelfordEwma
    ;       at_series_backend_ring_buffer       % 313   SeriesBackendRingBuffer
    ;       at_series_backend_monotonic_deque   % 314   SeriesBackendMonotonicDeque
    ;       at_series_backend_fifo_deque        % 315   SeriesBackendFifoDeque
    ;       at_series_backend_reservoir         % 316   SeriesBackendReservoir
    ;       at_test_case                        % 317   TestCase
    ;       at_test_fact                        % 318   TestFact
    ;       at_test_cache_seed                  % 319   TestCacheSeed
    ;       at_test_response                    % 320   TestResponse
    ;       at_test_reply                       % 321   TestReply
    ;       at_oracle_exclusive                 % 324   OracleExclusive
    ;       at_computation_error                % 325   ComputationError
    ;       at_fact_emit                        % 326   FactEmit
    ;       at_fact_withdraw                    % 327   FactWithdraw
    ;       at_type_error                       % 328   TypeError
    ;       at_bounds_error                     % 329   BoundsError
    ;       at_engine_error                     % 330   EngineError
    ;       at_fact_publish.                    % 331   FactPublish
% END GENERATED constructors

:- pred atom_of_field(uint32::in, atom_id::out) is semidet.
:- func atom_field(atom_id) = uint32.

:- func atom_message(atom_id) = string.

%-----------------------------------------------------------------------------%
% Bands
%-----------------------------------------------------------------------------%

:- type band
    --->    band_inject             % 1..127
    ;       band_reject             % 128..255
    ;       band_skip               % 256..2047
    ;       band_none.              % 0, or >= 2048: malformed [RFCS.16.3]

:- func band_of(uint32) = band.

    % What a reader does with an atom it has no entry for [RFCS.16.3].
    %
:- type disposition
    --->    disp_skip
    ;       disp_reject_inject      % DS_ERR_FS_UNKNOWN_INJECT
    ;       disp_reject_version     % DS_ERR_DSC_VERSION
    ;       disp_malformed.

:- func disposition_of_unknown(uint32) = disposition.

%-----------------------------------------------------------------------------%
% Framing
%-----------------------------------------------------------------------------%

    % Decided by the first atom's field number [RFCS.19.4]. A self-contained
    % bundle opens with `DscHeader` like a lean `.dsc`: telling those apart takes
    % a walk of the frames to `StreamHeader`.
    %
:- type container
    --->    container_dsc           % opens with DscHeader = 263
    ;       container_stream.       % opens with StreamHeader = 258

:- pred container_of(atom_id::in, container::out) is semidet.

:- type frame
    --->    frame(
                fr_atom   :: atom_ref,
                fr_body   :: reader,
                fr_offset :: int        % where the outer frame began
            ).

:- type atom_ref
    --->    known(atom_id)
    ;       unknown(uint32).

:- type frame_result
    --->    fr_ok(frame)
    ;       fr_eof
    ;       fr_error(atom_error, int).      % the byte offset ([RDSC.11.2])

:- type atom_error
    --->    ae_wire(wire_error)
            % The outer frame: `we_truncated` is the bytes running out, which a
            % stream reader takes as a tail still arriving.

    ;       ae_body(wire_error)
            % Inside a frame whose length was satisfied ([RDSC.11.1]): more bytes
            % cannot repair it.

    ;       ae_bad_outer_tag(uint32)
    ;       ae_bad_inner_type
    ;       ae_empty_atom.
            % [RFCS.19.3]: valid protobuf with no `oneof` member set.

:- pred next_frame(frame_result::out, reader::in, reader::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module uint32.
:- import_module uint8.

%-----------------------------------------------------------------------------%

atom_of_field(N, A) :- wire(A, N).

atom_field(A) = N :- wire(A, N).

:- pred wire(atom_id, uint32).
:- mode wire(in, out) is det.
:- mode wire(out, in) is semidet.
:- mode wire(out, out) is multi.

% BEGIN GENERATED wire
wire(at_fact_assert,                         1u32).
wire(at_fact_retract,                        2u32).
wire(at_clock_advance,                       3u32).
wire(at_pump_boundary,                       4u32).
wire(at_external_assert,                     5u32).
wire(at_cache_seed,                          6u32).
wire(at_realtime_contract,                 128u32).
wire(at_series_backend_interval_pulse,     129u32).
wire(at_series_backend_numeric_integral,   130u32).
wire(at_initial_fact,                      131u32).
wire(at_initial_cache_seed,                132u32).
wire(at_schema_def,                        256u32).
wire(at_slot,                              257u32).
wire(at_stream_header,                     258u32).
wire(at_rule_fire_annotation,              261u32).
wire(at_call_issued,                       262u32).
wire(at_dsc_header,                        263u32).
wire(at_dialect_info,                      264u32).
wire(at_capability_info,                   265u32).
wire(at_ds_source,                         267u32).
wire(at_alpha_node,                        268u32).
wire(at_beta_node,                         269u32).
wire(at_terminal_node,                     270u32).
wire(at_oracle_activated,                  287u32).
wire(at_oracle_emit,                       288u32).
wire(at_oracle_publish,                    289u32).
wire(at_oracle_call,                       290u32).
wire(at_oracle_cache_set,                  291u32).
wire(at_oracle_cache_delete,               292u32).
wire(at_oracle_log,                        294u32).
wire(at_oracle_retract,                    296u32).
wire(at_oracle_working_memory,             297u32).
wire(at_compiled_code,                     298u32).
wire(at_schema_logical,                    299u32).
wire(at_schema_ttl,                        300u32).
wire(at_hydration,                         301u32).
wire(at_schema_source,                     302u32).
wire(at_line_span,                         303u32).
wire(at_doc_string,                        304u32).
wire(at_rule_cooldown,                     307u32).
wire(at_rule_source,                       309u32).
wire(at_rule_debug_name,                   310u32).
wire(at_service_def,                       311u32).
wire(at_series_backend_welford_ewma,       312u32).
wire(at_series_backend_ring_buffer,        313u32).
wire(at_series_backend_monotonic_deque,    314u32).
wire(at_series_backend_fifo_deque,         315u32).
wire(at_series_backend_reservoir,          316u32).
wire(at_test_case,                         317u32).
wire(at_test_fact,                         318u32).
wire(at_test_cache_seed,                   319u32).
wire(at_test_response,                     320u32).
wire(at_test_reply,                        321u32).
wire(at_oracle_exclusive,                  324u32).
wire(at_computation_error,                 325u32).
wire(at_fact_emit,                         326u32).
wire(at_fact_withdraw,                     327u32).
wire(at_type_error,                        328u32).
wire(at_bounds_error,                      329u32).
wire(at_engine_error,                      330u32).
wire(at_fact_publish,                      331u32).
% END GENERATED wire

% BEGIN GENERATED message
atom_message(at_fact_assert)                     = "FactAssert".
atom_message(at_fact_retract)                    = "FactRetract".
atom_message(at_clock_advance)                   = "ClockAdvance".
atom_message(at_pump_boundary)                   = "PumpBoundary".
atom_message(at_external_assert)                 = "ExternalAssert".
atom_message(at_cache_seed)                      = "CacheSeed".
atom_message(at_realtime_contract)               = "RealtimeContract".
atom_message(at_series_backend_interval_pulse)   = "SeriesBackendIntervalPulse".
atom_message(at_series_backend_numeric_integral) = "SeriesBackendNumericIntegral".
atom_message(at_initial_fact)                    = "InitialFact".
atom_message(at_initial_cache_seed)              = "InitialCacheSeed".
atom_message(at_schema_def)                      = "SchemaDef".
atom_message(at_slot)                            = "Slot".
atom_message(at_stream_header)                   = "StreamHeader".
atom_message(at_rule_fire_annotation)            = "RuleFireAnnotation".
atom_message(at_call_issued)                     = "CallIssued".
atom_message(at_dsc_header)                      = "DscHeader".
atom_message(at_dialect_info)                    = "DialectInfo".
atom_message(at_capability_info)                 = "CapabilityInfo".
atom_message(at_ds_source)                       = "DsSource".
atom_message(at_alpha_node)                      = "AlphaNode".
atom_message(at_beta_node)                       = "BetaNode".
atom_message(at_terminal_node)                   = "TerminalNode".
atom_message(at_oracle_activated)                = "OracleActivated".
atom_message(at_oracle_emit)                     = "OracleEmit".
atom_message(at_oracle_publish)                  = "OraclePublish".
atom_message(at_oracle_call)                     = "OracleCall".
atom_message(at_oracle_cache_set)                = "OracleCacheSet".
atom_message(at_oracle_cache_delete)             = "OracleCacheDelete".
atom_message(at_oracle_log)                      = "OracleLog".
atom_message(at_oracle_retract)                  = "OracleRetract".
atom_message(at_oracle_working_memory)           = "OracleWorkingMemory".
atom_message(at_compiled_code)                   = "CompiledCode".
atom_message(at_schema_logical)                  = "SchemaLogical".
atom_message(at_schema_ttl)                      = "SchemaTtl".
atom_message(at_hydration)                       = "Hydration".
atom_message(at_schema_source)                   = "SchemaSource".
atom_message(at_line_span)                       = "LineSpan".
atom_message(at_doc_string)                      = "DocString".
atom_message(at_rule_cooldown)                   = "RuleCooldown".
atom_message(at_rule_source)                     = "RuleSource".
atom_message(at_rule_debug_name)                 = "RuleDebugName".
atom_message(at_service_def)                     = "ServiceDef".
atom_message(at_series_backend_welford_ewma)     = "SeriesBackendWelfordEwma".
atom_message(at_series_backend_ring_buffer)      = "SeriesBackendRingBuffer".
atom_message(at_series_backend_monotonic_deque)  = "SeriesBackendMonotonicDeque".
atom_message(at_series_backend_fifo_deque)       = "SeriesBackendFifoDeque".
atom_message(at_series_backend_reservoir)        = "SeriesBackendReservoir".
atom_message(at_test_case)                       = "TestCase".
atom_message(at_test_fact)                       = "TestFact".
atom_message(at_test_cache_seed)                 = "TestCacheSeed".
atom_message(at_test_response)                   = "TestResponse".
atom_message(at_test_reply)                      = "TestReply".
atom_message(at_oracle_exclusive)                = "OracleExclusive".
atom_message(at_computation_error)               = "ComputationError".
atom_message(at_fact_emit)                       = "FactEmit".
atom_message(at_fact_withdraw)                   = "FactWithdraw".
atom_message(at_type_error)                      = "TypeError".
atom_message(at_bounds_error)                    = "BoundsError".
atom_message(at_engine_error)                    = "EngineError".
atom_message(at_fact_publish)                    = "FactPublish".
% END GENERATED message

%-----------------------------------------------------------------------------%

band_of(N) =
    ( if N = 0u32 then
        band_none
    else if N =< 127u32 then
        band_inject
    else if N =< 255u32 then
        band_reject
    else if N =< 2047u32 then
        band_skip
    else
        band_none
    ).

disposition_of_unknown(N) = D :-
    B = band_of(N),
    (
        B = band_inject,
        D = disp_reject_inject
    ;
        B = band_reject,
        D = disp_reject_version
    ;
        B = band_skip,
        D = disp_skip
    ;
        B = band_none,
        D = disp_malformed
    ).

container_of(at_dsc_header, container_dsc).
container_of(at_stream_header, container_stream).

%-----------------------------------------------------------------------------%

:- func outer_field = uint32.

outer_field = 1u32.

next_frame(Result, !R) :-
    Offset = position(!.R),
    ( if at_end(!.R) then
        Result = fr_eof
    else if
        % Judged before the tag is read as a varint [RDSC.11.1], so a trailing
        % 0xFF is malformed rather than a varint still arriving.
        peek_byte(!.R, First),
        First \= 0x0Au8
    then
        Result = fr_error(ae_bad_outer_tag(uint32.cast_from_int(
            uint8.cast_to_int(First) >> 3)), Offset)
    else
        read_tag(TagResult, !R),
        (
            TagResult = error(E),
            Result = fr_error(ae_wire(E), Offset)
        ;
            TagResult = ok({Field, Type}),
            ( if Field \= outer_field then
                Result = fr_error(ae_bad_outer_tag(Field), Offset)
            else if Type \= wt_len then
                Result = fr_error(ae_bad_outer_tag(Field), Offset)
            else
                read_delimited(OuterResult, !R),
                (
                    OuterResult = error(E2),
                    Result = fr_error(ae_wire(E2), Offset)
                ;
                    OuterResult = ok(Atom),
                    Result = decode_atom(Atom, Offset)
                )
            )
        )
    ).

:- func decode_atom(reader, int) = frame_result.

decode_atom(Atom0, Offset) = Result :-
    ( if at_end(Atom0) then
        Result = fr_error(ae_empty_atom, Offset)
    else
        read_tag(TagResult, Atom0, Atom1),
        (
            TagResult = error(E),
            Result = fr_error(ae_body(E), Offset)
        ;
            TagResult = ok({Field, Type}),
            ( if Type \= wt_len then
                Result = fr_error(ae_bad_inner_type, Offset)
            else
                read_delimited(BodyResult, Atom1, _Atom2),
                (
                    BodyResult = error(E2),
                    Result = fr_error(ae_body(E2), Offset)
                ;
                    BodyResult = ok(Body),
                    ( if atom_of_field(Field, A) then
                        Result = fr_ok(frame(known(A), Body, Offset))
                    else
                        % The caller applies `disposition_of_unknown`.
                        Result = fr_ok(frame(unknown(Field), Body, Offset))
                    )
                )
            )
        )
    ).

%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.rfcs -- the recorded fact stream: writing it, and reading it back.
%
% `(timetag, rule_name)` is the `CallIssued` <-> `RuleFireAnnotation` join key
% [RFCS.11.2, RFCS.15.2].
%
% A host input whose fact holds a reference is one `ExternalAssert` (RFCS.24): the
% fact body has no encoding for a reference. The engine brackets such an input in
% its effect list (`ds.events.host_input`).
%
% `FactAssert.fact` is an instance of the `.proto` message the compiler generates
% per schema. This encoder derives the shape from the slot descriptors: the field
% number is the slot index + 1, the wire type follows `slot_kind` (`RDSC.5.8.6`).
%-----------------------------------------------------------------------------%

:- module ds.rfcs.
:- interface.

:- import_module ds.atom.
:- import_module ds.events.
:- import_module ds.id.
:- import_module ds.schema.
:- import_module ds.chrono.
:- import_module ds.value.
:- import_module ds.intern.
:- import_module bitmap.
:- import_module bool.

:- import_module list.
:- import_module maybe.
:- import_module set.
:- import_module uint64.
:- import_module uint8.

%-----------------------------------------------------------------------------%

    % What the header needs that the events do not carry.
    %
:- type stream_meta
    --->    stream_meta(
                sm_ds_version :: string,
                            % [LDET.1.10]: the version that wrote the stream.

                sm_dsc_hash  :: list(uint8),
                            % [RBND.1.3]
                sm_capabilities :: list(int),
                sm_def_sha   :: list(uint8),
                            % The rest of the dialect-binding tuple [RBND.1.3],
                            % fields 16 and 9, copied from the program's header.
                sm_session   :: string,
                            % the run id, "" if none ([RFCS.4.3])
                sm_tier      :: string
                            % the tier id, "" if none ([RFCS.4.4])
            ).

    % The wire carries text, so the intern table comes with the events.
    %
:- type rfcs_ctx
    --->    rfcs_ctx(
                rc_schemas :: list(schema),
                rc_interns :: intern_table
            ).

    % Fails for an event that reaches no atom. The meta is for the ids a
    % `FactAssert`'s `event_id` derives from.
    %
:- pred encode_event(stream_meta::in, rfcs_ctx::in, instant::in, seq::in,
                     stream_event::in, list(uint8)::out) is semidet.

    % The `event_id` a `FactAssert` or `FactEmit` carries: SHA-256 over
    % "ds.rfcs.event_id.v1", 0x1F, the run id, 0x1F, the tier id, 0x1F and the seq as
    % eight big-endian bytes; the first sixteen bytes, the version nibble set to 8
    % and the variant bits to 10, as lowercase hex in the 8-4-4-4-12 shape. Either id
    % may be "" ([NLFC.1.2]).
    %
%@spec [LFST.5.6]
:- func lfst_5_6_event_id(string, string, uint64) = string.

    % The `StreamHeader` header frame.
    %
:- func encode_header(stream_meta) = list(uint8).

    % True for the event kinds that reach an atom at all, which tells "not
    % recorded" from "could not be encoded".
    %
:- pred recordable(stream_event::in) is semidet.

    % A whole recording, with no `CacheSeed`s: the header, the schema prelude, then
    % every event that reaches an atom. `Unencodable` lists the recordable events
    % that did not encode.
    %
    % The instant is the clock when the recording began: every atom carries the clock
    % at its own event, advanced through the stream by each `se_clock_tick`
    % ([LTIM.2.8.5]).
    %
:- pred encode_stream(stream_meta::in, rfcs_ctx::in, instant::in,
                      list({seq, stream_event})::in,
                      list(uint8)::out, list(stream_event)::out) is det.

    % A `CacheSeed` ([RFCS.26.1]): the key, the value's canonical JSON text
    % ([IARC.12.2]), and the entry's deadline in engine-clock nanoseconds, 0 for none.
    %
:- type cache_seed
    --->    cache_seed(
                cs_key         :: string,
                cs_value_json  :: string,
                cs_deadline_ns :: uint64
            ).

    % What a recorder reads off the effect list: the events, numbered, and the
    % brackets around a host input, which take no `seq`.
    %
:- type record_item
    --->    ri_event(seq, stream_event)
    ;       ri_input(host_input).

    % An effect list's record items, its events numbered from `First`.
    %
:- func record_items(uint64, list(effect)) = list(record_item).

    % `encode_stream` over record items, with each bracketed input written as one
    % `ExternalAssert` (RFCS.24.1) at its first FactAssert's place, and every other
    % atom the input produced after it (RFCS.24.3).
    %
    % `Seeds` are the host's cache seeds ([RFCS.26.1]), written right after the schema
    % prelude, ascending by the key's UTF-8 bytes; `[]` for a recording begun after
    % the engine's first stream event.
    %
:- pred encode_recording(stream_meta::in, rfcs_ctx::in, instant::in,
                         list(cache_seed)::in, list(record_item)::in,
                         list(uint8)::out, list(stream_event)::out) is det.

:- pred encode_fact_body(rfcs_ctx::in, schema::in, list(ds_value)::in,
                         list(uint8)::out) is semidet.

%-----------------------------------------------------------------------------%
% Comparing a replay
%-----------------------------------------------------------------------------%

    % One compare-class atom ([RFCS.3.4], [LFST.9.3.1]) as its field number and its
    % body's bytes. Never a `pump_wcet_ns` BoundsError ([LFST.9.2.1]).
    %
:- type compare_atom
    --->    compare_atom(
                ca_atom :: atom_id,
                ca_body :: list(uint8)
            ).

    % [LFST.9.3.6]: a body's fields other than `timetag`, each as written, and the
    % `timetag`, 0 when absent. Fails for an atom that carries no `timetag` field, and
    % for a body that does not read.
    %
:- pred split_timetag(compare_atom::in, list(list(uint8))::out, uint64::out)
    is semidet.

    % A recorder on a replaying engine that keeps only the compare-class atoms,
    % writing each as `encode_recording` does.
    %
:- type capture.

:- func capture_init(instant) = capture.

    % The compare-class atoms one step's effects write. `First` is the `seq` of the
    % step's first event. An event that does not encode writes nothing.
    %
:- pred capture_step(stream_meta::in, rfcs_ctx::in, uint64::in,
                     list(effect)::in, list(compare_atom)::out,
                     capture::in, capture::out) is det.

%-----------------------------------------------------------------------------%
% Reading
%-----------------------------------------------------------------------------%
%
% A recording is self-describing ([RFCS.5.1]), so the reader builds its schema table
% as it walks. It carries no lifecycle, hence a list of names and no `schema`.

:- type decoded_stream
    --->    decoded_stream(
                dsm_meta   :: stream_meta,
                dsm_events :: list({seq, stream_event}),
                dsm_interns :: intern_table,
                            % Grown by decoding; the events are usable against
                            % this table and no other.

                dsm_emitted :: set(uint64),
                            % The `seq` of every `FactEmit`. Both atoms decode to
                            % `se_fact_assert`; this says which facts a replay
                            % delivers and which it re-derives ([RFCS.6a.1]).

                dsm_schemas :: list(string),
                            % Schema names in `SchemaDef` order: the synthetic
                            % `schema_id` of a decoded `se_fact_assert` indexes
                            % this, from 1. A name is all a stream and an engine
                            % share.

                dsm_first_seq :: maybe(uint64),
                            % The `seq` of the first event atom; `no` for none.
                            % Anything but `yes(0)` and `no` is refused
                            % ([LTIM.2.8.5], [LFST.5.3]).

                dsm_external :: list(recorded_external),
                            % Every `ExternalAssert`, in stream order (RFCS.24).
                            % Not events: which FactAsserts one stands for depends
                            % on working memory when it is delivered.

                dsm_compare :: list(recorded_compare),
                            % Every compare-class atom, in stream order, as
                            % written ([LFST.9.3.1]).

                dsm_seeds :: list(recorded_seed)
                            % every `CacheSeed`, in stream order ([RFCS.26])
            ).

    % One `CacheSeed` and where it sat. `rsd_late` is whether an event atom came before
    % it ([RFCS.26.2]); `rsd_events` and `rsd_external` count what was read before it,
    % and `rsd_seq` is the last event's `seq`.
    %
:- type recorded_seed
    --->    recorded_seed(
                rsd_late     :: bool,
                rsd_events   :: int,
                rsd_external :: int,
                rsd_seq      :: uint64,
                rsd_seed     :: cache_seed
            ).

    % One compare-class atom as held, and where: `rcm_events` and `rcm_external` count
    % the `dsm_events` and `dsm_external` read before it.
    %
:- type recorded_compare
    --->    recorded_compare(
                rcm_events   :: int,
                rcm_external :: int,
                rcm_seq      :: uint64,
                rcm_atom     :: compare_atom
            ).

    % One `ExternalAssert`. `re_after` is its place in the file, the number of
    % `dsm_events` read before it: a replay delivers in the file's order. `re_ttl_ns` is
    % 0 for the schema's own window.
    %
:- type recorded_external
    --->    recorded_external(
                re_after    :: int,
                re_seq      :: seq,
                re_fact     :: list(uint8),
                re_fact_ids :: list(uint64),
                re_ttl_ns   :: uint64,
                re_clock_ns :: uint64
            ).

:- type decode_result
    --->    decoded(decoded_stream)
    ;       decode_failed(string, int)      % clause id, byte offset
    ;       unannounced_schema(decoded_stream, uint64, int).
            % [RFCS.5.4]: the `FactAssert` with this `seq`, at this byte offset,
            % names a schema no `SchemaDef` before it announced. The walk stops
            % there (`ds.replay.replay_unannounced`).

    % The buffer is the whole stream, so a partial trailing atom is refused
    % ([RFCS.19.2]).
    %
:- pred decode_stream(bitmap::in, intern_table::in, decode_result::out) is det.

    % What has arrived of a recording that may be growing or was cut off
    % ([RFCS.19.8]). A partial trailing atom ends the stream ([RFCS.19.2]), and
    % `TailBytes` is its length. A prefix too short to hold the whole `StreamHeader` is
    % refused under [LDET.1.10].
    %
:- pred decode_stream_prefix(bitmap::in, intern_table::in, decode_result::out,
                             int::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.action.
:- import_module ds.binding.
:- import_module ds.fact.
:- import_module ds.fact_external.
:- import_module ds.fault.
:- import_module ds.format.
:- import_module ds.json.
:- import_module ds.json_text.
:- import_module ds.sha256.
:- import_module ds.version.
:- import_module ds.wire.
:- import_module map.
:- import_module string.
:- import_module int.
:- import_module int64.
:- import_module uint32.
:- import_module assoc_list.
:- import_module pair.
:- import_module builtin.
:- import_module require.

%-----------------------------------------------------------------------------%

encode_header(Meta) = Bytes :-
    % `RDSC.3.6`'s "zeroed" hash is 32 zero bytes, written; an empty list is omitted.
    (
        Meta ^ sm_dsc_hash = [],
        B2 = init_builder
    ;
        Meta ^ sm_dsc_hash = [_ | _],
        put_delimited(4u32, Meta ^ sm_dsc_hash, init_builder, B2)
    ),
    put_string(5u32, Meta ^ sm_session, B2, B3),
    put_string(6u32, Meta ^ sm_tier, B3, B4),
    % [RBND.2]: in field-number order. `capabilities` is packed.
    (
        Meta ^ sm_def_sha = [],
        B5 = B4
    ;
        Meta ^ sm_def_sha = [_ | _],
        put_delimited(9u32, Meta ^ sm_def_sha, B4, B5)
    ),
    put_string(10u32, Meta ^ sm_ds_version, B5, B6),
    (
        Meta ^ sm_capabilities = [],
        Body = B6
    ;
        Meta ^ sm_capabilities = [_ | _],
        list.foldl(
            ( pred(C::in, P0::in, P::out) is det :-
                put_varint(uint64.cast_from_int(C), P0, P) ),
            Meta ^ sm_capabilities, init_builder, Packed),
        put_delimited(16u32, builder_bytes(Packed), B6, Body)
    ),
    frame(at_stream_header, builder_bytes(Body), Bytes).

recordable(se_fact_assert(_, _, _, _)).
recordable(se_fact_retract(_)).
recordable(se_fact_withdraw(_, _)).
recordable(se_fact_withdraw_unnamed(_, _)).
recordable(se_emit(_, _)).
recordable(se_publish(_, _, _)).
recordable(se_clock_tick(_, _)).
recordable(se_pump_boundary).
recordable(se_fire_begin(_)).
recordable(se_fire_end(_)).
recordable(se_call_issued(_, _, _, _, _)).
recordable(se_engine_error(_, _)).

lfst_5_6_event_id(Run, Tier, Seq) = Id :-
    Sep = [0x1Fu8],
    Input = utf8_bytes("ds.rfcs.event_id.v1") ++ Sep ++ utf8_bytes(Run)
        ++ Sep ++ utf8_bytes(Tier) ++ Sep ++ be64_bytes(Seq),
    Head = list.take_upto(16, ds.sha256.sha256(Input)),
    Hex = ds.sha256.hex(list.map_corresponding(uuid_bits, 0 .. 15, Head)),
    Id = string.between(Hex, 0, 8) ++ "-" ++ string.between(Hex, 8, 12)
        ++ "-" ++ string.between(Hex, 12, 16) ++ "-"
        ++ string.between(Hex, 16, 20) ++ "-" ++ string.between(Hex, 20, 32).

    % RFC 9562 version 8 in byte 6, the RFC 4122 variant in byte 8; every
    % other byte as the digest gave it.
    %
:- func uuid_bits(int, uint8) = uint8.

uuid_bits(I, B) =
    ( if I = 6 then (B /\ 0x0Fu8) \/ 0x80u8
    else if I = 8 then (B /\ 0x3Fu8) \/ 0x80u8
    else B ).

:- func utf8_bytes(string) = list(uint8).

utf8_bytes(S) = list.map(uint8.cast_from_int, Codes) :-
    string.to_utf8_code_unit_list(S, Codes).

:- func be64_bytes(uint64) = list(uint8).

be64_bytes(V) = list.map(
    (func(Shift) = uint8.cast_from_int(uint64.cast_to_int(
        (V >> Shift) /\ 0xFFu64))),
    [56, 48, 40, 32, 24, 16, 8, 0]).

encode_stream(Meta, Env, Origin, Records, Bytes, Unencodable) :-
    encode_recording(Meta, Env, Origin, [],
        list.map((func({S, E}) = ri_event(S, E)), Records), Bytes, Unencodable).

record_items(First, Effects) = list.reverse(Rev) :-
    list.foldl2(record_item, Effects, First, _, [], Rev).

:- pred record_item(effect::in, uint64::in, uint64::out,
                    list(record_item)::in, list(record_item)::out) is det.

record_item(eff_event(E), N, N + 1u64, Acc, [ri_event(make_seq(N), E) | Acc]).
record_item(eff_input(I), N, N, Acc, [ri_input(I) | Acc]).
record_item(eff_action(_), N, N, Acc, Acc).
record_item(eff_cache_expired(_), N, N, Acc, Acc).
record_item(eff_metric(_), N, N, Acc, Acc).
record_item(eff_host_log(_, _, _), N, N, Acc, Acc).
record_item(eff_pump_status(_), N, N, Acc, Acc).

encode_recording(Meta, Env, Origin, Seeds, Items, Bytes, Unencodable) :-
    list.foldl3(encode_item(Meta, Env), Items,
        enc_state(no, map.init, Origin, no), _, [], RevEncoded, [],
        RevFailed),
    Encoded = list.reverse(RevEncoded),
    Unencodable = list.reverse(RevFailed),
    % The prelude holds every schema, less the compiler-synthesised, before the facts
    % that use them [RFCS.5.1]. A synthetic fact never reaches the effect list.
    list.negated_filter(synthetic(Env ^ rc_interns), Env ^ rc_schemas,
        Recorded),
    Prelude = list.condense(list.map(encode_schema(Env), Recorded)),
    Bytes = encode_header(Meta) ++ Prelude
        ++ list.condense(list.map(rfcs_26_1_cache_seed, seed_order(Seeds)))
        ++ list.condense(Encoded).

    % [RFCS.26.1]: ascending by the key's UTF-8 bytes.
    %
:- func seed_order(list(cache_seed)) = list(cache_seed).

seed_order(Seeds) = list.map((func({_, S}) = S), list.sort(Keyed)) :-
    Keyed = list.map((func(S) = {utf8_bytes(S ^ cs_key), S}), Seeds).

    % `key` = 1, `value_json` = 2, `deadline_ns` = 3.
    %
    %@spec [RFCS.26.1]
:- func rfcs_26_1_cache_seed(cache_seed) = list(uint8).

rfcs_26_1_cache_seed(cache_seed(Key, Value, Deadline)) = Bytes :-
    put_string(1u32, Key, init_builder, B1),
    put_string(2u32, Value, B1, B2),
    put_uint64(3u32, Deadline, B2, Body),
    frame(at_cache_seed, builder_bytes(Body), Bytes).

:- type capture
    --->    capture(enc_state).

capture_init(Origin) = capture(enc_state(no, map.init, Origin, no)).

capture_step(Meta, Env, First, Effects, Atoms, capture(St0), capture(St)) :-
    list.foldl3(encode_item(Meta, Env), record_items(First, Effects), St0, St,
        [], RevEncoded, [], _),
    Atoms = list.filter_map(captured, list.reverse(RevEncoded)).

    % An encoded frame's atom, when it is one a replay compares.
    %
:- func captured(list(uint8)) = compare_atom is semidet.

captured(Frame) = compare_atom(Atom, reader_bytes(F ^ fr_body)) :-
    next_frame(fr_ok(F), init_reader(octets_bitmap(Frame)), _),
    F ^ fr_atom = known(Atom),
    lfst_9_3_1_compared(Atom, F ^ fr_body).

split_timetag(compare_atom(Atom, Body), Kept, Timetag) :-
    timetag_field(Atom, Field),
    split_fields(Field, Body, init_reader(octets_bitmap(Body)), [], RevKept,
        0u64, Timetag),
    Kept = list.reverse(RevKept).

    % The field number of `timetag` in a compare atom's body, from its proto.
    %
:- pred timetag_field(atom_id::in, uint32::out) is semidet.

timetag_field(at_rule_fire_annotation, 6u32).
timetag_field(at_call_issued, 8u32).
timetag_field(at_bounds_error, 5u32).
timetag_field(at_computation_error, 3u32).
timetag_field(at_fact_publish, 5u32).

:- pred split_fields(uint32::in, list(uint8)::in, reader::in,
                     list(list(uint8))::in, list(list(uint8))::out,
                     uint64::in, uint64::out) is semidet.

split_fields(Field, Body, R0, !Kept, !Timetag) :-
    next_field(Res, R0, R1),
    (
        Res = fields_end
    ;
        Res = field(Num, Value),
        ( if Num = Field, Value = fv_varint(V) then
            !:Timetag = V
        else
            list.drop(position(R0), Body, From),
            list.take(position(R1) - position(R0), From, Bytes),
            !:Kept = [Bytes | !.Kept]
        ),
        split_fields(Field, Body, R1, !Kept, !Timetag)
    ).

    % [RFCS.3.1]: the atoms a replay re-derives and compares, a `FactPublish`
    % among them ([RFCS.27.2]).
    %
    %@spec [LFST.9.3.1]
:- pred lfst_9_3_1_compared(atom_id::in, reader::in) is semidet.

lfst_9_3_1_compared(at_rule_fire_annotation, _).
lfst_9_3_1_compared(at_call_issued, _).
lfst_9_3_1_compared(at_fact_emit, _).
lfst_9_3_1_compared(at_fact_publish, _).
lfst_9_3_1_compared(at_fact_withdraw, _).
lfst_9_3_1_compared(at_engine_error, _).
lfst_9_3_1_compared(at_type_error, _).
lfst_9_3_1_compared(at_computation_error, _).
lfst_9_3_1_compared(at_bounds_error, Body) :-
    not lfst_9_2_1_wcet(Body).

    % A `BoundsError` naming `CAP_PUMP_WCET_NS` (`cap` = 1).
    %
    %@spec [LFST.9.2.1]
:- pred lfst_9_2_1_wcet(reader::in) is semidet.

lfst_9_2_1_wcet(Body) :-
    fold_fields(Body, seq_field(1u32), 0u64, ff_ok(Cap)),
    Cap = uint32.cast_to_uint64(cap_name_number(cap_pump_wcet)).

    % `SchemaDef`, then one `Slot` per slot, in declaration order.
    %
:- func encode_schema(rfcs_ctx, schema) = list(uint8).

encode_schema(Ctx, Schema) = Bytes :-
    ( if expand(Ctx ^ rc_interns, schema_name_ref(Schema ^ s_name), Name) then
        put_string(1u32, Name, init_builder, D0),
        % `COMPRESSION_NONE` is 1 ([RDSC.4.3-4.5.1]); zero is unspecified.
        put_uint32(2u32, 1u32, D0, D1),
        (
            Schema ^ s_proto = yes(Proto),
            Text = proto_source_text(Proto),
            put_string(3u32, Text, D1, D2)
        ;
            Schema ^ s_proto = no,
            D2 = D1
        ),
        frame(at_schema_def, builder_bytes(D2), SdefBytes),
        Slots = list.map(encode_slot_atom(Ctx, Name),
            slot_announcements(Schema ^ s_lifecycle)),
        Bytes = SdefBytes ++ list.condense(Slots)
    else
        Bytes = []
    ).

    % A slot as its `Slot` atom announces it ([RFCS.5.1]). Only a `logical` slot has a
    % role and a tolerance ([RDSC.5.5.7]).
    %
:- type slot_announcement
    --->    slot_announcement(
                sa_common    :: slot_common,
                sa_role      :: maybe(identity_role),
                sa_tolerance :: tolerance
            ).

:- func slot_announcements(lifecycle) = list(slot_announcement).

slot_announcements(lc_logical(Slots, _)) = list.map(
    (func(S) = slot_announcement(S ^ ls_common, yes(S ^ ls_role),
        S ^ ls_tolerance)),
    Slots).
slot_announcements(lc_ttl(Slots, _)) = list.map(plain_announcement, Slots).
slot_announcements(lc_explicit(Slots)) = list.map(plain_announcement, Slots).
slot_announcements(lc_activation(Slots)) = list.map(plain_announcement, Slots).

:- func plain_announcement(plain_slot) = slot_announcement.

plain_announcement(S) = slot_announcement(S ^ ps_common, no, exact).

    % `proto/slot.proto#IdentityRole`.
    %
:- func identity_role_code(identity_role) = uint32.

identity_role_code(role_key) = 1u32.
identity_role_code(role_mutable) = 2u32.
identity_role_code(role_engine) = 3u32.

    % One `Slot` atom, in field-number order, as it would stand in the artefact
    % ([RFCS.5.1]). `module_id` is not announced.
    %
:- func encode_slot_atom(rfcs_ctx, string, slot_announcement) = list(uint8).

encode_slot_atom(Ctx, SchemaName, Announced) = Bytes :-
    Slot = Announced ^ sa_common,
    ( if expand(Ctx ^ rc_interns, Slot ^ sc_name, N) then
        SlotName = N
    else
        SlotName = ""
    ),
    put_string(1u32, SchemaName, init_builder, S1),
    put_string(2u32, SlotName, S1, S2),
    put_uint32(3u32, slot_kind_code(Slot ^ sc_kind), S2, S3a),
    % `schema_ref` = 4: a reader needs it to know the slot's field is a `uint64`
    % handle (RFCS.6.3).
    ( if
        Slot ^ sc_kind = k_schema(Ref),
        expand(Ctx ^ rc_interns, schema_name_ref(Ref), RefText)
    then
        put_string(4u32, RefText, S3a, S3)
    else
        S3 = S3a
    ),
    (
        Slot ^ sc_sampled = yes,
        put_bool(5u32, yes, S3, S4)
    ;
        Slot ^ sc_sampled = no,
        S4 = S3
    ),
    (
        Slot ^ sc_retained = yes,
        put_bool(6u32, yes, S4, S5)
    ;
        Slot ^ sc_retained = no,
        S5 = S4
    ),
    % `tolerance` = 7 ([LFAC.2.5.1]). `put_double` omits +0.0.
    (
        Announced ^ sa_tolerance = within(T),
        ( if put_double(7u32, T, S5, S6a) then
            S6 = S6a
        else
            unexpected($pred, "a tolerance's bit pattern did not parse")
        )
    ;
        Announced ^ sa_tolerance = exact,
        S6 = S5
    ),
    % `identity_role` = 9 ([RDSC.5.5.7]).
    (
        Announced ^ sa_role = yes(Role),
        put_uint32(9u32, identity_role_code(Role), S6, S7)
    ;
        Announced ^ sa_role = no,
        S7 = S6
    ),
    % `nullable` = 11 ([RDSC.7.1], [RFCS.6.3]).
    (
        Slot ^ sc_nullable = nullable,
        put_bool(11u32, yes, S7, S8)
    ;
        Slot ^ sc_nullable = non_null,
        S8 = S7
    ),
    % `capacity` = 12 ([LSTR.11.1]).
    (
        Slot ^ sc_capacity = at_most(Cap),
        put_uint32(12u32, Cap, S8, S9)
    ;
        Slot ^ sc_capacity = unbounded,
        S9 = S8
    ),
    frame(at_slot, builder_bytes(S9), Bytes).

    % `SlotKind`.
    %
:- func slot_kind_code(slot_kind) = uint32.

slot_kind_code(k_int) = 1u32.
slot_kind_code(k_float) = 2u32.
slot_kind_code(k_string) = 3u32.
slot_kind_code(k_bool) = 4u32.
slot_kind_code(k_json) = 5u32.
slot_kind_code(k_schema(_)) = 6u32.
slot_kind_code(k_bytes) = 7u32.
slot_kind_code(k_time) = 8u32.
slot_kind_code(k_date) = 9u32.
slot_kind_code(k_duration) = 10u32.

:- func slot_commons_of(lifecycle) = list(slot_common).

slot_commons_of(lc_logical(Slots, _)) =
    list.map((func(S) = S ^ ls_common), Slots).
slot_commons_of(lc_ttl(Slots, _)) =
    list.map((func(S) = S ^ ps_common), Slots).
slot_commons_of(lc_explicit(Slots)) =
    list.map((func(S) = S ^ ps_common), Slots).
slot_commons_of(lc_activation(Slots)) =
    list.map((func(S) = S ^ ps_common), Slots).

    % What the writer carries across events.
    %
:- type enc_state
    --->    enc_state(
                es_fire   :: maybe(fire_id),
                            % An assert inside a fire frame is rule-origin, a
                            % FactEmit [RFCS.6a]: no host assert arrives during a
                            % firing.
                es_bodies :: map(fact_id,
                                 {schema_id, list(ds_value), maybe(duration)}),
                            % A FactEmit is written at the verb marker, which names
                            % only the fact id; a no-op emit's fact was asserted
                            % earlier.
                es_clock  :: instant,
                            % the last tick's, or the recording's origin
                es_delivery :: maybe(delivery)
                            % Between a host input's brackets (RFCS.24) its
                            % FactAsserts are noted and every other atom waits.
            ).

:- type delivery
    --->    delivery(
                dl_fact     :: list(uint8),
                dl_first    :: maybe({seq, instant}),
                            % the first FactAssert's seq and clock
                dl_rev_ids  :: list(uint64),
                dl_ttl      :: uint64,
                            % the last FactAssert's window, the received fact's
                dl_rev_held :: list(list(uint8))
            ).

:- pred encode_item(stream_meta::in, rfcs_ctx::in, record_item::in,
                    enc_state::in, enc_state::out,
                    list(list(uint8))::in, list(list(uint8))::out,
                    list(stream_event)::in, list(stream_event)::out) is det.

encode_item(Meta, Env, ri_event(Seq, Event), !St, !Enc, !Failed) :-
    encode_record(Meta, Env, {Seq, Event}, !St, !Enc, !Failed).
encode_item(_, _, ri_input(hi_open(Fact)), !St, !Enc, !Failed) :-
    % Never opened inside another ([RARC.13.16]).
    !St ^ es_delivery := yes(delivery(Fact, no, [], 0u64, [])).
encode_item(_, _, ri_input(hi_close), !St, !Enc, !Failed) :-
    (
        !.St ^ es_delivery = yes(D),
        % A delivery with no assert writes no ExternalAssert; what it held still goes.
        (
            D ^ dl_first = yes({Seq, Clock}),
            !:Enc = [rfcs_24_1_fcxt(D ^ dl_fact, list.reverse(D ^ dl_rev_ids),
                D ^ dl_ttl, Clock, Seq) | !.Enc]
        ;
            D ^ dl_first = no
        ),
        !:Enc = D ^ dl_rev_held ++ !.Enc,
        !St ^ es_delivery := no
    ;
        !.St ^ es_delivery = no
    ).

    % `ExternalAssert` (RFCS.24.1): `fact` = 1, `fact_ids` = 2, packed, `ttl_ns` = 3,
    % `clock_ns` = 4, `seq` = 5.
    %
    %@helper
:- func rfcs_24_1_fcxt(list(uint8), list(uint64), uint64, instant, seq)
    = list(uint8).

rfcs_24_1_fcxt(Fact, Ids, Ttl, Clock, Seq) = Bytes :-
    ( if Fact = [] then
        B1 = init_builder
    else
        put_delimited(1u32, Fact, init_builder, B1)
    ),
    (
        Ids = [],
        B2 = B1
    ;
        Ids = [_ | _],
        list.foldl(put_varint, Ids, init_builder, Packed),
        put_delimited(2u32, builder_bytes(Packed), B1, B2)
    ),
    put_uint64(3u32, Ttl, B2, B3),
    put_uint64(4u32, instant_ns(Clock), B3, B4),
    put_uint64(5u32, seq_value(Seq), B4, Body),
    frame(at_external_assert, builder_bytes(Body), Bytes).

:- pred emit_atom(list(uint8)::in, enc_state::in, enc_state::out,
                  list(list(uint8))::in, list(list(uint8))::out) is det.

emit_atom(Bytes, !St, !Enc) :-
    (
        !.St ^ es_delivery = yes(D),
        !St ^ es_delivery := yes(D ^ dl_rev_held := [Bytes | D ^ dl_rev_held])
    ;
        !.St ^ es_delivery = no,
        !:Enc = [Bytes | !.Enc]
    ).

:- pred encode_record(stream_meta::in, rfcs_ctx::in, {seq, stream_event}::in,
                      enc_state::in, enc_state::out,
                      list(list(uint8))::in, list(list(uint8))::out,
                      list(stream_event)::in, list(stream_event)::out) is det.

encode_record(Meta, Env, {Seq, Event}, !St, !Enc, !Failed) :-
    ( if Event = se_fire_begin(Fire) then
        !St ^ es_fire := yes(Fire)
    else if Event = se_fire_end(_) then
        !St ^ es_fire := no
    else if Event = se_fact_assert(Id, SchemaId, Values, Ttl) then
        map.set(Id, {SchemaId, Values, Ttl}, !.St ^ es_bodies, Bodies),
        !St ^ es_bodies := Bodies
    else if Event = se_clock_tick(To, _) then
        % `clock_ns` is the monotonic clock ([RFCS.6.6]).
        !St ^ es_clock := To
    else
        true
    ),
    Clock = !.St ^ es_clock,
    ( if
        Event = se_fact_assert(_, AssertedSchema, _, _),
        ( !.St ^ es_fire = yes(_)
        ; engine_fault_fact(Env, AssertedSchema)
        )
    then
        % Rule-origin, or a fault fact ([LERR.9.8]): its atom is the FactEmit its
        % verb marker writes.
        true
    else if
        Event = se_fact_assert(Delivered, _, _, DeliveredTtl),
        !.St ^ es_delivery = yes(D0)
    then
        % RFCS.24.3: listed in the ExternalAssert, with no atom of its own.
        (
            D0 ^ dl_first = yes(_),
            D1 = D0
        ;
            D0 ^ dl_first = no,
            D1 = D0 ^ dl_first := yes({Seq, Clock})
        ),
        (
            DeliveredTtl = yes(W),
            Window = duration_ns(W)
        ;
            DeliveredTtl = no,
            Window = 0u64
        ),
        !St ^ es_delivery := yes((D1
            ^ dl_rev_ids := [fact_id_value(Delivered) | D1 ^ dl_rev_ids])
            ^ dl_ttl := Window)
    else if Event = se_emit(MarkedId, _) then
        ( if femt(Meta, Env, Clock, Seq, !.St, MarkedId, FBytes) then
            emit_atom(FBytes, !St, !Enc)
        else
            !:Failed = [Event | !.Failed]
        )
    else if Event = se_publish(PublishedSchema, _, _) then
        ( if fpub(Env, Clock, Seq, !.St, PublishedSchema, PBytes) then
            emit_atom(PBytes, !St, !Enc)
        else
            !:Failed = [Event | !.Failed]
        )
    else if recordable(Event) then
        ( if encode_event(Meta, Env, Clock, Seq, Event, Bytes) then
            emit_atom(Bytes, !St, !Enc)
        else
            !:Failed = [Event | !.Failed]
        )
    else
        true
    ).

    % `FactEmit`. Refused outside a firing [RFCS.6a], except a fault fact ([LERR.9.7]),
    % whose `rule_name` is its own `rule` slot ([LERR.9.8], [LERR.9.11]). Its
    % `event_id` derives from the marker's seq, which this atom carries. Field 9
    % is reserved: a `publish` records a `FactPublish` ([RFCS.27.1]).
    %
:- pred femt(stream_meta::in, rfcs_ctx::in, instant::in, seq::in,
             enc_state::in, fact_id::in, list(uint8)::out)
    is semidet.

femt(Meta, Env, Clock, Seq, St, Id, Bytes) :-
    map.search(St ^ es_bodies, Id, {SchemaId, Values, Ttl}),
    find_schema(Env, SchemaId, Schema),
    encode_fact_body(Env, Schema, Values, FactBytes),
    expand(Env ^ rc_interns, schema_name_ref(Schema ^ s_name), NameText),
    ( if St ^ es_fire = yes(Fire) then
        expand(Env ^ rc_interns, Fire ^ fi_rule, RuleName)
    else
        fault_fact_rule(Env, Schema, Values, RuleName)
    ),
    put_uint64(1u32, fact_id_value(Id), init_builder, B1),
    put_string(2u32, NameText, B1, B2),
    ( if FactBytes = [] then
        B3 = B2
    else
        put_delimited(3u32, FactBytes, B2, B3)
    ),
    (
        Ttl = yes(D),
        put_uint64(4u32, duration_ns(D), B3, B4)
    ;
        Ttl = no,
        B4 = B3
    ),
    put_string(5u32, RuleName, B4, B5),
    put_uint64(6u32, instant_ns(Clock), B5, B6),
    put_uint64(7u32, seq_value(Seq), B6, B7),
    put_string(8u32, lfst_5_6_event_id(Meta ^ sm_session, Meta ^ sm_tier,
        seq_value(Seq)), B7, Body),
    frame(at_fact_emit, builder_bytes(Body), Bytes).

    % `FactPublish` ([RFCS.27.1]): the schema, the rule, the action's clock and
    % seq, and the firing's timetag; no value and no handle ([LTIE.4.3]).
    % Refused outside a firing: `rule_name` is never "".
    %
:- pred fpub(rfcs_ctx::in, instant::in, seq::in, enc_state::in,
             schema_id::in, list(uint8)::out) is semidet.

fpub(Env, Clock, Seq, St, SchemaId, Bytes) :-
    St ^ es_fire = yes(Fire),
    find_schema(Env, SchemaId, Schema),
    expand(Env ^ rc_interns, schema_name_ref(Schema ^ s_name), NameText),
    expand(Env ^ rc_interns, Fire ^ fi_rule, RuleName),
    RuleName \= "",
    put_string(1u32, NameText, init_builder, B1),
    put_string(2u32, RuleName, B1, B2),
    put_uint64(3u32, instant_ns(Clock), B2, B3),
    put_uint64(4u32, seq_value(Seq), B3, B4),
    put_uint64(5u32, timetag_value(Fire ^ fi_timetag), B4, Body),
    frame(at_fact_publish, builder_bytes(Body), Bytes).

    % A schema id naming a built-in fault schema ([LERR.9.4]).
    %
:- pred engine_fault_fact(rfcs_ctx::in, schema_id::in) is semidet.

engine_fault_fact(Env, SchemaId) :-
    find_schema(Env, SchemaId, Schema),
    expand(Env ^ rc_interns, schema_name_ref(Schema ^ s_name), Name),
    lerr_9_4_fault_schema_name(Name).

:- pred fault_fact_rule(rfcs_ctx::in, schema::in, list(ds_value)::in,
                        string::out) is semidet.

fault_fact_rule(Env, Schema, Values, Rule) :-
    expand(Env ^ rc_interns, schema_name_ref(Schema ^ s_name), Name),
    ( Name = "ComputationError" ; Name = "TypeError" ),
    slot_named(Env, "rule", slot_commons(Schema), Values, str(Ref)),
    expand(Env ^ rc_interns, Ref, Rule).

:- pred slot_named(rfcs_ctx::in, string::in, list(slot_common)::in,
                   list(ds_value)::in, ds_value::out) is semidet.

slot_named(Env, Want, [C | Cs], [V | Vs], Found) :-
    ( if expand(Env ^ rc_interns, C ^ sc_name, Want) then
        Found = V
    else
        slot_named(Env, Want, Cs, Vs, Found)
    ).

    % `FactWithdraw.Cause` ([RFCS.7a.2]). `rc_explicit` has none: a host retract is a
    % FactRetract.
    %
:- pred withdraw_cause_code(retract_cause::in, uint32::out) is semidet.

withdraw_cause_code(rc_justifier_end, 1u32).
withdraw_cause_code(rc_ttl, 2u32).
withdraw_cause_code(rc_hydration_ttl, 2u32).
withdraw_cause_code(rc_supersede, 3u32).
withdraw_cause_code(rc_synthetic_discharged, 5u32).
withdraw_cause_code(rc_author_withdrawn, 6u32).
withdraw_cause_code(rc_activation_completed, 7u32).

encode_event(Meta, Env, Clock, Seq, Event, Bytes) :-
    (
        Event = se_fact_assert(FactId, SchemaId, Values, MaybeTtl),
        find_schema(Env, SchemaId, Schema),
        encode_fact_body(Env, Schema, Values, FactBytes),
        put_uint64(1u32, fact_id_value(FactId), init_builder, B1),
        expand(Env ^ rc_interns, schema_name_ref(Schema ^ s_name), NameText),
        put_string(2u32, NameText, B1, B2),
        % An empty fact body is omitted, like every proto3 default.
        ( if FactBytes = [] then
            B3 = B2
        else
            put_delimited(3u32, FactBytes, B2, B3)
        ),
        (
            MaybeTtl = yes(Ttl),
            put_uint64(4u32, duration_ns(Ttl), B3, B4)
        ;
            MaybeTtl = no,
            B4 = B3
        ),
        % Field 5, `rule_name`, is not written on a FactAssert.
        put_uint64(6u32, instant_ns(Clock), B4, B5),
        put_uint64(7u32, seq_value(Seq), B5, B6),
        % [LFST.5.6].
        put_string(8u32, lfst_5_6_event_id(Meta ^ sm_session, Meta ^ sm_tier,
            seq_value(Seq)), B6, Body),
        frame(at_fact_assert, builder_bytes(Body), Bytes)
    ;
        % `FactRetract`: `fact_id` = 1, `seq` = 2, `clock_ns` = 3 (RFCS.7.5).
        Event = se_fact_retract(FactId),
        put_uint64(1u32, fact_id_value(FactId), init_builder, R1),
        put_uint64(2u32, seq_value(Seq), R1, R2),
        put_uint64(3u32, instant_ns(Clock), R2, Body),
        frame(at_fact_retract, builder_bytes(Body), Bytes)
    ;
        Event = se_fact_withdraw(FactId, Cause),
        withdraw_cause_code(Cause, Code),
        put_uint64(1u32, fact_id_value(FactId), init_builder, W1),
        put_uint32(2u32, Code, W1, W2),
        put_uint64(3u32, instant_ns(Clock), W2, W3),
        put_uint64(4u32, seq_value(Seq), W3, Body),
        frame(at_fact_withdraw, builder_bytes(Body), Bytes)
    ;
        % A decoded withdrawal whose cause the enum does not name ([RFCS.7a.2]).
        Event = se_fact_withdraw_unnamed(FactId, Code),
        put_uint64(1u32, fact_id_value(FactId), init_builder, U1),
        put_uint32(2u32, Code, U1, U2),
        put_uint64(3u32, instant_ns(Clock), U2, U3),
        put_uint64(4u32, seq_value(Seq), U3, Body),
        frame(at_fact_withdraw, builder_bytes(Body), Bytes)
    ;
        % `ClockAdvance` is the tick. `se_clock_advance` is never emitted here.
        Event = se_clock_tick(To, Wall),
        put_uint64(1u32, seq_value(Seq), init_builder, B1),
        put_uint64(2u32, instant_ns(To), B1, B2),
        % `wall_ns` = 3 ([RFCS.10.3]) and `has_wall` = 4 ([RFCS.10.1]).
        (
            Wall = yes(W),
            put_int64(3u32, W, B2, B3),
            put_bool(4u32, yes, B3, Body)
        ;
            Wall = no,
            Body = B2
        ),
        frame(at_clock_advance, builder_bytes(Body), Bytes)
    ;
        % `PumpBoundary` ([RFCS.22]): `seq` = 1, `clock_ns` = 2.
        Event = se_pump_boundary,
        put_uint64(1u32, seq_value(Seq), init_builder, P1),
        put_uint64(2u32, instant_ns(Clock), P1, Body),
        frame(at_pump_boundary, builder_bytes(Body), Bytes)
    ;
        Event = se_fire_begin(Fire),
        rfra(Env, Clock, Seq, Fire, no, Bytes)
    ;
        Event = se_fire_end(Fire),
        rfra(Env, Clock, Seq, Fire, yes, Bytes)
    ;
        Event = se_engine_error(Err, Site),
        % `RARC.5.8.9` orders the record first. The class picks the atom [RFCS.16.1].
        encode_fault(Env ^ rc_interns, Clock, Seq, Err, Site, Bytes)
    ;
        Event = se_call_issued(Fire, Service, Correlation, Args, Origin),
        expand(Env ^ rc_interns, Service, ServiceName),
        expand(Env ^ rc_interns, Fire ^ fi_rule, RuleName),
        put_string(2u32, ServiceName, init_builder, C1),
        ( if
            Correlation = correlated(Ref),
            expand(Env ^ rc_interns, Ref, CorrText),
            CorrText \= ""
        then
            put_string(3u32, CorrText, C1, C2)
        else
            C2 = C1
        ),
        put_uint64(5u32, instant_ns(Clock), C2, C4),
        put_uint64(6u32, seq_value(Seq), C4, C5),
        % `rule_name` = 7: not written for a hydration dispatch.
        (
            Origin = co_call_verb,
            put_string(7u32, RuleName, C5, C6)
        ;
            Origin = co_hydration,
            C6 = C5
        ),
        put_int64(8u32, int64.cast_from_uint64(timetag_value(Fire ^ fi_timetag)),
            C6, C7),
        % `args` = 9 (RFCS.15.2), sorted by name as the artefact has them.
        list.foldl(put_arg(9u32), Args, C7, Body),
        frame(at_call_issued, builder_bytes(Body), Bytes)
    ).

    % `RuleFireAnnotation`.
    %
:- pred rfra(rfcs_ctx::in, instant::in, seq::in, fire_id::in, bool::in,
             list(uint8)::out) is semidet.

rfra(Env, Clock, Seq, Fire, End, Bytes) :-
    expand(Env ^ rc_interns, Fire ^ fi_rule, RuleName),
    put_uint64(1u32, seq_value(Seq), init_builder, B1),
    put_uint64(2u32, instant_ns(Clock), B1, B2),
    put_string(3u32, RuleName, B2, B3),
    put_bool(5u32, End, B3, B4),
    put_int64(6u32, int64.cast_from_uint64(timetag_value(Fire ^ fi_timetag)),
        B4, Body),
    frame(at_rule_fire_annotation, builder_bytes(Body), Bytes).

%-----------------------------------------------------------------------------%

    % `TrapKind`. A refused slot value is DOMAIN. `fault_class/1` sends the last three
    % elsewhere; they are `TRAP_UNSPECIFIED` only to keep this total.
    %
:- func trap_kind(engine_error) = uint32.

trap_kind(ee_expr_fault(Fault)) = expr_trap_kind(Fault).
trap_kind(ee_slot_invalid(_, _)) = 2u32.
trap_kind(ee_contract_breach(_)) = 0u32.
trap_kind(ee_fire_budget_exceeded(_)) = 0u32.
trap_kind(ee_duplicate_order_key) = 0u32.

    % One fault, one atom, chosen by `ds.fault.fault_class/1`, the site written field
    % by field as each atom's proto names it. A field the site does not know is left
    % absent, and a BoundsError's `limit` and `observed` go together or not at all.
    %
:- pred encode_fault(intern_table::in, instant::in, seq::in, engine_error::in,
                     fault_site::in, list(uint8)::out) is det.

encode_fault(Interns, Clock, Seq, Err, Site, Bytes) :-
    Class = fault_class(Err),
    Rule = fault_rule_name(Interns, Site ^ fs_rule),
    Node = site_node(Site),
    Schema = site_text(Interns, Site ^ fs_schema),
    Slot = site_text(Interns, Site ^ fs_slot),
    (
        Class = fc_computation,
        put_uint32(1u32, trap_kind(Err), init_builder, E0),
        put_string(2u32, Rule, E0, E1),
        put_int64(3u32, site_timetag(Site), E1, E2),
        put_string(4u32, Schema, E2, E3),
        put_string(5u32, Slot, E3, E4),
        put_uint64(6u32, site_fact(Site), E4, E5),
        put_uint32(7u32, Node, E5, E6),
        put_bool(8u32, recoverable(Err), E6, E7),
        put_uint64(9u32, instant_ns(Clock), E7, E8),
        put_uint64(10u32, seq_value(Seq), E8, EBody),
        frame(at_computation_error, builder_bytes(EBody), Bytes)
    ;
        Class = fc_type,
        Actual = ( if Site ^ fs_actual = yes(A) then A else "" ),
        put_uint32(1u32, Node, init_builder, T1),
        put_string(2u32, Schema, T1, T2),
        put_string(3u32, Slot, T2, T3),
        put_string(4u32, Actual, T3, T4),
        put_uint64(5u32, instant_ns(Clock), T4, T5),
        put_uint64(6u32, seq_value(Seq), T5, T6),
        put_string(7u32, Rule, T6, TBody),
        frame(at_type_error, builder_bytes(TBody), Bytes)
    ;
        Class = fc_bounds,
        put_uint32(1u32, cap_number(Err), init_builder, B0),
        (
            Site ^ fs_bound = yes(fault_bound(Limit, Observed)),
            put_uint64(2u32, Limit, B0, B0a),
            put_uint64(3u32, Observed, B0a, B1)
        ;
            Site ^ fs_bound = no,
            B1 = B0
        ),
        put_uint64(6u32, instant_ns(Clock), B1, B2),
        put_uint64(7u32, seq_value(Seq), B2, BBody),
        frame(at_bounds_error, builder_bytes(BBody), Bytes)
    ;
        Class = fc_engine,
        put_uint32(1u32, engine_fault_number(Err), init_builder, G1),
        put_uint32(2u32, Node, G1, G2),
        put_uint64(3u32, instant_ns(Clock), G2, G3),
        put_uint64(4u32, seq_value(Seq), G3, G4),
        put_string(5u32, Rule, G4, GBody),
        frame(at_engine_error, builder_bytes(GBody), Bytes)
    ).

    % Each is the proto's default where the site does not know it.
    %
:- func site_node(fault_site) = uint32.

site_node(Site) =
    ( if Site ^ fs_node = yes(N) then node_id_value(N) else 0u32 ).

:- func site_fact(fault_site) = uint64.

site_fact(Site) =
    ( if Site ^ fs_fact = yes(F) then fact_id_value(F) else 0u64 ).

:- func site_timetag(fault_site) = int64.

site_timetag(Site) =
    ( if Site ^ fs_activation = yes(Fire) then
        int64.cast_from_uint64(timetag_value(Fire ^ fi_timetag))
    else
        0i64
    ).

:- func site_text(intern_table, maybe(intern_ref)) = string.

site_text(Interns, MaybeRef) =
    ( if MaybeRef = yes(Ref), expand(Interns, Ref, Text) then Text else "" ).

    % `CapName` (`proto/bounds_error.proto`). The zeros are unreachable: `fault_class`
    % sends those elsewhere.
    %
:- func cap_number(engine_error) = uint32.

cap_number(ee_contract_breach(Cap))        = cap_name_number(Cap).
cap_number(ee_fire_budget_exceeded(_))     = 3u32.  % CAP_MAX_FIRES_PER_PUMP
cap_number(ee_expr_fault(_))               = 0u32.
cap_number(ee_slot_invalid(_, _))          = 0u32.
cap_number(ee_duplicate_order_key)         = 0u32.

:- func cap_name_number(cap) = uint32.

cap_name_number(cap_wm_max)             = 1u32.
cap_name_number(cap_agenda)             = 2u32.
cap_name_number(cap_max_fires_per_pump) = 3u32.
cap_name_number(cap_token_pool)         = 4u32.
cap_name_number(cap_intern)             = 5u32.
cap_name_number(cap_intern_bytes)       = 6u32.
cap_name_number(cap_pump_wcet)          = 7u32.
cap_name_number(cap_cache)              = 8u32.
cap_name_number(cap_cache_bytes)        = 9u32.
% Per-instance, and the instance is not on the wire.
cap_name_number(cap_node(_))            = 10u32.
cap_name_number(cap_series)             = 11u32.
cap_name_number(cap_value_capacity)     = 12u32.

    % `EngineFault` (`proto/engine_fault.proto`).
    %
:- func engine_fault_number(engine_error) = uint32.

engine_fault_number(ee_expr_fault(Fault))       = expr_engine_fault(Fault).
engine_fault_number(ee_duplicate_order_key)     = 4u32.  % ENGINE_FAULT_ORDER_KEY
engine_fault_number(ee_contract_breach(_))      = 0u32.
engine_fault_number(ee_fire_budget_exceeded(_)) = 0u32.
engine_fault_number(ee_slot_invalid(_, _))      = 0u32.

    % Per occurrence, not per kind [LERR.1.4.9].
    %
:- func recoverable(engine_error) = bool.

recoverable(Err) =
    ( if disposition(Err) = latched then no else yes ).

    % The two-level frame: outer field 1, then the atom's `oneof` number.
    %
:- pred frame(atom_id::in, list(uint8)::in, list(uint8)::out) is det.

frame(Atom, Body, Bytes) :-
    put_delimited(atom_field(Atom), Body, init_builder, Inner),
    put_message(1u32, Inner, init_builder, Outer),
    Bytes = builder_bytes(Outer).


:- pred find_schema(rfcs_ctx::in, schema_id::in, schema::out) is semidet.

find_schema(Ctx, Id, Found) :-
    find_schema_in(Ctx ^ rc_schemas, Id, Found).

:- pred find_schema_in(list(schema)::in, schema_id::in, schema::out) is semidet.

find_schema_in([S | Rest], Id, Found) :-
    ( if S ^ s_id = Id then Found = S else find_schema_in(Rest, Id, Found) ).

%-----------------------------------------------------------------------------%

encode_fact_body(Ctx, Schema, Values, Bytes) :-
    body_slots(Schema ^ s_lifecycle, Shapes),
    encode_slots(Ctx, Shapes, Values, 1u32, init_builder, Body),
    Bytes = builder_bytes(Body).

    % A fact body's view of a slot: a nullable slot's field has presence ([RFCS.6.3]).
    %
:- type body_slot
    --->    body_slot(
                sh_kind     :: slot_kind,
                sh_nullable :: nullable
            ).

:- pred body_slots(lifecycle::in, list(body_slot)::out) is det.

body_slots(Lifecycle, list.map(shape_of, slot_commons_of(Lifecycle))).

:- func shape_of(slot_common) = body_slot.

shape_of(C) = body_slot(C ^ sc_kind, C ^ sc_nullable).

    % The field number is position + 1, as in the `.proto` the compiler generates.
    % Fails on a value whose kind does not match its slot.
    %
:- pred encode_slots(rfcs_ctx::in, list(body_slot)::in, list(ds_value)::in,
                     uint32::in, builder::in, builder::out) is semidet.

encode_slots(_, [], [], _, !B).
encode_slots(Ctx, [Shape | Shapes], [Value | Values], Num, !B) :-
    Shape = body_slot(Kind, Nullable),
    (
        Nullable = nullable,
        rfcs_6_3_encode_present(Ctx, Kind, Value, Num, !B)
    ;
        Nullable = non_null,
        encode_slot(Ctx, Kind, Value, Num, !B)
    ),
    encode_slots(Ctx, Shapes, Values, Num + 1u32, !B).

    % A nullable slot's field has presence: `null` is the absent field, and every
    % other value is written, zero included.
    %
    %@spec [RFCS.6.3]
:- pred rfcs_6_3_encode_present(rfcs_ctx::in, slot_kind::in, ds_value::in,
                                uint32::in, builder::in, builder::out)
    is semidet.

rfcs_6_3_encode_present(_, _, null, _, !B).
rfcs_6_3_encode_present(_, k_int, int(I), Num, !B) :-
    put_int64_always(Num, I, !B).
rfcs_6_3_encode_present(_, k_time, int(I), Num, !B) :-
    put_int64_always(Num, I, !B).
rfcs_6_3_encode_present(_, k_date, int(I), Num, !B) :-
    put_int64_always(Num, I, !B).
rfcs_6_3_encode_present(_, k_duration, int(I), Num, !B) :-
    put_int64_always(Num, I, !B).
rfcs_6_3_encode_present(_, k_float, float(F), Num, !B) :-
    put_double_always(Num, F, !B).
rfcs_6_3_encode_present(Ctx, k_string, str(Ref), Num, !B) :-
    expand(Ctx ^ rc_interns, Ref, Text),
    put_string_always(Num, Text, !B).
rfcs_6_3_encode_present(_, k_bool, bool(Bool), Num, !B) :-
    put_bool_always(Num, Bool, !B).
rfcs_6_3_encode_present(_, k_bytes, bytes(BM), Num, !B) :-
    put_delimited(Num, bitmap_octets(BM), !B).
rfcs_6_3_encode_present(_, k_schema(_), fact_ref(Id), Num, !B) :-
    put_uint64_always(Num, fact_id_value(Id), !B).
rfcs_6_3_encode_present(_, k_json, json(J), Num, !B) :-
    rfcs_6_3_json_field(J, Num, !B).

    % A non-nullable slot: a zero is omitted, and `null` has no encoding, so it fails.
    % A fact reference is its target's handle, the `fact_id` the target's own atom was
    % written under (RFCS.6.3); a target id is never 0.
    %
:- pred encode_slot(rfcs_ctx::in, slot_kind::in, ds_value::in, uint32::in,
                    builder::in, builder::out) is semidet.

encode_slot(_, k_int, int(I), Num, !B) :-
    put_int64(Num, I, !B).
encode_slot(_, k_time, int(I), Num, !B) :-
    put_int64(Num, I, !B).
encode_slot(_, k_date, int(I), Num, !B) :-
    put_int64(Num, I, !B).
encode_slot(_, k_duration, int(I), Num, !B) :-
    put_int64(Num, I, !B).
encode_slot(_, k_float, float(F), Num, !B) :-
    put_double(Num, F, !B).
encode_slot(Ctx, k_string, str(Ref), Num, !B) :-
    expand(Ctx ^ rc_interns, Ref, Text),
    put_string(Num, Text, !B).
encode_slot(_, k_bool, bool(Bool), Num, !B) :-
    put_bool(Num, Bool, !B).
encode_slot(_, k_bytes, bytes(BM), Num, !B) :-
    Octets = bitmap_octets(BM),
    (
        Octets = []
    ;
        Octets = [_ | _],
        put_delimited(Num, Octets, !B)
    ).
encode_slot(_, k_schema(_), fact_ref(Id), Num, !B) :-
    put_uint64(Num, fact_id_value(Id), !B).
encode_slot(_, k_json, json(J), Num, !B) :-
    rfcs_6_3_json_field(J, Num, !B).

    % A `Json` value is its canonical text in a `string` field (RFCS.23.2,
    % [LDET.3.2.7]), never empty. A non-finite Float has no text and fails.
    %
    %@spec [RFCS.6.3]
:- pred rfcs_6_3_json_field(json_term::in, uint32::in, builder::in,
                            builder::out) is semidet.

rfcs_6_3_json_field(J, Num, !B) :-
    json_text(J, Text),
    put_string_always(Num, Text, !B).

:- func bitmap_octets(bitmap) = list(uint8).

bitmap_octets(BM) = octets_from(BM, bitmap.det_num_bytes(BM) - 1, []).

:- func octets_from(bitmap, int, list(uint8)) = list(uint8).

octets_from(BM, I, Acc) =
    ( if I < 0 then
        Acc
    else
        octets_from(BM, I - 1, [uint8.cast_from_int(bitmap.byte(I, BM)) | Acc])
    ).

:- func octets_bitmap(list(uint8)) = bitmap.

octets_bitmap(Octets) = BM :-
    fill_octets(0, Octets, bitmap.init(list.length(Octets) * 8), BM).

:- pred fill_octets(int::in, list(uint8)::in,
                    bitmap::bitmap_di, bitmap::bitmap_uo) is det.

fill_octets(_, [], !BM).
fill_octets(I, [O | Os], !BM) :-
    bitmap.set_uint8(I, O, !BM),
    fill_octets(I + 1, Os, !BM).

%-----------------------------------------------------------------------------%
% Reading
%-----------------------------------------------------------------------------%

    % What the walk accumulates. `rd_slots` is keyed by schema name, which is what a
    % recording carries.
:- type read_acc
    --->    read_acc(
                rd_meta   :: stream_meta,
                rd_slots  :: assoc_list(string, list(body_slot)),
                rd_events :: list({seq, stream_event}),     % reversed
                rd_emitted :: set(uint64),                  % see `dsm_emitted`
                rd_interns :: intern_table,
                rd_first_seq :: maybe(uint64),              % see `dsm_first_seq`
                rd_external :: list(recorded_external),     % reversed
                rd_recorded :: set(uint64),
                    % The handles a fact-ref slot may name (RFCS.6.3, RFCS.24.3).
                    % A body naming any other is refused (`read_fcem`).
                rd_n_events :: int,                         % in `rd_events`
                rd_n_external :: int,                       % in `rd_external`
                rd_compare :: list(recorded_compare),       % reversed
                rd_seeds :: list(recorded_seed)             % reversed
            ).

decode_stream(BM, IT0, Result) :-
    rfcs_19_2_decode(no, BM, IT0, Result, _).

decode_stream_prefix(BM, IT0, Result, TailBytes) :-
    rfcs_19_2_decode(yes, BM, IT0, Result, TailBytes).

    % `Incremental` decides only what a partial trailing atom is.
    %
    %@spec [RFCS.19.2]
:- pred rfcs_19_2_decode(bool::in, bitmap::in, intern_table::in,
                         decode_result::out, int::out) is det.

rfcs_19_2_decode(Incremental, BM, IT0, Result, TailBytes) :-
    Acc0 = read_acc(stream_meta("", [], [], [], "", ""), [], [], set.init, IT0, no,
        [], set.init, 0, 0, [], []),
    read_frames(Incremental, init_reader(BM), Acc0, Result0),
    (
        Result0 = ra_error(Clause, Offset),
        Result = decode_failed(Clause, Offset),
        TailBytes = 0
    ;
        Result0 = ra_ok(Acc, TailBytes),
        ( if not version_accepted(Acc ^ rd_meta) then
            % A reader accepts its own `<major>.<minor>.` series.
            Result = decode_failed("LDET.1.10", 0)
        else
            Result = decoded(stream_of(Acc))
        )
    ;
        Result0 = ra_unannounced(Acc, Seq, Offset),
        TailBytes = 0,
        % The version comes first: the header opens the stream.
        ( if not version_accepted(Acc ^ rd_meta) then
            Result = decode_failed("LDET.1.10", 0)
        else
            Result = unannounced_schema(stream_of(Acc), Seq, Offset)
        )
    ).

:- func stream_of(read_acc) = decoded_stream.

stream_of(Acc) =
    decoded_stream(Acc ^ rd_meta,
        list.reverse(Acc ^ rd_events), Acc ^ rd_interns,
        Acc ^ rd_emitted,
        list.map((func(N - _) = N), Acc ^ rd_slots),
        Acc ^ rd_first_seq, list.reverse(Acc ^ rd_external),
        list.reverse(Acc ^ rd_compare), list.reverse(Acc ^ rd_seeds)).

:- type read_step
    --->    ra_ok(read_acc, int)        % the length of a partial tail, or 0
    ;       ra_error(string, int)
    ;       ra_unannounced(read_acc, uint64, int).
            % `unannounced_schema`'s.

:- pred read_frames(bool::in, reader::in, read_acc::in, read_step::out) is det.

read_frames(Incremental, R0, Acc0, Result) :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Result = ra_ok(Acc0, 0)
    ;
        FrameResult = fr_error(_, Offset),
        ( if
            Incremental = yes,
            outer_frame_partial(R0)
        then
            Result = ra_ok(Acc0, remaining(R0))
        else
            Result = ra_error("RFCS.19.2", Offset)
        )
    ;
        FrameResult = fr_ok(F),
        ( if
            F ^ fr_atom = unknown(Field),
            disposition_of_unknown(Field) = D,
            D \= disp_skip
        then
            % An unknown number's band decides, and only the skip band skips
            % [RFCS.16.3], [RFCS.16.2], [RFCS.18.8].
            Result = ra_error(unknown_atom_clause(D), F ^ fr_offset)
        else if
            F ^ fr_atom = known(at_fact_assert),
            rfcs_5_4_unannounced(F ^ fr_body, Acc0, Seq)
        then
            % [RFCS.5.3], [RFCS.5.4]: asked before the body is decoded, which needs
            % the descriptor. Its `seq` is noted first ([LTIM.2.8.5]).
            note_first_seq(at_fact_assert, F ^ fr_body, Acc0, AccSeq),
            Result = ra_unannounced(AccSeq, Seq, F ^ fr_offset)
        else if read_atom(F, Acc0, Acc1) then
            ( if
                F ^ fr_atom = known(at_stream_header),
                not capabilities_well_formed(Acc1 ^ rd_meta ^ sm_capabilities)
            then
                % [RBND.1.3]: refused where it is read, before the version gate.
                Result = ra_error("RBND.1.3", F ^ fr_offset)
            else
                read_frames(Incremental, R1, Acc1, Result)
            )
        else
            % A body that does not decode.
            Result = ra_error("RFCS.19.3", F ^ fr_offset)
        )
    ).

    % The frame at the reader's position runs past the end of the buffer, which more
    % bytes can complete ([RFCS.19.2]). Only the one-byte tag 0x0A opens a frame
    % ([RDSC.11.1], [RFCS.19.1]). A complete frame whose body is short of its own
    % contents is malformed, so the outer prefix is re-read here.
    %
    %@helper
:- pred outer_frame_partial(reader::in) is semidet.

outer_frame_partial(R0) :-
    peek_byte(R0, 0x0Au8),
    read_tag(TagResult, R0, R1),
    TagResult = ok({1u32, wt_len}),
    read_delimited(BodyResult, R1, _),
    BodyResult = error(we_truncated).

:- func unknown_atom_clause(disposition) = string.

unknown_atom_clause(disp_reject_inject) = "RFCS.18.8".
unknown_atom_clause(disp_reject_version) = "RFCS.16.2".
unknown_atom_clause(disp_malformed) = "RFCS.16.3".
unknown_atom_clause(disp_skip) = "RFCS.16.3".

:- pred read_atom(frame::in, read_acc::in, read_acc::out) is semidet.

read_atom(F, !Acc) :-
    Ref = F ^ fr_atom,
    (
        Ref = unknown(_),
        % Only a skip-band number reaches here [RFCS.16.2].
        true
    ;
        Ref = known(Atom),
        note_first_seq(Atom, F ^ fr_body, !Acc),
        Before = !.Acc,
        read_known(Atom, F ^ fr_body, !Acc),
        note_compare(Atom, F ^ fr_body, Before, !Acc)
    ).

    % [LFST.9.3.1]: a compare-class atom kept as written, with the counts of what was
    % read before it (`Before`), so a FactEmit or FactWithdraw is compared before its
    % own event is reached.
    %
:- pred note_compare(atom_id::in, reader::in, read_acc::in,
                     read_acc::in, read_acc::out) is det.

note_compare(Atom, Body, Before, !Acc) :-
    ( if lfst_9_3_1_compared(Atom, Body) then
        ( if
            event_seq_field(Atom, Field),
            fold_fields(Body, seq_field(Field), 0u64, ff_ok(S))
        then
            Seq = S
        else
            Seq = 0u64
        ),
        !Acc ^ rd_compare := [recorded_compare(Before ^ rd_n_events,
            Before ^ rd_n_external, Seq,
            compare_atom(Atom, reader_bytes(Body))) | !.Acc ^ rd_compare]
    else
        true
    ).

    % [LTIM.2.8.5], [LFST.5.3]: the first event atom's `seq`, read off its body, since
    % some atoms decode to no event.
    %
:- pred note_first_seq(atom_id::in, reader::in, read_acc::in, read_acc::out)
    is det.

note_first_seq(Atom, Body, !Acc) :-
    First = !.Acc ^ rd_first_seq,
    ( if
        First = no,
        event_seq_field(Atom, Field),
        fold_fields(Body, seq_field(Field), 0u64, ff_ok(Seq))
    then
        !Acc ^ rd_first_seq := yes(Seq)
    else
        true
    ).

    % The field number of `seq` in an event atom's body, from its proto.
    %
:- pred event_seq_field(atom_id::in, uint32::out) is semidet.

event_seq_field(at_fact_assert, 7u32).
event_seq_field(at_fact_emit, 7u32).
event_seq_field(at_fact_publish, 4u32).
event_seq_field(at_fact_retract, 2u32).
event_seq_field(at_clock_advance, 1u32).
event_seq_field(at_pump_boundary, 1u32).
event_seq_field(at_rule_fire_annotation, 1u32).
event_seq_field(at_call_issued, 6u32).
event_seq_field(at_fact_withdraw, 4u32).
event_seq_field(at_computation_error, 10u32).
event_seq_field(at_type_error, 6u32).
event_seq_field(at_bounds_error, 7u32).
event_seq_field(at_engine_error, 4u32).
event_seq_field(at_external_assert, 5u32).

:- pred seq_field(uint32::in, uint32::in, field_value::in,
                  uint64::in, uint64::out) is semidet.

seq_field(Field, Num, Value, S0, S) :-
    ( if Num = Field, Value = fv_varint(V) then
        S = V
    else
        S = S0
    ).

:- pred read_known(atom_id::in, reader::in, read_acc::in, read_acc::out)
    is semidet.

read_known(Atom, Body, !Acc) :-
    ( if Atom = at_stream_header then
        fold_fields(Body, fcst_field, !.Acc ^ rd_meta, ff_ok(Meta)),
        !Acc ^ rd_meta := Meta
    else if Atom = at_schema_def then
        % The name alone: the Slot atoms give a body's fields.
        fold_fields(Body, name_field, "", ff_ok(Name)),
        Name \= "",
        ( if assoc_list.search(!.Acc ^ rd_slots, Name, _) then
            true
        else
            !Acc ^ rd_slots := !.Acc ^ rd_slots ++ [Name - []]
        )
    else if Atom = at_slot then
        fold_fields(Body, slot_field, {"", "", 0u32, non_null, ""},
            ff_ok({SName, _, Kind, Nullable, RefSchema})),
        SName \= "",
        ( if Kind = 6u32 then
            % SLOT_KIND_SCHEMA: its body field is the target's handle (RFCS.6.3).
            RefSchema \= "",
            intern(RefSchema, RefSchemaRef, !.Acc ^ rd_interns, RefIT),
            !Acc ^ rd_interns := RefIT,
            SlotKind = k_schema(make_schema_name(RefSchemaRef))
        else
            kind_of_code(Kind, SlotKind)
        ),
        !Acc ^ rd_slots := add_slot(!.Acc ^ rd_slots, SName,
            body_slot(SlotKind, Nullable))
    else if Atom = at_fact_retract then
        % `fact_id` = 1 and `seq` = 2 (RFCS.7.5); the ClockAdvance before it set the
        % clock.
        fold_fields(Body, fcrt_field, {0u64, 0u64}, ff_ok({Id, Seq})),
        add_event(make_seq(Seq), se_fact_retract(make_fact_id(Id)), !Acc)
    else if Atom = at_clock_advance then
        fold_fields(Body, clka_field, {0u64, 0u64, 0i64, no},
            ff_ok({Seq, Ns, W, HasWall})),
        add_event(make_seq(Seq), se_clock_tick(from_ns(Ns), clka_wall(W, HasWall)),
            !Acc)
    else if Atom = at_fact_assert then
        read_fcem(Body, _, !Acc)
    else if Atom = at_pump_boundary then
        % [RFCS.22]: `seq` = 1 and `clock_ns` = 2, ClockAdvance's first two fields.
        fold_fields(Body, clka_field, {0u64, 0u64, 0i64, no},
            ff_ok({Seq, _, _, _})),
        add_event(make_seq(Seq), se_pump_boundary, !Acc)
    else if Atom = at_fact_emit then
        % `FactEmit` shares `FactAssert`'s field numbers; `dsm_emitted` keeps it out
        % of a replay's inputs ([RFCS.6a.1]).
        read_fcem(Body, Seq, !Acc),
        !Acc ^ rd_emitted := set.insert(!.Acc ^ rd_emitted, Seq)
    else if Atom = at_fact_withdraw then
        fold_fields(Body, fwth_field, {0u64, 0u32, 0u64},
            ff_ok({Id, Code, Seq})),
        % [RFCS.7a.2]: a cause the enum does not hold is carried, not refused.
        ( if cause_of_code(Code, Cause) then
            Withdrawn = se_fact_withdraw(make_fact_id(Id), Cause)
        else
            Withdrawn = se_fact_withdraw_unnamed(make_fact_id(Id), Code)
        ),
        add_event(make_seq(Seq), Withdrawn, !Acc)
    else if Atom = at_external_assert then
        % RFCS.24, kept for a replayer to deliver. A record with no `fact` is
        % malformed.
        fold_fields(Body, fcxt_field, {no, [], 0u64, 0u64, 0u64},
            ff_ok({yes(Fact), RevIds, Ttl, Clock, Seq})),
        !Acc ^ rd_external := [recorded_external(
            !.Acc ^ rd_n_events, make_seq(Seq), Fact,
            list.reverse(RevIds), Ttl, Clock) | !.Acc ^ rd_external],
        !Acc ^ rd_n_external := !.Acc ^ rd_n_external + 1,
        % RFCS.24.3: a later body may name a listed handle (RFCS.6.3).
        !Acc ^ rd_recorded := set.insert_list(!.Acc ^ rd_recorded, RevIds)
    else if Atom = at_cache_seed then
        % [RFCS.26]: kept for a replayer, which refuses one after an event atom
        % ([RFCS.26.2]).
        fold_fields(Body, cache_seed_field, {"", "", 0u64},
            ff_ok({Key, Value, Deadline})),
        Late = ( if !.Acc ^ rd_first_seq = yes(_) then yes else no ),
        ( if !.Acc ^ rd_events = [{LastSeq, _} | _] then
            Seq = seq_value(LastSeq)
        else
            Seq = 0u64
        ),
        !Acc ^ rd_seeds := [recorded_seed(Late, !.Acc ^ rd_n_events,
            !.Acc ^ rd_n_external, Seq, cache_seed(Key, Value, Deadline))
            | !.Acc ^ rd_seeds]
    else if Atom = at_rule_fire_annotation then
        % No event: a `fire_id`'s intern half is table-local. The body is read so a
        % malformed one refuses the stream ([RFCS.19.3]).
        fold_fields(Body, rfra_field, {0u64, no}, ff_ok(_))
    else if Atom = at_fact_publish then
        % NOT an event and never delivered: a rule's `publish` is compare
        % class ([RFCS.27.2]), re-derived by the replay's own firing and kept
        % as written for it to compare (`note_compare`). The body is still
        % read, so a malformed one refuses the stream ([RFCS.19.3]).
        fold_fields(Body, seq_field(4u32), 0u64, ff_ok(_))
    else
        % `CallIssued`, likewise no event.
        true
    ).

:- pred rfra_field(uint32::in, field_value::in,
                   {uint64, bool}::in, {uint64, bool}::out) is semidet.

rfra_field(Num, Value, {S0, E0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_varint(S), Acc = {S, E0}
    else if Num = 5u32 then
        Value = fv_varint(E), Acc = {S0, ( if E = 0u64 then no else yes )}
    else
        Acc = {S0, E0}
    ).

    % A `FactAssert` or `FactEmit` body, and its `seq`.
    %
:- pred read_fcem(reader::in, uint64::out, read_acc::in, read_acc::out)
    is semidet.

read_fcem(Body, Seq, !Acc) :-
    fold_fields(Body, fcem_field, {0u64, "", no, 0u64, 0u64},
        ff_ok({Id, Name, MaybeBody, Ttl, Seq})),
    Name \= "",
    assoc_list.search(!.Acc ^ rd_slots, Name, Shapes),
    (
        MaybeBody = yes(FactReader),
        decode_fact_body(Shapes, FactReader, Values, !.Acc ^ rd_interns, IT)
    ;
        % An absent `fact` is a fact of all absent fields, not of no slots.
        MaybeBody = no,
        rebuild(Shapes, [], 1u32, Values, !.Acc ^ rd_interns, IT)
    ),
    !Acc ^ rd_interns := IT,
    % RFCS.6.3: a reference no earlier record gave refuses the body (RFCS.19.3).
    refs_recorded(!.Acc ^ rd_recorded, Values),
    !Acc ^ rd_recorded := set.insert(!.Acc ^ rd_recorded, Id),
    intern(Name, NameRef, !.Acc ^ rd_interns, IT2),
    !Acc ^ rd_interns := IT2,
    % The schema id is synthesised from position, local to this stream.
    Position = schema_position(!.Acc ^ rd_slots, Name),
    ( if Ttl = 0u64 then Deadline = no else Deadline = yes(duration_from_ns(Ttl)) ),
    add_event(make_seq(Seq),
        se_fact_assert(make_fact_id(Id), make_schema_id(Position), Values,
            Deadline), !Acc),
    _ = NameRef.

    % A well-formed `FactAssert` body whose `schema_name` no `SchemaDef` read so far has
    % announced ([RFCS.5.3]), and its `seq`. The pool is the stream's own, never the
    % program's. Any other body fails here and `read_atom` judges it.
    %
    %@spec [RFCS.5.4]
:- pred rfcs_5_4_unannounced(reader::in, read_acc::in, uint64::out)
    is semidet.

rfcs_5_4_unannounced(Body, Acc, Seq) :-
    fold_fields(Body, fcem_field, {0u64, "", no, 0u64, 0u64},
        ff_ok({_, Name, _, _, Seq})),
    Name \= "",
    not assoc_list.search(Acc ^ rd_slots, Name, _).

:- pred refs_recorded(set(uint64)::in, list(ds_value)::in) is semidet.

refs_recorded(_, []).
refs_recorded(Recorded, [V | Vs]) :-
    ( if V = fact_ref(Ref) then
        set.member(fact_id_value(Ref), Recorded)
    else
        true
    ),
    refs_recorded(Recorded, Vs).

:- pred add_event(seq::in, stream_event::in, read_acc::in, read_acc::out)
    is det.

add_event(Seq, Event, !Acc) :-
    !Acc ^ rd_events := [{Seq, Event} | !.Acc ^ rd_events],
    !Acc ^ rd_n_events := !.Acc ^ rd_n_events + 1.

:- func add_slot(assoc_list(string, list(body_slot)), string, body_slot)
    = assoc_list(string, list(body_slot)).

add_slot([], Name, Kind) = [Name - [Kind]].
add_slot([N - Ks | Rest], Name, Kind) =
    ( if N = Name then
        % Arrival order is the field numbering [RFCS.5.1].
        [N - (Ks ++ [Kind]) | Rest]
    else
        [N - Ks | add_slot(Rest, Name, Kind)]
    ).

:- func schema_position(assoc_list(string, list(body_slot)), string) = uint32.

schema_position(Slots, Name) = position_loop(Slots, Name, 1u32).

:- func position_loop(assoc_list(string, list(body_slot)), string, uint32)
    = uint32.

position_loop([], _, N) = N.
position_loop([S - _ | Rest], Name, N) =
    ( if S = Name then N else position_loop(Rest, Name, N + 1u32) ).

%-----------------------------------------------------------------------------%

:- pred fcst_field(uint32::in, field_value::in,
                   stream_meta::in, stream_meta::out) is semidet.

fcst_field(Num, Value, !M) :-
    ( if Num = 10u32 then
        Value = fv_bytes(S), reader_string(S, T), !M ^ sm_ds_version := T
    else if Num = 4u32 then
        Value = fv_bytes(S), !M ^ sm_dsc_hash := reader_bytes(S)
    else if Num = 5u32 then
        Value = fv_bytes(S), reader_string(S, T), !M ^ sm_session := T
    else if Num = 6u32 then
        Value = fv_bytes(S), reader_string(S, T), !M ^ sm_tier := T
    else if Num = 9u32 then
        % Kept at the length written ([RBND.2.1]).
        Value = fv_bytes(S), !M ^ sm_def_sha := reader_bytes(S)
    else if Num = 16u32 then
        % Packed or unpacked: the order is part of the tuple ([RBND.1.3]).
        !M ^ sm_capabilities := !.M ^ sm_capabilities ++ enum_values(Value)
    else
        true
    ).

:- pred version_accepted(stream_meta::in) is semidet.

version_accepted(Meta) :-
    Meta ^ sm_ds_version \= "",
    string.prefix(Meta ^ sm_ds_version, version_series(ds.version.ds_version)).

    % `<major>.<minor>.`, or the whole string when there are fewer than two dots.
    %
:- func version_series(string) = string.

version_series(V) = Series :-
    ( if
        string.sub_string_search(V, ".", I1),
        string.sub_string_search_start(V, ".", I1 + 1, I2)
    then
        Series = string.left(V, I2 + 1)
    else
        Series = V
    ).

:- pred fwth_field(uint32::in, field_value::in,
                   {uint64, uint32, uint64}::in, {uint64, uint32, uint64}::out)
    is semidet.

fwth_field(Num, Value, {I0, C0, S0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_varint(I), Acc = {I, C0, S0}
    else if Num = 2u32 then
        Value = fv_varint(C), Acc = {I0, uint32.cast_from_uint64(C), S0}
    else if Num = 4u32 then
        Value = fv_varint(S), Acc = {I0, C0, S}
    else
        Acc = {I0, C0, S0}
    ).

    % The inverse of `withdraw_cause_code`: the wire does not tell a hydration retain
    % from a schema TTL. A cause the enum does not hold fails, and the FactWithdraw arm
    % carries the number.
    %
:- pred cause_of_code(uint32::in, retract_cause::out) is semidet.

cause_of_code(1u32, rc_justifier_end).
cause_of_code(2u32, rc_ttl).
cause_of_code(3u32, rc_supersede).
cause_of_code(5u32, rc_synthetic_discharged).
cause_of_code(6u32, rc_author_withdrawn).
cause_of_code(7u32, rc_activation_completed).

:- pred name_field(uint32::in, field_value::in, string::in, string::out)
    is semidet.

name_field(Num, Value, S0, S) :-
    ( if Num = 1u32 then
        Value = fv_bytes(R), reader_string(R, S)
    else
        S = S0
    ).

    % `Slot`: schema = 1, name = 2, kind = 3, schema_ref = 4, nullable = 11.
    %
:- pred slot_field(uint32::in, field_value::in,
                   {string, string, uint32, nullable, string}::in,
                   {string, string, uint32, nullable, string}::out) is semidet.

slot_field(Num, Value, {S0, N0, K0, L0, F0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(R), reader_string(R, S), Acc = {S, N0, K0, L0, F0}
    else if Num = 2u32 then
        Value = fv_bytes(R), reader_string(R, N), Acc = {S0, N, K0, L0, F0}
    else if Num = 3u32 then
        Value = fv_varint(V), Acc = {S0, N0, uint32.cast_from_uint64(V), L0, F0}
    else if Num = 4u32 then
        Value = fv_bytes(R), reader_string(R, F), Acc = {S0, N0, K0, L0, F}
    else if Num = 11u32 then
        Value = fv_varint(V),
        Acc = {S0, N0, K0, ( if V = 0u64 then non_null else nullable ), F0}
    else
        Acc = {S0, N0, K0, L0, F0}
    ).

    % `ExternalAssert`: `fact` = 1, `fact_ids` = 2 (packed, or one varint per field),
    % `ttl_ns` = 3, `clock_ns` = 4, `seq` = 5. The ids accumulate newest first.
    %
:- pred fcxt_field(uint32::in, field_value::in,
    {maybe(list(uint8)), list(uint64), uint64, uint64, uint64}::in,
    {maybe(list(uint8)), list(uint64), uint64, uint64, uint64}::out)
    is semidet.

fcxt_field(Num, Value, {F0, I0, T0, C0, S0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(R), Acc = {yes(reader_bytes(R)), I0, T0, C0, S0}
    else if Num = 2u32 then
        (
            Value = fv_varint(V),
            Acc = {F0, [V | I0], T0, C0, S0}
        ;
            Value = fv_bytes(R),
            read_packed_varints(R, ok(Vs)),
            Acc = {F0, list.reverse(Vs) ++ I0, T0, C0, S0}
        )
    else if Num = 3u32 then
        Value = fv_varint(T), Acc = {F0, I0, T, C0, S0}
    else if Num = 4u32 then
        Value = fv_varint(C), Acc = {F0, I0, T0, C, S0}
    else if Num = 5u32 then
        Value = fv_varint(S), Acc = {F0, I0, T0, C0, S}
    else
        Acc = {F0, I0, T0, C0, S0}
    ).

:- pred cache_seed_field(uint32::in, field_value::in,
                         {string, string, uint64}::in,
                         {string, string, uint64}::out) is semidet.

cache_seed_field(Num, Value, {K0, V0, D0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(R), reader_string(R, K), Acc = {K, V0, D0}
    else if Num = 2u32 then
        Value = fv_bytes(R), reader_string(R, V), Acc = {K0, V, D0}
    else if Num = 3u32 then
        Value = fv_varint(D), Acc = {K0, V0, D}
    else
        Acc = {K0, V0, D0}
    ).

:- pred fcrt_field(uint32::in, field_value::in,
                   {uint64, uint64}::in, {uint64, uint64}::out) is semidet.

fcrt_field(Num, Value, {I0, S0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_varint(I), Acc = {I, S0}
    else if Num = 2u32 then
        Value = fv_varint(S), Acc = {I0, S}
    else
        Acc = {I0, S0}
    ).

    % `ClockAdvance`: `seq` = 1, `clock_ns` = 2, `wall_ns` = 3, `has_wall` = 4. The wall
    % value is `no` exactly when `has_wall` is false ([RFCS.10.1]).
    %
:- pred clka_field(uint32::in, field_value::in,
                   {uint64, uint64, int64, bool}::in,
                   {uint64, uint64, int64, bool}::out) is semidet.

clka_field(Num, Value, {S0, N0, W0, H0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_varint(S), Acc = {S, N0, W0, H0}
    else if Num = 2u32 then
        Value = fv_varint(N), Acc = {S0, N, W0, H0}
    else if Num = 3u32 then
        Value = fv_varint(W), Acc = {S0, N0, int64.cast_from_uint64(W), H0}
    else if Num = 4u32 then
        Value = fv_varint(H), Acc = {S0, N0, W0, ( if H = 0u64 then no else yes )}
    else
        Acc = {S0, N0, W0, H0}
    ).

:- func clka_wall(int64, bool) = maybe(int64).

clka_wall(_, no) = no.
clka_wall(W, yes) = yes(W).

:- pred fcem_field(uint32::in, field_value::in,
                   {uint64, string, maybe(reader), uint64, uint64}::in,
                   {uint64, string, maybe(reader), uint64, uint64}::out)
    is semidet.

fcem_field(Num, Value, {Id0, N0, B0, T0, S0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), Acc = {V, N0, B0, T0, S0}
    else if Num = 2u32 then
        Value = fv_bytes(R), reader_string(R, N), Acc = {Id0, N, B0, T0, S0}
    else if Num = 3u32 then
        Value = fv_bytes(R), Acc = {Id0, N0, yes(R), T0, S0}
    else if Num = 4u32 then
        Value = fv_varint(T), Acc = {Id0, N0, B0, T, S0}
    else if Num = 7u32 then
        Value = fv_varint(S), Acc = {Id0, N0, B0, T0, S}
    else
        Acc = {Id0, N0, B0, T0, S0}
    ).

:- pred kind_of_code(uint32::in, slot_kind::out) is semidet.

kind_of_code(1u32, k_int).
kind_of_code(2u32, k_float).
kind_of_code(3u32, k_string).
kind_of_code(4u32, k_bool).
kind_of_code(5u32, k_json).
kind_of_code(7u32, k_bytes).
kind_of_code(8u32, k_time).
kind_of_code(9u32, k_date).
kind_of_code(10u32, k_duration).

%-----------------------------------------------------------------------------%

    % An absent field means `null` in a nullable slot ([RFCS.6.3]), and elsewhere the
    % type's zero, but for the two kinds with no zero (`rebuild`).
    %
:- pred decode_fact_body(list(body_slot)::in, reader::in, list(ds_value)::out,
                         intern_table::in, intern_table::out) is semidet.

decode_fact_body(Shapes, R, Values, !IT) :-
    fold_fields(R, collect_slot, [], ff_ok(RevFields)),
    Fields = list.reverse(RevFields),
    rebuild(Shapes, Fields, 1u32, Values, !IT).

:- pred collect_slot(uint32::in, field_value::in,
                     assoc_list(uint32, field_value)::in,
                     assoc_list(uint32, field_value)::out) is semidet.

collect_slot(Num, Value, Acc, [Num - Value | Acc]) :-
    semidet_true.

:- pred rebuild(list(body_slot)::in, assoc_list(uint32, field_value)::in,
                uint32::in, list(ds_value)::out,
                intern_table::in, intern_table::out) is semidet.

rebuild([], _, _, [], !IT).
rebuild([body_slot(Kind, Nullable) | Shapes], Fields, Num, [Value | Values],
        !IT) :-
    ( if assoc_list.search(Fields, Num, FV) then
        slot_value(Kind, FV, Read, !IT),
        % A root-null `Json` document is the canonical `null` ([RFCS.6.3], [LNUL.3.4]):
        % a refused body in a non-nullable slot.
        ( if Read = json(j_null) then
            Nullable = nullable,
            Value = null
        else
            Value = Read
        )
    else
        (
            Nullable = nullable,
            Value = null                % [RFCS.6.3]: the absent `optional`
        ;
            Nullable = non_null,
            % A fact reference and `Json` have no zero ([RFCS.6.3]): absent, one
            % refuses the body.
            Kind \= k_schema(_),
            Kind \= k_json,
            default_value(Kind, Value, !IT)
        )
    ),
    rebuild(Shapes, Fields, Num + 1u32, Values, !IT).

    % A non-nullable slot's absent field: proto3's default, not `null`. `rebuild`
    % refuses `Json` and a fact reference before this is asked.
    %
:- pred default_value(slot_kind::in, ds_value::out,
                      intern_table::in, intern_table::out) is det.

default_value(k_int, int(0i64), !IT).
default_value(k_float, float(0.0), !IT).
default_value(k_bool, bool(no), !IT).
default_value(k_string, str(Ref), !IT) :-
    intern("", Ref, !IT).
default_value(k_json, null, !IT).
default_value(k_bytes, bytes(bitmap.init(0)), !IT).
default_value(k_schema(_), null, !IT).
default_value(k_time, int(0i64), !IT).
default_value(k_date, int(0i64), !IT).
default_value(k_duration, int(0i64), !IT).

:- pred slot_value(slot_kind::in, field_value::in, ds_value::out,
                   intern_table::in, intern_table::out) is semidet.

slot_value(k_int, fv_varint(V), int(int64.cast_from_uint64(V)), !IT).
slot_value(k_time, fv_varint(V), int(int64.cast_from_uint64(V)), !IT).
slot_value(k_date, fv_varint(V), int(int64.cast_from_uint64(V)), !IT).
slot_value(k_duration, fv_varint(V), int(int64.cast_from_uint64(V)), !IT).
slot_value(k_bool, fv_varint(V), bool(bool_of_uint(V)), !IT).
slot_value(k_float, fv_fixed64(Bits), float(float_from_bits(Bits)), !IT).
slot_value(k_string, fv_bytes(R), str(Ref), !IT) :-
    reader_string(R, S),
    intern(S, Ref, !IT).
slot_value(k_bytes, fv_bytes(R), bytes(octets_bitmap(reader_bytes(R))), !IT).
    % A target's handle (RFCS.6.3), never 0; `read_fcem` checks it was recorded.
slot_value(k_schema(_), fv_varint(V), fact_ref(make_fact_id(V)), !IT) :-
    V \= 0u64.
    % The document's text under the tree limits, not the text limit: canonical text
    % of a value within the other three may be longer ([LGRA.5.8.6]).
slot_value(k_json, fv_bytes(R), json(J), !IT) :-
    reader_string(R, S),
    Limits0 = ds.json_text.limits,
    Limits = Limits0 ^ lim_text_bytes := no,
    ds.json_text.parse_with(Limits, S, parsed(J)).


:- func bool_of_uint(uint64) = bool.

bool_of_uint(V) = ( if V = 0u64 then no else yes ).

%-----------------------------------------------------------------------------%

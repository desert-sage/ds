% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.fact_external -- the portable typed value: `Arg` and `FactExternal`.
%
% proto/fact_external.proto: a call's arguments (RFCS.15.2) and a fact that leaves
% the engine (RFCS.23) are both written as `Arg`s.
%
% - A `oneof` member is written whenever it is the member set, zero or not:
%   a zero int written as an absence would decode as `null`. `KIND_INT` (0)
%   itself is omitted, and a decoder reads an absent kind as INT.
%
% - A known `asserted_at` writes it and `has_asserted_at`, each with proto3's
%   default omitted, so the epoch is field 6 alone; an unknown one writes neither.
%
% - `schema_hash` sorts its slots by byte order of name (RFCS.23.3). Mercury
%   compares `string` by code point, which on UTF-8 is byte order.
%-----------------------------------------------------------------------------%

:- module ds.fact_external.
:- interface.

:- import_module ds.intern.
:- import_module ds.kind.
:- import_module ds.schema.
:- import_module ds.wire.

:- import_module bitmap.
:- import_module bool.
:- import_module int64.
:- import_module list.
:- import_module maybe.
:- import_module uint8.

    %@helper
:- type arg_value
    --->    av_int(int64)
    ;       av_float(float)
    ;       av_string(string)
    ;       av_bool(bool)
    ;       av_json(string)            % canonical JSON text (LDET.3.2.7)
    ;       av_bytes(list(uint8))
    ;       av_null
    ;       av_fact_ref(fact_external)        % slot values only
    ;       av_encoded_fact(fact_external).   % call arguments only

    % One named value: a call's kwarg, or a fact's slot.
    %
    %@helper
:- type arg
    --->    arg(
                arg_name    :: string,
                arg_value   :: arg_value
            ).

    % A fact that left the engine (RFCS.23.1). `fields` are in the writing
    % schema's declaration order (RFCS.23.4).
    %
    %@helper
:- type fact_external
    --->    fact_external(
                fe_schema       :: string,
                fe_schema_hash  :: list(uint8),
                fe_fields       :: list(arg),
                fe_asserted_at  :: maybe(int64)
                    % `no` when the wall clock had no value at assertion
                    % (RFCS.23.5, LTIM.2.8.3).
            ).

    % One slot of a `SchemaShape` (RFCS.23.3).
    %
    %@helper
:- type slot_shape
    --->    slot_shape(
                ss_name         :: string,
                ss_kind         :: kind,
                ss_nullable     :: bool,
                ss_ref_schema   :: string,  % "" unless the kind is a fact reference
                ss_temporal     :: maybe(temporal_kind)
                    % `SlotShape.temporal_kind`: the declared type of a slot
                    % whose values are RDSC.5.5.8's integers. `no` is not written.
            ).

    % The declared types that cross as `kind_int` (RFCS.23.2).
    %
    %@helper
:- type temporal_kind
    --->    tk_time
    ;       tk_date
    ;       tk_duration.

    %@helper
:- func arg_value_kind(arg_value) = kind.

    % The value may be a slot value / a call argument (RFCS.23.2).
    %
    %@helper
:- pred slot_value_ok(arg_value::in) is semidet.
    %@helper
:- pred call_arg_ok(arg_value::in) is semidet.

    % SHA-256 of the encoded `SchemaShape`: the schema's name and its slots,
    % sorted by name, whatever order they are given in.
    %
    %@helper
:- func schema_hash(string, list(slot_shape)) = list(uint8).

    % `Arg` as field `Num` of the enclosing message. `semidet` only because
    % `put_double_always` is.
    %
    %@helper
:- pred put_arg(uint32::in, arg::in, builder::in, builder::out) is semidet.

    % The `FactExternal` message body, standalone.
    %
    %@helper
:- pred encode_fact_external(fact_external::in, list(uint8)::out) is semidet.

    % A schema's `SchemaShape` slots (RFCS.23.3), in declaration order. Fails
    % only on a name the intern table does not hold.
    %
    %@helper
:- pred schema_slot_shapes(intern_table::in, schema::in, list(slot_shape)::out)
    is semidet.

    %@helper
:- pred schema_name_and_hash(intern_table::in, schema::in, string::out,
                             list(uint8)::out) is semidet.

%-----------------------------------------------------------------------------%
% Decoding -- the receiving half (NCBK.10.4, RFCS.23.7)
%-----------------------------------------------------------------------------%

    % A FactExternal as the wire carries it, unjudged: which refusal a record
    % gets depends on the order `ds.fact_receive` checks it in. `asserted_at` and
    % `has_asserted_at` are read for their wire types and not kept.
    %
    %@helper
:- type raw_fact_external
    --->    raw_fact_external(
                rfe_schema      :: string,
                rfe_schema_hash :: list(uint8),
                rfe_fields      :: list(raw_arg)      % wire order
            )
    ;       raw_too_deep.
            % Nested past `raw_nesting_cap`; its bytes are not read.

    %@helper
:- type raw_arg
    --->    raw_arg(
                ra_name  :: string,
                ra_kind  :: uint32,               % the wire number, unjudged
                ra_value :: maybe(fe_value)       % the `oneof` member set:
                                                  % the last one on the wire
            ).

    %@helper
:- type fe_value
    --->    fev_int(int64)
    ;       fev_float_bits(uint64)              % the bits, so a NaN is seen
    ;       fev_string(string)
    ;       fev_bool(bool)
    ;       fev_json(string)
    ;       fev_bytes(list(uint8))
    ;       fev_fact(raw_fact_external).

    % RFCS.23.4's bound: the deepest a nested FactExternal may be, the top record
    % at depth 0.
    %
    %@helper
:- func raw_nesting_cap = int.

    % Fails on malformed wire, a known field of the wrong wire type, or a string
    % that is not UTF-8.
    %
    %@helper
:- pred decode_fact_external(bitmap::in, raw_fact_external::out) is semidet.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module ds.sha256.

:- import_module int.
:- import_module string.
:- import_module uint32.
:- import_module uint64.

arg_value_kind(av_int(_)) = kind_int.
arg_value_kind(av_float(_)) = kind_float.
arg_value_kind(av_string(_)) = kind_string.
arg_value_kind(av_bool(_)) = kind_bool.
arg_value_kind(av_json(_)) = kind_json.
arg_value_kind(av_bytes(_)) = kind_bytes.
arg_value_kind(av_null) = kind_null.
arg_value_kind(av_fact_ref(_)) = kind_fact_ref.
arg_value_kind(av_encoded_fact(_)) = kind_encoded_fact.

slot_value_ok(V) :-
    slot_kind(arg_value_kind(V)).

call_arg_ok(V) :-
    arg_kind(arg_value_kind(V)).

%-----------------------------------------------------------------------------%

schema_hash(Schema, Slots) = sha256(builder_bytes(B)) :-
    Sorted = list.sort(Slots),
    some [!B] (
        !:B = init_builder,
        put_string(1u32, Schema, !B),
        list.foldl(put_slot_shape, Sorted, !B),
        B = !.B
    ).

    % `schema_hash` sorts whole `slot_shape`s, which are name-first, and two
    % slots never share a name in one schema.
    %
:- pred put_slot_shape(slot_shape::in, builder::in, builder::out) is det.

put_slot_shape(slot_shape(Name, Kind, Nullable, Ref, Temporal), !B) :-
    some [!S] (
        !:S = init_builder,
        put_string(1u32, Name, !S),
        put_uint32(2u32, kind_number(Kind), !S),
        put_bool(3u32, Nullable, !S),
        put_string(4u32, Ref, !S),
        (
            Temporal = yes(TK),
            put_uint32(5u32, temporal_kind_number(TK), !S)
        ;
            Temporal = no
        ),
        put_message(2u32, !.S, !B)
    ).

    % `proto/slot.proto#SlotKind`'s numbers.
    %
:- func temporal_kind_number(temporal_kind) = uint32.

temporal_kind_number(tk_time) = 8u32.
temporal_kind_number(tk_date) = 9u32.
temporal_kind_number(tk_duration) = 10u32.

%-----------------------------------------------------------------------------%

put_arg(Num, arg(Name, Value), !B) :-
    some [!A] (
        !:A = init_builder,
        put_string(1u32, Name, !A),
        put_uint32(2u32, kind_number(arg_value_kind(Value)), !A),
        put_value(Value, !A),
        put_message(Num, !.A, !B)
    ).

:- pred put_value(arg_value::in, builder::in, builder::out) is semidet.

put_value(av_int(I), !B) :-
    put_int64_always(3u32, I, !B).
put_value(av_float(F), !B) :-
    put_double_always(4u32, F, !B).
put_value(av_string(S), !B) :-
    put_string_always(5u32, S, !B).
put_value(av_bool(Bool), !B) :-
    put_bool_always(6u32, Bool, !B).
put_value(av_json(Text), !B) :-
    put_string_always(7u32, Text, !B).
put_value(av_bytes(Bytes), !B) :-
    put_delimited(8u32, Bytes, !B).
put_value(av_null, !B).
put_value(av_fact_ref(F), !B) :-
    encode_fact_external(F, Body),
    put_delimited(9u32, Body, !B).
put_value(av_encoded_fact(F), !B) :-
    encode_fact_external(F, Body),
    put_delimited(9u32, Body, !B).

encode_fact_external(fact_external(Schema, Hash, Fields, At), Body) :-
    some [!B] (
        !:B = init_builder,
        put_string(1u32, Schema, !B),
        ( if Hash = [] then true else put_delimited(2u32, Hash, !B) ),
        list.foldl(put_arg(3u32), Fields, !B),
        (
            At = yes(Instant),
            put_int64(5u32, Instant, !B),
            put_bool(6u32, yes, !B)
        ;
            At = no
        ),
        Body = builder_bytes(!.B)
    ).

%-----------------------------------------------------------------------------%
% Schema shapes
%-----------------------------------------------------------------------------%

schema_slot_shapes(Interns, Schema, Shapes) :-
    list.map(slot_shape_of(Interns), slot_commons(Schema), Shapes).

schema_name_and_hash(Interns, Schema, Name, Hash) :-
    expand(Interns, schema_name_ref(Schema ^ s_name), Name),
    schema_slot_shapes(Interns, Schema, Shapes),
    Hash = schema_hash(Name, Shapes).

:- pred slot_shape_of(intern_table::in, slot_common::in, slot_shape::out)
    is semidet.

    % The temporal kinds are `kind_int` with their declared type in the shape
    % (RFCS.23.2, RFCS.23.3).
    %
slot_shape_of(Interns, SC, slot_shape(Name, Kind, Nullable, Ref, Temporal)) :-
    expand(Interns, SC ^ sc_name, Name),
    Nullable = ( if SC ^ sc_nullable = nullable then yes else no ),
    SlotKind = SC ^ sc_kind,
    (
        SlotKind = k_int, Kind = kind_int, Ref = "", Temporal = no
    ;
        SlotKind = k_time, Kind = kind_int, Ref = "", Temporal = yes(tk_time)
    ;
        SlotKind = k_date, Kind = kind_int, Ref = "", Temporal = yes(tk_date)
    ;
        SlotKind = k_duration, Kind = kind_int, Ref = "",
        Temporal = yes(tk_duration)
    ;
        SlotKind = k_float, Kind = kind_float, Ref = "", Temporal = no
    ;
        SlotKind = k_string, Kind = kind_string, Ref = "", Temporal = no
    ;
        SlotKind = k_bool, Kind = kind_bool, Ref = "", Temporal = no
    ;
        SlotKind = k_json, Kind = kind_json, Ref = "", Temporal = no
    ;
        SlotKind = k_bytes, Kind = kind_bytes, Ref = "", Temporal = no
    ;
        SlotKind = k_schema(RefName), Kind = kind_fact_ref, Temporal = no,
        expand(Interns, schema_name_ref(RefName), Ref)
    ).

%-----------------------------------------------------------------------------%
% Decoding
%-----------------------------------------------------------------------------%

raw_nesting_cap = 16.

decode_fact_external(Bytes, Raw) :-
    decode_node(0, init_reader(Bytes), Raw).

:- pred decode_node(int::in, reader::in, raw_fact_external::out) is semidet.

decode_node(Depth, R, Raw) :-
    ( if Depth > raw_nesting_cap then
        Raw = raw_too_deep
    else
        fold_fields(R, fe_field(Depth), fe_acc("", [], []), ff_ok(Acc)),
        Acc = fe_acc(Schema, Hash, RevFields),
        Raw = raw_fact_external(Schema, Hash, list.reverse(RevFields))
    ).

:- type fe_acc
    --->    fe_acc(
                fa_schema   :: string,
                fa_hash     :: list(uint8),
                fa_fields   :: list(raw_arg)        % reverse wire order
            ).

    % A singular field met twice keeps the last; a known field of another wire
    % type fails.
    %
:- pred fe_field(int::in, uint32::in, field_value::in, fe_acc::in, fe_acc::out)
    is semidet.

fe_field(Depth, Num, Value, A0, A) :-
    ( if Num = 1u32 then
        Value = fv_bytes(Sub), reader_string(Sub, S),
        A = A0 ^ fa_schema := S
    else if Num = 2u32 then
        Value = fv_bytes(Sub),
        A = A0 ^ fa_hash := reader_bytes(Sub)
    else if Num = 3u32 then
        Value = fv_bytes(Sub), decode_arg(Depth, Sub, Arg),
        A = A0 ^ fa_fields := [Arg | A0 ^ fa_fields]
    else if ( Num = 5u32 ; Num = 6u32 ) then
        % `asserted_at`, `has_asserted_at`: checked, not kept.
        Value = fv_varint(_), A = A0
    else
        A = A0
    ).

:- pred decode_arg(int::in, reader::in, raw_arg::out) is semidet.

decode_arg(Depth, R, Arg) :-
    fold_fields(R, arg_field(Depth), raw_arg("", 0u32, no), ff_ok(Arg)).

:- pred arg_field(int::in, uint32::in, field_value::in, raw_arg::in,
                  raw_arg::out) is semidet.

arg_field(Depth, Num, Value, A0, A) :-
    ( if Num = 1u32 then
        Value = fv_bytes(Sub), reader_string(Sub, S),
        A = A0 ^ ra_name := S
    else if Num = 2u32 then
        Value = fv_varint(V),
        A = A0 ^ ra_kind := uint32.cast_from_uint64(V)
    else if Num = 3u32 then
        Value = fv_varint(V),
        A = A0 ^ ra_value := yes(fev_int(int64.cast_from_uint64(V)))
    else if Num = 4u32 then
        Value = fv_fixed64(Bits),
        A = A0 ^ ra_value := yes(fev_float_bits(Bits))
    else if Num = 5u32 then
        Value = fv_bytes(Sub), reader_string(Sub, S),
        A = A0 ^ ra_value := yes(fev_string(S))
    else if Num = 6u32 then
        Value = fv_varint(V),
        A = A0 ^ ra_value := yes(fev_bool(( if V = 0u64 then no else yes )))
    else if Num = 7u32 then
        Value = fv_bytes(Sub), reader_string(Sub, S),
        A = A0 ^ ra_value := yes(fev_json(S))
    else if Num = 8u32 then
        Value = fv_bytes(Sub),
        A = A0 ^ ra_value := yes(fev_bytes(reader_bytes(Sub)))
    else if Num = 9u32 then
        Value = fv_bytes(Sub), decode_node(Depth + 1, Sub, Inner),
        A = A0 ^ ra_value := yes(fev_fact(Inner))
    else
        A = A0
    ).

%-----------------------------------------------------------------------------%
:- end_module ds.fact_external.
%-----------------------------------------------------------------------------%

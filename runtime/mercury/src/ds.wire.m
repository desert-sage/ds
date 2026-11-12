% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.wire -- protobuf primitives: varints, tags, length-delimited slices.
%
% Hand-written: a generated parser accepts an `Atom` with no `oneof` member set,
% and carries on past a field number its schema does not know, where a DS reader
% refuses both [RFCS.19.3].
%
% Every read returns a result rather than failing: a load error names the byte
% offset and the violated clause [RDSC.11.2].
%-----------------------------------------------------------------------------%

:- module ds.wire.
:- interface.

:- import_module bitmap.
:- import_module bool.
:- import_module list.
:- import_module uint8.

%-----------------------------------------------------------------------------%

    % A cursor into a byte buffer, bounded above: a length-delimited field yields a
    % sub-reader bounded to its own body.
    %
:- type reader.

:- func init_reader(bitmap) = reader.

    % A reader over `[Start, Limit)`. Fails if the window is not within the buffer.
    %
:- pred init_reader_at(bitmap::in, int::in, int::in, reader::out) is semidet.

:- pred at_end(reader::in) is semidet.

:- func position(reader) = int.
:- func remaining(reader) = int.

    % The byte at the reader's position, without moving it. Fails at the end.
    %
:- pred peek_byte(reader::in, uint8::out) is semidet.

%-----------------------------------------------------------------------------%

:- type wire_error
    --->    we_truncated
            % The buffer or the enclosing bound ended mid-value. The caller decides
            % what that is [RFCS.19.2].

    ;       we_varint_overlong
            % More than 10 bytes, or a 10th byte carrying bits above 64.

    ;       we_bad_wire_type(int)
            % 3, 4, 6 or 7.

    ;       we_field_overflow
            % A tag whose field number is wider than uint32.

    ;       we_length_overflow.
            % A declared length past 2^31 - 1 ([RFCS.19.7]). A caller reads it as
            % truncation ([RDSC.11.1]).

:- type read_result(T)
    --->    ok(T)
    ;       error(wire_error).

%-----------------------------------------------------------------------------%

:- pred read_varint(read_result(uint64)::out, reader::in, reader::out) is det.

:- type wire_type
    --->    wt_varint       % 0
    ;       wt_fixed64      % 1
    ;       wt_len          % 2
    ;       wt_fixed32.     % 5

:- pred read_tag(read_result({uint32, wire_type})::out,
                 reader::in, reader::out) is det.

    % A sub-reader bounded to the value's body. The parent advances past it.
    %
:- pred read_delimited(read_result(reader)::out, reader::in, reader::out)
    is det.

:- pred skip_value(wire_type::in, read_result({})::out,
                   reader::in, reader::out) is det.

%-----------------------------------------------------------------------------%
% Message fields
%-----------------------------------------------------------------------------%

:- type field_value
    --->    fv_varint(uint64)
    ;       fv_fixed64(uint64)
    ;       fv_fixed32(uint32)
    ;       fv_bytes(reader).       % a sub-reader over the value's own bytes

:- type field_result
    --->    field(uint32, field_value)
    ;       fields_end
    ;       field_error(wire_error).

    % `fields_end` is the reader reaching its bound.
    %
:- pred next_field(field_result::out, reader::in, reader::out) is det.

:- func reader_bytes(reader) = list(uint8).

    % The bytes decoded as UTF-8; fails on ill-formed input.
    %
:- pred reader_string(reader::in, string::out) is semidet.

%-----------------------------------------------------------------------------%
% Walking a message body
%-----------------------------------------------------------------------------%

:- type fold_result(T)
    --->    ff_ok(T)
    ;       ff_bad_field
            % A handler rejected a field: the bytes parsed and the message did not.
    ;       ff_wire(wire_error).

    % Walk a message body, applying a per-field handler, whose failure means "this
    % field is not acceptable here". Unknown field numbers are the handler's business
    % [LNAM.7.2].
    %
:- pred fold_fields(reader, pred(uint32, field_value, T, T), T, fold_result(T)).
:- mode fold_fields(in, pred(in, in, in, out) is semidet, in, out) is det.

    % A length-delimited field as a packed repeated varint. A caller still accepts the
    % unpacked form: protobuf requires a decoder to handle both.
    %
:- pred read_packed_varints(reader::in, read_result(list(uint64))::out) is det.

    % A `repeated` enum field's values, packed or unpacked, from one occurrence.
    % Anything else is a 0: no `Capability` is 0, so every check downstream refuses it.
    %
:- func enum_values(field_value) = list(int).

%-----------------------------------------------------------------------------%
% Floats
%-----------------------------------------------------------------------------%

    % Reinterpret an IEEE-754 binary64 bit pattern as a float, from its three fields:
    % `float.cast_from_uint64` converts numerically. A NaN reads as 0.0; a caller that
    % must refuse one tests `nan_bits` first ([RDSC.9.10]).
    %
:- func float_from_bits(uint64) = float.

:- pred nan_bits(uint64::in) is semidet.

%-----------------------------------------------------------------------------%
% Encoding
%-----------------------------------------------------------------------------%
%
% The plain scalar helpers omit a zero, per proto3. The `_always` forms write it, for
% a field with presence ([RFCS.6.3]) or a `oneof` member.

    % An output buffer. A byte is a cons onto a reversed run; a byte list and a nested
    % message's builder are appended as chunks, so a byte is copied a fixed number of
    % times however deep the messages nest.
    %
:- type builder.

:- func init_builder = builder.

:- func builder_bytes(builder) = list(uint8).

:- func builder_length(builder) = int.

    % Neither copies a byte.
    %
:- func append_builder(builder, builder) = builder.
:- func concat_builders(list(builder)) = builder.

:- pred put_byte(uint8::in, builder::in, builder::out) is det.
:- pred put_bytes(list(uint8)::in, builder::in, builder::out) is det.

    % Zero is one byte: omitting a default is the field helpers' decision.
    %
:- pred put_varint(uint64::in, builder::in, builder::out) is det.

:- pred put_tag(uint32::in, wire_type::in, builder::in, builder::out) is det.

:- pred put_delimited(uint32::in, list(uint8)::in,
                      builder::in, builder::out) is det.

:- pred put_message(uint32::in, builder::in, builder::in, builder::out) is det.

:- pred put_string(uint32::in, string::in, builder::in, builder::out) is det.

:- pred put_string_always(uint32::in, string::in,
                          builder::in, builder::out) is det.

:- pred put_uint32(uint32::in, uint32::in, builder::in, builder::out) is det.
:- pred put_uint64(uint32::in, uint64::in, builder::in, builder::out) is det.
:- pred put_bool(uint32::in, bool::in, builder::in, builder::out) is det.
:- pred put_uint64_always(uint32::in, uint64::in,
                          builder::in, builder::out) is det.

    % Not zigzag: a negative `int32` sign-extends to ten bytes.
    %
:- pred put_int32(uint32::in, int::in, builder::in, builder::out) is det.

:- pred put_int64(uint32::in, int64::in, builder::in, builder::out) is det.

    % `fixed64` little-endian, from `float.float64_bits_string`'s decimal text.
    % `semidet` because that text has to parse.
    %
:- pred put_double(uint32::in, float::in, builder::in, builder::out) is semidet.

:- pred put_bool_always(uint32::in, bool::in, builder::in, builder::out) is det.
:- pred put_int64_always(uint32::in, int64::in,
                         builder::in, builder::out) is det.
:- pred put_double_always(uint32::in, float::in,
                          builder::in, builder::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.i64.
:- import_module char.
:- import_module cord.
:- import_module float.
:- import_module int.
:- import_module int64.
:- import_module string.
:- import_module uint.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%

:- type reader
    --->    reader(
                rd_bytes :: bitmap,
                rd_pos   :: int,
                rd_limit :: int     % exclusive
            ).

init_reader(BM) = reader(BM, 0, bitmap.det_num_bytes(BM)).

init_reader_at(BM, Start, Limit, reader(BM, Start, Limit)) :-
    Start >= 0,
    Limit >= Start,
    Limit =< bitmap.det_num_bytes(BM).

at_end(R) :-
    R ^ rd_pos >= R ^ rd_limit.

position(R) = R ^ rd_pos.

remaining(R) = R ^ rd_limit - R ^ rd_pos.

peek_byte(R, B) :-
    next_byte(B, R, _).

:- pred next_byte(uint8::out, reader::in, reader::out) is semidet.

next_byte(B, R0, R) :-
    P = R0 ^ rd_pos,
    P < R0 ^ rd_limit,
    B = bitmap.get_uint8(R0 ^ rd_bytes, P),
    R = R0 ^ rd_pos := P + 1.

%-----------------------------------------------------------------------------%

read_varint(Result, !R) :-
    read_varint_loop(0, 0u64, Result, !R).

:- pred read_varint_loop(int::in, uint64::in, read_result(uint64)::out,
                         reader::in, reader::out) is det.

read_varint_loop(Group, Acc, Result, !R) :-
    ( if Group >= 10 then
        Result = error(we_varint_overlong)
    else if next_byte(B, !R) then
        Low = uint64.cast_from_uint8(B /\ 0x7Fu8),
        ( if Group = 9, Low > 1u64 then
            % The tenth group may contribute exactly one bit.
            Result = error(we_varint_overlong)
        else
            Acc1 = Acc \/ (Low << (Group * 7)),
            ( if B /\ 0x80u8 = 0u8 then
                Result = ok(Acc1)
            else
                read_varint_loop(Group + 1, Acc1, Result, !R)
            )
        )
    else
        Result = error(we_truncated)
    ).

%-----------------------------------------------------------------------------%

read_tag(Result, !R) :-
    read_varint(VarResult, !R),
    (
        VarResult = error(E),
        Result = error(E)
    ;
        VarResult = ok(V),
        WT = V /\ 0x7u64,
        Field = V >> 3,
        ( if wire_type_of(WT, Type) then
            ( if Field =< 0xFFFFFFFFu64 then
                Result = ok({uint32.cast_from_uint64(Field), Type})
            else
                Result = error(we_field_overflow)
            )
        else
            Result = error(we_bad_wire_type(uint64.cast_to_int(WT)))
        )
    ).

:- pred wire_type_of(uint64::in, wire_type::out) is semidet.

wire_type_of(0u64, wt_varint).
wire_type_of(1u64, wt_fixed64).
wire_type_of(2u64, wt_len).
wire_type_of(5u64, wt_fixed32).

%-----------------------------------------------------------------------------%

read_delimited(Result, !R) :-
    read_varint(LenResult, !R),
    (
        LenResult = error(E),
        Result = error(E)
    ;
        LenResult = ok(Len64),
        ( if Len64 > 0x7FFFFFFFu64 then
            % Refused before it is used as a bound [RFCS.19.7].
            Result = error(we_length_overflow)
        else
            Len = uint64.cast_to_int(Len64),
            Start = !.R ^ rd_pos,
            % The room left, not `Start + Len`, which can pass `max_int` on a
            % 32-bit grade.
            ( if Len =< !.R ^ rd_limit - Start then
                End = Start + Len,
                Sub = reader(!.R ^ rd_bytes, Start, End),
                !R ^ rd_pos := End,
                Result = ok(Sub)
            else
                Result = error(we_truncated)
            )
        )
    ).

%-----------------------------------------------------------------------------%

skip_value(wt_varint, Result, !R) :-
    read_varint(V, !R),
    (
        V = ok(_),
        Result = ok({})
    ;
        V = error(E),
        Result = error(E)
    ).
skip_value(wt_fixed64, Result, !R) :-
    skip_fixed(8, Result, !R).
skip_value(wt_fixed32, Result, !R) :-
    skip_fixed(4, Result, !R).
skip_value(wt_len, Result, !R) :-
    read_delimited(D, !R),
    (
        D = ok(_),
        Result = ok({})
    ;
        D = error(E),
        Result = error(E)
    ).

:- pred skip_fixed(int::in, read_result({})::out, reader::in, reader::out)
    is det.

skip_fixed(N, Result, !R) :-
    ( if !.R ^ rd_pos + N =< !.R ^ rd_limit then
        !R ^ rd_pos := !.R ^ rd_pos + N,
        Result = ok({})
    else
        Result = error(we_truncated)
    ).

%-----------------------------------------------------------------------------%

%-----------------------------------------------------------------------------%
% Message fields
%-----------------------------------------------------------------------------%

next_field(Result, !R) :-
    ( if at_end(!.R) then
        Result = fields_end
    else
        read_tag(TagResult, !R),
        (
            TagResult = error(E),
            Result = field_error(E)
        ;
            TagResult = ok({Field, Type}),
            read_field_value(Type, ValueResult, !R),
            (
                ValueResult = error(E2),
                Result = field_error(E2)
            ;
                ValueResult = ok(V),
                Result = field(Field, V)
            )
        )
    ).

:- pred read_field_value(wire_type::in, read_result(field_value)::out,
                         reader::in, reader::out) is det.

read_field_value(wt_varint, Result, !R) :-
    read_varint(V, !R),
    (
        V = ok(N),
        Result = ok(fv_varint(N))
    ;
        V = error(E),
        Result = error(E)
    ).
read_field_value(wt_len, Result, !R) :-
    read_delimited(D, !R),
    (
        D = ok(Sub),
        Result = ok(fv_bytes(Sub))
    ;
        D = error(E),
        Result = error(E)
    ).
read_field_value(wt_fixed64, Result, !R) :-
    read_fixed(8, 0, 0u64, Result0, !R),
    (
        Result0 = ok(N),
        Result = ok(fv_fixed64(N))
    ;
        Result0 = error(E),
        Result = error(E)
    ).
read_field_value(wt_fixed32, Result, !R) :-
    read_fixed(4, 0, 0u64, Result0, !R),
    (
        Result0 = ok(N),
        Result = ok(fv_fixed32(uint32.cast_from_uint64(N)))
    ;
        Result0 = error(E),
        Result = error(E)
    ).

    % Little-endian, per protobuf's fixed encoding.
    %
:- pred read_fixed(int::in, int::in, uint64::in, read_result(uint64)::out,
                   reader::in, reader::out) is det.

read_fixed(Want, Got, Acc, Result, !R) :-
    ( if Got >= Want then
        Result = ok(Acc)
    else if next_byte(B, !R) then
        Acc1 = Acc \/ (uint64.cast_from_uint8(B) << (Got * 8)),
        read_fixed(Want, Got + 1, Acc1, Result, !R)
    else
        Result = error(we_truncated)
    ).

reader_bytes(R) = collect(R ^ rd_bytes, R ^ rd_pos, R ^ rd_limit).

:- func collect(bitmap, int, int) = list(uint8).

collect(BM, I, Limit) =
    ( if I >= Limit then
        []
    else
        [bitmap.get_uint8(BM, I) | collect(BM, I + 1, Limit)]
    ).

%-----------------------------------------------------------------------------%

reader_string(R, S) :-
    string.from_utf8_code_unit_list(
        list.map(uint8.cast_to_int, reader_bytes(R)), S).

%-----------------------------------------------------------------------------%

fold_fields(R0, Handler, Acc0, Result) :-
    next_field(F, R0, R1),
    (
        F = fields_end,
        Result = ff_ok(Acc0)
    ;
        F = field_error(E),
        Result = ff_wire(E)
    ;
        F = field(Num, Value),
        ( if Handler(Num, Value, Acc0, Acc1) then
            fold_fields(R1, Handler, Acc1, Result)
        else
            Result = ff_bad_field
        )
    ).

%-----------------------------------------------------------------------------%

read_packed_varints(R, Result) :-
    packed_loop(R, [], Result).

enum_values(Value) = Values :-
    ( if Value = fv_varint(V) then
        Values = [uint64.cast_to_int(V)]
    else if
        Value = fv_bytes(Sub),
        read_packed_varints(Sub, ok(Vs))
    then
        Values = list.map(uint64.cast_to_int, Vs)
    else
        Values = [0]
    ).

:- pred packed_loop(reader::in, list(uint64)::in,
                    read_result(list(uint64))::out) is det.

packed_loop(R0, Acc, Result) :-
    ( if at_end(R0) then
        Result = ok(list.reverse(Acc))
    else
        read_varint(One, R0, R1),
        (
            One = error(E),
            Result = error(E)
        ;
            One = ok(V),
            packed_loop(R1, [V | Acc], Result)
        )
    ).

%-----------------------------------------------------------------------------%

float_from_bits(Bits) = Value :-
    Sign = ( if (Bits >> 63) /\ 1u64 = 1u64 then -1.0 else 1.0 ),
    Exp = uint64.cast_to_int((Bits >> 52) /\ 0x7FFu64),
    Frac = Bits /\ 0xFFFFFFFFFFFFFu64,
    FracF = float(uint64.cast_to_int(Frac)) / 4503599627370496.0,  % 2^52
    ( if Exp = 0 then
        % Subnormal: no implicit leading 1, and the exponent is 1-1023 rather
        % than 0-1023.
        Value = Sign * FracF * float.pow(2.0, -1022)
    else if Exp = 2047 then
        ( if Frac = 0u64 then
            Value = Sign * float.infinity
        else
            Value = 0.0
        )
    else
        Value = Sign * (1.0 + FracF) * float.pow(2.0, Exp - 1023)
    ).

nan_bits(Bits) :-
    (Bits >> 52) /\ 0x7FFu64 = 0x7FFu64,
    Bits /\ 0xFFFFFFFFFFFFFu64 \= 0u64.

%-----------------------------------------------------------------------------%
% Encoding
%-----------------------------------------------------------------------------%

    % A run of bytes as it came: sealing a run or taking a caller's list copies nothing.
    %
:- type chunk
    --->    rev(list(uint8))
    ;       fwd(list(uint8)).

:- type builder
    --->    builder(
                b_chunks :: cord(chunk),    % sealed, in order
                b_rev    :: list(uint8),    % the open run, reversed
                b_len    :: int             % carried, not recomputed
            ).

init_builder = builder(cord.empty, [], 0).

:- func sealed(builder) = cord(chunk).

sealed(B) = Chunks :-
    Rev = B ^ b_rev,
    (
        Rev = [],
        Chunks = B ^ b_chunks
    ;
        Rev = [_ | _],
        Chunks = cord.snoc(B ^ b_chunks, rev(Rev))
    ).

    % Built from the last chunk back, in tail calls.
    %
builder_bytes(B) = cord.foldr(prepend_chunk, sealed(B), []).

:- func prepend_chunk(chunk, list(uint8)) = list(uint8).

prepend_chunk(rev(Rev), Acc) = list.foldl(cons_byte, Rev, Acc).
prepend_chunk(fwd(Fwd), Acc) = list.foldl(cons_byte, list.reverse(Fwd), Acc).

:- func cons_byte(uint8, list(uint8)) = list(uint8).

cons_byte(Byte, Acc) = [Byte | Acc].

builder_length(B) = B ^ b_len.

append_builder(A, B) =
    builder(sealed(A) ++ sealed(B), [], A ^ b_len + B ^ b_len).

concat_builders(Bs) = list.foldl(append_onto, Bs, init_builder).

:- func append_onto(builder, builder) = builder.

append_onto(B, Acc) = append_builder(Acc, B).

put_byte(Byte, B0, B) :-
    B0 = builder(Chunks, Rev, Len),
    B = builder(Chunks, [Byte | Rev], Len + 1).

    % A short list is consed onto the open run, a long one kept as a chunk.
    %
put_bytes(Bytes, !B) :-
    N = list.length(Bytes),
    ( if N < 16 then
        list.foldl(put_byte, Bytes, !B)
    else
        !:B = builder(cord.snoc(sealed(!.B), fwd(Bytes)), [],
            !.B ^ b_len + N)
    ).

put_varint(V, !B) :-
    ( if V < 0x80u64 then
        put_byte(uint8.cast_from_int(uint64.cast_to_int(V)), !B)
    else
        Low = uint8.cast_from_int(uint64.cast_to_int((V /\ 0x7Fu64) \/ 0x80u64)),
        put_byte(Low, !B),
        put_varint(V >> 7, !B)
    ).

put_tag(Num, WT, !B) :-
    wire_type_code(WT, Code),
    Tag = (uint32.cast_to_uint64(Num) << 3) \/ Code,
    put_varint(Tag, !B).

:- pred wire_type_code(wire_type::in, uint64::out) is det.

wire_type_code(wt_varint, 0u64).
wire_type_code(wt_fixed64, 1u64).
wire_type_code(wt_len, 2u64).
wire_type_code(wt_fixed32, 5u64).

put_delimited(Num, Bytes, !B) :-
    put_tag(Num, wt_len, !B),
    put_varint(uint64.cast_from_int(list.length(Bytes)), !B),
    put_bytes(Bytes, !B).

put_message(Num, Body, !B) :-
    put_tag(Num, wt_len, !B),
    put_varint(uint64.cast_from_int(builder_length(Body)), !B),
    !:B = append_builder(!.B, Body).

put_string(Num, S, !B) :-
    ( if S = "" then true else put_string_always(Num, S, !B) ).

    % The UTF-8 code units, consed onto the open run, with no list of them first unless
    % the string has a code point past ASCII.
    %
put_string_always(Num, S, !B) :-
    N = string.count_utf8_code_units(S),
    put_tag(Num, wt_len, !B),
    put_varint(uint64.cast_from_int(N), !B),
    !.B = builder(Chunks, Rev0, Len),
    ( if string.all_match(ascii_char, S) then
        Rev = string.foldl(cons_ascii, S, Rev0)
    else
        string.to_utf8_code_unit_list(S, Codes),
        Rev = list.foldl(cons_code_unit, Codes, Rev0)
    ),
    !:B = builder(Chunks, Rev, Len + N).

    % An ill-formed sequence reads as U+FFFD, so such a string keeps its bytes through
    % the code-unit path.
    %
:- pred ascii_char(char::in) is semidet.

ascii_char(C) :-
    char.to_int(C) < 0x80.

:- func cons_ascii(char, list(uint8)) = list(uint8).

cons_ascii(C, Acc) = [uint8.cast_from_int(char.to_int(C)) | Acc].

:- func cons_code_unit(int, list(uint8)) = list(uint8).

cons_code_unit(U, Acc) = [uint8.cast_from_int(U) | Acc].

put_uint32(Num, V, !B) :-
    ( if V = 0u32 then
        true                                    % proto3: omit the default
    else
        put_tag(Num, wt_varint, !B),
        put_varint(uint32.cast_to_uint64(V), !B)
    ).

put_uint64(Num, V, !B) :-
    ( if V = 0u64 then
        true
    else
        put_tag(Num, wt_varint, !B),
        put_varint(V, !B)
    ).

put_uint64_always(Num, V, !B) :-
    put_tag(Num, wt_varint, !B),
    put_varint(V, !B).

put_bool(Num, Bool, !B) :-
    (
        Bool = no                               % proto3: false is the default
    ;
        Bool = yes,
        put_tag(Num, wt_varint, !B),
        put_varint(1u64, !B)
    ).

put_int32(Num, V, !B) :-
    ( if V = 0 then
        true
    else
        put_tag(Num, wt_varint, !B),
        put_varint(uint64.cast_from_int(V), !B)
    ).

put_int64(Num, V, !B) :-
    ( if V = 0i64 then
        true
    else
        % Reinterpreted, so a negative writes its ten-byte two's complement.
        put_tag(Num, wt_varint, !B),
        put_varint(uint64.cast_from_int64(V), !B)
    ).

put_double(Num, F, !B) :-
    % `float64_bits_string` renders the bits as a signed decimal.
    i64.from_decimal(float.float64_bits_string(F), Signed),
    % Omits +0.0 on the bit pattern: -0.0 unifies with 0.0, and is written.
    ( if Signed = 0i64 then
        true
    else
        put_tag(Num, wt_fixed64, !B),
        put_fixed64(uint64.cast_from_int64(Signed), !B)
    ).

put_bool_always(Num, Bool, !B) :-
    put_tag(Num, wt_varint, !B),
    ( Bool = yes, put_varint(1u64, !B)
    ; Bool = no, put_varint(0u64, !B)
    ).

put_int64_always(Num, V, !B) :-
    put_tag(Num, wt_varint, !B),
    put_varint(uint64.cast_from_int64(V), !B).

put_double_always(Num, F, !B) :-
    i64.from_decimal(float.float64_bits_string(F), Signed),
    put_tag(Num, wt_fixed64, !B),
    put_fixed64(uint64.cast_from_int64(Signed), !B).

:- pred put_fixed64(uint64::in, builder::in, builder::out) is det.

put_fixed64(V, !B) :-
    put_fixed_loop(V, 8, !B).

:- pred put_fixed_loop(uint64::in, int::in, builder::in, builder::out) is det.

put_fixed_loop(V, N, !B) :-
    ( if N =< 0 then
        true
    else
        put_byte(uint8.cast_from_int(uint64.cast_to_int(V /\ 0xFFu64)), !B),
        put_fixed_loop(V >> 8, N - 1, !B)
    ).

%-----------------------------------------------------------------------------%

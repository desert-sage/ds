% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.dsc_schema -- decoding the schema atoms, and resolving them into schemas.
%
% A slot's index is not on the wire: it is the order of arrival within its schema
% [RFCS.5.1], assigned at resolve.
%-----------------------------------------------------------------------------%

:- module ds.dsc_schema.
:- interface.

:- import_module ds.fault.
:- import_module ds.intern.
:- import_module ds.schema.
:- import_module ds.wire.
:- import_module list.

%-----------------------------------------------------------------------------%

:- type schema_staging.

:- func init_schema_staging = schema_staging.

:- type schema_step
    --->    ss_ok(schema_staging, intern_table)
    ;       ss_error(load_error_kind, string).      % kind, clause id

:- pred decode_slog(reader::in, schema_staging::in, intern_table::in,
                    schema_step::out) is det.
:- pred decode_sttl(reader::in, schema_staging::in, intern_table::in,
                    schema_step::out) is det.
:- pred decode_slot(reader::in, schema_staging::in, intern_table::in,
                    schema_step::out) is det.
:- pred decode_sdef(reader::in, schema_staging::in, intern_table::in,
                    schema_step::out) is det.

    % [RDSC.5.6]. The compiler emits none.
    %
:- pred decode_hydr(reader::in, schema_staging::in, intern_table::in,
                    schema_step::out) is det.

:- type resolve_result
    --->    resolved(list(schema))
    ;       resolve_error(load_error_kind, string).

:- pred resolve_schemas(schema_staging::in, intern_table::in,
                        resolve_result::out) is det.

    % Did a lifecycle atom declare this schema ([LFAC.1.1])?
    %
:- pred declares_schema(schema_staging::in, string::in) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.chrono.
:- import_module ds.id.
:- import_module assoc_list.
:- import_module bool.
:- import_module float.
:- import_module int.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%

:- type raw_slot
    --->    raw_slot(
                rs_name      :: string,
                rs_kind      :: uint32,
                rs_ref       :: string,
                rs_sampled   :: bool,
                rs_retained  :: bool,
                rs_tolerance :: uint64,     % IEEE-754 bits; see `to_tolerance`
                rs_role      :: uint32,
                rs_nullable  :: bool,
                rs_hydratable :: bool,      % set by a later Hydration atom
                rs_capacity  :: uint32      % field 12; 0 = none declared
            ).

:- type raw_lifecycle
    --->    rl_slog(bool, slog_lifecycle)   % ambient, and the declared lifecycle
    ;       rl_ttl(uint64).                 % ttl_ns

    % `SchemaLifecycle` ([RDSC.5.4.5]). `UNSPECIFIED` is refused at decode.
    %
:- type slog_lifecycle
    --->    sl_explicit
    ;       sl_logical
    ;       sl_activation.

:- type schema_staging
    --->    schema_staging(
                sg_lifecycles :: assoc_list(string, raw_lifecycle),
                                            % reverse declaration order
                sg_slots      :: assoc_list(string, raw_slot),
                                            % reverse arrival order
                sg_defs       :: assoc_list(string, string)
                                            % schema name - proto_source text
            ).

init_schema_staging = schema_staging([], [], []).

%-----------------------------------------------------------------------------%
% Decoding
%-----------------------------------------------------------------------------%

    % `SchemaLogical` is every lifecycle but `ttl`, and field 3 says which.
    %
decode_slog(R, Sg0, IT0, Step) :-
    fold_body(R, slog_field, {"", no, 0u32}, Result),
    (
        Result = ff_failed(K, C),
        Step = ss_error(K, C)
    ;
        Result = ff_got({Name, Ambient, Code}),
        ( if slog_lifecycle_of_code(Code, Lifecycle) then
            intern(Name, _, IT0, IT),
            Step = ss_ok(add_lifecycle(Name, rl_slog(Ambient, Lifecycle), Sg0),
                IT)
        else
            Step = ss_error(lek_semantic, "RDSC.5.4.5")
        )
    ).

:- pred slog_lifecycle_of_code(uint32::in, slog_lifecycle::out) is semidet.

slog_lifecycle_of_code(1u32, sl_explicit).
slog_lifecycle_of_code(2u32, sl_logical).
slog_lifecycle_of_code(3u32, sl_activation).

:- pred slog_field(uint32::in, field_value::in,
                   {string, bool, uint32}::in, {string, bool, uint32}::out)
    is semidet.

    % If-then-else rather than one clause per field, throughout this module: with
    % a catch-all clause Mercury infers `multi`. Failure means the wrong wire type.
    %
slog_field(Num, Value, {N0, A0, L0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, Name), Acc = {Name, A0, L0}
    else if Num = 2u32 then
        Value = fv_varint(V), Acc = {N0, bool_of(V), L0}
    else if Num = 3u32 then
        Value = fv_varint(V), Acc = {N0, A0, uint32.cast_from_uint64(V)}
    else
        Acc = {N0, A0, L0}
    ).

decode_sttl(R, Sg0, IT0, Step) :-
    fold_body(R, sttl_field, {"", 0u64}, Result),
    (
        Result = ff_failed(K, C),
        Step = ss_error(K, C)
    ;
        Result = ff_got({Name, Ttl}),
        % A zero is not checked, and gives facts that expire at once.
        intern(Name, _, IT0, IT),
        Step = ss_ok(add_lifecycle(Name, rl_ttl(Ttl), Sg0), IT)
    ).

:- pred sttl_field(uint32::in, field_value::in,
                   {string, uint64}::in, {string, uint64}::out) is semidet.

sttl_field(Num, Value, {N0, T0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, Name), Acc = {Name, T0}
    else if Num = 2u32 then
        Value = fv_varint(V), Acc = {N0, V}
    else
        Acc = {N0, T0}
    ).

decode_slot(R, Sg0, IT0, Step) :-
    Blank = {"", raw_slot("", 0u32, "", no, no, 0u64, 0u32, no, no, 0u32)},
    fold_body(R, slot_field, Blank, Result),
    (
        Result = ff_failed(K, C),
        Step = ss_error(K, C)
    ;
        Result = ff_got({Schema, Raw}),
        ( if nan_bits(Raw ^ rs_tolerance) then
            Step = ss_error(lek_semantic, "RDSC.9.10")
        else if float_from_bits(Raw ^ rs_tolerance) < 0.0 then
            Step = ss_error(lek_semantic, "RDSC.9.11")
        else
            intern(Schema, _, IT0, IT1),
            intern(Raw ^ rs_name, _, IT1, IT),
            Step = ss_ok(Sg0 ^ sg_slots := [Schema - Raw | Sg0 ^ sg_slots], IT)
        )
    ).

:- pred slot_field(uint32::in, field_value::in,
                   {string, raw_slot}::in, {string, raw_slot}::out) is semidet.

slot_field(Num, Value, {Sc0, R0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, V), Acc = {V, R0}
    else if Num = 2u32 then
        Value = fv_bytes(S), reader_string(S, V), Acc = {Sc0, R0 ^ rs_name := V}
    else if Num = 3u32 then
        Value = fv_varint(V),
        Acc = {Sc0, R0 ^ rs_kind := uint32.cast_from_uint64(V)}
    else if Num = 4u32 then
        Value = fv_bytes(S), reader_string(S, V), Acc = {Sc0, R0 ^ rs_ref := V}
    else if Num = 5u32 then
        Value = fv_varint(V), Acc = {Sc0, R0 ^ rs_sampled := bool_of(V)}
    else if Num = 6u32 then
        Value = fv_varint(V), Acc = {Sc0, R0 ^ rs_retained := bool_of(V)}
    else if Num = 7u32 then
        Value = fv_fixed64(V), Acc = {Sc0, R0 ^ rs_tolerance := V}
    else if Num = 9u32 then
        Value = fv_varint(V),
        Acc = {Sc0, R0 ^ rs_role := uint32.cast_from_uint64(V)}
    else if Num = 11u32 then
        Value = fv_varint(V), Acc = {Sc0, R0 ^ rs_nullable := bool_of(V)}
    else if Num = 12u32 then
        Value = fv_varint(V),
        Acc = {Sc0, R0 ^ rs_capacity := uint32.cast_from_uint64(V)}
    else
        Acc = {Sc0, R0}
    ).

    % `compression` must be 1, NONE: absent is `COMPRESSION_UNSPECIFIED`, and
    % refused. `proto_source` is read as text only then, as its last occurrence
    % ([RDSC.9.12]).
    %
decode_sdef(R, Sg0, IT0, Step) :-
    fold_body(R, sdef_field, {"", no, 0u64}, Result),
    (
        Result = ff_failed(K, C),
        Step = ss_error(K, C)
    ;
        Result = ff_got({Name, MaybeProto, Compression}),
        ( if Compression \= 1u64 then
            Step = ss_error(lek_decompress, "RDSC.4.5.1")
        else if proto_text(MaybeProto, Proto) then
            intern(Name, _, IT0, IT),
            Step = ss_ok(Sg0 ^ sg_defs := [Name - Proto | Sg0 ^ sg_defs], IT)
        else
            Step = ss_error(lek_decode, "RDSC.9.12")
        )
    ).

:- pred proto_text(maybe(reader)::in, string::out) is semidet.

proto_text(no, "").
proto_text(yes(S), Text) :- reader_string(S, Text).

:- pred sdef_field(uint32::in, field_value::in,
                   {string, maybe(reader), uint64}::in,
                   {string, maybe(reader), uint64}::out)
    is semidet.

sdef_field(Num, Value, {Name0, Proto0, Comp0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, Name), Acc = {Name, Proto0, Comp0}
    else if Num = 3u32 then
        % `proto_source` is kept because `ds.rfcs` writes it back out ([RFCS.5.1]).
        Value = fv_bytes(S), Acc = {Name0, yes(S), Comp0}
    else if Num = 2u32 then
        Value = fv_varint(V), Acc = {Name0, Proto0, V}
    else
        Acc = {Name0, Proto0, Comp0}
    ).

    % Checked on arrival: [RDSC.8.1]'s grammar puts a Slot before its Hydration.
    %
decode_hydr(R, Sg0, IT0, Step) :-
    fold_body(R, hydr_field, {"", ""}, Result),
    (
        Result = ff_failed(K, C),
        Step = ss_error(K, C)
    ;
        Result = ff_got({Schema, Slot}),
        mark_hydratable(Schema, Slot, Sg0, Marked),
        (
            Marked = mh_ok(Sg),
            Step = ss_ok(Sg, IT0)
        ;
            Marked = mh_unknown_slot,
            Step = ss_error(lek_dangling, "RDSC.5.6.4")
        )
    ).

:- pred hydr_field(uint32::in, field_value::in,
                   {string, string}::in, {string, string}::out) is semidet.

hydr_field(Num, Value, {Sc0, Sl0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, V), Acc = {V, Sl0}
    else if Num = 2u32 then
        Value = fv_bytes(S), reader_string(S, V), Acc = {Sc0, V}
    else
        Acc = {Sc0, Sl0}
    ).

:- type mark_result
    --->    mh_ok(schema_staging)
    ;       mh_unknown_slot.

:- pred mark_hydratable(string::in, string::in, schema_staging::in,
                        mark_result::out) is det.

mark_hydratable(Schema, Slot, Sg0, Result) :-
    mark_slots(Schema, Slot, Sg0 ^ sg_slots, [], no, SlotsResult),
    (
        SlotsResult = ms_ok(Slots),
        Result = mh_ok(Sg0 ^ sg_slots := Slots)
    ;
        SlotsResult = ms_none,
        Result = mh_unknown_slot
    ).

:- type mark_slots_result
    --->    ms_ok(assoc_list(string, raw_slot))
    ;       ms_none.

    % Marks every Slot for one `(schema, slot)`.
    %
:- pred mark_slots(string::in, string::in,
                   assoc_list(string, raw_slot)::in,
                   assoc_list(string, raw_slot)::in,
                   bool::in, mark_slots_result::out) is det.

mark_slots(_, _, [], Acc, Found, Result) :-
    (
        Found = yes,
        Result = ms_ok(list.reverse(Acc))
    ;
        Found = no,
        Result = ms_none
    ).
mark_slots(Schema, Slot, [S - R | Rest], Acc, Found0, Result) :-
    ( if S = Schema, R ^ rs_name = Slot then
        mark_slots(Schema, Slot, Rest,
            [S - (R ^ rs_hydratable := yes) | Acc], yes, Result)
    else
        mark_slots(Schema, Slot, Rest, [S - R | Acc], Found0, Result)
    ).

:- func bool_of(uint64) = bool.

bool_of(V) = ( if V = 0u64 then no else yes ).

:- func add_lifecycle(string, raw_lifecycle, schema_staging) = schema_staging.

add_lifecycle(Name, L, Sg) =
    Sg ^ sg_lifecycles := [Name - L | Sg ^ sg_lifecycles].

%-----------------------------------------------------------------------------%
% Field folding
%-----------------------------------------------------------------------------%

:- type fold_outcome(T)
    --->    ff_got(T)
    ;       ff_failed(load_error_kind, string).

:- pred fold_body(reader, pred(uint32, field_value, T, T), T, fold_outcome(T)).
:- mode fold_body(in, pred(in, in, in, out) is semidet, in, out) is det.

fold_body(R, Handler, Acc0, Outcome) :-
    fold_fields(R, Handler, Acc0, Result),
    (
        Result = ff_ok(Acc),
        Outcome = ff_got(Acc)
    ;
        Result = ff_wire(_),
        Outcome = ff_failed(lek_decode, "RDSC.11.1")
    ;
        Result = ff_bad_field,
        Outcome = ff_failed(lek_decode, "RDSC.5.5")
    ).

%-----------------------------------------------------------------------------%
% Resolution
%-----------------------------------------------------------------------------%

    % A Slot or SchemaDef naming a schema no lifecycle atom declares is refused
    % ([LFAC.1.1]): this builds from the lifecycle atoms alone, so an orphan would
    % otherwise go unseen. libds refuses only its active accumulator for a name,
    % the highest `module_id`; they part on one name declared in two modules,
    % which no compiler emits.
    %
resolve_schemas(Sg, IT, Result) :-
    Lifecycles = lfac_1_1_one_lifecycle(list.reverse(Sg ^ sg_lifecycles)),
    Slots = list.reverse(Sg ^ sg_slots),
    ( if
        ( list.member(Name - _, Slots)
        ; list.member(Name - _, Sg ^ sg_defs)
        ),
        not declares_schema(Sg, Name)
    then
        Result = resolve_error(lek_semantic, "LFAC.1.1")
    else
        build(Lifecycles, Slots, Sg ^ sg_defs, IT, 1u32, [], Result)
    ).

declares_schema(Sg, Name) :-
    assoc_list.search(Sg ^ sg_lifecycles, Name, _).

    % One per schema name, in the order the names first arrived. The load does not
    % check [LFAC.1.1]'s rule: a SchemaTtl wins, and among several of one kind the
    % last, as libds chooses.
    %
:- func lfac_1_1_one_lifecycle(assoc_list(string, raw_lifecycle))
    = assoc_list(string, raw_lifecycle).

lfac_1_1_one_lifecycle(Ls) =
    list.map(( func(Name) = Name - chosen_lifecycle(Name, Ls) ),
        list.remove_dups(list.map(( func(P) = N :- P = N - _ ), Ls))).

    % The name came from `Ls`, so its list is never empty.
    %
:- func chosen_lifecycle(string, assoc_list(string, raw_lifecycle))
    = raw_lifecycle.

chosen_lifecycle(Name, Ls) = L :-
    Mine = list.filter_map(
        ( func(P) = L0 is semidet :- P = Name - L0 ), Ls),
    Ttls = list.filter(( pred(L1::in) is semidet :- L1 = rl_ttl(_) ), Mine),
    ( if Ttls = [_ | _] then
        L = list.det_last(Ttls)
    else
        L = list.det_last(Mine)
    ).

:- pred build(assoc_list(string, raw_lifecycle)::in,
              assoc_list(string, raw_slot)::in,
              assoc_list(string, string)::in, intern_table::in,
              uint32::in, list(schema)::in, resolve_result::out) is det.

    % The atom decides the lifecycle; slot roles are read only for a `logical` one
    % and not checked against it.
    %
build([], _, _, _, _, Acc, resolved(Schemas)) :-
    Schemas = list.reverse(Acc).
build([Name - Raw | Rest], AllSlots, Defs, IT, NextId, Acc, Result) :-
    Mine = slots_for(Name, AllSlots),
    ( if make_schema(Name, Raw, Mine, proto_for(Name, Defs), IT, NextId, S) then
        build(Rest, AllSlots, Defs, IT, NextId + 1u32, [S | Acc], Result)
    else
        Result = resolve_error(lek_semantic, "RDSC.5.5")
    ).

:- func slots_for(string, assoc_list(string, raw_slot)) = list(raw_slot).

slots_for(_, []) = [].
slots_for(Name, [S - R | Rest]) =
    ( if S = Name then [R | slots_for(Name, Rest)] else slots_for(Name, Rest) ).

:- func proto_for(string, assoc_list(string, string)) = maybe(proto_source).

proto_for(_, []) = no.
proto_for(Name, [N - P | Rest]) =
    ( if N = Name then yes(make_proto_source(P)) else proto_for(Name, Rest) ).

:- pred make_schema(string::in, raw_lifecycle::in, list(raw_slot)::in,
                    maybe(proto_source)::in,
                    intern_table::in, uint32::in, schema::out) is semidet.

make_schema(Name, Raw, Raws, Proto, IT, Id, S) :-
    interned(IT, Name, NameRef),
    commons(Raws, 0, IT, Commons),
    (
        Raw = rl_slog(Ambient, sl_logical),
        LSlots = logical_slots(Raws, Commons),
        Life = lc_logical(LSlots, Ambient)
    ;
        Raw = rl_slog(_, sl_explicit),
        Life = lc_explicit(list.map(make_plain_slot, Commons))
    ;
        Raw = rl_slog(_, sl_activation),
        Life = lc_activation(list.map(make_plain_slot, Commons))
    ;
        Raw = rl_ttl(Ns),
        Life = lc_ttl(list.map(make_plain_slot, Commons), duration_from_ns(Ns))
    ),
    S = schema(make_schema_id(Id), make_schema_name(NameRef), Life, no, Proto).

    % Assigns slot indices from position. Fails on an invalid `SlotKind` or an
    % out-of-range index.
    %
:- pred commons(list(raw_slot)::in, int::in, intern_table::in,
                list(slot_common)::out) is semidet.

commons([], _, _, []).
commons([R | Rs], I, IT, [C | Cs]) :-
    interned(IT, R ^ rs_name, NameRef),
    slot_index(uint32.det_from_int(I), Ix),
    kind_of(R, IT, Kind),
    C = slot_common(NameRef, Kind, Ix, nullable_of(R ^ rs_nullable),
        R ^ rs_sampled, R ^ rs_retained, R ^ rs_hydratable,
        capacity_of(R ^ rs_capacity)),
    commons(Rs, I + 1, IT, Cs).

:- func capacity_of(uint32) = capacity.

capacity_of(N) = ( if N = 0u32 then unbounded else at_most(N) ).

:- func nullable_of(bool) = nullable.

nullable_of(yes) = nullable.
nullable_of(no) = non_null.

    % [RDSC.5.5.5]: a SCHEMA slot needs its `schema_ref`; on any other kind the
    % field is ignored.
    %
:- pred kind_of(raw_slot::in, intern_table::in, slot_kind::out) is semidet.

kind_of(R, IT, Kind) :-
    ( if R ^ rs_kind = 6u32 then
        R ^ rs_ref \= "",
        interned(IT, R ^ rs_ref, RefName),
        Kind = k_schema(make_schema_name(RefName))
    else
        simple_kind(R ^ rs_kind, Kind)
    ).

:- pred simple_kind(uint32::in, slot_kind::out) is semidet.

simple_kind(1u32, k_int).
simple_kind(2u32, k_float).
simple_kind(3u32, k_string).
simple_kind(4u32, k_bool).
simple_kind(5u32, k_json).
simple_kind(7u32, k_bytes).
simple_kind(8u32, k_time).
simple_kind(9u32, k_date).
simple_kind(10u32, k_duration).

:- func logical_slots(list(raw_slot), list(slot_common)) = list(logical_slot).

logical_slots(Raws, Commons) = Slots :-
    ( if
        Raws = [R | Rs],
        Commons = [C | Cs]
    then
        Slots = [logical_slot(C, role_of(R ^ rs_role),
                    to_tolerance(R ^ rs_tolerance))
                | logical_slots(Rs, Cs)]
    else
        Slots = []
    ).

    % 1 is KEY, 3 is ENGINE (`ts`, [LFAC.9.1]). An unmarked slot, which the load
    % does not check, reads as mutable, which leaves the identity as it is.
    %
:- func role_of(uint32) = identity_role.

role_of(V) =
    ( if V = 1u32 then role_key
    else if V = 3u32 then role_engine
    else role_mutable ).

    % Zero, either sign, is exact ([RLOW.3.7.8]). `decode_slot` has refused a NaN
    % or negative one. `+inf` suppresses every reassertion ([RLOW.3.7.4]).
    %
:- func to_tolerance(uint64) = tolerance.

to_tolerance(Bits) = Tol :-
    F = float_from_bits(Bits),
    ( if F = 0.0 then
        Tol = exact
    else
        Tol = within(F)
    ).

:- func make_plain_slot(slot_common) = plain_slot.

make_plain_slot(C) = plain_slot(C).

%-----------------------------------------------------------------------------%

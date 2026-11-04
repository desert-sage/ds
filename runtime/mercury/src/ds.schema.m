% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.schema -- slot kinds, identity roles, lifecycles, schema descriptors.
%
% The identity-role partition is conditional on lifecycle
% [formal/alloy/identity_slots.als]: a `logical` schema's slots carry a role
% [LFAC.1.7.4], any other's do not [LFAC.1.7.6]. So they are two types.
%-----------------------------------------------------------------------------%

:- module ds.schema.
:- interface.

:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.chrono.
:- import_module ds.value.
:- import_module list.
:- import_module array.
:- import_module bool.
:- import_module maybe.
:- import_module uint32.

%-----------------------------------------------------------------------------%
% Slot kinds
%-----------------------------------------------------------------------------%

    % A slot's declared type [RDSC.5.5.2]. `schema_ref` is folded into `k_schema`.
    %
:- type slot_kind
    --->    k_int
    ;       k_float
    ;       k_string
    ;       k_bool
    ;       k_json
    ;       k_bytes
    ;       k_schema(schema_name)
    ;       k_time
    ;       k_date
    ;       k_duration.
            % The temporal types (RDSC.5.5.8) hold an `int`. Ask `int_represented`,
            % never `= k_int`, about the representation.

:- pred int_represented(slot_kind::in) is semidet.

    % An interned NFC string, which the runtime does not re-normalize [RFCS.6.5].
    %
:- type schema_name.

:- func make_schema_name(intern_ref) = schema_name.
:- func schema_name_ref(schema_name) = intern_ref.

%-----------------------------------------------------------------------------%
% Identity roles
%-----------------------------------------------------------------------------%

    % A slot's role in its schema's identity [LFAC.1.7.1, RDSC.5.5.7]. `role_engine`
    % is `ts` alone [LFAC.9.1], outside the key and the no-op comparison.
    %
:- type identity_role
    --->    role_key
    ;       role_mutable
    ;       role_engine.

    % Tolerance-aware dedup [LFAC.2.5.1], legal only on a mutable Int or Float slot of
    % a `logical` schema [LFAC.1.7.1]. `tolerance 0` is exact equality [RLOW.3.7.8].
    %
:- type tolerance
    --->    exact
    ;       within(float).

%-----------------------------------------------------------------------------%
% Slots
%-----------------------------------------------------------------------------%

:- type slot_common
    --->    slot_common(
                sc_name      :: intern_ref,
                sc_kind      :: slot_kind,
                sc_index     :: slot_index,
                sc_nullable  :: nullable,
                sc_sampled   :: bool,        % routes changes to the samples plane
                sc_retained  :: bool,        % adapter fills from retention
                sc_hydratable :: bool,       % Hydration atom present for this slot
                sc_capacity  :: capacity     % [LSTR.11.1]
            ).

    % A `String` slot's declared `capacity`, in codepoints [LSTR.11.1]. 0 on the wire
    % is none declared.
    %
:- type capacity
    --->    unbounded
    ;       at_most(uint32).

:- type nullable
    --->    non_null
    ;       nullable.

:- type logical_slot
    --->    logical_slot(
                ls_common    :: slot_common,
                ls_role      :: identity_role,
                ls_tolerance :: tolerance     % `exact` unless mutable and declared
            ).

    % A slot of a schema with no identity: no marker, no tolerance [LFAC.1.7.6].
    %
:- type plain_slot
    --->    plain_slot(
                ps_common :: slot_common
            ).

%-----------------------------------------------------------------------------%
% Schemas
%-----------------------------------------------------------------------------%

    % A schema's lifecycle, carrying the slots whose shape depends on it. Exactly one
    % lifecycle atom [RDSC.8.1], and `SchemaLogical` carries `lifecycle` for `explicit`
    % and `activation` too ([RDSC.5.4.5]).
    %
:- type lifecycle
    --->    lc_logical(
                lcl_slots   :: list(logical_slot),
                lcl_ambient :: bool
                            % `scope ambient` [LSCP.2.5]
            )
    ;       lc_ttl(
                lct_slots   :: list(plain_slot),
                lct_default :: duration          % SchemaTtl.ttl_ns, never zero
                                              % [RDSC.5.3.3]
            )
    ;       lc_explicit(
                lce_slots   :: list(plain_slot)
                            % `scope explicit` [LSCP.2.1.1], the default [LSCP.1.4]:
                            % no identity, no deadline; facts accumulate.
            )
    ;       lc_activation(
                lca_slots   :: list(plain_slot)
                            % `scope activation` [LSCP.2.4]: as `explicit`, and a fact
                            % lives until its activation completes ([LSCP.3.1]).
            ).

:- type schema
    --->    schema(
                s_id        :: schema_id,
                s_name      :: schema_name,
                s_lifecycle :: lifecycle,
                s_module    :: maybe(module_id), % `no` where no artefact
                                                 % module declared it
                                                 % [RFCS.12.3]
                s_proto     :: maybe(proto_source)
            ).

    % The canonical `.proto` text the compiler generated [RDSC.5.8], verbatim.
    %
:- type proto_source.

:- func proto_source_text(proto_source) = string.

:- func make_proto_source(string) = proto_source.

%-----------------------------------------------------------------------------%
% Identity
%-----------------------------------------------------------------------------%

    % The projection of a fact onto its schema's key slots [LFAC.1.7.5].
    %
:- type fact_identity.

    % What falls out of which slots are the key [LFAC.1.7.2, .7.3].
    %
:- type key_width
    --->    kw_singleton     % key = 0 slots; one live fact, latest payload wins
    ;       kw_entity        % key = 1 slot;  one live fact per entity
    ;       kw_composite     % key = 2..n-1 slots
    ;       kw_relation.     % key = all slots; distinct tuples coexist,
                             % identical tuples coalesce

:- func key_width(lifecycle) = maybe(key_width).

    % The deadline a fact of this schema gets, absent a per-fact override: an explicit
    % `retain:` applies on a `logical` schema too [RHIM.6.2].
    %
:- func schema_deadline(schema, instant) = maybe(instant).

    % The window a `FactAssert` records for a deadline, however it arose [RFCS.7.4].
    %
:- func recorded_ttl(maybe(instant), instant) = maybe(duration).

    % A schema's slots in declaration order, the slot numbering [RFCS.5.1].
    %
:- func slot_commons(schema) = list(slot_common).

    % The name of the slot at a zero-based index, if there is one.
    %
:- func slot_name_at(schema, int) = maybe(intern_ref).

:- pred slot_by_name(schema::in, intern_ref::in, slot_common::out) is semidet.

    % A synthetic name [LLEX.10.6.1]: `$` followed by the name. `$` is no `NAME`
    % character [LLEX.10], so no author name is one.
    %
:- pred synthetic_name(string::in) is semidet.

    % `$ClockTick`, the engine-internal fact [IRET.19.5] cycled once per pump.
    %
:- func clock_tick_name = string.

    % A compiler-synthesised schema, by its name: machinery for the matcher. Its facts
    % live in working memory for the join, and `ds.engine` keeps them out of the effect
    % list and the reported count.
    %
:- pred synthetic(intern_table::in, schema::in) is semidet.

    % `no` for a schema with no identity.
    %
:- func project_identity(schema, array(ds_value)) = maybe(fact_identity).

    % For working memory's supersedure index ([LNLS.4.7]), over every key slot and the
    % schema. Two identities that unify hash alike. A `Json` key slot hashes to a
    % constant; `nolinscan` has none [LNLS.3.1].
    %
:- pred identity_hash(fact_identity::in, int::out) is det.

    % For an index keyed on a slot value (`ds.match`'s join buckets). Two values that
    % unify hash alike.
    %
:- pred value_hash_int(ds_value::in, int::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module bitmap.
:- import_module ds.i64.
:- import_module float.
:- import_module int.
:- import_module string.
:- import_module uint32.
:- import_module uint64.
:- import_module uint8.

int_represented(k_int).
int_represented(k_time).
int_represented(k_date).
int_represented(k_duration).

:- type schema_name  ---> schema_name(intern_ref).

make_schema_name(R) = schema_name(R).
schema_name_ref(schema_name(R)) = R.

synthetic_name(Name) :-
    string.prefix(Name, "$").

clock_tick_name = "$ClockTick".

synthetic(IT, Schema) :-
    expand(IT, schema_name_ref(Schema ^ s_name), Name),
    synthetic_name(Name).

proto_source_text(proto_source(S)) = S.
make_proto_source(S) = proto_source(S).
:- type proto_source ---> proto_source(string).

:- type fact_identity ---> fact_identity(schema_id, list(ds_value)).
    % The key slots' values in declaration order. Comparison is exact [LFAC.1.7.1], so
    % structural equality is the identity relation.

key_width(lc_ttl(_, _)) = no.
key_width(lc_explicit(_)) = no.
key_width(lc_activation(_)) = no.
key_width(lc_logical(Slots, _)) = yes(Width) :-
    Keys = count_keys(Slots),
    % `ts` is in neither the key nor the payload [LFAC.9.1].
    Total = list.length(list.filter(
        ( pred(S::in) is semidet :- S ^ ls_role \= role_engine ), Slots)),
    ( if Keys = 0 then
        Width = kw_singleton
    else if Keys = 1 then
        Width = kw_entity
    else if Keys = Total then
        Width = kw_relation
    else
        Width = kw_composite
    ).

:- func count_keys(list(logical_slot)) = int.

count_keys([]) = 0.
count_keys([S | Ss]) =
    ( if S ^ ls_role = role_key then 1 else 0 ) + count_keys(Ss).

project_identity(Schema, Slots) = MaybeIdentity :-
    (
        Schema ^ s_lifecycle = lc_ttl(_, _),
        MaybeIdentity = no
    ;
        Schema ^ s_lifecycle = lc_explicit(_),
        MaybeIdentity = no
    ;
        Schema ^ s_lifecycle = lc_activation(_),
        MaybeIdentity = no
    ;
        Schema ^ s_lifecycle = lc_logical(LSlots, _),
        MaybeIdentity =
            yes(fact_identity(Schema ^ s_id, key_values(LSlots, Slots)))
    ).

    % In declaration order, which is part of the identity [LCDB.3.3.3].
    %
:- func key_values(list(logical_slot), array(ds_value)) = list(ds_value).

key_values([], _) = [].
key_values([S | Ss], Slots) = Vs :-
    Rest = key_values(Ss, Slots),
    ( if S ^ ls_role = role_key then
        Vs = [array.lookup(Slots, slot_index_int(S ^ ls_common ^ sc_index))
             | Rest]
    else
        Vs = Rest
    ).

%-----------------------------------------------------------------------------%

identity_hash(fact_identity(Schema, Values), Hash) :-
    H0 = mix(14695981039346656037u64,
        uint32.cast_to_uint64(schema_id_value(Schema))),
    H = list.foldl(( func(V, A) = mix(A, value_hash(V)) ), Values, H0),
    % Non-negative, for a hash table's slot arithmetic.
    Hash = uint64.cast_to_int(H >> 1).

value_hash_int(V, Hash) :-
    Hash = uint64.cast_to_int(mix(14695981039346656037u64, value_hash(V)) >> 1).

    % One word into the running hash, then splitmix64's finaliser.
    %
:- func mix(uint64, uint64) = uint64.

mix(H, X) = Z :-
    Z0 = (H * 31u64) `xor` X,
    Z1 = (Z0 `xor` (Z0 >> 30)) * 0xbf58476d1ce4e5b9u64,
    Z2 = (Z1 `xor` (Z1 >> 27)) * 0x94d049bb133111ebu64,
    Z = Z2 `xor` (Z2 >> 31).

:- func value_hash(ds_value) = uint64.

value_hash(int(I)) = uint64.cast_from_int64(I).
value_hash(float(F)) = float_bits(F).
value_hash(str(R)) = uint32.cast_to_uint64(intern_ref_value(R)).
value_hash(text(S)) = uint64.cast_from_int(string.length(S)).
value_hash(bool(yes)) = 1u64.
value_hash(bool(no)) = 2u64.
value_hash(bytes(B)) =
    ( if bitmap.num_bytes(B) = N then
        bytes_hash(B, 0, N, 14695981039346656037u64)
    else
        uint64.cast_from_int(bitmap.num_bits(B))
    ).
value_hash(json(_)) = 3u64.
value_hash(fact_ref(Id)) = fact_id_value(Id).
value_hash(duration(_)) = 4u64.
value_hash(time(T)) = uint64.cast_from_int64(utc_ns(T)).
value_hash(ratio(N, D)) =
    uint64.cast_from_int64(N) `xor` (uint64.cast_from_int64(D) * 31u64).
value_hash(null) = 0u64.

    % The IEEE-754 bits. Both zeros take +0.0's: Mercury unifies -0.0 with 0.0.
    %
:- func float_bits(float) = uint64.

float_bits(F) = Bits :-
    ( if F = 0.0 then
        Bits = 0u64
    else if i64.from_decimal(float.float64_bits_string(F), Signed) then
        Bits = uint64.cast_from_int64(Signed)
    else
        Bits = 1u64
    ).

:- func bytes_hash(bitmap, int, int, uint64) = uint64.

bytes_hash(B, I, N, H) =
    ( if I >= N then
        H
    else
        bytes_hash(B, I + 1, N,
            (H `xor` uint64.cast_from_int(uint8.cast_to_int(
                bitmap.get_uint8(B, I)))) * 1099511628211u64)
    ).

%-----------------------------------------------------------------------------%

slot_commons(Schema) = Commons :-
    (
        Schema ^ s_lifecycle = lc_logical(LSlots, _),
        Commons = list.map(logical_common, LSlots)
    ;
        Schema ^ s_lifecycle = lc_ttl(TSlots, _),
        Commons = list.map(plain_common, TSlots)
    ;
        Schema ^ s_lifecycle = lc_explicit(PSlots),
        Commons = list.map(plain_common, PSlots)
    ;
        Schema ^ s_lifecycle = lc_activation(PSlots),
        Commons = list.map(plain_common, PSlots)
    ).

slot_name_at(Schema, Index) = Name :-
    ( if list.index0(slot_commons(Schema), Index, Common) then
        Name = yes(Common ^ sc_name)
    else
        Name = no
    ).

:- func logical_common(logical_slot) = slot_common.
:- func plain_common(plain_slot) = slot_common.

logical_common(S) = S ^ ls_common.
plain_common(S) = S ^ ps_common.

slot_by_name(Schema, Name, Found) :-
    find_slot(slot_commons(Schema), Name, Found).

:- pred find_slot(list(slot_common)::in, intern_ref::in, slot_common::out)
    is semidet.

find_slot([S | Ss], Name, Found) :-
    ( if S ^ sc_name = Name then
        Found = S
    else
        find_slot(Ss, Name, Found)
    ).

%-----------------------------------------------------------------------------%

schema_deadline(Schema, Now) = Deadline :-
    (
        Schema ^ s_lifecycle = lc_ttl(_, Ttl),
        Deadline = yes(add(Now, Ttl))
    ;
        Schema ^ s_lifecycle = lc_logical(_, _),
        Deadline = no
    ;
        Schema ^ s_lifecycle = lc_explicit(_),
        Deadline = no
    ;
        Schema ^ s_lifecycle = lc_activation(_),
        Deadline = no
    ).

recorded_ttl(no, _) = no.
recorded_ttl(yes(Deadline), Asserted) = yes(diff(Deadline, Asserted)).

%-----------------------------------------------------------------------------%

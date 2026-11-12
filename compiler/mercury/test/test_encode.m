% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% test_encode -- the encoder, through the runtime's own decoder.
%
% The round trip:
%
%     schemas -> [dsc.encode] -> bytes -> [ds.dsc, the RUNTIME's loader] -> schemas
%
% Its two limits:
%
% 1. Not framing: encoder and decoder share `ds.wire`, so a shared varint bug
%    round-trips. The format vectors pin the framing. This tests message
%    construction: field numbers, wire types, default omission, order, and
%    which atoms exist.
%
% 2. Not a shared misreading of [RDSC]: one reading wrote both sides. The
%    conformance corpus, run in both runtimes, reaches that.
%
% A failure is attributable: `ds.dsc` names a kind and a clause.
%
% A module apart from `test_dsc`: `dsc.cst` and `ds.schema` both spell
% `lc_ttl/2` and `nullable/0`, and each suite imports one.
%-----------------------------------------------------------------------------%

% @spec [RCLI.1.5] [RDSC.5.8.3] [RDSC.5.8.6] [RLOW.7.3.8]
:- module test_encode.
:- interface.

:- import_module io.

    % Runs every case. Returns (passed, failed) rather than taking `test_dsc`s
    % tally, so the two modules share no type and no import.
    %
:- pred run(int::out, int::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module char.
:- import_module dsc.
:- import_module dsc.capability.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.dialect.
:- import_module dsc.driver.
:- import_module dsc.encode.
:- import_module dsc.rete.
:- import_module dsc.token.

:- import_module ds.
:- import_module ds.action.
:- import_module ds.atom.
:- import_module ds.builtins.
:- import_module ds.capability.
:- import_module ds.chrono.
:- import_module ds.dsc.
:- import_module ds.dsc_action.
:- import_module ds.effect.
:- import_module ds.engine.
:- import_module ds.fact.
:- import_module ds.events.
:- import_module ds.expr.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.json.
:- import_module ds.network.
:- import_module ds.rules.
:- import_module ds.schema.
:- import_module ds.series.
:- import_module ds.service.
:- import_module ds.value.
:- import_module ds.wire.

:- import_module assoc_list.
:- import_module bitmap.
:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module math.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module set.
:- import_module string.
:- import_module uint32.
:- import_module uint64.
:- import_module uint8.

%-----------------------------------------------------------------------------%

:- type tally
    --->    tally(
                t_pass :: int,
                t_fail :: int
            ).

:- pred check(string::in, bool::in, tally::in, tally::out, io::di, io::uo)
    is det.

check(Name, Ok, !Tally, !IO) :-
    (
        Ok = yes,
        !Tally ^ t_pass := !.Tally ^ t_pass + 1
    ;
        Ok = no,
        !Tally ^ t_fail := !.Tally ^ t_fail + 1,
        io.format("  FAIL  %s\n", [s(Name)], !IO)
    ).

run(Pass, Fail, !IO) :-
    cases(tally(0, 0), T, !IO),
    Pass = T ^ t_pass,
    Fail = T ^ t_fail.

%-----------------------------------------------------------------------------%
% Comparing a schema that went round with the one that went in
%-----------------------------------------------------------------------------%
%
% The comparison is on a projection, not `=`. It drops `s_id`, which the
% loader assigns (checked on its own below), and `s_module` and `s_proto`
% (asserted once, below). `intern_ref`s are table-relative, so every name is
% expanded through its own table before anything is compared.

:- type slot_shape
    --->    slot_shape(
                sh_name       :: string,
                sh_kind       :: string,
                sh_index      :: int,
                sh_nullable   :: string,
                sh_sampled    :: bool,
                sh_retained   :: bool,
                sh_hydratable :: bool,
                sh_identity   :: string,
                sh_tolerance  :: string
            ).

:- type schema_shape
    --->    schema_shape(
                sm_name  :: string,
                sm_life  :: string,
                sm_slots :: list(slot_shape)
            ).

:- func shape_of(intern_table, schema) = schema_shape.

shape_of(IT, S) = schema_shape(Name, Life, Slots) :-
    Name = text(IT, schema_name_ref(S ^ s_name)),
    L = S ^ s_lifecycle,
    (
        L = lc_logical(Ls, Ambient),
        (
            Ambient = yes,
            Life = "logical+ambient"
        ;
            Ambient = no,
            Life = "logical"
        ),
        Slots = list.map(logical_shape(IT), Ls)
    ;
        L = lc_ttl(Ps, D),
        Life = "ttl:" ++ string.string(duration_ns(D)),
        Slots = list.map(plain_shape(IT), Ps)
    ;
        L = lc_explicit(Ps),
        Life = "explicit",
        Slots = list.map(plain_shape(IT), Ps)
    ;
        L = lc_activation(Ps),
        Life = "activation",
        Slots = list.map(plain_shape(IT), Ps)
    ).

:- func logical_shape(intern_table, logical_slot) = slot_shape.

logical_shape(IT, L) = Shape :-
    Common = common_shape(IT, L ^ ls_common),
    WithRole = Common ^ sh_identity := role_text(L ^ ls_role),
    Shape = WithRole ^ sh_tolerance := tolerance_text(L ^ ls_tolerance).

:- func plain_shape(intern_table, plain_slot) = slot_shape.

plain_shape(IT, P) = common_shape(IT, P ^ ps_common).

    % `-` for both identity fields, so a NON-logical slot that somehow acquired
    % a role shows up as a difference rather than as an absence.
    %
:- func common_shape(intern_table, slot_common) = slot_shape.

common_shape(IT, C) =
    slot_shape(text(IT, C ^ sc_name), kind_text(IT, C ^ sc_kind),
        slot_index_int(C ^ sc_index), nullable_text(C ^ sc_nullable),
        C ^ sc_sampled, C ^ sc_retained, C ^ sc_hydratable, "-", "-").

:- func kind_text(intern_table, slot_kind) = string.

kind_text(_, k_int) = "Int".
kind_text(_, k_float) = "Float".
kind_text(_, k_string) = "String".
kind_text(_, k_bool) = "Bool".
kind_text(_, k_json) = "Json".
kind_text(_, k_bytes) = "Bytes".
kind_text(IT, k_schema(N)) = "->" ++ text(IT, schema_name_ref(N)).
kind_text(_, k_time) = "Time".
kind_text(_, k_date) = "Date".
kind_text(_, k_duration) = "Duration".

:- func nullable_text(nullable) = string.

nullable_text(nullable) = "?".
nullable_text(non_null) = "!".

:- func role_text(identity_role) = string.

role_text(role_key) = "key".
role_text(role_mutable) = "mutable".
role_text(role_engine) = "engine".

:- func tolerance_text(tolerance) = string.

tolerance_text(exact) = "exact".
tolerance_text(within(F)) = string.float_to_string(F).

:- func text(intern_table, intern_ref) = string.

text(IT, Ref) = ( if expand(IT, Ref, S) then S else "<UNINTERNED>" ).

%-----------------------------------------------------------------------------%
% The trip itself
%-----------------------------------------------------------------------------%

:- type trip
    --->    trip_ok(program)
    ;       trip_failed(load_error).

:- func round_trip(intern_table, list(schema)) = trip.

round_trip(IT, Schemas) = round_trip_as(builtin_binding("default", []), IT,
    Schemas).

    % A built-in dialect's settings ([LDIA.9]), as the driver hands them to
    % `encode` for a program whose `use` line names it with no block, and
    % `Requires` as the content's ([RDSC.16.2.8]).
    %
:- func builtin_binding(string, list(capability)) = binding.

builtin_binding(Name, Requires) =
        binding(program_settings(Name, Settings, map.init),
            set.list_to_set(Requires)) :-
    ( if map.search(builtin_registry, Name, Dialect) then
        Settings = Dialect ^ dl_settings
    else
        unexpected($pred, "no built-in dialect " ++ Name)
    ).

:- func round_trip_as(binding, intern_table, list(schema)) = trip.

round_trip_as(Binding, IT, Schemas) = Trip :-
    rdsc_1_1_encode(Binding, IT, Schemas, [],
        [module_source(1u32, "<in-memory:main.ds>", "")], [], [], 1u32, no_rules, no,
        Bytes),
    load_dsc(from_bytes(Bytes), Result),
    (
        Result = loaded(Program),
        Trip = trip_ok(Program)
    ;
        Result = load_failed(E),
        Trip = trip_failed(E)
    ).

    % A loaded schema's slot names, in index order. Fails when no schema has
    % the name, so a test that names the wrong schema cannot pass on `[]`.
    %
:- func slot_names(program, string) = list(string) is semidet.

slot_names(P, Name) = Names :-
    list.find_first_match(
        ( pred(S::in) is semidet :-
            expand(interns(P), schema_name_ref(S ^ s_name), Name)
        ), schemas(P), Schema),
    Names = list.map(
        ( func(C) = N :-
            ( if expand(interns(P), C ^ sc_name, N0) then N = N0 else N = "?" )
        ), slot_commons(Schema)).

    % `bitmap.init` takes a bit count.
    %
:- func from_bytes(list(uint8)) = bitmap.

from_bytes(Bs) = BM :-
    BM0 = bitmap.init(list.length(Bs) * 8),
    fill_bytes(0, Bs, BM0, BM).

:- pred fill_bytes(int::in, list(uint8)::in,
                   bitmap::bitmap_di, bitmap::bitmap_uo) is det.

fill_bytes(_, [], !BM).
fill_bytes(I, [B | Bs], !BM) :-
    bitmap.set_uint8(I, B, !BM),
    fill_bytes(I + 1, Bs, !BM).

    % The round trip, asserted on the shapes. Prints both on a mismatch.
    %
:- pred check_trip(string::in, intern_table::in, list(schema)::in,
                   tally::in, tally::out, io::di, io::uo) is det.

check_trip(Name, IT, Schemas, !T, !IO) :-
    Trip = round_trip(IT, Schemas),
    (
        Trip = trip_ok(P),
        Got = list.map(shape_of(interns(P)), schemas(P)),
        Want = list.map(shape_of(IT), Schemas),
        ( if Got = Want then
            Ok = yes
        else
            Ok = no,
            io.format("    want %s\n    got  %s\n",
                [s(string.string(Want)), s(string.string(Got))], !IO)
        )
    ;
        Trip = trip_failed(E),
        Ok = no,
        io.format("    load refused: %s [%s]\n",
            [s(string.string(E ^ le_kind)),
             s(clause_id_string(E ^ le_clause))], !IO)
    ),
    check(Name, Ok, !T, !IO).

    % For the cases asserting something about the loaded `program` other than
    % the schema shapes.
    %
:- pred check_loaded(string, intern_table, list(schema), pred(program),
                     tally, tally, io, io).
:- mode check_loaded(in, in, in, pred(in) is semidet, in, out, di, uo) is det.

check_loaded(Name, IT, Schemas, Wanted, !T, !IO) :-
    ( if round_trip(IT, Schemas) = trip_ok(P), Wanted(P) then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

%-----------------------------------------------------------------------------%
% Fixtures
%-----------------------------------------------------------------------------%

    % Intern every name up front and keep the table: a `schema` holds
    % `intern_ref`s, so there is no other way to build one.
    %
:- pred interns_of(list(string)::in, intern_table::out) is det.

interns_of(Names, IT) :-
    list.foldl(
        ( pred(N::in, T0::in, T::out) is det :- intern(N, _, T0, T) ),
        Names, init_interns, IT).

:- func ref(intern_table, string) = intern_ref.

ref(IT, N) =
    ( if interned(IT, N, R) then
        R
    else
        unexpected($pred, "fixture name was never interned: " ++ N)
    ).

    % A slot at `Index` with every flag off; a case that cares about a flag
    % sets it.
    %
:- func slot(intern_table, string, slot_kind, int) = slot_common.

slot(IT, Name, Kind, Index) = slot_common(ref(IT, Name), Kind,
    det_slot_index(Index), non_null, no, no, no, unbounded, no).

:- func det_slot_index(int) = slot_index.

det_slot_index(I) =
    ( if slot_index(uint32.det_from_int(I), Ix) then
        Ix
    else
        unexpected($pred, "slot index out of range")
    ).

:- func named(intern_table, string) = schema_name.

named(IT, N) = make_schema_name(ref(IT, N)).

%-----------------------------------------------------------------------------%
% The cases
%-----------------------------------------------------------------------------%

:- pred cases(tally::in, tally::out, io::di, io::uo) is det.

cases(!T, !IO) :-
    interns_of(["Reading", "Sensor", "Other", "entity_id", "state",
                "celsius", "payload", "raw", "flag", "owner",
                "seen", "due", "span"], IT),

    % ── the four lifecycles ─────────────────────────────────────────────────

    % [LSCP.1.4]: a bare `schema Foo:` is `scope explicit`: SchemaLogical with
    % `lifecycle` = EXPLICIT (RDSC.5.4.5). Read as logical, it would have an
    % empty identity key, and every fact of it would be one fact.
    Explicit = schema(make_schema_id(1u32), named(IT, "Reading"),
        lc_explicit([plain_slot(slot(IT, "entity_id", k_string, 0)),
                     plain_slot(slot(IT, "state", k_float, 1))]),
        no, no),
    % `scope activation`: the same slot shape under `lifecycle` = ACTIVATION,
    % back as its own constructor.
    Activation = schema(make_schema_id(1u32), named(IT, "Reading"),
        lc_activation([plain_slot(slot(IT, "entity_id", k_string, 0))]),
        no, no),
    check_trip("RDSC.5.4.5: an `activation` schema round-trips as activation",
        IT, [Activation], !T, !IO),
    check_trip("[LSCP.1.4] an `explicit` schema round-trips as explicit",
        IT, [Explicit], !T, !IO),

    % [LFAC.1.7.4] is require-all, so every slot of a `logical` schema carries
    % KEY or MUTABLE. Both wire values are non-zero, which is what stops
    % proto3's default omission from eating a KEY and emptying the identity.
    Logical = schema(make_schema_id(1u32), named(IT, "Sensor"),
        lc_logical([
            logical_slot(slot(IT, "entity_id", k_string, 0), role_key, exact),
            logical_slot(slot(IT, "state", k_float, 1), role_mutable,
                within(0.5))], no),
        no, no),
    check_trip("a `logical` schema keeps its roles and its tolerance",
        IT, [Logical], !T, !IO),

    % [RFCS.6.5]: an incoming `schema_name` is not re-normalized. A name not in
    % NFC, `Cafe` plus a combining acute, comes back as those bytes: found by
    % them and not by the composed `Café`. The compiler never emits one
    % ([LLEX.10.8.2]), so the case is built by hand.
    Decomposed = "Cafe\x301\",
    Composed = "Caf\xe9\",
    interns_of([Decomposed, "entity_id"], NfdIT),
    Nfd = schema(make_schema_id(1u32), named(NfdIT, Decomposed),
        lc_explicit([plain_slot(slot(NfdIT, "entity_id", k_string, 0))]),
        no, no),
    check_loaded("[RFCS.6.5] a non-NFC schema name loads as its own bytes",
        NfdIT, [Nfd],
        ( pred(P::in) is semidet :-
            slot_names(P, Decomposed) = ["entity_id"],
            not slot_names(P, Composed) = _
        ), !T, !IO),

    % `scope ambient` [LSCP.2.5] is a FLAG on logical, not a fourth lifecycle.
    Ambient = Logical ^ s_lifecycle :=
        lc_logical([logical_slot(slot(IT, "entity_id", k_string, 0),
            role_key, exact)], yes),
    check_trip("[LSCP.2.5] `ambient` survives as a flag on logical",
        IT, [Ambient], !T, !IO),

    Ttl = schema(make_schema_id(1u32), named(IT, "Reading"),
        lc_ttl([plain_slot(slot(IT, "state", k_float, 0))],
            duration_from_ns(3600000000000u64)),
        no, no),
    check_trip("a `ttl` schema keeps its ttl_ns", IT, [Ttl], !T, !IO),

    % ── the slot body ───────────────────────────────────────────────────────

    % Every `SlotKind` in [RDSC.5.5.2]'s enum, in one schema, with `k_schema`
    % last so its `schema_ref` (field 4) cannot mask a bug in the plain kinds.
    %
    % `slot_kind` has a `Bytes` constructor, so the encode covers it.
    %
    % `Other` is declared: the loader resolves a `schema_ref` only to a schema
    % the artefact declares, as a real bundle does.
    Other = schema(make_schema_id(1u32), named(IT, "Other"),
        lc_explicit([plain_slot(slot(IT, "entity_id", k_string, 0))]), no, no),
    Kinds = schema(make_schema_id(1u32), named(IT, "Reading"),
        lc_explicit([
            plain_slot(slot(IT, "entity_id", k_int, 0)),
            plain_slot(slot(IT, "state", k_float, 1)),
            plain_slot(slot(IT, "celsius", k_string, 2)),
            plain_slot(slot(IT, "flag", k_bool, 3)),
            plain_slot(slot(IT, "payload", k_json, 4)),
            plain_slot(slot(IT, "raw", k_bytes, 5)),
            plain_slot(slot(IT, "owner", k_schema(named(IT, "Other")), 6)),
            plain_slot(slot(IT, "seen", k_time, 7)),
            plain_slot(slot(IT, "due", k_date, 8)),
            plain_slot(slot(IT, "span", k_duration, 9))]),
        no, no),
    % RDSC.5.5.8: the temporal kinds come back as themselves, not as `k_int`.
    check_trip("[RDSC.5.5.4] RDSC.5.5.8 all ten slot kinds round-trip",
        IT, [Kinds, Other], !T, !IO),

    % Fields 5, 6 and 11, all `bool`, set together: separate cases would pass
    % with the numbers permuted.
    Flags = schema(make_schema_id(1u32), named(IT, "Reading"),
        lc_explicit([plain_slot(slot_common(ref(IT, "state"), k_float,
            det_slot_index(0), nullable, yes, yes, no, unbounded, no))]), no, no),
    check_trip("`sampled`, `retained` and `nullable` all survive together",
        IT, [Flags], !T, !IO),

    % [RDSC.5.6]: Hydration is its own atom, after the Slots it names; the
    % loader answers a forward reference with `DS_ERR_DSC_DANGLING`.
    Hydr = schema(make_schema_id(1u32), named(IT, "Reading"),
        lc_explicit([
            plain_slot(slot(IT, "entity_id", k_string, 0)),
            plain_slot(slot_common(ref(IT, "state"), k_float,
                det_slot_index(1), non_null, no, no, yes, unbounded, no))]), no, no),
    check_trip("[RDSC.5.6.3] a hydratable slot keeps its Hydration",
        IT, [Hydr], !T, !IO),

    % ── order, which is semantic ────────────────────────────────────────────

    % [RFCS.5.1]: the slot index is position, not a field. The names are in an
    % order no sort produces, so a reordering shows.
    Ordered = schema(make_schema_id(1u32), named(IT, "Reading"),
        lc_explicit([
            plain_slot(slot(IT, "state", k_float, 0)),
            plain_slot(slot(IT, "entity_id", k_string, 1)),
            plain_slot(slot(IT, "celsius", k_int, 2))]), no, no),
    check_trip("[RFCS.5.1] slot order is the slot numbering",
        IT, [Ordered], !T, !IO),

    % Two schemas, two lifecycles: a Slot attributed to the wrong schema shows.
    TtlSensor = Ttl ^ s_name := named(IT, "Sensor"),
    check_trip("two schemas in one artefact keep their own slots",
        IT, [Explicit, TtlSensor], !T, !IO),

    % ── what the loader assigns, rather than what the wire carried ──────────

    % `schema_id` is the loader's, 1..n in arrival order; no field carries the
    % compiler's.
    LoudId = Explicit ^ s_id := make_schema_id(77u32),
    LoudId2 = TtlSensor ^ s_id := make_schema_id(9u32),
    check_loaded("schema ids are assigned by the loader, 1..n",
        IT, [LoudId, LoudId2],
        ( pred(P::in) is semidet :-
            author_schemas(P) = [A, B],
            schema_id_value(A ^ s_id) = 1u32,
            schema_id_value(B ^ s_id) = 2u32
        ), !T, !IO),

    % `s_module` stays `no` and `s_proto` does not: the loader skips field 10,
    % the module id, and decodes SchemaDef.
    check_loaded("a SchemaDef round-trips as the schema's proto_source",
        IT, [Explicit],
        ( pred(P::in) is semidet :-
            author_schemas(P) = [A],
            A ^ s_module = no,
            A ^ s_proto = yes(_)
        ), !T, !IO),

    % ── the atom census, which is the emission grammar ──────────────────────

    % [RDSC.8.1]: `module_group ::= DsSource schema_group* ...` and
    % `schema_group ::= lifecycle_atom Slot* Hydration* SchemaSource SchemaDef`, so the module's
    % DsSource opens its group and the schema atoms follow. `ds.dsc.atoms` is
    % encounter order, which no shape comparison pins. CapabilityInfo is in
    % every artefact, after DialectInfo ([RDSC.16.2.4]).
    check_loaded("[RDSC.8.1] DscHeader, DialectInfo, CapabilityInfo, DsSource, "
            ++ "lifecycle, Slots, Hydration, "
            ++ "then SchemaDef",
        IT, [Hydr],
        ( pred(P::in) is semidet :-
            atoms(P) = [at_dsc_header, at_dialect_info, at_capability_info, at_ds_source, at_schema_logical, at_slot,
                at_slot, at_hydration, at_schema_def]
        ), !T, !IO),

    check_loaded("[RDSC.8.1] a `ttl` schema emits SchemaTtl and not SchemaLogical",
        IT, [Ttl],
        ( pred(P::in) is semidet :-
            atoms(P) = [at_dsc_header, at_dialect_info, at_capability_info, at_ds_source, at_schema_ttl, at_slot,
                at_schema_def]
        ), !T, !IO),

    % Nothing emitted is skipped: a loader steps over only the atoms
    % [RDSC.9.4] names, and this artefact carries none of them.
    check_loaded("no atom this encoder emits is one a loader skips",
        IT, [Hydr],
        ( pred(P::in) is semidet :-
            skips(P) = []
        ), !T, !IO),

    % ── the header ──────────────────────────────────────────────────────────

    % [RDSC.3.6], by two independent methods: the runtime locates the stored
    % hash, zeroes it and re-hashes; the encoder hashes over zeroes and
    % re-emits the header. `ds.sha256` is shared, so this tests what is hashed,
    % not the digest, which the published vectors pin.
    rdsc_1_1_encode(builtin_binding("default", []), IT, [Logical], [],
        [module_source(1u32, "<in-memory:main.ds>", "")], [], [], 1u32, no_rules, no,
        HashBytes),
    load_dsc(from_bytes(HashBytes), HashLoad),
    ( if
        HashLoad = loaded(HashProgram),
        verify_self_hash(from_bytes(HashBytes), header(HashProgram))
    then
        HashOk = yes
    else
        HashOk = no
    ),
    check("[RDSC.3.6] the runtime verifies the artefact's own dsc_sha256",
        HashOk, !T, !IO),

    % [LDET.1.10]: the loader accepts iff `compiler_version` begins with its
    % own `<major>.<minor>.`; an empty stamp is a mismatch.
    check_loaded("[LDET.1.10] compiler_version is in the loader's series",
        IT, [Explicit],
        ( pred(P::in) is semidet :-
            string.prefix(header(P) ^ dh_compiler_version, ds_version_series)
        ), !T, !IO),

    % [RDSC.3.6]: 32 bytes, present.
    check_loaded("[RDSC.3.6] dsc_sha256 is 32 bytes",
        IT, [Explicit],
        ( pred(P::in) is semidet :-
            list.length(header(P) ^ dh_sha256) = 32
        ), !T, !IO),

    % [RDSC.3.8]: `rt_config_sha256` is empty on a non-`+realtime` artefact;
    % absent and empty are one thing under protobuf.
    check_loaded("[RDSC.3.8] rt_config_sha256 is empty without +realtime",
        IT, [Explicit],
        ( pred(P::in) is semidet :-
            header(P) ^ dh_rt_config_sha = []
        ), !T, !IO),

    % RDSC.3.10: "`0` where the network has no site". No rules, no nodes.
    check_loaded("[RDSC.3.10] a program with no site carries 0",
        IT, [Explicit],
        ( pred(P::in) is semidet :-
            header(P) ^ dh_fault_fact_sites = 0u32
        ), !T, !IO),

    % The count of the network the loader resolved, by the shared definition;
    % not 0 for a join test that divides, so writer and reader cannot agree on
    % an unwritten field 14.
    DivideSrc =
        "schema S scope logical:\n    k: Int key\n    a: Int mutable\n"
            ++ "    b: Int mutable\n\n"
            ++ "rule divide:\n    S s where s.a // s.b > 1\n->\n"
            ++ "    log info \"big\"\n",
    check_source_loaded("[RDSC.3.10] the header carries the network's sites",
        DivideSrc,
        ( pred(P::in) is semidet :-
            Sites = header(P) ^ dh_fault_fact_sites,
            Sites \= 0u32,
            Sites = uint32.det_from_int(
                lerr_9_10_fault_fact_sites(network(P), interns(P)))
        ), !T, !IO),

    % [LERR.9.6]: a handler's terminal and chain are never sites. Compared
    % across two compiles, not against a number.
    HandlerSrc = DivideSrc
        ++ "\nrule handler:\n    ComputationError e\n->\n"
        ++ "    log info \"handled {e.kind}\"\n",
    ( if
        compiled_sites(DivideSrc, Without),
        compiled_sites(HandlerSrc, With)
    then
        HandlerOk = ( if With = Without then yes else no )
    else
        HandlerOk = no
    ),
    check("[LERR.9.6] a handler adds no fault-fact site", HandlerOk, !T, !IO),

    % ── the binding tuple and CapabilityInfo -- [RBND.1.3], [RDSC.16.2] ──────────────

    % [RBND.1.3]: the header's `capabilities`, ascending; the loader keeps
    % arrival order, so the order is the encoder's.
    Chosen = set.list_to_set([cap_call, cap_regex, cap_logical]),
    ChosenRequires = set.make_singleton_set(cap_call),
    ChosenTrip = round_trip_as(
        binding(program_settings("chosen", Chosen, map.init), ChosenRequires),
        IT, [Explicit]),
    ( if
        ChosenTrip = trip_ok(CP),
        header(CP) ^ dh_capabilities = [4, 6, 8]
    then
        HeaderCapsOk = yes
    else
        HeaderCapsOk = no
    ),
    check("[RBND.1.3] the header carries the settings, ascending",
        HeaderCapsOk, !T, !IO),

    % [RDSC.16.2.2]: CapabilityInfo's `enabled` is the settings and `requires` what the
    % content needs, both read back through the loader's own decode.
    ( if
        ChosenTrip = trip_ok(CP2),
        capb_of(CP2) = capb(Chosen, ChosenRequires)
    then
        CapbOk = yes
    else
        CapbOk = no
    ),
    check("[RDSC.16.2.2] CapabilityInfo carries `enabled` and `requires`",
        CapbOk, !T, !IO),

    % [RDSC.16.2.8]: `requires` is computed from content, "whatever the
    % settings", and a runtime trusts it. A `Float` slot needs `float` whether
    % or not a rule reads it.
    check_source_loaded(
        "[RDSC.16.2.8] a Float slot no rule reads puts `float` in `requires`",
        "schema Reading scope logical:\n    id: String key\n"
            ++ "    level: Float mutable\n\n"
            ++ "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule r:\n    Trig\n->\n    log info \"x\"\n",
        ( pred(P::in) is semidet :-
            carries_float_slot(P),
            requires_float(P)
        ), !T, !IO),
    % The control: `default` enables `float`, so a compiler listing every
    % enabled capability passes the case above. Here the content has none.
    check_source_loaded(
        "[RDSC.16.2.8] ...and with the slot `Int`, `float` is not required",
        "schema Reading scope logical:\n    id: String key\n"
            ++ "    level: Int mutable\n\n"
            ++ "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule r:\n    Trig\n->\n    log info \"x\"\n",
        ( pred(P::in) is semidet :-
            not carries_float_slot(P),
            not requires_float(P)
        ), !T, !IO),
    % An injected schema is content too: [LIMP.12.2] writes
    % `HydrationComplete`, with its two Float slots ([LHYD.5.1]), because the
    % rule names it. Both halves are asserted, so it cannot pass without the
    % schema.
    check_source_loaded(
        "[RDSC.16.2.8] an injected schema's Float slot is in `requires`",
        "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule r:\n    HydrationComplete hc where hc.count > 0\n->\n"
            ++ "    log info \"x\"\n",
        ( pred(P::in) is semidet :-
            carries_float_slot(P),
            requires_float(P)
        ), !T, !IO),

    % [RBND.4.2]: `dialect_def_sha256` digests the settings, so two settings
    % give two digests -- and each is 32 bytes, since every program has
    % settings.
    ( if
        ChosenTrip = trip_ok(CP3),
        round_trip(IT, [Explicit]) = trip_ok(DP),
        list.length(header(CP3) ^ dh_dialect_sha) = 32,
        list.length(header(DP) ^ dh_dialect_sha) = 32,
        header(CP3) ^ dh_dialect_sha \= header(DP) ^ dh_dialect_sha
    then
        DialectShaOk = yes
    else
        DialectShaOk = no
    ),
    check("[RBND.4.2] dialect_def_sha256 digests the settings",
        DialectShaOk, !T, !IO),

    % `requires ⊆ enabled` is the loader's check ([RDSC.16.2.3]); an encoder
    % handed the wrong pair writes it, and the refusal is seen to fire.
    Outside = round_trip_as(
        binding(program_settings("thin", set.make_singleton_set(cap_regex),
            map.init), set.make_singleton_set(cap_call)),
        IT, [Explicit]),
    ( if
        Outside = trip_failed(OutsideErr),
        OutsideErr ^ le_kind = lek_semantic
    then
        OutsideOk = yes
    else
        OutsideOk = no
    ),
    check("[RDSC.16.2.3] `requires` outside `enabled` is refused",
        OutsideOk, !T, !IO),

    % [RDSC.16.2.1]: `realtime` is read from CapabilityInfo. No
    % RealtimeContract is emitted, so the refusal shows the setting was read.
    Realtime = round_trip_as(
        builtin_binding("realtime", [cap_realtime, cap_constspace]),
        IT, [Explicit]),
    ( if
        Realtime = trip_failed(RtErr),
        RtErr ^ le_kind = lek_contract_missing
    then
        RtOk = yes
    else
        RtOk = no
    ),
    check("[RTCT.6.3] a `realtime` bundle with no RealtimeContract is refused",
        RtOk, !T, !IO),

    % ── the refusals the encoder must not paper over ────────────────────────

    % [RDSC.5.3.3]: a zero `ttl_ns` is a producer defect the compiler refuses
    % upstream ([LGRA.5.2]); the loader does not check it. The SchemaTtl atom
    % stays, so its facts expire at once. The encoder does not rewrite it.
    ZeroTtl = Ttl ^ s_lifecycle :=
        lc_ttl([plain_slot(slot(IT, "state", k_float, 0))],
            duration_from_ns(0u64)),
    check_loaded("[RDSC.5.3.3] a zero ttl_ns comes back as a zero ttl, not `no TTL`",
        IT, [ZeroTtl],
        ( pred(P::in) is semidet :-
            author_schemas(P) = [Z],
            Z ^ s_lifecycle = lc_ttl(_, D),
            D = duration_from_ns(0u64)
        ), !T, !IO),

    % [RLOW.3.7.8]: `tolerance 0` is exact equality, so the loader reads zero
    % as `exact`. Not the identity, and pinned.
    ZeroTol = schema(make_schema_id(1u32), named(IT, "Sensor"),
        lc_logical([logical_slot(slot(IT, "state", k_float, 0),
            role_mutable, within(0.0))], no), no, no),
    check_loaded("[RLOW.3.7.8] `within(0.0)` comes back as `exact`",
        IT, [ZeroTol],
        ( pred(P::in) is semidet :-
            author_schemas(P) = [Z],
            Z ^ s_lifecycle = lc_logical([ZS], _),
            ZS ^ ls_tolerance = exact
        ), !T, !IO),

    source_cases(!T, !IO).

%-----------------------------------------------------------------------------%
% From source
%-----------------------------------------------------------------------------%
%
% The cases above start at a `schema` built by hand; these start at source
% text, so they assert what the front end actually produces.

:- pred source_cases(tally::in, tally::out, io::di, io::uo) is det.

source_cases(!T, !IO) :-
    % [LSCP.1.4]: a bare `schema Foo:` is `scope explicit`, applied by `build`
    % and carried through `lower` without anyone restating the default.
    check_source("a bare `schema` compiles to an explicit schema",
        "schema Reading:\n" ++
        "    entity_id: String\n" ++
        "    state: Float\n",
        [schema_shape("Reading", "explicit",
            [src_slot("entity_id", "String", 0, "!", "-", "-"),
             src_slot("state", "Float", 1, "!", "-", "-")])],
        !T, !IO),

    % [LGRA.5.10]'s require-all and [LGRA.5.9]'s tolerance, from the spelling an
    % author writes -- markers before the tolerance, per [LGRA.5.1]'s
    % `field_type NULLABLE? slot_marker* field_tolerance?`.
    check_source("`key` / `mutable` and a tolerance survive from source",
        "schema Sensor scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    state: Float mutable tolerance 0.5\n",
        % A logical slot always has a tolerance; undeclared it is `exact`
        % ([LGRA.5.9.9]). `-` would mean a slot with no identity.
        [schema_shape("Sensor", "logical",
            [src_slot("entity_id", "String", 0, "!", "key", "exact"),
             src_slot("state", "Float", 1, "!", "mutable", "0.5")])],
        !T, !IO),

    % Both slots are unit-typed and their wire kinds differ, because their
    % dimensions declare different storage ([LUNI.7.1]): `Int` for an `int64`
    % dimension. Made `Float`, it would still load.
    check_source("[LUNI.7.1] a unit slot takes its dimension's declared storage",
        "unit dimension warmth storage float64 base therm\n" ++
        "unit therm: warmth\n" ++
        "unit celsius: warmth = x + 273.15\n" ++
        "unit dimension currency_usd storage int64 base usd\n" ++
        "unit usd: currency_usd\n" ++
        "\n" ++
        "schema Reading:\n" ++
        "    temp: celsius\n" ++
        "    price: usd\n",
        [schema_shape("Reading", "explicit",
            [src_slot("temp", "Float", 0, "!", "-", "-"),
             src_slot("price", "Int", 1, "!", "-", "-")])],
        !T, !IO),

    % [LNUL.3.1]'s `T?` and [LGRA.5.1]'s `retained`, together, as above.
    % `sampled` is never set from source.
    check_source("`T?` and `retained` both arrive from source",
        "schema Reading:\n" ++
        "    state: Float? retained\n",
        [schema_shape("Reading", "explicit",
            [slot_shape("state", "Float", 0, "?", no, yes, no, "-", "-")])],
        !T, !IO),

    % A fact-pointer slot: the type name resolves to another schema in the unit,
    % and [RDSC.5.5.5]'s `schema_ref` carries the NAME rather than an id.
    check_source("[RDSC.5.5.5] a schema-typed slot becomes a fact pointer",
        "schema Other:\n" ++
        "    entity_id: String\n" ++
        "\n" ++
        "schema Reading:\n" ++
        "    owner: Other\n",
        [schema_shape("Other", "explicit",
            [src_slot("entity_id", "String", 0, "!", "-", "-")]),
         schema_shape("Reading", "explicit",
            [src_slot("owner", "->Other", 0, "!", "-", "-")])],
        !T, !IO),

    % [LLEX.12.1], [LUNI.3.1.1]: the separator is optional, so the two
    % spellings compile to the same artefact.
    Bare = compiled_bytes("schema R scope ttl 30s:\n    state: Float\n"),
    Separated = compiled_bytes("schema R scope ttl 30_s:\n    state: Float\n"),
    % Without DsSource, which carries the source text ([RDSC.14.2.1]), and the
    % header, whose `dsc_sha256` digests it.
    ( if
        Bare = yes(B), Separated = yes(Sp),
        without_source(B) = without_source(Sp)
    then
        SepOk = yes
    else
        SepOk = no
    ),
    check("[LLEX.12.1] `30s` and `30_s` compile to the same artefact",
        SepOk, !T, !IO),

    % ── [RDSC.4.7]: every per-module atom carries a `module_id` ──────────────
    %
    % A file with no imports is one module, so everything it emits is `1`.
    % `module_id = 0` is the reserved unset sentinel, so a missing field and a
    % zero read alike here and either would fail this.
    OneModule = compiled_bytes(
        "schema Trig scope logical:\n    id: String key\n\n"
            ++ "schema Out scope ttl 1_h:\n    v: Int\n\n"
            ++ "rule r cooldown 5_s:\n    Trig t\n->\n"
            ++ "    emit Out v: len(t.id)\n"),
    % The two fault schemas ([LERR.9.4]) and `TimeZoneOffset` ([LIMP.12.2])
    % are the file's too: three more `SchemaLogical`s, fourteen more `Slot`s.
    ( if OneModule = yes(Single) then
        SingleOk = ( if
            clips_of(Single, at_schema_logical) = [1u32, 1u32, 1u32, 1u32],
            clips_of(Single, at_schema_ttl) = [1u32],
            clips_of(Single, at_slot) = list.duplicate(16, 1u32),
            clips_of(Single, at_rule_source) = [1u32],
            clips_of(Single, at_rule_cooldown) = [1u32]
        then yes else no )
    else
        SingleOk = no
    ),
    show_clips_on_failure(SingleOk, OneModule, !IO),
    check("[RDSC.4.7] a file with no imports emits `module_id` 1 throughout",
        SingleOk, !T, !IO),

    % The library is another module: leaves first ([RDSC.8.1.1]), so the
    % imported schema's atoms say `1` and the file's own `2`.
    TwoModules = compiled_lib_bytes(
        ["shared" - "schema Reading scope logical:\n    id: String key\n"],
        "from shared import Reading\n\n"
            ++ "schema Out scope ttl 1_h:\n    v: Int\n\n"
            ++ "rule r:\n    Reading x\n->\n    emit Out v: len(x.id)\n"),
    ( if TwoModules = yes(Two) then
        % The injected schemas are the importing file's (`2`): one copy per
        % artefact.
        TwoOk = ( if
            clips_of(Two, at_schema_logical) = [1u32, 2u32, 2u32, 2u32],
            clips_of(Two, at_schema_ttl) = [2u32],
            clips_of(Two, at_slot) = [1u32 | list.duplicate(15, 2u32)],
            clips_of(Two, at_rule_source) = [2u32]
        then yes else no )
    else
        TwoOk = no
    ),
    show_clips_on_failure(TwoOk, TwoModules, !IO),
    check("[RDSC.4.7] an imported schema's atoms carry the library's module",
        TwoOk, !T, !IO),

    % ── [RDSC.14.2]: one DsSource per source module, carrying its text ─────────
    %
    % [RDSC.14.2.4]: "At least one DsSource atom is required (the importing file).
    % When the importing file imports libraries, additional DsSource atoms cover
    % each transitively-loaded library." [RDSC.14.2.5] allows at most one per
    % `module_id`, which is what the count checks.
    OneSource = "schema Trig scope logical:\n    id: String key\n",
    ( if compiled_bytes(OneSource) = yes(Only) then
        OnlyOk = ( if
            dsrc_atoms(Only) = [{1u32, "<in-memory:main.ds>", OneSource}]
        then yes else no )
    else
        OnlyOk = no
    ),
    check("[RDSC.14.2.1] the file's DsSource carries its text verbatim",
        OnlyOk, !T, !IO),

    % The library's text is its own, labelled in [RDSC.14.2.3]'s in-memory
    % form, since these imports come from a map.
    LibSource = "schema Reading scope logical:\n    id: String key\n",
    ImporterSource = "from shared import Reading\n\n"
        ++ "schema Out scope ttl 1_h:\n    v: Int\n\n"
        ++ "rule r:\n    Reading x\n->\n    emit Out v: len(x.id)\n",
    ( if
        compiled_lib_bytes(["shared" - LibSource], ImporterSource) = yes(Pair)
    then
        PairOk = ( if
            dsrc_atoms(Pair) = [{1u32, "<in-memory:shared.ds>", LibSource},
                {2u32, "<in-memory:main.ds>", ImporterSource}]
        then yes else no )
    else
        PairOk = no
    ),
    check("[RDSC.14.2.4] an imported library gets its own DsSource, leaves first",
        PairOk, !T, !IO),

    % [RDSC.14.2.3]: `file` is "the original `.ds` source path (a real path for
    % disk-resolved libraries ...)". A caller that read the modules from disk
    % supplies the paths, and the atoms carry them as given.
    ( if
        compiled_labelled_bytes(["shared" - LibSource],
            source_labels("rules/main.ds",
                map.singleton("shared", "lib/shared.ds"), map.init,
                no_companions),
            ImporterSource) = yes(Labelled)
    then
        LabelledOk = ( if
            dsrc_atoms(Labelled) = [{1u32, "lib/shared.ds", LibSource},
                {2u32, "rules/main.ds", ImporterSource}]
        then yes else no )
    else
        LabelledOk = no
    ),
    check("[RDSC.14.2.3] each DsSource names the path its module was read from",
        LabelledOk, !T, !IO),

    % [LIMP.3.1.3]: two distinct files for one name refuse the import that
    % resolves it, naming both. On a name nothing imports it refuses nothing.
    Ambiguous = map.singleton("shared", ["lib1/shared.ds", "lib2/shared.ds"]),
    compile_labelled(as_though("default"),
        yes(map.from_assoc_list(["shared" - LibSource])), dsrt_absent,
        source_labels("rules/main.ds", map.init, Ambiguous, no_companions),
        ImporterSource,
        AmbiguousRes),
    AmbiguousOk = ( if
        AmbiguousRes = compile_rejected(AmbiguousDs),
        list.member(AmbiguousD, AmbiguousDs),
        AmbiguousD ^ dg_code = dc_validate(dv_ambiguous_library),
        string.sub_string_search(AmbiguousD ^ dg_message, "lib1/shared.ds", _),
        string.sub_string_search(AmbiguousD ^ dg_message, "lib2/shared.ds", _)
    then yes else no ),
    check("[LIMP.3.1.3] an import of an ambiguous library is refused, naming both",
        AmbiguousOk, !T, !IO),

    UnusedOk = ( if
        compiled_labelled_bytes(["shared" - LibSource],
            source_labels("rules/main.ds", map.init,
                map.singleton("other", ["lib1/other.ds", "lib2/other.ds"]),
                no_companions),
            ImporterSource) = yes(_)
    then yes else no ),
    check("[LIMP.3.1.3] an ambiguous name nothing imports refuses nothing",
        UnusedOk, !T, !IO),

    % ── [RDSC.5.7]: one SchemaSource per schema, where it was declared ─────────────
    %
    % [RDSC.5.7.3]: "`line` and `col` are 1-indexed". `Second` is declared on
    % line 4 of this source, so a 0-indexed count or an off-by-one shows here.
    TwoSchemas = compiled_bytes(
        "schema First scope logical:\n    id: String key\n\n"
            ++ "schema Second scope ttl 1_h:\n    v: Int\n"),
    ( if TwoSchemas = yes(Pair2) then
        SrcsOk = ( if
            srcs_atoms(Pair2) = [{"First", 1u32, 1u32, 1u32},
                {"Second", 4u32, 1u32, 1u32}]
        then yes else no )
    else
        SrcsOk = no
    ),
    show_srcs_on_failure(SrcsOk, TwoSchemas, !IO),
    check("[RDSC.5.7.1] each schema's SchemaSource gives its 1-indexed declaration",
        SrcsOk, !T, !IO),

    % A library's schema is attributed to the library: [RDSC.4.7] takes the
    % path from `DsSource[module_id]`.
    ( if
        compiled_lib_bytes(["shared" - LibSource], ImporterSource) = yes(Pair3)
    then
        SrcsLibOk = ( if
            srcs_atoms(Pair3) = [{"shared.Reading", 1u32, 1u32, 1u32},
                {"Out", 3u32, 1u32, 2u32}]
        then yes else no )
    else
        SrcsLibOk = no
    ),
    show_srcs_on_failure(SrcsLibOk,
        compiled_lib_bytes(["shared" - LibSource], ImporterSource), !IO),
    check("[RDSC.5.7.1] an imported schema's SchemaSource carries the library's module",
        SrcsLibOk, !T, !IO),

    % [LCCO.10.1]: a depth-two continuation, legal under [LCCO.10.2]'s cap.
    DepthTwo =
        ok_services
            ++ "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule outer:\n"
            ++ "    Trig\n"
            ++ "->\n"
            ++ "    call weather.get_forecast entity_id: \"w\" cooldown: 1_h as \"fc\"\n"
            ++ "        on response.ok:\n"
            ++ "            call switch.turn_on entity_id: \"s\" cooldown: 1_h as \"sw\"\n"
            ++ "                on response.ok:\n"
            ++ "                    log info \"inner fired\"\n",
    % Nothing is reported: the rule lowers, and a `service` is never an
    % unlowered declaration.
    check_unlowered("[LCCO.10.1] a depth-two continuation lowers",
        DepthTwo, [], !T, !IO),

    % Flat, as the clause has it: three terminals, the outer rule and each
    % call's `on`.
    check_source_loaded("[LCCO.10.1] the inner `on` is a sibling of its own",
        DepthTwo,
        ( pred(P::in) is semidet :-
            list.length(terminal_nodes(network(P))) = 3
        ), !T, !IO),

    % [LCCO.10.3]: an inner continuation reading an outer LHS binding joins the
    % outer capture fact "in addition to the inner capture fact".
    DepthTwoOuterRef =
        ok_services
            ++ "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule outer:\n"
            ++ "    Trig t\n"
            ++ "->\n"
            ++ "    call weather.get_forecast entity_id: \"w\" cooldown: 1_h as \"fc\"\n"
            ++ "        on response.ok:\n"
            ++ "            call switch.turn_on entity_id: \"s\" cooldown: 1_h as \"sw\"\n"
            ++ "                on response.ok:\n"
            ++ "                    log info \"v={t.v}\"\n",
    % `{t.v}` reads the rule's binding across two call boundaries. Loading it
    % checks the join meets a declared schema ([RDSC.8.7]).
    check_unlowered("[LCCO.10.3] an inner continuation reading an outer "
            ++ "binding lowers",
        DepthTwoOuterRef, [], !T, !IO),

    % "In addition to the inner capture fact": the sibling that makes the
    % inner call asserts `$CaptureBindings_$outer_response_0_c0`, with `corr`
    % the inner call's literal `as` and `t_v` copied from the OUTER capture
    % fact's view at token position 1. It does so before it releases that
    % outer capture, its last action ([LCCO.5.0]). The schema is declared,
    % `t_v` typed as `Trig.v` is.
    check_source_loaded("[LCCO.10.3] the inner capture fact is declared and "
            ++ "asserted from the outer one",
        DepthTwoOuterRef,
        ( pred(P::in) is semidet :-
            schema_called(P, "$CaptureBindings_$outer_response_0_c0", Inner),
            [_, InnerSlot] = slot_commons(Inner),
            expand(interns(P), InnerSlot ^ sc_name, "t_v"),
            InnerSlot ^ sc_kind = k_int,
            [_, OnSib, InnerSib] = terminal_nodes(network(P)),
            expand(interns(P), OnSib ^ tn_rule, "$outer_response_0"),
            expand(interns(P), InnerSib ^ tn_rule,
                "$$outer_response_0_response_0"),
            list.append(_, [InnerAssert, Release], OnSib ^ tn_inline_actions),
            InnerAssert = ia_assert(plain, InnerRef, [CorrSet, VSet], yes(_)),
            CorrSet = slot_assign(_, e_lit(str(Corr))),
            VSet = slot_assign(_, e_slot(token_fact(1), slot(_))),
            Release = ia_internal(fn_retract_token_fact, [e_lit(int(1i64))]),
            expand(interns(P), InnerRef,
                "$CaptureBindings_$outer_response_0_c0"),
            expand(interns(P), Corr, "sw")
        ), !T, !IO),

    % [LCCO.7.2] one level in: the sibling that makes the inner call asserts
    % its timer, `$Timer_$outer_response_0_timeout_0`, corr `sw`, and both it
    % and `$ClockTick` are declared.
    DepthTwoTimeout =
        ok_services
            ++ "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule outer:\n"
            ++ "    Trig\n"
            ++ "->\n"
            ++ "    call weather.get_forecast entity_id: \"w\" cooldown: 1_h as \"fc\"\n"
            ++ "        on response.ok:\n"
            ++ "            call switch.turn_on entity_id: \"s\" cooldown: 1_h as \"sw\"\n"
            ++ "                timeout 5_s:\n"
            ++ "                    log info \"late\"\n",
    check_unlowered("[LCCO.7.2] an inner call's `timeout` lowers",
        DepthTwoTimeout, [], !T, !IO),
    check_source_loaded("[LCCO.7.2] an inner call's timeout timer is declared "
            ++ "and asserted by the sibling that makes the call",
        DepthTwoTimeout,
        ( pred(P::in) is semidet :-
            schema_called(P, "$ClockTick", _),
            schema_called(P, "$Timer_$outer_response_0_timeout_0", _),
            % [LCCO.7.6]: the timeout's two discharge rules follow its sibling.
            [_, OnSib, TimeoutSib, Answered, Failed] = terminal_nodes(network(P)),
            expand(interns(P), TimeoutSib ^ tn_rule,
                "$$outer_response_0_timeout_0"),
            expand(interns(P), Answered ^ tn_rule,
                "$$outer_response_0_timeout_0_answered"),
            expand(interns(P), Failed ^ tn_rule,
                "$$outer_response_0_timeout_0_failed"),
            list.member(TimerAssert, OnSib ^ tn_inline_actions),
            TimerAssert = ia_assert(plain, TimerRef, [_, CorrSet], no),
            CorrSet = slot_assign(_, e_lit(str(Corr))),
            expand(interns(P), TimerRef, "$Timer_$outer_response_0_timeout_0"),
            expand(interns(P), Corr, "sw")
        ), !T, !IO),

    % [LTAC.6.1.3]: a `call` with continuations inside an `after`, depth two
    % and legal.
    AfterCall =
        ok_services
            ++ "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule outer:\n"
            ++ "    Trig\n"
            ++ "->\n"
            ++ "    after 5_s:\n"
            ++ "        call switch.turn_on entity_id: \"s\" cooldown: 1_h as \"sw\"\n"
            ++ "            on response.ok:\n"
            ++ "                log info \"inner fired\"\n",
    check_unlowered("[LTAC.6.1.3] a call with continuations inside an `after`",
        AfterCall, [], !T, !IO),

    % ── [LNAM.2.8.1]: schema names are NFC on the wire ────────────────────
    %
    % "The compiler must emit schema names in NFC on every wire and on-disk
    % encoding ... A producer and consumer that disagree on the normalized
    % form of a schema name does not decode a fact body ([LNAM.7.1])."
    %
    % Discharged lexically: `llex_10_4_scan_ident` emits the NFC form, so no
    % emission site can get it wrong.
    %
    % A decomposed sequence, `e` + U+0301, which is Allowed ([LNAM.2.2.1]) and
    % normalises to U+00E9; a compatibility character is refused before it
    % could show anything. Built from code points, since a literal would look
    % the same as its normal form.
    Acute = string.from_char_list([char.det_from_int(0x0301)]),
    EAcute = string.from_char_list([char.det_from_int(0x00E9)]),
    check_source_loaded("[LNAM.2.8.1] a schema name reaches the wire in NFC",
        "schema Caf" ++ "e" ++ Acute ++ " scope logical:\n    id: String key\n",
        ( pred(P::in) is semidet :-
            author_schemas(P) = [S],
            expand(interns(P), schema_name_ref(S ^ s_name), "Caf" ++ EAcute)
        ), !T, !IO),
    % ── [LADP.8.2.1]: ServiceDef ────────────────────────────────────────────────
    SvcSource =
        "service light.turn_on:\n"
            ++ "    kwarg entity_id: String required\n"
            ++ "    kwarg brightness: Int\n"
            ++ "    no response\n\n"
            ++ "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule r:\n    Trig\n->\n"
            ++ "    call light.turn_on entity_id: \"x\" nocooldown\n",
    ( if compiled_bytes(SvcSource) = yes(SvcBytes) then
        SvcOk = ( if
            svcd_atoms(SvcBytes) = [{"light.turn_on", "", 1u32}]
        then yes else no )
    else
        SvcOk = no
    ),
    check("[LADP.8.2.1] a service declaration reaches the DSC as ServiceDef",
        SvcOk, !T, !IO),
    % [LGRA.23.2]: written `entity_id` then `brightness`, emitted sorted by
    % name; `no response` is field 5.
    ( if compiled_bytes(SvcSource) = yes(SortBytes) then
        SortOk = ( if
            svcd_kwarg_names(SortBytes) = ["brightness", "entity_id"],
            svcd_no_response(SortBytes) = yes
        then yes else no )
    else
        SortOk = no
    ),
    check("[LGRA.23.2] ServiceDef kwargs are sorted by name; `no response` is set",
        SortOk, !T, !IO),

    % [RDSC.6a.2.4]: every kwarg reaches the runtime's reader
    % whole, in `ds.service`'s type, its default as the canonical text of the
    % value the service receives: a negative Int, a Float written `1.50`, a
    % String with a quote and a backslash in it, a Bool. An Int literal on a
    % Float kwarg is the Float, `2.0`. `-10_celsius` on a `celsius` kwarg is
    % the quantity in that unit, a `float64` dimension's, so `-10.0`.
    %
    % @spec [RDSC.6a.2.4]
    KwSource =
        "unit dimension warmth storage float64 base therm\n"
            ++ "unit therm: warmth\n"
            ++ "unit celsius: warmth = x + 273.15\n\n"
            ++ "service lamp.set:\n"
            ++ "    kwarg room: String literal required\n"
            ++ "    kwarg level: Int default -3\n"
            ++ "    kwarg gain: Float default 1.50\n"
            ++ "    kwarg scale: Float default 2\n"
            ++ "    kwarg label: String default \"a\\\"b\\\\c\"\n"
            ++ "    kwarg enabled: Bool default true\n"
            ++ "    kwarg note: String\n"
            ++ "    kwarg t: celsius default -10_celsius\n"
            ++ "    no response\n\n"
            ++ "schema Trig scope logical:\n    v: Int key\n",
    check_source_loaded("[RDSC.6a.2.4] ServiceDef kwargs and their defaults round-trip",
        KwSource,
        ( pred(P::in) is semidet :-
            assoc_list.search(service_kwargs(P), "lamp.set", Got),
            Got = [
                service_kwarg("enabled", "Bool", no, no, default_text("true")),
                service_kwarg("gain", "Float", no, no, default_text("1.5")),
                service_kwarg("label", "String", no, no,
                    default_text("\"a\\\"b\\\\c\"")),
                service_kwarg("level", "Int", no, no, default_text("-3")),
                service_kwarg("note", "String", no, no, no_default),
                service_kwarg("room", "String", yes, yes, no_default),
                service_kwarg("scale", "Float", no, no, default_text("2.0")),
                service_kwarg("t", "celsius", no, no, default_text("-10.0"))]
        ), !T, !IO),

    % @spec [RDSC.6a.2.7]
    % test_rdsc_6a_2_7__a_schema_kwarg_holds_its_own_name: a schema's own name,
    % as the file declaring the service resolves it; anything else as declared.
    % Read back from the compiled ServiceDef, whose kwargs are sorted by name.
    % PATH: `service_kwarg_of`, and for a library's kwarg
    % `dsc.imports.limp_1_5_kwarg` first.
    Replies = ["a" - "schema Reply scope logical:\n    k: Int key\n",
        "b" - "schema Reply scope logical:\n    k: Int key\n    w: Int mutable\n"],
    KwargsOf = ( func(Libs, Source, Key) = Kwargs :-
        ( if
            compiled_lib_bytes(Libs, Source) = yes(KwargBytes),
            load_dsc(from_bytes(KwargBytes), loaded(KwargP)),
            assoc_list.search(service_kwargs(KwargP), Key, Kwargs0)
        then
            Kwargs = Kwargs0
        else
            Kwargs = []
        ) ),
    KwargOf = ( func(Libs, Source, Key) =
        list.map(( func(K) = K ^ sk_type ), KwargsOf(Libs, Source, Key)) ),
    Service = "service svc.x:\n    kwarg r: ",
    Rest = "\n    no response\n",
    check("[RDSC.6a.2.7] a kwarg typed through an alias holds the own name",
        ( if
            KwargOf(Replies, "from a import Reply as AR\n\n" ++ Service ++ "AR"
                ++ Rest, "svc.x") = ["a.Reply"]
          then yes else no ), !T, !IO),
    check("[RDSC.6a.2.7] a kwarg typed by an imported name holds the own name",
        ( if
            KwargOf(Replies, "from a import Reply\n\n" ++ Service ++ "Reply"
                ++ Rest, "svc.x") = ["a.Reply"]
          then yes else no ), !T, !IO),
    check("[RDSC.6a.2.7] a library's kwarg is its own file's schema, whatever "
            ++ "the importer binds that name to",
        ( if
            KwargOf(["c" - ("from a import Reply\n\n" ++ Service ++ "Reply"
                    ++ Rest) | Replies],
                "from b import Reply\nimport c\n", "svc.x") = ["a.Reply"]
          then yes else no ), !T, !IO),
    check("[RDSC.6a.2.7] a kwarg typed by a schema the file declares holds its "
            ++ "NAME",
        ( if
            KwargOf([], "schema Local scope logical:\n    k: Int key\n\n"
                ++ Service ++ "Local" ++ Rest, "svc.x") = ["Local"]
          then yes else no ), !T, !IO),
    check("[RDSC.6a.2.7] any other type is as declared",
        ( if
            KwargOf([],
                "unit dimension warmth storage float64 base therm\n"
                    ++ "unit therm: warmth\n\n"
                    ++ "service svc.x:\n    kwarg a: Int\n    kwarg b: therm\n"
                    ++ "    kwarg c: warmth\n    kwarg d: Schema\n"
                    ++ "    no response\n",
                "svc.x") = ["Int", "therm", "warmth", "Schema"]
          then yes else no ), !T, !IO),
    check("[RDSC.6a.2.7] a library's unit and opaque kwargs are as it declares "
            ++ "them",
        ( if
            KwargOf(["u" - ("unit dimension warmth storage float64 base therm\n"
                    ++ "unit therm: warmth\n\nopaque type Secret over Bytes\n\n"
                    ++ "service svc.x:\n    kwarg t: therm\n    kwarg s: Secret\n"
                    ++ "    no response\n")],
                "import u\n", "svc.x") = ["Secret", "therm"]
          then yes else no ), !T, !IO),
    check("[RDSC.6a.2.7] a library's opaque type under `as` is as it spells it",
        ( if
            KwargOf(["crypto" - "opaque type Key over Bytes\n",
                    "vault" - ("from crypto import Key as K\n\nservice svc.x:\n"
                        ++ "    kwarg s: K\n    no response\n")],
                "import vault\n", "svc.x") = ["K"]
          then yes else no ), !T, !IO),

    % @spec [LIMP.1.5]
    % test_limp_1_5__a_library_kwargs_default_resolves_in_its_library: `c`'s
    % `mark` is `x * 3`, and the program binds `mark` to `a`'s, at `x * 2`. PATH:
    % `dsc.imports.limp_1_5_kwarg`, and `service_kwarg_of` through
    % `dsc.resolve.kwarg_scope`. On a `mark` kwarg 5 marks are 5, and on a `warmth`
    % one 15 in the base unit, not 10.
    MarkLibs = ["a" - ("unit dimension warmth storage float64 base base_a\n"
            ++ "unit base_a: warmth\nunit mark: warmth = x * 2\n"),
        "c" - ("from a import warmth\n\nunit mark: warmth = x * 3\n\n"
            ++ "service svc.x:\n    kwarg d: warmth default 5_mark\n"
            ++ "    kwarg u: mark default 5_mark\n    no response\n")],
    check("[LIMP.1.5] a library kwarg's default resolves in that library",
        ( if
            KwargsOf(MarkLibs, "from a import mark\nimport c\n", "svc.x") = [
                service_kwarg("d", "warmth", no, no, default_text("15.0")),
                service_kwarg("u", "mark", no, no, default_text("5.0"))]
          then yes else no ), !T, !IO),

    % [RDSC.6a.2.4]'s two quantity rows, through `rdsc_6a_2_4_text`'s unit
    % arm, read back by the runtime's loader:
    % - a unit symbol is the quantity in that unit: `24_tick` on a `dozen`
    %   kwarg is `2`, decimal because `tally` declares `storage int64`, and
    %   `-10_celsius` on a `celsius` one is `-10.0`;
    % - a dimension is the quantity in its base unit: `-10_celsius` on a
    %   `warmth` kwarg is `263.15` therms, and `24_tick` on a `tally` one
    %   `24` ticks.
    % The negated literal negates its number, then converts ([LUNI.3.3]): a
    % fold that converted first would write `-556.3` and `-283.15`.
    %
    % The int64 dimension is `tally`, not `time`: `units.core`'s names may not
    % be redeclared ([LUNI.4.1.2], [LIMP.5.1.5]), and the rows are about
    % storage.
    %
    % @spec [RDSC.6a.2.4]
    QtySource =
        "unit dimension warmth storage float64 base therm\n"
            ++ "unit therm: warmth\n"
            ++ "unit celsius: warmth = x + 273.15\n"
            ++ "unit dimension tally storage int64 base tick\n"
            ++ "unit tick: tally\n"
            ++ "unit dozen: tally = x * 12\n\n"
            ++ "service oven.set:\n"
            ++ "    kwarg c: celsius default -10_celsius\n"
            ++ "    kwarg k: warmth default -10_celsius\n"
            ++ "    kwarg m: dozen default 24_tick\n"
            ++ "    kwarg w: tally default 24_tick\n"
            ++ "    no response\n\n"
            ++ "schema Trig scope logical:\n    v: Int key\n",
    check_source_loaded(
        "[RDSC.6a.2.4] a quantity default is the number the service receives",
        QtySource,
        ( pred(P::in) is semidet :-
            assoc_list.search(service_kwargs(P), "oven.set", Got),
            Got = [
                service_kwarg("c", "celsius", no, no, default_text("-10.0")),
                service_kwarg("k", "warmth", no, no,
                    default_text("263.15")),
                service_kwarg("m", "dozen", no, no, default_text("2")),
                service_kwarg("w", "tally", no, no, default_text("24"))]
        ), !T, !IO),

    % An imported service takes its library's `module_id` (`rf_service_origin`,
    % since `rf_services` is keyed by name, [LGRA.10.1.6]). The atom's name is
    % the dotted service path.
    ( if
        compiled_lib_bytes(
            ["ha" - ("service light.turn_on:\n"
                ++ "    kwarg entity_id: String required\n"
                ++ "    no response\n")],
            "from ha import light\n\n"
                ++ "schema Trig scope logical:\n    v: Int key\n\n"
                ++ "rule r:\n    Trig\n->\n"
                ++ "    call light.turn_on entity_id: \"x\" nocooldown\n")
            = yes(LibSvcBytes)
    then
        LibSvcOk = ( if
            svcd_atoms(LibSvcBytes) = [{"light.turn_on", "", 1u32}]
        then yes else no )
    else
        LibSvcOk = no
    ),
    check("[LADP.8.2.1] an imported service carries its library's `module_id`",
        LibSvcOk, !T, !IO),

    % [RDSC.6a.2.6]: one `ServiceDef` per service, none nameless. One
    % declaration reached by two import paths (`base` directly, and through
    % `mid`): the driver reads each library once. Read on the wire
    % (`svcd_atoms`, which sees a nameless atom too) and as the loader keeps it.
    %
    % @spec [RDSC.6a.2.6]
    TwoPathLibs = [
        "base" - ("schema Trig scope logical:\n    v: Int key\n\n"
            ++ "service svc.method:\n    \"\"\"the only one\"\"\"\n"
            ++ "    no response\n"),
        "mid" - ("from base import Trig\n\n"
            ++ "schema Mid scope logical:\n    k: Int key\n")],
    ( if
        compiled_lib_bytes(TwoPathLibs,
            "from base import Trig\nfrom mid import Mid\n") = yes(TwoPathBytes),
        svcd_atoms(TwoPathBytes) = [{"svc.method", _, _}],
        load_dsc(from_bytes(TwoPathBytes), loaded(TwoPathP)),
        declared_services(TwoPathP) = [TwoPathSvc],
        TwoPathSvc ^ sv_name = "svc.method"
    then
        TwoPathOk = yes
    else
        TwoPathOk = no
    ),
    check("[RDSC.6a.2.6] one service reached by two import paths is one "
        ++ "ServiceDef", TwoPathOk, !T, !IO),

    % ── [RDSC.8.7]: a test atom names its `TestCase` ──────────────────────
    %
    % "An `oracle_atom` and a `TestFact` name the `TestCase` test they belong
    % to." Pinned on the wire, over two tests, so a reference that always
    % named the first fails.
    TestSource =
        "schema Reading scope logical:\n    zone: String key\n"
            ++ "    celsius: Float mutable\n\n"
            ++ "schema Heater scope logical:\n    zone: String key\n\n"
            ++ "rule cold:\n    Reading r where r.celsius < 5.0\n->\n"
            ++ "    emit Heater logical zone: r.zone\n\n"
            ++ "test \"one\":\n    inputs:\n        at 0_s:\n"
            ++ "            Reading zone: \"a\" celsius: 1.0\n"
            ++ "    produces:\n        emitted Heater h where h.zone == \"a\"\n\n"
            ++ "test \"two\":\n    inputs:\n        at 0_s:\n"
            ++ "            Reading zone: \"b\" celsius: 1.0\n"
            ++ "    produces:\n        activated cold\n"
            ++ "        emitted Heater h where h.zone == \"b\"\n",
    ( if compiled_bytes(TestSource) = yes(TestBytes) then
        {Cases, Refs} = test_refs(TestBytes),
        TestRefsOk = ( if
            list.length(Cases) = 2,
            list.sort_and_remove_dups(Cases) = SortedCases,
            list.length(SortedCases) = 2,
            % 2 TestFacts + 3 oracle atoms.
            list.length(Refs) = 5,
            list.all_true(( pred(R::in) is semidet :- list.member(R, Cases) ),
                Refs),
            list.all_true(( pred(C::in) is semidet :- list.member(C, Refs) ),
                Cases)
        then yes else no )
    else
        TestRefsOk = no
    ),
    check("[RDSC.8.7] every TestFact and oracle atom names an emitted TestCase",
        TestRefsOk, !T, !IO),

    % ── [RDSC.14.3]: LineSpan ─────────────────────────────────────────────
    SpanSource =
        "schema Door scope logical:\n    id: String key\n\n"
            ++ "schema Motion scope logical:\n    id: String key\n\n"
            ++ "rule alert:\n"
            ++ "    Door\n"
            ++ "    Motion\n"
            ++ "->\n"
            ++ "    log info \"x\"\n",
    % Nodes 1 and 3, the alphas, carry no span ([RDSC.14.3.6]: a shared alpha
    % has no single source). 2 and 4 are the betas, at their patterns' lines;
    % 5 the terminal, at the `rule` line.
    ( if compiled_bytes(SpanSource) = yes(SpanBytes) then
        SpanOk = ( if
            span_atoms(SpanBytes) = [{2u32, 8u32, 5u32, 1u32},
                {4u32, 9u32, 5u32, 1u32}, {5u32, 7u32, 1u32, 1u32}]
        then yes else no )
    else
        SpanOk = no
    ),
    check("[RDSC.14.3.6] one LineSpan per beta and terminal, none per alpha",
        SpanOk, !T, !IO),

    % A synthetic node gets no LineSpan ([RDSC.14.3.4], [RDSC.14.3.5]): a
    % `then` sequence's tick betas add none to the three.
    ( if
        compiled_bytes(
            "schema DoorOpen scope ttl 1_h:\n    ts: Time\n    zone: String\n\n"
                ++ "schema Motion scope ttl 1_h:\n"
                ++ "    ts: Time\n    location: String\n\n"
                ++ "rule seq:\n"
                ++ "    DoorOpen d\n"
                ++ "    then Motion m within 30_s where m.location == d.zone\n"
                ++ "->\n"
                ++ "    log info \"seen at {d.zone}\"\n") = yes(SeqBytes)
    then
        SeqOk = ( if list.length(span_atoms(SeqBytes)) = 3 then yes else no )
    else
        SeqOk = no
    ),
    check("[RDSC.14.3.4] a synthetic tick beta carries no LineSpan",
        SeqOk, !T, !IO),

    % ── [RDSC.14.4]: DocString ────────────────────────────────────────────
    %
    % All three target kinds in one program, in declaration order, which is
    % [RDSC.14.4.6]'s within-module ordering. The schema docstring is a bare
    % string as the schema body's first statement ([LGRA.5.6]); a slot's is
    % the trailing `STRING_LIT?` of [LGRA.5.1]'s `field_decl`; a rule's is the
    % same bare-string form as a schema's.
    DocSource =
        "schema Reading scope logical:\n"
            ++ "    \"A sensor reading.\"\n"
            ++ "    entity_id: String key \"Which sensor.\"\n"
            ++ "    state: Float mutable\n"
            ++ "\n"
            ++ "rule warm:\n"
            ++ "    \"Fires once the reading is warm.\"\n"
            ++ "    Reading r where r.state > 30.0\n"
            ++ "->\n"
            ++ "    log info \"warm\"\n",
    ( if compiled_bytes(DocSource) = yes(DocBytes) then
        DocsOk = ( if
            docs_atoms(DocBytes) =
                [{2u32, 1u32, "Reading", "", "", "A sensor reading.", 1u32, 1u32},
                 {3u32, 1u32, "Reading", "entity_id", "", "Which sensor.",
                  3u32, 5u32},
                 {4u32, 1u32, "", "", "warm", "Fires once the reading is warm.",
                  6u32, 1u32}]
        then yes else no )
    else
        DocsOk = no
    ),
    check("[RDSC.14.4.3] DocString carries schema, slot and rule docstrings",
        DocsOk, !T, !IO),

    % An undocumented declaration emits no DocString, not one with `text: ""`,
    % which would read as a docstring written empty ([RDSC.14.4.1]).
    ( if
        compiled_bytes("schema Reading scope logical:\n"
            ++ "    entity_id: String key\n") = yes(BareBytes)
    then
        BareOk = ( if docs_atoms(BareBytes) = [] then yes else no )
    else
        BareOk = no
    ),
    check("[RDSC.14.4.1] no docstring, no DocString atom", BareOk, !T, !IO),

    % A library's DocString atoms carry the library's `module_id` ([RDSC.4.7]);
    % the importing file is the last clip, so the library's comes first, 1.
    ( if
        compiled_lib_bytes(
            ["shared" - ("schema Reading scope logical:\n"
                ++ "    \"From the library.\"\n"
                ++ "    id: String key\n")],
            "from shared import Reading\n\n"
                ++ "schema Out scope ttl 1_h:\n"
                ++ "    \"From the file.\"\n"
                ++ "    v: Int\n\n"
                ++ "rule r:\n    Reading x\n->\n"
                ++ "    emit Out v: len(x.id)\n") = yes(LibDocBytes)
    then
        LibDocsOk = ( if
            docs_atoms(LibDocBytes) =
                [{2u32, 1u32, "shared.Reading", "", "", "From the library.", 1u32,
                    1u32},
                 {2u32, 2u32, "Out", "", "", "From the file.", 3u32, 1u32}]
        then yes else no )
    else
        LibDocsOk = no
    ),
    check("[RDSC.14.4.6] DocString atoms are ordered by `module_id`, library "
            ++ "first",
        LibDocsOk, !T, !IO),

    % ── [RDSC.8.4]: a group's atoms in source order ─────────────────────────
    %
    % Every repeated declaration written out of name order, and a rule
    % between the two schemas, so that no sort by name and no "schemas, then
    % rules" grouping reproduces what was written. Read back from the bytes:
    % the schema groups by their SchemaSource names, the rule groups by their
    % RuleSource names, the ServiceDef atoms by name, and the DocString atoms,
    % each in emission order. A service's kwargs are the one thing sorted,
    % because the world outside the program reads them ([LGRA.23.2]), so
    % `svc.zulu`'s `b, a` comes back `a, b`. Driven through
    % `dsc.encode.rdsc_8_1_module_group`, whose services
    % `dsc.driver.ladp_8_2_1_services` hands it.
    %
    % @spec [RDSC.8.4]
    OrderSource =
        "schema Zeta scope logical:\n"
            ++ "    \"Declared first.\"\n"
            ++ "    id: String key\n\n"
            ++ "rule zed:\n"
            ++ "    \"Declared between the schemas.\"\n"
            ++ "    Zeta\n->\n    log info \"zed\"\n\n"
            ++ "schema Alpha scope logical:\n"
            ++ "    \"Declared second.\"\n"
            ++ "    id: String key\n\n"
            ++ "service svc.zulu:\n"
            ++ "    kwarg b: Int\n"
            ++ "    kwarg a: Int\n"
            ++ "    no response\n\n"
            ++ "service svc.alpha:\n"
            ++ "    no response\n\n"
            ++ "rule ace:\n"
            ++ "    Alpha\n->\n    log info \"ace\"\n",
    MaybeOrderBytes = compiled_bytes(OrderSource),
    check("[RDSC.8.4] the out-of-order program compiles",
        ( if MaybeOrderBytes = yes(_) then yes else no ), !T, !IO),
    ( if MaybeOrderBytes = yes(OrderBytes) then
        OrderOk = ( if
            list.map(( func({N, _, _, _}) = N ), srcs_atoms(OrderBytes))
                = ["Zeta", "Alpha"],
            rule_source_names(OrderBytes) = ["zed", "ace"],
            list.map(( func({N, _, _}) = N ), svcd_atoms(OrderBytes))
                = ["svc.zulu", "svc.alpha"],
            svcd_kwarg_names(OrderBytes) = ["a", "b"],
            list.map(( func({_, _, Sc, _, Ru, _, _, _}) = Sc ++ Ru ),
                docs_atoms(OrderBytes)) = ["Zeta", "zed", "Alpha"]
        then yes else no )
    else
        OrderOk = no
    ),
    check("[RDSC.8.4] schemas, rules, services and docstrings in source "
            ++ "order, kwargs by name",
        OrderOk, !T, !IO),

    % [RDSC.8.4]'s series rule: a declaration's backend atoms follow its
    % lines, a backing that several lines share at the first line that
    % selects it. Line 1 selects a FifoDeque at 10 s, line 2 a RingBuffer at
    % 10 s, line 3 line 1's FifoDeque again, and line 4 a FifoDeque at 1 min.
    % Read back from the bytes, the backend atoms are FifoDeque, RingBuffer,
    % FifoDeque:
    % - kind order, [RDSC.8.1]'s alternation, would put the RingBuffer first;
    % - a FifoDeque for line 3 would make four atoms;
    % - grouping a backing's windows at its first line would put the two
    %   FifoDeques together. The atom is the (backing, window) pair
    %   [RDSC.5a.8.1] keys, so the 1-minute one takes line 4's place.
    %
    % @spec [RDSC.8.4]
    SeriesOrderSource =
        "use default\n\n"
            ++ "schema Gauge scope logical:\n"
            ++ "    entity_id: String key\n"
            ++ "    v: Float mutable\n\n"
            ++ "schema Seen scope ttl 1_h:\n"
            ++ "    a: Float\n"
            ++ "    b: Float\n"
            ++ "    c: Float\n"
            ++ "    d: Float\n\n"
            ++ "series Gauge.v (by: entity_id):\n"
            ++ "    first sliding 10_s as f10\n"
            ++ "    median sliding 10_s as m10\n"
            ++ "    last sliding 10_s as l10\n"
            ++ "    first sliding 1_min as f60\n\n"
            ++ "rule seen:\n"
            ++ "    Gauge g\n->\n"
            ++ "    emit Seen a: g.f10.first ?? -1.0 b: g.m10.median ?? -1.0 "
            ++ "c: g.l10.last ?? -1.0 d: g.f60.first ?? -1.0\n",
    SeriesResult = compile(SeriesOrderSource),
    ( if SeriesResult = compiled(_, _, _) then
        SeriesCompiled = yes
    else
        SeriesCompiled = no,
        report_failure(SeriesResult, !IO)
    ),
    check("[RDSC.8.4] the four-line series program compiles",
        SeriesCompiled, !T, !IO),
    ( if SeriesResult = compiled(SeriesBytes, _, _) then
        SeriesNames = backend_atom_names(SeriesBytes),
        ( if
            SeriesNames = ["SeriesBackendFifoDeque", "SeriesBackendRingBuffer",
                "SeriesBackendFifoDeque"]
        then
            SeriesOk = yes
        else
            SeriesOk = no,
            io.format("    backend atoms: %s\n",
                [s(string.join_list(", ", SeriesNames))], !IO)
        )
    else
        SeriesOk = no
    ),
    check("[RDSC.8.4] a series' backend atoms follow its lines, a shared "
            ++ "backing at its first line",
        SeriesOk, !T, !IO),

    % ── [RDSC.5.8]: the generated `.proto`, and the shape invariant ────────
    %
    % The syntax line, the `ds.dsc.user.v1` package, one message, fields
    % numbered from 1 in declaration order.
    check_source_loaded("[RDSC.5.8.3] the SchemaDef carries the generated `.proto`",
        "schema Reading scope logical:\n"
            ++ "    entity_id: String key\n"
            ++ "    state: Float mutable\n",
        ( pred(P::in) is semidet :-
            author_schemas(P) = [S],
            S ^ s_proto = yes(Proto),
            proto_source_text(Proto) =
                "syntax = \"proto3\";\n"
                ++ "package ds.dsc.user.v1;\n"
                ++ "message Reading {\n"
                ++ "  string entity_id = 1;\n"
                ++ "  double state = 2;\n"
                ++ "}\n"
        ), !T, !IO),

    % @spec [RDSC.5.8.3]
    % test_rdsc_5_8_3__a_librarys_package_holds_its_path: the package gains the
    % library's dotted path and the message stays its NAME, so two libraries'
    % `Reply`s are two messages. A program's stays the base package, and a
    % `dump-schemas` of the library alone keeps it ([RCLI.1.5]).
    Shared = "schema Reading scope logical:\n    id: String key\n",
    check("[RDSC.5.8.3] a library's package holds its path, and a program's "
            ++ "does not",
        ( if
            compiled_lib_bytes(["board.model" - Shared],
                "from board.model import Reading\n\n"
                    ++ "schema Out scope logical:\n    id: String key\n\n"
                    ++ "rule r:\n    Reading x\n->\n"
                    ++ "    log info \"{x.id}\"\n") = yes(SharedBytes),
            load_dsc(from_bytes(SharedBytes), loaded(SharedP)),
            sdef_text(SharedP, "board.model.Reading") =
                "syntax = \"proto3\";\n"
                ++ "package ds.dsc.user.v1.board.model;\n"
                ++ "message Reading {\n"
                ++ "  string id = 1;\n"
                ++ "}\n",
            sdef_text(SharedP, "Out") =
                "syntax = \"proto3\";\n"
                ++ "package ds.dsc.user.v1;\n"
                ++ "message Out {\n"
                ++ "  string id = 1;\n"
                ++ "}\n"
          then yes else no ),
        !T, !IO),
    check("[RCLI.1.5] `dump-schemas` of a library alone keeps the base package",
        ( if dump_matches_sdefs(Shared, ["Reading"]) then yes else no ),
        !T, !IO),

    % [RDSC.5.8.5]: the SchemaDef `.proto` and the Slots describe the same
    % shape, compared field for field off the loaded program, over
    % [RDSC.5.8.6]'s matrix: `Every` the six scalar kinds and a unit-typed slot
    % (`double`, by [LUNI.7.1]'s storage), `Ref` the fact reference, `Aged`
    % the `ttl` lifecycle.
    EverySource = "unit dimension warmth storage float64 base therm\n"
            ++ "unit therm: warmth\n\n"
            ++ "schema Every scope logical:\n"
            ++ "    entity_id: String key\n"
            ++ "    qty: Int mutable\n"
            ++ "    state: Float mutable\n"
            ++ "    live: Bool mutable\n"
            ++ "    payload: Json mutable\n"
            ++ "    blob: Bytes mutable\n"
            ++ "    temp: therm mutable\n"
            ++ "\n"
            ++ "schema Ref scope logical:\n"
            ++ "    entity_id: String key\n"
            ++ "    source: Every mutable\n"
            ++ "\n"
            ++ "schema Aged scope ttl 1_h:\n"
            ++ "    reading: Float\n",
    check_source_loaded("[RDSC.5.8.5] the SchemaDef and the SLOTs agree, kind by kind",
        EverySource, proto_matches_slots, !T, !IO),

    % [RDSC.5.8.3], [RDSC.5.8.6]: a `T?` slot is an `optional` field, over
    % every kind that admits `?`, beside a non-nullable key.
    % `proto_matches_slots` compares label and type both ways; the literal
    % text pins the spelling.
    NullableSource = "unit dimension warmth storage float64 base therm\n"
            ++ "unit therm: warmth\n\n"
            ++ "schema Maybe scope logical:\n"
            ++ "    entity_id: String key\n"
            ++ "    qty: Int? mutable\n"
            ++ "    state: Float? mutable\n"
            ++ "    label: String? mutable\n"
            ++ "    live: Bool? mutable\n"
            ++ "    payload: Json? mutable\n"
            ++ "    blob: Bytes? mutable\n"
            ++ "    temp: therm? mutable\n"
            ++ "    seen: Time? mutable\n"
            ++ "    due: Date? mutable\n"
            ++ "    span: Duration? mutable\n",
    check_source_loaded("[RDSC.5.8.6] each nullable slot's field is `optional`, "
            ++ "and no other is",
        NullableSource, proto_matches_slots, !T, !IO),
    check_source_loaded("[RDSC.5.8.3] the `optional` label is spelled in the "
            ++ "generated `.proto`",
        NullableSource,
        ( pred(P::in) is semidet :-
            author_schemas(P) = [S],
            S ^ s_proto = yes(Proto),
            proto_source_text(Proto) =
                "syntax = \"proto3\";\n"
                ++ "package ds.dsc.user.v1;\n"
                ++ "message Maybe {\n"
                ++ "  string entity_id = 1;\n"
                ++ "  optional int64 qty = 2;\n"
                ++ "  optional double state = 3;\n"
                ++ "  optional string label = 4;\n"
                ++ "  optional bool live = 5;\n"
                ++ "  optional string payload = 6;\n"
                ++ "  optional bytes blob = 7;\n"
                ++ "  optional double temp = 8;\n"
                ++ "  optional int64 seen = 9;\n"
                ++ "  optional int64 due = 10;\n"
                ++ "  optional int64 span = 11;\n"
                ++ "}\n"
        ), !T, !IO),

    % [RCLI.1.5]: `dump-schemas` writes each schema's message as its
    % SchemaDef carries it, read back through the runtime's loader. `Plain`
    % follows `Maybe` to pin order and the blank line between messages.
    DumpSource = NullableSource
            ++ "\n"
            ++ "schema Plain scope ttl 1_h:\n"
            ++ "    reading: Float\n",
    check("[RCLI.1.5] dump-schemas writes each declared schema's SchemaDef "
            ++ "message, `optional` included",
        ( if dump_matches_sdefs(DumpSource, ["Maybe", "Plain"]) then yes
          else no ),
        !T, !IO),

    % RDSC.5.8.3: a fact reference renders `uint64`, the referenced fact's
    % handle in a recorded body (RFCS.6.3).
    check_source_loaded("[RDSC.5.5] a fact-reference slot renders `uint64`",
        EverySource,
        ( pred(P::in) is semidet :-
            list.find_first_match(
                ( pred(S::in) is semidet :-
                    expand(interns(P), schema_name_ref(S ^ s_name), "Ref")
                ), schemas(P), Ref),
            list.find_first_match(
                ( pred(C::in) is semidet :- C ^ sc_kind = k_schema(_) ),
                slot_commons(Ref), Slot),
            Slot ^ sc_kind = k_schema(Target),
            expand(interns(P), schema_name_ref(Target), "Every"),
            proto_type_of(Slot ^ sc_kind) = "uint64"
        ), !T, !IO),

    check_source_loaded("[RDSC.5.8.6] the `.proto` says nothing about lifecycle "
            ++ "or hydration",
        EverySource, sdef_lifecycle_silent_in_proto, !T, !IO),


    % [LUNI.3.1.5]: multiply, then truncate; at 1.5 hours the other order is
    % an hour off.
    check_source_loaded("[LUNI.3.1.5] a fractional ttl scales before it truncates",
        "schema R scope ttl 1.5_h:\n    state: Float\n",
        ( pred(P::in) is semidet :-
            author_schemas(P) = [S],
            S ^ s_lifecycle = lc_ttl(_, D),
            duration_ns(D) = 5400000000000u64
        ), !T, !IO),

    % ── what the artefact does not carry ────────────────────────────────────

    % A rule `dsc.rete` does not lower refuses the compile. An `after` body
    % interpolating a parent binding as a whole fact needs a capture shape
    % [LTAC.3.5]'s slot captures do not cover.
    Unlowerable =
        "schema Sensor:\n" ++
        "    state: Float\n" ++
        "\n" ++
        "rule warm:\n" ++
        "    Sensor s where s.state > 30\n" ++
        "->\n" ++
        "    after 5_s:\n" ++
        "        log info \"warm {s}\"\n",
    check_unlowered("a rule not lowered is refused, not silently dropped",
        Unlowerable, ["rule"], !T, !IO),

    % The refusal names the rule and carries the lowering's reason, at the
    % rule's own position.
    check("the refusal names the rule it could not lower",
        ( if
            compile(Unlowerable) = compile_rejected([WarmD]),
            WarmD ^ dg_code = dc_validate(dv_rule_not_lowered),
            string.prefix(WarmD ^ dg_message,
                "rule `warm` cannot be lowered: "),
            string.length(WarmD ^ dg_message)
                > string.length("rule `warm` cannot be lowered: ")
        then yes else no ), !T, !IO),

    % A library's rules join the importer's artefact ([LIMP.7.5]), so one not
    % lowered refuses the importer, named in the library's file ([RCLI.1.9]).
    UnlowerableLib = "schema Sensor:\n" ++
        "    state: Float\n" ++
        "\n" ++
        "rule warm:\n" ++
        "    Sensor s where s.state > 30\n" ++
        "->\n" ++
        "    after 5_s:\n" ++
        "        log info \"warm {s}\"\n",
    compile_with(as_though("default"),
        yes(map.from_assoc_list(["shared" - UnlowerableLib])),
        "from shared import Sensor\n\n"
            ++ "schema Out scope ttl 1_h:\n    v: Int\n",
        LibResult),
    check("a library rule not lowered refuses the importer, named "
            ++ "in its library",
        ( if
            LibResult = compile_rejected([LibD]),
            LibD ^ dg_code = dc_validate(dv_rule_not_lowered),
            LibD ^ dg_file = yes("<in-memory:shared.ds>"),
            string.prefix(LibD ^ dg_message,
                "rule `warm` cannot be lowered: ")
        then yes else no ), !T, !IO),

    % [RCLI.1.9]: an error lowering a library's schema, a slot type no type
    % declares, is named in the library's file, as its `DsSource` names it,
    % not in the importing file's. The control: the same declaration in the
    % importing file is named by no library, so the caller's `--filename`
    % names it.
    BadTypeLib = "schema Sensor scope logical:\n"
        ++ "    entity_id: String key\n"
        ++ "\n"
        ++ "schema Other scope logical:\n"
        ++ "    name: Strin key\n",
    compile_with(as_though("default"),
        yes(map.from_assoc_list(["badtype" - BadTypeLib])),
        "from badtype import Sensor\n\n"
            ++ "rule seen:\n"
            ++ "    Sensor s where s.entity_id == \"kitchen\"\n"
            ++ "->\n"
            ++ "    log warning \"seen\"\n",
        BadTypeResult),
    check("[RCLI.1.9] an error lowering a library's schema is named in its "
            ++ "library",
        ( if
            BadTypeResult = compile_rejected(BadDs),
            UnknownInLib = list.filter(
                ( pred(BadD::in) is semidet :-
                    BadD ^ dg_code = dc_validate(dv_unknown_type) ), BadDs),
            UnknownInLib = [_ | _],
            list.all_true(
                ( pred(LibBadD::in) is semidet :-
                    LibBadD ^ dg_file = yes("<in-memory:badtype.ds>") ),
                UnknownInLib)
        then yes else no ), !T, !IO),
    check("[RCLI.1.9] the control: the same declaration in the importing "
            ++ "file is named by no library",
        ( if
            compile("schema Other scope logical:\n    name: Strin key\n")
                = compile_rejected(OwnDs),
            UnknownOwn = list.filter(
                ( pred(OwnD::in) is semidet :-
                    OwnD ^ dg_code = dc_validate(dv_unknown_type) ), OwnDs),
            UnknownOwn = [_ | _],
            list.all_true(
                ( pred(OwnUnD::in) is semidet :- OwnUnD ^ dg_file = no ),
                UnknownOwn)
        then yes else no ), !T, !IO),

    % @spec [RDSC.11.3]: the compiler refuses a program an expression
    % of which would lower to an `Expr` nested deeper than 48, the outermost at
    % 0, with DS_VALIDATE_EXPRESSION_TOO_DEEP. The join test `s.v + ... + s.v
    % > 0` over N reads is the comparison at 0 and N - 1 additions under it,
    % so its deepest `Expr`, a read, is at N. Slot reads, so nothing folds.
    DeepSource = ( func(N) = S :-
        Sum = string.join_list(" + ", list.duplicate(N, "s.v")),
        S = "schema Sensor:\n    v: Int\n\nrule deep:\n    Sensor s where "
            ++ Sum ++ " > 0\n->\n    log info \"deep\"\n"
    ),
    check("[RDSC.11.3] an expression lowering to an `Expr` 48 deep compiles",
        ( if compile(DeepSource(48)) = compiled(_, _, _) then yes else no ),
        !T, !IO),
    check("[RDSC.11.3] one lowering to an `Expr` 49 deep is refused with "
            ++ "DS_VALIDATE_EXPRESSION_TOO_DEEP, at the pattern",
        ( if
            compile(DeepSource(49)) = compile_rejected([Deep]),
            Deep ^ dg_code = dc_validate(dv_expression_too_deep)
        then yes else no ), !T, !IO),

    check_unlowered("a rule that lowers is not reported",
        "schema Sensor:\n" ++
        "    state: Float\n" ++
        "\n" ++
        "rule warm:\n" ++
        "    Sensor s where s.state > 30\n" ++
        "->\n" ++
        "    log info \"warm\"\n",
        [], !T, !IO),

    % A `series` emits its backing and a `service` a dispatch table entry, so
    % neither is an unlowered declaration.
    check_unlowered("a series and a service are not reported unlowered",
        "use default\n" ++
        "\n" ++
        "service switch.turn_on:\n" ++
        "    kwarg entity_id: String\n" ++
        "    no response\n" ++
        "\n" ++
        "schema Thermometer scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    temperature: Float mutable\n" ++
        "\n" ++
        "schema Report scope ttl 1_h:\n" ++
        "    label: String\n" ++
        "    avg: Float\n" ++
        "\n" ++
        "series Thermometer.temperature (by: entity_id):\n" ++
        "    mean sliding 10_min\n" ++
        "\n" ++
        "rule report:\n" ++
        "    Thermometer t\n" ++
        "->\n" ++
        "    emit Report label: t.entity_id avg: t.mean ?? -1.0\n",
        [], !T, !IO),

    % ── the network ─────────────────────────────────────────────────────────

    % `runtime/mercury/test/fixtures/31_source_order.ds`: two bare patterns,
    % one log each. An omitted binding still gets a synthetic, so both rules
    % carry a display template.
    check_source_loaded("[RLOW.4.2.1] two rules, one root beta and terminal each",
        "schema Alpha scope logical:\n" ++
        "    id: Int key\n" ++
        "\n" ++
        "schema Beta scope logical:\n" ++
        "    id: Int key\n" ++
        "\n" ++
        "rule alpha_rule:\n" ++
        "    Alpha\n" ++
        "->\n" ++
        "    log info \"alpha fired\"\n" ++
        "\n" ++
        "rule beta_rule:\n" ++
        "    Beta\n" ++
        "->\n" ++
        "    log warning \"beta fired\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            list.length(alpha_nodes(Net)) = 2,
            [Beta1, Beta2] = beta_nodes(Net),
            Beta1 ^ bn_parent = no,
            Beta2 ^ bn_parent = no,
            [Term1, Term2] = terminal_nodes(Net),
            expand(interns(P), Term1 ^ tn_rule, "alpha_rule"),
            expand(interns(P), Term2 ^ tn_rule, "beta_rule"),
            Term1 ^ tn_inline_actions = [ia_log(log_info, e_lit(str(Msg1)))],
            expand(interns(P), Msg1, "alpha fired"),
            Term2 ^ tn_inline_actions = [ia_log(log_warning, _)],
            [Meta1, _] = rule_metas(P),
            Meta1 ^ rm_display = yes(
                "alpha_rule($alpha_rule_pat0={$alpha_rule_pat0.id})")
        ), !T, !IO),

    % [RDSC.6.8.4]: a `logical` schema whose key is ∅ contributes its first
    % declared slot.
    check_source_loaded("[RDSC.6.8.4] a key-less logical schema names its first slot",
        "schema Meter scope logical:\n" ++
        "    reading: Float mutable\n" ++
        "\n" ++
        "rule meter_rule:\n" ++
        "    Meter\n" ++
        "->\n" ++
        "    log info \"metered\"\n",
        ( pred(P::in) is semidet :-
            [Meta] = rule_metas(P),
            Meta ^ rm_display = yes(
                "meter_rule($meter_rule_pat0={$meter_rule_pat0.reading})")
        ), !T, !IO),

    % [LREG.1.2] / [LREG.1.3]: `~` is `FN_REGEX_MATCH(subject, pattern,
    % flags)` on the beta, `!~` its `not`. `msg` is nullable so the `~` stays
    % in the join test: on a non-nullable `String` it hoists onto the alpha
    % (RLOW.5.2.2, below).
    check_source_loaded("[LREG.1.2] `~` and `!~` lower to a regex match call",
        "schema Log scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    msg: String? mutable\n" ++
        "\n" ++
        "rule errors:\n" ++
        "    Log e where e.msg ~ /^error:/i\n" ++
        "->\n" ++
        "    log info \"error {e.entity_id}\"\n" ++
        "\n" ++
        "rule quiet:\n" ++
        "    Log q where q.msg !~ /\\d+/\n" ++
        "->\n" ++
        "    log info \"quiet {q.entity_id}\"\n",
        ( pred(P::in) is semidet :-
            [ErrBeta, QuietBeta] = beta_nodes(network(P)),
            ErrBeta ^ bn_tests = [e_call(fn_regex_match,
                [_, e_lit(str(ErrPat)), e_lit(str(ErrFlags))])],
            expand(interns(P), ErrPat, "^error:"),
            expand(interns(P), ErrFlags, "i"),
            QuietBeta ^ bn_tests = [e_unop(op_not, e_call(fn_regex_match,
                [_, e_lit(str(QuietPat)), _]))],
            expand(interns(P), QuietPat, "\\d+")
        ), !T, !IO),

    % `06_rule_with_where.ds`: both conjuncts are single-fact constants on
    % non-nullable slots, so both hoist onto the alpha and the beta tests
    % nothing.
    check_source_loaded("[RLOW.5.2.1] constant conjuncts hoist onto the alpha",
        "schema Sensor scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    state: Float mutable\n" ++
        "\n" ++
        "rule kitchen_high:\n" ++
        "    Sensor s where s.state > 75 and s.entity_id == \"kitchen\"\n" ++
        "->\n" ++
        "    log warning \"high\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            [Alfa] = alpha_nodes(Net),
            Alfa ^ an_tests = [at_cmp(Slot1, op_gt, al_int(75i64)),
                at_eq(Slot0, al_string(Kitchen))],
            slot_index_int(Slot1) = 1,
            slot_index_int(Slot0) = 0,
            expand(interns(P), Kitchen, "kitchen"),
            [Beta] = beta_nodes(Net),
            Beta ^ bn_tests = []
        ), !T, !IO),

    % RLOW.5.2.2, `dsc.rete.rlow_5_2_2_regex_test`: a decided `~` on the
    % pattern's own non-nullable `String` slot is an alpha REGEX test, and the
    % beta tests nothing. No flags, so the pattern is `p` as written. Through
    % the encoder and the Mercury runtime's decoder, so the loader's
    % acceptance of `at_regex` is in the path too.
    check_source_loaded("RLOW.5.2.2: a decided `~` hoists onto the alpha",
        "schema Log scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    msg: String mutable\n" ++
        "\n" ++
        "rule errors:\n" ++
        "    Log e where e.msg ~ /^error:/\n" ++
        "->\n" ++
        "    log info \"error {e.entity_id}\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            [Alfa] = alpha_nodes(Net),
            Alfa ^ an_tests = [at_regex(Slot, "^error:")],
            slot_index_int(Slot) = 1,
            [Beta] = beta_nodes(Net),
            Beta ^ bn_tests = []
        ), !T, !IO),

    % RLOW.5.2.2: an alpha test has no flags field, so the flags go into the
    % pattern as RE2's scoped group `(?f:p)`, letters as written -- each of
    % the three and a combination. Four patterns, so four alphas
    % ([IRET.6.6] shares only on equal tests), in whatever order the build
    % lists them.
    check_source_loaded("RLOW.5.2.2: flags fold into the pattern as `(?f:p)`",
        "schema Log scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    msg: String mutable\n" ++
        "\n" ++
        "rule ri:\n" ++
        "    Log a where a.msg ~ /error/i\n" ++
        "->\n" ++
        "    log info \"i\"\n" ++
        "\n" ++
        "rule rm:\n" ++
        "    Log b where b.msg ~ /^error$/m\n" ++
        "->\n" ++
        "    log info \"m\"\n" ++
        "\n" ++
        "rule rs:\n" ++
        "    Log c where c.msg ~ /a.b/s\n" ++
        "->\n" ++
        "    log info \"s\"\n" ++
        "\n" ++
        "rule rims:\n" ++
        "    Log d where d.msg ~ /^a.b$/ims\n" ++
        "->\n" ++
        "    log info \"ims\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            Alphas = alpha_nodes(Net),
            list.length(Alphas) = 4,
            Patterns = list.map(
                ( func(A) = Pat :-
                    ( if A ^ an_tests = [at_regex(_, Pat0)] then
                        Pat = Pat0
                    else
                        Pat = "<not one regex test>"
                    )
                ), Alphas),
            % The pred form: `list.sort(X) = list.sort(Y)` is ambiguous
            % between the func and the pred.
            list.sort(Patterns, Sorted),
            Sorted = ["(?i:error)", "(?ims:^a.b$)", "(?m:^error$)",
                "(?s:a.b)"],
            list.all_true((pred(B::in) is semidet :- B ^ bn_tests = []),
                beta_nodes(Net))
        ), !T, !IO),

    % RLOW.5.2.2 beside RLOW.5.2.1: a conjunction hoists both kinds, in
    % source order, and leaves the beta empty.
    check_source_loaded("RLOW.5.2.2: a `~` and a comparison hoist together",
        "schema Log scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    msg: String mutable\n" ++
        "\n" ++
        "rule kitchen_errors:\n" ++
        "    Log e where e.msg ~ /error/ and e.entity_id == \"kitchen\"\n" ++
        "->\n" ++
        "    log info \"kitchen\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            [Alfa] = alpha_nodes(Net),
            Alfa ^ an_tests = [at_regex(Slot1, "error"),
                at_eq(Slot0, al_string(Kitchen))],
            slot_index_int(Slot1) = 1,
            slot_index_int(Slot0) = 0,
            expand(interns(P), Kitchen, "kitchen"),
            [Beta] = beta_nodes(Net),
            Beta ^ bn_tests = []
        ), !T, !IO),

    % RLOW.5.2.2's non-hoists, each pinned by what stays in the join test:
    %   * `!~` -- an alpha test has no negation;
    %   * a NULLABLE subject -- the match is Kleene, so it is not decided
    %     ([IRET.6.4]);
    %   * a pattern whose `(?f:p)` form RE2 refuses -- an unterminated `\Q`
    %     quotes to the end of the pattern and swallows the group's `)`, so
    %     the wrapped form would fail the load ([IRET.6.3]). `\Qerr` alone is
    %     valid, which is why it compiles.
    % The third non-hoist, a `nolinscan` slot with no `capacity`, cannot be
    % written: [LNLS.3.7] refuses such a `~` before lowering.
    check_source_loaded("RLOW.5.2.2: `!~`, a nullable subject and an "
        ++ "unwrappable pattern stay on the beta",
        "schema Log scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    msg: String mutable\n" ++
        "    note: String? mutable\n" ++
        "\n" ++
        "rule not_error:\n" ++
        "    Log a where a.msg !~ /error/\n" ++
        "->\n" ++
        "    log info \"not\"\n" ++
        "\n" ++
        "rule noted:\n" ++
        "    Log b where b.note ~ /error/\n" ++
        "->\n" ++
        "    log info \"noted\"\n" ++
        "\n" ++
        "rule quoted:\n" ++
        "    Log c where c.msg ~ /\\Qerr/i\n" ++
        "->\n" ++
        "    log info \"quoted\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            list.all_true((pred(A::in) is semidet :- A ^ an_tests = []),
                alpha_nodes(Net)),
            Tests = list.map((func(B) = B ^ bn_tests), beta_nodes(Net)),
            list.member(NotTests, Tests),
            NotTests = [e_unop(op_not, e_call(fn_regex_match, _))],
            list.member(NoteTests, Tests),
            NoteTests = [e_call(fn_regex_match,
                [e_slot(_, slot(NoteSlot)), _, _])],
            slot_index_int(NoteSlot) = 2,
            list.member(QuotedTests, Tests),
            QuotedTests = [e_call(fn_regex_match,
                [e_slot(_, slot(MsgSlot)), e_lit(str(QPat)), _])],
            slot_index_int(MsgSlot) = 1,
            expand(interns(P), QPat, "\\Qerr")
        ), !T, !IO),

    % [IRET.9.6], through the encoder and the decoder: field 19 is written and
    % read. The projection is stamped and so is the comparison above it, since
    % `ds.eval` classifies a fault at the node that raised it. The clean
    % conjunct still hoists: `and_conjuncts` splits through the wrapper.
    check_source_loaded("[IRET.9.6] a `Json` projection taints itself and the "
        ++ "operation above it",
        "schema Msg scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    body: Json mutable\n" ++
        "\n" ++
        "rule big:\n" ++
        "    Msg m where m.body.foo > 30 and m.entity_id == \"kitchen\"\n" ++
        "->\n" ++
        "    log info \"big\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            [Alfa] = alpha_nodes(Net),
            Alfa ^ an_tests = [at_eq(_, al_string(Kitchen))],
            expand(interns(P), Kitchen, "kitchen"),
            [Beta] = beta_nodes(Net),
            Beta ^ bn_tests = [e_tainted(e_binop(op_gt,
                e_tainted(e_call(fn_json_path, [_, e_lit(str(Path))])),
                e_lit(int(30i64))))],
            expand(interns(P), Path, "foo")
        ), !T, !IO),

    % `??` keeps provenance: it passes a present value through whatever its
    % kind, so it establishes nothing. The projection, the `??` and the `>`
    % above all carry the flag.
    check_source_loaded("[IRET.9.6] `??` keeps a projection's provenance",
        "schema Msg scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    body: Json mutable\n" ++
        "\n" ++
        "rule big:\n" ++
        "    Msg m where (m.body.foo ?? 0) > 30\n" ++
        "->\n" ++
        "    log info \"big\"\n",
        ( pred(P::in) is semidet :-
            [Beta] = beta_nodes(network(P)),
            Beta ^ bn_tests = [e_tainted(e_binop(op_gt,
                e_tainted(e_coalesce(e_tainted(e_call(fn_json_path, _)),
                    e_lit(int(0i64)))),
                e_lit(int(30i64))))]
        ), !T, !IO),

    % [LCST.4.5.11]: a cast of a `Json` leaf dispatches on the kind the leaf
    % holds, `null` first, and its result is clean ([IRET.9.6]), so the `>`
    % above takes no flag.
    check_source_loaded("[LCST.4.5.11] a `Json` leaf's cast dispatches on its "
        ++ "kind, and its result is clean",
        "schema Msg scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    body: Json mutable\n" ++
        "\n" ++
        "rule big:\n" ++
        "    Msg m where m.body.foo::Float? > 1.0\n" ++
        "->\n" ++
        "    log info \"big\"\n",
        ( pred(P::in) is semidet :-
            [Beta] = beta_nodes(network(P)),
            Beta ^ bn_tests = [e_binop(op_gt,
                e_if(e_is_test(e_tainted(e_call(fn_json_path, _)), is_null, no),
                    e_lit(null),
                    e_if(e_is_test(_, is_int, no),
                        e_call(fn_int_to_float, [_]),
                        e_if(e_is_test(_, is_float, no), _,
                            e_if(e_is_test(_, is_string, no),
                                e_call(fn_string_to_float, [_]),
                                e_if(e_is_test(_, is_bool, no),
                                    e_tainted(_), e_tainted(_)))))),
                e_lit(float(1.0)))]
        ), !T, !IO),

    % `m.seen_on.year` is a nested access that is not a projection: a Date
    % component ([LTIM.6.1], LTIM.6.6), `FN_YEAR` over the Date's UTC
    % midnight, with no `FN_JSON_PATH` beneath it, so no flag. The source is
    % read off the lowered node, since on the AST this nesting looks like a
    % `Json` path.
    check_source_loaded("[IRET.9.6] a Date component lowers with no flag: "
        ++ "a nested access that is not a projection",
        "schema Msg scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    seen_on: Date mutable\n" ++
        "\n" ++
        "rule recent:\n" ++
        "    Msg m where m.seen_on.year > 2020\n" ++
        "->\n" ++
        "    log info \"recent\"\n",
        ( pred(P::in) is semidet :-
            [Beta] = beta_nodes(network(P)),
            Beta ^ bn_tests = [e_binop(op_gt,
                e_call(fn_year, [e_call(fn_float_to_int, [_]), _]),
                e_lit(int(2020i64)))]
        ), !T, !IO),

    % A `Time` constant and a `Date` call over constants are each one literal,
    % and no `FN_CALENDAR_*` call reaches the artefact.
    %
    %@spec [RLOW.6.1.8]
    check_source_loaded("[RLOW.6.1.8] a Time and a Date constant are literals",
        "import calendar\n\n" ++
        "const LAUNCH = calendar.time(2026, 1, 1)\n\n" ++
        "schema Ev scope logical:\n" ++
        "    id: Int key\n" ++
        "    t: Time mutable\n" ++
        "    d: Date mutable\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Ev e where e.t >= LAUNCH and e.d == calendar.date(2024, 2, 29)\n" ++
        "->\n" ++
        "    log info \"r\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            [Alfa] = alpha_nodes(Net),
            Alfa ^ an_tests = [at_eq(_, al_int(19782i64))],
            [Beta] = beta_nodes(Net),
            Beta ^ bn_tests = [e_binop(op_ge, e_slot(candidate, slot(_)),
                e_lit(time(T)))],
            utc_ns(T) = 1767225600000000000i64,
            tz_offset_ns(T) = 0i64
        ), !T, !IO),

    % An `or` does not split, so nothing hoists and the whole `where` stays one
    % join test over the candidate.
    check_source_loaded("[RLOW.5.5] a disjunction stays a join test",
        "schema Sensor:\n" ++
        "    state: Float\n" ++
        "\n" ++
        "rule odd:\n" ++
        "    Sensor s where s.state > 75 or s.state < 0\n" ++
        "->\n" ++
        "    log info \"odd\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            [Alfa] = alpha_nodes(Net),
            Alfa ^ an_tests = [],
            [Beta] = beta_nodes(Net),
            Beta ^ bn_tests = [e_binop(op_or,
                e_binop(op_gt, e_slot(candidate, slot(_)), e_lit(int(75i64))),
                e_binop(op_lt, e_slot(candidate, slot(_)), e_lit(int(0i64))))]
        ), !T, !IO),

    % A second pattern joins under the first, reading the first from the token
    % and itself as the candidate.
    check_source_loaded("[RLOW.4.4.1] a join reads the token and the candidate",
        "schema Alfa:\n" ++
        "    id: Int\n" ++
        "\n" ++
        "schema Beta:\n" ++
        "    id: Int\n" ++
        "\n" ++
        "rule joined:\n" ++
        "    Alfa a\n" ++
        "    Beta b where b.id == a.id\n" ++
        "->\n" ++
        "    log info \"pair {a.id}\"\n",
        ( pred(P::in) is semidet :-
            Net = network(P),
            [Root, Join] = beta_nodes(Net),
            Root ^ bn_parent = no,
            Join ^ bn_parent = yes(Root),
            Join ^ bn_tests = [e_binop(op_eq, e_slot(candidate, slot(_)),
                e_slot(token_fact(0), slot(_)))],
            [Term] = terminal_nodes(Net),
            Term ^ tn_inline_actions = [ia_log(log_info, e_interp([fp_text(_),
                fp_value(value_prim(e_slot(token_fact(0), slot(_)),
                    align_default, no, no, 0u32, no, ft_canonical))]))]
        ), !T, !IO),

    % `07_action_verbs.ds`: every verb, in order, through the runtime's own
    % resolution of each.
    check_source_loaded("[RLOW.13.8] every action verb reaches the terminal",
        "schema Trig scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "schema Alert scope ttl 1_h:\n" ++
        "    severity: Int\n" ++
        "    zone: String\n" ++
        "\n" ++
        "service light.turn_on:\n" ++
        "    kwarg entity_id: String\n" ++
        "    no response\n" ++
        "\n" ++
        "rule fire_them_all:\n" ++
        "    Trig\n" ++
        "->\n" ++
        "    log info \"trig fired\"\n" ++
        "    log critical \"operator alert\"\n" ++
        "    emit Alert severity: 7 zone: \"kitchen\"\n" ++
        "    publish Alert severity: 7 zone: \"kitchen\"\n" ++
        "    call light.turn_on entity_id: \"light.foyer\" cooldown: 30_s\n" ++
        "    cache key: \"last_alert\" value: 1\n" ++
        "    cache_delete key: \"stale_key\"\n",
        % The call has no `as`, so its correlation is generated ([LCRS.3.1]):
        % one `fn_gensym` bind heads the frame, and the call reads it.
        ( pred(P::in) is semidet :-
            [Term] = terminal_nodes(network(P)),
            Term ^ tn_inline_actions = [
                ia_bind(Gx, e_call(fn_gensym, [])),
                ia_log(log_info, _),
                ia_log(log_critical, _),
                ia_assert(plain, _, [_, _], no),
                ia_publish(_, [_, _], no),
                % `$<rule>_c0_`, then the bind ([LCCO.3.4]): two parts.
                ia_call(_, e_interp([_, fp_value(value_prim(e_bind_ref(Gx),
                    _, _, _, _, _, _))]), _, yes(_)),
                ia_cache_set(_, e_call(fn_json_value, [_]), yes(_)),
                ia_cache_delete(_)
            ],
            list.length(actions_for(P, Term ^ tn_id)) = 8
        ), !T, !IO),

    % IRET.10.5: `withdraw j` is `ACTION_WITHDRAW` at `j`'s TOKEN position, which
    % skips the negated pattern between -- so 1, not 2 -- and the runtime's
    % own decoder reads it back.
    check_source_loaded("[RDSC.4a.8] `withdraw` lowers to its token position",
        "schema Trig scope logical:\n    v: Int key\n\n" ++
        "schema Gate scope logical:\n    g: Int key\n\n" ++
        "schema Job scope explicit:\n    id: Int\n\n" ++
        "rule r:\n" ++
        "    Trig t\n" ++
        "    no Gate\n" ++
        "    Job j where j.id == t.v\n" ++
        "->\n" ++
        "    withdraw j\n",
        ( pred(P::in) is semidet :-
            [Term] = terminal_nodes(network(P)),
            Term ^ tn_inline_actions = [ia_withdraw(1)]
        ), !T, !IO),

    % `08_let_bindings.ds`: a pure `let` inlines at its use, a sync-impure one
    % is one BIND at the head of the RHS and a BIND_REF wherever it is read.
    % `firing_at` is a `Time` ([LLET.3.6], [LGRA.9.8.10]), so `{firing_at}`
    % renders it in UTC through `to_string(utc(...))` ([LGRA.2.9.6.10]).
    check_source_loaded("[RLOW.4.5.1] pure `let` inlines, `now()` binds once",
        "schema Reading scope logical:\n" ++
        "    state: Float key\n" ++
        "\n" ++
        "schema Probe scope ttl 1_min:\n" ++
        "    delta: Float\n" ++
        "\n" ++
        "rule normalised_reading:\n" ++
        "    Reading r\n" ++
        "->\n" ++
        "    let scaled = r.state * 100.0\n" ++
        "    let firing_at = now()\n" ++
        "    log info \"raw {r.state} at {firing_at}\"\n" ++
        "    emit Probe delta: scaled\n" ++
        "    cache key: \"last_fire\" value: firing_at\n",
        ( pred(P::in) is semidet :-
            [LetTerm] = terminal_nodes(network(P)),
            LetTerm ^ tn_binds = 1,
            LetTerm ^ tn_inline_actions = [
                ia_bind(_, e_now),
                ia_log(log_info, e_interp([fp_text(_), fp_value(_),
                    fp_text(_), fp_value(BindPrim)])),
                ia_assert(plain, _, [slot_assign(_, e_binop(op_mul,
                    e_slot(token_fact(0), slot(_)), e_lit(float(_))))], no),
                ia_cache_set(_, e_call(fn_json_value, [e_bind_ref(_)]),
                    yes(_))
            ],
            BindPrim ^ vp_value =
                e_call(fn_to_string, [e_call(fn_utc, [e_bind_ref(_)])])
        ), !T, !IO),

    % `54_series.ds`: a companion read is a series builtin over the row key,
    % and the declaration it reads emits its backing.
    check_source_loaded("[RLOW.8.3.2] `t.mean` reads the series it declares",
        "use default\n" ++
        "\n" ++
        "schema Thermometer scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    temperature: Float mutable\n" ++
        "\n" ++
        "schema Report scope ttl 1_h:\n" ++
        "    label: String\n" ++
        "    avg: Float\n" ++
        "\n" ++
        "series Thermometer.temperature (by: entity_id):\n" ++
        "    mean sliding 10_min\n" ++
        "\n" ++
        "rule report:\n" ++
        "    Thermometer t\n" ++
        "->\n" ++
        "    emit Report label: t.entity_id avg: t.mean ?? -1.0\n",
        ( pred(P::in) is semidet :-
            [Decl] = series_decls(P),
            Decl ^ sd_backing = bk_ring_buffer,
            Decl ^ sd_id_slot = "entity_id",
            Decl ^ sd_window = 600000000000u64,
            Decl ^ sd_element = el_float,
            [SeriesTerm] = terminal_nodes(network(P)),
            SeriesTerm ^ tn_inline_actions = [ia_assert(plain, _,
                [_, slot_assign(_, e_coalesce(e_call(fn_series_mean,
                    [_, _, _, e_slot(token_fact(0), slot(_)),
                     e_lit(int(600000000000i64))]), _))], no)]
        ), !T, !IO),

    % `64_integral.ds`, one of four: SeriesBackendNumericIntegral carries its
    % time model and gap.
    check_source_loaded(
        "[RDSC.5a.2] `integral` emits SeriesBackendNumericIntegral with its gap",
        "use default\n" ++
        "\n" ++
        "schema AllZero scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    v: Float mutable\n" ++
        "\n" ++
        "schema Vol scope ttl 1_h:\n" ++
        "    label: String\n" ++
        "    total: Float\n" ++
        "\n" ++
        "series AllZero.v (by: entity_id):\n" ++
        "    integral all_time gap zero\n" ++
        "\n" ++
        "rule az:\n" ++
        "    AllZero s\n" ++
        "->\n" ++
        "    emit Vol label: \"az\" total: s.integral\n",
        ( pred(P::in) is semidet :-
            [Decl] = series_decls(P),
            Decl ^ sd_backing = bk_numeric_integral,
            Decl ^ sd_time = tm_all_time,
            Decl ^ sd_gap = gp_zero,
            Decl ^ sd_window = 0u64
        ), !T, !IO),

    % `20_json_path_probe.ds`: a path through a `Json` slot is `json_path`
    % over the slot and the rest of the path, bare in an interpolation.
    %
    % The interpolation is tainted, since a segment is a `Json` projection
    % ([IRET.9.6], `iret_9_6_interp_stamp`).
    check_source_loaded("[RLOW.6.3.3] a Json path is a json_path call",
        "schema Reading scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    payload: Json mutable\n" ++
        "\n" ++
        "rule json_chain:\n" ++
        "    Reading r\n" ++
        "->\n" ++
        "    log info \"depth {r.payload.depth}\"\n",
        ( pred(P::in) is semidet :-
            [JsonTerm] = terminal_nodes(network(P)),
            JsonTerm ^ tn_inline_actions = [ia_log(log_info,
                e_tainted(e_interp([_, fp_value(JsonPrim)])))],
            untainted(JsonPrim ^ vp_value) = e_call(fn_json_path,
                [e_slot(token_fact(0), slot(_)), e_lit(str(PathRef))]),
            expand(interns(P), PathRef, "depth")
        ), !T, !IO),

    % An integer-literal index is a `[N]` segment joined with no dot, the path
    % libds's `path_step` reads.
    check_source_loaded("[RLOW.6.3.3] a literal index is a `[N]` path "
            ++ "segment",
        "schema Event scope logical:\n" ++
        "    payload: Json key\n" ++
        "\n" ++
        "rule first_tag:\n" ++
        "    Event e where e.payload.tags[0] == \"first\"\n" ++
        "->\n" ++
        "    log info \"matched\"\n",
        ( pred(P::in) is semidet :-
            % The rule is lowered, and the path it reads is `tags[0]`.
            [_] = terminal_nodes(network(P)),
            interned(interns(P), "tags[0]", _),
            not interned(interns(P), "tags.[0]", _)
        ), !T, !IO),
    % [LCCO.8.2]: an `error:` body reads the `CallError` the sibling matches,
    % bound as `error`. It validates, and the
    % sibling's log reads the `code` slot off that pattern.
    check_source_loaded("[LCCO.8.2] an `error:` body reads the CallError as "
            ++ "`error`",
        "service svc.do:\n" ++
        "    kwarg line: String\n" ++
        "    no response\n" ++
        "\n" ++
        "schema Req scope logical:\n" ++
        "    entity_id: String key\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Req q\n" ++
        "->\n" ++
        "    call svc.do line: q.entity_id nocooldown as \"k\"\n" ++
        "        error:\n" ++
        "            log error \"failed: {error.code}\"\n",
        ( pred(P::in) is semidet :-
            list.member(Term, terminal_nodes(network(P))),
            Term ^ tn_inline_actions = [ia_log(log_error, e_interp([_,
                fp_value(ErrPrim)]))],
            ErrPrim ^ vp_value = e_slot(_, slot(_))
        ), !T, !IO),

    % `verify kvectors`' fixture for `dscast.trap`, verbatim: `(inf)::Int`
    % reaches the runtime as FN_FLOAT_TO_INT over a +Inf literal, so the cast
    % traps as K's `dscast.trap` says. Both rules must be lowered.
    check_source_loaded("[LCST.4.5.4] `(inf)::Int` lowers, so it can trap",
        "schema Tick scope logical:\n" ++
        "    n: Int key\n" ++
        "\n" ++
        "rule agrees:\n" ++
        "    Tick t where t.n == 1 and (((inf)::Int) is null)\n" ++
        "->\n" ++
        "    log info \"AGREE\"\n" ++
        "\n" ++
        "rule differs:\n" ++
        "    Tick t where t.n == 1 and not (((inf)::Int) is null)\n" ++
        "->\n" ++
        "    log info \"DIFFER\"\n",
        ( pred(P::in) is semidet :-
            % Bind, then match: a lone `[_, _] = f(X)` is a mode error.
            Terms = terminal_nodes(network(P)),
            Terms = [_, _]
        ), !T, !IO),

    % `t.date(tz)` is `FN_TIME_DATE` over the receiver and the zone.
    %
    % A zone other than `"UTC"` is a zone read, so the `where` is
    % time-dependent ([LTIM.2.4.1]): the test is the terminal's fire
    % guard behind a `$ClockTick` tail beta, the shape a clock read takes,
    % so a replaced `TimeZoneOffset` row is read at the next pump.
    check_source_loaded("[LTIM.3.3.1] t.date(tz) is FN_TIME_DATE, re-driven",
        "schema E scope logical:\n" ++
        "    k: Int key\n" ++
        "    fired: Time mutable\n" ++
        "    d: Date mutable\n" ++
        "\n" ++
        "rule same_day:\n" ++
        "    E e where e.fired.date(\"America/Los_Angeles\") == e.d\n" ++
        "->\n" ++
        "    log info \"same day\"\n",
        ( pred(P::in) is semidet :-
            [Tick, _] = author_schemas(P),
            expand(interns(P), schema_name_ref(Tick ^ s_name),
                "$ClockTick"),
            Net = network(P),
            [Pattern, TickBeta] = beta_nodes(Net),
            Pattern ^ bn_tests = [],
            TickBeta ^ bn_parent = yes(Pattern),
            TickBeta ^ bn_tests = [],
            [Term] = terminal_nodes(Net),
            Term ^ tn_guard = yes(e_binop(op_eq,
                e_call(fn_time_date, [_, _]), _))
        ), !T, !IO),

    % A zone that folds to `"UTC"` -- here a `const` -- resolves no zone
    % ([LTIM.10.8], [LTIM.2.6.2]), so the `where` is not time-dependent: it
    % stays a join test on the pattern's beta, no `$ClockTick` is
    % declared, and the terminal has no fire guard.
    check_source_loaded("[LTIM.2.6.2] a `const` \"UTC\" zone stays on the beta",
        "const HOME = \"UTC\"\n" ++
        "\n" ++
        "schema E scope logical:\n" ++
        "    k: Int key\n" ++
        "    fired: Time mutable\n" ++
        "    d: Date mutable\n" ++
        "\n" ++
        "rule same_day:\n" ++
        "    E e where e.fired.date(HOME) == e.d\n" ++
        "->\n" ++
        "    log info \"same day\"\n",
        ( pred(P::in) is semidet :-
            [_] = author_schemas(P),
            Net = network(P),
            [Beta] = beta_nodes(Net),
            Beta ^ bn_tests = [e_binop(op_eq, e_call(fn_time_date, [_, _]), _)],
            [Term] = terminal_nodes(Net),
            Term ^ tn_guard = no
        ), !T, !IO),

    % A spec is resolved into the primitive's fields at compile time, and no
    % pattern or format string reaches the artefact ([LGRA.2.9.6.4],
    % [LGRA.2.9.6.5]): `:%Y-%m-%d` is a `TimePrim` of three fields and two
    % literal dashes, `:08b` a `ValuePrim` with the zero flag, width 8 and type
    % `b`. Round-tripped through the runtime's decoder, as every check here is.
    check_source_loaded("[LGRA.2.9.6.4] a timestamp spec is a TimePrim",
        "schema Event scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    ts: Time\n" ++
        "\n" ++
        "rule show:\n" ++
        "    Event e\n" ++
        "->\n" ++
        "    log info \"at {e.ts:%Y-%m-%d}\"\n",
        ( pred(P::in) is semidet :-
            [Term] = terminal_nodes(network(P)),
            Term ^ tn_inline_actions = [ia_log(log_info, e_interp([
                fp_text("at "),
                fp_time(e_slot(_, _), [ti_field(tf_year), ti_text("-"),
                    ti_field(tf_month), ti_text("-"), ti_field(tf_day)])]))]
        ), !T, !IO),
    check_source_loaded("[LGRA.2.9.6.5] a binary spec is a ValuePrim",
        "schema Flags scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    v: Int mutable\n" ++
        "\n" ++
        "rule show:\n" ++
        "    Flags f\n" ++
        "->\n" ++
        "    log info \"[{f.v:08b}]\"\n",
        ( pred(P::in) is semidet :-
            [Term] = terminal_nodes(network(P)),
            Term ^ tn_inline_actions = [ia_log(log_info, e_interp([
                fp_text("["),
                fp_value(value_prim(e_slot(_, _), align_default, no, yes, 8u32,
                    no, ft_b)),
                fp_text("]")]))]
        ), !T, !IO),
    % Python's order, `[align][sign][0][width][.precision][type]`, every
    % field reaching the wire ([LGRA.2.9.6.1]).
    check_source_loaded("[LGRA.2.9.6.5] every spec field reaches the ValuePrim",
        "schema Reading scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    v: Float mutable\n" ++
        "    label: String mutable\n" ++
        "\n" ++
        "rule show:\n" ++
        "    Reading r\n" ++
        "->\n" ++
        "    log info \"{r.v:>+010.2f}|{r.label:<8.3s}\"\n",
        ( pred(P::in) is semidet :-
            [Term] = terminal_nodes(network(P)),
            Term ^ tn_inline_actions = [ia_log(log_info, e_interp([
                fp_value(value_prim(_, align_right, yes, yes, 10u32, yes(2u32),
                    ft_f)),
                fp_text("|"),
                fp_value(value_prim(_, align_left, no, no, 8u32, yes(3u32),
                    ft_s))]))]
        ), !T, !IO),
    % The same text through an interpolation, which splits its path on `.`
    % and so reaches the join with `thumbnails[0]` as one segment.
    check_source_loaded("[RLOW.6.3.3] a name after an index takes its "
            ++ "dot",
        "schema Event scope logical:\n" ++
        "    payload: Json key\n" ++
        "\n" ++
        "rule thumb:\n" ++
        "    Event e\n" ++
        "->\n" ++
        "    log info \"{e.payload.thumbnails[0].url}\"\n",
        ( pred(P::in) is semidet :-
            [_] = terminal_nodes(network(P)),
            interned(interns(P), "thumbnails[0].url", _)
        ), !T, !IO),

    % [LSCP.3.1]: an activation-scoped fact arrives by an ordinary `emit`. The
    % lowering is a plain assert in the author's order, with no NOT beta and
    % nothing synthesised ahead of it.
    check_source_loaded("[LSCP.3.1] an activation fact is a plain emit",
        "schema Request:\n" ++
        "    who: String\n" ++
        "    n: Int\n" ++
        "\n" ++
        "schema Lock scope activation:\n" ++
        "    entity_id: String\n" ++
        "\n" ++
        "rule work:\n" ++
        "    Request r\n" ++
        "->\n" ++
        "    emit Lock entity_id: r.who\n" ++
        "    log info \"work start\"\n",
        ( pred(P::in) is semidet :-
            N2 = network(P),
            [_] = beta_nodes(N2),
            [Term] = terminal_nodes(N2),
            Term ^ tn_inline_actions = [ia_assert(plain, _, [_], no),
                ia_log(log_info, _)]
        ), !T, !IO),

    % `09_negation_and_within.ds`, second rule: a `then` step is a join under
    % its predecessor with the ordering-and-gap test ahead of its own `where`.
    check_source_loaded("[RLOW.5.6.1] a then step joins after its predecessor",
        "schema DoorOpen scope ttl 1_h:\n" ++
        "    ts: Time\n" ++
        "    zone: String\n" ++
        "\n" ++
        "schema Motion scope ttl 1_h:\n" ++
        "    ts: Time\n" ++
        "    location: String\n" ++
        "\n" ++
        "rule no_motion_after_door:\n" ++
        "    DoorOpen d\n" ++
        "    then Motion m within 30_s where m.location == d.zone\n" ++
        "->\n" ++
        "    log info \"motion confirmed at {d.zone}\"\n",
        ( pred(P::in) is semidet :-
            [Anchor, Step] = beta_nodes(network(P)),
            Step ^ bn_parent = yes(Anchor),
            Step ^ bn_tests = [e_binop(op_and, e_binop(op_gt, _, _),
                    e_binop(op_lt, e_binop(op_sub, _, _), e_lit(int(Window)))),
                e_binop(op_eq, _, _)],
            % [LTHE.2.2.2]: `Y.ts - X.ts < T`, strict.
            Window = 30000000000i64
        ), !T, !IO),

    % `51_after.ds`: the parent emits its timer, `fire_at: monotonic_ns() +
    % 5_min` ([LTAC.3.3]); the follow-up joins the timer and the clock tick,
    % guards on `monotonic_ns() >= fire_at` ([LTAC.3.4]), runs the body and
    % retracts the timer. Both synthetic schemas load ahead of the file's own.
    % The parent's TerminalNode comes first and its follow-up's after it
    % ([RLOW.14.7]).
    check_source_loaded("[LTAC.3.1] an `after` is a timer emit and a follow-up",
        "schema Trig scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "rule after_only:\n" ++
        "    Trig\n" ++
        "->\n" ++
        "    after 5_min:\n" ++
        "        log critical \"deferred\"\n",
        ( pred(P::in) is semidet :-
            [Tick, Timer, _] = author_schemas(P),
            expand(interns(P), schema_name_ref(Tick ^ s_name),
                "$ClockTick"),
            expand(interns(P), schema_name_ref(Timer ^ s_name),
                "$Timer_after_only_0"),
            [ParentTerm, FollowTerm] = terminal_nodes(network(P)),
            ParentTerm ^ tn_inline_actions = [ia_assert(plain, _,
                [slot_assign(_, e_call(fn_duration_add,
                    [e_call(fn_monotonic_ns, []),
                     e_lit(int(300000000000i64))])), _], no)],
            FollowTerm ^ tn_guard = yes(e_binop(op_ge,
                e_call(fn_monotonic_ns, []), _)),
            FollowTerm ^ tn_inline_actions = [ia_log(log_critical, _),
                ia_internal(fn_retract_token_fact, [e_lit(int(0i64))])]
        ), !T, !IO),

    % [LTIM.2.4]: a `where` reading the clock leaves the pattern's beta for
    % the fire guard, and a `$ClockTick` beta at the tail re-drives the
    % terminal every pump. The synthetic schema loads ahead of the file's own.
    % `now() - e.fired` is `Time - Time`, saturated through `FN_MAX`
    % ([RLOW.6.1.6]); both operands are non-null, so with no `null` guard.
    check_source_loaded("[LTIM.2.4.2] a clock-reading `where` is the fire guard",
        "schema E scope logical:\n" ++
        "    k: Int key\n" ++
        "    fired: Time mutable\n" ++
        "\n" ++
        "rule r:\n" ++
        "    E e where (now() - e.fired) > 1_h\n" ++
        "->\n" ++
        "    log info \"m\"\n",
        ( pred(P::in) is semidet :-
            [Tick, _] = author_schemas(P),
            expand(interns(P), schema_name_ref(Tick ^ s_name),
                "$ClockTick"),
            [Pattern, TickBeta] = beta_nodes(network(P)),
            Pattern ^ bn_tests = [],
            TickBeta ^ bn_parent = yes(Pattern),
            TickBeta ^ bn_tests = [],
            [Term] = terminal_nodes(network(P)),
            Term ^ tn_guard = yes(e_binop(op_gt, e_call(fn_max,
                [e_binop(op_sub, e_now, _), e_lit(int(0i64))]), _))
        ), !T, !IO),

    % [LTIM.2.7.2]: a `within` window justifying a logical fact gets a
    % `$ClockTick` beta in front of its pattern's beta, which keeps the
    % window test; the tick takes token position 0, so the RHS reads `d` at 1.
    %
    % [LTIM.2.7.1]: the window test is the candidate's AGE from
    % its entry stamp, STRICT -- `monotonic_ns() - entry_stamp(cand) < 5_min`
    % -- and `DoorOpen` declares no `ts`, because nothing reads one.
    check_source_loaded("[LTIM.2.7.2] a `within` justifying a logical fact is re-driven",
        "schema DoorOpen scope ttl 1_h:\n" ++
        "    zone: String\n" ++
        "\n" ++
        "schema Open scope logical:\n" ++
        "    zone: String key\n" ++
        "\n" ++
        "rule recent:\n" ++
        "    DoorOpen d within 5_min\n" ++
        "->\n" ++
        "    emit Open logical zone: d.zone\n",
        ( pred(P::in) is semidet :-
            Schemas = author_schemas(P),
            list.length(Schemas) = 3,
            list.index0(Schemas, 0, Tick),
            expand(interns(P), schema_name_ref(Tick ^ s_name),
                "$ClockTick"),
            Betas = beta_nodes(network(P)),
            list.length(Betas) = 2,
            list.index0(Betas, 0, TickBeta),
            list.index0(Betas, 1, Pattern),
            TickBeta ^ bn_tests = [],
            Pattern ^ bn_parent = yes(TickBeta),
            Pattern ^ bn_tests = [e_binop(op_lt,
                e_binop(op_sub, e_call(fn_monotonic_ns, []),
                    e_entry_stamp(candidate)),
                e_lit(int(300000000000i64)))],
            Terms = terminal_nodes(network(P)),
            list.length(Terms) = 1,
            list.index0(Terms, 0, Term),
            Term ^ tn_guard = no,
            Emits = Term ^ tn_inline_actions,
            list.length(Emits) = 1,
            list.index0(Emits, 0, Emit),
            Emit = ia_assert(_, _, Assigns, _),
            list.length(Assigns) = 1,
            list.index0(Assigns, 0, Assign),
            Assign = slot_assign(_, e_slot(token_fact(1), _))
        ), !T, !IO),

    % [LEXP.9.5.1], [LEXP.9.5.2]: `s.dwell` reaches the lowered form as
    % `monotonic_ns() - entry_stamp(s)`, a clock read nowhere in the source.
    % Reading it makes the `where` time-dependent ([LEXP.9.5.3]), so the
    % condition is the terminal's fire guard behind a `$ClockTick` tail beta
    % -- the same shape a written `now()` takes. `Sensor` declares no `ts`:
    % `dwell` reads no slot.
    check_source_loaded("[LEXP.9.5.2] `dwell` lowers as the entry stamp's age",
        "schema Sensor scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    v: Int mutable\n" ++
        "\n" ++
        "rule stale_check:\n" ++
        "    Sensor s where s.dwell > 5_s\n" ++
        "->\n" ++
        "    log info \"stale\"\n",
        ( pred(P::in) is semidet :-
            [Tick, _] = author_schemas(P),
            expand(interns(P), schema_name_ref(Tick ^ s_name),
                "$ClockTick"),
            [Pattern, TickBeta] = beta_nodes(network(P)),
            Pattern ^ bn_tests = [],
            TickBeta ^ bn_parent = yes(Pattern),
            [Term] = terminal_nodes(network(P)),
            Term ^ tn_guard = yes(e_binop(op_gt,
                e_binop(op_sub, e_call(fn_monotonic_ns, []),
                    e_entry_stamp(token_fact(0))),
                e_lit(int(5000000000i64))))
        ), !T, !IO),

    % [LEXP.4.1], [LIMP.3.3.4]: `math.pi`, a constant of `math`'s source, is
    % folded into a Float literal, because nothing on the wire names a
    % constant. `math.pi - 0.001` keeps the comparison off the alpha node --
    % its right side is not a literal -- so the folded value is visible in the
    % beta's test. The library is `stdlib/math.ds`'s declaration of `pi`, in
    % memory: this suite reads no filesystem.
    check("[LEXP.4.1] `math.pi` folds to a Float literal",
        ( if
            compiled_lib_bytes(["math" - "const pi = 3.141592653589793\n"],
                "import math\n" ++
                "\n" ++
                "schema T scope logical:\n" ++
                "    v: Float key\n" ++
                "\n" ++
                "rule r_pi:\n" ++
                "    T t where t.v > math.pi - 0.001\n" ++
                "->\n" ++
                "    log critical \"pi\"\n") = yes(PiBytes),
            load_dsc(from_bytes(PiBytes), loaded(PiP)),
            [PiBeta] = beta_nodes(network(PiP)),
            PiBeta ^ bn_tests = [e_binop(op_gt, e_slot(_, _),
                e_binop(op_sub, e_lit(float(PiVal)), e_lit(float(_))))],
            PiVal = math.pi
        then yes else no ), !T, !IO),

    % [RLOW.5.4]: a trailing negated `within` gets a `$ClockTick` beta in
    % front of its NOT beta, so a blocker ageing out of the window releases the
    % rule on the next pump. No positive pattern follows, so `d` stays at 0.
    check_source_loaded("[RLOW.5.4] a trailing negated `within` is re-driven",
        "schema Motion scope ttl 1_h:\n" ++
        "    ts: Time\n" ++
        "    zone: String\n" ++
        "\n" ++
        "schema Door scope logical:\n" ++
        "    zone: String key\n" ++
        "\n" ++
        "rule quiet:\n" ++
        "    Door d\n" ++
        "    no Motion m within 5_min where m.zone == d.zone\n" ++
        "->\n" ++
        "    log info \"quiet {d.zone}\"\n",
        ( pred(P::in) is semidet :-
            Schemas = author_schemas(P),
            list.length(Schemas) = 3,
            list.index0(Schemas, 0, Tick),
            expand(interns(P), schema_name_ref(Tick ^ s_name),
                "$ClockTick"),
            Betas = beta_nodes(network(P)),
            list.length(Betas) = 3,
            list.index0(Betas, 0, DoorBeta),
            list.index0(Betas, 1, TickBeta),
            list.index0(Betas, 2, NotBeta),
            TickBeta ^ bn_parent = yes(DoorBeta),
            TickBeta ^ bn_tests = [],
            TickBeta ^ bn_negative = no,
            NotBeta ^ bn_parent = yes(TickBeta),
            NotBeta ^ bn_negative = yes
        ), !T, !IO),

    % [LTAC.6.2.2]: a nested `after` is emitted from its parent clause's
    % follow-up, after the body and before the timer retract, and its
    % follow-up is allocated first. Timers are declared outer then inner. The
    % rule's TerminalNode comes first, then the outer follow-up, then the inner
    % one it induced: [RLOW.14.7]'s order at every level, not allocation order.
    check_source_loaded("[LTAC.6.2.2] a nested `after` emits from its parent's follow-up",
        "schema Motion scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    state: Bool mutable\n" ++
        "\n" ++
        "rule cascading:\n" ++
        "    Motion m where m.state == true\n" ++
        "->\n" ++
        "    log info \"step 0\"\n" ++
        "    after 5_min:\n" ++
        "        log info \"step 1\"\n" ++
        "        after 10_min:\n" ++
        "            log info \"step 2\"\n",
        ( pred(P::in) is semidet :-
            Schemas = author_schemas(P),
            list.length(Schemas) = 4,
            list.index0(Schemas, 1, Outer),
            list.index0(Schemas, 2, Inner),
            expand(interns(P), schema_name_ref(Outer ^ s_name),
                "$Timer_cascading_0"),
            expand(interns(P), schema_name_ref(Inner ^ s_name),
                "$Timer_cascading_0_0"),
            Terms = terminal_nodes(network(P)),
            list.length(Terms) = 3,
            list.index0(Terms, 0, ParentTerm),
            list.index0(Terms, 1, OuterTerm),
            list.index0(Terms, 2, InnerTerm),
            list.length(InnerTerm ^ tn_inline_actions) = 2,
            OuterActs = OuterTerm ^ tn_inline_actions,
            list.length(OuterActs) = 3,
            list.index0(OuterActs, 1, NestedEmit),
            NestedEmit = ia_assert(_, _, _, _),
            list.length(ParentTerm ^ tn_inline_actions) = 2
        ), !T, !IO),

    % [LRST.2.1]: `after ... as <key>` sweeps its own timer schema on the key
    % ahead of the emit, so a re-fire with the same key retracts the pending
    % timer; the key is the timer's `corr`.
    check_source_loaded("[LRST.2.1] `after ... as` sweeps its timer on the key",
        "schema Motion scope logical:\n" ++
        "    target_light: String key\n" ++
        "    state: String mutable\n" ++
        "\n" ++
        "rule motion_light:\n" ++
        "    Motion m where m.state == \"on\"\n" ++
        "->\n" ++
        "    log info \"on\"\n" ++
        "    after 5_min as m.target_light:\n" ++
        "        log info \"timed out\"\n",
        ( pred(P::in) is semidet :-
            Terms = terminal_nodes(network(P)),
            list.length(Terms) = 2,
            % The parent's TerminalNode first ([RLOW.14.7]).
            list.index0(Terms, 0, ParentTerm),
            Acts = ParentTerm ^ tn_inline_actions,
            list.length(Acts) = 3,
            list.index0(Acts, 1, Sweep),
            Sweep = ia_internal(fn_retract_corr, SweepArgs),
            list.length(SweepArgs) = 3,
            list.index0(Acts, 2, Emit),
            Emit = ia_assert(_, _, _, _)
        ), !T, !IO),

    % [LTAC.3.5], [LRST.4.5]: with both an `as` key and a captured read, the
    % key is the correlation (`top_after_corr`) and both facts are swept on
    % it. Two sweeps: the timer's alone would leave the superseded capture,
    % and the body would run twice.
    check_source_loaded(
        "[LTAC.3.5] `after ... as` with a captured read sweeps timer AND capture",
        "schema Request scope logical:\n" ++
        "    entity_id: String key\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Request e\n" ++
        "->\n" ++
        "    log info \"start\"\n" ++
        "    after 30_s as e.entity_id:\n" ++
        "        log info \"timeout for {e.entity_id}\"\n",
        ( pred(P::in) is semidet :-
            Terms2 = terminal_nodes(network(P)),
            % The parent's TerminalNode first ([RLOW.14.7]).
            list.index0(Terms2, 0, ParentTerm2),
            Acts2 = ParentTerm2 ^ tn_inline_actions,
            % No `fn_gensym` bind: the key is the correlation, so a gensym
            % would be bound and read by nothing.
            not list.member(ia_bind(_, e_call(fn_gensym, [])), Acts2),
            % Both sweeps, and both on the SAME correlation expression.
            list.filter(
                ( pred(A2::in) is semidet :-
                    A2 = ia_internal(fn_retract_corr, _)
                ), Acts2, Sweeps2),
            list.length(Sweeps2) = 2,
            list.index0(Sweeps2, 0, ia_internal(_, [_, _, CorrA])),
            list.index0(Sweeps2, 1, ia_internal(_, [_, _, CorrB])),
            CorrA = CorrB
        ), !T, !IO),

    % [LCST.4.5.2]: a `::` cast lowers to the builtin its (source, target)
    % pair names, and a fallible one feeds `??` like any `T?`.
    check_source_loaded("[LCST.4.5.2] `::Float` and `::Int?` lower to their builtins",
        "schema Reading scope logical:\n" ++
        "    id: Int key\n" ++
        "    qty: Int mutable\n" ++
        "    text: String mutable\n" ++
        "\n" ++
        "schema Out scope logical:\n" ++
        "    id: Int key\n" ++
        "    ratio: Float mutable\n" ++
        "    parsed: Int mutable\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Reading x\n" ++
        "->\n" ++
        "    emit Out logical id: x.id ratio: x.qty::Float parsed: x.text::Int? ?? 0\n",
        ( pred(P::in) is semidet :-
            Terms = terminal_nodes(network(P)),
            list.length(Terms) = 1,
            list.index0(Terms, 0, Term),
            Emits = Term ^ tn_inline_actions,
            list.length(Emits) = 1,
            list.index0(Emits, 0, Emit),
            Emit = ia_assert(_, _, Assigns, _),
            list.length(Assigns) = 3,
            list.index0(Assigns, 1, Ratio),
            Ratio = slot_assign(_, e_call(fn_int_to_float, _)),
            list.index0(Assigns, 2, Parsed),
            Parsed = slot_assign(_, e_coalesce(e_call(fn_string_to_int, _), _))
        ), !T, !IO),

    % [LCST.4.5.6]: `Float::String` lowers to `FN_FLOAT_TO_STRING`.
    check_source_loaded("[LCST.4.5.6] `Float::String` lowers to its builtin",
        "schema Reading scope logical:\n" ++
        "    id: Int key\n" ++
        "    ratio: Float mutable\n" ++
        "\n" ++
        "schema Out scope logical:\n" ++
        "    id: Int key\n" ++
        "    label: String mutable\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Reading x\n" ++
        "->\n" ++
        "    emit Out logical id: x.id label: x.ratio::String\n",
        ( pred(P::in) is semidet :-
            Terms = terminal_nodes(network(P)),
            list.index0(Terms, 0, Term),
            list.index0(Term ^ tn_inline_actions, 0, Emit),
            Emit = ia_assert(_, _, Assigns, _),
            list.index0(Assigns, 1, Label),
            Label = slot_assign(_, e_call(fn_float_to_string, _))
        ), !T, !IO),

    % [LCCO.5.1] / [LCCO.5.2] / [LCCO.5.4] END TO END, through this runtime:
    % the outer rule fires and its `Trig` is retracted before the response
    % arrives, and the `on` body still logs the parent binding it read --
    % the snapshot, from the capture fact joined on the correlation.
    check_source_loaded("[LCCO.5.4] a continuation body reads its parent's snapshot",
        "schema Ok scope ttl 1_h:\n" ++
        "    corr: String\n" ++
        "    ok: Bool\n" ++
        "\n" ++
        "service svc.check:\n" ++
        "    kwarg entity_id: String\n" ++
        "    response Ok\n" ++
        "\n" ++
        "schema Trig scope logical:\n" ++
        "    entity_id: String key\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Trig t\n" ++
        "->\n" ++
        "    call svc.check entity_id: t.entity_id cooldown: 30_s\n" ++
        "        on response.ok == true:\n" ++
        "            log critical \"ok {t.entity_id}\"\n",
        continuation_logs_snapshot, !T, !IO),

    % LGRA.13.11: an omitted nullable slot on an emit is `null`, the compiler's
    % fill (`dsc.rete.lgra_13_11_null_fills`), not the empty byte string.
    % `is null` is the total test ([LNUL.4.4]) that tells them apart.
    check_source_loaded("LGRA.13.11 an omitted `Bytes?` slot on an emit is null",
        "schema Trig scope logical:\n" ++
        "    id: String key\n" ++
        "\n" ++
        "schema Blob scope ttl 1_h:\n" ++
        "    name: String\n" ++
        "    data: Bytes?\n" ++
        "\n" ++
        "rule raise:\n" ++
        "    Trig t\n" ++
        "->\n" ++
        "    emit Blob name: t.id\n" ++
        "\n" ++
        "rule absent:\n" ++
        "    Blob b where b.data is null\n" ++
        "->\n" ++
        "    log info \"absent {b.name}\"\n",
        omitted_bytes_is_null, !T, !IO),

    % [LSTO.4.3.1a]: `cached()` in a `where`, its key interpolated -- the
    % corpus's `LSTO.4.3.1_cached_interp` -- reads the cache under the
    % `str_cat` of the key's runs and sites.
    check_source_loaded("[LSTO.4.3.1a] an interpolated `cached` key lowers to a str_cat",
        "schema DispatchCommand scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    device_id: String mutable\n" ++
        "    revision: Int mutable\n" ++
        "\n" ++
        "rule dispatch:\n" ++
        "    DispatchCommand d where d.revision != cached(\"last-cmd-{d.device_id}\")\n" ++
        "->\n" ++
        "    log info \"dispatch\"\n",
        ( pred(P::in) is semidet :-
            [Beta] = beta_nodes(network(P)),
            list.member(Test, Beta ^ bn_tests),
            contains_cache_concat(Test)
        ), !T, !IO),

    % [LINT.3.1.1]: `t in (a..b)` is `a <= t and t < b` on the beta, inside
    % the interval's check, `FN_INTERVAL_CHECK(a, b, ...)` ([RLOW.6.1.7]). The
    % check ENCLOSES the comparisons: a check that were one more conjunct of
    % the `and` would leave the test an `and`, and this would fail.
    check_source_loaded("[LINT.3.1.1] `in` lowers to its endpoint comparisons",
        "schema Sample scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    val: Int mutable\n" ++
        "    lo: Int mutable\n" ++
        "    hi: Int mutable\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Sample s where s.val in (s.lo..s.hi)\n" ++
        "->\n" ++
        "    log info \"in range\"\n",
        ( pred(P::in) is semidet :-
            Betas = beta_nodes(network(P)),
            list.length(Betas) = 1,
            list.index0(Betas, 0, Beta),
            Tests = Beta ^ bn_tests,
            list.length(Tests) = 1,
            list.index0(Tests, 0, Test),
            Test = e_call(fn_interval_check, [_, _, Value]),
            Value = e_binop(op_and, e_binop(op_le, _, _), e_binop(op_lt, _, _))
        ), !T, !IO),

    % [LINT.3.2.1] and [LINT.4.1]: `contains` is two `<=`; `overlaps` is four
    % strict comparisons, both non-emptiness conjuncts included, each inside
    % both intervals' check ([RLOW.6.1.7]).
    check_source_loaded("[LINT.4.1] `contains` and `overlaps` lower to endpoints",
        "schema Span scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    lo: Int mutable\n" ++
        "    hi: Int mutable\n" ++
        "\n" ++
        "rule outer:\n" ++
        "    Span a\n" ++
        "    Span b where (a.lo..a.hi) contains (b.lo..b.hi)\n" ++
        "->\n" ++
        "    log info \"inner\"\n" ++
        "\n" ++
        "rule shared:\n" ++
        "    Span c\n" ++
        "    Span d where (c.lo..c.hi) overlaps (d.lo..d.hi)\n" ++
        "->\n" ++
        "    log info \"overlap\"\n",
        ( pred(P::in) is semidet :-
            Betas = beta_nodes(network(P)),
            list.length(Betas) = 4,
            list.index0(Betas, 1, Contains),
            ContainsTests = Contains ^ bn_tests,
            list.length(ContainsTests) = 1,
            list.index0(ContainsTests, 0, ContainsTest),
            ContainsTest = e_call(fn_interval_check, [_, _, _, _, Contained]),
            Contained = e_binop(op_and, e_binop(op_le, _, _),
                e_binop(op_le, _, _)),
            list.index0(Betas, 3, Overlaps),
            OverlapsTests = Overlaps ^ bn_tests,
            list.length(OverlapsTests) = 1,
            list.index0(OverlapsTests, 0, OverlapsTest),
            OverlapsTest = e_call(fn_interval_check, [_, _, _, _, Overlap]),
            Overlap = e_binop(op_and,
                e_binop(op_and, e_binop(op_lt, _, _), e_binop(op_lt, _, _)),
                e_binop(op_and, e_binop(op_lt, _, _), e_binop(op_lt, _, _)))
        ), !T, !IO),

    % [LSER.16.1]: an aggregation called as a function is the companion read's
    % builtin, five arguments, the call's window last. Reading a series makes
    % the `where` time-dependent ([LTIM.2.4.1]), so the test is the
    % terminal's fire guard behind a `$ClockTick` tail beta, the shape a
    % clock read takes.
    check_source_loaded("[LSER.16.1] `count(r.val)` is `FN_SERIES_COUNT`",
        "use default\n" ++
        "\n" ++
        "schema Reading scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    val: Float mutable\n" ++
        "\n" ++
        "series Reading.val:\n" ++
        "    count sliding 5_s\n" ++
        "\n" ++
        "rule check:\n" ++
        "    Reading r where count(r.val) >= 3\n" ++
        "->\n" ++
        "    log info \"count reached\"\n",
        ( pred(P::in) is semidet :-
            [Pattern, TickBeta] = beta_nodes(network(P)),
            Pattern ^ bn_tests = [],
            TickBeta ^ bn_parent = yes(Pattern),
            TickBeta ^ bn_tests = [],
            [Term] = terminal_nodes(network(P)),
            Term ^ tn_guard = yes(Test),
            Test = e_binop(op_ge, Call, e_lit(int(3i64))),
            Call = e_call(fn_series_count, CallArgs),
            list.length(CallArgs) = 5,
            list.index0(CallArgs, 4, WindowArg),
            WindowArg = e_lit(int(5000000000i64))
        ), !T, !IO),

    % [LTAC.3.5]: an `after` body reading `m.entity_id` gets a capture fact.
    % The parent binds one `ds_gensym`, asserts the timer and the capture with
    % it, and snapshots the slot; the follow-up reads the slot from the
    % capture (token position 2) and retracts the timer and the capture.
    check_source_loaded("[LTAC.3.5] an `after` body's parent binding is captured",
        "schema Motion scope logical:\n" ++
        "    entity_id: String key\n" ++
        "\n" ++
        "rule auto_off:\n" ++
        "    Motion m\n" ++
        "->\n" ++
        "    log info \"on\"\n" ++
        "    after 5_min:\n" ++
        "        log info \"off: {m.entity_id}\"\n",
        ( pred(P::in) is semidet :-
            [_, _, Capture, _] = author_schemas(P),
            expand(interns(P), schema_name_ref(Capture ^ s_name),
                "$CaptureBindings_auto_off_after_0"),
            [ParentTerm, FollowTerm] = terminal_nodes(network(P)),
            ParentTerm ^ tn_binds = 1,
            ParentTerm ^ tn_inline_actions = [ia_log(_, _),
                ia_bind(_, e_call(fn_gensym, [])),
                ia_assert(plain, _, [_, slot_assign(_, e_bind_ref(_))], no),
                ia_assert(plain, _, [slot_assign(_, e_bind_ref(_)),
                    slot_assign(_, e_slot(token_fact(0), slot(_)))], no)],
            FollowTerm ^ tn_inline_actions = [ia_log(_, _),
                ia_internal(fn_retract_token_fact, [e_lit(int(0i64))]),
                ia_internal(fn_retract_token_fact, [e_lit(int(2i64))])]
        ), !T, !IO),

    % A `Json` path is captured whole: the parent snapshots the `json_path`
    % read into `w_payload_user_id` ([LCCO.5.5]'s flattening), `String`-typed,
    % and the follow-up reads that slot.
    check_source_loaded("[LTAC.3.5] an `after` body's Json path is captured",
        "schema Webhook scope logical:\n" ++
        "    payload: Json key\n" ++
        "\n" ++
        "rule fire:\n" ++
        "    Webhook w\n" ++
        "->\n" ++
        "    log info \"fire\"\n" ++
        "    after 100_ms:\n" ++
        "        log info \"got:{w.payload.user.id}\"\n",
        ( pred(P::in) is semidet :-
            schema_called(P, "$CaptureBindings_fire_after_0", Capture),
            [_, CapSlot] = slot_commons(Capture),
            expand(interns(P), CapSlot ^ sc_name, "w_payload_user_id"),
            CapSlot ^ sc_kind = k_string,
            [ParentTerm, FollowTerm] = terminal_nodes(network(P)),
            ParentTerm ^ tn_inline_actions = [_, _, _,
                ia_assert(plain, _, [_, slot_assign(_, Snap)], no)],
            ( Snap = e_call(fn_json_path, [_, e_lit(str(Path))])
            ; Snap = e_tainted(e_call(fn_json_path, [_, e_lit(str(Path))]))
            ),
            expand(interns(P), Path, "user.id"),
            FollowTerm ^ tn_inline_actions = [ia_log(_, e_interp([_,
                fp_value(SnapPrim)])) | _],
            SnapPrim ^ vp_value = e_slot(token_fact(2), slot(_))
        ), !T, !IO),

    % A bare binding is captured as the fact itself: `m_FACTREF`, typed by the
    % parent's schema, and the follow-up's `m` reads it rather than the
    % capture fact the view sits over. `Trace` is `ttl`: a `logical` emit in
    % an `after` body is refused ([LLOG.11.9]), and the capture is the same.
    check_source_loaded("[LTAC.3.5] an `after` body's bare binding is captured",
        "schema Motion scope logical:\n" ++
        "    state: Bool key\n" ++
        "\n" ++
        "schema Trace scope ttl 1_h:\n" ++
        "    target: Motion\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Motion m where m.state == true\n" ++
        "->\n" ++
        "    log info \"fired\"\n" ++
        "    after 100_ms:\n" ++
        "        emit Trace target: m\n",
        ( pred(P::in) is semidet :-
            schema_called(P, "$CaptureBindings_r_after_0", Capture),
            [_, CapSlot] = slot_commons(Capture),
            expand(interns(P), CapSlot ^ sc_name, "m_FACTREF"),
            CapSlot ^ sc_kind = k_schema(_),
            [ParentTerm, FollowTerm] = terminal_nodes(network(P)),
            ParentTerm ^ tn_inline_actions = [_, _, _,
                ia_assert(plain, _, [_, slot_assign(_,
                    e_slot(token_fact(0), whole_fact))], no)],
            FollowTerm ^ tn_inline_actions = [ia_assert(_, _,
                [slot_assign(_, e_slot(token_fact(2), slot(_)))], _) | _]
        ), !T, !IO),

    % `50_call_cont.ds`: the outer call carries the generated correlation, the
    % outer rule emits the timeout timer after sweeping its prior one on the
    % same key ([LRST.2.2]), and each continuation is a sibling after the outer
    % terminal, the timeout's followed by its two discharge rules
    % ([LCCO.7.6]).
    check_source_loaded("[LCCO.3.1] a call's continuations are sibling rules",
        "schema Forecast scope ttl 1_h:\n" ++
        "    corr: String\n" ++
        "    tomorrow_max: Int\n" ++
        "\n" ++
        "service weather.get_forecast:\n" ++
        "    kwarg entity_id: String\n" ++
        "    response Forecast\n" ++
        "\n" ++
        "service switch.turn_on:\n" ++
        "    kwarg entity_id: String\n" ++
        "    no response\n" ++
        "\n" ++
        "schema Trig scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "rule with_continuations:\n" ++
        "    Trig\n" ++
        "->\n" ++
        "    call weather.get_forecast entity_id: \"weather.home\" cooldown: 1_h as \"fc\"\n" ++
        "        on response.tomorrow_max < 60:\n" ++
        "            call switch.turn_on entity_id: \"switch.preheater\" cooldown: 1_h\n" ++
        "        timeout 30_s:\n" ++
        "            log critical \"forecast never arrived\"\n" ++
        "        error adapter:\n" ++
        "            log error \"adapter failed\"\n",
        ( pred(P::in) is semidet :-
            [Outer, OnSib, TimeoutSib, Answered, Failed, ErrorSib] =
                terminal_nodes(network(P)),
            % No sweep precedes the call: the engine performs it inside
            % `FN_CALL` (RLOW.7.3.8). The one after it is the timer's
            % ([LRST.2.2]).
            Outer ^ tn_inline_actions = [ia_call(_, e_lit(str(CorrRef)), _, _),
                ia_internal(fn_retract_corr, [_, _, e_lit(str(CorrRef))]),
                ia_assert(plain, _, [_, _], no)],
            expand(interns(P), CorrRef, "fc"),
            expand(interns(P), OnSib ^ tn_rule,
                "$with_continuations_response_0"),
            % The sibling's `switch.turn_on` has no `as`, so the sibling's own
            % frame mints its correlation ([LCRS.3.1]): its text, the
            % sibling's own name and `_c0_`, then the bind ([LCCO.3.4]).
            OnSib ^ tn_binds = 1,
            OnSib ^ tn_inline_actions = [ia_bind(Gx, e_call(fn_gensym, [])),
                ia_call(_, e_interp([fp_text("$$with_continuations_response_0_c0_"),
                    fp_value(value_prim(e_bind_ref(Gx),
                    _, _, _, _, _, _))]), _, _)],
            expand(interns(P), TimeoutSib ^ tn_rule,
                "$with_continuations_timeout_0"),
            TimeoutSib ^ tn_guard = yes(_),
            expand(interns(P), Answered ^ tn_rule,
                "$with_continuations_timeout_0_answered"),
            Answered ^ tn_inline_actions =
                [ia_internal(fn_retract_token_fact, [e_lit(int(0i64))])],
            expand(interns(P), Failed ^ tn_rule,
                "$with_continuations_timeout_0_failed"),
            Failed ^ tn_inline_actions =
                [ia_internal(fn_retract_token_fact, [e_lit(int(0i64))])],
            expand(interns(P), ErrorSib ^ tn_rule,
                "$with_continuations_error_0")
        ), !T, !IO),

    % [LCCO.5.2]: a call whose correlation is generated gets the capture fact
    % even with nothing to capture, and its siblings join it; `as "fc"` above
    % is a constant they match directly. The generated-correlation path has
    % no other oracle: the conformance corpus's continuations all write `as`.
    % The fact ([LCCO.5.2]) and its per-activation value ([LCCO.3.4]) are one
    % mechanism, pinned together.
    %
    % The release proxies the join: `one_pattern_sibling` emits it in the arm
    % that builds the capture beta.
    check_source_loaded(
        "[LCCO.5.2] a generated correlation gets a corr-only capture fact",
        "schema Forecast scope ttl 24_h:\n" ++
        "    corr: String\n" ++
        "    ok: Bool\n" ++
        "\n" ++
        "service weather.get_forecast:\n" ++
        "    kwarg entity_id: String\n" ++
        "    response Forecast\n" ++
        "\n" ++
        "schema Trig scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "rule gen_corr:\n" ++
        "    Trig\n" ++
        "->\n" ++
        "    call weather.get_forecast entity_id: \"weather.home\" cooldown: 1_h\n" ++
        "        on response.ok == true:\n" ++
        "            log info \"ok\"\n",
        ( pred(P::in) is semidet :-
            list.find_first_match(
                ( pred(S::in) is semidet :-
                    expand(interns(P), schema_name_ref(S ^ s_name),
                        "$CaptureBindings_gen_corr_c0")
                ), schemas(P), _),
            [Outer, OnSib] = terminal_nodes(network(P)),
            % [LCCO.3.4]: ONE gensym, bound before the call, and the call's
            % correlation renders `$gen_corr_c0_`, then that bind.
            Outer ^ tn_binds = 1,
            % [LCCO.5.3]: the capture lives as long as the response schema
            % its `on` sibling matches, `Forecast`'s 24_h. No call compiles
            % to a sweep (RLOW.7.3.8); the engine sweeps inside `FN_CALL`.
            Outer ^ tn_inline_actions = [ia_bind(Gx, e_call(fn_gensym, [])),
                ia_call(_, CallCorr, _, yes(_)),
                ia_assert(plain, _, [slot_assign(_, CapCorr)],
                    yes(e_lit(int(86400000000000i64))))],
            CallCorr = e_interp([fp_text("$gen_corr_c0_"),
                fp_value(value_prim(e_bind_ref(Gx), _, _, _, _, _,
                    ft_canonical))]),
            % The same expression, not an equal one minted twice: `fn_gensym`
            % advances on every evaluation. `corr` alone: one slot assign.
            CallCorr = CapCorr,
            expand(interns(P), OnSib ^ tn_rule, "$gen_corr_response_0"),
            % No correlation test on the sibling's beta: the join to the
            % capture fact is the tie ([LCCO.3.3]), and the release shows it.
            OnSib ^ tn_inline_actions = [ia_log(_, _),
                ia_internal(fn_retract_token_fact, [e_lit(int(1i64))])]
        ), !T, !IO),

    % [LCCO.3.8]: a call with continuations nested in a continuation body
    % carries a literal `as`, or is refused at validation: its capture fact
    % and timer would need the outer rule's frame.
    check_refused("[LCCO.3.8] a nested continued call with no `as`",
        nested_continued_source(""), dv_nested_continued_call_as, !T, !IO),

    % [LCCO.3.8], [LCCO.3.7] item 2: with a literal `as` it lowers, carrying
    % the literal, and takes no counter value -- the sibling whose body holds
    % it has an empty bind frame.
    check_source_loaded("[LCCO.3.8] a nested continued call with a literal "
            ++ "`as` takes no value",
        nested_continued_source(" as \"probe\""),
        ( pred(P::in) is semidet :-
            list.find_first_match(
                ( pred(N::in) is semidet :-
                    expand(interns(P), N ^ tn_rule,
                        "$nested_lit_response_0")
                ), terminal_nodes(network(P)), OnSib),
            OnSib ^ tn_binds = 0,
            list.find_first_match(
                ( pred(IA::in) is semidet :-
                    IA = ia_call(_, e_lit(str(Corr)), _, _),
                    expand(interns(P), Corr, "probe")
                ), OnSib ^ tn_inline_actions, _)
        ), !T, !IO),

    % [LCCO.3.4]: an author's `as` passes through unchanged, and the
    % continuations join on the same decoded value the call carries -- here
    % checked through the timeout timer's `corr`, the siblings' key. The
    % service answers with `Forecast`: a `timeout` on a `no response` service
    % is refused ([LCRS.17.2]).
    check_source_loaded("[LCCO.3.4] a continuation joins on the decoded `as`",
        "schema Forecast scope ttl 1_h:\n" ++
        "    corr: String\n" ++
        "\n" ++
        "service weather.get_forecast:\n" ++
        "    kwarg entity_id: String\n" ++
        "    response Forecast\n" ++
        "\n" ++
        "schema Trig scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "rule escaped_corr:\n" ++
        "    Trig\n" ++
        "->\n" ++
        "    call weather.get_forecast entity_id: \"weather.home\" cooldown: 1_h as \"a\\\"b\"\n" ++
        "        timeout 30_s:\n" ++
        "            log critical \"late\"\n",
        ( pred(P::in) is semidet :-
            [Outer | _] = terminal_nodes(network(P)),
            Outer ^ tn_inline_actions = [ia_call(_, e_lit(str(CallCorr)), _, _),
                ia_internal(fn_retract_corr, [_, _, e_lit(str(SweepCorr))]),
                ia_assert(plain, _, [_, slot_assign(_, e_lit(str(TimerCorr)))],
                    no)],
            expand(interns(P), CallCorr, "a\"b"),
            expand(interns(P), SweepCorr, "a\"b"),
            expand(interns(P), TimerCorr, "a\"b")
        ), !T, !IO),

    % [LCCO.4.1]: `<N>` runs on across the rule's calls, so the second call's
    % `on` and `timeout` are `_1`. Each timer is tied to its call by the
    % correlation the outer rule asserts it with, and each sibling by the body
    % only its own call wrote. A count restarted per call fails here.
    % @spec [LCCO.4.1]
    check_source_loaded("[LCCO.4.1] sibling numbering runs across a rule's "
            ++ "calls",
        ok_services
            ++ "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule r:\n"
            ++ "    Trig\n"
            ++ "->\n"
            ++ "    call weather.get_forecast entity_id: \"w\" cooldown: 1_h as \"fc\"\n"
            ++ "        on response.ok:\n"
            ++ "            log info \"fc ok\"\n"
            ++ "        timeout 5_s:\n"
            ++ "            log info \"fc late\"\n"
            ++ "    call switch.turn_on entity_id: \"s\" cooldown: 1_h as \"sw\"\n"
            ++ "        on response.ok:\n"
            ++ "            log info \"sw ok\"\n"
            ++ "        timeout 5_s:\n"
            ++ "            log info \"sw late\"\n",
        ( pred(P::in) is semidet :-
            [Outer, R0, T0, A0, F0, R1, T1, A1, F1] =
                terminal_nodes(network(P)),
            % The two calls, then each timer after its sweep ([LRST.2.2]):
            % the timers come "after its immediate actions" ([LCCO.7.2]).
            Outer ^ tn_inline_actions = [
                ia_call(_, e_lit(str(Call0)), _, _),
                ia_call(_, e_lit(str(Call1)), _, _),
                ia_internal(fn_retract_corr, [_, _, _]),
                ia_assert(plain, Timer0, [_, slot_assign(_, e_lit(str(Corr0)))],
                    no),
                ia_internal(fn_retract_corr, [_, _, _]),
                ia_assert(plain, Timer1, [_, slot_assign(_, e_lit(str(Corr1)))],
                    no)],
            expand(interns(P), Call0, "fc"),
            expand(interns(P), Timer0, "$Timer_r_timeout_0"),
            expand(interns(P), Corr0, "fc"),
            expand(interns(P), Call1, "sw"),
            expand(interns(P), Timer1, "$Timer_r_timeout_1"),
            expand(interns(P), Corr1, "sw"),
            expand(interns(P), R0 ^ tn_rule, "$r_response_0"),
            list.member(LogR0, R0 ^ tn_inline_actions),
            LogR0 = ia_log(_, e_lit(str(MsgR0))),
            expand(interns(P), MsgR0, "fc ok"),
            expand(interns(P), T0 ^ tn_rule, "$r_timeout_0"),
            list.member(LogT0, T0 ^ tn_inline_actions),
            LogT0 = ia_log(_, e_lit(str(MsgT0))),
            expand(interns(P), MsgT0, "fc late"),
            expand(interns(P), A0 ^ tn_rule, "$r_timeout_0_answered"),
            expand(interns(P), F0 ^ tn_rule, "$r_timeout_0_failed"),
            expand(interns(P), R1 ^ tn_rule, "$r_response_1"),
            list.member(LogR1, R1 ^ tn_inline_actions),
            LogR1 = ia_log(_, e_lit(str(MsgR1))),
            expand(interns(P), MsgR1, "sw ok"),
            expand(interns(P), T1 ^ tn_rule, "$r_timeout_1"),
            list.member(LogT1, T1 ^ tn_inline_actions),
            LogT1 = ia_log(_, e_lit(str(MsgT1))),
            expand(interns(P), MsgT1, "sw late"),
            expand(interns(P), A1 ^ tn_rule, "$r_timeout_1_answered"),
            expand(interns(P), F1 ^ tn_rule, "$r_timeout_1_failed")
        ), !T, !IO),

    % [LCCO.7.2]: the timer carries what its body reads (`t_v`, from `t`), and
    % the sibling joins no capture: with one `timeout` clause it releases the
    % capture on the timer's `corr` ([LSCP.2.4.1]), then retracts its timer
    % (position 0), last, since the release reads it. A sibling that joined
    % the capture releases it at position 2, and fails this.
    % @spec [LCCO.7.2]
    check_source_loaded("[LCCO.7.2] a timeout timer carries what its body "
            ++ "reads, and its sibling joins no capture",
        ok_services
            ++ "schema Trig scope logical:\n    v: Int key\n\n"
            ++ "rule r:\n"
            ++ "    Trig t\n"
            ++ "->\n"
            ++ "    call weather.get_forecast entity_id: \"w\" cooldown: 1_h as \"fc\"\n"
            ++ "        timeout 5_s:\n"
            ++ "            log info \"late {t.v}\"\n",
        % Each list is read by position from a bound value: matching one
        % against a literal of unbound variables here was refused as a mode
        % error (MERCURY.md 14).
        ( pred(P::in) is semidet :-
            slot_names(P, "$Timer_r_timeout_0") = ["fire_at", "corr", "t_v"],
            slot_names(P, "$CaptureBindings_r_c0") = ["corr", "t_v"],
            Nodes = terminal_nodes(network(P)),
            list.length(Nodes) = 4,
            list.index0(Nodes, 0, Outer),
            list.index0(Nodes, 1, Sib),
            list.member(TimerAssert, Outer ^ tn_inline_actions),
            TimerAssert = ia_assert(plain, TimerRef, TimerSlots, no),
            expand(interns(P), TimerRef, "$Timer_r_timeout_0"),
            list.length(TimerSlots) = 3,
            list.index0(TimerSlots, 2, TimerV),
            TimerV = slot_assign(_, e_slot(token_fact(0), slot(_))),
            expand(interns(P), Sib ^ tn_rule, "$r_timeout_0"),
            Reversed = list.reverse(Sib ^ tn_inline_actions),
            list.index0(Reversed, 0, RetractTimer),
            list.index0(Reversed, 1, Release),
            RetractTimer = ia_internal(fn_retract_token_fact, RetractArgs),
            RetractArgs = [e_lit(int(0i64))],
            Release = ia_internal(fn_retract_corr, ReleaseArgs),
            list.length(ReleaseArgs) = 3,
            list.index0(ReleaseArgs, 0, CapArg),
            CapArg = e_lit(str(CapRef)),
            list.index0(ReleaseArgs, 1, CorrSlotArg),
            CorrSlotArg = e_lit(str(CorrRef)),
            list.index0(ReleaseArgs, 2, CorrArg),
            CorrArg = e_slot(token_fact(0), slot(_)),
            expand(interns(P), CapRef, "$CaptureBindings_r_c0"),
            expand(interns(P), CorrRef, "corr"),
            not list.member(ia_internal(fn_retract_token_fact,
                [e_lit(int(2i64))]), Sib ^ tn_inline_actions)
        ), !T, !IO),

    % RLOW.7.3.8: a call compiles to its gated `FN_CALL` alone, with no
    % `FN_RETRACT_CORR`; the engine sweeps inside `FN_CALL` when the gate
    % admits it. A call with no `as` carries its generated correlation, from
    % the `fn_gensym` bind before it ([LCRS.3.1]).
    check_source_loaded("RLOW.7.3.8: a correlated call compiles to no sweep",
        "schema Forecast scope ttl 1_h:\n" ++
        "    corr: String\n" ++
        "    high: Int\n" ++
        "\n" ++
        "service weather.get_forecast:\n" ++
        "    kwarg entity_id: String\n" ++
        "    response Forecast\n" ++
        "\n" ++
        "schema Trig scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "rule correlated:\n" ++
        "    Trig\n" ++
        "->\n" ++
        "    call weather.get_forecast entity_id: \"weather.home\" cooldown: 1_h as \"fc\"\n" ++
        "\n" ++
        "rule fire_and_forget:\n" ++
        "    Trig\n" ++
        "->\n" ++
        "    call weather.get_forecast entity_id: \"weather.home\" cooldown: 1_h\n",
        ( pred(P::in) is semidet :-
            [Correlated, Plain] = terminal_nodes(network(P)),
            Correlated ^ tn_inline_actions = [
                ia_call(_, e_lit(str(K3)), _, yes(_))],
            expand(interns(P), K3, "fc"),
            Plain ^ tn_inline_actions = [ia_bind(Gx, e_call(fn_gensym, [])),
                ia_call(_, CallCorr, _, yes(_))],
            CallCorr = e_interp([fp_text("$fire_and_forget_c0_"),
                fp_value(value_prim(e_bind_ref(Gx), _, _, _, _, _,
                    ft_canonical))])
        ), !T, !IO),

    % RLOW.4.6.6.1 / [IRET.25.5.1]: a `cooldown:` call carries its gate --
    % the `<rule>#call<N>` tracker, then the declared `key` slot of the one
    % `logical` fact the rule binds (`Trig.v`), then the window, and NOTHING
    % after it: both runtimes read the window from the last argument. A
    % `nocooldown` call in the same rule carries none, and N counts only the
    % `cooldown:` calls, so the second gated call is `#call1`.
    check_source_loaded("RLOW.4.6.6.1 a cooldown: call is gated per call site",
        "service svc.a:\n" ++
        "    kwarg n: Int\n" ++
        "    no response\n" ++
        "\n" ++
        "schema Trig scope logical:\n" ++
        "    v: Int key\n" ++
        "    w: Int mutable\n" ++
        "\n" ++
        "rule gated:\n" ++
        "    Trig t\n" ++
        "->\n" ++
        "    call svc.a n: t.w cooldown: 1_h\n" ++
        "    call svc.a n: 2 nocooldown\n" ++
        "    call svc.a n: 3 cooldown: 30_s\n",
        % None of the three has an `as`, so each has a `fn_gensym` bind, in
        % call order, ahead of every call: a gated call takes its value
        % whether or not the gate admits it ([LCRS.3.1]).
        ( pred(P::in) is semidet :-
            [Term] = terminal_nodes(network(P)),
            Term ^ tn_binds = 3,
            Term ^ tn_inline_actions = [
                ia_bind(_, e_call(fn_gensym, [])),
                ia_bind(_, e_call(fn_gensym, [])),
                ia_bind(_, e_call(fn_gensym, [])),
                ia_call(_, _, _, yes([e_lit(str(T0)), e_slot(_, K0),
                    e_lit(int(3600000000000i64))])),
                ia_call(_, _, _, no),
                ia_call(_, _, _, yes([e_lit(str(T1)), e_slot(_, K1),
                    e_lit(int(30000000000i64))]))],
            expand(interns(P), T0, "gated#call0"),
            expand(interns(P), T1, "gated#call1"),
            K0 = K1
        ), !T, !IO),

    % [LGRA.2.8.2]: a call's `cooldown:` and its `timeout` take a `time_expr`,
    % and a `time` const is read for its value, as a `within` reads one
    % (`dsc.dstest.lgra_2_8_1_time_value_ns`). The gate's window, its last
    % argument, is 30 s and the timer fires 5 s on. Both used to be read as a
    % unit literal only, so the call had no gate and no timer was armed.
    ConstDurations = ( func(Cool, Late) =
        "const W = 30_s\n" ++
        "const T = 5_s\n" ++
        "const N = 5\n" ++
        "\n" ++
        "schema Reply scope ttl 1_h:\n" ++
        "    corr: String\n" ++
        "\n" ++
        "service svc.a:\n" ++
        "    kwarg n: Int\n" ++
        "    response Reply\n" ++
        "\n" ++
        "schema Trig scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "rule gated:\n" ++
        "    Trig\n" ++
        "->\n" ++
        "    call svc.a n: 1 cooldown: " ++ Cool ++ " as \"c\"\n" ++
        "        timeout " ++ Late ++ ":\n" ++
        "            log info \"late\"\n" ),
    check_source_loaded("[LGRA.2.8.2] a `time` const is a call's `cooldown:` "
            ++ "window and its `timeout`'s delay",
        ConstDurations("W", "T"),
        ( pred(P::in) is semidet :-
            [Outer | _] = terminal_nodes(network(P)),
            Acts = Outer ^ tn_inline_actions,
            list.member(Call, Acts),
            Call = ia_call(_, _, _, yes(Gate)),
            Gate = [e_lit(str(Tracker)) | _],
            list.last(Gate, e_lit(int(30000000000i64))),
            expand(interns(P), Tracker, "gated#call0"),
            list.member(Timer, Acts),
            Timer = ia_assert(plain, TimerRef, [Fire, _], no),
            Fire = slot_assign(_, e_call(fn_duration_add,
                [e_call(fn_monotonic_ns, []), e_lit(int(5000000000i64))])),
            expand(interns(P), TimerRef, "$Timer_gated_timeout_0")
        ), !T, !IO),

    % The same positions given a const that is no `Duration` are refused by
    % its type ([LGRA.2.8.11]). The other site takes its const above, so each
    % refusal is its own site's.
    check_refused("[LGRA.2.8.11] a `cooldown:` const that is no `Duration` "
            ++ "is a type mismatch",
        ConstDurations("N", "T"), dv_type_mismatch, !T, !IO),
    check_refused("[LGRA.2.8.11] a `timeout` const that is no `Duration` "
            ++ "is a type mismatch",
        ConstDurations("W", "N"), dv_type_mismatch, !T, !IO),

    % A continuation's siblings learn a per-activation correlation only from
    % [LCCO.5.2]'s capture fact, so an interpolated or computed `as` gets the
    % fact with nothing to capture, and the rule lowers.
    check_source_loaded(
        "[LCCO.5.2] an interpolated `as` gets a corr-only capture fact",
        "schema Forecast scope ttl 1_h:\n" ++
        "    corr: String\n" ++
        "\n" ++
        "service weather.get_forecast:\n" ++
        "    kwarg entity_id: String\n" ++
        "    response Forecast\n" ++
        "\n" ++
        "schema Trig scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "rule interp_corr:\n" ++
        "    Trig t\n" ++
        "->\n" ++
        "    call weather.get_forecast entity_id: \"weather.home\" cooldown: 1_h as \"k-{t.v}\"\n" ++
        "        timeout 30_s:\n" ++
        "            log critical \"late\"\n",
        ( pred(P::in) is semidet :-
            list.find_first_match(
                ( pred(S::in) is semidet :-
                    expand(interns(P), schema_name_ref(S ^ s_name),
                        "$CaptureBindings_interp_corr_c0")
                ), schemas(P), _)
        ), !T, !IO),

    % The computed half: a slot read, not a literal; a `String`, since a call's
    % key is one ([LRST.1.4.1]).
    check_source_loaded(
        "[LCCO.5.2] a computed `as` gets a corr-only capture fact",
        "schema Forecast scope ttl 1_h:\n" ++
        "    corr: String\n" ++
        "\n" ++
        "service weather.get_forecast:\n" ++
        "    kwarg entity_id: String\n" ++
        "    response Forecast\n" ++
        "\n" ++
        "schema Trig scope logical:\n" ++
        "    v: String key\n" ++
        "\n" ++
        "rule int_corr:\n" ++
        "    Trig t\n" ++
        "->\n" ++
        "    call weather.get_forecast entity_id: \"weather.home\" cooldown: 1_h as t.v\n" ++
        "        timeout 30_s:\n" ++
        "            log critical \"late\"\n",
        ( pred(P::in) is semidet :-
            list.find_first_match(
                ( pred(S::in) is semidet :-
                    expand(interns(P), schema_name_ref(S ^ s_name),
                        "$CaptureBindings_int_corr_c0")
                ), schemas(P), _)
        ), !T, !IO),

    % A rule-header cooldown is a RuleCooldown atom and a rate-allow fire guard.
    check_source_loaded("[RLOW.4.6.1] a rule cooldown is metadata and a guard",
        "schema Sensor scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    state: Float mutable\n" ++
        "\n" ++
        "rule warm cooldown 5_s:\n" ++
        "    Sensor s\n" ++
        "->\n" ++
        "    log info \"warm {s.entity_id}\"\n",
        ( pred(P::in) is semidet :-
            [Meta] = rule_metas(P),
            Meta ^ rm_rate ^ rc_cooldown = yes(Dur),
            duration_ns(Dur) = 5000000000u64,
            Meta ^ rm_fire_guard = yes(e_call(fn_rate_allow,
                [_, e_slot(token_fact(0), slot(_)), e_lit(int(5000000000i64))]))
        ), !T, !IO),

    % [LCDB.3.3.4]: a `by:` IS the key, in the order written -- here the
    % reverse of declaration order, so the order is the author's and not the
    % schema's. `who` is slot 0 and `ts` slot 1.
    check_source_loaded("[LCDB.3.3.4] a `by:` key is its paths, in order",
        "schema Ev scope ttl 1_h:\n" ++
        "    who: String\n" ++
        "    ts: Time\n" ++
        "\n" ++
        "rule r cooldown 5_s by: e.ts, e.who:\n" ++
        "    Ev e\n" ++
        "->\n" ++
        "    log info \"r\"\n",
        ( pred(P::in) is semidet :-
            [Meta] = rule_metas(P),
            Meta ^ rm_fire_guard = yes(e_call(fn_rate_allow,
                [_, e_slot(token_fact(0), slot(First)),
                 e_slot(token_fact(0), slot(Second)),
                 e_lit(int(5000000000i64))])),
            slot_index_int(First) = 1,
            slot_index_int(Second) = 0
        ), !T, !IO),

    % `by: none` is the one global window: no key arguments at all.
    check_source_loaded("[LCDB.3.3.4] `by: none` passes no key",
        "schema Ev scope ttl 1_h:\n" ++
        "    who: String\n" ++
        "\n" ++
        "rule r cooldown 5_s by: none:\n" ++
        "    Ev e\n" ++
        "->\n" ++
        "    log info \"{e.who}\"\n",
        ( pred(P::in) is semidet :-
            [Meta] = rule_metas(P),
            Meta ^ rm_fire_guard = yes(e_call(fn_rate_allow,
                [_, e_lit(int(5000000000i64))]))
        ), !T, !IO),

    % ── the refusals ───────────────────────────────────────────────────────

    % [LGRA.5.10], [LFAC.1.7.4] require-all, refused by `validate`, since
    % `lower` has no right default for an unmarked slot.
    check_refused("[LGRA.5.10] a `logical` slot with no identity marker",
        "schema Sensor scope logical:\n" ++
        "    entity_id: String key\n" ++
        "    state: Float\n",
        dv_identity_role_required, !T, !IO),

    % [LSCP.2.5.9]: "v1 admits `scope logical ambient` only. The compiler must
    % reject `scope ttl <dur> ambient`". `lc_ttl` carries no ambient flag and
    % SchemaTtl has no field for one, so this is the point where it would be dropped.
    check_refused("[LSCP.2.5.9] `scope ttl <dur> ambient` is refused",
        "schema R scope ttl 30_s ambient:\n" ++
        "    state: Float\n",
        dv_ttl_ambient_not_in_v1, !T, !IO),

    % [LCAP.2.1.5]: a `realtime` source is refused at its `use` line, so no
    % `realtime` artefact is emitted without a RealtimeContract.
    check_refused("[LCAP.2.1.5] a `realtime` source is refused",
        "use realtime\n" ++
        "\n" ++
        "schema R scope logical:\n" ++
        "    v: Int key\n",
        dv_realtime_deferred, !T, !IO),

    % A declared unit of the wrong dimension at a duration position.
    check_refused("[LLEX.12.8] a ttl in a non-time unit is a dimension error",
        "unit dimension span storage float64 base stride\n" ++
        "unit stride: span\n" ++
        "\n" ++
        "schema R scope ttl 30_stride:\n" ++
        "    state: Float\n",
        dv_bad_unit_dimension, !T, !IO),

    % An undeclared suffix at a duration position is the same code
    % ([LLEX.12.8]), as `LUNI.3.1_bad_dim_at_ttl` pins for `30kg`.
    check_refused("[LLEX.12.8] a ttl in an undeclared unit is a dimension error",
        "schema R scope ttl 30_fortnight:\n" ++
        "    state: Float\n",
        dv_bad_unit_dimension, !T, !IO),

    builtin_schema_cases(!T, !IO),
    cycle_cases(!T, !IO),
    front_code_cases(!T, !IO),
    bit_field_range_cases(!T, !IO),
    luni_2_4_1_duration_cases(!T, !IO).

%-----------------------------------------------------------------------------%
% [LUNI.2.4.1]: a duration literal outside int64 nanoseconds, at each position
%-----------------------------------------------------------------------------%

    % `10000000000_s` is 10^19 ns. Each position that takes a duration literal
    % refuses it at the literal, and none reaches a lowering that would wrap it
    % or abort on it.
    %
:- pred luni_2_4_1_duration_cases(tally::in, tally::out, io::di, io::uo)
    is det.

luni_2_4_1_duration_cases(!T, !IO) :-
    Big = "10000000000_s",
    Trig = "schema T scope logical:\n    v: Int key\n    ts: Time\n\n",
    check_refused("[LUNI.2.4.1] a `ttl` past int64 nanoseconds",
        "schema R scope ttl " ++ Big ++ ":\n    state: Float\n",
        dv_constant_out_of_range, !T, !IO),
    check_refused("[LUNI.2.4.1] an `after` delay past int64 nanoseconds",
        Trig ++ "rule r:\n    T t\n->\n    after " ++ Big ++ ":\n"
            ++ "        log info \"y\"\n",
        dv_constant_out_of_range, !T, !IO),
    check_refused("[LUNI.2.4.1] a `within` past int64 nanoseconds",
        Trig ++ "rule r:\n    T within " ++ Big ++ "\n->\n"
            ++ "    log info \"y\"\n",
        dv_constant_out_of_range, !T, !IO),
    check_refused("[LUNI.2.4.1] a `cooldown` past int64 nanoseconds",
        Trig ++ "rule r cooldown " ++ Big ++ ":\n    T\n->\n"
            ++ "    log info \"y\"\n",
        dv_constant_out_of_range, !T, !IO).

%-----------------------------------------------------------------------------%
% [LEXP.3.7.4]: constant arguments outside [LEXP.3.7.3]'s domain
%-----------------------------------------------------------------------------%

:- pred bit_field_range_cases(tally::in, tally::out, io::di, io::uo) is det.

bit_field_range_cases(!T, !IO) :-
    Head = "schema S scope logical:\n    id: String key\n    x: Int mutable\n"
        ++ "    lo: Int mutable\n    w: Int mutable\n\nrule r:\n    S s where ",
    Tail = " > 0\n->\n    log info \"x\"\n",
    check_refused("[LEXP.3.7.4] a negative constant `lo` is refused",
        Head ++ "s.x.bits(-1, s.w)" ++ Tail, dv_bit_field_range, !T, !IO),
    check_refused("[LEXP.3.7.4] a constant width of 0 is refused",
        Head ++ "s.x.bits(s.lo, 0)" ++ Tail, dv_bit_field_range, !T, !IO),
    check_refused("[LEXP.3.7.4] a constant field past bit 63 is refused",
        Head ++ "s.x.bits(60, 5)" ++ Tail, dv_bit_field_range, !T, !IO),
    check_refused("[LEXP.3.7.4] `sign_extend(65)` is refused",
        Head ++ "s.x.sign_extend(65)" ++ Tail, dv_bit_field_range, !T, !IO),
    check_refused("[LEXP.3.7.4] `swap_bytes(24)` is refused",
        Head ++ "s.x.swap_bytes(24)" ++ Tail, dv_bit_field_range, !T, !IO),
    % [LEXP.8.8]: a `const` is a compile-time constant too.
    check_refused("[LEXP.3.7.4] a `const` width outside the domain is refused",
        "const W = 60 + 5\n\n" ++ Head ++ "s.x.sign_extend(W)" ++ Tail,
        dv_bit_field_range, !T, !IO),
    check_unlowered("[LEXP.3.7.4] constant arguments inside the domain compile",
        Head ++ "s.x.bits(0, 64) + s.x.sign_extend(64) + s.x.swap_bytes(16) "
            ++ "+ s.x.bits(63, 1)" ++ Tail, [], !T, !IO),
    % `logical/LEXP.3.7.3_bits_extracts_a_field`'s program: every argument a
    % slot, the result compared with another.
    check_unlowered("[LEXP.3.7.3] `bits` over slots, against a slot, compiles",
        "schema T scope logical:\n    id: String key\n    x: Int mutable\n"
            ++ "    lo: Int mutable\n    w: Int mutable\n    want: Int mutable\n\n"
            ++ "rule extracted:\n    T t where t.x.bits(t.lo, t.w) == t.want\n"
            ++ "->\n    log info \"extracted {t.id}\"\n", [], !T, !IO).

%-----------------------------------------------------------------------------%
% Front-end codes
%-----------------------------------------------------------------------------%

:- pred front_code_cases(tally::in, tally::out, io::di, io::uo) is det.

front_code_cases(!T, !IO) :-
    check_stop_code("a tab indent is a lex error",
        "schema T scope logical:\n\tv: Int key\n", lex_generic, !T, !IO),
    check_stop_code("a three-space indent is a lex error",
        "schema T scope logical:\n   v: Int key\n", lex_generic, !T, !IO),
    check_stop_code("a second `use` is its own parse code",
        "use default\nuse default\n\nschema T scope logical:\n    v: Int key\n",
        parse_duplicate_use, !T, !IO),
    check_stop_code("an ellipsis is a parse error in the corpus",
        "schema T scope logical:\n    v: Int key\n\nrule r:\n"
            ++ "    T t where t.v == ...\n->\n    log info \"x\"\n",
        parse_generic, !T, !IO),
    % [LLEX.8.2.1]: `@` "is lexed as a single-character token `@` and is
    % reserved: any parser production sees it as an error" -- the parser's
    % code, in an operator position and at the start of an operand.
    check_stop_code("[LLEX.8.2.1] `@` between operands is a parse error",
        "schema T scope logical:\n    v: Int key\n\nrule r:\n"
            ++ "    T t where t.v @ 5\n->\n    log info \"x\"\n",
        parse_generic, !T, !IO),
    check_stop_code("[LLEX.8.2.1] `@` before an operand is a parse error",
        "schema T scope logical:\n    v: Int key\n\nrule r:\n"
            ++ "    T t where @t.v > 0\n->\n    log info \"x\"\n",
        parse_generic, !T, !IO),
    % [LGRA.2.9.1]: in a `"""` literal a `\` takes the next character, so
    % `\"` is an escaped quote and cannot begin the closing `"""`. With only
    % `""` after it before the end of the source, the literal is
    % [LLEX.15.2.1]'s "unterminated string literal", not a dangling backslash.
    check_stop_code("[LLEX.15.2.1] `\"\"\"...\\\"\"\"` then EOF is unterminated",
        "schema T scope logical:\n    v: Int key\n\nrule r:\n"
            ++ "    T t\n->\n    log info \"\"\"trailing\\\"\"\"\n",
        lex_generic, !T, !IO),
    check("[LLEX.15.2.1] `\"\"\"...\\\"\"\"` then EOF is the lexer's stop",
        ( if
            compile_source(as_though("default"),
                "schema T scope logical:\n    v: Int key\n\nrule r:\n"
                    ++ "    T t\n->\n    log info \"\"\"trailing\\\"\"\"\n",
                TripleStopped),
            TripleStopped = compile_stopped(lex_generic, _, _, no)
        then yes else no ), !T, !IO),
    check_stop_code("`persist:` is not a block option",
        "schema S scope logical:\n    k: String key\n    v: Float mutable\n\n"
            ++ "series S.v (persist: 7_d):\n    mean sliding 10_min\n",
        parse_generic, !T, !IO),
    check_stop_code("an over-range integer is a range error",
        "const TooBig = 9999999999999999999\n", parse_int_range, !T, !IO),

    % The underline's END, which `dsc.driver.token_end_at` reconstructs by
    % looking the stopping position up among the tokens the parser was handed.
    %
    % The other stop cases discard the position, so this is what exercises
    % the lookup. `bogus` stops as `pe_unknown_decl` at that token: five
    % characters at 0-based column 0 (only the rendered header and
    % `rdsc_5_7_3_col` add one), so the exclusive end is column 5.
    check("render:a parse stop carries the offending token's end",
        ( if
            compile_source(as_though("default"),"bogus Thing\n", Stopped),
            Stopped = compile_stopped(_, _, pos(1, 0), yes(pos(1, 5)))
        then yes else no ), !T, !IO),

    % A lexer stop has no end: it is about characters before any token. An
    % unterminated string is `llex_5_4_lex`'s, which never emits a token.
    check("render:a lexer stop carries no end",
        ( if
            compile_source(as_though("default"),"const S = \"abc\n",
                LexStopped),
            LexStopped = compile_stopped(_, _, _, no)
        then yes else no ), !T, !IO),

    % The code does not say which phase stopped: a brace outside a string is
    % a parse stop that `parse_front_code` maps to `lex_generic`
    % ([LLEX.7.5.6]), so it carries an end.
    check("render:a `lex_generic` PARSE stop still carries an end",
        ( if
            compile_source(as_though("default"),
                "schema T scope logical:\n    v: Int key\n\nrule r:\n"
                    ++ "    T t\n->\n    log info {t.v}\n",
                BraceStopped),
            BraceStopped = compile_stopped(lex_generic, _, _, yes(_))
        then yes else no ), !T, !IO).

:- pred check_stop_code(string::in, string::in, ds_front::in,
                        tally::in, tally::out, io::di, io::uo) is det.

check_stop_code(Name, Source, Want, !T, !IO) :-
    compile_source(as_though("default"),Source, Result),
    ( if Result = compile_stopped(Got, _, _, _) then
        ( if Got = Want then
            Ok = yes
        else
            Ok = no,
            io.format("    stopped with %s\n", [s(ds_front_name(Got))], !IO)
        )
    else
        Ok = no,
        report_failure(Result, !IO)
    ),
    check(Name, Ok, !T, !IO).

%-----------------------------------------------------------------------------%
% The rule graph
%-----------------------------------------------------------------------------%
%
% The corpus's LCYC fixtures pin the cycle diagnostics; its fixture for
% `publish` making no edge ([LCYC.6.3]) is deprecated, so these pin it.

:- pred cycle_cases(tally::in, tally::out, io::di, io::uo) is det.

cycle_cases(!T, !IO) :-
    % [LTIE.4.3]: a `publish` asserts nothing in this tier, so it makes no
    % edge, and a rule that publishes the schema it matches is not a cycle.
    check_source("[LTIE.4.3] `publish` is not an edge in this graph",
        "schema X scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "rule a:\n" ++
        "    X\n" ++
        "->\n" ++
        "    publish X v: 1\n",
        [schema_shape("X", "logical",
            [src_slot("v", "Int", 0, "!", "key", "exact")])],
        !T, !IO),

    % And `emit` on the same program is one: the pair differs in the verb.
    check_refused("[LCYC.3.2.2] the same rule with `emit` is a self-cycle",
        "schema X scope logical:\n" ++
        "    v: Int key\n" ++
        "\n" ++
        "rule a:\n" ++
        "    X x\n" ++
        "->\n" ++
        "    emit X logical v: 1\n",
        dv_rule_cycle, !T, !IO),

    % [LCYC.3.3.3]: a rule that emits a schema and withdraws a binding of it
    % is reported at the RHS, "rather than as a graph-cycle diagnostic". A
    % graph that kept the rule's edges to itself raises DS_VALIDATE_RULE_CYCLE
    % too, and fails this.
    % @spec [LCYC.3.3.3]
    check_refused_without("[LCYC.3.3.3] an emit and a withdraw of one schema "
            ++ "is no graph cycle",
        "schema Trig scope explicit:\n" ++
        "    v: Int\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Trig t\n" ++
        "->\n" ++
        "    emit Trig v: t.v\n" ++
        "    withdraw t\n",
        dv_withdraw_emit_same_schema, dv_rule_cycle, !T, !IO),

    % Its control: the same rule on a cycle through a second rule is still
    % one. `r` emits the `Trig` that `s` matches and `s` the `Other` that `r`
    % matches. Dropping more than `r`'s edges to itself loses it.
    check_refused("[LCYC.3.3.3] a cycle through another rule is still found",
        "schema Trig scope explicit:\n" ++
        "    v: Int\n" ++
        "\n" ++
        "schema Other scope explicit:\n" ++
        "    v: Int\n" ++
        "\n" ++
        "rule r:\n" ++
        "    Trig t\n" ++
        "    Other\n" ++
        "->\n" ++
        "    emit Trig v: t.v\n" ++
        "    withdraw t\n" ++
        "\n" ++
        "rule s:\n" ++
        "    Trig\n" ++
        "->\n" ++
        "    emit Other v: 1\n",
        dv_rule_cycle, !T, !IO),

    % [RCLI.1.9], [LCYC.6.3]: a cycle through a library's rule and the
    % importing file's is placed at the earliest rule, the library's `la`
    % (the unit graph lists libraries first), so it is named in the library's
    % file, at `la`'s line 7. The control: a cycle in the importing file alone
    % is named by no library, though a library with a rule is imported.
    CycleLib = "schema A scope logical:\n"
        ++ "    v: Int key\n"
        ++ "\n"
        ++ "schema B scope logical:\n"
        ++ "    v: Int key\n"
        ++ "\n"
        ++ "rule la:\n"
        ++ "    A\n"
        ++ "->\n"
        ++ "    emit B logical v: 1\n",
    compile_with(as_though("default"),
        yes(map.from_assoc_list(["cyc" - CycleLib])),
        "from cyc import A, B\n\n"
            ++ "rule pb:\n"
            ++ "    B\n"
            ++ "->\n"
            ++ "    emit A logical v: 1\n",
        CrossResult),
    check("[RCLI.1.9] a cycle placed at a library's rule is named in its "
            ++ "library, at that rule",
        ( if
            CrossResult = compile_rejected(CrossDs),
            Cycles = list.filter(
                ( pred(CycD::in) is semidet :-
                    CycD ^ dg_code = dc_validate(dv_rule_cycle) ), CrossDs),
            Cycles = [_ | _],
            list.all_true(
                ( pred(LibCycD::in) is semidet :-
                    LibCycD ^ dg_file = yes("<in-memory:cyc.ds>"),
                    LibCycD ^ dg_pos ^ p_line = 7 ),
                Cycles)
        then yes else no ), !T, !IO),
    QuietLib = "schema A scope logical:\n"
        ++ "    v: Int key\n"
        ++ "\n"
        ++ "rule la:\n"
        ++ "    A\n"
        ++ "->\n"
        ++ "    log info \"a\"\n",
    compile_with(as_though("default"),
        yes(map.from_assoc_list(["quiet" - QuietLib])),
        "from quiet import A\n\n"
            ++ "schema X scope logical:\n"
            ++ "    v: Int key\n"
            ++ "\n"
            ++ "rule a:\n"
            ++ "    X x\n"
            ++ "->\n"
            ++ "    emit X logical v: 1\n",
        OwnCycleResult),
    check("[RCLI.1.9] the control: a cycle in the importing file is named by "
            ++ "no library",
        ( if
            OwnCycleResult = compile_rejected(OwnCycleDs),
            OwnCycles = list.filter(
                ( pred(OwnCycD::in) is semidet :-
                    OwnCycD ^ dg_code = dc_validate(dv_rule_cycle) ),
                OwnCycleDs),
            OwnCycles = [_ | _],
            list.all_true(
                ( pred(FileCycD::in) is semidet :- FileCycD ^ dg_file = no ),
                OwnCycles)
        then yes else no ), !T, !IO).

%-----------------------------------------------------------------------------%
% The builtin schemas
%-----------------------------------------------------------------------------%
%
% The builtin schemas are DS source in `dsc.builtins`, and the driver refuses
% rather than aborts if one is wrong; these show that refusal does not fire.
% Asserted through the artefact: a program matching one gets the schema the
% clause gives.

    % The TTL as `shape_of` renders it, written from a number.
    %
:- func ttl_life(uint64) = string.

ttl_life(Ns) = "ttl:" ++ string.string(Ns).

:- pred builtin_schema_cases(tally::in, tally::out, io::di, io::uo) is det.

builtin_schema_cases(!T, !IO) :-
    % [LCRS.4.3.3]: a rule matching `CallResponse` is refused by name, not as
    % an unknown schema.
    check_refused("[LCRS.4.3.3] matching `CallResponse` is refused",
        "rule handle:\n" ++
        "    CallResponse r where r.corr == \"c1\"\n" ++
        "->\n" ++
        "    log info \"ok\"\n",
        dv_call_response_retired, !T, !IO),

    check_source("[LCRS.4.2.1] matching `CallError` injects it",
        "rule handle:\n" ++
        "    CallError e where e.code == \"timeout\"\n" ++
        "->\n" ++
        "    log critical \"failed\"\n",
        [schema_shape("CallError", ttl_life(300000000000u64),
            [src_slot("corr", "String", 0, "!", "-", "-"),
             src_slot("code", "String", 1, "!", "-", "-"),
             src_slot("message", "String", 2, "!", "-", "-"),
             src_slot("ts", "Time", 3, "!", "-", "-")])],
        !T, !IO),

    % Not injected when not referenced.
    check_source("a program that names no builtin gets none",
        "schema Reading:\n" ++
        "    state: Float\n",
        [schema_shape("Reading", "explicit",
            [src_slot("state", "Float", 0, "!", "-", "-")])],
        !T, !IO),

    % [LERR.9.4]: except the two fault schemas, which every program carries
    % ([LERR.9.1]): ahead of the file's own, `explicit` on the wire
    % ([LSCP.2.6.1]), slots in [LERR.9.2] / [LERR.9.3]'s order. The other
    % checks read `author_schemas/1`, which drops them, so this pins them.
    %
    % [LIMP.12.2]: and `TimeZoneOffset` after them, as [LTIM.10.6]'s table
    % declares it.
    check_source_all("[LERR.9.4] [LIMP.12.2] every program carries the two "
            ++ "fault schemas and `TimeZoneOffset`",
        "schema Reading:\n" ++
        "    state: Float\n",
        [schema_shape("ComputationError", "explicit",
            [src_slot("kind", "String", 0, "!", "-", "-"),
             src_slot("rule", "String", 1, "!", "-", "-"),
             src_slot("schema", "String", 2, "!", "-", "-"),
             src_slot("slot", "String", 3, "!", "-", "-"),
             src_slot("node", "Int", 4, "!", "-", "-")]),
         schema_shape("TypeError", "explicit",
            [src_slot("actual", "String", 0, "!", "-", "-"),
             src_slot("rule", "String", 1, "!", "-", "-"),
             src_slot("schema", "String", 2, "!", "-", "-"),
             src_slot("slot", "String", 3, "!", "-", "-"),
             src_slot("node", "Int", 4, "!", "-", "-")]),
         schema_shape("TimeZoneOffset", "logical+ambient",
            [src_slot("zone", "String", 0, "!", "key", "exact"),
             src_slot("valid_from", "Time", 1, "!", "key", "exact"),
             src_slot("valid_until", "Time", 2, "!", "mutable", "exact"),
             src_slot("offset_s", "Int", 3, "!", "mutable", "exact")]),
         schema_shape("Reading", "explicit",
            [src_slot("state", "Float", 0, "!", "-", "-")])],
        !T, !IO),

    % [LIMP.12.3]: `TimeZoneOffset` is a built-in module name like
    % `CallError`, so a local declaration of it collides.
    check_refused("[LIMP.12.3] a user-declared `TimeZoneOffset` is a "
            ++ "collision",
        "schema TimeZoneOffset scope logical:\n" ++
        "    zone: String key\n",
        dv_import_name_collision, !T, !IO),

    % [LIMP.12.3]: a local declaration collides with the built-in module,
    % which every compilation imports ([LIMP.12.1]), with a rule matching it
    % or not.
    check_refused("[LIMP.12.3] a user-declared `CallError` is a collision",
        "schema CallError scope ttl 1_h:\n" ++
        "    mine: Int\n" ++
        "\n" ++
        "rule r:\n" ++
        "    CallError e where e.mine == 1\n" ++
        "->\n" ++
        "    log info \"local\"\n",
        dv_import_name_collision, !T, !IO),

    % And with nothing in the file naming it: the module is imported whether
    % or not the file uses it.
    check_refused("[LIMP.12.3] a `CallError` no rule names still collides",
        "schema CallError scope ttl 1_h:\n" ++
        "    mine: Int\n",
        dv_import_name_collision, !T, !IO).

%-----------------------------------------------------------------------------%

    % A slot shape with the three flags off, which is every source case that is
    % not about the flags.
    %
:- func src_slot(string, string, int, string, string, string) = slot_shape.

src_slot(Name, Kind, Index, Null, Identity, Tolerance) =
    slot_shape(Name, Kind, Index, Null, no, no, no, Identity, Tolerance).

:- func compile(string) = compile_result.

compile(Source) = Result :-
    compile_source(as_though("default"),Source, Result).

    % The series backend atoms, by message name, in artefact order.
    %
:- func backend_atom_names(list(uint8)) = list(string).

backend_atom_names(Bytes) = list.filter_map(
    ( func(Atom - _) = Name is semidet :-
        Name = atom_message(Atom),
        string.prefix(Name, "SeriesBackend")
    ), atom_clips(Bytes)).

    % Every atom with its `module_id`, field 10, or 0 where it carries none
    % ([RDSC.4.7]'s unset sentinel). Read from the bytes: the loader skips
    % field 10.
    %
:- func atom_clips(list(uint8)) = assoc_list(atom_id, uint32).

atom_clips(Bytes) = list.reverse(walk_clips(init_reader(from_bytes(Bytes)),
    [])).

:- func walk_clips(reader, assoc_list(atom_id, uint32))
    = assoc_list(atom_id, uint32).

walk_clips(R0, Acc) = Clips :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Clips = Acc
    ;
        FrameResult = fr_error(_, _),
        Clips = Acc
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(Atom) then
            Clips = walk_clips(R1,
                [Atom - field_10(Frame ^ fr_body, 0u32) | Acc])
        else
            Clips = walk_clips(R1, Acc)
        )
    ).

:- func field_10(reader, uint32) = uint32.

field_10(R0, Found) = Clip :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        ( if Num = 10u32, Value = fv_varint(V) then
            Clip = field_10(R1, uint32.cast_from_uint64(V))
        else
            Clip = field_10(R1, Found)
        )
    ;
        FieldResult = fields_end,
        Clip = Found
    ;
        FieldResult = field_error(_),
        Clip = Found
    ).

    % [RDSC.5.8.5]: every field the SchemaDef declares is the proto3 type its Slot
    % atom's kind maps to, in the same order, with no field left over on
    % either side.
    %
    % EVERY schema in the program, not the first: [RDSC.5.8.6]'s matrix needs a
    % fact-reference slot, which needs a second schema to point at, and needs
    % both lifecycles, which cannot be one schema.
    %
:- pred proto_matches_slots(program::in) is semidet.

proto_matches_slots(P) :-
    Schemas = schemas(P),
    Schemas = [_ | _],
    list.all_true(schema_proto_matches, Schemas).

    % One schema, both directions: a Slot atom with no matching `.proto` field
    % and a `.proto` field with no matching Slot atom are both failures
    % ([RDSC.5.8.5]), and comparing the two lists whole is what catches each.
    %
:- pred schema_proto_matches(schema::in) is semidet.

schema_proto_matches(S) :-
    S ^ s_proto = yes(Proto),
    Lines = string.split_at_char('\n', proto_source_text(Proto)),
    % Drop the syntax line, the package, the `message` opener, the `}` and the
    % empty tail: what is left is one line per field.
    list.drop(3, Lines, Body),
    % [RDSC.5.8.6]: each field's `optional` is compared with its Slot's
    % `nullable`, as well as its type with the Slot's kind -- so a `T?` slot
    % whose field is not `optional`, and an `optional` field on a
    % non-nullable slot, both fail here.
    FieldShapes = list.filter_map(field_shape, Body),
    SlotShapes = list.map(
        ( func(C) = {nullable_is_optional(C ^ sc_nullable),
                     proto_type_of(C ^ sc_kind)} ),
        slot_commons(S)),
    FieldShapes = SlotShapes.

    % [RCLI.1.5]: the dump of `Source` is the SchemaDef header, a blank line, then
    % the `message` of each schema in `Names`, in that order, each exactly as
    % the loaded program's SchemaDef `proto_source` carries it. Prints both texts on
    % a mismatch.
    %
:- pred dump_matches_sdefs(string::in, list(string)::in) is semidet.

dump_matches_sdefs(Source, Names) :-
    compile(Source) = compiled(Bytes, _, Messages),
    Dump = rcli_1_5_combined_proto(Source, Messages),
    load_dsc(from_bytes(Bytes), loaded(P)),
    list.map(sdef_message(P), Names, Sdefs),
    Want = rdsc_5_8_3_proto_header ++ "\n" ++ string.join_list("\n", Sdefs),
    ( if Dump = Want then
        true
    else
        trace [io(!IO)] (
            io.write_string("    dump:\n" ++ Dump ++ "    sdefs:\n" ++ Want,
                !IO)
        ),
        fail
    ).

    % The `message` block of the named schema's SchemaDef, as loaded.
    %
:- pred sdef_message(program::in, string::in, string::out) is semidet.

sdef_message(P, Name, Message) :-
    list.find_first_match(
        ( pred(S::in) is semidet :-
            expand(interns(P), schema_name_ref(S ^ s_name), Name)
        ), schemas(P), Schema),
    Schema ^ s_proto = yes(Proto),
    string.remove_prefix(rdsc_5_8_3_proto_header, proto_source_text(Proto),
        Message).

    % The named schema's SchemaDef whole, as loaded, or "" with none.
    %
:- func sdef_text(program, string) = string.

sdef_text(P, Name) = Text :-
    ( if
        list.find_first_match(
            ( pred(S::in) is semidet :-
                expand(interns(P), schema_name_ref(S ^ s_name), Name)
            ), schemas(P), Schema),
        Schema ^ s_proto = yes(Proto)
    then
        Text = proto_source_text(Proto)
    else
        Text = ""
    ).

    % Whether a `.proto` field for this slot is `optional` ([RDSC.5.8.3]).
    %
:- func nullable_is_optional(nullable) = bool.

nullable_is_optional(nullable) = yes.
nullable_is_optional(non_null) = no.

    % [RDSC.5.8.6]'s OTHER half: "the lifecycle (SchemaTtl presence + ttl_ns, SchemaLogical
    % presence) and hydration eligibility (Hydration per slot) match the `.proto`'s
    % declared options or comments".
    %
    % The generated `.proto` is bare fields, with no options or comments, so
    % there is nothing to match the atoms against. This pins that the atoms
    % carry the lifecycle and the `.proto` is silent; should either move, it
    % fails.
    %
:- pred sdef_lifecycle_silent_in_proto(program::in) is semidet.

sdef_lifecycle_silent_in_proto(P) :-
    Schemas = schemas(P),
    Schemas = [_ | _],
    list.all_true(lifecycle_silent, Schemas).

:- pred lifecycle_silent(schema::in) is semidet.

lifecycle_silent(S) :-
    S ^ s_proto = yes(Proto),
    Text = proto_source_text(Proto),
    % No option, no comment, no lifecycle word anywhere in the generated file.
    not string.sub_string_search(Text, "option", _),
    not string.sub_string_search(Text, "//", _),
    not string.sub_string_search(Text, "ttl", _),
    not string.sub_string_search(Text, "logical", _),
    % No slot is hydratable: `dsc.lower` sets `sc_hydratable` false, so the
    % Hydration half is vacuous. Should Hydration be emitted, this fails.
    list.all_true(( pred(C::in) is semidet :- C ^ sc_hydratable = no ),
        slot_commons(S)).

    % The label and type of `  [optional ]<type> <name> = <n>;`: whether the
    % field is `optional`, and its type token.
    %
:- func field_shape(string) = {bool, string} is semidet.

field_shape(Line) = {Optional, Type} :-
    Words = string.words(Line),
    ( if Words = ["optional", T | _] then
        Optional = yes, Type = T
    else
        Words = [Type | _],
        Optional = no
    ),
    Type \= "}".

    % The mapping `dsc.encode` writes, restated here so the test does not read
    % its answer from the code under test.
    %
:- func proto_type_of(slot_kind) = string.

proto_type_of(k_int)       = "int64".
proto_type_of(k_float)     = "double".
proto_type_of(k_string)    = "string".
proto_type_of(k_bool)      = "bool".
proto_type_of(k_json)      = "string".
proto_type_of(k_bytes)     = "bytes".
proto_type_of(k_schema(_)) = "uint64".    % RDSC.5.8.3: the handle
proto_type_of(k_time)      = "int64".
proto_type_of(k_date)      = "int64".
proto_type_of(k_duration)  = "int64".

    % [RDSC.8.7]'s test references: every `TestCase` id (field 1), and the
    % `test_id` (field 1) of every `TestFact` and oracle atom, each in
    % emission order.
    %
:- func test_refs(list(uint8)) = {list(uint32), list(uint32)}.

test_refs(Bytes) = {list.reverse(Cases), list.reverse(Refs)} :-
    walk_test_refs(init_reader(from_bytes(Bytes)), [], Cases, [], Refs).

:- pred walk_test_refs(reader::in, list(uint32)::in, list(uint32)::out,
                       list(uint32)::in, list(uint32)::out) is det.

walk_test_refs(R0, !Cases, !Refs) :-
    next_frame(FrameResult, R0, R1),
    (
        ( FrameResult = fr_eof
        ; FrameResult = fr_error(_, _)
        )
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_test_case) then
            !:Cases = [field1_uint32(Frame ^ fr_body) | !.Cases]
        else if
            Frame ^ fr_atom = known(A),
            names_its_test(A)
        then
            !:Refs = [field1_uint32(Frame ^ fr_body) | !.Refs]
        else
            true
        ),
        walk_test_refs(R1, !Cases, !Refs)
    ).

    % The atoms [RDSC.8.7] lists: `TestFact` and every oracle atom.
    %
:- pred names_its_test(atom_id::in) is semidet.

names_its_test(at_test_fact).
names_its_test(at_oracle_activated).
names_its_test(at_oracle_emit).
names_its_test(at_oracle_publish).
names_its_test(at_oracle_call).
names_its_test(at_oracle_cache_set).
names_its_test(at_oracle_cache_delete).
names_its_test(at_oracle_log).
names_its_test(at_oracle_retract).
names_its_test(at_oracle_working_memory).

    % Field 1 as a uint32, or 0 when absent -- proto3's default, and the value
    % a missing reference reads as.
    %
:- func field1_uint32(reader) = uint32.

field1_uint32(R0) = V :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        ( if Num = 1u32, Value = fv_varint(U) then
            V = uint32.cast_from_uint64(U)
        else
            V = field1_uint32(R1)
        )
    ;
        ( FieldResult = fields_end
        ; FieldResult = field_error(_)
        ),
        V = 0u32
    ).

    % Every SchemaSource atom as `{schema_name, line, col, module_id}`, in emission
    % order.
    %
:- func srcs_atoms(list(uint8)) = list({string, uint32, uint32, uint32}).

srcs_atoms(Bytes) = list.reverse(walk_srcs(init_reader(from_bytes(Bytes)),
    [])).

:- func walk_srcs(reader, list({string, uint32, uint32, uint32}))
    = list({string, uint32, uint32, uint32}).

walk_srcs(R0, Acc) = Found :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Found = Acc
    ;
        FrameResult = fr_error(_, _),
        Found = Acc
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_schema_source) then
            Found = walk_srcs(R1,
                [srcs_body(Frame ^ fr_body, {"", 0u32, 0u32, 0u32}) | Acc])
        else
            Found = walk_srcs(R1, Acc)
        )
    ).

:- func srcs_body(reader, {string, uint32, uint32, uint32})
    = {string, uint32, uint32, uint32}.

srcs_body(R0, {Name0, Line0, Col0, Clip0}) = Body :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        ( if Num = 1u32, Value = fv_bytes(N), reader_string(N, Name) then
            Body = srcs_body(R1, {Name, Line0, Col0, Clip0})
        else if Num = 3u32, Value = fv_varint(L) then
            Body = srcs_body(R1,
                {Name0, uint32.cast_from_uint64(L), Col0, Clip0})
        else if Num = 4u32, Value = fv_varint(C) then
            Body = srcs_body(R1,
                {Name0, Line0, uint32.cast_from_uint64(C), Clip0})
        else if Num = 10u32, Value = fv_varint(K) then
            Body = srcs_body(R1,
                {Name0, Line0, Col0, uint32.cast_from_uint64(K)})
        else
            Body = srcs_body(R1, {Name0, Line0, Col0, Clip0})
        )
    ;
        FieldResult = fields_end,
        Body = {Name0, Line0, Col0, Clip0}
    ;
        FieldResult = field_error(_),
        Body = {Name0, Line0, Col0, Clip0}
    ).

    % Two services answering with `Ok`, a `ttl` response schema with `corr`
    % ([LCRS.4.3.2]) and a `Bool` `ok`, for the continuation probes.
    %
:- func ok_services = string.

ok_services =
    "schema Ok scope ttl 1_h:\n    corr: String\n    ok: Bool\n\n"
    ++ "service weather.get_forecast:\n    kwarg entity_id: String\n"
    ++ "    response Ok\n\n"
    ++ "service switch.turn_on:\n    kwarg entity_id: String\n"
    ++ "    response Ok\n\n".

    % The first ServiceDef atom's kwarg names, in emission order.
    %
:- func svcd_kwarg_names(list(uint8)) = list(string).

svcd_kwarg_names(Bytes) = Names :-
    ( if first_svcd(init_reader(from_bytes(Bytes)), Body) then
        Names = list.reverse(svcd_kwargs(Body, []))
    else
        Names = []
    ).

:- func svcd_kwargs(reader, list(string)) = list(string).

svcd_kwargs(R0, Acc) = Names :-
    next_field(FieldResult, R0, R1),
    ( if FieldResult = field(2u32, fv_bytes(Sub)) then
        Names = svcd_kwargs(R1, [kwarg_name(Sub) | Acc])
    else if FieldResult = field(_, _) then
        Names = svcd_kwargs(R1, Acc)
    else
        Names = Acc
    ).

:- func kwarg_name(reader) = string.

kwarg_name(R0) = Name :-
    next_field(FieldResult, R0, R1),
    ( if
        FieldResult = field(2u32, fv_bytes(N)),
        reader_string(N, Nm)
    then
        Name = Nm
    else if FieldResult = field(_, _) then
        Name = kwarg_name(R1)
    else
        Name = ""
    ).

    % The first ServiceDef atom's `no_response` (field 5).
    %
:- func svcd_no_response(list(uint8)) = bool.

svcd_no_response(Bytes) = NoResponse :-
    ( if first_svcd(init_reader(from_bytes(Bytes)), Body) then
        NoResponse = svcd_field5(Body)
    else
        NoResponse = no
    ).

:- func svcd_field5(reader) = bool.

svcd_field5(R0) = NoResponse :-
    next_field(FieldResult, R0, R1),
    ( if FieldResult = field(5u32, fv_varint(V)) then
        NoResponse = ( if V = 1u64 then yes else no )
    else if FieldResult = field(_, _) then
        NoResponse = svcd_field5(R1)
    else
        NoResponse = no
    ).

:- pred first_svcd(reader::in, reader::out) is semidet.

first_svcd(R0, Body) :-
    next_frame(FrameResult, R0, R1),
    FrameResult = fr_ok(Frame),
    ( if Frame ^ fr_atom = known(at_service_def) then
        Body = Frame ^ fr_body
    else
        first_svcd(R1, Body)
    ).

    % Every ServiceDef atom as `{name, response, module_id}`, in emission order. The
    % kwarg sub-messages are skipped: field 2 is length-delimited and this
    % reader only needs to say which services reached the wire and under which
    % module.
    %
:- func svcd_atoms(list(uint8)) = list({string, string, uint32}).

svcd_atoms(Bytes) = list.reverse(walk_svcd(init_reader(from_bytes(Bytes)),
    [])).

:- func walk_svcd(reader, list({string, string, uint32}))
    = list({string, string, uint32}).

walk_svcd(R0, Acc) = Found :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Found = Acc
    ;
        FrameResult = fr_error(_, _),
        Found = Acc
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_service_def) then
            Found = walk_svcd(R1,
                [svcd_body(Frame ^ fr_body, {"", "", 0u32}) | Acc])
        else
            Found = walk_svcd(R1, Acc)
        )
    ).

:- func svcd_body(reader, {string, string, uint32}) = {string, string, uint32}.

svcd_body(R0, {N0, Rs0, K0}) = Body :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        ( if Num = 1u32, Value = fv_bytes(N), reader_string(N, Nm) then
            Body = svcd_body(R1, {Nm, Rs0, K0})
        else if Num = 3u32, Value = fv_bytes(N), reader_string(N, Rs) then
            Body = svcd_body(R1, {N0, Rs, K0})
        else if Num = 10u32, Value = fv_varint(K) then
            Body = svcd_body(R1, {N0, Rs0, uint32.cast_from_uint64(K)})
        else
            Body = svcd_body(R1, {N0, Rs0, K0})
        )
    ;
        FieldResult = fields_end,
        Body = {N0, Rs0, K0}
    ;
        FieldResult = field_error(_),
        Body = {N0, Rs0, K0}
    ).

    % Every RuleSource atom's `rule_name` (field 1), in emission order: one per
    % `rule_group` ([RDSC.8.1]).
    %
:- func rule_source_names(list(uint8)) = list(string).

rule_source_names(Bytes) =
    list.reverse(walk_rule_sources(init_reader(from_bytes(Bytes)), [])).

:- func walk_rule_sources(reader, list(string)) = list(string).

walk_rule_sources(R0, Acc) = Found :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Found = Acc
    ;
        FrameResult = fr_error(_, _),
        Found = Acc
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_rule_source) then
            Found = walk_rule_sources(R1,
                [field_1_string(Frame ^ fr_body) | Acc])
        else
            Found = walk_rule_sources(R1, Acc)
        )
    ).

:- func field_1_string(reader) = string.

field_1_string(R0) = Name :-
    next_field(FieldResult, R0, R1),
    ( if FieldResult = field(1u32, fv_bytes(N)), reader_string(N, Nm) then
        Name = Nm
    else if FieldResult = field(_, _) then
        Name = field_1_string(R1)
    else
        Name = ""
    ).

    % Every LineSpan atom as `{node_id, line, col, module_id}`, in emission order.
    %
:- func span_atoms(list(uint8)) = list({uint32, uint32, uint32, uint32}).

span_atoms(Bytes) = list.reverse(walk_spans(init_reader(from_bytes(Bytes)),
    [])).

:- func walk_spans(reader, list({uint32, uint32, uint32, uint32}))
    = list({uint32, uint32, uint32, uint32}).

walk_spans(R0, Acc) = Found :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Found = Acc
    ;
        FrameResult = fr_error(_, _),
        Found = Acc
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_line_span) then
            Found = walk_spans(R1,
                [span_body(Frame ^ fr_body, {0u32, 0u32, 0u32, 0u32}) | Acc])
        else
            Found = walk_spans(R1, Acc)
        )
    ).

:- func span_body(reader, {uint32, uint32, uint32, uint32})
    = {uint32, uint32, uint32, uint32}.

span_body(R0, {N0, L0, C0, K0}) = Body :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        ( if Num = 1u32, Value = fv_varint(N) then
            Body = span_body(R1, {uint32.cast_from_uint64(N), L0, C0, K0})
        else if Num = 4u32, Value = fv_varint(L) then
            Body = span_body(R1, {N0, uint32.cast_from_uint64(L), C0, K0})
        else if Num = 5u32, Value = fv_varint(C) then
            Body = span_body(R1, {N0, L0, uint32.cast_from_uint64(C), K0})
        else if Num = 10u32, Value = fv_varint(K) then
            Body = span_body(R1, {N0, L0, C0, uint32.cast_from_uint64(K)})
        else
            Body = span_body(R1, {N0, L0, C0, K0})
        )
    ;
        FieldResult = fields_end,
        Body = {N0, L0, C0, K0}
    ;
        FieldResult = field_error(_),
        Body = {N0, L0, C0, K0}
    ).

    % Every DocString atom as `{target, module_id, schema, slot, rule, text, line,
    % col}`, in emission order -- `proto/doc_string.proto`'s eight fields.
    %
:- func docs_atoms(list(uint8))
    = list({uint32, uint32, string, string, string, string, uint32, uint32}).

docs_atoms(Bytes) = list.reverse(walk_docs(init_reader(from_bytes(Bytes)),
    [])).

:- func walk_docs(reader,
        list({uint32, uint32, string, string, string, string, uint32, uint32}))
    = list({uint32, uint32, string, string, string, string, uint32, uint32}).

walk_docs(R0, Acc) = Found :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Found = Acc
    ;
        FrameResult = fr_error(_, _),
        Found = Acc
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_doc_string) then
            Found = walk_docs(R1, [docs_body(Frame ^ fr_body,
                {0u32, 0u32, "", "", "", "", 0u32, 0u32}) | Acc])
        else
            Found = walk_docs(R1, Acc)
        )
    ).

:- func docs_body(reader,
        {uint32, uint32, string, string, string, string, uint32, uint32})
    = {uint32, uint32, string, string, string, string, uint32, uint32}.

docs_body(R0, {T0, K0, Sc0, Sl0, Ru0, Tx0, Ln0, Co0}) = Body :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        ( if Num = 1u32, Value = fv_varint(T) then
            Body = docs_body(R1, {uint32.cast_from_uint64(T), K0, Sc0, Sl0,
                Ru0, Tx0, Ln0, Co0})
        else if Num = 2u32, Value = fv_varint(K) then
            Body = docs_body(R1, {T0, uint32.cast_from_uint64(K), Sc0, Sl0,
                Ru0, Tx0, Ln0, Co0})
        else if Num = 3u32, Value = fv_bytes(N), reader_string(N, Sc) then
            Body = docs_body(R1, {T0, K0, Sc, Sl0, Ru0, Tx0, Ln0, Co0})
        else if Num = 4u32, Value = fv_bytes(N), reader_string(N, Sl) then
            Body = docs_body(R1, {T0, K0, Sc0, Sl, Ru0, Tx0, Ln0, Co0})
        else if Num = 5u32, Value = fv_bytes(N), reader_string(N, Ru) then
            Body = docs_body(R1, {T0, K0, Sc0, Sl0, Ru, Tx0, Ln0, Co0})
        else if Num = 6u32, Value = fv_bytes(N), reader_string(N, Tx) then
            Body = docs_body(R1, {T0, K0, Sc0, Sl0, Ru0, Tx, Ln0, Co0})
        else if Num = 7u32, Value = fv_varint(L) then
            Body = docs_body(R1, {T0, K0, Sc0, Sl0, Ru0, Tx0,
                uint32.cast_from_uint64(L), Co0})
        else if Num = 8u32, Value = fv_varint(C) then
            Body = docs_body(R1, {T0, K0, Sc0, Sl0, Ru0, Tx0, Ln0,
                uint32.cast_from_uint64(C)})
        else
            Body = docs_body(R1, {T0, K0, Sc0, Sl0, Ru0, Tx0, Ln0, Co0})
        )
    ;
        FieldResult = fields_end,
        Body = {T0, K0, Sc0, Sl0, Ru0, Tx0, Ln0, Co0}
    ;
        FieldResult = field_error(_),
        Body = {T0, K0, Sc0, Sl0, Ru0, Tx0, Ln0, Co0}
    ).

    % Every DsSource atom as `{module_id, file, text}`, in emission order.
    %
:- func dsrc_atoms(list(uint8)) = list({uint32, string, string}).

dsrc_atoms(Bytes) = list.reverse(walk_dsrc(init_reader(from_bytes(Bytes)),
    [])).

:- func walk_dsrc(reader, list({uint32, string, string}))
    = list({uint32, string, string}).

walk_dsrc(R0, Acc) = Found :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Found = Acc
    ;
        FrameResult = fr_error(_, _),
        Found = Acc
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_ds_source) then
            Found = walk_dsrc(R1,
                [dsrc_body(Frame ^ fr_body, {0u32, "", ""}) | Acc])
        else
            Found = walk_dsrc(R1, Acc)
        )
    ).

:- func dsrc_body(reader, {uint32, string, string}) = {uint32, string, string}.

dsrc_body(R0, {Clip0, File0, Text0}) = Body :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        ( if Num = 1u32, Value = fv_bytes(F), reader_string(F, File) then
            Body = dsrc_body(R1, {Clip0, File, Text0})
        else if Num = 3u32, Value = fv_bytes(D), reader_string(D, Text) then
            Body = dsrc_body(R1, {Clip0, File0, Text})
        else if Num = 10u32, Value = fv_varint(V) then
            Body = dsrc_body(R1,
                {uint32.cast_from_uint64(V), File0, Text0})
        else
            Body = dsrc_body(R1, {Clip0, File0, Text0})
        )
    ;
        FieldResult = fields_end,
        Body = {Clip0, File0, Text0}
    ;
        FieldResult = field_error(_),
        Body = {Clip0, File0, Text0}
    ).

    % The artefact's frames with DsSource and the header dropped, for a comparison
    % about what two sources MEAN rather than what they say. `test_conformance`
    % strips the same set for `dsc_equivalent`, and says why there.
    %
:- func without_source(list(uint8)) = list(uint8).

without_source(Bytes) = list.condense(list.reverse(
    kept_frames(Bytes, init_reader(from_bytes(Bytes)), []))).

:- func kept_frames(list(uint8), reader, list(list(uint8)))
    = list(list(uint8)).

kept_frames(Bytes, R0, Acc) = Kept :-
    Start = position(R0),
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Kept = Acc
    ;
        FrameResult = fr_error(_, _),
        Kept = Acc
    ;
        FrameResult = fr_ok(Frame),
        ( if
            Frame ^ fr_atom = known(Atom),
            ( Atom = at_ds_source ; Atom = at_dsc_header )
        then
            Kept = kept_frames(Bytes, R1, Acc)
        else
            list.det_split_list(Start, Bytes, _, Rest),
            list.det_split_list(position(R1) - Start, Rest, Slice, _),
            Kept = kept_frames(Bytes, R1, [Slice | Acc])
        )
    ).

    % What a failed atom-level check saw: every (atom, module_id) pair, or every
    % SchemaSource row. Printed, not asserted -- the checks above say what is wanted.
    %
:- pred show_clips_on_failure(bool::in, maybe(list(uint8))::in,
                              io::di, io::uo) is det.

show_clips_on_failure(Ok, MaybeBytes, !IO) :-
    ( if Ok = no, MaybeBytes = yes(Bytes) then
        io.format("    got %s\n", [s(string.string(atom_clips(Bytes)))], !IO)
    else
        true
    ).

:- pred show_srcs_on_failure(bool::in, maybe(list(uint8))::in,
                             io::di, io::uo) is det.

show_srcs_on_failure(Ok, MaybeBytes, !IO) :-
    ( if Ok = no, MaybeBytes = yes(Bytes) then
        io.format("    got %s\n", [s(string.string(srcs_atoms(Bytes)))], !IO)
    else
        true
    ).

    % The `module_id`s carried by one atom kind, in emission order.
    %
:- func clips_of(list(uint8), atom_id) = list(uint32).

clips_of(Bytes, Want) = list.filter_map(
    ( func(Atom - Clip) = Clip is semidet :- Atom = Want ),
    atom_clips(Bytes)).

    % As `compiled_bytes`, against in-memory libraries.
    %
:- func compiled_lib_bytes(assoc_list(string, string), string)
    = maybe(list(uint8)).

compiled_lib_bytes(Libraries, Source) = Bytes :-
    compile_with(as_though("default"), yes(map.from_assoc_list(Libraries)),
        Source, Result),
    ( if Result = compiled(Got, _, _) then Bytes = yes(Got) else Bytes = no ).

:- func compiled_labelled_bytes(assoc_list(string, string), source_labels,
                                string) = maybe(list(uint8)).

compiled_labelled_bytes(Libraries, Labels, Source) = Bytes :-
    compile_labelled(as_though("default"), yes(map.from_assoc_list(Libraries)),
        dsrt_absent, Labels, Source, Result),
    ( if Result = compiled(Got, _, _) then Bytes = yes(Got) else Bytes = no ).

:- func compiled_bytes(string) = maybe(list(uint8)).

compiled_bytes(Source) =
    ( if compile(Source) = compiled(Bytes, _, _) then yes(Bytes) else no ).

    % A program's schemas less the three every program carries ([LIMP.12.2]):
    % the fault pair ([LERR.9.4]) and `TimeZoneOffset` ([LTIM.10.6]). A check
    % about what a SOURCE declares or references reads this;
    % `check_source_all` is where the three are pinned themselves.
    %
:- func author_schemas(program) = list(schema).

author_schemas(P) =
    list.filter(( pred(S::in) is semidet :-
            Name = text(interns(P), schema_name_ref(S ^ s_name)),
            Name \= "ComputationError",
            Name \= "TypeError",
            Name \= "TimeZoneOffset"
        ), schemas(P)).

    % Source text through every phase, then through the runtime's loader, then
    % compared on the same projection the hand-built cases use.
    %
:- pred check_source(string::in, string::in, list(schema_shape)::in,
                     tally::in, tally::out, io::di, io::uo) is det.

check_source(Name, Source, Want, !T, !IO) :-
    check_source_on(author_schemas, Name, Source, Want, !T, !IO).

    % The same, over every schema the artefact carries.
    %
:- pred check_source_all(string::in, string::in, list(schema_shape)::in,
                         tally::in, tally::out, io::di, io::uo) is det.

check_source_all(Name, Source, Want, !T, !IO) :-
    check_source_on(schemas, Name, Source, Want, !T, !IO).

:- pred check_source_on((func(program) = list(schema))::in, string::in,
                        string::in, list(schema_shape)::in,
                        tally::in, tally::out, io::di, io::uo) is det.

check_source_on(Which, Name, Source, Want, !T, !IO) :-
    Result = compile(Source),
    (
        Result = compiled(Bytes, _, _),
        load_dsc(from_bytes(Bytes), Load),
        (
            Load = loaded(P),
            Got = list.map(shape_of(interns(P)), Which(P)),
            ( if Got = Want then
                Ok = yes
            else
                Ok = no,
                io.format("    want %s\n    got  %s\n",
                    [s(string.string(Want)), s(string.string(Got))], !IO)
            )
        ;
            Load = load_failed(E),
            Ok = no,
            io.format("    load refused: %s [%s]\n",
                [s(string.string(E ^ le_kind)),
                 s(clause_id_string(E ^ le_clause))], !IO)
        )
    ;
        Result = compile_rejected(Diagnostics),
        Ok = no,
        report_rejection(Diagnostics, !IO)
    ;
        Result = compile_stopped(_, Message, Pos, _),
        Ok = no,
        io.format("    stopped at %d:%d — %s\n",
            [i(Pos ^ p_line), i(Pos ^ p_col), s(Message)], !IO)
    ),
    check(Name, Ok, !T, !IO).

    % Assert `Trig("dev1")`, pump, retract it, deliver an `Ok` response (the
    % service's response schema, [LCRS.4.3.2]) on the correlation the call
    % issued with `ok: true`, pump: the `on` sibling must log "ok dev1" --
    % once: a second response finds the capture released.
    %
:- pred continuation_logs_snapshot(program::in) is semidet.

continuation_logs_snapshot(P) :-
    E0 = init_engine(P),
    schema_called(P, "Trig", Trig),
    schema_called(P, "Ok", Response),
    engine_intern("dev1", Dev, E0, E1),
    host_assert(Trig, [str(Dev)], no, TrigResult, _, E1, E2),
    TrigResult = inserted(TrigId),
    pump(default_budget, CallEffects, E2, E3),
    % [LCCO.3.4]: the correlation is one per activation, so it is read off
    % the call.
    list.find_first_match(issued_call, CallEffects, CallEff),
    CallEff = eff_action(a_call(_, correlated(Corr), _, _)),
    host_retract(TrigId, _, E3, E4),
    % A per-call-site value, `$r_c0`, must not answer it.
    engine_intern("$r_c0", Stale, E4, E4a),
    Stale \= Corr,
    host_assert(Response, [str(Stale), bool(yes)], no,
        StaleResult, _, E4a, E4b),
    StaleResult = inserted(StaleId),
    pump(default_budget, StaleEffects, E4b, E4c),
    not list.find_first_match(logged_ok, StaleEffects, _),
    host_retract(StaleId, _, E4c, E5),
    host_assert(Response, [str(Corr), bool(yes)], no,
        ResponseResult, _, E5, E6),
    ResponseResult = inserted(_),
    pump(default_budget, Effects, E6, E7),
    list.find_first_match(logged_ok, Effects, _),
    % [LCCO.5.0]: the `on` match is a completion path, so the capture is
    % released with it, and a second response on the same correlation finds
    % no snapshot to fire against. A `ttl` schema makes each response its own
    % fact ([LCRS.4.3.2]), so the second is inserted, not merged.
    host_assert(Response, [str(Corr), bool(yes)], no,
        SecondResult, _, E7, E8),
    SecondResult = inserted(_),
    pump(default_budget, SecondEffects, E8, _),
    not list.find_first_match(logged_ok, SecondEffects, _).

:- pred omitted_bytes_is_null(program::in) is semidet.

omitted_bytes_is_null(P) :-
    E0 = init_engine(P),
    schema_called(P, "Trig", Trig),
    engine_intern("kitchen", Kitchen, E0, E1),
    host_assert(Trig, [str(Kitchen)], no, TrigResult, _, E1, E2),
    TrigResult = inserted(_),
    pump(default_budget, Effects, E2, _),
    list.find_first_match(logged("absent kitchen"), Effects, _).

:- pred logged(string::in, effect::in) is semidet.

logged(Text, Eff) :-
    Eff = eff_event(se_log_emitted(_, Text)).

    % Anywhere in a test, a cache read whose key is an interpolation of more
    % than one primitive -- through whatever provenance or comparison wraps it.
    %
:- pred contains_cache_concat(expr::in) is semidet.

contains_cache_concat(E) :-
    ( if E = e_call(fn_cache_get, [e_interp([_, _ | _])]) then
        true
    else if E = e_binop(_, L, R) then
        ( contains_cache_concat(L) ; contains_cache_concat(R) )
    else if E = e_unop(_, X) then
        contains_cache_concat(X)
    else
        E = e_call(_, Args),
        list.member(A, Args),
        contains_cache_concat(A)
    ).

:- pred logged_ok(effect::in) is semidet.

logged_ok(Eff) :-
    Eff = eff_event(se_log_emitted(_, "ok dev1")).

    % A dispatched `call` carrying a resolved correlation. [IDSP.6.7] has the
    % engine evaluate it once at dispatch, so the effect carries the value the
    % activation minted rather than the expression that built it.
    %
:- pred issued_call(effect::in) is semidet.

issued_call(eff_action(a_call(_, correlated(_), _, _))).

:- pred schema_called(program::in, string::in, schema::out) is semidet.

schema_called(P, Name, Schema) :-
    list.find_first_match(
        ( pred(S::in) is semidet :-
            expand(interns(P), schema_name_ref(S ^ s_name), Name)
        ), schemas(P), Schema).

    % Some schema in the loaded program has a `Float` slot.
    %
:- pred carries_float_slot(program::in) is semidet.

carries_float_slot(P) :-
    list.find_first_match(
        ( pred(S::in) is semidet :-
            list.find_first_match(
                ( pred(C::in) is semidet :- C ^ sc_kind = k_float ),
                slot_commons(S), _)
        ), schemas(P), _).

    % The loaded CapabilityInfo's `requires` names `float`.
    %
:- pred requires_float(program::in) is semidet.

requires_float(P) :-
    capb_of(P) = capb(_, Requires),
    set.contains(Requires, cap_float).

    % A source's header site count, through the real compiler and loader.
    %
:- pred compiled_sites(string::in, uint32::out) is semidet.

compiled_sites(Source, Sites) :-
    compile(Source) = compiled(Bytes, _, _),
    load_dsc(from_bytes(Bytes), Load),
    Load = loaded(P),
    Sites = header(P) ^ dh_fault_fact_sites.

    % Like `check_source`, asserting on the loaded program.
    %
:- pred check_source_loaded(string, string, pred(program),
                            tally, tally, io, io).
:- mode check_source_loaded(in, in, pred(in) is semidet, in, out, di, uo)
    is det.

check_source_loaded(Name, Source, Wanted, !T, !IO) :-
    Result = compile(Source),
    ( if Result = compiled(Bytes, _, _) then
        load_dsc(from_bytes(Bytes), Load),
        (
            Load = loaded(P),
            ( if Wanted(P) then
                Ok = yes
            else
                Ok = no,
                io.write_string("    loaded, but the program is not the one "
                    ++ "wanted\n", !IO)
            )
        ;
            Load = load_failed(E),
            Ok = no,
            io.format("    load refused: %s [%s]\n",
                [s(string.string(E ^ le_kind)),
                 s(clause_id_string(E ^ le_clause))], !IO)
        )
    else
        Ok = no,
        report_failure(Result, !IO)
    ),
    check(Name, Ok, !T, !IO).

    % What the lowering makes of every rule. `Want` lists one "rule" per rule
    % the compile must REFUSE with `DS_VALIDATE_RULE_NOT_LOWERED`, and nothing
    % else in the refusal; `[]` means the compile must succeed and load.
    %
:- pred check_unlowered(string::in, string::in, list(string)::in,
                        tally::in, tally::out, io::di, io::uo) is det.

check_unlowered(Name, Source, Want, !T, !IO) :-
    Result = compile(Source),
    (
        Result = compiled(Bytes, _, _),
        ( if Want = [], load_dsc(from_bytes(Bytes), loaded(_)) then
            Ok = yes
        else
            Ok = no,
            io.format("    want %s refused; the file compiled\n",
                [s(string.string(Want))], !IO)
        )
    ;
        Result = compile_rejected(Diagnostics),
        Got = list.map(not_lowered_kind, Diagnostics),
        ( if Want = [_ | _], Got = Want then
            Ok = yes
        else
            Ok = no,
            io.format("    want %s refused, got:\n",
                [s(string.string(Want))], !IO),
            report_rejection(Diagnostics, !IO)
        )
    ;
        Result = compile_stopped(_, _, _, _),
        Ok = no,
        report_failure(Result, !IO)
    ),
    check(Name, Ok, !T, !IO).

    % "rule" for a `DS_VALIDATE_RULE_NOT_LOWERED`, and the code's name for any
    % other diagnostic, so an unexpected code shows in the comparison.
    %
:- func not_lowered_kind(diagnostic) = string.

not_lowered_kind(D) =
    ( if D ^ dg_code = dc_validate(dv_rule_not_lowered) then
        "rule"
    else
        code_name(D ^ dg_code)
    ).

    % Rule `nested_lit`: a call with a generated correlation whose `on` body
    % holds a continued call carrying `As`.
    %
:- func nested_continued_source(string) = string.

nested_continued_source(As) =
    "schema Reply scope ttl 1_h:\n" ++
    "    corr: String\n" ++
    "    code: Int\n" ++
    "\n" ++
    "service svc.a:\n" ++
    "    kwarg entity_id: String\n" ++
    "    response Reply\n" ++
    "\n" ++
    "service svc.b:\n" ++
    "    kwarg entity_id: String\n" ++
    "    response Reply\n" ++
    "\n" ++
    "schema Trig scope logical:\n" ++
    "    v: Int key\n" ++
    "\n" ++
    "rule nested_lit:\n" ++
    "    Trig\n" ++
    "->\n" ++
    "    call svc.a entity_id: \"x\" cooldown: 1_h\n" ++
    "        on response.code == 200:\n" ++
    "            call svc.b entity_id: \"y\" cooldown: 1_h" ++ As ++ "\n" ++
    "                on response.code == 200:\n" ++
    "                    log info \"inner\"\n".

    % Refused, with this code. The wording is not asserted.
    %
:- pred check_refused(string::in, string::in, ds_validate::in,
                      tally::in, tally::out, io::di, io::uo) is det.

check_refused(Name, Source, Want, !T, !IO) :-
    Result = compile(Source),
    ( if Result = compile_rejected(Diagnostics) then
        ( if has_code(Diagnostics, Want) then
            Ok = yes
        else
            Ok = no,
            io.format("    wanted %s, got:\n",
                [s(ds_validate_name(Want))], !IO),
            report_rejection(Diagnostics, !IO)
        )
    else
        Ok = no,
        io.format("    wanted %s, but the file was not refused\n",
            [s(ds_validate_name(Want))], !IO),
        report_failure(Result, !IO)
    ),
    check(Name, Ok, !T, !IO).

    % Refused with `Want` and without `Unwanted`.
    %
:- pred check_refused_without(string::in, string::in, ds_validate::in,
                              ds_validate::in, tally::in, tally::out,
                              io::di, io::uo) is det.

check_refused_without(Name, Source, Want, Unwanted, !T, !IO) :-
    Result = compile(Source),
    ( if
        Result = compile_rejected(Diagnostics),
        has_code(Diagnostics, Want),
        not has_code(Diagnostics, Unwanted)
    then
        Ok = yes
    else
        Ok = no,
        io.format("    wanted %s and no %s, got:\n",
            [s(ds_validate_name(Want)), s(ds_validate_name(Unwanted))], !IO),
        report_failure(Result, !IO)
    ),
    check(Name, Ok, !T, !IO).

    % Recursive, not `list.member`: `member(out, in)` is nondet, and a list can
    % carry one code twice.
    %
:- pred has_code(list(diagnostic)::in, ds_validate::in) is semidet.

has_code([D | Ds], Code) :-
    ( if D ^ dg_code = dc_validate(Code) then
        true
    else
        has_code(Ds, Code)
    ).

:- pred report_rejection(list(diagnostic)::in, io::di, io::uo) is det.

report_rejection(Diagnostics, !IO) :-
    list.foldl(report_diagnostic, Diagnostics, !IO).

:- pred report_diagnostic(diagnostic::in, io::di, io::uo) is det.

report_diagnostic(D, !IO) :-
    Pos = D ^ dg_pos,
    io.format("    %s at %d:%d — %s\n",
        [s(code_name(D ^ dg_code)), i(Pos ^ p_line), i(Pos ^ p_col),
         s(D ^ dg_message)], !IO).

:- pred report_failure(compile_result::in, io::di, io::uo) is det.

report_failure(compiled(_, _, _), !IO).
report_failure(compile_rejected(Ds), !IO) :-
    report_rejection(Ds, !IO).
report_failure(compile_stopped(_, Message, Pos, _), !IO) :-
    io.format("    stopped at %d:%d — %s\n",
        [i(Pos ^ p_line), i(Pos ^ p_col), s(Message)], !IO).

%-----------------------------------------------------------------------------%
:- end_module test_encode.
%-----------------------------------------------------------------------------%

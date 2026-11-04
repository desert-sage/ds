% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.lower -- schema declarations to the runtime's `schema` descriptors.
%
% The output is the runtime's own `schema` type. A slot's wire kind comes from
% the type table, a unit's from its declared storage.
%-----------------------------------------------------------------------------%

:- module dsc.lower.
:- interface.

:- import_module ds.
:- import_module ds.intern.
:- import_module ds.schema.

:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.encode.
:- import_module dsc.resolve.
:- import_module dsc.token.

:- import_module assoc_list.
:- import_module list.
:- import_module pair.
:- import_module uint32.


%-----------------------------------------------------------------------------%

    %@helper
:- type lower_result
    --->    lowered(intern_table, list(schema), uint32,
                assoc_list(string, pos), list(doc_entry))
            % The importing file's `module_id`; each schema's declaration
            % position, by name; every schema and slot docstring.
            % `dsc.driver` adds the rules' docstrings.
    ;       lower_errors(list(diagnostic)).

    % In source order, with `hydrated_corr` supplied to each schema the list
    % names.
    %
    %@helper
:- pred lower_schemas(resolved_file::in, list(string)::in, lower_result::out)
    is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.chrono.
:- import_module ds.i64.
:- import_module ds.id.
:- import_module int64.

:- import_module dsc.ast.
:- import_module dsc.builtin_types.
:- import_module dsc.dstest.
:- import_module dsc.expr.
:- import_module dsc.types.

:- use_module dsc.exact.
:- use_module dsc.quantity.

:- import_module bool.
:- import_module float.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module require.
:- import_module string.
:- import_module uint64.

%-----------------------------------------------------------------------------%
% The pass
%-----------------------------------------------------------------------------%

lower_schemas(RF, HydrationTargets, Result) :-
    Decls = RF ^ rf_ast ^ af_decls,
    Storage = RF ^ rf_unit_storage,
    Local = ast_schemas(Decls),
    % Imported libraries' schemas first, leaves first. One reached through two
    % libraries is emitted once.
    list.foldl3(rdsc_4_7_module, RF ^ rf_library_modules,
        list.map((func(S) = S ^ as_own), Local), _,
        1u32, FileClip, [], RevLibrary),
    Schemas = list.reverse(RevLibrary)
        ++ list.map((func(S) = FileClip - S), Local),
    lower_each(RF, Storage,
        list.map(
            ( func(Clip - S) = Clip - rhim_2_1_hydrated_corr(HydrationTargets, S)
            ), Schemas),
        1u32, init_interns, IT,
        [], RevOut, [], RevErrors),
    (
        RevErrors = [],
        Result = lowered(IT, list.reverse(RevOut), FileClip,
            list.filter_map(rdsc_5_7_1_position, Schemas),
            list.condense(list.map(rdsc_14_4_1_schema_docs, Schemas)))
    ;
        RevErrors = [_ | _],
        Result = lower_errors(list.reverse(RevErrors))
    ).

    % An injected schema has none: its `as_pos` is a line of `dsc.builtins`' text.
    %
    %@spec [RDSC.5.7.1]
:- func rdsc_5_7_1_position(pair(uint32, ast_schema)) = pair(string, pos)
    is semidet.

    % An undocumented declaration contributes nothing, not an empty DocString.
    %
    %@spec [RDSC.14.4.1]
    %@spec [RDSC.14.4.6]
:- func rdsc_14_4_1_schema_docs(pair(uint32, ast_schema)) = list(doc_entry).

rdsc_14_4_1_schema_docs(Module) = Docs :-
    Module = Clip - S,
    Name = S ^ as_own,
    Origin = S ^ as_origin,
    ( if S ^ as_doc = yes(Text) then
        Own = [doc_entry(dt_schema, Clip, Name, "", "", Text, S ^ as_pos,
            Origin)]
    else
        Own = []
    ),
    Slots = list.filter_map(
        ( func(F) = doc_entry(dt_slot, Clip, Name, F ^ af_name ^ id_name, "",
                              SlotText, F ^ af_pos, Origin)
            is semidet :- F ^ af_doc = yes(SlotText)
        ), S ^ as_fields),
    Docs = Own ++ Slots.

rdsc_5_7_1_position(Module) = Name - Position :-
    Module = _ - S,
    S ^ as_origin = author_declared,
    Name = S ^ as_own,
    Position = S ^ as_pos.

    % `rf_library_modules` is in `module_id` order, so the id is the position. A
    % library with no schema still takes its id: the id identifies a module. A
    % name already taken is dropped: it is one library reached along two paths.
    %
    %@spec [RDSC.4.7]
    %@spec [RDSC.8.1.1]
:- pred rdsc_4_7_module(pair(string, list(ast_schema))::in,
                        list(string)::in, list(string)::out,
                        uint32::in, uint32::out,
                        assoc_list(uint32, ast_schema)::in,
                        assoc_list(uint32, ast_schema)::out) is det.

rdsc_4_7_module(_Library - Schemas, !Seen, !Clip, !Acc) :-
    list.foldl2(
        ( pred(S::in, Seen0::in, Seen::out, Acc0::in, Acc::out) is det :-
            Name = S ^ as_own,
            ( if list.member(Name, Seen0) then
                Seen = Seen0,
                Acc = Acc0
            else
                Seen = [Name | Seen0],
                Acc = [!.Clip - S | Acc0]
            )
        ), Schemas, !Seen, !Acc),
    !:Clip = !.Clip + 1u32.

    % Added to the schema the lowering sees, not to the file: validation has run
    % over the author's declaration, and everything downstream sees a real slot.
    %
    %@spec [RHIM.2.1]
    %@spec [RHIM.2.3]
:- func rhim_2_1_hydrated_corr(list(string), ast_schema) = ast_schema.

rhim_2_1_hydrated_corr(Targets, S) = Supplied :-
    Fields = S ^ as_fields,
    ( if
        list.member(S ^ as_own, Targets),
        not (
            list.member(F, Fields),
            F ^ af_name ^ id_name = "hydrated_corr"
        )
    then
        Pos = S ^ as_pos,
        ( if S ^ as_lifecycle = al_logical(_) then
            Markers = [am_mutable(Pos)]
        else
            Markers = []
        ),
        Slot = ast_field(ident("hydrated_corr", Pos), ident("String", Pos),
            non_null, no, Markers, no, no, Pos, no),
        Supplied = (S ^ as_fields := Fields ++ [Slot])
    else
        Supplied = S
    ).

    %@helper
:- func ast_schemas(list(ast_decl)) = list(ast_schema).

ast_schemas([]) = [].
ast_schemas([D | Ds]) =
    ( if D = ad_schema(S) then [S | ast_schemas(Ds)] else ast_schemas(Ds) ).

    % The id is 1-based, as `ds.dsc_schema.make_schema` numbers schemas, and is not
    % on the wire: a value produced here equals the one the loader builds.
    %
    %@helper
:- pred lower_each(resolved_file::in, map(decl_ref, string)::in,
                   assoc_list(uint32, ast_schema)::in, uint32::in,
                   intern_table::in, intern_table::out,
                   list(schema)::in, list(schema)::out,
                   list(diagnostic)::in, list(diagnostic)::out) is det.

lower_each(_, _, [], _, !IT, !Out, !Errors).
lower_each(RF, Storage, [Clip - S | Ss], Id, !IT, !Out, !Errors) :-
    lower_one(RF, Storage, Id, Clip, S, !IT, !Out, !Errors),
    lower_each(RF, Storage, Ss, Id + 1u32, !IT, !Out, !Errors).

    %@helper
:- pred lower_one(resolved_file::in, map(decl_ref, string)::in, uint32::in,
                  uint32::in,
                  ast_schema::in,
                  intern_table::in, intern_table::out,
                  list(schema)::in, list(schema)::out,
                  list(diagnostic)::in, list(diagnostic)::out) is det.

lower_one(RF, Storage, Id, Clip, S, !IT, !Out, !Errors) :-
    intern(S ^ as_own, NameRef, !IT),
    lower_fields(RF, Storage, S ^ as_fields, 0, !IT, [], RevSlots, !Errors),
    Slots = list.reverse(RevSlots),
    lifecycle_of(RF, S, Slots, Lifecycle, !Errors),
    ( if module_id(Clip, Module) then
        MaybeModule = yes(Module)
    else
        MaybeModule = no
    ),
    Schema = schema(make_schema_id(Id), make_schema_name(NameRef), Lifecycle,
        MaybeModule, no),
    !:Out = [Schema | !.Out].

%-----------------------------------------------------------------------------%
% Lifecycles -- [LSCP.2], [RDSC.5.3], [RDSC.5.4]
%-----------------------------------------------------------------------------%

    % `scope ttl <dur> ambient` is refused here: `lc_ttl` carries no ambient flag,
    % so this is where it would be dropped.
    %
    %@helper
:- pred lifecycle_of(resolved_file::in, ast_schema::in, list(field_slot)::in,
                     lifecycle::out,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

lifecycle_of(RF, S, Slots, Lifecycle, !Errors) :-
    Life = S ^ as_lifecycle,
    (
        % `internal` travels as `explicit`: the runtime knows the two fault schemas
        % by their reserved names.
        ( Life = al_explicit
        ; Life = al_internal
        ),
        Lifecycle = lc_explicit(list.map(plain, Slots))
    ;
        Life = al_activation,
        Lifecycle = lc_activation(list.map(plain, Slots))
    ;
        Life = al_logical(Ambient),
        logical_slots(RF, Slots, Logical, !Errors),
        Lifecycle = lc_logical(Logical, ambient_flag(Ambient))
    ;
        Life = al_ttl(Span, Ambient),
        ttl_ambient(S, Ambient, !Errors),
        ttl_ns(RF, S, Span, Ns, !Errors),
        Lifecycle = lc_ttl(list.map(plain, Slots), duration_from_ns(Ns))
    ).

    %@helper
:- func ambient_flag(ast_ambient) = bool.

ambient_flag(aa_ambient) = yes.
ambient_flag(aa_not_ambient) = no.

    %@helper
:- pred ttl_ambient(ast_schema::in, ast_ambient::in,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

ttl_ambient(S, Ambient, !Errors) :-
    (
        Ambient = aa_ambient,
        D = with_hint(error_at(dv_ttl_ambient_not_in_v1, S ^ as_pos,
            "schema `" ++ S ^ as_name ^ id_name ++ "`: `scope ttl <dur> "
                ++ "ambient` is reserved and not supported in v1 "
                ++ "([LSCP.2.5.9]); only `scope logical ambient` is admitted"),
            "a `ttl` base for `ambient` needs a wire field SchemaTtl does not carry"),
        !:Errors = [D | !.Errors]
    ;
        Ambient = aa_not_ambient
    ).

%-----------------------------------------------------------------------------%
% The TTL duration -- [LGRA.5.2], [RDSC.5.3.3]
%-----------------------------------------------------------------------------%

    %@helper
:- pred ttl_ns(resolved_file::in, ast_schema::in, list(positioned)::in,
               uint64::out,
               list(diagnostic)::in, list(diagnostic)::out) is det.

ttl_ns(RF, S, Span, Ns, !Errors) :-
    ( if
        Span = [Tok],
        Tok ^ tk_tok = unit_lit(Magnitude, Suffix)
    then
        Pos = Tok ^ tk_pos,
        Symbol = llex_12_5_symbol_of(Suffix),
        ( if dur_unit_ns(Symbol, Multiplier) then
            Value = luni_3_1_5_magnitude_ns(Magnitude, Multiplier),
            ( if Value =< 0i64 then
                Ns = 0u64,
                !:Errors = [error_at(dv_ttl_zero, Pos,
                    "schema `" ++ S ^ as_name ^ id_name ++ "`: a `ttl` "
                        ++ "duration must be greater than zero "
                        ++ "([RDSC.5.3.3])") | !.Errors]
            else
                Ns = uint64.cast_from_int64(Value)
            )
        else
            % One code, two messages: `30sec` is not told it is another dimension.
            Ns = 0u64,
            ( if declared_unit(RF, Symbol) then
                Message = "a `ttl` duration takes a time-unit suffix; `"
                    ++ Symbol ++ "` is a declared unit of another dimension "
                    ++ "([LLEX.12.8])"
            else
                Message = "a `ttl` duration takes a time-unit suffix, and `"
                    ++ Symbol ++ "` in `" ++ Magnitude ++ Suffix
                    ++ "` is no time unit ([LLEX.12.8])"
            ),
            D = with_hint(error_at(dv_bad_unit_dimension, Pos, Message),
                "the time units are `ns`, `µs`, `ms`, `s`, `min`, `h` and `d`"),
            !:Errors = [D | !.Errors]
        )
    else if
        % `dsc.parse` leaves one `UNIT_LIT` or one `NAME` here ([LGRA.2.8.10]),
        % so this is the `NAME`, a `Duration` const once `dsc.validate`'s
        % `lgra_2_8_11_name` has passed it, read as the literal of its value
        % ([LGRA.2.8.11]).
        Span = [Tok],
        lgra_2_8_1_time_expr_ns(RF, Span, Value)
    then
        ( if Value =< 0i64 then
            Ns = 0u64,
            !:Errors = [error_at(dv_ttl_zero, Tok ^ tk_pos,
                "schema `" ++ S ^ as_name ^ id_name ++ "`: a `ttl` duration "
                    ++ "must be greater than zero, and this constant's value is "
                    ++ "not ([LGRA.5.2])") | !.Errors]
        else
            Ns = uint64.cast_from_int64(Value)
        )
    else
        % A `Duration` const whose value does not fold. Nothing the validator
        % passes reaches here; refusing it keeps a zero `SchemaTtl` off the wire.
        Ns = 0u64,
        !:Errors = [error_at(dv_type_mismatch, S ^ as_pos,
            "schema `" ++ S ^ as_name ^ id_name ++ "`: the `ttl` constant has "
                ++ "no value the compiler can fold ([LGRA.2.8.11])") | !.Errors]
    ).

    %@helper
:- pred declared_unit(resolved_file::in, string::in) is semidet.

declared_unit(RF, Symbol) :-
    ( if map.search(RF ^ rf_types, Symbol, Entry) then
        Entry = te_unit(_, _)
    else
        map.contains(RF ^ rf_unit_alias, Symbol)
    ).

    % Not the unit registry: a user-declared `time`-dimensioned unit cannot spell a
    % TTL.
    %
    %@helper
:- pred dur_unit_ns(string::in, int64::out) is semidet.

dur_unit_ns(Symbol, Multiplier) :-
    luni_10_2_time_unit(Symbol, Multiplier).

%-----------------------------------------------------------------------------%
% Slots
%-----------------------------------------------------------------------------%

    % The field is kept because the role is decided once the lifecycle is known.
    %
    %@helper
:- type field_slot
    --->    field_slot(
                fs_field  :: ast_field,
                fs_common :: slot_common
            ).

    %@helper
:- func plain(field_slot) = plain_slot.

plain(FS) = plain_slot(FS ^ fs_common).

    %@helper
:- pred lower_fields(resolved_file::in, map(decl_ref, string)::in,
                     list(ast_field)::in, int::in,
                     intern_table::in, intern_table::out,
                     list(field_slot)::in, list(field_slot)::out,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

lower_fields(_, _, [], _, !IT, !Slots, !Errors).
lower_fields(RF, Storage, [F | Fs], Index, !IT, !Slots, !Errors) :-
    slot_kind_of(RF, Storage, F, MaybeKind, !IT, !Errors),
    (
        MaybeKind = yes(Kind),
        intern(F ^ af_name ^ id_name, NameRef, !IT),
        Common = slot_common(NameRef, Kind, det_slot_index(Index),
            wire_nullable(F ^ af_nullable),
            marker_flag(mk_sampled, F ^ af_markers),
            marker_flag(mk_retained, F ^ af_markers),
            no, lstr_11_1_capacity(F)),
        !:Slots = [field_slot(F, Common) | !.Slots],
        Next = Index + 1
    ;
        MaybeKind = no,
        Next = Index
    ),
    lower_fields(RF, Storage, Fs, Next, !IT, !Slots, !Errors).

    %@helper
:- func wire_nullable(nullability) = ds.schema.nullable.

wire_nullable(dsc.expr.nullable) = ds.schema.nullable.
wire_nullable(dsc.expr.non_null) = ds.schema.non_null.

    %@helper
:- func det_slot_index(int) = slot_index.

det_slot_index(I) =
    ( if slot_index(uint32.det_from_int(I), Ix) then
        Ix
    else
        % `dsc.validate.lgra_5_11_slot_count` has refused such a schema.
        unexpected($pred, "schema has more slots than the wire can index")
    ).

%-----------------------------------------------------------------------------%
% Identity roles -- [LGRA.5.10], [LFAC.1.7.4]
%-----------------------------------------------------------------------------%

    % An unmarked slot is refused, not defaulted: either default is a wrong key
    % with no error to show for it.
    %
    %@helper
:- pred logical_slots(resolved_file::in, list(field_slot)::in,
                      list(logical_slot)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

logical_slots(_, [], [], !Errors).
logical_slots(RF, [FS | FSs], Slots, !Errors) :-
    logical_slots(RF, FSs, Rest, !Errors),
    F = FS ^ fs_field,
    ( if F ^ af_name ^ id_name = "ts" then
        % The engine's slot, outside identity and the no-op test.
        Slots = [logical_slot(FS ^ fs_common, role_engine, ds.schema.exact)
                | Rest]
    else if not identity_role_of(F ^ af_markers, _) then
        Slots = Rest,
        !:Errors = [error_at(dv_identity_role_required, F ^ af_pos,
            "slot `" ++ F ^ af_name ^ id_name ++ "`: every slot of a "
                ++ "`logical` schema must be marked `key` or `mutable` "
                ++ "([LGRA.5.10] / [LFAC.1.7.4])") | !.Errors]
    else if
        identity_role_of(F ^ af_markers, Role),
        Tolerance = tolerance_of(RF, F)
    then
        Slots = [logical_slot(FS ^ fs_common, Role, Tolerance) | Rest]
    else
        Slots = Rest,
        !:Errors = [error_at(dv_tolerance_literal_type, F ^ af_pos,
            "slot `" ++ F ^ af_name ^ id_name ++ "`: the tolerance must be a "
                ++ "numeric literal ([LGRA.5.9.1])") | !.Errors]
    ).

    % The last marker wins.
    %
    %@helper
:- pred identity_role_of(list(ast_marker)::in, identity_role::out) is semidet.

identity_role_of(Markers, Role) :-
    list.foldl(keep_identity, Markers, no, Found),
    Found = yes(Role).

    %@helper
:- pred keep_identity(ast_marker::in, maybe(identity_role)::in,
                      maybe(identity_role)::out) is det.

keep_identity(M, !Found) :-
    Kind = kind_of(M),
    (
        Kind = mk_key,
        !:Found = yes(role_key)
    ;
        Kind = mk_mutable,
        !:Found = yes(role_mutable)
    ;
        ( Kind = mk_sampled
        ; Kind = mk_retained
        )
    ).

    % A classifier: `list.member(am_key(_), Markers)` would be nondet.
    %
    %@helper
:- type marker_kind
    --->    mk_key
    ;       mk_mutable
    ;       mk_sampled
    ;       mk_retained.

    %@helper
:- func kind_of(ast_marker) = marker_kind.

kind_of(am_key(_)) = mk_key.
kind_of(am_mutable(_)) = mk_mutable.
kind_of(am_sampled(_)) = mk_sampled.
kind_of(am_retained(_)) = mk_retained.

    %@helper
:- func marker_flag(marker_kind, list(ast_marker)) = bool.

marker_flag(Kind, Markers) =
    ( if has_marker(Kind, Markers) then yes else no ).

    %@helper
:- pred has_marker(marker_kind::in, list(ast_marker)::in) is semidet.

has_marker(Kind, [M | Ms]) :-
    ( if kind_of(M) = Kind then
        true
    else
        has_marker(Kind, Ms)
    ).

%-----------------------------------------------------------------------------%
% Tolerance -- [LFAC.2.5.1]
%-----------------------------------------------------------------------------%

    % `dsc.validate.lstr_11_1_capacity` has refused an `N` below 1. One above a
    % `uint32`, the wire field's width, is unbounded.
    %
    %@spec [LSTR.11.1]
:- func lstr_11_1_capacity(ast_field) = capacity.

lstr_11_1_capacity(F) = Cap :-
    ( if
        F ^ af_capacity = yes(P),
        P ^ tk_tok = int_lit(I),
        I >= 1i64,
        I =< 4294967295i64
    then
        Cap = at_most(uint32.det_from_int(int64.cast_to_int(I)))
    else
        Cap = unbounded
    ).

    % A unit slot's tolerance is written in the base unit: `|a| * declared` for a
    % unit that converts as `y = a*x + b`, folded exactly and rounded once. A zero
    % is `exact`. Fails, and the caller refuses, rather than drop a tolerance.
    %
    %@spec [LUNI.7.4]
:- func tolerance_of(resolved_file, ast_field) = tolerance is semidet.

tolerance_of(RF, F) = T :-
    Declared = F ^ af_tolerance,
    (
        Declared = no,
        T = exact
    ;
        Declared = yes(P),
        Tok = P ^ tk_tok,
        ( if Tok = int_lit(I) then
            Exact0 = dsc.exact.from_int64(I)
        else
            Tok = float_lit(Fl),
            dsc.exact.from_float(Fl, Exact0)
        ),
        ( if
            slot_entry(RF, F, Entry),
            Entry = te_unit(uk_symbol(_), Symbol)
        then
            dsc.quantity.luni_7_4_tolerance_base(RF, Symbol, Exact0, Exact)
        else
            Exact = Exact0
        ),
        ( if dsc.exact.sign(Exact) = 0 then
            T = exact
        else
            dsc.exact.to_float(Exact, D),
            T = within(D)
        )
    ).

%-----------------------------------------------------------------------------%
% Slot kinds -- [RDSC.5.5.2]
%-----------------------------------------------------------------------------%

    %@spec [RDSC.5.5.4]
    %@spec [RDSC.5.5.2]
:- pred rdsc_5_5_4_slot_kind(resolved_file::in, map(decl_ref, string)::in,
                             string::in, pos::in, type_entry::in,
                             maybe(slot_kind)::out,
                             intern_table::in, intern_table::out,
                             list(diagnostic)::in, list(diagnostic)::out)
    is det.

rdsc_5_5_4_slot_kind(RF, Storage, Name, Pos, Entry, Result, !IT, !Errors) :-
    (
        Entry = te_builtin(Builtin),
        ( if builtin_slot_kind(Builtin) = yes(Kind) then
            Result = yes(Kind)
        else
            Result = no,
            !:Errors = [with_hint(error_at(dv_bad_type, Pos,
                "`" ++ Name ++ "` is a type in the expression language but "
                    ++ "has no slot representation, so it cannot be stored"),
                "an interval is a pair of bounds; store the two endpoints")
                | !.Errors]
        )
    ;
        Entry = te_schema(Target),
        intern(Target ^ as_own, Ref, !IT),
        Result = yes(k_schema(make_schema_name(Ref)))
    ;
        Entry = te_unit(UnitKind, Unit),
        Group = unit_group(UnitKind, Unit),
        ( if
            map.search(Storage, Group, Declared),
            storage_slot_kind(Declared, Kind)
        then
            Result = yes(Kind)
        else
            Result = no,
            !:Errors = [with_hint(error_at(dv_bad_unit_dimension, Pos,
                "`" ++ Name ++ "` resolves to the unit group `" ++ Group ^ dr_name
                    ++ "`, which declares no storage type this slot can take"),
                "`unit dimension " ++ Group ^ dr_name
                    ++ " storage int64` (or `int32` / "
                    ++ "`float64`)") | !.Errors]
        )
    ;
        Entry = te_opaque(Opaque),
        % Erased at the wire only: `dsc.types` keeps it as `lk_opaque`.
        ReprName = Opaque ^ aop_repr ^ id_name,
        ( if
            map.search(RF ^ rf_types, ReprName, ReprEntry),
            ReprEntry = te_builtin(ReprBuiltin),
            builtin_slot_kind(ReprBuiltin) = yes(Kind)
        then
            Result = yes(Kind)
        else
            Result = no,
            !:Errors = [error_at(dv_opaque_unsupported_repr, Pos,
                "opaque type `" ++ Name ++ "` is represented as `" ++ ReprName
                    ++ "`, which has no slot representation") | !.Errors]
        )
    ).

    %@helper
:- pred slot_kind_of(resolved_file::in, map(decl_ref, string)::in, ast_field::in,
                     maybe(slot_kind)::out,
                     intern_table::in, intern_table::out,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

slot_kind_of(RF, Storage, Field, Result, !IT, !Errors) :-
    TypeId = Field ^ af_type,
    Name = TypeId ^ id_name,
    Pos = TypeId ^ id_pos,
    ( if slot_entry(RF, Field, Entry) then
        rdsc_5_5_4_slot_kind(RF, Storage, Name, Pos, Entry, Result, !IT,
            !Errors)
    else if map.search(RF ^ rf_unit_alias, Name, Canonical) then
        Result = no,
        !:Errors = [with_hint(error_at(dv_slot_type_alias, Pos,
            "`" ++ Name ++ "` is an alias of `" ++ Canonical ^ id_name
                ++ "`, and a slot type takes the canonical unit name "
                ++ "([LUNI.7.5])"),
            "write `" ++ Canonical ^ id_name ++ "`") | !.Errors]
    else
        Result = no,
        !:Errors = [error_at(dv_unknown_type, Pos,
            "`" ++ Name ++ "` is not a declared type") | !.Errors]
    ).

    % `Interval` has no slot representation.
    %
    %@helper
:- func builtin_slot_kind(lgra_22_8_builtin_type) = maybe(slot_kind).

builtin_slot_kind(bt_bool) = yes(k_bool).
builtin_slot_kind(bt_bytes) = yes(k_bytes).
builtin_slot_kind(bt_date) = yes(k_date).
builtin_slot_kind(bt_duration) = yes(k_duration).
builtin_slot_kind(bt_float) = yes(k_float).
builtin_slot_kind(bt_int) = yes(k_int).
builtin_slot_kind(bt_interval) = no.
builtin_slot_kind(bt_json) = yes(k_json).
builtin_slot_kind(bt_string) = yes(k_string).
builtin_slot_kind(bt_time) = yes(k_time).

    %@helper
:- pred storage_slot_kind(string::in, slot_kind::out) is semidet.

storage_slot_kind("int64", k_int).
storage_slot_kind("int32", k_int).
storage_slot_kind("float64", k_float).

    %@helper
:- func unit_group(unit_kind, decl_ref) = decl_ref.

unit_group(uk_dimension, Declared) = Declared.
unit_group(uk_scalar, Declared) = Declared.
unit_group(uk_symbol(Dimension), _) = Dimension.

%-----------------------------------------------------------------------------%
:- end_module dsc.lower.
%-----------------------------------------------------------------------------%

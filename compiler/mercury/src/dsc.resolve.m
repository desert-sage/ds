% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.resolve -- names, and the tables every later phase reads. The AST is
% carried through unchanged.
%
% `rf_identity` is [LFAC.1.7.5]'s one answer: no consumer recomputes it.
% Names compare as `dsc.lex` left them, NFC ([LNAM.2.3.1], [LNAM.2.4.1]).
%-----------------------------------------------------------------------------%

:- module dsc.resolve.
:- interface.

:- import_module dsc.ast.
:- import_module dsc.builtin_types.
:- import_module dsc.capability.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.expr.
:- import_module dsc.imports.
:- import_module dsc.token.

:- import_module assoc_list.
:- import_module list.
:- import_module map.

%-----------------------------------------------------------------------------%

    %@helper
:- type resolve_result
    --->    resolve_ok(resolved_file)
    ;       resolve_errors(list(diagnostic)).

    %@helper
:- type resolved_file
    --->    resolved_file(
                rf_ast         :: ast_file,
                rf_types       :: map(string, type_entry),
                rf_unit_alias  :: map(string, ident),
                rf_consts      :: map(string, ast_const),
                    % Each dimension's and scalar group's storage type.
                rf_unit_storage :: map(decl_ref, string),
                rf_identity    :: map(string, identity),
                rf_scopes      :: list(rule_scope),

                    % Every service a `call` in this file could name, by its
                    % dotted name ([LGRA.10.1.6]), the file's own and its
                    % import closure's.
                rf_services   :: map(string, ast_service_decl),

                    % Which library each imported service came from. A service
                    % the file declares is absent, and takes the file's own
                    % `module_id` ([RDSC.4.7]).
                rf_service_origin :: map(string, string),

                    % The schema each service in `rf_services` answers with, in
                    % the declaring file's scope. `asv_response` is only the
                    % spelling: through an import alias it names no schema in
                    % an artefact.
                rf_response_names :: map(string, string),

                    % Every unit declaration in scope, the file's own and its
                    % import closure's. A later phase walks a formula whole.
                rf_units       :: list(ast_unit),

                    % Each whole-library import's surface, by binding. Only
                    % libraries that loaded have an entry; a `binding.NAME`
                    % through any other is untyped and unchecked.
                rf_qualified_surface :: map(string, list(string)),

                    % Each whole-library import's schemas, keyed
                    % `binding;Schema`.
                rf_qualified_schemas :: map(string, ast_schema),

                    % Each whole-library import's constants, keyed
                    % `binding;NAME` ([LGRA.22.9]).
                rf_qualified_consts :: map(string, ast_const),

                    % Every imported library's schemas, by library, in artefact
                    % order. The grouping is what [RDSC.4.7]'s `module_id` keys.
                rf_library_modules :: assoc_list(string, list(ast_schema)),

                    % The program's resolved settings ([LDIA.1.3]), which
                    % govern every module of the unit ([LDIA.2.10.9]). Set by
                    % `dsc.driver`; until then `unresolved_program`, under
                    % which nothing passes.
                rf_program :: program_settings,

                    % The schemas the PROGRAM's services answer with, as a
                    % library cannot see them: its importer's services are
                    % outside its own closure. Set by `dsc.driver` on each
                    % library, and empty on the program's file, whose
                    % `rf_response_names` is the whole program. [LCRS.4.3.4].
                rf_program_responses :: list(string),

                    % Every dimension, scalar group, unit symbol and opaque type
                    % this file and its import closure declare, by declaration
                    % ([LUNI.4.1.5]): what a library's slot or constant names,
                    % whether or not this file can spell it ([LIMP.1.5]).
                rf_decl_types :: map(decl_ref, type_entry)
            ).

    % One rule's names, in source order: consumers walk this in step with the
    % file's rules. Two rules of one name are refused later
    % (`dsc.driver.lgra_6_8_duplicate_rules`), and this list can hold both.
    %
    %@helper
:- type rule_scope
    --->    rule_scope(
                rsc_rule     :: ident,
                rsc_bindings :: map(string, pattern_binding),
                rsc_lets     :: map(string, ident),
                rsc_captures :: map(string, ident),
                    % [LREG.4.1]'s capture names, each a `String` binding
                    % ([LREG.4.4]).
                rsc_let_types :: map(string, ast_annotation),
                    % Each annotated `let`'s annotation ([LUNI.8.6]).
                rsc_let_exprs :: map(string, lgra_9_3_1_expr)
                    % Each simple `let`'s right-hand side, annotated or not: a
                    % `let` is that expression inlined ([LLET.12.5]), and an
                    % unannotated one takes its type ([LLET.3.6]). A capture
                    % `let` has no entry.
            ).

    %@helper
:- type pattern_binding
    --->    pattern_binding(
                pb_name :: ident,
                pb_head :: lgra_22_4_head_ref
            ).

    % `head_local`: a bare name that resolved to a schema. `head_imported`: a
    % bare name a selective import binds, whose schema this compilation cannot
    % see. `head_qualified`: `lib.Schema`, with its qualifier checked. Only
    % `head_local` carries a schema.
    %
    %@spec [LGRA.22.4]
:- type lgra_22_4_head_ref
    --->    head_local(ast_schema)
    ;       head_imported(ident)
    ;       head_qualified(list(ident), ident).

    % [LGRA.22.7]'s type namespace, plus the opaque types [LOPQ.2.1] declares.
    %
    %@helper
:- type type_entry
    --->    te_builtin(lgra_22_8_builtin_type)
    ;       te_schema(ast_schema)
    ;       te_unit(unit_kind, decl_ref)
    ;       te_opaque(ast_opaque).

    % `uk_symbol` carries its dimension ([LUNI.7.1]).
    %
    %@helper
:- type unit_kind
    --->    uk_dimension
    ;       uk_scalar
    ;       uk_symbol(decl_ref).

    % [LFAC.1.7.1]'s declared key, and [LFAC.1.7.6]'s absence of one. An empty
    % key is a singleton ([LFAC.1.7.2]), not `id_unkeyed`.
    %
    %@helper
:- type identity
    --->    id_keyed(list(ident))
    ;       id_unkeyed.

    % The phase, with no library environment.
    %
    %@helper
:- pred resolve_file(ast_file::in, resolve_result::out) is det.

    % `imports_resolved`: what `dsc.imports` loaded. `imports_trusted`: no
    % library environment, so nothing loaded.
    %
    %@helper
:- type import_scope
    --->    imports_resolved(imports)
    ;       imports_trusted.

    %@helper
:- pred resolve_imported(ast_file::in, import_scope::in, resolve_result::out)
    is det.

    %@spec [LGRA.22.7]
:- pred lgra_22_7_reserved_type(string::in) is semidet.

    % [LIMP.13.1]: the own name of the schema a spelling names in this file's
    % type namespace, or the spelling where it names none.
    %
    %@spec [LIMP.13.1]
:- func limp_13_1_own_of(resolved_file, string) = string.

    % [LIMP.1.5]: the type a slot has, as the file declaring it resolved it.
    % Fails for a type that names nothing, which that file's checks refuse.
    %
    %@spec [LIMP.1.5]
:- pred slot_entry(resolved_file::in, ast_field::in, type_entry::out) is semidet.

    % [LIMP.1.5]: the file a library's constant is read in: its unit literals mean
    % what they mean in that library, whatever this file binds those names to.
    %
    %@spec [LIMP.1.5]
:- func const_scope(resolved_file, ast_const) = resolved_file.

    % [LIMP.1.5]: the file a library's kwarg is read in: its type and its
    % `default`'s unit literals mean what they mean in that library. The argument a
    % call writes is not read in it: that is the calling file's.
    %
    %@spec [LIMP.1.5]
:- func kwarg_scope(resolved_file, ast_service_kwarg) = resolved_file.

    % The schema a schema reference names, at any [LGRA.22.4] site: a bare
    % name through the type namespace, `lib.Schema` through the qualified
    % imports. Fails for a name this compilation cannot see a schema for --
    % unknown, or trusted from a library that did not load.
    %
    %@spec [LGRA.22.4]
:- pred lgra_22_4_schema_of(resolved_file::in, ast_type_ref::in,
                            ast_schema::out) is semidet.

    % [LIMP.4.3.2]: "`ha._Helper` in pattern position rejects with
    % `DS_VALIDATE_UNKNOWN_SCHEMA`" -- a qualified reference to a library this
    % compiler loaded, naming no schema the library exports. A library with no
    % recorded surface did not load, and its reference stays trusted.
    %
    %@spec [LIMP.4.3.2]
:- pred limp_4_3_2_not_exported(map(string, list(string))::in,
                                map(string, ast_schema)::in,
                                list(ident)::in, ident::in) is semidet.

    % The name a schema reference ends in, which is where its diagnostics
    % point.
    %
    %@helper
:- func type_ref_name(ast_type_ref) = ident.
    %@helper
:- func type_ref_text(ast_type_ref) = string.

    % [LGRA.22.9]: a dotted name in expression position that is a library
    % member, `lib.NAME` or `units.si.NAME`, as the library's path or alias
    % and the member. Fails for slot access and for anything unresolved.
    %
    % A property of the file's imports alone: `lgra_22_9_shadows` keeps a
    % binding from sharing a library's first segment. A longer chain,
    % `ha.RETRY.utc`, fails here and its caller reads it as an access on the
    % shorter one.
    %
    %@spec [LGRA.22.9]
:- pred lgra_22_9_library_member(resolved_file::in, lgra_9_3_1_expr::in,
                                 list(ident)::out, ident::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.




:- import_module dsc.builtins.
:- import_module dsc.libcall.
:- import_module maybe.
:- import_module pair.
:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%

resolve_file(File, Result) :-
    resolve_imported(File, imports_trusted, Result).

resolve_imported(File0, Scope, Result) :-
    % [LIMP.3.3.4]: every call to a `math` or `distance` member, in whatever
    % spelling the file's imports allow, becomes a call to its [LEXP.17.2] row
    % before anything reads the tree (`dsc.libcall`).
    File1 = limp_3_3_4_rewrite_file(File0),
    File0Decls = File1 ^ af_decls,
    (
        Scope = imports_resolved(Imports)
    ;
        Scope = imports_trusted,
        Imports = no_imports
    ),
    % The diagnostics are discarded: their positions are in another file.
    list.foldl3(add_type_decl, imported_unit_decls(Imports),
        map.init, ImportedTypes, map.init, ImportedAliases, [], _),
    Decls = luni_4_1_5_own_links(ImportedTypes, File0Decls),
    File = File1 ^ af_decls := Decls,
    lgra_22_7_type_env(Decls, Types0, Aliases0, TypeErrors),
    resolve_consts(Decls, LocalConsts, ConstErrors),
    Consts = map.overlay(Imports ^ im_consts, LocalConsts),
    Types = limp_13_1_own_types(Decls, Imports,
        map.overlay(map.overlay(ImportedTypes, imported_types(Imports)),
            Types0)),
    Aliases = map.overlay(ImportedAliases, Aliases0),
    % The closure's units last, so a name this file binds is found first. A file
    % cannot spell the ones it doesn't bind, and a slot of a library's schema still
    % needs their storage and scale ([LIMP.1.5]).
    Units = local_units(Decls) ++ Imports ^ im_units
        ++ list.filter_map(
            ( func(D) = U is semidet :- D = ad_unit(U) ),
            list.condense(list.map(( func(_ - Ds) = Ds ),
                Imports ^ im_library_types))),
    UnitStorage = unit_storage(Units),
    DeclTypes = luni_4_1_5_decl_types(Decls ++ imported_type_decls(Imports)
        ++ list.condense(list.map(( func(_ - Ds) = Ds ),
            Imports ^ im_library_types))),
    Identity = identity_env(Decls),
    llet_12_4_rule_scopes(Types, Decls, Consts, Imports ^ im_qualified_surface,
        Imports ^ im_qualified_schemas, Scopes, ScopeErrors),
    UnitErrors = luni_4_1_2_local_units(Decls, Imports ^ im_unit_origin),
    SchemaErrors = lgra_22_5_local_schemas(Decls,
        Imports ^ im_schema_origin)
        ++ limp_12_3_builtin_collisions(Decls),
    LocalConstErrors = lgra_4_6_local_consts(Decls,
        Imports ^ im_const_origin),
    ShadowErrors = lgra_22_9_shadows(Decls),
    Errors = TypeErrors ++ ConstErrors ++ ScopeErrors ++ UnitErrors
        ++ SchemaErrors ++ LocalConstErrors ++ ShadowErrors,
    (
        Errors = [],
        Services = map.overlay(Imports ^ im_services, local_services(Decls)),
        Result = resolve_ok(resolved_file(File, Types, Aliases, Consts,
            UnitStorage, Identity, Scopes, Services,
            % A local declaration under an imported spelling has no origin.
            map.delete_list(Imports ^ im_service_origin,
                map.keys(local_services(Decls))),
            map.overlay(
                map.delete_list(Imports ^ im_service_response,
                    map.keys(local_services(Decls))),
                lgra_23_1_responses(limp_13_1_file_own(Imports), Decls)),
            Units,
            Imports ^ im_qualified_surface, Imports ^ im_qualified_schemas,
            Imports ^ im_qualified_consts,
            Imports ^ im_library_schemas, unresolved_program, [], DeclTypes))
    ;
        Errors = [_ | _],
        Result = resolve_errors(Errors)
    ).

    % [LIMP.1.5]: every library schema this file's closure holds, under its own
    % name, which is how a library's slot names one (`dsc.imports.limp_1_5_tree`).
    % Source cannot spell these keys: a type is one symbol ([LGRA.2.5.1]) and an
    % own name with a path holds a `.`, so no author's name meets one. A schema
    % whose own name is its `NAME` is in the table already.
    %
    %@spec [LIMP.1.5]
:- func limp_13_1_own_types(list(ast_decl), imports, map(string, type_entry))
    = map(string, type_entry).

limp_13_1_own_types(Decls, Imports, Types0) =
    list.foldl(
        ( func(S, Types) = map.set(Types, S ^ as_own, te_schema(S)) ),
        list.filter(
            ( pred(S::in) is semidet :- S ^ as_own \= S ^ as_name ^ id_name ),
            list.filter_map(
                ( func(D) = S is semidet :- D = ad_schema(S) ), Decls)
            ++ list.condense(list.map(
                ( func(_ - Schemas) = Schemas ),
                Imports ^ im_library_schemas))),
        Types0).

    % [LUNI.4.1.5]: each declaration in `Decls` that has an identity, by it.
    %
    %@spec [LUNI.4.1.5]
:- func luni_4_1_5_decl_types(list(ast_decl)) = map(decl_ref, type_entry).

luni_4_1_5_decl_types(Decls) =
    list.foldl(
        ( func(D, Types) =
            ( if luni_4_1_5_decl_entry(D, Ref, Entry) then
                map.set(Types, Ref, Entry)
            else
                Types
            )
        ), Decls, map.init).

    %@helper
:- pred luni_4_1_5_decl_entry(ast_decl::in, decl_ref::out, type_entry::out)
    is semidet.

luni_4_1_5_decl_entry(ad_opaque(O), Ref, te_opaque(O)) :-
    Ref = decl_ref(O ^ aop_file, O ^ aop_name ^ id_name).
luni_4_1_5_decl_entry(ad_unit(U), Ref, Entry) :-
    (
        U = au_dimension(N, _, _, _, File),
        Ref = decl_ref(File, N ^ id_name),
        Entry = te_unit(uk_dimension, Ref)
    ;
        U = au_scalar(N, _, _, _, File),
        Ref = decl_ref(File, N ^ id_name),
        Entry = te_unit(uk_scalar, Ref)
    ;
        U = au_symbol(N, _, _, _, _, _, File, DimRef),
        Ref = decl_ref(File, N ^ id_name),
        Entry = te_unit(uk_symbol(DimRef), Ref)
    ).

    % [LUNI.4.1.5]: the declaration each unit of the program's own file names as
    % its dimension: one the file declares, else one it holds from an import,
    % else `units.core`'s, in scope in every file ([LUNI.4.1.2]). A library's are
    % its own file's (`dsc.imports.limp_1_5_unit`).
    %
    %@spec [LUNI.4.1.5]
:- func luni_4_1_5_own_links(map(string, type_entry), list(ast_decl))
    = list(ast_decl).

luni_4_1_5_own_links(Imported, Decls) =
    list.map(luni_4_1_5_own_link(Imported, list.filter_map(own_dimension, Decls)),
        Decls).

    %@helper
:- func own_dimension(ast_decl) = string is semidet.

own_dimension(Decl) = Name :-
    Decl = ad_unit(U),
    (
        U = au_dimension(N, _, _, _, ""),
        Name = N ^ id_name
    ;
        U = au_scalar(N, _, _, _, ""),
        Name = N ^ id_name
    ).

    %@helper
:- func luni_4_1_5_own_link(map(string, type_entry), list(string), ast_decl)
    = ast_decl.

luni_4_1_5_own_link(Imported, Own, Decl) =
    ( if
        Decl = ad_unit(au_symbol(N, Dim, Body, Label, Aliases, Pos, "", _))
    then
        ad_unit(au_symbol(N, Dim, Body, Label, Aliases, Pos, "",
            luni_4_1_5_dimension_ref(Imported, Own, Dim ^ id_name)))
    else
        Decl
    ).

    %@helper
:- func luni_4_1_5_dimension_ref(map(string, type_entry), list(string), string)
    = decl_ref.

luni_4_1_5_dimension_ref(Imported, Own, Name) =
    ( if list.member(Name, Own) then
        decl_ref("", Name)
    else if
        map.search(Imported, Name, Entry),
        Entry = te_unit(Kind, Ref),
        ( Kind = uk_dimension ; Kind = uk_scalar )
    then
        Ref
    else
        decl_ref("units.core", Name)
    ).

slot_entry(RF, Field, Entry) :-
    ( if Field ^ af_decl = yes(Ref) then
        map.search(RF ^ rf_decl_types, Ref, Entry)
    else
        map.search(RF ^ rf_types, Field ^ af_type ^ id_name, Entry)
    ).

const_scope(RF, Const) = limp_1_5_scope(RF, Const ^ acn_units).

kwarg_scope(RF, Kwarg) = limp_1_5_scope(RF, Kwarg ^ ask_units).

    %@helper
:- func limp_1_5_scope(resolved_file, assoc_list(string, decl_ref))
    = resolved_file.

limp_1_5_scope(RF, Units) = RF ^ rf_types :=
    list.foldl(
        ( func(Suffix - Ref, Types) =
            ( if map.search(RF ^ rf_decl_types, Ref, Entry) then
                map.set(Types, Suffix, Entry)
            else
                Types
            )
        ), Units, RF ^ rf_types).

    % [LIMP.13.1]: the own name of what a spelling names in the file: an
    % imported schema's, else the spelling, as a schema the file declares has
    % its `NAME` for its own name.
    %
    %@spec [LIMP.13.1]
:- func limp_13_1_file_own(imports, string) = string.

limp_13_1_file_own(Imports, Spelling) =
    ( if map.search(Imports ^ im_schemas, Spelling, Schema) then
        Schema ^ as_own
    else
        Spelling
    ).

limp_13_1_own_of(RF, Spelling) =
    ( if map.search(RF ^ rf_types, Spelling, te_schema(Schema)) then
        Schema ^ as_own
    else
        Spelling
    ).

    % A file's own `schema` under a name a selective import bound to a library's
    % schema: the two are distinct whatever their text. Keyed on the binding:
    % `from ha import X as Y` binds `Y`, and `import ha` binds no bare name.
    %
    %@spec [LGRA.22.5]
    %@spec [LIMP.2.1.7]
:- func lgra_22_5_local_schemas(list(ast_decl), map(string, string))
    = list(diagnostic).

lgra_22_5_local_schemas(Decls, Origins) =
    list.filter_map(
        ( func(Decl) = D is semidet :-
            Decl = ad_schema(Schema),
            Id = Schema ^ as_name,
            map.search(Origins, Id ^ id_name, Lib),
            D = with_hint(error_at(dv_import_name_collision, Id ^ id_pos,
                "schema `" ++ Id ^ id_name ++ "` is declared here and also "
                    ++ "imported from `" ++ Lib ++ "`, which declares another "
                    ++ "([LGRA.22.5])"),
                "rename the local schema, or import the library's with `as`")
        ),
        Decls).

    % A local `const` under a name a selective import bound to a library's
    % constant, keyed on the binding as `lgra_22_5_local_schemas` is. A `math`
    % or `distance` member is `lgra_22_9_shadows`'s.
    %
    %@spec [LGRA.4.6]
:- func lgra_4_6_local_consts(list(ast_decl), map(string, string))
    = list(diagnostic).

lgra_4_6_local_consts(Decls, Origins) =
    list.filter_map(
        ( func(Decl) = D is semidet :-
            Decl = ad_const(Const),
            Id = Const ^ acn_name,
            map.search(Origins, Id ^ id_name, Lib),
            not limp_3_3_4_builtin_module(Lib),
            D = with_hint(error_at(dv_import_name_collision, Id ^ id_pos,
                "constant `" ++ Id ^ id_name ++ "` is declared here and also "
                    ++ "imported from `" ++ Lib ++ "`, which declares another "
                    ++ "([LGRA.4.6])"),
                "rename the local constant, or import the library's with `as`")
        ),
        Decls).

    % A file's own `schema` under a built-in schema's name. `ComputationError`
    % and `TypeError` are reserved words, and `dsc.validate` refuses them.
    %
    %@spec [LIMP.12.3]
:- func limp_12_3_builtin_collisions(list(ast_decl)) = list(diagnostic).

limp_12_3_builtin_collisions(Decls) =
    list.filter_map(
        ( func(Decl) = D is semidet :-
            Decl = ad_schema(Schema),
            Schema ^ as_origin = author_declared,
            Id = Schema ^ as_name,
            list.member(Id ^ id_name, limp_12_3_collision_names),
            D = with_hint(error_at(dv_import_name_collision, Id ^ id_pos,
                "schema `" ++ Id ^ id_name ++ "` is declared here, and every "
                    ++ "program imports the built-in schema of that name "
                    ++ "([LIMP.12.1], [LIMP.12.3])"),
                "rename the local schema; the built-in one is in scope "
                    ++ "without a declaration")
        ),
        Decls).

    % A local unit under a name with a recorded origin. A unit's group members
    % have none, so a file importing `Hz` may still declare `frequency`.
    %
    %@spec [LUNI.4.1.2]
:- func luni_4_1_2_local_units(list(ast_decl), map(string, string))
    = list(diagnostic).

luni_4_1_2_local_units(Decls, Origins) =
    list.filter_map(local_unit_collision(Origins),
        list.condense(list.map(local_unit_names, Decls))).

    %@helper
:- func local_unit_names(ast_decl) = list(ident).

local_unit_names(Decl) = Names :-
    ( if Decl = ad_unit(au_dimension(N, _, _, _, _)) then
        Names = [N]
    else if Decl = ad_unit(au_scalar(N, _, _, _, _)) then
        Names = [N]
    else if Decl = ad_unit(au_symbol(N, _, _, _, _, _, _, _)) then
        Names = [N]
    else
        Names = []
    ).

    %@helper
:- func local_unit_collision(map(string, string), ident) = diagnostic
    is semidet.

local_unit_collision(Origins, Id) = D :-
    Name = Id ^ id_name,
    map.search(Origins, Name, Origin),
    ( if Origin = "units.core" then
        D = with_hint(error_at(dv_unit_import_collision, Id ^ id_pos,
            "`" ++ Name ++ "` is one of the base units baked into `units.core`, "
                ++ "which are always in scope and cannot be redeclared "
                ++ "([LUNI.4.1.2])"),
            "derive a new unit from the base one instead of redeclaring it")
    else
        D = with_hint(error_at(dv_unit_local_shadows_import, Id ^ id_pos,
            "`" ++ Name ++ "` is declared here and imported from `" ++ Origin
                ++ "`; there is no precedence between the two"),
            "rename the local unit, or drop the import")
    ).

    % A file's own `service` declarations, keyed by the whole dotted path a
    % `call` writes.
    %
    %@helper
:- func local_services(list(ast_decl)) = map(string, ast_service_decl).

local_services(Decls) =
    list.foldl(add_local_service, Decls, map.init).

    %@helper
:- func add_local_service(ast_decl, map(string, ast_service_decl))
    = map(string, ast_service_decl).

add_local_service(Decl, Services) =
    ( if Decl = ad_service(Service) then
        map.set(Services, service_path(Service ^ asv_name), Service)
    else
        Services
    ).

    %@helper
:- func service_path(list(ident)) = string.

service_path(Path) = string.join_list(".", list.map(segment_name, Path)).

    %@helper
:- func segment_name(ident) = string.

segment_name(Id) = Id ^ id_name.

    % An imported schema or opaque type, under its binding.
    %
    %@helper
:- func imported_types(imports) = map(string, type_entry).

imported_types(Imports) =
    map.overlay(
        map.map_values_only(func(S) = te_schema(S), Imports ^ im_schemas),
        map.map_values_only(func(O) = te_opaque(O), Imports ^ im_opaques)).

    % A symbol has no storage of its own: a consumer resolves it to its
    % dimension before the lookup.
    %
    %@helper
:- func unit_storage(list(ast_unit)) = map(decl_ref, string).

unit_storage(Units) = list.foldl(add_unit_storage, Units, map.init).

    %@helper
:- func add_unit_storage(ast_unit, map(decl_ref, string))
    = map(decl_ref, string).

add_unit_storage(Unit, Map) =
    ( if Unit = au_dimension(Name, Storage, _, _, File) then
        map.set(Map, decl_ref(File, Name ^ id_name), Storage ^ id_name)
    else if Unit = au_scalar(Name, Storage, _, _, File) then
        map.set(Map, decl_ref(File, Name ^ id_name), Storage ^ id_name)
    else
        Map
    ).

    %@helper
:- func local_units(list(ast_decl)) = list(ast_unit).

local_units([]) = [].
local_units([D | Ds]) =
    ( if D = ad_unit(U) then [U | local_units(Ds)] else local_units(Ds) ).

    %@helper
:- func imported_type_decls(imports) = list(ast_decl).

imported_type_decls(Imports) =
    list.map(func(O) = ad_opaque(O), map.values(Imports ^ im_opaques))
        ++ imported_unit_decls(Imports).

    %@helper
:- func imported_unit_decls(imports) = list(ast_decl).

imported_unit_decls(Imports) =
    list.map(func(U) = ad_unit(U), Imports ^ im_units).

%-----------------------------------------------------------------------------%
% The type namespace -- [LGRA.22.7]
%-----------------------------------------------------------------------------%

    % One flat map: entries of any kind may not share a name.
    %
    %@spec [LGRA.22.7]
:- pred lgra_22_7_type_env(list(ast_decl)::in, map(string, type_entry)::out,
                           map(string, ident)::out, list(diagnostic)::out)
    is det.

lgra_22_7_type_env(Decls, Types, Aliases, Errors) :-
    list.foldl(seed_builtin, lgra_22_8_builtin_types, map.init, Seeded),
    list.foldl3(add_type_decl, Decls, Seeded, Types, map.init, Aliases,
        [], RevErrors),
    Errors = reverse(RevErrors).

    %@helper
:- pred seed_builtin(lgra_22_8_builtin_type::in, map(string, type_entry)::in,
                     map(string, type_entry)::out) is det.

seed_builtin(Builtin, !Types) :-
    map.set(lgra_22_8_type_name(Builtin), te_builtin(Builtin), !Types).

lgra_22_7_reserved_type(Name) :-
    lgra_22_8_named(Name, _).

    %@helper
:- pred add_type_decl(ast_decl::in,
                      map(string, type_entry)::in, map(string, type_entry)::out,
                      map(string, ident)::in, map(string, ident)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

add_type_decl(Decl, !Types, !Aliases, !Errors) :-
    (
        Decl = ad_schema(S),
        lgra_22_7_insert_type(S ^ as_name, te_schema(S), "schema", !Types, !Errors)
    ;
        Decl = ad_opaque(O),
        lgra_22_7_insert_type(O ^ aop_name, te_opaque(O), "opaque type", !Types,
            !Errors)
    ;
        Decl = ad_unit(U),
        add_unit_decl(U, !Types, !Aliases, !Errors)
    ;
        ( Decl = ad_rule(_)
        ; Decl = ad_const(_)
        ; Decl = ad_series(_)
        ; Decl = ad_service(_)
        ; Decl = ad_test(_)
        ; Decl = ad_initial(_)
        ; Decl = ad_import(_)
        )
    ).

    % A `unit fx_pair` and a `unit formula pair` declare no type: their names
    % are conversion names, never at a type position.
    %
    %@helper
:- pred add_unit_decl(ast_unit::in,
                      map(string, type_entry)::in, map(string, type_entry)::out,
                      map(string, ident)::in, map(string, ident)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

add_unit_decl(U, !Types, !Aliases, !Errors) :-
    (
        U = au_dimension(N, _, _, _, File),
        lgra_22_7_insert_type(N, te_unit(uk_dimension, decl_ref(File, N ^ id_name)),
            "unit dimension", !Types, !Errors)
    ;
        U = au_scalar(N, _, _, _, File),
        lgra_22_7_insert_type(N, te_unit(uk_scalar, decl_ref(File, N ^ id_name)),
            "unit scalar", !Types, !Errors)
    ;
        U = au_symbol(Sym, _, _, _, AliasNames, _, File, DimRef),
        lgra_22_7_insert_type(Sym,
            te_unit(uk_symbol(DimRef), decl_ref(File, Sym ^ id_name)), "unit",
            !Types, !Errors),
        list.foldl(add_unit_alias(Sym), AliasNames, !Aliases)
    ;
        ( U = au_formula(_, _, _, _)
        ; U = au_fx_pair(_, _, _, _, _, _, _, _)
        )
    ).

    % An alias is no type-namespace entry ([LUNI.7.5]), so it collides with
    % nothing.
    %
    %@helper
:- pred add_unit_alias(ident::in, ident::in,
                       map(string, ident)::in, map(string, ident)::out) is det.

add_unit_alias(Canonical, Alias, !Aliases) :-
    map.set(Alias ^ id_name, Canonical, !Aliases).

    %@spec [LGRA.22.7]
    %@spec [LLEX.9.7]
:- pred lgra_22_7_insert_type(ident::in, type_entry::in, string::in,
                    map(string, type_entry)::in, map(string, type_entry)::out,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_22_7_insert_type(Id, Entry, What, !Types, !Errors) :-
    Name = Id ^ id_name,
    Pos = Id ^ id_pos,
    ( if lgra_22_7_reserved_type(Name) then
        D = with_hint(error_at(dv_reserved_type_name, Pos,
            "`" ++ Name ++ "` is a reserved builtin type name and cannot be a "
                ++ What ++ " name: the scalar builtins, `Json`, the "
                ++ "temporal types and `Interval` are reserved in the type "
                ++ "namespace "
                ++ "([LGRA.22.7])"),
            "choose a different " ++ What ++ " name"),
        !:Errors = [D | !.Errors]
    else if map.search(!.Types, Name, Prior) then
        !:Errors = [duplicate_type(Name, Pos, What, Entry, Prior) | !.Errors]
    else
        map.det_insert(Name, Entry, !Types)
    ).

    %@helper
:- func duplicate_type(string, pos, string, type_entry, type_entry)
    = diagnostic.

duplicate_type(Name, Pos, What, Entry, Prior) = D :-
    ( if Entry = te_schema(_), Prior = te_schema(PriorSchema) then
        D = with_hint(error_with(dv_duplicate_schema, Pos,
            "a schema named `" ++ Name ++ "` is already declared in this file",
            PriorSchema ^ as_pos, "first declaration here"),
            "rename one of the two schemas")
    else if Entry = te_opaque(_), Prior = te_opaque(PriorOpaque) then
        D = with_hint(error_with(dv_duplicate_opaque_type, Pos,
            "an opaque type named `" ++ Name ++ "` is already declared",
            PriorOpaque ^ aop_pos, "first declaration here"),
            "rename one of the two opaque types")
    else if
        ( Entry = te_opaque(_), Prior = te_schema(_)
        ; Entry = te_schema(_), Prior = te_opaque(_)
        )
    then
        D = with_hint(error_at(dv_name_collision, Pos,
            "`" ++ Name ++ "` names both an opaque type and a schema; an "
                ++ "opaque type is nominal and distinct from every other type "
                ++ "([LOPQ.2.3])"),
            "rename one of the two")
    else
        D = with_hint(error_at(dv_duplicate_type_name, Pos,
            "`" ++ Name ++ "` names both a " ++ What ++ " and a "
                ++ describe_entry(Prior) ++ "; the type namespace is flat, so "
                ++ "two entries cannot share one NFC name ([LGRA.22.7])"),
            "rename the " ++ What ++ " `" ++ Name ++ "`")
    ).

    %@helper
:- func describe_entry(type_entry) = string.

describe_entry(te_builtin(_)) = "builtin type".
describe_entry(te_schema(_)) = "schema".
describe_entry(te_unit(uk_dimension, _)) = "unit dimension".
describe_entry(te_unit(uk_scalar, _)) = "unit scalar".
describe_entry(te_unit(uk_symbol(_), _)) = "unit".
describe_entry(te_opaque(_)) = "opaque type".

%-----------------------------------------------------------------------------%
% Constants -- the file-scope half of the value namespace
%-----------------------------------------------------------------------------%

    %@helper
:- pred resolve_consts(list(ast_decl)::in, map(string, ast_const)::out,
                       list(diagnostic)::out) is det.

resolve_consts(Decls, Consts, Errors) :-
    list.foldl2(add_const, Decls, map.init, Consts, [], RevErrors),
    Errors = reverse(RevErrors).

    %@helper
:- pred add_const(ast_decl::in, map(string, ast_const)::in,
                  map(string, ast_const)::out,
                  list(diagnostic)::in, list(diagnostic)::out) is det.

add_const(Decl, !Consts, !Errors) :-
    ( if Decl = ad_const(C) then
        Name = C ^ acn_name ^ id_name,
        ( if map.search(!.Consts, Name, Prior) then
            D = with_hint(error_with(dv_duplicate_constant,
                C ^ acn_name ^ id_pos,
                "a constant named `" ++ Name ++ "` is already declared",
                Prior ^ acn_pos, "first declaration here"),
                "rename one of the two constants"),
            !:Errors = [D | !.Errors]
        else
            map.det_insert(Name, C, !Consts)
        )
    else
        true
    ).

%-----------------------------------------------------------------------------%
% Dotted paths
%-----------------------------------------------------------------------------%

    %@helper
:- func dotted_name(list(ident)) = string.

dotted_name(Segments) =
    string.join_list(".", list.map((func(I) = I ^ id_name), Segments)).

%-----------------------------------------------------------------------------%
% Rule scope -- [LLET.12.4]
%-----------------------------------------------------------------------------%
%
% Only what declarations alone decide. [LLET.12.3] and [LGRA.8.6] are
% `dsc.validate`'s, and an unresolved name is `dsc.typecheck`'s: a bare `NAME`
% is not always a value-namespace name (`latest(Signal)` takes a schema).

    %@spec [LLET.12.4]
    %@spec [LLET.12.6]
:- pred llet_12_4_rule_scopes(map(string, type_entry)::in, list(ast_decl)::in,
                              map(string, ast_const)::in,
                              map(string, list(string))::in,
                              map(string, ast_schema)::in,
                              list(rule_scope)::out, list(diagnostic)::out)
    is det.

llet_12_4_rule_scopes(Types, Decls, Consts, Surface, QSchemas, Scopes,
        Errors) :-
    import_scope(Decls, Trusted, Quals0),
    Quals = qualified_scope(Quals0, Surface, QSchemas),
    list.foldl2(add_rule_scope(Types, Trusted, Quals, Consts), Decls,
        [], RevScopes, [], RevErrors),
    Scopes = reverse(RevScopes),
    Errors = reverse(RevErrors).

    % What a `lib.Schema` head is checked against: which qualifiers the file
    % imported, and, for each library that loaded, its surface and schemas.
    %
    %@helper
:- type qualified_scope
    --->    qualified_scope(
                qs_imported :: set(string),
                qs_surface  :: map(string, list(string)),
                qs_schemas  :: map(string, ast_schema)
            ).

    %@helper
:- pred add_rule_scope(map(string, type_entry)::in, set(string)::in,
                       qualified_scope::in, map(string, ast_const)::in,
                       ast_decl::in,
                       list(rule_scope)::in, list(rule_scope)::out,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

add_rule_scope(Types, Trusted, Quals, Consts, Decl, !Scopes, !Errors) :-
    ( if Decl = ad_rule(R) then
        list.foldl2(add_pattern_binding(Types, Trusted, Quals),
            lhs_bodies(R ^ ar_lhs), map.init, Bindings, !Errors),
        list.foldl2(lreg_4_6_add_capture(Bindings),
            list.condense(list.map(body_capture_names, lhs_bodies(R ^ ar_lhs))),
            map.init, Captures, !Errors),
        list.foldl2(llet_12_4_add_let(Consts, Bindings, Captures),
            rhs_let_names(R ^ ar_rhs), map.init, Lets, !Errors),
        !:Scopes = [rule_scope(R ^ ar_name, Bindings, Lets, Captures,
            let_annotations(R ^ ar_rhs), let_expressions(R ^ ar_rhs))
            | !.Scopes]
    else
        true
    ).

    %@helper
:- func let_expressions(ast_rule_rhs) = map(string, lgra_9_3_1_expr).

let_expressions(RHS) =
    list.foldl(add_let_expression,
        list.condense(list.map((func(D) = D ^ ald_bindings), RHS ^ arr_lets)),
        map.init).

    %@helper
:- func add_let_expression(ast_let_binding, map(string, lgra_9_3_1_expr))
    = map(string, lgra_9_3_1_expr).

add_let_expression(B, Exprs) =
    ( if B = alb_simple(Id, _, Rhs, _) then
        map.set(Exprs, Id ^ id_name, Rhs)
    else
        Exprs
    ).

    %@helper
:- func let_annotations(ast_rule_rhs) = map(string, ast_annotation).

let_annotations(RHS) =
    list.foldl(add_let_annotation,
        list.condense(list.map((func(D) = D ^ ald_bindings), RHS ^ arr_lets)),
        map.init).

    %@helper
:- func add_let_annotation(ast_let_binding, map(string, ast_annotation))
    = map(string, ast_annotation).

add_let_annotation(B, Anns) =
    ( if B = alb_simple(Id, yes(Ann), _, _) then
        map.set(Anns, Id ^ id_name, Ann)
    else
        Anns
    ).

    % Every pattern body in an LHS, in source order, negated ones included:
    % `no Motion m` still writes `m`.
    %
    %@helper
:- func lhs_bodies(list(ast_lhs_clause)) = list(ast_pattern_body).

lhs_bodies(Clauses) = list.condense(list.map(clause_bodies, Clauses)).

    %@helper
:- func clause_bodies(ast_lhs_clause) = list(ast_pattern_body).

clause_bodies(alc_pattern(P)) = pattern_bodies(P).
clause_bodies(alc_then(S)) = [S ^ ats_body].

    %@helper
:- func pattern_bodies(ast_pattern) = list(ast_pattern_body).

pattern_bodies(ap_simple(B)) = [B].
pattern_bodies(ap_negated(B, _)) = [B].
pattern_bodies(ap_sequence(_, Head, Steps, _)) =
    [Head | list.map((func(S) = S ^ ats_body), Steps)].

    %@helper
:- pred add_pattern_binding(map(string, type_entry)::in, set(string)::in,
                            qualified_scope::in, ast_pattern_body::in,
                            map(string, pattern_binding)::in,
                            map(string, pattern_binding)::out,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

add_pattern_binding(Types, Trusted, Quals, Body, !Bindings, !Errors) :-
    lgra_22_4_pattern_head(Types, Trusted, Quals, Body ^ apb_type, MaybeHead,
        !Errors),
    (
        Body ^ apb_binding = no
    ;
        Body ^ apb_binding = yes(Id),
        Name = Id ^ id_name,
        ( if lgra_22_7_builtin_fn(Name) then
            !:Errors = [lgra_22_7_reserved_value_name(Id, "binding") | !.Errors]
        else if map.search(!.Bindings, Name, Prior) then
            D = with_hint(error_with(dv_duplicate_binding, Id ^ id_pos,
                "`" ++ Name ++ "` is already bound by an earlier pattern in "
                    ++ "this rule",
                Prior ^ pb_name ^ id_pos, "first bound here"),
                "rename one of the two bindings"),
            !:Errors = [D | !.Errors]
        else
            (
                MaybeHead = yes(Head),
                map.det_insert(Name, pattern_binding(Id, Head), !Bindings)
            ;
                % The head already produced a diagnostic.
                MaybeHead = no
            )
        )
    ).

    %@spec [LGRA.22.4]
    %@spec [LIMP.4.3.2]
:- pred lgra_22_4_pattern_head(map(string, type_entry)::in, set(string)::in,
                       qualified_scope::in, ast_type_ref::in,
                       maybe(lgra_22_4_head_ref)::out,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_22_4_pattern_head(Types, Trusted, Quals, TypeRef, MaybeHead, !Errors) :-
    (
        TypeRef = atr_bare(Id),
        Name = Id ^ id_name,
        ( if map.search(Types, Name, te_schema(S)) then
            MaybeHead = yes(head_local(S))
        else if set.contains(Trusted, Name) then
            MaybeHead = yes(head_imported(Id))
        else if Name = "CallResponse" then
            % A file that declares `CallResponse` resolves, and `dsc.validate`
            % refuses it there.
            MaybeHead = no,
            D = with_hint(error_at(dv_call_response_retired, Id ^ id_pos,
                "`CallResponse` is retired: a call's response is a fact of "
                    ++ "the service's own response schema ([LCRS.4.3.3])"),
                "match the schema the service's `response T` line names, with "
                    ++ "`corr` equal to the call's correlation ([LCRS.5.5])"),
            !:Errors = [D | !.Errors]
        else
            MaybeHead = no,
            D = with_hint(error_at(dv_unknown_schema, Id ^ id_pos,
                "unknown schema `" ++ Name ++ "`"),
                "declare it in this file, or bring it into scope with "
                    ++ "`from <lib> import " ++ Name ++ "`"),
            !:Errors = [D | !.Errors]
        )
    ;
        TypeRef = atr_qualified(Path, Id),
        Qualifier = dotted_name(Path),
        ( if
            set.contains(Quals ^ qs_imported, Qualifier),
            limp_4_3_2_not_exported(Quals ^ qs_surface, Quals ^ qs_schemas,
                Path, Id)
        then
            MaybeHead = no,
            !:Errors = [limp_4_3_2_unknown_schema(Path, Id) | !.Errors]
        else if set.contains(Quals ^ qs_imported, Qualifier) then
            MaybeHead = yes(head_qualified(Path, Id))
        else
            MaybeHead = no,
            D = with_hint(error_at(dv_unknown_qualifier, Id ^ id_pos,
                "`" ++ Qualifier ++ "." ++ Id ^ id_name ++ "`: library `"
                    ++ Qualifier ++ "` is not in scope"),
                "add `import " ++ Qualifier ++ "` above the first declaration"),
            !:Errors = [D | !.Errors]
        )
    ).

limp_4_3_2_not_exported(Surface, Schemas, Path, Id) :-
    map.contains(Surface, dotted_name(Path)),
    not map.contains(Schemas, qualified_key(Path, Id)).

    %@spec [LIMP.4.3.2]
:- func limp_4_3_2_unknown_schema(list(ident), ident) = diagnostic.

limp_4_3_2_unknown_schema(Path, Id) =
    with_hint(error_at(dv_unknown_schema, Id ^ id_pos,
        "unknown schema `" ++ dotted_name(Path) ++ "." ++ Id ^ id_name
            ++ "`: library `"
            ++ dotted_name(Path) ++ "` exports no schema `" ++ Id ^ id_name
            ++ "`"),
        "a leading `_` keeps a name library-internal ([LIMP.4.3.1])").

lgra_22_4_schema_of(RF, atr_bare(Id), Schema) :-
    map.search(RF ^ rf_types, Id ^ id_name, te_schema(Schema)).
lgra_22_4_schema_of(RF, atr_qualified(Path, Id), Schema) :-
    map.search(RF ^ rf_qualified_schemas, qualified_key(Path, Id), Schema).

type_ref_name(atr_bare(Id)) = Id.
type_ref_name(atr_qualified(_, Id)) = Id.

type_ref_text(atr_bare(Id)) = Id ^ id_name.
type_ref_text(atr_qualified(Path, Id)) = qualified_key(Path, Id).

    % `lib;Schema`, the key `dsc.imports` files a library's schemas under.
    %
    %@helper
:- func qualified_key(list(ident), ident) = string.

qualified_key(Path, Id) = dotted_name(Path) ++ ";" ++ Id ^ id_name.

    %@helper
:- func body_capture_names(ast_pattern_body) = list(ident).

body_capture_names(Body) =
    ( if Body ^ apb_capture = yes(C) then C ^ acap_names else [] ).

    % A capture collides as a pattern binding does ([LREG.4.6]).
    %
    %@spec [LREG.4.1]
:- pred lreg_4_6_add_capture(map(string, pattern_binding)::in, ident::in,
                             map(string, ident)::in, map(string, ident)::out,
                             list(diagnostic)::in, list(diagnostic)::out) is det.

lreg_4_6_add_capture(Bindings, Id, !Captures, !Errors) :-
    Name = Id ^ id_name,
    ( if lgra_22_7_builtin_fn(Name) then
        !:Errors = [lgra_22_7_reserved_value_name(Id, "capture") | !.Errors]
    else if map.search(Bindings, Name, Prior) then
        !:Errors = [with_hint(error_with(dv_duplicate_binding, Id ^ id_pos,
            "`" ++ Name ++ "` is already bound by a pattern in this rule",
            Prior ^ pb_name ^ id_pos, "bound here"),
            "rename the capture") | !.Errors]
    else if map.search(!.Captures, Name, PriorCap) then
        !:Errors = [with_hint(error_with(dv_duplicate_binding, Id ^ id_pos,
            "`" ++ Name ++ "` is already bound by an earlier capture in this "
                ++ "rule",
            PriorCap ^ id_pos, "first bound here"),
            "rename one of the two captures") | !.Errors]
    else
        map.det_insert(Name, Id, !Captures)
    ).

    % The names a `from <lib> import …` brought into bare scope, and the
    % qualifiers an `import <lib>` bound.
    %
    %@helper
:- pred import_scope(list(ast_decl)::in, set(string)::out, set(string)::out)
    is det.

import_scope(Decls, Trusted, Quals) :-
    list.foldl2(add_import_scope, Decls, set.init, Trusted, set.init, Quals).

    %@helper
:- pred add_import_scope(ast_decl::in, set(string)::in, set(string)::out,
                         set(string)::in, set(string)::out) is det.

add_import_scope(Decl, !Trusted, !Quals) :-
    ( if Decl = ad_import(I) then
        (
            I ^ ai_form = aif_qualified(_, Binding),
            set.insert(Binding, !Quals)
        ;
            I ^ ai_form = aif_selective(Items),
            list.foldl(
                (pred(It::in, S0::in, S::out) is det :-
                    set.insert(It ^ aii_binding, S0, S)),
                Items, !Trusted)
        )
    else
        true
    ).

lgra_22_9_library_member(RF, Expr, Path, Member) :-
    Expr = ex_slot(Base, Member, _),
    slot_chain_names(Base, [], Path),
    import_scope(RF ^ rf_ast ^ af_decls, _, Quals),
    set.contains(Quals, dotted_name(Path)).

    % The names of a chain of slot accesses over one name, root first. Fails
    % for any other base: a call, an index or a literal is not a name.
    %
    %@helper
:- pred slot_chain_names(lgra_9_3_1_expr::in, list(ident)::in,
                         list(ident)::out) is semidet.

slot_chain_names(ex_name(Id), Acc, [Id | Acc]).
slot_chain_names(ex_slot(Base, Field, _), Acc, Path) :-
    slot_chain_names(Base, [Field | Acc], Path).

    % The file's own `const`s only: an imported one was declared where this
    % file's imports do not apply. An alias replaces its path: `import units.si
    % as si` frees `units`.
    %
    %@spec [LGRA.22.9]
:- func lgra_22_9_shadows(list(ast_decl)) = list(diagnostic).

lgra_22_9_shadows(Decls) = Errors :-
    import_scope(Decls, _, Quals),
    Segments = list.foldl(
        ( func(B, M) = map.set(M, first_segment(B), B) ),
        set.to_sorted_list(Quals), map.init),
    % A member is a constant or a builtin (step 2).
    Scope = limp_3_3_4_scope(Decls),
    Members = map.overlay(Scope ^ lcs_consts, Scope ^ lcs_members),
    Errors = list.filter_map(
        ( func({Id, What}) = D is semidet :-
            Name = Id ^ id_name,
            ( if map.search(Segments, Name, Library) then
                D = with_hint(error_at(dv_binding_shadows_library, Id ^ id_pos,
                    "the " ++ What ++ " `" ++ Name ++ "` has the name of "
                        ++ "the imported library `" ++ Library ++ "`'s first "
                        ++ "segment, so `" ++ Name ++ ".x` would have two "
                        ++ "readings ([LGRA.22.9])"),
                    "rename the " ++ What)
            else
                map.search(Members, Name, Row),
                D = with_hint(error_at(dv_binding_shadows_library, Id ^ id_pos,
                    "the " ++ What ++ " `" ++ Name ++ "` has the name of `"
                        ++ Row ++ "`, which this file imports bare, and a "
                        ++ "`math` or `distance` member is never rebound "
                        ++ "([LGRA.22.9])"),
                    "rename the " ++ What ++ ", or import the module whole "
                        ++ "and call `" ++ Row ++ "`")
            )
        ), list.condense(list.map(shadow_candidates, Decls))).

    % A library binding's first `.`-separated segment: the whole of a bare one
    % or an alias.
    %
    %@helper
:- func first_segment(string) = string.

first_segment(Binding) =
    ( if string.sub_string_search(Binding, ".", I) then
        string.left(Binding, I)
    else
        Binding
    ).

    % The names [LGRA.22.9] holds against the imports, each with what it is.
    %
    %@helper
:- func shadow_candidates(ast_decl) = list({ident, string}).

shadow_candidates(Decl) = Candidates :-
    ( if Decl = ad_const(C) then
        Candidates = [{C ^ acn_name, "constant"}]
    else if Decl = ad_rule(R) then
        Bodies = lhs_bodies(R ^ ar_lhs),
        Candidates = list.filter_map(
            ( func(B) = {Id, "pattern binding"} is semidet :-
                B ^ apb_binding = yes(Id)
            ), Bodies)
            ++ list.map(( func(Id) = {Id, "regex capture"} ),
                list.condense(list.map(body_capture_names, Bodies)))
            ++ list.map(( func(Id) = {Id, "`let` binding"} ),
                rhs_let_names(R ^ ar_rhs))
    else
        Candidates = []
    ).

    %@helper
:- func rhs_let_names(ast_rule_rhs) = list(ident).

rhs_let_names(RHS) =
    list.condense(list.map(let_decl_names, RHS ^ arr_lets)).

    %@helper
:- func let_decl_names(ast_let_decl) = list(ident).

let_decl_names(D) = list.condense(list.map(let_binding_names, D ^ ald_bindings)).

    %@helper
:- func let_binding_names(ast_let_binding) = list(ident).

let_binding_names(alb_simple(Id, _, _, _)) = [Id].
let_binding_names(alb_capture(Ids, _, _)) = Ids.

    %@spec [LLET.12.4]
    %@spec [LLET.10.2]
:- pred llet_12_4_add_let(map(string, ast_const)::in, map(string, pattern_binding)::in,
                        map(string, ident)::in, ident::in,
                        map(string, ident)::in, map(string, ident)::out,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

llet_12_4_add_let(Consts, Bindings, Captures, Id, !Lets, !Errors) :-
    Name = Id ^ id_name,
    Pos = Id ^ id_pos,
    ( if lgra_22_7_builtin_fn(Name) then
        !:Errors = [lgra_22_7_reserved_value_name(Id, "let binding") | !.Errors]
    else if map.search(Bindings, Name, PriorBinding) then
        D = with_hint(error_with(dv_let_shadows_binding, Pos,
            "`" ++ Name ++ "` is already a pattern binding in this rule; "
                ++ "`let` does not shadow ([LLET.12.4])",
            PriorBinding ^ pb_name ^ id_pos, "bound by this pattern"),
            "rename the `let` binding"),
        !:Errors = [D | !.Errors]
    else if map.search(Captures, Name, PriorCapture) then
        D = with_hint(error_with(dv_let_shadows_binding, Pos,
            "`" ++ Name ++ "` is already a regex capture in this rule; "
                ++ "`let` does not shadow ([LLET.12.4])",
            PriorCapture ^ id_pos, "captured here"),
            "rename the `let` binding"),
        !:Errors = [D | !.Errors]
    else if map.search(Consts, Name, PriorConst) then
        D = with_hint(error_with(dv_let_shadows_constant, Pos,
            "`" ++ Name ++ "` is already a constant; `let` does not shadow "
                ++ "([LLET.12.4])",
            PriorConst ^ acn_pos, "declared here"),
            "rename the `let` binding"),
        !:Errors = [D | !.Errors]
    else if map.search(!.Lets, Name, PriorLet) then
        D = with_hint(error_with(dv_duplicate_let, Pos,
            "`" ++ Name ++ "` is already bound by an earlier `let` in this "
                ++ "rule",
            PriorLet ^ id_pos, "first bound here"),
            "rename one of the two `let` bindings"),
        !:Errors = [D | !.Errors]
    else
        map.det_insert(Name, Id, !Lets)
    ).

    %@spec [LGRA.22.7]
    %@spec [LLEX.9.7]
:- func lgra_22_7_reserved_value_name(ident, string) = diagnostic.

lgra_22_7_reserved_value_name(Id, What) =
    with_hint(error_at(dv_reserved_builtin_name, Id ^ id_pos,
        "`" ++ Id ^ id_name ++ "` is a reserved builtin function name and "
            ++ "cannot be a " ++ What ++ " name: value-namespace resolution "
            ++ "ends at the builtins, so a declaration under one would shadow "
            ++ "it ([LGRA.22.7])"),
        "choose a different " ++ What ++ " name").

%-----------------------------------------------------------------------------%
% Identity -- [LFAC.1.7]
%-----------------------------------------------------------------------------%
%
% [LFAC.1.7.1], [LFAC.1.7.6] and [LFAC.1.7.7]. This records what was declared;
% [LFAC.1.7.4]'s require-all is a refusal, in `dsc.validate`.

    %@helper
:- func identity_env(list(ast_decl)) = map(string, identity).

identity_env(Decls) = list.foldl(add_identity, Decls, map.init).

    %@helper
:- func add_identity(ast_decl, map(string, identity)) = map(string, identity).

add_identity(Decl, Ids0) = Ids :-
    ( if Decl = ad_schema(S) then
        map.set(S ^ as_name ^ id_name, schema_identity(S), Ids0, Ids)
    else
        Ids = Ids0
    ).

    %@helper
:- func schema_identity(ast_schema) = identity.

schema_identity(S) = Identity :-
    Lifecycle = S ^ as_lifecycle,
    (
        Lifecycle = al_logical(_),
        Identity = id_keyed(list.filter_map(key_slot, S ^ as_fields))
    ;
        ( Lifecycle = al_explicit
        ; Lifecycle = al_activation
        ; Lifecycle = al_ttl(_, _)
        ),
        Identity = id_unkeyed
    ;
        % [LERR.9.2]'s `(node, rule)` is the engine's latching identity, not a
        % schema's.
        Lifecycle = al_internal,
        Identity = id_unkeyed
    ).

    %@helper
:- func key_slot(ast_field) = ident is semidet.

key_slot(F) = F ^ af_name :-
    has_key_marker(F ^ af_markers).

    %@helper
:- pred has_key_marker(list(ast_marker)::in) is semidet.

has_key_marker([M | Ms]) :-
    ( if M = am_key(_) then
        true
    else
        has_key_marker(Ms)
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.resolve.
%-----------------------------------------------------------------------------%

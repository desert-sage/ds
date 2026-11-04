% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.imports -- resolving an `import` to a library's declarations.
%
% Takes a name-to-source map, [LIMP.3.1.6]'s in-memory loader. Disk search is the
% command line's (`-L`).
%-----------------------------------------------------------------------------%

:- module dsc.imports.
:- interface.

:- import_module dsc.ast.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.token.

:- import_module list.
:- import_module map.
:- import_module pair.
:- import_module string.

%-----------------------------------------------------------------------------%

    %@helper
:- type library_sources == map(string, string).

    % What an import brought in, keyed by the name a reference writes.
    %
    %@helper
:- type imports
    --->    imports(
                im_consts   :: map(string, ast_const),
                im_schemas  :: map(string, ast_schema),
                im_opaques  :: map(string, ast_opaque),
                im_units    :: list(ast_unit),

                    % Where each unit name came from: "units.core" for the
                    % preload, or the library a selective import named. A unit's
                    % group members are not recorded.
                im_unit_origin :: map(string, string),

                    % Every service in the import closure, by its own dotted
                    % name ([LGRA.10.1.6]).
                im_services :: map(string, ast_service_decl),

                    % The library each imported service came from.
                im_service_origin :: map(string, string),

                    % The schema each imported service answers with.
                im_service_response :: map(string, string),

                    % The library each selectively imported schema came from.
                im_schema_origin :: map(string, string),

                    % The library each selectively imported constant came from.
                im_const_origin :: map(string, string),

                    % What `binding.NAME` may name, by binding.
                im_qualified_surface :: map(string, list(string)),

                    % Each whole-library import's schemas, keyed
                    % `binding;Schema`.
                im_qualified_schemas :: map(string, ast_schema),

                    % Each whole-library import's constants, keyed
                    % `binding;NAME`.
                im_qualified_consts :: map(string, ast_const),

                    % Every schema of every library this file imports, whatever
                    % it took: the libraries leaves first ([RDSC.4.7]), each one's
                    % schemas in source order.
                im_library_schemas :: list(pair(string, list(ast_schema))),

                    % The dimensions, scalar groups, unit symbols and opaque
                    % types each of those libraries declares ([LIMP.1.5]).
                im_library_types :: list(pair(string, list(ast_decl)))
            ).

    %@helper
:- func no_imports = imports.

    %@helper
:- pred load_libraries(library_sources::in, list(ast_decl)::in,
                        imports::out, list(diagnostic)::out) is det.

    % Every library one compilation can reach, each parsed once. The set is the
    % file's imports, the imports of each library that parses, and `units.core`;
    % a name outside it is parsed on demand.
    %
    %@helper
:- type library_env.

    %@helper
:- func library_env(library_sources, list(ast_decl)) = library_env.

    % `library_env` with the module names more than one distinct file resolved to,
    % and every candidate path ([LIMP.3.1.3]).
    %
    %@helper
:- func library_env_on_disk(library_sources, map(string, list(string)),
                            list(ast_decl)) = library_env.

    % `load_libraries` over trees already parsed.
    %
    %@helper
:- pred load_libraries_in(library_env::in, list(ast_decl)::in,
                          imports::out, list(diagnostic)::out) is det.

    % Fails if the library is absent or did not parse.
    %
    %@helper
:- pred library_tree(library_env::in, string::in, ast_file::out) is semidet.

    %@helper
:- pred parse_library(string::in, ast_file::out) is semidet.

    % `library_unparsed` carries which pass refused, the line and column in the
    % library, and what the pass said.
    %
    %@helper
:- type library_parse
    --->    library_parsed(ast_file)
    ;       library_unparsed(string).

    %@helper
:- func parse_library_why(string) = library_parse.

    %@helper
:- func library_name(list(ident)) = string.

    %@spec [LIMP.3.3.4]
:- pred limp_3_3_4_builtin_module(string::in) is semidet.

    % Each service's response schema, by the service's own dotted name: the
    % schema's own name, resolved in the declaring file's scope. A service with no
    % `response T` has no entry.
    %
    %@spec [LGRA.23.1]
:- func lgra_23_1_responses((func(string) = string), list(ast_decl))
    = map(string, string).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.build.
:- import_module dsc.builtins.
:- import_module dsc.libcall.
:- import_module dsc.cst.
:- import_module dsc.expr.
:- import_module dsc.layout.
:- import_module dsc.lex.
:- import_module dsc.parse.

:- import_module maybe.

%-----------------------------------------------------------------------------%

no_imports = imports(map.init, map.init, map.init, [], map.init, map.init,
    map.init, map.init, map.init, map.init, map.init, map.init, map.init, [],
    []).

limp_3_3_4_builtin_module("math").
limp_3_3_4_builtin_module("distance").
limp_3_3_4_builtin_module("calendar").

load_libraries(Sources, Decls, Imports, Diagnostics) :-
    load_libraries_in(library_env(Sources, Decls), Decls, Imports,
        Diagnostics).

load_libraries_in(Libs, Decls, Imports0, Diagnostics) :-
    list.foldl2(load_one(Libs), Decls, no_imports, Imports1,
        [], RevDiagnostics),
    list.foldl(limp_9_11_cycle(Libs), Decls, [], RevCycles),
    Diagnostics = list.reverse(RevDiagnostics) ++ list.reverse(RevCycles)
        ++ luni_4_1_2_core_unparsed(Libs),
    lgra_10_1_6_global_services(Libs, Imports1, Imports2),
    Imports3 = Imports2 ^ im_library_types := list.filter_map(
        ( func(Name - _) = Name - list.filter(limp_1_5_type_decl,
                Library ^ af_decls) is semidet :-
            library_tree(Libs, Name, Library)
        ), Imports2 ^ im_library_schemas),
    luni_4_1_2_preload_core(Libs, Imports3, Imports0).

    % From the closure, not the import lines. A later declaration of one name
    % replaces the earlier; `lcrs_14_9_duplicate_services` refuses the program.
    %
    %@spec [LGRA.10.1.6]
    %@spec [LADP.8.2.1]
    %@spec [LIMP.4.2.6]
:- pred lgra_10_1_6_global_services(library_env::in,
                                    imports::in, imports::out) is det.

lgra_10_1_6_global_services(Libs, !Imports) :-
    list.foldl(
        ( pred(Name - _::in, I0::in, I::out) is det :-
            ( if library_tree(Libs, Name, Library) then
                Services = list.filter_map(service_decl, Library ^ af_decls),
                I1 = list.foldl(
                    ( func(S, IA) = (IA
                        ^ im_services := map.set(IA ^ im_services,
                            service_own_name(S), S))
                        ^ im_service_origin := map.set(IA ^ im_service_origin,
                            service_own_name(S), Name) ),
                    Services, I0),
                I = I1 ^ im_service_response := map.overlay(
                    I1 ^ im_service_response,
                    lgra_23_1_responses(limp_13_1_own_in(Libs, [Name], Library),
                        Library ^ af_decls))
            else
                I = I0
            )
        ), !.Imports ^ im_library_schemas, !Imports).

    %@helper
:- func service_own_name(ast_service_decl) = string.

service_own_name(Service) =
    string.join_list(".", list.map(service_segment, Service ^ asv_name)).

lgra_23_1_responses(Own, Decls) =
    list.foldl(lgra_23_1_add_response(Own), Decls, map.init).

    %@helper
:- func lgra_23_1_add_response((func(string) = string), ast_decl,
                               map(string, string)) = map(string, string).

lgra_23_1_add_response(Own, Decl, Names) =
    ( if
        Decl = ad_service(Service),
        Service ^ asv_response = ar_schema(Id)
    then
        map.set(Names, service_own_name(Service), Own(Id ^ id_name))
    else
        Names
    ).

    % The own name of the schema a spelling names in a library's scope, followed
    % through a re-export. Any other spelling, a built-in's, is its own. `Chain`
    % stops at an import cycle.
    %
    %@spec [LIMP.13.1]
:- func limp_13_1_own_in(library_env, list(string), ast_file, string) = string.

limp_13_1_own_in(Libs, Chain, Library, Spelling) = Own :-
    Decls = Library ^ af_decls,
    ( if find_schema(Decls, Spelling, Schema) then
        Own = Schema ^ as_own
    else if limp_13_1_binding(Decls, Spelling, Dep, Name) then
        ( if
            not list.member(Dep, Chain),
            library_tree(Libs, Dep, DepLibrary)
        then
            Own = limp_13_1_own_in(Libs, [Dep | Chain], DepLibrary, Name)
        else
            Own = Name
        )
    else
        Own = Spelling
    ).

    % The library and the name a selective import binds to a spelling.
    %
    %@helper
:- pred limp_13_1_binding(list(ast_decl)::in, string::in, string::out,
                          string::out) is semidet.

limp_13_1_binding([Decl | Decls], Spelling, Dep, Name) :-
    ( if
        Decl = ad_import(Import),
        Import ^ ai_form = aif_selective(Items),
        list.find_first_match(
            ( pred(Item0::in) is semidet :- Item0 ^ aii_binding = Spelling ),
            Items, Item)
    then
        Dep = library_name(Import ^ ai_path),
        Name = Item ^ aii_name ^ id_name
    else
        limp_13_1_binding(Decls, Spelling, Dep, Name)
    ).

    % `units.core` present and unparsed is an error naming why; absent is silent.
    %
    %@spec [LUNI.4.1.2]
:- func luni_4_1_2_core_unparsed(library_env) = list(diagnostic).

luni_4_1_2_core_unparsed(Libs) = Diagnostics :-
    ( if
        library_lookup(Libs, "units.core") = lib_unparsed,
        map.search(Libs ^ le_sources, "units.core", Source),
        parse_library_why(Source) = library_unparsed(Why)
    then
        Diagnostics = [error_at(dv_library_parse_failed, pos(0, 0),
            "the implicit library `units.core` ([LUNI.4.1.2]) did not parse: "
                ++ Why ++ "; no base dimension or anchor is in scope")]
    else
        Diagnostics = []
    ).

%-----------------------------------------------------------------------------%
% The parsed libraries
%-----------------------------------------------------------------------------%

    %@helper
:- type library_env
    --->    lenv(
                le_sources :: library_sources,

                    % `no` for a source that did not parse.
                le_trees   :: map(string, maybe(ast_file)),

                le_ambiguous :: map(string, list(string))
            ).

library_env(Sources, Decls) = library_env_on_disk(Sources, map.init, Decls).

library_env_on_disk(Sources, Ambiguous, Decls) = Libs :-
    parse_reachable(Sources,
        ["units.core" | list.filter_map(import_name, Decls)],
        map.init, Trees),
    Parsed = lenv(Sources, Trees, Ambiguous),
    Libs = Parsed ^ le_trees := map.map_values(limp_1_5_tree(Parsed), Trees).

    % A slot typed by a schema takes the schema's own name; one typed by a unit or
    % an opaque type holds its declaration in `af_decl`. A dimension, scalar group,
    % unit symbol or opaque type is stamped with the library declaring it.
    %
    %@spec [LIMP.1.5]
    %@spec [LUNI.4.1.5]
    %@spec [LOPQ.2.3]
:- func limp_1_5_tree(library_env, string, maybe(ast_file)) = maybe(ast_file).

limp_1_5_tree(_, _, no) = no.
limp_1_5_tree(Libs, Name, yes(Ast)) =
    yes(Ast ^ af_decls :=
        list.map(limp_1_5_decl(Libs, Name, Ast), Ast ^ af_decls)).

    %@helper
:- func limp_1_5_decl(library_env, string, ast_file, ast_decl) = ast_decl.

limp_1_5_decl(Libs, Name, Ast, Decl) =
    ( if Decl = ad_schema(S) then
        ad_schema(S ^ as_fields :=
            list.map(limp_1_5_field(Libs, Name, Ast), S ^ as_fields))
    else if Decl = ad_opaque(O) then
        ad_opaque(O ^ aop_file := Name)
    else if Decl = ad_unit(U) then
        ad_unit(limp_1_5_unit(Libs, Name, Ast, U))
    else if Decl = ad_const(C) then
        ad_const(limp_1_5_const(Libs, Name, Ast, C))
    else if Decl = ad_service(V) then
        ad_service(V ^ asv_kwargs :=
            list.map(limp_1_5_kwarg(Libs, Name, Ast), V ^ asv_kwargs))
    else
        Decl
    ).

    %@helper
:- func limp_1_5_unit(library_env, string, ast_file, ast_unit) = ast_unit.

limp_1_5_unit(Libs, Name, Ast, U) =
    ( if U = au_dimension(N, Storage, Base, Pos, _) then
        au_dimension(N, Storage, Base, Pos, Name)
    else if U = au_scalar(N, Storage, Label, Pos, _) then
        au_scalar(N, Storage, Label, Pos, Name)
    else if U = au_symbol(Symbol, Dim, Body, Label, Aliases, Pos, _, _) then
        au_symbol(Symbol, Dim, Body, Label, Aliases, Pos, Name,
            limp_1_5_dimension_ref(Libs, Name, Ast, Dim ^ id_name))
    else
        U
    ).

    %@helper
:- func limp_1_5_dimension_ref(library_env, string, ast_file, string) = decl_ref.

limp_1_5_dimension_ref(Libs, Name, Ast, Dim) =
    ( if limp_1_5_declaring(Libs, [Name], Name, Ast, Dim, Path, Bare) then
        decl_ref(Path, Bare)
    else
        decl_ref("units.core", Dim)
    ).

    %@helper
:- func limp_1_5_field(library_env, string, ast_file, ast_field) = ast_field.

limp_1_5_field(Libs, Name, Ast, Field) =
    ( if
        limp_4_4_1_schema(Libs, [Name], Name, Ast, Field ^ af_type ^ id_name, _,
            Schema)
    then
        Field ^ af_type ^ id_name := Schema ^ as_own
    else if
        limp_1_5_declaring(Libs, [Name], Name, Ast, Field ^ af_type ^ id_name,
            Path, Bare),
        Path \= "units.core"
    then
        Field ^ af_decl := yes(decl_ref(Path, Bare))
    else
        Field
    ).

    % A schema takes its own name, which `ds_type` writes ([RDSC.6a.2.7]). A unit
    % or an opaque type keeps its spelling, with its declaration in `ask_units`.
    %
    %@spec [LIMP.1.5]
:- func limp_1_5_kwarg(library_env, string, ast_file, ast_service_kwarg)
    = ast_service_kwarg.

limp_1_5_kwarg(Libs, Name, Ast, Kwarg0) = Kwarg :-
    Spelled = Kwarg0 ^ ask_type ^ id_name,
    Suffixes = list.condense(list.map(limp_1_5_default_suffixes,
        Kwarg0 ^ ask_modifiers)),
    Kwarg1 = Kwarg0 ^ ask_units :=
        list.filter_map(limp_1_5_const_unit(Libs, Name, Ast),
            [Spelled | Suffixes]),
    ( if limp_4_4_1_schema(Libs, [Name], Name, Ast, Spelled, _, Schema) then
        Kwarg = Kwarg1 ^ ask_type ^ id_name := Schema ^ as_own
    else
        Kwarg = Kwarg1
    ).

    %@helper
:- func limp_1_5_default_suffixes(ast_kwarg_modifier) = list(string).

limp_1_5_default_suffixes(Modifier) =
    ( if Modifier = akm_default(E, _) then
        limp_1_5_expr_suffixes(E)
    else
        []
    ).

    % The unit literals in a constant's value, resolved in its declaring file.
    % `units.core`'s need no entry.
    %
    %@spec [LIMP.1.5]
:- func limp_1_5_const(library_env, string, ast_file, ast_const) = ast_const.

limp_1_5_const(Libs, Name, Ast, Const) = Const ^ acn_units :=
    list.filter_map(limp_1_5_const_unit(Libs, Name, Ast),
        limp_1_5_const_suffixes(Const ^ acn_form)).

    %@helper
:- func limp_1_5_const_unit(library_env, string, ast_file, string)
    = pair(string, decl_ref) is semidet.

limp_1_5_const_unit(Libs, Name, Ast, Suffix) = Suffix - decl_ref(Path, Bare) :-
    Symbol = limp_1_5_canonical_unit(
        Ast ^ af_decls ++ limp_1_5_group_decls(Libs, Ast), Suffix),
    limp_1_5_declaring(Libs, [Name], Name, Ast, Symbol, Path, Bare),
    Path \= "units.core".

    %@helper
:- func limp_1_5_group_decls(library_env, ast_file) = list(ast_decl).

limp_1_5_group_decls(Libs, Ast) =
    list.condense(list.filter_map(
        ( func(D) = GroupAst ^ af_decls is semidet :-
            D = ad_import(I),
            I ^ ai_form = aif_selective(_),
            library_tree(Libs, library_name(I ^ ai_path), GroupAst)
        ), Ast ^ af_decls)).

    %@helper
:- func limp_1_5_const_suffixes(ast_const_form) = list(string).

limp_1_5_const_suffixes(acf_value(no, E)) = limp_1_5_expr_suffixes(E).
limp_1_5_const_suffixes(acf_value(yes(Ann), E)) =
    [Ann ^ aan_type ^ id_name | limp_1_5_expr_suffixes(E)].
limp_1_5_const_suffixes(acf_colon_literal(E)) = limp_1_5_expr_suffixes(E).

    %@helper
:- func limp_1_5_expr_suffixes(lgra_9_3_1_expr) = list(string).

limp_1_5_expr_suffixes(E) =
    ( if E = ex_unit(_, Raw, _) then
        [( if string.remove_prefix("_", Raw, Rest) then Rest else Raw )]
    else if E = ex_unary(_, Inner, _) then
        limp_1_5_expr_suffixes(Inner)
    else if E = ex_binary(_, L, R, _) then
        limp_1_5_expr_suffixes(L) ++ limp_1_5_expr_suffixes(R)
    else
        []
    ).

    %@helper
:- func limp_1_5_canonical_unit(list(ast_decl), string) = string.

limp_1_5_canonical_unit([], Symbol) = Symbol.
limp_1_5_canonical_unit([D | Ds], Symbol) =
    ( if
        D = ad_unit(au_symbol(Id, _, _, _, Aliases, _, _, _)),
        list.find_first_match(
            ( pred(Alias::in) is semidet :- Alias ^ id_name = Symbol ),
            Aliases, _)
    then
        Id ^ id_name
    else
        limp_1_5_canonical_unit(Ds, Symbol)
    ).

    % The library declaring the unit or opaque type a spelling names in `Ast`, and
    % its `NAME` there. Fails for any other name, and at a library on `Chain`.
    %
    %@helper
:- pred limp_1_5_declaring(library_env::in, list(string)::in, string::in,
                           ast_file::in, string::in, string::out, string::out)
    is semidet.

limp_1_5_declaring(Libs, Chain, Path, Ast, Spelled, Declaring, Bare) :-
    Decls = Ast ^ af_decls,
    ( if list.find_first_match(limp_1_5_declares(Spelled), Decls, _) then
        Declaring = Path,
        Bare = Spelled
    else if limp_13_1_binding(Decls, Spelled, Dep, Name) then
        not list.member(Dep, Chain),
        library_tree(Libs, Dep, DepAst),
        limp_1_5_declaring(Libs, [Dep | Chain], Dep, DepAst, Name, Declaring, Bare)
    else
        Found = list.filter_map(
            ( func(D) = {DeclaredIn, Declared} is semidet :-
                D = ad_import(I),
                I ^ ai_form = aif_selective(Items),
                Group = library_name(I ^ ai_path),
                not list.member(Group, Chain),
                library_tree(Libs, Group, GroupAst),
                list.find_first_match(
                    ( pred(Item::in) is semidet :-
                        find_unit(GroupAst ^ af_decls,
                            Item ^ aii_name ^ id_name, _)
                    ), Items, _),
                limp_1_5_declaring(Libs, [Group | Chain], Group, GroupAst, Spelled,
                    DeclaredIn, Declared)
            ), Decls),
        Found = [{Declaring, Bare} | _]
    ).

    %@helper
:- pred limp_1_5_declares(string::in, ast_decl::in) is semidet.

limp_1_5_declares(Name, ad_opaque(O)) :-
    O ^ aop_name ^ id_name = Name.
limp_1_5_declares(Name, ad_unit(U)) :-
    limp_1_5_type_unit(U),
    unit_declared_name(U) = Name.

    %@helper
:- pred limp_1_5_type_decl(ast_decl::in) is semidet.

limp_1_5_type_decl(ad_opaque(_)).
limp_1_5_type_decl(ad_unit(U)) :-
    limp_1_5_type_unit(U).

    %@helper
:- pred limp_1_5_type_unit(ast_unit::in) is semidet.

limp_1_5_type_unit(au_dimension(_, _, _, _, _)).
limp_1_5_type_unit(au_scalar(_, _, _, _, _)).
limp_1_5_type_unit(au_symbol(_, _, _, _, _, _, _, _)).

    %@helper
:- pred parse_reachable(library_sources::in, list(string)::in,
                        map(string, maybe(ast_file))::in,
                        map(string, maybe(ast_file))::out) is det.

parse_reachable(_, [], !Trees).
parse_reachable(Sources, [Name | Names], !Trees) :-
    ( if map.contains(!.Trees, Name) then
        parse_reachable(Sources, Names, !Trees)
    else if map.search(Sources, Name, Source) then
        ( if parse_library(Source, Ast0) then
            Ast = limp_13_1_own_names(Name, Ast0),
            map.det_insert(Name, yes(Ast), !Trees),
            parse_reachable(Sources, Names ++ library_imports(Ast), !Trees)
        else
            map.det_insert(Name, no, !Trees),
            parse_reachable(Sources, Names, !Trees)
        )
    else
        parse_reachable(Sources, Names, !Trees)
    ).

    %@helper
:- type library_lookup
    --->    lib_absent
    ;       lib_unparsed
    ;       lib_parsed(ast_file).

    %@helper
:- func library_lookup(library_env, string) = library_lookup.

library_lookup(Libs, Name) = Lookup :-
    ( if map.search(Libs ^ le_trees, Name, Tree) then
        (
            Tree = yes(Ast),
            Lookup = lib_parsed(Ast)
        ;
            Tree = no,
            Lookup = lib_unparsed
        )
    else if map.search(Libs ^ le_sources, Name, Source) then
        ( if parse_library(Source, Ast) then
            Lookup = lib_parsed(limp_13_1_own_names(Name, Ast))
        else
            Lookup = lib_unparsed
        )
    else
        Lookup = lib_absent
    ).

    % `Path` is the dotted import path a library is keyed by, never an alias.
    %
    %@spec [LIMP.13.1]
:- func limp_13_1_own_names(string, ast_file) = ast_file.

limp_13_1_own_names(Path, Ast) =
    Ast ^ af_decls := list.map(limp_13_1_own_name(Path), Ast ^ af_decls).

    %@helper
:- func limp_13_1_own_name(string, ast_decl) = ast_decl.

limp_13_1_own_name(Path, Decl) =
    ( if Decl = ad_schema(S) then
        ad_schema(S ^ as_own := Path ++ "." ++ S ^ as_name ^ id_name)
    else
        Decl
    ).

library_tree(Libs, Name, Ast) :-
    library_lookup(Libs, Name) = lib_parsed(Ast).

%-----------------------------------------------------------------------------%
% Import cycles -- [LIMP.9.11]
%-----------------------------------------------------------------------------%

    %@spec [LIMP.9.11]
:- pred limp_9_11_cycle(library_env::in, ast_decl::in,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

limp_9_11_cycle(Libs, Decl, !Diagnostics) :-
    ( if
        Decl = ad_import(Import),
        Name = library_name(Import ^ ai_path),
        cycle_from(Libs, Name, [], Path)
    then
        !:Diagnostics = [with_hint(error_at(dv_import_cycle, Import ^ ai_pos,
            "import cycle: " ++ string.join_list(" -> ", Path)
                ++ " ([LIMP.9.11])"),
            "a library may not import itself, directly or through another")
            | !.Diagnostics]
    else
        true
    ).

    % The cycle reachable from this library. `Seen` is ordered: the diagnostic is
    % the path.
    %
    %@helper
:- pred cycle_from(library_env::in, string::in, list(string)::in,
                   list(string)::out) is semidet.

cycle_from(Libs, Name, Seen, Path) :-
    ( if list.member(Name, Seen) then
        Path = cycle_tail(Name, list.reverse(Seen)) ++ [Name]
    else
        library_tree(Libs, Name, Library),
        first_cycle(Libs, library_imports(Library), [Name | Seen], Path)
    ).

    % The first edge that closes, in source order: one cycle per import line.
    %
    %@helper
:- pred first_cycle(library_env::in, list(string)::in, list(string)::in,
                    list(string)::out) is semidet.

first_cycle(Libs, [Edge | Edges], Seen, Path) :-
    ( if cycle_from(Libs, Edge, Seen, Found) then
        Path = Found
    else
        first_cycle(Libs, Edges, Seen, Path)
    ).

    %@helper
:- func library_imports(ast_file) = list(string).

library_imports(Library) = list.filter_map(import_name, Library ^ af_decls).

    %@helper
:- func import_name(ast_decl) = string is semidet.

import_name(ad_import(Import)) = library_name(Import ^ ai_path).

    %@helper
:- func cycle_tail(string, list(string)) = list(string).

cycle_tail(_, []) = [].
cycle_tail(Name, [S | Ss]) =
    ( if S = Name then [S | Ss] else cycle_tail(Name, Ss) ).

%-----------------------------------------------------------------------------%
% The baked base -- [LUNI.4.1.2]
%-----------------------------------------------------------------------------%
%
% On the command line this always finds `units.core`: `dsc.cli.run` refuses first
% without it. The guard is for an in-process caller that supplies its own libraries.

    %@spec [LUNI.4.1.2]
:- pred luni_4_1_2_preload_core(library_env::in,
                                 imports::in, imports::out) is det.

luni_4_1_2_preload_core(Libs, !Imports) :-
    ( if library_tree(Libs, "units.core", Core) then
        list.foldl(preload_unit, Core ^ af_decls, !Imports)
    else
        true
    ).

    %@helper
:- pred preload_unit(ast_decl::in, imports::in, imports::out) is det.

preload_unit(Decl, !Imports) :-
    ( if
        Decl = ad_unit(Unit),
        Name = unit_declared_name(Unit),
        not limp_7_1_underscore(Name)
    then
        !Imports ^ im_units := !.Imports ^ im_units ++ [Unit],
        !Imports ^ im_unit_origin :=
            map.set(!.Imports ^ im_unit_origin, Name, "units.core")
    else
        true
    ).

    %@helper
:- pred load_one(library_env::in, ast_decl::in, imports::in, imports::out,
                 list(diagnostic)::in, list(diagnostic)::out) is det.

load_one(Libs, Decl, !Imports, !Diagnostics) :-
    ( if Decl = ad_import(Import) then
        Name = library_name(Import ^ ai_path),
        Pos = Import ^ ai_pos,
        Lookup = library_lookup(Libs, Name),
        ( if map.search(Libs ^ le_ambiguous, Name, Candidates) then
            limp_3_1_3_ambiguous(Name, Candidates, Pos, !Diagnostics)
        else
        (
            Lookup = lib_parsed(Library),
            !Imports ^ im_library_schemas := library_modules(Libs, [],
                Name, Library, !.Imports ^ im_library_schemas),
            limp_7_1_take(Libs, Library, Import, Name,
                library_unit_group(Libs, [Name], Library), !Imports,
                !Diagnostics)
        ;
            Lookup = lib_unparsed,
            % Parsed again for the reason, on this path only.
            ( if
                map.search(Libs ^ le_sources, Name, Source),
                parse_library_why(Source) = library_unparsed(Why)
            then
                Reason = ": " ++ Why
            else
                Reason = ""
            ),
            !:Diagnostics = [error_at(dv_library_parse_failed, Pos,
                "library `" ++ Name ++ "` did not parse" ++ Reason)
                | !.Diagnostics]
        ;
            Lookup = lib_absent,
            % No search path is available here, so the hint names what was
            % loadable ([LIMP.3.1.2]).
            !:Diagnostics = [with_hint(error_at(dv_unknown_library, Pos,
                "library `" ++ Name ++ "` not found ([LIMP.3.1.2])"),
                available(Libs ^ le_sources)) | !.Diagnostics]
        )
        )
    else
        true
    ).

    % Fires at the import, not at the search path. The caller decides which files
    % are distinct.
    %
    %@spec [LIMP.3.1.3]
:- pred limp_3_1_3_ambiguous(string::in, list(string)::in, pos::in,
                             list(diagnostic)::in, list(diagnostic)::out)
    is det.

limp_3_1_3_ambiguous(Name, Candidates, Pos, !Diagnostics) :-
    !:Diagnostics = [with_hint(error_at(dv_ambiguous_library, Pos,
        "library `" ++ Name ++ "` resolves to more than one file: "
            ++ string.join_list(", ", Candidates) ++ " ([LIMP.3.1.3])"),
        "remove all but one from the search path, or rename one")
        | !.Diagnostics].

    % Leaves first ([RDSC.4.7]). A library on the current chain is skipped: that
    % is a cycle.
    %
    %@helper
:- func library_modules(library_env, list(string), string, ast_file,
                        list(pair(string, list(ast_schema))))
    = list(pair(string, list(ast_schema))).

library_modules(Libs, Chain, Name, Library, Acc0) = Acc :-
    ( if
        ( list.member(Name - _, Acc0)
        ; list.member(Name, Chain)
        )
    then
        Acc = Acc0
    else
        Deps = list.filter_map(
            ( func(D) = library_name(I ^ ai_path) is semidet :-
                D = ad_import(I)
            ), Library ^ af_decls),
        list.foldl(
            ( pred(Dep::in, A0::in, A::out) is det :-
                ( if library_tree(Libs, Dep, DepLibrary) then
                    A = library_modules(Libs, [Name | Chain], Dep,
                        DepLibrary, A0)
                else
                    A = A0
                )
            ), Deps, Acc0, Acc1),
        ( if list.member(Name - _, Acc1) then
            Acc = Acc1
        else
            Acc = Acc1 ++
                [Name - list.filter_map(schema_of_decl, Library ^ af_decls)]
        )
    ).

library_name(Path) = string.join_list(".", list.map(name_of, Path)).

    %@helper
:- func name_of(ident) = string.

name_of(Id) = Id ^ id_name.

    %@helper
:- func available(library_sources) = string.

available(Sources) = Text :-
    Keys = map.keys(Sources),
    (
        Keys = [],
        Text = "no libraries were supplied to this compilation"
    ;
        Keys = [_ | _],
        Text = "libraries available: " ++ string.join_list(", ", Keys)
    ).

%-----------------------------------------------------------------------------%
% Parsing a library
%-----------------------------------------------------------------------------%

parse_library(Source, Ast) :-
    parse_library_why(Source) = library_parsed(Ast).

parse_library_why(Source) = Result :-
    llex_5_4_lex(Source, Lexed),
    (
        Lexed = lex_error(LexErr, LexPos),
        Result = library_unparsed(library_where(LexPos) ++ "lex: "
            ++ describe_lex_error(LexErr))
    ;
        Lexed = lex_ok(Lines),
        llex_6_2_layout(Lines, Laid),
        (
            Laid = lay_error(LayErr, LayPos),
            Result = library_unparsed(library_where(LayPos) ++ "layout: "
                ++ string.string(LayErr))
        ;
            Laid = lay_ok(Tokens),
            lgra_3_1_parse(Tokens, Parsed),
            (
                Parsed = parse_error(ParseErr, ParsePos),
                Result = library_unparsed(library_where(ParsePos) ++ "parse: "
                    ++ describe_parse_error(ParseErr))
            ;
                Parsed = parse_ok(Cst),
                build_file(Cst, Ast),
                Result = library_parsed(limp_3_3_4_rewrite_file(Ast))
            )
        )
    ).

    %@helper
:- func library_where(pos) = string.

library_where(pos(Line, Col)) =
    string.format("its line %d, column %d: ", [i(Line), i(Col)]).

%-----------------------------------------------------------------------------%
% Projecting the surface -- [LIMP.7]
%-----------------------------------------------------------------------------%

    % A rule is not taken here: `dsc.driver`'s `limp_7_5_library_rules` compiles
    % every rule of the import DAG, whichever form the import took.
    %
    %@spec [LIMP.9.8]
    %@spec [LIMP.7.1]
    %@spec [LIMP.2.1.2]
    %@spec [LIMP.7.3]
:- pred limp_7_1_take(library_env::in, ast_file::in, ast_import::in, string::in,
                      list(ast_unit)::in, imports::in, imports::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

limp_7_1_take(Libs, Library, Import, LibName, Group, !Imports, !Diagnostics) :-
    Form = Import ^ ai_form,
    (
        % No service is taken: a service is not reached through a library
        % ([LIMP.4.1.1]).
        Form = aif_qualified(_, QualifiedBinding),
        !Imports ^ im_qualified_surface := map.set(
            !.Imports ^ im_qualified_surface, QualifiedBinding,
            list.filter((pred(N::in) is semidet :- not limp_7_1_underscore(N)),
                list.condense(list.map(surface_names, Library ^ af_decls)))),
        !Imports ^ im_qualified_schemas := list.foldl(
            (func(S, M) = map.set(M,
                QualifiedBinding ++ ";" ++ S ^ as_name ^ id_name, S)),
            list.filter_map(schema_of_decl, Library ^ af_decls),
            limp_4_4_1_qualified(Libs, LibName, Library, QualifiedBinding,
                !.Imports ^ im_qualified_schemas)),
        !Imports ^ im_qualified_consts := list.foldl(
            (func(C, M) = map.set(M,
                QualifiedBinding ++ ";" ++ C ^ acn_name ^ id_name, C)),
            list.filter(
                (pred(C::in) is semidet :-
                    not limp_7_1_underscore(C ^ acn_name ^ id_name)),
                list.filter_map(const_of_decl, Library ^ af_decls)),
            !.Imports ^ im_qualified_consts)
    ;
        Form = aif_selective(Items),
        list.foldl2(limp_7_7_take_item(Libs, Library, LibName, Group), Items,
            !Imports, !Diagnostics)
    ).

    % The schema a name on a library's surface reaches, followed to its
    % declaration, and the library declaring it. Fails for any other name, and at
    % a name on `Chain`.
    %
    %@spec [LIMP.4.4.1]
:- pred limp_4_4_1_schema(library_env::in, list(string)::in, string::in,
                          ast_file::in, string::in, string::out,
                          ast_schema::out) is semidet.

limp_4_4_1_schema(Libs, Chain, LibName, Library, Spelling, Origin, Schema) :-
    Decls = Library ^ af_decls,
    ( if find_schema(Decls, Spelling, Declared) then
        Origin = LibName,
        Schema = Declared
    else
        limp_13_1_binding(Decls, Spelling, Dep, Name),
        not list.member(Dep, Chain),
        library_tree(Libs, Dep, DepLibrary),
        limp_4_4_1_schema(Libs, [Dep | Chain], Dep, DepLibrary, Name, Origin,
            Schema)
    ).

    % What a library re-exports, under `binding;NAME`.
    %
    %@spec [LIMP.4.4.1]
:- func limp_4_4_1_qualified(library_env, string, ast_file, string,
                             map(string, ast_schema)) = map(string, ast_schema).

limp_4_4_1_qualified(Libs, LibName, Library, QualifiedBinding, Schemas0) =
    list.foldl(
        ( func(Spelling, M) =
            ( if
                not limp_7_1_underscore(Spelling),
                limp_4_4_1_schema(Libs, [LibName], LibName, Library, Spelling,
                    _, S)
            then
                map.set(M, QualifiedBinding ++ ";" ++ Spelling, S)
            else
                M
            )
        ),
        limp_4_4_1_bindings(Library ^ af_decls), Schemas0).

    %@helper
:- func limp_4_4_1_bindings(list(ast_decl)) = list(string).

limp_4_4_1_bindings(Decls) = list.condense(list.filter_map(
    ( func(D) = list.map((func(Item) = Item ^ aii_binding), Items) is semidet :-
        D = ad_import(I),
        I ^ ai_form = aif_selective(Items)
    ), Decls)).

    %@spec [LIMP.7.7]
    %@spec [LIMP.7.2]
    %@spec [LIMP.7.4]
    %@spec [LIMP.2.1.7]
    %@spec [LIMP.2.1.3]
    %@spec [LGRA.22.5]
    %@spec [LGRA.4.6]
:- pred limp_7_7_take_item(library_env::in, ast_file::in, string::in,
                           list(ast_unit)::in,
                           ast_import_item::in, imports::in, imports::out,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

limp_7_7_take_item(Libs, Library, LibName, Group, Item, !Imports,
        !Diagnostics) :-
    Wanted = Item ^ aii_name ^ id_name,
    Binding = Item ^ aii_binding,
    Decls = Library ^ af_decls,
    ( if limp_7_1_underscore(Wanted) then
        !:Diagnostics = [with_hint(error_at(dv_unknown_import_name,
            Item ^ aii_pos,
            "`" ++ Wanted ++ "` is not part of `" ++ LibName ++ "`'s "
                ++ "importable surface ([LIMP.7.1])"),
            "a leading `_` marks a declaration library-internal")
            | !.Diagnostics]
    else if find_const(Decls, Wanted, Const) then
        % Distinct by library: one library imported twice is no collision.
        ( if
            map.search(!.Imports ^ im_const_origin, Binding, Prior),
            Prior \= LibName
        then
            !:Diagnostics = [with_hint(error_at(dv_import_name_collision,
                Item ^ aii_pos,
                "a constant named `" ++ Binding ++ "` is already imported "
                    ++ "from `" ++ Prior ++ "`, and `" ++ LibName
                    ++ "` declares another ([LGRA.4.6])"),
                "rename one with `as`: `from " ++ LibName ++ " import "
                    ++ Wanted ++ " as <other>`") | !.Diagnostics]
        else
            true
        ),
        !Imports ^ im_const_origin :=
            map.set(!.Imports ^ im_const_origin, Binding, LibName),
        !Imports ^ im_consts := map.set(!.Imports ^ im_consts, Binding, Const)
    else if
        limp_3_3_4_builtin_module(LibName),
        Row = LibName ++ "." ++ Wanted,
        lgra_22_7_builtin_fn(Row)
    then
        % It binds nothing here: `dsc.libcall` rewrites the file's calls.
        true
    else if
        limp_4_4_1_schema(Libs, [LibName], LibName, Library, Wanted, Origin,
            Schema)
    then
        % Distinct by declaring library, not by text.
        ( if
            map.search(!.Imports ^ im_schema_origin, Binding, Prior),
            Prior \= Origin
        then
            !:Diagnostics = [with_hint(error_at(dv_import_name_collision,
                Item ^ aii_pos,
                "a schema named `" ++ Binding ++ "` is already imported from `"
                    ++ Prior ++ "`, and `" ++ Origin ++ "` declares another "
                    ++ "([LIMP.2.1.7])"),
                "rename one with `as`: `from " ++ LibName ++ " import "
                    ++ Wanted ++ " as <other>`") | !.Diagnostics]
        else
            true
        ),
        !Imports ^ im_schema_origin :=
            map.set(!.Imports ^ im_schema_origin, Binding, Origin),
        !Imports ^ im_schemas :=
            map.set(!.Imports ^ im_schemas, Binding, Schema)
    else if find_opaque(Decls, Wanted, Opaque) then
        !Imports ^ im_opaques :=
            map.set(!.Imports ^ im_opaques, Binding, Opaque)
    else if find_unit(Decls, Wanted, Unit) then
        % A unit is taken with its group, under its own names, so it takes no
        % `as` ([LIMP.2.1.7]). Two libraries naming one unit is a collision; the
        % preload does not count.
        ( if Binding \= Wanted then
            !:Diagnostics = [with_hint(error_at(dv_unit_import_alias,
                Item ^ aii_pos,
                "`" ++ Wanted ++ "` is a unit declaration of `" ++ LibName
                    ++ "`, and an import of one takes no `as` ([LIMP.2.1.7])"),
                "write `from " ++ LibName ++ " import " ++ Wanted ++ "`")
                | !.Diagnostics]
        else
            true
        ),
        ( if
            map.search(!.Imports ^ im_unit_origin, Wanted, Prior),
            Prior \= LibName,
            Prior \= "units.core"
        then
            !:Diagnostics = [with_hint(error_at(dv_unit_import_collision,
                Item ^ aii_pos,
                "unit `" ++ Wanted ++ "` is imported from both `" ++ Prior
                    ++ "` and `" ++ LibName ++ "`"),
                "import it from one library only") | !.Diagnostics]
        else
            true
        ),
        !Imports ^ im_unit_origin :=
            map.set(!.Imports ^ im_unit_origin, Wanted, LibName),
        !Imports ^ im_units := !.Imports ^ im_units ++ [Unit] ++ Group
    else if find_services(Decls, Wanted, _) then
        % It binds nothing: a service is callable under its own name
        % ([LGRA.10.1.6]).
        true
    else if declares(Decls, Wanted) then
        % Declared, of a kind not projected: the name is untyped downstream.
        true
    else if formula_of_function(Decls, Wanted, FormulaName) then
        !:Diagnostics = [with_hint(error_at(dv_unknown_import_name,
            Item ^ aii_pos,
            "`" ++ Wanted ++ "` is a function of `unit formula " ++ FormulaName
                ++ "` in `" ++ LibName ++ "`, and a formula is imported by its "
                ++ "formula name ([LIMP.7.7])"),
            "`from " ++ LibName ++ " import " ++ FormulaName ++ "` brings both "
                ++ "of its functions")
            | !.Diagnostics]
    else
        !:Diagnostics = [with_hint(error_at(dv_unknown_import_name,
            Item ^ aii_pos,
            "`" ++ Wanted ++ "` is not declared at the top level of `"
                ++ LibName ++ "` ([LIMP.7.7])"),
            "the lookup tables consulted: schema / const / rule / domain / "
                ++ "flat-service / unit / unit formula")
            | !.Diagnostics]
    ).

    %@helper
:- pred formula_of_function(list(ast_decl)::in, string::in, string::out)
    is semidet.

formula_of_function(Decls, Name, FormulaName) :-
    list.find_first_match(
        ( pred(D::in) is semidet :-
            D = ad_unit(au_formula(_, _, Lines, _)),
            list.find_first_match(
                ( pred(L::in) is semidet :- L ^ afl_name ^ id_name = Name ),
                Lines, _)
        ), Decls, Found),
    Found = ad_unit(au_formula(Formula, _, _, _)),
    FormulaName = Formula ^ id_name.

    %@spec [LIMP.9.9]
    %@spec [LIMP.7.1]
    %@spec [LIMP.4.3.1]
    %@spec [LIMP.4.3.3]
:- pred limp_7_1_underscore(string::in) is semidet.

limp_7_1_underscore(Name) :-
    string.prefix(Name, "_").

    % Every top-level name one declaration contributes to a qualified binding's
    % surface: `declared_name`'s twin.
    %
    %@helper
:- func surface_names(ast_decl) = list(string).

surface_names(ad_schema(S)) = [S ^ as_name ^ id_name].
surface_names(ad_rule(R)) = [R ^ ar_name ^ id_name].
surface_names(ad_const(C)) = [C ^ acn_name ^ id_name].
surface_names(ad_opaque(O)) = [O ^ aop_name ^ id_name].
surface_names(ad_test(_)) = [].
surface_names(ad_series(_)) = [].
surface_names(ad_initial(_)) = [].
surface_names(ad_unit(U)) = [unit_declared_name(U)].
surface_names(ad_service(V)) = Names :-
    Path = list.map((func(I) = I ^ id_name), V ^ asv_name),
    ( if Path = [Head | _] then
        Names = [Head, string.join_list(".", Path)]
    else
        Names = []
    ).
surface_names(ad_import(I)) = Names :-
    (
        I ^ ai_form = aif_qualified(_, Binding),
        Names = [Binding]
    ;
        I ^ ai_form = aif_selective(Items),
        Names = list.map((func(It) = It ^ aii_binding), Items)
    ).

    % [LIMP.7.7]'s test, over every declaration kind that has a name.
    %
    %@helper
:- pred declares(list(ast_decl)::in, string::in) is semidet.

declares([D | Ds], Name) :-
    ( if declared_name(D, Name) then true else declares(Ds, Name) ).

    %@helper
:- pred declared_name(ast_decl::in, string::in) is semidet.

declared_name(ad_schema(S), Name) :- S ^ as_name ^ id_name = Name.
declared_name(ad_rule(R), Name) :- R ^ ar_name ^ id_name = Name.
declared_name(ad_const(C), Name) :- C ^ acn_name ^ id_name = Name.
declared_name(ad_opaque(O), Name) :- O ^ aop_name ^ id_name = Name.
declared_name(ad_service(V), Name) :- service_surface(V ^ asv_name, Name).
declared_name(ad_unit(U), Name) :- unit_declared_name(U) = Name.

    % A library re-exports what it imports. Only a schema's chain is followed
    % (`limp_4_4_1_schema`); any other kind's name resolves and is untyped.
declared_name(ad_import(I), Name) :- import_binding(I ^ ai_form, Name).

    %@helper
:- pred import_binding(ast_import_form::in, string::in) is semidet.

import_binding(aif_qualified(_, Binding), Name) :- Binding = Name.
import_binding(aif_selective(Items), Name) :-
    item_binding(Items, Name).

    %@helper
:- pred item_binding(list(ast_import_item)::in, string::in) is semidet.

item_binding([Item | Items], Name) :-
    ( if Item ^ aii_binding = Name then
        true
    else
        item_binding(Items, Name)
    ).

    % Every service a library offers under one importable name. A dotted service
    % is imported by its domain, not its leaf.
    %
    %@helper
:- pred find_services(list(ast_decl)::in, string::in,
                      list(ast_service_decl)::out) is semidet.

find_services(Decls, Wanted, Services) :-
    Services = list.filter_map(service_offered_as(Wanted), Decls),
    Services = [_ | _].

    %@helper
:- func service_offered_as(string, ast_decl) = ast_service_decl is semidet.

service_offered_as(Wanted, ad_service(Service)) = Service :-
    service_surface(Service ^ asv_name, Wanted).

    %@helper
:- func schema_of_decl(ast_decl) = ast_schema is semidet.

schema_of_decl(ad_schema(Schema)) = Schema.

    %@helper
:- func const_of_decl(ast_decl) = ast_const is semidet.

const_of_decl(ad_const(Const)) = Const.

    %@helper
:- func service_decl(ast_decl) = ast_service_decl is semidet.

service_decl(ad_service(Service)) = Service.

    %@helper
:- func service_segment(ident) = string.

service_segment(Id) = Id ^ id_name.

    %@helper
:- pred service_surface(list(ident)::in, string::out) is semidet.

service_surface([Id | Ids], Name) :-
    (
        % Flat: `service hydrate:` is imported as `hydrate`.
        Ids = [],
        Name = Id ^ id_name
    ;
        % Dotted: `service light.turn_on:` is imported as `light`.
        Ids = [_ | _],
        Name = Id ^ id_name
    ).

    %@helper
:- func unit_declared_name(ast_unit) = string.

unit_declared_name(au_dimension(Id, _, _, _, _)) = Id ^ id_name.
unit_declared_name(au_scalar(Id, _, _, _, _)) = Id ^ id_name.
unit_declared_name(au_symbol(Id, _, _, _, _, _, _, _)) = Id ^ id_name.
unit_declared_name(au_formula(Id, _, _, _)) = Id ^ id_name.
unit_declared_name(au_fx_pair(Id, _, _, _, _, _, _, _)) = Id ^ id_name.

    %@helper
:- pred find_const(list(ast_decl)::in, string::in, ast_const::out) is semidet.

find_const([D | Ds], Name, Found) :-
    ( if D = ad_const(C), C ^ acn_name ^ id_name = Name then
        Found = C
    else
        find_const(Ds, Name, Found)
    ).

    %@helper
:- pred find_opaque(list(ast_decl)::in, string::in, ast_opaque::out) is semidet.

find_opaque([D | Ds], Name, Found) :-
    ( if D = ad_opaque(O), O ^ aop_name ^ id_name = Name then
        Found = O
    else
        find_opaque(Ds, Name, Found)
    ).

    %@helper
:- pred find_unit(list(ast_decl)::in, string::in, ast_unit::out) is semidet.

find_unit([D | Ds], Name, Found) :-
    ( if D = ad_unit(U), unit_declared_name(U) = Name then
        Found = U
    else
        find_unit(Ds, Name, Found)
    ).

    % The units a library's unit brings with it: every unit declaration the
    % library makes, and those of each library it imports a unit from by name. A
    % qualified `import B` is not followed. `Chain` stops a cycle.
    %
    %@spec [LIMP.9.8]
:- func library_unit_group(library_env, list(string), ast_file)
    = list(ast_unit).

library_unit_group(Libs, Chain, Library) =
    unit_group(Library ^ af_decls) ++ list.condense(list.filter_map(
        reexported_units(Libs, Chain), Library ^ af_decls)).

    %@helper
:- func reexported_units(library_env, list(string), ast_decl)
    = list(ast_unit) is semidet.

reexported_units(Libs, Chain, Decl) = Units :-
    Decl = ad_import(Import),
    Import ^ ai_form = aif_selective(Items),
    Dep = library_name(Import ^ ai_path),
    not list.member(Dep, Chain),
    library_tree(Libs, Dep, DepLibrary),
    list.find_first_match(
        ( pred(I::in) is semidet :-
            find_unit(DepLibrary ^ af_decls, I ^ aii_name ^ id_name, _)
        ), Items, _),
    Units = library_unit_group(Libs, [Dep | Chain], DepLibrary).

    % Duplicates are harmless: `resolve` classifies into a map.
    %
    %@helper
:- func unit_group(list(ast_decl)) = list(ast_unit).

unit_group([]) = [].
unit_group([D | Ds]) =
    ( if D = ad_unit(U) then [U | unit_group(Ds)] else unit_group(Ds) ).

    %@helper
:- pred find_schema(list(ast_decl)::in, string::in, ast_schema::out) is semidet.

find_schema([D | Ds], Name, Found) :-
    ( if D = ad_schema(S), S ^ as_name ^ id_name = Name then
        Found = S
    else
        find_schema(Ds, Name, Found)
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.imports.
%-----------------------------------------------------------------------------%

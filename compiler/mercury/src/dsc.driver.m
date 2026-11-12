% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.driver -- source text to a `.dsc` artefact.
%
% The phases run in order, each `det`, and each that can fail returns a whole
% result or its diagnostics, never a partial one. A front-end stop is one error,
% since `lex`, `layout` and `parse` each stop at their first.
%
% The program's `use` line is resolved first, and its settings govern every
% module of the unit ([LDIA.2.10.9]).
%-----------------------------------------------------------------------------%

:- module dsc.driver.
:- interface.

:- import_module dsc.cst.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.dialect.
:- import_module dsc.imports.
:- import_module dsc.lex.
:- import_module dsc.token.

:- import_module assoc_list.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module string.
:- import_module uint8.

%-----------------------------------------------------------------------------%

    % How a source with no `use` line is taken: refused, as `dsc` does, or
    % compiled as though it began with `use <dialect>`, with no position
    % shifted, which only a test harness asks for.
    %
    %@helper
:- type program_mode
    --->    as_written
    ;       as_though(string).

    %@helper
:- type compile_result
    --->    compiled(
                cp_bytes     :: list(uint8),
                cp_warnings  :: list(diagnostic),
                    % In source order.
                cp_messages  :: assoc_list(string, string)
                    % Every schema the artefact carries a SchemaDef for, by name,
                    % with the `message` block of its `proto_source`
                    % ([RDSC.5.8.3]), in emission order. What `dsc
                    % dump-schemas` writes ([RCLI.1.5]).
            )

    ;       compile_rejected(list(diagnostic))
            % `resolve`, `validate` or `lower` refused it.

    ;       compile_stopped(ds_front, string, pos, maybe(pos)).
            % `lex`, `layout` or `parse` refused it: the code, the rendered
            % message, where it starts, and where it ends when it stopped at a
            % token. A lex error and `pos(0, 0)` have no token.

    % Source text to artefact bytes, with no library environment.
    %
    %@helper
:- pred compile_source(program_mode::in, string::in, compile_result::out)
    is det.

    % Source text to artefact bytes, against a library environment. `no` is none
    % configured, so imports are trusted. `yes(map.init)` is an empty one, so
    % every import is `DS_VALIDATE_UNKNOWN_LIBRARY` ([LIMP.3.1.2]).
    %
    %@helper
:- pred compile_with(program_mode::in, maybe(library_sources)::in, string::in,
                     compile_result::out) is det.

    % What the caller found beside the source for [RTCT.4.1]'s sibling lookup:
    % this compiler reads no filesystem. `dsrt_absent` is [RTCT.4.2]'s refusal on
    % a `realtime` source.
    %
    %@helper
:- type dsrt_input
    --->    dsrt_absent
    ;       dsrt_source(string).

    %@helper
:- pred compile_realtime(program_mode::in, maybe(library_sources)::in,
                         dsrt_input::in, string::in, compile_result::out)
    is det.

    % What only a caller that walked the disk knows. `sl_file` and `sl_libraries`:
    % each module's DsSource `file` ([RDSC.14.2.3]), by module name, a module with
    % no entry keeping `<in-memory:{name}.ds>`. `sl_ambiguous`: each module name
    % more than one file resolves to, with every candidate ([LIMP.3.1.3]).
    %
    %@helper
:- type source_labels
    --->    source_labels(
                sl_file       :: string,
                sl_libraries  :: map(string, string),
                sl_ambiguous  :: map(string, list(string)),
                sl_companions :: companions
            ).

    % The text of each compiled module's companion `.dstest` ([LTSL.2.4]), the
    % program's, and each library's by its module name.
    %
    %@helper
:- type companions
    --->    companions(
                cm_program   :: maybe(string),
                cm_libraries :: map(string, string)
            ).

    %@helper
:- func no_companions = companions.

    %@helper
:- func in_memory_labels = source_labels.

    %@helper
:- pred compile_labelled(program_mode::in, maybe(library_sources)::in,
                         dsrt_input::in, source_labels::in, string::in,
                         compile_result::out) is det.

    % Resolves the `use` line against a caller's dialects ([NDLC.4.3]). Every
    % other entry point is this with `builtin_registry`.
    %
    %@helper
:- pred compile_labelled_in(registry::in, program_mode::in,
                            maybe(library_sources)::in, dsrt_input::in,
                            source_labels::in, string::in,
                            compile_result::out) is det.

    % The names of the schemas a source declares, in declaration order. Answers
    % `[]` if the front end refuses, so call it on a source that compiled.
    %
    %@helper
:- pred declared_schema_names(string::in, list(string)::out) is det.

    % `dsc dump-schemas`'s one proto3 file. A declared schema with no SchemaDef is
    % a compiler bug, and aborts.
    %
    %@spec [RCLI.1.5]
:- func rcli_1_5_combined_proto(string, assoc_list(string, string)) = string.

    % `dsc dump-schemas --json`'s document, one line of JSON, for a source that
    % compiled against the same libraries and ambiguities: the front end and
    % resolution run again, as `declared_schema_names` runs the front end again.
    % A source that does not resolve, or a unit the resolved file cannot
    % describe, is a compiler bug, and aborts.
    %
    %@spec [RCLI.1.14]
:- func rcli_1_14_schemas_json(maybe(library_sources),
                               map(string, list(string)), string) = string.

    % The front end alone, and what `dsc dump-ast` writes out from: the tree, the
    % laid-out tokens and the lexer's trivia. No validation: a tool must be able
    % to read a program that does not compile yet.
    %
    %@helper
:- type front_result
    --->    front_ok(dsc.cst.file, list(positioned), trivia)
    ;       front_stopped(ds_front, string, pos, maybe(pos)).

    %@helper
:- pred parse_front(string::in, front_result::out) is det.

    %@spec [LDIA.2.10.6]
:- pred ldia_2_10_6_test_use(string::in, pos::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.
:- import_module ds.contract.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.schema.
:- import_module ds.float_text.

:- import_module dsc.ast.
:- import_module dsc.astjson.
:- import_module dsc.build.
:- import_module dsc.builtins.
:- import_module ds.capability.
:- import_module dsc.capability.
:- import_module dsc.contract.
:- import_module dsc.cycle.
:- import_module dsc.dstest.
:- import_module dsc.encode.
:- import_module dsc.expr.
:- import_module dsc.layout.
:- import_module dsc.libcall.
:- import_module dsc.lower.
:- import_module dsc.parse.
:- import_module dsc.quantity.
:- import_module dsc.resolve.
:- import_module dsc.rete.
:- import_module dsc.validate.

:- import_module bool.
:- import_module int.
:- import_module pair.
:- import_module require.
:- import_module uint32.

%-----------------------------------------------------------------------------%
% The phase chain
%-----------------------------------------------------------------------------%

compile_source(Mode, Source, Result) :-
    compile_with(Mode, no, Source, Result).

compile_with(Mode, Libraries, Source, Result) :-
    compile_realtime(Mode, Libraries, dsrt_absent, Source, Result).

compile_realtime(Mode, Libraries, Dsrt, Source, Result) :-
    compile_labelled(Mode, Libraries, Dsrt, in_memory_labels, Source,
        Result).

in_memory_labels = source_labels("<in-memory:main.ds>", map.init, map.init,
    no_companions).

no_companions = companions(no, map.init).

compile_labelled(Mode, Libraries, Dsrt, Labels, Source, Result) :-
    compile_labelled_in(builtin_registry, Mode, Libraries, Dsrt, Labels,
        Source, Result).

compile_labelled_in(Env, Default, Libraries, Dsrt, Labels, Source, Result) :-
    llex_5_4_lex(Source, LexResult),
    (
        LexResult = lex_error(Error, Pos),
        ( if Error = lx_complex_literal(_) then
            % [LUNI.14.9]'s code is no front-end stop's.
            Result = compile_rejected([error_at(dv_complex_not_in_v1, Pos,
                describe_lex_error(Error))])
        else
            Result = compile_stopped(lex_front_code(Error),
                describe_lex_error(Error), Pos, no)
        )
    ;
        LexResult = lex_ok(Lines),
        after_lex(Env, Default, Libraries, Dsrt, Labels, Source, Lines, Result)
    ).

parse_front(Source, Result) :-
    llex_5_4_lex_trivia(Source, LexResult),
    (
        LexResult = lex_trivia_error(Error, Pos),
        Result = front_stopped(lex_front_code(Error),
            describe_lex_error(Error), Pos, no)
    ;
        LexResult = lex_trivia_ok(Lines, Trivia),
        llex_6_2_layout(Lines, LayoutResult),
        (
            LayoutResult = lay_error(LayError, LayPos),
            Result = front_stopped(lex_generic,
                dsc.layout.describe_error(LayError), LayPos, no)
        ;
            LayoutResult = lay_ok(Tokens),
            lgra_3_1_parse(Tokens, ParseResult),
            (
                ParseResult = parse_error(ParseError, ParsePos),
                Result = front_stopped(parse_front_code(ParseError),
                    describe_parse_error(ParseError), ParsePos,
                    token_end_at(Tokens, ParsePos))
            ;
                ParseResult = parse_ok(Cst),
                Result = front_ok(Cst, Tokens, Trivia)
            )
        )
    ).

ldia_2_10_6_test_use(Source, Pos) :-
    parse_front(Source, front_ok(Cst, _, _)),
    Cst ^ f_use = yes(Use),
    Pos = Use ^ u_pos.

    %@helper
:- pred after_lex(registry::in, program_mode::in, maybe(library_sources)::in,
                  dsrt_input::in, source_labels::in, string::in,
                  list(source_line)::in, compile_result::out) is det.

after_lex(Env, Default, Libraries, Dsrt, Labels, Source, Lines, Result) :-
    llex_6_2_layout(Lines, LayoutResult),
    (
        LayoutResult = lay_error(Error, Pos),
        Result = compile_stopped(lex_generic,
            dsc.layout.describe_error(Error), Pos, no)
    ;
        LayoutResult = lay_ok(Tokens),
        after_layout(Env, Default, Libraries, Dsrt, Labels, Source, Tokens,
            Result)
    ).

    %@helper
:- pred after_layout(registry::in, program_mode::in, maybe(library_sources)::in,
                     dsrt_input::in, source_labels::in, string::in,
                     list(positioned)::in, compile_result::out) is det.

after_layout(Env, Default, Libraries, Dsrt, Labels, Source, Tokens, Result) :-
    lgra_3_1_parse(Tokens, ParseResult),
    (
        ParseResult = parse_error(Error, Pos),
        ( if Error = pe_complex_unit(_) then
            Result = compile_rejected([error_at(dv_complex_not_in_v1, Pos,
                describe_parse_error(Error))])
        else
            Result = compile_stopped(parse_front_code(Error),
                describe_parse_error(Error), Pos, token_end_at(Tokens, Pos))
        )
    ;
        ParseResult = parse_ok(Cst),
        build_file(Cst, Ast00),
        % The companion joins before injection, so a builtin one of its tests
        % names is brought in.
        Companion = ltsl_2_4_companion(
            Labels ^ sl_companions ^ cm_program,
            rcli_1_9_companion_label(Labels ^ sl_file)),
        (
            Companion = companion_refused(CompanionErrors),
            Result = compile_rejected(CompanionErrors)
        ;
            Companion = companion_tests(CompanionTests),
            Ast0 = ltsl_2_4_with_tests(CompanionTests, Ast00),
            inject_builtin_schemas(Ast0, Injected),
            (
                Injected = injected(Ast),
                after_build(Env, Default, Libraries, Dsrt, Labels, Source, Ast,
                    Result)
            ;
                Injected = injection_failed(Message),
                Result = compile_stopped(parse_generic, Message, pos(0, 0),
                    no)
            )
        )
    ).

%-----------------------------------------------------------------------------%
% A module's companion `.dstest` -- [LTSL.2.4], [LTSL.2.1]
%-----------------------------------------------------------------------------%

    %@helper
:- type companion_read
    --->    companion_tests(list(ast_test))
    ;       companion_refused(list(diagnostic)).

    % Every diagnostic names the companion ([RCLI.1.9]): its positions are its
    % own.
    %
    %@spec [LTSL.2.4]
    %@spec [LTSL.2.1]
:- func ltsl_2_4_companion(maybe(string), string) = companion_read.

ltsl_2_4_companion(no, _) = companion_tests([]).
ltsl_2_4_companion(yes(Text), Label) = Read :-
    parse_front(Text, Front),
    (
        Front = front_stopped(Code, Message, Pos, End),
        D0 = front_error_at(Code, Pos, Message),
        D = ( if End = yes(E) then with_end(D0, E) else D0 ),
        Read = companion_refused([rcli_1_9_in_file(Label, D)])
    ;
        Front = front_ok(Cst, _, _),
        build_file(Cst, Ast),
        (
            Ast ^ af_use = yes(Use),
            UseErrors = [with_hint(error_at(dv_use_in_test, Use ^ au_pos,
                "a `.dstest` file must not have a `use` directive; it runs "
                    ++ "under the resolved settings of the program it tests "
                    ++ "([LDIA.2.10.6])"),
                "remove the `use` line")]
        ;
            Ast ^ af_use = no,
            UseErrors = []
        ),
        DeclErrors = list.filter_map(ltsl_2_1_companion_decl, Ast ^ af_decls),
        Errors = UseErrors ++ DeclErrors,
        (
            Errors = [],
            Read = companion_tests(list.filter_map(
                ( func(D) = Test is semidet :-
                    D = ad_test(T),
                    Test = T ^ tst_file := yes(Label)
                ), Ast ^ af_decls))
        ;
            Errors = [_ | _],
            Read = companion_refused(
                list.map(rcli_1_9_in_file(Label), Errors))
        )
    ).

    %@spec [LTSL.2.1]
:- func ltsl_2_1_companion_decl(ast_decl) = diagnostic is semidet.

ltsl_2_1_companion_decl(Decl) = with_hint(error_at(dv_test_companion_decl,
        decl_pos(Decl), "a `.dstest` holds `test` declarations and nothing "
            ++ "else ([LTSL.2.1])"),
        "move this declaration into the module's `.ds`") :-
    not Decl = ad_test(_).

    % The `.ds`'s tests then the companion's: [RLOW.17.1]'s order.
    %
    %@spec [LTSL.2.4]
:- func ltsl_2_4_with_tests(list(ast_test), ast_file) = ast_file.

ltsl_2_4_with_tests(Tests, Ast) =
    Ast ^ af_decls := Ast ^ af_decls ++ list.map(( func(T) = ad_test(T) ),
        Tests).

    %@spec [RCLI.1.9]
:- func rcli_1_9_companion_label(string) = string.

rcli_1_9_companion_label(Module) = Label :-
    ( if string.remove_suffix(Module, ".ds", Stem) then
        Label = Stem ++ ".dstest"
    else if string.remove_suffix(Module, ".ds>", Stem) then
        Label = Stem ++ ".dstest>"
    else
        Label = Module ++ ".dstest"
    ).

    %@spec [RCLI.1.9]
:- func rcli_1_9_library_label(source_labels, string) = string.

rcli_1_9_library_label(Labels, Name) =
    ( if map.search(Labels ^ sl_libraries, Name, Path) then Path
      else library_label(Name) ).

    % How far library `Name` moves the `test_id` of every module after it. One
    % that does not parse counts what could be read: the compile is refused.
    %
    %@spec [RLOW.17.1]
:- func rlow_17_1_library_tests(library_env, source_labels, string) = int.

rlow_17_1_library_tests(Libs, Labels, Name) = Count :-
    ( if library_tree(Libs, Name, Ast) then
        Count = rlow_17_1_test_count(
            ltsl_2_4_with_tests(library_companion_tests(Labels, Name), Ast))
    else
        Count = 0
    ).

    %@helper
:- func library_companion_tests(source_labels, string) = list(ast_test).

library_companion_tests(Labels, Name) = Tests :-
    Read = library_companion(Labels, Name),
    (
        Read = companion_tests(Tests)
    ;
        Read = companion_refused(_),
        Tests = []
    ).

    %@helper
:- func library_companion(source_labels, string) = companion_read.

library_companion(Labels, Name) = ltsl_2_4_companion(Text,
        rcli_1_9_companion_label(rcli_1_9_library_label(Labels, Name))) :-
    ( if map.search(Labels ^ sl_companions ^ cm_libraries, Name, T) then
        Text = yes(T)
    else
        Text = no
    ).

%-----------------------------------------------------------------------------%
% Front-end codes
%-----------------------------------------------------------------------------%
%
% The code is the corpus's and does not always follow the phase that stopped:
% this lexer refuses by name some spellings the corpus gives the parser's code.

    %@helper
:- func lex_front_code(lex_error) = ds_front.

lex_front_code(Error) = Code :-
    ( if Error = lx_bad_identifier(_, _) then
        Code = lex_invalid_identifier
    else if Error = lx_int_out_of_range(_) then
        Code = parse_int_range
    else if Error = lx_float_out_of_range(_) then
        Code = parse_float_range
    else if
        ( Error = lx_ellipsis
        ; Error = lx_bare_fraction
        ; Error = lx_underscore_placement(_)
        ; Error = lx_unterminated_regex
        ; Error = lx_based_unit(_)
        ; Error = lx_bare_imaginary(_)
        ; Error = lx_complex_literal(_)     % `dump-ast` only
        )
    then
        Code = parse_generic
    else
        Code = lex_generic
    ).

    % A brace outside a string is a lexer error ([LLEX.7.5.6]) that this lexer
    % tokenises, so it surfaces here. `@` is the parser's ([LLEX.8.2.1]).
    %
    %@helper
:- func parse_front_code(parse_error) = ds_front.

parse_front_code(Error) = Code :-
    ( if Error = pe_duplicate_use(_) then
        Code = parse_duplicate_use
    else if
        ( Error = pe_expected(_, Found)
        ; Error = pe_expected_eof(Found)
        )
    then
        ( if ( Found = lbrace ; Found = rbrace ) then
            Code = lex_generic
        else if Found = int_min_magnitude then
            % `9223372036854775808` un-negated.
            Code = parse_int_range
        else
            Code = parse_generic
        )
    else
        Code = parse_generic
    ).

%-----------------------------------------------------------------------------%
% Builtin schemas -- [LCRS.4], [LHYD.4.3.1], [LHYD.5.1]
%-----------------------------------------------------------------------------%
%
% Here and not in `resolve`, because injecting means parsing. A file gets a
% schema's declaration when it references it or the row's condition holds
% ([LIMP.12.2]). A file declaring one gets no injected copy, so
% `dsc.resolve.limp_12_3_builtin_collisions` is its one diagnostic.

    %@helper
:- type injection
    --->    injected(ast_file)
    ;       injection_failed(string).

    %@helper
:- pred inject_builtin_schemas(ast_file::in, injection::out) is det.

inject_builtin_schemas(Ast, Injected) :-
    Decls = Ast ^ af_decls,
    Declared = declared_schema_names(Decls),
    Referenced = referenced_type_names(Decls),
    Wanted = list.filter(wants_injection(Declared, Referenced),
        builtin_schema_names)
        ++ list.filter(( pred(N::in) is semidet :-
                not contains_name(Declared, N) ),
            limp_12_2_always_written),
    list.foldl(parse_builtin, Wanted, injected_decls([]), Built),
    (
        Built = injected_decls(New),
        Injected = injected(Ast ^ af_decls := list.reverse(New) ++ Decls)
    ;
        Built = injection_error(Message),
        Injected = injection_failed(Message)
    ).

    %@helper
:- type injected_decls
    --->    injected_decls(list(ast_decl))
    ;       injection_error(string).

    %@helper
:- pred wants_injection(list(string)::in, list(string)::in, string::in)
    is semidet.

wants_injection(Declared, Referenced, Name) :-
    contains_name(Referenced, Name),
    not contains_name(Declared, Name).

    %@helper
:- pred contains_name(list(string)::in, string::in) is semidet.

contains_name([N | Ns], Name) :-
    ( if N = Name then true else contains_name(Ns, Name) ).

    %@helper
:- func declared_schema_names(list(ast_decl)) = list(string).

declared_schema_names([]) = [].
declared_schema_names([D | Ds]) =
    ( if D = ad_schema(S) then
        [S ^ as_name ^ id_name | declared_schema_names(Ds)]
    else
        declared_schema_names(Ds)
    ).

    % Only a bare name counts: `lib.Schema` is never a builtin.
    %
    %@helper
:- func referenced_type_names(list(ast_decl)) = list(string).

referenced_type_names(Decls) =
    list.condense(list.map(rule_type_names, Decls)).

    %@helper
:- func rule_type_names(ast_decl) = list(string).

rule_type_names(Decl) =
    ( if Decl = ad_rule(R) then
        list.condense(list.map(clause_type_names, R ^ ar_lhs))
            ++ rhs_builtin_uses(R ^ ar_rhs)
    else if Decl = ad_test(T) then
        test_type_names(T)
    else
        []
    ).

    % The interpreter asserts a test's facts through the artefact's own schemas,
    % so a builtin a test names is one the artefact needs.
    %
    %@helper
:- func test_type_names(ast_test) = list(string).

test_type_names(T) =
    list.condense(list.map(section_type_names, T ^ tst_sections)).

    %@helper
:- func section_type_names(ast_test_section) = list(string).

section_type_names(tsec_initial(Items, _)) =
    list.filter_map(initial_schema, Items).
section_type_names(tsec_inputs(Blocks, _)) = list.condense(list.map(
    ( func(B) = list.filter_map(fact_schema, B ^ tat_facts) ),
    Blocks)).
section_type_names(tsec_responses(Stubs, _)) = list.condense(list.map(
    ( func(S) = list.filter_map(reply_schema, S ^ tstb_replies) ),
    Stubs)).
section_type_names(tsec_produces(As, _)) =
    list.filter_map(assertion_head_schema, As).
section_type_names(tsec_until(_, _)) = [].

    %@helper
:- func initial_schema(ast_test_initial) = string is semidet.

initial_schema(tini_fact(F)) = fact_schema(F).

    %@helper
:- func reply_schema(ast_test_reply) = string is semidet.

reply_schema(trep_fact(F)) = fact_schema(F).

    %@helper
:- func fact_schema(ast_test_fact) = string is semidet.

fact_schema(F) = bare_schema(F ^ tfa_schema).

    %@helper
:- func bare_schema(ast_type_ref) = string is semidet.

bare_schema(atr_bare(Id)) = Id ^ id_name.

    %@helper
:- func assertion_head_schema(ast_test_assertion) = string is semidet.

assertion_head_schema(A) = assertion_schema(A ^ tas_head).

    %@helper
:- func assertion_schema(ast_test_head) = string is semidet.

assertion_schema(thd_emitted(S, _, _)) = bare_schema(S).
assertion_schema(thd_published(S, _, _)) = bare_schema(S).
assertion_schema(thd_retracted(S, _)) = bare_schema(S).
assertion_schema(thd_wm_has(S, _)) = bare_schema(S).
assertion_schema(thd_wm_count(S, _)) = bare_schema(S).

    %@helper
:- func rhs_builtin_uses(ast_rule_rhs) = list(string).

rhs_builtin_uses(Rhs) =
    actions_builtin_uses(Rhs ^ arr_actions)
        ++ list.condense(list.map(after_builtin_uses, Rhs ^ arr_afters)).

    %@helper
:- func after_builtin_uses(ast_after_clause) = list(string).

after_builtin_uses(After) =
    actions_builtin_uses(After ^ aaf_actions)
        ++ list.condense(list.map(after_builtin_uses, After ^ aaf_nested)).

    %@helper
:- func actions_builtin_uses(list(ast_action)) = list(string).

actions_builtin_uses(Actions) =
    list.condense(list.map(action_builtin_uses, Actions)).

    %@helper
:- func action_builtin_uses(ast_action) = list(string).

action_builtin_uses(Action) = Uses :-
    Block = Action ^ aac_block,
    (
        Block = aab_call(_, Continuations),
        Nested = list.condense(list.map(continuation_actions, Continuations)),
        FromCont = list.condense(list.map(continuation_uses, Continuations))
            ++ actions_builtin_uses(Nested)
    ;
        ( Block = aab_none
        ; Block = aab_kwargs(_)
        ),
        FromCont = []
    ),
    Uses = FromCont ++ limp_12_2_call_uses(Action ^ aac_head).

    % A `call` writes `CallError` whether or not a rule matches it: an adapter
    % may assert one for any call ([LCRS.4.2.2]).
    %
    %@spec [LIMP.12.2]
:- func limp_12_2_call_uses(ast_action_head) = list(string).

limp_12_2_call_uses(Head) =
    ( if Head = aah_call(_) then ["CallError"] else [] ).

    %@helper
:- func continuation_uses(ast_continuation) = list(string).

continuation_uses(acont_on(_, _, _)) = [].
continuation_uses(acont_error(_, _, _)) = ["CallError"].
continuation_uses(acont_timeout(_, _, _)) = ["CallError"].

    %@helper
:- func continuation_actions(ast_continuation) = list(ast_action).

continuation_actions(acont_on(_, Actions, _)) = Actions.
continuation_actions(acont_error(_, Actions, _)) = Actions.
continuation_actions(acont_timeout(_, Actions, _)) = Actions.

    %@helper
:- func clause_type_names(ast_lhs_clause) = list(string).

clause_type_names(alc_pattern(P)) = pattern_type_names(P).
clause_type_names(alc_then(S)) = step_type_names(S).

    %@helper
:- func pattern_type_names(ast_pattern) = list(string).

pattern_type_names(ap_simple(B)) = body_type_names(B).
pattern_type_names(ap_negated(B, _)) = body_type_names(B).
pattern_type_names(ap_sequence(_, Head, Steps, _)) =
    body_type_names(Head) ++
        list.condense(list.map(step_type_names, Steps)).

    %@helper
:- func step_type_names(ast_then_step) = list(string).

step_type_names(Step) = body_type_names(Step ^ ats_body).

    %@helper
:- func body_type_names(ast_pattern_body) = list(string).

body_type_names(Body) = Names :-
    ( if Body ^ apb_type = atr_bare(Id) then
        Names = [Id ^ id_name]
    else
        Names = []
    ).

    % A failure is a defect in this compiler's own constant; `test_dsc` parses
    % them all.
    %
    %@helper
:- pred parse_builtin(string::in, injected_decls::in, injected_decls::out)
    is det.

parse_builtin(_, injection_error(M), injection_error(M)).
parse_builtin(Name, injected_decls(Acc), Out) :-
    ( if builtin_schema(Name, Source) then
        llex_5_4_lex(Source, LexResult),
        ( if
            LexResult = lex_ok(Lines),
            llex_6_2_layout(Lines, lay_ok(Tokens)),
            lgra_3_1_parse(Tokens, parse_ok(Cst))
        then
            build_file(Cst, Built),
            Marked = list.map(mark_injected, Built ^ af_decls),
            Out = injected_decls(list.reverse(Marked) ++ Acc)
        else
            Out = injection_error("internal: the builtin schema `" ++ Name
                ++ "` did not parse")
        )
    else
        Out = injection_error("internal: no source for the builtin schema `"
            ++ Name ++ "`")
    ).

    % A fault schema becomes `internal` here ([LSCP.2.6]): the author grammar has
    % no `internal` ([LSCP.2.6.2]).
    %
    %@helper
:- func mark_injected(ast_decl) = ast_decl.

mark_injected(Decl) =
    ( if Decl = ad_schema(S) then
        ( if contains_name(fault_schema_names, S ^ as_name ^ id_name) then
            ad_schema((S ^ as_origin := compiler_injected)
                ^ as_lifecycle := al_internal)
        else
            ad_schema(S ^ as_origin := compiler_injected)
        )
    else
        Decl
    ).

    %@helper
:- pred after_build(registry::in, program_mode::in, maybe(library_sources)::in,
                    dsrt_input::in, source_labels::in, string::in,
                    ast_file::in, compile_result::out) is det.

after_build(Registry, Mode, Libraries, Dsrt, Labels, Source, Ast0, Result) :-
    Finance = finance_deferred(Ast0),
    (
        Finance = [_ | _],
        Result = compile_rejected(Finance)
    ;
        Finance = [],
        after_finance(Registry, Mode, Libraries, Dsrt, Labels, Source, Ast0,
            Result)
    ).

    %@helper
:- pred after_finance(registry::in, program_mode::in,
                      maybe(library_sources)::in, dsrt_input::in,
                      source_labels::in, string::in, ast_file::in,
                      compile_result::out) is det.

after_finance(Registry, Mode, Libraries, Dsrt, Labels, Source, Ast0, Result) :-
    ldia_2_10_8_program(Mode, Ast0, MaybeUse),
    (
        MaybeUse = no,
        Result = compile_rejected([with_hint(error_at(dv_not_a_program,
            pos(1, 1), "this file has no `use` directive, so it is a "
                ++ "library, and a library has no settings to be built under "
                ++ "([LDIA.2.10.8])"),
            "build a program that imports it, or begin this file with "
                ++ "`use <dialect>` to make it one")])
    ;
        MaybeUse = yes(Use),
        Ast = Ast0 ^ af_use := yes(Use),
        ldia_3_1_resolve(Registry, Use, Resolution),
        (
            Resolution = resolution_refused(Diagnostics),
            Result = compile_rejected(Diagnostics)
        ;
            Resolution = resolved(Program),
            after_program(Program, Libraries, Dsrt, Labels, Source, Ast,
                Result)
        )
    ).

    % A supplied line sits at `pos(0, 0)`, before every token, so no placement
    % check sees anything ahead of it.
    %
    %@spec [LDIA.2.10.1]
    %@spec [LDIA.2.10.8]
:- pred ldia_2_10_8_program(program_mode::in, ast_file::in,
                            maybe(ast_use)::out) is det.

ldia_2_10_8_program(Mode, Ast, MaybeUse) :-
    (
        Ast ^ af_use = yes(Use),
        MaybeUse = yes(Use)
    ;
        Ast ^ af_use = no,
        (
            Mode = as_written,
            MaybeUse = no
        ;
            Mode = as_though(Dialect),
            MaybeUse = yes(ast_use(ident(Dialect, pos(0, 0)), [], pos(0, 0)))
        )
    ).

    %@spec [LDIA.2.10.7]
:- func ldia_2_10_7_imports(maybe(library_env), list(ast_decl))
    = list(diagnostic).

ldia_2_10_7_imports(no, _) = [].
ldia_2_10_7_imports(yes(Libs), Decls) = list.filter_map(
    ( func(D) = Diag is semidet :-
        D = ad_import(I),
        Name = library_name(I ^ ai_path),
        library_tree(Libs, Name, Imported),
        Imported ^ af_use = yes(_),
        Diag = with_hint(error_at(dv_import_of_program, I ^ ai_pos,
            "`" ++ Name ++ "` has a `use` directive, so it is a program, and "
                ++ "a program imports libraries only ([LDIA.2.10.7])"),
            "remove the `use` line from `" ++ Name ++ "` to make it a "
                ++ "library")
    ), Decls).

    %@helper
:- pred after_program(program_settings::in, maybe(library_sources)::in,
                      dsrt_input::in, source_labels::in, string::in,
                      ast_file::in, compile_result::out) is det.

after_program(Program, Libraries, Dsrt, Labels, Source, Ast00, Result) :-
    % A load failure is reported with the file's own errors ([LERR.1.1.11]). The
    % libraries are parsed once, here: every later phase reads `Libs`.
    (
        Libraries = yes(Sources),
        Libs = library_env_on_disk(Sources, Labels ^ sl_ambiguous,
            Ast00 ^ af_decls),
        load_libraries_in(Libs, Ast00 ^ af_decls, Imports, LoadErrors0),
        Scope = imports_resolved(Imports),
        MaybeLibs = yes(Libs),
        % Every library's tests are numbered before the program's ([RLOW.17.1]),
        % in the order `library_rules` numbers them.
        LibraryTests = list.foldl(
            ( func(Name - _, N) = N + rlow_17_1_library_tests(Libs, Labels,
                Name) ),
            Imports ^ im_library_schemas, 0)
    ;
        Libraries = no,
        Scope = imports_trusted,
        LoadErrors0 = [],
        MaybeLibs = no,
        LibraryTests = 0
    ),
    % [RTIM.14.11]'s oracle rules join the file before anything resolves, named
    % by the artefact-wide `test_id` ([RTIM.14.13]). The rewrite is idempotent;
    % doing it here as well as in `resolve_imported` keeps `after_resolve`'s tree
    % the resolved file's.
    Ast = limp_3_3_4_rewrite_file(
        rtim_14_11_oracle_rules(LibraryTests + 1, Ast00)),
    Rerun = companion_rerun(rcli_1_9_companion_label(Labels ^ sl_file), Ast,
        limp_3_3_4_rewrite_file(
            rcli_1_9_module_oracle_rules(LibraryTests + 1, Ast00)),
        Scope, Program, []),
    LoadErrors = LoadErrors0 ++ ldia_2_10_7_imports(MaybeLibs, Ast ^ af_decls),
    resolve_imported(Ast, Scope, ResolveResult),
    (
        ResolveResult = resolve_errors(Diagnostics),
        Result = compile_rejected(LoadErrors
            ++ rcli_1_9_companion_oracle(Rerun, Diagnostics))
    ;
        ResolveResult = resolve_ok(RF0),
        RF = RF0 ^ rf_program := Program,
        after_resolve(Dsrt, LoadErrors, Rerun, Libraries, MaybeLibs, Labels,
            Source, Ast, RF, Result)
    ).

    % What a module is checked again with, to name the companion for what its
    % oracle rules raised: the companion's name, the module with every rule but
    % those, how its imports resolve, and what `validate` reads.
    %
    %@helper
:- type companion_rerun
    --->    no_companion_rules
    ;       companion_rules(string, ast_file, import_scope, program_settings,
                list(string)).

    %@helper
:- func companion_rerun(string, ast_file, ast_file, import_scope,
                        program_settings, list(string)) = companion_rerun.

companion_rerun(Label, Ast, Module, Scope, Program, Responses) =
    ( if list.same_length(Ast ^ af_decls, Module ^ af_decls) then
        no_companion_rules
      else
        companion_rules(Label, Module, Scope, Program, Responses) ).

    % A rule carries no file, and a companion's positions overlap its module's.
    % So the module is checked again without the companion's oracle rules: a
    % diagnostic that raises too is the module's, and any other the companion's,
    % matched one for one. The second check runs only when there is one to name.
    %
    %@spec [RCLI.1.9]
:- func rcli_1_9_companion_oracle(companion_rerun, list(diagnostic))
    = list(diagnostic).

rcli_1_9_companion_oracle(no_companion_rules, Ds) = Ds.
rcli_1_9_companion_oracle(
        companion_rules(Label, Module, Scope, Program, Responses), Ds)
        = Named :-
    (
        Ds = [],
        Named = []
    ;
        Ds = [_ | _],
        resolve_imported(Module, Scope, Resolved),
        (
            Resolved = resolve_errors(Own)
        ;
            Resolved = resolve_ok(RF0),
            validate_file((RF0 ^ rf_program := Program)
                ^ rf_program_responses := Responses, Validated),
            (
                Validated = validate_errors(Own)
            ;
                Validated = validate_ok(Own)
            )
        ),
        list.foldl2(name_companion(Label), Ds, Own, _, [], RevNamed),
        Named = list.reverse(RevNamed)
    ).

    %@helper
:- pred name_companion(string::in, diagnostic::in,
                       list(diagnostic)::in, list(diagnostic)::out,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

name_companion(Label, D, !Own, !Named) :-
    ( if list.delete_first(!.Own, D, Rest) then
        !:Own = Rest,
        !:Named = [D | !.Named]
    else
        !:Named = [rcli_1_9_in_file(Label, D) | !.Named]
    ).

    %@helper
:- pred after_resolve(dsrt_input::in,
                      list(diagnostic)::in, companion_rerun::in,
                      maybe(library_sources)::in, maybe(library_env)::in,
                      source_labels::in, string::in, ast_file::in,
                      resolved_file::in, compile_result::out) is det.

after_resolve(Dsrt, LoadErrors, Rerun, Libraries, MaybeLibs, Labels, Source,
        Ast, RF, Result) :-
    validate_file(RF, ValidateResult0),
    (
        ValidateResult0 = validate_errors(Diagnostics0),
        ValidateResult = validate_errors(
            rcli_1_9_companion_oracle(Rerun, Diagnostics0))
    ;
        ValidateResult0 = validate_ok(Warnings0),
        ValidateResult = validate_ok(
            rcli_1_9_companion_oracle(Rerun, Warnings0))
    ),
    (
        ValidateResult = validate_errors(Diagnostics),
        Result = compile_rejected(LoadErrors ++ Diagnostics)
    ;
        ValidateResult = validate_ok(Warnings),
        LoadErrors = [_ | _],
        Result = compile_rejected(LoadErrors ++ Warnings)
    ;
        ValidateResult = validate_ok(FileWarnings),
        LoadErrors = [],
        limp_7_5_library_rules(MaybeLibs, Labels, RF, LibraryResult),
        (
            LibraryResult = library_errors(LibraryErrors),
            Result = compile_rejected(LibraryErrors)
        ;
            LibraryResult = library_modules(LibraryModules, AllLibraries,
                LibraryWarnings),
            % Only a cycle spanning modules can fail this.
            lcyc_6_3_unit_graph(
                list.map(( func(M) = M ^ lm_name - M ^ lm_resolved ),
                    LibraryModules) ++ ["" - RF],
                CycleErrors),
            UnitErrors = lcrs_14_9_duplicate_services(MaybeLibs, Labels, RF)
                ++ lgra_6_8_duplicate_rules(Labels, LibraryModules, RF)
                ++ list.map(rcli_1_9_named_by_module(Labels), CycleErrors),
            (
                UnitErrors = [_ | _],
                Result = compile_rejected(UnitErrors)
            ;
                UnitErrors = [],
                Warnings = LibraryWarnings ++ FileWarnings,
                Program = RF ^ rf_program,
                Binding = binding(Program,
                    rdsc_16_2_8_requires(Program, [RF | AllLibraries])),
                after_libraries(Binding, Dsrt, Libraries, Labels, Source, Ast,
                    RF, LibraryModules, Warnings, Result)
            )
        )
    ).

    %@helper
:- pred after_libraries(binding::in, dsrt_input::in,
                        maybe(library_sources)::in, source_labels::in,
                        string::in, ast_file::in, resolved_file::in,
                        list(library_module)::in, list(diagnostic)::in,
                        compile_result::out) is det.

after_libraries(Binding, Dsrt, Libraries, Labels, Source, Ast, RF,
        LibraryModules, Warnings, Result) :-
    % The libraries' tests in `module_id` order and the file's last, numbered
    % across the artefact ([RLOW.17.1]).
    list.foldl3(ltsl_2_4_library_tests(Labels, LibraryModules), LibraryModules,
        first_test_counters, Counters, [], RevLibraryTests, [], RevErrors),
    % The file's tests see every rule the artefact carries.
    RuleNames = list.condense(list.map(
        ( func(M) = rule_names(M ^ lm_resolved ^ rf_ast) ), LibraryModules))
        ++ rule_names(RF ^ rf_ast),
    rlow_17_1_lower_tests(RF, RuleNames, Counters, _, TestOutcome),
    (
        TestOutcome = tests_rejected(FileErrors)
    ;
        TestOutcome = tests_lowered(_),
        FileErrors = []
    ),
    ( if
        TestOutcome = tests_lowered(FileTests),
        RevErrors = []
    then
        after_tests(Binding, Dsrt, Libraries, Labels, Source, Ast, RF,
            LibraryModules, Warnings,
            list.reverse(RevLibraryTests) - FileTests, Result)
    else
        Result = compile_rejected(list.reverse(RevErrors) ++ FileErrors)
    ).

    % One library's tests, against its own rules and its import closure's.
    %
    %@spec [LTSL.2.4]
:- pred ltsl_2_4_library_tests(source_labels::in, list(library_module)::in,
                               library_module::in,
                               test_counters::in, test_counters::out,
                               assoc_list(uint32, list(test_ir))::in,
                               assoc_list(uint32, list(test_ir))::out,
                               list(diagnostic)::in, list(diagnostic)::out)
    is det.

ltsl_2_4_library_tests(Labels, Modules, M, !Counters, !RevTests, !RevErrors) :-
    LibRF = M ^ lm_resolved,
    Closure = list.map((func(N - _) = N), LibRF ^ rf_library_modules),
    Seen = list.filter(
        ( pred(Other::in) is semidet :- list.member(Other ^ lm_name, Closure) ),
        Modules),
    RuleNames = list.condense(list.map(
        ( func(Other) = rule_names(Other ^ lm_resolved ^ rf_ast) ), Seen))
        ++ rule_names(LibRF ^ rf_ast),
    rlow_17_1_lower_tests(LibRF, RuleNames, !Counters, Outcome),
    (
        Outcome = tests_lowered(Tests),
        !:RevTests = [M ^ lm_clip - Tests | !.RevTests]
    ;
        Outcome = tests_rejected(Errors),
        !:RevErrors = list.reverse(
            list.map(in_library(Labels, M ^ lm_name), Errors)) ++ !.RevErrors
    ).

    %@helper
:- func rule_names(ast_file) = list(string).

rule_names(Ast) = list.filter_map(decl_rule_name, Ast ^ af_decls).

    %@helper
:- func decl_rule_name(ast_decl) = string is semidet.

decl_rule_name(ad_rule(R)) = R ^ ar_name ^ id_name.

    %@helper
:- pred after_tests(binding::in, dsrt_input::in,
                    maybe(library_sources)::in, source_labels::in,
                    string::in, ast_file::in, resolved_file::in,
                    list(library_module)::in, list(diagnostic)::in,
                    pair(assoc_list(uint32, list(test_ir)), list(test_ir))::in,
                    compile_result::out) is det.

after_tests(Binding, Dsrt, Libraries, Labels, Source, Ast, RF,
        LibraryModules, Warnings, LibraryTests - FileTests, Result) :-
    lower_schemas(RF, rhim_2_2_hydration_targets(RF), LowerResult),
    (
        LowerResult = lower_errors(Located),
        Result = compile_rejected(
            list.map(rcli_1_9_named_by_module(Labels), Located))
    ;
        LowerResult = lowered(Interns0, Schemas, FileClip, Positions,
            SchemaDocs),
        % The libraries' rules, leaves first, and the file's last ([LDET.5.4]).
        rlow_4_2_1_lower_rules(
            list.map(( func(M) = M ^ lm_clip - M ^ lm_resolved ),
                LibraryModules) ++ [FileClip - RF],
            Schemas, Interns0, Interns, Network, Skips),
        % A skipped rule ends the compile: the network is complete or there is
        % no artefact. So does an `Expr` nested too deep ([RDSC.11.3]) and an
        % index a byte cannot hold ([LGRA.8.7], [LGRA.5.11]), both measured on
        % the lowered network.
        Refused = rules_not_lowered(Labels, Ast, LibraryModules, Skips)
            ++ list.map(rdsc_11_3_expression_too_deep(Labels, LibraryModules),
                rdsc_11_3_too_deep_nodes(Interns, Network))
            ++ list.map(lgra_8_7_too_wide(Labels, LibraryModules),
                lgra_8_7_index_overflows(Interns, Network)),
        (
            Refused = [_ | _],
            Result = compile_rejected(Refused)
        ;
            Refused = [],
            rtct_4_2_contract(Binding, Dsrt, Network, ContractRes),
            (
                ContractRes = contract_carried(MaybeContract),
                % A schema the lowering synthesised belongs to the file's module.
                Encoded = list.map(in_module(FileClip), Network ^ rn_schemas)
                    ++ Schemas,
                rdsc_1_1_encode_tests(Binding, Interns, Encoded,
                    Positions,
                    rdsc_14_2_4_modules(Libraries, Labels, Source, RF,
                        FileClip),
                    SchemaDocs
                        ++ list.condense(list.map(
                            ( func(M) = rdsc_14_4_1_rule_docs(M ^ lm_clip,
                                M ^ lm_resolved ^ rf_ast) ),
                            LibraryModules))
                        ++ rdsc_14_4_1_rule_docs(FileClip, Ast),
                    ladp_8_2_1_services(RF, FileClip),
                    FileClip, Network, MaybeContract,
                    list.map(( func(M) = M ^ lm_clip
                            - lgra_24_3_initial_items(M ^ lm_resolved) ),
                        LibraryModules)
                        ++ [FileClip - lgra_24_3_initial_items(RF)],
                    LibraryTests ++ [FileClip - FileTests], Bytes),
                Result = compiled(Bytes, Warnings,
                    rdsc_5_8_3_messages(Interns, Encoded))
            ;
                ContractRes = contract_refused(ContractErrors),
                Result = compile_rejected(ContractErrors)
            )
        )
    ).

%-----------------------------------------------------------------------------%
% An imported library's rules -- [LIMP.7.5]
%-----------------------------------------------------------------------------%

    %@helper
:- type library_module
    --->    library_module(
                lm_name     :: string,
                lm_clip     :: uint32,
                lm_resolved :: resolved_file
            ).

    %@helper
:- type library_result
    --->    library_modules(list(library_module), list(resolved_file),
                list(diagnostic))
            % The libraries whose rules join the artefact, leaves first;
            % every library the artefact carries, rules or none, for what its
            % content requires ([RDSC.16.2.8]); and their warnings.
    ;       library_errors(list(diagnostic)).

    % Every library in the import DAG, resolved and validated in its own scope.
    % Those with a rule, an `initial:` block or a test are returned, to join the
    % importer's artefact whatever the import took.
    %
    %@spec [LIMP.7.5]
    %@spec [LTSL.2.4]
:- pred limp_7_5_library_rules(maybe(library_env)::in, source_labels::in,
                               resolved_file::in, library_result::out) is det.

limp_7_5_library_rules(MaybeLibs, Labels, RF, Result) :-
    (
        MaybeLibs = no,
        Result = library_modules([], [], [])
    ;
        MaybeLibs = yes(Libs),
        list.foldl4(
            library_rules(RF ^ rf_program, map.values(RF ^ rf_response_names),
                Libs, Labels),
            list.map((func(N - _) = N), RF ^ rf_library_modules),
            {1u32, 1}, _, [], RevModules, [], RevAll, [], RevDiagnostics),
        Diagnostics = list.reverse(RevDiagnostics),
        ( if
            list.find_first_match(
                ( pred(D::in) is semidet :- D ^ dg_severity = sev_error ),
                Diagnostics, _)
        then
            Result = library_errors(Diagnostics)
        else
            Result = library_modules(list.reverse(RevModules),
                list.reverse(RevAll), Diagnostics)
        )
    ).

    % Its clip is its position in `rf_library_modules`, counted whether or not it
    % has rules ([RDSC.4.7]). It is validated under the program's settings
    % ([LDIA.2.10.9]) and against the program's `Responses` ([LCRS.4.3.4]).
    %
    %@helper
:- pred library_rules(program_settings::in, list(string)::in, library_env::in,
                      source_labels::in, string::in,
                      {uint32, int}::in, {uint32, int}::out,
                      list(library_module)::in, list(library_module)::out,
                      list(resolved_file)::in, list(resolved_file)::out,
                      list(diagnostic)::in, list(diagnostic)::out) is det.

library_rules(Program, Responses, Libs, Labels, Name, {Clip, FirstTest}, Next,
        !Modules, !All, !Diagnostics) :-
    Next = {Clip + 1u32,
        FirstTest + rlow_17_1_library_tests(Libs, Labels, Name)},
    ( if
        library_tree(Libs, Name, Ast0),
        Finance = finance_deferred(Ast0),
        Finance = [_ | _]
    then
        !:Diagnostics = list.reverse(
            list.map(in_library(Labels, Name), Finance)) ++ !.Diagnostics
    else if library_tree(Libs, Name, Ast0) then
        % A refused companion is the compile's error, and the library is still
        % checked without it.
        Companion = library_companion(Labels, Name),
        (
            Companion = companion_tests(CompanionTests),
            CompanionErrors = []
        ;
            Companion = companion_refused(CompanionErrors),
            CompanionTests = []
        ),
        !:Diagnostics = list.reverse(CompanionErrors) ++ !.Diagnostics,
        WithTests = ltsl_2_4_with_tests(CompanionTests, Ast0),
        inject_builtin_schemas(rtim_14_11_oracle_rules(FirstTest, WithTests),
            Injected),
        (
            Injected = injected(Ast),
            load_libraries_in(Libs, Ast ^ af_decls, Imports, LoadErrors0),
            LoadErrors = LoadErrors0
                ++ ldia_2_10_7_imports(yes(Libs), Ast ^ af_decls),
            Scope = imports_resolved(Imports),
            inject_builtin_schemas(
                rcli_1_9_module_oracle_rules(FirstTest, WithTests), Module),
            (
                Module = injected(ModuleAst),
                Rerun = companion_rerun(rcli_1_9_companion_label(
                    rcli_1_9_library_label(Labels, Name)), Ast, ModuleAst,
                    Scope, Program, Responses)
            ;
                Module = injection_failed(_),
                Rerun = no_companion_rules
            ),
            resolve_imported(Ast, Scope, Resolved),
            (
                Resolved = resolve_errors(Errors),
                !:Diagnostics = list.reverse(
                    list.map(in_library(Labels, Name), LoadErrors
                        ++ rcli_1_9_companion_oracle(Rerun, Errors)))
                    ++ !.Diagnostics
            ;
                Resolved = resolve_ok(LibRF0),
                LibRF = (LibRF0 ^ rf_program := Program)
                    ^ rf_program_responses := Responses,
                validate_file(LibRF, Validated),
                (
                    Validated = validate_errors(Errors),
                    !:Diagnostics = list.reverse(
                        list.map(in_library(Labels, Name), LoadErrors
                            ++ rcli_1_9_companion_oracle(Rerun, Errors)))
                        ++ !.Diagnostics
                ;
                    Validated = validate_ok(Warnings),
                    !:Diagnostics = list.reverse(
                        list.map(in_library(Labels, Name), LoadErrors
                            ++ rcli_1_9_companion_oracle(Rerun, Warnings)))
                        ++ !.Diagnostics,
                    !:All = [LibRF | !.All],
                    ( if
                        list.find_first_match(
                            ( pred(D::in) is semidet :-
                                ( D = ad_rule(_)
                                ; D = ad_initial(_)
                                ; D = ad_test(_)
                                ) ),
                            Ast ^ af_decls, _)
                    then
                        !:Modules = [library_module(Name, Clip, LibRF)
                            | !.Modules]
                    else
                        true
                    )
                )
            )
        ;
            Injected = injection_failed(Message),
            !:Diagnostics = [error_at(dv_library_parse_failed, pos(0, 0),
                "library `" ++ Name ++ "`: " ++ Message) | !.Diagnostics]
        )
    else
        % Absent or unparseable: the importer's own load reported both.
        true
    ).

    % A diagnostic already naming a file, a companion's, keeps it.
    %
    %@helper
:- func in_library(source_labels, string, diagnostic) = diagnostic.

in_library(Labels, Name, D) =
    rcli_1_9_in_file(rcli_1_9_library_label(Labels, Name), D).

    % A diagnostic a pass over the whole unit raised, the lowering's or the
    % cross-module cycle check's, with the module it is in: a library's is
    % named as its `DsSource` names it, the importing file's ("") by
    % `--filename`, which the caller supplies.
    %
    %@spec [RCLI.1.9]
:- func rcli_1_9_named_by_module(source_labels, pair(string, diagnostic))
    = diagnostic.

rcli_1_9_named_by_module(Labels, Where - D) =
    ( if Where = "" then D else in_library(Labels, Where, D) ).

    % Every library in the closure is read once, so one declaration reached by
    % two import paths passes.
    %
    %@spec [LCRS.14.9]
:- func lcrs_14_9_duplicate_services(maybe(library_env), source_labels,
                                     resolved_file) = list(diagnostic).

lcrs_14_9_duplicate_services(MaybeLibs, Labels, RF) = list.reverse(RevDs) :-
    (
        MaybeLibs = yes(Libs),
        LibraryDecls = list.condense(list.map(
            ( func(Name - _) = Decls :-
                ( if library_tree(Libs, Name, LibAst) then
                    Decls = list.map(( func(S) = Name - S ),
                        service_decls(LibAst))
                else
                    Decls = []
                )
            ), RF ^ rf_library_modules))
    ;
        MaybeLibs = no,
        LibraryDecls = []
    ),
    FileDecls = list.map(( func(S) = "" - S ), service_decls(RF ^ rf_ast)),
    list.foldl2(lcrs_14_9_declared(Labels), LibraryDecls ++ FileDecls,
        map.init, _, [], RevDs).

    %@helper
:- pred lcrs_14_9_declared(source_labels::in,
                           pair(string, ast_service_decl)::in,
                           map(string, pair(string, pos))::in,
                           map(string, pair(string, pos))::out,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lcrs_14_9_declared(Labels, Where - S, !Seen, !RevDs) :-
    Name = string.join_list(".",
        list.map(( func(Id) = Id ^ id_name ), S ^ asv_name)),
    ( if map.search(!.Seen, Name, FirstWhere - FirstPos) then
        D0 = error_with(dv_duplicate_service, S ^ asv_pos,
            "a second declaration of service `" ++ Name ++ "`: a service "
                ++ "name is unique across the file and every library it "
                ++ "imports, so a call names one handler ([LCRS.14.9])",
            FirstPos, "the first `" ++ Name ++ "`, "
                ++ unit_member(FirstWhere)),
        D1 = with_hint(D0, "remove one declaration, or rename one of the "
            ++ "two services"),
        ( if Where = "" then D = D1 else D = in_library(Labels, Where, D1) ),
        !:RevDs = [D | !.RevDs]
    else
        map.det_insert(Name, Where - S ^ asv_pos, !Seen)
    ).

    %@helper
:- func service_decls(ast_file) = list(ast_service_decl).

service_decls(Ast) = list.filter_map(decl_service, Ast ^ af_decls).

    %@helper
:- func decl_service(ast_decl) = ast_service_decl is semidet.

decl_service(ad_service(S)) = S.

    % Over every rule-bearing library, since a library's rules join whatever the
    % import took. A synthetic name ([LLEX.10.6.1]) is outside the check.
    %
    %@spec [LGRA.6.8]
:- func lgra_6_8_duplicate_rules(source_labels, list(library_module),
                                 resolved_file) = list(diagnostic).

lgra_6_8_duplicate_rules(Labels, Modules, RF) = list.reverse(RevDs) :-
    Decls = list.condense(list.map(
        ( func(M) = list.map(( func(Id) = M ^ lm_name - Id ),
            rule_idents(M ^ lm_resolved ^ rf_ast)) ), Modules))
        ++ list.map(( func(Id) = "" - Id ), rule_idents(RF ^ rf_ast)),
    list.foldl2(lgra_6_8_declared(Labels), Decls, map.init, _, [], RevDs).

    %@helper
:- pred lgra_6_8_declared(source_labels::in, pair(string, ident)::in,
                          map(string, pair(string, pos))::in,
                          map(string, pair(string, pos))::out,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

lgra_6_8_declared(Labels, Where - Id, !Seen, !RevDs) :-
    Name = Id ^ id_name,
    ( if synthetic_name(Name) then
        true
    else if map.search(!.Seen, Name, FirstWhere - FirstPos) then
        D0 = error_with(dv_duplicate_rule, Id ^ id_pos,
            "a second rule named `" ++ Name ++ "`: a rule name is unique "
                ++ "across the file and every library it imports ([LGRA.6.8])",
            FirstPos, "the first `" ++ Name ++ "`, " ++ unit_member(FirstWhere)),
        D1 = with_hint(D0, "rename one of the two rules"),
        ( if Where = "" then D = D1 else D = in_library(Labels, Where, D1) ),
        !:RevDs = [D | !.RevDs]
    else
        map.det_insert(Name, Where - Id ^ id_pos, !Seen)
    ).

    %@helper
:- func unit_member(string) = string.

unit_member(Where) =
    ( if Where = "" then "in this file" else "in library `" ++ Where ++ "`" ).

    %@helper
:- func rule_idents(ast_file) = list(ident).

rule_idents(Ast) = list.filter_map(decl_rule_ident, Ast ^ af_decls).

    %@helper
:- func decl_rule_ident(ast_decl) = ident is semidet.

decl_rule_ident(ad_rule(R)) = R ^ ar_name.

%-----------------------------------------------------------------------------%
% The realtime contract -- [RTCT.4]
%-----------------------------------------------------------------------------%

    %@helper
:- type contract_outcome
    --->    contract_carried(maybe(contract))
    ;       contract_refused(list(diagnostic)).

    %@spec [RTCT.4.2]
    %@spec [RTCT.4.3]
    %@spec [RTCT.4.4]
:- pred rtct_4_2_contract(binding::in, dsrt_input::in, rete_network::in,
                        contract_outcome::out) is det.

rtct_4_2_contract(Binding, Dsrt, Network, Outcome) :-
    Realtime = ( if enabled(Binding ^ bd_program, cap_realtime) then yes
        else no ),
    (
        Dsrt = dsrt_absent,
        (
            Realtime = yes,
            Outcome = contract_refused([error_at(dv_compile_missing_dsrt,
                pos(1, 1), "a `realtime` source needs its contract in a "
                    ++ "sibling `.dsrt`, and there is none ([RTCT.4.2])")])
        ;
            Realtime = no,
            Outcome = contract_carried(no)
        )
    ;
        Dsrt = dsrt_source(Text),
        (
            Realtime = no,
            Outcome = contract_refused([error_at(
                dv_compile_dsrt_without_realtime, pos(1, 1),
                "a `.dsrt` sits beside a source that does not declare "
                    ++ "`realtime`; it would do nothing ([RTCT.4.3])")])
        ;
            Realtime = yes,
            rtct_3_1_parse(Text, Parsed),
            (
                Parsed = contract_errors(Errors),
                Outcome = contract_refused(Errors)
            ;
                Parsed = contract_ok(Contract),
                rtct_4_4_cover(Network, Contract, CoverErrors),
                (
                    CoverErrors = [],
                    Outcome = contract_carried(yes(Contract))
                ;
                    CoverErrors = [_ | _],
                    Outcome = contract_refused(CoverErrors)
                )
            )
        )
    ).

%-----------------------------------------------------------------------------%
% The dialect binding -- [LGRA.3.1], [RBND.1.3]
%-----------------------------------------------------------------------------%

    % The service-dispatch table, sorted by clip then source position ([RDSC.8.4]),
    % since `rf_services` is keyed by name. A service absent from
    % `rf_service_origin` is local. The response is written as the schema's own
    % name, not the spelling: a runtime finds the schema by it ([LCRS.6.2.4]).
    %
    %@spec [LADP.8.2.1]
    %@spec [RDSC.8.4]
:- func ladp_8_2_1_services(resolved_file, uint32) = list(service_entry).

ladp_8_2_1_services(RF, FileClip) = list.sort(
    ( func(A, B) = R :-
        compare(R, {A ^ se_clip, A ^ se_decl ^ asv_pos},
            {B ^ se_clip, B ^ se_decl ^ asv_pos})
    ),
    list.map(
        ( func(Key - Decl) = service_entry(Clip, Named,
                rdsc_6a_2_4_kwargs(RF, Decl)) :-
            ( if
                map.search(RF ^ rf_service_origin, Key, LibName),
                list.index0_of_first_occurrence(
                    list.map((func(N - _) = N), RF ^ rf_library_modules),
                    LibName, Ix)
            then
                Clip = uint32.det_from_int(Ix) + 1u32
            else
                Clip = FileClip
            ),
            ( if
                Decl ^ asv_response = ar_schema(Spelled),
                map.search(RF ^ rf_response_names, Key, Schema)
            then
                Named = Decl ^ asv_response :=
                    ar_schema(Spelled ^ id_name := Schema)
            else
                Named = Decl
            )
        ), map.to_assoc_list(RF ^ rf_services))).

    %@spec [RDSC.14.4.1]
    %@spec [RDSC.14.4.3]
:- func rdsc_14_4_1_rule_docs(uint32, ast_file) = list(doc_entry).

rdsc_14_4_1_rule_docs(FileClip, Ast) = list.filter_map(
    ( func(Decl) = doc_entry(dt_rule, FileClip, "", "",
                             R ^ ar_name ^ id_name, Text, R ^ ar_pos,
                             R ^ ar_origin)
        is semidet :-
        Decl = ad_rule(R),
        R ^ ar_doc = yes(Text)
    ), Ast ^ af_decls).

    %@spec [RDSC.14.2.4]
    %@spec [RDSC.14.2.5]
    %@spec [RDSC.14.2.3]
:- func rdsc_14_2_4_modules(maybe(library_sources), source_labels, string,
                            resolved_file, uint32) = list(module_source).

rdsc_14_2_4_modules(Libraries, Labels, Source, RF, FileClip) = Modules :-
    (
        Libraries = yes(Sources)
    ;
        Libraries = no,
        Sources = map.init
    ),
    list.foldl2(
        ( pred(Module::in, Clip0::in, Clip::out, Acc0::in, Acc::out) is det :-
            Module = Name - _,
            ( if map.search(Sources, Name, Text) then
                Label = rcli_1_9_library_label(Labels, Name),
                Acc = Acc0 ++ [module_source(Clip0, Label, Text)]
            else
                Acc = Acc0
            ),
            Clip = Clip0 + 1u32
        ), RF ^ rf_library_modules, 1u32, _, [], LibraryModules),
    Modules = LibraryModules
        ++ [module_source(FileClip, Labels ^ sl_file, Source)].

    % [RDSC.14.2.3]'s synthetic identifier.
    %
    %@helper
:- func library_label(string) = string.

library_label(Name) = "<in-memory:" ++ Name ++ ".ds>".

    %@helper
:- func in_module(uint32, schema) = schema.

in_module(Clip, S) =
    ( if module_id(Clip, Module) then S ^ s_module := yes(Module) else S ).

    % A token's start position is unique. Runs once, on a compile that failed.
    %
    %@helper
:- func token_end_at(list(positioned), pos) = maybe(pos).

token_end_at([], _) = no.
token_end_at([P | Ps], Pos) =
    ( if P ^ tk_pos = Pos then yes(P ^ tk_end) else token_end_at(Ps, Pos) ).

    %@helper
:- func name_of(ident) = string.

name_of(Id) = Id ^ id_name.

declared_schema_names(Source, Names) :-
    llex_5_4_lex(Source, LexResult),
    ( if
        LexResult = lex_ok(Lines),
        llex_6_2_layout(Lines, LayoutResult),
        LayoutResult = lay_ok(Tokens),
        lgra_3_1_parse(Tokens, ParseResult),
        ParseResult = parse_ok(Cst)
    then
        build_file(Cst, ast_file(_, Decls)),
        Names = list.filter_map(declared_schema_name, Decls)
    else
        Names = []
    ).

    %@helper
:- func declared_schema_name(ast_decl) = string is semidet.

declared_schema_name(ad_schema(S)) = name_of(S ^ as_name).

rcli_1_5_combined_proto(Source, Messages) = Text :-
    declared_schema_names(Source, Names),
    Text = rdsc_5_8_3_proto_header
        ++ "\n"
        ++ string.join_list("\n",
            list.map(rcli_1_5_message_named(Messages), Names)).

    %@helper
:- func rcli_1_5_message_named(assoc_list(string, string), string) = string.

rcli_1_5_message_named(Messages, Name) = Message :-
    ( if assoc_list.search(Messages, Name, Found) then
        Message = Found
    else
        unexpected($pred, "declared schema " ++ Name ++ " has no SchemaDef")
    ).

%-----------------------------------------------------------------------------%
% `dump-schemas --json` -- [RCLI.1.14]
%-----------------------------------------------------------------------------%

rcli_1_14_schemas_json(Libraries, Ambiguous, Source) = Json :-
    ( if
        parse_front(Source, front_ok(Cst, _, _)),
        build_file(Cst, Ast00),
        inject_builtin_schemas(Ast00, injected(Ast0)),
        (
            Libraries = yes(Sources),
            Libs = library_env_on_disk(Sources, Ambiguous, Ast0 ^ af_decls),
            load_libraries_in(Libs, Ast0 ^ af_decls, Imports, _),
            Scope = imports_resolved(Imports)
        ;
            Libraries = no,
            Scope = imports_trusted
        ),
        resolve_imported(limp_3_3_4_rewrite_file(Ast0), Scope,
            resolve_ok(RF))
    then
        Schemas = list.filter_map(author_schema, RF ^ rf_ast ^ af_decls),
        Json = "{\"schemas\":["
            ++ string.join_list(",", list.map(schema_json(RF), Schemas))
            ++ "]}\n"
    else
        unexpected($pred, "a source that compiled does not resolve")
    ).

    % The schemas the input declares, in declaration order ([RCLI.1.5]).
    %
    %@helper
:- func author_schema(ast_decl) = ast_schema is semidet.

author_schema(ad_schema(S)) = S :-
    S ^ as_origin = author_declared.

    %@helper
:- func schema_json(resolved_file, ast_schema) = string.

schema_json(RF, S) =
    "{\"name\":" ++ json_quote(name_of(S ^ as_name))
        ++ ",\"slots\":["
        ++ string.join_list(",", list.map(slot_json(RF), S ^ as_fields))
        ++ "]}".

    % `type` as the source names it, without the `?`.
    %
    %@helper
:- func slot_json(resolved_file, ast_field) = string.

slot_json(RF, Field) =
    "{\"name\":" ++ json_quote(name_of(Field ^ af_name))
        ++ ",\"type\":" ++ json_quote(name_of(Field ^ af_type))
        ++ ",\"nullable\":"
        ++ ( if Field ^ af_nullable = nullable then "true" else "false" )
        ++ ",\"unit\":" ++ unit_json(RF, Field)
        ++ "}".

    % A slot typed by a unit symbol names its unit; one typed by a dimension or
    % a scalar group names none, and holds base-unit values ([LUNI.7.1]). Any
    % other slot's `unit` is `null`.
    %
    %@spec [RCLI.1.14]
:- func unit_json(resolved_file, ast_field) = string.

unit_json(RF, Field) = Json :-
    ( if slot_unit(RF, Field, Kind, Ref) then
        (
            Kind = uk_symbol(Group),
            Declared = json_quote(Ref ^ dr_name),
            unit_symbol_decl(RF, Ref, MaybeLabel, Body),
            Label = maybe_json(MaybeLabel),
            Conversion = conversion_json(RF, Ref, Body)
        ;
            ( Kind = uk_dimension
            ; Kind = uk_scalar
            ),
            Group = Ref,
            Declared = "null",
            Label = "null",
            Conversion = "null"
        ),
        Json = "{\"declared\":" ++ Declared
            ++ ",\"label\":" ++ Label
            ++ ",\"dimension\":" ++ json_quote(Group ^ dr_name)
            ++ ",\"base\":" ++ json_quote(group_base(RF, Group))
            ++ ",\"storage\":" ++ json_quote(group_storage(RF, Group))
            ++ ",\"conversion\":" ++ Conversion
            ++ "}"
    else
        Json = "null"
    ).

    % The slot's unit entry, its type as the declaring file resolved it. A slot
    % type is a canonical unit name, never an alias ([LUNI.7.5]), so the
    % entry's symbol is the one `declared` names.
    %
    %@helper
:- pred slot_unit(resolved_file::in, ast_field::in, unit_kind::out,
                  decl_ref::out) is semidet.

slot_unit(RF, Field, Kind, Ref) :-
    slot_entry(RF, Field, te_unit(Kind, Ref)).

    % [LUNI.2.7.1]'s baked line for a base or tier-1 unit, each constant as the
    % Float's canonical text ([LDET.3.2.7]); a tier-2 unit carries none.
    %
    %@spec [RCLI.1.14]
:- func conversion_json(resolved_file, decl_ref, ast_unit_body) = string.

conversion_json(RF, Ref, Body) = Json :-
    ( if Body = aub_tier2(_, _, _) then
        Json = "{\"kind\":\"tier2\"}"
    else if rcli_1_14_baked_line(RF, Ref, A, B) then
        Json = "{\"kind\":\"affine\",\"a\":" ++ ds.float_text.canonical(A)
            ++ ",\"b\":" ++ ds.float_text.canonical(B) ++ "}"
    else
        unexpected($pred, "unit " ++ Ref ^ dr_name ++ " has no baked line")
    ).

    %@helper
:- func maybe_json(maybe(string)) = string.

maybe_json(no) = "null".
maybe_json(yes(S)) = json_quote(S).

    % A unit symbol's label and body, from its declaration.
    %
    %@helper
:- pred unit_symbol_decl(resolved_file::in, decl_ref::in, maybe(string)::out,
                         ast_unit_body::out) is det.

unit_symbol_decl(RF, Ref, Label, Body) :-
    ( if
        list.find_first_match(
            ( pred(U::in) is semidet :-
                U = au_symbol(Id, _, _, _, _, _, File, _),
                decl_ref(File, Id ^ id_name) = Ref
            ), RF ^ rf_units, Found),
        Found = au_symbol(_, _, Body0, Label0, _, _, _, _)
    then
        Label = Label0,
        Body = Body0
    else
        unexpected($pred, "unit " ++ Ref ^ dr_name ++ " is not declared")
    ).

    % A dimension's base is the symbol it declares; a scalar group's is the
    % unit of the group with no body ([LUNI.4.3]). Either as its canonical
    % symbol.
    %
    %@helper
:- func group_base(resolved_file, decl_ref) = string.

group_base(RF, Group) = Base :-
    ( if
        list.find_first_match(
            ( pred(U::in) is semidet :-
                U = au_dimension(Name, _, _, _, File),
                decl_ref(File, Name ^ id_name) = Group
            ), RF ^ rf_units, Dimension),
        Dimension = au_dimension(_, _, Written, _, _)
    then
        ( if map.search(RF ^ rf_unit_alias, Written ^ id_name, Canonical) then
            Base = Canonical ^ id_name
        else
            Base = Written ^ id_name
        )
    else if
        list.find_first_match(
            ( pred(U::in) is semidet :-
                U = au_symbol(_, _, aub_base, _, _, _, _, Group)
            ), RF ^ rf_units, Symbol),
        Symbol = au_symbol(Id, _, _, _, _, _, _, _)
    then
        Base = Id ^ id_name
    else
        unexpected($pred, Group ^ dr_name ++ " has no base unit")
    ).

    %@helper
:- func group_storage(resolved_file, decl_ref) = string.

group_storage(RF, Group) = Storage :-
    ( if map.search(RF ^ rf_unit_storage, Group, Found) then
        Storage = Found
    else
        unexpected($pred, Group ^ dr_name ++ " has no storage")
    ).

%-----------------------------------------------------------------------------%
% A rule the lowering could not build
%-----------------------------------------------------------------------------%

    % One `DS_VALIDATE_RULE_NOT_LOWERED` per skip, in its module. A declaration
    % is consulted only for the rule's name, so a skip with none still refuses.
    %
    %@helper
:- func rules_not_lowered(source_labels, ast_file, list(library_module),
                          list(rule_skip)) = list(diagnostic).

rules_not_lowered(Labels, Ast, Modules, Skips) =
    list.map(rule_not_lowered(Labels, Ast, Modules), Skips).

    %@helper
:- func rule_not_lowered(source_labels, ast_file, list(library_module),
                         rule_skip) = diagnostic.

rule_not_lowered(Labels, Ast, Modules, S) = D :-
    ( if
        list.find_first_match(
            ( pred(M0::in) is semidet :- M0 ^ lm_clip = S ^ rsk_clip ),
            Modules, M)
    then
        D = in_library(Labels, M ^ lm_name,
            not_lowered_at(M ^ lm_resolved ^ rf_ast, S))
    else
        D = not_lowered_at(Ast, S)
    ).

    % A lowered `Expr` carries no position, so the site is the node's span, and
    % a node with none is reported at the file's start.
    %
    %@spec [RDSC.11.3]
:- func rdsc_11_3_expression_too_deep(source_labels, list(library_module),
                                      rdsc_11_3_too_deep) = diagnostic.

rdsc_11_3_expression_too_deep(Labels, Modules,
        rdsc_11_3_too_deep(Site, Depth)) = D :-
    Message = "an expression here lowers to an `Expr` nested "
        ++ string.int_to_string(Depth)
        ++ " deep, past the 48 a `.dsc` admits (the outermost at 0)",
    (
        Site = yes(Clip - Pos),
        Here = error_at(dv_expression_too_deep, Pos, Message),
        ( if
            list.find_first_match(
                ( pred(M0::in) is semidet :- M0 ^ lm_clip = Clip ),
                Modules, M)
        then
            D = in_library(Labels, M ^ lm_name, Here)
        else
            D = Here
        )
    ;
        Site = no,
        D = error_at(dv_expression_too_deep, pos(0, 0), Message)
    ).

    %@spec [LGRA.8.7]
    %@spec [LGRA.5.11]
:- func lgra_8_7_too_wide(source_labels, list(library_module), index_overflow)
    = diagnostic.

lgra_8_7_too_wide(Labels, Modules, Overflow) = D :-
    (
        Overflow = too_many_patterns(Site, Name, Count),
        Code = dv_rule_too_many_patterns,
        Message = "rule `" ++ Name ++ "` is built with "
            ++ string.int_to_string(Count)
            ++ " patterns, past the 255 a rule may have ([LGRA.8.7])"
    ;
        Overflow = too_many_slots(Site, Name, Count),
        Code = dv_schema_too_many_slots,
        Message = "the compiler declares schema `" ++ Name ++ "` with "
            ++ string.int_to_string(Count)
            ++ " slots for this rule, past the 255 a schema may hold "
            ++ "([LGRA.5.11])"
    ),
    (
        Site = yes(Clip - Pos),
        Here = error_at(Code, Pos, Message),
        ( if
            list.find_first_match(
                ( pred(M0::in) is semidet :- M0 ^ lm_clip = Clip ),
                Modules, M)
        then
            D = in_library(Labels, M ^ lm_name, Here)
        else
            D = Here
        )
    ;
        Site = no,
        D = error_at(Code, pos(0, 0), Message)
    ).

    %@helper
:- func not_lowered_at(ast_file, rule_skip) = diagnostic.

not_lowered_at(Ast, S) =
    error_at(dv_rule_not_lowered, S ^ rsk_pos,
        rule_named_at(Ast, S ^ rsk_pos) ++ " cannot be lowered: "
            ++ S ^ rsk_why).

    %@helper
:- func rule_named_at(ast_file, pos) = string.

rule_named_at(Ast, Pos) = Name :-
    ( if
        list.find_first_match(
            ( pred(Decl0::in) is semidet :-
                Decl0 = ad_rule(R0),
                R0 ^ ar_pos = Pos
            ), Ast ^ af_decls, Decl),
        Decl = ad_rule(R)
    then
        Name = "rule `" ++ R ^ ar_name ^ id_name ++ "`"
    else
        Name = "a rule"
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.driver.
%-----------------------------------------------------------------------------%

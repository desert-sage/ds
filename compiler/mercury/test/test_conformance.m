% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% test_conformance -- the language's own corpus, run against this compiler.
%
% `specs/conformance/compiler/*.json`: each fixture a DS source and an
% expected outcome, named by the clause it pins. It runs in the `compiler`
% gate, against the compiler built from the branch under test.
%
% Every name in the index must open and parse, and every fixture must pass or
% be deprecated, or the run fails. Every outcome but `pass` and `deprecated`
% is a failure.
%-----------------------------------------------------------------------------%

:- module test_conformance.
:- interface.

:- import_module ds.
:- import_module ds.json.
:- import_module dsc.
:- import_module dsc.dialect.
:- import_module dsc.imports.

:- import_module io.
:- import_module list.
:- import_module maybe.

    % (passed, failed) over the gate's checks. The corpus census is printed.
    %
:- pred run(int::out, int::out, io::di, io::uo) is det.

    % The built-in registry plus every staged harness dialect file, and why
    % each file that did not register did not. `test_behave` compiles its
    % corpus against the same registry; this module's gate reports the errors.
    %
:- pred harness_registry(registry::out, list(string)::out,
                         io::di, io::uo) is det.

    % The standard library the repository ships, each module keyed by the
    % dotted name that imports it (`units/si.ds` is `units.si`), read once per
    % run from `DSC_STDLIB`, the clone's `stdlib/` ([RCTS.1.2.14]). Every
    % fixture resolves against it after its own `libraries`. Unset or
    % unreadable, there is none, and the run fails (`stdlib_is_read`).
    %
:- type stdlib.

:- pred read_stdlib(stdlib::out, io::di, io::uo) is det.

    % Whether `read_stdlib` found a standard library. A run without one fails
    % ([RCTS.1.2.14]: "must fail its run, not the fixture"): both suites check
    % it before they judge a fixture.
    %
:- pred stdlib_is_read(stdlib::in) is semidet.

    % The modules `read_stdlib` found, keyed by the dotted name that imports
    % each; empty when it found none, which `stdlib_is_read` reports.
    % `test_lower` compiles the runtime's fixtures against it.
    %
:- func stdlib_sources(stdlib) = library_sources.

    % A fixture checked against the format before anything is compiled
    % ([RCTS.1.2.15]): well formed, with the libraries it compiles against, or
    % malformed under a named clause of [RCTS.1.2], and why.
    %
:- type fixture_format
    --->    well_formed(maybe(library_sources))
    ;       malformed(
                mf_clause :: string,    % "RCTS.1.2.14"
                mf_why    :: string
            ).

    % The format check both suites run on every fixture that is not
    % deprecated, before they compile it:
    %
    %   * [RCTS.1.2.1]: no object in it, at any depth, repeats a member name.
    %     `Repeats` is every repeat `rcts_1_2_1_parse_corpus_json` reported,
    %     since the term keeps only the last value. Checked first, as
    %     `runner.py`'s `_format_refusal` checks it;
    %   * [RCTS.1.2.1]: one JSON object, carrying `id`, `category`, `scenario`,
    %     `rules_ds` and an `expect` object;
    %   * [RCTS.1.2.7]: an `expect.kind`, a string, since a harness must fail
    %     a fixture whose kind it does not evaluate;
    %   * [RCTS.1.2.15]: a `malformed_fixture` carries `expect.reason`, a string;
    %   * [RCTS.1.2.13], [RCTS.1.2.14]: the libraries it compiles against -- its
    %     own `libraries`, then the standard library. A name both supply is
    %     malformed, and so is a `stdlib` key, whatever its value.
    %
    % A kind-specific field a kind needs and lacks is the kind's own check,
    % made where the kind is judged.
    %
:- pred rcts_fixture_format(stdlib::in, list(string)::in, json::in,
                            fixture_format::out) is det.

    % `malformed(Clause, Why)` as one line, the clause first in brackets, as
    % each suite prints a refusal.
    %
:- func malformed_text(fixture_format) = string.

    % [RCTS.1.2.3]: why a fixture read from the directory `Dir` is malformed,
    % or `no`: `Dir` is no category of [RCTS.1.1.4], or the fixture's
    % `category` is not `Dir`. `runner.py`'s `_rcts_1_2_3_malformed` refuses
    % the same, with the same text.
    %
:- func rcts_1_2_3_refusal(string, json) = maybe(string).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.atom.
:- import_module ds.json_text.
:- import_module ds.sha256.
:- import_module ds.wire.

:- import_module dsc.cli.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.driver.
:- import_module dsc.encode.
:- import_module dsc.json.
:- import_module dsc.token.
:- import_module dsc.yaml.

:- import_module field_order_walk.

:- import_module assoc_list.
:- import_module bitmap.
:- import_module bool.
:- import_module char.
:- import_module dir.
:- import_module int.
:- import_module int64.
:- import_module map.
:- import_module pair.
:- import_module string.
:- import_module uint32.
:- import_module uint8.

%-----------------------------------------------------------------------------%

:- type outcome
    --->    oc_pass
            % The fixture's expectation was met: `compile_ok` and we compiled,
            % or `compile_error` and we raised its code.

    ;       oc_deprecated
            % [RCTS.1.2.12]: deprecated. Recorded, not run.

    ;       oc_stopped
            % `lex` / `layout` / `parse` refused it.

    ;       oc_rejected
            % `resolve` / `validate` / `lower` refused a fixture expecting
            % `compile_ok`.

    ;       oc_wrong_code
            % Refused, but not with the code the fixture names.

    ;       oc_wrong_line
            % Refused with the code the fixture names, but not on its
            % `expected_line` ([RCTS.1.2.34]): the same code, raised somewhere
            % other than the construct the fixture is about.

    ;       oc_accepted
            % Compiled a fixture expecting an error -- a check we do not have.

    ;       oc_wrong_artefact
            % Compiled, and the artefact fails the fixture's assertion over it:
            % a TerminalNode sequence, a reserved field, an equivalence.

    ;       oc_unknown_kind.
            % An `expect.kind` this harness has no driver for: a failure
            % ([RCTS.1.2.7]).

    % One fixture's result, with what it wanted. Not named `result`, which
    % is `io.result`: Mercury reports that collision at every use.
    %
:- type fixture_result
    --->    fixture_result(
                r_outcome :: outcome,
                r_kind    :: string,
                r_code    :: string,   % "" when the fixture names none
                r_got     :: list(string),
                    % What the compiler reported, so a `rejected` row names the
                    % check that refused it.
                r_unlowered :: list(string)
                    % The `DS_VALIDATE_RULE_NOT_LOWERED` messages, apart from
                    % the other codes.
            ).

:- func outcome_name(outcome) = string.

outcome_name(oc_pass) = "pass".
outcome_name(oc_deprecated) = "deprecated".
outcome_name(oc_stopped) = "stopped".
outcome_name(oc_rejected) = "rejected".
outcome_name(oc_wrong_code) = "wrong-code".
outcome_name(oc_wrong_line) = "wrong-line".
outcome_name(oc_accepted) = "accepted".
outcome_name(oc_wrong_artefact) = "wrong-artefact".
outcome_name(oc_unknown_kind) = "unknown-kind".

%-----------------------------------------------------------------------------%

:- type tally
    --->    tally(t_pass :: int, t_fail :: int).

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

%-----------------------------------------------------------------------------%

run(Pass, Fail, !IO) :-
    io.read_named_file_as_string("conformance-index.txt", IndexRes, !IO),
    (
        IndexRes = error(_),
        check("conformance-index.txt is present and readable", no,
            tally(0, 0), T, !IO),
        Pass = T ^ t_pass,
        Fail = T ^ t_fail
    ;
        IndexRes = ok(IndexText),
        Names = list.filter(non_empty,
            list.map(string.strip, string.split_at_char('\n', IndexText))),
        harness_registry(Registry, DialectErrors, !IO),
        read_stdlib(Stdlib, !IO),
        read_field_order_table(FoTable, !IO),
        list.map_foldl(run_fixture(Registry, Stdlib, FoTable), Names, Results,
            !IO),
        % [RCTS.1.2.14]: no standard library fails the run, not each fixture.
        check("RCTS.1.2.14:the standard library is read (DSC_STDLIB)",
            ( if stdlib_is_read(Stdlib) then yes else no ),
            tally(0, 0), Ts, !IO),
        artefact_self_test(Ts, Ta, !IO),
        format_self_test(Ta, Tb, !IO),
        expected_line_self_test(Registry, Stdlib, FoTable, Tb, Tc, !IO),
        also_raises_self_test(Registry, Stdlib, FoTable, Tc, Td, !IO),
        test_cases_self_test(Registry, Td, T0, !IO),
        list.foldl(report_dialect_error, DialectErrors, !IO),
        check("the harness dialects are staged and register",
            ( if DialectErrors = [] then yes else no ), T0, T1, !IO),
        report(Names, Results, T1, T, !IO),
        Pass = T ^ t_pass,
        Fail = T ^ t_fail
    ).

%-----------------------------------------------------------------------------%
% The harness's dialects
%-----------------------------------------------------------------------------%
%
% `restricted_v1` is the harness's dialect, not the language's ([LDIA.9]
% names the built-ins): YAML in `specs/conformance/harness/dialects/`,
% registered as an integrator registers one with `dsc compile -d`
% ([NDLC.2.1]). A file that does not register fails the gate.

harness_registry(Registry, Errors, !IO) :-
    io.read_named_file_as_string("dialects-index.txt", Res, !IO),
    (
        Res = error(_),
        Registry = builtin_registry,
        Errors = ["dialects-index.txt is absent; the harness dialects were "
            ++ "not staged"]
    ;
        Res = ok(Text),
        Names = list.filter(non_empty,
            list.map(string.strip, string.split_at_char('\n', Text))),
        list.foldl3(register_dialect_file, Names, builtin_registry, Registry,
            [], RevErrors, !IO),
        ( if Names = [] then
            Errors = ["dialects-index.txt names no dialect file"]
        else
            Errors = list.reverse(RevErrors)
        )
    ).

:- pred register_dialect_file(string::in, registry::in, registry::out,
                              list(string)::in, list(string)::out,
                              io::di, io::uo) is det.

register_dialect_file(Name, !Registry, !Errors, !IO) :-
    io.read_named_file_as_string("dialects/" ++ Name, Res, !IO),
    (
        Res = error(Error),
        !:Errors = [Name ++ ": " ++ io.error_message(Error) | !.Errors]
    ;
        Res = ok(Text),
        read_mapping(Text, Read),
        (
            Read = yaml_error(Line, Why),
            !:Errors = [string.format("%s, line %d: %s",
                [s(Name), i(Line), s(Why)]) | !.Errors]
        ;
            Read = yaml_ok(Entries),
            ndlc_2_1_definition(Entries, Defined),
            (
                Defined = definition_refused(Why),
                !:Errors = [Name ++ ": " ++ Why | !.Errors]
            ;
                Defined = definition(Def),
                ndlc_2_2_register(Def, !.Registry, Registered),
                (
                    Registered = registered(Grown),
                    !:Registry = Grown
                ;
                    Registered = registration_refused(Code, Why),
                    !:Errors = [Name ++ ": " ++ ds_validate_name(Code) ++ ": "
                        ++ Why | !.Errors]
                )
            )
        )
    ).

:- pred report_dialect_error(string::in, io::di, io::uo) is det.

report_dialect_error(Why, !IO) :-
    io.format("    harness dialect: %s\n", [s(Why)], !IO).

    % A fixture's compile: against the harness's registry, as though it began
    % with `use default` unless it says `compile_as_written` ([LDIA.2.10.1]),
    % and with nothing beside it for
    % [RTCT.4.1]'s lookup to find.
    %
:- pred fixture_compile(registry::in, program_mode::in,
                        maybe(library_sources)::in, string::in,
                        compile_result::out) is det.

fixture_compile(Registry, Mode, Libraries, Source, Compiled) :-
    compile_labelled_in(Registry, Mode, Libraries, dsrt_absent,
        in_memory_labels, Source, Compiled).

:- func fixture_mode(json) = program_mode.

fixture_mode(Fixture) =
    ( if
        Fixture = j_object(Members),
        lookup_member(Members, "compile_as_written", Found),
        Found = j_bool(yes)
    then
        as_written
    else
        as_though("default")
    ).

    % [RCTS.1.2.1]'s repeat refusal, shown able to fail and shown to come
    % first: the cases `test_conformance.py`'s
    % `test_a_repeated_member_is_refused_under_rcts_1_2_1` runs on `runner.py`.
    % The vectors `compiler/RCTS.1.2.1_repeated_member_refused` and
    % `logical/RCTS.1.2.1_repeated_reason_refused` drive the two suites'
    % `run_fixture` through it.
    % @spec [RCTS.1.2.1]
    %
:- pred format_self_test(tally::in, tally::out, io::di, io::uo) is det.

format_self_test(!T, !IO) :-
    Head = "{\"id\": \"X\", \"category\": \"compiler\", \"scenario\": \"\", "
        ++ "\"rules_ds\": \"\", ",
    Good = Head ++ "\"expect\": {\"kind\": \"compile_ok\"}",
    Refused = ( pred(Text::in, Name::in) is semidet :-
        format_of(Text) = malformed("RCTS.1.2.1", Why),
        string.sub_string_search(Why, "`" ++ Name ++ "`", _)
    ),
    Nested = Good ++ ", \"libraries\": {\"a\": \"\", \"a\": \"\"}}",
    check("RCTS.1.2.1:a nested repeat whose values agree is refused, named",
        ( if Refused(Nested, "a") then yes else no ), !T, !IO),
    check("RCTS.1.2.1:so is one in an array's object",
        ( if Refused(Good ++ ", \"x\": [{\"b\": 1, \"b\": 2}]}", "b")
          then yes else no ), !T, !IO),
    % Without the repeat check first, `expect.kind` is [RCTS.1.2.7]'s.
    check("RCTS.1.2.1:a repeat is refused before any other check",
        ( if
            Refused(Head ++ "\"expect\": {\"kind\": 1}, "
                ++ "\"stdlib\": false, \"stdlib\": false}", "stdlib")
          then yes else no ), !T, !IO),
    check("RCTS.1.2.1:one name in two objects is no repeat",
        ( if
            format_of(Good ++ ", \"libraries\": {\"a\": \"\"}, "
                ++ "\"x\": {\"a\": \"\"}}") = well_formed(_)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.1:a malformed_fixture naming it passes on a repeat",
        ( if
            malformed_fixture_result("RCTS.1.2.1", format_of(Nested))
                ^ r_outcome = oc_pass
          then yes else no ), !T, !IO),
    check("RCTS.1.2.1:and is accepted, so fails, without one",
        ( if
            malformed_fixture_result("RCTS.1.2.1", format_of(Good ++ "}"))
                ^ r_outcome = oc_accepted
          then yes else no ), !T, !IO),
    % [RCTS.1.2.14]: the cases `test_conformance.py`'s
    % `test_rcts_1_2_14__*` run on `runner.py`. The standard library here is
    % one module, `units.core`, so the checks read no directory.
    Std = stdlib(yes(map.singleton("units.core", ""))),
    Fourteen = ( pred(Text::in) is semidet :-
        rcts_1_2_1_parse_corpus_json(Text, json_ok(F), []),
        rcts_fixture_format(Std, [], F, malformed("RCTS.1.2.14", _))
    ),
    check("RCTS.1.2.14:a fixture carrying `stdlib`, whatever its value, "
            ++ "is malformed",
        ( if
            Fourteen(Good ++ ", \"stdlib\": true}"),
            Fourteen(Good ++ ", \"stdlib\": false}"),
            Fourteen(Good ++ ", \"stdlib\": null}")
          then yes else no ), !T, !IO),
    check("RCTS.1.2.14:a library the standard library supplies is malformed",
        ( if Fourteen(Good ++ ", \"libraries\": {\"units.core\": \"\"}}")
          then yes else no ), !T, !IO),
    check("RCTS.1.2.14:and any other library is well formed, beside it",
        ( if
            rcts_1_2_1_parse_corpus_json(
                Good ++ ", \"libraries\": {\"widgets\": \"\"}}",
                json_ok(W), []),
            rcts_fixture_format(Std, [], W, well_formed(yes(Libs))),
            map.contains(Libs, "widgets"),
            map.contains(Libs, "units.core")
          then yes else no ), !T, !IO),
    % [RCTS.1.2.35]: the category refusal `test_conformance.py`'s
    % `test_rcts_1_2_35__*` runs on `runner.py`, and the refusals of the
    % field's form and of a program with no `use` line, which only this
    % harness makes: only it judges a `compiler` fixture.
    Compiler = ( func(Kind, Rules, Extra) =
        "{\"id\": \"X\", \"category\": \"compiler\", \"scenario\": \"\", "
        ++ "\"rules_ds\": \"" ++ Rules ++ "\", \"expect\": {\"kind\": \""
        ++ Kind ++ "\""
        ++ ( if Kind = "dsc_test_cases" then ", \"test_cases\": []" else "" )
        ++ "}" ++ Extra ++ "}" ),
    Files = ( func(J) = ", \"files\": " ++ J ),
    Use = "use default\\n",
    ThirtyFive = ( pred(Text::in) is semidet :-
        format_of(Text) = malformed("RCTS.1.2.35", _)
    ),
    check("RCTS.1.2.35:`files` on another category is malformed, naming it",
        ( if
            format_of("{\"id\": \"X\", \"category\": \"logical\", "
                ++ "\"scenario\": \"\", \"rules_ds\": \"\", \"expect\": "
                ++ "{\"kind\": \"rule_fire_order\"}, \"files\": {}}")
                = malformed("RCTS.1.2.35", Other),
            string.sub_string_search(Other, "`logical`", _)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.35:and on a kind that does not read it",
        ( if ThirtyFive(Compiler("dsc_term_order", Use, Files("{}")))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.35:as is a `files` that is not an object of strings",
        ( if
            ThirtyFive(Compiler("compile_ok", Use, Files("[]"))),
            ThirtyFive(Compiler("compile_ok", Use, Files("\"main.dstest\""))),
            ThirtyFive(Compiler("compile_ok", Use,
                Files("{\"main.dstest\": 1}")))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.35:or that names a path in another form",
        ( if
            list.all_true(
                ( pred(P::in) is semidet :-
                    ThirtyFive(Compiler("compile_ok", Use,
                        Files("{\"" ++ P ++ "\": \"\"}")))
                ),
                ["../main.dstest", "main.ds", "lib//a.dstest", "1a.dstest",
                 "a.b.dstest", ".dstest", "lib/.dstest", "/main.dstest",
                 "main.dstest/"])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.35:a fixture compiled from files with no `use` line is "
            ++ "malformed: one carrying `files`, and `dsc_test_cases`",
        ( if
            ThirtyFive(Compiler("compile_ok", "", Files("{}"))),
            ThirtyFive(Compiler("compile_ok", "used = 1\\n", Files("{}"))),
            ThirtyFive(Compiler("dsc_test_cases", "", ""))
          then yes else no ), !T, !IO),
    % The controls: the form in full is well formed, a `use` line need not be
    % the first, and a fixture compiled in memory needs none.
    check("RCTS.1.2.35:and each well-formed one is well formed",
        ( if
            format_of(Compiler("compile_ok", Use, Files("{\"main.dstest\": "
                ++ "\"\", \"lib/a.dstest\": \"\", \"lib/a/b_2.dstest\": "
                ++ "\"\"}"))) = well_formed(_),
            format_of(Compiler("compile_error", "\\n# x\\n" ++ Use,
                Files("{}"))) = well_formed(_),
            format_of(Compiler("dsc_test_cases", Use, "")) = well_formed(_),
            format_of(Compiler("compile_ok", "", "")) = well_formed(_)
          then yes else no ), !T, !IO).

    % [RCTS.1.2.34]'s `expected_line`, shown able to fail. The program stops
    % in the front end on its fifth line, a `where` that ends in `>`; the
    % self-test reads the code and line it is refused with off the compile
    % rather than spelling them, so it holds the comparison and not this
    % parser's wording or column. Then a fixture naming that line passes, one
    % naming a line 100 further on is `wrong-line`, and a value that is not a
    % positive integer, or the field on `compile_ok`, makes the fixture
    % malformed (`classify` fails).
    % @spec [RCTS.1.2.34]
    %
:- pred expected_line_self_test(registry::in, stdlib::in, maybe(fo_table)::in,
    tally::in, tally::out, io::di, io::uo) is det.

expected_line_self_test(Registry, Stdlib, FoTable, !T, !IO) :-
    Source = "schema T scope logical:\n    v: Int key\n\nrule r:\n"
        ++ "    T t where t.v >\n->\n    emit T logical v: 1\n",
    fixture_compile(Registry, as_though("default"), yes(map.init), Source,
        Compiled),
    ( if
        ( Compiled = compile_stopped(Front, _, _, _),
            Code = ds_front_name(Front)
        ; Compiled = compile_rejected([D | _]),
            Code = code_name(D ^ dg_code)
        ),
        refusal_lines(Compiled, Code) = [Line | _]
    then
        Fixture = ( func(Kind, Extra) = Text :-
            Text = "{\"id\": \"X\", \"category\": \"compiler\", "
                ++ "\"scenario\": \"\", \"rules_ds\": \""
                ++ string.replace_all(Source, "\n", "\\n")
                ++ "\", \"expect\": {\"kind\": \"" ++ Kind ++ "\", "
                ++ "\"code\": \"" ++ Code ++ "\"" ++ Extra ++ "}}" ),
        Outcome = ( func(Text) = O :-
            rcts_1_2_1_parse_corpus_json(Text, Parsed, Repeats),
            ( if
                Parsed = json_ok(J),
                classify(Registry, Stdlib, FoTable, Repeats, J, no, R)
            then
                O = yes(R ^ r_outcome)
            else
                O = no
            ) ),
        At = ( func(N) = ", \"expected_line\": " ++ string.int_to_string(N) ),
        check("RCTS.1.2.34:the line the refusal begins on passes",
            ( if Outcome(Fixture("compile_error", At(Line))) = yes(oc_pass)
              then yes else no ), !T, !IO),
        check("RCTS.1.2.34:another line is wrong-line",
            ( if Outcome(Fixture("compile_error", At(Line + 100)))
                    = yes(oc_wrong_line)
              then yes else no ), !T, !IO),
        % Without the field: malformed when the code is the catch-all parse
        % code, and judged on the code alone otherwise.
        check("RCTS.1.2.34:no expected_line: malformed for DS_PARSE_GENERIC, "
                ++ "the code alone for any other",
            ( if
                Outcome(Fixture("compile_error", "")) =
                    ( if Code = "DS_PARSE_GENERIC" then no else yes(oc_pass) ),
                FixtureCode = ( func(C) =
                    "{\"id\": \"X\", \"category\": \"compiler\", "
                        ++ "\"scenario\": \"\", \"rules_ds\": \""
                        ++ string.replace_all(Source, "\n", "\\n")
                        ++ "\", \"expect\": {\"kind\": \"compile_error\", "
                        ++ "\"code\": \"" ++ C ++ "\"}}" ),
                Outcome(FixtureCode("DS_PARSE_GENERIC")) = no,
                Outcome(FixtureCode("DS_VALIDATE_UNKNOWN_SCHEMA")) = yes(_)
              then yes else no ), !T, !IO),
        check("RCTS.1.2.34:a value that is not a positive integer is malformed",
            ( if
                Outcome(Fixture("compile_error", At(0))) = no,
                Outcome(Fixture("compile_error", At(-1))) = no,
                Outcome(Fixture("compile_error",
                    ", \"expected_line\": \"5\"")) = no,
                Outcome(Fixture("compile_error",
                    ", \"expected_line\": 5.5")) = no
              then yes else no ), !T, !IO),
        % Its control: the same `compile_ok` fixture without the field is
        % judged, so the refusal above is the field's.
        check("RCTS.1.2.34:the field on another kind is malformed",
            ( if
                Outcome(Fixture("compile_ok", At(Line))) = no,
                Outcome(Fixture("compile_ok", "")) = yes(_)
              then yes else no ), !T, !IO)
    else
        check("RCTS.1.2.34:the self-test's program is refused, at a line",
            no, !T, !IO)
    ).

    % [RCTS.1.2.36]'s exact set of codes, shown able to fail. The program raises
    % two error codes for one interpolated `cache` key, read off the compile.
    % @spec [RCTS.1.2.36]
    %
:- pred also_raises_self_test(registry::in, stdlib::in, maybe(fo_table)::in,
    tally::in, tally::out, io::di, io::uo) is det.

also_raises_self_test(Registry, Stdlib, FoTable, !T, !IO) :-
    Source = "schema Src scope logical:\n    id: String key\n\nrule r:\n"
        ++ "    Src s\n->\n    cache key: \"k.{s.id}\" value: 1\n",
    fixture_compile(Registry, as_though("default"), yes(map.init), Source,
        Compiled),
    ( if
        Compiled = compile_rejected(Diagnostics),
        error_codes(Diagnostics) = [A, B]
    then
        Fixture = ( func(Kind, Extra) =
            "{\"id\": \"X\", \"category\": \"compiler\", "
                ++ "\"scenario\": \"\", \"rules_ds\": \""
                ++ string.replace_all(string.replace_all(Source,
                    "\"", "\\\""), "\n", "\\n")
                ++ "\", \"expect\": {\"kind\": \"" ++ Kind ++ "\", "
                ++ "\"code\": \"" ++ A ++ "\"" ++ Extra ++ "}}" ),
        Outcome = ( func(Text) = O :-
            rcts_1_2_1_parse_corpus_json(Text, Parsed, Repeats),
            ( if
                Parsed = json_ok(J),
                classify(Registry, Stdlib, FoTable, Repeats, J, no, R)
            then
                O = yes(R ^ r_outcome)
            else
                O = no
            ) ),
        Also = ( func(Codes) = ", \"also_raises\": [" ++
            string.join_list(", ", list.map(
                func(C) = "\"" ++ C ++ "\"", Codes)) ++ "]" ),
        check("RCTS.1.2.36:every code named passes",
            ( if Outcome(Fixture("compile_error", Also([B]))) = yes(oc_pass)
              then yes else no ), !T, !IO),
        check("RCTS.1.2.36:a code raised and not named is wrong-code",
            ( if Outcome(Fixture("compile_error", "")) = yes(oc_wrong_code)
              then yes else no ), !T, !IO),
        check("RCTS.1.2.36:a code named and not raised is wrong-code",
            ( if
                Outcome(Fixture("compile_error",
                    Also([B, "DS_VALIDATE_RULE_CYCLE"]))) = yes(oc_wrong_code)
              then yes else no ), !T, !IO),
        check("RCTS.1.2.36:a value that is not such a list is malformed",
            ( if
                Outcome(Fixture("compile_error", Also([]))) = no,
                Outcome(Fixture("compile_error", Also([B, B]))) = no,
                Outcome(Fixture("compile_error", Also([A, B]))) = no,
                Outcome(Fixture("compile_error",
                    ", \"also_raises\": \"" ++ B ++ "\"")) = no,
                Outcome(Fixture("compile_error",
                    ", \"also_raises\": [1]")) = no
              then yes else no ), !T, !IO),
        check("RCTS.1.2.36:the field on another kind is malformed",
            ( if
                Outcome(Fixture("compile_ok", Also([B]))) = no,
                Outcome(Fixture("compile_ok", "")) = yes(_)
              then yes else no ), !T, !IO)
    else
        check("RCTS.1.2.36:the self-test's program raises two error codes",
            no, !T, !IO)
    ).

    % A fixture's text through the format check, as `run_fixture` reads it.
    %
:- func format_of(string) = fixture_format.

format_of(Text) = Format :-
    rcts_1_2_1_parse_corpus_json(Text, Parsed, Repeats),
    (
        Parsed = json_ok(Fixture),
        rcts_fixture_format(stdlib(no), Repeats, Fixture, Format)
    ;
        Parsed = json_error(Why, _),
        Format = malformed("", "does not parse: " ++ Why)
    ).

    % The artefact assertions, shown able to fail: one case per way each can
    % refuse, and the expectation checks that make a fixture with nothing to
    % assert malformed.
    %
:- pred artefact_self_test(tally::in, tally::out, io::di, io::uo) is det.

artefact_self_test(!T, !IO) :-
    Two = "schema Trig scope logical:\n    v: Int key\n\n"
        ++ "rule zebra:\n    Trig\n->\n    log info \"zebra\"\n\n"
        ++ "rule alpha:\n    Trig\n->\n    log info \"alpha\"\n",
    compile_with(as_though("default"), no, Two, TwoCompiled),

    check("[dsc_term_order] the source order passes",
        term_order_is(oc_pass,
            "{\"expected_terminal_order\": [\"zebra\", \"alpha\"], "
                ++ "\"forbidden_term_fields\": [9]}", TwoCompiled),
        !T, !IO),
    check("[dsc_term_order] a sorted order is refused",
        term_order_is(oc_wrong_artefact,
            "{\"expected_terminal_order\": [\"alpha\", \"zebra\"]}",
            TwoCompiled),
        !T, !IO),
    % Field 3 is `rule_name`, which every TerminalNode carries.
    check("[dsc_term_order] a field every TerminalNode carries is caught",
        term_order_is(oc_wrong_artefact,
            "{\"forbidden_term_fields\": [3]}", TwoCompiled),
        !T, !IO),
    compile_with(as_though("default"), no,
        "schema Trig scope logical:\n    v: Int key\n", NoRules),
    check("[dsc_term_order] an artefact with no TerminalNode is refused",
        term_order_is(oc_wrong_artefact, "{}", NoRules), !T, !IO),
    check("[dsc_term_order] a fixture with neither expectation is malformed",
        expectations_read(term_order_kind, "{}", no), !T, !IO),
    check("[dsc_term_order] an order that is not a list of strings is malformed",
        expectations_read(term_order_kind,
            "{\"expected_terminal_order\": \"zebra\"}", no), !T, !IO),
    check("[dsc_term_order] forbidden fields that are not integers are malformed",
        expectations_read(term_order_kind,
            "{\"expected_terminal_order\": [\"zebra\"], "
                ++ "\"forbidden_term_fields\": [\"9\"]}", no), !T, !IO),
    check("[dsc_term_order] either expectation alone is well formed",
        ( if
            expectations_read(term_order_kind,
                "{\"expected_terminal_order\": [\"zebra\"]}", yes) = yes,
            expectations_read(term_order_kind,
                "{\"forbidden_term_fields\": [9]}", yes) = yes
          then yes else no ),
        !T, !IO),

    % `alert_high` has a positive pattern and so a RuleDebugName; `clear` has
    % none ([RDSC.6.8.7]).
    Sensors = "schema Sensor scope logical:\n    entity_id: String key\n"
        ++ "    level: Float mutable\n\n"
        ++ "rule alert_high:\n    Sensor s where s.level > 90.0\n->\n"
        ++ "    log info \"high\"\n\n"
        ++ "rule clear:\n    no Sensor\n->\n    log info \"clear\"\n",
    compile_with(as_though("default"), no, Sensors, SensorsCompiled),
    check("[dsc_dnam_templates] the emitted templates pass",
        dnam_is(oc_pass,
            "{\"expected_dnam\": {\"alert_high\": \"alert_high(s={s.entity_id})\"}, "
                ++ "\"absent_rules\": [\"clear\"]}", SensorsCompiled),
        !T, !IO),
    check("[dsc_dnam_templates] a template the rule does not carry is refused",
        dnam_is(oc_wrong_artefact,
            "{\"expected_dnam\": {\"alert_high\": \"alert_high(x=\"}}",
            SensorsCompiled),
        !T, !IO),
    check("[dsc_dnam_templates] a rule with no RuleDebugName is refused",
        dnam_is(oc_wrong_artefact,
            "{\"expected_dnam\": {\"clear\": \"clear\"}}", SensorsCompiled),
        !T, !IO),
    check("[dsc_dnam_templates] an absent rule that carries one is refused",
        dnam_is(oc_wrong_artefact, "{\"absent_rules\": [\"alert_high\"]}",
            SensorsCompiled),
        !T, !IO),
    check("[dsc_dnam_templates] a fixture with neither expectation is malformed",
        expectations_read(dnam_kind, "{}", no), !T, !IO),
    check("[dsc_dnam_templates] templates that are not strings are malformed",
        expectations_read(dnam_kind,
            "{\"expected_dnam\": {\"alert_high\": 1}}", no), !T, !IO),
    check("[dsc_dnam_templates] either expectation alone is well formed",
        ( if
            expectations_read(dnam_kind,
                "{\"expected_dnam\": {\"alert_high\": \"alert_high(\"}}", yes)
                = yes,
            expectations_read(dnam_kind, "{\"absent_rules\": [\"clear\"]}", yes)
                = yes
          then yes else no ),
        !T, !IO),

    Chain = ( func(Factor) = "schema Ev scope ttl 1_h:\n    v: Float\n\n"
        ++ "rule chain:\n    Ev e\n->\n    let start = e.v\n"
        ++ "    let scaled = start * " ++ Factor ++ "\n"
        ++ "    log info \"{scaled}\"\n" ),
    compile_with(as_though("default"), no, Chain("2.0"), Twice),
    compile_with(as_though("default"), no, Chain("3.0"), Thrice),
    check("[dsc_equivalent] a program is equivalent to itself",
        ( if equivalent_result(Twice, Twice) ^ r_outcome = oc_pass
          then yes else no ),
        !T, !IO),
    check("[dsc_equivalent] a different constant is not",
        ( if equivalent_result(Twice, Thrice) ^ r_outcome = oc_wrong_artefact
          then yes else no ),
        !T, !IO),
    check("[dsc_equivalent] two rule-less artefacts are not compared",
        ( if equivalent_result(NoRules, NoRules) ^ r_outcome = oc_wrong_artefact
          then yes else no ),
        !T, !IO),

    % `NoRules` compiles under `default` ([LDIA.9.2]), so a text enabling no
    % capability is not its serialization.
    Other = "ds.dialect.v2\nenabled=\n",
    check("[dsc_dialect_binding] a hex that is not the text's digest is refused",
        ( if dialect_binding_result(Other, "00", NoRules) ^ r_outcome
                = oc_wrong_artefact
          then yes else no ),
        !T, !IO),
    check("[dsc_dialect_binding] another dialect's digest is refused",
        ( if dialect_binding_result(Other, hex(sha256(utf8_of(Other))),
                NoRules) ^ r_outcome = oc_wrong_artefact
          then yes else no ),
        !T, !IO),

    % [RDSC.5.8.6]'s round trip over a compiled program with a nullable slot
    % and a fact reference, then the comparison fed each defect it must refuse,
    % one per way it can refuse.
    RefSource = "schema Target scope logical:\n    id: Int key\n\n"
        ++ "schema Holder scope logical:\n    id: Int key\n"
        ++ "    note: String? mutable\n    target: Target mutable\n",
    compile_with(as_though("default"), no, RefSource, RefCompiled),
    check("[dsc_sdef_roundtrip] the emitted SchemaDefs and Slots agree",
        ( if sdef_roundtrip_result(["Target", "Holder"], RefCompiled)
                ^ r_outcome = oc_pass
          then yes else no ),
        !T, !IO),
    check("[dsc_sdef_roundtrip] a named schema with no SchemaDef is refused",
        ( if sdef_roundtrip_result(["Absent"], RefCompiled) ^ r_outcome
                = oc_wrong_artefact
          then yes else no ),
        !T, !IO),
    Proto = ( func(Body) = "syntax = \"proto3\";\npackage ds.dsc.user.v1;\n"
        ++ "message Holder {\n" ++ Body ++ "}\n" ),
    Held = [sdef_slot("Holder", "id", 1u64, no),
            sdef_slot("Holder", "note", 3u64, yes),
            sdef_slot("Holder", "target", 6u64, no)],
    Good = "  int64 id = 1;\n  optional string note = 2;\n  uint64 target = 3;\n",
    Judge = ( func(JFields, JSlots) = sdef_failure(["Holder"],
        [sdef_def("Holder", Proto(JFields))], JSlots) ),
    check("[dsc_sdef_roundtrip] a message that matches its Slots passes",
        ( if Judge(Good, Held) = no then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a Slot with no field is refused",
        ( if Judge("  int64 id = 1;\n  optional string note = 2;\n", Held)
                = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a field with no Slot is refused",
        ( if Judge(Good ++ "  bool extra = 4;\n", Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a field numbered out of slot order is refused",
        ( if Judge("  int64 id = 1;\n  optional string note = 3;\n"
                ++ "  uint64 target = 2;\n", Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a nullable slot's field that is not "
            ++ "`optional` is refused",
        ( if Judge("  int64 id = 1;\n  string note = 2;\n"
                ++ "  uint64 target = 3;\n", Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] an `optional` field on a slot that is not "
            ++ "nullable is refused",
        ( if Judge("  optional int64 id = 1;\n  optional string note = 2;\n"
                ++ "  uint64 target = 3;\n", Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a fact reference's field that is not "
            ++ "`uint64` is refused",
        ( if Judge("  int64 id = 1;\n  optional string note = 2;\n"
                ++ "  string target = 3;\n", Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a `uint64` field on a slot that is no fact "
            ++ "reference is refused ([RDSC.5.8.7])",
        ( if Judge("  uint64 id = 1;\n  optional string note = 2;\n"
                ++ "  uint64 target = 3;\n", Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a field of another type than its kind's is "
            ++ "refused ([RDSC.5.8.7])",
        ( if Judge("  int64 id = 1;\n  optional bytes note = 2;\n"
                ++ "  uint64 target = 3;\n", Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a Slot kind RDSC.5.8.7 gives no type is "
            ++ "refused",
        ( if Judge(Good, [sdef_slot("Holder", "id", 0u64, no),
                          sdef_slot("Holder", "note", 3u64, yes),
                          sdef_slot("Holder", "target", 6u64, no)]) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] the table gives every kind 1 to 10 a type, "
            ++ "and 0 none",
        ( if
            list.all_true((pred(K::in) is semidet :-
                rdsc_5_8_7_proto_type(K, _)),
                [1u64, 2u64, 3u64, 4u64, 5u64, 6u64, 7u64, 8u64, 9u64, 10u64]),
            not rdsc_5_8_7_proto_type(0u64, _),
            not rdsc_5_8_7_proto_type(11u64, _)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a field line of another shape is refused",
        ( if Judge("  int64 id=1;\n  optional string note = 2;\n"
                ++ "  uint64 target = 3;\n", Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a proto_source with no message is refused",
        ( if sdef_failure(["Holder"],
                [sdef_def("Holder", "syntax = \"proto3\";\n")], Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] an artefact with no proto_source is refused",
        ( if sdef_failure([], [sdef_def("Holder", "")], Held) = yes(_)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] a fixture with no `schemas` is malformed",
        ( if
            parse_corpus_json("{}", json_ok(NoSchemas)),
            not sdef_expectations(NoSchemas, _)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] an empty `schemas` is malformed",
        ( if
            parse_corpus_json("{\"schemas\": []}", json_ok(EmptySchemas)),
            not sdef_expectations(EmptySchemas, _)
          then yes else no ), !T, !IO),
    check("[dsc_sdef_roundtrip] `schemas` that are not strings are malformed",
        ( if
            parse_corpus_json("{\"schemas\": [1]}", json_ok(IntSchemas)),
            not sdef_expectations(IntSchemas, _)
          then yes else no ), !T, !IO).

:- func term_order_is(outcome, string, compile_result) = bool.

term_order_is(Want, ExpectText, Compiled) = Ok :-
    parse_corpus_json(ExpectText, Parsed),
    ( if
        Parsed = json_ok(Expect),
        term_order_result(Expect, Compiled) ^ r_outcome = Want
    then
        Ok = yes
    else
        Ok = no
    ).

:- func dnam_is(outcome, string, compile_result) = bool.

dnam_is(Want, ExpectText, Compiled) = Ok :-
    parse_corpus_json(ExpectText, Parsed),
    ( if
        Parsed = json_ok(Expect),
        dnam_result(Expect, Compiled) ^ r_outcome = Want
    then
        Ok = yes
    else
        Ok = no
    ).

:- type expectations_kind
    --->    term_order_kind
    ;       dnam_kind.

    % `yes` when the kind's expectation check reads `ExpectText` as `Want`
    % says: `yes` well formed, `no` malformed.
    %
:- func expectations_read(expectations_kind, string, bool) = bool.

expectations_read(Kind, ExpectText, Want) = Ok :-
    parse_corpus_json(ExpectText, Parsed),
    ( if Parsed = json_ok(Expect) then
        (
            Kind = term_order_kind,
            Got = ( if term_order_expectations(Expect) then yes else no )
        ;
            Kind = dnam_kind,
            Got = ( if dnam_expectations(Expect) then yes else no )
        ),
        Ok = ( if Got = Want then yes else no )
    else
        Ok = no
    ).

:- pred non_empty(string::in) is semidet.

non_empty(S) :- S \= "".

%-----------------------------------------------------------------------------%
% One fixture
%-----------------------------------------------------------------------------%

    % A fixture that would not open or parse is `no`, which the caller fails
    % by name, never an outcome.
    %
:- pred run_fixture(registry::in, stdlib::in, maybe(fo_table)::in,
                    string::in, maybe(fixture_result)::out,
                    io::di, io::uo) is det.

run_fixture(Registry, Stdlib, FoTable, Name, Result, !IO) :-
    io.read_named_file_as_string("conformance/" ++ Name, Res, !IO),
    (
        Res = error(_),
        Result = no
    ;
        Res = ok(Text),
        % The repeats are kept for the format check ([RCTS.1.2.1]); the term
        % holds only the last value of each.
        rcts_1_2_1_parse_corpus_json(Text, Parsed, Repeats),
        (
            Parsed = json_error(_, _),
            Result = no
        ;
            Parsed = json_ok(Fixture),
            % [RCTS.1.2.35]: a well-formed fixture compiled from files is
            % compiled here, where there is IO, and judged in `classify`.
            ( if
                from_files(Fixture),
                not member_string(Fixture, "deprecated", _),
                rcts_fixture_format(Stdlib, Repeats, Fixture, well_formed(_))
            then
                compile_from_files(Name, Fixture, CC, !IO),
                Cli = yes(CC)
            else
                Cli = no
            ),
            ( if
                not member_string(Fixture, "deprecated", _),
                rcts_1_2_3_refusal("compiler", Fixture) = yes(Why)
            then
                % [RCTS.1.2.3]: every fixture here is staged from
                % `specs/conformance/compiler/`.
                Result = no,
                io.format("    malformed fixture %s: [RCTS.1.2.3] %s\n",
                    [s(Name), s(Why)], !IO)
            else if
                classify(Registry, Stdlib, FoTable, Repeats, Fixture, Cli,
                    Classified)
            then
                Result = yes(Classified)
            else
                Result = no,
                print_refusal(Stdlib, Repeats, Name, Fixture, !IO)
            )
        )
    ).

    % A fixture `classify` refused, with the clause it breaks when the format
    % check is why ([RCTS.1.2.15]: a harness names it in each refusal).
    %
:- pred print_refusal(stdlib::in, list(string)::in, string::in, json::in,
                      io::di, io::uo) is det.

print_refusal(Stdlib, Repeats, Name, Fixture, !IO) :-
    rcts_fixture_format(Stdlib, Repeats, Fixture, Format),
    (
        Format = malformed(_, _),
        io.format("    malformed fixture %s: %s\n",
            [s(Name), s(malformed_text(Format))], !IO)
    ;
        Format = well_formed(_)
    ).

    % [RCTS.1.2.15]: a `malformed_fixture` passes only when the format check
    % refuses it under the clause `expect.reason` names. Accepting it is
    % `accepted` (a check this harness does not have), and refusing it under
    % another clause is `wrong-code`; `r_got` says which clause, and why.
    %
:- func malformed_fixture_result(string, fixture_format) = fixture_result.

malformed_fixture_result(Reason, Format) = Result :-
    Kind = "malformed_fixture",
    (
        Format = well_formed(_),
        Result = fixture_result(oc_accepted, Kind, Reason, [], [])
    ;
        Format = malformed(Clause, _),
        Outcome = ( if Clause = Reason then oc_pass else oc_wrong_code ),
        Result = fixture_result(Outcome, Kind, Reason,
            [malformed_text(Format)], [])
    ).

    % Fails when the fixture is malformed: the format check refused it
    % ([RCTS.1.2.15]), or its kind lacks a field it needs. A
    % `malformed_fixture` is judged on the format check alone. `Cli` is the
    % compile from files ([RCTS.1.2.35]), `no` for a fixture compiled in
    % memory.
    %
:- pred classify(registry::in, stdlib::in, maybe(fo_table)::in,
                 list(string)::in, json::in, maybe(cli_compile)::in,
                 fixture_result::out) is semidet.

classify(Registry, Stdlib, FoTable, Repeats, Fixture, Cli, Result) :-
    ( if member_string(Fixture, "deprecated", _) then
        Result = fixture_result(oc_deprecated, "", "", [], [])
    else if
        member_object(Fixture, "expect", Expect0),
        member_string(Expect0, "kind", "malformed_fixture"),
        member_string(Expect0, "reason", Reason)
    then
        rcts_fixture_format(Stdlib, Repeats, Fixture, Format),
        Result = malformed_fixture_result(Reason, Format)
    else
        rcts_fixture_format(Stdlib, Repeats, Fixture, Format),
        Format = well_formed(Libraries),
        member_string(Fixture, "rules_ds", Source),
        member_object(Fixture, "expect", Expect),
        member_string(Expect, "kind", Kind),
        % [RCTS.1.2.34], [RCTS.1.2.36]: `expected_line` and `also_raises` are
        % `compile_error`'s alone; on any other kind the fixture is malformed.
        not (
            Kind \= "compile_error",
            Expect = j_object(ExpectMs),
            ( lookup_member(ExpectMs, "expected_line", _)
            ; lookup_member(ExpectMs, "also_raises", _)
            )
        ),
        Mode = fixture_mode(Fixture),
        ( if Cli = yes(CC) then
            % [RCTS.1.2.35]: `rcts_fixture_format` has refused a fixture
            % compiled from files of any other kind.
            ( if Kind = "compile_ok" then
                % `warning` is read from the warnings of an in-memory
                % compile, which a compile from files does not give, so a
                % fixture carrying it is malformed here.
                not member_string(Expect, "warning", _),
                Result = cli_ok_result(Kind, CC)
            else if Kind = "compile_error" then
                member_string(Expect, "code", Code),
                rcts_1_2_34_expected_line(Expect, WantLine),
                not ( Code = "DS_PARSE_GENERIC", WantLine = no ),
                rcts_1_2_36_also_raises(Expect, Code, Also),
                Result = cli_error_result(Kind, Code, Also, WantLine, CC)
            else
                Kind = "dsc_test_cases",
                test_cases_expectations(Expect, Want),
                Result = test_cases_result(Want, CC)
            )
        else if Kind = "compile_ok" then
            fixture_compile(Registry, Mode, Libraries, Source, Compiled),
            % An optional `warning`: the program compiles and raises that code
            % as a warning ([LCDB.7.9]).
            ( if member_string(Expect, "warning", Warned) then
                Outcome = warning_outcome(Compiled, Warned),
                Wanted = Warned
            else
                Outcome = ok_outcome(Compiled),
                Wanted = ""
            ),
            Result = fixture_result(Outcome, Kind, Wanted,
                emitted_codes(Compiled), unlowered_reasons(Compiled))
        else if Kind = "compile_error" then
            member_string(Expect, "code", Code),
            rcts_1_2_34_expected_line(Expect, WantLine),
            % [RCTS.1.2.34]: the catch-all parse code says only that the
            % program does not parse, so a fixture naming it must say where.
            not ( Code = "DS_PARSE_GENERIC", WantLine = no ),
            rcts_1_2_36_also_raises(Expect, Code, Also),
            fixture_compile(Registry, Mode, Libraries, Source, Compiled),
            Result = error_result(Kind, Code, Also, WantLine, Compiled)
        else if Kind = "dsc_dnam_templates" then
            dnam_expectations(Expect),
            fixture_compile(Registry, Mode, Libraries, Source, Compiled),
            Result = dnam_result(Expect, Compiled)
        else if Kind = "dsc_term_order" then
            term_order_expectations(Expect),
            fixture_compile(Registry, Mode, Libraries, Source, Compiled),
            Result = term_order_result(Expect, Compiled)
        else if Kind = "dsc_sdef_roundtrip" then
            % A fixture with no `schemas` list is malformed, not a result.
            sdef_expectations(Expect, Schemas),
            fixture_compile(Registry, Mode, Libraries, Source, Compiled),
            Result = sdef_roundtrip_result(Schemas, Compiled)
        else if Kind = "dsc_dialect_binding" then
            % A fixture missing either expectation is malformed, not a result.
            member_string(Expect, "expected_serialization", Serialization),
            member_string(Expect, "expected_dialect_def_sha256", WantHex),
            fixture_compile(Registry, Mode, Libraries, Source, Compiled),
            Result = dialect_binding_result(Serialization, WantHex, Compiled)
        else if Kind = "dsc_equivalent" then
            % A fixture missing `equivalent_ds` is malformed, not a result.
            member_string(Expect, "equivalent_ds", Other),
            fixture_compile(Registry, Mode, Libraries, Source, Compiled),
            fixture_compile(Registry, Mode, Libraries, Other, OtherCompiled),
            Result = equivalent_result(Compiled, OtherCompiled)
        else if Kind = "dsc_field_order" then
            fixture_compile(Registry, Mode, Libraries, Source, Compiled),
            Result = dsc_field_order_result(FoTable, Expect, Compiled)
        else
            % Not compiled: there is nothing to compare the result against.
            Result = fixture_result(oc_unknown_kind, Kind, "", [], [])
        )
    ).

%-----------------------------------------------------------------------------%
% Artefact assertions -- the `dsc_*` kinds
%-----------------------------------------------------------------------------%
%
% Each asserts its [RCTS.1.2.10] row. An artefact with nothing to assert
% about is a failure, and a fixture with nothing to assert is malformed.
% Read with the runtime's frame reader, `next_frame` and `next_field`.

    % [RDSC.6.8]'s debug-name templates: `expected_dnam` maps a rule to a
    % string its RuleDebugName `name_template` contains ([RCTS.1.2.10]), and
    % `absent_rules` lists rules that carry no RuleDebugName: a rule with no
    % positive pattern ([RDSC.6.8.7]).
    %
:- func dnam_result(json, compile_result) = fixture_result.

dnam_result(Expect, Compiled) = Result :-
    Kind = "dsc_dnam_templates",
    (
        Compiled = compiled(Bytes, _, _),
        Walk = dnam_atoms(Bytes),
        (
            Walk = dnam_broken(Why),
            Failure = yes(Why)
        ;
            Walk = dnam_ok(Templates),
            Failure = dnam_failure(Expect, Templates)
        ),
        (
            Failure = no,
            Result = fixture_result(oc_pass, Kind, "", [], [])
        ;
            Failure = yes(Message),
            Result = fixture_result(oc_wrong_artefact, Kind, "", [Message], [])
        )
    ;
        Compiled = compile_rejected(_),
        Result = fixture_result(oc_rejected, Kind, "", emitted_codes(Compiled),
            unlowered_reasons(Compiled))
    ;
        Compiled = compile_stopped(_, _, _, _),
        Result = fixture_result(oc_stopped, Kind, "", emitted_codes(Compiled),
            [])
    ).

    % The first expectation the artefact does not meet.
    %
:- func dnam_failure(json, assoc_list(string, string)) = maybe(string).

dnam_failure(Expect, Templates) = Failure :-
    ( if
        expect_members(Expect, "expected_dnam", Wanted),
        list.find_first_match(
            ( pred(Rule - Want::in) is semidet :-
                not (
                    assoc_list.search(Templates, Rule, Template),
                    string.sub_string_search(Template, Want, _)
                )
            ), Wanted, BadRule - BadWant)
    then
        ( if assoc_list.search(Templates, BadRule, Got) then
            Failure = yes("RuleDebugName: rule `" ++ BadRule ++ "` has template `"
                ++ Got ++ "`, which does not contain `" ++ BadWant ++ "`")
        else
            Failure = yes("RuleDebugName: rule `" ++ BadRule ++ "` has no RuleDebugName atom")
        )
    else if
        expect_strings(Expect, "absent_rules", Absent),
        list.find_first_match(
            ( pred(Rule::in) is semidet :-
                assoc_list.search(Templates, Rule, _)
            ), Absent, Present)
    then
        Failure = yes("RuleDebugName: rule `" ++ Present
            ++ "` carries a RuleDebugName atom and the fixture says it must not")
    else
        Failure = no
    ).

:- type dnam_walk
    --->    dnam_ok(assoc_list(string, string))
    ;       dnam_broken(string).

    % Every RuleDebugName atom as `rule_name - name_template` ([RDSC.6.8.1]: fields 1
    % and 2).
    %
:- func dnam_atoms(list(uint8)) = dnam_walk.

dnam_atoms(Bytes) = Walk :-
    walk_dnam(init_reader(from_bytes(Bytes)), [], Walk).

:- pred walk_dnam(reader::in, assoc_list(string, string)::in,
                  dnam_walk::out) is det.

walk_dnam(R0, Acc, Walk) :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Walk = dnam_ok(list.reverse(Acc))
    ;
        FrameResult = fr_error(_, Offset),
        Walk = dnam_broken(string.format(
            "the emitted artefact does not frame at byte %d", [i(Offset)]))
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_rule_debug_name) then
            dnam_fields(Frame ^ fr_body, "" - "", Entry),
            walk_dnam(R1, [Entry | Acc], Walk)
        else
            walk_dnam(R1, Acc, Walk)
        )
    ).

:- pred dnam_fields(reader::in, pair(string, string)::in,
                    pair(string, string)::out) is det.

dnam_fields(R0, Rule0 - Template0, Entry) :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        ( if Num = 1u32, Value = fv_bytes(N), reader_string(N, Rule) then
            dnam_fields(R1, Rule - Template0, Entry)
        else if Num = 2u32, Value = fv_bytes(T), reader_string(T, Template)
        then
            dnam_fields(R1, Rule0 - Template, Entry)
        else
            dnam_fields(R1, Rule0 - Template0, Entry)
        )
    ;
        FieldResult = fields_end,
        Entry = Rule0 - Template0
    ;
        FieldResult = field_error(_),
        Entry = Rule0 - Template0
    ).

    % [RCTS.1.2.10]: a `dsc_dnam_templates` fixture carries `expected_dnam`,
    % an object of strings, or `absent_rules`, a list of strings, or both.
    % Fails for one carrying neither, or either in another shape: with neither,
    % `dnam_failure` checks nothing and every artefact passes.
    %
:- pred dnam_expectations(json::in) is semidet.

dnam_expectations(Expect) :-
    expectations_present(Expect, "expected_dnam", "absent_rules"),
    ( if has_member(Expect, "expected_dnam") then
        expect_members(Expect, "expected_dnam", _)
    else
        true
    ),
    ( if has_member(Expect, "absent_rules") then
        expect_strings(Expect, "absent_rules", _)
    else
        true
    ).

    % [RCTS.1.2.10]: a `dsc_term_order` fixture carries
    % `expected_terminal_order`, a list of strings, or `forbidden_term_fields`,
    % a list of integers, or both. Fails for one carrying neither, or either in
    % another shape: with neither, all `term_order_result` checks is that a
    % TerminalNode exists.
    %
:- pred term_order_expectations(json::in) is semidet.

term_order_expectations(Expect) :-
    expectations_present(Expect, "expected_terminal_order",
        "forbidden_term_fields"),
    ( if has_member(Expect, "expected_terminal_order") then
        expect_strings(Expect, "expected_terminal_order", _)
    else
        true
    ),
    ( if has_member(Expect, "forbidden_term_fields") then
        expect_ints(Expect, "forbidden_term_fields", _)
    else
        true
    ).

:- pred expectations_present(json::in, string::in, string::in) is semidet.

expectations_present(Expect, A, B) :-
    ( has_member(Expect, A)
    ; has_member(Expect, B)
    ).

:- pred has_member(json::in, string::in) is semidet.

has_member(Expect, Key) :-
    Expect = j_object(Members),
    lookup_member(Members, Key, _).

    % An object-valued expectation as `key - value` string pairs.
    %
:- pred expect_members(json::in, string::in, assoc_list(string, string)::out)
    is semidet.

expect_members(Expect, Key, Members) :-
    Expect = j_object(Outer),
    lookup_member(Outer, Key, Found),
    Found = j_object(Inner),
    Members = list.filter_map(
        ( func(Name - Value) = Name - Text is semidet :- Value = j_string(Text)
        ), members(Inner)),
    list.same_length(Members, members(Inner)).

    % [RBND.4.2]: the artefact's `dialect_def_sha256` (DscHeader field 10) is
    % `expected_dialect_def_sha256`, which is SHA-256 of
    % `expected_serialization`. The fixture is checked against itself first,
    % and that failure prints the text's digest.
    %
:- func dialect_binding_result(string, string, compile_result)
    = fixture_result.

dialect_binding_result(Serialization, WantHex, Compiled) = Result :-
    Kind = "dsc_dialect_binding",
    (
        Compiled = compiled(Bytes, _, _),
        TextHex = hex(sha256(utf8_of(Serialization))),
        ( if TextHex \= WantHex then
            Failure = yes("the fixture disagrees with itself: SHA-256 of "
                ++ "expected_serialization is " ++ TextHex
                ++ ", expected_dialect_def_sha256 is " ++ WantHex)
        else if header_def_sha(init_reader(from_bytes(Bytes)), Got) then
            ( if hex(Got) = WantHex then
                Failure = no
            else
                Failure = yes("DscHeader dialect_def_sha256 is " ++ hex(Got)
                    ++ ", want " ++ WantHex)
            )
        else
            Failure = yes("the artefact has no DscHeader header carrying "
                ++ "dialect_def_sha256 (field 10)")
        ),
        (
            Failure = no,
            Result = fixture_result(oc_pass, Kind, "", [], [])
        ;
            Failure = yes(Message),
            Result = fixture_result(oc_wrong_artefact, Kind, "", [Message], [])
        )
    ;
        Compiled = compile_rejected(_),
        Result = fixture_result(oc_rejected, Kind, "", emitted_codes(Compiled),
            unlowered_reasons(Compiled))
    ;
        Compiled = compile_stopped(_, _, _, _),
        Result = fixture_result(oc_stopped, Kind, "", emitted_codes(Compiled),
            [])
    ).

    % The first DscHeader frame's field 10. Fails when there is no DscHeader, or it
    % carries no field 10.
    %
:- pred header_def_sha(reader::in, list(uint8)::out) is semidet.

header_def_sha(R0, Sha) :-
    next_frame(FrameResult, R0, R1),
    FrameResult = fr_ok(Frame),
    ( if Frame ^ fr_atom = known(at_dsc_header) then
        field_bytes(Frame ^ fr_body, 10u32, Sha)
    else
        header_def_sha(R1, Sha)
    ).

:- pred field_bytes(reader::in, uint32::in, list(uint8)::out) is semidet.

field_bytes(R0, Want, Bytes) :-
    next_field(FieldResult, R0, R1),
    FieldResult = field(Num, Value),
    ( if Num = Want, Value = fv_bytes(Sub) then
        Bytes = reader_bytes(Sub)
    else
        field_bytes(R1, Want, Bytes)
    ).

:- func utf8_of(string) = list(uint8).

utf8_of(S) = list.map(uint8.det_from_int, Units) :-
    string.to_utf8_code_unit_list(S, Units).

    % [RLOW.14.3] / [LDET.5.4]: the firing-order ordinal is a TerminalNode's
    % index in emission order, so the sequence is asserted.
    % `forbidden_term_fields` asserts an absence (field 9 is reserved), so
    % every field seen is kept.
    %
:- func term_order_result(json, compile_result) = fixture_result.

term_order_result(Expect, Compiled) = Result :-
    Kind = "dsc_term_order",
    (
        Compiled = compiled(Bytes, _, _),
        Walk = term_atoms(Bytes),
        (
            Walk = walk_broken(Why),
            Failure = yes(Why)
        ;
            Walk = walk_ok(Terms),
            Names = list.map(( func(T) = T ^ tt_name ), Terms),
            ( if Terms = [] then
                % With no TerminalNode the forbidden-field check is vacuous.
                Failure = yes("no TerminalNode atoms in the emitted artefact")
            else if
                expect_strings(Expect, "expected_terminal_order", Want),
                Want \= Names
            then
                Failure = yes("TerminalNode order: want ["
                    ++ string.join_list(", ", Want)
                    ++ "], got [" ++ string.join_list(", ", Names) ++ "]")
            else if
                expect_ints(Expect, "forbidden_term_fields", Forbidden),
                Carriers = list.filter_map(carrier_of(Forbidden), Terms),
                Carriers = [_ | _]
            then
                Failure = yes("a forbidden TerminalNode field is present on ["
                    ++ string.join_list(", ", Carriers) ++ "]")
            else
                Failure = no
            )
        ),
        (
            Failure = no,
            Result = fixture_result(oc_pass, Kind, "", [], [])
        ;
            Failure = yes(Message),
            Result = fixture_result(oc_wrong_artefact, Kind, "", [Message], [])
        )
    ;
        Compiled = compile_rejected(_),
        Result = fixture_result(oc_rejected, Kind, "", emitted_codes(Compiled),
            unlowered_reasons(Compiled))
    ;
        Compiled = compile_stopped(_, _, _, _),
        Result = fixture_result(oc_stopped, Kind, "", emitted_codes(Compiled),
            [])
    ).

    % [RCTS.1.2.19]'s `dsc_field_order` ([RFCS.19.5]): this compiler's `.dsc`
    % for the program, walked from its `Dsc` message ([RFCS.19.1]) by the
    % field table `field_order.py --table` derives from `proto/`, and judged
    % as `test_behave` judges a recording for `field_order`: each atom
    % `expect.atoms` names is held, the walk refuses the copy with two fields
    % of one atom body swapped, and then it finds nothing in the artefact.
    % The walk is `field_order_walk`'s, not the compiler's reader.
    %
:- func dsc_field_order_result(maybe(fo_table), json, compile_result)
    = fixture_result.

dsc_field_order_result(MaybeTable, Expect, Compiled) = Result :-
    Kind = "dsc_field_order",
    (
        Compiled = compiled(Bytes, _, _),
        ( if
            Expect = j_object(EMs),
            fo_wanted_atoms(EMs, Want)
        then
            (
                MaybeTable = no,
                Failure = yes("no field table: `field_order.py --table` "
                    ++ "writes it, and the gate stages it as "
                    ++ "behaviour/FIELD_ORDER_TABLE.json")
            ;
                MaybeTable = yes(Table),
                ( if map.contains(Table, "Dsc") then
                    Verdict = fo_judge("Dsc", Table, Want, "artefact", Bytes),
                    (
                        Verdict = fo_ok,
                        Failure = no
                    ;
                        Verdict = fo_refused(Why),
                        Failure = yes(Why)
                    )
                else
                    Failure = yes("the field table has no message `Dsc`")
                )
            )
        else
            Failure = yes("no `atoms` list of names")
        ),
        (
            Failure = no,
            Result = fixture_result(oc_pass, Kind, "", [], [])
        ;
            Failure = yes(Message),
            Result = fixture_result(oc_wrong_artefact, Kind, "", [Message], [])
        )
    ;
        Compiled = compile_rejected(_),
        Result = fixture_result(oc_rejected, Kind, "", emitted_codes(Compiled),
            unlowered_reasons(Compiled))
    ;
        Compiled = compile_stopped(_, _, _, _),
        Result = fixture_result(oc_stopped, Kind, "", emitted_codes(Compiled),
            [])
    ).

    % The field table the gate stages for both suites, or `no` when it is
    % absent or unreadable: a
    % `dsc_field_order` fixture then fails, naming why.
    %
:- pred read_field_order_table(maybe(fo_table)::out, io::di, io::uo) is det.

read_field_order_table(Table, !IO) :-
    io.read_named_file_as_string("behaviour/FIELD_ORDER_TABLE.json", Res,
        !IO),
    ( if
        Res = ok(Text),
        parse_corpus_json(Text, json_ok(J)),
        fo_table(J, _, T)
    then
        Table = yes(T)
    else
        Table = no
    ).

:- func carrier_of(list(int), term_atom) = string is semidet.

carrier_of(Forbidden, T) = T ^ tt_name :-
    % A filter, not `member(out, in)`, which is nondet.
    list.filter(
        ( pred(F::in) is semidet :-
            list.member(uint32.cast_from_int(F), T ^ tt_fields)
        ), Forbidden, [_ | _]).

    % [RDSC.5.8.6]'s round trip, `dsc_sdef_roundtrip`: every schema `schemas`
    % names has a SchemaDef carrying a `proto_source`, and every SchemaDef
    % carrying one declares one field per Slot atom of its schema, in Slot
    % order. Field N is the Nth slot ([LFST.8.10]: the generated definition
    % takes its field numbers from slot position), `optional` exactly when
    % the slot is `nullable`, and of the proto3 type [RDSC.5.8.7] gives the
    % slot's kind ([RDSC.5.8.3]; `rdsc_5_8_7_proto_type`).
    %
    % The schema a reference names is not compared: its field is a `uint64`
    % handle ([RFCS.6.3]). The `.proto` is read by `parse_proto_message`, not
    % the compiler's parser.
    %
:- func sdef_roundtrip_result(list(string), compile_result) = fixture_result.

sdef_roundtrip_result(Schemas, Compiled) = Result :-
    Kind = "dsc_sdef_roundtrip",
    (
        Compiled = compiled(Bytes, _, _),
        Walk = sdef_atoms(Bytes),
        (
            Walk = sdef_broken(Why),
            Failure = yes(Why)
        ;
            Walk = sdef_ok(Defs, Slots),
            Failure = sdef_failure(Schemas, Defs, Slots)
        ),
        (
            Failure = no,
            Result = fixture_result(oc_pass, Kind, "", [], [])
        ;
            Failure = yes(Message),
            Result = fixture_result(oc_wrong_artefact, Kind, "", [Message], [])
        )
    ;
        Compiled = compile_rejected(_),
        Result = fixture_result(oc_rejected, Kind, "", emitted_codes(Compiled),
            unlowered_reasons(Compiled))
    ;
        Compiled = compile_stopped(_, _, _, _),
        Result = fixture_result(oc_stopped, Kind, "", emitted_codes(Compiled),
            [])
    ).

    % [RCTS.1.2.10]: a `dsc_sdef_roundtrip` fixture carries `schemas`, a
    % non-empty list of strings.
    %
:- pred sdef_expectations(json::in, list(string)::out) is semidet.

sdef_expectations(Expect, Schemas) :-
    expect_strings(Expect, "schemas", Schemas),
    Schemas = [_ | _].

    % One Slot atom as the round trip reads it. `ss_kind` is the
    % `proto/slot.proto#SlotKind` number; `ss_name` names the slot in a failure.
    %
:- type sdef_slot
    --->    sdef_slot(
                ss_schema   :: string,  % Slot.schema_name, field 1
                ss_name     :: string,  % Slot.slot_name, field 2
                ss_kind     :: uint64,  % Slot.kind, field 3
                ss_nullable :: bool     % Slot.nullable, field 11
            ).

    % One SchemaDef atom. `sd_proto` is "" when it carries no `proto_source`.
    %
:- type sdef_def
    --->    sdef_def(
                sd_schema :: string,    % SchemaDef.schema_name, field 1
                sd_proto  :: string     % SchemaDef.proto_source, field 3
            ).

    % One field line of a `proto_source` message.
    %
:- type proto_field
    --->    proto_field(
                pf_optional :: bool,
                pf_type     :: string,
                pf_name     :: string,
                pf_number   :: int
            ).

:- type sdef_walk
    --->    sdef_ok(list(sdef_def), list(sdef_slot))
    ;       sdef_broken(string).

    % The first thing the atoms do not meet, or `no`. An artefact with no
    % SchemaDef carrying a `proto_source` fails.
    %
:- func sdef_failure(list(string), list(sdef_def), list(sdef_slot))
    = maybe(string).

sdef_failure(Schemas, Defs, Slots) = Failure :-
    WithProto = list.filter(( pred(Def::in) is semidet :- Def ^ sd_proto \= "" ),
        Defs),
    ( if
        list.find_first_match(
            ( pred(Wanted::in) is semidet :-
                not carries_proto(WithProto, Wanted)
            ), Schemas, Missing)
    then
        Failure = yes("schema `" ++ Missing ++ "` has no SchemaDef atom "
            ++ "carrying a `proto_source`")
    else if WithProto = [] then
        Failure = yes("no SchemaDef atom in the emitted artefact carries a "
            ++ "`proto_source`")
    else
        Failure = first_def_failure(WithProto, Slots)
    ).

:- pred carries_proto(list(sdef_def)::in, string::in) is semidet.

carries_proto(Defs, Schema) :-
    list.find_first_match(
        ( pred(D::in) is semidet :- D ^ sd_schema = Schema ), Defs, _).

:- func first_def_failure(list(sdef_def), list(sdef_slot)) = maybe(string).

first_def_failure([], _) = no.
first_def_failure([D | Ds], Slots) = Failure :-
    Own = list.filter(
        ( pred(S::in) is semidet :- S ^ ss_schema = D ^ sd_schema ), Slots),
    Parsed = parse_proto_message(D ^ sd_proto),
    (
        Parsed = proto_bad(Why),
        DefFailure = yes("SchemaDef `" ++ D ^ sd_schema ++ "`: " ++ Why)
    ;
        Parsed = proto_message(Fields),
        DefFailure = fields_failure(D ^ sd_schema, 1, Fields, Own)
    ),
    (
        DefFailure = yes(_),
        Failure = DefFailure
    ;
        DefFailure = no,
        Failure = first_def_failure(Ds, Slots)
    ).

    % Field N against the Nth Slot, both lists to their ends, so a Slot with
    % no field and a field with no Slot both fail ([RDSC.5.8.6]'s
    % "unidirectional case").
    %
:- func fields_failure(string, int, list(proto_field), list(sdef_slot))
    = maybe(string).

fields_failure(Schema, N, Fields, Slots) = Failure :-
    (
        Fields = [],
        (
            Slots = [],
            Failure = no
        ;
            Slots = [Extra | _],
            Failure = yes("SchemaDef `" ++ Schema ++ "`: Slot `"
                ++ Extra ^ ss_name ++ "` has no field in the proto_source")
        )
    ;
        Fields = [F | Fs],
        (
            Slots = [],
            Failure = yes("SchemaDef `" ++ Schema ++ "`: field `"
                ++ F ^ pf_name ++ "` has no Slot atom")
        ;
            Slots = [S | Ss],
            Where = "SchemaDef `" ++ Schema ++ "`, slot " ++ string.from_int(N)
                ++ " (`" ++ S ^ ss_name ++ "`): ",
            ( if F ^ pf_number \= N then
                Failure = yes(Where ++ "its field `" ++ F ^ pf_name
                    ++ "` is numbered " ++ string.from_int(F ^ pf_number))
            else if F ^ pf_optional \= S ^ ss_nullable then
                Failure = yes(Where ++
                    ( if S ^ ss_nullable = yes then
                        "nullable, and its field is not `optional`"
                    else
                        "not nullable, and its field is `optional`"
                    ))
            else if not rdsc_5_8_7_proto_type(S ^ ss_kind, _) then
                Failure = yes(Where ++ "its Slot's kind is "
                    ++ string.string(S ^ ss_kind)
                    ++ ", which RDSC.5.8.7 gives no proto3 type")
            else if
                rdsc_5_8_7_proto_type(S ^ ss_kind, Want),
                F ^ pf_type \= Want
            then
                Failure = yes(Where ++ "its field is `" ++ F ^ pf_type
                    ++ "`, and RDSC.5.8.7 gives its kind `" ++ Want ++ "`")
            else
                Failure = fields_failure(Schema, N + 1, Fs, Ss)
            )
        )
    ).

    % [RDSC.5.8.7]: the proto3 field type each Slot kind takes, as the table
    % states it, keyed by `SlotKind`'s number in proto/slot.proto: the judge's
    % own copy, apart from `dsc.encode.rdsc_5_8_3_proto_type`.
    % SLOT_KIND_UNSPECIFIED (0) has none.
    %
:- pred rdsc_5_8_7_proto_type(uint64::in, string::out) is semidet.

rdsc_5_8_7_proto_type(1u64, "int64").        % SLOT_KIND_INT
rdsc_5_8_7_proto_type(2u64, "double").       % SLOT_KIND_FLOAT
rdsc_5_8_7_proto_type(3u64, "string").       % SLOT_KIND_STRING
rdsc_5_8_7_proto_type(4u64, "bool").         % SLOT_KIND_BOOL
rdsc_5_8_7_proto_type(5u64, "string").       % SLOT_KIND_JSON
rdsc_5_8_7_proto_type(6u64, "uint64").       % SLOT_KIND_SCHEMA
rdsc_5_8_7_proto_type(7u64, "bytes").        % SLOT_KIND_BYTES
rdsc_5_8_7_proto_type(8u64, "int64").        % SLOT_KIND_TIME
rdsc_5_8_7_proto_type(9u64, "int64").        % SLOT_KIND_DATE
rdsc_5_8_7_proto_type(10u64, "int64").       % SLOT_KIND_DURATION

:- type proto_parse
    --->    proto_message(list(proto_field))
    ;       proto_bad(string).

    % A `proto_source` read as [RDSC.5.8.3] gives it: a proto3 file of one
    % `message`, one field to a line, `[optional] <type> <name> = <n>;`.
    % `syntax` and `package` lines and blank lines before the message are
    % passed over. Anything else is refused.
    %
:- func parse_proto_message(string) = proto_parse.

parse_proto_message(Text) = Parse :-
    proto_outside(string.split_at_char('\n', Text), Parse).

:- pred proto_outside(list(string)::in, proto_parse::out) is det.

proto_outside([], proto_bad("the proto_source declares no message")).
proto_outside([Line | Lines], Parse) :-
    Words = string.words(Line),
    ( if
        ( Words = []
        ; Words = ["syntax" | _]
        ; Words = ["package" | _]
        )
    then
        proto_outside(Lines, Parse)
    else if Words = ["message", _, "{"] then
        proto_fields(Lines, [], Parse)
    else
        Parse = proto_bad("not a field, and outside the message: `"
            ++ Line ++ "`")
    ).

:- pred proto_fields(list(string)::in, list(proto_field)::in,
                     proto_parse::out) is det.

proto_fields([], _, proto_bad("the message is not closed")).
proto_fields([Line | Lines], Acc, Parse) :-
    Words = string.words(Line),
    ( if Words = ["}"] then
        ( if list.all_true(blank_line, Lines) then
            Parse = proto_message(list.reverse(Acc))
        else
            Parse = proto_bad("the proto_source goes on after its message")
        )
    else if Words = [] then
        proto_fields(Lines, Acc, Parse)
    else if proto_field_line(Words, Field) then
        proto_fields(Lines, [Field | Acc], Parse)
    else
        Parse = proto_bad("not a field: `" ++ Line ++ "`")
    ).

:- pred blank_line(string::in) is semidet.

blank_line(Line) :-
    string.words(Line) = [].

:- pred proto_field_line(list(string)::in, proto_field::out) is semidet.

proto_field_line(Words, Field) :-
    ( if Words = ["optional" | Rest0] then
        Optional = yes,
        Rest = Rest0
    else
        Optional = no,
        Rest = Words
    ),
    Rest = [Type, Name, "=", NumText],
    string.remove_suffix(NumText, ";", Digits),
    string.to_int(Digits, Number),
    Field = proto_field(Optional, Type, Name, Number).

    % Every SchemaDef and every Slot atom, each in emission order.
    %
:- func sdef_atoms(list(uint8)) = sdef_walk.

sdef_atoms(Bytes) = Walk :-
    walk_sdef(init_reader(from_bytes(Bytes)), [], [], Walk).

:- pred walk_sdef(reader::in, list(sdef_def)::in, list(sdef_slot)::in,
                  sdef_walk::out) is det.

walk_sdef(R0, Defs, Slots, Walk) :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Walk = sdef_ok(list.reverse(Defs), list.reverse(Slots))
    ;
        FrameResult = fr_error(_, Offset),
        Walk = sdef_broken(string.format(
            "the emitted artefact does not frame at byte %d", [i(Offset)]))
    ;
        FrameResult = fr_ok(Frame),
        Atom = Frame ^ fr_atom,
        ( if Atom = known(at_schema_def) then
            fold_fields(Frame ^ fr_body, sdef_def_field, sdef_def("", ""),
                ReadDef),
            ( if ReadDef = ff_ok(Def) then
                walk_sdef(R1, [Def | Defs], Slots, Walk)
            else
                Walk = sdef_broken("a SchemaDef atom's body does not parse")
            )
        else if Atom = known(at_slot) then
            fold_fields(Frame ^ fr_body, sdef_slot_field,
                sdef_slot("", "", 0u64, no), ReadSlot),
            ( if ReadSlot = ff_ok(Slot) then
                walk_sdef(R1, Defs, [Slot | Slots], Walk)
            else
                Walk = sdef_broken("a Slot atom's body does not parse")
            )
        else
            walk_sdef(R1, Defs, Slots, Walk)
        )
    ).

    % `proto/schema_def.proto#SchemaDef`'s `schema_name` (1) and
    % `proto_source` (3). Fails on either in another wire type, or not UTF-8.
    %
:- pred sdef_def_field(uint32::in, field_value::in, sdef_def::in,
                       sdef_def::out) is semidet.

sdef_def_field(Num, Value, D0, D) :-
    ( if Num = 1u32 then
        Value = fv_bytes(R),
        reader_string(R, Name),
        D = D0 ^ sd_schema := Name
    else if Num = 3u32 then
        Value = fv_bytes(R),
        reader_string(R, Text),
        D = D0 ^ sd_proto := Text
    else
        D = D0
    ).

    % `proto/slot.proto#Slot`'s `schema_name` (1), `slot_name` (2), `kind` (3)
    % and `nullable` (11). Fails on any of them in another wire type.
    %
:- pred sdef_slot_field(uint32::in, field_value::in, sdef_slot::in,
                        sdef_slot::out) is semidet.

sdef_slot_field(Num, Value, S0, S) :-
    ( if Num = 1u32 then
        Value = fv_bytes(R),
        reader_string(R, Schema),
        S = S0 ^ ss_schema := Schema
    else if Num = 2u32 then
        Value = fv_bytes(R),
        reader_string(R, Name),
        S = S0 ^ ss_name := Name
    else if Num = 3u32 then
        Value = fv_varint(K),
        S = S0 ^ ss_kind := K
    else if Num = 11u32 then
        Value = fv_varint(V),
        S = S0 ^ ss_nullable := ( if V = 0u64 then no else yes )
    else
        S = S0
    ).

    % [LLET.10.6]: two sources differing only in layout emit the same
    % artefact, compared without the source-position atoms (DsSource,
    % LineSpan, DocString). An artefact with no TerminalNode fails: a pure
    % `let` inlines into the terminal's actions.
    %
:- func equivalent_result(compile_result, compile_result) = fixture_result.

equivalent_result(Compiled, OtherCompiled) = Result :-
    Kind = "dsc_equivalent",
    ( if
        Compiled = compiled(Bytes, _, _),
        OtherCompiled = compiled(OtherBytes, _, _)
    then
        Walk = term_atoms(Bytes),
        ( if Walk = walk_broken(Why) then
            Failure = yes(Why)
        else if Walk = walk_ok([]) then
            Failure = yes("no TerminalNode atoms in the emitted artefact -- the "
                ++ "inlined `let` values ride the terminal's actions")
        else
            Stripped = strip_layout(Bytes),
            OtherStripped = strip_layout(OtherBytes),
            ( if Stripped = OtherStripped then
                Failure = no
            else
                Failure = yes(string.format(
                    "the artefacts differ at byte %d (lengths %d and %d, "
                        ++ "source-position atoms dropped)",
                    [i(first_difference(Stripped, OtherStripped, 0)),
                     i(list.length(Stripped)), i(list.length(OtherStripped))]))
            )
        ),
        (
            Failure = no,
            Result = fixture_result(oc_pass, Kind, "", [], [])
        ;
            Failure = yes(Message),
            Result = fixture_result(oc_wrong_artefact, Kind, "", [Message], [])
        )
    else if Compiled = compiled(_, _, _) then
        % Only the second spelling was refused: name it as such, since the
        % fixture's `rules_ds` is not the program at fault.
        Result = fixture_result(ok_outcome(OtherCompiled), Kind, "",
            list.map(( func(C) = "equivalent_ds: " ++ C ),
                emitted_codes(OtherCompiled)),
            unlowered_reasons(OtherCompiled))
    else
        Result = fixture_result(ok_outcome(Compiled), Kind, "",
            emitted_codes(Compiled), unlowered_reasons(Compiled))
    ).

:- func first_difference(list(uint8), list(uint8), int) = int.

first_difference([], _, N) = N.
first_difference([_ | _], [], N) = N.
first_difference([A | As], [B | Bs], N) =
    ( if A = B then first_difference(As, Bs, N + 1) else N ).

:- type term_atom
    --->    term_atom(
                tt_name   :: string,        % TerminalNode.rule_name, field 3
                tt_fields :: list(uint32)   % every field number seen
            ).

:- type term_walk
    --->    walk_ok(list(term_atom))
    ;       walk_broken(string).

    % Every TerminalNode atom, in emission order.
    %
:- func term_atoms(list(uint8)) = term_walk.

term_atoms(Bytes) = Walk :-
    walk_terms(init_reader(from_bytes(Bytes)), [], Walk).

:- pred walk_terms(reader::in, list(term_atom)::in, term_walk::out) is det.

walk_terms(R0, Acc, Walk) :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof,
        Walk = walk_ok(list.reverse(Acc))
    ;
        FrameResult = fr_error(_, Offset),
        % A failure, not a short list.
        Walk = walk_broken(string.format(
            "the emitted artefact does not frame at byte %d", [i(Offset)]))
    ;
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_terminal_node) then
            term_fields(Frame ^ fr_body, term_atom("", []), Term),
            walk_terms(R1, [Term | Acc], Walk)
        else
            walk_terms(R1, Acc, Walk)
        )
    ).

:- pred term_fields(reader::in, term_atom::in, term_atom::out) is det.

term_fields(R0, T0, T) :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        T1 = T0 ^ tt_fields := [Num | T0 ^ tt_fields],
        ( if Num = 3u32, Value = fv_bytes(Sub), reader_string(Sub, Name) then
            T2 = T1 ^ tt_name := Name
        else
            T2 = T1
        ),
        term_fields(R1, T2, T)
    ;
        FieldResult = fields_end,
        T = T0
    ;
        FieldResult = field_error(_),
        T = T0
    ).

    % The artefact with every DsSource, LineSpan, DocString and DscHeader frame
    % removed and the rest copied verbatim; an unframeable tail is kept. The
    % header goes because its `dsc_sha256` digests DsSource ([RDSC.3.6]).
    %
:- func strip_layout(list(uint8)) = list(uint8).

strip_layout(Bytes) = Kept :-
    strip_frames(Bytes, init_reader(from_bytes(Bytes)), [], Chunks),
    Kept = list.condense(list.reverse(Chunks)).

:- pred strip_frames(list(uint8)::in, reader::in, list(list(uint8))::in,
                     list(list(uint8))::out) is det.

strip_frames(Bytes, R0, !Chunks) :-
    Start = position(R0),
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_eof
    ;
        FrameResult = fr_error(_, _),
        !:Chunks = [slice(Bytes, Start, list.length(Bytes)) | !.Chunks]
    ;
        FrameResult = fr_ok(Frame),
        ( if
            Frame ^ fr_atom = known(Atom),
            ( Atom = at_ds_source ; Atom = at_line_span ; Atom = at_doc_string
            ; Atom = at_dsc_header
            )
        then
            true
        else
            !:Chunks = [slice(Bytes, Start, position(R1)) | !.Chunks]
        ),
        strip_frames(Bytes, R1, !Chunks)
    ).

:- func slice(list(uint8), int, int) = list(uint8).

slice(Bytes, Start, End) = Slice :-
    list.det_split_list(Start, Bytes, _, Rest),
    list.det_split_list(End - Start, Rest, Slice, _).

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

:- pred expect_strings(json::in, string::in, list(string)::out) is semidet.

expect_strings(Expect, Key, Strings) :-
    Expect = j_object(Members),
    lookup_member(Members, Key, Found),
    Found = j_array(Items),
    Strings = list.filter_map(( func(J) = S is semidet :- J = j_string(S) ),
        Items),
    list.same_length(Strings, Items).

:- pred expect_ints(json::in, string::in, list(int)::out) is semidet.

expect_ints(Expect, Key, Ints) :-
    Expect = j_object(Members),
    lookup_member(Members, Key, Found),
    Found = j_array(Items),
    % Field numbers, so Mercury `int`s; the Json leaf is `int64`.
    Ints = list.filter_map(
        ( func(J) = int64.cast_to_int(N) is semidet :- J = j_int(N) ), Items),
    list.same_length(Ints, Items).

    % The messages of the `DS_VALIDATE_RULE_NOT_LOWERED` refusals, each naming
    % its rule and the lowering's reason.
    %
:- func unlowered_reasons(compile_result) = list(string).

unlowered_reasons(compiled(_, _, _)) = [].
unlowered_reasons(compile_rejected(Diagnostics)) =
    list.filter_map(
        ( func(D) = D ^ dg_message is semidet :-
            D ^ dg_code = dc_validate(dv_rule_not_lowered)
        ), Diagnostics).
unlowered_reasons(compile_stopped(_, _, _, _)) = [].

:- func ok_outcome(compile_result) = outcome.

ok_outcome(compiled(_, _, _)) = oc_pass.
ok_outcome(compile_rejected(_)) = oc_rejected.
ok_outcome(compile_stopped(_, _, _, _)) = oc_stopped.

    % `compile_ok` with a `warning`: compiled, and that code among the
    % warnings. Compiled without it is `wrong_code`.
    %
:- func warning_outcome(compile_result, string) = outcome.

warning_outcome(compiled(_, Warnings, _), Code) =
    ( if has_code(Warnings, Code) then oc_pass else oc_wrong_code ).
warning_outcome(compile_rejected(_), _) = oc_rejected.
warning_outcome(compile_stopped(_, _, _, _), _) = oc_stopped.

    % A front-end stop passes only on its own `DS_LEX_*` / `DS_PARSE_*` code;
    % a fixture wanting a `DS_VALIDATE_*` code that the parser stopped is
    % `stopped`. `front_coded` lists each front-coded fixture with its
    % message, since `DS_PARSE_GENERIC` names no reason.
    %
    % [RCTS.1.2.36]: a refusal passes on exactly the codes the fixture names.
    %
:- func error_outcome(compile_result, string, list(string)) = outcome.

error_outcome(compiled(_, _, _), _, _) = oc_accepted.
error_outcome(compile_stopped(Code, _, _, _), Want, Also) =
    ( if ds_front_name(Code) = Want, Also = [] then oc_pass else oc_stopped ).
error_outcome(compile_rejected(Diagnostics), Code, Also) =
    ( if error_codes(Diagnostics) = list.sort([Code | Also])
    then oc_pass
    else oc_wrong_code
    ).

    % The error codes among a refusal's diagnostics, each once.
    %
:- func error_codes(list(diagnostic)) = list(string).

error_codes(Diagnostics) =
    list.sort_and_remove_dups(list.filter_map(
        ( func(D) = code_name(D ^ dg_code) is semidet :-
            D ^ dg_severity = sev_error
        ), Diagnostics)).

    % [RCTS.1.2.36]: a `compile_error` fixture's optional `also_raises`. FAILS
    % for any other value, which makes the fixture malformed.
    %
:- pred rcts_1_2_36_also_raises(json::in, string::in, list(string)::out)
    is semidet.

rcts_1_2_36_also_raises(Expect, Code, Also) :-
    ( if
        Expect = j_object(Ms),
        lookup_member(Ms, "also_raises", J)
    then
        J = j_array(Items),
        Items = [_ | _],
        list.map(( pred(I::in, S::out) is semidet :- I = j_string(S) ),
            Items, Also),
        list.sort_and_remove_dups(Also, Unique),
        list.same_length(Unique, Also),
        not list.member(Code, Also)
    else
        Also = []
    ).

    % [RCTS.1.2.34]: a `compile_error` fixture's optional `expected_line`, a
    % positive integer. FAILS for any other value, which makes the fixture
    % malformed, as a missing `code` does.
    %
:- pred rcts_1_2_34_expected_line(json::in, maybe(int)::out) is semidet.

rcts_1_2_34_expected_line(Expect, Line) :-
    ( if
        Expect = j_object(Ms),
        lookup_member(Ms, "expected_line", J)
    then
        J = j_int(N),
        N >= 1i64,
        Line = yes(int64.cast_to_int(N))
    else
        Line = no
    ).

    % A `compile_error` fixture's result: `error_outcome`'s, then, when it
    % passed and the fixture names `expected_line`, `wrong-line` unless a
    % refusal carrying `code` begins on that line ([RCTS.1.2.34]).
    %
    % The lines go into `r_got` for a result that raised the code, so the
    % front-coded listing shows where each stopped. Not for other outcomes:
    % `r_got` keys the front-end histogram.
    %
:- func error_result(string, string, list(string), maybe(int), compile_result)
    = fixture_result.

error_result(Kind, Code, Also, WantLine, Compiled) = Result :-
    Outcome0 = error_outcome(Compiled, Code, Also),
    Lines = refusal_lines(Compiled, Code),
    ( if
        Outcome0 = oc_pass,
        WantLine = yes(Line),
        not list.member(Line, Lines)
    then
        Outcome = oc_wrong_line
    else
        Outcome = Outcome0
    ),
    ( if ( Outcome = oc_pass ; Outcome = oc_wrong_line ) then
        Got = emitted_codes(Compiled) ++ ["at line(s) "
            ++ string.join_list(", ", list.map(string.int_to_string, Lines))]
    else
        Got = emitted_codes(Compiled)
    ),
    Result = fixture_result(Outcome, Kind, Code, Got,
        unlowered_reasons(Compiled)).

    % The line each refusal carrying `Code` begins on, 1-based, in the order
    % the compiler reported them: a front-end stop's one position, or every
    % diagnostic of a refusal that carries the code.
    %
:- func refusal_lines(compile_result, string) = list(int).

refusal_lines(compiled(_, _, _), _) = [].
refusal_lines(compile_stopped(Front, _, Pos, _), Code) =
    ( if ds_front_name(Front) = Code then [Pos ^ p_line] else [] ).
refusal_lines(compile_rejected(Diagnostics), Code) =
    list.filter_map(
        ( func(D) = D ^ dg_pos ^ p_line is semidet :-
            code_name(D ^ dg_code) = Code ),
        Diagnostics).

    % The codes this compiler actually raised, deduplicated so a check that
    % fires per slot does not drown the row it is reported on.
    %
:- func emitted_codes(compile_result) = list(string).

emitted_codes(compiled(_, Warnings, _)) =
    list.sort_and_remove_dups(
        list.map(func(D) = code_name(D ^ dg_code), Warnings)).
emitted_codes(compile_stopped(_, Message, _, _)) = [Message].
emitted_codes(compile_rejected(Diagnostics)) =
    list.sort_and_remove_dups(
        list.map(func(D) = code_name(D ^ dg_code), Diagnostics)).

    % Recursive, not `list.member`: `member(out, in)` is nondet and a
    % diagnostic list can carry one code twice.
    %
:- pred has_code(list(diagnostic)::in, string::in) is semidet.

has_code([D | Ds], Code) :-
    ( if code_name(D ^ dg_code) = Code then
        true
    else
        has_code(Ds, Code)
    ).

%-----------------------------------------------------------------------------%
% A fixture compiled from files -- [RCTS.1.2.35]
%-----------------------------------------------------------------------------%
%
% The fixture is written out as files and `dsc.cli.run` compiles `main.ds`
% from them, so which `.dstest` files are read is the compiler's decision
% ([LTSL.2.4]). The verdict is its exit status ([RCLI.3.1]), its JSON
% diagnostics ([RCLI.3.2]) and the artefact it wrote.

    % What one compile from files did, and the paths a DsSource names each
    % module by.
    %
:- type cli_compile
    --->    cli_compile(
                cc_status      :: int,
                cc_diagnostics :: list(json_members),
                cc_err         :: string,
                cc_bytes       :: list(uint8),
                    % The artefact: none unless the status is 0.
                cc_program     :: string,
                    % The program's file, `D/main.ds`.
                cc_lib_root    :: string,
                    % `-L`'s directory, `D/lib`.
                cc_std_root    :: string
                    % The standard library's directory, or "".
            ).

    % [RCTS.1.2.35]: a fixture is compiled from files when it carries `files`
    % or is `dsc_test_cases`.
    %
:- pred from_files(json::in) is semidet.

from_files(Fixture) :-
    Fixture = j_object(Members),
    (
        lookup_member(Members, "files", _)
    ;
        member_object(Fixture, "expect", Expect),
        member_string(Expect, "kind", "dsc_test_cases")
    ).

    % The fixture in `conformance/Name`, written out under `rcts_files/` and
    % compiled from there. The directory is emptied first, so no companion
    % the fixture does not name is read.
    %
:- pred compile_from_files(string::in, json::in, cli_compile::out,
                           io::di, io::uo) is det.

compile_from_files(Name, Fixture, CC, !IO) :-
    Stem = ( if string.remove_suffix(Name, ".json", S) then S else Name ),
    Dir = "rcts_files/" ++ string.replace_all(Stem, "/", "_"),
    remove_tree(Dir, !IO),
    dir.make_directory(Dir ++ "/lib", _, !IO),
    Source = ( if member_string(Fixture, "rules_ds", R) then R else "" ),
    Program = Dir ++ "/main.ds",
    write_text_file(Program, Source, !IO),
    ( if fixture_libraries(Fixture) = yes(Libraries) then
        list.foldl(write_library(Dir), map.to_assoc_list(Libraries), !IO)
    else
        true
    ),
    ( if
        Fixture = j_object(Members),
        lookup_member(Members, "files", FilesJ),
        FilesJ = j_object(Files)
    then
        list.foldl(write_entry(Dir), members(Files), !IO)
    else
        true
    ),
    harness_dialect_args(DialectArgs, !IO),
    io.get_environment_var("DSC_STDLIB", MaybeStd, !IO),
    ( if MaybeStd = yes(Std), Std \= "" then
        Bundle = bundle_at(Std),
        StdRoot = Std
    else
        % Every compile then exits 2, and the run has already failed
        % (`stdlib_is_read`).
        Bundle = no_bundle("DSC_STDLIB, which is unset"),
        StdRoot = ""
    ),
    Args = ["compile", Program, "-o", Dir ++ "/main.dsc", "-L", Dir ++ "/lib",
        "--diagnostics", "json"] ++ DialectArgs,
    run_cli(Dir, Args, Bundle, Status, Err, !IO),
    ( if Status = 0 then
        read_byte_list(Dir ++ "/main.dsc", Bytes, !IO)
    else
        Bytes = []
    ),
    Diagnostics = ( if cli_diagnostics(Err, Ds) then Ds else [] ),
    CC = cli_compile(Status, Diagnostics, Err, Bytes, Program, Dir ++ "/lib",
        StdRoot).

    % `dsc <Args>` in-process, its four streams over files in `Dir`: the exit
    % status and what it wrote on standard error.
    %
:- pred run_cli(string::in, list(string)::in, bundle::in, int::out,
                string::out, io::di, io::uo) is det.

run_cli(Dir, Args, Bundle, Status, Err, !IO) :-
    write_text_file(Dir ++ "/stdin.txt", "", !IO),
    io.open_input(Dir ++ "/stdin.txt", InRes, !IO),
    io.open_output(Dir ++ "/stdout.txt", OutRes, !IO),
    io.open_binary_output(Dir ++ "/stdout.bin", BinRes, !IO),
    io.open_output(Dir ++ "/stderr.txt", ErrRes, !IO),
    ( if
        InRes = ok(In),
        OutRes = ok(Out),
        BinRes = ok(Bin),
        ErrRes = ok(ErrStream)
    then
        dsc.cli.run(Args, Bundle, cli_streams(In, Out, Bin, ErrStream),
            Status, !IO),
        io.close_input(In, !IO),
        io.close_output(Out, !IO),
        io.close_binary_output(Bin, !IO),
        io.close_output(ErrStream, !IO),
        io.read_named_file_as_string(Dir ++ "/stderr.txt", ErrText, !IO),
        Err = ( if ErrText = ok(E) then E else "" )
    else
        % Distinguishable from every status `run` returns.
        Status = -1,
        Err = "the harness could not open the compile's streams in " ++ Dir
    ).

    % One `-d` per harness dialect, as `harness_registry` registers them.
    %
:- pred harness_dialect_args(list(string)::out, io::di, io::uo) is det.

harness_dialect_args(Args, !IO) :-
    io.read_named_file_as_string("dialects-index.txt", Res, !IO),
    ( if Res = ok(Text) then
        Names = list.filter(non_empty,
            list.map(string.strip, string.split_at_char('\n', Text))),
        Args = list.condense(
            list.map((func(N) = ["-d", "dialects/" ++ N]), Names))
    else
        Args = []
    ).

    % `Dir` and everything under it removed, deepest first, so each directory
    % is empty when it goes.
    %
:- pred remove_tree(string::in, io::di, io::uo) is det.

remove_tree(Dir, !IO) :-
    io.file_type(no, Dir, Type, !IO),
    ( if Type = ok(directory) then
        dir.recursive_foldl2(collect_path, Dir, no, [], Walked, !IO),
        ( if Walked = ok(Paths) then
            Deepest = list.sort(
                ( func(A, B) = Order :-
                    string.length(A, LengthA),
                    string.length(B, LengthB),
                    compare(Order, LengthB, LengthA) ),
                Paths),
            list.foldl(remove_path, Deepest, !IO)
        else
            true
        ),
        remove_path(Dir, !IO)
    else
        true
    ).

:- pred collect_path(string::in, string::in, io.file_type::in, bool::out,
                     list(string)::in, list(string)::out, io::di, io::uo)
    is det.

collect_path(DirName, BaseName, _, yes, !Paths, !IO) :-
    !:Paths = [DirName ++ "/" ++ BaseName | !.Paths].

:- pred remove_path(string::in, io::di, io::uo) is det.

remove_path(Path, !IO) :-
    io.remove_file(Path, _, !IO).

    % `Text` at `Path`, its directory made first.
    %
:- pred write_text_file(string::in, string::in, io::di, io::uo) is det.

write_text_file(Path, Text, !IO) :-
    dir.make_directory(dir.dirname(Path), _, !IO),
    io.open_output(Path, Res, !IO),
    (
        Res = ok(Stream),
        io.write_string(Stream, Text, !IO),
        io.close_output(Stream, !IO)
    ;
        % The compile then misses the file, and the fixture fails on it.
        Res = error(_)
    ).

    % Library `a.b` at `Dir/lib/a/b.ds`, where [LIMP.3.1.4] resolves it.
    %
:- pred write_library(string::in, pair(string, string)::in,
                      io::di, io::uo) is det.

write_library(Dir, Name - Text, !IO) :-
    write_text_file(Dir ++ "/lib/" ++ string.replace_all(Name, ".", "/")
        ++ ".ds", Text, !IO).

:- pred write_entry(string::in, pair(string, json)::in, io::di, io::uo)
    is det.

write_entry(Dir, Path - Value, !IO) :-
    ( if Value = j_string(Text) then
        write_text_file(Dir ++ "/" ++ Path, Text, !IO)
    else
        true
    ).

:- pred read_byte_list(string::in, list(uint8)::out, io::di, io::uo) is det.

read_byte_list(Path, Bytes, !IO) :-
    io.open_binary_input(Path, OpenRes, !IO),
    (
        OpenRes = ok(Stream),
        io.read_binary_file_as_bitmap(Stream, Res, !IO),
        io.close_binary_input(Stream, !IO),
        ( if Res = ok(BM) then
            Bytes = list.map(( func(I) = bitmap.get_uint8(BM, I) ),
                0 .. (bitmap.det_num_bytes(BM) - 1))
        else
            Bytes = []
        )
    ;
        OpenRes = error(_),
        Bytes = []
    ).

    % The diagnostics of `--diagnostics json`'s one document ([RCLI.3.2]).
    %
:- pred cli_diagnostics(string::in, list(json_members)::out) is semidet.

cli_diagnostics(Text, Diagnostics) :-
    ds.json_text.parse(Text, Parsed),
    Parsed = parsed(DocJ),
    DocJ = j_object(Doc),
    lookup_member(Doc, "diagnostics", ItemsJ),
    ItemsJ = j_array(Items),
    list.map((pred(J::in, M::out) is semidet :- J = j_object(M)), Items,
        Diagnostics).

    % The codes a compile from files raised, deduplicated; or, when it
    % raised none and did not compile, its exit status and first error line.
    %
:- func cli_codes(cli_compile) = list(string).

cli_codes(CC) = Codes :-
    Raised = list.sort_and_remove_dups(
        list.filter_map(diagnostic_code, CC ^ cc_diagnostics)),
    ( if Raised = [], CC ^ cc_status \= 0 then
        Codes = [string.format("exit %d: %s",
            [i(CC ^ cc_status), s(first_line(CC ^ cc_err))])]
    else
        Codes = Raised
    ).

:- func diagnostic_code(json_members) = string is semidet.

diagnostic_code(D) = Code :-
    lookup_member(D, "code", CodeJ),
    CodeJ = j_string(Code).

:- func first_line(string) = string.

first_line(Text) =
    ( if string.split_at_char('\n', Text) = [Line | _] then Line else "" ).

    % `compile_ok` from files: compiled, exit 0.
    %
:- func cli_ok_result(string, cli_compile) = fixture_result.

cli_ok_result(Kind, CC) =
    fixture_result(
        ( if CC ^ cc_status = 0 then oc_pass else oc_rejected ),
        Kind, "", cli_codes(CC), []).

    % `compile_error` from files: refused, exit 1, with exactly the error codes
    % the fixture names ([RCTS.1.2.36]); and, with `expected_line`, one with
    % `Code` in the program at that line, the program being `rules_ds`
    % ([RCTS.1.2.34]).
    %
:- func cli_error_result(string, string, list(string), maybe(int), cli_compile)
    = fixture_result.

cli_error_result(Kind, Code, Also, WantLine, CC) =
        fixture_result(Outcome, Kind, Code, Got, []) :-
    Lines = list.filter_map(program_line(Code, CC ^ cc_program),
        CC ^ cc_diagnostics),
    Codes = cli_codes(CC),
    ( if CC ^ cc_status = 0 then
        Outcome = oc_accepted
    else if
        CC ^ cc_status = 1,
        cli_error_codes(CC) = list.sort([Code | Also])
    then
        ( if WantLine = yes(Line), not list.member(Line, Lines) then
            Outcome = oc_wrong_line
        else
            Outcome = oc_pass
        )
    else
        Outcome = oc_wrong_code
    ),
    ( if Lines = [] then
        Got = Codes
    else
        Got = Codes ++ ["at line(s) " ++ string.join_list(", ",
            list.map(string.int_to_string, Lines))]
    ).

    % The error codes a compile from files raised, each once.
    %
:- func cli_error_codes(cli_compile) = list(string).

cli_error_codes(CC) =
    list.sort_and_remove_dups(list.filter_map(
        ( func(D) = C is semidet :-
            not lookup_member(D, "severity", j_string("warning")),
            C = diagnostic_code(D)
        ), CC ^ cc_diagnostics)).

    % The line a diagnostic with `Code` begins on, when its file is the
    % program.
    %
:- func program_line(string, string, json_members) = int is semidet.

program_line(Code, Program, D) = Line :-
    lookup_member(D, "code", CodeJ),
    CodeJ = j_string(Code),
    lookup_member(D, "span", SpanJ),
    SpanJ = j_object(Span),
    lookup_member(Span, "file", FileJ),
    FileJ = j_string(Program),
    lookup_member(Span, "start", StartJ),
    StartJ = j_object(Start),
    lookup_member(Start, "line", LineJ),
    LineJ = j_int(Line64),
    Line = int64.cast_to_int(Line64).

    % [RCTS.1.2.10]'s `dsc_test_cases`: `test_cases`, a list of objects of
    % exactly `test_id`, a positive integer, `name` and `module`, strings.
    % FAILS -- the fixture is malformed -- for anything else.
    %
:- pred test_cases_expectations(json::in, list({int, string, string})::out)
    is semidet.

test_cases_expectations(Expect, Want) :-
    Expect = j_object(Members),
    lookup_member(Members, "test_cases", Found),
    Found = j_array(Items),
    list.map(test_case_entry, Items, Want).

:- pred test_case_entry(json::in, {int, string, string}::out) is semidet.

test_case_entry(J, {Id, Name, Module}) :-
    J = j_object(Entry),
    list.length(members(Entry), Count),
    Count = 3,
    lookup_member(Entry, "test_id", IdJ),
    IdJ = j_int(Id64),
    Id64 >= 1i64,
    Id = int64.cast_to_int(Id64),
    lookup_member(Entry, "name", NameJ),
    NameJ = j_string(Name),
    lookup_member(Entry, "module", ModuleJ),
    ModuleJ = j_string(Module).

    % The TestCases the artefact holds, against `Want`, in order. Exit 0 with
    % no artefact read fails.
    %
:- func test_cases_result(list({int, string, string}), cli_compile)
    = fixture_result.

test_cases_result(Want, CC) = Result :-
    Kind = "dsc_test_cases",
    ( if CC ^ cc_status \= 0 then
        Result = fixture_result(oc_rejected, Kind, "", cli_codes(CC), [])
    else if CC ^ cc_bytes = [] then
        Result = fixture_result(oc_wrong_artefact, Kind, "",
            ["exit 0, and no artefact was read at " ++ CC ^ cc_program], [])
    else
        Got = carried_test_cases(CC),
        ( if Got = Want then
            Result = fixture_result(oc_pass, Kind, "", [], [])
        else
            Result = fixture_result(oc_wrong_artefact, Kind, "",
                list.map(render_case, Got), [])
        )
    ).

:- func render_case({int, string, string}) = string.

render_case({Id, Name, Module}) =
    string.format("%d \"%s\" (%s)", [i(Id), s(Name), s(Module)]).

    % Every TestCase, in atom order: its `test_id`, its name, and the module
    % its `module_id` names through that module's DsSource ([RDSC.4.7]).
    %
:- func carried_test_cases(cli_compile) = list({int, string, string}).

carried_test_cases(CC) = list.map(case_entry(CC, Sources), Cases) :-
    BM = from_bytes(CC ^ cc_bytes),
    Cases = tc_cases(BM),
    Sources = tc_sources(BM).

:- func case_entry(cli_compile, list({uint32, string}),
                   {uint32, string, uint32}) = {int, string, string}.

case_entry(CC, Sources, {Id, Name, ModuleId}) =
        {uint32.cast_to_int(Id), Name, Module} :-
    ( if
        list.find_first_match(
            ( pred(Source::in) is semidet :- Source = {ModuleId, _} ),
            Sources, {_, File})
    then
        Module = module_of(CC, File)
    else
        Module = "<no DsSource for module_id "
            ++ string.int_to_string(uint32.cast_to_int(ModuleId)) ++ ">"
    ).

    % `""` for the program; the dotted name of a library under `-L` or the
    % standard library; else the file as the DsSource gives it, which no
    % expectation names.
    %
:- func module_of(cli_compile, string) = string.

module_of(CC, File) = Module :-
    ( if File = CC ^ cc_program then
        Module = ""
    else if dotted_under(CC ^ cc_lib_root, File, Dotted) then
        Module = Dotted
    else if
        CC ^ cc_std_root \= "",
        dotted_under(CC ^ cc_std_root, File, Dotted)
    then
        Module = Dotted
    else
        Module = File
    ).

:- pred dotted_under(string::in, string::in, string::out) is semidet.

dotted_under(Root, File, Dotted) :-
    string.remove_prefix(Root ++ "/", File, Relative),
    string.remove_suffix(Relative, ".ds", Stem),
    Dotted = string.replace_all(Stem, "/", ".").

    % Every TestCase: its test_id (1), name (2) and module_id (4).
    %
:- func tc_cases(bitmap) = list({uint32, string, uint32}).

tc_cases(BM) = list.map(
    ( func(B) = {tc_body_uint(B, 1u32), tc_body_string(B, 2u32),
        tc_body_uint(B, 4u32)} ),
    tc_atom_bodies(at_test_case, BM)).

    % Every DsSource: its module_id (10) and file (1).
    %
:- func tc_sources(bitmap) = list({uint32, string}).

tc_sources(BM) = list.map(
    ( func(B) = {tc_body_uint(B, 10u32), tc_body_string(B, 1u32)} ),
    tc_atom_bodies(at_ds_source, BM)).

    % The bodies of every frame of one atom, in order. A tail that does not
    % frame ends the walk, and the exact-list comparison then fails.
    %
:- func tc_atom_bodies(atom_id, bitmap) = list(reader).

tc_atom_bodies(Atom, BM) = list.reverse(Rev) :-
    tc_walk_bodies(Atom, init_reader(BM), [], Rev).

:- pred tc_walk_bodies(atom_id::in, reader::in,
                       list(reader)::in, list(reader)::out) is det.

tc_walk_bodies(Atom, R0, !Rev) :-
    next_frame(FrameResult, R0, R1),
    ( if FrameResult = fr_ok(Frame) then
        ( if Frame ^ fr_atom = known(Atom) then
            !:Rev = [Frame ^ fr_body | !.Rev]
        else
            true
        ),
        tc_walk_bodies(Atom, R1, !Rev)
    else
        true
    ).

:- pred tc_body_field(reader::in, uint32::in, field_value::out) is semidet.

tc_body_field(R0, Want, Value) :-
    next_field(FieldResult, R0, R1),
    FieldResult = field(Num, Value0),
    ( if Num = Want then Value = Value0 else tc_body_field(R1, Want, Value) ).

:- func tc_body_uint(reader, uint32) = uint32.

tc_body_uint(R, Num) =
    ( if tc_body_field(R, Num, Value), Value = fv_varint(U) then
        uint32.cast_from_uint64(U)
    else
        0u32
    ).

:- func tc_body_string(reader, uint32) = string.

tc_body_string(R, Num) =
    ( if
        tc_body_field(R, Num, Value),
        Value = fv_bytes(Sub),
        reader_string(Sub, S)
    then
        S
    else
        ""
    ).

    % [RCTS.1.2.10]'s `dsc_test_cases`, shown able to fail: an in-memory
    % compile of a program with two tests, judged against the cases it
    % carries and against each way a list can differ from them. The program's
    % DsSource file stands in for `main.ds`, so this reads no directory. A
    % compile from files that is refused, or leaves no artefact, fails too.
    % @spec [RCTS.1.2.10]
    %
:- pred test_cases_self_test(registry::in, tally::in, tally::out,
                             io::di, io::uo) is det.

test_cases_self_test(Registry, !T, !IO) :-
    Source = "schema Tick scope logical:\n    id: Int key\n\n"
        ++ "schema Tock scope logical:\n    id: Int key\n\n"
        ++ "rule tock:\n    Tick p\n->\n    emit Tock logical id: p.id\n\n"
        ++ "test \"one\":\n    inputs:\n        at 0_s:\n"
        ++ "            Tick id: 1\n    produces:\n        activated tock\n\n"
        ++ "test \"two\":\n    inputs:\n        at 0_s:\n"
        ++ "            Tick id: 2\n    produces:\n        activated tock\n",
    fixture_compile(Registry, as_though("default"), yes(map.init), Source,
        Compiled),
    ( if
        Compiled = compiled(Bytes, _, _),
        BM = from_bytes(Bytes),
        tc_cases(BM) = [{_, _, ModuleId} | _],
        list.find_first_match(
            ( pred(S::in) is semidet :- S = {ModuleId, _} ),
            tc_sources(BM), {_, ProgramFile})
    then
        CC = cli_compile(0, [], "", Bytes, ProgramFile, "lib", ""),
        Judged = ( func(Want) = test_cases_result(Want, CC) ^ r_outcome ),
        Right = [{1, "one", ""}, {2, "two", ""}],
        check("RCTS.1.2.10:dsc_test_cases passes on the cases the artefact "
                ++ "carries",
            ( if Judged(Right) = oc_pass then yes else no ), !T, !IO),
        check("RCTS.1.2.10:and fails on a wrong name, module or test_id, "
                ++ "another order, a case missing or one more",
            ( if
                Judged([{1, "uno", ""}, {2, "two", ""}]) = oc_wrong_artefact,
                Judged([{1, "one", "x"}, {2, "two", ""}]) = oc_wrong_artefact,
                Judged([{1, "one", ""}, {3, "two", ""}]) = oc_wrong_artefact,
                Judged([{2, "two", ""}, {1, "one", ""}]) = oc_wrong_artefact,
                Judged([{1, "one", ""}]) = oc_wrong_artefact,
                Judged(Right ++ [{3, "three", ""}]) = oc_wrong_artefact,
                Judged([]) = oc_wrong_artefact
              then yes else no ), !T, !IO),
        Refused = CC ^ cc_status := 1,
        Empty = CC ^ cc_bytes := [],
        check("RCTS.1.2.10:and on a compile that was refused, or that left "
                ++ "no artefact",
            ( if
                test_cases_result(Right, Refused) ^ r_outcome = oc_rejected,
                test_cases_result(Right, Empty) ^ r_outcome
                    = oc_wrong_artefact
              then yes else no ), !T, !IO)
    else
        check("RCTS.1.2.10:the dsc_test_cases self-test's program compiles, "
                ++ "with its two tests and their DsSource", no, !T, !IO)
    ).

%-----------------------------------------------------------------------------%
% Reading the fixture
%-----------------------------------------------------------------------------%
%
% Bind, then match: `lookup_member(M, Key, j_string(S))` is a mode error.

    % [RCTS.1.2.13]'s `libraries`. A non-object value, or a member that is not
    % a string, is dropped. `no` is the field's absence, which
    % `rcts_1_2_14_libraries` resolves against the standard library alone.
    %
:- func fixture_libraries(json) = maybe(library_sources).

fixture_libraries(Fixture) = Libraries :-
    ( if
        Fixture = j_object(Members),
        lookup_member(Members, "libraries", Found),
        Found = j_object(Sources)
    then
        Libraries = yes(list.foldl(add_library, members(Sources), map.init))
    else
        Libraries = no
    ).

:- func add_library(pair(string, json), library_sources) = library_sources.

add_library(Name - Value, Map) =
    ( if Value = j_string(Source) then map.set(Map, Name, Source) else Map ).

    % `no` when there is none to read: `DSC_STDLIB` unset or empty, the
    % directory unreadable, or no module under it.
    %
:- type stdlib
    --->    stdlib(maybe(library_sources)).

stdlib_is_read(stdlib(yes(_))).

stdlib_sources(stdlib(Modules)) =
    ( if Modules = yes(Found) then Found else map.init ).

read_stdlib(stdlib(Modules), !IO) :-
    io.get_environment_var("DSC_STDLIB", MaybeRoot, !IO),
    ( if MaybeRoot = yes(Root), Root \= "" then
        dir.recursive_foldl2(add_stdlib_module(Root), Root, no, map.init,
            Walked, !IO),
        ( if Walked = ok(Found), not map.is_empty(Found) then
            Modules = yes(Found)
        else
            Modules = no
        )
    else
        Modules = no
    ).

    % One file of the walk: a `.ds` file is the module its path names, read
    % in place, keyed as `dsc_cli`'s `-L` reader keys it; anything else is
    % passed over.
    %
:- pred add_stdlib_module(string::in, string::in, string::in,
                          io.file_type::in, bool::out,
                          library_sources::in, library_sources::out,
                          io::di, io::uo) is det.

add_stdlib_module(Root, DirName, BaseName, FileType, yes, !Modules, !IO) :-
    ( if
        FileType = regular_file,
        stdlib_module_name(Root, DirName, BaseName, Name)
    then
        io.read_named_file_as_string(DirName ++ "/" ++ BaseName, Res, !IO),
        ( if Res = ok(Text) then
            map.set(Name, Text, !Modules)
        else
            % Unreadable is absent: a fixture importing it is then refused
            % with DS_VALIDATE_UNKNOWN_LIBRARY, which names it.
            true
        )
    else
        true
    ).

    % `<root>/units/si.ds` -> `units.si`.
    %
:- pred stdlib_module_name(string::in, string::in, string::in, string::out)
    is semidet.

stdlib_module_name(Root, DirName, BaseName, Name) :-
    string.remove_suffix(BaseName, ".ds", Stem),
    ( if DirName = Root then
        Rel = Stem
    else
        string.remove_prefix(Root ++ "/", DirName, SubDir),
        Rel = SubDir ++ "/" ++ Stem
    ),
    Name = string.replace_all(Rel, "/", ".").

rcts_fixture_format(_, Repeats, _, Format) :-
    Repeats = [_ | _],
    Names = list.map((func(N) = "`" ++ N ++ "`"),
        list.sort_and_remove_dups(Repeats)),
    Format = malformed("RCTS.1.2.1",
        "an object in the fixture repeats the member name(s) "
        ++ string.join_list(", ", Names)).
rcts_fixture_format(Stdlib, [], Fixture, Format) :-
    ( if Fixture = j_object(Members) then
        ( if
            list.find_first_match(
                ( pred(F::in) is semidet :- not lookup_member(Members, F, _) ),
                ["id", "category", "scenario", "rules_ds", "expect"], Absent)
        then
            Format = malformed("RCTS.1.2.1", "no `" ++ Absent ++ "`")
        else if not member_string(Fixture, "rules_ds", _) then
            Format = malformed("RCTS.1.2.1", "`rules_ds` is not a string")
        else if not member_object(Fixture, "expect", _) then
            Format = malformed("RCTS.1.2.1", "`expect` is not an object")
        else if
            member_object(Fixture, "expect", Expect),
            not member_string(Expect, "kind", _)
        then
            Format = malformed("RCTS.1.2.7", "`expect.kind` is not a string")
        else if
            member_object(Fixture, "expect", Expect),
            member_string(Expect, "kind", "malformed_fixture"),
            not member_string(Expect, "reason", _)
        then
            Format = malformed("RCTS.1.2.15",
                "a `malformed_fixture` with no `expect.reason` string")
        else if rcts_1_2_35_files(Fixture, Why) then
            Format = malformed("RCTS.1.2.35", Why)
        else
            rcts_1_2_14_libraries(Stdlib, Fixture, Format)
        )
    else
        Format = malformed("RCTS.1.2.1", "not one JSON object")
    ).

rcts_1_2_3_refusal(Dir, Fixture) = Refusal :-
    ( if not list.member(Dir, rcts_1_1_4_categories) then
        Refusal = yes("the fixture is in `" ++ Dir ++ "/`, which is no "
            ++ "category of [RCTS.1.1.4]")
    else if member_string(Fixture, "category", Dir) then
        Refusal = no
    else if member_string(Fixture, "category", Category) then
        Refusal = yes("`category` is `" ++ Category ++ "`, and the fixture "
            ++ "is in `" ++ Dir ++ "/`")
    else
        Refusal = yes("`category` is not a string")
    ).

    % [RCTS.1.1.4]'s categories.
    %
:- func rcts_1_1_4_categories = list(string).

rcts_1_1_4_categories =
    ["adapter", "compiler", "cross-tier", "logical", "runtime", "temporal"].

    % [RCTS.1.2.35]: why `files`, or a fixture compiled from files, makes the
    % fixture malformed. Fails when neither does. The category refusal's text
    % is `runner.py`'s `_rcts_1_2_35_malformed`'s.
    %
:- pred rcts_1_2_35_files(json::in, string::out) is semidet.

rcts_1_2_35_files(Fixture, Why) :-
    Fixture = j_object(Members),
    Kind = ( if
        member_object(Fixture, "expect", Expect),
        member_string(Expect, "kind", K)
    then K else "" ),
    Category = ( if member_string(Fixture, "category", C) then C else "" ),
    ( if lookup_member(Members, "files", Files) then
        ( if Category \= "compiler" then
            Why = "`files` is the `compiler` category's alone; this "
                ++ "fixture's category is `" ++ Category ++ "`"
        else if
            not list.member(Kind, ["compile_ok", "compile_error",
                "dsc_test_cases"])
        then
            Why = "`files` is read by `compile_ok`, `compile_error` and "
                ++ "`dsc_test_cases` alone; this fixture's kind is `"
                ++ Kind ++ "`"
        else if not Files = j_object(_) then
            Why = "`files` is not an object"
        else if
            Files = j_object(Entries),
            list.find_first_match(not_a_file_entry, members(Entries),
                Path - _)
        then
            Why = "`files` maps `" ++ Path ++ "`, which is not segments of "
                ++ "ASCII letters, digits and `_` joined by `/` and followed "
                ++ "by `.dstest`, or maps it to no string"
        else
            not rcts_1_2_35_use_line(Fixture),
            Why = rcts_1_2_35_no_use_line
        )
    else
        Kind = "dsc_test_cases",
        not rcts_1_2_35_use_line(Fixture),
        Why = rcts_1_2_35_no_use_line
    ).

:- func rcts_1_2_35_no_use_line = string.

rcts_1_2_35_no_use_line = "a fixture compiled from files is compiled as "
    ++ "written, and its program has no `use` line ([LDIA.2.10.1])".

:- pred not_a_file_entry(pair(string, json)::in) is semidet.

not_a_file_entry(Path - Value) :-
    ( not rcts_1_2_35_path(Path)
    ; not Value = j_string(_)
    ).

    % One or more segments joined by `/`, each ASCII letters, digits and `_`
    % not beginning with a digit, the last followed by `.dstest`. So no
    % segment is empty, `.` or `..`, and no path leaves the directory.
    %
:- pred rcts_1_2_35_path(string::in) is semidet.

rcts_1_2_35_path(Path) :-
    string.remove_suffix(Path, ".dstest", Stem),
    list.all_true(rcts_1_2_35_segment, string.split_at_char('/', Stem)).

:- pred rcts_1_2_35_segment(string::in) is semidet.

rcts_1_2_35_segment(Segment) :-
    string.to_char_list(Segment, Chars),
    Chars = [First | Rest],
    ( char.is_alpha(First) ; First = '_' ),
    list.all_true(char.is_alnum_or_underscore, Rest).

    % The program has a `use` line ([LDIA.2.10.1]): a line that is `use`, or
    % begins with it and then a character that cannot continue a name, as
    % `runner.py`'s `_USE_LINE_RE` reads one.
    %
:- pred rcts_1_2_35_use_line(json::in) is semidet.

rcts_1_2_35_use_line(Fixture) :-
    member_string(Fixture, "rules_ds", Source),
    list.member(Line, string.split_at_char('\n', Source)),
    string.remove_prefix("use", Line, Rest),
    ( Rest = ""
    ; string.index(Rest, 0, Next),
      not char.is_alnum_or_underscore(Next)
    ).

    % [RCTS.1.2.13], [RCTS.1.2.14]: the libraries, or why the two keys make the
    % fixture malformed.
    %
:- pred rcts_1_2_14_libraries(stdlib::in, json::in, fixture_format::out)
    is det.

rcts_1_2_14_libraries(stdlib(Std), Fixture, Format) :-
    Own = ( if fixture_libraries(Fixture) = yes(G) then G else map.init ),
    Modules = ( if Std = yes(M) then M else map.init ),
    Both = list.filter((pred(N::in) is semidet :- map.contains(Modules, N)),
        map.keys(Own)),
    ( if
        Fixture = j_object(Members),
        lookup_member(Members, "stdlib", _)
    then
        Format = malformed("RCTS.1.2.14", "the fixture carries `stdlib`: "
            ++ "the standard library is on every fixture's search path")
    else if Both = [_ | _] then
        % A name both supply: malformed, never a choice between them.
        Format = malformed("RCTS.1.2.14",
            "`libraries` and the standard library both supply "
            ++ string.join_list(", ", Both))
    else
        % [RCTS.1.2.13]: the fixture's own libraries, then the standard
        % library, and nothing else.
        Format = well_formed(yes(map.overlay(Modules, Own)))
    ).

malformed_text(well_formed(_)) = "well formed".
malformed_text(malformed(Clause, Why)) = "[" ++ Clause ++ "] " ++ Why.

:- pred member_string(json::in, string::in, string::out) is semidet.

member_string(Object, Key, Value) :-
    Object = j_object(Members),
    lookup_member(Members, Key, Found),
    Found = j_string(Value).

:- pred member_object(json::in, string::in, json::out) is semidet.

member_object(Object, Key, Value) :-
    Object = j_object(Members),
    lookup_member(Members, Key, Found),
    Found = j_object(_),
    Value = Found.

%-----------------------------------------------------------------------------%
% The verdict
%-----------------------------------------------------------------------------%

:- pred report(list(string)::in, list(maybe(fixture_result))::in,
               tally::in, tally::out, io::di, io::uo) is det.

report(Names, Results, !T, !IO) :-
    Full = list.filter_map(corresponding, assoc_from(Names, Results)),
    Pairs = list.map(outcome_pair, Full),
    Unreadable = list.filter_map(unreadable, assoc_from(Names, Results)),

    % 1. Every name in the index opened, parsed, and yielded an outcome.
    (
        Unreadable = [],
        UnreadableOk = yes
    ;
        Unreadable = [_ | _],
        UnreadableOk = no,
        list.foldl(report_unreadable, first_n(10, Unreadable), !IO)
    ),
    check(string.format("every one of the %d corpus fixtures is readable",
        [i(list.length(Names))]), UnreadableOk, !T, !IO),

    census(Pairs, !IO),
    work_list(Full, !IO),

    % 2. Every fixture passes, or is deprecated ([RCTS.1.2.12]: kept, not
    % run). Any other outcome fails the gate.
    NotPassing = list.filter(
        ( pred(_ - O::in) is semidet :- O \= oc_pass, O \= oc_deprecated ),
        Pairs),
    (
        NotPassing = [],
        PassOk = yes
    ;
        NotPassing = [_ | _],
        PassOk = no,
        io.write_string("    fixtures that do not pass:\n", !IO),
        list.foldl(report_not_passing, NotPassing, !IO)
    ),
    check(string.format(
        "every corpus fixture passes or is deprecated (%d do not)",
        [i(list.length(NotPassing))]), PassOk, !T, !IO).

:- pred report_not_passing(pair(string, outcome)::in, io::di, io::uo) is det.

report_not_passing(Name - Outcome, !IO) :-
    io.format("      %s %s\n", [s(Name), s(outcome_name(Outcome))], !IO).

:- func assoc_from(list(string), list(maybe(fixture_result)))
    = assoc_list(string, maybe(fixture_result)).

assoc_from([], _) = [].
assoc_from([_ | _], []) = [].
assoc_from([N | Ns], [R | Rs]) = [N - R | assoc_from(Ns, Rs)].

:- func corresponding(pair(string, maybe(fixture_result))) = pair(string, fixture_result)
    is semidet.

corresponding(Name - yes(Result)) = Name - Result.

:- func outcome_pair(pair(string, fixture_result)) = pair(string, outcome).

outcome_pair(Name - Result) = Name - Result ^ r_outcome.

:- func unreadable(pair(string, maybe(fixture_result))) = string is semidet.

unreadable(Name - no) = Name.

:- pred report_unreadable(string::in, io::di, io::uo) is det.

report_unreadable(Name, !IO) :-
    io.format("    unreadable or malformed fixture: %s\n", [s(Name)], !IO).

%-----------------------------------------------------------------------------%

    % Printed whether or not the gate passes. It counts fixtures; the tally
    % counts the gate's checks.
    %
:- pred census(assoc_list(string, outcome)::in, io::di, io::uo) is det.

census(Pairs, !IO) :-
    list.foldl(count_outcome, Pairs, map.init, Counts),
    io.format("  conformance corpus: %d fixtures\n",
        [i(list.length(Pairs))], !IO),
    list.foldl(report_count(Counts), all_outcomes, !IO).

:- pred count_outcome(pair(string, outcome)::in,
                      map(string, int)::in, map(string, int)::out) is det.

count_outcome(_ - Outcome, !Counts) :-
    Key = outcome_name(Outcome),
    ( if map.search(!.Counts, Key, N) then
        map.det_update(Key, N + 1, !Counts)
    else
        map.det_insert(Key, 1, !Counts)
    ).

:- func all_outcomes = list(outcome).

all_outcomes = [oc_pass, oc_deprecated, oc_stopped, oc_rejected, oc_wrong_code,
    oc_wrong_line, oc_accepted, oc_wrong_artefact, oc_unknown_kind].

:- pred report_count(map(string, int)::in, outcome::in, io::di, io::uo) is det.

report_count(Counts, Outcome, !IO) :-
    Key = outcome_name(Outcome),
    ( if map.search(Counts, Key, N) then
        io.format("    %-14s %d\n", [s(Key), i(N)], !IO)
    else
        true
    ).

%-----------------------------------------------------------------------------%
% The work list
%-----------------------------------------------------------------------------%
%
% The failures, grouped: `accepted` by the code wanted, `unknown-kind` by
% kind, the failing classes by clause prefix, then each queue by name.

:- pred work_list(assoc_list(string, fixture_result)::in, io::di, io::uo)
    is det.

work_list(Full, !IO) :-
    Accepted = list.filter(has_outcome(oc_accepted), Full),
    histogram("the `validate` queue -- codes `accepted` fixtures want",
        list.map(code_of, Accepted), 15, !IO),

    Unmodelled = list.filter(has_outcome(oc_unknown_kind), Full),
    histogram("expectation kinds this harness cannot evaluate",
        list.map(kind_of, Unmodelled), 10, !IO),

    Failing = list.filter(is_failing, Full),
    histogram("gaps by clause family", list.map(prefix_of, Failing), 12, !IO),

    % Every `DS_VALIDATE_RULE_NOT_LOWERED` reason, one count per rule, and
    % the fixtures carrying one, whatever their outcome.
    WithUnlowered = list.filter(
        ( pred(_ - R::in) is semidet :- R ^ r_unlowered = [_ | _] ), Full),
    io.format("  fixtures refused with a rule not lowered: %d\n",
        [i(list.length(WithUnlowered))], !IO),
    histogram("why rules go unlowered",
        list.condense(list.map(( func(_ - R) = R ^ r_unlowered ), Full)),
        40, !IO),
    list.foldl(
        ( pred(Name - R::in, IO0::di, IO::uo) is det :-
            io.format("    %-44s %s\n",
                [s(Name), s(string.join_list(" | ", R ^ r_unlowered))],
                IO0, IO)
        ), WithUnlowered, !IO),

    % Stopped fixtures, by the front end's message.
    Stopped = list.filter(has_outcome(oc_stopped), Full),
    histogram("why fixtures stop -- the front-end queue",
        list.map(stop_message_of, Stopped), 25, !IO),

    % Every fixture that names a front-end code, with what it got, then the
    % stopped fixtures expecting `compile_ok` or a `DS_VALIDATE_*` code.
    FrontCoded = list.filter(front_coded, Full),
    (
        FrontCoded = []
    ;
        FrontCoded = [_ | _],
        io.format("  fixtures that name a lex or parse code (%d):\n",
            [i(list.length(FrontCoded))], !IO),
        list.foldl(report_front_coded, FrontCoded, !IO)
    ),

    Misrouted = list.filter(front_end_should_pass, Stopped),
    (
        Misrouted = []
    ;
        Misrouted = [_ | _],
        io.format("  stopped before the phase they test (%d):\n",
            [i(list.length(Misrouted))], !IO),
        list.foldl(report_rejected, Misrouted, !IO)
    ),

    % Each `rejected` fixture, with the codes raised.
    Rejected = list.filter(has_outcome(oc_rejected), Full),
    (
        Rejected = []
    ;
        Rejected = [_ | _],
        io.format("  legal programs this compiler refuses (%d):\n",
            [i(list.length(Rejected))], !IO),
        list.foldl(report_rejected, first_n(20, Rejected), !IO),
        ( if list.length(Rejected) > 20 then
            io.format("    ... and %d more\n",
                [i(list.length(Rejected) - 20)], !IO)
        else
            true
        )
    ),
    % Each `wrong-code` fixture, with the code wanted beside what was raised.
    WrongCode = list.filter(has_outcome(oc_wrong_code), Full),
    (
        WrongCode = []
    ;
        WrongCode = [_ | _],
        io.format("  refused with a different code (%d):\n",
            [i(list.length(WrongCode))], !IO),
        list.foldl(report_wrong_code, WrongCode, !IO)
    ),
    % Refused with the right code on another line than `expected_line`
    % ([RCTS.1.2.34]): `r_got` ends with the lines it was raised at.
    WrongLine = list.filter(has_outcome(oc_wrong_line), Full),
    (
        WrongLine = []
    ;
        WrongLine = [_ | _],
        io.format("  refused with the code, on another line (%d):\n",
            [i(list.length(WrongLine))], !IO),
        list.foldl(report_wrong_code, WrongLine, !IO)
    ),
    % Compiled into an artefact the fixture's own assertion refuses, with the
    % assertion's message -- the sequence it wanted, or the byte it split at.
    WrongArtefact = list.filter(has_outcome(oc_wrong_artefact), Full),
    (
        WrongArtefact = []
    ;
        WrongArtefact = [_ | _],
        io.format("  compiled into the wrong artefact (%d):\n",
            [i(list.length(WrongArtefact))], !IO),
        list.foldl(report_rejected, WrongArtefact, !IO)
    ).

:- pred report_wrong_code(pair(string, fixture_result)::in, io::di, io::uo)
    is det.

report_wrong_code(Name - Result, !IO) :-
    io.format("    %-44s want %s\n      got  %s\n",
        [s(Name), s(Result ^ r_code),
            s(string.join_list(" ", Result ^ r_got))], !IO).

:- pred report_rejected(pair(string, fixture_result)::in, io::di, io::uo)
    is det.

report_rejected(Name - Result, !IO) :-
    io.format("    %-52s %s\n",
        [s(Name), s(string.join_list(" ", Result ^ r_got))], !IO).

:- pred front_coded(pair(string, fixture_result)::in) is semidet.

front_coded(_ - Result) :-
    ( string.prefix(Result ^ r_code, "DS_LEX_")
    ; string.prefix(Result ^ r_code, "DS_PARSE_")
    ).

:- pred report_front_coded(pair(string, fixture_result)::in, io::di, io::uo)
    is det.

report_front_coded(Name - Result, !IO) :-
    io.format("    %-40s %-10s %s\n      %s\n",
        [s(Name), s(outcome_name(Result ^ r_outcome)), s(Result ^ r_code),
            s(string.join_list(" ", Result ^ r_got))], !IO).

:- pred front_end_should_pass(pair(string, fixture_result)::in) is semidet.

front_end_should_pass(_ - Result) :-
    ( Result ^ r_kind = "compile_ok"
    ; string.prefix(Result ^ r_code, "DS_VALIDATE_")
    ).

:- pred has_outcome(outcome::in, pair(string, fixture_result)::in) is semidet.

has_outcome(Outcome, _ - Result) :-
    Result ^ r_outcome = Outcome.

    % Every outcome but `pass` and `deprecated`; `unknown-kind` included
    % ([RCTS.1.2.7]).
    %
:- pred is_failing(pair(string, fixture_result)::in) is semidet.

is_failing(_ - Result) :-
    ( Result ^ r_outcome = oc_stopped
    ; Result ^ r_outcome = oc_rejected
    ; Result ^ r_outcome = oc_wrong_code
    ; Result ^ r_outcome = oc_wrong_line
    ; Result ^ r_outcome = oc_accepted
    ; Result ^ r_outcome = oc_wrong_artefact
    ; Result ^ r_outcome = oc_unknown_kind
    ).

:- func code_of(pair(string, fixture_result)) = string.

code_of(_ - Result) =
    ( if Result ^ r_code = "" then "(no code named)" else Result ^ r_code ).

:- func stop_message_of(pair(string, fixture_result)) = string.

stop_message_of(_ - Result) = string.join_list(" ", Result ^ r_got).

:- func kind_of(pair(string, fixture_result)) = string.

kind_of(_ - Result) = Result ^ r_kind.

    % The fixture's clause family: `LUNI.7.5_slot_type_alias_rejects.json`
    % becomes `LUNI`: the text before the first `.`, or the whole name when it
    % has none.
    %
:- func prefix_of(pair(string, fixture_result)) = string.

prefix_of(Name - _) = Prefix :-
    ( if string.sub_string_search(Name, ".", At) then
        Prefix = string.left(Name, At)
    else
        Prefix = Name
    ).

    % Sorted on `(-count) - name`: descending counts, ties by name.
    %
:- pred histogram(string::in, list(string)::in, int::in, io::di, io::uo) is det.

histogram(Title, Items, Limit, !IO) :-
    (
        Items = []
    ;
        Items = [_ | _],
        list.foldl(count_item, Items, map.init, Counts),
        Rows = list.sort(list.map(negate_count, map.to_assoc_list(Counts))),
        io.format("  %s (%d):\n", [s(Title), i(list.length(Items))], !IO),
        list.foldl(report_row, first_n(Limit, Rows), !IO),
        ( if list.length(Rows) > Limit then
            io.format("    ... and %d more\n",
                [i(list.length(Rows) - Limit)], !IO)
        else
            true
        )
    ).

:- pred count_item(string::in, map(string, int)::in, map(string, int)::out)
    is det.

count_item(Item, !Counts) :-
    ( if map.search(!.Counts, Item, N) then
        map.det_update(Item, N + 1, !Counts)
    else
        map.det_insert(Item, 1, !Counts)
    ).

:- func negate_count(pair(string, int)) = pair(int, string).

negate_count(Item - N) = (-N) - Item.

:- pred report_row(pair(int, string)::in, io::di, io::uo) is det.

report_row(NegCount - Item, !IO) :-
    io.format("    %4d  %s\n", [i(-NegCount), s(Item)], !IO).

%-----------------------------------------------------------------------------%

:- func first_n(int, list(T)) = list(T).

first_n(N, Xs) = ( if list.take(N, Xs, Taken) then Taken else Xs ).

%-----------------------------------------------------------------------------%
:- end_module test_conformance.
%-----------------------------------------------------------------------------%

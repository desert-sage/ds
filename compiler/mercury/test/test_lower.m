% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% test_lower -- the Mercury runtime's fixtures
% (`runtime/mercury/test/fixtures/*.ds`), compiled with
% `dsc.driver.compile_realtime` and loaded by `ds.dsc.load_dsc`.
%
% Compiled against the standard library (`DSC_STDLIB`), as `dsc` compiles
% them ([LIMP.3.3.1], [LUNI.4.1.2]); a run without one fails.
%
% Each fixture is one check: by default it compiles, loads, and no rule is
% skipped; `expected_refusal` names the fixtures refused, with their codes.
%-----------------------------------------------------------------------------%

:- module test_lower.
:- interface.

:- import_module io.

    % (fixtures as expected, fixtures not).
    %
:- pred run(int::out, int::out, io::di, io::uo) is det.

    % A fixture refused with a `DS_PARSE_*` code. test_cli reads it for
    % `dump-ast`.
    %
:- pred parse_refused(string::in) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.
:- import_module ds.dsc.
:- import_module ds.fault.
:- import_module ds.network.

:- import_module dsc.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.driver.
:- import_module dsc.encode.
:- import_module dsc.imports.
:- import_module test_conformance.

:- import_module bitmap.
:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module string.
:- import_module uint8.

%-----------------------------------------------------------------------------%

:- type row
    --->    row(
                r_name     :: string,
                r_compile  :: string,
                r_load     :: string,
                r_rules    :: int,
                r_terms    :: int,
                r_compiled :: bool,
                r_loaded   :: bool,
                r_skipped  :: list(string),
                    % The `DS_VALIDATE_RULE_NOT_LOWERED` messages.
                r_deferred :: bool
                    % See `deferred_source`.
            ).

run(Pass, Fail, !IO) :-
    io.read_named_file_as_string("lowering-index.txt", IndexRes, !IO),
    (
        IndexRes = error(_),
        io.write_string("  FAIL  lowering: lowering-index.txt is absent; the "
            ++ "runtime fixtures were not staged\n", !IO),
        Pass = 0,
        Fail = 1
    ;
        IndexRes = ok(Text),
        Names = list.filter((pred(N::in) is semidet :- N \= ""),
            list.map(string.strip, string.split_at_char('\n', Text))),
        read_stdlib(Stdlib, !IO),
        Libs = stdlib_sources(Stdlib),
        list.map_foldl(lower_one(Libs), Names, Rows, !IO),
        report(Rows, !IO),
        list.foldl3(gate_row, Rows, 0, Pass0, 0, Fail0, !IO),
        library_checks(Libs, Pass0, Pass, Fail0, Fail, !IO)
    ).

    % The library: it holds `units.core`; an empty one is refused; and a
    % `kilogram` slot is refused without it and compiles with it.
    %
:- pred library_checks(library_sources::in, int::in, int::out,
                       int::in, int::out, io::di, io::uo) is det.

library_checks(Libs, !Pass, !Fail, !IO) :-
    library_check("a standard library holding units.core was read "
            ++ "(DSC_STDLIB)",
        ( if has_core(Libs) then yes else no ), !Pass, !Fail, !IO),
    library_check("an empty library is refused as no standard library",
        ( if has_core(map.init) then no else yes ), !Pass, !Fail, !IO),
    Probe = "use default\n\nschema Box scope logical:\n    id: Int key\n"
        ++ "    weight: kilogram mutable\n",
    compile_realtime(as_though("default"), yes(map.init), dsrt_absent, Probe,
        Bare),
    compile_realtime(as_though("default"), yes(Libs), dsrt_absent, Probe,
        WithLib),
    library_check("a `kilogram` slot is refused with no library and "
            ++ "compiles with the standard library",
        ( if
            not Bare = compiled(_, _, _),
            WithLib = compiled(_, _, _)
        then yes else no ), !Pass, !Fail, !IO).

:- pred has_core(library_sources::in) is semidet.

has_core(Libs) :-
    map.contains(Libs, "units.core").

:- pred library_check(string::in, bool::in, int::in, int::out,
                      int::in, int::out, io::di, io::uo) is det.

library_check(Name, Ok, !Pass, !Fail, !IO) :-
    (
        Ok = yes,
        !:Pass = !.Pass + 1
    ;
        Ok = no,
        !:Fail = !.Fail + 1,
        io.format("  FAIL  lowering: %s\n", [s(Name)], !IO)
    ).

    % One fixture against its expectation.
    %
:- pred gate_row(row::in, int::in, int::out, int::in, int::out,
                 io::di, io::uo) is det.

gate_row(R, !Pass, !Fail, !IO) :-
    Name = R ^ r_name,
    ( if R ^ r_deferred = yes then
        Want = "rejected DS_VALIDATE_REALTIME_DEFERRED",
        Ok = ( if R ^ r_compile = Want then yes else no )
    else if expected_refusal(Name, Code) then
        Want = "rejected " ++ Code,
        % A front-end refusal reports as `stopped <code>: <message>`.
        Ok = ( if
            ( R ^ r_compile = Want
            ; string.prefix(R ^ r_compile, "stopped " ++ Code ++ ":")
            )
        then yes else no )
    else
        Want = "compiled, loaded, no rule skipped",
        Ok = ( if
            R ^ r_compiled = yes,
            R ^ r_loaded = yes,
            R ^ r_skipped = []
        then yes else no )
    ),
    (
        Ok = yes,
        !:Pass = !.Pass + 1
    ;
        Ok = no,
        !:Fail = !.Fail + 1,
        io.format("  FAIL  lowering %s: want %s; got %s / %s%s\n",
            [s(Name), s(Want), s(R ^ r_compile), s(R ^ r_load),
             s(string.join_list("", list.map((func(W) = "; skipped: " ++ W),
                R ^ r_skipped)))], !IO)
    ).

parse_refused(Name) :-
    expected_refusal(Name, Code),
    string.prefix(Code, "DS_PARSE_").

    % Fixtures this compiler must refuse, and the codes, sorted:
    % `compile_corpus.py`'s `_EXPECTED_REJECT`. The `use … (realtime)`
    % fixtures are decided by `r_deferred` instead.
    %
:- pred expected_refusal(string::in, string::out) is semidet.

    % [LEXP.7.1a]: there is no string `+`.
expected_refusal("41_string_plus.ds", "DS_VALIDATE_BAD_OPERAND_TYPE").
    % `series_min` and `series_max` are neither aggregations nor builtins.
expected_refusal("probe_series_minmax_read.ds",
    "DS_VALIDATE_SERIES_AGG_NOT_SUPPORTED DS_VALIDATE_UNKNOWN_FUNCTION").
    % A hydration call names no service, and its `retain:` is refused
    % ([LCRS.6.3.3]).
expected_refusal("55_hydrate.ds",
    "DS_VALIDATE_RETAIN_UNWIRED DS_VALIDATE_UNKNOWN_SERVICE").
    % `persist:` is not in the grammar.
expected_refusal("111_persisted_series.ds", "DS_PARSE_GENERIC").

:- pred lower_one(library_sources::in, string::in, row::out,
                  io::di, io::uo) is det.

lower_one(Stdlib, Name, Row, !IO) :-
    io.read_named_file_as_string("lowering/" ++ Name, Res, !IO),
    (
        Res = error(Error),
        Row = row(Name, "unreadable: " ++ io.error_message(Error), "-", 0, 0,
            no, no, [], no)
    ;
        Res = ok(Source),
        Rules = declared_rules(Source),
        Deferred = deferred_source(Source),
        % As `compile_corpus.py` compiles it: no `.dsrt` ([LCAP.2.1.5]), `use
        % default` where the fixture has no `use` line, and the standard
        % library alone.
        compile_realtime(as_though("default"), yes(Stdlib), dsrt_absent,
            Source, Result),
        (
            Result = compile_stopped(Code, Message, _, _),
            Row = row(Name, "stopped " ++ ds_front_name(Code) ++ ": "
                ++ Message, "-", Rules, 0, no, no, [], Deferred)
        ;
            Result = compile_rejected(Diagnostics),
            Codes = list.sort_and_remove_dups(list.map(
                (func(D) = code_name(D ^ dg_code)), Diagnostics)),
            Row = row(Name, "rejected " ++ string.join_list(" ", Codes), "-",
                Rules, 0, no, no,
                list.filter_map(rule_skip_reason, Diagnostics), Deferred)
        ;
            Result = compiled(Bytes, _, _),
            load_dsc(from_bytes(Bytes), Load),
            (
                Load = loaded(Program),
                Terms = list.length(terminal_nodes(network(Program))),
                Row = row(Name, "compiled", "loaded", Rules, Terms, yes, yes,
                    [], Deferred)
            ;
                Load = load_failed(LoadError),
                Row = row(Name, "compiled", "load failed: "
                    ++ string.string(LoadError ^ le_kind), Rules, 0, yes, no,
                    [], Deferred)
            )
        )
    ).

    % Whether the source's `use` line names `realtime` or `constspace`, which
    % [LCAP.2.1.5] refuses with DS_VALIDATE_REALTIME_DEFERRED. Read off the
    % text, so the expectation does not come from the compiler under test.
    %
:- func deferred_source(string) = bool.

deferred_source(Source) =
    ( if
        list.member(Line, string.split_at_char('\n', Source)),
        string.prefix(Line, "use "),
        ( string.sub_string_search(Line, "realtime", _)
        ; string.sub_string_search(Line, "constspace", _)
        )
    then yes
    else no ).

    % Lines opening with `rule `: not a parse, so it counts a refused source.
    %
:- func declared_rules(string) = int.

declared_rules(Source) =
    list.length(list.filter((pred(L::in) is semidet :-
        string.prefix(L, "rule ")), string.split_at_char('\n', Source))).

:- pred report(list(row)::in, io::di, io::uo) is det.

report(Rows, !IO) :-
    Compiled = list.filter((pred(R::in) is semidet :- R ^ r_compiled = yes),
        Rows),
    Loaded = list.filter((pred(R::in) is semidet :- R ^ r_loaded = yes), Rows),
    Unloadable = list.filter((pred(R::in) is semidet :-
        R ^ r_compiled = yes, R ^ r_loaded = no), Rows),
    Declared = list.foldl((func(R, N) = N + R ^ r_rules), Rows, 0),
    Lowered = list.foldl((func(R, N) = N + R ^ r_terms), Rows, 0),
    io.format("  lowering: %d runtime fixtures -- %d compiled, %d loaded; "
        ++ "%d rules declared, %d terminals loaded\n",
        [i(list.length(Rows)), i(list.length(Compiled)),
            i(list.length(Loaded)), i(Declared), i(Lowered)], !IO),
    (
        Unloadable = []
    ;
        Unloadable = [_ | _],
        io.format("  compiled here, refused by the runtime's loader (%d):\n",
            [i(list.length(Unloadable))], !IO),
        list.foldl(report_row, Unloadable, !IO)
    ),
    io.write_string("  per fixture:\n", !IO),
    list.foldl(report_row, Rows, !IO).

:- pred report_row(row::in, io::di, io::uo) is det.

report_row(R, !IO) :-
    io.format("    %-36s rules %2d  terms %2d  %s  %s\n",
        [s(R ^ r_name), i(R ^ r_rules), i(R ^ r_terms), s(R ^ r_load),
            s(R ^ r_compile)], !IO),
    list.foldl(report_skip, R ^ r_skipped, !IO).

:- pred report_skip(string::in, io::di, io::uo) is det.

report_skip(Why, !IO) :-
    io.format("        rule not lowered: %s\n", [s(Why)], !IO).

    % A `DS_VALIDATE_RULE_NOT_LOWERED` refusal's message.
    %
:- func rule_skip_reason(diagnostic) = string is semidet.

rule_skip_reason(D) = D ^ dg_message :-
    D ^ dg_code = dc_validate(dv_rule_not_lowered).

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

%-----------------------------------------------------------------------------%
:- end_module test_lower.
%-----------------------------------------------------------------------------%

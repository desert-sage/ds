% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% test_cli -- the `dsc` command line, run in-process.
%
% The command line's contract: its exit codes, `-L` both ways, `-d`, standard
% input and output, the refused flags, and what `dump-ast`, `compile-project`,
% `dump-schemas` and `check` write. Each case calls `dsc.cli.run` -- the body
% `dsc_cli.main` runs -- with an argument list and four streams over files, and
% reads back the exit status and what was written. Only `main`'s own three
% lines are outside it.
%
% [RCLI.3.1]'s exit codes are pinned exactly: 3 an internal compiler error, 2
% usage or configuration, 1 a program that does not compile, 0 an artefact. 3
% is the one code `run` never returns, so its cases run the linked `dsc_cli`
% (`cases_internal_error`).
%
% `--diagnostics json` ([RCLI.3.2]) is checked against
% `compiler/dsc_diagnostics.schema.json` itself, staged beside the suite.
% `schema_errors` interprets the keywords the schema uses and refuses any
% other; `cases_validator` shows it can fail.
%
% Run in the suite's own directory, beside the staged `lowering/` fixtures and
% `lowering-index.txt` (which test_lower also reads); every file a case writes
% is named `cli_*` or `smoke_*` there.
%-----------------------------------------------------------------------------%

:- module test_cli.
:- interface.

:- import_module io.

    % Runs the cases: (passed, failed).
    %
:- pred run(int::out, int::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.
:- import_module dsc.cli.

:- import_module test_lower.

:- import_module ds.
:- import_module ds.atom.
:- import_module ds.float_text.
:- import_module ds.json.
:- import_module ds.json_text.
:- import_module ds.re2.
:- import_module ds.wire.

:- import_module bitmap.
:- import_module bool.
:- import_module dir.
:- import_module int.
:- import_module int64.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module string.
:- import_module time.
:- import_module uint32.

%-----------------------------------------------------------------------------%

:- type tally
    --->    tally(
                t_pass :: int,
                t_fail :: int
            ).

:- pred check(string::in, bool::in, tally::in, tally::out, io::di, io::uo)
    is det.

check(Name, Ok, !T, !IO) :-
    (
        Ok = yes,
        !T ^ t_pass := !.T ^ t_pass + 1
    ;
        Ok = no,
        !T ^ t_fail := !.T ^ t_fail + 1,
        io.format("  FAIL  cli: %s\n", [s(Name)], !IO)
    ).

    % What one invocation did: its exit status, its text output, its error
    % output, and its binary output.
    %
:- type outcome
    --->    outcome(
                o_status :: int,
                o_out    :: string,
                o_err    :: string,
                o_bin    :: bitmap
            ).

    % `dsc <Args>`, with `Stdin` as its standard input, as a `dsc` that found
    % the repository's `stdlib/` beside its binary, as every build lays it out
    % ([RCLI.1.11]). The gate names that directory in `DSC_STDLIB`; unset, the
    % bundle is missing and every compile here exits 2, which fails the cases
    % that expect otherwise rather than passing over nothing.
    %
:- pred invoke(list(string)::in, string::in, outcome::out, io::di, io::uo)
    is det.

invoke(Args, Stdin, Outcome, !IO) :-
    io.get_environment_var("DSC_STDLIB", MaybeStdlib, !IO),
    (
        MaybeStdlib = yes(Stdlib),
        Bundle = bundle_at(Stdlib)
    ;
        MaybeStdlib = no,
        Bundle = no_bundle("DSC_STDLIB, which is unset")
    ),
    invoke_bundled(Args, Bundle, Stdin, Outcome, !IO).

    % `dsc <Args>`, as a `dsc` that found `Bundle` beside its binary, or did
    % not.
    %
:- pred invoke_bundled(list(string)::in, bundle::in, string::in,
                       outcome::out, io::di, io::uo) is det.

invoke_bundled(Args, Bundle, Stdin, Outcome, !IO) :-
    write_file("cli_stdin.txt", Stdin, !IO),
    io.open_input("cli_stdin.txt", InRes, !IO),
    io.open_output("cli_out.txt", OutRes, !IO),
    io.open_binary_output("cli_bin.out", BinRes, !IO),
    io.open_output("cli_err.txt", ErrRes, !IO),
    ( if
        InRes = ok(In),
        OutRes = ok(Out),
        BinRes = ok(Bin),
        ErrRes = ok(Err)
    then
        dsc.cli.run(Args, Bundle, cli_streams(In, Out, Bin, Err), Status, !IO),
        io.close_input(In, !IO),
        io.close_output(Out, !IO),
        io.close_binary_output(Bin, !IO),
        io.close_output(Err, !IO),
        read_text("cli_out.txt", OutText, !IO),
        read_text("cli_err.txt", ErrText, !IO),
        read_bytes("cli_bin.out", Bytes, !IO),
        Outcome = outcome(Status, OutText, ErrText, Bytes)
    else
        % Distinguishable from every status `run` returns.
        Outcome = outcome(-1, "", "the case could not open its streams",
            bitmap.init(0))
    ).

:- pred write_file(string::in, string::in, io::di, io::uo) is det.

write_file(Path, Text, !IO) :-
    io.open_output(Path, Res, !IO),
    (
        Res = ok(S),
        io.write_string(S, Text, !IO),
        io.close_output(S, !IO)
    ;
        Res = error(_)
    ).

    % A file's text, or "" when it cannot be read. Every caller checks for
    % content, so an unreadable file fails the check that needed it.
    %
:- pred read_text(string::in, string::out, io::di, io::uo) is det.

read_text(Path, Text, !IO) :-
    io.read_named_file_as_string(Path, Res, !IO),
    ( if Res = ok(T) then Text = T else Text = "" ).

    % A file's bytes, or none when it cannot be read.
    %
:- pred read_bytes(string::in, bitmap::out, io::di, io::uo) is det.

read_bytes(Path, Bytes, !IO) :-
    io.open_binary_input(Path, OpenRes, !IO),
    (
        OpenRes = ok(S),
        io.read_binary_file_as_bitmap(S, Res, !IO),
        io.close_binary_input(S, !IO),
        ( if Res = ok(B) then Bytes = B else Bytes = bitmap.init(0) )
    ;
        OpenRes = error(_),
        Bytes = bitmap.init(0)
    ).

:- pred non_empty_file(string::in, bool::out, io::di, io::uo) is det.

non_empty_file(Path, Ok, !IO) :-
    read_bytes(Path, B, !IO),
    Ok = ( if bitmap.num_bits(B) > 0 then yes else no ).

:- pred absent(string::in, bool::out, io::di, io::uo) is det.

absent(Path, Ok, !IO) :-
    io.file_type(yes, Path, Res, !IO),
    Ok = ( if Res = ok(_) then no else yes ).

:- pred remove(string::in, io::di, io::uo) is det.

remove(Path, !IO) :-
    io.remove_file(Path, _, !IO).

:- pred make_dir(string::in, io::di, io::uo) is det.

make_dir(Path, !IO) :-
    dir.make_directory(Path, _, !IO).

:- func lines(string) = list(string).

lines(Text) = string.split_at_char('\n', Text).

:- func status_is(int, outcome) = bool.

status_is(Want, O) = ( if O ^ o_status = Want then yes else no ).

    % The field numbers of an artefact's DscHeader body, in wire order, read
    % with the runtime's own framing and field readers (`ds.atom`,
    % `ds.wire`). Fails when the artefact has no DscHeader atom or a field
    % does not decode, so the caller's check fails with it.
    %
:- pred dsc_header_fields(bitmap::in, list(uint32)::out) is semidet.

dsc_header_fields(Bytes, Fields) :-
    first_dsc_header(init_reader(Bytes), Body),
    body_fields(Body, [], Fields).

:- pred first_dsc_header(reader::in, reader::out) is semidet.

first_dsc_header(R0, Body) :-
    next_frame(FrameResult, R0, R1),
    FrameResult = fr_ok(Frame),
    ( if Frame ^ fr_atom = known(at_dsc_header) then
        Body = Frame ^ fr_body
    else
        first_dsc_header(R1, Body)
    ).

:- pred body_fields(reader::in, list(uint32)::in, list(uint32)::out)
    is semidet.

body_fields(R0, Acc, Fields) :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, _),
        body_fields(R1, [Num | Acc], Fields)
    ;
        FieldResult = fields_end,
        Fields = list.reverse(Acc)
    ;
        FieldResult = field_error(_),
        fail
    ).

%-----------------------------------------------------------------------------%

run(Pass, Fail, !IO) :-
    some [!T] (
        !:T = tally(0, 0),
        read_text("lowering/06_rule_with_where.ds", Library, !IO),
        ( if Library = "" then
            % Not staged is a failure: cases that pass on no input prove
            % nothing.
            check("lowering/06_rule_with_where.ds is staged", no, !T, !IO)
        else
            Program = "use default\n\n" ++ Library,
            write_file("smoke_prog.ds", Program, !IO),
            cases_compile(!T, !IO),
            cases_import(!T, !IO),
            cases_bundle(!T, !IO),
            test_rdsc_14_2_3_bundled_name_is_install_independent(!T, !IO),
            test_rcli_1_11_no_bundled_library_refuses(!T, !IO),
            cases_project(!T, !IO),
            cases_dump_schemas(!T, !IO),
            cases_dump_schemas_json(!T, !IO),
            cases_dialect(!T, !IO),
            cases_dump_ast(!T, !IO),
            cases_check(Program, Library, !T, !IO),
            cases_stdin(Program, !T, !IO),
            cases_refused(!T, !IO),
            cases_diagnostics(!T, !IO),
            cases_large(!T, !IO),
            cases_byte_indexes(!T, !IO),
            cases_scaling(!T, !IO),
            cases_internal_error(!T, !IO),
            test_rcli_1_4_project_ends_at_exit_3(!T, !IO)
        ),
        Pass = !.T ^ t_pass,
        Fail = !.T ^ t_fail
    ).

    % `--version`, a compile, a library refused, a refusal.
    %
:- pred cases_compile(tally::in, tally::out, io::di, io::uo) is det.

cases_compile(!T, !IO) :-
    invoke(["--version"], "", V, !IO),
    check("`--version` exits 0 and names the compiler",
        ( if V ^ o_status = 0, string.prefix(V ^ o_out, "dsc ") then yes
          else no ), !T, !IO),

    remove("smoke.dsc", !IO),
    invoke(["compile", "smoke_prog.ds", "-o", "smoke.dsc"], "", C, !IO),
    non_empty_file("smoke.dsc", Wrote, !IO),
    check("a program compiles: exit 0, and the artefact is written",
        bool.and(status_is(0, C), Wrote), !T, !IO),

    % [RDSC.3.11]: the same inputs give byte-identical output. The second
    % compile runs later, so anything read from the clock or the process would
    % part them; the path is the same in both ([RDSC.14.2.3]).
    %
    % @spec [RDSC.3.11]
    remove("smoke_again.dsc", !IO),
    invoke(["compile", "smoke_prog.ds", "-o", "smoke_again.dsc"], "", C2, !IO),
    read_bytes("smoke.dsc", First, !IO),
    read_bytes("smoke_again.dsc", Second, !IO),
    check("[RDSC.3.11] compiling the same program twice writes the same bytes",
        ( if
            C2 ^ o_status = 0,
            bitmap.num_bits(First) > 0,
            First = Second
        then yes else no ), !T, !IO),

    % [LDET.1.10]: every artefact carries `compiler_version`, DscHeader field
    % 3. Decoded with the runtime's own readers, so a header that decodes to
    % nothing fails.
    %
    % @spec [LDET.1.10]
    check("[LDET.1.10] the DscHeader carries compiler_version (3)",
        ( if
            dsc_header_fields(First, Fields),
            list.member(3u32, Fields)
        then yes else no ), !T, !IO),

    % [LDIA.2.10.8]: a file with no `use` line is a library, and `compile`
    % refuses to build one.
    invoke(["compile", "lowering/06_rule_with_where.ds", "-o",
        "smoke_lib_only.dsc"], "", L, !IO),
    check("[LDIA.2.10.8] a library given to `compile` exits 1",
        status_is(1, L), !T, !IO),

    % `bogus` is not a declaration keyword, so the front end stops.
    write_file("smoke_bad.ds", "bogus Thing\n", !IO),
    invoke(["compile", "smoke_bad.ds", "-o", "smoke_bad.dsc"], "", B, !IO),
    check("a source the front end stops on exits 1", status_is(1, B), !T, !IO).

    % `-L` both ways: either case alone passes a command line that resolves
    % nothing, or everything. `import util.shapes` alone would not bring
    % `Helper` into scope.
    %
:- pred cases_import(tally::in, tally::out, io::di, io::uo) is det.

cases_import(!T, !IO) :-
    make_dir("smoke_lib/util", !IO),
    write_file("smoke_lib/util/shapes.ds",
        "schema Helper scope logical:\n    id: String key\n", !IO),
    write_file("smoke_importer.ds",
        "use default\n\nfrom util.shapes import Helper\n\nrule r:\n"
        ++ "    Helper\n->\n    log info \"ok\"\n", !IO),
    invoke(["compile", "smoke_importer.ds", "-o", "smoke_imp.dsc",
        "-L", "smoke_lib"], "", With, !IO),
    check("[LIMP.3.1.1] an import resolves under `-L`", status_is(0, With),
        !T, !IO),
    % `dsc.driver` trusts imports when it has no library environment, so a
    % command line that passed none would emit an artefact here.
    invoke(["compile", "smoke_importer.ds", "-o", "smoke_imp2.dsc"], "",
        Without, !IO),
    check("[LIMP.3.1.2] without `-L` the same import is refused, exit 1",
        status_is(1, Without), !T, !IO),
    % [LIMP.2.1.5]: each segment is a NAME, so a file or directory name with a
    % dot in it is no library. `util.shapes` above, in the same `-L`, shows the
    % directory is read.
    write_file("smoke_lib/dotted.leaf.ds",
        "schema Dotted scope logical:\n    id: String key\n", !IO),
    write_file("smoke_dotted_file.ds",
        "use default\n\nfrom dotted.leaf import Dotted\n\nrule r:\n"
        ++ "    Dotted\n->\n    log info \"ok\"\n", !IO),
    invoke(["compile", "smoke_dotted_file.ds", "-o", "smoke_dotted.dsc",
        "-L", "smoke_lib"], "", DottedFile, !IO),
    check("[LIMP.2.1.5] `dotted.leaf.ds` is no library: `import dotted.leaf` "
            ++ "is DS_VALIDATE_UNKNOWN_LIBRARY, exit 1",
        unknown_library(DottedFile), !T, !IO),
    make_dir("smoke_lib/dotted.dir", !IO),
    write_file("smoke_lib/dotted.dir/leaf.ds",
        "schema DirLeaf scope logical:\n    id: String key\n", !IO),
    write_file("smoke_dotted_dir.ds",
        "use default\n\nfrom dotted.dir.leaf import DirLeaf\n\nrule r:\n"
        ++ "    DirLeaf\n->\n    log info \"ok\"\n", !IO),
    invoke(["compile", "smoke_dotted_dir.ds", "-o", "smoke_dotted.dsc",
        "-L", "smoke_lib"], "", DottedDir, !IO),
    check("[LIMP.2.1.5] `dotted.dir/leaf.ds` is no library: `import "
            ++ "dotted.dir.leaf` is DS_VALIDATE_UNKNOWN_LIBRARY, exit 1",
        unknown_library(DottedDir), !T, !IO),
    % [LIMP.2.1.6]: no namespace packages on disk either. `util/shapes.ds`
    % exists and `util.ds` does not, so `import util` is unknown.
    write_file("smoke_namespace.ds",
        "use default\n\nimport util\n\nschema Trig scope logical:\n"
        ++ "    v: Int key\n", !IO),
    invoke(["compile", "smoke_namespace.ds", "-o", "smoke_namespace.dsc",
        "-L", "smoke_lib"], "", Namespace, !IO),
    check("[LIMP.2.1.6] `import util` with only `util/shapes.ds` is "
            ++ "DS_VALIDATE_UNKNOWN_LIBRARY, exit 1",
        unknown_library(Namespace), !T, !IO).

:- func unknown_library(outcome) = bool.

unknown_library(O) =
    ( if
        O ^ o_status = 1,
        string.sub_string_search(O ^ o_err, "DS_VALIDATE_UNKNOWN_LIBRARY", _)
    then yes else no ).

    % [LIMP.3.3.1]: the bundled library is one entry on the search path. It
    % resolves with no `-L`; beside a `-L` holding the same library it is
    % [LIMP.3.1.3]'s ambiguity, which a `run` that dropped the bundle under
    % `-L` would not raise; and named again by `-L` it is one entry. The bundle
    % here is a stand-in directory.
    %
:- pred cases_bundle(tally::in, tally::out, io::di, io::uo) is det.

cases_bundle(!T, !IO) :-
    make_dir("smoke_bundle/util", !IO),
    write_file("smoke_bundle/util/shapes.ds",
        "schema Helper scope logical:\n    id: String key\n", !IO),
    invoke_bundled(["compile", "smoke_importer.ds", "-o", "smoke_bundled.dsc"],
        bundle_at("smoke_bundle"), "", Bundled, !IO),
    check("[LIMP.3.3.1] an import resolves through the bundle, with no `-L`",
        status_is(0, Bundled), !T, !IO),
    invoke_bundled(["compile", "smoke_importer.ds", "-o", "smoke_both.dsc",
        "-L", "smoke_lib"], bundle_at("smoke_bundle"), "", Both, !IO),
    check("[LIMP.3.1.3] the bundle and a `-L` holding one library: exit 1",
        status_is(1, Both), !T, !IO),
    check("[LIMP.3.1.3] ... refused as AMBIGUOUS_LIBRARY",
        ( if string.sub_string_search(Both ^ o_err,
            "DS_VALIDATE_AMBIGUOUS_LIBRARY", _) then yes else no ), !T, !IO),
    invoke_bundled(["compile", "smoke_importer.ds", "-o", "smoke_same.dsc",
        "-L", "smoke_bundle"], bundle_at("smoke_bundle"), "", Same, !IO),
    check("[LIMP.3.3.1] the bundle named again by `-L` is one entry",
        status_is(0, Same), !T, !IO).

    % [RDSC.14.2.3]: a library read from the bundled library is named
    % "`<stdlib>/` followed by its path relative to the bundle's directory
    % ... whatever directory the compiler found the bundle in". One source
    % importing `calendar` from the bundle, and a library of its own from a
    % `-L` entry, is compiled with the bundle at two directories, two copies of
    % the build's library ([RCLI.1.11]). The two artefacts are the same bytes;
    % `calendar`'s DsSource `file` is `<stdlib>/calendar.ds`; the source's own
    % is its [RCLI.1.9] name. The control: the `-L` library is named by the
    % entry's path, so a fix that relabels every library fails here. With the
    % install path as the label, the two artefacts differ, and the first check
    % fails on that alone.
    %
    % @spec [RDSC.14.2.3]
:- pred test_rdsc_14_2_3_bundled_name_is_install_independent(tally::in,
    tally::out, io::di, io::uo) is det.

test_rdsc_14_2_3_bundled_name_is_install_independent(!T, !IO) :-
    io.get_environment_var("DSC_STDLIB", MaybeStdlib, !IO),
    Stdlib = ( if MaybeStdlib = yes(S) then S else "cli_inst_unset" ),
    io.call_system("rm -rf cli_inst_a cli_inst_b cli_inst_lib && "
        ++ "mkdir -p cli_inst_a/share/ds cli_inst_b/opt/x/share/ds "
        ++ "cli_inst_lib && "
        ++ "cp -R '" ++ Stdlib ++ "' cli_inst_a/share/ds/stdlib && "
        ++ "cp -R '" ++ Stdlib ++ "' cli_inst_b/opt/x/share/ds/stdlib",
        CopyRes, !IO),
    write_file("cli_inst_lib/helper.ds",
        "schema Probe scope logical:\n    id: String key\n", !IO),
    write_file("cli_inst.ds",
        "use default\n\nimport calendar\nfrom helper import Probe\n\n"
        ++ "schema Ev scope logical:\n    id: Int key\n    t: Time mutable\n\n"
        ++ "rule late:\n    Ev e where e.t > calendar.time(2026, 1, 1)\n->\n"
        ++ "    log info \"late\"\n\n"
        ++ "rule seen:\n    Probe\n->\n    log info \"seen\"\n", !IO),
    Args = ( func(Out) =
        ["compile", "cli_inst.ds", "-o", Out, "-L", "cli_inst_lib"] ),
    remove("cli_inst_a.dsc", !IO),
    remove("cli_inst_b.dsc", !IO),
    invoke_bundled(Args("cli_inst_a.dsc"),
        bundle_at("cli_inst_a/share/ds/stdlib"), "", A, !IO),
    invoke_bundled(Args("cli_inst_b.dsc"),
        bundle_at("cli_inst_b/opt/x/share/ds/stdlib"), "", B, !IO),
    read_bytes("cli_inst_a.dsc", BytesA, !IO),
    read_bytes("cli_inst_b.dsc", BytesB, !IO),
    Files = ds_source_files(BytesA),
    check("[RDSC.14.2.3] the bundle at two directories compiles to the same "
            ++ "bytes" ++ A ^ o_err ++ B ^ o_err,
        ( if
            CopyRes = ok(0),
            A ^ o_status = 0,
            B ^ o_status = 0,
            bitmap.num_bits(BytesA) > 0,
            BytesA = BytesB
        then yes else no ), !T, !IO),
    check("[RDSC.14.2.3] a library from the bundle is named "
            ++ "`<stdlib>/calendar.ds`: " ++ string.join_list(", ", Files),
        ( if list.member("<stdlib>/calendar.ds", Files) then yes else no ),
        !T, !IO),
    check("[RDSC.14.2.3] the source is named as [RCLI.1.9] names it: "
            ++ string.join_list(", ", Files),
        ( if list.member("cli_inst.ds", Files) then yes else no ), !T, !IO),
    check("[RDSC.14.2.3] the control: a library from a `-L` entry is named by "
            ++ "the entry's path: " ++ string.join_list(", ", Files),
        ( if list.member("cli_inst_lib/helper.ds", Files) then yes else no ),
        !T, !IO).

    % Each DsSource atom's `file` (field 1), in emission order, read with the
    % runtime's own framing and field readers.
    %
:- func ds_source_files(bitmap) = list(string).

ds_source_files(Bytes) = list.reverse(walk_sources(init_reader(Bytes), [])).

:- func walk_sources(reader, list(string)) = list(string).

walk_sources(R0, Acc) = Files :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(at_ds_source) then
            Files = walk_sources(R1, [source_file(Frame ^ fr_body) | Acc])
        else
            Files = walk_sources(R1, Acc)
        )
    ;
        FrameResult = fr_eof,
        Files = Acc
    ;
        FrameResult = fr_error(_, _),
        Files = Acc
    ).

:- func source_file(reader) = string.

source_file(R0) = File :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        ( if Num = 1u32, Value = fv_bytes(F), reader_string(F, S) then
            File = S
        else
            File = source_file(R1)
        )
    ;
        FieldResult = fields_end,
        File = ""
    ;
        FieldResult = field_error(_),
        File = ""
    ).

    % [RCLI.1.11]: a compiler that does not find its bundled library resolves
    % nothing. One program, which reads `5_kg` with no import, so it needs
    % `units.core` ([LUNI.4.1.2]):
    %   - with no bundle, `compile`, `compile-project` and `dump-schemas` exit 2
    %     and name where they looked, and write nothing; `dump-ast`, which
    %     resolves no name, exits 0;
    %   - the control: the same program with the bundle compiles, exit 0, and
    %     the artefact is written.
    % Then through the real program, to drive `dsc_cli`'s lookup too
    % ([STYL.5.10.8]): copied away from `../share/ds/stdlib` it refuses, and
    % laid out as the build leaves it, it compiles.
    %
    % One underscore after the id: Mercury reads `a__b` as `b` qualified by
    % module `a`, so the `@spec` line is the link ([STYL.5.3.6.3]).
    %
    % @spec [RCLI.1.11]
:- pred test_rcli_1_11_no_bundled_library_refuses(tally::in, tally::out,
                                                  io::di, io::uo) is det.

test_rcli_1_11_no_bundled_library_refuses(!T, !IO) :-
    write_file("cli_kg.ds", "use default\n\nschema Box scope logical:\n"
        ++ "    id: Int key\n    weight: kilogram mutable\n\nrule r:\n"
        ++ "    Box b where b.weight > 5_kg\n->\n    log info \"heavy\"\n", !IO),
    Missing = no_bundle("cli_nowhere/share/ds/stdlib"),
    remove("cli_kg_none.dsc", !IO),
    invoke_bundled(["compile", "cli_kg.ds", "-o", "cli_kg_none.dsc"], Missing,
        "", Compile, !IO),
    absent("cli_kg_none.dsc", NoArtefact, !IO),
    check("[RCLI.1.11] with no bundle, `compile` exits 2, names where it "
            ++ "looked, and writes nothing",
        ( if
            Compile ^ o_status = 2,
            string.sub_string_search(Compile ^ o_err,
                "cli_nowhere/share/ds/stdlib", _),
            NoArtefact = yes
        then yes else no ), !T, !IO),
    make_dir("cli_kg_sketch/rules", !IO),
    write_file("cli_kg_sketch/rules/a.ds", "use default\n\nschema S:\n"
        ++ "    v: Int\n", !IO),
    invoke_bundled(["compile-project", "cli_kg_sketch"], Missing, "", Project,
        !IO),
    check("[RCLI.1.11] with no bundle, `compile-project` exits 2",
        status_is(2, Project), !T, !IO),
    invoke_bundled(["dump-schemas", "cli_kg.ds"], Missing, "", Dump, !IO),
    check("[RCLI.1.11] with no bundle, `dump-schemas` exits 2",
        status_is(2, Dump), !T, !IO),
    invoke_bundled(["dump-ast", "cli_kg.ds"], Missing, "", Ast, !IO),
    check("[RCLI.1.11] with no bundle, `dump-ast` still exits 0",
        ( if
            Ast ^ o_status = 0,
            string.prefix(Ast ^ o_out, "{\"_type\":\"Module\"")
        then yes else no ), !T, !IO),
    remove("cli_kg.dsc", !IO),
    invoke(["compile", "cli_kg.ds", "-o", "cli_kg.dsc"], "", Bundled, !IO),
    non_empty_file("cli_kg.dsc", Wrote, !IO),
    check("[RCLI.1.11] the control: with the bundle, `5_kg` compiles, exit 0, "
            ++ "and the artefact is written",
        bool.and(status_is(0, Bundled), Wrote), !T, !IO),

    % A copy, not a link: a copy has no target to follow, so it looks beside
    % itself.
    remove("cli_kg_bin.dsc", !IO),
    remove("cli_kg_nolib.dsc", !IO),
    io.call_system("mkdir -p cli_nolib/bin && cp dsc_cli cli_nolib/bin/dsc",
        CopyRes, !IO),
    io.call_system("cli_nolib/bin/dsc compile cli_kg.ds -o cli_kg_nolib.dsc "
        ++ "2> cli_nolib_err.txt", NoLibRes, !IO),
    read_text("cli_nolib_err.txt", NoLibErr, !IO),
    absent("cli_kg_nolib.dsc", NoLibNone, !IO),
    check("[RCLI.1.11] `dsc_cli` copied away from its library exits 2, naming "
            ++ "`cli_nolib/bin/../share/ds/stdlib`, and writes nothing",
        ( if
            CopyRes = ok(0),
            NoLibRes = ok(2),
            string.sub_string_search(NoLibErr,
                "cli_nolib/bin/../share/ds/stdlib", _),
            NoLibNone = yes
        then yes else no ), !T, !IO),
    io.call_system("./dsc_cli compile cli_kg.ds -o cli_kg_bin.dsc", BinRes,
        !IO),
    non_empty_file("cli_kg_bin.dsc", BinWrote, !IO),
    check("[RCLI.1.11] the control: `dsc_cli` as the build lays it out finds "
            ++ "its library and compiles, exit 0",
        ( if BinRes = ok(0), BinWrote = yes then yes else no ), !T, !IO),
    test_rcli_1_11_a_link_is_followed(!T, !IO).

    % [RCLI.1.11]: "A symbolic link to the compiler is followed. The directory
    % that holds the executable is the one that holds the file itself, with
    % every link on the way to it resolved ... A chain of links that ends
    % nowhere, or that does not end, is a compiler that does not find the
    % library." Each link leads to the built `dsc_cli` in this directory,
    % which finds its library beside it (the control above), and sits where no
    % `../share/ds/stdlib` is, so a link that was not followed exits 2:
    %   - a link in another directory, invoked by path, to `dsc_cli` by an
    %     absolute target;
    %   - the same link reached through `PATH` by its bare name;
    %   - a link to that link, by a relative target;
    %   - a loop of two links: no library, exit 2, nothing written. No shell
    %     can execute a loop, so the lookup is asked in-process with the
    %     loop's path as the program name, and its answer drives `run`. That
    %     it answers at all is what shows the walk is bounded.
    % The copy above, away from its library, still exits 2.
    %
    % @spec [RCLI.1.11]
:- pred test_rcli_1_11_a_link_is_followed(tally::in, tally::out,
                                          io::di, io::uo) is det.

test_rcli_1_11_a_link_is_followed(!T, !IO) :-
    list.foldl(remove, ["cli_kg_link.dsc", "cli_kg_path.dsc",
        "cli_kg_chain.dsc", "cli_kg_loop.dsc"], !IO),
    io.call_system("mkdir -p cli_link/bin && "
        ++ "ln -sfn \"$PWD/dsc_cli\" cli_link/bin/dsc", LinkRes, !IO),
    io.call_system("cli_link/bin/dsc compile cli_kg.ds -o cli_kg_link.dsc",
        LinkRun, !IO),
    non_empty_file("cli_kg_link.dsc", LinkWrote, !IO),
    check("[RCLI.1.11] a link to `dsc_cli` in another directory, invoked by "
            ++ "path, finds the library beside its target: exit 0, and the "
            ++ "artefact is written",
        ( if LinkRes = ok(0), LinkRun = ok(0), LinkWrote = yes
          then yes else no ), !T, !IO),
    io.call_system("PATH=\"$PWD/cli_link/bin:$PATH\" "
        ++ "dsc compile cli_kg.ds -o cli_kg_path.dsc", PathRun, !IO),
    non_empty_file("cli_kg_path.dsc", PathWrote, !IO),
    check("[RCLI.1.11] the same link reached through PATH by its bare name: "
            ++ "exit 0, and the artefact is written",
        ( if PathRun = ok(0), PathWrote = yes then yes else no ), !T, !IO),
    io.call_system("mkdir -p cli_chain/bin && "
        ++ "ln -sfn ../../cli_link/bin/dsc cli_chain/bin/dsc", ChainRes, !IO),
    io.call_system("cli_chain/bin/dsc compile cli_kg.ds -o cli_kg_chain.dsc",
        ChainRun, !IO),
    non_empty_file("cli_kg_chain.dsc", ChainWrote, !IO),
    check("[RCLI.1.11] a link to a link, by a relative target: exit 0, and "
            ++ "the artefact is written",
        ( if ChainRes = ok(0), ChainRun = ok(0), ChainWrote = yes
          then yes else no ), !T, !IO),
    io.call_system("mkdir -p cli_loop/bin && "
        ++ "ln -sfn dsc_b cli_loop/bin/dsc_a && "
        ++ "ln -sfn dsc_a cli_loop/bin/dsc_b", LoopRes, !IO),
    limp_3_3_1_bundled_library("cli_loop/bin/dsc_a", LoopBundle, !IO),
    invoke_bundled(["compile", "cli_kg.ds", "-o", "cli_kg_loop.dsc"],
        LoopBundle, "", Loop, !IO),
    absent("cli_kg_loop.dsc", LoopNone, !IO),
    check("[RCLI.1.11] a loop of links is a compiler with no library: the "
            ++ "lookup returns no bundle, and `compile` exits 2 and writes "
            ++ "nothing",
        ( if
            LoopRes = ok(0),
            LoopBundle = no_bundle(_),
            Loop ^ o_status = 2,
            LoopNone = yes
        then yes else no ), !T, !IO).

    % compile-project: a sketch with two rule files, one in a subdirectory,
    % yields a `.dsc` and a `_dsc.h` beside each, the header naming the symbol
    % the reference's rule gives (`sub/b.ds` -> `B_DSC`).
    %
:- pred cases_project(tally::in, tally::out, io::di, io::uo) is det.

cases_project(!T, !IO) :-
    read_text("smoke_prog.ds", Program, !IO),
    make_dir("smoke_sketch/rules/sub", !IO),
    write_file("smoke_sketch/rules/a.ds", Program, !IO),
    write_file("smoke_sketch/rules/sub/b.ds", Program, !IO),
    Outputs = ["smoke_sketch/rules/a.dsc", "smoke_sketch/rules/a_dsc.h",
               "smoke_sketch/rules/sub/b.dsc", "smoke_sketch/rules/sub/b_dsc.h"],
    list.foldl(remove, Outputs, !IO),
    invoke(["compile-project", "smoke_sketch"], "", P, !IO),
    check("[RCLI.1.4] `compile-project` exits 0", status_is(0, P), !T, !IO),
    list.foldl2(
        ( pred(F::in, T0::in, T1::out, IO0::di, IO1::uo) is det :-
            non_empty_file(F, Ok, IO0, IO2),
            check("[RCLI.1.4] `compile-project` writes " ++ F, Ok, T0, T1,
                IO2, IO1) ),
        Outputs, !T, !IO),
    read_text("smoke_sketch/rules/sub/b_dsc.h", Header, !IO),
    check("[RCLI.1.4] `sub/b.ds`'s header names B_DSC_LEN",
        ( if string.sub_string_search(Header, "B_DSC_LEN", _) then yes
          else no ), !T, !IO).

    % dump-schemas: the proto3 header, and a message for the schema the
    % source declares. Checked by content, because an empty stdout exits 0 too.
    %
:- pred cases_dump_schemas(tally::in, tally::out, io::di, io::uo) is det.

cases_dump_schemas(!T, !IO) :-
    invoke(["dump-schemas", "lowering/06_rule_with_where.ds"], "", D, !IO),
    Ls = lines(D ^ o_out),
    check("[RCLI.1.5] `dump-schemas` exits 0 with the package line",
        ( if D ^ o_status = 0, list.member("package ds.dsc.user.v1;", Ls)
          then yes else no ), !T, !IO),
    check("[RCLI.1.5] `dump-schemas` writes a message",
        ( if list.any_true(starts_with("message "), Ls) then yes
          else no ), !T, !IO),
    % The dump's fields are the SchemaDef's: a `T?` slot is `optional`, a
    % `Time` slot `int64`. Both labels, since dropping or writing `optional`
    % everywhere still yields a message.
    write_file("smoke_nullable.ds",
        "use default\n\nschema Sighting scope logical:\n    id: String key\n"
        ++ "    seen: Time? mutable\n", !IO),
    invoke(["dump-schemas", "smoke_nullable.ds"], "", N, !IO),
    NLs = lines(N ^ o_out),
    check("[RCLI.1.5] a key slot is a plain string field",
        ( if list.member("  string id = 1;", NLs) then yes else no ), !T, !IO),
    check("[RCLI.1.5] a `Time?` slot is an optional int64 field",
        ( if list.member("  optional int64 seen = 2;", NLs) then yes else no ),
        !T, !IO).

:- pred starts_with(string::in, string::in) is semidet.

starts_with(Prefix, S) :-
    string.prefix(S, Prefix).

    % `dump-schemas --json` ([RCLI.1.14]) over one program whose schema holds
    % every kind of slot the clause names, then the same document against the
    % committed schema. With `-o` it writes the same document; an input the
    % proto3 form refuses writes none.
    %
:- pred cases_dump_schemas_json(tally::in, tally::out, io::di, io::uo) is det.

cases_dump_schemas_json(!T, !IO) :-
    write_file("cli_units.ds",
        "use default\n\nfrom math import log2\n\n"
        ++ "unit celsius: temperature = x + 273.15 label \"°C\" alias degC\n\n"
        ++ "unit dimension loudness storage float64 base sone\n"
        ++ "unit sone: loudness\n"
        ++ "unit phon: loudness:\n"
        ++ "    to_base:   2.0 ** ((x - 40.0) / 10.0)\n"
        ++ "    from_base: 10.0 * log2(x) + 40.0\n\n"
        ++ "schema Room scope explicit:\n"
        ++ "    warmth: celsius\n"
        ++ "    noise: phon\n"
        ++ "    heat: temperature\n"
        ++ "    wait: second\n"
        ++ "    level: Float\n"
        ++ "    peak: kelvin?\n", !IO),
    invoke(["dump-schemas", "cli_units.ds", "--json"], "", D, !IO),
    ds.json_text.parse(D ^ o_out, Parsed),
    ( if Parsed = parsed(Doc0) then MaybeDoc = yes(Doc0) else MaybeDoc = no ),
    test_rcli_1_14_dump_schemas_json_units(D, MaybeDoc, !T, !IO),
    test_rcli_1_14_dump_schemas_json_validates(D, MaybeDoc, !T, !IO),

    remove("cli_units.json", !IO),
    invoke(["dump-schemas", "cli_units.ds", "--json", "-o", "cli_units.json"],
        "", ToFile, !IO),
    read_text("cli_units.json", Written, !IO),
    check("[RCLI.1.14] with `-o`, the same document is written to the file, "
            ++ "and nothing to standard output",
        ( if
            ToFile ^ o_status = 0,
            ToFile ^ o_out = "",
            Written = D ^ o_out,
            Written \= ""
        then yes else no ), !T, !IO),
    write_file("cli_units_bad.ds",
        "use default\n\nschema Bad scope explicit:\n    v: no_such_unit\n", !IO),
    invoke(["dump-schemas", "cli_units_bad.ds", "--json"], "", Bad, !IO),
    check("[RCLI.1.14] an input `dump-schemas` refuses writes no document: "
            ++ "exit 1, and nothing on standard output",
        ( if Bad ^ o_status = 1, Bad ^ o_out = "" then yes else no ),
        !T, !IO).

    % [RCLI.1.14]: each slot's unit, by what its type names. Path: `dsc.cli`'s
    % `dump-schemas` with `--json`, `dsc.driver.rcli_1_14_schemas_json` and its
    % unit resolution, and `dsc.quantity.rcli_1_14_baked_line`. A dump that
    % wrote the alias, a host-formatted float or the unbaked Rational fails:
    % the constants are checked as the Float's canonical text
    % ([LDET.3.2.7]), as written.
    %
    % @spec [RCLI.1.14]
:- pred test_rcli_1_14_dump_schemas_json_units(outcome::in, maybe(json)::in,
    tally::in, tally::out, io::di, io::uo) is det.

test_rcli_1_14_dump_schemas_json_units(D, MaybeDoc, !T, !IO) :-
    check("[RCLI.1.14] `dump-schemas --json` exits 0 with one JSON document"
            ++ D ^ o_err,
        ( if D ^ o_status = 0, MaybeDoc = yes(_) then yes else no ), !T, !IO),
    Doc = ( if MaybeDoc = yes(Doc1) then Doc1 else j_null ),
    Affine = ( func(A, B) = "{\"kind\":\"affine\",\"a\":"
        ++ ds.float_text.canonical(A) ++ ",\"b\":"
        ++ ds.float_text.canonical(B) ++ "}" ),
    check("[RCLI.1.14] a slot typed by a unit with an alias names the canonical "
            ++ "symbol, its label, dimension, base and storage",
        ( if
            room_slot(Doc, "warmth", Warmth),
            member_is(Warmth, "type", j_string("celsius")),
            member_is(Warmth, "nullable", j_bool(no)),
            member_is(Warmth, "unit", Unit),
            member_is(Unit, "declared", j_string("celsius")),
            member_is(Unit, "label", j_string("°C")),
            member_is(Unit, "dimension", j_string("temperature")),
            member_is(Unit, "base", j_string("kelvin")),
            member_is(Unit, "storage", j_string("float64"))
        then yes else no ), !T, !IO),
    check("[RCLI.1.14] a tier-1 unit's conversion is the baked line, a = 1.0 "
            ++ "and b = 273.15, as canonical Float text",
        ( if
            room_slot(Doc, "warmth", W),
            member_is(W, "unit", WU),
            member_is(WU, "conversion", j_object(_)),
            string.sub_string_search(D ^ o_out,
                "\"name\":\"warmth\"", WarmthAt),
            string.sub_string_search_start(D ^ o_out,
                "\"conversion\":" ++ Affine(1.0, 273.15), WarmthAt, _)
        then yes else no ), !T, !IO),
    check("[RCLI.1.14] a tier-2 unit's conversion is `tier2`, with no constants",
        ( if
            room_slot(Doc, "noise", Noise),
            member_is(Noise, "unit", NU),
            member_is(NU, "declared", j_string("phon")),
            member_is(NU, "base", j_string("sone")),
            member_is(NU, "conversion", j_object(C)),
            members(C) = ["kind" - j_string("tier2")]
        then yes else no ), !T, !IO),
    check("[RCLI.1.14] a slot typed by its dimension names no unit: declared, "
            ++ "label and conversion are null",
        ( if
            room_slot(Doc, "heat", Heat),
            member_is(Heat, "unit", HU),
            member_is(HU, "declared", j_null),
            member_is(HU, "label", j_null),
            member_is(HU, "conversion", j_null),
            member_is(HU, "dimension", j_string("temperature")),
            member_is(HU, "base", j_string("kelvin"))
        then yes else no ), !T, !IO),
    check("[RCLI.1.14] a `time` slot is stored int64, and its `a` is the "
            ++ "unit's nanosecond factor as a canonical Float",
        ( if
            room_slot(Doc, "wait", Wait),
            member_is(Wait, "unit", TU),
            member_is(TU, "declared", j_string("second")),
            member_is(TU, "storage", j_string("int64")),
            string.sub_string_search(D ^ o_out, "\"name\":\"wait\"", WaitAt),
            string.sub_string_search_start(D ^ o_out,
                "\"conversion\":" ++ Affine(1.0e9, 0.0), WaitAt, _)
        then yes else no ), !T, !IO),
    check("[RCLI.1.14] a `Float` slot's unit is null",
        ( if
            room_slot(Doc, "level", Level),
            member_is(Level, "type", j_string("Float")),
            member_is(Level, "unit", j_null)
        then yes else no ), !T, !IO),
    check("[RCLI.1.14] a nullable slot is `nullable`, and its type has no `?`; "
            ++ "a base unit's line is 1.0 and 0.0",
        ( if
            room_slot(Doc, "peak", Peak),
            member_is(Peak, "type", j_string("kelvin")),
            member_is(Peak, "nullable", j_bool(yes)),
            member_is(Peak, "unit", PU),
            member_is(PU, "declared", j_string("kelvin")),
            string.sub_string_search(D ^ o_out, "\"name\":\"peak\"", PeakAt),
            string.sub_string_search_start(D ^ o_out,
                "\"conversion\":" ++ Affine(1.0, 0.0), PeakAt, _)
        then yes else no ), !T, !IO).

    % [RCLI.1.14]: the document validates against the committed
    % `compiler/dsc_schemas.schema.json`, staged beside the suite, so a member
    % the schema refuses or lacks fails. The validator shows it can fail on
    % this schema's keywords: the same document broken through `const`,
    % `oneOf`, a type array, `number` and `enum`, each refused.
    %
    % @spec [RCLI.1.14]
:- pred test_rcli_1_14_dump_schemas_json_validates(outcome::in, maybe(json)::in,
    tally::in, tally::out, io::di, io::uo) is det.

test_rcli_1_14_dump_schemas_json_validates(D, MaybeDoc, !T, !IO) :-
    read_text("dsc_schemas.schema.json", SchemaText, !IO),
    ds.json_text.parse(SchemaText, SchemaRes),
    (
        SchemaRes = parsed(Schema),
        check("[RCLI.1.14] the document validates against "
                ++ "dsc_schemas.schema.json"
                ++ ( if MaybeDoc = yes(Doc) then
                        string.join_list("; ", schema_errors(Schema, Doc))
                     else " -- it does not parse" ),
            ( if MaybeDoc = yes(Doc2), schema_errors(Schema, Doc2) = []
              then yes else no ), !T, !IO),
        list.foldl2(
            ( pred(Case::in, T0::in, T1::out, IO0::di, IO1::uo) is det :-
                Case = {Name, Old, New},
                check("[RCLI.1.14] the validator refuses " ++ Name,
                    ( if
                        string.replace(D ^ o_out, Old, New, Broken),
                        validates(Schema, Broken) = no
                    then yes else no ), T0, T1, IO0, IO1) ),
            [   {"a conversion of another kind (`const`, `oneOf`)",
                    "\"kind\":\"tier2\"", "\"kind\":\"tier3\""},
                {"a label that is a number (a type array)",
                    "\"label\":null", "\"label\":7"},
                {"a constant that is a string (`number`)",
                    "\"b\":" ++ ds.float_text.canonical(273.15),
                    "\"b\":\"273.15\""},
                {"a storage of another kind (`enum`)",
                    "\"int64\"", "\"int16\""},
                {"a member the unit does not declare (`additionalProperties`)",
                    "\"declared\":", "\"extra\":0,\"declared\":"}
            ], !T, !IO)
    ;
        SchemaRes = refused(_),
        check("[RCLI.1.14] dsc_schemas.schema.json is staged and parses",
            no, !T, !IO)
    ).

    % The slot named `Name` of the document's schema `Room`.
    %
:- pred room_slot(json::in, string::in, json::out) is semidet.

room_slot(Doc, Name, Slot) :-
    member_is(Doc, "schemas", j_array(Schemas)),
    list.find_first_match(
        ( pred(S::in) is semidet :- member_is(S, "name", j_string("Room")) ),
        Schemas, Room),
    member_is(Room, "slots", j_array(Slots)),
    list.find_first_match(
        ( pred(S::in) is semidet :- member_is(S, "name", j_string(Name)) ),
        Slots, Slot).

:- pred member_is(json::in, string::in, json::out) is semidet.

member_is(j_object(Members), Key, Value) :-
    lookup_member(Members, Key, Value).

    % `-d` ([NDLC.2.1]): it admits a `call` and refuses a `publish`, since
    % either alone passes a command line that gates nothing. A dialect file
    % missing a capability ([NDLC.2.2]) and `--dialect` are configuration
    % errors, exit 2.
    %
:- pred cases_dialect(tally::in, tally::out, io::di, io::uo) is det.

cases_dialect(!T, !IO) :-
    write_file("smoke_bu.yaml", string.join_list("\n", [
        "name: smoke_bu",
        "settings:",
        "  realtime: false",
        "  constspace: false",
        "  linear_scan: false",
        "  logical: false",
        "  dynamic_ttl: false",
        "  regex: true",
        "  float: false",
        "  call: true",
        "  publish: false",
        "  cache: false",
        "  cache_delete: false",
        "  nocooldown: true",
        "  series: false",
        "  sampled_slots: false",
        "  persist_on_series: false",
        "  storage_hydrate_facts: false",
        "  storage_hydrate_samples: false",
        ""]), !IO),
    write_file("smoke_call.ds",
        "use smoke_bu\n\nservice svc.method:\n    \"\"\"stub\"\"\"\n"
        ++ "    no response\n\nschema Trig:\n    v: Int\n\nrule r:\n    Trig\n"
        ++ "->\n    call svc.method nocooldown\n", !IO),
    write_file("smoke_publish.ds",
        "use smoke_bu\n\nschema Trig:\n    v: Int\n\nschema Local:\n"
        ++ "    a: Int\n\nrule r:\n    Trig\n->\n    publish Local a: 1\n", !IO),
    write_file("smoke_bad_dialect.yaml", "name: smoke_bad\nsettings:\n"
        ++ "  call: true\n", !IO),
    invoke(["compile", "smoke_call.ds", "-o", "smoke_call.dsc",
        "-d", "smoke_bu.yaml"], "", Call, !IO),
    check("[NDLC.2.1] `-d`: an enabled capability compiles",
        status_is(0, Call), !T, !IO),
    invoke(["compile", "smoke_publish.ds", "-o", "smoke_publish.dsc",
        "-d", "smoke_bu.yaml"], "", Publish, !IO),
    check("[NDLC.2.1] `-d`: a disabled capability exits 1",
        status_is(1, Publish), !T, !IO),
    invoke(["compile", "smoke_call.ds", "-o", "smoke_x.dsc",
        "-d", "smoke_bad_dialect.yaml"], "", Bad, !IO),
    check("[NDLC.2.2] `-d`: a dialect missing a capability exits 2",
        status_is(2, Bad), !T, !IO),
    invoke(["compile", "smoke_call.ds", "-o", "smoke_x.dsc",
        "-d", "smoke_bu.yaml", "--dialect", "smoke_bu"], "", Retired, !IO),
    check("`--dialect`: the retired fallback exits 2",
        status_is(2, Retired), !T, !IO).

    % dump-ast: every staged fixture dumps JSON naming its root, counted so an
    % empty index fails. A fixture test_lower declares a parse refusal must not
    % dump.
    %
:- pred cases_dump_ast(tally::in, tally::out, io::di, io::uo) is det.

cases_dump_ast(!T, !IO) :-
    read_text("lowering-index.txt", Index, !IO),
    Names = list.filter((pred(N::in) is semidet :- N \= ""),
        list.map(string.strip, lines(Index))),
    list.foldl3(dump_one, Names, 0, Dumped, !T, !IO),
    check("`dump-ast` dumped at least one fixture",
        ( if Dumped > 0 then yes else no ), !T, !IO),
    % `-` is standard input: the same fixture by path and by standard input
    % dumps byte for byte the same.
    (
        Names = [First | _],
        Path = "lowering/" ++ First,
        read_text(Path, Source, !IO),
        invoke(["dump-ast", Path, "-o", "smoke_ast_path.json"], "", _, !IO),
        invoke(["dump-ast", "-", "-o", "smoke_ast_stdin.json"], Source, _,
            !IO),
        read_bytes("smoke_ast_path.json", ByPath, !IO),
        read_bytes("smoke_ast_stdin.json", ByStdin, !IO),
        check("`dump-ast -` dumps " ++ First ++ " as its path does",
            ( if bitmap.num_bits(ByPath) > 0, ByPath = ByStdin then yes
              else no ), !T, !IO)
    ;
        Names = []
    ),
    % `--filename` labels a syntax error on standard input, which exits 1.
    invoke(["dump-ast", "-", "--filename", "labelled.ds"], "schema\n", Bad,
        !IO),
    check("`dump-ast`: a syntax error on standard input exits 1, labelled",
        ( if
            Bad ^ o_status = 1,
            string.sub_string_search(Bad ^ o_err, "File \"labelled.ds\", line",
                _)
        then yes else no ), !T, !IO).

:- pred dump_one(string::in, int::in, int::out, tally::in, tally::out,
                 io::di, io::uo) is det.

dump_one(Name, !Dumped, !T, !IO) :-
    invoke(["dump-ast", "lowering/" ++ Name], "", D, !IO),
    ( if test_lower.parse_refused(Name) then
        check("`dump-ast` refuses " ++ Name
                ++ ", which test_lower declares a parse refusal",
            ( if D ^ o_status = 0 then no else yes ), !T, !IO)
    else
        Ok = ( if
            D ^ o_status = 0,
            string.prefix(D ^ o_out, "{\"_type\":\"Module\"")
        then yes else no ),
        check("`dump-ast` dumps " ++ Name, Ok, !T, !IO),
        ( if Ok = yes then !:Dumped = !.Dumped + 1 else true )
    ).

    % `compile -` and `-o -`, as pyds uses them. Labelled with the path,
    % standard input compiles to the path's bytes, since DsSource records the
    % label. `-L` still resolves.
    %
:- pred cases_stdin(string::in, tally::in, tally::out, io::di, io::uo) is det.

cases_stdin(Program, !T, !IO) :-
    invoke(["compile", "-", "--filename", "smoke_prog.ds", "-o", "-"],
        Program, S, !IO),
    read_bytes("smoke.dsc", ByPath, !IO),
    check("`compile -` labelled with the path compiles to its bytes",
        ( if
            S ^ o_status = 0,
            bitmap.num_bits(ByPath) > 0,
            S ^ o_bin = ByPath
        then yes else no ), !T, !IO),
    read_text("smoke_importer.ds", Importer, !IO),
    invoke(["compile", "-", "-o", "-", "-L", "smoke_lib"], Importer, I, !IO),
    check("`compile -` resolves an import under `-L`",
        ( if I ^ o_status = 0, bitmap.num_bits(I ^ o_bin) > 0 then yes
          else no ), !T, !IO).

    % What the command line refuses.
    %
:- pred cases_refused(tally::in, tally::out, io::di, io::uo) is det.

cases_refused(!T, !IO) :-
    % [LCAP.2.1.5]: `realtime` and `--dsrt` are refused with
    % DS_VALIDATE_REALTIME_DEFERRED, exit 1, and no `.dsrt` is read. A realtime
    % source is refused by path, beside its own `.dsrt`.
    remove("smoke_x.dsc", !IO),
    invoke(["compile", "lowering/74_realtime.ds", "-o", "smoke_x.dsc"], "",
        RT, !IO),
    check("[LCAP.2.1.5] a `realtime` source exits 1, refused as deferred",
        ( if
            RT ^ o_status = 1,
            string.sub_string_search(RT ^ o_err,
                "DS_VALIDATE_REALTIME_DEFERRED", _)
        then yes else no ), !T, !IO),
    % On a source that is not realtime, naming a file that does not exist: a
    % command line that read the contract would exit 2.
    read_text("smoke_prog.ds", Program, !IO),
    remove("smoke_x.dsc", !IO),
    invoke(["compile", "-", "--dsrt", "no_such.dsrt", "-o", "smoke_x.dsc"],
        Program, Dsrt, !IO),
    absent("smoke_x.dsc", NoArtefact, !IO),
    check("[LCAP.2.1.5] `--dsrt` exits 1, refused as deferred, and writes "
            ++ "nothing",
        ( if
            Dsrt ^ o_status = 1,
            string.sub_string_search(Dsrt ^ o_err,
                "DS_VALIDATE_REALTIME_DEFERRED", _),
            NoArtefact = yes
        then yes else no ), !T, !IO),
    % [RCLI.3.1]: an option not admitted exits 2. `compiler/dsc_cli.ebnf`
    % names both emit flags and withholds them.
    list.foldl2(
        ( pred(Flag::in, T0::in, T1::out, IO0::di, IO1::uo) is det :-
            remove("smoke_x.dsc", IO0, IO2),
            invoke(["compile", "smoke_prog.ds", "-o", "smoke_x.dsc", Flag], "",
                E, IO2, IO3),
            absent("smoke_x.dsc", None, IO3, IO4),
            check("[RCLI.3.1] `" ++ Flag ++ "` exits 2 and writes nothing",
                ( if E ^ o_status = 2, None = yes then yes else no ),
                T0, T1, IO4, IO1) ),
        ["--emit-rete", "--emit-aot=arm64"], !T, !IO).

%-----------------------------------------------------------------------------%
% `check` -- `compile` writing no artefact
%-----------------------------------------------------------------------------%

    % `check` is this compiler's own subcommand ([RCLI.1.3]), so it is pinned
    % against `compile`: on each program, under each format, `compile`'s exit
    % status and standard error, and nothing written.
    %
    % Each program also pins its own status, so a `check` and a `compile` that
    % both accepted everything cannot agree. The not-lowered program is one
    % `validate` accepts and `lower` refuses, which a `check` that stopped at
    % `validate` would pass; should `lower` come to accept it, its pinned
    % status fails and it is replaced by another such rule.
    %
:- pred cases_check(string::in, string::in, tally::in, tally::out,
                    io::di, io::uo) is det.

cases_check(Program, Library, !T, !IO) :-
    Programs = check_programs(Program, Library),
    list.foldl2(check_parity("text"), Programs, !T, !IO),
    list.foldl2(check_parity("json"), Programs, !T, !IO),
    list.foldl2(check_dump_ast_parity, Programs, !T, !IO),
    cases_check_usage(!T, !IO),
    cases_check_bundle(!T, !IO),
    cases_check_stdin(!T, !IO).

    % A program `check` is run on: what the case calls it, its source, the
    % status `compile` gives it, a code its diagnostics must carry ("" for
    % none pinned), and whether it parses.
    %
:- type check_program
    --->    check_program(
                pg_tag    :: string,
                pg_source :: string,
                pg_status :: int,
                pg_code   :: string,
                pg_parses :: bool
            ).

:- func check_programs(string, string) = list(check_program).

check_programs(Program, Library) = [
    check_program("clean", Program, 0, "", yes),
    check_program("warned", cast_program("s.x::Float > 1.0"), 0,
        "DS_VALIDATE_CAST_IDENTITY", yes),
    check_program("duplicate", duplicate_slot_program, 1,
        "DS_VALIDATE_DUPLICATE_SLOT", yes),
    check_program("not_lowered", "use default\n\n"
        ++ "schema Sample scope logical:\n    x: String key\n\n"
        ++ "schema Out scope ttl 1_h:\n    payload: Json\n\n"
        ++ "rule r:\n    Sample s\n->\n    emit Out payload: s::Json\n", 1,
        "DS_VALIDATE_RULE_NOT_LOWERED", yes),
    check_program("stopped", "bogus Thing\n", 1, "", no),
    % A library: it parses, and `compile` refuses to build it
    % ([LDIA.2.10.8]).
    check_program("library", Library, 1, "", yes)
].

    % A slot declared twice, which `validate` refuses after it parses.
    %
:- func duplicate_slot_program = string.

duplicate_slot_program =
    "use default\n\nschema S scope logical:\n    k: Int key\n"
    ++ "    k: Int mutable\n".

    % `compile` and `check` on one program, under `--diagnostics Format`.
    %
:- pred check_parity(string::in, check_program::in, tally::in, tally::out,
                     io::di, io::uo) is det.

check_parity(Format, P, !T, !IO) :-
    Path = "cli_check_" ++ P ^ pg_tag ++ ".ds",
    Dsc = "cli_check_" ++ P ^ pg_tag ++ ".dsc",
    write_file(Path, P ^ pg_source, !IO),
    invoke(["compile", Path, "-o", Dsc, "--diagnostics", Format], "", C, !IO),
    remove(Dsc, !IO),
    invoke(["check", Path, "--diagnostics", Format], "", K, !IO),
    absent(Dsc, None, !IO),
    Name = "the " ++ P ^ pg_tag ++ " program under `" ++ Format ++ "`",
    check(Name ++ " is what the case needs: `compile` exits "
            ++ string.from_int(P ^ pg_status)
            ++ ( if P ^ pg_code = "" then "" else ", " ++ P ^ pg_code ),
        ( if
            C ^ o_status = P ^ pg_status,
            ( P ^ pg_code = ""
            ; string.sub_string_search(C ^ o_err, P ^ pg_code, _)
            ),
            ( P ^ pg_status = 0
            ; C ^ o_err \= ""
            )
        then yes else no ), !T, !IO),
    check("`check` on " ++ Name ++ ": `compile`'s exit status and standard "
            ++ "error, and nothing written",
        ( if
            K ^ o_status = C ^ o_status,
            K ^ o_err = C ^ o_err,
            K ^ o_out = "",
            bitmap.num_bits(K ^ o_bin) = 0,
            None = yes
        then yes else no ), !T, !IO).

    % `check --dump-ast` on one program: `compile`'s status, `compile`'s
    % standard error as `diagnostics`, and `dump-ast`'s tree whenever the
    % program parses, whatever the verdict -- or `null` when it does not.
    %
:- pred check_dump_ast_parity(check_program::in, tally::in, tally::out,
                              io::di, io::uo) is det.

check_dump_ast_parity(P, !T, !IO) :-
    Path = "cli_check_" ++ P ^ pg_tag ++ ".ds",
    write_file(Path, P ^ pg_source, !IO),
    invoke(["compile", Path, "-o", "cli_check_ast.dsc"], "", C, !IO),
    remove("cli_check_ast.dsc", !IO),
    invoke(["dump-ast", Path], "", D, !IO),
    invoke(["check", Path, "--dump-ast"], "", K, !IO),
    absent("cli_check_ast.dsc", None, !IO),
    ds.json_text.parse(K ^ o_out, Parsed),
    Name = "`check --dump-ast` on the " ++ P ^ pg_tag ++ " program",
    check(Name ++ ": `compile`'s exit status, nothing on standard error or "
            ++ "written, and `compile`'s standard error as `diagnostics`",
        ( if
            K ^ o_status = C ^ o_status,
            K ^ o_err = "",
            bitmap.num_bits(K ^ o_bin) = 0,
            None = yes,
            Parsed = parsed(j_object(Obj)),
            lookup_member(Obj, "diagnostics", Diags),
            Diags = j_string(C ^ o_err)
        then yes else no ), !T, !IO),
    (
        P ^ pg_parses = yes,
        check(Name ++ ": `tree` is the tree `dump-ast` writes",
            ( if
                D ^ o_status = 0,
                string.remove_suffix(D ^ o_out, "\n", Tree),
                string.prefix(K ^ o_out,
                    "{\"tree\":" ++ Tree ++ ",\"diagnostics\":")
            then yes else no ), !T, !IO)
    ;
        P ^ pg_parses = no,
        check(Name ++ ": `tree` is null, since the input does not parse",
            ( if
                D ^ o_status = 1,
                Parsed = parsed(j_object(NullObj)),
                lookup_member(NullObj, "tree", NoTree),
                NoTree = j_null
            then yes else no ), !T, !IO)
    ).

    % What `check` refuses with exit 2, writing nothing: a missing, doubled
    % or unreadable input, an option it does not take -- `-o` above all, since
    % it writes no artefact -- and a value the grammar's `--diagnostics` does
    % not name.
    %
:- pred cases_check_usage(tally::in, tally::out, io::di, io::uo) is det.

cases_check_usage(!T, !IO) :-
    list.foldl2(check_usage, [
        {"`check` with no input", ["check"]},
        {"`check -o`", ["check", "smoke_prog.ds", "-o", "cli_check_o.dsc"]},
        {"`check --output`", ["check", "smoke_prog.ds", "--output",
            "cli_check_o.dsc"]},
        {"`check --dsrt`", ["check", "smoke_prog.ds", "--dsrt",
            "cli_check.dsrt"]},
        {"`check --diagnostics xml`", ["check", "smoke_prog.ds",
            "--diagnostics", "xml"]},
        {"`check -L` with no directory", ["check", "smoke_prog.ds", "-L"]},
        {"`check` with two inputs", ["check", "smoke_prog.ds",
            "smoke_prog.ds"]},
        {"`check` of a file that is not there",
            ["check", "cli_check_nowhere.ds"]},
        {"`check --dump-ast` of a file that is not there",
            ["check", "cli_check_nowhere.ds", "--dump-ast"]}
    ], !T, !IO).

:- pred check_usage({string, list(string)}::in, tally::in, tally::out,
                    io::di, io::uo) is det.

check_usage({Name, Args}, !T, !IO) :-
    remove("cli_check_o.dsc", !IO),
    invoke(Args, "", U, !IO),
    absent("cli_check_o.dsc", None, !IO),
    check(Name ++ " exits 2 and writes nothing",
        ( if
            U ^ o_status = 2,
            U ^ o_out = "",
            bitmap.num_bits(U ^ o_bin) = 0,
            None = yes
        then yes else no ), !T, !IO).

    % `check` compiles, so a `dsc` with no bundled library refuses it as it
    % refuses `compile` ([RCLI.1.11]), with `--dump-ast` or without: `5_kg`
    % needs `units.core` ([LUNI.4.1.2]). The control is the same program with
    % the bundle, which `check` passes.
    %
:- pred cases_check_bundle(tally::in, tally::out, io::di, io::uo) is det.

cases_check_bundle(!T, !IO) :-
    write_file("cli_check_kg.ds", "use default\n\nschema Box scope logical:\n"
        ++ "    id: Int key\n    weight: kilogram mutable\n\nrule r:\n"
        ++ "    Box b where b.weight > 5_kg\n->\n    log info \"heavy\"\n", !IO),
    Missing = no_bundle("cli_nowhere/share/ds/stdlib"),
    invoke_bundled(["check", "cli_check_kg.ds"], Missing, "", Plain, !IO),
    invoke_bundled(["check", "cli_check_kg.ds", "--dump-ast"], Missing, "",
        Dumped, !IO),
    list.foldl2(
        ( pred(Case::in, T0::in, T1::out, IO0::di, IO1::uo) is det :-
            Case = {Name, O},
            check(Name ++ " with no bundle exits 2, names where it looked, "
                    ++ "and writes nothing",
                ( if
                    O ^ o_status = 2,
                    string.sub_string_search(O ^ o_err,
                        "cli_nowhere/share/ds/stdlib", _),
                    O ^ o_out = ""
                then yes else no ), T0, T1, IO0, IO1) ),
        [{"`check`", Plain}, {"`check --dump-ast`", Dumped}], !T, !IO),
    invoke(["check", "cli_check_kg.ds"], "", Bundled, !IO),
    check("the control: with the bundle, `check` passes `5_kg`, exit 0",
        status_is(0, Bundled), !T, !IO).

    % Standard input under `--filename`: the diagnostics name the label, as
    % `compile`'s do.
    %
:- pred cases_check_stdin(tally::in, tally::out, io::di, io::uo) is det.

cases_check_stdin(!T, !IO) :-
    invoke(["compile", "-", "--filename", "cli_check_label.ds", "-o", "-"],
        duplicate_slot_program, C, !IO),
    invoke(["check", "-", "--filename", "cli_check_label.ds"],
        duplicate_slot_program, K, !IO),
    check("`check -` under `--filename`: exit 1, `compile`'s standard error, "
            ++ "naming the label",
        ( if
            K ^ o_status = 1,
            K ^ o_err = C ^ o_err,
            string.sub_string_search(K ^ o_err, "cli_check_label.ds", _),
            K ^ o_out = "",
            bitmap.num_bits(K ^ o_bin) = 0
        then yes else no ), !T, !IO).

%-----------------------------------------------------------------------------%
% `--diagnostics` ([RCLI.3.2]) and `dump-ast` ([RCLI.1.10])
%-----------------------------------------------------------------------------%

    % The schema, as the gate stages it beside the suite, and every case that
    % reads a document against it. Unstaged or unreadable is a failure, not a
    % skip: a case with no schema to validate against proves nothing.
    %
:- pred cases_diagnostics(tally::in, tally::out, io::di, io::uo) is det.

cases_diagnostics(!T, !IO) :-
    read_text("dsc_diagnostics.schema.json", SchemaText, !IO),
    ds.json_text.parse(SchemaText, SchemaRes),
    (
        SchemaRes = parsed(Schema),
        cases_validator(Schema, !T, !IO),
        cases_json_refused(Schema, !T, !IO),
        cases_json_accepted(Schema, !T, !IO),
        cases_json_order(Schema, !T, !IO),
        cases_json_usage(!T, !IO),
        cases_json_dump_ast(Schema, !T, !IO),
        cases_json_check(Schema, !T, !IO),
        cases_companion(Schema, !T, !IO)
    ;
        SchemaRes = refused(_),
        check("[RCLI.3.2] dsc_diagnostics.schema.json is staged and parses",
            no, !T, !IO)
    ).

    % The validator shows it can fail, since every case below is only as good
    % as it is. A document that validates, then the same document broken one
    % way at a time, each through a different keyword, each of which must be
    % refused; a mutation that did not apply fails too, rather than passing
    % over an unbroken document. And a keyword it does not interpret is an
    % error, never a pass.
    %
:- pred cases_validator(json::in, tally::in, tally::out, io::di, io::uo)
    is det.

cases_validator(Schema, !T, !IO) :-
    Span = "{\"file\":\"f.ds\",\"start\":{\"line\":1,\"column\":1},"
        ++ "\"end\":{\"line\":1,\"column\":2}}",
    Good = "{\"diagnostics\":[{\"code\":\"DS_VALIDATE_X\","
        ++ "\"severity\":\"error\",\"message\":\"m\",\"hint\":\"h\","
        ++ "\"span\":" ++ Span ++ ","
        ++ "\"related\":[{\"message\":\"r\",\"span\":" ++ Span ++ "}]}]}",
    check("[RCLI.3.2] the validator accepts a well-formed document"
            ++ why(Schema, Good),
        validates(Schema, Good), !T, !IO),
    list.foldl2(
        ( pred(Case::in, T0::in, T1::out, IO0::di, IO1::uo) is det :-
            Case = {Name, Old, New},
            check("[RCLI.3.2] the validator refuses " ++ Name,
                ( if
                    string.replace(Good, Old, New, Bad),
                    validates(Schema, Bad) = no
                then yes else no ), T0, T1, IO0, IO1) ),
        [   {"a missing required member (`required`)",
                "\"message\":\"m\",", ""},
            {"an empty hint (`minLength`)", "\"hint\":\"h\"", "\"hint\":\"\""},
            {"column 0 (`minimum`)", "\"column\":1", "\"column\":0"},
            {"severity `info` (`enum`)", "\"error\"", "\"info\""},
            {"a code by another spelling (`pattern`)", "DS_VALIDATE_X",
                "ds_validate_x"},
            {"a member the span does not declare (`additionalProperties`)",
                "\"file\":\"f.ds\",", "\"file\":\"f.ds\",\"extra\":1,"},
            {"a line as a string (`type`)", "\"line\":1", "\"line\":\"1\""},
            {"a related message that is no string (`items`, `$ref`)",
                "\"message\":\"r\"", "\"message\":7"},
            {"a member the document does not declare",
                "{\"diagnostics\":", "{\"extra\":0,\"diagnostics\":"}
        ], !T, !IO),
    check("[RCLI.3.2] the validator refuses `{}`, which has no diagnostics",
        bool.not(validates(Schema, "{}")), !T, !IO),
    check("[RCLI.3.2] the validator refuses a document that is not JSON",
        bool.not(validates(Schema, Good ++ Good)), !T, !IO),
    ds.json_text.parse("{\"type\":\"object\",\"uniqueItems\":true}",
        Unknown),
    check("[RCLI.3.2] the validator refuses a keyword it does not interpret",
        ( if
            Unknown = parsed(UnknownSchema),
            schema_errors(UnknownSchema, j_object(empty_object)) = [_ | _]
        then yes else no ), !T, !IO).

    % A refused program, with a hint and a related span. Read by path, so the
    % span's file is the path as given ([RCLI.1.9]). The slot's name `k` is at column 4 (0-based) of lines 4
    % and 5; a diagnostic that carries no end is one code point long.
    %
:- pred cases_json_refused(json::in, tally::in, tally::out, io::di, io::uo)
    is det.

cases_json_refused(Schema, !T, !IO) :-
    write_file("cli_diag_dup.ds", "use default\n\nschema S scope logical:\n"
        ++ "    k: Int key\n    k: Int mutable\n", !IO),
    remove("cli_diag_dup.dsc", !IO),
    invoke(["compile", "cli_diag_dup.ds", "-o", "cli_diag_dup.dsc",
        "--diagnostics", "json"], "", Dup, !IO),
    absent("cli_diag_dup.dsc", NoArtefact, !IO),
    % @spec [RCLI.3.2]
    check("[RCLI.3.2] a refused program under `json` exits 1, writes nothing "
            ++ "else, and its stderr is one document the schema validates"
            ++ why(Schema, Dup ^ o_err),
        ( if
            Dup ^ o_status = 1,
            NoArtefact = yes,
            Dup ^ o_out = "",
            validates(Schema, Dup ^ o_err) = yes
        then yes else no ), !T, !IO),
    % @spec [RCLI.3.2]
    check("[RCLI.3.2] the refusal's code, span, hint and related span",
        ( if
            document_diagnostics(Dup ^ o_err, [D]),
            lookup_member(D, "code", j_string("DS_VALIDATE_DUPLICATE_SLOT")),
            lookup_member(D, "severity", j_string("error")),
            lookup_member(D, "hint", j_string(Hint)),
            Hint \= "",
            lookup_member(D, "span", j_object(Span)),
            span_is(Span, "cli_diag_dup.ds", 5, 5, 5, 6),
            lookup_member(D, "related", j_array([j_object(Related)])),
            lookup_member(Related, "span", j_object(RelatedSpan)),
            span_is(RelatedSpan, "cli_diag_dup.ds", 4, 5, 4, 6)
        then yes else no ), !T, !IO).

    % An accepted program with a warning writes one document
    % and its artefact; a clean one writes no document at all. The two
    % programs differ only in the cast, an identity on `x: Float` and a real
    % conversion on `k: Int` ([LCST.4.5.1]). The warning is read from
    % standard input under `--filename`, the label the span must carry.
    %
    % And the format is only how: `text` is the default, `--diagnostics
    % text` writes what no option writes, and a second `--diagnostics` wins
    % over the first ([RCLI.1.3]).
    %
:- pred cases_json_accepted(json::in, tally::in, tally::out, io::di, io::uo)
    is det.

cases_json_accepted(Schema, !T, !IO) :-
    Warned = cast_program("s.x::Float > 1.0"),
    invoke(["compile", "-", "--filename", "cli_diag_warn.ds", "-o", "-",
        "--diagnostics", "json"], Warned, W, !IO),
    % @spec [RCLI.3.2]
    check("[RCLI.3.2] an accepted program's warning under `json`: exit 0, "
            ++ "the artefact, and one document the schema validates"
            ++ why(Schema, W ^ o_err),
        ( if
            W ^ o_status = 0,
            bitmap.num_bits(W ^ o_bin) > 0,
            validates(Schema, W ^ o_err) = yes,
            document_diagnostics(W ^ o_err, [D]),
            lookup_member(D, "code", j_string("DS_VALIDATE_CAST_IDENTITY")),
            lookup_member(D, "severity", j_string("warning")),
            lookup_member(D, "span", j_object(Span)),
            lookup_member(Span, "file", j_string("cli_diag_warn.ds"))
        then yes else no ), !T, !IO),

    invoke(["compile", "-", "-o", "-", "--diagnostics", "json"],
        cast_program("s.k::Float > 1.0"), Clean, !IO),
    % @spec [RCLI.3.2]
    check("[RCLI.3.2] a clean compile under `json` exits 0 and writes no "
            ++ "document",
        ( if
            Clean ^ o_status = 0,
            bitmap.num_bits(Clean ^ o_bin) > 0,
            Clean ^ o_err = ""
        then yes else no ), !T, !IO),

    invoke(["compile", "-", "--filename", "cli_diag_warn.ds", "-o", "-"],
        Warned, Default, !IO),
    invoke(["compile", "-", "--filename", "cli_diag_warn.ds", "-o", "-",
        "--diagnostics", "text"], Warned, Text, !IO),
    invoke(["compile", "-", "--filename", "cli_diag_warn.ds", "-o", "-",
        "--diagnostics", "json", "--diagnostics", "text"], Warned, Last, !IO),
    ds.json_text.parse(Default ^ o_err, DefaultAsJson),
    % @spec [RCLI.3.2]
    check("[RCLI.3.2] `text` is the default: the warning is rendered, not a "
            ++ "document",
        ( if
            Default ^ o_status = 0,
            string.sub_string_search(Default ^ o_err,
                "DS_VALIDATE_CAST_IDENTITY: ", _),
            DefaultAsJson = refused(_)
        then yes else no ), !T, !IO),
    % @spec [RCLI.3.2]
    check("[RCLI.3.2] `--diagnostics text` writes what no option writes",
        ( if Text ^ o_status = 0, Text ^ o_err = Default ^ o_err then yes
          else no ), !T, !IO),
    % @spec [RCLI.1.3]
    check("[RCLI.1.3] given twice, the last `--diagnostics` wins",
        ( if Last ^ o_status = 0, Last ^ o_err = Default ^ o_err then yes
          else no ), !T, !IO).

    % A rule over `S` filtering on `Predicate`, as test_dsc's `cast_rule`.
    %
:- func cast_program(string) = string.

cast_program(Predicate) =
    "use default\n\nschema S scope logical:\n    k: Int key\n"
    ++ "    x: Float mutable\n\nrule r:\n    S s where " ++ Predicate
    ++ "\n->\n    log info \"x\"\n".

    % Every diagnostic the text form renders, in its order: the same program
    % under both formats, two refusals in two schemas, each with a related
    % span. The locations read off the text form's headers -- `File` for a
    % diagnostic, `related: File` for each span it names -- are the
    % document's, in the same order, so the document neither drops,
    % reorders nor counts a position differently from the text form.
    %
:- pred cases_json_order(json::in, tally::in, tally::out, io::di, io::uo)
    is det.

cases_json_order(Schema, !T, !IO) :-
    Two = "use default\n\nschema A scope logical:\n    k: Int key\n"
        ++ "    k: Int mutable\n\nschema B scope logical:\n    j: Int key\n"
        ++ "    j: Int mutable\n",
    invoke(["compile", "-", "-o", "-", "--diagnostics", "json"], Two, J, !IO),
    invoke(["compile", "-", "-o", "-"], Two, X, !IO),
    list.filter_map(text_location, lines(X ^ o_err), TextLocations),
    % @spec [RCLI.3.2]
    check("[RCLI.3.2] the document holds every diagnostic the text form "
            ++ "renders, in its order" ++ why(Schema, J ^ o_err),
        ( if
            J ^ o_status = 1,
            X ^ o_status = 1,
            validates(Schema, J ^ o_err) = yes,
            document_diagnostics(J ^ o_err, Ds),
            Ds = [_, _],
            list.map(json_locations, Ds, Nested),
            list.condense(Nested) = TextLocations
        then yes else no ), !T, !IO).

    % One location from a text-form header line: `File "<f>", line L,
    % column C`, or the same after `related: `.
    %
:- pred text_location(string::in, {string, int, int}::out) is semidet.

text_location(Line, Location) :-
    ( if string.remove_prefix("related: ", Line, Rest0) then
        Kind = "related",
        Rest1 = Rest0
    else
        Kind = "primary",
        Rest1 = Line
    ),
    string.prefix(Rest1, "File \""),
    string.sub_string_search(Rest1, "\", line ", At),
    Rest = string.between(Rest1, At + 8, string.length(Rest1)),
    string.split_at_string(", column ", Rest) = [LineText, ColText],
    string.to_int(LineText, L),
    string.to_int(ColText, C),
    Location = {Kind, L, C}.

    % A diagnostic's locations as the text form lists them: its own span's
    % start, then each related span's.
    %
:- pred json_locations(json_members::in, list({string, int, int})::out)
    is semidet.

json_locations(D, Locations) :-
    lookup_member(D, "span", j_object(Span)),
    span_start(Span, L, C),
    lookup_member(D, "related", j_array(Related)),
    list.map(
        ( pred(R::in, Location::out) is semidet :-
            R = j_object(RM),
            lookup_member(RM, "span", j_object(RSpan)),
            span_start(RSpan, RL, RC),
            Location = {"related", RL, RC} ),
        Related, Rs),
    Locations = [{"primary", L, C} | Rs].

    % A usage error under `json`: exit 2, never a
    % document, since it is no diagnostic of the program ([RCLI.3.2]), and
    % never an artefact. A value the grammar does not name and a missing one
    % are both usage errors ([RCLI.3.1]), for `dump-ast` as for `compile`.
    %
:- pred cases_json_usage(tally::in, tally::out, io::di, io::uo) is det.

cases_json_usage(!T, !IO) :-
    list.foldl2(
        ( pred(Case::in, T0::in, T1::out, IO0::di, IO1::uo) is det :-
            Case = {Name, Args},
            remove("cli_diag_x.dsc", IO0, IO2),
            invoke(Args, "", U, IO2, IO3),
            absent("cli_diag_x.dsc", None, IO3, IO4),
            ds.json_text.parse(U ^ o_err, AsJson),
            % @spec [RCLI.3.1]
            check("[RCLI.3.1] " ++ Name ++ " exits 2, with no document and "
                    ++ "no artefact",
                ( if
                    U ^ o_status = 2,
                    None = yes,
                    AsJson = refused(_)
                then yes else no ), T0, T1, IO4, IO1) ),
        [   {"`--diagnostics xml`", ["compile", "smoke_prog.ds", "-o",
                "cli_diag_x.dsc", "--diagnostics", "xml"]},
            {"`--diagnostics` with no value", ["compile", "smoke_prog.ds",
                "-o", "cli_diag_x.dsc", "--diagnostics"]},
            {"a usage error under `--diagnostics json`", ["compile",
                "smoke_prog.ds", "--diagnostics", "json"]},
            {"`dump-ast --diagnostics xml`", ["dump-ast", "smoke_prog.ds",
                "--diagnostics", "xml"]}
        ], !T, !IO).

    % `dump-ast` on input that does not parse writes no tree and one document,
    % its file `<stdin>` ([RCLI.1.9]); on input that parses, under `json`, the
    % tree and no document. The tree against `ds.asdl` is
    % tools/ds_ast/tests/test_parse.py's.
    %
:- pred cases_json_dump_ast(json::in, tally::in, tally::out, io::di, io::uo)
    is det.

cases_json_dump_ast(Schema, !T, !IO) :-
    invoke(["dump-ast", "-", "--diagnostics", "json"], "schema\n", Bad, !IO),
    % @spec [RCLI.1.10]
    check("[RCLI.1.10] input that does not parse under `json`: exit 1, no "
            ++ "tree, one document the schema validates"
            ++ why(Schema, Bad ^ o_err),
        ( if
            Bad ^ o_status = 1,
            Bad ^ o_out = "",
            validates(Schema, Bad ^ o_err) = yes,
            document_diagnostics(Bad ^ o_err, [D]),
            lookup_member(D, "severity", j_string("error")),
            lookup_member(D, "span", j_object(Span)),
            lookup_member(Span, "file", j_string("<stdin>"))
        then yes else no ), !T, !IO),
    read_text("smoke_prog.ds", Program, !IO),
    invoke(["dump-ast", "-", "--diagnostics", "json"], Program, Good, !IO),
    % @spec [RCLI.1.10]
    check("[RCLI.1.10] input that parses under `json`: exit 0, the tree, "
            ++ "and no document",
        ( if
            Good ^ o_status = 0,
            string.prefix(Good ^ o_out, "{\"_type\":\"Module\""),
            Good ^ o_err = ""
        then yes else no ), !T, !IO).

    % `check --dump-ast --diagnostics json`: `diagnostics` is the
    % document `compile` writes to standard error, which the schema validates,
    % and `null` when `compile` writes none.
    %
:- pred cases_json_check(json::in, tally::in, tally::out, io::di, io::uo)
    is det.

cases_json_check(Schema, !T, !IO) :-
    invoke(["compile", "-", "-o", "-", "--diagnostics", "json"],
        duplicate_slot_program, C, !IO),
    invoke(["check", "-", "--dump-ast", "--diagnostics", "json"],
        duplicate_slot_program, K, !IO),
    ds.json_text.parse(K ^ o_out, Parsed),
    ds.json_text.parse(C ^ o_err, CompileDoc),
    check("`check --dump-ast --diagnostics json` on a refused program: exit "
            ++ "1, and `diagnostics` is `compile`'s document, which the "
            ++ "schema validates",
        ( if
            K ^ o_status = 1,
            K ^ o_err = "",
            Parsed = parsed(j_object(Obj)),
            lookup_member(Obj, "diagnostics", Doc),
            Doc = j_object(_),
            schema_errors(Schema, Doc) = [],
            CompileDoc = parsed(Doc)
        then yes else no ), !T, !IO),
    invoke(["check", "-", "--dump-ast", "--diagnostics", "json"],
        cast_program("s.k::Float > 1.0"), Clean, !IO),
    ds.json_text.parse(Clean ^ o_out, CleanParsed),
    check("`check --dump-ast --diagnostics json` on a clean program: exit 0, "
            ++ "the tree, and `diagnostics` null",
        ( if
            Clean ^ o_status = 0,
            Clean ^ o_err = "",
            CleanParsed = parsed(j_object(CleanObj)),
            lookup_member(CleanObj, "diagnostics", Diags),
            Diags = j_null,
            lookup_member(CleanObj, "tree", j_object(Tree)),
            lookup_member(Tree, "_type", j_string("Module"))
        then yes else no ), !T, !IO).

%-----------------------------------------------------------------------------%
% Reading a document
%-----------------------------------------------------------------------------%

    % Whether `Text` is one JSON document that `Schema` validates.
    %
:- func validates(json, string) = bool.

validates(Schema, Text) = Ok :-
    ds.json_text.parse(Text, Res),
    ( if Res = parsed(Doc), schema_errors(Schema, Doc) = [] then
        Ok = yes
    else
        Ok = no
    ).

    % Why `Text` does not validate, for a failing check's name; "" when it
    % does.
    %
:- func why(json, string) = string.

why(Schema, Text) = Note :-
    ds.json_text.parse(Text, Res),
    (
        Res = parsed(Doc),
        Errors = schema_errors(Schema, Doc),
        ( if Errors = [] then
            Note = ""
        else
            Note = " -- " ++ string.join_list("; ", Errors)
        )
    ;
        Res = refused(_),
        Note = " -- not one JSON document: " ++ Text
    ).

    % The document's diagnostics, each an object.
    %
:- pred document_diagnostics(string::in, list(json_members)::out) is semidet.

document_diagnostics(Text, Ds) :-
    ds.json_text.parse(Text, parsed(j_object(Doc))),
    lookup_member(Doc, "diagnostics", j_array(Items)),
    list.map((pred(J::in, M::out) is semidet :- J = j_object(M)), Items, Ds).

    % A span in `File` from (L0, C0) up to (L1, C1).
    %
:- pred span_is(json_members::in, string::in, int::in, int::in, int::in,
                int::in) is semidet.

span_is(Span, File, L0, C0, L1, C1) :-
    lookup_member(Span, "file", j_string(File)),
    span_start(Span, L0, C0),
    lookup_member(Span, "end", j_object(End)),
    position(End, L1, C1).

:- pred span_start(json_members::in, int::out, int::out) is semidet.

span_start(Span, L, C) :-
    lookup_member(Span, "start", j_object(Start)),
    position(Start, L, C).

:- pred position(json_members::in, int::out, int::out) is semidet.

position(P, L, C) :-
    lookup_member(P, "line", j_int(L64)),
    lookup_member(P, "column", j_int(C64)),
    L = int64.cast_to_int(L64),
    C = int64.cast_to_int(C64).

%-----------------------------------------------------------------------------%
% A module's companion `.dstest` ([LTSL.2.4])
%-----------------------------------------------------------------------------%

    % One project on disk: `main.ds` imports libraries `alpha` and `beta`
    % through `-L`, each with a companion holding a test named alike,
    % "answers"; `main.ds` holds one inline and its own companion one more.
    % Its oracle rules' names and order are checked here; then the companion
    % oracle cases.
    %
    % Which tests a compile carries, and which `.dstest` it reads, are the
    % `LTSL.2.4_*` and `LTSL.2.1_*` compiler vectors ([RCTS.1.2.35]), which
    % also hold the codes of the three companion refusals below. What is held
    % here is the file each refusal is named in ([RCLI.1.9]).
    %
:- pred cases_companion(json::in, tally::in, tally::out, io::di, io::uo)
    is det.

cases_companion(Schema, !T, !IO) :-
    make_dir("cli_companion/lib", !IO),
    write_file("cli_companion/lib/alpha.ds",
        two_schemas("Ping", "Pong") ++ answering_rule("answer", "Ping", "Pong"),
        !IO),
    write_file("cli_companion/lib/alpha.dstest",
        answers_test("Ping", "Pong", "1", ""), !IO),
    write_file("cli_companion/lib/beta.ds",
        two_schemas("Ding", "Dong") ++ answering_rule("ring", "Ding", "Dong"),
        !IO),
    write_file("cli_companion/lib/beta.dstest",
        answers_test("Ding", "Dong", "2", "        activated ring\n"), !IO),
    write_file("cli_companion/main.ds",
        "use default\n\nimport alpha\nimport beta\n\n"
        ++ two_schemas("Tick", "Tock") ++ answering_rule("tock", "Tick", "Tock")
        ++ "\n" ++ answers_test("Tick", "Tock", "3", ""), !IO),
    write_file("cli_companion/main.dstest",
        "test \"from the companion\":\n    inputs:\n        at 0_s:\n"
        ++ "            Tick id: 4\n    produces:\n        activated tock\n",
        !IO),
    remove("cli_companion.dsc", !IO),
    invoke(["compile", "cli_companion/main.ds", "-o", "cli_companion.dsc",
        "-L", "cli_companion/lib"], "", C, !IO),
    read_bytes("cli_companion.dsc", Bytes, !IO),

    % @spec [RTIM.14.13]
    % @spec [RLOW.14.3]
    % Path: dsc.dstest names each oracle rule by its test_id
    % (`rtim_14_11_oracle_rules`), and dsc.rete lowers every module's
    % author rules before every module's oracle rules (`rlow_14_3_pass`).
    check("[RTIM.14.13] [RLOW.14.3] oracle rules are named by the "
            ++ "artefact-wide test_id, and every oracle terminal follows "
            ++ "every author terminal, main's included, in (test_id, i) order"
            ++ C ^ o_err,
        ( if
            C ^ o_status = 0,
            terminal_names(Bytes) = ["answer", "ring", "tock",
                "$dstest_oracle_1_0", "$dstest_oracle_2_0",
                "$dstest_oracle_3_0"]
        then yes else no ), !T, !IO),

    % A vector's `compile_error` does not read the file a refusal names; these
    % do.
    %
    % @spec [RCLI.1.9]
    % Path: a library's tests are lowered against the rules its module sees
    % (dsc.driver `ltsl_2_4_library_tests`), and a companion's diagnostic
    % names the companion (dsc.diag `rcli_1_9_in_file`, dsc.render).
    make_dir("cli_companion_scope/lib", !IO),
    write_file("cli_companion_scope/lib/gamma.ds",
        two_schemas("Ding", "Dong") ++ answering_rule("ring", "Ding", "Dong"),
        !IO),
    write_file("cli_companion_scope/lib/gamma.dstest",
        "test \"sees too far\":\n    inputs:\n        at 0_s:\n"
        ++ "            Ding id: 1\n    produces:\n        activated tock\n",
        !IO),
    write_file("cli_companion_scope/main.ds",
        "use default\n\nimport gamma\n\n"
        ++ two_schemas("Tick", "Tock") ++ answering_rule("tock", "Tick", "Tock"),
        !IO),
    invoke(["compile", "cli_companion_scope/main.ds", "-o",
        "cli_companion_scope.dsc", "-L", "cli_companion_scope/lib",
        "--diagnostics", "json"], "", Scope, !IO),
    check("[LTSL.2.4] a companion's `activated` of a rule its module cannot "
            ++ "see is DS_VALIDATE_TEST_UNKNOWN_RULE, in the companion's file"
            ++ why(Schema, Scope ^ o_err),
        bool.and(validates(Schema, Scope ^ o_err),
            refused_with(Scope, "DS_VALIDATE_TEST_UNKNOWN_RULE",
                "cli_companion_scope/lib/gamma.dstest")), !T, !IO),

    % @spec [RCLI.1.9]
    % Path: dsc.driver `ltsl_2_1_companion_decl`.
    make_dir("cli_companion_decl", !IO),
    write_file("cli_companion_decl/prog.ds", "use default\n\n"
        ++ two_schemas("Tick", "Tock"), !IO),
    write_file("cli_companion_decl/prog.dstest",
        "schema Extra scope logical:\n    id: Int key\n", !IO),
    invoke(["compile", "cli_companion_decl/prog.ds", "-o",
        "cli_companion_decl.dsc", "--diagnostics", "json"], "", Decl, !IO),
    check("[LTSL.2.1] a companion holding a schema is "
            ++ "DS_VALIDATE_TEST_COMPANION_DECL, in the companion's file"
            ++ Decl ^ o_err,
        refused_with(Decl, "DS_VALIDATE_TEST_COMPANION_DECL",
            "cli_companion_decl/prog.dstest"), !T, !IO),
    write_file("cli_companion_decl/used.ds", "use default\n\n"
        ++ two_schemas("Tick", "Tock"), !IO),
    write_file("cli_companion_decl/used.dstest", "use default\n", !IO),
    invoke(["compile", "cli_companion_decl/used.ds", "-o",
        "cli_companion_decl.dsc", "--diagnostics", "json"], "", Use, !IO),
    check("[LTSL.2.1] a companion with a `use` line is "
            ++ "DS_VALIDATE_USE_IN_TEST, in the companion's file" ++ Use ^ o_err,
        refused_with(Use, "DS_VALIDATE_USE_IN_TEST",
            "cli_companion_decl/used.dstest"), !T, !IO),
    cases_companion_oracle(Schema, !T, !IO).

    % [RCLI.1.9]: a diagnostic inside the `where` of an oracle rule
    % ([RTIM.14.11]) names the file of the test the rule came from. Each
    % `where` names a slot `Tock` (`Dong`) does not have, which `validate`
    % refuses at the slot's name, DS_VALIDATE_UNKNOWN_SLOT. A module's own
    % test and its companion's are refused in one compile, each in its file,
    % at its own line (19 in the `.ds`, 6 in the companion). Then the two at
    % one position: the companion's test is written at the `.ds`'s line, so
    % the two diagnostics are equal but for their files, and one is named for
    % each. Then a library's companion.
    %
    % @spec [RCLI.1.9]
    % Path: dsc.driver `rcli_1_9_companion_oracle`, from `after_resolve` for
    % the program and `library_rules` for a library, with dsc.dstest
    % `rcli_1_9_module_oracle_rules`.
    %
:- pred cases_companion_oracle(json::in, tally::in, tally::out,
                               io::di, io::uo) is det.

cases_companion_oracle(Schema, !T, !IO) :-
    Module = "use default\n\n" ++ two_schemas("Tick", "Tock")
        ++ answering_rule("tock", "Tick", "Tock") ++ "\n",
    make_dir("cli_companion_oracle", !IO),
    write_file("cli_companion_oracle/main.ds",
        Module ++ oracle_test("own", "Tick", "Tock", "mine"), !IO),
    write_file("cli_companion_oracle/main.dstest",
        oracle_test("theirs", "Tick", "Tock", "theirs"), !IO),
    invoke(["compile", "cli_companion_oracle/main.ds", "-o",
        "cli_companion_oracle.dsc", "--diagnostics", "json"], "", Both, !IO),
    check("[RCLI.1.9] an oracle rule's diagnostic names its test's file: "
            ++ "the module's own in the `.ds`, its companion's in the "
            ++ "companion" ++ why(Schema, Both ^ o_err),
        ( if
            Both ^ o_status = 1,
            validates(Schema, Both ^ o_err) = yes,
            lines_with(Both, "DS_VALIDATE_UNKNOWN_SLOT",
                "cli_companion_oracle/main.ds") = [19],
            lines_with(Both, "DS_VALIDATE_UNKNOWN_SLOT",
                "cli_companion_oracle/main.dstest") = [6]
        then yes else no ), !T, !IO),

    make_dir("cli_companion_twin", !IO),
    write_file("cli_companion_twin/main.ds",
        Module ++ oracle_test("own", "Tick", "Tock", "nope"), !IO),
    write_file("cli_companion_twin/main.dstest",
        string.duplicate_char('\n', 13)
            ++ oracle_test("twin", "Tick", "Tock", "nope"), !IO),
    invoke(["compile", "cli_companion_twin/main.ds", "-o",
        "cli_companion_twin.dsc", "--diagnostics", "json"], "", Twin, !IO),
    check("[RCLI.1.9] two diagnostics equal but for their files, one from "
            ++ "the module's test and one from its companion's, are each "
            ++ "named for its file" ++ Twin ^ o_err,
        ( if
            Twin ^ o_status = 1,
            lines_with(Twin, "DS_VALIDATE_UNKNOWN_SLOT",
                "cli_companion_twin/main.ds") = [19],
            lines_with(Twin, "DS_VALIDATE_UNKNOWN_SLOT",
                "cli_companion_twin/main.dstest") = [19]
        then yes else no ), !T, !IO),

    make_dir("cli_companion_liboracle/lib", !IO),
    write_file("cli_companion_liboracle/lib/gamma.ds",
        two_schemas("Ding", "Dong") ++ answering_rule("ring", "Ding", "Dong"),
        !IO),
    write_file("cli_companion_liboracle/lib/gamma.dstest",
        oracle_test("theirs", "Ding", "Dong", "nope"), !IO),
    write_file("cli_companion_liboracle/main.ds",
        "use default\n\nimport gamma\n\n" ++ two_schemas("Tick", "Tock")
            ++ answering_rule("tock", "Tick", "Tock"), !IO),
    invoke(["compile", "cli_companion_liboracle/main.ds", "-o",
        "cli_companion_liboracle.dsc", "-L", "cli_companion_liboracle/lib",
        "--diagnostics", "json"], "", Lib, !IO),
    check("[RCLI.1.9] a library companion's oracle rule diagnostic names "
            ++ "that companion, not the library" ++ Lib ^ o_err,
        ( if
            Lib ^ o_status = 1,
            lines_with(Lib, "DS_VALIDATE_UNKNOWN_SLOT",
                "cli_companion_liboracle/lib/gamma.dstest") = [6],
            lines_with(Lib, "DS_VALIDATE_UNKNOWN_SLOT",
                "cli_companion_liboracle/lib/gamma.ds") = []
        then yes else no ), !T, !IO).

    % A test named `Name`: an `In` of id 1, and an `Out` emitted whose `where`
    % reads its slot `Slot`, an oracle rule's assertion. Its `emitted` line is
    % its sixth.
    %
:- func oracle_test(string, string, string, string) = string.

oracle_test(Name, In, Out, Slot) =
    "test \"" ++ Name ++ "\":\n    inputs:\n        at 0_s:\n            "
    ++ In ++ " id: 1\n    produces:\n        emitted " ++ Out ++ " o where o."
    ++ Slot ++ " == 1\n".

    % The start line of every diagnostic with `Code` in `File`, in order.
    %
:- func lines_with(outcome, string, string) = list(int).

lines_with(O, Code, File) =
    ( if document_diagnostics(O ^ o_err, Ds) then
        list.filter_map(line_with(Code, File), Ds)
      else [] ).

:- func line_with(string, string, json_members) = int is semidet.

line_with(Code, File, D) = L :-
    lookup_member(D, "code", j_string(Code)),
    lookup_member(D, "span", j_object(Span)),
    lookup_member(Span, "file", j_string(File)),
    span_start(Span, L, _).

    % Two keyed schemas.
    %
:- func two_schemas(string, string) = string.

two_schemas(In, Out) =
    "schema " ++ In ++ " scope logical:\n    id: Int key\n\n"
    ++ "schema " ++ Out ++ " scope logical:\n    id: Int key\n\n".

    % A rule that answers each `In` with an `Out` of the same id.
    %
:- func answering_rule(string, string, string) = string.

answering_rule(Name, In, Out) =
    "rule " ++ Name ++ ":\n    " ++ In ++ " p\n->\n    emit " ++ Out
    ++ " logical id: p.id\n".

    % A test named "answers": an `In` of `Id`, and the `Out` of the same id
    % emitted, an oracle rule's assertion; `More` adds assertions after it.
    %
:- func answers_test(string, string, string, string) = string.

answers_test(In, Out, Id, More) =
    "test \"answers\":\n    inputs:\n        at 0_s:\n            " ++ In
    ++ " id: " ++ Id ++ "\n    produces:\n        emitted " ++ Out
    ++ " o where o.id == " ++ Id ++ "\n" ++ More.

    % Refused, exit 1, with `Code` in `File`.
    %
:- func refused_with(outcome, string, string) = bool.

refused_with(O, Code, File) =
    ( if
        O ^ o_status = 1,
        document_diagnostics(O ^ o_err, Ds),
        list.member(D, Ds),
        lookup_member(D, "code", j_string(Code)),
        lookup_member(D, "span", j_object(Span)),
        lookup_member(Span, "file", j_string(File))
    then yes else no ).

    % Every TerminalNode's rule name (3), in emission order: the terminal
    % ordinal order ([RLOW.14.3]).
    %
:- func terminal_names(bitmap) = list(string).

terminal_names(Bytes) = list.map(( func(B) = body_string(B, 3u32) ),
    atom_bodies(at_terminal_node, Bytes)).

    % The bodies of every frame of one atom, in order. An unframeable tail
    % ends the walk, which the exact-list checks above then fail.
    %
:- func atom_bodies(atom_id, bitmap) = list(reader).

atom_bodies(Atom, Bytes) = list.reverse(Rev) :-
    walk_bodies(Atom, init_reader(Bytes), [], Rev).

:- pred walk_bodies(atom_id::in, reader::in,
                    list(reader)::in, list(reader)::out) is det.

walk_bodies(Atom, R0, !Rev) :-
    next_frame(FrameResult, R0, R1),
    ( if FrameResult = fr_ok(Frame) then
        ( if Frame ^ fr_atom = known(Atom) then
            !:Rev = [Frame ^ fr_body | !.Rev]
        else
            true
        ),
        walk_bodies(Atom, R1, !Rev)
    else
        true
    ).

:- pred body_field(reader::in, uint32::in, field_value::out) is semidet.

body_field(R0, Want, Value) :-
    next_field(FieldResult, R0, R1),
    FieldResult = field(Num, Value0),
    ( if Num = Want then Value = Value0 else body_field(R1, Want, Value) ).

    % A string field, or "" when absent.
    %
:- func body_string(reader, uint32) = string.

body_string(R, Num) =
    ( if body_field(R, Num, fv_bytes(Sub)), reader_string(Sub, S) then S
      else "" ).

%-----------------------------------------------------------------------------%
% A JSON Schema validator, over the subset dsc_diagnostics.schema.json uses
%-----------------------------------------------------------------------------%

    % `schema_errors(Schema, Instance)`: every way `Instance` breaks
    % `Schema`, none when it validates.
    %
    % A subset of JSON Schema 2020-12, the one dsc_diagnostics.schema.json and
    % dsc_schemas.schema.json use: `type` (a name, or an array of names),
    % `required`, `properties`, `additionalProperties: false`, `enum`,
    % `const`, `oneOf`, `pattern`, `minimum`, `minLength`, `items` and a `$ref`
    % into `#/$defs`; `$schema`, `$id`, `title`, `description` and `$defs` are
    % annotations. Any other keyword is an error, never an assertion passed
    % over, and one inside a `oneOf` branch too.
    %
    % Each assertion applies to its own kind, as the specification has it:
    % `pattern` and `minLength` to a string, `minimum` to an integer, the
    % object keywords to an object, `items` to an array. `type` is what
    % refuses the wrong kind. `pattern` is RE2's, unanchored, as the
    % specification's is; the schema anchors its own.
    %
:- func schema_errors(json, json) = list(string).

schema_errors(Root, Instance) = list.reverse(Errors) :-
    validate(Root, "#", Root, Instance, [], Errors).

:- pred validate(json::in, string::in, json::in, json::in,
                 list(string)::in, list(string)::out) is det.

validate(Root, Where, Schema, Instance, !Errors) :-
    ( if Schema = j_object(Keywords) then
        list.foldl(keyword(Root, Where, Keywords, Instance),
            members(Keywords), !Errors)
    else
        !:Errors = [Where ++ ": the schema is not an object" | !.Errors]
    ).

:- pred keyword(json::in, string::in, json_members::in, json::in,
                pair(string, json)::in,
                list(string)::in, list(string)::out) is det.

keyword(Root, Where, Keywords, Instance, Key - Value, !Errors) :-
    ( if
        ( Key = "$schema" ; Key = "$id" ; Key = "title"
        ; Key = "description" ; Key = "$defs" )
    then
        true
    else if Key = "$ref" then
        ( if
            Value = j_string(Ref),
            string.remove_prefix("#/$defs/", Ref, Name),
            Root = j_object(RootKeywords),
            lookup_member(RootKeywords, "$defs", j_object(Defs)),
            lookup_member(Defs, Name, Target)
        then
            validate(Root, Where, Target, Instance, !Errors)
        else
            not_understood(Where, Key, !Errors)
        )
    else if Key = "type" then
        ( if Value = j_string(Type), known_type(Type) then
            ( if of_type(Type, Instance) then
                true
            else
                !:Errors = [Where ++ ": not " ++ Type | !.Errors]
            )
        else if
            Value = j_array(Types0),
            Types0 = [_ | _],
            list.map(json_string, Types0, Types),
            list.all_true(known_type, Types)
        then
            ( if
                list.find_first_match(
                    ( pred(Type::in) is semidet :- of_type(Type, Instance) ),
                    Types, _)
            then
                true
            else
                !:Errors = [Where ++ ": not " ++ string.join_list(" or ", Types)
                    | !.Errors]
            )
        else
            not_understood(Where, Key, !Errors)
        )
    else if Key = "const" then
        ( if Instance = Value then
            true
        else
            !:Errors = [Where ++ ": not the `const`" | !.Errors]
        )
    else if Key = "oneOf" then
        ( if Value = j_array(Branches), Branches = [_ | _] then
            BranchErrors = list.map(
                ( func(Branch) = Es :-
                    validate(Root, Where, Branch, Instance, [], Es) ),
                Branches),
            ( if
                list.find_first_match(
                    ( pred(Es::in) is semidet :-
                        list.find_first_match(not_a_keyword, Es, _) ),
                    BranchErrors, Unknown)
            then
                !:Errors = Unknown ++ !.Errors
            else
                Passing = list.filter(( pred(Es::in) is semidet :- Es = [] ),
                    BranchErrors),
                ( if Passing = [_] then
                    true
                else
                    !:Errors = [Where ++ ": matches "
                        ++ string.from_int(list.length(Passing))
                        ++ " branches of `oneOf`, not one" | !.Errors]
                )
            )
        else
            not_understood(Where, Key, !Errors)
        )
    else if Key = "required" then
        ( if Value = j_array(Names0), list.map(json_string, Names0, Names) then
            ( if Instance = j_object(Members) then
                list.foldl(required(Where, Members), Names, !Errors)
            else
                true
            )
        else
            not_understood(Where, Key, !Errors)
        )
    else if Key = "properties" then
        ( if Value = j_object(Properties) then
            ( if Instance = j_object(Members) then
                list.foldl(property(Root, Where, Members),
                    members(Properties), !Errors)
            else
                true
            )
        else
            not_understood(Where, Key, !Errors)
        )
    else if Key = "additionalProperties" then
        ( if Value = j_bool(no) then
            ( if Instance = j_object(Members) then
                ( if
                    lookup_member(Keywords, "properties", j_object(Declared0))
                then
                    Declared = Declared0
                else
                    Declared = empty_object
                ),
                list.foldl(declared(Where, Declared), members(Members),
                    !Errors)
            else
                true
            )
        else
            not_understood(Where, Key, !Errors)
        )
    else if Key = "items" then
        ( if Instance = j_array(Items) then
            list.foldl2(item(Root, Where, Value), Items, 0, _, !Errors)
        else
            true
        )
    else if Key = "enum" then
        ( if Value = j_array(Allowed) then
            ( if list.member(Instance, Allowed) then
                true
            else
                !:Errors = [Where ++ ": not one of `enum`" | !.Errors]
            )
        else
            not_understood(Where, Key, !Errors)
        )
    else if Key = "pattern" then
        ( if Value = j_string(Pattern) then
            ( if
                Instance = j_string(S),
                not re2_matches(Pattern, re2_flags(no, no, no), S)
            then
                !:Errors = [Where ++ ": does not match " ++ Pattern
                    | !.Errors]
            else
                true
            )
        else
            not_understood(Where, Key, !Errors)
        )
    else if Key = "minimum" then
        ( if Value = j_int(Min) then
            ( if Instance = j_int(N), N < Min then
                !:Errors = [Where ++ ": below `minimum`" | !.Errors]
            else
                true
            )
        else
            not_understood(Where, Key, !Errors)
        )
    else if Key = "minLength" then
        ( if Value = j_int(Min) then
            ( if
                Instance = j_string(S),
                int64.from_int(string.count_codepoints(S)) < Min
            then
                !:Errors = [Where ++ ": shorter than `minLength`" | !.Errors]
            else
                true
            )
        else
            not_understood(Where, Key, !Errors)
        )
    else
        not_understood(Where, Key, !Errors)
    ).

:- pred not_understood(string::in, string::in,
                       list(string)::in, list(string)::out) is det.

not_understood(Where, Key, !Errors) :-
    !:Errors = [Where ++ ": `" ++ Key ++ "` as written is not a keyword "
        ++ "this validator interprets" | !.Errors].

    % An error `not_understood` wrote.
    %
:- pred not_a_keyword(string::in) is semidet.

not_a_keyword(Error) :-
    string.sub_string_search(Error, "is not a keyword this validator", _).

:- pred known_type(string::in) is semidet.

known_type(Type) :-
    ( Type = "object" ; Type = "array" ; Type = "string" ; Type = "integer"
    ; Type = "number" ; Type = "boolean" ; Type = "null" ).

:- pred of_type(string::in, json::in) is semidet.

of_type("object", j_object(_)).
of_type("array", j_array(_)).
of_type("string", j_string(_)).
of_type("integer", j_int(_)).
of_type("number", j_int(_)).
of_type("number", j_float(_)).
of_type("boolean", j_bool(_)).
of_type("null", j_null).

:- pred json_string(json::in, string::out) is semidet.

json_string(j_string(S), S).

:- pred required(string::in, json_members::in, string::in,
                 list(string)::in, list(string)::out) is det.

required(Where, Members, Name, !Errors) :-
    ( if lookup_member(Members, Name, _) then
        true
    else
        !:Errors = [Where ++ ": no `" ++ Name ++ "`" | !.Errors]
    ).

:- pred property(json::in, string::in, json_members::in,
                 pair(string, json)::in,
                 list(string)::in, list(string)::out) is det.

property(Root, Where, Members, Name - Schema, !Errors) :-
    ( if lookup_member(Members, Name, Value) then
        validate(Root, Where ++ "/" ++ Name, Schema, Value, !Errors)
    else
        true
    ).

:- pred declared(string::in, json_members::in, pair(string, json)::in,
                 list(string)::in, list(string)::out) is det.

declared(Where, Declared, Name - _, !Errors) :-
    ( if lookup_member(Declared, Name, _) then
        true
    else
        !:Errors = [Where ++ ": `" ++ Name ++ "` is not declared" | !.Errors]
    ).

:- pred item(json::in, string::in, json::in, json::in, int::in, int::out,
             list(string)::in, list(string)::out) is det.

item(Root, Where, Schema, Value, I, Next, !Errors) :-
    validate(Root, Where ++ "/" ++ string.from_int(I), Schema, Value,
        !Errors),
    Next = I + 1.

    % The compiler's stack use does not grow with its input: 100 schemas of 250
    % slots ([LGRA.5.11]'s most is 255), 25,000 identifiers and 37,500 tokens,
    % compile on the suite's own stack with no stack size raised.
    %
    % Few declarations, many tokens each: many declarations are
    % `cases_scaling`'s subject.
    %
    % A per-token frame costs nothing where the C compiler turns sibling calls
    % into jumps, and crashes where it does not, as on arm64, which runs this
    % suite after every merge. A pass that recurses once per declaration
    % without a tail call fails here on every host.
    %
:- pred cases_large(tally::in, tally::out, io::di, io::uo) is det.

cases_large(!T, !IO) :-
    large_lines(1, 100, 250, [], RevLines),
    Source = "use default\n" ++ string.append_list(list.reverse(RevLines)),
    write_file("cli_large.ds", Source, !IO),
    remove("cli_large.dsc", !IO),
    invoke(["compile", "cli_large.ds", "-o", "cli_large.dsc"], "", L, !IO),
    non_empty_file("cli_large.dsc", Wrote, !IO),
    check("a source of 25,000 identifiers compiles: exit 0, and the "
            ++ "artefact is written" ++ ( if L ^ o_err = "" then ""
                else " -- " ++ L ^ o_err ),
        bool.and(status_is(0, L), Wrote), !T, !IO).

    % Schemas `S<K>` for K from `K` to `NSchemas`, each with `NSlots` slots
    % `s<I>: Int`, as lines prepended to the accumulator. By loops: the
    % test's own construction must not take stack per line either.
    %
:- pred large_lines(int::in, int::in, int::in, list(string)::in,
                    list(string)::out) is det.

large_lines(K, NSchemas, NSlots, !Acc) :-
    ( if K > NSchemas then
        true
    else
        !:Acc = ["\nschema S" ++ string.from_int(K) ++ " scope explicit:\n"
            | !.Acc],
        slot_lines(1, NSlots, !Acc),
        large_lines(K + 1, NSchemas, NSlots, !Acc)
    ).

:- pred slot_lines(int::in, int::in, list(string)::in, list(string)::out)
    is det.

slot_lines(I, N, !Acc) :-
    ( if I > N then
        true
    else
        !:Acc = ["    s" ++ string.from_int(I) ++ ": Int\n" | !.Acc],
        slot_lines(I + 1, N, !Acc)
    ).

    % A slot or pattern index is a byte, and 255 is reserved ([RDSC.4a.9.1]):
    % a schema of 255 slots and a rule of 255 patterns compile, and one more
    % of either is refused, exit 1, with its code ([LGRA.5.11], [LGRA.8.7]).
    % The conformance vectors `LGRA.5.11_*` and `LGRA.8.7_*` hold the same
    % bounds; these build the sources by loop.
    %
:- pred cases_byte_indexes(tally::in, tally::out, io::di, io::uo) is det.

cases_byte_indexes(!T, !IO) :-
    list.foldl2(byte_index_case,
        [{"a schema of 255 slots", "cli_slots_255", slots_source(255), ""},
         {"a schema of 256 slots", "cli_slots_256", slots_source(256),
            "DS_VALIDATE_SCHEMA_TOO_MANY_SLOTS"},
         {"a rule of 255 patterns", "cli_patterns_255", patterns_source(255),
            ""},
         {"a rule of 256 patterns", "cli_patterns_256", patterns_source(256),
            "DS_VALIDATE_RULE_TOO_MANY_PATTERNS"}],
        !T, !IO).

    % One source, compiled: exit 0 and an artefact when `Code` is empty,
    % else exit 1 naming `Code`.
    %
:- pred byte_index_case({string, string, string, string}::in,
                        tally::in, tally::out, io::di, io::uo) is det.

byte_index_case({Label, Stem, Source, Code}, !T, !IO) :-
    write_file(Stem ++ ".ds", Source, !IO),
    remove(Stem ++ ".dsc", !IO),
    invoke(["compile", Stem ++ ".ds", "-o", Stem ++ ".dsc"], "", O, !IO),
    ( if Code = "" then
        non_empty_file(Stem ++ ".dsc", Wrote, !IO),
        check("[RDSC.4a.9.1] " ++ Label ++ " compiles"
                ++ ( if O ^ o_err = "" then "" else " -- " ++ O ^ o_err ),
            bool.and(status_is(0, O), Wrote), !T, !IO)
    else
        check("[RDSC.4a.9.1] " ++ Label ++ " is refused with " ++ Code
                ++ ", exit 1",
            ( if
                O ^ o_status = 1,
                string.sub_string_search(O ^ o_err, Code, _)
              then yes else no ), !T, !IO)
    ).

    % Schema `S` with `N` slots `s1` .. `sN`.
    %
:- func slots_source(int) = string.

slots_source(N) = Source :-
    slot_lines(1, N, [], RevLines),
    Source = "use default\n\nschema S scope explicit:\n"
        ++ string.append_list(list.reverse(RevLines)).

    % Rule `r` over `N` patterns of `S`, bound `pat1` .. `patN`, each read in
    % its own `where`: an unreferenced binding is refused ([LGRA.8.6]). Not
    % `p<N>`: `p50` and its kin are reserved builtin names ([LGRA.22.7]).
    %
:- func patterns_source(int) = string.

patterns_source(N) = Source :-
    pattern_lines(1, N, [], RevLines),
    Source = "use default\n\nschema S scope explicit:\n    v: Int\n\nrule r:\n"
        ++ string.append_list(list.reverse(RevLines))
        ++ "->\n    log info \"r\"\n".

:- pred pattern_lines(int::in, int::in, list(string)::in, list(string)::out)
    is det.

pattern_lines(I, N, !Acc) :-
    ( if I > N then
        true
    else
        Name = "pat" ++ string.from_int(I),
        !:Acc = ["    S " ++ Name ++ " where " ++ Name ++ ".v > 0\n" | !.Acc],
        pattern_lines(I + 1, N, !Acc)
    ).

    % Compile time grows linearly with the number of declarations.
    %
    % A ratio, never a time limit: a check that can hang is disabled, never
    % given a timeout (TESTING.md), and seconds measure the host. `scaling_n`
    % `const`s and four times as many; the larger must cost less than twelve
    % times the smaller. Linear is four on paper and quadratic sixteen, but
    % between these sizes the live data outgrows the caches and every phase
    % costs more per declaration, so linear measures between six and eight.
    %
    % The one-`const` program's cost, the same at every size, is subtracted
    % from both, or it would pull the ratio toward one. CPU time, the least of
    % three compiles, so other jobs and a stray collection do not count.
    %
:- pred cases_scaling(tally::in, tally::out, io::di, io::uo) is det.

cases_scaling(!T, !IO) :-
    const_cost(1, Base, !IO),
    const_cost(scaling_n, Small, !IO),
    const_cost(4 * scaling_n, Large, !IO),
    ( if
        Base = yes(B),
        Small = yes(S),
        Large = yes(L)
    then
        Curve = string.format("CPU clock ticks: %d for 1 `const`, %d for %d, "
            ++ "%d for %d", [i(B), i(S), i(scaling_n), i(L), i(4 * scaling_n)]),
        io.format("  cli: const scaling %s\n", [s(Curve)], !IO),
        check("four times the `const`s cost less than twelve times the "
                ++ "compile time -- " ++ Curve,
            ( if S - B > 0, L - B < 12 * (S - B) then yes else no ), !T, !IO)
    else
        check("a source of `const`s compiles at every size: exit 0, "
            ++ "and the artefact is written", no, !T, !IO)
    ).

:- func scaling_n = int.

scaling_n = 5000.

    % The least CPU time of three compiles of a source of `N` `const`s, or
    % `no` when any compile fails or writes no artefact.
    %
:- pred const_cost(int::in, maybe(int)::out, io::di, io::uo) is det.

const_cost(N, Cost, !IO) :-
    const_lines(1, N, [], RevLines),
    write_file("cli_consts.ds",
        "use default\n" ++ string.append_list(list.reverse(RevLines)), !IO),
    timed_compiles(3, [], Ticks, yes, Ok, !IO),
    ( if Ok = yes, Ticks = [First | Rest] then
        Cost = yes(list.foldl(int.min, Rest, First))
    else
        Cost = no
    ).

:- pred timed_compiles(int::in, list(int)::in, list(int)::out,
                       bool::in, bool::out, io::di, io::uo) is det.

timed_compiles(K, !Ticks, !Ok, !IO) :-
    ( if K =< 0 then
        true
    else
        remove("cli_consts.dsc", !IO),
        time.clock(Before, !IO),
        invoke(["compile", "cli_consts.ds", "-o", "cli_consts.dsc"], "", O,
            !IO),
        time.clock(After, !IO),
        non_empty_file("cli_consts.dsc", Wrote, !IO),
        !:Ticks = [After - Before | !.Ticks],
        !:Ok = bool.and_list([!.Ok, status_is(0, O), Wrote]),
        timed_compiles(K - 1, !Ticks, !Ok, !IO)
    ).

    % `const C<I> = <I>` for I from `I` to `N`, as lines prepended to the
    % accumulator. By a loop, as `slot_lines` is.
    %
:- pred const_lines(int::in, int::in, list(string)::in, list(string)::out)
    is det.

const_lines(I, N, !Acc) :-
    ( if I > N then
        true
    else
        S = string.from_int(I),
        !:Acc = ["const C" ++ S ++ " = " ++ S ++ "\n" | !.Acc],
        const_lines(I + 1, N, !Acc)
    ).

%-----------------------------------------------------------------------------%
% An internal compiler error -- [RCLI.3.1]
%-----------------------------------------------------------------------------%

    % [RCLI.3.1]: a compiler that cannot finish exits 3, writes the reason to
    % standard error, writes nothing to standard output and no file at `-o`'s
    % path, and renders no diagnostic.
    %
    % The linked `./dsc_cli`, not `invoke`: the 3 comes from
    % `rcli_3_1_run`'s hooks, which `dsc_cli.main` arms and `run` does not.
    %
    % Its memory is exhausted on purpose: Boehm's heap capped at 2 MB
    % (GC_MAXIMUM_HEAP_SIZE) and a source of `oom_n` `const`s. Uncapped it
    % compiles (the control), so the 3 is the cap's.
    %
    % No case raises an exception: `rcli_3_1_run`'s caught-exception arm has
    % no hook to reach it, and the `MR_fatal_error` arm is the js-dsc gate's
    % `overflow` case, on the wasm32 build.
    %
:- pred cases_internal_error(tally::in, tally::out, io::di, io::uo) is det.

cases_internal_error(!T, !IO) :-
    const_lines(1, oom_n, [], RevLines),
    write_file("cli_oom.ds",
        "use default\n" ++ string.append_list(list.reverse(RevLines)), !IO),
    list.foldl(remove, ["cli_oom_ok.dsc", "cli_oom.dsc"], !IO),

    spawn_dsc("", "-o cli_oom_ok.dsc", "cli_oom_ok", Control, !IO),
    non_empty_file("cli_oom_ok.dsc", Compiled, !IO),
    read_text("cli_oom_ok.err", ControlErr, !IO),
    check("[RCLI.3.1] the control: uncapped, the source compiles (exit "
            ++ string.from_int(Control) ++ ") " ++ ControlErr,
        ( if Control = 0, Compiled = yes then yes else no ), !T, !IO),

    spawn_dsc(oom_cap, "-o cli_oom.dsc", "cli_oom", Capped, !IO),
    absent("cli_oom.dsc", NoFile, !IO),
    read_text("cli_oom.out", CappedOut, !IO),
    read_text("cli_oom.err", CappedErr, !IO),
    % @spec [RCLI.3.1]
    check("[RCLI.3.1] out of memory: exit 3 (got " ++ string.from_int(Capped)
            ++ "), the reason on stderr, no diagnostic, nothing on stdout and "
            ++ "no file at -o's path -- " ++ CappedErr,
        ( if
            Capped = 3,
            NoFile = yes,
            CappedOut = "",
            string.sub_string_search(CappedErr, "internal compiler error", _),
            not string.sub_string_search(CappedErr, "DS_", _)
        then yes else no ), !T, !IO),

    spawn_dsc(oom_cap, "-o -", "cli_oom_stdout", ToStdout, !IO),
    read_bytes("cli_oom_stdout.out", Written, !IO),
    % @spec [RCLI.3.1]
    check("[RCLI.3.1] out of memory under `-o -`: exit 3 (got "
            ++ string.from_int(ToStdout) ++ ") and nothing on stdout",
        ( if ToStdout = 3, bitmap.num_bits(Written) = 0 then yes else no ),
        !T, !IO).

    % [RCLI.1.4]: an internal compiler error ends `compile-project` at once
    % with 3 ([RCLI.3.1]), and the artefacts already written for earlier
    % modules stay. PATH: `compile-project`'s per-program loop
    % (`project_files`, `project_file`) through `rcli_3_1_run`'s exhaustion
    % arm, Boehm's out-of-memory hook, in the linked `./dsc_cli` under
    % `cases_internal_error`'s cap.
    %
    % `compile-project` compiles in path order, so `a.ds`, one `const`, fits
    % under the cap and `b.ds`, `oom_n` of them, does not. Standard output is
    % not judged: it carries progress lines, and [RCLI.3.1]'s "nothing to
    % standard output" is about the artefact.
    %
:- pred test_rcli_1_4_project_ends_at_exit_3(tally::in, tally::out,
                                             io::di, io::uo) is det.

test_rcli_1_4_project_ends_at_exit_3(!T, !IO) :-
    const_lines(1, oom_n, [], RevLines),
    make_dir("cli_oom_project/rules", !IO),
    write_file("cli_oom_project/rules/a.ds", "use default\nconst C1 = 1\n",
        !IO),
    write_file("cli_oom_project/rules/b.ds",
        "use default\n" ++ string.append_list(list.reverse(RevLines)), !IO),
    Written = ["cli_oom_project/rules/a.dsc", "cli_oom_project/rules/a_dsc.h"],
    Unwritten = ["cli_oom_project/rules/b.dsc",
                 "cli_oom_project/rules/b_dsc.h"],
    list.foldl(remove, Written ++ Unwritten, !IO),

    io.call_system(oom_cap ++ "./dsc_cli compile-project cli_oom_project"
        ++ " > /dev/null 2> cli_oom_project.err", Res, !IO),
    Status = ( if Res = ok(S) then S else -1 ),
    list.map_foldl(non_empty_file, Written, Kept, !IO),
    list.map_foldl(absent, Unwritten, Gone, !IO),
    read_text("cli_oom_project.err", Err, !IO),
    % @spec [RCLI.1.4]
    check("[RCLI.1.4] `compile-project` out of memory at its second program: "
            ++ "exit 3 (got " ++ string.from_int(Status) ++ "), the first "
            ++ "program's .dsc and _dsc.h kept, none for the second, no "
            ++ "diagnostic -- " ++ Err,
        ( if
            Status = 3,
            list.all_true(( pred(K::in) is semidet :- K = yes ), Kept),
            list.all_true(( pred(G::in) is semidet :- G = yes ), Gone),
            string.sub_string_search(Err, "internal compiler error", _),
            not string.sub_string_search(Err, "DS_", _)
        then yes else no ), !T, !IO).

    % How many `const`s: four times what `cases_scaling`'s smaller compile
    % takes, which is what its larger one compiles in this suite's heap.
    %
:- func oom_n = int.

oom_n = 4 * scaling_n.

    % The environment that caps the heap. Boehm reads it when it starts.
    %
:- func oom_cap = string.

oom_cap = "GC_MAXIMUM_HEAP_SIZE=2097152 ".

    % `<Env>./dsc_cli compile cli_oom.ds <OutArgs>`, its standard output and
    % error in `<Stem>.out` and `<Stem>.err`, and its exit status: -1 when the
    % shell could not run it.
    %
:- pred spawn_dsc(string::in, string::in, string::in, int::out,
                  io::di, io::uo) is det.

spawn_dsc(Env, OutArgs, Stem, Status, !IO) :-
    io.call_system(Env ++ "./dsc_cli compile cli_oom.ds " ++ OutArgs
        ++ " > " ++ Stem ++ ".out 2> " ++ Stem ++ ".err", Res, !IO),
    ( if Res = ok(S) then Status = S else Status = -1 ).

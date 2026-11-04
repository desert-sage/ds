% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.cli -- the compiler's command line, as a predicate over its streams.
%
% `run` takes the arguments and the four streams and returns the exit status.
% `dsc_cli.main` hands it the process's own; test_cli hands it streams over
% files. The compiler below this module reads no filesystem.
%
%   0   an artefact was written
%   1   the source was refused -- rejected by a checker, or stopped in the
%       front end
%   2   the invocation was wrong, or a file could not be read or written
%   3   the compiler could not finish: a fault in it, or its memory exhausted
%       ([RCLI.3.1])
%
% `run` never returns 3: `rcli_3_1_run`, what `main` calls, is where that
% becomes the status.
%
% `check` is `compile` writing no artefact, with `compile`'s exit codes. It is
% this compiler's own subcommand, outside the surface ([RCLI.1.3]).
%
% A source on standard input has no directory, so its imports come from `-L`
% and the bundled standard library alone.
%-----------------------------------------------------------------------------%

:- module dsc.cli.
:- interface.

:- import_module io.
:- import_module list.

    % The standard library this compiler ships with: found, or looked for and
    % not there.
    %
    %@helper
:- type bundle
    --->    bundle_at(string)
                % The directory it is in.
    ;       no_bundle(string).
                % Where it was looked for: the directory, or why there was
                % none to look in.

    % The library of a compiler invoked as `Prog`: `../share/ds/stdlib` beside
    % its executable, which is `Prog` when it has a `/`, else the first `PATH`
    % entry holding a file of that name. Every link on the way is followed, a
    % relative target against the link's own directory. A chain that ends
    % nowhere, or does not end, is `no_bundle`.
    %
    %@spec [LIMP.3.3.1]
    %@spec [RCLI.1.11]
:- pred limp_3_3_1_bundled_library(string::in, bundle::out,
                                   io::di, io::uo) is det.

    %@helper
:- type cli_streams
    --->    cli_streams(
                cs_in   :: io.text_input_stream,
                    % Standard input: `-` as an input.
                cs_out  :: io.text_output_stream,
                    % Standard output, for text: `--version`, `--help`, the
                    % dumps, `compile-project`'s progress lines.
                cs_bin  :: io.binary_output_stream,
                    % Standard output, for bytes: `compile -o -`.
                cs_err  :: io.text_output_stream
                    % Standard error: every refusal and warning.
            ).

    % `run(Args, Bundle, Streams, Status, !IO)`: `Args` excludes the program
    % name.
    %
    %@helper
:- pred run(list(string)::in, bundle::in, cli_streams::in, int::out,
            io::di, io::uo) is det.

    % `run` as the process runs it: an invocation the compiler cannot finish
    % exits 3, with the reason on standard error and the file it was writing
    % removed. An exception is caught here. The Mercury runtime ending the
    % process, and Boehm's heap exhausted, reach 3 through the C hooks below.
    %
    % An I/O error is a path that could not be written: 2, not 3.
    %
    % Every subcommand writes standard output after computing it, and the hooks
    % end the process with `_exit`, so a compile that stops leaves none of it.
    %
    % docs/PROMISE_LEDGER.md lists this module's promises.
    %
    %@spec [RCLI.3.1]
:- pred rcli_3_1_run(list(string)::in, bundle::in, cli_streams::in, int::out,
                     io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.astjson.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.dialect.
:- import_module dsc.driver.
:- import_module dsc.encode.
:- import_module dsc.render.
:- import_module dsc.imports.
:- import_module dsc.token.
:- import_module dsc.uniname.
:- import_module dsc.yaml.
:- import_module ds.
:- import_module ds.version.

:- import_module bool.
:- import_module char.
:- import_module dir.
:- import_module exception.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module set.
:- import_module string.
:- import_module uint8.
:- import_module univ.

%-----------------------------------------------------------------------------%

    %@helper
:- type diag_format
    --->    df_text
                % Rendered for a person; the default.
    ;       df_json.
                % One document, `compiler/dsc_diagnostics.schema.json`'s.

    % A search-path entry: a `-L` directory, whose libraries are named by the
    % path as the entry spells it, or the bundled library, whose libraries are
    % named `<stdlib>/` and their path in it, wherever it is installed
    % ([RDSC.14.2.3]).
    %
    %@helper
:- type search_dir
    --->    sd_entry(string)
    ;       sd_bundle(string).

    %@helper
:- type invocation
    --->    inv_compile(
                iv_input    :: string,
                    % A path, or `-` for standard input.
                iv_output   :: string,
                    % A path, or `-` for standard output.
                iv_format   :: diag_format,
                iv_label    :: maybe(string),
                    % `--filename`: what diagnostics and the DsSource atom call
                    % the input. `no` is the path as given, or `<stdin>`.
                iv_dsrt     :: maybe(string),
                    % `--dsrt`, which is refused ([LCAP.2.1.5]).
                iv_dialects :: list(string),
                    % `-d` files, in the order they register.
                iv_search   :: list(search_dir)
                    % `-L` directories, in the order given, then the bundle.
            )
    ;       inv_project(
                ip_dir       :: string,
                ip_no_header :: bool,
                ip_dialects  :: list(string),
                ip_search    :: list(search_dir)
            )
    ;       inv_dump(
                id_input    :: string,
                id_output   :: maybe(string),
                    % `no`, or `-o -`, is stdout.
                id_dialects :: list(string),
                id_search   :: list(search_dir),
                id_json     :: bool
                    % `--json`: the document of [RCLI.1.14], not proto3.
            )
    ;       inv_check(
                ic_input    :: string,
                    % A path, or `-` for standard input.
                ic_format   :: diag_format,
                ic_label    :: maybe(string),
                ic_dump_ast :: bool,
                ic_dialects :: list(string),
                ic_search   :: list(search_dir)
            )
    ;       inv_dump_ast(
                ia_input  :: string,
                    % A path, or `-` for standard input.
                ia_label  :: maybe(string),
                ia_output :: maybe(string),
                    % `no`, or `-o -`, is stdout.
                ia_format :: diag_format
            )
    ;       inv_version
    ;       inv_usage(string).
            % The message explaining why not, or "" for a bare `--help`.

run(Args, Bundle, S, ExitStatus, !IO) :-
    parse_args(Args, Inv0),
    ( if
        Bundle = no_bundle(Where),
        rcli_1_11_resolves(Inv0)
    then
        io.format(S ^ cs_err, "dsc: %s\n", [s(rcli_1_11_no_bundle(Where))],
            !IO),
        ExitStatus = 2
    else
        run_invocation(S, limp_3_3_1_bundle(Bundle, Inv0), ExitStatus, !IO)
    ).

%-----------------------------------------------------------------------------%
% An internal compiler error -- [RCLI.3.1]
%-----------------------------------------------------------------------------%

rcli_3_1_run(Args, Bundle, S, Status, !IO) :-
    rcli_3_1_install_exit_hooks(!IO),
    promise_equivalent_solutions [Result, !:IO] (
        exception.try_io(
            ( pred(St::out, IO0::di, IO1::uo) is det :-
                run(Args, Bundle, S, St, IO0, IO1) ),
            Result, !IO)
    ),
    (
        Result = succeeded(Status)
    ;
        Result = exception(Univ),
        rcli_3_1_abandon_output(!IO),
        ( if univ_to_type(Univ, IOError) then
            Status = 2,
            io.format(S ^ cs_err, "dsc: cannot write: %s\n",
                [s(io.error_message(IOError))], !IO)
        else
            Status = 3,
            io.format(S ^ cs_err,
                "dsc: internal compiler error ([RCLI.3.1]): %s\n",
                [s(rcli_3_1_reason(Univ))], !IO)
        )
    ),
    rcli_3_1_finished(!IO).

    %@helper
:- func rcli_3_1_reason(univ) = string.

rcli_3_1_reason(Univ) = Reason :-
    ( if univ_to_type(Univ, software_error(Message)) then
        Reason = Message
    else
        Reason = string.string(univ_value(Univ))
    ).

% The C half: the path being written, and the two hooks that end the process
% with 3 where no Mercury code runs. Nothing in a hook allocates -- one of them
% runs because allocation failed -- so the path sits in a fixed buffer, and the
% message is written with write(2).
%
% A path longer than the buffer is not recorded, so it is not removed; nothing
% the compiler is handed comes near that length.
:- pragma foreign_decl("C", local, "
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef MR_BOEHM_GC
  #include \"gc.h\"
#endif
").

:- pragma foreign_code("C", "
static char         dsc_rcli_3_1_path[4096];
static volatile int dsc_rcli_3_1_done = 0;

static void dsc_rcli_3_1_say(const char *m)
{
    ssize_t ignored = write(2, m, strlen(m));
    (void) ignored;
}

static void dsc_rcli_3_1_unlink(void)
{
    if (dsc_rcli_3_1_path[0] != '\\0') {
        (void) unlink(dsc_rcli_3_1_path);
        dsc_rcli_3_1_path[0] = '\\0';
    }
}

/* At exit before `rcli_3_1_run` returned: the runtime ended the process --
   MR_fatal_error, the wasm32 grade's heap overflow among them. Its own message
   is already on stderr; this one says what the status means. _exit, so the
   runtime's status does not stand and nothing still buffered is written. */
static void dsc_rcli_3_1_at_exit(void)
{
    if (dsc_rcli_3_1_done) return;
    dsc_rcli_3_1_unlink();
    dsc_rcli_3_1_say(\"dsc: internal compiler error ([RCLI.3.1]): the \"
        \"compiler stopped before it finished\\n\");
    _exit(3);
}

#ifdef MR_BOEHM_GC
/* Boehm's heap exhausted: its default hook returns NULL. */
static void *dsc_rcli_3_1_out_of_memory(size_t bytes)
{
    (void) bytes;
    dsc_rcli_3_1_unlink();
    dsc_rcli_3_1_say(\"dsc: internal compiler error ([RCLI.3.1]): out of \"
        \"memory\\n\");
    _exit(3);
    return NULL;
}
#endif
").

    %@helper
:- pred rcli_3_1_install_exit_hooks(io::di, io::uo) is det.

:- pragma foreign_proc("C",
    rcli_3_1_install_exit_hooks(IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    (void) atexit(dsc_rcli_3_1_at_exit);
#ifdef MR_BOEHM_GC
    GC_set_oom_fn(dsc_rcli_3_1_out_of_memory);
#endif
    IO = IO0;
").

    % `run` returned, with whatever status: the exit hook stands down.
    %
    %@helper
:- pred rcli_3_1_finished(io::di, io::uo) is det.

:- pragma foreign_proc("C",
    rcli_3_1_finished(IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    dsc_rcli_3_1_done = 1;
    IO = IO0;
").

    % The compiler is about to create `Path`: until `rcli_3_1_written`, a
    % compiler that stops removes it.
    %
    %@helper
:- pred rcli_3_1_writing(string::in, io::di, io::uo) is det.

:- pragma foreign_proc("C",
    rcli_3_1_writing(Path::in, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    if (strlen(Path) < sizeof dsc_rcli_3_1_path) {
        strcpy(dsc_rcli_3_1_path, Path);
    } else {
        dsc_rcli_3_1_path[0] = '\\0';
    }
    IO = IO0;
").

    % The file is closed, or was never opened: it stays.
    %
    %@helper
:- pred rcli_3_1_written(io::di, io::uo) is det.

:- pragma foreign_proc("C",
    rcli_3_1_written(IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    dsc_rcli_3_1_path[0] = '\\0';
    IO = IO0;
").

    % Remove the file being written, if one is.
    %
    %@helper
:- pred rcli_3_1_abandon_output(io::di, io::uo) is det.

:- pragma foreign_proc("C",
    rcli_3_1_abandon_output(IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    dsc_rcli_3_1_unlink();
    IO = IO0;
").

    % The invocations refused when there is no bundled library. A filter: a
    % subcommand that resolves a name and has no arm here compiles against no
    % library.
    %
    %@spec [RCLI.1.11]
:- pred rcli_1_11_resolves(invocation::in) is semidet.

rcli_1_11_resolves(inv_compile(_, _, _, _, _, _, _)).
rcli_1_11_resolves(inv_project(_, _, _, _)).
rcli_1_11_resolves(inv_dump(_, _, _, _, _)).
rcli_1_11_resolves(inv_check(_, _, _, _, _, _)).

    %@spec [RCLI.1.11]
:- func rcli_1_11_no_bundle(string) = string.

rcli_1_11_no_bundle(Where) =
    "no bundled standard library at " ++ Where ++ " ([RCLI.1.11]); a "
    ++ "compiler resolves nothing without it. It ships at "
    ++ "`../share/ds/stdlib` beside the `dsc` executable, as the release "
    ++ "tarball and the pyds wheel lay it out".

    %@helper
:- pred run_invocation(cli_streams::in, invocation::in, int::out,
                       io::di, io::uo) is det.

run_invocation(S, Inv, ExitStatus, !IO) :-
    some [!Status] (
        !:Status = 0,
        (
            Inv = inv_version,
            io.format(S ^ cs_out, "dsc %s\n", [s(ds.version.ds_version)], !IO)
        ;
            Inv = inv_usage(Why),
            ( if Why = "" then
                io.write_string(S ^ cs_out, usage, !IO)
            else
                io.format(S ^ cs_err, "dsc: %s\n", [s(Why)], !IO),
                io.write_string(S ^ cs_err, usage, !IO),
                !:Status = 2
            )
        ;
            Inv = inv_compile(In, Out, Format, Label, DsrtPath, Dialects,
                Search),
            run_compile(S, Format, In, Out, Label, DsrtPath, Dialects, Search,
                !Status, !IO)
        ;
            Inv = inv_project(Dir, NoHeader, Dialects, Search),
            run_project(S, Dir, NoHeader, Dialects, Search, !Status, !IO)
        ;
            Inv = inv_dump(In, Out, Dialects, Search, Json),
            run_dump(S, In, Out, Dialects, Search, Json, !Status, !IO)
        ;
            Inv = inv_check(In, Format, Label, DumpAst, Dialects, Search),
            run_check(S, Format, In, Label, DumpAst, Dialects, Search,
                !Status, !IO)
        ;
            Inv = inv_dump_ast(In, Label, Out, Format),
            rcli_1_10_dump_ast(S, Format, In, Label, Out, !Status, !IO)
        ),
        ExitStatus = !.Status
    ).

limp_3_3_1_bundled_library(Prog, Bundle, !IO) :-
    ( if string.contains_char(Prog, '/') then
        Named = yes(Prog)
    else
        io.get_environment_var("PATH", MaybePath, !IO),
        (
            MaybePath = yes(Path),
            on_path(string.split_at_char(':', Path), Prog, Named, !IO)
        ;
            MaybePath = no,
            Named = no
        )
    ),
    (
        Named = yes(File),
        rcli_1_11_follow_links(rcli_1_11_link_limit, File, Resolved, !IO),
        (
            Resolved = yes(Executable),
            Library = dir.dirname(Executable) / ".." / "share" / "ds"
                / "stdlib",
            io.file_type(yes, Library, Res, !IO),
            ( if Res = ok(directory) then
                Bundle = bundle_at(Library)
            else
                Bundle = no_bundle(Library)
            )
        ;
            Resolved = no,
            Bundle = no_bundle("`../share/ds/stdlib` beside `" ++ File
                ++ "`, a symbolic link that ends nowhere or does not end")
        )
    ;
        Named = no,
        Bundle = no_bundle("`../share/ds/stdlib` beside `" ++ Prog
            ++ "`, which is neither a path nor a file on PATH")
    ).

    % An empty `PATH` entry is the current directory. `file_type(yes, ...)`
    % follows links, so a link on `PATH` to a regular file counts.
    %
    %@helper
:- pred on_path(list(string)::in, string::in, maybe(string)::out,
                io::di, io::uo) is det.

on_path([], _, no, !IO).
on_path([Entry0 | Entries], Prog, Named, !IO) :-
    Entry = ( if Entry0 = "" then "." else Entry0 ),
    io.file_type(yes, Entry / Prog, Res, !IO),
    ( if Res = ok(regular_file) then
        Named = yes(Entry / Prog)
    else
        on_path(Entries, Prog, Named, !IO)
    ).

    % `File` with every link on the way resolved, a relative target against
    % the directory of the link that names it. `no` for a chain that ends at
    % nothing or is longer than `Hops` links, so a loop cannot hang.
    %
    %@spec [RCLI.1.11]
:- pred rcli_1_11_follow_links(int::in, string::in, maybe(string)::out,
                               io::di, io::uo) is det.

rcli_1_11_follow_links(Hops, File, Resolved, !IO) :-
    io.file_type(no, File, Res, !IO),
    ( if Res = ok(symbolic_link) then
        ( if Hops =< 0 then
            Resolved = no
        else
            io.read_symlink(File, TargetRes, !IO),
            (
                TargetRes = ok(Target),
                Next = ( if dir.path_name_is_absolute(Target) then Target
                         else dir.dirname(File) / Target ),
                rcli_1_11_follow_links(Hops - 1, Next, Resolved, !IO)
            ;
                TargetRes = error(_),
                Resolved = no
            )
        )
    else if Res = ok(_) then
        Resolved = yes(File)
    else
        Resolved = no
    ).

    % Linux's `MAXSYMLINKS`, so no chain the kernel resolves is refused.
    %
    %@helper
:- func rcli_1_11_link_limit = int.

rcli_1_11_link_limit = 40.

    % The `-L` directories a parse collected, last first, in the order given.
    %
    %@helper
:- func l_entries(list(string)) = list(search_dir).

l_entries(RevDirs) = list.map((func(D) = sd_entry(D)), list.reverse(RevDirs)).

    % The bundle is the last search-path entry, so `-L` directories come first.
    %
    %@spec [LIMP.3.3.1]
:- func limp_3_3_1_bundle(bundle, invocation) = invocation.

limp_3_3_1_bundle(no_bundle(_), Inv) = Inv.
limp_3_3_1_bundle(bundle_at(Dir), Inv0) = Inv :-
    Bundle = sd_bundle(Dir),
    (
        Inv0 = inv_compile(In, Out, Format, Label, Dsrt, Dialects, Search),
        Inv = inv_compile(In, Out, Format, Label, Dsrt, Dialects,
            Search ++ [Bundle])
    ;
        Inv0 = inv_project(Sketch, NoHeader, Dialects, Search),
        Inv = inv_project(Sketch, NoHeader, Dialects, Search ++ [Bundle])
    ;
        Inv0 = inv_dump(In, Out, Dialects, Search, Json),
        Inv = inv_dump(In, Out, Dialects, Search ++ [Bundle], Json)
    ;
        Inv0 = inv_check(In, Format, Label, DumpAst, Dialects, Search),
        Inv = inv_check(In, Format, Label, DumpAst, Dialects,
            Search ++ [Bundle])
    ;
        ( Inv0 = inv_dump_ast(_, _, _, _)
        ; Inv0 = inv_version
        ; Inv0 = inv_usage(_)
        ),
        Inv = Inv0
    ).

    %@helper
:- pred parse_args(list(string)::in, invocation::out) is det.

parse_args([], inv_usage("")).
parse_args([A | As], Inv) :-
    ( if A = "--version" then
        Inv = inv_version
    else if ( A = "--help" ; A = "-h" ) then
        Inv = inv_usage("")
    else if A = "compile" then
        parse_compile(As, compile_args(no, no, df_text, no, no, [], []), Inv)
    else if A = "compile-project" then
        parse_project(As, no, no, [], [], Inv)
    else if A = "dump-schemas" then
        parse_dump(As, no, no, [], [], no, Inv)
    else if A = "dump-ast" then
        parse_dump_ast(As, no, no, no, df_text, Inv)
    else if A = "check" then
        parse_check(As, check_args(no, df_text, no, no, [], []), Inv)
    else
        Inv = inv_usage("unknown subcommand `" ++ A ++ "`")
    ).

    %@helper
:- type compile_args
    --->    compile_args(
                ca_in       :: maybe(string),
                ca_out      :: maybe(string),
                ca_format   :: diag_format,
                ca_label    :: maybe(string),
                ca_dsrt     :: maybe(string),
                ca_dialects :: list(string),    % reversed
                ca_search   :: list(string)     % reversed
            ).

    %@helper
:- pred parse_compile(list(string)::in, compile_args::in, invocation::out)
    is det.

parse_compile([], CA, Inv) :-
    ( if CA ^ ca_in = yes(Input) then
        ( if CA ^ ca_out = yes(Output) then
            Inv = inv_compile(Input, Output, CA ^ ca_format, CA ^ ca_label,
                CA ^ ca_dsrt, list.reverse(CA ^ ca_dialects),
                l_entries(CA ^ ca_search))
        else
            Inv = inv_usage("`compile` needs `-o <output>`, or `-o -`")
        )
    else
        Inv = inv_usage("`compile` needs an input path, or `-`")
    ).
parse_compile([A | As], CA, Inv) :-
    ( if A = "--diagnostics" then
        rcli_3_2_parse_diagnostics(A, As, Parsed),
        (
            Parsed = ok({Format, Rest}),
            parse_compile(Rest, CA ^ ca_format := Format, Inv)
        ;
            Parsed = error(Why),
            Inv = inv_usage(Why)
        )
    else if
        compile_valued_option(A, Needs, Set)
    then
        (
            As = [Value | Rest],
            parse_compile(Rest, Set(Value, CA), Inv)
        ;
            As = [],
            Inv = inv_usage("`" ++ A ++ "` needs " ++ Needs)
        )
    else if A = "--emit-rete" then
        Inv = inv_usage("--emit-rete is not available in v1 -- it only "
            ++ "keeps the Rete network beside `--emit-aot`'s CompiledCode atoms, and "
            ++ "the emit flags are deferred with AOT ([IAOT.3.2]). A "
            ++ "plain `dsc compile` emits the Rete network")
    else if A = "--dialect" then
        Inv = inv_usage("`--dialect` is retired: a program names its dialect "
            ++ "in its own `use` line, and a file without one is a library, "
            ++ "which is not built on its own ([LDIA.2.10.1], [LDIA.2.10.8])")
    else if A = "--emit-aot" then
        Inv = inv_usage("--emit-aot is not available in v1 -- AOT is frozen "
            ++ "and [IAOT.3.1] is deferred. The Rete network is "
            ++ "emitted as normal; no CompiledCode atoms are produced")
    else if
        ( A = "--cc" ; A = "--objcopy" ; A = "--cflags" )
    then
        Inv = inv_usage("`" ++ A ++ "` is not implemented in this compiler "
            ++ "yet, and is refused rather than ignored")
    else if A \= "-", string.prefix(A, "-") then
        Inv = inv_usage("unknown option `" ++ A ++ "`")
    else if CA ^ ca_in = no then
        parse_compile(As, CA ^ ca_in := yes(A), Inv)
    else
        Inv = inv_usage("more than one input path")
    ).

    % `compile`'s options that take a value: what the value is, for the
    % refusal when it is missing, and where it goes.
    %
    %@helper
:- pred compile_valued_option(string::in, string::out,
    (func(string, compile_args) = compile_args)::out(func(in, in) = out is det))
    is semidet.

compile_valued_option(A, Needs, Set) :-
    ( if ( A = "-o" ; A = "--output" ) then
        Needs = "a path, or `-`",
        Set = ( func(V, CA) = CA ^ ca_out := yes(V) )
    else if A = "--filename" then
        Needs = "a name",
        Set = ( func(V, CA) = CA ^ ca_label := yes(V) )
    else if A = "--dsrt" then
        Needs = "a file",
        Set = ( func(V, CA) = CA ^ ca_dsrt := yes(V) )
    else if ( A = "-d" ; A = "--dialect-file" ) then
        Needs = "a file",
        Set = ( func(V, CA) = CA ^ ca_dialects := [V | CA ^ ca_dialects] )
    else
        ( A = "-L" ; A = "--search-path" ),
        Needs = "a directory",
        Set = ( func(V, CA) = CA ^ ca_search := [V | CA ^ ca_search] )
    ).

    %@spec [RCLI.3.2]
:- pred rcli_3_2_parse_diagnostics(string::in, list(string)::in,
    maybe_error({diag_format, list(string)})::out) is det.

rcli_3_2_parse_diagnostics(A, As, Parsed) :-
    (
        As = [],
        Parsed = error("`" ++ A ++ "` needs `text` or `json`")
    ;
        As = [Value | Rest],
        ( if Value = "text" then
            Parsed = ok({df_text, Rest})
        else if Value = "json" then
            Parsed = ok({df_json, Rest})
        else
            Parsed = error("`" ++ A ++ "` takes `text` or `json`, not `"
                ++ Value ++ "`")
        )
    ).

    %@helper
:- pred parse_project(list(string)::in, maybe(string)::in, bool::in,
                      list(string)::in, list(string)::in, invocation::out)
    is det.

parse_project([], Dir, NoHeader, RevDialects, RevSearch, Inv) :-
    (
        Dir = yes(D),
        Inv = inv_project(D, NoHeader, list.reverse(RevDialects),
            l_entries(RevSearch))
    ;
        Dir = no,
        Inv = inv_usage("`compile-project` needs a sketch directory")
    ).
parse_project([A | As], Dir, NoHeader, RevDialects, RevSearch, Inv) :-
    ( if ( A = "-L" ; A = "--search-path" ) then
        (
            As = [Value | Rest],
            parse_project(Rest, Dir, NoHeader, RevDialects,
                [Value | RevSearch], Inv)
        ;
            As = [],
            Inv = inv_usage("`" ++ A ++ "` needs a directory")
        )
    else if ( A = "-d" ; A = "--dialect-file" ) then
        (
            As = [Value | Rest],
            parse_project(Rest, Dir, NoHeader, [Value | RevDialects],
                RevSearch, Inv)
        ;
            As = [],
            Inv = inv_usage("`" ++ A ++ "` needs a file")
        )
    else if A = "--no-header" then
        parse_project(As, Dir, yes, RevDialects, RevSearch, Inv)
    else if A = "--strip" then
        Inv = inv_usage("`" ++ A ++ "` is not implemented in this compiler "
            ++ "yet, and is refused rather than ignored")
    else if string.prefix(A, "-") then
        Inv = inv_usage("unknown option `" ++ A ++ "`")
    else if Dir = no then
        parse_project(As, yes(A), NoHeader, RevDialects, RevSearch, Inv)
    else
        Inv = inv_usage("more than one sketch directory")
    ).

    %@helper
:- pred parse_dump(list(string)::in, maybe(string)::in, maybe(string)::in,
                   list(string)::in, list(string)::in, bool::in,
                   invocation::out) is det.

parse_dump([], In, Out, RevDialects, RevSearch, Json, Inv) :-
    (
        In = yes(Input),
        Inv = inv_dump(Input, Out, list.reverse(RevDialects),
            l_entries(RevSearch), Json)
    ;
        In = no,
        Inv = inv_usage("`dump-schemas` needs an input path")
    ).
parse_dump([A | As], In, Out, RevDialects, RevSearch, Json, Inv) :-
    ( if ( A = "-o" ; A = "--output" ) then
        (
            As = [Value | Rest],
            parse_dump(Rest, In, yes(Value), RevDialects, RevSearch, Json,
                Inv)
        ;
            As = [],
            Inv = inv_usage("`" ++ A ++ "` needs a path")
        )
    else if ( A = "-L" ; A = "--search-path" ) then
        (
            As = [Value | Rest],
            parse_dump(Rest, In, Out, RevDialects, [Value | RevSearch], Json,
                Inv)
        ;
            As = [],
            Inv = inv_usage("`" ++ A ++ "` needs a directory")
        )
    else if ( A = "-d" ; A = "--dialect-file" ) then
        (
            As = [Value | Rest],
            parse_dump(Rest, In, Out, [Value | RevDialects], RevSearch, Json,
                Inv)
        ;
            As = [],
            Inv = inv_usage("`" ++ A ++ "` needs a file")
        )
    else if A = "--json" then
        % [RCLI.1.14].
        parse_dump(As, In, Out, RevDialects, RevSearch, yes, Inv)
    else if A = "-" then
        Inv = inv_usage("`-` is not an input path")
    else if string.prefix(A, "-") then
        Inv = inv_usage("unknown option `" ++ A ++ "`")
    else if In = no then
        parse_dump(As, yes(A), Out, RevDialects, RevSearch, Json, Inv)
    else
        Inv = inv_usage("more than one input path")
    ).

    % The dump is syntax only, so it takes no dialect and no search path.
    %
    %@helper
:- pred parse_dump_ast(list(string)::in, maybe(string)::in, maybe(string)::in,
                       maybe(string)::in, diag_format::in, invocation::out)
    is det.

parse_dump_ast([], In, Label, Out, Format, Inv) :-
    (
        In = yes(Input),
        Inv = inv_dump_ast(Input, Label, Out, Format)
    ;
        In = no,
        Inv = inv_usage("`dump-ast` needs an input path, or `-`")
    ).
parse_dump_ast([A | As], In, Label, Out, Format, Inv) :-
    ( if A = "--diagnostics" then
        rcli_3_2_parse_diagnostics(A, As, Parsed),
        (
            Parsed = ok({Format1, Rest}),
            parse_dump_ast(Rest, In, Label, Out, Format1, Inv)
        ;
            Parsed = error(Why),
            Inv = inv_usage(Why)
        )
    else if ( A = "-o" ; A = "--output" ; A = "--filename" ) then
        (
            As = [Value | Rest],
            ( if A = "--filename" then
                parse_dump_ast(Rest, In, yes(Value), Out, Format, Inv)
            else
                parse_dump_ast(Rest, In, Label, yes(Value), Format, Inv)
            )
        ;
            As = [],
            Inv = inv_usage("`" ++ A ++ "` needs a value")
        )
    else if A \= "-", string.prefix(A, "-") then
        Inv = inv_usage("unknown option `" ++ A ++ "`")
    else if In = no then
        parse_dump_ast(As, yes(A), Label, Out, Format, Inv)
    else
        Inv = inv_usage("more than one input path")
    ).

    %@helper
:- type check_args
    --->    check_args(
                ck_in       :: maybe(string),
                ck_format   :: diag_format,
                ck_label    :: maybe(string),
                ck_dump_ast :: bool,
                ck_dialects :: list(string),    % reversed
                ck_search   :: list(string)     % reversed
            ).

    %@helper
:- pred parse_check(list(string)::in, check_args::in, invocation::out) is det.

parse_check([], CK, Inv) :-
    (
        CK ^ ck_in = yes(Input),
        Inv = inv_check(Input, CK ^ ck_format, CK ^ ck_label,
            CK ^ ck_dump_ast, list.reverse(CK ^ ck_dialects),
            l_entries(CK ^ ck_search))
    ;
        CK ^ ck_in = no,
        Inv = inv_usage("`check` needs an input path, or `-`")
    ).
parse_check([A | As], CK, Inv) :-
    ( if A = "--diagnostics" then
        rcli_3_2_parse_diagnostics(A, As, Parsed),
        (
            Parsed = ok({Format, Rest}),
            parse_check(Rest, CK ^ ck_format := Format, Inv)
        ;
            Parsed = error(Why),
            Inv = inv_usage(Why)
        )
    else if A = "--dump-ast" then
        parse_check(As, CK ^ ck_dump_ast := yes, Inv)
    else if ( A = "-o" ; A = "--output" ) then
        Inv = inv_usage("`check` writes no artefact and takes no `" ++ A
            ++ "`; `compile` writes one")
    else if
        ( A = "--filename" ; A = "-d" ; A = "--dialect-file" ; A = "-L"
        ; A = "--search-path" )
    then
        (
            As = [Value | Rest],
            ( if A = "--filename" then
                parse_check(Rest, CK ^ ck_label := yes(Value), Inv)
            else if ( A = "-d" ; A = "--dialect-file" ) then
                parse_check(Rest,
                    CK ^ ck_dialects := [Value | CK ^ ck_dialects], Inv)
            else
                parse_check(Rest,
                    CK ^ ck_search := [Value | CK ^ ck_search], Inv)
            )
        ;
            As = [],
            Inv = inv_usage("`" ++ A ++ "` needs a value")
        )
    else if A \= "-", string.prefix(A, "-") then
        Inv = inv_usage("unknown option `" ++ A ++ "`")
    else if CK ^ ck_in = no then
        parse_check(As, CK ^ ck_in := yes(A), Inv)
    else
        Inv = inv_usage("more than one input path")
    ).

    %@helper
:- func usage = string.

usage =
    "usage: dsc compile <input.ds | -> -o <output.dsc | ->\n" ++
    "                   [--filename <name>] [--dsrt <contract.dsrt>]\n" ++
    "                   [-d <dialect.yaml>]... [-L <dir>]...\n" ++
    "                   [--diagnostics text|json]\n" ++
    "       dsc check <input.ds | -> [--filename <name>] [--dump-ast]\n" ++
    "                 [-d <dialect.yaml>]... [-L <dir>]...\n" ++
    "                 [--diagnostics text|json]\n" ++
    "       dsc compile-project <sketch-dir> [--no-header] " ++
    "[-d <dialect.yaml>]... [-L <dir>]...\n" ++
    "       dsc dump-schemas <input.ds> [-o <output>] [--json] " ++
    "[-d <dialect.yaml>]... [-L <dir>]...\n" ++
    "       dsc dump-ast <input.ds | -> [--filename <name>] " ++
    "[-o <output.json>]\n" ++
    "                    [--diagnostics text|json]\n" ++
    "       dsc --version\n".

%-----------------------------------------------------------------------------%

    % The dialects register before the input is read.
    %
    %@helper
:- pred run_compile(cli_streams::in, diag_format::in, string::in, string::in,
                    maybe(string)::in, maybe(string)::in, list(string)::in,
                    list(search_dir)::in, int::in, int::out, io::di, io::uo)
    is det.

run_compile(S, Format, In, Out, Label, DsrtPath, DialectFiles, Search,
        !Status, !IO) :-
    load_dialects(DialectFiles, builtin_registry, Loaded, !IO),
    (
        Loaded = dialects_error(Why),
        fail_with(S, 2, Why, !Status, !IO)
    ;
        Loaded = dialects_ok(Registry),
        run_compile_in(S, Format, Registry, In, Out, Label, DsrtPath, Search,
            !Status, !IO)
    ).

    %@helper
:- pred run_compile_in(cli_streams::in, diag_format::in, registry::in,
                       string::in, string::in,
                       maybe(string)::in, maybe(string)::in,
                       list(search_dir)::in, int::in, int::out,
                       io::di, io::uo) is det.

run_compile_in(S, Format, Registry, In, Out, Label, DsrtPath, Search,
        !Status, !IO) :-
    read_input(S, In, SourceRes, !IO),
    Name = input_name(In, Label),
    (
        SourceRes = error(Error),
        fail_with(S, 2, "cannot read " ++ Name ++ ": "
            ++ io.error_message(Error), !Status, !IO)
    ;
        SourceRes = ok(Source),
        (
            DsrtPath = yes(_),
            report(S, Format, Name, Out, Source,
                compile_rejected([lcap_2_1_5_dsrt_refused]), !Status, !IO)
        ;
            DsrtPath = no,
            compile_source(Registry, In, Name, Source, Search, Compiled, !IO),
            (
                Compiled = error(Why),
                fail_with(S, 2, Why, !Status, !IO)
            ;
                Compiled = ok(Result),
                report(S, Format, Name, Out, Source, Result, !Status, !IO)
            )
        )
    ).

    % The verdict `compile` and `check` both reach. `error` is a search path or
    % a companion that could not be read: exit 2.
    %
    %@helper
:- pred compile_source(registry::in, string::in, string::in, string::in,
                       list(search_dir)::in, maybe_error(compile_result)::out,
                       io::di, io::uo) is det.

compile_source(Registry, In, Name, Source, Search, Compiled, !IO) :-
    read_libraries(Search, LibRes, !IO),
    read_program_companion(In, CompanionRes, !IO),
    (
        LibRes = error(Why),
        Compiled = error(Why)
    ;
        LibRes = ok(Libraries, LibraryPaths, Ambiguous, LibraryCompanions),
        (
            CompanionRes = error(Why),
            Compiled = error(Why)
        ;
            CompanionRes = ok(ProgramCompanion),
            compile_found(Registry, Name, Source, Libraries, LibraryPaths,
                Ambiguous, companions(ProgramCompanion, LibraryCompanions),
                Compiled)
        )
    ).

    %@helper
:- pred compile_found(registry::in, string::in, string::in,
                      library_sources::in, map(string, string)::in,
                      map(string, list(string))::in, companions::in,
                      maybe_error(compile_result)::out) is det.

compile_found(Registry, Name, Source, Libraries, LibraryPaths, Ambiguous,
        Companions, Compiled) :-
    (
        % [LCAP.2.1.5]: no `.dsrt` is read.
        Dsrt = dsrt_absent,
        % Always `yes`: `no` would trust every import rather than resolve it.
        ( if
            string.suffix(Name, ".dstest"),
            ldia_2_10_6_test_use(Source, UsePos)
        then
            Result = compile_rejected([with_hint(error_at(dv_use_in_test,
                UsePos, "a `.dstest` file must not have a `use` "
                    ++ "directive; it runs under the resolved settings of "
                    ++ "the program it tests ([LDIA.2.10.6])"),
                "remove the `use` line")])
        else
            compile_labelled_in(Registry, as_written, yes(Libraries),
                Dsrt, source_labels(Name, LibraryPaths, Ambiguous,
                    Companions),
                Source, Result)
        ),
        Compiled = ok(Result)
    ).

    %@helper
:- pred read_program_companion(string::in, maybe_error(maybe(string))::out,
                               io::di, io::uo) is det.

read_program_companion(In, Res, !IO) :-
    ( if In = "-" then
        Res = ok(no)
    else
        ltsl_2_4_read_companion(In, Read, !IO),
        (
            Read = ok(Companion),
            Res = ok(Companion)
        ;
            Read = error(Error),
            Res = error("cannot read the companion of " ++ In ++ ": "
                ++ io.error_message(Error))
        )
    ).

    %@helper
:- func input_name(string, maybe(string)) = string.

input_name(In, Label) = Name :-
    ( if Label = yes(L) then
        Name = L
    else if In = "-" then
        Name = "<stdin>"
    else
        Name = In
    ).

    %@spec [LCAP.2.1.5]
:- func lcap_2_1_5_dsrt_refused = diagnostic.

lcap_2_1_5_dsrt_refused =
    with_hint(error_at(dv_realtime_deferred, pos(1, 1),
        "`--dsrt` is refused: the `realtime` contract is not part of this "
            ++ "edition of DS ([LCAP.2.1.5])"),
        "compile without `--dsrt`").

    % Called by nothing, nor is `read_sibling_dsrt`: [LCAP.2.1.5] has the
    % compiler read no `.dsrt`.
    %
    %@helper
:- pred read_contract(string::in, maybe(string)::in,
                      maybe_error(dsrt_input)::out, io::di, io::uo) is det.

read_contract(In, DsrtPath, Res, !IO) :-
    (
        DsrtPath = yes(Path),
        io.read_named_file_as_string(Path, Read, !IO),
        (
            Read = ok(Text),
            Res = ok(dsrt_source(Text))
        ;
            Read = error(Error),
            Res = error("cannot read " ++ Path ++ ": "
                ++ io.error_message(Error))
        )
    ;
        DsrtPath = no,
        ( if In = "-" then
            Res = ok(dsrt_absent)
        else
            read_sibling_dsrt(In, Dsrt, !IO),
            Res = ok(Dsrt)
        )
    ).

%-----------------------------------------------------------------------------%
% check -- `compile` writing no artefact
%-----------------------------------------------------------------------------%

    % With `--dump-ast`, standard output carries one JSON object:
    %
    %   {"tree": <the tree `dump-ast` writes, or null>,
    %    "diagnostics": <what `compile` would write to standard error>}
    %
    % - `tree` is written whenever the input parses, and is `null` only when
    %   the front end stops.
    % - `diagnostics` under `text` is a string, "" when there is none; under
    %   `json` the [RCLI.3.2] document, `null` when there is none.
    %
    % `astjson_refused` writes no object: a `null` would read as "did not parse".
    %
    %@helper
:- pred run_check(cli_streams::in, diag_format::in, string::in,
                  maybe(string)::in, bool::in, list(string)::in,
                  list(search_dir)::in, int::in, int::out, io::di, io::uo)
    is det.

run_check(S, Format, In, Label, DumpAst, DialectFiles, Search, !Status, !IO) :-
    load_dialects(DialectFiles, builtin_registry, Loaded, !IO),
    (
        Loaded = dialects_error(Why),
        fail_with(S, 2, Why, !Status, !IO)
    ;
        Loaded = dialects_ok(Registry),
        read_input(S, In, SourceRes, !IO),
        Name = input_name(In, Label),
        (
            SourceRes = error(Error),
            fail_with(S, 2, "cannot read " ++ Name ++ ": "
                ++ io.error_message(Error), !Status, !IO)
        ;
            SourceRes = ok(Source),
            compile_source(Registry, In, Name, Source, Search, Compiled,
                !IO),
            (
                Compiled = error(Why),
                fail_with(S, 2, Why, !Status, !IO)
            ;
                Compiled = ok(Result),
                (
                    DumpAst = no,
                    write_diagnostics(S, Format, Name, Source,
                        result_diagnostics(Result), !IO),
                    !:Status = result_status(Result)
                ;
                    DumpAst = yes,
                    check_object(S, Format, Name, Source, Result, !Status,
                        !IO)
                )
            )
        )
    ).

    %@helper
:- pred check_object(cli_streams::in, diag_format::in, string::in, string::in,
                     compile_result::in, int::in, int::out,
                     io::di, io::uo) is det.

check_object(S, Format, Name, Source, Result, !Status, !IO) :-
    parse_front(Source, Front),
    (
        Front = front_stopped(_, _, _, _),
        Tree = yes("null")
    ;
        Front = front_ok(Cst, Tokens, Trivia),
        astjson_file(Source, Cst, Tokens, Trivia, Dumped),
        (
            Dumped = astjson_ok(Json),
            Tree = yes(Json)
        ;
            % A bad escape, which the front end meets only inside a literal:
            % the input does not parse, and the compile reports it.
            Dumped = astjson_stopped(_, _),
            Tree = yes("null")
        ;
            Dumped = astjson_refused(pos(Line, Col), Why),
            Tree = no,
            fail_with(S, 1, Name ++ ":" ++ string.from_int(Line) ++ ":"
                ++ string.from_int(Col + 1)
                ++ ": cannot write the tree: " ++ Why, !Status, !IO)
        )
    ),
    (
        Tree = no
    ;
        Tree = yes(TreeJson),
        Diags = result_diagnostics(Result),
        (
            Diags = [],
            (
                Format = df_text,
                DiagJson = json_quote("")
            ;
                Format = df_json,
                DiagJson = "null"
            )
        ;
            Diags = [_ | _],
            Text = diagnostics_text(Format, Name, Source, Diags),
            (
                Format = df_text,
                % As standard error would carry it, its newline included.
                DiagJson = json_quote(Text ++ "\n")
            ;
                Format = df_json,
                DiagJson = Text
            )
        ),
        io.write_string(S ^ cs_out, "{\"tree\":" ++ TreeJson
            ++ ",\"diagnostics\":" ++ DiagJson ++ "}\n", !IO),
        !:Status = result_status(Result)
    ).

%-----------------------------------------------------------------------------%
% dump-ast -- the syntax tree `ds_ast` reads (tools/ds_ast/DESIGN.md)
%-----------------------------------------------------------------------------%

    % Syntax only: nothing is resolved or validated.
    %
    % `astjson_refused` has no registered code, so it stays a `dsc:` line.
    %
    %@spec [RCLI.1.10]
:- pred rcli_1_10_dump_ast(cli_streams::in, diag_format::in, string::in,
                           maybe(string)::in, maybe(string)::in,
                           int::in, int::out, io::di, io::uo) is det.

rcli_1_10_dump_ast(S, Format, In, Label, Out, !Status, !IO) :-
    read_input(S, In, SourceRes, !IO),
    Name = input_name(In, Label),
    (
        SourceRes = error(Error),
        fail_with(S, 2, "cannot read " ++ Name ++ ": "
            ++ io.error_message(Error), !Status, !IO)
    ;
        SourceRes = ok(Source),
        parse_front(Source, Front),
        (
            Front = front_stopped(Code, Message, Pos, End),
            report(S, Format, Name, "", Source,
                compile_stopped(Code, Message, Pos, End), !Status, !IO)
        ;
            Front = front_ok(Cst, Tokens, Trivia),
            astjson_file(Source, Cst, Tokens, Trivia, Dumped),
            (
                Dumped = astjson_refused(pos(Line, Col), Why),
                fail_with(S, 1, Name ++ ":" ++ string.from_int(Line) ++ ":"
                    ++ string.from_int(Col + 1)
                    ++ ": cannot write the tree: " ++ Why, !Status, !IO)
            ;
                % A bad escape, which the front end meets only inside a
                % literal: rendered as `compile` renders it, with its code.
                Dumped = astjson_stopped(StopPos, Why),
                report(S, Format, Name, "", Source,
                    compile_stopped(parse_bad_escape, Why, StopPos, no),
                    !Status, !IO)
            ;
                Dumped = astjson_ok(Json),
                ( if ( Out = no ; Out = yes("-") ) then
                    io.write_string(S ^ cs_out, Json ++ "\n", !IO)
                else if Out = yes(Path) then
                    write_text(S, Path, Json ++ "\n", !Status, !IO)
                else
                    true
                )
            )
        )
    ).

    % A read that stops partway is an error, not a shorter program.
    %
    %@helper
:- pred read_input(cli_streams::in, string::in, io.res(string)::out,
                   io::di, io::uo) is det.

read_input(S, In, Res, !IO) :-
    ( if In = "-" then
        io.read_file_as_string(S ^ cs_in, Partial, !IO),
        (
            Partial = ok(Source),
            Res = ok(Source)
        ;
            Partial = error(_, Error),
            Res = error(Error)
        )
    else
        io.read_named_file_as_string(In, Res, !IO)
    ).

%-----------------------------------------------------------------------------%
% Dialect files -- `-d`, [NDLC.2.1]
%-----------------------------------------------------------------------------%

    %@helper
:- type dialects_result
    --->    dialects_ok(registry)
    ;       dialects_error(string).

    % The first refusal stops the rest.
    %
    %@helper
:- pred load_dialects(list(string)::in, registry::in, dialects_result::out,
                      io::di, io::uo) is det.

load_dialects([], Registry, dialects_ok(Registry), !IO).
load_dialects([Path | Paths], Registry0, Result, !IO) :-
    io.read_named_file_as_string(Path, Res, !IO),
    (
        Res = error(Error),
        Result = dialects_error("cannot read " ++ Path ++ ": "
            ++ io.error_message(Error))
    ;
        Res = ok(Text),
        register_file(Path, Text, Registry0, One),
        (
            One = dialects_ok(Registry),
            load_dialects(Paths, Registry, Result, !IO)
        ;
            One = dialects_error(_),
            Result = One
        )
    ).

    %@helper
:- pred register_file(string::in, string::in, registry::in,
                      dialects_result::out) is det.

register_file(Path, Text, Registry0, Result) :-
    read_mapping(Text, YamlRes),
    (
        YamlRes = yaml_error(Line, Why),
        Result = dialects_error(Path ++ ":" ++ string.from_int(Line) ++ ": "
            ++ Why)
    ;
        YamlRes = yaml_ok(Entries),
        ndlc_2_1_definition(Entries, DefRes),
        (
            DefRes = definition_refused(Why),
            Result = dialects_error(Path ++ ": " ++ Why)
        ;
            DefRes = definition(Def),
            ndlc_2_2_register(Def, Registry0, RegRes),
            (
                RegRes = registered(Registry),
                Result = dialects_ok(Registry)
            ;
                RegRes = registration_refused(Code, Why),
                Result = dialects_error(Path ++ ": " ++ ds_validate_name(Code)
                    ++ ": " ++ Why)
            )
        )
    ).

    % Every `<dir>/**/<name>.ds` under the `-L` directories, keyed by import
    % path: `foo/bar.ds` under `-L lib` is `foo.bar`. All are read, since the
    % driver takes the whole map before it parses.
    %
    % `ok`'s maps, each by name: the text; the path it was read from; every
    % candidate of a name more than one file resolved to, first directory first;
    % the companion `.dstest`, where there is one.
    %
    %@helper
:- type library_result
    --->    ok(library_sources, map(string, string),
                map(string, list(string)), map(string, string))
    ;       error(string).

    %@helper
:- type library_acc == {library_sources, map(string, string),
                        map(string, list(string)), map(string, string)}.

    % One directory listed twice is one entry, not an ambiguity. Directories
    % compare as absolute paths with `.` and `..` resolved as text, so a symlink
    % to one is still a second entry.
    %
    %@helper
:- pred read_libraries(list(search_dir)::in, library_result::out,
                       io::di, io::uo) is det.

read_libraries(Dirs0, Result, !IO) :-
    dir.current_directory(CwdRes, !IO),
    ( if CwdRes = ok(Cwd0) then Cwd = Cwd0 else Cwd = "" ),
    Dirs = distinct_dirs(Cwd, Dirs0, set.init),
    read_libraries_in(Dirs, Result0, !IO),
    (
        Result0 = error(_),
        Result = Result0
    ;
        Result0 = ok(Sources, Paths, Candidates, Companions),
        Ambiguous = map.foldl(
            ( func(Name, Found, Acc) =
                ( if Found = [_, _ | _] then map.det_insert(Acc, Name, Found)
                  else Acc ) ),
            Candidates, map.init),
        Result = ok(Sources, Paths, Ambiguous, Companions)
    ).

    %@helper
:- func distinct_dirs(string, list(search_dir), set(string))
    = list(search_dir).

distinct_dirs(_, [], _) = [].
distinct_dirs(Cwd, [Dir | Dirs], Seen) = Out :-
    Key = normal_dir(Cwd, search_dir_path(Dir)),
    ( if set.member(Key, Seen) then
        Out = distinct_dirs(Cwd, Dirs, Seen)
    else
        Out = [Dir | distinct_dirs(Cwd, Dirs, set.insert(Seen, Key))]
    ).

    % A directory as an absolute path, `.` and `..` resolved as text.
    %
    %@helper
:- func normal_dir(string, string) = string.

normal_dir(Cwd, Dir) = "/" ++ string.join_list("/", list.reverse(Kept)) :-
    Abs = ( if string.prefix(Dir, "/") then Dir else Cwd ++ "/" ++ Dir ),
    list.foldl(
        ( pred(Seg::in, K0::in, K::out) is det :-
            ( if ( Seg = "" ; Seg = "." ) then
                K = K0
            else if Seg = ".." then
                ( K0 = [], K = [] ; K0 = [_ | K] )
            else
                K = [Seg | K0]
            ) ),
        string.split_at_char('/', Abs), [], Kept).

    %@helper
:- func search_dir_path(search_dir) = string.

search_dir_path(sd_entry(Dir)) = Dir.
search_dir_path(sd_bundle(Dir)) = Dir.

    %@helper
:- pred read_libraries_in(list(search_dir)::in, library_result::out,
                          io::di, io::uo) is det.

read_libraries_in([], ok(map.init, map.init, map.init, map.init), !IO).
read_libraries_in([Entry | Entries], Result, !IO) :-
    read_libraries_in(Entries, Rest, !IO),
    Dir = search_dir_path(Entry),
    (
        Rest = error(_),
        Result = Rest
    ;
        Rest = ok(Later, LaterPaths, LaterCandidates, LaterCompanions),
        dir.recursive_foldl2(add_library(Entry), Dir, no,
            {Later, LaterPaths, LaterCandidates, LaterCompanions}, Walked,
            !IO),
        (
            Walked = ok({Sources, Paths, Candidates, Companions}),
            Result = ok(Sources, Paths, Candidates, Companions)
        ;
            Walked = error(_, Error),
            Result = error("cannot read the search path " ++ Dir ++ ": "
                ++ io.error_message(Error))
        )
    ).

    % Directories are walked last first, so prepending leaves each name's
    % candidates in search-path order, and the sources map holds the last
    % directory's text. A name in two directories is refused at an import;
    % `units.core`'s preload is no import, and so reads the bundle's, the last.
    %
    % A library is read from its path and named by its label
    % (`rdsc_14_2_3_label`), in the DsSource atom and in every diagnostic.
    %
    %@helper
:- pred add_library(search_dir::in, string::in, string::in, io.file_type::in,
                    bool::out, library_acc::in, library_acc::out,
                    io::di, io::uo) is det.

add_library(Entry, DirName, BaseName, FileType, yes, !Acc, !IO) :-
    Root = search_dir_path(Entry),
    ( if
        FileType = regular_file,
        limp_2_1_5_library_name(Root, DirName, BaseName, Name)
    then
        Path = DirName ++ "/" ++ BaseName,
        Label = rdsc_14_2_3_label(Entry, DirName, BaseName),
        io.read_named_file_as_string(Path, Res, !IO),
        ( if Res = ok(Text) then
            !.Acc = {Sources0, Paths0, Candidates0, Companions0},
            ( if map.search(Candidates0, Name, Found) then
                map.det_update(Name, [Label | Found], Candidates0, Candidates)
            else
                map.det_insert(Name, [Label], Candidates0, Candidates)
            ),
            ( if map.insert(Name, Text, Sources0, Sources) then
                map.set(Name, Label, Paths0, Paths),
                % An unreadable companion is absent, as an unreadable library is.
                ltsl_2_4_read_companion(Path, CompanionRes, !IO),
                ( if CompanionRes = ok(yes(Companion)) then
                    map.set(Name, Companion, Companions0, Companions)
                else
                    Companions = Companions0
                ),
                !:Acc = {Sources, Paths, Candidates, Companions}
            else
                !:Acc = {Sources0, Paths0, Candidates, Companions0}
            )
        else
            % Unreadable is absent: a program that never imports it compiles.
            true
        )
    else
        true
    ).

    % A path that does not end `.ds` has no companion.
    %
    %@spec [LTSL.2.4]
:- pred ltsl_2_4_read_companion(string::in, io.res(maybe(string))::out,
                                io::di, io::uo) is det.

ltsl_2_4_read_companion(Path, Res, !IO) :-
    ( if string.remove_suffix(Path, ".ds", Stem) then
        Companion = Stem ++ ".dstest",
        io.file_type(yes, Companion, Type, !IO),
        ( if Type = ok(regular_file) then
            io.read_named_file_as_string(Companion, Read, !IO),
            (
                Read = ok(Text),
                Res = ok(yes(Text))
            ;
                Read = error(Error),
                Res = error(Error)
            )
        else
            Res = ok(no)
        )
    else
        Res = ok(no)
    ).

    % `<root>/foo/bar.ds` -> `foo.bar`. Fails unless each directory under the
    % root, and the stem, is a NAME, so a name holding a dot is no library.
    %
    %@spec [LIMP.2.1.5]
    %@spec [LIMP.2.1.6]
:- pred limp_2_1_5_library_name(string::in, string::in, string::in,
                                string::out) is semidet.

limp_2_1_5_library_name(Root, DirName, BaseName, Name) :-
    string.remove_suffix(BaseName, ".ds", Stem),
    ( if DirName = Root then
        Segments = [Stem]
    else if string.remove_prefix(Root ++ "/", DirName, SubDir) then
        Segments = string.split_at_char('/', SubDir) ++ [Stem]
    else
        fail
    ),
    list.all_true(
        ( pred(Segment::in) is semidet :-
            not lnam_2_2_3_check(lnam_2_4_1_nfc(Segment), _) ),
        Segments),
    Name = string.join_list(".", Segments).

    % A library's DsSource `file`: from a `-L` entry, its path as the entry
    % spells it; from the bundle, `<stdlib>/` and its path in the bundle, so it
    % has one name wherever the compiler is installed.
    %
    %@spec [RDSC.14.2.3]
:- func rdsc_14_2_3_label(search_dir, string, string) = string.

rdsc_14_2_3_label(sd_entry(_), DirName, BaseName) = DirName ++ "/" ++ BaseName.
rdsc_14_2_3_label(sd_bundle(Root), DirName, BaseName) = "<stdlib>/" ++ Rel :-
    ( if DirName = Root then
        Rel = BaseName
    else if string.remove_prefix(Root ++ "/", DirName, SubDir) then
        Rel = SubDir ++ "/" ++ BaseName
    else
        % `limp_2_1_5_library_name` names no library outside the root.
        Rel = BaseName
    ).

    %@helper
:- pred read_sibling_dsrt(string::in, dsrt_input::out, io::di, io::uo) is det.

read_sibling_dsrt(In, Dsrt, !IO) :-
    ( if string.remove_suffix(In, ".ds", Stem) then
        Path = Stem ++ ".dsrt"
    else
        Path = In ++ ".dsrt"
    ),
    io.read_named_file_as_string(Path, Res, !IO),
    (
        Res = ok(Text),
        Dsrt = dsrt_source(Text)
    ;
        Res = error(_),
        Dsrt = dsrt_absent
    ).

    %@helper
:- pred report(cli_streams::in, diag_format::in, string::in, string::in,
               string::in, compile_result::in, int::in, int::out,
               io::di, io::uo) is det.

report(S, Format, In, Out, Source, Result, !Status, !IO) :-
    write_diagnostics(S, Format, In, Source, result_diagnostics(Result), !IO),
    (
        Result = compiled(Bytes, _, _),
        write_artefact(S, Out, Bytes, !Status, !IO)
    ;
        ( Result = compile_rejected(_)
        ; Result = compile_stopped(_, _, _, _)
        ),
        !:Status = 1
    ).

    %@helper
:- func result_diagnostics(compile_result) = list(diagnostic).

result_diagnostics(compiled(_, Warnings, _)) = Warnings.
result_diagnostics(compile_rejected(Diags)) = Diags.
result_diagnostics(compile_stopped(Code, Message, Pos, End)) = [Stopped] :-
    Stopped0 = front_error_at(Code, Pos, Message),
    (
        End = yes(EndPos),
        Stopped = with_end(Stopped0, EndPos)
    ;
        End = no,
        Stopped = Stopped0
    ).

    %@helper
:- func result_status(compile_result) = int.

result_status(compiled(_, _, _)) = 0.
result_status(compile_rejected(_)) = 1.
result_status(compile_stopped(_, _, _, _)) = 1.

    % None writes nothing, under either format.
    %
    %@helper
:- pred write_diagnostics(cli_streams::in, diag_format::in, string::in,
                          string::in, list(diagnostic)::in,
                          io::di, io::uo) is det.

write_diagnostics(S, Format, In, Source, Diags, !IO) :-
    (
        Diags = []
    ;
        Diags = [_ | _],
        io.write_string(S ^ cs_err,
            diagnostics_text(Format, In, Source, Diags) ++ "\n", !IO)
    ).

    % Without the newline that ends them on standard error.
    %
    %@helper
:- func diagnostics_text(diag_format, string, string, list(diagnostic))
    = string.

diagnostics_text(df_text, In, Source, Diags) =
    rcli_5_3_render_all(In, Source, Diags).
diagnostics_text(df_json, In, _, Diags) = rcli_3_2_document(In, Diags).

    %@helper
:- pred report_warnings(cli_streams::in, diag_format::in, string::in,
                        string::in, list(diagnostic)::in,
                        io::di, io::uo) is det.

report_warnings(S, Format, In, Source, Warnings, !IO) :-
    write_diagnostics(S, Format, In, Source, Warnings, !IO).

    %@helper
:- pred write_artefact(cli_streams::in, string::in, list(uint8)::in,
                       int::in, int::out, io::di, io::uo) is det.

write_artefact(S, Out, Bytes, !Status, !IO) :-
    ( if Out = "-" then
        list.foldl(io.write_binary_uint8(S ^ cs_bin), Bytes, !IO),
        io.flush_binary_output(S ^ cs_bin, !IO)
    else
        write_artefact_file(S, Out, Bytes, !Status, !IO)
    ).

    %@helper
:- pred write_artefact_file(cli_streams::in, string::in, list(uint8)::in,
                            int::in, int::out, io::di, io::uo) is det.

write_artefact_file(S, Out, Bytes, !Status, !IO) :-
    % [RCLI.3.1]: from here to the close, a compiler that stops removes it.
    rcli_3_1_writing(Out, !IO),
    io.open_binary_output(Out, OpenRes, !IO),
    (
        OpenRes = error(Error),
        rcli_3_1_written(!IO),
        fail_with(S, 2, "cannot write " ++ Out ++ ": "
            ++ io.error_message(Error), !Status, !IO)
    ;
        OpenRes = ok(Stream),
        list.foldl(io.write_binary_uint8(Stream), Bytes, !IO),
        io.close_binary_output(Stream, !IO),
        rcli_3_1_written(!IO)
    ).

    %@helper
:- pred fail_with(cli_streams::in, int::in, string::in, int::in, int::out,
                  io::di, io::uo) is det.

fail_with(S, Code, Message, _, Code, !IO) :-
    io.format(S ^ cs_err, "dsc: %s\n", [s(Message)], !IO).

%-----------------------------------------------------------------------------%
% compile-project -- [NGST.4.3], [RCLI.1.4]
%-----------------------------------------------------------------------------%

    % Every `.ds` under `<Dir>/rules/`, beside each a `.dsc` and a `_dsc.h`. One
    % file failing does not stop the others: the run exits 1 at the end.
    %
    %@helper
:- pred run_project(cli_streams::in, string::in, bool::in, list(string)::in,
                    list(search_dir)::in, int::in, int::out,
                    io::di, io::uo) is det.

run_project(S, Dir, NoHeader, DialectFiles, Search, !Status, !IO) :-
    RulesDir = Dir ++ "/rules",
    io.file_type(yes, Dir, DirType, !IO),
    io.file_type(yes, RulesDir, RulesType, !IO),
    ( if DirType = ok(directory) then
        ( if RulesType = ok(directory) then
            load_dialects(DialectFiles, builtin_registry, Loaded, !IO),
            (
                Loaded = dialects_error(Why),
                fail_with(S, 2, Why, !Status, !IO)
            ;
                Loaded = dialects_ok(Env),
                read_libraries(Search, LibRes, !IO),
                (
                    LibRes = error(Why),
                    fail_with(S, 2, Why, !Status, !IO)
                ;
                    LibRes = ok(Libraries, LibraryPaths, Ambiguous,
                        LibraryCompanions),
                    project_files(S, Env, RulesDir, NoHeader, Libraries,
                        LibraryPaths, Ambiguous, LibraryCompanions, !Status,
                        !IO)
                )
            )
        else
            fail_with(S, 2, "no rules/ directory under " ++ Dir, !Status, !IO)
        )
    else
        fail_with(S, 2, "sketch directory not found: " ++ Dir, !Status, !IO)
    ).

    % Sorted by path, so the order does not depend on the filesystem's.
    %
    %@helper
:- pred project_files(cli_streams::in, registry::in, string::in, bool::in,
                      library_sources::in, map(string, string)::in,
                      map(string, list(string))::in, map(string, string)::in,
                      int::in, int::out, io::di, io::uo) is det.

project_files(S, Env, RulesDir, NoHeader, Libraries, LibraryPaths, Ambiguous,
        LibraryCompanions, !Status, !IO) :-
    dir.recursive_foldl2(collect_ds, RulesDir, no, [], Walked, !IO),
    (
        Walked = error(_, Error),
        fail_with(S, 2, "cannot read " ++ RulesDir ++ ": "
            ++ io.error_message(Error), !Status, !IO)
    ;
        Walked = ok(Found),
        list.sort(Found, Paths),
        (
            Paths = [],
            fail_with(S, 2, "no .ds files found under " ++ RulesDir,
                !Status, !IO)
        ;
            Paths = [_ | _],
            list.foldl3(
                project_file(S, Env, RulesDir, NoHeader, Libraries,
                    LibraryPaths, Ambiguous, LibraryCompanions),
                Paths, 0, Failed, !Status, !IO),
            ( if Failed > 0 then
                fail_with(S, 1, "compile-project: " ++ string.from_int(Failed)
                    ++ " file(s) failed", !Status, !IO)
            else
                true
            )
        )
    ).

    %@helper
:- pred collect_ds(string::in, string::in, io.file_type::in, bool::out,
                   list(string)::in, list(string)::out, io::di, io::uo)
    is det.

collect_ds(DirName, BaseName, FileType, yes, !Paths, !IO) :-
    ( if FileType = regular_file, string.suffix(BaseName, ".ds") then
        !:Paths = [DirName ++ "/" ++ BaseName | !.Paths]
    else
        true
    ).

    %@helper
:- pred project_file(cli_streams::in, registry::in, string::in, bool::in,
                     library_sources::in, map(string, string)::in,
                     map(string, list(string))::in, map(string, string)::in,
                     string::in, int::in, int::out, int::in, int::out,
                     io::di, io::uo) is det.

project_file(S, Env, RulesDir, NoHeader, Libraries, LibraryPaths, Ambiguous,
        LibraryCompanions, Path, !Failed, !Status, !IO) :-
    io.read_named_file_as_string(Path, SourceRes, !IO),
    (
        SourceRes = error(Error),
        io.format(S ^ cs_err, "dsc: cannot read %s: %s\n",
            [s(Path), s(io.error_message(Error))], !IO),
        !:Failed = !.Failed + 1
    ;
        SourceRes = ok(Source),
        read_program_companion(Path, CompanionRes, !IO),
        (
            CompanionRes = error(Why),
            io.format(S ^ cs_err, "dsc: %s\n", [s(Why)], !IO),
            !:Failed = !.Failed + 1
        ;
            CompanionRes = ok(Companion),
            project_compile(S, Env, RulesDir, NoHeader, Libraries,
                source_labels(Path, LibraryPaths, Ambiguous,
                    companions(Companion, LibraryCompanions)),
                Source, !Failed, !Status, !IO)
        )
    ).

    %@helper
:- pred project_compile(cli_streams::in, registry::in, string::in, bool::in,
                        library_sources::in, source_labels::in, string::in,
                        int::in, int::out, int::in, int::out,
                        io::di, io::uo) is det.

project_compile(S, Env, RulesDir, NoHeader, Libraries, Labels, Source,
        !Failed, !Status, !IO) :-
    Path = Labels ^ sl_file,
    ( if string.remove_prefix(RulesDir ++ "/", Path, Rel0) then
        Rel = Rel0
    else
        Rel = Path
    ),
    (
        % [LCAP.2.1.5]: no `.dsrt` is read.
        Dsrt = dsrt_absent,
        compile_labelled_in(Env, as_written, yes(Libraries), Dsrt, Labels,
            Source, Result),
        (
            Result = compiled(Bytes, Warnings, _),
            report_warnings(S, df_text, Path, Source, Warnings, !IO),
            Stem = source_stem(Path),
            DscPath = Stem ++ ".dsc",
            write_artefact(S, DscPath, Bytes, !Status, !IO),
            io.format(S ^ cs_out, "  %s → %s (%d bytes)\n",
                [s(Rel), s(base_name(DscPath)), i(list.length(Bytes))], !IO),
            (
                NoHeader = yes
            ;
                NoHeader = no,
                Symbol = embed_symbol(base_name(Stem)),
                HeaderPath = Stem ++ "_dsc.h",
                write_embed_header(S, HeaderPath, Bytes, Symbol, !Status, !IO),
                io.format(S ^ cs_out, "  %s → %s (%s_DSC, %s_DSC_LEN)\n",
                    [s(Rel), s(base_name(HeaderPath)), s(Symbol), s(Symbol)],
                    !IO)
            )
        ;
            Result = compile_rejected(_),
            report(S, df_text, Path, "", Source, Result, !Status, !IO),
            !:Failed = !.Failed + 1
        ;
            Result = compile_stopped(_, _, _, _),
            report(S, df_text, Path, "", Source, Result, !Status, !IO),
            !:Failed = !.Failed + 1
        )
    ).

    %@helper
:- func source_stem(string) = string.

source_stem(Path) =
    ( if string.remove_suffix(Path, ".ds", Stem) then Stem else Path ).

    %@helper
:- func base_name(string) = string.

base_name(Path) =
    ( if dir.basename(Path, Base) then Base else Path ).

    % The C identifier stem: upper-cased, every character outside `[A-Z0-9]`
    % replaced by `_`.
    %
    %@helper
:- func embed_symbol(string) = string.

embed_symbol(Stem) =
    string.from_char_list(list.map(
        ( func(C) = ( if ( char.is_upper(C) ; char.is_digit(C) ) then C
                      else '_' ) ),
        string.to_char_list(string.to_upper(Stem)))).

    %@helper
:- pred write_embed_header(cli_streams::in, string::in, list(uint8)::in,
                           string::in, int::in, int::out,
                           io::di, io::uo) is det.

write_embed_header(S, Path, Bytes, Symbol, !Status, !IO) :-
    Hex = string.join_list(", ",
        list.map((func(B) = string.format("0x%02x", [i(uint8.to_int(B))])),
            Bytes)),
    Text = "/* Generated by dsc compile-project — do not edit */\n"
        ++ "static const uint8_t " ++ Symbol ++ "_DSC[] = { " ++ Hex
        ++ " };\n"
        ++ "static const size_t  " ++ Symbol ++ "_DSC_LEN = "
        ++ string.from_int(list.length(Bytes)) ++ "u;\n",
    write_text(S, Path, Text, !Status, !IO).

    %@helper
:- pred write_text(cli_streams::in, string::in, string::in, int::in, int::out,
                   io::di, io::uo) is det.

write_text(S, Path, Text, !Status, !IO) :-
    % [RCLI.3.1], as `write_artefact_file`.
    rcli_3_1_writing(Path, !IO),
    io.open_output(Path, OpenRes, !IO),
    (
        OpenRes = ok(Stream),
        io.write_string(Stream, Text, !IO),
        io.close_output(Stream, !IO),
        rcli_3_1_written(!IO)
    ;
        OpenRes = error(Error),
        rcli_3_1_written(!IO),
        fail_with(S, 2, "cannot write " ++ Path ++ ": "
            ++ io.error_message(Error), !Status, !IO)
    ).

%-----------------------------------------------------------------------------%
% dump-schemas -- [RCLI.1.5]
%-----------------------------------------------------------------------------%

    % A library is dumped, not refused: a file with no `use` line compiles as
    % though it began `use default`, since this writes no artefact. `--json`
    % writes [RCLI.1.14]'s document in place of the proto3 file, for the same
    % compile, so a source the proto3 form refuses writes neither.
    %
    %@helper
:- pred run_dump(cli_streams::in, string::in, maybe(string)::in,
                 list(string)::in, list(search_dir)::in, bool::in,
                 int::in, int::out, io::di, io::uo) is det.

run_dump(S, In, Out, DialectFiles, Search, Json, !Status, !IO) :-
    load_dialects(DialectFiles, builtin_registry, Loaded, !IO),
    (
        Loaded = dialects_error(Why),
        fail_with(S, 2, Why, !Status, !IO)
    ;
        Loaded = dialects_ok(Registry),
        run_dump_in(S, Registry, In, Out, Search, Json, !Status, !IO)
    ).

    %@helper
:- pred run_dump_in(cli_streams::in, registry::in, string::in,
                    maybe(string)::in, list(search_dir)::in, bool::in,
                    int::in, int::out, io::di, io::uo) is det.

run_dump_in(S, Env, In, Out, Search, Json, !Status, !IO) :-
    io.read_named_file_as_string(In, SourceRes, !IO),
    (
        SourceRes = error(Error),
        fail_with(S, 2, "cannot read " ++ In ++ ": "
            ++ io.error_message(Error), !Status, !IO)
    ;
        SourceRes = ok(Source),
        % [LCAP.2.1.5]: no `.dsrt` is read.
        Dsrt = dsrt_absent,
        read_libraries(Search, LibRes, !IO),
        (
            LibRes = error(Why),
            fail_with(S, 2, Why, !Status, !IO)
        ;
            % No companion is read: a test changes nothing this writes.
            LibRes = ok(Libraries, _, Ambiguous, _),
            compile_labelled_in(Env, as_though("default"), yes(Libraries),
                Dsrt, in_memory_labels ^ sl_ambiguous := Ambiguous, Source,
                Result),
            (
                Result = compiled(_, Warnings, Messages),
                report_warnings(S, df_text, In, Source, Warnings, !IO),
                (
                    Json = yes,
                    Text = rcli_1_14_schemas_json(yes(Libraries), Ambiguous,
                        Source)
                ;
                    Json = no,
                    Text = rcli_1_5_combined_proto(Source, Messages)
                ),
                ( if ( Out = no ; Out = yes("-") ) then
                    io.write_string(S ^ cs_out, Text, !IO)
                else if Out = yes(Path) then
                    write_text(S, Path, Text, !Status, !IO)
                else
                    true
                )
            ;
                Result = compile_rejected(_),
                report(S, df_text, In, "", Source, Result, !Status, !IO)
            ;
                Result = compile_stopped(_, _, _, _),
                report(S, df_text, In, "", Source, Result, !Status, !IO)
            )
        )
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.cli.
%-----------------------------------------------------------------------------%

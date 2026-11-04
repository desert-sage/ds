% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc_cli -- the compiler's command-line program.
%
% What `dsc.cli` cannot check in-process: the streams, the exit status, and where
% the binary sits.
%-----------------------------------------------------------------------------%

:- module dsc_cli.
:- interface.

:- import_module io.

    %@helper
:- pred main(io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.
:- import_module dsc.cli.

main(!IO) :-
    io.command_line_arguments(Args, !IO),
    io.progname("dsc", Prog, !IO),
    % Where the binary sits, which is where its library is ([RCLI.1.11]).
    dsc.cli.limp_3_3_1_bundled_library(Prog, Bundle, !IO),
    io.stdin_stream(In, !IO),
    io.output_stream(Out, !IO),
    io.binary_output_stream(Bin, !IO),
    io.stderr_stream(Err, !IO),
    dsc.cli.rcli_3_1_run(Args, Bundle, cli_streams(In, Out, Bin, Err), Status,
        !IO),
    io.set_exit_status(Status, !IO).

%-----------------------------------------------------------------------------%

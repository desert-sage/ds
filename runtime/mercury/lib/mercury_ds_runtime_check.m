%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% Mercury implementation of the DS runtime.
%
% mercury_ds_runtime_check.m -- a program outside the runtime's tree that links
% the installed `mercury_ds_runtime`.
%
% `scripts/private/gate/gate.py mercury-lib` copies it into a directory of its own, links it
% with `--mld <prefix>/lib/mercury --ml mercury_ds_runtime` and nothing else
% from the tree, statically and shared, and runs both. Each answer below comes
% through one of the sanctioned foreign modules (docs/PROMISE_LEDGER.md), whose C the
% library carries inside it, so a library that links and still computes the
% wrong thing fails as well: a wrong answer exits 1.
%-----------------------------------------------------------------------------%

:- module mercury_ds_runtime_check.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module bool.
:- import_module ds.
:- import_module ds.core_math.
:- import_module ds.float_text.
:- import_module ds.re2.
:- import_module ds.version.
:- import_module list.
:- import_module mercury_ds_runtime.
:- import_module string.

main(!IO) :-
    Version = mercury_ds_runtime.ds_version,
    Exp = ds.float_text.canonical(ds.core_math.exp(1.0)),
    ( if ds.float_text.parse_text("0.1", F) then
        Parsed = ds.float_text.canonical(F)
    else
        Parsed = "(refused)"
    ),
    Flags = ds.re2.re2_flags_of_letters(""),
    Matches = ( if ds.re2.re2_matches("^a+b$", Flags, "aaab") then yes else no ),
    Refuses = ( if ds.re2.re2_matches("^a+b$", Flags, "abc") then no else yes ),
    io.format("version %s\n", [s(Version)], !IO),
    io.format("exp(1.0) %s\n", [s(Exp)], !IO),
    io.format("parse 0.1 %s\n", [s(Parsed)], !IO),
    io.format("re2 ^a+b$ matches aaab %s, refuses abc %s\n",
        [s(string(Matches)), s(string(Refuses))], !IO),
    ( if
        Version = ds.version.ds_version,
        Version \= "",
        Exp = "2.718281828459045",
        Parsed = "0.1",
        Matches = yes,
        Refuses = yes
    then
        io.write_string("mercury_ds_runtime: ok\n", !IO)
    else
        io.write_string("mercury_ds_runtime: WRONG ANSWER\n", !IO),
        io.set_exit_status(1, !IO)
    ).

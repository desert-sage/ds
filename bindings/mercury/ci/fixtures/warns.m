%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: warns.m.
%
% The negative fixture for the gate's halt at a warning (check.py): a
% module that compiles with one warning, a variable that occurs only once.
% Built under the option line every mercury_ds module carries, it must fail;
% built without it, it must build.
%
%---------------------------------------------------------------------------%

:- module warns.
:- interface.

:- pred ignore(int::in) is det.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

ignore(Unused) :-
    true.

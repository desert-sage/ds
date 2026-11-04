% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.intern -- the string intern table. The empty string is interned first, so
% it is always present.
%-----------------------------------------------------------------------------%

:- module ds.intern.
:- interface.

:- import_module ds.id.

%-----------------------------------------------------------------------------%

:- type intern_table.

:- func init_interns = intern_table.

:- func empty_ref(intern_table) = intern_ref.

:- pred intern(string::in, intern_ref::out,
               intern_table::in, intern_table::out) is det.

    % Fails on a ref from another table.
    %
:- pred expand(intern_table::in, intern_ref::in, string::out) is semidet.

    % Whether a string is already interned, without interning it.
    %
:- pred interned(intern_table::in, string::in, intern_ref::out) is semidet.

    % Bytes are UTF-8 code units.
    %
:- func intern_count(intern_table) = int.
:- func intern_bytes(intern_table) = int.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module map.
:- import_module string.
:- import_module uint32.

%-----------------------------------------------------------------------------%

:- type intern_table
    --->    intern_table(
                it_fwd   :: map(string, intern_ref),
                it_rev   :: map(uint32, string),
                it_next  :: uint32,
                it_bytes :: int,
                it_empty :: intern_ref
            ).

init_interns = T :-
    T0 = intern_table(map.init, map.init, 0u32, 0, make_intern_ref(0u32)),
    intern("", Empty, T0, T1),
    T = T1 ^ it_empty := Empty.

empty_ref(T) = T ^ it_empty.

intern(S, Ref, !T) :-
    ( if map.search(!.T ^ it_fwd, S, Existing) then
        Ref = Existing
    else
        N = !.T ^ it_next,
        Ref = make_intern_ref(N),
        !T ^ it_fwd := map.det_insert(!.T ^ it_fwd, S, Ref),
        !T ^ it_rev := map.det_insert(!.T ^ it_rev, N, S),
        !T ^ it_next := N + 1u32,
        !T ^ it_bytes := !.T ^ it_bytes + string.count_utf8_code_units(S)
    ).

expand(T, Ref, S) :-
    map.search(T ^ it_rev, intern_ref_value(Ref), S).

interned(T, S, Ref) :-
    map.search(T ^ it_fwd, S, Ref).

intern_count(T) = map.count(T ^ it_fwd).

intern_bytes(T) = T ^ it_bytes.

%-----------------------------------------------------------------------------%

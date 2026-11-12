%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.atoms.m.
%
% The atoms of an artefact or a recording, read in file order without a
% session: each atom's identity and where its body lies in the bytes.
%
% An atom is named by the runtime's own `atom_id`, the closed union
% generated from `proto/atom.proto`, so a host switches on it rather than
% comparing names. A recording's events, typed by their schemas, are what
% the runtime's `ds.rfcs.decode_stream` reads; this module reads only the
% framing.
%
%---------------------------------------------------------------------------%

:- module mercury_ds.atoms.
:- interface.

:- import_module mercury_ds.error.
:- import_module ds.
:- import_module ds.atom.
:- import_module bitmap.
:- import_module list.

%---------------------------------------------------------------------------%

    % One atom.
    %
:- type atom
    --->    atom(
                atom_ref         :: atom_ref,
                            % `known(Id)`, or `unknown(Field)` for a field
                            % number this runtime has no atom for, which names
                            % no member of `Atom`'s oneof ([RFCS.19.3]); a
                            % listing lists it.
                atom_offset      :: int,
                            % Where its frame begins, in bytes.
                atom_body_offset :: int,
                atom_body_length :: int
                            % Where its body lies, in bytes.
            ).

    % The atoms read, and `ok`, or why the walk stopped where it did.
    %
:- type atom_listing
    --->    atom_listing(
                atom_listing_atoms   :: list(atom),
                atom_listing_outcome :: outcome
            ).

    % The atoms of a `.dsc` or a recording, in order ([RFCS.19]). The walk
    % stops at the first frame that is not well formed, with `parse` and
    % the offset in the detail: a frame cut short ([RFCS.19.2]), an outer
    % tag that is not this format's, or an atom with no member
    % ([RFCS.19.3]).
    %
:- func atoms(bitmap) = atom_listing.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

:- import_module mercury_ds.status.
:- import_module ds.wire.
:- import_module string.

%---------------------------------------------------------------------------%

atoms(Bytes) = atom_listing(list.reverse(Reversed), Outcome) :-
    walk(init_reader(Bytes), [], Reversed, Outcome).

:- pred walk(reader::in, list(atom)::in, list(atom)::out, outcome::out)
    is det.

walk(Reader0, !Atoms, Outcome) :-
    next_frame(Result, Reader0, Reader),
    (
        Result = fr_eof,
        Outcome = ok
    ;
        Result = fr_error(_, Offset),
        Outcome = error(status_error(parse,
            "the frame at byte " ++ string.int_to_string(Offset) ++
            " is not well formed"))
    ;
        Result = fr_ok(frame(Ref, Body, Offset)),
        !:Atoms = [atom(Ref, Offset, position(Body), remaining(Body))
            | !.Atoms],
        walk(Reader, !Atoms, Outcome)
    ).

%---------------------------------------------------------------------------%

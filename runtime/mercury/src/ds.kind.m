%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% ds.kind -- GENERATED. Do not edit: change the definition and
% regenerate ([STYL.5.9.6]).
%
% proto/fact_external.proto#Kind: one number space for a slot value and a
% call argument (RFCS.23.2, NFCT.2.7). A slot value admits the common kinds
% and `kind_fact_ref`; a call argument admits the common kinds and
% `kind_encoded_fact`. libds's `ds_kind_t` / `ds_slot_kind_t` /
% `ds_arg_kind_t` are generated from the same proto by the same script.
%-----------------------------------------------------------------------------%

:- module ds.kind.
:- interface.

:- import_module uint32.

    %@helper
:- type kind
    --->    kind_int
    ;       kind_float
    ;       kind_string
    ;       kind_bool
    ;       kind_json
    ;       kind_fact_ref
    ;       kind_bytes
    ;       kind_null
    ;       kind_encoded_fact.

    % The kind's number on the wire.
    %
    %@helper
:- func kind_number(kind) = uint32.

    % The kind a wire number names; fails on a number `Kind` does not have.
    %
    %@helper
:- pred kind_from_number(uint32::in, kind::out) is semidet.

    % A kind a slot value may have: the common kinds and the fact reference.
    %
    %@helper
:- pred slot_kind(kind::in) is semidet.

    % A kind a call argument may have: the common kinds and the encoded fact.
    %
    %@helper
:- pred arg_kind(kind::in) is semidet.

%-----------------------------------------------------------------------------%

:- implementation.

kind_number(kind_int) = 0u32.
kind_number(kind_float) = 1u32.
kind_number(kind_string) = 2u32.
kind_number(kind_bool) = 3u32.
kind_number(kind_json) = 4u32.
kind_number(kind_fact_ref) = 5u32.
kind_number(kind_bytes) = 6u32.
kind_number(kind_null) = 7u32.
kind_number(kind_encoded_fact) = 8u32.

kind_from_number(0u32, kind_int).
kind_from_number(1u32, kind_float).
kind_from_number(2u32, kind_string).
kind_from_number(3u32, kind_bool).
kind_from_number(4u32, kind_json).
kind_from_number(5u32, kind_fact_ref).
kind_from_number(6u32, kind_bytes).
kind_from_number(7u32, kind_null).
kind_from_number(8u32, kind_encoded_fact).

slot_kind(kind_int).
slot_kind(kind_float).
slot_kind(kind_string).
slot_kind(kind_bool).
slot_kind(kind_json).
slot_kind(kind_fact_ref).
slot_kind(kind_bytes).
slot_kind(kind_null).

arg_kind(kind_int).
arg_kind(kind_float).
arg_kind(kind_string).
arg_kind(kind_bool).
arg_kind(kind_json).
arg_kind(kind_bytes).
arg_kind(kind_null).
arg_kind(kind_encoded_fact).

%-----------------------------------------------------------------------------%
:- end_module ds.kind.
%-----------------------------------------------------------------------------%

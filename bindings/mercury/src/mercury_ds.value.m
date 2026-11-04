%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.value.m.
%
% What a host asserts, and what it reads back.
%
% The values are the runtime's own type, `ds.value.ds_value` (MER.4). A slot
% holds eight of its twelve constructors, and `storable` is the subtype with
% exactly those eight, so a host cannot hand an assert a duration, a ratio or
% an engine-relative string: the call would not type-check.
%
% Every value read back is a `storable` too: a fact's slots, an assert
% event's values. A string is `text`: the runtime's
% `str` names a string in one engine's intern table, which a host never
% sees, so it is expanded to `text` as it is read.
%
% A `Json` value is the runtime's term, which a host builds as a Mercury
% value, or reads from its text and writes as text as libds does.
%
%---------------------------------------------------------------------------%

:- module mercury_ds.value.
:- interface.

:- import_module mercury_ds.error.
:- import_module ds.
:- import_module ds.chrono.
:- import_module ds.id.
:- import_module ds.value.
:- import_module bitmap.
:- import_module bool.
:- import_module list.
:- import_module maybe.

%---------------------------------------------------------------------------%

    % A value a slot can hold.
    %
:- type storable =< ds_value
    --->    int(int64)
            % An `Int`, or a `Time`, `Date` or `Duration` as its integer.
    ;       float(float)
    ;       text(string)
    ;       bool(bool)
    ;       bytes(bitmap)
    ;       json(json_term)
    ;       fact_ref(fact_id)
    ;       null.
            % No value, for a nullable slot.

    % The runtime's value a `storable` is.
    %
:- func to_value(storable) = ds_value.

    % A `Json` value from its text, read as libds's `ds_json_parse` reads
    % it: its grammar, and the limits it enforces on depth, values, string
    % bytes and text bytes. Refused, in this order, with `json_limit` for a
    % text past the text limit; with `encoding` for a text that is not
    % well-formed UTF-8, whatever else is wrong with it ([LSTR.8.5]); with
    % `json_limit` for a text past one of the other limits; and with `parse`
    % for any other text that is not one JSON document: one that repeats a
    % key, holds an integer outside `int64`, a float that rounds to an
    % infinity (LGRA.5.8.10), a `\u0000` escape or half a surrogate pair's
    % escape, or has anything but whitespace after it.
    %
:- func json_from_text(string) = maybe_error(json_term, ds_error).

    % A `Json` value's text, byte for byte what libds's `ds_json_serialize`
    % writes: no whitespace, object keys in byte order. Refused with
    % `json_nonfinite` for a value holding an infinite or NaN float, which
    % JSON cannot spell.
    %
:- func json_to_text(json_term) = maybe_error(string, ds_error).

    % A fact as a host reads it: a snapshot taken at the read, never a
    % reference into the engine.
    %
:- type fact_view
    --->    fact_view(
                fact_view_id       :: fact_id,
                fact_view_schema   :: string,
                            % The schema's name.
                fact_view_slots    :: list(storable),
                            % The slot values in declaration order.
                fact_view_asserted :: instant,
                            % When the fact entered working memory.
                fact_view_deadline :: maybe(instant)
                            % When it expires, or `no` for never.
            ).

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

:- import_module mercury_ds.status.
:- import_module int.

    % Qualified: its `parse` is not `mercury_ds.status`'s, and only one name
    % is wanted from each.
    %
:- use_module ds.format.
:- use_module ds.json.
:- use_module ds.json_text.
:- use_module string.

%---------------------------------------------------------------------------%

to_value(S) = coerce(S).

json_to_text(Json) = Result :-
    ( if ds.format.json_text(Json, Text) then
        Result = ok(Text)
    else
        Result = error(status_error(json_nonfinite,
            "a float that is infinite or NaN, which JSON cannot spell"))
    ).

json_from_text(Text) = Result :-
    ( if
        % [LSTR.8.5]: a host's JSON text that is not well-formed
        % UTF-8 is refused before it is parsed, as libds's `ds_json_parse`
        % refuses it: after the text limit, which refuses text unread, and
        % before the parse, so text both ill-formed and malformed is
        % `encoding`. `ds.json_text.parse` does not ask
        % (its header): the runtime's own reads of trusted text go through it
        % unchecked, as libds's `ds_json_parse_limited` does.
        string.count_utf8_code_units(Text) =< ds.json.max_text_bytes,
        not ds.json.utf8_well_formed(Text)
    then
        Result = error(status_error(encoding,
            "JSON text that is not well-formed UTF-8"))
    else
        ds.json_text.parse(Text, Parsed),
        (
            Parsed = ds.json_text.parsed(Json),
            Result = ok(Json)
        ;
            Parsed = ds.json_text.refused(Why),
            Result = error(json_refusal(Why))
        )
    ).

    % libds answers a limit passed with DS_ERR_JSON_LIMIT, and every other
    % refusal of its parser with DS_ERR_PARSE.
    %
:- func json_refusal(ds.json_text.json_refusal) = ds_error.

json_refusal(ds.json_text.jr_syntax) =
    status_error(parse, "not one JSON document").
json_refusal(ds.json_text.jr_int_outside_int64) =
    status_error(parse, "an integer outside int64").
json_refusal(ds.json_text.jr_float_outside_double) =
    status_error(parse, "a float that rounds to an infinity").
json_refusal(ds.json_text.jr_nul_escape) =
    status_error(parse, "a \\u0000 escape, which no string holds").
json_refusal(ds.json_text.jr_unpaired_surrogate) =
    status_error(parse, "a surrogate escape that is half of no pair").
json_refusal(ds.json_text.jr_repeated_key) =
    status_error(parse, "an object that names one key twice").
json_refusal(ds.json_text.jr_limit(_)) =
    status_error(json_limit, "past a limit on a Json value").

%---------------------------------------------------------------------------%

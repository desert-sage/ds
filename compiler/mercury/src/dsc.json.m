% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.json -- JSON text to the runtime's `json` term.
%
% RFC 8259. Offsets are in codepoints. A repeated key is refused ([LGRA.5.8.7]) by
% `parse_json`; the corpus readers keep the last. A lone surrogate is refused
% ([LSTR.7.2.3]).
%-----------------------------------------------------------------------------%

:- module dsc.json.
:- interface.

:- import_module ds.
:- import_module ds.json.

:- import_module list.
:- import_module string.

%-----------------------------------------------------------------------------%

    %@helper
:- type json_parse_result
    --->    json_ok(json)
    ;       json_error(
                jpe_message :: string,
                jpe_offset  :: int
            ).

    % One value, then end of input.
    %
    %@helper
:- pred parse_json(string::in, json_parse_result::out) is det.

    % The same, as Python's `json` reads the corpus: `NaN`, `Infinity` and
    % `-Infinity` are numbers. For the corpus only.
    %
    %@helper
:- pred parse_corpus_json(string::in, json_parse_result::out) is det.

    % `parse_corpus_json`, and every member name an object repeats, at any
    % depth, one entry per repeat, in document order.
    %
    %@spec [RCTS.1.2.1]
:- pred rcts_1_2_1_parse_corpus_json(string::in, json_parse_result::out,
                                     list(string)::out) is det.

    % A DS string literal's text, its [LGRA.2.9.1] escapes decoded.
    %
    % Fails on a bad escape, which `validate` reports, and on a zero code point.
    %
    %@helper
:- pred string_literal_value(string::in, string::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.float_text.
:- import_module ds.i64.
:- import_module assoc_list.
:- import_module bool.
:- import_module char.
:- import_module float.
:- import_module int.
:- import_module pair.

%-----------------------------------------------------------------------------%

    %@helper
:- type step
    --->    ok(json, list(char), int)
    ;       err(string, int).

    %@helper
:- type str_step
    --->    sok(string, list(char), int)
    ;       serr(string, int).

%-----------------------------------------------------------------------------%

parse_json(Text, Result) :-
    parse_in(strict, Text, Result, _).

parse_corpus_json(Text, Result) :-
    parse_in(python, Text, Result, _).

rcts_1_2_1_parse_corpus_json(Text, Result, Repeats) :-
    parse_in(python, Text, Result, Repeats).

    %@helper
:- type dialect
    --->    strict
    ;       python.

    %@helper
:- pred parse_in(dialect::in, string::in, json_parse_result::out,
                 list(string)::out) is det.

parse_in(Dialect, Text, Result, Repeats) :-
    skip_ws(string.to_char_list(Text), 0, Chars, Offset),
    value(Dialect, Chars, Offset, Step, [], RevRepeats),
    Repeats = list.reverse(RevRepeats),
    (
        Step = err(Message, At),
        Result = json_error(Message, At)
    ;
        Step = ok(Json, Rest0, Offset1),
        skip_ws(Rest0, Offset1, Rest, Offset2),
        (
            Rest = [],
            Result = json_ok(Json)
        ;
            Rest = [C | _],
            Result = json_error("trailing input after the document: `"
                ++ char_to_string(C) ++ "`", Offset2)
        )
    ).

    %@helper
:- pred skip_ws(list(char)::in, int::in, list(char)::out, int::out) is det.

skip_ws([], Offset, [], Offset).
skip_ws([C | Cs], Offset, Rest, Out) :-
    ( if json_ws(C) then
        skip_ws(Cs, Offset + 1, Rest, Out)
    else
        Rest = [C | Cs],
        Out = Offset
    ).

    %@helper
:- pred json_ws(char::in) is semidet.

json_ws(' ').
json_ws('\t').
json_ws('\n').
json_ws('\r').

%-----------------------------------------------------------------------------%
% Values
%-----------------------------------------------------------------------------%

    % `!Rep` collects the member names an object repeats, reversed.
    %
    %@helper
:- pred value(dialect::in, list(char)::in, int::in, step::out,
              list(string)::in, list(string)::out) is det.

value(_, [], Offset, err("expected a value, found end of input", Offset),
        !Rep).
value(Dialect, [C | Cs], Offset, Step, !Rep) :-
    Next = Offset + 1,
    ( if C = '{' then
        object_members(Dialect, Cs, Next, [], Step, !Rep)
    else if C = '[' then
        array_elements(Dialect, Cs, Next, [], Step, !Rep)
    else if C = '"' then
        string_body(Cs, Next, [], StrStep),
        (
            StrStep = sok(S, Rest, After),
            Step = ok(j_string(S), Rest, After)
        ;
            StrStep = serr(Message, At),
            Step = err(Message, At)
        )
    % `-Infinity` before the number arm, which would take its `-`.
    else if Dialect = python, literal([C | Cs], "NaN") then
        % This `float` module has no `nan`; `inf - inf` is the quiet NaN.
        Step = ok(j_float(float.infinity - float.infinity), drop(3, [C | Cs]),
            Offset + 3)
    else if Dialect = python, literal([C | Cs], "Infinity") then
        Step = ok(j_float(float.infinity), drop(8, [C | Cs]), Offset + 8)
    else if Dialect = python, literal([C | Cs], "-Infinity") then
        Step = ok(j_float(-float.infinity), drop(9, [C | Cs]), Offset + 9)
    else if ( C = ('-') ; char.is_digit(C) ) then
        number([C | Cs], Offset, Step)
    else if literal([C | Cs], "true") then
        Step = ok(j_bool(yes), drop(4, [C | Cs]), Offset + 4)
    else if literal([C | Cs], "false") then
        Step = ok(j_bool(no), drop(5, [C | Cs]), Offset + 5)
    else if literal([C | Cs], "null") then
        Step = ok(j_null, drop(4, [C | Cs]), Offset + 4)
    else
        Step = err("expected a value, found `" ++ char_to_string(C) ++ "`",
            Offset)
    ).

    %@helper
:- pred literal(list(char)::in, string::in) is semidet.

literal(Chars, Word) :-
    prefix_matches(string.to_char_list(Word), Chars).

    %@helper
:- pred prefix_matches(list(char)::in, list(char)::in) is semidet.

prefix_matches([], _).
prefix_matches([W | Ws], [C | Cs]) :-
    W = C,
    prefix_matches(Ws, Cs).

    %@helper
:- func drop(int, list(char)) = list(char).

drop(N, Cs) = ( if N =< 0 then Cs else drop_one(N, Cs) ).

    %@helper
:- func drop_one(int, list(char)) = list(char).

drop_one(_, []) = [].
drop_one(N, [_ | Cs]) = drop(N - 1, Cs).

%-----------------------------------------------------------------------------%
% Objects and arrays
%-----------------------------------------------------------------------------%

    % `ds.json` sorts the members. Keys compare decoded. A repeated key is
    % refused under `strict`; under `python` `object/1` keeps the last and `!Rep`
    % gets the name.
    %
    %@helper
:- pred object_members(dialect::in, list(char)::in, int::in,
                       assoc_list(string, json)::in,
                       step::out, list(string)::in, list(string)::out) is det.

object_members(Dialect, Chars0, Offset0, Acc, Step, !Rep) :-
    skip_ws(Chars0, Offset0, Chars, Offset),
    ( if Chars = ['}' | Rest] then
        Step = ok(j_object(object(list.reverse(Acc))), Rest, Offset + 1)
    else if Acc = [], not Chars = ['"' | _] then
        Step = object_expected("a key or `}`", Chars, Offset)
    else if Chars = ['"' | AfterQuote] then
        string_body(AfterQuote, Offset + 1, [], KeyStep),
        (
            KeyStep = serr(Message, At),
            Step = err(Message, At)
        ;
            KeyStep = sok(Key, AfterKey0, AfterKey),
            skip_ws(AfterKey0, AfterKey, Colon, ColonAt),
            ( if
                Dialect = strict,
                assoc_list.search(Acc, Key, _)
            then
                Step = err("in an object: the key `" ++ Key
                    ++ "` is repeated", Offset)
            else if Colon = [':' | AfterColon] then
                ( if assoc_list.search(Acc, Key, _) then
                    !:Rep = [Key | !.Rep]
                else
                    true
                ),
                skip_ws(AfterColon, ColonAt + 1, ValueChars, ValueAt),
                value(Dialect, ValueChars, ValueAt, ValueStep, !Rep),
                (
                    ValueStep = err(Message, At),
                    Step = err(Message, At)
                ;
                    ValueStep = ok(Value, AfterValue0, AfterValue),
                    object_more(Dialect, AfterValue0, AfterValue,
                        [Key - Value | Acc],
                        Step, !Rep)
                )
            else
                Step = object_expected("`:` after the key", Colon, ColonAt)
            )
        )
    else
        Step = object_expected("a key", Chars, Offset)
    ).

    %@helper
:- pred object_more(dialect::in, list(char)::in, int::in,
                    assoc_list(string, json)::in,
                    step::out, list(string)::in, list(string)::out) is det.

object_more(Dialect, Chars0, Offset0, Acc, Step, !Rep) :-
    skip_ws(Chars0, Offset0, Chars, Offset),
    ( if Chars = ['}' | Rest] then
        Step = ok(j_object(object(list.reverse(Acc))), Rest, Offset + 1)
    else if Chars = [',' | Rest] then
        % `object_members` would accept a `}` here, so a trailing comma is
        % refused before it.
        skip_ws(Rest, Offset + 1, AfterComma, AfterAt),
        ( if AfterComma = ['"' | _] then
            object_members(Dialect, AfterComma, AfterAt, Acc, Step, !Rep)
        else
            Step = object_expected("a key after `,`", AfterComma, AfterAt)
        )
    else
        Step = object_expected("`,` or `}`", Chars, Offset)
    ).

    %@helper
:- func object_expected(string, list(char), int) = step.

object_expected(Wanted, Chars, Offset) =
    err("in an object: expected " ++ Wanted ++ ", found " ++ found(Chars),
        Offset).

    %@helper
:- pred array_elements(dialect::in, list(char)::in, int::in, list(json)::in,
                       step::out, list(string)::in, list(string)::out)
    is det.

array_elements(Dialect, Chars0, Offset0, Acc, Step, !Rep) :-
    skip_ws(Chars0, Offset0, Chars, Offset),
    ( if Chars = [']' | Rest], Acc = [] then
        Step = ok(j_array([]), Rest, Offset + 1)
    else
        value(Dialect, Chars, Offset, ValueStep, !Rep),
        (
            ValueStep = err(Message, At),
            Step = err(Message, At)
        ;
            ValueStep = ok(Value, Rest, After),
            array_more(Dialect, Rest, After, [Value | Acc], Step, !Rep)
        )
    ).

    %@helper
:- pred array_more(dialect::in, list(char)::in, int::in, list(json)::in,
                   step::out, list(string)::in, list(string)::out) is det.

array_more(Dialect, Chars0, Offset0, Acc, Step, !Rep) :-
    skip_ws(Chars0, Offset0, Chars, Offset),
    ( if Chars = [']' | Rest] then
        Step = ok(j_array(list.reverse(Acc)), Rest, Offset + 1)
    else if Chars = [',' | Rest] then
        array_elements(Dialect, Rest, Offset + 1, Acc, Step, !Rep)
    else
        Step = err("in an array: expected `,` or `]`, found " ++ found(Chars),
            Offset)
    ).

    %@helper
:- func found(list(char)) = string.

found([]) = "end of input".
found([C | _]) = "`" ++ char_to_string(C) ++ "`".

%-----------------------------------------------------------------------------%
% Strings
%-----------------------------------------------------------------------------%

    % The opening quote is already consumed. The accumulator is reversed.
    %
    %@helper
:- pred string_body(list(char)::in, int::in, list(char)::in, str_step::out)
    is det.

string_body([], Offset, _, serr("unterminated string", Offset)).
string_body([C | Cs], Offset, Acc, Step) :-
    Next = Offset + 1,
    ( if C = '"' then
        Step = sok(string.from_char_list(list.reverse(Acc)), Cs, Next)
    else if C = ('\\') then
        escape(Cs, Next, Acc, Step)
    else if char.to_int(C) < 0x20 then
        Step = serr("a raw control character is not legal in a string; "
            ++ "escape it", Offset)
    else
        string_body(Cs, Next, [C | Acc], Step)
    ).

    %@helper
:- pred escape(list(char)::in, int::in, list(char)::in, str_step::out) is det.

escape([], Offset, _, serr("a `\\` at end of input", Offset)).
escape([C | Cs], Offset, Acc, Step) :-
    Next = Offset + 1,
    ( if simple_escape(C, Decoded) then
        string_body(Cs, Next, [Decoded | Acc], Step)
    else if C = 'u' then
        unicode_escape(Cs, Next, Acc, Step)
    else
        Step = serr("`\\" ++ char_to_string(C) ++ "` is not a JSON escape",
            Offset)
    ).

    %@helper
:- pred simple_escape(char::in, char::out) is semidet.

simple_escape('"', '"').
simple_escape('\\', '\\').
simple_escape('/', '/').
simple_escape('b', '\b').
simple_escape('f', '\f').
simple_escape('n', '\n').
simple_escape('r', '\r').
simple_escape('t', '\t').

    %@helper
:- pred unicode_escape(list(char)::in, int::in, list(char)::in, str_step::out)
    is det.

unicode_escape(Chars, Offset, Acc, Step) :-
    ( if hex4(Chars, High, AfterHigh) then
        ( if High >= 0xD800, High =< 0xDBFF then
            ( if
                AfterHigh = ['\\', 'u' | AfterPrefix],
                hex4(AfterPrefix, Low, AfterLow),
                Low >= 0xDC00,
                Low =< 0xDFFF
            then
                Code = 0x10000 + ((High - 0xD800) * 0x400) + (Low - 0xDC00),
                emit_code(Code, AfterLow, Offset + 10, Acc, Step)
            else
                Step = serr("a high surrogate escape with no low surrogate "
                    ++ "following it is not a character", Offset)
            )
        else if High >= 0xDC00, High =< 0xDFFF then
            Step = serr("a lone low surrogate escape is not a character",
                Offset)
        else
            emit_code(High, AfterHigh, Offset + 4, Acc, Step)
        )
    else
        Step = serr("`\\u` must be followed by four hex digits", Offset)
    ).

    %@helper
:- pred emit_code(int::in, list(char)::in, int::in, list(char)::in,
                  str_step::out) is det.

emit_code(Code, Rest, Offset, Acc, Step) :-
    ( if char.from_int(Code, Decoded) then
        string_body(Rest, Offset, [Decoded | Acc], Step)
    else
        Step = serr("`\\u` escape is not a Unicode character", Offset)
    ).

    %@helper
:- pred hex4(list(char)::in, int::out, list(char)::out) is semidet.

hex4([A, B, C, D | Rest], Value, Rest) :-
    hex_digit(A, VA),
    hex_digit(B, VB),
    hex_digit(C, VC),
    hex_digit(D, VD),
    Value = (((VA * 16 + VB) * 16 + VC) * 16) + VD.

    %@helper
:- pred hex_digit(char::in, int::out) is semidet.

hex_digit(C, Value) :-
    ( if char.is_digit(C) then
        Value = char.to_int(C) - char.to_int('0')
    else if lower_hex(C, V) then
        Value = V
    else
        upper_hex(C, Value)
    ).

    %@helper
:- pred lower_hex(char::in, int::out) is semidet.

lower_hex('a', 10).
lower_hex('b', 11).
lower_hex('c', 12).
lower_hex('d', 13).
lower_hex('e', 14).
lower_hex('f', 15).

    %@helper
:- pred upper_hex(char::in, int::out) is semidet.

upper_hex('A', 10).
upper_hex('B', 11).
upper_hex('C', 12).
upper_hex('D', 13).
upper_hex('E', 14).
upper_hex('F', 15).

%-----------------------------------------------------------------------------%
% Numbers
%-----------------------------------------------------------------------------%

    % The spelling decides the kind: `1` is `j_int(1)`, `1.0` is `j_float(1.0)`.
    % An integer that does not fit an `int64` becomes a float.
    %
    %@helper
:- pred number(list(char)::in, int::in, step::out) is det.

number(Chars, Offset, Step) :-
    take_number(Chars, [], Digits, Rest, Length),
    Text = string.from_char_list(list.reverse(Digits)),
    After = Offset + Length,
    ( if is_integral(Text), i64.from_decimal(Text, I) then
        Step = ok(j_int(I), Rest, After)
    else if float_text.parse_json(Text, F) then
        % The runtime's parser, not the host's ([LDET.3.3a.8]).
        Step = ok(j_float(F), Rest, After)
    else
        Step = err("`" ++ Text ++ "` is not a JSON number", Offset)
    ).

    %@helper
:- pred take_number(list(char)::in, list(char)::in, list(char)::out,
                    list(char)::out, int::out) is det.

take_number([], Acc, Acc, [], 0).
take_number([C | Cs], Acc, Digits, Rest, Length) :-
    ( if number_char(C) then
        take_number(Cs, [C | Acc], Digits, Rest, Inner),
        Length = Inner + 1
    else
        Digits = Acc,
        Rest = [C | Cs],
        Length = 0
    ).

    %@helper
:- pred number_char(char::in) is semidet.

number_char(C) :-
    ( char.is_digit(C)
    ; C = ('-')
    ; C = ('+')
    ; C = ('.')
    ; C = 'e'
    ; C = 'E'
    ).

    %@helper
:- pred is_integral(string::in) is semidet.

is_integral(Text) :-
    not string.contains_char(Text, '.'),
    not string.contains_char(Text, 'e'),
    not string.contains_char(Text, 'E').

%-----------------------------------------------------------------------------%
string_literal_value(Text, Value) :-
    literal_chars(string.to_char_list(Text), Chars),
    Value = string.from_char_list(Chars).

    %@helper
:- pred literal_chars(list(char)::in, list(char)::out) is semidet.

literal_chars([], []).
literal_chars([C | Cs], Out) :-
    ( if C = ('\\') then
        Cs = [E | Rest],
        ( if literal_simple(E, Decoded) then
            literal_chars(Rest, Tail),
            Out = [Decoded | Tail]
        else
            literal_width(E, Width),
            literal_hex(Width, Rest, 0, Code, AfterHex),
            Code \= 0,
            char.from_int(Code, Decoded),
            literal_chars(AfterHex, Tail),
            Out = [Decoded | Tail]
        )
    else
        literal_chars(Cs, Tail),
        Out = [C | Tail]
    ).

    %@helper
:- pred literal_simple(char::in, char::out) is semidet.

literal_simple('"', '"').
literal_simple('\\', '\\').
literal_simple('n', '\n').
literal_simple('t', '\t').
literal_simple('r', '\r').

    %@helper
:- pred literal_width(char::in, int::out) is semidet.

literal_width('x', 2).
literal_width('u', 4).
literal_width('U', 8).

    %@helper
:- pred literal_hex(int::in, list(char)::in, int::in, int::out,
                    list(char)::out) is semidet.

literal_hex(N, Chars, Acc, Code, Rest) :-
    ( if N = 0 then
        Code = Acc,
        Rest = Chars
    else
        Chars = [C | Cs],
        char.is_hex_digit(C, Digit),
        literal_hex(N - 1, Cs, Acc * 16 + Digit, Code, Rest)
    ).

:- end_module dsc.json.
%-----------------------------------------------------------------------------%

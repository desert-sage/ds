% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.strlit -- a string literal's escapes and interpolation sites, read once.
%
% A literal's text arrives raw from the lexer: escapes undecoded, braces
% undoubled.
%
% A `{` starts a site only when a name could start after it, so `"{\"v\":1}"`
% is literal text: the corpus's reading, over [LGRA.2.9.6.7]'s "any other
% unescaped `{`". `{len(x)}` is a site, which `validate` refuses.
%-----------------------------------------------------------------------------%

:- module dsc.strlit.
:- interface.

:- import_module dsc.expr.
:- import_module dsc.token.

:- import_module bool.
:- import_module char.
:- import_module list.
:- import_module maybe.
:- import_module uint32.

%-----------------------------------------------------------------------------%
% Escapes -- [LGRA.2.9.1], [LGRA.2.9.4]
%-----------------------------------------------------------------------------%

    % A literal run's text, decoded, or the first bad escape in it.
    %
    %@helper
:- type decoded
    --->    decoded(list(char))
    ;       bad_escape(string).

    %@spec [LGRA.2.9.4]
:- func lgra_2_9_4_decode(list(char)) = decoded.

%-----------------------------------------------------------------------------%
% Sites -- [LGRA.2.9.6]
%-----------------------------------------------------------------------------%

    % `p_text` is a literal run with `{{` / `}}` collapsed to one brace and
    % its escapes still raw. `p_site` is a site's body between the braces,
    % its `:format` included. `p_empty` is `{}`. `p_unclosed` is a `{` that
    % starts a site and has no `}` after it, with the raw text to the literal's
    % end.
    %
    %@helper
:- type piece
    --->    p_text(list(char))
    ;       p_site(list(char))
    ;       p_empty
    ;       p_unclosed(list(char)).

    %@spec [LGRA.2.9.6.7]
:- func lgra_2_9_6_7_pieces(list(char)) = list(piece).

    %@helper
:- pred has_site(list(piece)::in) is semidet.

    % A literal's value, its `{{` / `}}` collapsed and its escapes decoded.
    % Fails on a site and on a bad escape.
    %
    %@helper
:- pred literal_value(string::in, string::out) is semidet.

    % A site body split at its first `:` into the path and any format.
    %
    %@helper
:- pred site_split(list(char)::in, list(char)::out, maybe(list(char))::out)
    is det.

    % The whole of [LGRA.2.9.6.1]'s `interp_body`, returning the leading NAME
    % in NFC.
    %
    %@spec [LGRA.2.9.6.1]
    %@spec [LGRA.2.9.6.6]
:- pred lgra_2_9_6_1_path(list(char)::in, string::out) is semidet.

    % The identifiers a site body names, in order, each in NFC.
    %
    %@helper
:- func site_names(list(char)) = list(string).

    % A site's path read as an expression, with nothing left over. Fails on a
    % body the expression grammar does not read. Its positions are the body's
    % own; `at_pos` moves them onto the literal.
    %
    %@helper
:- pred site_expr(list(char)::in, lgra_9_3_1_expr::out) is semidet.

    %@helper
:- func at_pos(pos, lgra_9_3_1_expr) = lgra_9_3_1_expr.

    %@helper
:- pred name_start(char::in) is semidet.
    %@helper
:- pred name_continue(char::in) is semidet.

%-----------------------------------------------------------------------------%
% Format specs -- [LGRA.2.9.6.1]
%-----------------------------------------------------------------------------%

    %@helper
:- type interp_format
    --->    if_time(list(time_piece))
            % A timestamp pattern, its directives resolved and its literal
            % runs merged ([LGRA.2.9.6.4]). `%%` is text.

    ;       if_num(num_format).

    %@helper
:- type time_piece
    --->    tp_text(string)
    ;       tp_dir(char).       % one of `Y m d H M S f z`

    % `nf_type` is the character as written.
    %
    %@helper
:- type num_format
    --->    num_format(
                nf_align     :: maybe(char),    % `<` or `>`
                nf_plus      :: bool,
                nf_zero      :: bool,
                % The wire's `uint32`: a Mercury `int` is 32 bits on a 32-bit
                % target.
                nf_width     :: maybe(uint32),
                nf_precision :: maybe(uint32),
                nf_type      :: maybe(char)
            ).

:- type spec_read
    --->    spec_ok(interp_format)
    ;       spec_bad(string).       % what is wrong, for the diagnostic

    % The grammar only; the constraints that need the value's type are
    % `validate`'s ([LGRA.2.9.6.5]).
    %
    %@spec [LGRA.2.9.6.1]
    %@spec [LGRA.2.9.6.4]
:- func lgra_2_9_6_1_format(list(char)) = spec_read.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.layout.
:- import_module dsc.lex.
:- import_module dsc.parse.
:- import_module dsc.uniname.

:- import_module int.
:- import_module string.
:- import_module uint64.

%-----------------------------------------------------------------------------%
% Escapes
%-----------------------------------------------------------------------------%

lgra_2_9_4_decode(Chars) = decode(Chars, []).

    %@helper
:- func decode(list(char), list(char)) = decoded.

decode([], Acc) = decoded(list.reverse(Acc)).
decode([C | Cs], Acc) = Result :-
    ( if C = ('\\') then
        ( if
            escape(Cs, Value, Rest),
            char.from_int(Value, Char)
        then
            Result = decode(Rest, [Char | Acc])
        else
            Result = bad_escape(escape_reason(Cs))
        )
    else
        Result = decode(Cs, [C | Acc])
    ).

    % One escape after its `\`: the code point it denotes, and what follows.
    %
    %@helper
:- pred escape(list(char)::in, int::out, list(char)::out) is semidet.

escape([C | Cs], Value, Rest) :-
    ( if simple_escape(C, Out) then
        Value = char.to_int(Out),
        Rest = Cs
    else if C = 'x' then
        hex_digits(2, Cs, Value, Rest),
        codepoint_ok(Value)
    else if C = 'u' then
        hex_digits(4, Cs, Value, Rest),
        codepoint_ok(Value)
    else
        C = 'U',
        hex_digits(8, Cs, Value, Rest),
        codepoint_ok(Value)
    ).

    %@helper
:- pred simple_escape(char::in, char::out) is semidet.

simple_escape('"', '"').
simple_escape('\'', '\'').    % [LGRA.2.9.7]
simple_escape('\\', '\\').
simple_escape('n', '\n').
simple_escape('t', '\t').
simple_escape('r', '\r').

    % Exactly N hex digits, and their value.
    %
    %@helper
:- pred hex_digits(int::in, list(char)::in, int::out, list(char)::out)
    is semidet.

hex_digits(N, Chars, Value, Rest) :-
    hex_acc(N, Chars, 0, Value, Rest).

    %@helper
:- pred hex_acc(int::in, list(char)::in, int::in, int::out, list(char)::out)
    is semidet.

hex_acc(N, Chars, Acc, Value, Rest) :-
    ( if N = 0 then
        Value = Acc,
        Rest = Chars
    else
        Chars = [C | Cs],
        char.is_hex_digit(C, Digit),
        hex_acc(N - 1, Cs, Acc * 16 + Digit, Value, Rest)
    ).

    %@helper
:- pred codepoint_ok(int::in) is semidet.

codepoint_ok(Value) :-
    Value >= 1,                                 % [LSTR.1.1]: no U+0000
    Value =< 0x10FFFF,
    not ( Value >= 0xD800, Value =< 0xDFFF ).

    %@helper
:- func escape_reason(list(char)) = string.

escape_reason([]) = "a `\\` at the end of the literal".
escape_reason([C | Cs]) = Reason :-
    ( if C = 'x' then
        Reason = short_or_bad("\\x", 2, Cs)
    else if C = 'u' then
        Reason = short_or_bad("\\u", 4, Cs)
    else if C = 'U' then
        Reason = short_or_bad("\\U", 8, Cs)
    else
        Reason = "`\\" ++ string.char_to_string(C) ++ "` is not an escape"
    ).

    %@helper
:- func short_or_bad(string, int, list(char)) = string.

short_or_bad(Prefix, N, Cs) = Reason :-
    ( if hex_digits(N, Cs, Value, _) then
        Reason = Prefix ++ " names U+" ++ string.int_to_base_string(Value, 16)
            ++ ", which is not a character"
    else
        Reason = Prefix ++ " needs exactly " ++ string.int_to_string(N)
            ++ " hex digits"
    ).

%-----------------------------------------------------------------------------%
% Sites
%-----------------------------------------------------------------------------%

lgra_2_9_6_7_pieces(Chars) = pieces(Chars, []).

    % `Run` is the literal run so far, reversed.
    %
    %@helper
:- func pieces(list(char), list(char)) = list(piece).

pieces([], Run) = run(Run).
pieces([C | Cs], Run) = Pieces :-
    ( if C = ('{'), Cs = ['{' | Rest] then
        Pieces = pieces(Rest, ['{' | Run])
    else if C = ('}'), Cs = ['}' | Rest] then
        Pieces = pieces(Rest, ['}' | Run])
    else if C = ('{'), Cs = ['}' | Rest] then
        Pieces = run(Run) ++ [p_empty | pieces(Rest, [])]
    else if C = ('{'), Cs = [First | _], name_start(First) then
        ( if take_to_close(Cs, Body, Rest) then
            Pieces = run(Run) ++ [p_site(Body) | pieces(Rest, [])]
        else
            Pieces = run(Run) ++ [p_unclosed([C | Cs])]
        )
    else
        Pieces = pieces(Cs, [C | Run])
    ).

    %@helper
:- func run(list(char)) = list(piece).

run(Run) = ( if Run = [] then [] else [p_text(list.reverse(Run))] ).

    %@helper
:- pred take_to_close(list(char)::in, list(char)::out, list(char)::out)
    is semidet.

take_to_close([C | Cs], Body, Rest) :-
    ( if C = ('}') then
        Body = [],
        Rest = Cs
    else
        take_to_close(Cs, Inner, Rest),
        Body = [C | Inner]
    ).

has_site(Pieces) :-
    list.find_first_match(is_site, Pieces, _).

literal_value(Text, Value) :-
    not has_site(lgra_2_9_6_7_pieces(string.to_char_list(Text))),
    Collapsed = string.replace_all(string.replace_all(Text, "{{", "{"),
        "}}", "}"),
    lgra_2_9_4_decode(string.to_char_list(Collapsed)) = decoded(Chars),
    Value = string.from_char_list(Chars).

    %@helper
:- pred is_site(piece::in) is semidet.

is_site(p_site(_)).

site_split([], [], no).
site_split([C | Cs], Path, Format) :-
    ( if C = (':') then
        Path = [],
        Format = yes(Cs)
    else
        site_split(Cs, Path0, Format),
        Path = [C | Path0]
    ).

lgra_2_9_6_1_path(Chars, Leading) :-
    take_name(Chars, LeadChars, Rest),
    LeadChars = [_ | _],
    Leading = lnam_2_4_1_nfc(string.from_char_list(LeadChars)),
    path_tail(Rest).

    %@helper
:- pred path_tail(list(char)::in) is semidet.

path_tail([]).
path_tail([C | Cs]) :-
    ( if C = ('.') then
        take_name(Cs, Name, Rest),
        Name = [_ | _],
        path_tail(Rest)
    else
        C = ('['),
        take_digits(Cs, Digits, Rest0),
        Digits = [_ | _],
        Rest0 = [']' | Rest],
        path_tail(Rest)
    ).

site_names(Body) = Names :-
    site_split(Body, Path, _),
    names_in(Path, [], RevNames),
    Names = list.reverse(RevNames).

    % Every maximal name in `Chars`. A run starting with a digit is a number,
    % and is skipped whole.
    %
    %@helper
:- pred names_in(list(char)::in, list(string)::in, list(string)::out) is det.

names_in([], !Names).
names_in([C | Cs], !Names) :-
    ( if name_start(C) then
        take_name([C | Cs], Name, Rest),
        !:Names = [lnam_2_4_1_nfc(string.from_char_list(Name)) | !.Names],
        names_in(Rest, !Names)
    else if char.is_digit(C) then
        list.drop_while(name_continue, Cs, Rest),
        names_in(Rest, !Names)
    else
        names_in(Cs, !Names)
    ).

    % Empty if the first character is not a name start.
    %
    %@helper
:- pred take_name(list(char)::in, list(char)::out, list(char)::out) is det.

take_name([], [], []).
take_name([C | Cs], Name, Rest) :-
    ( if name_start(C) then
        list.take_while(name_continue, Cs, More, Rest),
        Name = [C | More]
    else
        Name = [],
        Rest = [C | Cs]
    ).

    %@helper
:- pred take_digits(list(char)::in, list(char)::out, list(char)::out) is det.

take_digits(Chars, Digits, Rest) :-
    list.take_while(char.is_digit, Chars, Digits, Rest).

site_expr(Path, Expr) :-
    llex_5_4_lex(string.from_char_list(Path), lex_ok(Lines)),
    llex_6_2_layout(Lines, lay_ok(Tokens)),
    % The expression parser refuses a trailing end-of-line token.
    Span = list.negated_filter(
        ( pred(P::in) is semidet :- layout_token(P ^ tk_tok) ), Tokens),
    lgra_9_1_parse_expr(Span, ex_ok(Expr, [])).

at_pos(P, ex_int(I, _)) = ex_int(I, P).
at_pos(P, ex_float(F, _)) = ex_float(F, P).
at_pos(P, ex_string(S, _)) = ex_string(S, P).
at_pos(P, ex_unit(M, U, _)) = ex_unit(M, U, P).
at_pos(P, ex_bool(B, _)) = ex_bool(B, P).
at_pos(P, ex_null(_)) = ex_null(P).
at_pos(P, ex_name(ident(N, _))) = ex_name(ident(N, P)).
at_pos(P, ex_unary(Op, E, _)) = ex_unary(Op, at_pos(P, E), P).
at_pos(P, ex_not(E, _)) = ex_not(at_pos(P, E), P).
at_pos(P, ex_binary(Op, L, R, _)) = ex_binary(Op, at_pos(P, L), at_pos(P, R), P).
at_pos(P, ex_compare(L, Steps, _)) =
    ex_compare(at_pos(P, L), list.map(step_at(P), Steps), P).
at_pos(P, ex_is(E, Neg, Subject, _)) = ex_is(at_pos(P, E), Neg, Subject, P).
at_pos(P, ex_slot(E, ident(N, _), _)) = ex_slot(at_pos(P, E), ident(N, P), P).
at_pos(P, ex_index(E, I, _)) = ex_index(at_pos(P, E), at_pos(P, I), P).
at_pos(P, ex_call(F, Args, _)) =
    ex_call(at_pos(P, F), list.map(at_pos(P), Args), P).
at_pos(P, ex_cast(E, ident(T, _), Null, _)) =
    ex_cast(at_pos(P, E), ident(T, P), Null, P).
at_pos(P, ex_match(E, Sense, Pattern, Flags, _)) =
    ex_match(at_pos(P, E), Sense, Pattern, Flags, P).

    %@helper
:- func ident_at(pos, ident) = ident.

ident_at(P, ident(N, _)) = ident(N, P).

    %@helper
:- func step_at(pos, lgra_9_3_2_compare_step) = lgra_9_3_2_compare_step.

step_at(P, lgra_9_3_2_compare_step(Op, R, _)) =
    lgra_9_3_2_compare_step(Op, at_pos(P, R), P).

name_start(C) :-
    ( lnam_2_2_1_id_start(C)
    ; C = ('_')
    ).

name_continue(C) :-
    ( lnam_2_2_1_id_continue(C)
    ; C = ('_')
    ; char.is_digit(C)
    ).

%-----------------------------------------------------------------------------%
% Format specs
%-----------------------------------------------------------------------------%

lgra_2_9_6_1_format(Chars) = Read :-
    ( if Chars = ['%' | _] then
        Read = time_format(Chars, [], [])
    else
        Read = num_spec_read(Chars)
    ).

    % `Run` is the literal run being built, reversed; `Acc` the pieces so far,
    % reversed.
    %
:- func time_format(list(char), list(char), list(time_piece)) = spec_read.

time_format([], Run, Acc) =
    spec_ok(if_time(list.reverse(flush_run(Run, Acc)))).
time_format([C | Cs], Run, Acc) = Read :-
    ( if C = ('%') then
        ( if Cs = [D | Rest] then
            ( if D = ('%') then
                Read = time_format(Rest, ['%' | Run], Acc)
            else if time_directive(D) then
                Read = time_format(Rest, [], [tp_dir(D) | flush_run(Run, Acc)])
            else
                Read = spec_bad("`%" ++ string.char_to_string(D)
                    ++ "` is not a directive DS admits")
            )
        else
            Read = spec_bad("a lone `%` ends the pattern")
        )
    else
        Read = time_format(Cs, [C | Run], Acc)
    ).

:- func flush_run(list(char), list(time_piece)) = list(time_piece).

flush_run(Run, Acc) =
    ( if Run = [] then Acc
    else [tp_text(string.from_char_list(list.reverse(Run))) | Acc] ).

    % [LGRA.2.9.6.4]'s closed set, `%%` aside.
    %
:- pred time_directive(char::in) is semidet.

time_directive('Y').
time_directive('m').
time_directive('d').
time_directive('H').
time_directive('M').
time_directive('S').
time_directive('f').
time_directive('z').

:- func num_spec_read(list(char)) = spec_read.

num_spec_read(Cs0) = Read :-
    ( if Cs0 = [A | Cs1a], ( A = ('<') ; A = ('>') ) then
        Align = yes(A), Cs1 = Cs1a
    else
        Align = no, Cs1 = Cs0
    ),
    ( if Cs1 = ['+' | Cs2a] then Plus = yes, Cs2 = Cs2a
    else Plus = no, Cs2 = Cs1 ),
    ( if Cs2 = ['0' | Cs3a] then Zero = yes, Cs3 = Cs3a
    else Zero = no, Cs3 = Cs2 ),
    spec_digits(Cs3, WidthDigits, Cs4),
    ( if Cs4 = ['.' | Cs5a] then
        spec_digits(Cs5a, PrecDigits, Cs5),
        HasPrec = yes
    else
        PrecDigits = [], Cs5 = Cs4, HasPrec = no
    ),
    ( if
        HasPrec = yes,
        PrecDigits = []
    then
        Read = spec_bad("a `.` with no precision after it")
    else if
        spec_count(WidthDigits, Width),
        spec_count(PrecDigits, Precision0),
        ( Cs5 = [], Type = no
        ; Cs5 = [T], spec_type(T), Type = yes(T)
        )
    then
        Precision = ( if HasPrec = yes then Precision0 else no ),
        Read = spec_ok(if_num(num_format(Align, Plus, Zero, Width, Precision,
            Type)))
    else
        Read = spec_bad("not `[<|>][+][0][width][.precision][type]`")
    ).

    % A digit run as a count: `no` for none, and fails past the wire's `uint32`.
    % Read in `uint64`, since a 32-bit `int` cannot hold the bound.
    %
:- pred spec_count(list(char)::in, maybe(uint32)::out) is semidet.

spec_count([], no).
spec_count([D | Ds], yes(N)) :-
    list.length([D | Ds]) =< 10,
    list.foldl(spec_digit, [D | Ds], 0u64, N64),
    N64 =< 4294967295u64,
    N = uint32.cast_from_uint64(N64).

:- pred spec_digit(char::in, uint64::in, uint64::out) is semidet.

spec_digit(C, N0, N) :-
    char.decimal_digit_to_int(C, Digit),
    N = N0 * 10u64 + uint64.cast_from_int(Digit).

:- pred spec_digits(list(char)::in, list(char)::out, list(char)::out) is det.

spec_digits([], [], []).
spec_digits([C | Cs], Digits, Rest) :-
    ( if char.is_digit(C) then
        spec_digits(Cs, Digits0, Rest),
        Digits = [C | Digits0]
    else
        Digits = [],
        Rest = [C | Cs]
    ).

:- pred spec_type(char::in) is semidet.

spec_type('d').
spec_type('f').
spec_type('s').
spec_type('x').
spec_type('X').
spec_type('b').
spec_type('u').
spec_type('i').
spec_type('j').

%-----------------------------------------------------------------------------%
:- end_module dsc.strlit.
%-----------------------------------------------------------------------------%

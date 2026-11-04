% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.json_text -- Json text to a Json term, for a FactExternal's Json slot
% (RFCS.23.2) and a recording's. The grammar must match `runtime/src/libds/json.c`
% byte for byte:
%
% - Whitespace is space, tab, LF and CR, and nothing else.
% - `true`, `false` and `null` are matched as byte prefixes, so `truex` fails at
%   the `x`.
% - A `\u` names one UTF-16 code unit ([LSTR.7.2.3]): a high-surrogate escape
%   followed at once by a low-surrogate one is the codepoint the pair encodes,
%   and any other surrogate escape is malformed. `\u0000` is refused. A raw byte
%   below 0x20 is refused; every other byte is copied as it is.
% - A number with a `.` or an exponent is a Float; one that rounds to an infinity
%   is refused (LGRA.5.8.10). Without, it is an Int; one outside int64 is refused.
% - A leading zero ends the number: `01` is `0` and then a stray `1`.
% - An object that repeats a key is refused when the key is read (LGRA.5.8.7),
%   compared as decoded.
%
% A limit is its own refusal: a caller maps `jr_limit` to DS_ERR_JSON_LIMIT and
% every other refusal to DS_ERR_PARSE. Ill-formed UTF-8 never reaches this parser:
% that boundary is the caller's (`ds.wire.reader_string`).
%-----------------------------------------------------------------------------%

:- module ds.json_text.
:- interface.

:- import_module ds.json.

:- import_module maybe.

    % One maximum per limit (`ds.json.json_limit`); `no` is unbounded.
    %
:- type json_limits
    --->    json_limits(
                lim_depth        :: maybe(int),
                    % levels; the root is level 1
                lim_nodes        :: maybe(int),
                    % values: every scalar, array and object
                lim_string_bytes :: maybe(int),
                    % UTF-8 bytes of every decoded string and key
                lim_text_bytes   :: maybe(int)
                    % bytes of the text, checked before it is read
            ).

    % [LGRA.5.8.6]'s limits.
    %
:- func limits = json_limits.

    % `limits` with a received FactExternal's text limit,
    % `ds.json.max_fx_text_bytes`.
    %
:- func fx_limits = json_limits.

:- type json_refusal
    --->    jr_syntax
    ;       jr_int_outside_int64
    ;       jr_float_outside_double
    ;       jr_nul_escape
    ;       jr_unpaired_surrogate
    ;       jr_repeated_key
    ;       jr_limit(json_limit).

:- type parse_result
    --->    parsed(json)
    ;       refused(json_refusal).

:- pred parse(string::in, parse_result::out) is det.

:- pred parse_with(json_limits::in, string::in, parse_result::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module ds.float_text.
:- import_module ds.i64.

:- import_module assoc_list.
:- import_module bool.
:- import_module float.
:- import_module int.
:- import_module list.
:- import_module pair.
:- import_module string.

%-----------------------------------------------------------------------------%

limits = json_limits(yes(ds.json.max_depth), yes(ds.json.max_nodes),
    yes(ds.json.max_string_bytes), yes(ds.json.max_text_bytes)).

fx_limits = limits ^ lim_text_bytes := yes(ds.json.max_fx_text_bytes).

parse(Text, Result) :-
    parse_with(limits, Text, Result).

parse_with(L, Text, Result) :-
    string.to_utf8_code_unit_list(Text, Bytes),
    ( if over(L ^ lim_text_bytes, list.length(Bytes)) then
        Result = refused(jr_limit(jl_text_bytes))
    else
        value(L, 0, pstate(Bytes, 0, 0), Step),
        (
            Step = step_err(Why),
            Result = refused(Why)
        ;
            Step = step_ok(Json, P),
            ( if skip_ws(P ^ rest) = [] then
                Result = parsed(Json)
            else
                Result = refused(jr_syntax)
            )
        )
    ).

:- pred over(maybe(int)::in, int::in) is semidet.

over(yes(Max), N) :-
    N > Max.

%-----------------------------------------------------------------------------%
% The parser's state: the bytes not yet read, and what the counted limits
% have spent.
%-----------------------------------------------------------------------------%

:- type pstate
    --->    pstate(
                rest      :: list(int),
                nodes     :: int,
                str_bytes :: int
            ).

:- type step(T)
    --->    step_ok(T, pstate)
    ;       step_err(json_refusal).

:- func with_rest(pstate, list(int)) = pstate.

with_rest(P, Rest) = P ^ rest := Rest.

%-----------------------------------------------------------------------------%
% Values
%-----------------------------------------------------------------------------%

    % A value whose container is at level `Depth` (0 for the root). The cap is
    % checked before the value is read, so it bounds the recursion.
    %
:- pred value(json_limits::in, int::in, pstate::in, step(json)::out) is det.

value(L, Depth, P0, Step) :-
    ( if over(L ^ lim_depth, Depth + 1) then
        Step = step_err(jr_limit(jl_depth))
    else if over(L ^ lim_nodes, P0 ^ nodes + 1) then
        Step = step_err(jr_limit(jl_nodes))
    else
        P = (P0 ^ nodes := P0 ^ nodes + 1),
        value_at(L, Depth + 1, P, Step)
    ).

:- pred value_at(json_limits::in, int::in, pstate::in, step(json)::out) is det.

value_at(L, Level, P0, Step) :-
    Bytes = skip_ws(P0 ^ rest),
    P = with_rest(P0, Bytes),
    (
        Bytes = [],
        Step = step_err(jr_syntax)
    ;
        Bytes = [C | After],
        ( if C = c_lbrace then
            parse_object(L, Level, with_rest(P, After), Step)
        else if C = c_lbracket then
            parse_array(L, Level, with_rest(P, After), Step)
        else if C = c_quote then
            string_body(L, with_rest(P, After), StrStep),
            (
                StrStep = step_ok(S, P1),
                Step = step_ok(j_string(S), P1)
            ;
                StrStep = step_err(Why),
                Step = step_err(Why)
            )
        else if ( C = c_minus ; is_digit(C) ) then
            number(P, Step)
        else if literal(c_true, Bytes, RT) then
            Step = step_ok(j_bool(yes), with_rest(P, RT))
        else if literal(c_false, Bytes, RF) then
            Step = step_ok(j_bool(no), with_rest(P, RF))
        else if literal(c_null, Bytes, RN) then
            Step = step_ok(j_null, with_rest(P, RN))
        else
            Step = step_err(jr_syntax)
        )
    ).

:- pred literal(list(int)::in, list(int)::in, list(int)::out) is semidet.

literal([], Rest, Rest).
literal([C | Cs], [C | Bs], Rest) :-
    literal(Cs, Bs, Rest).

%-----------------------------------------------------------------------------%
% Containers
%-----------------------------------------------------------------------------%

    % After the `[`.
    %
:- pred parse_array(json_limits::in, int::in, pstate::in, step(json)::out)
    is det.

parse_array(L, Level, P0, Step) :-
    Bytes = skip_ws(P0 ^ rest),
    ( if Bytes = [c_rbracket | AfterEmpty] then
        Step = step_ok(j_array([]), with_rest(P0, AfterEmpty))
    else
        array_items(L, Level, with_rest(P0, Bytes), [], Step)
    ).

:- pred array_items(json_limits::in, int::in, pstate::in, list(json)::in,
                    step(json)::out) is det.

array_items(L, Level, P0, Acc, Step) :-
    value(L, Level, P0, ItemStep),
    (
        ItemStep = step_err(Why),
        Step = step_err(Why)
    ;
        ItemStep = step_ok(Item, P1),
        Bytes = skip_ws(P1 ^ rest),
        ( if Bytes = [c_comma | AfterComma] then
            array_items(L, Level, with_rest(P1, AfterComma), [Item | Acc],
                Step)
        else if Bytes = [c_rbracket | AfterClose] then
            Step = step_ok(j_array(list.reverse([Item | Acc])),
                with_rest(P1, AfterClose))
        else
            Step = step_err(jr_syntax)
        )
    ).

    % After the `{`. A key counts against the string limit and is not a node.
    %
:- pred parse_object(json_limits::in, int::in, pstate::in, step(json)::out)
    is det.

parse_object(L, Level, P0, Step) :-
    Bytes = skip_ws(P0 ^ rest),
    ( if Bytes = [c_rbrace | AfterEmpty] then
        Step = step_ok(j_object(empty_object), with_rest(P0, AfterEmpty))
    else
        object_members(L, Level, with_rest(P0, Bytes), [], Step)
    ).

:- pred object_members(json_limits::in, int::in, pstate::in,
                       list(pair(string, json))::in, step(json)::out) is det.

object_members(L, Level, P0, Acc, Step) :-
    Bytes0 = skip_ws(P0 ^ rest),
    ( if Bytes0 = [c_quote | AfterQuote] then
        string_body(L, with_rest(P0, AfterQuote), KeyStep),
        (
            KeyStep = step_err(WhyKey),
            Step = step_err(WhyKey)
        ;
            KeyStep = step_ok(Key, P1),
            ( if assoc_list.search(Acc, Key, _) then
                Step = step_err(jr_repeated_key)
            else if skip_ws(P1 ^ rest) = [c_colon | AfterColon] then
                value(L, Level, with_rest(P1, AfterColon), ValStep),
                (
                    ValStep = step_err(WhyVal),
                    Step = step_err(WhyVal)
                ;
                    ValStep = step_ok(Val, P2),
                    Acc1 = [Key - Val | Acc],
                    Bytes2 = skip_ws(P2 ^ rest),
                    ( if Bytes2 = [c_comma | AfterComma] then
                        object_members(L, Level, with_rest(P2, AfterComma),
                            Acc1, Step)
                    else if Bytes2 = [c_rbrace | AfterClose] then
                        Step = step_ok(
                            j_object(ds.json.object(list.reverse(Acc1))),
                            with_rest(P2, AfterClose))
                    else
                        Step = step_err(jr_syntax)
                    )
                )
            else
                Step = step_err(jr_syntax)
            )
        )
    else
        Step = step_err(jr_syntax)
    ).

%-----------------------------------------------------------------------------%
% Strings
%-----------------------------------------------------------------------------%

    % After the opening `"`, to just past the closing one.
    %
:- pred string_body(json_limits::in, pstate::in, step(string)::out) is det.

string_body(L, P0, Step) :-
    string_bytes(P0 ^ rest, [], Scan),
    (
        Scan = scan_err(Why),
        Step = step_err(Why)
    ;
        Scan = scan_ok(RevOut, Rest),
        N = list.length(RevOut),
        Spent = P0 ^ str_bytes + N,
        ( if over(L ^ lim_string_bytes, Spent) then
            Step = step_err(jr_limit(jl_string_bytes))
        else if
            string.from_utf8_code_unit_list(list.reverse(RevOut), S)
        then
            Step = step_ok(S, pstate(Rest, P0 ^ nodes, Spent))
        else
            % Not reachable from a well-formed input string.
            Step = step_err(jr_syntax)
        )
    ).

:- type scan
    --->    scan_ok(list(int), list(int))
            % the decoded bytes, REVERSED; the bytes after the closing quote
    ;       scan_err(json_refusal).

:- pred string_bytes(list(int)::in, list(int)::in, scan::out) is det.

string_bytes([], _, scan_err(jr_syntax)).
string_bytes([B | Bs], Out, Scan) :-
    ( if B = c_quote then
        Scan = scan_ok(Out, Bs)
    else if B = c_backslash then
        escape(Bs, Out, Scan)
    else if B < 0x20 then
        Scan = scan_err(jr_syntax)
    else
        string_bytes(Bs, [B | Out], Scan)
    ).

:- pred escape(list(int)::in, list(int)::in, scan::out) is det.

escape([], _, scan_err(jr_syntax)).
escape([E | Bs], Out, Scan) :-
    ( if simple_escape(E, B) then
        string_bytes(Bs, [B | Out], Scan)
    else if E = c_u then
        ( if hex4(Bs, Unit, After) then
            ( if Unit >= 0xDC00, Unit =< 0xDFFF then
                Scan = scan_err(jr_unpaired_surrogate)
            else if Unit >= 0xD800, Unit =< 0xDBFF then
                ( if
                    After = [c_backslash, c_u | AfterU],
                    hex4(AfterU, Low, AfterLow),
                    Low >= 0xDC00, Low =< 0xDFFF
                then
                    CP = 0x10000 + ((Unit - 0xD800) << 10) + (Low - 0xDC00),
                    string_bytes(AfterLow, utf8_rev(CP) ++ Out, Scan)
                else
                    Scan = scan_err(jr_unpaired_surrogate)
                )
            else if Unit = 0 then
                Scan = scan_err(jr_nul_escape)
            else
                string_bytes(After, utf8_rev(Unit) ++ Out, Scan)
            )
        else
            Scan = scan_err(jr_syntax)
        )
    else
        Scan = scan_err(jr_syntax)
    ).

:- pred hex4(list(int)::in, int::out, list(int)::out) is semidet.

hex4([H0, H1, H2, H3 | After], Unit, After) :-
    hex(H0, D0), hex(H1, D1), hex(H2, D2), hex(H3, D3),
    Unit = (D0 << 12) \/ (D1 << 8) \/ (D2 << 4) \/ D3.

:- pred simple_escape(int::in, int::out) is semidet.

simple_escape(0x22, 0x22).      % \"
simple_escape(0x5C, 0x5C).      % \\
simple_escape(0x2F, 0x2F).      % \/
simple_escape(0x62, 0x08).      % \b
simple_escape(0x66, 0x0C).      % \f
simple_escape(0x6E, 0x0A).      % \n
simple_escape(0x72, 0x0D).      % \r
simple_escape(0x74, 0x09).      % \t

:- pred hex(int::in, int::out) is semidet.

hex(C, D) :-
    ( if C >= 0x30, C =< 0x39 then
        D = C - 0x30
    else if C >= 0x61, C =< 0x66 then
        D = C - 0x61 + 10
    else
        C >= 0x41, C =< 0x46,
        D = C - 0x41 + 10
    ).

    % A code point's UTF-8 bytes, REVERSED to prepend onto the reversed
    % output.
    %
:- func utf8_rev(int) = list(int).

utf8_rev(CP) = Rev :-
    ( if CP < 0x80 then
        Rev = [CP]
    else if CP < 0x800 then
        Rev = [0x80 \/ (CP /\ 0x3F), 0xC0 \/ (CP >> 6)]
    else if CP < 0x10000 then
        Rev = [0x80 \/ (CP /\ 0x3F), 0x80 \/ ((CP >> 6) /\ 0x3F),
               0xE0 \/ (CP >> 12)]
    else
        Rev = [0x80 \/ (CP /\ 0x3F), 0x80 \/ ((CP >> 6) /\ 0x3F),
               0x80 \/ ((CP >> 12) /\ 0x3F), 0xF0 \/ (CP >> 18)]
    ).

%-----------------------------------------------------------------------------%
% Numbers
%-----------------------------------------------------------------------------%

:- pred number(pstate::in, step(json)::out) is det.

number(P, Step) :-
    ( if
        number_bytes(P ^ rest, Rev, IsFloat, Rest),
        string.from_utf8_code_unit_list(list.reverse(Rev), Text)
    then
        (
            IsFloat = yes,
            ( if ds.float_text.parse_json(Text, F0) then
                ( if float.is_infinite(F0) then
                    Step = step_err(jr_float_outside_double)
                else
                    % A float zero in a Json value is +0.0 (LGRA.5.8.8). A zero
                    % of either sign passes both comparisons.
                    F = ( if F0 =< 0.0, F0 >= 0.0 then 0.0 else F0 ),
                    Step = step_ok(j_float(F), with_rest(P, Rest))
                )
            else
                Step = step_err(jr_syntax)
            )
        ;
            IsFloat = no,
            ( if ds.i64.from_decimal(Text, I) then
                Step = step_ok(j_int(I), with_rest(P, Rest))
            else
                % The only failure left is the range.
                Step = step_err(jr_int_outside_int64)
            )
        )
    else
        Step = step_err(jr_syntax)
    ).

    % The number's bytes, reversed; whether it is a Float; the bytes after.
    %
:- pred number_bytes(list(int)::in, list(int)::out, bool::out, list(int)::out)
    is semidet.

number_bytes(Bs0, Rev, IsFloat, Rest) :-
    ( if Bs0 = [c_minus | AfterMinus] then
        Bs1 = AfterMinus,
        Acc0 = [c_minus]
    else
        Bs1 = Bs0,
        Acc0 = []
    ),
    Bs1 = [D | Bs2],
    ( if D = c_zero then
        Acc1 = [D | Acc0],
        Bs3 = Bs2
    else
        D >= 0x31, D =< 0x39,
        digits(Bs2, [D | Acc0], Acc1, Bs3)
    ),
    ( if Bs3 = [c_dot | Bs4] then
        Bs4 = [F | _], is_digit(F),
        digits(Bs4, [c_dot | Acc1], Acc2, Bs5),
        Frac = yes
    else
        Acc2 = Acc1, Bs5 = Bs3, Frac = no
    ),
    ( if Bs5 = [X | Bs6], ( X = c_e ; X = c_cap_e ) then
        ( if Bs6 = [S | Bs7], ( S = c_plus ; S = c_minus ) then
            Acc3 = [S, X | Acc2], Bs8 = Bs7
        else
            Acc3 = [X | Acc2], Bs8 = Bs6
        ),
        Bs8 = [G | _], is_digit(G),
        digits(Bs8, Acc3, Rev, Rest),
        IsFloat = yes
    else
        Rev = Acc2, Rest = Bs5, IsFloat = Frac
    ).

:- pred digits(list(int)::in, list(int)::in, list(int)::out, list(int)::out)
    is det.

digits([], Acc, Acc, []).
digits([B | Bs], Acc0, Acc, Rest) :-
    ( if is_digit(B) then
        digits(Bs, [B | Acc0], Acc, Rest)
    else
        Acc = Acc0,
        Rest = [B | Bs]
    ).

%-----------------------------------------------------------------------------%
% Bytes
%-----------------------------------------------------------------------------%

:- func skip_ws(list(int)) = list(int).

skip_ws([]) = [].
skip_ws([B | Bs]) =
    ( if ( B = 0x20 ; B = 0x09 ; B = 0x0A ; B = 0x0D ) then
        skip_ws(Bs)
    else
        [B | Bs]
    ).

:- pred is_digit(int::in) is semidet.

is_digit(B) :-
    B >= 0x30, B =< 0x39.

:- func c_quote = int.
:- func c_backslash = int.
:- func c_comma = int.
:- func c_colon = int.
:- func c_minus = int.
:- func c_plus = int.
:- func c_dot = int.
:- func c_zero = int.
:- func c_e = int.
:- func c_cap_e = int.
:- func c_u = int.
:- func c_lbracket = int.
:- func c_rbracket = int.
:- func c_lbrace = int.
:- func c_rbrace = int.
:- func c_true = list(int).
:- func c_false = list(int).
:- func c_null = list(int).

c_quote = 0x22.
c_backslash = 0x5C.
c_comma = 0x2C.
c_colon = 0x3A.
c_minus = 0x2D.
c_plus = 0x2B.
c_dot = 0x2E.
c_zero = 0x30.
c_e = 0x65.
c_cap_e = 0x45.
c_u = 0x75.
c_lbracket = 0x5B.
c_rbracket = 0x5D.
c_lbrace = 0x7B.
c_rbrace = 0x7D.
c_true = [0x74, 0x72, 0x75, 0x65].
c_false = [0x66, 0x61, 0x6C, 0x73, 0x65].
c_null = [0x6E, 0x75, 0x6C, 0x6C].

%-----------------------------------------------------------------------------%
:- end_module ds.json_text.
%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.format -- rendering values as text: interpolation primitives, the bare
% renderings, Json text and a `Time`'s `to_string()`.
%
% An interpolated string arrives as primitives ([RLOW.6.4], [IARC.1.16]), so
% nothing here reads a format string. The rules are [LGRA.2.9.6.10] and
% [LGRA.2.9.6.4].
%-----------------------------------------------------------------------------%

:- module ds.format.
:- interface.

:- import_module ds.expr.
:- import_module ds.json.
:- import_module bool.
:- import_module list.

    % A value the renderer has a rule for, its kind decided by the caller:
    % `ds.eval` maps a `Time` and a `Duration` to their nanoseconds, renders
    % `null` as nothing, and raises the node's type error on any other kind.
    %
:- type renderable
    --->    r_int(int64)
    ;       r_float(float)
    ;       r_bool(bool)
    ;       r_string(string).

    % One `ValuePrim` [LGRA.2.9.6.10]. Fails when the value's kind does not take
    % a part of the spec ([LGRA.2.9.6.5]), which the caller raises as the
    % interpolation node's type error.
    %
:- pred render_value(value_prim::in, renderable::in, string::out) is semidet.

    % One `TimePrim`'s items [LGRA.2.9.6.4], over `render_time(Items, UtcNs,
    % OffsetNs)`: every field in the value's own UTC offset.
    %
:- func render_time(list(time_item), int64, int64) = string.

    % `render_iso8601(UtcNs, OffsetNs)` -- `t.to_string()` under the default
    % `"iso8601"` identifier [LTIM.8.2.1].
    %
:- func render_iso8601(int64, int64) = string.

    % `t.to_string(format)` under one of the four epoch identifiers
    % [LTIM.8.2.1], matched case-insensitively [LTIM.8.2.2]. Fails for
    % `"iso8601"`, which `render_iso8601` takes, and for anything unregistered.
    %
:- pred render_epoch(string::in, int64::in, string::out) is semidet.

    % The canonical texts, which are also what an interpolation site with no
    % spec renders.
    %
:- func bare_int(int64) = string.
:- func bare_float(float) = string.
:- func bare_bool(bool) = string.

    % A JSON string literal, quotes included, as LGRA.5.8.7a writes a string
    % inside a Json value: `/` is not escaped, non-ASCII stays raw UTF-8, control
    % characters are lowercase `\uXXXX` but for the five short forms.
    %
:- func json_string(string) = string.

    % A `String` value as JSON text, as IDSP.13.4's `String` row writes it for
    % `FN_JSON_VALUE` and a call body: `json_string` less the `\b` and `\f` short
    % forms.
    %
:- func string_value_json(string) = string.

    % A Json term as text, with no whitespace and object keys in byte order, as
    % `ds.json` stores them. Fails on a non-finite float.
    %
:- pred json_text(json::in, string::out) is semidet.

    % Days since 1970-01-01 to its proleptic Gregorian `(year, month, day)`.
    %
:- pred civil_from_days(int64::in, int64::out, int64::out, int64::out)
    is det.

    % [LTIM.8.4]'s compact form: the nonzero components, largest unit first, and no
    % sign [LTIM.8.4.2]; `0s` for zero or a negative count [LTIM.1.3.1].
    %
:- func ltim_8_4_render_duration(int64) = string.

    % `YYYY-MM-DD` [LTIM.8.2.1]; the year zero-padded to four places after any sign.
    %
:- func ltim_8_2_1_render_date(int64) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.float_text.
:- import_module char.
:- import_module float.
:- import_module int.
:- import_module int64.
:- import_module integer.
:- import_module maybe.
:- import_module pair.
:- import_module string.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%
% ValuePrim
%-----------------------------------------------------------------------------%

render_value(VP, R, Out) :-
    not (
        ( R = r_string(_) ; R = r_bool(_) ),
        ( VP ^ vp_plus = yes ; VP ^ vp_zero = yes )
    ),
    value_body(VP ^ vp_type, VP ^ vp_precision, R, IsNumber, Negative, Body),
    Sign = ( if Negative = yes then "-"
             else if VP ^ vp_plus = yes, IsNumber = yes then "+"
             else "" ),
    Used = string.count_code_units(Sign) + string.count_codepoints(Body),
    Width = uint32.cast_to_int(VP ^ vp_width),
    Pad = int.max(0, Width - Used),
    Align = VP ^ vp_align,
    Left = ( if ( Align = align_left ; Align = align_default, IsNumber = no )
             then yes else no ),
    ( if VP ^ vp_zero = yes, IsNumber = yes, Left = no then
        Out = Sign ++ string.duplicate_char('0', Pad) ++ Body
    else if Left = yes then
        Out = Sign ++ Body ++ string.duplicate_char(' ', Pad)
    else
        Out = string.duplicate_char(' ', Pad) ++ Sign ++ Body
    ).

    % The text without its sign, whether the value is a number, and whether it
    % is negative.
    %
:- pred value_body(format_type::in, maybe(uint32)::in, renderable::in,
                   bool::out, bool::out, string::out) is semidet.

value_body(ft_canonical, Prec, R, IsNumber, Negative, Body) :-
    (
        R = r_int(I),
        Prec = no,
        IsNumber = yes,
        magnitude(I, Negative, M),
        Body = string.uint64_to_string(M)
    ;
        R = r_float(F),
        Prec = no,
        IsNumber = yes,
        peel_sign(float_text.canonical(F), Negative, Body)
    ;
        R = r_bool(B),
        Prec = no,
        IsNumber = no,
        Negative = no,
        Body = bare_bool(B)
    ;
        R = r_string(S),
        IsNumber = no,
        Negative = no,
        Body = keep_codepoints(Prec, S)
    ).
value_body(ft_d, no, r_int(I), yes, Negative, string.uint64_to_string(M)) :-
    magnitude(I, Negative, M).
value_body(ft_x_lower, no, r_int(I), yes, Negative,
        string.uint64_to_lc_hex_string(M)) :-
    magnitude(I, Negative, M).
value_body(ft_x_upper, no, r_int(I), yes, Negative,
        string.to_upper(string.uint64_to_lc_hex_string(M))) :-
    magnitude(I, Negative, M).
value_body(ft_b, no, r_int(I), yes, Negative, binary_text(M)) :-
    magnitude(I, Negative, M).
value_body(ft_f, Prec, R, yes, Negative, Body) :-
    ( R = r_float(F)
    ; R = r_int(I), F = float.cast_from_int64(I)
    ),
    Digits = ( if Prec = yes(P) then uint32.cast_to_int(P) else 6 ),
    peel_sign(float_text.fixed(F, Digits), Negative, Body).
value_body(ft_s, Prec, r_string(S), no, no, keep_codepoints(Prec, S)).

    % An Int's magnitude, unsigned so `min_int64` has one.
    %
:- pred magnitude(int64::in, bool::out, uint64::out) is det.

magnitude(I, Negative, M) :-
    U = uint64.cast_from_int64(I),
    ( if I < 0i64 then
        Negative = yes,
        M = 0u64 - U
    else
        Negative = no,
        M = U
    ).

    % A Float's text carries the sign of every value but NaN ([LCST.4.5.6]),
    % `-0.0` included.
    %
:- pred peel_sign(string::in, bool::out, string::out) is det.

peel_sign(Text, Negative, Body) :-
    ( if string.remove_prefix("-", Text, Rest) then
        Negative = yes,
        Body = Rest
    else
        Negative = no,
        Body = Text
    ).

:- func keep_codepoints(maybe(uint32), string) = string.

keep_codepoints(no, S) = S.
keep_codepoints(yes(P), S) = string.left_by_codepoint(S, uint32.cast_to_int(P)).

:- func binary_text(uint64) = string.

binary_text(M) = string.from_char_list(binary_chars(M, [])).

:- func binary_chars(uint64, list(char)) = list(char).

binary_chars(M, Acc0) = Acc :-
    Bit = ( if M /\ 1u64 = 1u64 then '1' else '0' ),
    Rest = M >> 1,
    ( if Rest = 0u64 then
        Acc = [Bit | Acc0]
    else
        Acc = binary_chars(Rest, [Bit | Acc0])
    ).

%-----------------------------------------------------------------------------%
% TimePrim
%-----------------------------------------------------------------------------%

render_time(Items, UtcNs, OffsetNs) =
        string.append_list(list.map(time_item_text(Fields), Items)) :-
    Fields = civil_fields(UtcNs, OffsetNs).

    % One instant's calendar fields in its own offset. Floor throughout, so an
    % instant before the epoch keeps a non-negative fraction and second of the day.
    %
    % The wall clock is never formed as `UtcNs + OffsetNs`, which can leave int64
    % ([LTIM.8.2.4]): only the two remainders in [0, day) are added.
    %
:- type civil
    --->    civil(
                cv_year   :: int64,
                cv_month  :: int64,
                cv_day    :: int64,
                cv_sod    :: int64,
                cv_frac   :: int64,
                cv_offset :: int64
            ).

:- func civil_fields(int64, int64) = civil.

civil_fields(UtcNs, OffsetNs) = civil(Y, Mo, D, Sod, Frac, OffsetS) :-
    Day = 86400000000000i64,
    OffsetS = OffsetNs // 1000000000i64,
    Local = floor_mod64(UtcNs, Day) + floor_mod64(OffsetNs, Day),
    Days = floor_div64(UtcNs, Day) + floor_div64(OffsetNs, Day)
        + floor_div64(Local, Day),
    NsOfDay = floor_mod64(Local, Day),
    Sod = NsOfDay // 1000000000i64,
    Frac = NsOfDay rem 1000000000i64,
    civil_from_days(Days, Y, Mo, D).

:- func time_item_text(civil, time_item) = string.

time_item_text(_, ti_text(Text)) = Text.
time_item_text(C, ti_field(Field)) = Text :-
    (
        Field = tf_year,
        Text = zpad(C ^ cv_year, 4)
    ;
        Field = tf_month,
        Text = zpad(C ^ cv_month, 2)
    ;
        Field = tf_day,
        Text = zpad(C ^ cv_day, 2)
    ;
        Field = tf_hour,
        Text = zpad(C ^ cv_sod // 3600i64, 2)
    ;
        Field = tf_minute,
        Text = zpad((C ^ cv_sod mod 3600i64) // 60i64, 2)
    ;
        Field = tf_second,
        Text = zpad(C ^ cv_sod mod 60i64, 2)
    ;
        Field = tf_microsecond,
        % The nanoseconds below the microsecond are truncated, never rounded.
        Text = zpad(C ^ cv_frac // 1000i64, 6)
    ;
        Field = tf_utc_offset,
        % `+HHMM`, and `SS` after it only when the offset has seconds.
        Off = C ^ cv_offset,
        Abs = ( if Off < 0i64 then 0i64 - Off else Off ),
        Seconds = ( if Abs mod 60i64 = 0i64 then ""
                    else zpad(Abs mod 60i64, 2) ),
        Text = ( if Off < 0i64 then "-" else "+" )
            ++ zpad(Abs // 3600i64, 2) ++ zpad((Abs mod 3600i64) // 60i64, 2)
            ++ Seconds
    ).

%-----------------------------------------------------------------------------%
% to_string
%-----------------------------------------------------------------------------%

    % The local wall clock, then the offset, or `Z` when it is zero [LTIM.8.2.1]. A
    % nonzero sub-second part is `.` and nine digits with trailing zeros trimmed.
    %
render_iso8601(UtcNs, OffsetNs) = Out :-
    C = civil_fields(UtcNs, OffsetNs),
    Sod = C ^ cv_sod,
    Stamp = zpad(C ^ cv_year, 4) ++ "-" ++ zpad(C ^ cv_month, 2) ++ "-"
        ++ zpad(C ^ cv_day, 2) ++ "T" ++ zpad(Sod // 3600i64, 2) ++ ":"
        ++ zpad((Sod mod 3600i64) // 60i64, 2) ++ ":" ++ zpad(Sod mod 60i64, 2),
    ( if C ^ cv_frac = 0i64 then
        Fraction = ""
    else
        Fraction = "." ++ trim_zeros(zpad(C ^ cv_frac, 9))
    ),
    OffsetS = C ^ cv_offset,
    ( if OffsetS = 0i64 then
        Zone = "Z"
    else
        Abs = ( if OffsetS < 0i64 then 0i64 - OffsetS else OffsetS ),
        Zone = ( if OffsetS < 0i64 then "-" else "+" )
            ++ zpad(Abs // 3600i64, 2) ++ ":"
            ++ zpad((Abs mod 3600i64) // 60i64, 2)
    ),
    Out = Stamp ++ Fraction ++ Zone.

    % Floor, not truncation [LTIM.8.2.1a]: `-1500` ns is `-2` micros.
    %
render_epoch(Format, UtcNs, Out) :-
    Id = string.to_lower(Format),
    (
        Id = "epoch_seconds",
        Out = bare_int(floor_div64(UtcNs, 1000000000i64))
    ;
        Id = "epoch_millis",
        Out = bare_int(floor_div64(UtcNs, 1000000i64))
    ;
        Id = "epoch_micros",
        Out = bare_int(floor_div64(UtcNs, 1000i64))
    ;
        Id = "epoch_nanos",
        Out = bare_int(UtcNs)
    ).

:- func trim_zeros(string) = string.

trim_zeros(Digits) =
    ( if
        string.remove_suffix(Digits, "0", Shorter),
        Shorter \= ""
    then
        trim_zeros(Shorter)
    else
        Digits
    ).

%-----------------------------------------------------------------------------%
% Bare renderings and Json text
%-----------------------------------------------------------------------------%

bare_int(N) = string.int64_to_string(N).

bare_float(F) = float_text.canonical(F).

bare_bool(yes) = "true".
bare_bool(no) = "false".

json_string(S) =
    "\"" ++ string.append_list(list.map(json_char, string.to_char_list(S)))
        ++ "\"".

string_value_json(S) =
    "\"" ++ string.append_list(list.map(string_value_char,
        string.to_char_list(S))) ++ "\"".

:- func string_value_char(char) = string.

string_value_char(C) =
    ( if ( C = ('\b') ; C = ('\f') ) then hex_escape(C) else json_char(C) ).

:- func json_char(char) = string.

json_char(C) = Out :-
    ( if C = ('"') then
        Out = "\\\""
    else if C = ('\\') then
        Out = "\\\\"
    else if C = ('\n') then
        Out = "\\n"
    else if C = ('\r') then
        Out = "\\r"
    else if C = ('\t') then
        Out = "\\t"
    else if C = ('\b') then
        Out = "\\b"
    else if C = ('\f') then
        Out = "\\f"
    else if char.to_int(C) < 0x20 then
        Out = hex_escape(C)
    else
        Out = string.char_to_string(C)
    ).

    % `\u` and four lowercase hex digits (LGRA.5.8.7a).
    %
:- func hex_escape(char) = string.

hex_escape(C) = "\\u" ++ string.pad_left(Hex, '0', 4) :-
    Hex = string.to_lower(string.int_to_base_string(char.to_int(C), 16)).

json_text(J, Text) :-
    (
        J = j_null,
        Text = "null"
    ;
        J = j_bool(B),
        Text = bare_bool(B)
    ;
        J = j_int(I),
        Text = bare_int(I)
    ;
        J = j_float(F),
        not float.is_nan_or_inf(F),
        Text = bare_float(F)
    ;
        J = j_string(S),
        Text = json_string(S)
    ;
        J = j_array(Es),
        list.map(json_text, Es, Ts),
        Text = "[" ++ string.join_list(",", Ts) ++ "]"
    ;
        J = j_object(Ms),
        list.map(member_text, members(Ms), Ts),
        Text = "{" ++ string.join_list(",", Ts) ++ "}"
    ).

:- pred member_text(pair(string, json)::in, string::out) is semidet.

member_text(Key - Value, json_string(Key) ++ ":" ++ Text) :-
    json_text(Value, Text).

%-----------------------------------------------------------------------------%
% Integer helpers
%-----------------------------------------------------------------------------%

    % printf's `%0<width>lld`: zeros after the sign, the sign counting toward the
    % width; a value wider than the width is written whole.
    %
:- func zpad(int64, int) = string.

zpad(V, Width) = Sign ++ string.duplicate_char('0', Fill) ++ Digits :-
    magnitude(V, Negative, M),
    Digits = string.uint64_to_string(M),
    Sign = ( if Negative = yes then "-" else "" ),
    Fill = int.max(0, Width - string.count_code_units(Sign)
        - string.count_code_units(Digits)).

    % Floor division, which is not Mercury's `//` for negative operands.
    %
:- func floor_div64(int64, int64) = int64.

floor_div64(A, B) = Q :-
    Q0 = A // B,
    R = A rem B,
    ( if ( R < 0i64, B > 0i64 ; R > 0i64, B < 0i64 ) then
        Q = Q0 - 1i64
    else
        Q = Q0
    ).

    % Floor modulus, in [0, B) for B > 0. From `rem`, since
    % `A - floor_div64(A, B) * B` can leave int64.
    %
:- func floor_mod64(int64, int64) = int64.

floor_mod64(A, B) = M :-
    R = A rem B,
    M = ( if R < 0i64 then R + B else R ).

    % Howard Hinnant's `civil_from_days`.
    %
civil_from_days(Days, Y, Mo, D) :-
    Z = Days + 719468i64,
    Era = ( if Z >= 0i64 then Z else Z - 146096i64 ) // 146097i64,
    DoE = Z - Era * 146097i64,
    YoE = (DoE - DoE // 1460i64 + DoE // 36524i64 - DoE // 146096i64)
        // 365i64,
    Y0 = YoE + Era * 400i64,
    DoY = DoE - (365i64 * YoE + YoE // 4i64 - YoE // 100i64),
    Mp = (5i64 * DoY + 2i64) // 153i64,
    D = DoY - (153i64 * Mp + 2i64) // 5i64 + 1i64,
    Mo = ( if Mp < 10i64 then Mp + 3i64 else Mp - 9i64 ),
    Y = ( if Mo =< 2i64 then Y0 + 1i64 else Y0 ).

    % [LTIM.8.4]'s units, largest first.
    %
:- func ltim_8_4_units = list({string, int64}).

ltim_8_4_units = [
    {"h", 3600000000000i64},
    {"m", 60000000000i64},
    {"s", 1000000000i64},
    {"ms", 1000000i64},
    {"us", 1000i64},
    {"ns", 1i64}
].

ltim_8_4_render_duration(Ns) = Out :-
    ( if Ns =< 0i64 then
        Out = "0s"
    else
        Out = string.append_list(ltim_8_4_parts(ltim_8_4_units,
            integer.from_int64(Ns)))
    ).

:- func ltim_8_4_parts(list({string, int64}), integer) = list(string).

ltim_8_4_parts([], _) = [].
ltim_8_4_parts([{Sym, Ns} | Units], Magnitude) = Parts :-
    U = integer.from_int64(Ns),
    Q = Magnitude // U,
    Rest = ltim_8_4_parts(Units, Magnitude - Q * U),
    ( if Q = integer.zero then
        Parts = Rest
    else
        Parts = [integer.to_string(Q) ++ Sym | Rest]
    ).

ltim_8_2_1_render_date(Days) =
        ltim_zpad(Y, 4) ++ "-" ++ ltim_zpad(M, 2) ++ "-" ++ ltim_zpad(D, 2) :-
    civil_from_days(Days, Y, M, D).

:- func ltim_zpad(int64, int) = string.

ltim_zpad(V, Width) = Sign ++ string.pad_left(Digits, '0', Width - string.length(Sign)) :-
    ( if V < 0i64 then
        Sign = "-",
        Digits = integer.to_string(-integer.from_int64(V))
    else
        Sign = "",
        Digits = integer.to_string(integer.from_int64(V))
    ).

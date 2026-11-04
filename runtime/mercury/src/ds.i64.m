% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.i64 -- the DS `Int` operations Mercury's `int64` module does not provide.
%
% A DS `Int` is 64-bit two's complement and wraps [LEXP.7.13.1, LDET.3.2.2], so
% it is held as `int64`, never as Mercury `int`, which is 32 bits on a 32-bit
% target. Everything here is written against `int64` or `integer`.
%-----------------------------------------------------------------------------%

:- module ds.i64.
:- interface.

    % `B ** E` for `E >= 0`, wrapping. `E < 0` answers 1; refusing it is the
    % caller's.
    %
:- func pow(int64, int64) = int64.

    % Truncate a float toward zero. Fails for NaN, an infinity, or a value
    % whose truncation lies outside `[-2^63, 2^63)`.
    %
:- pred truncate_float(float::in, int64::out) is semidet.

    % `truncate_float` where it succeeds; otherwise C's undefined conversion.
    %
:- func truncate_float_as_before(float) = int64.

:- func to_float(int64) = float.

    % Decimal text to `Int`: an optional sign, then one or more ASCII digits.
    % Fails on anything else or outside the `int64` range.
    %
:- pred from_decimal(string::in, int64::out) is semidet.

    % Digits in `Base` (2..36), no sign, one or more, either letter case. Fails on
    % anything else or outside the `int64` range.
    %
:- pred from_base_digits(int::in, string::in, int64::out) is semidet.

    % `String::Int?` ([LCST.4.5.7]): an optional sign and an INT_LIT as a source
    % literal spells it ([LLEX.11.1]). Fails on anything else and outside the
    % `int64` range.
    %
:- pred from_literal(string::in, int64::out) is semidet.

:- func to_string(int64) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module char.
:- import_module float.
:- import_module int64.
:- import_module integer.
:- import_module list.
:- import_module math.
:- import_module string.

pow(B, E) = pow_loop(B, E, 1i64).

:- func pow_loop(int64, int64, int64) = int64.

pow_loop(B, E, Acc) =
    ( if E =< 0i64 then
        Acc
    else if int64.odd(E) then
        pow_loop(B * B, E // 2i64, Acc * B)
    else
        pow_loop(B * B, E // 2i64, Acc)
    ).

truncate_float(F, I) :-
    not float.is_nan_or_inf(F),
    T = math.truncate(F),
    T >= -9223372036854775808.0,
    T < 9223372036854775808.0,
    Hi = math.floor(T / 4398046511104.0),           % 2^42
    R = T - Hi * 4398046511104.0,
    Mid = math.floor(R / 2097152.0),                % 2^21
    Lo = R - Mid * 2097152.0,
    I = int64.from_int(float.truncate_to_int(Hi)) * 4398046511104i64
      + int64.from_int(float.truncate_to_int(Mid)) * 2097152i64
      + int64.from_int(float.truncate_to_int(Lo)).

truncate_float_as_before(F) =
    ( if truncate_float(F, I) then
        I
    else
        int64.cast_from_int(float.truncate_to_int(F))
    ).

to_float(I) = float.cast_from_int64(I).

from_decimal(S, I) :-
    string.to_char_list(S, Cs),
    ( if Cs = ['-' | Ds] then
        Neg = yes_neg, Digits = Ds
    else if Cs = ['+' | Ds] then
        Neg = no_neg, Digits = Ds
    else
        Neg = no_neg, Digits = Cs
    ),
    Digits = [_ | _],
    list.foldl(digit_acc, Digits, integer.zero, Mag),
    Value = ( if Neg = yes_neg then -Mag else Mag ),
    integer.to_int64(Value, I).

:- type sign ---> yes_neg ; no_neg.

:- pred digit_acc(char::in, integer::in, integer::out) is semidet.

digit_acc(C, Acc, Acc * integer(10) + integer(D)) :-
    char.decimal_digit_to_int(C, D).

from_literal(S, I) :-
    string.to_char_list(S, Cs0),
    ( if Cs0 = ['-' | Cs1] then
        Neg = yes_neg, Body = Cs1
    else if Cs0 = ['+' | Cs1] then
        Neg = no_neg, Body = Cs1
    else
        Neg = no_neg, Body = Cs0
    ),
    ( if Body = ['0', P | Ds], literal_prefix(P, B) then
        Base = B, Digits = Ds
    else
        Base = 10, Digits = Body
    ),
    llex_11_1_separated(Digits),
    list.foldl(literal_digit_acc(Base), Digits, integer.zero, Mag),
    Value = ( if Neg = yes_neg then -Mag else Mag ),
    integer.to_int64(Value, I).

    % [LLEX.11.1]'s `DIGIT ('_'? DIGIT)*`, for the `_`s alone: a non-`_`
    % first, and every `_` followed by a non-`_`, so none starts, ends or
    % doubles. `literal_digit_acc` then refuses any non-`_` that is no digit
    % of the base, which makes each `_` sit between two digits.
    %
:- pred llex_11_1_separated(list(char)::in) is semidet.

llex_11_1_separated([C | Cs]) :-
    C \= ('_'),
    separated_tail(Cs).

:- pred separated_tail(list(char)::in) is semidet.

separated_tail([]).
separated_tail([C | Cs]) :-
    ( if C = ('_') then
        Cs = [D | Ds],
        D \= ('_'),
        separated_tail(Ds)
    else
        separated_tail(Cs)
    ).

:- pred literal_prefix(char::in, int::out) is semidet.

literal_prefix('x', 16).
literal_prefix('b', 2).
literal_prefix('o', 8).

:- pred literal_digit_acc(int::in, char::in, integer::in, integer::out)
    is semidet.

literal_digit_acc(Base, C, Acc0, Acc) :-
    ( if C = ('_') then
        Acc = Acc0
    else
        char.is_alnum(C),
        char.base_digit_to_int(Base, C, D),
        Acc = Acc0 * integer(Base) + integer(D)
    ).

from_base_digits(Base, S, I) :-
    string.to_char_list(S, Cs),
    Cs = [_ | _],
    list.foldl(base_digit_acc(Base), Cs, integer.zero, Value),
    integer.to_int64(Value, I).

:- pred base_digit_acc(int::in, char::in, integer::in, integer::out)
    is semidet.

base_digit_acc(Base, C, Acc, Acc * integer(Base) + integer(D)) :-
    char.base_digit_to_int(Base, C, D).

to_string(I) = string.int64_to_string(I).

%-----------------------------------------------------------------------------%

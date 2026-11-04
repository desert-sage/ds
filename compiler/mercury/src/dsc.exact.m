% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.exact -- exact rational arithmetic for the values the compiler folds into
% a bundle ([LDET.3.3a.7]).
%
% A fold is carried in rationals and rounded once, at the end, to the nearest
% binary64 with ties to even. The host's floats are touched only where they
% cannot round: `to_float` builds an integer mantissa below 2^53, then applies
% a power of two one exact doubling or halving at a time.
%
% A zero has no sign here, so `-0.0` cannot come out of a fold.
%-----------------------------------------------------------------------------%
:- module dsc.exact.
:- interface.

:- import_module bool.
:- import_module int64.
:- import_module integer.

    % A reduced fraction with a positive denominator.
    %
    %@helper
:- type rational.

    %@helper
:- func from_integer(integer) = rational.
    %@helper
:- func from_int64(int64) = rational.

    % A decimal numeral, with no sign on the mantissa and no `_` separators.
    % Fails on anything else, and on an exponent outside ±1000.
    %
    %@helper
:- pred from_decimal(string::in, rational::out) is semidet.

    % The exact value of a finite binary64. Fails on an infinity or a NaN.
    %
    %@helper
:- pred from_float(float::in, rational::out) is semidet.

    % The exact value of the binary64 nearest π ([LUNI.2.6]).
    %
    %@helper
:- func pi = rational.

    %@helper
:- func negate(rational) = rational.
    %@helper
:- func add(rational, rational) = rational.
    %@helper
:- func sub(rational, rational) = rational.
    %@helper
:- func mul(rational, rational) = rational.

    % Fails on a zero divisor ([LDET.6.3.1]).
    %
    %@helper
:- pred divide(rational::in, rational::in, rational::out) is semidet.

    % `Base ** Exponent`. Fails on a non-integral exponent ([LDET.3.4.4]), on
    % `0 ** negative`, and on an exponent outside ±4096.
    %
    %@helper
:- pred int_pow(rational::in, rational::in, rational::out) is semidet.

    % The nearest binary64, ties to even. Fails when the value rounds past the
    % largest finite double.
    %
    %@helper
:- pred to_float(rational::in, float::out) is semidet.

    % A decimal literal's value would round to an infinity. `Text` is the
    % literal with its separators stripped, its exponent of any size. Fails on
    % any other text, and on a value inside the range.
    %
    %@spec [LLEX.11.2.4]
:- pred llex_11_2_4_past_largest(string::in) is semidet.

    % Truncated toward zero, then wrapped ([LEXP.7.13.1]).
    %
    %@helper
:- func truncate_wrapping_int64(rational) = int64.

    % -1, 0 or 1.
    %
    %@helper
:- func sign(rational) = int.

    %@helper
:- func compare_rational(rational, rational) = comparison_result.

    %@helper
:- func floor_integer(rational) = integer.
    %@helper
:- func truncate_integer(rational) = integer.

    %@helper
:- pred to_integer(rational::in, integer::out) is semidet.

    % An integer wrapped to 64-bit two's complement ([LEXP.7.13.1]).
    %
    %@helper
:- func wrap_int64(integer) = int64.

    % IEEE 754's `sqrt` ([LEXP.3.2]), found in integers. Fails on a value that
    % is not positive.
    %
    %@helper
:- pred sqrt_to_float(rational::in, float::out) is semidet.

    % `yes` for `-0.0` and every negative value.
    %
    %@helper
:- func sign_bit(float) = bool.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module char.
:- import_module float.
:- import_module int.
:- import_module math.
:- import_module require.
:- import_module string.

:- type rational
    --->    rational(integer, integer).     % numerator, denominator > 0, coprime

    % The denominator is non-zero at every call site.
    %
:- func make(integer, integer) = rational.

make(N0, D0) = rational(N, D) :-
    ( if D0 < integer.zero then
        N1 = -N0,
        D1 = -D0
    else
        N1 = N0,
        D1 = D0
    ),
    G = gcd(integer.abs(N1), D1),
    N = N1 // G,
    D = D1 // G.

    % Both arguments non-negative, the second positive at the top call.
    %
:- func gcd(integer, integer) = integer.

gcd(A, B) = ( if integer.is_zero(B) then A else gcd(B, A rem B) ).

:- func two_pow(int) = integer.

two_pow(N) = integer.one << N.

:- func ten_pow(int) = integer.

ten_pow(N) = integer.pow(integer.ten, integer.integer(N)).

from_integer(I) = rational(I, integer.one).

from_int64(I) = from_integer(integer.from_int64(I)).

%-----------------------------------------------------------------------------%

from_decimal(Text, R) :-
    S = string.to_lower(Text),
    ( if string.sub_string_search(S, "e", At) then
        string.split(S, At, Mantissa, ExpPart),
        string.remove_prefix("e", ExpPart, ExpText0),
        ( if string.remove_prefix("+", ExpText0, ExpText1) then
            ExpText = ExpText1
        else
            ExpText = ExpText0
        ),
        string.to_int(ExpText, Exp),
        Exp >= -1000,
        Exp =< 1000
    else
        Mantissa = S,
        Exp = 0
    ),
    ( if string.sub_string_search(Mantissa, ".", Dot) then
        string.split(Mantissa, Dot, Whole, DotFraction),
        string.remove_prefix(".", DotFraction, Fraction)
    else
        Whole = Mantissa,
        Fraction = ""
    ),
    Digits = Whole ++ Fraction,
    Digits \= "",
    string.all_match(char.is_digit, Digits),
    integer.from_string(Digits, M),
    Scale = Exp - string.length(Fraction),
    ( if Scale >= 0 then
        R = from_integer(M * ten_pow(Scale))
    else
        R = make(M, ten_pow(-Scale))
    ).

    % `float64_bits_string` gives the bit pattern as a signed decimal.
    %
from_float(F, R) :-
    not float.is_nan_or_inf(F),
    integer.from_string(float.float64_bits_string(F), Signed),
    ( if Signed < integer.zero then
        Bits = Signed + two_pow(64)
    else
        Bits = Signed
    ),
    Exponent = integer.det_to_int((Bits >> 52) /\ integer.integer(0x7ff)),
    Fraction = Bits /\ (two_pow(52) - integer.one),
    ( if Exponent = 0 then
        % Subnormal, or zero: no implicit leading bit.
        Magnitude = make(Fraction, two_pow(1074))
    else
        Significand = two_pow(52) + Fraction,
        Power = Exponent - 1075,
        ( if Power >= 0 then
            Magnitude = from_integer(Significand * two_pow(Power))
        else
            Magnitude = make(Significand, two_pow(-Power))
        )
    ),
    ( if Bits >= two_pow(63) then
        R = negate(Magnitude)
    else
        R = Magnitude
    ).

pi = R :-
    ( if from_float(math.pi, R0) then
        R = R0
    else
        unexpected($pred, "math.pi is not a finite binary64")
    ).

%-----------------------------------------------------------------------------%

negate(rational(N, D)) = rational(-N, D).

add(rational(A, B), rational(C, D)) = make(A * D + C * B, B * D).

sub(X, Y) = add(X, negate(Y)).

mul(rational(A, B), rational(C, D)) = make(A * C, B * D).

divide(rational(A, B), rational(C, D), R) :-
    not integer.is_zero(C),
    R = make(A * D, B * C).

int_pow(rational(A, B), rational(N, D), R) :-
    integer.is_zero(D - integer.one),
    integer.to_int(N, K),
    K >= -4096,
    K =< 4096,
    ( if K >= 0 then
        R = make(integer.pow(A, integer.integer(K)),
                 integer.pow(B, integer.integer(K)))
    else
        not integer.is_zero(A),
        R = make(integer.pow(B, integer.integer(-K)),
                 integer.pow(A, integer.integer(-K)))
    ).

%-----------------------------------------------------------------------------%
% Rounding to binary64
%-----------------------------------------------------------------------------%

    % For a positive P/Q: pick the binary exponent E that puts P/Q * 2^-E in
    % [2^52, 2^53), clamp it at -1074 for a subnormal, divide, and round the
    % remainder half to even. A carry to 2^53 moves the exponent up one.
    %
    % Largest finite double: (2^53 - 1) * 2^971. An exponent past 971 after
    % rounding is an overflow, and fails rather than answering an infinity.
    %
to_float(rational(N, D), F) :-
    ( if integer.is_zero(N) then
        F = 0.0
    else
        ( if N < integer.zero then
            Negative = yes,
            P = -N
        else
            Negative = no,
            P = N
        ),
        normalise(P, D, bit_length(P) - bit_length(D) - 53, E1),
        E2 = int.max(E1, -1074),
        scaled(P, D, E2, Num, Den),
        integer.divide_with_rem(Num, Den, M0, Rem),
        Twice = Rem * integer.two,
        ( if
            ( Twice > Den
            ; not (Twice < Den), not integer.is_zero(M0 /\ integer.one)
            )
        then
            M1 = M0 + integer.one
        else
            M1 = M0
        ),
        ( if not (M1 < two_pow(53)) then
            M = two_pow(52),
            E = E2 + 1
        else
            M = M1,
            E = E2
        ),
        E =< 971,
        Magnitude = scale2(integer.float(M), E),
        ( Negative = yes, F = -Magnitude
        ; Negative = no, F = Magnitude
        )
    ).

    % Binary64 rounds a value to infinity exactly when it is at least
    % 2^1024 - 2^970, the midpoint between the largest finite double and 2^1024,
    % where the tie goes to the even neighbour. The bounds on `Scale` keep the
    % exact comparison from building a huge power of ten.
    %
llex_11_2_4_past_largest(Text) :-
    S = string.to_lower(Text),
    ( if string.sub_string_search(S, "e", At) then
        string.split(S, At, Mantissa, ExpPart),
        string.remove_prefix("e", ExpPart, ExpText0),
        ( if string.remove_prefix("+", ExpText0, ExpText1) then
            ExpText = ExpText1
        else
            ExpText = ExpText0
        ),
        integer.from_string(ExpText, Exp)
    else
        Mantissa = S,
        Exp = integer.zero
    ),
    ( if string.sub_string_search(Mantissa, ".", Dot) then
        string.split(Mantissa, Dot, Whole, DotFraction),
        string.remove_prefix(".", DotFraction, Fraction)
    else
        Whole = Mantissa,
        Fraction = ""
    ),
    Digits = Whole ++ Fraction,
    Digits \= "",
    string.all_match(char.is_digit, Digits),
    integer.from_string(Digits, M),
    not integer.is_zero(M),
    Scale = Exp - integer.integer(string.length(Fraction)),
    Width = integer.integer(string.length(integer.to_string(M))),
    ( if Scale > integer.integer(400) then
        true
    else if Scale + Width < integer.integer(-400) then
        fail
    else
        Threshold = two_pow(1024) - two_pow(970),
        Ten = integer.integer(10),
        ( if Scale >= integer.zero then
            M * integer.pow(Ten, Scale) >= Threshold
        else
            M >= Threshold * integer.pow(Ten, -Scale)
        )
    ).

    % Adjust the estimate until 2^52 =< P/Q * 2^-E < 2^53. The bit-length
    % estimate is within one or two of the answer, so this runs at most twice.
    %
:- pred normalise(integer::in, integer::in, int::in, int::out) is det.

normalise(P, Q, E0, E) :-
    scaled(P, Q, E0, Num, Den),
    ( if not (Num < two_pow(53) * Den) then
        normalise(P, Q, E0 + 1, E)
    else if Num < two_pow(52) * Den then
        normalise(P, Q, E0 - 1, E)
    else
        E = E0
    ).

    % P/Q * 2^-E as a fraction of two integers, shifting whichever side keeps
    % the shift non-negative.
    %
:- pred scaled(integer::in, integer::in, int::in, integer::out, integer::out)
    is det.

scaled(P, Q, E, Num, Den) :-
    ( if E >= 0 then
        Num = P,
        Den = Q << E
    else
        Num = P << (-E),
        Den = Q
    ).

    % Positive only.
    %
:- func bit_length(integer) = int.

bit_length(I) = string.length(integer.to_base_string(I, 2)).

:- func scale2(float, int) = float.

scale2(X, E) =
    ( if E > 0 then
        scale2(X * 2.0, E - 1)
    else if E < 0 then
        scale2(X * 0.5, E + 1)
    else
        X
    ).

%-----------------------------------------------------------------------------%

truncate_wrapping_int64(R) = wrap_int64(truncate_integer(R)).

wrap_int64(T) = I :-
    Modulus = two_pow(64),
    W0 = T rem Modulus,
    W1 = ( if W0 < integer.zero then W0 + Modulus else W0 ),
    W = ( if W1 >= two_pow(63) then W1 - Modulus else W1 ),
    I = integer.det_to_int64(W).

sign(rational(N, _)) =
    ( if N < integer.zero then -1
    else if integer.is_zero(N) then 0
    else 1 ).

compare_rational(X, Y) = Order :-
    S = sign(sub(X, Y)),
    ( if S < 0 then Order = (<)
    else if S > 0 then Order = (>)
    else Order = (=) ).

floor_integer(rational(N, D)) = integer.div(N, D).

truncate_integer(rational(N, D)) = T :-
    Magnitude = integer.abs(N) // D,
    T = ( if N < integer.zero then -Magnitude else Magnitude ).

to_integer(rational(N, D), N) :-
    D = integer.one.

    % For P/Q > 0: scale by an even power of two, 2^(2K), so the integer part
    % T of P/Q * 2^(2K) has at least 110 bits; then S = isqrt(T) has at least
    % 55, and sqrt(P/Q) * 2^K lies in [S, S + 1). With two bits below the 53
    % a double keeps, a rounding boundary of the result falls on an even
    % multiple of S's last bit, so it cannot fall strictly inside (S, S + 1):
    % an inexact root rounds as S + 1/2 does. Exact when T is S squared and
    % the scaling lost nothing.
    %
sqrt_to_float(R, F) :-
    R = rational(P, Q),
    P > integer.zero,
    Shift = 112 - (bit_length(P) - bit_length(Q)),
    K = ( if Shift > 0 then (Shift + 1) // 2 else 0 ) + 1,
    T = integer.div(P * two_pow(2 * K), Q),
    S = isqrt(T),
    ( if S * S = T, integer.is_zero(integer.rem(P * two_pow(2 * K), Q)) then
        Root = make(S, two_pow(K))
    else
        Root = make(S * integer.two + integer.one, two_pow(K + 1))
    ),
    to_float(Root, F).

    % The integer square root, floor(sqrt(N)), by Newton's iteration from
    % above. N non-negative.
    %
:- func isqrt(integer) = integer.

isqrt(N) = Root :-
    ( if N < integer.two then
        Root = N
    else
        isqrt_from(N, two_pow((bit_length(N) + 1) // 2 + 1), Root)
    ).

:- pred isqrt_from(integer::in, integer::in, integer::out) is det.

isqrt_from(N, X, Root) :-
    Y = (X + N // X) // integer.two,
    ( if Y < X then
        isqrt_from(N, Y, Root)
    else
        Root = X
    ).

sign_bit(F) = B :-
    ( if
        integer.from_string(float.float64_bits_string(F), Signed),
        Signed < integer.zero
    then
        B = yes
    else
        B = no
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.exact.
%-----------------------------------------------------------------------------%

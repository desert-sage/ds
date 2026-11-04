// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [LCST.4.5] [LERR.1.4.10] [LDET.3.2.7] [LDET.3.2.8] [LLEX.11.2]
//
// dscast.k -- the DS `::` conversion-cast reduction as EXECUTABLE operational
// semantics (K Framework). The sole runtime conversion surface of DS, run here so
// its corner cases -- above all the Float→Int TRAP -- are executable, not just
// prose.
//
// NORMATIVE COMPANION. Formalizes the runtime half of [LCST.4.5]:
//   * [LCST.4.5.2] Int→Float widening; Int/Float/Bool→String render; String→Bool?
//     parse ([LCST.4.5.5]: only "true"/"false", else null); String→Int? parse
//     ([LCST.4.5.7]: an optional sign then an INT_LIT of [LLEX.11.1] -- decimal,
//     0x, 0b, 0o, both digit cases for hex, a `_` separator only before a digit
//     as [LLEX.12.1] places one -- the signed value in the 64-bit range, else
//     null: whitespace, a decimal point or exponent, a unit suffix, a trailing
//     or leading or post-prefix separator, an uppercase prefix, a value outside
//     the range, the empty string). formal/idris/Rete/Eval.idr carries the same
//     parse (`lcst_4_5_7__parse_int`) and the two are kept in step by hand.
//   * [LCST.4.5.8] String→Float? parse: the whole string an optional sign then an
//     INT_LIT in the 64-bit range, a FLOAT_LIT of [LLEX.11.2] (both sides of the
//     point, the exponent required on the bare form, a `_` only between two
//     digits as [LLEX.11.1] places one) or `inf`, to the NEAREST
//     double, ties to even ([LDET.3.2.8]: the decimal as an exact fraction in K's
//     bignum Ints, the binary exponent at which its quotient has 53 bits, the
//     remainder against a half), a zero keeping the sign it was spelt with;
//     null for every other string, a finite spelling that rounds past the
//     largest double included. Eval.idr's `lcst_4_5_8__parse_float` and
//     `ldet_3_2_8__nearest` are the same algorithm; kept in step by hand, and
//     run, not proved, on both sides. K's Float carries no
//     subnormal, so a value below 2^-1022 is outside this file and the vectors
//     stay in the normal range.
//   * [LCST.4.5.6] / [LDET.3.2.7] Float→String render: `nan`, `inf`, `-inf`, the
//     signed zeros, else the SHORTEST decimal that parses back to the same
//     double -- the double decomposed by exact halvings and doublings, a search
//     from one significant digit to seventeen that tests the two grid
//     neighbours at each length by the parse's own rounding and takes the
//     nearer, the even last digit at a tie -- in the clause's shape: `.0` kept
//     on a whole value, fixed notation from 1e-4 to below 1e16, scientific
//     outside it with a lowercase `e`, a signed exponent of at least two digits,
//     and no `.0` on a one-digit scientific mantissa (`1e+16`, as the clause
//     states; Eval.idr's `ldet_3_2_7__shape`).
//     Transcribed from Eval.idr's `lcst_4_5_6__render_float`; K's own
//     `Float2String` prints K's form and is not used.
//   * [LCST.4.3.1] a nullable source under a total conversion (`x::T?` with `x`
//     a `T'?`): a value converts as the total cast, null stays null, a trap
//     stands -- so `("-inf"::Float?)::Int?` is the Float→Int TRAP.
//   * `==` on two Floats, IEEE's, so a parse's value is stated against a literal
//     rather than printed: `("1500.0" :: Float ?) == 1500.0` reduces to `true`.
//   * [LCST.4.5.2] / [LCST.4.5.4] Float→Int is TOTAL: a value whose truncation
//     toward zero is an Int → that Int; any other → a hard runtime TRAP, NOT a
//     null -- it never feeds the T? / ?? / Kleene stack. The trap abandons the
//     activation and the engine continues, as `÷0` does ([LCST.4.5.4]).
//
// WHICH VALUES TRAP, and where the clauses differ. An Int is
// 64-bit ([LEXP.7.13.1]), so the truncation is an Int exactly when
// -2^63 <= F < 2^63. [LERR.1.4.10] says so: `NOT_REPRESENTABLE` is raised on "a
// value non-finite, or finite and outside `Int`", and [LERR.1.4.9] gives the
// reason -- a conversion that wrapped would bear no relation to its input.
// [LCST.4.5.2]'s row and [LCST.4.5.4] name the non-finite input alone. This
// file follows [LERR.1.4.10]: under the row, `1e30 :: Int` would reduce to
// 10^30, which no Int holds.
//
// The bounds are exact in Float: 2^63 and -2^63 are both doubles, the double
// below 2^63 is 2^63 - 1024, and the one below -2^63 is -2^63 - 2048. So
// "F < 2^63" admits no value that truncates past INT64_MAX, and "-2^63 <= F"
// loses none that truncates to INT64_MIN. The five `dscast.range_*` vectors
// sit on those four doubles and on 1e30.
//
// ONE `trap`, NO KIND. [LERR.1.4.10] gives both cases one kind, and this model
// has no second raiser to tell it from.
//
// NOT MODELLED: a subnormal double, in either direction (K's Float has none);
// the parses and renders of [LCST.4.5.9]'s temporal types; a unit or Json
// target.
//   * [LCST.4.5.1] identity `x::T` where x already has type T is a no-op.
//   * [LCST.4.2.3] `null::T?` → null (a bare `null::T` is a compile error, so the
//     runtime never sees one).
//   * [LCST.4.1.5] a chain `x::A::B` applies left to right (the source is strict).
// The tie is file-level, the tag line at the head of this file, and
// the crossref gates it in both directions.
//
// THE MEANING. krun reduces `<value> :: <type>` to the converted value (or `trap`
// / `null`); the gate's programs pin the flagship trap and the total/fallible split.

module DSCAST-SYNTAX
  imports INT-SYNTAX
  imports FLOAT-SYNTAX
  imports BOOL-SYNTAX
  imports STRING-SYNTAX

  // A cast reduces to a value, the sentinel `trap` (the activation is
  // abandoned, [LCST.4.5.4]), or `null` (a fallible ::T? failure).
  syntax Val ::= Int | Float | Bool | String | "null" | "trap"

  // Target type terminals of a cast suffix.
  syntax Ty ::= "Int" | "Float" | "Bool" | "String"

  syntax Exp ::= Val
               | Exp "/" Exp      [strict, left]   // only to build ±Inf (1.0/0.0)
               > Exp "::" Ty      [strict(1)]       // total cast  ([LCST.4.2.1])
               | Exp "::" Ty "?"  [strict(1)]       // fallible cast ([LCST.4.2.2])
               | "(" Exp ")"      [bracket]         // in this block, not a lower one: K's
                                                    // priority filter refuses a bracket from a
                                                    // lower block as the operand of `::`
               > Exp "==" Exp     [strict, left]    // IEEE equality on two Floats, to state a parse's value

  // A significand with a binary exponent, or digits with a power of ten:
  // `qe(q, e)` is `q * 2^e` or `q * 10^e` by the function that returns it;
  // `none` is a search that found nothing.
  syntax QE ::= qe(Int, Int) | "none"
endmodule

module DSCAST
  imports DSCAST-SYNTAX
  imports INT
  imports FLOAT
  imports BOOL
  imports STRING

  syntax KResult ::= Val

  syntax Float ::= i2f(Int) [function]
  rule i2f(I:Int) => Int2Float(I, 53, 11)

  // helper to build a float for the trap test
  rule F1:Float / F2:Float => F1 /Float F2

  // ---- identity ([LCST.4.5.1]) ----
  rule I:Int    :: Int    => I
  rule F:Float  :: Float  => F
  rule B:Bool   :: Bool   => B
  rule S:String :: String => S

  // ---- Int → Float, widening ([LCST.4.5.2]) ----
  rule I:Int :: Float => i2f(I)

  // ---- Float → Int, TOTAL: a value inside Int truncates toward zero; one
  //      outside it, or non-finite, TRAPS ([LCST.4.5.2] / [LCST.4.5.4] /
  //      [LERR.1.4.10]). NaN cannot occur; it is outside Int all the same. ----
  //
  // TRUNCATION IS WRITTEN OUT, because K's `Float2Int` ROUNDS. This rule read
  // `Float2Int(F)` and its only vector, `9.0 / 4.0` = 2.25, gives 2 under both
  // readings, so nothing separated them. `rkey.k` had already met the same
  // hook (1.5 rendered with an integer part of 2) and wrote its own `trunc`.
  // `dscast.trunc_high` (2.75 → 2) and `dscast.trunc_negative` (-2.75 → -2)
  // are the vectors that tell truncation from rounding, in both signs.
  rule F:Float :: Int => f2iTrunc(F) requires inInt(F)
  rule F:Float :: Int => trap        requires notBool inInt(F)

  // -2^63 <= F < 2^63, and F is a number. Both bounds are built from the Int
  // so that no decimal literal has to round to them.
  syntax Bool ::= inInt(Float) [function]
  rule inInt(F:Float) => notBool (isInfinite(F) orBool isNaN(F))
                 andBool F >=Float i2f(0 -Int 9223372036854775808)
                 andBool F <Float  i2f(9223372036854775808)

  // Toward zero: correct the rounded value by one where rounding went away
  // from zero. Holds whichever way `Float2Int` breaks ties. Beyond 2^52 every
  // Float is integral, `Float2Int` is exact and neither correction fires.
  syntax Int ::= f2iTrunc(Float) [function]
  rule f2iTrunc(F:Float) => Float2Int(F) -Int 1
       requires F >=Float 0.0 andBool Int2Float(Float2Int(F), 53, 11) >Float F
  rule f2iTrunc(F:Float) => Float2Int(F) +Int 1
       requires F <Float 0.0 andBool Int2Float(Float2Int(F), 53, 11) <Float F
  rule f2iTrunc(F:Float) => Float2Int(F)
       requires notBool (F >=Float 0.0 andBool Int2Float(Float2Int(F), 53, 11) >Float F)
        andBool notBool (F <Float 0.0 andBool Int2Float(Float2Int(F), 53, 11) <Float F)

  // ---- <scalar> → String, render ([LCST.4.5.2] / [LCST.4.5.6]) ----
  rule I:Int   :: String => Int2String(I)
  rule F:Float :: String => renderFloat(F)
  rule true    :: String => "true"
  rule false   :: String => "false"

  // ---- `==` on two Floats, IEEE's ([LDET.3.6.2]); a trap in either operand
  //      stands ([LNUL.4.10]), else a null does ([LNUL.4.1]). Constructor
  //      patterns, one rule per shape, so no two apply to one term. ----
  rule F1:Float == F2:Float => F1 ==Float F2
  rule trap     == _:Val    => trap
  rule F:Float  == trap     => trap
  rule null     == trap     => trap
  rule null     == F:Float  => null
  rule F:Float  == null     => null
  rule null     == null     => null

  // ---- a nullable source under a total conversion ([LCST.4.3.1], rows 3 and 4):
  //      a value converts as the total cast, null stays null (below), a trap
  //      stands. A String source is a parse, not this. ----
  rule I:Int   :: T:Ty ? => I :: T
  rule F:Float :: T:Ty ? => F :: T
  rule B:Bool  :: T:Ty ? => B :: T
  rule trap :: _:Ty => trap
  rule trap :: _:Ty ? => trap

  // ---- Float → String, [LDET.3.2.7]'s canonical text ([LCST.4.5.6]), transcribed
  //      from Eval.idr's `lcst_4_5_6__render_float` and kept in step by hand ----
  //
  // `nan` for a NaN whatever its sign, `inf` / `-inf`, `0.0` / `-0.0` each
  // with its sign, and for a finite nonzero value the shortest digits in the
  // clause's shape. A search that finds no digits is `trap`, the parse's defect
  // surfacing; seventeen digits identify every double, so no finite value
  // reaches it.
  syntax Val ::= renderFloat(Float) [function]
  rule renderFloat(F) => "nan" requires isNaN(F)
  rule renderFloat(F) => "inf" requires isInfinite(F) andBool F >Float 0.0
  rule renderFloat(F) => "-inf" requires isInfinite(F) andBool F <Float 0.0
  rule renderFloat(F) => zeroText(F) requires F ==Float 0.0
  rule renderFloat(F) => shaped(F <Float 0.0, strip(shortest(norm(absFloat(F), 0))))
       requires notBool (isNaN(F) orBool isInfinite(F)) andBool F =/=Float 0.0

  // the sign of a zero: 1 / -0.0 is -inf
  syntax String ::= zeroText(Float) [function]
  rule zeroText(F) => "-0.0" requires 1.0 /Float F <Float 0.0
  rule zeroText(F) => "0.0" requires notBool (1.0 /Float F <Float 0.0)

  // DECOMPOSE a finite nonzero magnitude into `qe(m, e)`, `m` in [2^52, 2^53)
  // and `m * 2^e` the value, by exact halvings and doublings (every
  // intermediate value is representable, so no step rounds) and the exact
  // `Float2Int` of the integral result.
  syntax QE ::= norm(Float, Int) [function]
  rule norm(Y, E) => norm(Y /Float 2.0, E +Int 1) requires Y >=Float 9007199254740992.0
  rule norm(Y, E) => norm(Y *Float 2.0, E -Int 1) requires Y <Float 4503599627370496.0
  rule norm(Y, E) => qe(Float2Int(Y), E)
       requires Y >=Float 4503599627370496.0 andBool Y <Float 9007199254740992.0

  // THE SHORTEST DIGITS of `m * 2^e`: the value as the exact fraction n / md,
  // the power of ten of its leading digit, then the search from one digit to
  // seventeen. `qe(q, p)`: the digits and the power of ten of the last.
  syntax QE ::= shortest(QE) [function]
  rule shortest(qe(M, E)) => search(1, 17, M, E, binNum(M, E), binDen(E),
                                    decExp(12, binNum(M, E), binDen(E), estX(binNum(M, E), binDen(E))))

  syntax Int ::= binNum(Int, Int) [function]   // m * 2^e as a fraction: the numerator
  rule binNum(M, E) => M *Int (2 ^Int E) requires E >=Int 0
  rule binNum(M, E) => M requires E <Int 0
  syntax Int ::= binDen(Int) [function]        // ... and the divisor
  rule binDen(E) => 1 requires E >=Int 0
  rule binDen(E) => 2 ^Int (0 -Int E) requires E <Int 0

  // an estimate of the decimal exponent from the bit lengths (log10 2 ~ 0.30103)
  syntax Int ::= estX(Int, Int) [function]
  rule estX(N, MD) => ((bitLen(N) -Int bitLen(MD)) *Int 30103) /Int 100000 -Int 1
       requires bitLen(N) >=Int bitLen(MD)
  rule estX(N, MD) => 0 -Int (((bitLen(MD) -Int bitLen(N)) *Int 30103) /Int 100000) -Int 2
       requires bitLen(N) <Int bitLen(MD)

  syntax Int ::= bitLen(Int) [function]   // the least k with n < 2^k
  rule bitLen(0) => 0
  rule bitLen(N) => log2Int(N) +Int 1 requires N >Int 0

  // n / md >= 10^x, exact for either sign of x
  syntax Bool ::= gePow10(Int, Int, Int) [function]
  rule gePow10(N, MD, X) => N >=Int MD *Int (10 ^Int X) requires X >=Int 0
  rule gePow10(N, MD, X) => N *Int (10 ^Int (0 -Int X)) >=Int MD requires X <Int 0

  // the x with 10^x <= n/md < 10^(x+1), from the estimate, a step at a time
  syntax Int ::= decExp(Int, Int, Int, Int) [function]
  rule decExp(0, _, _, X) => X
  rule decExp(K, N, MD, X) => decExp(K -Int 1, N, MD, X -Int 1)
       requires K >Int 0 andBool notBool gePow10(N, MD, X)
  rule decExp(K, N, MD, X) => decExp(K -Int 1, N, MD, X +Int 1)
       requires K >Int 0 andBool gePow10(N, MD, X) andBool gePow10(N, MD, X +Int 1)
  rule decExp(K, N, MD, X) => X
       requires K >Int 0 andBool gePow10(N, MD, X) andBool notBool gePow10(N, MD, X +Int 1)

  // the search from `len` digits upward, `left` lengths at most
  syntax QE ::= search(Int, Int, Int, Int, Int, Int, Int) [function]
  rule search(_, 0, _, _, _, _, _) => none
  rule search(Len, Left, M, E, N, MD, X) => found(candidates(Len, M, E, N, MD, X), Len, Left, M, E, N, MD, X)
       requires Left >Int 0
  syntax QE ::= found(QE, Int, Int, Int, Int, Int, Int, Int) [function]
  rule found(qe(Q, P), _, _, _, _, _, _, _) => qe(Q, P)
  rule found(none, Len, Left, M, E, N, MD, X) => search(Len +Int 1, Left -Int 1, M, E, N, MD, X)

  // THE CANDIDATES AT ONE LENGTH: the value scaled to `len` digits is lo + r/den;
  // lo and lo + 1 bracket it on that length's grid, and a decimal of that
  // length that parses back is one of them. Each is tested by the parse, the
  // upper only when the value is not the lower exactly.
  syntax QE ::= candidates(Int, Int, Int, Int, Int, Int) [function]
  rule candidates(Len, M, E, N, MD, X) => bracket(M, E, X -Int Len +Int 1,
                                                  dec10Num(N, X -Int Len +Int 1), dec10Den(MD, X -Int Len +Int 1))
  syntax QE ::= bracket(Int, Int, Int, Int, Int) [function]   // m e p num den
  rule bracket(M, E, P, Num, Den) => pick(M, E, P, Num /Int Den, Num %Int Den, Den)
  syntax QE ::= pick(Int, Int, Int, Int, Int, Int) [function]   // m e p lo r den
  rule pick(M, E, P, Lo, R, Den) => choose(Lo, P, roundTrips(M, E, Lo, P),
                                           R =/=Int 0 andBool roundTrips(M, E, Lo +Int 1, P),
                                           R <Int Den -Int R, Den -Int R <Int R, Lo %Int 2 ==Int 0)

  syntax Int ::= dec10Num(Int, Int) [function]   // n / md scaled by 10^-p: the numerator
  rule dec10Num(N, P) => N requires P >=Int 0
  rule dec10Num(N, P) => N *Int (10 ^Int (0 -Int P)) requires P <Int 0
  syntax Int ::= dec10Den(Int, Int) [function]   // ... and the divisor
  rule dec10Den(MD, P) => MD *Int (10 ^Int P) requires P >=Int 0
  rule dec10Den(MD, P) => MD requires P <Int 0

  // THE CHOICE, a case table and no `if` (Eval.idr's `ldet_3_2_7__choose`):
  // lo p loOk hiOk nearLo nearHi loEven -> the one that parses back; of two,
  // the nearer; at an exact tie the even last digit; of none, nothing.
  syntax QE ::= choose(Int, Int, Bool, Bool, Bool, Bool, Bool) [function]
  rule choose(Lo, P, true,  true,  true,  _,     _)     => qe(Lo, P)
  rule choose(Lo, P, true,  true,  false, true,  _)     => qe(Lo +Int 1, P)
  rule choose(Lo, P, true,  true,  false, false, true)  => qe(Lo, P)
  rule choose(Lo, P, true,  true,  false, false, false) => qe(Lo +Int 1, P)
  rule choose(Lo, P, true,  false, _,     _,     _)     => qe(Lo, P)
  rule choose(Lo, P, false, true,  _,     _,     _)     => qe(Lo +Int 1, P)
  rule choose(_,  _, false, false, _,     _,     _)     => none

  // does q * 10^p parse back to m * 2^e? Its nearest double, as an exact value,
  // is that one. The clause's "parses back to the identical double", read
  // through the parse's own rounding.
  syntax Bool ::= roundTrips(Int, Int, Int, Int) [function]
  rule roundTrips(M, E, Q, P) => sameBin(nearest(numOf(Q, P), denOf(P)), M, E)
  syntax Bool ::= sameBin(QE, Int, Int) [function]
  rule sameBin(qe(Q2, E2), M, E) => Q2 *Int (2 ^Int (E2 -Int E)) ==Int M requires E2 >=Int E
  rule sameBin(qe(Q2, E2), M, E) => Q2 ==Int M *Int (2 ^Int (E -Int E2)) requires E2 <Int E
  rule sameBin(none, _, _) => false

  // the digits with their trailing zeros removed, the power moved up by as many
  syntax QE ::= strip(QE) [function]
  rule strip(none) => none
  rule strip(qe(Q, P)) => strip(qe(Q /Int 10, P +Int 1)) requires Q >Int 0 andBool Q %Int 10 ==Int 0
  rule strip(qe(Q, P)) => qe(Q, P) requires notBool (Q >Int 0 andBool Q %Int 10 ==Int 0)

  // THE SHAPE ([LDET.3.2.7]): digits q at power p, x the leading digit's power.
  // Fixed notation when x is -4 to 15, `.0` kept on a whole value, a `0`
  // before a sub-one one; scientific otherwise, the mantissa's point only when
  // there is more than one digit, `e`, the exponent's sign, at least two digits.
  syntax Val ::= shaped(Bool, QE) [function]
  rule shaped(_, none) => trap
  rule shaped(Neg, qe(Q, P)) => signTxt(Neg) +String shapeBody(Int2String(Q), P, P +Int lengthString(Int2String(Q)) -Int 1)

  syntax String ::= shapeBody(String, Int, Int) [function]   // digits p x
  rule shapeBody(Ds, P, X) => Ds +String zeros(P) +String ".0"
       requires X >=Int -4 andBool X <=Int 15 andBool P >=Int 0
  rule shapeBody(Ds, P, X) => substrString(Ds, 0, lengthString(Ds) +Int P) +String "."
                              +String substrString(Ds, lengthString(Ds) +Int P, lengthString(Ds))
       requires X >=Int -4 andBool X <=Int 15 andBool P <Int 0 andBool lengthString(Ds) >Int 0 -Int P
  rule shapeBody(Ds, P, X) => "0." +String zeros(0 -Int P -Int lengthString(Ds)) +String Ds
       requires X >=Int -4 andBool X <=Int 15 andBool P <Int 0 andBool lengthString(Ds) <=Int 0 -Int P
  rule shapeBody(Ds, _, X) => substrString(Ds, 0, 1) +String afterPoint(substrString(Ds, 1, lengthString(Ds)))
                              +String "e" +String expSign(X) +String twoDigits(absInt(X))
       requires X <Int -4 orBool X >Int 15

  syntax String ::= zeros(Int) [function]
  rule zeros(K) => "" requires K <=Int 0
  rule zeros(K) => "0" +String zeros(K -Int 1) requires K >Int 0
  syntax String ::= afterPoint(String) [function]
  rule afterPoint(R) => "" requires R ==String ""
  rule afterPoint(R) => "." +String R requires R =/=String ""
  syntax String ::= expSign(Int) [function]
  rule expSign(X) => "-" requires X <Int 0
  rule expSign(X) => "+" requires X >=Int 0
  syntax String ::= twoDigits(Int) [function]
  rule twoDigits(V) => "0" +String Int2String(V) requires V <Int 10
  rule twoDigits(V) => Int2String(V) requires V >=Int 10
  syntax String ::= signTxt(Bool) [function]
  rule signTxt(true)  => "-"
  rule signTxt(false) => ""

  // ---- String → Bool?, fallible parse ([LCST.4.5.5]) ----
  rule "true"   :: Bool ? => true
  rule "false"  :: Bool ? => false
  rule _:String :: Bool ? => null [owise]

  // ---- String → Int?, fallible parse ([LCST.4.5.7], [LLEX.11.1], [LLEX.12.1]) ----
  //
  // The whole string is an optional sign then an INT_LIT, else null. The
  // body after the sign is checked by `isIntLit` -- a digit run of its base,
  // a digit first and last, every character a digit or a `_` sitting before a
  // digit -- and valued by K's `String2Base` over the digits with the
  // separators removed; the value stands when it lies in the 64-bit range.
  rule S:String :: Int ? => strToInt(S)

  syntax Val ::= strToInt(String) [function]
  rule strToInt(S) => inRange(signOf(S) *Int intLit(body(S))) requires isIntLit(body(S))
  rule strToInt(S) => null requires notBool isIntLit(body(S))

  syntax Int ::= signOf(String) [function]
  rule signOf(S) => 0 -Int 1 requires hasPrefix(S, "-")
  rule signOf(S) => 1 requires notBool hasPrefix(S, "-")

  syntax String ::= body(String) [function]
  rule body(S) => substrString(S, 1, lengthString(S)) requires hasPrefix(S, "-") orBool hasPrefix(S, "+")
  rule body(S) => S requires notBool (hasPrefix(S, "-") orBool hasPrefix(S, "+"))

  syntax Bool ::= hasPrefix(String, String) [function]
  rule hasPrefix(S, P) => lengthString(S) >=Int lengthString(P) andBool substrString(S, 0, lengthString(P)) ==String P

  // the base a body is in, by its prefix, and the digits after the prefix
  syntax Int ::= baseOf(String) [function]
  rule baseOf(B) => 16 requires hasPrefix(B, "0x")
  rule baseOf(B) => 2 requires hasPrefix(B, "0b")
  rule baseOf(B) => 8 requires hasPrefix(B, "0o")
  rule baseOf(B) => 10 requires notBool (hasPrefix(B, "0x") orBool hasPrefix(B, "0b") orBool hasPrefix(B, "0o"))

  syntax String ::= digitsOf(String) [function]
  rule digitsOf(B) => substrString(B, 2, lengthString(B)) requires baseOf(B) =/=Int 10
  rule digitsOf(B) => B requires baseOf(B) ==Int 10

  syntax Bool ::= isIntLit(String) [function]
  rule isIntLit(B) => digitsOk(digitsOf(B), baseOf(B), true)

  // digitsOk(Rest, Base, NeedDigit): NeedDigit holds at the start and after a
  // `_`, so the run opens and closes on a digit and no two `_` meet.
  syntax Bool ::= digitsOk(String, Int, Bool) [function]
  rule digitsOk("", _, Need) => notBool Need
  rule digitsOk(S, Base, _) => digitsOk(substrString(S, 1, lengthString(S)), Base, false)
       requires lengthString(S) >Int 0 andBool isDigitOf(substrString(S, 0, 1), Base)
  rule digitsOk(S, Base, false) => digitsOk(substrString(S, 1, lengthString(S)), Base, true)
       requires lengthString(S) >Int 0 andBool substrString(S, 0, 1) ==String "_"
  rule digitsOk(S, Base, Need) => false
       requires lengthString(S) >Int 0 andBool notBool isDigitOf(substrString(S, 0, 1), Base)
        andBool notBool (substrString(S, 0, 1) ==String "_" andBool notBool Need)

  syntax Bool ::= isDigitOf(String, Int) [function]
  rule isDigitOf(C, Base) => digitVal(C) >=Int 0 andBool digitVal(C) <Int Base

  syntax Int ::= digitVal(String) [function]
  rule digitVal(C) => ordChar(C) -Int 48 requires ordChar(C) >=Int 48 andBool ordChar(C) <=Int 57
  rule digitVal(C) => ordChar(C) -Int 87 requires ordChar(C) >=Int 97 andBool ordChar(C) <=Int 102
  rule digitVal(C) => ordChar(C) -Int 55 requires ordChar(C) >=Int 65 andBool ordChar(C) <=Int 70
  rule digitVal(C) => 0 -Int 1
       requires notBool (ordChar(C) >=Int 48 andBool ordChar(C) <=Int 57)
        andBool notBool (ordChar(C) >=Int 97 andBool ordChar(C) <=Int 102)
        andBool notBool (ordChar(C) >=Int 65 andBool ordChar(C) <=Int 70)

  syntax Int ::= intLit(String) [function]
  rule intLit(B) => String2Base(replaceAll(digitsOf(B), "_", ""), baseOf(B))

  syntax Val ::= inRange(Int) [function]
  rule inRange(V) => V requires fitsInt(V)
  rule inRange(V) => null requires notBool fitsInt(V)

  // -2^63 <= V <= 2^63 - 1: the 64-bit signed range an INT_LIT must fit.
  syntax Bool ::= fitsInt(Int) [function]
  rule fitsInt(V) => V >=Int (0 -Int 9223372036854775808) andBool V <=Int 9223372036854775807

  // ---- String → Float?, fallible parse ([LCST.4.5.8], [LLEX.11.2], [LDET.3.2.8]) ----
  //
  // The whole string is an optional sign then an INT_LIT in the 64-bit range
  // (`isIntLit`, above), a FLOAT_LIT (`isFloatLit`), or `inf`; else null. A
  // FLOAT_LIT's digits and power of ten go to `decToFloat`, the nearest double
  // by exact Integer arithmetic; an INT_LIT's value goes the same way at power
  // zero. Eval.idr's `lcst_4_5_8__parse_float`; kept in step by hand.
  rule S:String :: Float ? => strToFloat(S)

  syntax Val ::= strToFloat(String) [function]
  rule strToFloat(S) => signedInf(hasPrefix(S, "-")) requires body(S) ==String "inf"
  rule strToFloat(S) => decToFloat(hasPrefix(S, "-"), absInt(signOf(S) *Int intLit(body(S))), 0)
       requires body(S) =/=String "inf" andBool isIntLit(body(S))
        andBool fitsInt(signOf(S) *Int intLit(body(S)))
  rule strToFloat(S) => decToFloat(hasPrefix(S, "-"), fltDigits(body(S)), fltPower(body(S)))
       requires body(S) =/=String "inf" andBool isFloatLit(body(S))
  rule strToFloat(_) => null [owise]

  syntax Float ::= signedInf(Bool) [function]
  rule signedInf(true)  => --Float (1.0 /Float 0.0)
  rule signedInf(false) => 1.0 /Float 0.0

  // A FLOAT_LIT ([LLEX.11.2]): `DEC_LIT '.' DEC_LIT EXPONENT?` or `DEC_LIT EXPONENT`,
  // a DEC_LIT a decimal digit run with a `_` only between digits (`digitsOk`
  // in base 10: [LLEX.11.1]), the EXPONENT an `e` or `E`, an
  // optional sign and a DEC_LIT that ends the string. The mantissa is the text
  // before the marker, split at its point.
  syntax Int ::= expIdx(String) [function]
  rule expIdx(B) => findChar(B, "eE", 0)
  syntax String ::= mant(String) [function]
  rule mant(B) => B requires expIdx(B) <Int 0
  rule mant(B) => substrString(B, 0, expIdx(B)) requires expIdx(B) >=Int 0
  syntax String ::= expo(String) [function]   // after the marker, "" when none
  rule expo(B) => "" requires expIdx(B) <Int 0
  rule expo(B) => substrString(B, expIdx(B) +Int 1, lengthString(B)) requires expIdx(B) >=Int 0
  syntax Int ::= dotIdx(String) [function]
  rule dotIdx(M) => findChar(M, ".", 0)
  syntax String ::= ipart(String) [function]
  rule ipart(M) => M requires dotIdx(M) <Int 0
  rule ipart(M) => substrString(M, 0, dotIdx(M)) requires dotIdx(M) >=Int 0
  syntax String ::= fpart(String) [function]   // after the point, "" when none
  rule fpart(M) => "" requires dotIdx(M) <Int 0
  rule fpart(M) => substrString(M, dotIdx(M) +Int 1, lengthString(M)) requires dotIdx(M) >=Int 0

  syntax Bool ::= isDecLit(String) [function]
  rule isDecLit(D) => digitsOk(D, 10, true)
  syntax Bool ::= isExponent(String) [function]
  rule isExponent(E) => isDecLit(body(E))

  syntax Bool ::= isFloatLit(String) [function]
  rule isFloatLit(B) => isDecLit(ipart(mant(B))) andBool isDecLit(fpart(mant(B)))
                        andBool (expIdx(B) <Int 0 orBool isExponent(expo(B)))
       requires dotIdx(mant(B)) >=Int 0
  rule isFloatLit(B) => isDecLit(mant(B)) andBool expIdx(B) >=Int 0 andBool isExponent(expo(B))
       requires dotIdx(mant(B)) <Int 0

  // the digits as one Integer, and the power of ten the last one sits at
  syntax Int ::= fltDigits(String) [function]
  rule fltDigits(B) => String2Int(replaceAll(ipart(mant(B)) +String fpart(mant(B)), "_", ""))
  syntax Int ::= fltPower(String) [function]
  rule fltPower(B) => expVal(B) -Int lengthString(replaceAll(fpart(mant(B)), "_", ""))
  syntax Int ::= expVal(String) [function]
  rule expVal(B) => 0 requires expIdx(B) <Int 0
  rule expVal(B) => signOf(expo(B)) *Int String2Int(replaceAll(body(expo(B)), "_", "")) requires expIdx(B) >=Int 0

  // A signed decimal d * 10^x to the nearest double, ties to even ([LDET.3.2.8];
  // Eval.idr's `ldet_3_2_8__of_decimal`): the magnitude settled by the digit
  // count before any arithmetic -- with k digits the value is at least
  // 10^(k-1+x) and below 10^(k+x), so past 10^310 it exceeds every double and
  // is null ([LCST.4.5.8]), and below 10^-324 it is under half the least
  // subnormal and the signed zero -- and `nearest` between.
  syntax Val ::= decToFloat(Bool, Int, Int) [function]
  rule decToFloat(Neg, 0, _) => zeroF(Neg)
  rule decToFloat(_, D, X) => null requires D >Int 0 andBool digitCount(D) +Int X >Int 310
  rule decToFloat(Neg, D, X) => zeroF(Neg) requires D >Int 0 andBool digitCount(D) +Int X <Int -324
  rule decToFloat(Neg, D, X) => composeQE(Neg, nearest(numOf(D, X), denOf(X)))
       requires D >Int 0 andBool digitCount(D) +Int X <=Int 310 andBool digitCount(D) +Int X >=Int -324

  syntax Float ::= zeroF(Bool) [function]
  rule zeroF(true)  => --Float 0.0
  rule zeroF(false) => 0.0
  syntax Int ::= digitCount(Int) [function]   // decimal digits of a positive Int
  rule digitCount(N) => lengthString(Int2String(N))

  // d * 10^x as an exact fraction
  syntax Int ::= numOf(Int, Int) [function]
  rule numOf(D, X) => D *Int (10 ^Int X) requires X >=Int 0
  rule numOf(D, X) => D requires X <Int 0
  syntax Int ::= denOf(Int) [function]
  rule denOf(X) => 1 requires X >=Int 0
  rule denOf(X) => 10 ^Int (0 -Int X) requires X <Int 0

  // THE PARSE'S ROUNDING (Eval.idr's `ldet_3_2_8__nearest`): the double nearest
  // n / m, ties to even, as `qe(q, e)` -- `q * 2^e` the value, q below 2^53,
  // e at least -1074 -- or an e above 971 when the value rounds past the
  // largest double. The exponent at which the quotient has 53 bits (or the
  // least a double has), the remainder against a half, a rounding that carries
  // into a 54th bit moving the exponent up.
  syntax QE ::= nearest(Int, Int) [function]
  rule nearest(N, M) => roundAt(N, M, clampE(expOf(4, N, M, bitLen(N) -Int bitLen(M) -Int 53)))
  syntax Int ::= clampE(Int) [function]
  rule clampE(E) => 0 -Int 1074 requires E <Int 0 -Int 1074
  rule clampE(E) => E requires E >=Int 0 -Int 1074
  syntax Int ::= scNum(Int, Int) [function]   // n / m scaled by 2^-e: the numerator
  rule scNum(N, E) => N requires E >=Int 0
  rule scNum(N, E) => N *Int (2 ^Int (0 -Int E)) requires E <Int 0
  syntax Int ::= scDen(Int, Int) [function]   // ... and the divisor
  rule scDen(M, E) => M *Int (2 ^Int E) requires E >=Int 0
  rule scDen(M, E) => M requires E <Int 0
  syntax Int ::= quo(Int, Int, Int) [function]
  rule quo(N, M, E) => scNum(N, E) /Int scDen(M, E)
  // the exponent at which the quotient is in [2^52, 2^53), from an estimate
  // corrected a step at a time; an estimate by bit lengths is off by at most two
  syntax Int ::= expOf(Int, Int, Int, Int) [function]   // fuel n m e
  rule expOf(0, _, _, E) => E
  rule expOf(K, N, M, E) => expOf(K -Int 1, N, M, E +Int 1)
       requires K >Int 0 andBool quo(N, M, E) >=Int 9007199254740992
  rule expOf(K, N, M, E) => expOf(K -Int 1, N, M, E -Int 1)
       requires K >Int 0 andBool quo(N, M, E) <Int 4503599627370496
  rule expOf(K, N, M, E) => E
       requires K >Int 0 andBool quo(N, M, E) <Int 9007199254740992 andBool quo(N, M, E) >=Int 4503599627370496
  syntax QE ::= roundAt(Int, Int, Int) [function]
  rule roundAt(N, M, E) => carry(rhe(scNum(N, E) /Int scDen(M, E), scNum(N, E) %Int scDen(M, E), scDen(M, E)), E)
  // round half to even: q, or q + 1 above a half, or at a half when q is odd
  syntax Int ::= rhe(Int, Int, Int) [function]
  rule rhe(Q, R, D) => Q requires 2 *Int R <Int D
  rule rhe(Q, R, D) => Q +Int 1 requires 2 *Int R >Int D
  rule rhe(Q, R, D) => Q requires 2 *Int R ==Int D andBool Q %Int 2 ==Int 0
  rule rhe(Q, R, D) => Q +Int 1 requires 2 *Int R ==Int D andBool Q %Int 2 =/=Int 0
  syntax QE ::= carry(Int, Int) [function]
  rule carry(Q, E) => qe(4503599627370496, E +Int 1) requires Q >=Int 9007199254740992
  rule carry(Q, E) => qe(Q, E) requires Q <Int 9007199254740992

  // the double `(-1)^neg * q * 2^e`, exact: q read by the primitive conversion,
  // scaled by powers of two -- as a value in [1, 2) first, so that no
  // intermediate leaves the normal range for a normal result. Past the largest
  // double, null.
  syntax Val ::= composeQE(Bool, QE) [function]
  rule composeQE(_, qe(_, E)) => null requires E >Int 971
  rule composeQE(Neg, qe(Q, E)) => signedF(Neg, (Int2Float(Q, 53, 11) *Float pow2F(0 -Int 52)) *Float pow2F(E +Int 52))
       requires E <=Int 971
  rule composeQE(_, none) => null
  syntax Float ::= pow2F(Int) [function]   // 2^e as a double, exact for |e| <= 1022
  rule pow2F(E) => Int2Float(2 ^Int E, 53, 11) requires E >=Int 0
  rule pow2F(E) => 1.0 /Float Int2Float(2 ^Int (0 -Int E), 53, 11) requires E <Int 0
  syntax Float ::= signedF(Bool, Float) [function]
  rule signedF(true, F)  => --Float F
  rule signedF(false, F) => F

  // ---- null flows through a fallible cast as null ([LCST.4.2.3]) ----
  rule null :: _:Ty ? => null
endmodule

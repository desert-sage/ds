// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [LEXP.7.2] [LEXP.7.4] [LEXP.7.5] [LEXP.7.6] [LNUL.4.1] [LNUL.4.2] [LNUL.4.4] [LNUL.5.3] [LEXP.7.13.1] [LEXP.7.15.1] [LNUL.8.9] [LDET.3.6.2]
//
// dsexpr.k -- the DS expression-evaluation core as EXECUTABLE operational
// semantics (K Framework). The "deeper" K target beyond the Kleene pilot: it runs
// the value/boolean layer of DS expressions -- arithmetic with Int→Float
// promotion, value-level null propagation, comparison to 3-valued booleans, the
// Kleene connectives, the total null-test, and the coalesce operator.
//
// NORMATIVE COMPANION. Formalizes:
//   * [LEXP.7.2] all-Int arithmetic is Int; [LEXP.7.3] any Float operand promotes
//     the result to Float; [LEXP.7.4] `/` is ALWAYS Float (Python-3 semantics).
//   * [LEXP.7.5] `//` rounds toward negative infinity and [LEXP.7.6] a nonzero
//     `%` takes the divisor's sign: on Int the floor pair, written over K's
//     truncating `/Int` and `%Int` with one adjustment when the remainder's
//     sign is not the divisor's, and wrapped ([LEXP.7.13.1]: `INT64_MIN // -1`
//     is `INT64_MIN`); with a Float operand the Int one promotes and the result
//     is the clauses' COMPOSITION and no other -- step 1 the EXACT remainder of
//     the quotient truncated toward zero, carrying the dividend's sign, computed
//     here as a loop that subtracts the largest `|b| * 2^k` not above what is
//     left (each subtraction exact by Sterbenz's lemma; never through a rounded
//     quotient, and never through K's `%Float` hook, whose reading would then
//     be the semantics), then `%`'s steps 2 and 3 (a nonzero remainder of the
//     wrong sign moved by `b`, rounded once; a zero one given `b`'s sign) and
//     `//`'s steps 1 to 4 (`(a - r) / b` rounded once each, less one when
//     step 2 adjusted, a zero given the sign of `a / b`, else the floor
//     corrected upward when the quotient sits more than a half above it). A
//     zero Float divisor is [LEXP.7.15.1]'s row, taken first: `//` by zero is
//     the IEEE quotient (`±Inf`, NaN for a zero dividend) and `%` by zero NaN.
//     formal/idris/Rete/Eval.idr carries the same loop and the same steps, and
//     the vectors below are its Main.idr cases, so the two readings are one.
//     `//` is K's own line-comment marker: the program layout below drops that
//     comment form so the operator can be a token, and the rules name the
//     production by its symbol, `floorDiv(_, _)`, because a `//` in a rule
//     body is a comment to K's outer reader whatever the grammar says.
//   * [LNUL.4.1] value level -- any arithmetic or comparison with a `null` operand
//     yields `null` ("unknown"). NO EXCEPTIONS: this read "the sole exceptions
//     being the null-tests", which was the corpus's framing at the time and is no
//     longer anyone's. ISNULLFLAG1 made `== null` / `!= null` a compile error and
//     `is null` the total test, so the null-test is a DIFFERENT OPERATOR rather
//     than a carve-out of this one, and [LNUL.4.1] now states propagation flatly.
//     THIS MODEL ALREADY HAD IT RIGHT -- `rule _:Val == null => null` below is
//     exactly the amended rule, and it predates the amendment. Both runtimes still
//     special-case an EQ against a null literal, for an artefact-compatibility
//     reason recorded at those sites; the model is the one that was never wrong.
//   * [LNUL.4.2] boolean level -- `and`/`or`/`not` are Kleene 3-valued (and = min,
//     or = max over false < null < true).
//   * [LNUL.4.4] null-tests are TOTAL: `x is null` returns true/false, never null.
//     The test is its own production here, spelled as DS spells it
//     ([LGRA.9.3.1]), so a vector reaches the compiler verbatim; `is_null(x)`
//     is a spelling the compiler refuses ([LGRA.9.6.3]). The negated form and the other eleven subjects of
//     [LNUL.4.9]'s tag test are Rete/Eval.idr's (`lnul_4_9__is`), not this
//     file's.
//   * [LNUL.5.3] coalesce -- `x ?? d` is `x` when non-null, else `d`. It binds
//     tighter than the comparisons and the null test and looser than the
//     arithmetic, left-assoc ([LGRA.9.3.1]'s `coalesce_expr`).
// The tie is file-level, the tag line at the head of this file, and
// the crossref gates it in both directions.
//
// WHERE AN OPERATION HAS NO VALUE. Four clauses say so, and the rules
// follow them. All four are in the tag line. [LERR.1.4.3] is cited below and
// not tied.
//   * [LEXP.7.13.1] an Int is 64-bit two's complement and overflow WRAPS. Every
//     Int result of `+` `-` `*` goes through `wrap`.
//   * [LEXP.7.15.1] / [LERR.1.4.3] a zero divisor under all-`Int` operands is a
//     runtime error: `/` reduces to `trap`. With a `Float` operand the `Int`
//     one promotes ([LEXP.7.3]) and the division is IEEE 754's ([LDET.3.6.2]):
//     `±Inf` for a nonzero dividend, signed by both operands, so `-0.0` gives
//     the negative one, and NaN for a zero dividend. No rule tests a Float
//     divisor for zero; `/Float` carries the clause.
//   * [LNUL.4.2] a fault under `and` / `or` is absorbed by a deciding operand on
//     either side and raised otherwise. `trap` is outside `Val`, so no rule
//     written for a value can take it for one.
//   * [LNUL.8.9] `??` is LAZY: `d` is evaluated only when `x` is `null`.
//     `5.5 ?? (1 / (1 - 1))` is `5.5`, and with `d` evaluated first it is a
//     trap.
//
// TWO READINGS, marked because no clause chooses:
//   * `null op t`, with `t` a fault, is the FAULT. [LNUL.4.1] gives `null` to
//     any operation with a `null` operand and says nothing of an operand that
//     has no value at all. formal/idris/Rete/Eval.idr (`iret_7_6__strict2`)
//     reads it this way, and the two models are kept in step. No vector pins
//     it. A `null` over a zero divisor is `null`: the division is never
//     performed ([LNUL.9.3]), and `dsexpr.div_null_zero` pins that.
//   * ONE `trap`. Which of two faults an expression yields is [LNUL.4.2]'s
//     order by kind and by record, and is dswherev5.k's subject, not this
//     file's.
//
// THE MEANING. krun reduces a DS expression to its value; the gate's programs pin
// the corners -- promotion (`7 / 2` is Float, not integer 3), null propagation
// (`null + 1` = null), Kleene (`true and null` = null), and the null-test /
// coalesce that are DS's safe defaults for absent data.
//
// EVERY RULE IS REACHED BY A NAMED VECTOR. A semantics whose rules no program
// fires is checked by nothing (TESTING.md), so `dsexpr.<op>_<shape>.prog`
// pins each rule once, named for the rule: `eq_null_left` is
// `(null + 1) == 5`, a null VALUE rather than a null literal, because [LNUL.4.4]
// makes the literal a compile error and the propagation rule is about values.
// A Float result is never the observable -- its rendering is K's, not DS's -- so
// a vector that exercises a Float rule ends in a comparison
// (`(7 / 2.0) == 3.5`), which also reaches the Float arm of `==`.
//
// `//` AND `%`, one vector per rule and per
// row of the compositions: `floordiv_int` / `mod_int` and their negative and
// INT64_MIN shapes, `floordiv_zero_int` / `mod_zero_int` (the all-Int trap),
// the four null and the four trap shapes, `floordiv_float_float` and the
// three other operand shapes for each, `floordiv_tenths` / `mod_tenths` (0.3
// by 0.1, where a rounded quotient would miss), the two large pairs of the
// fixture LEXP.7.6.float_composition (|a / b| above 2^53, CPython 3.12's
// answers), the Float zero divisor (`floordiv_zero_float`, its negative and
// NaN rows, `mod_zero_float`, `mod_zero_int_float`), an infinite divisor on
// either sign, an infinite or NaN dividend, a zero remainder's sign
// (`mod_negative_zero`, `mod_zero_by_negative`) and a zero quotient's sign
// (`floordiv_negative_zero`, `floordiv_small_quotient`). A negative literal
// is written `0 - x` / `0.0 - x`, as `div_zero_negative` writes `-0.0`, and
// an Int zero divisor `(1 - 1)`, as the `div_zero_*` and `div_trap_*` vectors
// write it: a literal Int zero divisor is the compiler's refusal
// (DS_VALIDATE_DIV_BY_ZERO, LEXP.10.2.2), and the runtime differential
// compiles every vector of this file as a DS `where` test
// (the kvectors driver, private tooling), so a vector spelled with one
// is run by K alone and checked against no engine. K reduces `1 - 1` first
// and the trap and null rules see the zero as they would a literal.
//
// AN IEEE SPECIAL VALUE IS PINNED BY A TEST ONLY IT SATISFIES. An infinity by
// `0.0 < x and x == x * 2.0` (`x < 0.0 and ...` for the negative one): no
// finite nonzero double equals its own double, and the sign test excludes
// zero. A NaN by `x != x`, which no other value satisfies. TEETH of the five
// `div_zero_*` vectors: under rules that trap on every zero divisor each
// reduces to `trap`, not `true` (a fault in an operand is the operation's, and
// `and` absorbs it only on a `false`); under a reading that answers zero or
// any finite value, to `false`; under one that loses the divisor's sign,
// `div_zero_negative` is `false`.

module DSEXPR-SYNTAX
  imports INT-SYNTAX
  imports FLOAT-SYNTAX
  imports BOOL-SYNTAX

  // THE PROGRAM LAYOUT, without `//` comments. K's default layout reads `//`
  // to the end of a line as a comment, which would read DS's floor-division
  // operator out of every program (`7 // 2` as `7`). Block comments and
  // whitespace alone, so `//` can be a token -- one regex, since K gives
  // every regex production of a sort one symbol and refuses a second.
  syntax #Layout ::= r"(/\\*([^\\*]|(\\*+([^\\*/])))*\\*+/|[\\ \\n\\r\\t])"

  // Values: machine Int / Float and a 3-valued boolean (K's Bool ∪ `null`).
  // `null` is the shared "unknown/absent" value (Kleene unknown AND value-level
  // null), so it is a Bool3 that also flows anywhere a Val is expected.
  syntax Bool3 ::= Bool | "null"
  syntax Val   ::= Int | Float | Bool3

  // What an expression reduces to: a value, or `trap` -- the computation had
  // no honest answer ([LERR.1.4.9]) and there is no value to go on with.
  syntax Res   ::= Val | "trap"

  // Precedence high → low via `>` (Python-style, [LEXP.1.2]); associativity via
  // [left] / [non-assoc]; [strict] evaluates operands to results first. `??` is
  // strict in `x` alone ([LNUL.8.9]).
  syntax Exp ::= Res
               | "(" Exp ")"           [bracket]
               // arithmetic (`/` is always-Float per [LEXP.7.4]; `//` and
               // `%` at `*`'s level, [LEXP.1.2]). `//` carries a symbol so
               // the rules can name it without writing a line comment.
               > Exp "*" Exp  [strict, left]
               | Exp "/" Exp  [strict, left]
               | Exp "//" Exp [strict, left, symbol(floorDiv)]
               | Exp "%" Exp  [strict, left, symbol(modOp)]
               > Exp "+" Exp  [strict, left]
               | Exp "-" Exp  [strict, left]
               // coalesce: tighter than the comparisons and the null test,
               // looser than the arithmetic ([LGRA.9.2.1] level 5;
               // `coalesce_expr` is `comparison`'s operand, [LGRA.9.3.1]),
               // left-assoc; lazy in `d` ([LNUL.8.9]). `5 ?? 1 == 5` reads
               // `(5 ?? 1) == 5`, true. No vector's parse depends on the
               // level (each `??` vector is parenthesised or has one
               // operator); `coalesce_before_eq` pins the clause's.
               > Exp "??" Exp  [strict(1), left]
               // comparison -> 3-valued boolean, and the null test at the same
               // level ([LGRA.9.2.1] level 4). Neither chains here: DS chains
               // a comparison pairwise ([LGRA.9.3.2]) and never `is`
               // ([LGRA.9.3.1]), so a chain is refused by one side and parsed
               // by the other, and no vector writes one.
               > Exp "<" Exp  [strict, non-assoc]
               | Exp "<=" Exp [strict, non-assoc]
               | Exp "==" Exp [strict, non-assoc]
               | Exp "!=" Exp [strict, non-assoc]
               | Exp "is" "null" [strict]
               // Kleene connectives
               > "not" Exp     [strict]
               > Exp "and" Exp [strict, left]
               > Exp "or" Exp  [strict, left]
endmodule

module DSEXPR
  imports DSEXPR-SYNTAX
  imports INT
  imports FLOAT
  imports BOOL

  syntax KResult ::= Res

  // Int → Float promotion. K's Int2Float carries the IEEE-754 double shape
  // (precision 53, exponent 11), so wrap it in a one-arg helper.
  syntax Float ::= i2f(Int) [function]
  rule i2f(I:Int) => Int2Float(I, 53, 11)

  // An Int result, brought into 64-bit two's complement ([LEXP.7.13.1]). K's
  // Int is unbounded and `modInt` takes the sign of its divisor, so the middle
  // term is in 0 .. 2^64 - 1 whatever the sign of `I`.
  syntax Int ::= wrap(Int) [function]
  rule wrap(I:Int) => ((I +Int 9223372036854775808) modInt 18446744073709551616)
                      -Int 9223372036854775808

  // ---- a fault in an operand is the operation's ([LERR.1.4.9]): there is no
  //      value to operate on. `trap` is a Res and not a Val, so the right-hand
  //      rule of each pair is the only one that can see a `null` beside a
  //      fault, and it gives the fault (the first reading in the header). ----
  rule trap +  _:Res => trap     rule _:Val +  trap => trap
  rule trap -  _:Res => trap     rule _:Val -  trap => trap
  rule trap *  _:Res => trap     rule _:Val *  trap => trap
  rule trap /  _:Res => trap     rule _:Val /  trap => trap
  rule floorDiv(trap, _:Res) => trap     rule floorDiv(_:Val, trap) => trap
  rule modOp(trap, _:Res) => trap        rule modOp(_:Val, trap) => trap
  rule trap <  _:Res => trap     rule _:Val <  trap => trap
  rule trap <= _:Res => trap     rule _:Val <= trap => trap
  rule trap == _:Res => trap     rule _:Val == trap => trap
  rule trap != _:Res => trap     rule _:Val != trap => trap

  // ---- arithmetic: promotion ([LEXP.7.2/7.3]) + null propagation ([LNUL.4.1])
  //      + the Int wrap ([LEXP.7.13.1]) ----
  rule null + _:Val => null      rule _:Val + null => null
  rule I1:Int   + I2:Int   => wrap(I1 +Int I2)
  rule I1:Int   + F2:Float => i2f(I1) +Float F2
  rule F1:Float + I2:Int   => F1 +Float i2f(I2)
  rule F1:Float + F2:Float => F1 +Float F2

  rule null - _:Val => null      rule _:Val - null => null
  rule I1:Int   - I2:Int   => wrap(I1 -Int I2)
  rule I1:Int   - F2:Float => i2f(I1) -Float F2
  rule F1:Float - I2:Int   => F1 -Float i2f(I2)
  rule F1:Float - F2:Float => F1 -Float F2

  rule null * _:Val => null      rule _:Val * null => null
  rule I1:Int   * I2:Int   => wrap(I1 *Int I2)
  rule I1:Int   * F2:Float => i2f(I1) *Float F2
  rule F1:Float * I2:Int   => F1 *Float i2f(I2)
  rule F1:Float * F2:Float => F1 *Float F2

  // `/` is ALWAYS Float ([LEXP.7.4]) -- both operands promote to Float. A zero
  // divisor traps only when both operands are `Int` ([LEXP.7.15.1]); with a
  // `Float` operand the division is IEEE 754's and `/Float` gives `±Inf` or
  // NaN itself ([LDET.3.6.2]). A `null` operand is `null` before the divisor is
  // looked at, because the division is never performed ([LNUL.9.3]).
  rule null / _:Val => null      rule _:Val / null => null
  rule I1:Int   / I2:Int   => i2f(I1) /Float i2f(I2)  requires I2 =/=Int 0
  rule _:Int    / I2:Int   => trap                    requires I2 ==Int 0
  rule I1:Int   / F2:Float => i2f(I1) /Float F2
  rule F1:Float / I2:Int   => F1 /Float i2f(I2)
  rule F1:Float / F2:Float => F1 /Float F2

  // ---- `//` and `%` ([LEXP.7.5], [LEXP.7.6]). On Int the floor pair, wrapped
  //      ([LEXP.7.13.1]), an Int zero divisor the trap ([LEXP.7.15.1]); a
  //      `null` operand `null` before the divisor is looked at ([LNUL.9.3]);
  //      with a Float operand the compositions below, a Float zero divisor
  //      [LEXP.7.15.1]'s IEEE row inside them. `floorDiv(_, _)` is `_ // _`
  //      by its symbol (the header says why). ----
  rule floorDiv(null, _:Val) => null     rule floorDiv(_:Val, null) => null
  rule floorDiv(I1:Int, I2:Int) => wrap(floorDivInt(I1, I2)) requires I2 =/=Int 0
  rule floorDiv(_:Int, I2:Int) => trap                        requires I2 ==Int 0
  rule floorDiv(I1:Int, F2:Float) => floorDivF(i2f(I1), F2)
  rule floorDiv(F1:Float, I2:Int) => floorDivF(F1, i2f(I2))
  rule floorDiv(F1:Float, F2:Float) => floorDivF(F1, F2)

  rule null % _:Val => null      rule _:Val % null => null
  rule I1:Int   % I2:Int   => wrap(modFloorInt(I1, I2)) requires I2 =/=Int 0
  rule _:Int    % I2:Int   => trap                      requires I2 ==Int 0
  rule I1:Int   % F2:Float => modF(i2f(I1), F2)
  rule F1:Float % I2:Int   => modF(F1, i2f(I2))
  rule F1:Float % F2:Float => modF(F1, F2)

  // The Int floor pair over K's truncating `/Int` and `%Int` (INT.tdiv and
  // INT.tmod: the quotient toward zero, the remainder with the dividend's
  // sign): one adjustment when the remainder is nonzero and its sign is not
  // the divisor's, so that `a = q * b + r` with `r` between 0 and `b`.
  syntax Int ::= floorDivInt(Int, Int) [function]
               | modFloorInt(Int, Int) [function]
  rule floorDivInt(A:Int, B:Int) => (A /Int B) -Int 1
    requires (A %Int B) =/=Int 0 andBool (((A %Int B) <Int 0) =/=Bool (B <Int 0))
  rule floorDivInt(A:Int, B:Int) => A /Int B [owise]
  rule modFloorInt(A:Int, B:Int) => (A %Int B) +Int B
    requires (A %Int B) =/=Int 0 andBool (((A %Int B) <Int 0) =/=Bool (B <Int 0))
  rule modFloorInt(A:Int, B:Int) => A %Int B [owise]

  // [LEXP.7.15.1]'s row on a Float zero divisor, either zero, taken before
  // the composition: `//` by zero is the IEEE quotient, `%` by zero NaN.
  syntax Float ::= floorDivF(Float, Float) [function]
                 | modF(Float, Float)      [function]
  rule floorDivF(A:Float, B:Float) => A /Float B      requires B ==Float 0.0
  rule floorDivF(A:Float, B:Float) => ffloordiv(A, B) requires B =/=Float 0.0
  rule modF(_:Float, B:Float) => 0.0 /Float 0.0       requires B ==Float 0.0
  rule modF(A:Float, B:Float) => fmod(A, B)           requires B =/=Float 0.0

  // The IEEE specials, by the tests the header names: a NaN is unequal to
  // itself; an infinity is nonzero and equal to its own double.
  syntax Bool ::= isNaNF(Float) [function]
                | isInfF(Float) [function]
  rule isNaNF(F:Float) => F =/=Float F
  rule isInfF(F:Float) => F =/=Float 0.0 andBool F *Float 2.0 ==Float F

  // [LEXP.7.6] STEP 1: the EXACT remainder of the quotient truncated toward
  // zero, `a - b * trunc(a / b)` with no rounding, carrying `a`'s sign. NaN
  // when `a` is infinite or either operand is NaN; `a` when `b` is infinite
  // and `a` finite; else the magnitudes' loop with `a`'s sign put back. The
  // loop: while `r` is at or above `|b|`, subtract the largest `|b| * 2^k`
  // not above `r`, found by doubling (a double past the largest finite value
  // is an infinity and fails the test). Since `d <= r < 2d` the difference is
  // representable (Sterbenz) and `r - d < d`, so each round lowers the
  // exponent of what is left, and the exponent span of binary64 bounds the
  // rounds. A zero `b` never reaches it (the row above).
  syntax Float ::= exrem(Float, Float)      [function]
                 | reduceRem(Float, Float)  [function]
                 | stripRem(Float, Float)   [function]
                 | signAs(Float, Float)     [function]
  rule exrem(A:Float, B:Float) => A +Float B
    requires isNaNF(A) orBool isNaNF(B)
  rule exrem(A:Float, B:Float) => 0.0 /Float 0.0
    requires notBool isNaNF(A) andBool notBool isNaNF(B) andBool isInfF(A)
  rule exrem(A:Float, B:Float) => A
    requires notBool isNaNF(A) andBool notBool isNaNF(B) andBool notBool isInfF(A) andBool isInfF(B)
  rule exrem(A:Float, B:Float) => signAs(reduceRem(absFloat(A), absFloat(B)), A)
    requires notBool isNaNF(A) andBool notBool isNaNF(B) andBool notBool isInfF(A) andBool notBool isInfF(B)
  rule reduceRem(R:Float, B:Float) => reduceRem(stripRem(R, B), B) requires R >=Float B
  rule reduceRem(R:Float, B:Float) => R                            requires notBool (R >=Float B)
  rule stripRem(R:Float, D:Float) => stripRem(R, D *Float 2.0) requires D *Float 2.0 <=Float R
  rule stripRem(R:Float, D:Float) => R -Float D                requires notBool (D *Float 2.0 <=Float R)
  // `r` with `a`'s sign: negated below zero and for `-0.0`, which the
  // reciprocal tells from `+0.0`.
  rule signAs(R:Float, A:Float) => --Float R
    requires A <Float 0.0 orBool (A ==Float 0.0 andBool 1.0 /Float A <Float 0.0)
  rule signAs(R:Float, _:Float) => R [owise]

  // A zero with the sign of its argument (below zero, or `-0.0`).
  syntax Float ::= zeroSigned(Float) [function]
  rule zeroSigned(X:Float) => --Float 0.0
    requires X <Float 0.0 orBool (X ==Float 0.0 andBool 1.0 /Float X <Float 0.0)
  rule zeroSigned(_:Float) => 0.0 [owise]

  // [LEXP.7.6] STEPS 2 AND 3 over the exact remainder: a nonzero remainder
  // whose sign is not the divisor's moves by the divisor, rounded once; a
  // zero remainder is a zero with the divisor's sign; otherwise itself. A NaN
  // remainder is unequal to zero and below nothing, so it stays NaN.
  syntax Float ::= fmod(Float, Float)     [function]
                 | fmodFrom(Float, Float) [function]   // (b, r)
  rule fmod(A:Float, B:Float) => fmodFrom(B, exrem(A, B))
  rule fmodFrom(B:Float, R:Float) => R +Float B
    requires R =/=Float 0.0 andBool ((R <Float 0.0) =/=Bool (B <Float 0.0))
  rule fmodFrom(B:Float, R:Float) => zeroSigned(B) requires R ==Float 0.0
  rule fmodFrom(_:Float, R:Float) => R [owise]

  // [LEXP.7.5] STEPS 1 TO 4 over the exact remainder: `q = (a - r) / b`, the
  // subtraction and the division each rounded once; `q - 1`, rounded once,
  // when [LEXP.7.6]'s step 2 adjusted `r`; a zero `q` is a zero with the sign
  // of `a / b`; otherwise `f = floor q`, and `f + 1` when `q - f` exceeds a
  // half, else `f`. A NaN `q` is unequal to zero, floors to NaN and fails the
  // half test, so it gives NaN.
  syntax Float ::= ffloordiv(Float, Float)         [function]
                 | floorFrom(Float, Float, Float)  [function]   // (a, b, r)
                 | floorQ(Float, Float)            [function]   // (a / b, q)
                 | floorStep4(Float, Float)        [function]   // (q, floor q)
  rule ffloordiv(A:Float, B:Float) => floorFrom(A, B, exrem(A, B))
  rule floorFrom(A:Float, B:Float, R:Float) => floorQ(A /Float B, ((A -Float R) /Float B) -Float 1.0)
    requires R =/=Float 0.0 andBool ((R <Float 0.0) =/=Bool (B <Float 0.0))
  rule floorFrom(A:Float, B:Float, R:Float) => floorQ(A /Float B, (A -Float R) /Float B) [owise]
  rule floorQ(S:Float, Q:Float) => zeroSigned(S) requires Q ==Float 0.0
  rule floorQ(_:Float, Q:Float) => Q             requires isNaNF(Q)
  rule floorQ(_:Float, Q:Float) => floorStep4(Q, floorFloat(Q)) [owise]
  rule floorStep4(Q:Float, F:Float) => F +Float 1.0 requires Q -Float F >Float 0.5
  rule floorStep4(_:Float, F:Float) => F [owise]

  // ---- comparison -> Bool, null propagates ([LNUL.4.1]) ----
  rule null <  _:Val => null     rule _:Val <  null => null
  rule I1:Int   <  I2:Int   => I1 <Int I2
  rule I1:Int   <  F2:Float => i2f(I1) <Float F2
  rule F1:Float <  I2:Int   => F1 <Float i2f(I2)
  rule F1:Float <  F2:Float => F1 <Float F2

  rule null <= _:Val => null     rule _:Val <= null => null
  rule I1:Int   <= I2:Int   => I1 <=Int I2
  rule I1:Int   <= F2:Float => i2f(I1) <=Float F2
  rule F1:Float <= I2:Int   => F1 <=Float i2f(I2)
  rule F1:Float <= F2:Float => F1 <=Float F2

  rule null == _:Val => null     rule _:Val == null => null
  rule I1:Int   == I2:Int   => I1 ==Int I2
  rule I1:Int   == F2:Float => i2f(I1) ==Float F2
  rule F1:Float == I2:Int   => F1 ==Float i2f(I2)
  rule F1:Float == F2:Float => F1 ==Float F2
  rule B1:Bool  == B2:Bool  => B1 ==Bool B2

  rule null != _:Val => null     rule _:Val != null => null
  rule I1:Int   != I2:Int   => I1 =/=Int I2
  rule I1:Int   != F2:Float => i2f(I1) =/=Float F2
  rule F1:Float != I2:Int   => F1 =/=Float i2f(I2)
  rule F1:Float != F2:Float => F1 =/=Float F2
  rule B1:Bool  != B2:Bool  => B1 =/=Bool B2

  // ---- Kleene 3-valued connectives ([LNUL.4.2]) ----
  rule not true  => false
  rule not false => true
  rule not null  => null
  rule not trap  => trap

  rule true  and B:Bool3 => B          // and = min over false < null < true
  rule false and _:Val  => false
  rule null  and true   => null
  rule null  and null   => null
  rule null  and false  => false

  rule false or B:Bool3 => B           // or = max over false < null < true
  rule true  or _:Val  => true
  rule null  or true    => true
  rule null  or null    => null
  rule null  or false   => null

  // ---- a fault under a connective ([LNUL.4.2]): a deciding operand absorbs
  //      it on either side; with none, the connective is the fault, before it
  //      is `null`. Both operands are results by now, so "in any order" and
  //      "may stop at a deciding operand" have nothing left to change. ----
  rule false and trap  => false        rule trap and false => false
  rule true  and trap  => trap         rule trap and true  => trap
  rule null  and trap  => trap         rule trap and null  => trap
  rule trap  and trap  => trap

  rule true  or trap   => true         rule trap or true   => true
  rule false or trap   => trap         rule trap or false  => trap
  rule null  or trap   => trap         rule trap or null   => trap
  rule trap  or trap   => trap

  // ---- total null-test ([LNUL.4.4]) + coalesce ([LNUL.5.3], [LNUL.8.9]) ----
  // A fault has no value to test, and none to fall back from.
  rule null  is null => true
  rule trap  is null => trap
  rule _:Val is null => false [owise]

  // `d` is an Exp here, not a result: it is reduced only by the first rule,
  // once `x` is known to be `null`.
  rule null  ?? D:Exp => D
  rule trap  ?? _:Exp => trap
  rule V:Val ?? _:Exp => V   [owise]
endmodule

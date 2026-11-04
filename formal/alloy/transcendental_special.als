/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * The transcendental functions' special values ([LEXP.3.9.3]) -- the table, as a
 * relation, checked for being one (Alloy 6).
 *
 * NORMATIVE COMPANION, named and tagged as kleene_logic.als describes: every
 * element is <lowercased-clause-id>__<tag>, with the clause repeated above it.
 *
 * THE TABLE. [LEXP.3.9.3] states, for each of the fifteen functions of
 * [LEXP.3.9.1] (`pow` among them), the result at the operands where the function
 * has no real value or its value is a limit. Operands are taken here by CLASS:
 * the sign, whether zero, one or infinite, which side of 1 the magnitude is, and
 * for `pow`'s exponent whether it is an odd integer, another integer or not an
 * integer. Results are the IEEE values the table names. `lexp_3_9_3__row` is the
 * table, row by row, plus its NaN rule ("A NaN operand gives NaN, except in the
 * `pow` rows that say otherwise").
 *
 * WHAT IS CHECKED. That the table is a function and covers what it must:
 *   - one outcome: no two rows give one operand two results. The table's rows
 *     overlap -- `pow(+1, y)` and `pow(x, ±0)`; `pow(±0, -Inf)` under both the
 *     zero-base rows and the |x| < 1 rows; `atan2(±Inf, ±0)` under both the
 *     y < 0 / y > 0 rows and the infinite-y rows -- and every overlap must agree;
 *   - total on the operands it must decide: every operand pair with a NaN or an
 *     infinite component has exactly one result;
 *   - the signs IEEE's symmetries force: the odd functions at ±0 and ±Inf,
 *     `atan2` odd in y, `cos` and `cosh` even, a zero base's sign surviving only
 *     an odd integer exponent. A row typed with the wrong sign breaks one of these.
 *
 * READINGS this model takes, where the table's words leave room:
 *   - "|x| > 1" includes ±Inf, and "|x| < 1" includes ±0 (C Annex F's reading).
 *     Where that makes rows overlap they agree, which `one_outcome` checks.
 *   - In `atan2`, "x < 0" includes -Inf, "x > 0" includes +Inf, and "y < 0",
 *     "y > 0" include the infinities. Again the overlaps agree.
 *
 * WHAT IT DOES NOT CHECK. That the results are IEEE 754's: they are transcribed
 * from the clause, which states them. That an implementation returns them: that
 * is the conformance vectors' (E3). Regular operands: [LEXP.3.9.2]'s.
 *
 * TEETH. Change `pow`'s "|x| > 1, y -Inf" row to +Inf and `one_outcome` fails at
 * pow(+Inf, -Inf), where it meets the "x +Inf, y < 0" row. Give `atan2(-0, +0)` the result +0 and `atan2_odd_in_y` fails.
 * Drop the `exp(-Inf)` row and `specials_total` fails.
 */
module ds/transcendental_special

// ── vocabulary ───────────────────────────────────────────────────────────────

//@spec [LEXP.3.9.1]
// The fifteen functions: fourteen of [LEXP.3.9.1]'s table, and `pow`.
abstract sig lexp_3_9_1__fn {}
one sig Exp, Log, Log2, Log10, Sin, Cos, Tan, Asin, Acos, Atan, Atan2, Sinh, Cosh, Tanh, Pow extends lexp_3_9_1__fn {}

//@spec [LEXP.3.9.3]
// The first operand's class: `x`, or `atan2`'s `y`.
abstract sig lexp_3_9_3__a1 {}
one sig NaN1, NInf1, LtM1, M1, NFrac1, NZ1, PZ1, PFrac1, P1, GtP1, PInf1 extends lexp_3_9_3__a1 {}

//@spec [LEXP.3.9.3]
// The second operand's class: `pow`'s `y`, or `atan2`'s `x`; NA for a function
// of one argument. Finite nonzero values are split by integer parity, which only
// `pow` reads.
abstract sig lexp_3_9_3__a2 {}
one sig NA, NaN2, NInf2, NOdd2, NEven2, NFrac2, NZ2, PZ2, PFrac2, POdd2, PEven2, PInf2 extends lexp_3_9_3__a2 {}

//@spec [LEXP.3.9.3]
// The results the table names.
abstract sig lexp_3_9_3__res {}
one sig RNaN, RPZero, RNZero, ROne, RNegOne, RPInf, RNInf, RPPi, RNPi, RPPi2, RNPi2, RPPi4, RNPi4, RP3Pi4, RN3Pi4 extends lexp_3_9_3__res {}

//@spec [LEXP.3.9.3]
// A result's negation: "the result takes the operand's sign".
fun lexp_3_9_3__negr: lexp_3_9_3__res -> lexp_3_9_3__res {
  RPZero -> RNZero + RNZero -> RPZero + RPInf -> RNInf + RNInf -> RPInf
  + ROne -> RNegOne + RNegOne -> ROne + RPPi -> RNPi + RNPi -> RPPi
  + RPPi2 -> RNPi2 + RNPi2 -> RPPi2 + RPPi4 -> RNPi4 + RNPi4 -> RPPi4
  + RP3Pi4 -> RN3Pi4 + RN3Pi4 -> RP3Pi4 + RNaN -> RNaN
}

//@spec [LEXP.3.9.3]
// A first operand's mirror: the same magnitude, the other sign.
fun lexp_3_9_3__mirror1: lexp_3_9_3__a1 -> lexp_3_9_3__a1 {
  NZ1 -> PZ1 + PZ1 -> NZ1 + NFrac1 -> PFrac1 + PFrac1 -> NFrac1 + M1 -> P1
  + P1 -> M1 + LtM1 -> GtP1 + GtP1 -> LtM1 + NInf1 -> PInf1 + PInf1 -> NInf1
}

//@spec [LEXP.3.9.3]
fun lexp_3_9_3__neg1: set lexp_3_9_3__a1 { LtM1 + M1 + NFrac1 + NZ1 + NInf1 }

//@spec [LEXP.3.9.3]
fun lexp_3_9_3__pos1: set lexp_3_9_3__a1 { PFrac1 + P1 + GtP1 + PZ1 + PInf1 }

//@spec [LEXP.3.9.3]
// Finite and nonzero, by sign: first operand.
fun lexp_3_9_3__negfin1: set lexp_3_9_3__a1 { LtM1 + M1 + NFrac1 }
//@spec [LEXP.3.9.3]
fun lexp_3_9_3__posfin1: set lexp_3_9_3__a1 { PFrac1 + P1 + GtP1 }

//@spec [LEXP.3.9.3]
// Finite and nonzero, by sign: second operand.
fun lexp_3_9_3__negfin2: set lexp_3_9_3__a2 { NOdd2 + NEven2 + NFrac2 }
//@spec [LEXP.3.9.3]
fun lexp_3_9_3__posfin2: set lexp_3_9_3__a2 { POdd2 + PEven2 + PFrac2 }

//@spec [LEXP.3.9.3]
// "|x| < 1" and "|x| > 1", the infinities in the second (the header's reading).
fun lexp_3_9_3__under1: set lexp_3_9_3__a1 { NFrac1 + NZ1 + PZ1 + PFrac1 }
//@spec [LEXP.3.9.3]
fun lexp_3_9_3__over1: set lexp_3_9_3__a1 { LtM1 + GtP1 + NInf1 + PInf1 }

//@spec [LEXP.3.9.3]
// r is `pos` for a positive operand and its negation for a negative one.
pred lexp_3_9_3__by_sign_of[a: lexp_3_9_3__a1, pos, r: lexp_3_9_3__res] {
  (a in lexp_3_9_3__pos1 and r = pos) or (a in lexp_3_9_3__neg1 and r = pos.lexp_3_9_3__negr)
}

//@spec [LEXP.3.9.3]
// The functions of one argument.
fun lexp_3_9_3__unary: set lexp_3_9_1__fn { lexp_3_9_1__fn - Atan2 - Pow }

//@spec [LEXP.3.9.3]
// An operand tuple of the right arity.
pred lexp_3_9_3__wellformed[f: lexp_3_9_1__fn, a: lexp_3_9_3__a1, b: lexp_3_9_3__a2] {
  (f in lexp_3_9_3__unary and b = NA) or (f in Atan2 + Pow and b != NA)
}

// ── the table ────────────────────────────────────────────────────────────────

//@spec [LEXP.3.9.3]
// The rows for the functions of one argument.
pred lexp_3_9_3__unary_row[f: lexp_3_9_1__fn, a: lexp_3_9_3__a1, r: lexp_3_9_3__res] {
  (f = Exp and a in NZ1 + PZ1 and r = ROne)
  or (f = Exp and a = NInf1 and r = RPZero)
  or (f = Exp and a = PInf1 and r = RPInf)
  or (f in Log + Log2 + Log10 and a in NZ1 + PZ1 and r = RNInf)
  or (f in Log + Log2 + Log10 and a = P1 and r = RPZero)
  or (f in Log + Log2 + Log10 and a = PInf1 and r = RPInf)
  or (f in Log + Log2 + Log10 and a in lexp_3_9_3__negfin1 + NInf1 and r = RNaN)
  or (f in Sin + Tan and a in NZ1 + PZ1 and lexp_3_9_3__by_sign_of[a, RPZero, r])
  or (f = Cos and a in NZ1 + PZ1 and r = ROne)
  or (f in Sin + Cos + Tan and a in NInf1 + PInf1 and r = RNaN)
  or (f = Asin and a in NZ1 + PZ1 and lexp_3_9_3__by_sign_of[a, RPZero, r])
  or (f = Acos and a = P1 and r = RPZero)
  or (f in Asin + Acos and a in LtM1 + GtP1 + NInf1 + PInf1 and r = RNaN)
  or (f = Atan and a in NZ1 + PZ1 and lexp_3_9_3__by_sign_of[a, RPZero, r])
  or (f = Atan and a in NInf1 + PInf1 and lexp_3_9_3__by_sign_of[a, RPPi2, r])
  or (f in Sinh + Tanh and a in NZ1 + PZ1 and lexp_3_9_3__by_sign_of[a, RPZero, r])
  or (f = Sinh and a in NInf1 + PInf1 and lexp_3_9_3__by_sign_of[a, RPInf, r])
  or (f = Cosh and a in NZ1 + PZ1 and r = ROne)
  or (f = Cosh and a in NInf1 + PInf1 and r = RPInf)
  or (f = Tanh and a in NInf1 + PInf1 and lexp_3_9_3__by_sign_of[a, ROne, r])
}

//@spec [LEXP.3.9.3]
// `atan2(y, x)`'s rows; the result takes the sign of y.
pred lexp_3_9_3__atan2_row[y: lexp_3_9_3__a1, x: lexp_3_9_3__a2, r: lexp_3_9_3__res] {
  (y in NZ1 + PZ1 and x = NZ2 and lexp_3_9_3__by_sign_of[y, RPPi, r])
  or (y in NZ1 + PZ1 and x = PZ2 and lexp_3_9_3__by_sign_of[y, RPZero, r])
  or (y in NZ1 + PZ1 and x in lexp_3_9_3__negfin2 + NInf2 and lexp_3_9_3__by_sign_of[y, RPPi, r])
  or (y in NZ1 + PZ1 and x in lexp_3_9_3__posfin2 + PInf2 and lexp_3_9_3__by_sign_of[y, RPZero, r])
  or (y in lexp_3_9_3__negfin1 + NInf1 and x in NZ2 + PZ2 and r = RNPi2)
  or (y in lexp_3_9_3__posfin1 + PInf1 and x in NZ2 + PZ2 and r = RPPi2)
  or (y in lexp_3_9_3__negfin1 + lexp_3_9_3__posfin1 and x = NInf2 and lexp_3_9_3__by_sign_of[y, RPPi, r])
  or (y in lexp_3_9_3__negfin1 + lexp_3_9_3__posfin1 and x = PInf2 and lexp_3_9_3__by_sign_of[y, RPZero, r])
  or (y in NInf1 + PInf1 and x in lexp_3_9_3__negfin2 + lexp_3_9_3__posfin2 + NZ2 + PZ2
        and lexp_3_9_3__by_sign_of[y, RPPi2, r])
  or (y in NInf1 + PInf1 and x = NInf2 and lexp_3_9_3__by_sign_of[y, RP3Pi4, r])
  or (y in NInf1 + PInf1 and x = PInf2 and lexp_3_9_3__by_sign_of[y, RPPi4, r])
}

//@spec [LEXP.3.9.3]
// `pow(x, y)`'s rows.
pred lexp_3_9_3__pow_row[x: lexp_3_9_3__a1, y: lexp_3_9_3__a2, r: lexp_3_9_3__res] {
  (x = P1 and y != NA and r = ROne)
  or (y in NZ2 + PZ2 and r = ROne)
  or (x in NZ1 + PZ1 and y = NOdd2 and lexp_3_9_3__by_sign_of[x, RPInf, r])
  or (x in NZ1 + PZ1 and y in NEven2 + NFrac2 + NInf2 and r = RPInf)
  or (x in NZ1 + PZ1 and y = POdd2 and lexp_3_9_3__by_sign_of[x, RPZero, r])
  or (x in NZ1 + PZ1 and y in PEven2 + PFrac2 + PInf2 and r = RPZero)
  or (x = M1 and y in NInf2 + PInf2 and r = ROne)
  or (x in lexp_3_9_3__under1 and y = NInf2 and r = RPInf)
  or (x in lexp_3_9_3__over1 and y = NInf2 and r = RPZero)
  or (x in lexp_3_9_3__under1 and y = PInf2 and r = RPZero)
  or (x in lexp_3_9_3__over1 and y = PInf2 and r = RPInf)
  or (x = NInf1 and y = NOdd2 and r = RNZero)
  or (x = NInf1 and y in NEven2 + NFrac2 and r = RPZero)
  or (x = NInf1 and y = POdd2 and r = RNInf)
  or (x = NInf1 and y in PEven2 + PFrac2 and r = RPInf)
  or (x = PInf1 and y in lexp_3_9_3__negfin2 + NInf2 and r = RPZero)
  or (x = PInf1 and y in lexp_3_9_3__posfin2 + PInf2 and r = RPInf)
  or (x in lexp_3_9_3__negfin1 and y in NFrac2 + PFrac2 and r = RNaN)
}

//@spec [LEXP.3.9.3]
// "A NaN operand gives NaN, except in the `pow` rows that say otherwise."
pred lexp_3_9_3__nan_row[f: lexp_3_9_1__fn, a: lexp_3_9_3__a1, b: lexp_3_9_3__a2,
                         r: lexp_3_9_3__res] {
  lexp_3_9_3__wellformed[f, a, b]
  (a = NaN1 or b = NaN2)
  not (f = Pow and (a = P1 or b in NZ2 + PZ2))
  r = RNaN
}

//@spec [LEXP.3.9.3]
// The whole table: a row of it, or its NaN rule.
pred lexp_3_9_3__row[f: lexp_3_9_1__fn, a: lexp_3_9_3__a1, b: lexp_3_9_3__a2,
                     r: lexp_3_9_3__res] {
  (f in lexp_3_9_3__unary and b = NA and lexp_3_9_3__unary_row[f, a, r])
  or (f = Atan2 and b != NA and lexp_3_9_3__atan2_row[a, b, r])
  or (f = Pow and lexp_3_9_3__pow_row[a, b, r])
  or lexp_3_9_3__nan_row[f, a, b, r]
}

//@spec [LEXP.3.9.3]
// What the table gives an operand tuple: none (a regular operand, [LEXP.3.9.2]'s),
// or results.
fun lexp_3_9_3__result[f: lexp_3_9_1__fn, a: lexp_3_9_3__a1, b: lexp_3_9_3__a2]:
    set lexp_3_9_3__res {
  { r: lexp_3_9_3__res | lexp_3_9_3__row[f, a, b, r] }
}

// ── the table is consistent with itself ─────────────────────────────────────

//@probe
// The facts admit an instance: the table has rows and nothing above is empty.
run probe__special_table { some f: lexp_3_9_1__fn, a: lexp_3_9_3__a1, b: lexp_3_9_3__a2 |
  some lexp_3_9_3__result[f, a, b] } for 16

assert lexp_3_9_3__one_outcome {
  all f: lexp_3_9_1__fn, a: lexp_3_9_3__a1, b: lexp_3_9_3__a2 |
    lone lexp_3_9_3__result[f, a, b]
}
//@derives [LEXP.3.9.3]
check lexp_3_9_3__one_outcome for 16

assert lexp_3_9_3__specials_total {
  all f: lexp_3_9_1__fn, a: lexp_3_9_3__a1, b: lexp_3_9_3__a2 |
    (lexp_3_9_3__wellformed[f, a, b]
      and (a in NaN1 + NInf1 + PInf1 or b in NaN2 + NInf2 + PInf2))
      implies one lexp_3_9_3__result[f, a, b]
}
//@derives [LEXP.3.9.3]
check lexp_3_9_3__specials_total for 16

assert lexp_3_9_3__only_wellformed {
  all f: lexp_3_9_1__fn, a: lexp_3_9_3__a1, b: lexp_3_9_3__a2 |
    some lexp_3_9_3__result[f, a, b] implies lexp_3_9_3__wellformed[f, a, b]
}
//@derives [LEXP.3.9.3]
check lexp_3_9_3__only_wellformed for 16

// ── the signs IEEE's symmetries force ────────────────────────────────────────

assert lexp_3_9_3__odd_at_zero {
  all f: Sin + Tan + Asin + Atan + Sinh + Tanh |
    lexp_3_9_3__result[f, NZ1, NA] = lexp_3_9_3__result[f, PZ1, NA].lexp_3_9_3__negr
}
//@derives [LEXP.3.9.3]
check lexp_3_9_3__odd_at_zero for 16

assert lexp_3_9_3__odd_at_inf {
  all f: Atan + Sinh + Tanh |
    lexp_3_9_3__result[f, NInf1, NA] = lexp_3_9_3__result[f, PInf1, NA].lexp_3_9_3__negr
}
//@derives [LEXP.3.9.3]
check lexp_3_9_3__odd_at_inf for 16

assert lexp_3_9_3__even {
  all f: Cos + Cosh | lexp_3_9_3__result[f, NZ1, NA] = lexp_3_9_3__result[f, PZ1, NA]
  lexp_3_9_3__result[Cosh, NInf1, NA] = lexp_3_9_3__result[Cosh, PInf1, NA]
}
//@derives [LEXP.3.9.3]
check lexp_3_9_3__even for 16

assert lexp_3_9_3__atan2_odd_in_y {
  all y: lexp_3_9_3__a1 - NaN1, x: lexp_3_9_3__a2 - NA |
    lexp_3_9_3__result[Atan2, y.lexp_3_9_3__mirror1, x]
      = lexp_3_9_3__result[Atan2, y, x].lexp_3_9_3__negr
}
//@derives [LEXP.3.9.3]
check lexp_3_9_3__atan2_odd_in_y for 16

assert lexp_3_9_3__pow_zero_base_sign {
  all y: lexp_3_9_3__a2 - NA |
    lexp_3_9_3__result[Pow, NZ1, y]
      = (y in NOdd2 + POdd2 => lexp_3_9_3__result[Pow, PZ1, y].lexp_3_9_3__negr
                             else lexp_3_9_3__result[Pow, PZ1, y])
}
//@derives [LEXP.3.9.3]
check lexp_3_9_3__pow_zero_base_sign for 16

assert lexp_3_9_3__nan_exceptions {
  lexp_3_9_3__result[Pow, P1, NaN2] = ROne
  lexp_3_9_3__result[Pow, NaN1, NZ2] = ROne
  lexp_3_9_3__result[Pow, NaN1, PZ2] = ROne
  all f: lexp_3_9_3__unary | lexp_3_9_3__result[f, NaN1, NA] = RNaN
}
//@spec [LEXP.3.9.3]
check lexp_3_9_3__nan_exceptions for 16

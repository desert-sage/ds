/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS null semantics — Kleene 3-valued predicate logic model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lnul_4_2__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. DS predicate semantics are 3-valued over {true, false, null}: value
 * ops propagate null ([LNUL.4.1]), boolean and/or/not follow the Kleene tables
 * ([LNUL.4.2]), a `where` fires IFF true so both false and null decline to fire
 * ([LNUL.4.3]), and null-tests are total ([LNUL.4.4]). This model encodes the exact
 * Kleene tables and proves they form a proper Kleene algebra (De Morgan, involutive
 * negation, commutativity) AND deliver the safety collapse: a null (unknown) value
 * fires NEITHER positively NOR under negation — the "don't act on what you don't know"
 * property that the rejected null-as-false 2-valued reading violates.
 *
 * TEETH, measured one mutant at a time: make `not null = true`
 * (null read as false, then negated) and `lnul_4_3__null_never_fires` fails;
 * make `false and null = null` (pure propagation) and `lnul_4_2__de_morgan`
 * fails; make `not null = false` and `lnul_4_2__double_negation` fails.
 */
module ds/kleene_logic

//@spec [LNUL.4.2]
// The 3-valued truth domain the boolean operators range over: true, false, and the
// one canonical null ([LNUL.2.1]) read as "unknown".
abstract sig lnul_4_2__tri {}
one sig True  extends lnul_4_2__tri {}
one sig False extends lnul_4_2__tri {}
one sig Null  extends lnul_4_2__tri {}

//@spec [LNUL.4.1]
// Value level — a null operand propagates: any value-level operator with a null
// operand yields null ("unknown"). One abstract operator stands for every one the
// clause names — arithmetic, bitwise, comparison, interval relational, regex match
// — so the law is stated for all of them at once and the
// operators themselves are not drawn. (True stands for any non-null result here.)
fun lnul_4_1__value_op[a, b: lnul_4_2__tri]: lnul_4_2__tri {
  (a = Null or b = Null) => Null else True
}

//@spec [LNUL.4.2]
// Kleene AND: false dominates (false and anything = false); else null is contagious;
// else true. Note this is NOT pure propagation — `false and null = false`.
fun lnul_4_2__and[a, b: lnul_4_2__tri]: lnul_4_2__tri {
  (a = False or b = False) => False
    else ((a = Null or b = Null) => Null else True)
}

//@spec [LNUL.4.2]
// Kleene OR: true dominates; else null is contagious; else false.
fun lnul_4_2__or[a, b: lnul_4_2__tri]: lnul_4_2__tri {
  (a = True or b = True) => True
    else ((a = Null or b = Null) => Null else False)
}

//@spec [LNUL.4.2]
// Kleene NOT: swaps true/false, and fixes null (`not null = null`).
fun lnul_4_2__not[a: lnul_4_2__tri]: lnul_4_2__tri {
  (a = True) => False
    else ((a = False) => True else Null)
}

//@spec [LNUL.4.3]
// A `where` clause fires IFF it evaluates to true; false and null both decline —
// the collapse that keeps the Rete network 2-valued ([LNUL.9.2]).
pred lnul_4_3__fires[a: lnul_4_2__tri] { a = True }

//@spec [LNUL.4.4]
// A null-test (`x is null`, [LNUL.4.9]; `x == null` is a compile error) is TOTAL
// — true/false, never null; the only way to branch on absence inside a predicate.
fun lnul_4_4__is_null[a: lnul_4_2__tri]: lnul_4_2__tri {
  (a = Null) => True else False
}

//@spec [LNUL.5.3]
// Coalesce `x ?? d`: yields x when non-null, else the default d.
fun lnul_5_3__coalesce[x, d: lnul_4_2__tri]: lnul_4_2__tri {
  (x = Null) => d else x
}

//@probe
// Kleene is a proper refinement of pure null-propagation, not the rejected "any null
// kills the clause" reading: `false and null = false` and `true or null = true`
// — a null operand does NOT always yield null. Satisfiable.
run probe__kleene_refines_propagation {
  lnul_4_2__and[False, Null] = False and lnul_4_2__or[True, Null] = True
} for 3

// VALUE PROPAGATION: a value op with a null operand yields null ([LNUL.4.1]).
// NO counterexample.
assert lnul_4_1__value_propagates_null {
  all a, b: lnul_4_2__tri |
    (a = Null or b = Null) implies lnul_4_1__value_op[a, b] = Null
}
//@spec [LNUL.4.1]
check lnul_4_1__value_propagates_null for 3

// DE MORGAN: not(a and b) = (not a) or (not b), over all three values — a non-trivial
// law the Kleene tables satisfy and null-as-false breaks. NO counterexample.
assert lnul_4_2__de_morgan {
  all a, b: lnul_4_2__tri |
    lnul_4_2__not[lnul_4_2__and[a, b]]
      = lnul_4_2__or[lnul_4_2__not[a], lnul_4_2__not[b]]
}
//@derives [LNUL.4.2]
check lnul_4_2__de_morgan for 3

// INVOLUTIVE NEGATION: not(not a) = a. NO counterexample.
assert lnul_4_2__double_negation {
  all a: lnul_4_2__tri | lnul_4_2__not[lnul_4_2__not[a]] = a
}
//@derives [LNUL.4.2]
check lnul_4_2__double_negation for 3

// COMMUTATIVITY of Kleene and/or. NO counterexample.
assert lnul_4_2__and_or_commutative {
  all a, b: lnul_4_2__tri |
    lnul_4_2__and[a, b] = lnul_4_2__and[b, a]
      and lnul_4_2__or[a, b] = lnul_4_2__or[b, a]
}
//@derives [LNUL.4.2]
check lnul_4_2__and_or_commutative for 3

// SAFETY COLLAPSE: a null (unknown) value fires NEITHER positively NOR under negation
// — the LNUL.4.5 hot/cool example. null-as-false would spuriously fire
// the negated `cool` rule. NO counterexample.
assert lnul_4_3__null_never_fires {
  all a: lnul_4_2__tri |
    a = Null implies
      (not lnul_4_3__fires[a] and not lnul_4_3__fires[lnul_4_2__not[a]])
}
//@derives [LNUL.4.3]
check lnul_4_3__null_never_fires for 3

// NULL-TEST TOTALITY: is_null never yields null ([LNUL.4.4]) — total, unlike a value
// op. NO counterexample.
assert lnul_4_4__null_test_total {
  all a: lnul_4_2__tri | lnul_4_4__is_null[a] != Null
}
//@spec [LNUL.4.4]
check lnul_4_4__null_test_total for 3

// COALESCE PRODUCES A CONCRETE T: `x ?? d` with a non-null default is never null
// ([LNUL.5.3]). NO counterexample.
assert lnul_5_3__coalesce_non_null {
  all x, d: lnul_4_2__tri | d != Null implies lnul_5_3__coalesce[x, d] != Null
}
//@spec [LNUL.5.3]
check lnul_5_3__coalesce_non_null for 3

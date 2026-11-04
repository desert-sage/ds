/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS conversions — the `?`-presence bijection model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lcst_4_3__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. The postfix `::` cast encodes fallibility in the result type: `::T`
 * is total, `::T?` is fallible ([LCST.4.2]). The result is nullable iff the source is
 * nullable OR the conversion is fallible ([LCST.4.3.1]), and the `?`-presence is a
 * STRICT BIJECTION ([LCST.4.3.2]): the compiler accepts a cast iff the author's target
 * `?` mark exactly matches that result nullability — so a MISSING `?` on a nullable/
 * fallible result and a REDUNDANT `?` on a total non-null cast are BOTH rejected. This
 * model proves an accepted cast can carry neither error.
 *
 * TEETH: drop `lcst_4_3_2__accept_iff_mark_matches` and all three checks fail — an
 * accepted cast could then wear a missing or a redundant `?`.
 */
module ds/conversion_presence

//@spec [LCST.4.3]
// A static type's nullability — whether it admits `null` (`T?`) or not (`T`). Reused
// as the author's target `?` mark: Nullable = `::T?`, NonNull = `::T`.
abstract sig lcst_4_3__nullability {}
one sig NonNull  extends lcst_4_3__nullability {}
one sig Nullable extends lcst_4_3__nullability {}

//@spec [LCST.4.2]
// A conversion's fallibility, encoded in the result type: Total (`::T`, cannot fail)
// or Fallible (`::T?`, failure yields null).
abstract sig lcst_4_2__fallibility {}
one sig Total    extends lcst_4_2__fallibility {}
one sig Fallible extends lcst_4_2__fallibility {}

//@spec [LCST.4.3]
// A cast site: the source's nullability, the conversion's fallibility, and the
// nullability the author marked on the target (`::T` -> NonNull, `::T?` -> Nullable).
sig lcst_4_3__cast {
  source:      one lcst_4_3__nullability,
  fallibility: one lcst_4_2__fallibility,
  target_mark: one lcst_4_3__nullability
}

//@spec [LCST.4.3.1]
// The result of a cast is nullable IFF the source is nullable OR the conversion is
// fallible — the antecedent of the `?`-presence rule.
fun lcst_4_3_1__result_nullable[c: lcst_4_3__cast]: lcst_4_3__nullability {
  (c.source = Nullable or c.fallibility = Fallible) => Nullable else NonNull
}

//@spec [LCST.4.3.2]
// The subset of cast sites the compiler accepts (compiles).
sig lcst_4_3_2__accepted in lcst_4_3__cast {}

//@spec [LCST.4.3.2]
// The `?`-presence bijection: a cast is accepted IFF its target `?` mark equals its
// result nullability. This rejects BOTH a missing `?` (nullable/fallible result, a
// NonNull mark) and a redundant `?` (total non-null result, a Nullable mark).
fact lcst_4_3_2__accept_iff_mark_matches {
  all c: lcst_4_3__cast |
    c in lcst_4_3_2__accepted iff c.target_mark = lcst_4_3_1__result_nullable[c]
}

//@probe
// A world holding accepted casts across the fallible and nullable-source rows is
// satisfiable — the table rows coexist.
run probe__consistent {
  some lcst_4_3_2__accepted
  some c: lcst_4_3_2__accepted | c.fallibility = Fallible
  some c: lcst_4_3_2__accepted | c.source = Nullable
} for 6

// MISSING `?`: no accepted cast whose result is nullable lacks the `?` — an accepted
// nullable/fallible cast must carry the Nullable target mark. NO counterexample.
assert lcst_4_3_2__no_missing_mark {
  all c: lcst_4_3_2__accepted |
    lcst_4_3_1__result_nullable[c] = Nullable implies c.target_mark = Nullable
}
//@spec [LCST.4.3.2]
check lcst_4_3_2__no_missing_mark for 6

// REDUNDANT `?`: no accepted cast whose result is non-null wears a `?` — a total
// non-null cast must carry the NonNull target mark. NO counterexample.
assert lcst_4_3_2__no_redundant_mark {
  all c: lcst_4_3_2__accepted |
    lcst_4_3_1__result_nullable[c] = NonNull implies c.target_mark = NonNull
}
//@spec [LCST.4.3.2]
check lcst_4_3_2__no_redundant_mark for 6

// THE RULE: for an accepted cast the target is marked nullable IFF the source is
// nullable or the conversion is fallible ([LCST.4.3.1]). NO counterexample.
assert lcst_4_3_1__mark_iff_source_or_fallible {
  all c: lcst_4_3_2__accepted |
    (c.target_mark = Nullable) iff (c.source = Nullable or c.fallibility = Fallible)
}
//@spec [LCST.4.3.1]
check lcst_4_3_1__mark_iff_source_or_fallible for 6

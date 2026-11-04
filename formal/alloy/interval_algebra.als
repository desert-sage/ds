/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS intervals — the half-open interval algebra (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lint_3_2_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. An `Interval` is a half-open range `[start, end)` with `start <= end`
 * over one element type ([LINT.1.1]: any of the six types `<` orders; the endpoints are
 * named instants here after the time windows the document mostly speaks of). Every
 * predicate is a fixed boolean function of the two endpoints under the element type's one
 * total order, and reads nothing else of it:
 *   t in i          iff  i.start <= t  <  i.end            ([LINT.3.1.1])   -- upper bound STRICT
 *   i1 contains i2  iff  i1.start <= i2.start and i2.end <= i1.end          ([LINT.3.2.1])
 *   i1 overlaps i2  iff  max(i1.start, i2.start) < min(i1.end, i2.end)   ([LINT.4.1])
 * The half-open `<` on the upper edge is what makes adjacent ranges tile without overlap
 * ([LINT.4.3]), an empty interval overlap nothing ([LINT.4.4]), and boundary containment
 * (`contains`, `<=`) differ from membership (`in`, `<`) exactly at `i.end` ([LINT.3.2.3]).
 * This model proves those consequences plus overlaps-symmetry, contains-transitivity, and
 * contains(nonempty) ⇒ overlaps.
 *
 * TEETH: relax any half-open `<` to `<=` (or tighten a containment `<=` to `<`) and a check
 * fails — adjacent intervals overlap, an empty interval overlaps, or the `i.end` boundary
 * point becomes `in` the interval.
 */
module ds/interval_algebra
open util/ordering[lint_1_1__instant] as iord

//@spec [LINT.1.1]
// A value of the interval's element type T, one of the six types whose values `<`
// orders ([LINT.1.1]: Int and Float as one numeric type, String, Time, Date,
// Duration); named `instant` for the time windows the document mostly speaks of.
// util/ordering imposes the single total order start/end are compared under, and
// nothing below reads anything of T but that order -- which is what carries every
// check over to each element type alike.
sig lint_1_1__instant {}

//@spec [LINT.1.1]
// A half-open interval [start, end) over one element type; well-formed requires
// start <= end (empty iff equal, LINT.7.1).
sig lint_1_1__interval {
  start: one lint_1_1__instant,
  end:   one lint_1_1__instant
} { iord/lte[start, end] }

//@spec [LINT.3.1.1]
// t in i  iff  i.start <= t < i.end  (upper bound strict — the half-open edge).
pred lint_3_1_1__in [t: lint_1_1__instant, i: lint_1_1__interval] {
  iord/lte[i.start, t] and iord/lt[t, i.end]
}

//@spec [LINT.3.2.1]
// i1 contains i2  iff  i1.start <= i2.start and i2.end <= i1.end  (boundary-inclusive, both <=).
pred lint_3_2_1__contains [i1, i2: lint_1_1__interval] {
  iord/lte[i1.start, i2.start] and iord/lte[i2.end, i1.end]
}

//@spec [LINT.4.1]
// i1 overlaps i2  iff  max(starts) < min(ends) -- the intersection is non-empty.
// Expressed as the equivalent conjunction: both non-empty, and the two strict
// cross comparisons. The non-emptiness conjuncts are what [LINT.4.1] gained;
// without them an empty interval strictly inside a non-empty one "overlaps" it.
pred lint_4_1__overlaps [i1, i2: lint_1_1__interval] {
  iord/lt[i1.start, i1.end] and iord/lt[i2.start, i2.end]
  and iord/lt[i1.start, i2.end] and iord/lt[i2.start, i1.end]
}

//@spec [LINT.7.1]
// An interval is empty iff start == end.
pred lint_7_1__empty [i: lint_1_1__interval] {
  i.start = i.end
}

//@probe
// The half-open tiling scenario: two non-empty intervals abut (i1.end = i2.start) and do
// NOT overlap; the seam instant sits in an empty point-interval that i1 CONTAINS (boundary
// <=) yet is NOT `in` i1 (membership <). Satisfiable — exhibits both distinctions at once.
run probe__tiling_and_boundary {
  some i1, i2, e: lint_1_1__interval |
    (not lint_7_1__empty[i1] and not lint_7_1__empty[i2]
     and i1.end = i2.start
     and not lint_4_1__overlaps[i1, i2]
     and lint_7_1__empty[e] and e.start = i1.end
     and lint_3_2_1__contains[i1, e]
     and not lint_3_1_1__in[e.start, i1])
} for 6

// ADJACENT TILE WITHOUT OVERLAP: sharing a boundary (i1.end = i2.start) is not an overlap —
// the half-open upper edge makes ranges tile. NO counterexample.
assert lint_4_3__adjacent_no_overlap {
  all i1, i2: lint_1_1__interval |
    i1.end = i2.start implies not lint_4_1__overlaps[i1, i2]
}
//@derives [LINT.4.3]
check lint_4_3__adjacent_no_overlap for 6

// OVERLAPS IS SYMMETRIC: the relation does not depend on argument order. NO counterexample.
assert lint_4_1__overlaps_symmetric {
  all i1, i2: lint_1_1__interval |
    lint_4_1__overlaps[i1, i2] iff lint_4_1__overlaps[i2, i1]
}
//@derives [LINT.4.1]
check lint_4_1__overlaps_symmetric for 6

// EMPTY OVERLAPS NOTHING: an empty interval (start==end) has empty intersection with every
// interval: its own non-emptiness conjunct in [LINT.4.1] is false. NO counterexample.
assert lint_4_4__empty_overlaps_nothing {
  all i1, i2: lint_1_1__interval |
    lint_7_1__empty[i1] implies not lint_4_1__overlaps[i1, i2]
}
//@derives [LINT.4.4]
check lint_4_4__empty_overlaps_nothing for 6

// CONTAINS OF A NON-EMPTY INTERVAL IMPLIES OVERLAP: covering a range with positive extent
// necessarily intersects it. NO counterexample.
assert lint_3_2_1__contains_nonempty_overlaps {
  all i1, i2: lint_1_1__interval |
    (lint_3_2_1__contains[i1, i2] and not lint_7_1__empty[i2])
      implies lint_4_1__overlaps[i1, i2]
}
//@derives [LINT.3.2.1]
check lint_3_2_1__contains_nonempty_overlaps for 6

// CONTAINS IS TRANSITIVE: nested coverage composes. NO counterexample.
assert lint_3_2_1__contains_transitive {
  all i1, i2, i3: lint_1_1__interval |
    (lint_3_2_1__contains[i1, i2] and lint_3_2_1__contains[i2, i3])
      implies lint_3_2_1__contains[i1, i3]
}
//@derives [LINT.3.2.1]
check lint_3_2_1__contains_transitive for 6

// EMPTY-INTERVAL BOUNDARY CONTAINMENT: an empty i2 = (a..a) is contained by i1 iff a lies in
// the CLOSED range [i1.start, i1.end] — inclusive of i1.end, where the point is NOT `in` i1.
// This pins the contains(<=)/in(<) distinction. NO counterexample.
assert lint_3_2_3__empty_boundary_contained {
  all i1, i2: lint_1_1__interval |
    lint_7_1__empty[i2] implies
      (lint_3_2_1__contains[i1, i2]
         iff (iord/lte[i1.start, i2.start] and iord/lte[i2.start, i1.end]))
}
//@derives [LINT.3.2.3]
check lint_3_2_3__empty_boundary_contained for 6

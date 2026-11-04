/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS units — dimensional-consistency type-checking model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_luni_8__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. DS does NO automatic unit algebra ([LUNI.8]). The compiler accepts
 * a binary expression exactly when it is dimensionally sound: an additive op (`+`/`-`/
 * comparison) needs both operands in the SAME dimension ([LUNI.8.1] auto-convert,
 * [LUNI.8.2] cross-dimension reject); a dimensioned value with a bare scalar PRESERVES
 * the dimension for any op ([LUNI.8.3]); a dimensioned x dimensioned PRODUCT needs an
 * explicit `let` annotation or it is rejected ([LUNI.8.4], no silent unit inference).
 * This model encodes that acceptance rule and proves a cross-dimension add and an
 * un-annotated dimensioned product can never slip through.
 *
 * TEETH: drop `luni_8__accept_rule` and the [LUNI.8.1/8.2/8.4] checks fail — an
 * accepted binop could then add temperature to length, or infer a product's unit.
 */
module ds/unit_dimension

//@spec [LUNI.4.1]
// A dimension — the physical-quantity kind a value carries (temperature, length,
// ...). Values share a dimension iff they interconvert.
sig luni_4_1__dimension {}

//@spec [LUNI.8]
// A value in an expression carries at most one dimension: a dimensioned value (a
// unit-typed slot / literal / ::<unit> cast) has one; a bare scalar (plain Int/Float)
// has none.
sig luni_8__value { dim: lone luni_4_1__dimension }

//@spec [LUNI.8]
// The op class: Additive covers `+` / `-` / comparison (same-dimension rule); Mult
// covers `*` / `/` (the no-auto-algebra product rule).
abstract sig luni_8__opkind {}
one sig Additive extends luni_8__opkind {}
one sig Mult     extends luni_8__opkind {}

//@spec [LUNI.8]
// A binary expression: two operands, an op class, and the dimension of the author's
// `let` annotation if one is present (`some annotated` = annotated).
sig luni_8__binop {
  left:      one luni_8__value,
  right:     one luni_8__value,
  kind:      one luni_8__opkind,
  annotated: lone luni_4_1__dimension
}

//@spec [LUNI.8.2]
// A cross-dimension additive op — two dimensioned operands of DIFFERENT dimensions
// under `+`/`-`/comparison. A compile error ("temperature + length").
pred luni_8_2__cross_dim_additive[b: luni_8__binop] {
  some b.left.dim and some b.right.dim
  b.kind = Additive
  b.left.dim != b.right.dim
}

//@spec [LUNI.8.4]
// A dimensioned x dimensioned product with no annotation — the unit cannot be
// inferred, so it is a compile error unless a `let` annotation is supplied.
pred luni_8_4__unannotated_product[b: luni_8__binop] {
  some b.left.dim and some b.right.dim
  b.kind = Mult
  no b.annotated
}

//@spec [LUNI.8]
// The binops the compiler accepts (type-check).
sig luni_8__accepted in luni_8__binop {}

//@spec [LUNI.8]
// The dimensional type-check: a binop is accepted iff it is neither a cross-dimension
// add ([LUNI.8.2]) nor an un-annotated dimensioned product ([LUNI.8.4]). Same-
// dimension adds ([LUNI.8.1]), dimensioned-with-bare ([LUNI.8.3]), annotated
// products ([LUNI.8.4]), and plain bare arithmetic all pass.
fact luni_8__accept_rule {
  all b: luni_8__binop |
    b in luni_8__accepted iff
      (not luni_8_2__cross_dim_additive[b] and not luni_8_4__unannotated_product[b])
}

//@spec [LUNI.8.3]
// The result dimension: dimensioned-with-bare preserves the dimensioned operand's
// dimension; a same-dimension add keeps that dimension; an annotated product takes
// the annotation's dimension; bare-with-bare is bare.
fun luni_8_3__result_dim[b: luni_8__binop]: lone luni_4_1__dimension {
  (some b.left.dim and no b.right.dim) => b.left.dim
    else ((no b.left.dim and some b.right.dim) => b.right.dim
    else ((b.kind = Additive) => b.left.dim
    else b.annotated))
}

//@probe
// A world where a same-dimension add, a dimensioned-with-bare op, and an annotated
// dimensioned product are all accepted simultaneously is satisfiable.
run probe__consistent {
  some b: luni_8__accepted | b.kind = Additive and some b.left.dim and some b.right.dim
  some b: luni_8__accepted | some b.left.dim and no b.right.dim
  some b: luni_8__accepted | b.kind = Mult and some b.left.dim and some b.right.dim and some b.annotated
} for 6

// CROSS-DIMENSION REJECT: no accepted binop adds two different dimensions
// ([LUNI.8.2]) — temperature + length never type-checks. NO counterexample.
assert luni_8_2__no_cross_dimension {
  no b: luni_8__accepted | luni_8_2__cross_dim_additive[b]
}
//@spec [LUNI.8.2]
check luni_8_2__no_cross_dimension for 6

// PRODUCT NEEDS ANNOTATION: no accepted dimensioned x dimensioned product lacks an
// annotation ([LUNI.8.4]) — no silent unit inference. NO counterexample.
assert luni_8_4__product_needs_annotation {
  no b: luni_8__accepted | luni_8_4__unannotated_product[b]
}
//@spec [LUNI.8.4]
check luni_8_4__product_needs_annotation for 6

// SAME-DIMENSION ADD: an accepted additive op over two dimensioned operands has them
// in one shared dimension — auto-conversion is within a dimension ([LUNI.8.1]).
// NO counterexample.
assert luni_8_1__same_dimension_add {
  all b: luni_8__accepted |
    (b.kind = Additive and some b.left.dim and some b.right.dim)
      implies b.left.dim = b.right.dim
}
//@spec [LUNI.8.1]
check luni_8_1__same_dimension_add for 6

// BARE PRESERVES DIMENSION: a dimensioned value combined with a bare scalar yields a
// result of the dimensioned operand's dimension ([LUNI.8.3]). NO counterexample.
//
// A TRANSCRIPTION, NOT A REFUTATION: the two conjuncts are the first two cases
// of `luni_8_3__result_dim` read back, and rest on no fact -- the check holds
// of every binop, accepted or not. It is double-entry bookkeeping on the
// definition's transcription of the clause and is tagged `spec` for that
// reason.
assert luni_8_3__bare_preserves_dimension {
  all b: luni_8__accepted |
    ((some b.left.dim and no b.right.dim) implies luni_8_3__result_dim[b] = b.left.dim)
    and ((no b.left.dim and some b.right.dim) implies luni_8_3__result_dim[b] = b.right.dim)
}
//@spec [LUNI.8.3]
check luni_8_3__bare_preserves_dimension for 6

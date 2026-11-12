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
 * THE INVARIANT. DS does NO unit algebra ([LUNI.8]). The compiler accepts a binary
 * expression exactly when it is dimensionally sound, and the rule is by operator
 * class and by which operands carry a dimension:
 *
 *   `+` `-` `%` and the comparisons  two values of one dimension, or two bare
 *                                    numbers ([LUNI.8.1]); a bare number beside a
 *                                    dimensioned value is refused ([LUNI.8.3])
 *   `*`                              a dimensioned value scaled by a bare number,
 *                                    either order ([LUNI.8.3]); two dimensioned
 *                                    values are refused ([LUNI.8.4])
 *   `/` `//`                         a dimensioned value scaled by a bare number
 *                                    ([LUNI.8.3]); two values of one dimension,
 *                                    whose quotient is a bare number ([LUNI.8.1]);
 *                                    a bare number over a dimensioned value is
 *                                    refused ([LUNI.8.4])
 *   `**` and `math.pow`              bare numbers only ([LUNI.8.4])
 *
 * Two values of different dimensions are refused under every operator
 * ([LUNI.8.2]), and a `let` annotation admits nothing: it checks a type the
 * value already has ([LUNI.8.4], [LUNI.8.6]). A `Duration` is a value of the
 * `time` dimension and is a dimensioned value here like any other.
 *
 * The result of an accepted binop is dimensioned exactly where the clauses say:
 * scaling keeps the dimensioned operand's dimension ([LUNI.8.3]); a same-dimension
 * `+` `-` `%` keeps the dimension and a same-dimension quotient is bare
 * ([LUNI.8.1]); a comparison is a Bool; bare arithmetic is bare.
 *
 * NOT MODELLED: which of the two codes a refusal carries ([LUNI.8.2]'s
 * `DS_VALIDATE_DIM_MISMATCH`, [LUNI.8.4]'s `DS_VALIDATE_DIM_AMBIGUOUS`); the forms
 * of [LUNI.8.8] that stand beside each other as the operands of `+` do; the `::`
 * casts that make a value dimensioned or bare before this check ([LUNI.8.7]); a
 * `unit formula` bridging two dimensions ([LUNI.4.5]); the builtins of [LUNI.8.9].
 *
 * TEETH: drop `luni_8__accept_rule` and every check fails -- an accepted binop
 * could add temperature to length, add a bare number to a length, or multiply two
 * lengths. Admit `some b.annotated` in the rule and `luni_8_4__no_unit_algebra` and
 * `luni_8_4__annotation_admits_nothing` fail with an annotated product. Take
 * `Additive` out of `luni_8_3__bare_beside_dimensioned` and
 * `luni_8_3__bare_only_scales` fails with an accepted `x + n`. `probe__consistent`
 * is UNSAT if any accepted form is refused, so a check cannot pass over nothing.
 */
module ds/unit_dimension

//@spec [LUNI.4.1]
// A dimension — the physical-quantity kind a value carries (temperature, length,
// time, ...). Values share a dimension iff they interconvert.
sig luni_4_1__dimension {}

//@spec [LUNI.8]
// A value in an expression carries at most one dimension: a dimensioned value (a
// unit-typed slot / literal / ::<unit> cast, a `Duration`) has one; a bare number
// (plain Int/Float) has none.
sig luni_8__value { dim: lone luni_4_1__dimension }

//@spec [LUNI.8]
// The operator classes, one per rule: Additive is `+` / `-` / `%`; Compare the six
// comparisons; Scale is `*`; Quotient is `/` / `//`; Power is `**` and `math.pow`.
abstract sig luni_8__opkind {}
one sig Additive extends luni_8__opkind {}
one sig Compare  extends luni_8__opkind {}
one sig Scale    extends luni_8__opkind {}
one sig Quotient extends luni_8__opkind {}
one sig Power    extends luni_8__opkind {}

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
// Two dimensioned operands of DIFFERENT dimensions, under any operator. A compile
// error ("temperature + length", "meter / second").
pred luni_8_2__cross_dimension[b: luni_8__binop] {
  some b.left.dim and some b.right.dim
  b.left.dim != b.right.dim
}

//@spec [LUNI.8.3]
// A bare number beside a dimensioned value as an operand of `+`, `-` or `%`, in
// either order, or in a comparison. A compile error: the number takes no dimension
// from the operand beside it.
pred luni_8_3__bare_beside_dimensioned[b: luni_8__binop] {
  b.kind in Additive + Compare
  (some b.left.dim and no b.right.dim) or (no b.left.dim and some b.right.dim)
}

//@spec [LUNI.8.4]
// No unit algebra: a result with no dimension DS can state. `*` of two dimensioned
// values; `/` and `//` of two values of different dimensions, and of a bare number
// by a dimensioned value; `**` with a dimensioned operand on either side. The
// cross-dimension quotient is [LUNI.8.2]'s case as well; the two clauses name it
// alike as refused.
pred luni_8_4__unstatable[b: luni_8__binop] {
  (b.kind = Scale and some b.left.dim and some b.right.dim)
  or (b.kind = Quotient and some b.left.dim and some b.right.dim and b.left.dim != b.right.dim)
  or (b.kind = Quotient and no b.left.dim and some b.right.dim)
  or (b.kind = Power and (some b.left.dim or some b.right.dim))
}

//@spec [LUNI.8]
// The binops the compiler accepts (type-check).
sig luni_8__accepted in luni_8__binop {}

//@spec [LUNI.8]
// The dimensional type-check: a binop is accepted iff it is none of the three
// refusals -- a cross-dimension pair ([LUNI.8.2]), a bare number beside a dimensioned
// value under `+` `-` `%` or a comparison ([LUNI.8.3]), a form with no statable
// dimension ([LUNI.8.4]). What is left is [LUNI.8.1]'s same-dimension forms,
// [LUNI.8.3]'s scaling, and bare arithmetic. The annotation is read by nothing.
fact luni_8__accept_rule {
  all b: luni_8__binop |
    b in luni_8__accepted iff
      (not luni_8_2__cross_dimension[b]
       and not luni_8_3__bare_beside_dimensioned[b]
       and not luni_8_4__unstatable[b])
}

//@spec [LUNI.8.3]
//@spec [LUNI.8.1]
// The result's dimension, read on an accepted binop: a dimensioned value scaled by a
// bare number keeps its dimension ([LUNI.8.3]: `x * n`, `n * x`, `x / n`, `x // n`);
// a same-dimension `+` `-` `%` keeps the dimension and a same-dimension quotient is
// a bare number ([LUNI.8.1]); a comparison is a Bool; bare arithmetic is bare.
fun luni_8_3__result_dim[b: luni_8__binop]: lone luni_4_1__dimension {
  (b.kind in Scale + Quotient and some b.left.dim and no b.right.dim) => b.left.dim
    else ((b.kind = Scale and no b.left.dim and some b.right.dim) => b.right.dim
    else ((b.kind = Additive) => b.left.dim
    else none))
}

//@probe
// A world where every accepted form and two refusals stand together is satisfiable:
// a same-dimension add, a same-dimension quotient of two dimensioned values, a value
// scaled by a bare number under `*` and under `/`, a bare power, a refused
// annotated product, and a refused `x + n`. RunAlloy fails this run if it is
// UNSAT, which is what keeps the checks below from passing over nothing.
run probe__consistent {
  some b: luni_8__accepted | b.kind = Additive and some b.left.dim and some b.right.dim
  some b: luni_8__accepted | b.kind = Quotient and some b.left.dim and some b.right.dim
  some b: luni_8__accepted | b.kind = Scale and some b.left.dim and no b.right.dim
  some b: luni_8__accepted | b.kind = Quotient and some b.left.dim and no b.right.dim
  some b: luni_8__accepted | b.kind = Power and no b.left.dim and no b.right.dim
  some b: luni_8__binop - luni_8__accepted |
    b.kind = Scale and some b.annotated and some b.left.dim and some b.right.dim
  some b: luni_8__binop - luni_8__accepted |
    b.kind = Additive and some b.left.dim and no b.right.dim
} for 8

// CROSS-DIMENSION REJECT: no accepted binop combines two different dimensions,
// under any operator ([LUNI.8.2]) -- temperature + length and meter / second never
// type-check. NO counterexample. A restatement of the rule's first exclusion.
assert luni_8_2__no_cross_dimension {
  no b: luni_8__accepted | luni_8_2__cross_dimension[b]
}
//@spec [LUNI.8.2]
check luni_8_2__no_cross_dimension for 6

// SAME DIMENSION: an accepted binop over two dimensioned operands has them in one
// dimension, is a `+` `-` `%`, a comparison or a quotient -- never a product or a
// power -- and its result keeps the dimension under `+` `-` `%` and is a bare number
// under `/` and `//` ([LUNI.8.1]). NO counterexample. Derived: the operator half
// rests on all three exclusions, the result half on `luni_8_3__result_dim`.
assert luni_8_1__same_dimension {
  all b: luni_8__accepted {
    (some b.left.dim and some b.right.dim) implies {
      b.left.dim = b.right.dim
      b.kind in Additive + Compare + Quotient
      b.kind = Additive implies luni_8_3__result_dim[b] = b.left.dim
      b.kind = Quotient implies no luni_8_3__result_dim[b]
    }
  }
}
//@spec [LUNI.8.1]
check luni_8_1__same_dimension for 6

// A BARE NUMBER ONLY SCALES: an accepted binop with exactly one dimensioned operand
// is a `*` either way round or a `/` `//` with the dimensioned value on the left,
// and its result has that operand's dimension ([LUNI.8.3]). So no accepted `x + n`,
// `n - x`, `x % n`, `x < n` or `n / x` exists. NO counterexample. Derived: the
// operator half rests on the [LUNI.8.3] and [LUNI.8.4] exclusions, the result half
// on `luni_8_3__result_dim`.
assert luni_8_3__bare_only_scales {
  all b: luni_8__accepted {
    (some b.left.dim and no b.right.dim) implies
      (b.kind in Scale + Quotient and luni_8_3__result_dim[b] = b.left.dim)
    (no b.left.dim and some b.right.dim) implies
      (b.kind = Scale and luni_8_3__result_dim[b] = b.right.dim)
  }
}
//@spec [LUNI.8.3]
check luni_8_3__bare_only_scales for 6

// NO UNIT ALGEBRA: no accepted binop is a form with no statable dimension
// ([LUNI.8.4]) -- no dimensioned product, no bare-over-dimensioned quotient, no
// dimensioned power, annotation or not. NO counterexample. A restatement of the
// rule's third exclusion.
assert luni_8_4__no_unit_algebra {
  no b: luni_8__accepted | luni_8_4__unstatable[b]
}
//@spec [LUNI.8.4]
check luni_8_4__no_unit_algebra for 6

// THE ANNOTATION ADMITS NOTHING: two binops alike in their operands' dimensions and
// their operator are accepted or refused alike, whatever either is annotated with
// ([LUNI.8.4]: refused "under a `let` annotation too"). NO counterexample. Derived:
// acceptance is a function of the dimensions and the operator alone; a rule that
// read `annotated` would fail it.
assert luni_8_4__annotation_admits_nothing {
  all b1, b2: luni_8__binop |
    (b1.left.dim = b2.left.dim and b1.right.dim = b2.right.dim and b1.kind = b2.kind)
      implies (b1 in luni_8__accepted iff b2 in luni_8__accepted)
}
//@spec [LUNI.8.4]
check luni_8_4__annotation_admits_nothing for 6

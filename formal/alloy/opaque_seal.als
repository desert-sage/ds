/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS opaque types — the one-way seal model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lopq_4_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. An opaque type is nominal and distinct from its representation
 * ([LOPQ.2.3]), sealed one-way ([LOPQ.4]): a rule MUST NOT construct an opaque value from
 * its representation ([LOPQ.4.1], forge), MUST NOT eliminate one to its representation
 * ([LOPQ.4.3], extract), and an opaque value originates only from a CLOSED trusted set —
 * adapter ingest, a declared operation, or an adapter-contract constant ([LOPQ.4.2]) —
 * never a rule construction. This model represents the rule-level derivation graph and
 * proves no rule flow crosses the opaque/representation boundary in either direction, and
 * that every opaque value's origin is one of the three trusted sources.
 *
 * TEETH: drop `lopq_4__seal_no_crossing` and a forge (opaque-from-representation) or
 * extract (representation-from-opaque) path appears; drop
 * `lopq_4_2__no_rule_constructed_origin` and an opaque value acquires a rule-constructed
 * origin outside the trusted set.
 */
module ds/opaque_seal

//@spec [LOPQ.4.2]
// Where an opaque value can originate. The first three are the closed trusted set; the
// fourth (RuleConstructed) is the forge origin the seal forbids.
abstract sig lopq_4_2__origin {}
one sig Ingest          extends lopq_4_2__origin {}   // adapter ingest across IDSP
one sig DeclaredOp      extends lopq_4_2__origin {}   // a declared op returning the type
one sig Constant        extends lopq_4_2__origin {}   // an adapter-contract constant
one sig RuleConstructed extends lopq_4_2__origin {}   // forbidden: rule-level construction

//@spec [LOPQ.2.3]
// A value — either an opaque value or a representation value. The two are nominal and
// distinct (disjoint), with no implicit conversion.
abstract sig lopq_2_3__value {}

//@spec [LOPQ.2.3]
// An opaque value, carrying its provenance origin.
sig lopq_2_3__opaque extends lopq_2_3__value { origin: one lopq_4_2__origin }

//@spec [LOPQ.2.3]
// A representation value (the underlying bytes an adapter holds).
sig lopq_2_3__repr extends lopq_2_3__value {}

//@spec [LOPQ.4]
// The rule-level derivation graph: `result -> input` — a rule-derived value points to the
// values it was derived from.
one sig lopq_4__rules { flows: lopq_2_3__value -> lopq_2_3__value }

//@spec [LOPQ.4]
// The seal: no rule derivation crosses the opaque/representation boundary — an opaque value
// is never derived from a representation ([LOPQ.4.1], forge) and a representation is never
// derived from an opaque value ([LOPQ.4.3], extract).
fact lopq_4__seal_no_crossing {
  no (lopq_2_3__opaque -> lopq_2_3__repr) & lopq_4__rules.flows
  no (lopq_2_3__repr -> lopq_2_3__opaque) & lopq_4__rules.flows
}

//@spec [LOPQ.4.2]
// An opaque value never has a rule-constructed origin — it originates only from the closed
// trusted set.
fact lopq_4_2__no_rule_constructed_origin {
  no o: lopq_2_3__opaque | o.origin = RuleConstructed
}

//@probe
// Rule derivation WITHIN each side is fine: an opaque value derived from another opaque,
// and a representation derived from another representation, coexist. Satisfiable.
run probe__within_side_flows {
  some disj o1, o2: lopq_2_3__opaque | ((o1 -> o2) in lopq_4__rules.flows)
  some disj r1, r2: lopq_2_3__repr | ((r1 -> r2) in lopq_4__rules.flows)
} for 6

// NO FORGE: no opaque value is (transitively) rule-derived from a representation — the seal
// blocks construction from the underlying bytes ([LOPQ.4.1]). NO counterexample.
assert lopq_4_1__no_forge_path {
  all o: lopq_2_3__opaque | no (o.^(lopq_4__rules.flows) & lopq_2_3__repr)
}
//@derives [LOPQ.4.1]
check lopq_4_1__no_forge_path for 6

// NO EXTRACT: no representation is (transitively) rule-derived from an opaque value — the
// seal blocks elimination to the underlying bytes ([LOPQ.4.3]). NO counterexample.
assert lopq_4_3__no_extract_path {
  all r: lopq_2_3__repr | no (r.^(lopq_4__rules.flows) & lopq_2_3__opaque)
}
//@derives [LOPQ.4.3]
check lopq_4_3__no_extract_path for 6

// ORIGIN IS TRUSTED: every opaque value originates from exactly the closed set — adapter
// ingest, a declared operation, or an adapter constant — never a rule construction
// ([LOPQ.4.2]). NO counterexample.
assert lopq_4_2__origin_is_trusted {
  all o: lopq_2_3__opaque | o.origin in (Ingest + DeclaredOp + Constant)
}
//@spec [LOPQ.4.2]
check lopq_4_2__origin_is_trusted for 6

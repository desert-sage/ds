/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS Rete network — shared-alpha dedup integrity model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_iret_6_6__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. Two rules with identical patterns on the same schema and identical
 * tests share ONE alpha node ([IRET.6.6]) — the compiler dedups by (schema, tests),
 * and the loaded node may be the right input to several beta nodes. This model
 * proves (schema, tests) is a unique key for alpha nodes, so sharing is exact: any
 * two beta right-inputs with the same key are the very same node, never a duplicate.
 *
 * TEETH: drop `iret_6_6__alpha_dedup` and both checks fail — two distinct alpha
 * nodes share a (schema, tests) key, so betas that should share reference duplicates.
 */
module ds/rete_integrity

//@spec [IRET.6.6]
// A schema (the alpha-dispatch key).
sig iret_6_6__schema {}

//@spec [IRET.6.6]
// The set of alpha tests on a schema (EQ / CMP / REGEX predicates).
sig iret_6_6__test_set {}

//@spec [IRET.6.6]
// An alpha node, keyed by (schema, tests) — the dedup identity.
sig iret_6_6__alpha_node {
  schema: one iret_6_6__schema,
  tests:  one iret_6_6__test_set
}

//@spec [IRET.6.6]
// The compiler deduplicates: no two distinct alpha nodes share a (schema, tests)
// key — identical patterns collapse to one node.
fact iret_6_6__alpha_dedup {
  all disj a, b: iret_6_6__alpha_node |
    not (a.schema = b.schema and a.tests = b.tests)
}

//@spec [IRET.7.4]
// A beta (join) node; `right_input` is the alpha node feeding its right side — one
// alpha may feed many betas.
sig iret_7_4__beta_node { right_input: one iret_6_6__alpha_node }

//@probe
// One alpha node shared as the right input of two distinct beta nodes is
// satisfiable.
run probe__consistent {
  some disj b1, b2: iret_7_4__beta_node | b1.right_input = b2.right_input
} for 6

// DEDUP KEY: two alpha nodes with the same (schema, tests) are the same node —
// (schema, tests) uniquely identifies an alpha node. NO counterexample.
assert iret_6_6__dedup_key_identifies {
  all a, b: iret_6_6__alpha_node |
    (a.schema = b.schema and a.tests = b.tests) implies a = b
}
//@spec [IRET.6.6]
check iret_6_6__dedup_key_identifies for 6

// EXACT SHARING: two beta nodes whose right inputs carry the same (schema, tests)
// reference the very same alpha node — sharing is exact, never a duplicate. NO
// counterexample.
assert iret_6_6__sharing_is_exact {
  all b1, b2: iret_7_4__beta_node |
    (b1.right_input.schema = b2.right_input.schema
     and b1.right_input.tests = b2.right_input.tests)
      implies b1.right_input = b2.right_input
}
//@spec [IRET.6.6]
check iret_6_6__sharing_is_exact for 6

/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS CallError.code hierarchy — dot-prefix matching model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lecc_1_3__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. A CallError code is a dotted path — leftmost segment the family,
 * at most four segments ([LECC.1.3]/[LECC.1.4]). An `error <pattern>:` clause
 * matches a code iff the pattern is a SEGMENT-BOUNDARY prefix ([LCCO.8.3.2]):
 * `auth` matches `auth.failed`, but `auth.fail` does NOT — matching is by whole
 * segments, not characters. Modelled as a trie (each node = a segment path, its
 * parent = the one-segment-shorter prefix), this proves: the patterns matching a
 * code form a CHAIN (an unambiguous most-specific match), and two distinct
 * siblings never match each other (the segment-boundary rule).
 *
 * TEETH: drop `lecc_1_3__hierarchy_is_a_forest` and the chain check fails — a node
 * with two parents gives two incomparable patterns matching one code.
 */
module ds/call_error_hierarchy

//@spec [LECC.1.3]
// A node in the dotted-code hierarchy: a segment path (e.g. `auth`, `auth.failed`).
// `parent` is the one-segment-shorter prefix; family nodes (leftmost segment)
// have none. Modelled as a general relation so the forest shape is a checkable fact.
sig lecc_1_3__code_node { parent: set lecc_1_3__code_node }

//@spec [LECC.1.3]
// The hierarchy is a forest (trie): each node has at most one immediate prefix and
// no node is its own ancestor.
fact lecc_1_3__hierarchy_is_a_forest {
  all n: lecc_1_3__code_node | lone n.parent
  no n: lecc_1_3__code_node | n in n.^parent
}

//@spec [LECC.1.4]
// At most four segments: a node has at most three strict ancestors.
fact lecc_1_4__depth_bounded {
  all n: lecc_1_3__code_node | #(n.^parent) <= 3
}

//@spec [LCCO.8.3.2]
// A pattern matches a code iff it is a segment-boundary prefix — i.e. an
// ancestor-or-self of the code in the trie. `auth` matches `auth.failed`;
// `auth.fail` (a distinct sibling of `auth.failed`) does not.
fun lcco_8_3_2__matches : lecc_1_3__code_node -> lecc_1_3__code_node {
  { p: lecc_1_3__code_node, c: lecc_1_3__code_node | p in c.*parent }
}

//@probe
// Two distinct sibling leaves under one family (the `auth.fail` / `auth.failed`
// shape) — they exist and, per the check below, never match each other.
run probe__consistent {
  some disj a, b: lecc_1_3__code_node | some a.parent and a.parent = b.parent
} for 6

// UNAMBIGUOUS: the patterns that match a code form a chain — any two of them are
// prefix-comparable (one matches the other), so there is always a well-defined
// most-specific match. NO counterexample.
assert lcco_8_3_2__matches_form_a_chain {
  all c: lecc_1_3__code_node, disj p1, p2: lecc_1_3__code_node |
    (p1 -> c in lcco_8_3_2__matches and p2 -> c in lcco_8_3_2__matches)
      implies (p1 -> p2 in lcco_8_3_2__matches or p2 -> p1 in lcco_8_3_2__matches)
}
//@derives [LCCO.8.3.2]
check lcco_8_3_2__matches_form_a_chain for 6

// SEGMENT BOUNDARY: two distinct siblings never match each other — `auth.fail`
// does not match `auth.failed`. Matching is by whole segments, not characters.
// NO counterexample.
assert lcco_8_3_2__siblings_do_not_match {
  all disj a, b: lecc_1_3__code_node |
    (some a.parent and a.parent = b.parent)
      implies (a -> b not in lcco_8_3_2__matches and b -> a not in lcco_8_3_2__matches)
}
//@derives [LCCO.8.3.2]
check lcco_8_3_2__siblings_do_not_match for 6

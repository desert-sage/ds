/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS rule-graph cycle detection — compile-time acyclicity model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lcyc_3_2_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. The compiler builds a rule graph — nodes are rules ([LCYC.3.2.1]),
 * an edge A->B exists when A's RHS can trigger or disable B's LHS ([LCYC.3.2.2]) —
 * and refuses every cycle inside an SCC that [LCYC.3.1.1] does not admit. This
 * model draws the EMIT and NEGATION edges at literal precision; the admission,
 * and the withdraw edges of [LCYC.3.2.2]'s fourth and fifth forms, which no
 * literal breaks, are derivation_graph.als's. Two subtleties
 * this model pins:
 *   - [LCYC.6.1] emit edges are LITERAL-PRECISE: `kind==enter -> emit kind:leave`
 *     breaks the self-edge (a kind-flip cannot re-trigger itself), while a
 *     same-literal self-emit — and a two-rule literal oscillation — are real cycles.
 *   - [LCYC.3.4] negation edges (A emits what B requires absent) are IN the graph,
 *     so "rules that defeat each other" (mutual negation) is caught as a cycle.
 * So `lcyc_3_3_1__graph` below is the emit and negation edges alone, the graph
 * the two checks are about; the compiler's graph adds the withdraw edges. The
 * Idris termination certificate keeps the edges this model drops.
 *
 * TEETH: drop `emits_lit` from `lcyc_6_1__edges` and the kind-flip check fails
 * (a false self-cycle); drop `lcyc_3_4_1__disables` from the graph and the
 * defeat-each-other check fails (a mutual-negation loop slips through).
 */
module ds/cycle_detection

//@spec [LCYC.3.2.2]
// A fact schema/kind (the `emit X` / `X` pattern join key).
sig lcyc_3_2_2__fact_kind {}

//@spec [LCYC.6.1]
// A slot literal value (the `slot == X` / `slot: Y` comparison).
sig lcyc_6_1__literal {}

//@spec [LCYC.3.2.1]
// A rule: the (kind, literal) it matches on its LHS, the (kind, literal) it emits,
// and — if it carries a `no` pattern — the (kind, literal) it requires ABSENT.
sig lcyc_3_2_1__rule {
  matches_kind: one lcyc_3_2_2__fact_kind,
  matches_lit:  one lcyc_6_1__literal,
  emits_kind:   one lcyc_3_2_2__fact_kind,
  emits_lit:    one lcyc_6_1__literal,
  absent_kind:  lone lcyc_3_2_2__fact_kind,
  absent_lit:   lone lcyc_6_1__literal
}

//@spec [LCYC.6.1]
// Literal-precise trigger edges: A -> B iff A's emit satisfies B's LHS — same kind
// AND same literal ([LCYC.6.1.2]). Different comparable literals break the edge.
fun lcyc_6_1__edges : lcyc_3_2_1__rule -> lcyc_3_2_1__rule {
  { a: lcyc_3_2_1__rule, b: lcyc_3_2_1__rule |
      a.emits_kind = b.matches_kind and a.emits_lit = b.matches_lit }
}

//@spec [LCYC.3.4.1]
// Negation edges: A disables B iff A emits exactly what B requires absent — A's
// firing makes B's `no` condition impossible.
fun lcyc_3_4_1__disables : lcyc_3_2_1__rule -> lcyc_3_2_1__rule {
  { a: lcyc_3_2_1__rule, b: lcyc_3_2_1__rule |
      a.emits_kind = b.absent_kind and a.emits_lit = b.absent_lit }
}

//@spec [LCYC.3.3.1]
// The full rule graph the compiler runs cycle detection over: trigger edges plus
// negation edges.
fun lcyc_3_3_1__graph : lcyc_3_2_1__rule -> lcyc_3_2_1__rule {
  lcyc_6_1__edges + lcyc_3_4_1__disables
}

//@probe
// A non-trivial graph with both a trigger edge and a negation edge is satisfiable.
run probe__consistent { some lcyc_6_1__edges and some lcyc_3_4_1__disables } for 5

// LITERAL PRECISION, PER EDGE: an edge exists iff the emit satisfies the
// target's LHS — same kind AND same literal. A kind-flip carries no edge
// whether it emits back to itself (`kind==enter -> emit kind:leave`) or the
// flip is spread across two rules; a same-literal emit carries one either way.
// Quantifying over all pairs SUBSUMES the self-edge case at a = b, which is
// [LCYC.6.1.1]'s point: rule count does not decide it. NO counterexample.
assert lcyc_6_1__literal_mismatch_breaks_edge {
  all a, b: lcyc_3_2_1__rule |
    (a.emits_kind = b.matches_kind and a.emits_lit != b.matches_lit)
      implies a -> b not in lcyc_6_1__edges
  all a, b: lcyc_3_2_1__rule |
    (a.emits_kind = b.matches_kind and a.emits_lit = b.matches_lit)
      implies a -> b in lcyc_6_1__edges
}
//@spec [LCYC.6.1]
check lcyc_6_1__literal_mismatch_breaks_edge for 6

// DEFEAT EACH OTHER: two rules that mutually negate (A emits what B forbids and B
// emits what A forbids) form a cycle in the rule graph, so the acyclicity check
// catches them — the negation edges must be in the graph. NO counterexample.
assert lcyc_3_4_1__defeat_is_a_cycle {
  all disj a, b: lcyc_3_2_1__rule |
    (a -> b in lcyc_3_4_1__disables and b -> a in lcyc_3_4_1__disables)
      implies a in a.^lcyc_3_3_1__graph
}
//@derives [LCYC.3.4.1]
check lcyc_3_4_1__defeat_is_a_cycle for 6

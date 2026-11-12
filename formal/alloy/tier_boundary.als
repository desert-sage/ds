/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS tier boundary — cross-tier fact-flow acyclicity model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_ltie_3_2__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. Facts flow UPWARD-ONLY across tier boundaries ([LTIE.3.1]) and
 * the tier graph is a DAG ([LTIE.3.2]); the higher tier's one influence on the
 * lower, a call, introduces NO cross-tier fact edge ([LTIE.5.4]): what the
 * integrator asserts into the lower engine is that engine's own input, and each
 * tier's cache is its own and no path between tiers ([LTIE.9.7]). So a tier never
 * publishes, transitively, back to itself — the cross-tier fact graph is acyclic.
 * This is the inter-tier complement to derivation_graph's intra-engine acyclicity.
 *
 * TEETH: comment out `ltie_3_1__publish_upward_only` and the acyclicity check
 * fails with a tier that publishes back into its own ancestor cone.
 */
module ds/tier_boundary

//@spec [LTIE.3.2]
// A tier; `above` is the set of tiers strictly higher than it — the tier DAG.
sig ltie_3_2__tier { above: set ltie_3_2__tier }

//@spec [LTIE.3.2]
// The tier graph is a directed acyclic graph: no tier is above itself.
fact ltie_3_2__tier_dag { no t: ltie_3_2__tier | t in t.^above }

//@spec [LTIE.3.1]
// A cross-tier publish: fact flow from one tier up to another.
sig ltie_3_1__publish {
  from: one ltie_3_2__tier,
  to:   one ltie_3_2__tier
}

//@spec [LTIE.3.1]
// Facts flow upward only: a publish always targets a strictly-higher tier.
fact ltie_3_1__publish_upward_only {
  all p: ltie_3_1__publish | p.to in p.from.^above
}

//@spec [LTIE.3.1]
// The tier-level publish flow: A -> B when some publish carries a fact A up to B.
fun ltie_3_1__flow : ltie_3_2__tier -> ltie_3_2__tier {
  { a: ltie_3_2__tier, b: ltie_3_2__tier | some p: ltie_3_1__publish | p.from = a and p.to = b }
}

//@probe
// A non-trivial multi-tier configuration with cross-tier publishes is satisfiable.
run probe__consistent { some ltie_3_1__publish } for 5

// SAFETY: no tier publishes, transitively, back to itself — a call introduces no
// fact edge ([LTIE.5.4]), so the cross-tier fact graph is acyclic.
// NO counterexample.
assert ltie_5_4__no_cross_tier_fact_cycle {
  no t: ltie_3_2__tier | t in t.^ltie_3_1__flow
}
//@derives [LTIE.5.4]
check ltie_5_4__no_cross_tier_fact_cycle for 6

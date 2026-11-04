/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS subsystem init / teardown — the borrow rule, over a given teardown order
 * (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_iarc_3_2_5__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. Every subsystem is init'd inside ds_engine_new and destroyed
 * inside ds_engine_free, and the one rule ([IARC.3.2.5]) is
 * the borrow rule: a subsystem is init'd after every subsystem it borrows from,
 * and destroyed before every one of them, so teardown never invalidates a
 * borrow a subsystem not yet destroyed still holds. Teardown is NOT the reverse
 * of init: the order ds_engine_free takes is the clause's list, which the model
 * takes as GIVEN (`iarc_3_2_5__teardown`) and constrains by the rule alone.
 * libds destroys the cache and the two series registries after the first five
 * subsystems.
 *
 * WHAT THE CHECKS REFUSE. `iarc_3_2_5__teardown_preserves_borrows` refuses an
 * order under which a subsystem outlives one that borrows from it THROUGH ANY
 * CHAIN of borrows: it rests on the borrow rule (`borrower_destroyed_first`)
 * for one step and on the order being a sequence (`teardown_is_a_sequence`,
 * transitive) for the chain; without the second, a cyclic "order" satisfying
 * the one-step rule is its counterexample. `iarc_3_2_5__borrows_acyclic`
 * refuses a borrow graph with a cycle, which `borrow_from_earlier` rules out.
 * The two probes beside `probe__consistent` show the rule admits BOTH shapes
 * it must: libds's, where an earlier-inited subsystem goes before a
 * later-inited one, and the exact reverse of init, the reading this file once
 * fixed.
 */
module ds/init_teardown

open util/ordering[iarc_3_2_5__subsystem] as initord

//@spec [IARC.3.2.5]
// A libds subsystem (clock, telemetry, recorder, schema, wm, dispatcher, rete
// engine, cache, the two series registries), ordered by init sequence;
// `borrows` = subsystems it holds a reference into.
sig iarc_3_2_5__subsystem { borrows: set iarc_3_2_5__subsystem }

//@spec [IARC.3.2.5]
// "init a subsystem after every subsystem it borrows from": a subsystem may
// borrow only from earlier-inited ones — you cannot reference a subsystem that
// does not exist yet.
fact iarc_3_2_5__borrow_from_earlier {
  all s: iarc_3_2_5__subsystem, t: s.borrows | initord/lt[t, s]
}

//@spec [IARC.3.2.5]
// THE TEARDOWN ORDER, GIVEN: the order ds_engine_free takes, which the clause
// lists and does not derive from init. `destroys` holds `a -> b` when `a` is
// destroyed before `b`.
one sig iarc_3_2_5__teardown { destroys: iarc_3_2_5__subsystem -> iarc_3_2_5__subsystem }

//@spec [IARC.3.2.5]
// `a` is destroyed before `b`: the given order, read off `iarc_3_2_5__teardown`.
fun iarc_3_2_5__destroyed_before : iarc_3_2_5__subsystem -> iarc_3_2_5__subsystem {
  iarc_3_2_5__teardown.destroys
}

//@spec [IARC.3.2.5]
// ds_engine_free destroys the subsystems one at a time, "in this order": the
// given order is a strict total order — irreflexive, transitive, total.
fact iarc_3_2_5__teardown_is_a_sequence {
  no iden & iarc_3_2_5__destroyed_before
  iarc_3_2_5__destroyed_before.iarc_3_2_5__destroyed_before in iarc_3_2_5__destroyed_before
  all disj a, b: iarc_3_2_5__subsystem |
    a -> b in iarc_3_2_5__destroyed_before or b -> a in iarc_3_2_5__destroyed_before
}

//@spec [IARC.3.2.5]
// THE CLAUSE'S RULE: "destroy it before every one of them" — a borrower is
// destroyed before each subsystem it borrows from.
fact iarc_3_2_5__borrower_destroyed_first {
  all s: iarc_3_2_5__subsystem, t: s.borrows | s -> t in iarc_3_2_5__destroyed_before
}

//@probe
// A non-trivial init graph with some borrows, under some admissible teardown
// order, is satisfiable.
run probe__consistent { some borrows } for 5

//@probe
// libds's shape is admissible: with borrows present, an earlier-inited
// subsystem is destroyed before a later-inited one (engine.c: the cache,
// inited eighth, is destroyed after the dispatcher, working memory, the
// schema registry, the recorder and telemetry).
run probe__not_the_reverse {
  some borrows
  some a, b: iarc_3_2_5__subsystem | initord/lt[a, b] and a -> b in iarc_3_2_5__destroyed_before
} for 5

//@probe
// The exact reverse of init is one admissible order under the rule, and one
// libds is free to take.
run probe__reverse_admissible {
  some borrows
  iarc_3_2_5__destroyed_before = { a, b: iarc_3_2_5__subsystem | initord/gt[a, b] }
} for 5

// SAFETY, THROUGH ANY CHAIN: a subsystem is destroyed before every subsystem it
// borrows from directly or transitively, so no borrow ever dangles. One step is
// the rule as a fact; the chain is the rule composed along the given order,
// which is transitive. NO counterexample.
assert iarc_3_2_5__teardown_preserves_borrows {
  all s: iarc_3_2_5__subsystem, t: s.^borrows |
    s -> t in iarc_3_2_5__destroyed_before
}
//@derives [IARC.3.2.5]
check iarc_3_2_5__teardown_preserves_borrows for 6

// CONSEQUENCE: because a borrow only ever points to an earlier-inited subsystem,
// the borrow graph is acyclic — no subsystem transitively borrows from itself. NO
// counterexample.
assert iarc_3_2_5__borrows_acyclic {
  no s: iarc_3_2_5__subsystem | s in s.^borrows
}
//@derives [IARC.3.2.5]
check iarc_3_2_5__borrows_acyclic for 6

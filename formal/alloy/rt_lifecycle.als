/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS realtime lifecycle — INIT->LIVE one-way phase-gate model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_nrtm_5_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. RT execution has an INIT phase (load rules, size pools, warm the
 * intern table) and a LIVE phase (pump, zero-alloc, NO structural change), joined
 * by the one-way `ds_engine_go_live` gate ([NRTM.5.1]/[NRTM.5.2]). Pool-shaping
 * setters run before `ds_engine_set_wm_max` ([NRTM.2.1]); structural operations
 * are INIT-only ([NRTM.5.3]). This model proves that ordering makes the LIVE phase
 * structurally frozen: every structural operation strictly precedes every pump, so
 * no structural change ever interleaves with pumping.
 *
 * TEETH: drop `nrtm_5_2__structural_before_go_live` (or `nrtm_5_1__pump_after_
 * go_live`) and the frozen-LIVE check fails — a structural op lands at or after a
 * pump.
 */
module ds/rt_lifecycle

open util/ordering[nrtm_5_1__step] as ord

//@spec [NRTM.5.1]
// The lifecycle operations: INIT-phase structural ops (pool_setter, set_wm_max,
// load_warm), the one-way go_live gate, and the LIVE-phase pump.
abstract sig nrtm_5_1__op {}
one sig pool_setter extends nrtm_5_1__op {}
one sig set_wm_max  extends nrtm_5_1__op {}
one sig load_warm   extends nrtm_5_1__op {}
one sig go_live     extends nrtm_5_1__op {}
one sig pump        extends nrtm_5_1__op {}

//@spec [NRTM.5.1]
// A step in the engine's lifetime, running one operation; steps are time-ordered.
sig nrtm_5_1__step { op: one nrtm_5_1__op }

//@spec [NRTM.5.2]
// go_live happens exactly once — the INIT->LIVE transition is one-way.
fact nrtm_5_2__one_go_live { one s: nrtm_5_1__step | s.op = go_live }

//@spec [NRTM.5.2]
// The single go_live step (the phase boundary).
fun nrtm_5_2__the_go_live : nrtm_5_1__step { { s: nrtm_5_1__step | s.op = go_live } }

//@spec [NRTM.2.1]
// Pool-shaping setters run before set_wm_max (which allocates the pools).
fact nrtm_2_1__setters_before_wm_max {
  all a, b: nrtm_5_1__step |
    (a.op = pool_setter and b.op = set_wm_max) implies ord/lt[a, b]
}

//@spec [NRTM.5.2]
// Every INIT-phase structural op runs strictly before go_live.
fact nrtm_5_2__structural_before_go_live {
  all s: nrtm_5_1__step |
    s.op in (pool_setter + set_wm_max + load_warm)
      implies ord/lt[s, nrtm_5_2__the_go_live]
}

//@spec [NRTM.5.1]
// Pumping happens only in the LIVE phase — strictly after go_live.
fact nrtm_5_1__pump_after_go_live {
  all s: nrtm_5_1__step | s.op = pump implies ord/lt[nrtm_5_2__the_go_live, s]
}

//@probe
// A complete valid lifecycle (setter, wm_max, load/warm, go_live, pump) is
// satisfiable.
run probe__consistent {
  some a, b, c, g, p: nrtm_5_1__step |
    a.op = pool_setter and b.op = set_wm_max and c.op = load_warm
    and g.op = go_live and p.op = pump
} for 6

// FROZEN LIVE: every structural operation strictly precedes every pump — no
// loading, schema registration, or pool sizing ever interleaves with pumping, so
// the LIVE phase is structurally frozen ([NRTM.5.3]). NO counterexample.
assert nrtm_5_3__live_is_frozen {
  all s, p: nrtm_5_1__step |
    (s.op in (pool_setter + set_wm_max + load_warm) and p.op = pump)
      implies ord/lt[s, p]
}
//@derives [NRTM.5.3]
check nrtm_5_3__live_is_frozen for 6

// SETUP ORDER: pool setters precede set_wm_max, which precedes go_live — the RT
// initialization sequence holds. NO counterexample.
assert nrtm_2_1__setup_order {
  all a, b, g: nrtm_5_1__step |
    (a.op = pool_setter and b.op = set_wm_max and g.op = go_live)
      implies (ord/lt[a, b] and ord/lt[b, g])
}
//@derives [NRTM.2.1]
check nrtm_2_1__setup_order for 6

/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS engine lifecycle — one-way phase FSM + a substitutable clock source
 * (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_nlfc_6__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. An engine's lifecycle phase advances one-way — fresh -> running
 * (once pumped) -> freed — and `freed` is terminal: after `ds_engine_free` the
 * handle is invalid, so nothing runs on it ([NLFC.6.2]). The clock SOURCE, by
 * contrast, may be substituted in either direction on a live handle
 * ([NLFC.5.4]: "substituted, not switched back and forth" — the clause
 * contracts no timeline continuity on the way back, and this model carries no
 * clock values, so that half is outside it). This model proves the phase never
 * regresses and `freed` absorbs (no use after free), while the clock source is
 * unconstrained by the phase.
 *
 * TEETH: drop `nlfc_6__phase_monotone` and the no-use-after-free check fails — a
 * step runs at `running` after the engine was already `freed`.
 */
module ds/engine_lifecycle

open util/ordering[nlfc_6__step] as ord

//@spec [NLFC.6]
// The engine lifecycle phases: fresh (after ds_engine_new), running (after the
// first pump), freed (after ds_engine_free).
abstract sig nlfc_6__phase {}
one sig fresh   extends nlfc_6__phase {}
one sig running extends nlfc_6__phase {}
one sig freed   extends nlfc_6__phase {}

//@spec [NLFC.5.4]
// The clock source in force — live or mock. Substitutable on a live handle;
// nothing here says the timeline survives a second substitution.
abstract sig nlfc_5_4__clock_mode {}
one sig live_clock extends nlfc_5_4__clock_mode {}
one sig mock_clock extends nlfc_5_4__clock_mode {}

//@spec [NLFC.6]
// A step in one engine's lifetime, time-ordered: its lifecycle phase and clock mode.
sig nlfc_6__step {
  phase: one nlfc_6__phase,
  clock: one nlfc_5_4__clock_mode
}

//@spec [NLFC.6]
// The phase advance-or-stay relation: fresh -> {fresh, running, freed};
// running -> {running, freed}; freed -> freed. The lifecycle is one-way.
fun nlfc_6__phase_ok : nlfc_6__phase -> nlfc_6__phase {
  fresh->fresh + fresh->running + fresh->freed
  + running->running + running->freed
  + freed->freed
}

//@spec [NLFC.6]
// The phase never regresses over the timeline — a later step's phase is the same
// or further along.
fact nlfc_6__phase_monotone {
  all a, b: nlfc_6__step | ord/lt[a, b] implies a.phase -> b.phase in nlfc_6__phase_ok
}

//@probe
// Two substitutions of the clock source (live -> mock -> live) are legal calls
// while the lifecycle phase advances one-way. Satisfiable. This is consistency
// of the facts, not a claim that the second substitution resumes anything.
run probe__consistent {
  some a, b, c: nlfc_6__step |
    a.clock = live_clock and b.clock = mock_clock and c.clock = live_clock
    and ord/lt[a, b] and ord/lt[b, c]
} for 6

// TERMINAL: once an engine is freed it stays freed — the phase absorbs. NO
// counterexample.
//
// A TRANSCRIPTION, NOT A REFUTATION: this is `nlfc_6__phase_monotone` at
// `a.phase = freed`, where `nlfc_6__phase_ok` admits `freed -> freed` alone --
// one fact at one of its instances -- so it is UNSAT on any model that has the
// fact and is tagged `spec` for that reason.
// The TLA+ sibling's `FreedIsTerminal` stays `derives`: there the state is left
// by no action, which is more than one guard.
assert nlfc_6_2__freed_is_terminal {
  all a, b: nlfc_6__step | (a.phase = freed and ord/lt[a, b]) implies b.phase = freed
}
//@spec [NLFC.6.2]
check nlfc_6_2__freed_is_terminal for 6

// NO USE AFTER FREE: no step ever runs (`running`) after the engine was freed —
// the invalid handle is never operated on. NO counterexample. This is the
// clause's first bullet at rest, over the phase alone; the model carries no
// facts, schemas or callbacks, so its second and third bullets are outside it,
// as in the TLA+ sibling. The tie's verdict is `partial` for that reason.
//
// A TRANSCRIPTION, NOT A REFUTATION, for the reason `freed_is_terminal` gives:
// the same instance of the same fact, with `b.phase = freed` weakened to
// `!= running`. Tagged `spec`.
assert nlfc_6_2__no_use_after_free {
  all a, b: nlfc_6__step | (a.phase = freed and ord/lt[a, b]) implies b.phase != running
}
//@spec [NLFC.6.2]
check nlfc_6_2__no_use_after_free for 6

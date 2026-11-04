/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS truth maintenance — justification refcount model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_iret_12__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. A logical fact's liveness is truth-maintained by a justifier refcount
 * ([IRET.12]): each supporting activation increments justif_count, an ending activation
 * decrements it, and the fact is retracted exactly when the count reaches zero — a
 * multi-justified fact survives until its LAST justifier ends ([IRET.12.2], [IRET.12.3]).
 * Justification linkage keys on the assertion verb: only a fact asserted `logical` is
 * TMS-linked; a non-logical fact carries no justifiers and never retracts on justifier
 * withdrawal ([LLOG.15.1] / [LLOG.15.2]). This model — a language(LLOG)+impl(IRET)
 * convergence — proves a logical fact is live iff it has a justifier, survives partial
 * withdrawal, and that only logical facts are TMS-linked.
 *
 * TEETH: drop `iret_12__logical_live_iff_justified` and a logical fact survives with zero
 * justifiers (leaked derived fact) or retracts with one still live (premature retract);
 * drop `llog_15_2__non_logical_no_tms` and a non-logical fact gets TMS-linked.
 *
 * MODEL <-> MODEL. This is a SNAPSHOT of the refcount: live
 * iff some justifier, with no dynamics and no antecedents, so it cannot say what
 * happens when the justifiers themselves depend on the fact.
 * formal/tla/tms_cascade.tla models the count's dynamics on an acyclic support
 * graph -- the same mechanism, run as a cascade -- and formal/idris/Rete/Refcount.idr
 * states both the count and the well-founded contract and proves where they part:
 * `iret_12_2__witness_refcount` executes the count on P -> Q, Q -> R, R -> Q with P
 * retracted and shows Q and R kept live by each other -- the unfounded cycle a
 * snapshot cannot draw, the cascade keeps, and the well-founded set drops
 * (`llog_2_5__witness_well_founded`) -- while `iret_12_2__tla_retract_f1` shows
 * count and contract agreeing on the TLA+ model's ranked instance. Well-founded
 * support ([LLOG.2.5]) is
 * the contract, and [IRET.12.2]'s mechanism must agree with
 * it. So this model is faithful to the count
 * reaching zero, and to the contract only on the fragment [LCYC.3.1.1]
 * admits, where the two coincide (`iret_12_3__ranked_agree`); its [IRET.12.2]
 * tie carries `partial` for that reason -- not `violated`, since no admitted
 * program reaches the difference -- and the TLA+ model's
 * `iret_12_2__no_unsupported_forever` tie carries `derives` with `partial` for
 * the same reason. The TLA+ half of this comparison is held
 * by tms_cascade.cfg and tms_cascade.teeth.cycle.cfg, and the TLA+ and Idris
 * instances are held one by scripts/formal/check_instances.py (`instances.stamp`),
 * on every run of the lane; this model draws no instance, so its half, this
 * paragraph, is still by hand.
 */
module ds/tms_justification

//@spec [IRET.12]
// A rule activation — a justifier: while live it supports the logical facts it emitted.
sig iret_12__activation {}

//@spec [LLOG.15]
// A working-memory fact and the set of live activations currently justifying it
// (justif_count = the cardinality of this set).
sig llog_15__fact { justifiers: set iret_12__activation }

//@spec [LLOG.15.1]
// The facts asserted with the `logical` flag — the TMS-linked ones (justification keys
// on the assertion verb, not the fact's content).
sig llog_15_1__logical in llog_15__fact {}

//@spec [IRET.12]
// The facts currently live in working memory.
sig iret_12__live in llog_15__fact {}

//@spec [LLOG.15.2]
// A fact not asserted `logical` carries no TMS linkage — no justifiers.
fact llog_15_2__non_logical_no_tms {
  all f: llog_15__fact | f not in llog_15_1__logical implies no f.justifiers
}

//@spec [IRET.12]
// TMS liveness: a logical fact is live IFF its justif_count is non-zero (it has at least
// one live justifier). Retract fires exactly when the count reaches zero.
fact iret_12__logical_live_iff_justified {
  all f: llog_15_1__logical | f in iret_12__live iff some f.justifiers
}

//@probe
// A logical fact with two justifiers (live), a logical fact with none (retracted), and a
// non-logical fact (no TMS link) coexist. Satisfiable.
run probe__tms_states {
  some f: llog_15_1__logical | ((some disj a1, a2: f.justifiers | a1 != a2) and f in iret_12__live)
  some g: llog_15_1__logical | (no g.justifiers)
  some (llog_15__fact - llog_15_1__logical)
} for 6

// RETRACT IFF ZERO JUSTIFIERS: a logical fact is retracted (not live) IFF its justif_count
// is zero — it survives while any justifier remains ([IRET.12.2]). NO counterexample.
assert iret_12_2__retract_iff_no_justifier {
  all f: llog_15_1__logical | (f not in iret_12__live) iff (no f.justifiers)
}
//@spec [IRET.12.2]
check iret_12_2__retract_iff_no_justifier for 6

// MULTIPLE JUSTIFIERS: a logical fact with >= 2 justifiers is live, and removing any
// one of them leaves one — the snapshot's reading of [IRET.12.3]. No justifier ENDS
// in this model: there is no step, so "stays live when a justifier ends" is not
// what is checked; the dynamics are formal/tla/tms_cascade.tla's. NO counterexample.
//
// A TRANSCRIPTION, NOT A REFUTATION: the first conjunct is
// `iret_12__logical_live_iff_justified`'s `if` half at an instance (two
// justifiers are some), and the second is set arithmetic that rests on no fact.
// One fact in a second spelling; tagged `spec` for that reason.
assert iret_12_3__multi_justifier_survives {
  all f: llog_15_1__logical |
    (some disj a1, a2: f.justifiers | a1 != a2) implies
      (f in iret_12__live and (all a: f.justifiers | some (f.justifiers - a)))
}
//@spec [IRET.12.3]
check iret_12_3__multi_justifier_survives for 6

// ONLY LOGICAL FACTS ARE TMS-LINKED: a fact carries a justifier only if it was asserted
// `logical`; a non-logical fact has none and never retracts on justifier withdrawal
// ([LLOG.15.2]). NO counterexample.
assert llog_15_2__only_logical_is_tms_linked {
  all f: llog_15__fact | some f.justifiers implies f in llog_15_1__logical
}
//@spec [LLOG.15.2]
check llog_15_2__only_logical_is_tms_linked for 6

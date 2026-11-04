/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * V5: A `where` WITH FAULTS. No variant, tie-break or recording mode is a
 * parameter here, so a green run is a claim about V5. Written independently of formal/idris/Rete/WhereV5.idr (an
 * unbounded proof by structural recursion) and formal/k/dswherev5.k (an
 * executable search): this model states an evaluation relationally and lets
 * the solver quantify over every `where` of up to three conjuncts, every order
 * and every set of hoisted filters.
 *
 * THE READING. A conjunct yields true, false, null, or a fault -- a trap, a
 * TypeError or an EngineError ([LERR.1]) -- and a fault records an atom: its
 * kind and a body ([RFCS.21.1]). V5 evaluates the conjuncts in ANY order and
 * stops at the first false; every fault is absorbed, so evaluation goes on past
 * it. A false decides; otherwise the recorded fault is the one no other beats,
 * by kind (EngineError, then TypeError, then trap) and then by body (T2I);
 * otherwise null; otherwise true. Only that one fault is recorded (M1).
 * Filters -- an alpha test, an index probe -- run first, in [IRET.6.4]'s
 * order: a false among them rejects the
 * candidate whatever the others answer; otherwise a fault among them is raised
 * there, the one T2I selects of two, and nothing of the rest is evaluated;
 * otherwise a null rejects (the model's own); otherwise the rest. Source order
 * never enters.
 *
 * INVARIANTS, each a `check` over every `where` of up to three conjuncts:
 *   * the answer is [LNUL.4.2]'s absorbing table folded over the conjuncts
 *     (`lnul_4_2__v5_refines_table`);
 *   * every order V5 may take gives one answer and one record
 *     (`iret_9_5__v5_order_independent`);
 *   * a false anywhere decides and records nothing (`lnul_5_4__v5_false_decides`);
 *   * at most one atom is recorded (`rfcs_21_1__v5_one_atom`);
 *   * for an artefact that does not lie, filters on decided conjuncts --
 *     non-nullable, unable to raise by declared types -- leave the decision of
 *     a positive and of a `no` pattern, and the record, unchanged
 *     (`rlow_5_5__v5_hoist_sound`);
 *   * a false among the filters rejects and records nothing, a faulting filter
 *     beside it notwithstanding (`iret_6_4__v5_false_rejects`), and with no
 *     false among them a fault among them is raised and its atom recorded
 *     (`iret_6_4__v5_fault_if_none_false`) -- the two arms of the
 *     clause, restated as double entry on `iret_6_4__fstop`.
 * WITNESSES, each a `run`: the self-join records the lesser body in every order
 * (`rfcs_21_1__v5_selfjoin`); a hoisted conjunct over a value the artefact lied
 * about, with no false beside it among the filters, changes the `no` pattern's
 * decision (`iret_9_6__v5_lie_breaks_hoisting`); a faulting filter first in the
 * source and a false one after it reject in every order
 * (`iret_6_4__v5_fault_then_false_rejects`); a null anchor escapes the probe
 * (`iret_7_5_1__v5_null_anchor_escapes`).
 * CONSISTENCY: the `probe__` runs show the checks' premises satisfiable, so no
 * check is UNSAT for want of a `where`.
 *
 * TEETH (measured on temp branches):
 *   * pick the fault by kind alone              -> rfcs_21_1__v5_one_atom and the
 *                                                  self-join witness fail;
 *   * pick the first fault in evaluation order  -> iret_9_5__v5_order_independent and
 *                                                  the self-join witness fail;
 *   * let a false not absorb an EngineError     -> lnul_4_2__v5_refines_table,
 *                                                  iret_9_5__v5_order_independent and
 *                                                  lnul_5_4__v5_false_decides fail;
 *   * admit a nullable conjunct as a filter      -> rlow_5_5__v5_hoist_sound fails;
 *   * end the filter phase at the first filter in
 *     source order that is not true              -> iret_6_4__v5_false_rejects fails and
 *                                                  iret_6_4__v5_fault_then_false_rejects
 *                                                  is UNSAT.
 * What this model cannot catch: a tie-break keyed on SOURCE position. The
 * reference evaluation never reads source order, so no key here can depend on
 * it; formal/idris/Rete/WhereV5.idr's trichotomy and the counterexample models
 * are where a positional key is refuted.
 */
module where_v5
open util/boolean
open util/ordering[rfcs_21_1__body] as BO

//@spec [LNUL.4.2]
// What a conjunct yields for the pair at hand.
abstract sig lnul_4_2__out {}
one sig OYes, ONo, ONull, OTrap, OTE, OEE extends lnul_4_2__out {}

//@spec [LERR.1]
// The three fault kinds a `where` can meet.
fun lerr_1__faults: set lnul_4_2__out { OTrap + OTE + OEE }

//@spec [LERR.1]
// Kind priority. EngineError first is [LERR.1]'s order -- it abandons the tier,
// the other two the activation; TypeError before trap is [LNUL.4.2]'s choice,
// since [LERR.1] ties the two on cost. The trap kinds among themselves order by
// their value, the first field of the recorded body.
fun lerr_1__before: lnul_4_2__out -> lnul_4_2__out { OEE -> (OTE + OTrap) + OTE -> OTrap }

//@spec [RFCS.21.1]
// The body of the atom a fault records -- every recorded field after the kind,
// recording provenance excluded -- totally ordered.
sig rfcs_21_1__body {}

//@spec [IRET.7.6]
// A conjunct: what it yields, whether it can raise by its declared types,
// whether its slot is nullable, and the body its fault would record. Two
// conjuncts may share a body.
abstract sig iret_7_6__conj {
  out: one lnul_4_2__out,
  raw: one Bool,
  nullable: one Bool,
  body: one rfcs_21_1__body
}
one sig C0, C1, C2 extends iret_7_6__conj {}

//@spec [LNUL.4.2]
// A well-formed `where`: a trap or a TypeError comes only from a conjunct that
// can raise by its declared types; null only from a nullable slot. An
// EngineError may come from any conjunct -- it is a value the artefact lied about.
pred lnul_4_2__ok_where {
  all c: iret_7_6__conj | (c.out in OTrap + OTE implies isTrue[c.raw]) and (isFalse[c.nullable] implies c.out != ONull)
}

//@spec [IRET.9.6]
//@spec [LDET.1.11]
// The artefact did not lie: no conjunct yields an EngineError (the third arm of
// [IRET.9.6]). The determinism guarantee is scoped to such runs ([LDET.1.11]).
pred iret_9_6__honest { no c: iret_7_6__conj | c.out = OEE }

//@spec [RLOW.5.5]
// A decided conjunct: it cannot raise by its declared types and its slot is not
// nullable -- what an alpha test or an index anchor may be.
pred rlow_5_5__decided[c: iret_7_6__conj] { isFalse[c.raw] and isFalse[c.nullable] }

//@spec [IRET.9.5]
// The orders V5 may evaluate the conjuncts in, one atom each.
sig iret_9_5__ord { lt: iret_7_6__conj -> iret_7_6__conj }

//@spec [IRET.9.5]
// Each is a strict total order, and no two are the same; with six atoms, every
// order is present.
fact iret_9_5__orders {
  all o: iret_9_5__ord | no (iden & o.lt) and (o.lt).(o.lt) in o.lt
    and (all a, b: iret_7_6__conj | a != b implies (a -> b in o.lt or b -> a in o.lt))
  all disj o1, o2: iret_9_5__ord | o1.lt != o2.lt
}

//@spec [IRET.6.4]
// What ends the filter phase, in the clause's order: the filters answering false, if any -- a false anywhere rejects, a
// faulting test beside it notwithstanding; else, with no false among them, the
// faulting filters T2I selects (the tests being hoisted conjuncts of the
// `where`, RLOW.5.5, [LNUL.4.2] says which of two is raised); else the filters
// answering null, the model's own extension; else none, and every filter
// passed. Source order never enters. Idris's `iret_6_4__filtered` is the same
// phase as the V5 fold of the filters.
fun iret_6_4__fstop[F: set iret_7_6__conj]: set iret_7_6__conj {
  let N = { f: F | f.out = ONo }, X = { f: F | f.out in lerr_1__faults } |
    (some N) => N else (some X) => lnul_4_2__best[X] else { f: F | f.out = ONull }
}

//@spec [IRET.9.5]
// The first false of the rest in order o -- the only thing V5 stops at.
fun iret_9_5__stop[o: iret_9_5__ord, R: set iret_7_6__conj]: set iret_7_6__conj {
  { s: R | s.out = ONo and no s2: R | s2.out = ONo and s2 -> s in o.lt }
}

//@spec [IRET.9.5]
// What the rest evaluated: up to and including the stop, or all of it.
fun iret_9_5__evaluated[o: iret_9_5__ord, R: set iret_7_6__conj]: set iret_7_6__conj {
  let x = iret_9_5__stop[o, R] | (some x) => ({ c: R | c -> x in o.lt } + x) else R
}

//@spec [LNUL.4.2]
// T2I: the faulting conjuncts of E that no other faulting conjunct of E beats,
// by kind, then by recorded body.
fun lnul_4_2__best[E: set iret_7_6__conj]: set iret_7_6__conj {
  { f: E | f.out in lerr_1__faults and no g: E | g.out in lerr_1__faults
      and (g.out -> f.out in lerr_1__before or (g.out = f.out and g.body in BO/prevs[f.body])) }
}

//@spec [RFCS.21.1]
// How an evaluation ended.
abstract sig rfcs_21_1__answer {}
one sig AYes, ANo, ANull, AFault, ARej extends rfcs_21_1__answer {}

//@spec [RFCS.21.1]
// Filters F in source order, then the rest in order o: how it ended.
fun rfcs_21_1__ans[F: set iret_7_6__conj, o: iret_9_5__ord]: rfcs_21_1__answer {
  let fs = iret_6_4__fstop[F], R = iret_7_6__conj - F, E = iret_9_5__evaluated[o, R] |
    (some fs and fs.out in ONo + ONull) => ARej
    else (some fs) => AFault
    else (some iret_9_5__stop[o, R]) => ANo
    else (some c: E | c.out in lerr_1__faults) => AFault
    else (some c: E | c.out = ONull) => ANull
    else AYes
}

//@spec [RFCS.21.1]
//@spec [LERR.1.4.11]
// M1: the atom recorded -- a fault a filter raised, else the best fault of the
// rest when nothing false stopped it, else none. [LERR.1.4.11] holds every
// fault surface -- record, callback, metric -- to that one fault, so this
// stands for all three.
fun rfcs_21_1__rec[F: set iret_7_6__conj, o: iret_9_5__ord]: lnul_4_2__out -> rfcs_21_1__body {
  let fs = iret_6_4__fstop[F], R = iret_7_6__conj - F, E = iret_9_5__evaluated[o, R] |
    (some fs and fs.out in lerr_1__faults) => fs.out -> fs.body
    else (some fs or some iret_9_5__stop[o, R]) => (none -> none)
    else { k: lnul_4_2__out, b: rfcs_21_1__body | some f: lnul_4_2__best[E] | f.out = k and f.body = b }
}

//@spec [LNUL.4.7]
// A positive pattern, or a `no` pattern.
abstract sig lnul_4_7__pol {}
one sig POS, NEG extends lnul_4_7__pol {}

//@spec [LNUL.4.7]
// The decision: a positive pattern fires on true ([LNUL.4.3]); a `no` pattern
// is blocked unless the answer is false or the candidate was filtered out.
pred lnul_4_7__decides[pl: lnul_4_7__pol, a: rfcs_21_1__answer] {
  pl = POS implies a = AYes
  pl = NEG implies a not in ANo + ARej
}

//@spec [LNUL.4.2]
// [LNUL.4.2]'s absorbing `and`, folded over the conjuncts: false absorbs
// everything, a fault absorbs null and true, null absorbs true.
fun lnul_4_2__table: rfcs_21_1__answer {
  (some c: iret_7_6__conj | c.out = ONo) => ANo
  else (some c: iret_7_6__conj | c.out in lerr_1__faults) => AFault
  else (some c: iret_7_6__conj | c.out = ONull) => ANull
  else AYes
}

// ---------------------------------------------------------------------------
// The invariants
// ---------------------------------------------------------------------------

//@derives [LNUL.4.2]
// V5 REFINES THE TABLE: stopping at the first false in any order and absorbing
// every fault answers what the table answers.
check lnul_4_2__v5_refines_table {
  lnul_4_2__ok_where implies all o: iret_9_5__ord | rfcs_21_1__ans[none, o] = lnul_4_2__table
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@derives [IRET.9.5]
//@derives [IRET.7.6]
//@derives [LERR.1.4.11]
// ORDER INDEPENDENCE: every order gives one answer and records one atom.
check iret_9_5__v5_order_independent {
  lnul_4_2__ok_where implies all o1, o2: iret_9_5__ord |
    rfcs_21_1__ans[none, o1] = rfcs_21_1__ans[none, o2] and rfcs_21_1__rec[none, o1] = rfcs_21_1__rec[none, o2]
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@derives [LNUL.5.4]
//@derives [RLOW.6.1.4]
// NARROWING: a false anywhere decides, whatever the rest would raise, and
// nothing is recorded -- so folding a literal false operand is sound.
check lnul_5_4__v5_false_decides {
  lnul_4_2__ok_where implies all o: iret_9_5__ord |
    (some c: iret_7_6__conj | c.out = ONo) implies (rfcs_21_1__ans[none, o] = ANo and no rfcs_21_1__rec[none, o])
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@derives [RFCS.21.1]
//@derives [LERR.1.4.11]
// ONE ATOM: kind then body is total over what is recorded, so a `where`
// records at most one atom -- two faults tied on both record the same one.
check rfcs_21_1__v5_one_atom {
  lnul_4_2__ok_where implies all o: iret_9_5__ord | lone rfcs_21_1__rec[none, o]
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@derives [RLOW.5.5]
//@derives [IRET.6.4]
//@derives [IRET.7.5.1]
//@derives [LDET.1.11]
// HOISTING AND PROBING ARE SOUND for an artefact that does not lie: filters on
// any decided conjuncts, then the rest, give the decision of a positive and of
// a `no` pattern, and the record, of the whole `where`.
check rlow_5_5__v5_hoist_sound {
  (lnul_4_2__ok_where and iret_9_6__honest) implies
    all F: set iret_7_6__conj, o: iret_9_5__ord, pl: lnul_4_7__pol |
      (all f: F | rlow_5_5__decided[f]) implies
        ((lnul_4_7__decides[pl, rfcs_21_1__ans[F, o]] iff lnul_4_7__decides[pl, rfcs_21_1__ans[none, o]])
         and rfcs_21_1__rec[F, o] = rfcs_21_1__rec[none, o])
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@spec [IRET.6.4]
// A FALSE AMONG THE FILTERS REJECTS, whatever else they answer -- a faulting
// test beside it included -- and nothing is recorded: the amended clause's "the
// fact is rejected if another test of the node answers false". A restatement of
// `iret_6_4__fstop`'s first arm, as double entry on the transcription.
check iret_6_4__v5_false_rejects {
  lnul_4_2__ok_where implies all F: set iret_7_6__conj, o: iret_9_5__ord |
    (some f: F | f.out = ONo) implies (rfcs_21_1__ans[F, o] = ARej and no rfcs_21_1__rec[F, o])
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@spec [IRET.6.4]
// THE FAULT IS RAISED ONLY IF NONE ANSWERS FALSE: with no false among the
// filters and a fault among them, the evaluation ends on a fault one of the
// filters raised, whatever the rest would answer, and records that fault's
// atom. The second arm of `iret_6_4__fstop`, restated.
check iret_6_4__v5_fault_if_none_false {
  lnul_4_2__ok_where implies all F: set iret_7_6__conj, o: iret_9_5__ord |
    ((no f: F | f.out = ONo) and (some f: F | f.out in lerr_1__faults)) implies
      (rfcs_21_1__ans[F, o] = AFault
       and (some f: F | f.out in lerr_1__faults and rfcs_21_1__rec[F, o] = f.out -> f.body))
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

// ---------------------------------------------------------------------------
// Witnesses
// ---------------------------------------------------------------------------

//@derives [IRET.6.4]
// THE ORDER, DRAWN: a faulting alpha test first in the source and a
// false one after it, both hoisted. Every order rejects and records nothing.
// Ending the filter phase at the first filter in source order that is not true
// raises the fault, and under that this run is UNSAT.
run iret_6_4__v5_fault_then_false_rejects {
  lnul_4_2__ok_where
  C0.out = OTrap and C1.out = ONo and C2.out = OYes
  all o: iret_9_5__ord | rfcs_21_1__ans[C0 + C1, o] = ARej and no rfcs_21_1__rec[C0 + C1, o]
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@derives [RFCS.21.1]
// THE SELF-JOIN: two traps of one kind over two facts -- two bodies. Every
// order records the lesser body.
run rfcs_21_1__v5_selfjoin {
  lnul_4_2__ok_where
  C0.out = OTrap and C1.out = OTrap and C0.body != C1.body and C2.out = OYes
  all o: iret_9_5__ord | rfcs_21_1__rec[none, o] = OTrap -> BO/min[C0.body + C1.body]
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@derives [IRET.9.6]
//@derives [RLOW.5.5]
//@derives [LDET.1.11]
// WHY THE ARTEFACT MUST NOT LIE: a decided conjunct over a value the artefact
// lied about, hoisted alone, raises its EngineError and blocks the `no`
// pattern, where the whole `where` is false. The amended order does not close
// this: the false conjunct is in the rest, not among the node's tests.
run iret_9_6__v5_lie_breaks_hoisting {
  lnul_4_2__ok_where
  C0.out = OEE and rlow_5_5__decided[C0] and C1.out = ONo and C2.out = OYes
  some o: iret_9_5__ord |
    not (lnul_4_7__decides[NEG, rfcs_21_1__ans[C0, o]] iff lnul_4_7__decides[NEG, rfcs_21_1__ans[none, o]])
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@derives [IRET.7.5.1]
//@derives [LNUL.4.7]
// WHY THE ANCHOR MUST BE NON-NULL: a null anchor is in no bucket, where the
// whole `where` is null and blocks the `no` pattern.
run iret_7_5_1__v5_null_anchor_escapes {
  lnul_4_2__ok_where
  C0.out = ONull and isFalse[C0.raw] and isTrue[C0.nullable] and C1.out = OYes and C2.out = OYes
  some o: iret_9_5__ord |
    not (lnul_4_7__decides[NEG, rfcs_21_1__ans[C0, o]] iff lnul_4_7__decides[NEG, rfcs_21_1__ans[none, o]])
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

// ---------------------------------------------------------------------------
// Consistency
// ---------------------------------------------------------------------------

//@probe
// A well-formed `where` with a fault of every kind, and one with null beside a
// TypeError: the checks' common premise admits the cases they are about.
run probe__v5_every_kind {
  lnul_4_2__ok_where
  C0.out = OTrap and C1.out = OTE and C2.out = OEE
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

//@probe
// The hoisting premise with something to hoist past: an honest `where`, a
// decided filter, and faults beside it.
run probe__v5_hoist_premise {
  lnul_4_2__ok_where and iret_9_6__honest
  rlow_5_5__decided[C0] and C1.out = OTrap and C2.out = OTE
} for exactly 6 iret_9_5__ord, exactly 3 rfcs_21_1__body

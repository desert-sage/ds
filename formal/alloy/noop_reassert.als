/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS no-op reassertion — dedup / idempotence model (Alloy 6), with the
 * engine-owned `ts` slot beside the compared value.
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_idat_4_4__<tag>):
 *      <lowercased-clause-id>__<snake_tag>, e.g. `idat_4_4__fact` formalizes
 *      [IDAT.4.4]. A satisfiability probe carries the `probe__` marker.
 *      Enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. Reasserting a `logical` fact with an unchanged value is a no-op:
 * the engine keeps the SAME `ds_fact_t` (same `fact_id`) and emits no stream event
 * ([IDAT.4.4]); a *meaningful* change is a visible retract-and-replace — a fresh
 * `fact_id` and a FACT_RETRACT+FACT_ASSERT pair, never a silent in-place mutation,
 * never a second live fact ([LFAC.2.5.3]). The dedup relation ([LFAC.2.5.1]) is
 * reflexive and symmetric but NOT transitive (tolerance is a closeness relation) —
 * idempotence holds anyway because suppression compares the new value against the
 * single stored value, not transitively across history.
 *
 * THE `ts` SLOT. A fact's `ts` is not part of the compared value: the engine fills
 * it when the fact enters working memory — the value supplied by an input that
 * supplies one, else the step's wall sample ([LFAC.9.2]) — and authors never write
 * it ([LFAC.9.3]). A no-op does not enter, so it keeps the live fact's `ts`
 * ([LTIM.2.8.6] says the same of the entry stamp): a logical fact's `ts` is its
 * assertion time ([LTHE.5.5]). A replacement enters, and its `ts` is filled anew.
 * So the no-op decision is a function of the compared value alone, whatever `ts`
 * a reassertion supplies and whatever the step's sample is.
 *
 * TEETH: comment out `lfac_2_5_1__dedup_reflexive_symmetric` and the idempotence
 * check fails (a reassert of the identical value could be treated as a change).
 * Make `idat_4_4__reassert_outcome` require `r.supplied = r.onto.ts` of a no-op
 * and `lfac_2_5_1__ts_is_not_compared` fails: two reassertions of one value, one
 * supplying the live `ts` and one supplying another, would decide differently.
 */
module ds/noop_reassert

//@spec [LFAC.2]
// A fact's value (its compared slot-tuple), plus the engine's dedup relation
// `dedup_eq`: the values that count as "equal" to it for no-op suppression.
sig lfac_2__value { dedup_eq: set lfac_2__value }

//@spec [LFAC.2.5.1]
// The dedup relation is reflexive (a value equals itself — exact/structural) and
// symmetric, but NOT necessarily transitive (a `tolerance` band is a closeness
// relation: a~b, b~c does not force a~c).
fact lfac_2_5_1__dedup_reflexive_symmetric {
  all v: lfac_2__value | v in v.dedup_eq
  all v, w: lfac_2__value | v in w.dedup_eq iff w in v.dedup_eq
}

//@spec [LFAC.9.2]
// A wall-clock instant: a source time an input supplies, or a step's sample.
sig lfac_9_2__time {}

//@spec [IDAT.4.4]
// A `ds_fact_t` identity token (`fact_id`), monotonic and never reused.
sig idat_4_4__fact_id {}

//@spec [LFAC.2.5.3]
// The stream events a reassertion surfaces: FACT_ASSERT and/or FACT_RETRACT.
abstract sig lfac_2_5_3__stream_event {}
one sig assert_ev  extends lfac_2_5_3__stream_event {}
one sig retract_ev extends lfac_2_5_3__stream_event {}

//@spec [IDAT.4.4]
// The single live fact for an identity key: its `fact_id`, its stored value, and
// its `ts` — the instant it entered with ([LFAC.9.2]).
sig idat_4_4__fact {
  fact_id: one idat_4_4__fact_id,
  value:   one lfac_2__value,
  ts:      one lfac_9_2__time
}

//@spec [LFAC.2]
// Reasserting `value` onto the live fact `onto`, at a step whose wall sample is
// `sample`, supplying a `ts` or none ([LFAC.9.2]): the resulting `fact_id`, the
// stream events surfaced, and the `ts` of the fact left live.
sig lfac_2__reassertion {
  onto:      one idat_4_4__fact,
  value:     one lfac_2__value,
  supplied:  lone lfac_9_2__time,
  sample:    one lfac_9_2__time,
  result_id: one idat_4_4__fact_id,
  result_ts: one lfac_9_2__time,
  emits:     set lfac_2_5_3__stream_event
}

//@spec [LFAC.9.2]
// The `ts` a reassertion would enter with: the supplied value, else the step's
// wall sample.
fun lfac_9_2__fill[r: lfac_2__reassertion]: lfac_9_2__time {
  (some r.supplied) => r.supplied else r.sample
}

//@spec [IDAT.4.4]
//@spec [LFAC.2.5.3]
//@spec [LFAC.9.2]
// Reassertion outcome: dedup-equal to the stored value ([LFAC.2.5.1]) is a no-op —
// same `fact_id`, no event ([IDAT.4.4]), and the live `ts` kept, since nothing
// entered ([LFAC.9.2]); otherwise a meaningful change — a fresh `fact_id`, a
// retract+assert pair ([LFAC.2.5.3]), and the `ts` filled at entry.
fact idat_4_4__reassert_outcome {
  all r: lfac_2__reassertion |
    r.value in r.onto.value.dedup_eq
      implies (r.result_id = r.onto.fact_id and no r.emits and r.result_ts = r.onto.ts)
      else    (r.result_id != r.onto.fact_id and r.emits = assert_ev + retract_ev
               and r.result_ts = lfac_9_2__fill[r])
}

//@probe
// Non-trivial and robust: a no-op and a meaningful reassertion coexist even while
// the dedup relation is non-transitive (a~b, b~c, a!~c — the tolerance case); the
// no-op supplies a `ts` the live fact does not carry.
run probe__consistent {
  some r1, r2: lfac_2__reassertion |
    r1.value in r1.onto.value.dedup_eq and some r1.supplied and r1.supplied != r1.onto.ts and
    r2.value not in r2.onto.value.dedup_eq
  some a, b, c: lfac_2__value |
    a in b.dedup_eq and b in c.dedup_eq and a not in c.dedup_eq
} for 6

// IDEMPOTENCE: reasserting the identical value preserves the `fact_id` and emits
// no event. NO counterexample.
assert idat_4_4__reassert_same_is_noop {
  all r: lfac_2__reassertion |
    r.value = r.onto.value implies (r.result_id = r.onto.fact_id and no r.emits)
}
//@derives [IDAT.4.4]
check idat_4_4__reassert_same_is_noop for 6

// VISIBILITY: a meaningful change is never silent and never a second fact — it
// always surfaces retract+assert and takes a fresh `fact_id`. NO counterexample.
assert lfac_2_5_3__meaningful_change_is_visible_replace {
  all r: lfac_2__reassertion |
    r.value not in r.onto.value.dedup_eq
      implies (r.result_id != r.onto.fact_id and r.emits = assert_ev + retract_ev)
}
//@spec [LFAC.2.5.3]
check lfac_2_5_3__meaningful_change_is_visible_replace for 6

// A NO-OP KEEPS `ts`: a suppressed reassertion leaves the live fact's `ts`, whatever
// it supplied and whatever the step's sample — the fact did not enter ([LFAC.9.2]),
// so its assertion time stands ([LTHE.5.5]), as [LFAC.2.5.1] has a suppressed
// reassertion change nothing. NO counterexample.
assert lfac_9_2__noop_keeps_ts {
  all r: lfac_2__reassertion |
    r.value in r.onto.value.dedup_eq implies r.result_ts = r.onto.ts
}
//@derives [LFAC.9.2]
//@derives [LTHE.5.5]
//@derives [LFAC.2.5.1]
check lfac_9_2__noop_keeps_ts for 6

// A REPLACEMENT IS FILLED AT ENTRY: a meaningful change leaves live a fact whose `ts`
// is the supplied value, else the step's wall sample ([LFAC.9.2]). NO counterexample.
assert lfac_9_2__replace_fills_ts {
  all r: lfac_2__reassertion |
    r.value not in r.onto.value.dedup_eq implies r.result_ts = lfac_9_2__fill[r]
}
//@spec [LFAC.9.2]
check lfac_9_2__replace_fills_ts for 6

// `ts` IS NOT COMPARED: two reassertions of one value onto one fact decide alike,
// whatever `ts` each supplies and at whatever sample — the no-op test is a function
// of the compared value ([LFAC.2.5.1]). NO counterexample.
assert lfac_2_5_1__ts_is_not_compared {
  all r1, r2: lfac_2__reassertion |
    (r1.onto = r2.onto and r1.value = r2.value)
      implies ((no r1.emits) iff (no r2.emits))
}
//@derives [LFAC.2.5.1]
check lfac_2_5_1__ts_is_not_compared for 6

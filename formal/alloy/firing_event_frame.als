/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS callbacks — the per-firing stream-event frame (Alloy 6), and the fire guard that
 * decides whether a selected activation produces one. The global stream `seq` order is
 * modelled by util/ordering over positions, aliased `evord` (the Alloy keyword `seq` is
 * reserved).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_ncbk_2_6__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. [NCBK.2.6] fixes the stream-event order within one rule firing, along the
 * global `seq`:
 *   RULE_LHS_FACTS   (iff the firing matched >= 1 live fact)   -- immediately before BEGIN
 *   RULE_FIRE_BEGIN                                            -- opens the bracket
 *     FACT_ASSERT / ACTION_<verb> / FACT_RETRACT               -- body, strictly inside
 *   RULE_FIRE_END                                             -- closes the bracket
 * TIMER_ARMED      (iff the rate gate admitted a `cooldown` rule's firing) -- immediately after END
 * RULE_LHS_FACTS is conditional (a factless firing omits it, the BEGIN bracket still opens)
 * and, when present, is produced ATOMICALLY with BEGIN — no event lies between them.
 * TIMER_ARMED is outside the bracket and conditional the other way round: present exactly
 * when the firing's rate gate admitted it, which is to say the rule carries `cooldown`
 * ([RLOW.4.6.1]: the compiler emits the gate exactly then) and the gate answered `true` or
 * `null`; then it is the event right after RULE_FIRE_END. A suppressed firing arms nothing.
 *
 * THE GUARD, AND WHICH ACTIVATIONS BECOME FIRINGS. A terminal's fire guard
 * has up to two parts ([RDSC.4a.8.2.1]): a CONDITION and a RATE GATE. The condition is
 * evaluated when the activation is selected, before any event: `true` lets it fire, `false`
 * and `null` withhold it, and a withheld activation is not a firing -- no event, not even
 * RULE_LHS_FACTS, and the gate is not evaluated ([RDSC.4a.8.2.2]; [NCBK.2.6]'s last
 * sentence). The rate gate is evaluated INSIDE the firing, after RULE_FIRE_BEGIN and before
 * the first action, once: `true` and `null` admit the actions, `false` suppresses them while
 * the firing stands ([RDSC.4a.8.2.3]), so a suppressed firing's frame is RULE_LHS_FACTS (if
 * it matched), RULE_FIRE_BEGIN, RULE_FIRE_END and nothing between. The model's universe
 * therefore starts at the SELECTED ACTIVATION and not at the firing: the firing is `lone`, and the ordered carrier is
 * the stream's positions rather than its events, so that a withheld activation may leave
 * the stream with no event at all.
 *
 * This model encodes those rules and proves the frame's shape: FIRE_END closes the bracket,
 * every event but TIMER_ARMED preceding it; RULE_LHS_FACTS (when present) is the first event,
 * the lhs->begin pair is contiguous, the lhs event exists exactly when the firing matched a
 * fact; TIMER_ARMED (when present) is the last event, and exists exactly when the firing is
 * a `cooldown` rule's and its gate admitted it; and, whatever the guard did, a BEGIN has an
 * END and an END a BEGIN, a withheld activation emits nothing, and a gate-suppressed firing
 * keeps its bracket around an empty body and arms no timer.
 *
 * NOT MODELLED. Where the gate's evaluation falls among the events is not itself an event,
 * so it is drawn through its consequence alone, the empty body. TIMER_ARMED's payload (the
 * window and `fire_at_ns`, [NCBK.2.3]) and its timetag join to the firing ([NCBK.2.12]) are
 * not drawn: the model has one firing, so the join is trivially to it. A `cooldown:` on a
 * `call` ([LCRS.8.2]) has a gate of its own that [NCBK.2.6] says arms no TIMER_ARMED; calls
 * are `ActionVerb` events here with no gate of their own, so the model draws that clause
 * only as its instance: TIMER_ARMED answers to the rule's gate and nothing else. That a
 * suppressed firing's match is not fired again while it persists ([RDSC.4a.8.2.3]'s second
 * paragraph) is a statement over ticks, formal/idris/Rete/NetworkTick.idr's and
 * Rete/RateGate.idr's, not this snapshot's.
 *
 * ONE FIRING, SO "NO INTERVENING EVENT" IS DRAWN AGAINST THIS FIRING'S EVENTS ALONE. The
 * model's stream holds one firing's frame and nothing else, so every event that could lie
 * between RULE_LHS_FACTS and RULE_FIRE_BEGIN, or between RULE_FIRE_END and TIMER_ARMED, is
 * already placed elsewhere by the frame: both no-intervening conjuncts are consequences
 * here, not carried weight (measured, below). An event from outside the firing -- another
 * firing's, a TTL sweep's FACT_RETRACT, a TICK -- is not in the model, and that is where
 * the clause's "with no intervening event" binds.
 *
 * TEETH: drop the body-within-bracket rule and a body event escapes the bracket (before
 * BEGIN or after END); drop the lhs-iff-matched rule and a factless firing emits a spurious
 * RULE_LHS_FACTS; drop `rdsc_4a_8_2_2__selection`'s no-firing-no-event conjunct and a
 * withheld activation emits a frame; drop `rdsc_4a_8_2_3__gate_inside_the_firing`'s
 * suppression conjunct and a suppressed firing carries a body event. Measured on mutants of
 * this model's core, each against a control with no mutation that passes every check:
 * weaken `rdsc_4a_8_2_3__gate_inside_the_firing`'s iff to "no firing, no verdict" and a
 * rule with no rate gate gets a verdict and a TIMER_ARMED (`ncbk_2_6__timer_armed_iff_admitted`
 * fails); drop `ncbk_2_6__timer_armed`'s iff and a suppressed firing arms a timer
 * (`ncbk_2_6__suppressed_arms_no_timer` and `_iff_admitted` fail); drop its placement and
 * TIMER_ARMED stands anywhere (`_timer_armed_follows_end` and `_is_last` fail,
 * `_end_closes_the_bracket` holds); drop only its no-intervening half, or only the
 * lhs-atomic rule's, and no check fails -- the paragraph above.
 */
module ds/firing_event_frame
open util/ordering[ncbk_2_6__position] as evord

//@spec [NCBK.2.6]
// The stream-event kinds that make up one rule-firing frame.
abstract sig ncbk_2_6__kind {}
one sig LhsFacts    extends ncbk_2_6__kind {}
one sig FireBegin   extends ncbk_2_6__kind {}
one sig FactAssert  extends ncbk_2_6__kind {}
one sig ActionVerb  extends ncbk_2_6__kind {}
one sig FactRetract extends ncbk_2_6__kind {}
one sig FireEnd     extends ncbk_2_6__kind {}
one sig TimerArmed  extends ncbk_2_6__kind {}

//@spec [NCBK.2.6]
// A position in the global `seq` order. THE ORDERED CARRIER IS THE POSITIONS, not the
// events: util/ordering fixes its carrier at the scope, and an activation the guard
// withholds must be able to leave the stream with no event at all.
sig ncbk_2_6__position {}

//@spec [NCBK.2.6]
// The resolved live LHS facts THE STREAM CARRIES; >= 1 of them is what gates the
// RULE_LHS_FACTS event. A fact here is one on the stream: the compiler's timer, tick and
// capture facts that an `after` body's follow-up rule matches are live in working memory
// and on the stream not at all, so that firing resolves no fact of this sig and emits no
// RULE_LHS_FACTS -- the clause's "an `after` body's firing is factless".
sig ncbk_2_6__fact {}

//@spec [RDSC.4a.8.2.2]
// What the fire guard's condition answered when the activation was selected: `true` lets
// it fire; `false` and `null` both withhold it ([LNUL.4.3]). NoCondition is a guard with no
// condition part -- the rate gate alone, or no guard ([RDSC.4a.8.2.1]) -- which withholds
// nothing.
abstract sig rdsc_4a_8_2_2__answer {}
one sig CondTrue    extends rdsc_4a_8_2_2__answer {}
one sig CondFalse   extends rdsc_4a_8_2_2__answer {}
one sig CondNull    extends rdsc_4a_8_2_2__answer {}
one sig NoCondition extends rdsc_4a_8_2_2__answer {}

//@spec [RDSC.4a.8.2.3]
// The rate gate's verdict, where it was evaluated: `true` and `null` admit the actions
// ([LNUL.4.8]); `false` suppresses them while the firing stands.
abstract sig rdsc_4a_8_2_3__verdict {}
one sig GateAdmits     extends rdsc_4a_8_2_3__verdict {}
one sig GateSuppresses extends rdsc_4a_8_2_3__verdict {}

//@spec [RLOW.4.6.1]
// The rate gate in a terminal's fire guard. The compiler emits it for a rule exactly when
// the rule's header carries `cooldown`, so an activation whose guard has one is a
// `cooldown` rule's.
one sig rlow_4_6_1__rate_gate {}

//@spec [RDSC.4a.8.2.2]
// The one activation the engine selected: the live facts it resolves, its condition's
// answer, its rule's rate gate if the rule carries `cooldown`, and the gate's verdict if the
// gate was evaluated -- none where the guard has no gate, and none where the condition
// withheld the activation.
one sig rdsc_4a_8_2_2__activation {
  resolved:  set  ncbk_2_6__fact,
  condition: one  rdsc_4a_8_2_2__answer,
  rate:      lone rlow_4_6_1__rate_gate,
  gate:      lone rdsc_4a_8_2_3__verdict
}

//@spec [NCBK.2.6]
// The firing the activation became, if it became one: a withheld activation is no firing
// ([RDSC.4a.8.2.2]). Its matched facts are the activation's resolved facts.
lone sig ncbk_2_6__firing { matched: set ncbk_2_6__fact }

//@spec [NCBK.2.6]
// One stream event of the firing frame: of one kind, at one position in the global `seq`
// order.
sig ncbk_2_6__event { kind: one ncbk_2_6__kind, at: one ncbk_2_6__position }

//@spec [NCBK.2.6]
// Two events never share a position: `at` is the stream order.
fact ncbk_2_6__seq_order { all disj e1, e2: ncbk_2_6__event | e1.at != e2.at }

//@spec [RDSC.4a.8.2.2]
// Selection: the activation fires iff its condition is `true` or it has none; withheld, it
// is no firing and emits no event. A firing's matched facts are the activation's.
fact rdsc_4a_8_2_2__selection {
  (some ncbk_2_6__firing) iff (rdsc_4a_8_2_2__activation.condition in CondTrue + NoCondition)
  no ncbk_2_6__firing implies no ncbk_2_6__event
  all f: ncbk_2_6__firing | f.matched = rdsc_4a_8_2_2__activation.resolved
}

//@spec [RDSC.4a.8.2.3]
// The gate is evaluated inside the firing and nowhere else, once: there is a verdict exactly
// when there is a firing and its guard has a rate gate, so a withheld activation has none
// and a `cooldown` rule's firing has one. `false` suppresses the actions while the firing
// stands, so a suppressed firing's frame has no body event; RULE_LHS_FACTS and
// RULE_FIRE_BEGIN, emitted before the gate is read, stand.
fact rdsc_4a_8_2_3__gate_inside_the_firing {
  (some rdsc_4a_8_2_2__activation.gate) iff
    (some ncbk_2_6__firing and some rdsc_4a_8_2_2__activation.rate)
  (rdsc_4a_8_2_2__activation.gate = GateSuppresses) implies
    no kind.(FactAssert + ActionVerb + FactRetract)
}

//@spec [NCBK.2.6]
// The frame of a firing: one BEGIN, one END, at-most-one LHS_FACTS (present iff the firing
// matched >= 1 fact); BEGIN precedes END; every body event is strictly between them;
// LHS_FACTS, when present, is emitted immediately before BEGIN with no intervening event
// (produced atomically). With no firing there is no frame and, by `selection`, no event.
fact ncbk_2_6__frame {
  all f: ncbk_2_6__firing {
    one kind.FireBegin
    one kind.FireEnd
    lone kind.LhsFacts
    (some kind.LhsFacts) iff (some f.matched)
    evord/lt[kind.FireBegin.at, kind.FireEnd.at]
    all b: kind.(FactAssert + ActionVerb + FactRetract) |
      evord/lt[kind.FireBegin.at, b.at] and evord/lt[b.at, kind.FireEnd.at]
    all l: kind.LhsFacts |
      (evord/lt[l.at, kind.FireBegin.at]
       and no y: ncbk_2_6__event | (evord/lt[l.at, y.at] and evord/lt[y.at, kind.FireBegin.at]))
  }
}

//@spec [NCBK.2.6]
// TIMER_ARMED follows the bracket: at most one, present exactly when the rate gate admitted
// the firing (so the rule carries `cooldown`, and the firing stands), and then emitted
// immediately after RULE_FIRE_END with no intervening event. A suppressed firing, a firing
// with no gate and a withheld activation arm nothing.
fact ncbk_2_6__timer_armed {
  lone kind.TimerArmed
  (some kind.TimerArmed) iff (rdsc_4a_8_2_2__activation.gate = GateAdmits)
  all t: kind.TimerArmed |
    (evord/lt[kind.FireEnd.at, t.at]
     and no y: ncbk_2_6__event | (evord/lt[kind.FireEnd.at, y.at] and evord/lt[y.at, t.at]))
}

//@probe
// A withheld activation: the condition answered `false` or `null`, resolved facts and all;
// no firing, and the stream carries no event of it -- not even RULE_LHS_FACTS. Satisfiable:
// [RDSC.4a.8.2.2]'s case.
run probe__withheld_activation_leaves_no_event {
  rdsc_4a_8_2_2__activation.condition in CondFalse + CondNull
  and some rdsc_4a_8_2_2__activation.resolved
} for 7

//@probe
// A gate-suppressed firing: the condition held (or there was none) and the gate answered
// `false`; the frame is RULE_LHS_FACTS, RULE_FIRE_BEGIN, RULE_FIRE_END with nothing
// between. Satisfiable: [RDSC.4a.8.2.3]'s "suppresses the actions while the firing stands".
run probe__suppressed_firing_brackets_nothing {
  rdsc_4a_8_2_2__activation.gate = GateSuppresses
  and some rdsc_4a_8_2_2__activation.resolved
} for 7

//@probe
// A factless firing: nothing matched, so no RULE_LHS_FACTS, yet the BEGIN/END bracket still
// opens around a body event. Satisfiable — the bracket is unconditional once there is a
// firing.
run probe__factless_firing_keeps_bracket {
  some ncbk_2_6__firing
  and no ncbk_2_6__firing.matched
  and some kind.(FactAssert + ActionVerb + FactRetract)
} for 7

//@probe
// A matched firing: >= 1 fact matched, so RULE_LHS_FACTS is present and heads the frame.
// Satisfiable — confirms the lhs-present shape is reachable (checks below are non-vacuous).
run probe__matched_firing_has_lhs {
  some ncbk_2_6__firing.matched
  and some kind.(FactAssert + ActionVerb + FactRetract)
} for 7

//@probe
// An admitted `cooldown` firing that matched a fact and ran an action: the whole frame,
// RULE_LHS_FACTS through TIMER_ARMED. Satisfiable -- the armed shape is reachable, so the
// TIMER_ARMED checks below are not vacuous, and RULE_FIRE_END is not the last event of it.
run probe__admitted_cooldown_firing_arms_timer {
  rdsc_4a_8_2_2__activation.gate = GateAdmits
  and some ncbk_2_6__firing.matched
  and some kind.(FactAssert + ActionVerb + FactRetract)
} for 7

// FIRE_END CLOSES THE BRACKET: every event of the firing but TIMER_ARMED precedes
// RULE_FIRE_END in seq. NO counterexample.
assert ncbk_2_6__end_closes_the_bracket {
  all e: ncbk_2_6__event - kind.(FireEnd + TimerArmed) | evord/lt[e.at, kind.FireEnd.at]
}
//@derives [NCBK.2.6]
check ncbk_2_6__end_closes_the_bracket for 7

// TIMER_ARMED IS LAST: when present, every other event of the firing precedes it. From the
// bracket's order and TIMER_ARMED's place right after RULE_FIRE_END. NO counterexample.
assert ncbk_2_6__timer_armed_is_last {
  all t: kind.TimerArmed | all e: ncbk_2_6__event - t | evord/lt[e.at, t.at]
}
//@derives [NCBK.2.6]
check ncbk_2_6__timer_armed_is_last for 7

// TIMER_ARMED FOLLOWS END IMMEDIATELY: when present, it comes after RULE_FIRE_END with no
// event between. The fact's own conjunct, restated. NO counterexample.
assert ncbk_2_6__timer_armed_follows_end {
  all t: kind.TimerArmed |
    (evord/lt[kind.FireEnd.at, t.at]
     and no y: ncbk_2_6__event | (evord/lt[kind.FireEnd.at, y.at] and evord/lt[y.at, t.at]))
}
//@spec [NCBK.2.6]
check ncbk_2_6__timer_armed_follows_end for 7

// TIMER_ARMED IFF AN ADMITTED COOLDOWN FIRING: the event exists exactly when there is a
// firing, its rule carries `cooldown`, and the gate admitted it -- from TIMER_ARMED's rule
// and the gate's (a verdict exactly for a gated firing). NO counterexample.
assert ncbk_2_6__timer_armed_iff_admitted {
  (some kind.TimerArmed) iff
    (some ncbk_2_6__firing
     and some rdsc_4a_8_2_2__activation.rate
     and rdsc_4a_8_2_2__activation.gate = GateAdmits)
}
//@derives [NCBK.2.6]
check ncbk_2_6__timer_armed_iff_admitted for 7

// A SUPPRESSED FIRING ARMS NOTHING: the gate's `false` leaves no TIMER_ARMED. The clause's
// "must not emit one", the fact's iff read backwards. NO counterexample.
assert ncbk_2_6__suppressed_arms_no_timer {
  rdsc_4a_8_2_2__activation.gate = GateSuppresses implies no kind.TimerArmed
}
//@spec [NCBK.2.6]
check ncbk_2_6__suppressed_arms_no_timer for 7

// LHS_FACTS OPENS THE FRAME: when present, no event precedes RULE_LHS_FACTS in seq. NO
// counterexample.
assert ncbk_2_6__lhs_is_frame_opener {
  all l: kind.LhsFacts | no e: ncbk_2_6__event | evord/lt[e.at, l.at]
}
//@derives [NCBK.2.6]
check ncbk_2_6__lhs_is_frame_opener for 7

// LHS_FACTS IS ATOMIC WITH BEGIN: when present, no event lies strictly between RULE_LHS_FACTS
// and RULE_FIRE_BEGIN (the two are produced atomically). NO counterexample.
assert ncbk_2_6__lhs_atomic_with_begin {
  all l: kind.LhsFacts |
    no y: ncbk_2_6__event | (evord/lt[l.at, y.at] and evord/lt[y.at, kind.FireBegin.at])
}
//@spec [NCBK.2.6]
check ncbk_2_6__lhs_atomic_with_begin for 7

// LHS_FACTS IFF MATCHED: the RULE_LHS_FACTS event exists exactly when the firing matched a
// live fact — a factless firing emits none, and a withheld activation emits none however
// many facts it resolved. NO counterexample.
assert ncbk_2_6__lhs_iff_matched {
  (some kind.LhsFacts) iff (some ncbk_2_6__firing.matched)
}
//@spec [NCBK.2.6]
check ncbk_2_6__lhs_iff_matched for 7

// A BEGIN HAS AN END, AND AN END A BEGIN: whatever the guard did, the stream never carries
// half a bracket -- the pairing a replayer reads ([NCBK.2.12] joins the two by timetag).
// NO counterexample.
assert ncbk_2_6__begin_iff_end {
  lone kind.FireBegin
  lone kind.FireEnd
  (some kind.FireBegin) iff (some kind.FireEnd)
}
//@derives [NCBK.2.6]
check ncbk_2_6__begin_iff_end for 7

// A WITHHELD ACTIVATION EMITS NOTHING: a condition that is not `true` leaves no firing and
// no event, RULE_LHS_FACTS included, however many facts the activation resolved. NO
// counterexample.
assert rdsc_4a_8_2_2__withheld_emits_nothing {
  rdsc_4a_8_2_2__activation.condition in CondFalse + CondNull implies
    (no ncbk_2_6__firing and no ncbk_2_6__event)
}
//@spec [RDSC.4a.8.2.2]
check rdsc_4a_8_2_2__withheld_emits_nothing for 7

// THE GATE IS READ ONLY INSIDE A FIRING: a verdict implies a firing, hence a condition that
// held or was absent. NO counterexample.
assert rdsc_4a_8_2_3__gate_needs_a_firing {
  some rdsc_4a_8_2_2__activation.gate implies
    (some ncbk_2_6__firing
     and rdsc_4a_8_2_2__activation.condition in CondTrue + NoCondition)
}
//@spec [RDSC.4a.8.2.3]
check rdsc_4a_8_2_3__gate_needs_a_firing for 7

// A SUPPRESSED FIRING KEEPS ITS BRACKET: the gate's `false` leaves one BEGIN, one END, no
// body event, and RULE_LHS_FACTS exactly when the firing matched a fact -- [NCBK.2.6]'s
// frame with an empty body. NO counterexample.
assert rdsc_4a_8_2_3__suppressed_firing_keeps_bracket {
  rdsc_4a_8_2_2__activation.gate = GateSuppresses implies
    (one kind.FireBegin
     and one kind.FireEnd
     and no kind.(FactAssert + ActionVerb + FactRetract)
     and ((some kind.LhsFacts) iff (some rdsc_4a_8_2_2__activation.resolved)))
}
//@derives [RDSC.4a.8.2.3]
check rdsc_4a_8_2_3__suppressed_firing_keeps_bracket for 7

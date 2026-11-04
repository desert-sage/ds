----------------------------- MODULE rt_cap_enforcement -----------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS realtime cap enforcement -- a per-cap breach gate, as a             *)
(* SAFETY+LIVENESS spec (TLA+ / TLC). A `+realtime` contract declares hard  *)
(* caps (wm_max, agenda_cap, token_pool_cap, ...) each enforced at the      *)
(* operation that touches it ([RTCT.7.1]): the op commits only while it     *)
(* keeps the count within the cap, and a breach returns                     *)
(* `DS_ERR_CONTRACT_BREACH` while mutating NOTHING ([RTCT.7.2]). This       *)
(* models one representative counted cap over time -- assert (grow),        *)
(* retract (shrink), and the breach gate -- and proves the count can never  *)
(* cross the cap, no matter the interleaving.                              *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the tag line above it repeats the clause so the      *)
(* checker confirms the id exists AND matches.                             *)
(*                                                                         *)
(* THE INVARIANT. The counted resource never exceeds its cap ([RTCT.7.1]);  *)
(* a breaching call leaves the count untouched ([RTCT.7.2]: the engine MUST *)
(* NOT mutate state on a breach); and the engine is not poisoned -- after a *)
(* breach an assert is refused only if it, too, would cross the cap         *)
(* ([RTCT.7.2]: "subsequent calls work normally"). TLC proves the cap, the  *)
(* no-mutation and the refusal safety over every interleaving, and the      *)
(* recovery liveness on fair runs.                                         *)
(*                                                                         *)
(* TWO ENGINES, ONE CONSTANT. `rtct_7_2__POISONS` selects                   *)
(* which engine a run is of. FALSE is the clause's. TRUE is the engine the  *)
(* clause rules out: a breach latches, and every assert after it is         *)
(* refused whatever the count. It is modelled so that "not poisoned" can    *)
(* be seen to fail. The result says which operation produced it.            *)
(*                                                                         *)
(* TEETH, RUN ON EVERY LANE RUN. rt_cap_enforcement.cfg is the clause's     *)
(* engine, and every property holds. The two `.teeth.` configs beside it    *)
(* select the latching engine, and scripts/formal/check_tla.py requires TLC *)
(* to end in a violation: of `refused_only_over_cap` (assert, assert,      *)
(* breach, retract, and the next assert is refused at count 1 of 2) and of *)
(* `not_poisoned` (the same prefix, after which an assert is never again    *)
(* enabled).                                                               *)
(*                                                                         *)
(* THE CLAUSE'S BEHAVIOUR IS SEEN TO HAPPEN. Both                           *)
(* properties of [RTCT.7.2] are of the form "whenever an assert is          *)
(* refused, ...", and hold of a model in which none ever is.                *)
(* `.probe.recovers` runs the CLAUSE'S engine against a property that says  *)
(* no assert is admitted after a refusal, and TLC must return the           *)
(* behaviour that breaks it: a breach, a retract, an assert admitted.       *)
(*                                                                         *)
(* TEETH, MEASURED ONCE. There is NO soft mode                              *)
(* ([RTCT.7.4]): the only committing      *)
(* assert is guarded by `count + 1 <= CAP`. Drop that guard (a "soft"       *)
(* assert that commits over the cap) and TLC does return the trace this RT  *)
(* exists to prevent -- the count climbing 0, 1, 2, 3 past a CAP of 2 by    *)
(* repeated AssertOk.                                                      *)
(*                                                                         *)
(* But the invariant it reports violated is `rtct_7_1__TypeOK`, NOT          *)
(* `rtct_7_1__within_cap` as this comment used to say. Both encode the cap   *)
(* -- TypeOK's conjunct is `count \in 0..CAP` -- and TypeOK is checked       *)
(* first, so it trips first and TLC stops there. The teeth are real; only    *)
(* the name was wrong.                                                     *)
(***************************************************************************)
EXTENDS Naturals

\* @spec [RTCT.7.1]
\* The declared cap for the counted resource (e.g. wm_max live facts).
CONSTANT rtct_7_1__CAP

\* @spec [RTCT.7.2]
\* Which engine this run is of: FALSE, the clause's, in which a breach leaves
\* nothing behind; TRUE, the one it rules out, in which a breach latches.
CONSTANT rtct_7_2__POISONS

\* @spec [RTCT.7.1]
\* The live count of the capped resource -- what the enforcement point compares.
VARIABLE rtct_7_1__count

\* @spec [RTCT.7.2]
\* The result of the most recent operation, and which operation it was: none
\* yet; an assert that committed (DS_OK); a retract (DS_OK); an assert refused
\* with DS_ERR_CONTRACT_BREACH. The two DS_OKs are kept apart because the clause
\* is about what an ASSERT returns after a breach, and a retract's success says
\* nothing about that.
VARIABLE rtct_7_2__result

\* @spec [RTCT.7.2]
\* Whether a breach has happened. The clause's engine never reads it; the
\* latching engine refuses every assert once it is set.
VARIABLE rtct_7_2__latched

\* @spec [RTCT.7.1]
\* The state tuple -- the variables an operation may change.
rtct_7_1__vars == << rtct_7_1__count, rtct_7_2__result, rtct_7_2__latched >>

\* @spec [RTCT.7.1]
\* Initially the resource is empty and no operation has run.
rtct_7_1__Init ==
    /\ rtct_7_1__count = 0
    /\ rtct_7_2__result = "none"
    /\ rtct_7_2__latched = FALSE

\* @spec [RTCT.7.2]
\* The latching engine's refusal: a breach has happened and this engine holds
\* it against every later assert. Never true of the clause's engine.
rtct_7_2__poisoned ==
    rtct_7_2__POISONS /\ rtct_7_2__latched

\* @spec [RTCT.7.1]
\* An assert that stays within the cap commits: the count grows by one and the call
\* returns DS_OK. The enforcement point admits it because count + 1 <= CAP.
rtct_7_1__AssertOk ==
    /\ rtct_7_1__count + 1 <= rtct_7_1__CAP
    /\ ~rtct_7_2__poisoned
    /\ rtct_7_1__count' = rtct_7_1__count + 1
    /\ rtct_7_2__result' = "asserted"
    /\ UNCHANGED rtct_7_2__latched

\* @spec [RTCT.7.2]
\* An assert that would breach the cap (count + 1 > CAP) is rejected with
\* DS_ERR_CONTRACT_BREACH and mutates NOTHING -- the count is unchanged. The
\* latching engine rejects the same way when it is poisoned.
rtct_7_2__AssertBreach ==
    /\ \/ rtct_7_1__count + 1 > rtct_7_1__CAP
       \/ rtct_7_2__poisoned
    /\ rtct_7_2__result' = "breach"
    /\ rtct_7_2__latched' = TRUE
    /\ UNCHANGED rtct_7_1__count

\* @spec [RTCT.7.1]
\* A retract frees room: the count shrinks by one and the call returns DS_OK. This is
\* how a post-breach engine recovers -- freeing room lets a later assert commit.
rtct_7_1__Retract ==
    /\ rtct_7_1__count > 0
    /\ rtct_7_1__count' = rtct_7_1__count - 1
    /\ rtct_7_2__result' = "retracted"
    /\ UNCHANGED rtct_7_2__latched

\* @spec [RTCT.7.1]
\* Next: assert within cap, assert that breaches, or retract. Every state has an
\* enabled step (assert-or-breach always, retract when non-empty), so no deadlock.
rtct_7_1__Next ==
    \/ rtct_7_1__AssertOk
    \/ rtct_7_2__AssertBreach
    \/ rtct_7_1__Retract

\* @spec [RTCT.7.1]
\* The behavior spec. WEAK FAIRNESS on retract makes "a breach is recoverable" a
\* guarantee: after a breach, room is eventually freed and normal operation resumes.
\* Assert / breach carry NO fairness -- issuing an assert is the integrator's choice.
rtct_7_1__Spec ==
    /\ rtct_7_1__Init
    /\ [][rtct_7_1__Next]_rtct_7_1__vars
    /\ WF_rtct_7_1__vars(rtct_7_1__Retract)

\* @spec [RTCT.7.1]
\* Type-correctness -- a state invariant true at every reachable state.
rtct_7_1__TypeOK ==
    /\ rtct_7_1__count \in 0..rtct_7_1__CAP
    /\ rtct_7_2__result \in { "none", "asserted", "retracted", "breach" }
    /\ rtct_7_2__latched \in BOOLEAN
    /\ rtct_7_2__POISONS \in BOOLEAN

\* @derives [RTCT.7.1]
\* WITHIN CAP (safety): the counted resource never exceeds its cap -- the enforcement
\* point admits no over-cap commit, and there is no soft mode ([RTCT.7.4]). NO
\* counterexample.
rtct_7_1__within_cap ==
    rtct_7_1__count <= rtct_7_1__CAP

\* @spec [RTCT.7.2]
\* NO MUTATION ON BREACH (safety): whenever an operation reports a breach, the count
\* is unchanged on that step -- the engine does not mutate state on a breaching call.
\* NO counterexample.
\*
\* TAGGED `spec`, NOT `derives`: `rtct_7_2__AssertBreach` is the only action that
\* sets `result' = "breach"`, and `UNCHANGED rtct_7_1__count` is one of its
\* conjuncts, so this property restates that conjunct in a second spelling. A
\* transcription check (drop the conjunct and it fails), not a derivation.
rtct_7_2__breach_no_mutation ==
    [][ rtct_7_2__result' = "breach"
          => rtct_7_1__count' = rtct_7_1__count ]_rtct_7_1__vars

\* @spec [RTCT.7.2]
\* REFUSED ONLY OVER THE CAP (safety): an assert is refused only when committing
\* it would cross the cap -- whatever was refused before it. "The operation that
\* breached is rejected", and no other. NO counterexample in the clause's
\* engine; in the latching one, the assert after breach-then-retract.
\*
\* TAGGED `spec`: in the clause's engine this restates `AssertBreach`'s guard,
\* which is what makes it a check on the transcription. What it adds is that it
\* does not mention the latch, so it is the latching engine's guard it disagrees
\* with.
rtct_7_2__refused_only_over_cap ==
    [][ rtct_7_2__result' = "breach"
          => rtct_7_1__count + 1 > rtct_7_1__CAP ]_rtct_7_1__vars

\* @derives [RTCT.7.2]
\* NOT POISONED (liveness): after a breach the engine is not stuck -- room is
\* freed, and once it is an assert is admitted again. Stated on what the engine
\* will ACCEPT, not on the last result: a retract succeeding after a breach is
\* true of a poisoned engine too. Holds under weak fairness on retract (see
\* spec). NO counterexample in the clause's engine.
rtct_7_2__not_poisoned ==
    [](rtct_7_2__result = "breach" => <>(ENABLED rtct_7_1__AssertOk))

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: it says that once an assert has been refused
\* none is admitted again. FALSE of the clause's engine, and
\* rt_cap_enforcement.probe.recovers.cfg requires TLC to say so. `not_poisoned`
\* says an assert becomes POSSIBLE after a breach; this is the run in which one
\* is MADE.
probe__breach_is_final ==
    [](rtct_7_2__result = "breach" => [](rtct_7_2__result # "asserted"))

=============================================================================

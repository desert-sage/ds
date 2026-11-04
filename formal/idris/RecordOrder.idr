-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| What "in the order they were processed" orders ([RARC.5.6.8]).
|||
||| THE CLAUSE, step (8) of the consumption loop: "Records the event itself
||| (input) and any derived events (internal / action) through the recorder in
||| the order they were processed."
|||
||| That phrase is doing more work than it looks. It settles that the recorder
||| does not re-sort, which is real and worth having. What it does not settle is
||| WHEN an effect counts as processed relative to the action that caused it —
||| and the answer, measured, is counterintuitive enough that a consumer reading
||| causality off the stream gets it backwards.
|||
||| THE MEASURED MECHANISM. libds emits a TMS cascade retraction
||| BEFORE the `fact_assert` that caused it. A second runtime emitted the
||| cascade after the firing's effects and the two traces disagreed; the
||| divergence sat unresolved for want of a scenario that could tell WHICH
||| mechanism produced it, because a single-emit firing cannot distinguish
||| "the assert is announced late" from "the retract is emitted eagerly".
|||
||| `18_cascade_point` settled it: a rule emitting TWICE where only the second
||| invalidates a `no (…)` puts the retraction BETWEEN the two asserts. So
||| propagation is PER ACTION, not per firing, and a fact change is announced
||| only after it has been propagated. Both are encoded below as the two
||| theorems that scenario proved.
|||
||| WHY IT MATTERS BEYOND TRACE-MATCHING. `[RARC.5.6.8]` is what an operator
||| log, a debugger and a replayer all read. If precedence in the stream is
||| taken for causation — the natural reading of "in the order they were
||| processed" — every cascade is attributed to the wrong cause, because the
||| effect is recorded first. The clause is not false; it is silent about the
||| one thing a consumer needs to know before reading the order as a story.
module RecordOrder

%default total

--@spec [RARC.5.6.8]
||| A recorded event. Only the two the cascade question turns on: a fact
||| asserted by an action, and a fact retracted by truth maintenance because of
||| one.
data Rarc_5_6_8__event : Type where
  Assert  : Nat -> Rarc_5_6_8__event
  Retract : Nat -> Rarc_5_6_8__event

--@spec [RARC.5.6.8]
||| ONE ACTION, recorded. Propagate first, announce second: the retractions this
||| assert invalidates are emitted, then the assert itself.
|||
||| That order is the measured one, not a choice made here. It is what makes a
||| fact change "announced only after it has been propagated" — the phrasing the
||| divergence ledger settled on once `18_cascade_point` ran.
rarc_5_6_8__record_action : (asserted : Nat) -> (invalidated : List Nat) ->
                            List Rarc_5_6_8__event
rarc_5_6_8__record_action a inv = map Retract inv ++ [Assert a]

--@spec [RARC.5.6.8]
||| A whole firing: each action recorded in turn, per action.
rarc_5_6_8__record_firing : List (Nat, List Nat) -> List Rarc_5_6_8__event
rarc_5_6_8__record_firing []              = []
rarc_5_6_8__record_firing ((a, inv) :: r) =
  rarc_5_6_8__record_action a inv ++ rarc_5_6_8__record_firing r

--@derives [RARC.5.6.8]
||| PRECEDENCE IS NOT CAUSATION. The retraction an assert caused is recorded
||| BEFORE that assert.
|||
||| Stated as a refusal rather than an equation because the equation alone would
||| read as an implementation detail. What this rules out is the reading a
||| consumer naturally brings to "in the order they were processed": that if X
||| precedes Y in the stream, X did not come from Y.
rarc_5_6_8__cascade_precedes_its_cause :
  Not (rarc_5_6_8__record_action 1 [2] = [Assert 1, Retract 2])
rarc_5_6_8__cascade_precedes_its_cause Refl impossible

--@derives [RARC.5.6.8]
||| PROPAGATION IS PER ACTION. A firing that emits twice, where only the second
||| invalidates, interleaves the retraction BETWEEN the two asserts.
|||
||| This is `18_cascade_point`'s trace — a single-emit firing cannot distinguish per-action from
||| per-firing propagation, because both put the retract adjacent to the assert.
||| Two emits separate them.
rarc_5_6_8__cascade_is_per_action :
  rarc_5_6_8__record_firing [(1, []), (2, [3])]
    = [Assert 1, Retract 3, Assert 2]
rarc_5_6_8__cascade_is_per_action = Refl

--@derives [RARC.5.6.8]
||| And it is NOT per firing: the retraction does not wait for the firing's
||| effects to finish.
|||
||| The cheap fix for the original divergence was to reorder the finished effect
||| list, which would have matched the trace for a fraction of the work. It
||| would also have left two runtimes propagating against DIFFERENT working
||| memories — one against the firing's final memory, one against the memory in
||| force at each action — while agreeing on every observable the harness reads.
||| A difference that can no longer be seen is worse than one that is pinned,
||| which is why this theorem states the mechanism rather than the trace.
rarc_5_6_8__is_not_per_firing :
  Not (rarc_5_6_8__record_firing [(1, []), (2, [3])]
         = [Assert 1, Assert 2, Retract 3])
rarc_5_6_8__is_not_per_firing Refl impossible

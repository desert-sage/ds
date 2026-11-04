-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| `after` TIMERS ON THE IDRIS MODEL'S ENGINE: the timer fact a parent's firing
||| mints is stamped with the held sample, so [LTAC.3.3]'s `fire_at` is the
||| entry stamp plus the duration and the follow-up's guard
||| `monotonic_ns() >= t.fire_at` ([LTAC.3.4], [LTAC.5.3]) is the `dwell`
||| gate `t.dwell >= dur` ([LEXP.9.5.1]) that Rete/NetworkTimed.idr re-times
||| at every pump's entry; the follow-up is that one-node chain ending in the
||| timer's withdrawal ([LTAC.4.2]), and the parent's captured bindings ride
||| on the timer's payload ([LTAC.3.5], [LCCO.5.4]): [LTAC.1.1], [LTAC.3.1] to [LTAC.3.6],
||| [LTAC.4.1] to [LTAC.4.4], [LTAC.5.1], [LTAC.5.3], [LTAC.5.4],
||| [LTAC.6.2.1], [LTAC.7.1], [LTAC.8.1], [LTAC.9.1], [LDET.5.5],
||| [LTIM.2.5.1], [LTIM.2.8.2], [LTIM.2.8.4], [LTIM.2.8.6], [IRET.19.1],
||| [IRET.19.5], [RTIM.3.2.6].
|||
||| NORMATIVE COMPANION to Rete/NetworkAfter.idr, whose gate-level results
||| (the clause's counts as a list, their sum, the first due tick) this file
||| takes through one Nat lemma, and to Rete/NetworkTimed.idr, whose engine
||| the theorems here are stated on and the witnesses run.
|||
||| THE READING. [LTAC.3.1] to [LTAC.3.4] say what the compiler does: the
||| parent's RHS gains an assertion of a timer fact with `fire_at:
||| monotonic_ns() + dur` ([LTAC.3.3]), and a follow-up rule
||| `$<rule>_after_<N>` ([LTAC.8.1]) matches that timer under
||| `monotonic_ns() >= t.fire_at` and ends its RHS by retracting it. THE
||| TIMER CARRIES NO `fire_at` SLOT HERE: a fact a pump mints is stamped
||| with the held monotonic sample (Rete/NetworkTimed.idr's stamped RHS,
||| [IRET.19.1] step 4, [LTIM.2.8.6]), and `monotonic_ns()` read in the same
||| firing is that same sample ([LTIM.2.8.4]), so `fire_at` is the stamp
||| plus the duration by construction, and the guard is `t.dwell >= dur`:
||| the leaf Rete/NetworkTimed.idr substitutes and re-times, on a single
||| positive pattern ([LTIM.2.6.1]). What Rete/NetworkAfter.idr's header
||| names as not modelled -- an emit whose payload reads the clock -- is
||| not needed: the stamp reads it. THE CAPTURES RIDE ON THE TIMER: where
||| [LTAC.3.5] carries the parent's bindings in a separate capture fact
||| joined on a correlation, the model folds them into the timer's payload,
||| one slot per read, snapshot at the parent's firing ([LCCO.5.4]); both
||| facts are compiler-owned and on no stream ([RFCS.6a.5]), so the two are
||| one at every pump boundary, and the fold keeps the follow-up a
||| single-positive-pattern chain. The compiler's `$ClockTick` beta under
||| the timer is this engine's pump-entry re-time, as Rete/NetworkTimed.idr
||| reads the fire guard.
|||
||| PROVED.
|||
|||   * THE GUARD IS THE GATE (`ltac_3_4__guard_is_due`): for every stamp
|||     `s`, every positive duration `S d` ([LTAC.7.1]: a zero delay is no
|||     timer) and every sample `m`, `t.dwell >= S d` from the stamp is
|||     Rete/NetworkAfter.idr's `monotonic_ns() >= fire_at` with `fire_at =
|||     s + S d`. A Nat lemma; the `>=` against an absolute instant carried
|||     through ([LTAC.5.3]).
|||   * THE STAMP IS `fire_at` LESS THE DURATION (`ltac_3_3__stamp_is_fire_at`):
|||     an `Emit` into an explicit kind at the net's clock `m` stamps the
|||     fact it mints with `m` (Rete/EntryStamp.idr's assert for the explicit
|||     lifecycle always enters), and from that stamp the gate opens at
|||     `m + S d`: [LTAC.3.3]'s `monotonic_ns() + dur` under [LTIM.2.8.4].
|||   * ONE CYCLE OF ONE TIMER ON THE IDRIS MODEL'S ENGINE
|||     (`ltac_5_1__timer_cycle`): from the quiescent state at a clock --
|||     the timer live and unmatched while its gate is shut, gone once it
|||     has opened -- a tick then a pump, through Rete/NetworkTimed.idr's
|||     `ltim_2_8_4__tick_timed` and `ltim_2_4_2__pump_timed` (the re-time at
|||     entry, the gated stamped run), fires the gate's edge -- once, with the
|||     timer's retraction, when the sample reaches `s + d`; nothing
|||     otherwise -- and leaves the quiescent state at the new clock, the
|||     wall, the stamps and the trackers standing.
|||   * THE COUNTS ARE THE EDGES (`ltac_5_1__timer_counts_are_edges_timed`):
|||     over any tick history from any starting clock, the follow-up's
|||     firings per pump are the rising edges of the `dwell` gate; at most
|||     one (`ltac_5_1__at_most_once_timed`, Rete/NetworkTwoClocks.idr's C3a
|||     on the gate, which rises).
|||   * THE THEOREMS ([LTAC.5.1], [LTAC.5.3], [LTAC.4.2]):
|||     `ltac_5_1__fires_on_the_first_due_tick_timed` -- from a clock below
|||     `s + S d` the counts are Rete/NetworkAfter.idr's `due_edges` at that
|||     `fire_at`: 0 while the sample stays below it, 1 at the first tick
|||     whose sample reaches it, 0 after; `ltac_5_3__never_lost_timed` -- the
|||     counts sum to one exactly when the history's clock has reached it;
|||     `ltac_4_2__gone_once_due_timed` -- after any history whose clock has
|||     reached it the timer is not in working memory.
|||   * THE SNAPSHOT ([LTAC.3.5], [LCCO.5.4]; `ltac_3_5__capture_snapshot`):
|||     for every body expression of the fragment whose reads are all
|||     captured, its value over the timer at the follow-up's firing is its
|||     value over the parent's match at the parent's firing, given that the
|||     timer's payload slot at each capture's index holds what the parent's
|||     read gave. By induction on the expression.
|||   * THE FRAME (`ltac_3_1__lower_untimed`): a rule with no `after` clause
|||     lowers to itself, with its own test; a transcription, said so.
|||     Rete/NetworkTimed.idr's frame then says every earlier fixture runs
|||     as it did.
|||   * EXECUTED, `Refl` through the lowering, the loader, the stamps and the
|||     gated pump, the seven fixtures' shapes: one-shot, and nothing before
|||     the delay ([LTAC.4.2], [LTAC.9.1]); the follow-up's body minting a
|||     fact, and the timer surviving its parent's retraction ([LTAC.3.3],
|||     [LTAC.6.2.1]); two parent firings, two timers, each on its own tick
|||     ([LTAC.4.3]); two timers due in one tick both fired in it, the
|||     earlier-minted first ([LTAC.5.4], [LDET.5.5]); two TTL expiries and
|||     a timer inside one clock move all done at the one pump
|||     ([RTIM.3.2.6]).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. The value of the
||| lowered guard on Integer literals: the runner evaluates `dwell >= d` by
||| Rete/Eval.idr's Integer order, and the theorems take the gate form
||| (`ltac_3_4__due_stamped`, Rete/NetworkTwoClocks.idr's `dwell` gate); the
||| two decide alike on the executed shapes (`ltac_3_4__guard_forms_agree`),
||| as Rete/NetworkTimed.idr's `within` does, and are not proved equal on
||| variables. The value code's round trip through the timer's payload (the
||| snapshot's hypothesis), run as every code is. The general theorems are of
||| one timer, the follow-up alone, from the quiescent state at a clock; a
||| program with the parent beside the follow-up, two timers, a body that
||| mints, are executed. The `as` key and its supersedure ([LTAC.2.2.1]), a
||| nested clause ([LTAC.6.2.2]), a `call` in a body, the capture fact as its
||| own fact ([LTAC.3.5]'s mechanism), `every`, [LTAC.4.4]'s persistence and
||| the sweep's placement are outside.
module Rete.NetworkTimer

-- The imports are Rete/NetworkWall.idr's whole, with Rete/NetworkEdges.idr
-- and Rete/NetworkAfter.idr for the gate-level results, for the reason
-- Rete/NetworkThen.idr's comment gives: a run evaluated in a witness unfolds
-- only through modules the file imports.
import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkOrder
import Rete.NetworkOrderKeep
import Rete.NetworkRefraction
import Rete.NetworkCorollaries
import Rete.NetworkAgree
import Rete.NetworkTransferTable
import Rete.NetworkTransferAgree
import Rete.NetworkTransfer
import Rete.NetworkTmsCascade
import Rete.NetworkTms
import Rete.NetworkTmsTransfer
import Rete.NetworkTtl
import Rete.NetworkTraced
import Rete.NetworkTick
import Rete.NetworkClocked
import Rete.NetworkEdges
import Rete.NetworkTwoClocks
import Rete.NetworkAfter
import Rete.NetworkCooldown
import Rete.NetworkTimed
import Rete.EntryStamp
import Rete.Eval
import Rete.RunFold
import Rete.RateGate
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import TwoClocks
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.Maybe
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The timer, the guard, the follow-up [LTAC.3.2], [LTAC.3.4], [LTAC.4.2]
-- ---------------------------------------------------------------------

--@spec [LTAC.3.2]
--@spec [LTAC.4.1]
||| A TIMER FACT ON THE IDRIS MODEL'S ENGINE: kind 0 in the witnesses' kind
||| order, key 1 (the empty tuple's code: the schema declares no `key`), its
||| payload the captured values coded -- what the parent's `emitx` computes
||| -- or 1 for a body that reads nothing ([LTAC.3.6]). No `fire_at` slot:
||| the entry stamp carries it (the header's reading); no `corr`. An author
||| writes no pattern on it ([LTAC.4.1]): the lowering alone names the
||| kind.
public export
ltac_3_2__capture_timer : Nat -> Lfac_1_7_1__fact
ltac_3_2__capture_timer p = MkFact 0 0 1 p

--@spec [LTAC.3.4]
--@spec [LTAC.5.3]
--@spec [LEXP.9.5.1]
||| THE FOLLOW-UP'S GUARD AS THE LOWERING WRITES IT: `t.dwell >= dur` on the
||| chain's one positive pattern, in the witnesses' units (the lowering
||| scales the leaf to nanoseconds, as for every `dwell`): [LTAC.3.4]'s
||| `monotonic_ns() >= t.fire_at` with `fire_at` the stamp plus the
||| duration. `>=` against the absolute instant, as [LTAC.5.3] requires.
public export
ltac_3_4__guard_expr : Nat -> Iret_7_5__expr
ltac_3_4__guard_expr d = ECmp OpGe (EClock (ReadDwell 0)) (ELit (VInt (cast d)))

--@spec [LTAC.3.4]
--@spec [LTIM.2.8.2]
||| THE GUARD AS THE RUNNER BUILDS IT: Rete/NetworkTimed.idr's monotonic
||| timed test of the expression, which reads no `now()`.
public export
ltac_3_4__guard : Iret_7_6__env -> Nat -> Ltim_2_4_1__ttest
ltac_3_4__guard env d = ltim_2_8_2__mono_test_of env (ltac_3_4__guard_expr d)

--@spec [LTAC.3.4]
--@spec [LEXP.9.5.1]
--@spec [LTIM.2.8.6]
||| THE GUARD AS A GATE: Rete/NetworkTwoClocks.idr's `dwell >= d` over the
||| stamp table, the form the theorems take -- `t.dwell` read off the
||| candidate's entry stamp, compared as naturals.
public export
ltac_3_4__due_stamped : Nat -> Ltim_2_4_1__ttest
ltac_3_4__due_stamped d = \st => lexp_9_5_1__dwell_gate st d

--@derives [LTIM.2.8.2]
--@derives [LTAC.3.4]
||| THE GATE FORM IS A MONOTONIC GATE at every stamp table: it reads the
||| monotonic sample and the stamps, nothing of the wall. C2's hypothesis,
||| inhabited; a transcription of Rete/NetworkTwoClocks.idr's, said so.
export
ltac_3_4__due_stamped_monotonic : (d : Nat) -> (st : Ltim_2_8_6__stamps) -> Ltim_2_8_2__monotonic (ltac_3_4__due_stamped d st)
ltac_3_4__due_stamped_monotonic d st = lexp_9_5_1__dwell_gate_monotonic st d

--@spec [LTAC.3.4]
--@spec [IRET.19.5]
||| THE TIMED TESTS of the follow-up alone, by ordinal: its gate.
public export
ltac_3_4__tests_stamped : Nat -> List (Maybe Ltim_2_4_1__ttest)
ltac_3_4__tests_stamped d = [Just (ltac_3_4__due_stamped d)]

--@derives [LTAC.3.4]
--@derives [LEXP.9.5.1]
||| THE TWO FORMS DECIDE ALIKE ON THE EXECUTED SHAPES: the runner's
||| expression and the gate, on the timer stamped 0 with duration 5, both
||| admit at the sample 6 and refuse at the sample 3. Computed; what the
||| evaluator's Integer order gives on literals is run, not proved, as
||| Rete/NetworkTimed.idr's `within` is.
export
ltac_3_4__guard_forms_agree :
  ( ltac_3_4__guard ltim_2_4_1__wenv 5 [(0, 0)] (6, 0) [] (ltac_3_2__capture_timer 1) = True
  , ltac_3_4__guard ltim_2_4_1__wenv 5 [(0, 0)] (3, 0) [] (ltac_3_2__capture_timer 1) = False
  , ltac_3_4__due_stamped 5 [(0, 0)] (6, 0) [] (ltac_3_2__capture_timer 1) = True
  , ltac_3_4__due_stamped 5 [(0, 0)] (3, 0) [] (ltac_3_2__capture_timer 1) = False )
ltac_3_4__guard_forms_agree = (Refl, Refl, Refl, Refl)

-- ---------------------------------------------------------------------
-- The lowering of an `after` clause [LTAC.3.1], [LTAC.3.3], [LTAC.8.1]
-- ---------------------------------------------------------------------

--@spec [LTAC.1.1]
||| AN `after` CLAUSE on the model, "an optional trailing clause on a
||| rule's RHS" that "schedules its action list to run after the declared
||| duration": its timer kind, its duration, the captures as a function of
||| the parent's match -- the key `1` and the captured values coded, what
||| the parent's `emitx` computes ([LTAC.3.5]) -- and its body, every
||| captured read already rewritten to the timer's slot
||| (`ltac_3_5__rewrite`). No `as` key ([LTAC.2.2.1]) and nothing nested
||| ([LTAC.6.2.2]): the lowering refuses both.
public export
Ltac_1_1__clause : Type
Ltac_1_1__clause = (Nat, Nat, (List Lfac_1_7_1__fact -> (Nat, Nat)), List Lgra_10_1__action)

--@spec [LTAC.3.3]
--@spec [LTAC.3.1]
||| THE PARENT'S RHS GAINS THE TIMER'S ASSERTION, appended after its own
||| actions, one per clause in clause order: [LTAC.3.3]'s "appended after
||| the rule's original immediate actions".
public export
ltac_3_3__with_timer : (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> Ltac_1_1__clause ->
                       (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltac_3_3__with_timer (pats, acts) (k, d, capture, body) = (pats, acts ++ [Emit k capture])

--@spec [LTAC.3.4]
--@spec [LTAC.8.1]
--@spec [LTAC.4.2]
--@spec [LTAC.6.2.1]
||| THE FOLLOW-UP RULE: the timer kind's single positive pattern under the
||| guard as loaded at the sample (0, 0) and no stamps (the pump re-times
||| it), its RHS the body's actions ([LTAC.6.2.1]: any action of a rule's
||| RHS) followed by the retraction of the timer ([LTAC.4.2]). Named
||| `$<rule>_after_<N>` by the lowering ([LTAC.8.1]), which the model does
||| not carry.
public export
ltac_3_4__follow_up : Iret_7_6__env -> Ltac_1_1__clause -> (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltac_3_4__follow_up env (k, d, capture, body) = ([(k, ltac_3_4__guard env d [] (0, 0), False)], body ++ ltac_4_2__retract_timer)

--@spec [LTAC.3.1]
--@spec [LTAC.3.3]
--@spec [LTAC.3.4]
--@spec [LTAC.8.1]
||| THE LOWERING OF A RULE WITH ITS `after` CLAUSES: the parent with one
||| timer emit per clause appended after its actions, then one follow-up
||| per clause, in that order after the parent -- the compiler's terminal
||| order ([LDET.5.4]), which the lowering gives the Idris model as rule
||| ordinals.
public export
ltac_3_1__lower : Iret_7_6__env -> (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List Ltac_1_1__clause ->
                  List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltac_3_1__lower env rule clauses = foldl ltac_3_3__with_timer rule clauses :: map (ltac_3_4__follow_up env) clauses

--@spec [LTAC.3.1]
--@spec [LTAC.3.4]
--@spec [IRET.19.5]
||| THE TIMED TESTS the lowering gives with the rules ([LTAC.3.1]'s rewrite,
||| the tests' half): the parent's own (none for an untimed parent), then
||| each follow-up's guard.
public export
ltac_3_1__lower_tests : Iret_7_6__env -> Maybe Ltim_2_4_1__ttest -> List Ltac_1_1__clause -> List (Maybe Ltim_2_4_1__ttest)
ltac_3_1__lower_tests env parent clauses = parent :: map (\(k, d, capture, body) => Just (ltac_3_4__guard env d)) clauses

--@derives [LTAC.3.1]
||| THE FRAME: a rule with no `after` clause lowers to itself, with its own
||| test and nothing after it. A TRANSCRIPTION of the two definitions, said
||| so: with it, Rete/NetworkTimed.idr's frame says every fixture the Idris model
||| compared before this rung runs as it did.
export
ltac_3_1__lower_untimed : (env : Iret_7_6__env) -> (rule : (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) -> (parent : Maybe Ltim_2_4_1__ttest) ->
                          (ltac_3_1__lower env rule [] = [rule], ltac_3_1__lower_tests env parent [] = [parent])
ltac_3_1__lower_untimed env rule parent = (Refl, Refl)

-- ---------------------------------------------------------------------
-- The guard is the gate [LTAC.3.4], [LTAC.3.3], [LTAC.7.1]
-- ---------------------------------------------------------------------

--@derives [LTAC.5.3]
||| The two Boolean orders on naturals -- the Prelude's `lte`, which the
||| `dwell` gate uses, and Rete/TmsRun.idr's `lte_b`, which
||| Rete/NetworkAfter.idr's gate uses -- are one function.
export
ltac_5_3__lte_is_lte_b : (a, b : Nat) -> lte a b = iret_12__lte_b a b
ltac_5_3__lte_is_lte_b Z b = Refl
ltac_5_3__lte_is_lte_b (S a) Z = Refl
ltac_5_3__lte_is_lte_b (S a) (S b) = ltac_5_3__lte_is_lte_b a b

--@derives [LTAC.3.4]
--@derives [LTAC.3.3]
--@derives [LTAC.7.1]
--@derives [LEXP.9.5.1]
--@derives [LTAC.5.3]
||| THE GUARD IS THE GATE: for every stamp, every positive duration and
||| every sample, `dwell >= S d` from the stamp `s` is `monotonic_ns() >=
||| fire_at` with `fire_at = s + S d`, Rete/NetworkAfter.idr's gate. The
||| duration is positive by [LTAC.7.1] (a zero delay is no timer; the
||| compiler refuses it), and that is what closes the case of a stamp
||| ahead of the sample, where `dwell` saturates at zero. By induction on
||| the stamp and the sample together.
export
ltac_3_4__guard_is_due : (s, d, m : Nat) -> lexp_9_5_1__dwell_gate_b s (S d) m = ltac_3_4__due_b (s + S d) m
ltac_3_4__guard_is_due Z d Z = Refl
ltac_3_4__guard_is_due Z d (S m) = ltac_5_3__lte_is_lte_b d m
ltac_3_4__guard_is_due (S s) d Z = Refl
ltac_3_4__guard_is_due (S s) d (S m) = ltac_3_4__guard_is_due s d m

--@derives [LTAC.3.3]
--@derives [LTIM.2.8.6]
--@derives [IRET.19.1]
||| A MINT INTO AN EXPLICIT KIND IS STAMPED WITH THE SAMPLE: the explicit
||| lifecycle's assert always enters ([IRET.19.1] step 4), so
||| Rete/EntryStamp.idr's stamp of the fresh id is the sample. Stated over a
||| lifecycle equal to `Explicit`, so that a program's `life pg k` can be
||| passed with its equation.
export
ltac_3_3__explicit_mint_is_stamped : (l : Lscp_1_3__lifecycle) -> l = Explicit -> (avoid : List Nat) -> (k, key, pay, m : Nat) ->
                                     (wm : Rarc_5_6_4__wm) -> (st : Ltim_2_8_6__stamps) ->
                                     ltim_2_8_6__stamp_of (lfac_2_5_3__fresh_id avoid wm) (ltim_2_8_6__assert_stamps l avoid k key pay m wm st) = Just m
ltac_3_3__explicit_mint_is_stamped Explicit Refl avoid k key pay m wm st =
  ltim_2_8_6__entered_is_stamped Explicit avoid k key pay m wm (wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay]) st Refl

--@derives [LTAC.3.3]
--@derives [LTIM.2.8.6]
--@derives [IRET.19.1]
--@derives [LTIM.2.8.4]
||| THE STAMP IS `fire_at` LESS THE DURATION. An `Emit` into an explicit
||| kind, run by the stamped RHS at the net's clock `m`, stamps the fact it
||| mints with `m`: Rete/EntryStamp.idr's assert for the explicit lifecycle
||| always enters ([IRET.19.1] step 4, [LTIM.2.8.6]). And from that stamp the
||| follow-up's gate is `monotonic_ns() >= m + S d`: [LTAC.3.3]'s `fire_at:
||| monotonic_ns() + dur`, the clock read in the firing being the held
||| sample `m` ([LTIM.2.8.4]). For every program, kind, sample, activation,
||| value function, working memory and stamp table.
export
ltac_3_3__stamp_is_fire_at : (pg : Lcyc_3_2_1__program) -> (k : Nat) -> life pg k = Explicit -> (m : Nat) -> (a : Iret_8_1__act) ->
                             (value : List Lfac_1_7_1__fact -> (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (st : Ltim_2_8_6__stamps) ->
                             ( ltim_2_8_6__stamp_of (lfac_2_5_3__fresh_id (iret_11_3__fact_ids (atuple a)) wm)
                                 (ltim_2_8_6__record_action pg m a (Emit k value) wm st) = Just m
                             , (d, c : Nat) -> lexp_9_5_1__dwell_gate_b m (S d) c = ltac_3_4__due_b (m + S d) c )
ltac_3_3__stamp_is_fire_at pg k lifeE m a value wm st =
  ( ltac_3_3__explicit_mint_is_stamped (life pg k) lifeE (iret_11_3__fact_ids (atuple a)) k (fst (value (atuple a))) (snd (value (atuple a))) m wm st
  , \d, c => ltac_3_4__guard_is_due m d c )

-- ---------------------------------------------------------------------
-- Edges respect pointwise-equal gates [LTIM.2.5.1]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| AN EDGE from two readings of a gate: 1 when it was shut and is open, 0
||| otherwise. Rete/NetworkEdges.idr's `edge_at` at the two readings, named
||| so that an equality of readings lifts to an equality of edges by
||| congruence.
public export
ltim_2_5_1__edge_of : Bool -> Bool -> Nat
ltim_2_5_1__edge_of before after = if not before && after then 1 else 0

--@derives [LTIM.2.5.1]
||| An edge is decided by the gate's two readings, so two gates that read
||| alike at every clock make one edge.
export
ltim_2_5_1__edge_at_ext : (g, g' : Nat -> Bool) -> ((x : Nat) -> g x = g' x) -> (c, t : Nat) ->
                          ltim_2_5_1__edge_at g c t = ltim_2_5_1__edge_at g' c t
ltim_2_5_1__edge_at_ext g g' h c t = cong2 ltim_2_5_1__edge_of (h c) (h (rarc_5_6_3__next_clock c t))

--@derives [LTIM.2.5.1]
||| And so over a history: the edges of two gates that read alike at every
||| clock are one list. What lets Rete/NetworkAfter.idr's results, stated
||| on the `fire_at` gate, be read on the `dwell` gate.
export
ltim_2_5_1__edges_ext : (g, g' : Nat -> Bool) -> ((x : Nat) -> g x = g' x) -> (c : Nat) -> (ticks : List Nat) ->
                        Ltim_2_5_1__edges g c ticks = Ltim_2_5_1__edges g' c ticks
ltim_2_5_1__edges_ext g g' h c [] = Refl
ltim_2_5_1__edges_ext g g' h c (t :: ts) =
  cong2 (::) (ltim_2_5_1__edge_at_ext g g' h c t) (ltim_2_5_1__edges_ext g g' h (rarc_5_6_3__next_clock c t) ts)

-- ---------------------------------------------------------------------
-- The quiescent state of one timer on the Idris model's engine
-- ---------------------------------------------------------------------

--@spec [LTAC.3.4]
--@spec [LTAC.5.1]
--@spec [LTAC.4.2]
||| WORKING MEMORY OF ONE TIMER AT A CLOCK, quiescent: the timer stamped
||| `s` with duration `d` live while its gate is shut at the clock, gone
||| once the gate has opened -- the follow-up fired and retracted it.
public export
ltac_3_4__wm_timed : (s, d, c, p : Nat) -> Rarc_5_6_4__wm
ltac_3_4__wm_timed s d c p = if lexp_9_5_1__dwell_gate_b s d c then [] else [ltac_3_2__capture_timer p]

--@spec [LTAC.3.4]
||| THE FOLLOW-UP'S CHAIN at a clock over the timer's stamp: the one node
||| with the gate re-timed to the clock, its activations, the retraction.
public export
ltac_3_4__chain_timed : (s, d, c : Nat) -> List Iret_8_1__act -> Rlow_4_2_1__chain
ltac_3_4__chain_timed s d c acts = MkChain [MkBeta 0 (lexp_9_5_1__dwell_at c [(0, s)] d) False [[]] []] acts ltac_4_2__retract_timer

--@spec [LTAC.3.4]
||| THE FOLLOW-UP'S NETWORK over a working memory at a clock: the timer
||| alpha holding it and the one chain.
public export
ltac_3_4__net_timed : (s, d, c : Nat) -> Rarc_5_6_4__wm -> List Iret_8_1__act -> Rarc_5_3_1__network
ltac_3_4__net_timed s d c wm acts = MkNetwork [MkAlpha 0 lcdb_3_2_1__admits_all wm] [ltac_3_4__chain_timed s d c acts]

--@spec [LTAC.3.4]
--@spec [LTIM.2.8.6]
||| A TIMED STATE of the follow-up: the clocked net over a working memory
||| with no row and no deadline at a clock, the wall, the timer's stamp as
||| the one entry, no tracker.
public export
ltac_3_4__timed_state : (s, d, c, w : Nat) -> Rarc_5_6_4__wm -> List Iret_8_1__act -> Ltim_2_4_1__timed_state
ltac_3_4__timed_state s d c w wm acts =
  (MkSampled (MkClockedNet (MkTmsNet (MkEngine wm (ltac_3_4__net_timed s d c wm acts)) []) [] c) w [(0, s)], [])

--@spec [LTAC.3.4]
--@spec [LTAC.5.1]
--@spec [LTAC.4.2]
||| THE QUIESCENT STATE OF ONE TIMER AT A CLOCK: the timer's working memory
||| at that clock, no activation. What a cycle leaves, and what the
||| theorems start from.
public export
ltac_3_4__state_timed : (s, d, c, p, w : Nat) -> Ltim_2_4_1__timed_state
ltac_3_4__state_timed s d c p w = ltac_3_4__timed_state s d c w (ltac_3_4__wm_timed s d c p) []

--@spec [LTAC.3.4]
--@spec [LTAC.5.1]
--@spec [LTIM.2.4.2]
||| THE ACTIVATION A RE-TIME MAKES of one timer: the timer's match, unfired,
||| when the gate was shut at the old clock and is open at the new; none
||| otherwise.
public export
ltac_3_4__born_timed : (s, d, c, c', p : Nat) -> List Iret_8_1__act
ltac_3_4__born_timed s d c c' p =
  if not (lexp_9_5_1__dwell_gate_b s d c) && lexp_9_5_1__dwell_gate_b s d c' then [MkAct [ltac_3_2__capture_timer p] False] else []

--@spec [LTAC.5.1]
--@spec [LTAC.4.2]
||| THE DUE STATE: the timer live and its activation born unfired at the
||| clock that reached `fire_at`. What the run consumes.
public export
ltac_5_1__due_timed : (s, d, c', p, w : Nat) -> Ltim_2_4_1__timed_state
ltac_5_1__due_timed s d c' p w =
  ltac_3_4__timed_state s d c' w [ltac_3_2__capture_timer p] [MkAct [ltac_3_2__capture_timer p] False]

--@spec [LTAC.4.2]
--@spec [LTAC.3.4]
||| AN IDLE STATE: the follow-up with nothing to fire over a working memory
||| at a clock.
public export
ltac_4_2__idle_timed : (s, d, c', w : Nat) -> Rarc_5_6_4__wm -> Ltim_2_4_1__timed_state
ltac_4_2__idle_timed s d c' w wm = ltac_3_4__timed_state s d c' w wm []

--@spec [LTAC.5.1]
--@spec [LTAC.4.2]
||| THE FIRINGS OF ONE EDGE: the follow-up's one firing of the timer, with
||| the gate admitting, when the edge is made; none otherwise. A named
||| function on the edge count, not an inline `if` (the guide's note).
public export
ltac_5_1__firings_if : Nat -> Nat -> List (Nat, Iret_7_1__token, Bool)
ltac_5_1__firings_if Z p = []
ltac_5_1__firings_if (S _) p = [(0, [ltac_3_2__capture_timer p], True)]

--@derives [LTAC.5.1]
||| The firings of an edge are as many as the edge: an edge is 0 or 1.
export
ltac_5_1__firings_if_length : (g : Nat -> Bool) -> (c, t, p : Nat) ->
                              length (ltac_5_1__firings_if (ltim_2_5_1__edge_at g c t) p) = ltim_2_5_1__edge_at g c t
ltac_5_1__firings_if_length g c t p with (not (g c) && g (rarc_5_6_3__next_clock c t))
  ltac_5_1__firings_if_length g c t p | True = Refl
  ltac_5_1__firings_if_length g c t p | False = Refl

-- ---------------------------------------------------------------------
-- One cycle of one timer: the tick, the re-time at entry, the run
-- ---------------------------------------------------------------------

--@derives [LTAC.3.4]
--@derives [LTAC.5.1]
--@derives [IRET.19.5]
--@derives [LTIM.2.4.3]
||| THE RE-TIME OF THE FOLLOW-UP at a new clock over the timer's stamp: the
||| node takes the gate at the new clock; the timer's match is born unfired
||| exactly when the gate was shut and is open; nothing is ended, a rising
||| gate refusing nothing it admitted. Computed, over the four readings of
||| the gate; the gate's old reading inside the node's filter is rewritten
||| in by hand once the new one is decided (Rete/NetworkAfter.idr's
||| `tick_literal`).
export
ltac_3_4__tick_literal_timed : (s, d, c, c', p, w : Nat) ->
                               iret_19_5__tick (ltim_2_4_1__tests_at w [(0, s)] (ltac_3_4__tests_stamped d)) c'
                                 (MkEngine (ltac_3_4__wm_timed s d c p) (ltac_3_4__net_timed s d c (ltac_3_4__wm_timed s d c p) []))
                                 = MkEngine (ltac_3_4__wm_timed s d c p) (ltac_3_4__net_timed s d c' (ltac_3_4__wm_timed s d c p) (ltac_3_4__born_timed s d c c' p))
-- The scrutinees are the gate's normal form, `lte d (minus c s)`, so that
-- the proof `pc` rewrites the reading the filter holds in that spelling.
ltac_3_4__tick_literal_timed s d c c' p w with (lte d (minus c s)) proof pc
  ltac_3_4__tick_literal_timed s d c c' p w | True = Refl
  ltac_3_4__tick_literal_timed s d c c' p w | False with (lte d (minus c' s))
    ltac_3_4__tick_literal_timed s d c c' p w | False | True = rewrite pc in Refl
    ltac_3_4__tick_literal_timed s d c c' p w | False | False = rewrite pc in Refl

--@derives [LTIM.2.4.3]
--@derives [IRET.19.5]
--@derives [LTAC.3.4]
||| THE RE-TIME AT THE PUMP'S ENTRY on the quiescent state's net moved to a
||| new clock: the cascade touches nothing (no row), so it is the re-time
||| alone, which the lemma above computes.
export
ltac_3_4__retime_literal_timed : (pg : Lcyc_3_2_1__program) -> (s, d, c, c', p, w : Nat) ->
                                 ltim_2_4_3__retime_at_entry pg (ltac_3_4__tests_stamped d)
                                   (MkSampled (MkClockedNet (MkTmsNet (MkEngine (ltac_3_4__wm_timed s d c p) (ltac_3_4__net_timed s d c (ltac_3_4__wm_timed s d c p) [])) []) [] c') w [(0, s)])
                                   = MkSampled (MkClockedNet (MkTmsNet (MkEngine (ltac_3_4__wm_timed s d c p) (ltac_3_4__net_timed s d c' (ltac_3_4__wm_timed s d c p) (ltac_3_4__born_timed s d c c' p))) []) [] c') w [(0, s)]
ltac_3_4__retime_literal_timed pg s d c c' p w =
  cong (\n => MkSampled n w [(0, s)])
       (trans (ltim_2_7_2__no_cascade_is_the_retime pg (ltim_2_4_1__tests_at w [(0, s)] (ltac_3_4__tests_stamped d))
                 (MkEngine (ltac_3_4__wm_timed s d c p) (ltac_3_4__net_timed s d c (ltac_3_4__wm_timed s d c p) [])) [] [] c' Refl)
              (cong (\e => MkClockedNet (MkTmsNet e []) [] c') (ltac_3_4__tick_literal_timed s d c c' p w)))

--@derives [LTAC.4.2]
--@derives [LTAC.3.4]
--@derives [LTIM.2.5.4]
||| THE FOLLOW-UP FIRES AND RETRACTS ITS TIMER on the Idris model's engine: one
||| firing from the due state -- no cooldown, so the gate admits -- marks
||| the activation, runs the withdraw through the stamped RHS, which stamps
||| nothing, and leaves the timer gone from working memory, the alpha and
||| the terminal, the wall, the stamps and the trackers as they were.
||| Computed, once the timer's own equality and the gate's reading are
||| given (Rete/NetworkAfter.idr's `step_fires`).
export
ltac_4_2__step_fires_timed : (pg : Lcyc_3_2_1__program) -> (s, d, c', p, w : Nat) -> lte d (minus c' s) = True ->
                             ltim_2_5_4__fire_timed pg lcdb_3_2_1__no_ttl [Nothing] (ltac_5_1__due_timed s d c' p w)
                               = Just ((0, [ltac_3_2__capture_timer p], True), ltac_4_2__idle_timed s d c' w [])
ltac_4_2__step_fires_timed pg s d c' p w due =
  rewrite lcyc_1_1__nat_eq_refl p in rewrite due in rewrite lcyc_1_1__nat_eq_refl p in Refl

--@derives [LTAC.4.2]
--@derives [IRET.11.4]
||| NOTHING FIRES FROM AN IDLE STATE, whatever working memory holds: no
||| activation, no selection.
export
ltac_4_2__fire_idle_timed : (pg : Lcyc_3_2_1__program) -> (s, d, c', w : Nat) -> (wm : Rarc_5_6_4__wm) ->
                            ltim_2_5_4__fire_timed pg lcdb_3_2_1__no_ttl [Nothing] (ltac_4_2__idle_timed s d c' w wm) = Nothing
ltac_4_2__fire_idle_timed pg s d c' w wm = Refl

--@derives [LTAC.4.2]
--@derives [IRET.11.4]
||| THE RUN FROM THE DUE STATE: the one firing, then nothing to fire;
||| quiescent, the timer gone, one firing traced.
export
ltac_4_2__run_fires_timed : (pg : Lcyc_3_2_1__program) -> (k, s, d, c', p, w : Nat) -> lte d (minus c' s) = True ->
                            ltim_2_4_2__run_timed pg lcdb_3_2_1__no_ttl [Nothing] (S (S k)) (ltac_5_1__due_timed s d c' p w)
                              = (ltac_4_2__idle_timed s d c' w [], Quiescent, [(0, [ltac_3_2__capture_timer p], True)])
ltac_4_2__run_fires_timed pg k s d c' p w due =
  iret_11_4__trace_by_cons (ltim_2_5_4__fire_timed pg lcdb_3_2_1__no_ttl [Nothing]) (S k) (ltac_5_1__due_timed s d c' p w) (ltac_4_2__idle_timed s d c' w [])
    (0, [ltac_3_2__capture_timer p], True) (ltac_4_2__idle_timed s d c' w []) Quiescent []
    (ltac_4_2__step_fires_timed pg s d c' p w due)
    (iret_11_4__trace_by_end (ltim_2_5_4__fire_timed pg lcdb_3_2_1__no_ttl [Nothing]) k (ltac_4_2__idle_timed s d c' w []) (ltac_4_2__fire_idle_timed pg s d c' w []))

--@derives [LTAC.4.2]
--@derives [IRET.11.4]
||| THE RUN FROM AN IDLE STATE fires nothing: quiescent at once, nothing
||| traced.
export
ltac_4_2__run_idle_timed : (pg : Lcyc_3_2_1__program) -> (k, s, d, c', w : Nat) -> (wm : Rarc_5_6_4__wm) ->
                           ltim_2_4_2__run_timed pg lcdb_3_2_1__no_ttl [Nothing] (S (S k)) (ltac_4_2__idle_timed s d c' w wm)
                             = (ltac_4_2__idle_timed s d c' w wm, Quiescent, [])
ltac_4_2__run_idle_timed pg k s d c' w wm =
  iret_11_4__trace_by_end (ltim_2_5_4__fire_timed pg lcdb_3_2_1__no_ttl [Nothing]) (S k) (ltac_4_2__idle_timed s d c' w wm) (ltac_4_2__fire_idle_timed pg s d c' w wm)

--@derives [LTAC.5.1]
--@derives [LTAC.4.2]
--@derives [IRET.19.5]
||| THE RUN FROM THE RE-TIMED STATE, over the four readings of the gate:
||| fires once when the re-time made the edge and takes the timer, fires
||| nothing otherwise; the gate open before and shut after is no reading,
||| the gate being rising.
export
ltac_5_1__born_run_timed : (pg : Lcyc_3_2_1__program) -> (k, s, d, c, t, p, w : Nat) ->
                           ltim_2_4_2__run_timed pg lcdb_3_2_1__no_ttl [Nothing] (S (S k))
                             (MkSampled (MkClockedNet (MkTmsNet (MkEngine (ltac_3_4__wm_timed s d c p)
                                                                   (ltac_3_4__net_timed s d (rarc_5_6_3__next_clock c t) (ltac_3_4__wm_timed s d c p)
                                                                      (ltac_3_4__born_timed s d c (rarc_5_6_3__next_clock c t) p))) []) [] (rarc_5_6_3__next_clock c t)) w [(0, s)], [])
                             = (ltac_3_4__state_timed s d (rarc_5_6_3__next_clock c t) p w, Quiescent, ltac_5_1__firings_if (ltim_2_5_1__edge_at (lexp_9_5_1__dwell_gate_b s d) c t) p)
ltac_5_1__born_run_timed pg k s d c t p w with (lte d (minus c s)) proof pc
  ltac_5_1__born_run_timed pg k s d c t p w | True with (lte d (minus (rarc_5_6_3__next_clock c t) s)) proof pc'
    ltac_5_1__born_run_timed pg k s d c t p w | True | True = ltac_4_2__run_idle_timed pg k s d (rarc_5_6_3__next_clock c t) w []
    ltac_5_1__born_run_timed pg k s d c t p w | True | False =
      absurd (trans (sym pc') (lexp_9_5_1__dwell_gate_rising s d c (rarc_5_6_3__next_clock c t) (rarc_5_6_3__next_clock_lte c t) pc))
  ltac_5_1__born_run_timed pg k s d c t p w | False with (lte d (minus (rarc_5_6_3__next_clock c t) s)) proof pc'
    ltac_5_1__born_run_timed pg k s d c t p w | False | True = ltac_4_2__run_fires_timed pg k s d (rarc_5_6_3__next_clock c t) p w pc'
    ltac_5_1__born_run_timed pg k s d c t p w | False | False = ltac_4_2__run_idle_timed pg k s d (rarc_5_6_3__next_clock c t) w [ltac_3_2__capture_timer p]

--@derives [LTIM.2.8.4]
--@derives [RARC.5.6.3]
--@derives [LTAC.5.1]
||| THE TICK ON THE QUIESCENT STATE moves the clock alone: no deadline, no
||| row, so the sweep expires nothing and the cascade touches nothing; the
||| wall, the stamps and the trackers stand ([LTIM.2.8.6]: a tick stamps
||| nothing).
export
ltac_5_1__tick_literal_timed : (pg : Lcyc_3_2_1__program) -> (s, d, c, t, p, w : Nat) ->
                               ltim_2_8_4__tick_timed pg lcdb_3_2_1__no_ttl t (ltac_3_4__state_timed s d c p w)
                                 = (MkSampled (MkClockedNet (MkTmsNet (MkEngine (ltac_3_4__wm_timed s d c p) (ltac_3_4__net_timed s d c (ltac_3_4__wm_timed s d c p) [])) []) [] (rarc_5_6_3__next_clock c t)) w [(0, s)], [])
ltac_5_1__tick_literal_timed pg s d c t p w =
  cong (\n => (MkSampled n w [(0, s)], []))
       (ldet_5_8__quiet_tick_net pg lcdb_3_2_1__no_ttl t (ltac_3_4__wm_timed s d c p) (ltac_3_4__net_timed s d c (ltac_3_4__wm_timed s d c p) []) [] [] c Refl Refl)

--@spec [LTAC.5.1]
--@spec [IRET.19.5]
--@spec [LTIM.2.4.2]
||| A CYCLE on the Idris model's engine: a tick, then a pump -- the re-time at
||| the held sample over the stamps, then the gated stamped run
||| ([IRET.19.5]; [LTIM.2.4.2]'s "every engine tick (each pump)"). The
||| cadence every temporal fixture drives.
public export
ltac_5_1__cycle : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) -> Nat -> Nat ->
                  Ltim_2_4_1__timed_state -> (Ltim_2_4_1__timed_state, Iret_11_4__halt, List (Nat, Iret_7_1__token, Bool))
ltac_5_1__cycle pg ttl cools tests fuel t s = ltim_2_4_2__pump_timed pg ttl cools tests fuel (ltim_2_8_4__tick_timed pg ttl t s)

--@derives [LTAC.5.1]
--@derives [LTAC.4.2]
--@derives [LTAC.3.4]
--@derives [IRET.19.5]
--@derives [RARC.5.6.3]
--@derives [LTIM.2.4.3]
||| ONE CYCLE OF ONE TIMER ON THE IDRIS MODEL'S ENGINE: from the quiescent state
||| at a clock, a tick then a pump fire the gate's edge -- once, with the
||| timer's retraction, when the sample reaches the stamp plus the duration;
||| nothing otherwise -- and leave the quiescent state at the new clock,
||| the wall, the stamps and the trackers standing. The tick is the clock's
||| move alone; the re-time at entry is the re-time alone and makes the
||| born activation; the run is one firing or none.
export
ltac_5_1__timer_cycle : (pg : Lcyc_3_2_1__program) -> (k, s, d, c, t, p, w : Nat) ->
                        ltac_5_1__cycle pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped d) (S (S k)) t (ltac_3_4__state_timed s d c p w)
                          = (ltac_3_4__state_timed s d (rarc_5_6_3__next_clock c t) p w, Quiescent, ltac_5_1__firings_if (ltim_2_5_1__edge_at (lexp_9_5_1__dwell_gate_b s d) c t) p)
ltac_5_1__timer_cycle pg k s d c t p w =
  replace {p = \x => ltim_2_4_2__pump_timed pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped d) (S (S k)) x
                       = (ltac_3_4__state_timed s d (rarc_5_6_3__next_clock c t) p w, Quiescent, ltac_5_1__firings_if (ltim_2_5_1__edge_at (lexp_9_5_1__dwell_gate_b s d) c t) p)}
          (sym (ltac_5_1__tick_literal_timed pg s d c t p w))
          (replace {p = \y => ltim_2_4_2__run_timed pg lcdb_3_2_1__no_ttl [Nothing] (S (S k)) (y, [])
                                = (ltac_3_4__state_timed s d (rarc_5_6_3__next_clock c t) p w, Quiescent, ltac_5_1__firings_if (ltim_2_5_1__edge_at (lexp_9_5_1__dwell_gate_b s d) c t) p)}
                   (sym (ltac_3_4__retime_literal_timed pg s d c (rarc_5_6_3__next_clock c t) p w))
                   (ltac_5_1__born_run_timed pg k s d c t p w))

-- ---------------------------------------------------------------------
-- Over a history: the cycles, and the counts are the edges
-- ---------------------------------------------------------------------

--@spec [LTAC.5.1]
--@spec [IRET.19.5]
--@spec [LFST.9.2.1]
||| THE CYCLES OF A TICK HISTORY on the Idris model's engine: each tick followed
||| by a pump, the state after, and the number of firings of each pump.
public export
ltac_5_1__cycles : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) -> Nat -> List Nat ->
                   Ltim_2_4_1__timed_state -> (Ltim_2_4_1__timed_state, List Nat)
ltac_5_1__cycles pg ttl cools tests fuel [] s = (s, [])
ltac_5_1__cycles pg ttl cools tests fuel (t :: ts) s =
  let r = ltac_5_1__cycle pg ttl cools tests fuel t s
      rest = ltac_5_1__cycles pg ttl cools tests fuel ts (fst r)
  in (fst rest, length (snd (snd r)) :: snd rest)

--@spec [LTAC.5.1]
||| The counts of a tick history: one per pump.
public export
ltac_5_1__counts_timed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) -> Nat -> List Nat ->
                         Ltim_2_4_1__timed_state -> List Nat
ltac_5_1__counts_timed pg ttl cools tests fuel ticks s = snd (ltac_5_1__cycles pg ttl cools tests fuel ticks s)

--@spec [LTAC.5.1]
||| The state after a tick history.
public export
ltac_5_1__after_timed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) -> Nat -> List Nat ->
                        Ltim_2_4_1__timed_state -> Ltim_2_4_1__timed_state
ltac_5_1__after_timed pg ttl cools tests fuel ticks s = fst (ltac_5_1__cycles pg ttl cools tests fuel ticks s)

--@derives [LTAC.5.1]
--@derives [IRET.19.5]
||| One cycle of a history, unfolded: the cycles of the rest from the state
||| the cycle left, with the cycle's count in front.
export
ltac_5_1__cycles_cons : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (tests : List (Maybe Ltim_2_4_1__ttest)) ->
                        (fuel, t : Nat) -> (ts : List Nat) -> (s, s' : Ltim_2_4_1__timed_state) -> (h : Iret_11_4__halt) -> (tr : List (Nat, Iret_7_1__token, Bool)) ->
                        ltac_5_1__cycle pg ttl cools tests fuel t s = (s', h, tr) ->
                        ltac_5_1__cycles pg ttl cools tests fuel (t :: ts) s
                          = (fst (ltac_5_1__cycles pg ttl cools tests fuel ts s'), length tr :: snd (ltac_5_1__cycles pg ttl cools tests fuel ts s'))
ltac_5_1__cycles_cons pg ttl cools tests fuel t ts s s' h tr eq with (ltac_5_1__cycle pg ttl cools tests fuel t s)
  ltac_5_1__cycles_cons pg ttl cools tests fuel t ts s s' h tr eq | (s2, h2, tr2) =
    rewrite cong fst eq in rewrite cong (\z => snd (snd z)) eq in Refl

--@spec [LTAC.5.1]
--@spec [RARC.5.6.1]
||| THE STEPS OF A TICK HISTORY as a fixture drives them: each tick then a
||| pump under its fuel.
public export
ltac_5_1__cycle_steps : Nat -> List Nat -> List Rarc_5_6_2__step
ltac_5_1__cycle_steps fuel [] = []
ltac_5_1__cycle_steps fuel (t :: ts) = SInput (Tick t) :: SPumpT fuel :: ltac_5_1__cycle_steps fuel ts

--@derives [LCDB.3.2.1]
||| A trace's verdicts are as many as its firings.
export
lcdb_3_2_1__verdicts_length : (tr : List (Nat, Iret_7_1__token, Bool)) -> length (lcdb_3_2_1__verdicts tr) = length tr
lcdb_3_2_1__verdicts_length [] = Refl
lcdb_3_2_1__verdicts_length ((r, fs, ok) :: tr) = cong S (lcdb_3_2_1__verdicts_length tr)

--@derives [LTAC.5.1]
--@derives [RARC.5.6.1]
||| THE CYCLES ARE THE STEPS: Rete/NetworkTimed.idr's run of a history's
||| steps -- what the witnesses and the runner compute -- reaches the
||| cycles' state, and its verdict lists are as long as the cycles' counts.
||| By induction on the ticks, the pump's result and the recursive call's
||| each matched to its tuple (the guide's "two loops of one shape").
export
ltac_5_1__cycles_are_the_steps : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (tests : List (Maybe Ltim_2_4_1__ttest)) ->
                                 (fuel : Nat) -> (ticks : List Nat) -> (s : Ltim_2_4_1__timed_state) ->
                                 ( fst (ltim_2_4_1__run_steps_timed pg ttl cools tests (ltac_5_1__cycle_steps fuel ticks) s) = fst (ltac_5_1__cycles pg ttl cools tests fuel ticks s)
                                 , map length (snd (ltim_2_4_1__run_steps_timed pg ttl cools tests (ltac_5_1__cycle_steps fuel ticks) s)) = snd (ltac_5_1__cycles pg ttl cools tests fuel ticks s) )
ltac_5_1__cycles_are_the_steps pg ttl cools tests fuel [] s = (Refl, Refl)
ltac_5_1__cycles_are_the_steps pg ttl cools tests fuel (t :: ts) s with (ltac_5_1__cycle pg ttl cools tests fuel t s)
  ltac_5_1__cycles_are_the_steps pg ttl cools tests fuel (t :: ts) s | (s', h, tr)
    with (ltim_2_4_1__run_steps_timed pg ttl cools tests (ltac_5_1__cycle_steps fuel ts) s') proof rr
    ltac_5_1__cycles_are_the_steps pg ttl cools tests fuel (t :: ts) s | (s', h, tr) | (s'', vs) =
      let (ihS, ihC) = ltac_5_1__cycles_are_the_steps pg ttl cools tests fuel ts s'
      in ( trans (sym (cong fst rr)) ihS
         , cong2 (::) (lcdb_3_2_1__verdicts_length tr) (trans (sym (cong (map length . snd) rr)) ihC) )

--@derives [LTAC.5.1]
--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| THE COUNTS ARE THE EDGES on the Idris model's engine: over any tick history
||| from any starting clock, the follow-up's firings per pump are the rising
||| edges of the timer's `dwell` gate. Rete/NetworkEdges.idr's B2 for the
||| timer chain, whose RHS retracts what it matched, on the engine the
||| Idris model runs.
export
ltac_5_1__timer_counts_are_edges_timed : (pg : Lcyc_3_2_1__program) -> (k, s, d, c, p, w : Nat) -> (ticks : List Nat) ->
                                         ltac_5_1__counts_timed pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped d) (S (S k)) ticks (ltac_3_4__state_timed s d c p w)
                                           = Ltim_2_5_1__edges (lexp_9_5_1__dwell_gate_b s d) c ticks
ltac_5_1__timer_counts_are_edges_timed pg k s d c p w [] = Refl
ltac_5_1__timer_counts_are_edges_timed pg k s d c p w (t :: ts) =
  trans (cong snd (ltac_5_1__cycles_cons pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped d) (S (S k)) t ts
                     (ltac_3_4__state_timed s d c p w) (ltac_3_4__state_timed s d (rarc_5_6_3__next_clock c t) p w) Quiescent
                     (ltac_5_1__firings_if (ltim_2_5_1__edge_at (lexp_9_5_1__dwell_gate_b s d) c t) p) (ltac_5_1__timer_cycle pg k s d c t p w)))
        (cong2 (::) (ltac_5_1__firings_if_length (lexp_9_5_1__dwell_gate_b s d) c t p)
                    (ltac_5_1__timer_counts_are_edges_timed pg k s d (rarc_5_6_3__next_clock c t) p w ts))

--@derives [LTAC.4.2]
--@derives [LTAC.5.1]
||| THE STATE AFTER A TICK HISTORY IS THE QUIESCENT STATE AT ITS CLOCK, the
||| wall and the stamps standing: the cycles land on `state_timed` at the
||| clock the ticks reach.
export
ltac_4_2__after_cycles_is_state_timed : (pg : Lcyc_3_2_1__program) -> (k, s, d, c, p, w : Nat) -> (ticks : List Nat) ->
                                        ltac_5_1__after_timed pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped d) (S (S k)) ticks (ltac_3_4__state_timed s d c p w)
                                          = ltac_3_4__state_timed s d (ltac_5_1__clock_after c ticks) p w
ltac_4_2__after_cycles_is_state_timed pg k s d c p w [] = Refl
ltac_4_2__after_cycles_is_state_timed pg k s d c p w (t :: ts) =
  trans (cong fst (ltac_5_1__cycles_cons pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped d) (S (S k)) t ts
                     (ltac_3_4__state_timed s d c p w) (ltac_3_4__state_timed s d (rarc_5_6_3__next_clock c t) p w) Quiescent
                     (ltac_5_1__firings_if (ltim_2_5_1__edge_at (lexp_9_5_1__dwell_gate_b s d) c t) p) (ltac_5_1__timer_cycle pg k s d c t p w)))
        (ltac_4_2__after_cycles_is_state_timed pg k s d (rarc_5_6_3__next_clock c t) p w ts)

-- ---------------------------------------------------------------------
-- THE THEOREMS on the Idris model's engine [LTAC.5.1], [LTAC.5.3], [LTAC.4.2]
-- ---------------------------------------------------------------------

--@derives [LTAC.4.2]
--@derives [LTAC.5.1]
--@derives [LTIM.2.5.1]
||| AT MOST ONCE: over any tick history from any starting clock the
||| follow-up fires at most once -- the `dwell` gate is rising
||| (Rete/NetworkTwoClocks.idr: the clock never goes back, the stamp stays)
||| and C3a bounds a rising gate's edges by one.
export
ltac_5_1__at_most_once_timed : (pg : Lcyc_3_2_1__program) -> (k, s, d, c, p, w : Nat) -> (ticks : List Nat) ->
                               LTE (ltim_2_5_1__total (ltac_5_1__counts_timed pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped d) (S (S k)) ticks (ltac_3_4__state_timed s d c p w))) 1
ltac_5_1__at_most_once_timed pg k s d c p w ticks =
  replace {p = \l => LTE (ltim_2_5_1__total l) 1} (sym (ltac_5_1__timer_counts_are_edges_timed pg k s d c p w ticks))
          (ltim_2_5_1__rising_edges_at_most_one (lexp_9_5_1__dwell_gate_b s d) (lexp_9_5_1__dwell_gate_rising s d) c ticks)

--@derives [LTAC.5.1]
--@derives [LTAC.5.3]
--@derives [LTAC.3.4]
--@derives [LTIM.2.5.1]
||| THE FOLLOW-UP FIRES ON THE FIRST TICK AT OR AFTER `fire_at`, AND ON NO
||| OTHER, on the Idris model's engine: from the quiescent state at a clock below
||| the stamp plus the duration, over any tick history, the firings are
||| Rete/NetworkAfter.idr's clause counts at that `fire_at` -- 0 at every
||| tick whose sample stays below it, 1 at the first whose sample reaches
||| it, 0 at every tick after. The counts are the `dwell` gate's edges, the
||| `dwell` gate is the `fire_at` gate (the guard is the gate), and that
||| gate's edges are the clause's.
export
ltac_5_1__fires_on_the_first_due_tick_timed : (pg : Lcyc_3_2_1__program) -> (k, s, d, c, p, w : Nat) -> (ticks : List Nat) ->
                                              lexp_9_5_1__dwell_gate_b s (S d) c = False ->
                                              ltac_5_1__counts_timed pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped (S d)) (S (S k)) ticks (ltac_3_4__state_timed s (S d) c p w)
                                                = ltac_5_1__due_edges (s + S d) c ticks
ltac_5_1__fires_on_the_first_due_tick_timed pg k s d c p w ticks nd =
  trans (ltac_5_1__timer_counts_are_edges_timed pg k s (S d) c p w ticks)
        (trans (ltim_2_5_1__edges_ext (lexp_9_5_1__dwell_gate_b s (S d)) (ltac_3_4__due_b (s + S d)) (\x => ltac_3_4__guard_is_due s d x) c ticks)
               (ltac_5_1__edges_are_first_due (s + S d) c ticks (trans (sym (ltac_3_4__guard_is_due s d c)) nd)))

--@derives [LTAC.5.3]
--@derives [LTAC.5.1]
--@derives [LTAC.4.2]
--@derives [LTAC.4.4]
||| NEVER LOST, on the Idris model's engine: over any tick history from a clock
||| below the stamp plus the duration, the follow-up has fired exactly once
||| when the history's final clock has reached it, whatever ticks were
||| missed on the way, and not at all when it has not -- "regardless of how
||| long the engine has been running" ([LTAC.4.4]): the timer has no TTL
||| beyond its one shot, and no length of history loses it.
export
ltac_5_3__never_lost_timed : (pg : Lcyc_3_2_1__program) -> (k, s, d, c, p, w : Nat) -> (ticks : List Nat) ->
                             lexp_9_5_1__dwell_gate_b s (S d) c = False ->
                             ltim_2_5_1__total (ltac_5_1__counts_timed pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped (S d)) (S (S k)) ticks (ltac_3_4__state_timed s (S d) c p w))
                               = ltac_5_3__once_if (ltac_3_4__due_b (s + S d) (ltac_5_1__clock_after c ticks))
ltac_5_3__never_lost_timed pg k s d c p w ticks nd =
  trans (cong ltim_2_5_1__total (ltac_5_1__fires_on_the_first_due_tick_timed pg k s d c p w ticks nd))
        (ltac_5_1__due_edges_total (s + S d) c ticks (trans (sym (ltac_3_4__guard_is_due s d c)) nd))

--@derives [LTAC.4.2]
--@derives [LTAC.3.4]
||| ONE-SHOT, on the Idris model's engine: once a history's clock has reached the
||| stamp plus the duration, the timer is not in working memory -- the
||| follow-up's retraction took it, and the state holds nothing for a later
||| tick to re-fire.
export
ltac_4_2__gone_once_due_timed : (pg : Lcyc_3_2_1__program) -> (k, s, d, c, p, w : Nat) -> (ticks : List Nat) ->
                                lexp_9_5_1__dwell_gate_b s d (ltac_5_1__clock_after c ticks) = True ->
                                ewm (ncore (nengine (ltim_2_4_1__net_of (ltac_5_1__after_timed pg lcdb_3_2_1__no_ttl [Nothing] (ltac_3_4__tests_stamped d) (S (S k)) ticks (ltac_3_4__state_timed s d c p w))))) = []
ltac_4_2__gone_once_due_timed pg k s d c p w ticks due =
  rewrite ltac_4_2__after_cycles_is_state_timed pg k s d c p w ticks in rewrite due in Refl

-- ---------------------------------------------------------------------
-- The captures ride on the timer [LTAC.3.5], [LCCO.5.4]
-- ---------------------------------------------------------------------

--@spec [LTAC.3.5]
||| THE CAPTURES of a body: the parent's slot reads, each by (binding,
||| key-or-payload, slot) over the parent's positive patterns, in the order
||| the body first reads them; a read's index in the list is the timer's
||| payload slot the lowering rewrites it to.
public export
Ltac_3_5__captures : Type
Ltac_3_5__captures = List (Nat, Bool, Nat)

--@spec [LTAC.3.5]
||| A read's index among the captures, or none.
public export
ltac_3_5__index : Ltac_3_5__captures -> (Nat, Bool, Nat) -> Maybe Nat
ltac_3_5__index [] r = Nothing
ltac_3_5__index (c :: cs) r = if c == r then Just 0 else map S (ltac_3_5__index cs r)

--@spec [LTAC.3.5]
--@spec [LCCO.5.4]
||| THE REWRITE of a body expression: every captured read becomes the
||| timer's payload slot at the capture's index -- the timer is the
||| follow-up's one bound fact, at rank 0 -- and the rest of the expression
||| stands. A read the captures do not hold is left as it is; the lowering
||| refuses such a body (`after:capture`).
public export
ltac_3_5__rewrite : Ltac_3_5__captures -> Iret_7_5__expr -> Iret_7_5__expr
ltac_3_5__rewrite caps (ELit v)         = ELit v
ltac_3_5__rewrite caps (ESlot b k s)    = case ltac_3_5__index caps (b, k, s) of
  Just i  => ESlot 0 False i
  Nothing => ESlot b k s
ltac_3_5__rewrite caps (EClock r)       = EClock r
ltac_3_5__rewrite caps (ECmp op l r)    = ECmp op (ltac_3_5__rewrite caps l) (ltac_3_5__rewrite caps r)
ltac_3_5__rewrite caps (EArith op l r)  = EArith op (ltac_3_5__rewrite caps l) (ltac_3_5__rewrite caps r)
ltac_3_5__rewrite caps (ENeg e)         = ENeg (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (EAnd l r)       = EAnd (ltac_3_5__rewrite caps l) (ltac_3_5__rewrite caps r)
ltac_3_5__rewrite caps (EOr l r)        = EOr (ltac_3_5__rewrite caps l) (ltac_3_5__rewrite caps r)
ltac_3_5__rewrite caps (ENot e)         = ENot (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (EIs neg s e)    = EIs neg s (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (ECoalesce x d)  = ECoalesce (ltac_3_5__rewrite caps x) (ltac_3_5__rewrite caps d)
ltac_3_5__rewrite caps (ECast f t e)    = ECast f t (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (EPath segs e)   = EPath segs (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (EHas segs e)    = EHas segs (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (ELen e)         = ELen (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (ELenStr e)      = ELenStr (ltac_3_5__rewrite caps e)

--@spec [LTAC.3.5]
--@spec [LTAC.3.6]
||| WHETHER A BODY EXPRESSION IS CAPTURED WHOLE: every read it makes is
||| among the captures, and it reads no clock (the lowering refuses a clock
||| read in a body: the runner has no sample at an action). A body reading
||| nothing is captured by the empty list ([LTAC.3.6]).
public export
ltac_3_5__captured : Ltac_3_5__captures -> Iret_7_5__expr -> Bool
ltac_3_5__captured caps (ELit v)         = True
ltac_3_5__captured caps (ESlot b k s)    = isJust (ltac_3_5__index caps (b, k, s))
ltac_3_5__captured caps (EClock r)       = False
ltac_3_5__captured caps (ECmp op l r)    = ltac_3_5__captured caps l && ltac_3_5__captured caps r
ltac_3_5__captured caps (EArith op l r)  = ltac_3_5__captured caps l && ltac_3_5__captured caps r
ltac_3_5__captured caps (ENeg e)         = ltac_3_5__captured caps e
ltac_3_5__captured caps (EAnd l r)       = ltac_3_5__captured caps l && ltac_3_5__captured caps r
ltac_3_5__captured caps (EOr l r)        = ltac_3_5__captured caps l && ltac_3_5__captured caps r
ltac_3_5__captured caps (ENot e)         = ltac_3_5__captured caps e
ltac_3_5__captured caps (EIs neg s e)    = ltac_3_5__captured caps e
ltac_3_5__captured caps (ECoalesce x d)  = ltac_3_5__captured caps x && ltac_3_5__captured caps d
ltac_3_5__captured caps (ECast f t e)    = ltac_3_5__captured caps e
ltac_3_5__captured caps (EPath segs e)   = ltac_3_5__captured caps e
ltac_3_5__captured caps (EHas segs e)    = ltac_3_5__captured caps e
ltac_3_5__captured caps (ELen e)         = ltac_3_5__captured caps e
ltac_3_5__captured caps (ELenStr e)      = ltac_3_5__captured caps e

--@spec [LTAC.3.5]
--@spec [LCCO.5.4]
||| THE SNAPSHOT HYPOTHESIS: the timer's payload slot at each capture's
||| index reads, under the follow-up's environment over the timer, what the
||| parent's read gave under the parent's environment over its match. What
||| the parent's `emitx` computes at its firing and codes, and the runner
||| decodes at the follow-up's: the value code's round trip, run and not
||| proved as every code is.
public export
Ltac_3_5__snapshot : Iret_7_6__env -> Iret_7_6__env -> List Lfac_1_7_1__fact -> List Lfac_1_7_1__fact -> Ltac_3_5__captures -> Type
Ltac_3_5__snapshot env env' timer tok caps =
  (b : Nat) -> (k : Bool) -> (s, i : Nat) -> ltac_3_5__index caps (b, k, s) = Just i ->
  iret_7_6__slot env timer 0 False i = iret_7_6__slot env' tok b k s

--@derives [LTAC.3.5]
--@derives [LCCO.5.4]
--@derives [LTAC.6.2.1]
||| THE SNAPSHOT: for every body expression captured whole, its value over
||| the timer at the follow-up's firing is its value over the parent's match
||| at the parent's firing, under the snapshot hypothesis -- "capture is
||| snapshot-always" ([LCCO.5.4]), and the body's actions have their own
||| semantics unchanged ([LTAC.6.2.1]). By induction on the expression,
||| through Rete/Eval.idr's evaluator, every constructor a clause.
export
ltac_3_5__capture_snapshot : (env, env' : Iret_7_6__env) -> (timer, tok : List Lfac_1_7_1__fact) -> (caps : Ltac_3_5__captures) ->
                             Ltac_3_5__snapshot env env' timer tok caps -> (e : Iret_7_5__expr) -> ltac_3_5__captured caps e = True ->
                             iret_7_6__eval env timer (ltac_3_5__rewrite caps e) = iret_7_6__eval env' tok e
ltac_3_5__capture_snapshot env env' timer tok caps snap (ELit v) h = Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ESlot b k s) h with (ltac_3_5__index caps (b, k, s)) proof pi
  ltac_3_5__capture_snapshot env env' timer tok caps snap (ESlot b k s) h | (Just i) = snap b k s i pi
  ltac_3_5__capture_snapshot env env' timer tok caps snap (ESlot b k s) h | Nothing = absurd h
ltac_3_5__capture_snapshot env env' timer tok caps snap (EClock r) h = absurd h
ltac_3_5__capture_snapshot env env' timer tok caps snap (ECmp op l r) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap l (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap r (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EArith op l r) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap l (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap r (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ENeg e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EAnd l r) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap l (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap r (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EOr l r) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap l (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap r (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ENot e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EIs neg s e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ECoalesce x d) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap x (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap d (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ECast f t e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EPath segs e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EHas segs e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ELen e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ELenStr e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl

-- ---------------------------------------------------------------------
-- Executed: the fixtures' shapes on this engine, through the lowering
-- ---------------------------------------------------------------------

--@spec [LTAC.4.2]
||| THE LIFECYCLES of the one-timer fixtures: the trigger (kind 0) an
||| entity, every other kind -- the timer, a body's `ttl` fact -- explicit.
public export
ltac_4_2__life : Nat -> Lscp_1_3__lifecycle
ltac_4_2__life Z = Entity
ltac_4_2__life (S _) = Explicit

--@spec [LTAC.4.2]
||| Two alphas: the trigger's kind 0 and the timer's kind 1.
public export
ltac_4_2__alphas_two : List (Nat, Lfac_1_7_1__fact -> Bool)
ltac_4_2__alphas_two = [(0, lcdb_3_2_1__admits_all), (1, lcdb_3_2_1__admits_all)]

--@spec [LTAC.3.6]
||| THE EMPTY CAPTURE: a body that reads nothing; the timer's key and
||| payload both the empty tuple's code.
public export
ltac_3_6__no_capture : List Lfac_1_7_1__fact -> (Nat, Nat)
ltac_3_6__no_capture _ = (1, 1)

--@spec [LTAC.4.2]
--@spec [LTAC.3.1]
||| THE ONE-SHOT PROGRAM, lowered: `auto_off` on the trigger with `after 5:
||| <nothing>` -- the parent emitting the timer (kind 1), and the follow-up
||| `$auto_off_after_0` on it (logical/LTAC.4.2's shape, the log aside).
public export
ltac_4_2__rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltac_4_2__rules = ltac_3_1__lower ltim_2_4_1__wenv ([(0, lcdb_3_2_1__any_join, False)], []) [(1, 5, ltac_3_6__no_capture, [])]

--@spec [LTAC.4.2]
||| Its tests: the parent untimed, the follow-up's guard.
public export
ltac_4_2__tests : List (Maybe Ltim_2_4_1__ttest)
ltac_4_2__tests = ltac_3_1__lower_tests ltim_2_4_1__wenv Nothing [(1, 5, ltac_3_6__no_capture, [])]

--@spec [LTAC.4.2]
||| The verdicts of a schedule on a lowered one-timer program, from the
||| loaded network.
public export
ltac_4_2__verdicts_of : (Nat -> Lscp_1_3__lifecycle) -> Iret_4_2__ttl -> List (Nat, Lfac_1_7_1__fact -> Bool) ->
                        List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List (Maybe Ltim_2_4_1__ttest) ->
                        List Rarc_5_6_2__step -> List (List (Nat, Bool))
ltac_4_2__verdicts_of life ttl alphas rules tests steps = ltim_2_4_1__verdicts_of life ttl alphas rules [Nothing, Nothing] tests steps

--@spec [LTAC.4.2]
||| The working memory after a schedule on a lowered one-timer program.
public export
ltac_4_2__wm_after : (Nat -> Lscp_1_3__lifecycle) -> Iret_4_2__ttl -> List (Nat, Lfac_1_7_1__fact -> Bool) ->
                     List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List (Maybe Ltim_2_4_1__ttest) ->
                     List Rarc_5_6_2__step -> Rarc_5_6_4__wm
ltac_4_2__wm_after life ttl alphas rules tests steps = ltim_2_4_1__wm_after life ttl alphas rules [Nothing, Nothing] tests steps

--@derives [LTAC.4.2]
--@derives [LTAC.5.1]
--@derives [LTAC.3.1]
||| ONE-SHOT, EXECUTED THROUGH THE LOWERING: the trigger asserted and pumped
||| at 0 fires the parent, which mints the timer; the advance to 6 and a
||| pump fire the follow-up once; the advance to 8 and a pump fire nothing
||| -- logical/LTAC.4.2's shape. And the timer is gone: working memory
||| holds the trigger alone. Executed: `[[(0, True)], [(1, True)], []]`.
export
ltac_4_2__one_shot_timed :
  ( ltac_4_2__verdicts_of ltac_4_2__life lcdb_3_2_1__no_ttl ltac_4_2__alphas_two ltac_4_2__rules ltac_4_2__tests
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 6), SPumpT 3, SInput (Tick 8), SPumpT 3]
      = [[(0, True)], [(1, True)], []]
  , ltac_4_2__wm_after ltac_4_2__life lcdb_3_2_1__no_ttl ltac_4_2__alphas_two ltac_4_2__rules ltac_4_2__tests
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 6), SPumpT 3, SInput (Tick 8), SPumpT 3]
      = [MkFact 0 0 1 0] )
ltac_4_2__one_shot_timed = (Refl, Refl)

--@derives [LTAC.9.1]
--@derives [LTAC.5.1]
||| NOTHING BEFORE THE DELAY: the same program, the advance to 3 and a pump
||| fire nothing, and the timer is live beside the trigger --
||| temporal/LTAC.9.3.runtime's shape (the runner prints no timer; the
||| model holds it). Executed: `[[(0, True)], []]`.
export
ltac_9_1__nothing_before_the_delay_timed :
  ( ltac_4_2__verdicts_of ltac_4_2__life lcdb_3_2_1__no_ttl ltac_4_2__alphas_two ltac_4_2__rules ltac_4_2__tests
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 3), SPumpT 3]
      = [[(0, True)], []]
  , ltac_4_2__wm_after ltac_4_2__life lcdb_3_2_1__no_ttl ltac_4_2__alphas_two ltac_4_2__rules ltac_4_2__tests
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 3), SPumpT 3]
      = [MkFact 0 0 1 0, MkFact 1 1 1 1] )
ltac_9_1__nothing_before_the_delay_timed = (Refl, Refl)

--@spec [LTAC.3.3]
||| Three alphas: the trigger's kind 0, the body's `Delayed` kind 1, the
||| timer's kind 2.
public export
ltac_3_3__alphas_three : List (Nat, Lfac_1_7_1__fact -> Bool)
ltac_3_3__alphas_three = [(0, lcdb_3_2_1__admits_all), (1, lcdb_3_2_1__admits_all), (2, lcdb_3_2_1__admits_all)]

--@spec [LTAC.3.3]
--@spec [LTAC.6.2.1]
||| THE DELAYED-EMIT PROGRAM, lowered: `delayed` on the trigger with `after
||| 5: emit Delayed` -- the parent emitting the timer (kind 2), and the
||| follow-up emitting the `Delayed` (kind 1) then retracting the timer
||| (temporal/LTAC.3.1.runtime's and logical/LTAC.3.3's shape).
public export
ltac_3_3__rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltac_3_3__rules = ltac_3_1__lower ltim_2_4_1__wenv ([(0, lcdb_3_2_1__any_join, False)], []) [(2, 5, ltac_3_6__no_capture, [Emit 1 ltac_3_6__no_capture])]

--@spec [LTAC.3.3]
public export
ltac_3_3__tests : List (Maybe Ltim_2_4_1__ttest)
ltac_3_3__tests = ltac_3_1__lower_tests ltim_2_4_1__wenv Nothing [(2, 5, ltac_3_6__no_capture, [Emit 1 ltac_3_6__no_capture])]

--@derives [LTAC.3.1]
--@derives [LTAC.6.2.1]
--@derives [LTAC.4.2]
||| THE BODY RUNS WHEN THE FOLLOW-UP FIRES: the trigger pumped at 0 arms
||| the timer; the advance to 6 and a pump fire the follow-up, which mints
||| the `Delayed` and takes the timer -- temporal/LTAC.3.1.runtime's shape.
||| Executed: `[[(0, True)], [(1, True)]]`, and working memory holds the
||| trigger and the `Delayed`.
export
ltac_3_1__body_runs_timed :
  ( ltac_4_2__verdicts_of ltac_4_2__life lcdb_3_2_1__no_ttl ltac_3_3__alphas_three ltac_3_3__rules ltac_3_3__tests
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 6), SPumpT 3]
      = [[(0, True)], [(1, True)]]
  , ltac_4_2__wm_after ltac_4_2__life lcdb_3_2_1__no_ttl ltac_3_3__alphas_three ltac_3_3__rules ltac_3_3__tests
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 6), SPumpT 3]
      = [MkFact 0 0 1 0, MkFact 2 1 1 1] )
ltac_3_1__body_runs_timed = (Refl, Refl)

--@derives [LTAC.3.3]
--@derives [LTAC.9.1]
||| THE TIMER SURVIVES ITS PARENT'S RETRACTION: the trigger pumped at 0 arms
||| the timer; the trigger is retracted; the advance to 6 and a pump still
||| fire the follow-up and mint the `Delayed` -- the timer is asserted
||| plainly, with no justification (cancellation is only by an
||| `as` key, [LTAC.9.1]) -- logical/LTAC.3.3_after_survives_parent_retract's
||| shape. Executed: `[[(0, True)], [(1, True)]]`, and working memory holds
||| the `Delayed` alone.
export
ltac_3_3__survives_parent_retract_timed :
  ( ltac_4_2__verdicts_of ltac_4_2__life lcdb_3_2_1__no_ttl ltac_3_3__alphas_three ltac_3_3__rules ltac_3_3__tests
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Retract 0)), SInput (Tick 6), SPumpT 3]
      = [[(0, True)], [(1, True)]]
  , ltac_4_2__wm_after ltac_4_2__life lcdb_3_2_1__no_ttl ltac_3_3__alphas_three ltac_3_3__rules ltac_3_3__tests
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Retract 0)), SInput (Tick 6), SPumpT 3]
      = [MkFact 0 1 1 1] )
ltac_3_3__survives_parent_retract_timed = (Refl, Refl)

--@spec [LTAC.3.5]
--@spec [LTAC.4.3]
||| THE CAPTURE OF THE TRIGGER'S KEY: the body reads `t.entity_id`, so the
||| timer's payload is the trigger's key, snapshot at the parent's firing.
public export
ltac_3_5__capture_key : List Lfac_1_7_1__fact -> (Nat, Nat)
ltac_3_5__capture_key fs = (1, lcdb_3_3_1__key_of_head fs)

--@spec [LTAC.4.3]
--@spec [LTAC.3.5]
||| THE INDEPENDENT-TIMERS PROGRAM, lowered: `notify` on the trigger with
||| `after 3: log "{t.entity_id}"` -- the parent emitting the timer with the
||| key captured (kind 1), and the follow-up on it (logical/LTAC.4.3's and
||| LTAC.5.4_same_tick_order's shape, the log aside).
public export
ltac_4_3__rules_timed : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltac_4_3__rules_timed = ltac_3_1__lower ltim_2_4_1__wenv ([(0, lcdb_3_2_1__any_join, False)], []) [(1, 3, ltac_3_5__capture_key, [])]

--@spec [LTAC.4.3]
public export
ltac_4_3__tests_timed : List (Maybe Ltim_2_4_1__ttest)
ltac_4_3__tests_timed = ltac_3_1__lower_tests ltim_2_4_1__wenv Nothing [(1, 3, ltac_3_5__capture_key, [])]

--@derives [LTAC.4.3]
--@derives [LTAC.3.5]
--@derives [LTAC.5.1]
||| N TIMERS FROM N PARENT FIRINGS, EACH ON ITS OWN TICK: the trigger `a`
||| pumped at 0 arms a timer stamped 0; the advance to 2, the trigger `b`
||| and a pump arm a second, stamped 2; the advance to 3 and a pump fire the
||| first follow-up alone; the advance to 5 and a pump fire the second.
||| Each timer carries its own trigger's key. Executed: `[[(0, True)], [(0,
||| True)], [(1, True)], [(1, True)]]`, and the triggers alone remain.
export
ltac_4_3__independent_timed :
  ( ltac_4_2__verdicts_of ltac_4_2__life lcdb_3_2_1__no_ttl ltac_4_2__alphas_two ltac_4_3__rules_timed ltac_4_3__tests_timed
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 2), SInput (Data (Assert 0 2 0)), SPumpT 3, SInput (Tick 3), SPumpT 3, SInput (Tick 5), SPumpT 3]
      = [[(0, True)], [(0, True)], [(1, True)], [(1, True)]]
  , ltac_4_2__wm_after ltac_4_2__life lcdb_3_2_1__no_ttl ltac_4_2__alphas_two ltac_4_3__rules_timed ltac_4_3__tests_timed
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 2), SInput (Data (Assert 0 2 0)), SPumpT 3]
      = [MkFact 0 0 1 0, MkFact 1 1 1 1, MkFact 2 0 2 0, MkFact 3 1 1 2]
  , ltac_4_2__wm_after ltac_4_2__life lcdb_3_2_1__no_ttl ltac_4_2__alphas_two ltac_4_3__rules_timed ltac_4_3__tests_timed
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 2), SInput (Data (Assert 0 2 0)), SPumpT 3, SInput (Tick 3), SPumpT 3, SInput (Tick 5), SPumpT 3]
      = [MkFact 0 0 1 0, MkFact 2 0 2 0] )
ltac_4_3__independent_timed = (Refl, Refl, Refl)

--@spec [LTAC.5.4]
||| THE STATE TWO TRIGGERS LEAVE after one pump: both timers armed, stamped
||| 0, the first-asserted trigger's first.
public export
ltac_5_4__armed_timed : Ltim_2_4_1__timed_state
ltac_5_4__armed_timed =
  fst (ltim_2_4_1__run_steps_timed (lcyc_3_2_1__program_of ltac_4_2__life (enet (rdsc_4a_5__load ltac_4_2__alphas_two ltac_4_3__rules_timed)))
         lcdb_3_2_1__no_ttl [Nothing, Nothing] ltac_4_3__tests_timed
         [SInput (Data (Assert 0 1 0)), SInput (Data (Assert 0 2 0)), SPumpT 3]
         (ltim_2_4_1__loaded ltac_4_2__alphas_two ltac_4_3__rules_timed))

--@derives [LTAC.5.4]
--@derives [LDET.5.5]
--@derives [LTAC.4.2]
||| TWO TIMERS DUE IN ONE TICK BOTH FIRE IN IT, THE EARLIER-MINTED FIRST:
||| from the armed state the advance to 4 and a pump fire the follow-up
||| twice, the timer minted for the first trigger (id 2) before the one for
||| the second (id 3) -- [LDET.5.5]'s order on matches that complete
||| together, logical/LTAC.5.4_same_tick_order's shape -- each firing
||| retracting its own timer, and the triggers alone remain. Executed.
export
ltac_5_4__same_tick_timed :
  ( snd (snd (ltac_5_1__cycle (lcyc_3_2_1__program_of ltac_4_2__life (enet (rdsc_4a_5__load ltac_4_2__alphas_two ltac_4_3__rules_timed)))
                               lcdb_3_2_1__no_ttl [Nothing, Nothing] ltac_4_3__tests_timed 3 4 ltac_5_4__armed_timed))
      = [(1, [MkFact 2 1 1 1], True), (1, [MkFact 3 1 1 2], True)]
  , ewm (ncore (nengine (ltim_2_4_1__net_of (fst (ltac_5_1__cycle (lcyc_3_2_1__program_of ltac_4_2__life (enet (rdsc_4a_5__load ltac_4_2__alphas_two ltac_4_3__rules_timed)))
                                                                    lcdb_3_2_1__no_ttl [Nothing, Nothing] ltac_4_3__tests_timed 3 4 ltac_5_4__armed_timed)))))
      = [MkFact 0 0 1 0, MkFact 1 0 2 0] )
ltac_5_4__same_tick_timed = (Refl, Refl)

--@spec [RTIM.3.2.6]
||| THE ONE-MOVE FIXTURE'S KINDS: `Go` (0) an entity; `Short` (1), `Long`
||| (2) and `Fired` (3) explicit with a TTL; the timer (4) explicit.
public export
rtim_3_2_6__ttl : Iret_4_2__ttl
rtim_3_2_6__ttl Z = 0
rtim_3_2_6__ttl (S Z) = 2
rtim_3_2_6__ttl (S (S Z)) = 4
rtim_3_2_6__ttl (S (S (S Z))) = 100
rtim_3_2_6__ttl (S (S (S (S _)))) = 0

--@spec [RTIM.3.2.6]
||| Five alphas, kinds 0 to 4.
public export
rtim_3_2_6__alphas_five : List (Nat, Lfac_1_7_1__fact -> Bool)
rtim_3_2_6__alphas_five = [(0, lcdb_3_2_1__admits_all), (1, lcdb_3_2_1__admits_all), (2, lcdb_3_2_1__admits_all), (3, lcdb_3_2_1__admits_all), (4, lcdb_3_2_1__admits_all)]

--@spec [RTIM.3.2.6]
--@spec [LTAC.3.1]
||| `wait`, lowered: on `Go` with `after 3: emit Fired` -- the parent
||| emitting the timer (kind 4), the follow-up emitting `Fired` (kind 3)
||| then retracting the timer.
public export
rtim_3_2_6__rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
rtim_3_2_6__rules = ltac_3_1__lower ltim_2_4_1__wenv ([(0, lcdb_3_2_1__any_join, False)], []) [(4, 3, ltac_3_6__no_capture, [Emit 3 ltac_3_6__no_capture])]

--@spec [RTIM.3.2.6]
public export
rtim_3_2_6__tests : List (Maybe Ltim_2_4_1__ttest)
rtim_3_2_6__tests = ltac_3_1__lower_tests ltim_2_4_1__wenv Nothing [(4, 3, ltac_3_6__no_capture, [Emit 3 ltac_3_6__no_capture])]

--@derives [RTIM.3.2.6]
--@derives [LTAC.5.3]
--@derives [IRET.19.3]
||| ONE MOVE DOES EVERYTHING DUE: `Go`, a `Short` (TTL 2) and a `Long` (TTL
||| 4) asserted at 0 and pumped arm the timer; one advance to 5 sweeps both
||| TTL facts at the tick and the pump fires the follow-up, which mints
||| `Fired` and takes the timer -- logical/RTIM.3.2.6_one_move_does_everything_due's
||| shape, the sweep at the tick. Executed: `[[(0, True)],
||| [(1, True)]]`, and working memory holds `Go` and `Fired`.
export
rtim_3_2_6__one_move_timed :
  ( ltac_4_2__verdicts_of ltac_4_2__life rtim_3_2_6__ttl rtim_3_2_6__alphas_five rtim_3_2_6__rules rtim_3_2_6__tests
      [SInput (Data (Assert 0 1 0)), SInput (Data (Assert 1 1 0)), SInput (Data (Assert 2 1 0)), SPumpT 3, SInput (Tick 5), SPumpT 3]
      = [[(0, True)], [(1, True)]]
  , ltac_4_2__wm_after ltac_4_2__life rtim_3_2_6__ttl rtim_3_2_6__alphas_five rtim_3_2_6__rules rtim_3_2_6__tests
      [SInput (Data (Assert 0 1 0)), SInput (Data (Assert 1 1 0)), SInput (Data (Assert 2 1 0)), SPumpT 3, SInput (Tick 5), SPumpT 3]
      = [MkFact 0 0 1 0, MkFact 1 3 1 1] )
rtim_3_2_6__one_move_timed = (Refl, Refl)

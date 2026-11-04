-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| `after` TIMERS ON THE CLOCKED NETWORK: the follow-up rule of an `after`
||| clause is a timed chain whose gate reads the clock against the timer
||| fact's `fire_at` and whose RHS ends with the timer's retraction; over
||| any tick history it fires on the first tick at or after `fire_at` and
||| on no other ([LTAC.5.1]), late and never lost when a tick is missed
||| ([LTAC.5.3]), once ([LTAC.4.2]); timers are independent ([LTAC.4.3])
||| and several due on one tick all fire in it ([LTAC.5.4]). The
||| clocked-network programme's part G.
|||
||| NORMATIVE COMPANION to Rete/NetworkEdges.idr and Rete/NetworkTwoClocks.idr,
||| whose one-fact edge count and rising-gate results it stands on, and to
||| Rete/NetworkFrameRetime.idr, whose fixtures it borrows.
|||
||| WHY. [LTAC.3.2] gives the timer fact a `fire_at`, a monotonic-clock
||| reading; [LTAC.3.4] gives the follow-up rule a single positive pattern
||| on the timer schema under `monotonic_ns() >= t.fire_at`, and makes its
||| RHS end with the timer's retraction ([LTAC.4.2]). On this network that
||| is Rete/NetworkTick.idr's timed chain: one positive node whose test at
||| clock `c` admits a timer whose payload -- `fire_at` here -- is at or
||| below `c` (`ltac_3_4__due`), and whose actions are `[Withdraw 0]`
||| (`ltac_4_2__retract_timer`). The gate is RISING in the clock for a fixed
||| timer (`ltac_5_3__due_rising`): true once, true after, because the
||| composed engine's clock never goes back ([LTIM.2.8.2]). So a timer's
||| edge is at most one (Rete/NetworkTwoClocks.idr's C3a), and it is AT the
||| first tick whose sample is at or after `fire_at` -- which is what
||| `>=` against an absolute instant gives and equality against a
||| scheduled one would lose ([LTAC.5.3]).
|||
||| PROVED.
|||
|||   * THE GATE (`ltac_3_4__due`, `ltac_3_4__due_b`, `ltac_3_4__due_is_the_gate`):
|||     the follow-up's test reads the timer's `fire_at` and the clock, and
|||     for one timer it is a gate on the clock alone; the gate is rising
|||     (`ltac_5_3__due_rising`).
|||   * ONE PUMP OF ONE TIMER (`ltac_5_1__timer_pump`): from the quiescent
|||     state at a clock -- the timer live and unmatched while the clock is
|||     below `fire_at`, gone once it is not -- the pump at a tick fires the
|||     gate's edge and leaves the quiescent state at the new clock: when
|||     the edge is made, the follow-up fires once and its withdraw takes the
|||     timer with it (`ltac_4_2__step_fires`, `ltac_4_2__run_fires`).
|||   * THE COUNTS ARE THE EDGES (`ltac_5_1__timer_counts_are_edges`): over
|||     any tick history from any starting clock, the firings are the rising
|||     edges of the timer's gate, one count per pump; so at most one
|||     (`ltac_5_1__at_most_once_is_an_instance`, [LTAC.4.2]).
|||   * THE EDGE IS AT THE FIRST DUE TICK (`ltac_5_1__edges_are_first_due`,
|||     `ltac_5_1__fires_on_the_first_due_tick`): from a clock below
|||     `fire_at`, the history's counts are `ltac_5_1__due_edges`: 0 at every
|||     tick whose sample stays below `fire_at`, 1 at the first whose sample
|||     reaches it, 0 at every tick after. [LTAC.5.1].
|||   * NEVER LOST (`ltac_5_3__never_lost`, `ltac_5_3__late_edge`): the sum of
|||     the counts is 1 exactly when the history's final clock has reached
|||     `fire_at`, whatever samples were skipped; a tick that lands past
|||     `fire_at` still makes the edge. [LTAC.5.3].
|||   * ONE-SHOT (`ltac_4_2__after_ticks_is_state`, `ltac_4_2__gone_once_due`):
|||     the state after any tick history -- Rete/NetworkClocked.idr's fold
|||     `iret_19_5__run_clocked`, read for its state -- is the quiescent
|||     state at the final clock, so once the clock has reached `fire_at`
|||     the timer is not in working memory, and no later tick re-fires it
|||     (its gate's edges after a true reading are all 0,
|||     `ltac_5_1__edges_after_due`). [LTAC.4.2]. The final clock is
|||     `ltac_5_1__clock_after`, the samples taken in turn on the clause's
|||     side (RARC.5.6.3), against which the counts' sum is stated
|||     (`ltac_5_1__due_edges_total`) with no engine in it; that the
|||     engine's clock is that clock is what `after_ticks_is_state` says.
|||   * EXECUTED. The timer with `fire_at` 2 asserted at clock 0 on the loaded
|||     network is the quiescent state (`ltac_5_1__loaded_is_state`). A MISSED
|||     TICK: ticks to 1 and 3 fire at 3, `[0, 1]`, the theorem's instance
|||     (`ltac_5_3__missed_tick_fires_late`, `_is_an_instance`). ONE-SHOT:
|||     ticks to 1, 2, 3, 4 fire once, `[0, 1, 0, 0]`, and the timer is gone
|||     (`ltac_4_2__one_shot_executed`, `ltac_4_2__timer_gone_executed`); the
|||     three theorems at that history, the due tick with ticks after it
|||     (`ltac_4_2__one_shot_is_an_instance`, `ltac_5_3__never_lost_is_an_instance`,
|||     `ltac_4_2__gone_is_an_instance`). A
|||     timer already due when asserted fires in that pump
|||     (`ltac_5_1__due_at_assert_fires_now`, [LTIM.2.5.3]). INDEPENDENT: a
|||     parent rule fires twice on two triggers, emitting two timers with
|||     their own `fire_at` (2 and 4), which fire on their own ticks,
|||     `[1, 1, 0, 1, 0, 1, 0]`, the triggers alone remaining
|||     (`ltac_4_3__two_timers`, `ltac_4_3__independent_counts`,
|||     `ltac_4_3__both_gone`). SAME TICK: two timers due by one tick to 5
|||     both fire in it, `[0, 0, 2]`, their activations in [LDET.5.5]'s order
|||     (`ltac_5_4__same_tick_ready`, `ltac_5_4__same_tick_trace`,
|||     `ltac_5_4__same_tick_counts`).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. The parent half of
||| [LTAC.3.3], `fire_at: monotonic_ns() + dur`: an emit whose payload reads
||| the clock is not an action of this model (`Emit` takes its payload from
||| the bindings), and adding one would change the action type every frame
||| lemma is stated over; here the timer arrives as an input with its
||| `fire_at`, or from an emit that copies it from the trigger's payload
||| (`ltac_3_3__timer_value`), and the fixtures say which. The timer's `corr`
||| slot and `as <expr>` supersedure ([LTAC.2.2.1], RESTART's), the capture
||| fact ([LTAC.3.5]), nesting ([LTAC.6.2.2]) and the sub-tick warning
||| ([LTAC.5.2]) are not modelled. The general theorems start from the
||| QUIESCENT state at a clock (`ltac_3_4__state`): a timer whose `fire_at`
||| is at or below the clock when it is asserted fires at the next pump
||| ([LTIM.2.5.3]), executed and not covered by them. One timer per
||| theorem; two timers are executed. The model's fact has no `fire_at`
||| slot: its payload stands for it, and the `Duration` type of [LTAC.3.2]
||| is a natural here. Fuel is two or more, as Rete/NetworkEdges.idr's B2
||| takes it.
module Rete.NetworkAfter

-- The imports are Rete/NetworkFrameRetime.idr's whole, with NetworkTwoClocks
-- for the rising gate, for the reason Rete/NetworkSampled.idr's comment
-- gives: a run evaluated in a witness unfolds only through modules the
-- file imports.
import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkView
import Rete.NetworkDispatch
import Rete.NetworkOrderKeep
import Rete.NetworkTransferAgree
import Rete.NetworkTms
import Rete.NetworkTmsTransfer
import Rete.NetworkTtl
import Rete.NetworkTick
import Rete.NetworkClocked
import Rete.NetworkEdges
import Rete.NetworkTwoClocks
import Rete.NetworkOnce
import Rete.NetworkFrame
import Rete.NetworkFrameClocked
import Rete.NetworkFrameRetime
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Control.Relation
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The timer fact, the follow-up rule, its gate
-- ---------------------------------------------------------------------

--@spec [LTAC.3.2]
||| A TIMER FACT: kind 0 is the timer schema; its payload is `fire_at`, the
||| monotonic reading at or after which the follow-up may fire. Id 0 and
||| key 1, as the first input the fixtures assert.
public export
ltac_3_2__timer : Nat -> Lfac_1_7_1__fact
ltac_3_2__timer fire_at = MkFact 0 0 1 fire_at

--@spec [LTAC.3.4]
--@spec [LTAC.5.3]
--@spec [LTIM.2.4.1]
||| THE FOLLOW-UP'S GATE: `monotonic_ns() >= t.fire_at`, a time-dependent
||| test that reads the candidate's `fire_at` and the clock. `>=` against
||| the absolute instant, as [LTAC.5.3] requires.
public export
ltac_3_4__due : Ltim_2_4_1__timed
ltac_3_4__due c = \t, f => iret_12__lte_b (fpay f) c

--@spec [LTAC.3.4]
--@spec [LTAC.5.1]
||| THE GATE OF ONE TIMER, as a function of the clock alone: `fire_at <= c`.
public export
ltac_3_4__due_b : Nat -> Nat -> Bool
ltac_3_4__due_b fire_at c = iret_12__lte_b fire_at c

--@derives [LTAC.3.4]
||| The follow-up's test at a timer is that timer's gate, at every clock
||| and whatever the token. Computed.
export
ltac_3_4__due_is_the_gate : (fire_at, c : Nat) -> (t : Iret_7_1__token) -> ltac_3_4__due c t (ltac_3_2__timer fire_at) = ltac_3_4__due_b fire_at c
ltac_3_4__due_is_the_gate fire_at c t = Refl

--@spec [LTAC.4.2]
--@spec [LTAC.3.4]
||| THE FOLLOW-UP'S RHS: the retraction of the timer it matched, the
||| action list's last and here its only action.
public export
ltac_4_2__retract_timer : List Lgra_10_1__action
ltac_4_2__retract_timer = [Withdraw 0]

--@spec [LTAC.3.4]
||| THE FOLLOW-UP RULE, loaded at clock 0: the timer schema's single
||| positive pattern under the gate as read at 0, then the retraction.
public export
ltac_3_4__follow_up_rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltac_3_4__follow_up_rules = [([(0, ltac_3_4__due 0, False)], ltac_4_2__retract_timer)]

--@spec [LTAC.3.4]
--@spec [LTAC.3.2]
||| THE ALPHAS of the follow-up program: the timer schema alone.
public export
ltac_3_4__alphas : List (Nat, Lfac_1_7_1__fact -> Bool)
ltac_3_4__alphas = [(0, ltim_2_5_1__admits_all)]

--@spec [LTAC.3.4]
--@spec [IRET.19.5]
||| THE TIMED TESTS, by ordinal: the follow-up's gate.
public export
ltac_3_4__timed : List (Maybe Ltim_2_4_1__timed)
ltac_3_4__timed = [Just ltac_3_4__due]

--@spec [LTAC.3.4]
||| THE PROGRAM: the follow-up alone, the timer kind explicit -- its
||| lifecycle is the retraction's ([LTAC.3.2]: not a `logical` schema).
public export
ltac_3_4__program : Lcyc_3_2_1__program
ltac_3_4__program = lcyc_3_2_1__program_of (\_ => Explicit) (enet (rdsc_4a_5__load ltac_3_4__alphas ltac_3_4__follow_up_rules))

-- ---------------------------------------------------------------------
-- The quiescent state of one timer at a clock
-- ---------------------------------------------------------------------

--@spec [LTAC.3.4]
--@spec [LTAC.5.1]
--@spec [LTAC.4.2]
||| WORKING MEMORY OF ONE TIMER AT A CLOCK, quiescent: the timer live while
||| the clock is below its `fire_at`, and gone once the clock has reached
||| it -- the follow-up fired and retracted it.
public export
ltac_3_4__wm : Nat -> Nat -> Rarc_5_6_4__wm
ltac_3_4__wm fire_at c = if iret_12__lte_b fire_at c then [] else [ltac_3_2__timer fire_at]

--@spec [LTAC.3.4]
||| THE FOLLOW-UP'S NETWORK over a working memory at a clock: the timer
||| alpha holding it, the one chain's node re-timed to the clock, no
||| activation.
public export
ltac_3_4__net : Rarc_5_6_4__wm -> Nat -> Rarc_5_3_1__network
ltac_3_4__net wm c = MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all wm] [MkChain [MkBeta 0 (ltac_3_4__due c) False [[]] []] [] ltac_4_2__retract_timer]

--@spec [LTAC.4.2]
--@spec [LTAC.3.4]
--@spec [IRET.19.3]
||| AN IDLE CLOCKED NETWORK: the follow-up with nothing to fire over a
||| working memory, no rows, no deadlines, at a clock.
public export
ltac_4_2__idle_net : Rarc_5_6_4__wm -> Nat -> Iret_19_3__clocked_net
ltac_4_2__idle_net wm c = MkClockedNet (MkTmsNet (MkEngine wm (ltac_3_4__net wm c)) []) [] c

--@spec [LTAC.3.4]
--@spec [LTAC.5.1]
--@spec [LTAC.4.2]
||| THE QUIESCENT STATE OF ONE TIMER AT A CLOCK: idle over the timer's
||| working memory at that clock. What a pump leaves, and what the
||| theorems start from.
public export
ltac_3_4__state : Nat -> Nat -> Iret_19_3__clocked_net
ltac_3_4__state fire_at c = ltac_4_2__idle_net (ltac_3_4__wm fire_at c) c

--@spec [LTAC.3.4]
--@spec [LTAC.5.1]
--@spec [LTIM.2.4.2]
||| THE ACTIVATION A TICK MAKES of one timer: the timer's match, unfired,
||| when the gate was false at the old clock and is true at the new; none
||| otherwise.
public export
ltac_3_4__born : Nat -> Nat -> Nat -> List Iret_8_1__act
ltac_3_4__born fire_at c c' = if not (iret_12__lte_b fire_at c) && iret_12__lte_b fire_at c' then [MkAct [ltac_3_2__timer fire_at] False] else []

--@spec [LTAC.3.4]
--@spec [LTAC.5.1]
--@spec [IRET.19.5]
||| THE STATE AS A TICK LEAVES IT, before the run: the working memory of
||| the old clock, the node re-timed to the new, the born activation if
||| any.
public export
ltac_3_4__ticked : Nat -> Nat -> Nat -> Iret_19_3__clocked_net
ltac_3_4__ticked fire_at c c' =
  MkClockedNet (MkTmsNet (MkEngine (ltac_3_4__wm fire_at c)
                                   (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all (ltac_3_4__wm fire_at c)]
                                              [MkChain [MkBeta 0 (ltac_3_4__due c') False [[]] []] (ltac_3_4__born fire_at c c') ltac_4_2__retract_timer]))
                         []) [] c'

--@spec [LTAC.5.1]
--@spec [LTAC.4.2]
||| THE DUE STATE: the timer live and its activation born unfired at the
||| clock that reached `fire_at`. What the run consumes.
public export
ltac_5_1__due_net : Nat -> Nat -> Iret_19_3__clocked_net
ltac_5_1__due_net fire_at c' =
  MkClockedNet (MkTmsNet (MkEngine [ltac_3_2__timer fire_at]
                                   (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [ltac_3_2__timer fire_at]]
                                              [MkChain [MkBeta 0 (ltac_3_4__due c') False [[]] []] [MkAct [ltac_3_2__timer fire_at] False] ltac_4_2__retract_timer]))
                         []) [] c'

-- ---------------------------------------------------------------------
-- The gate is rising
-- ---------------------------------------------------------------------

--@derives [LTAC.5.3]
||| The order on naturals, as a Bool: at or below is `True`. Rete/TtlSweep.idr
||| has the converse.
export
ltac_5_3__lte_lte_b : (a, b : Nat) -> LTE a b -> iret_12__lte_b a b = True
ltac_5_3__lte_lte_b Z b _ = Refl
ltac_5_3__lte_lte_b (S a) Z le = absurd le
ltac_5_3__lte_lte_b (S a) (S b) (LTESucc le) = ltac_5_3__lte_lte_b a b le

--@derives [LTAC.5.3]
--@derives [LTIM.2.5.1]
--@derives [LTIM.2.8.2]
||| THE GATE IS RISING: `fire_at <= c` true at a clock is true at every
||| clock at or after it. `>=` against an absolute instant on a clock that
||| never goes back -- the whole of [LTAC.5.3]'s mechanism.
export
ltac_5_3__due_rising : (fire_at : Nat) -> Ltim_2_5_1__rising_b (ltac_3_4__due_b fire_at)
ltac_5_3__due_rising fire_at c c' le h = ltac_5_3__lte_lte_b fire_at c' (transitive (iret_12__lte_b_true_lte fire_at c h) le)

-- ---------------------------------------------------------------------
-- One pump of one timer
-- ---------------------------------------------------------------------

--@derives [LTAC.3.4]
--@derives [LTAC.5.1]
--@derives [IRET.19.5]
--@derives [LTIM.2.4.2]
||| THE RE-TIME OF THE FOLLOW-UP at a new clock: the node takes the gate at
||| the new clock; the timer's match is born unfired exactly when the gate
||| was false and is true; nothing is ended, since a rising gate refuses
||| nothing it admitted. Computed, over the four readings of the gate.
export
ltac_3_4__tick_literal : (fire_at, c, c' : Nat) ->
                         iret_19_5__tick ltac_3_4__timed c' (MkEngine (ltac_3_4__wm fire_at c) (ltac_3_4__net (ltac_3_4__wm fire_at c) c))
                           = MkEngine (ltac_3_4__wm fire_at c)
                                      (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all (ltac_3_4__wm fire_at c)]
                                                 [MkChain [MkBeta 0 (ltac_3_4__due c') False [[]] []] (ltac_3_4__born fire_at c c') ltac_4_2__retract_timer])
-- The first `with` decides the memory the node joins against; the filter
-- that join unfolds to was stuck behind it, so the gate's old reading
-- inside the filter is rewritten in by hand once the second `with` has
-- decided the new one.
ltac_3_4__tick_literal fire_at c c' with (iret_12__lte_b fire_at c) proof pc
  ltac_3_4__tick_literal fire_at c c' | True = Refl
  ltac_3_4__tick_literal fire_at c c' | False with (iret_12__lte_b fire_at c')
    ltac_3_4__tick_literal fire_at c c' | False | True = rewrite pc in Refl
    ltac_3_4__tick_literal fire_at c c' | False | False = rewrite pc in Refl

--@derives [LTAC.4.2]
--@derives [LTAC.3.4]
--@derives [IRET.11.4]
||| THE FOLLOW-UP FIRES AND RETRACTS ITS TIMER: one firing from the due
||| state marks the activation, runs the withdraw, and leaves the timer
||| gone from working memory, from the alpha and from the terminal -- the
||| retraction of the matched fact ends the match that fired. Computed,
||| once the timer's own equality and the gate's reading are given.
export
ltac_4_2__step_fires : (pg : Lcyc_3_2_1__program) -> (fire_at, c' : Nat) -> iret_12__lte_b fire_at c' = True ->
                       iret_11_4__step_ttl_net pg ltim_2_5_1__no_ttl (ltac_5_1__due_net fire_at c') = Just (ltac_4_2__idle_net [] c')
-- The timer's own equality decides the withdraw's `any`, which guards the
-- retraction; inside it the gate's reading decides which tokens the node
-- retracts, and the equality decides again what working memory, the alpha
-- and the terminal keep. Each rewrite opens what the next one reaches.
ltac_4_2__step_fires pg fire_at c' due =
  rewrite lcyc_1_1__nat_eq_refl fire_at in rewrite due in rewrite lcyc_1_1__nat_eq_refl fire_at in Refl

--@derives [LTAC.4.2]
--@derives [IRET.11.4]
||| THE RUN FROM THE DUE STATE: the one firing, then nothing to fire; one
||| firing counted, quiescent, the timer gone.
export
ltac_4_2__run_fires : (pg : Lcyc_3_2_1__program) -> (k, fire_at, c' : Nat) -> iret_12__lte_b fire_at c' = True ->
                      iret_11_4__run_ttl_net pg ltim_2_5_1__no_ttl (S (S k)) (ltac_5_1__due_net fire_at c') = (ltac_4_2__idle_net [] c', Quiescent, 1)
ltac_4_2__run_fires pg k fire_at c' due =
  iret_11_4__run_ttl_net_just pg ltim_2_5_1__no_ttl (S k) (ltac_5_1__due_net fire_at c') (ltac_4_2__idle_net [] c') (ltac_4_2__step_fires pg fire_at c' due)
    (ltac_4_2__idle_net [] c') Quiescent 0 (iret_11_4__run_ttl_net_nothing pg ltim_2_5_1__no_ttl k (ltac_4_2__idle_net [] c') Refl)

--@derives [LTAC.4.2]
--@derives [IRET.11.4]
||| THE RUN FROM AN IDLE STATE fires nothing, whatever working memory
||| holds: no activation, quiescent at once.
export
ltac_4_2__run_idle : (pg : Lcyc_3_2_1__program) -> (k : Nat) -> (wm : Rarc_5_6_4__wm) -> (c' : Nat) ->
                     iret_11_4__run_ttl_net pg ltim_2_5_1__no_ttl (S (S k)) (ltac_4_2__idle_net wm c') = (ltac_4_2__idle_net wm c', Quiescent, 0)
ltac_4_2__run_idle pg k wm c' = iret_11_4__run_ttl_net_nothing pg ltim_2_5_1__no_ttl (S k) (ltac_4_2__idle_net wm c') Refl

--@derives [LTAC.5.1]
--@derives [LTAC.4.2]
--@derives [IRET.19.5]
||| THE RUN AFTER THE TICK, over the four readings of the gate: fires once
||| when the tick made the edge and takes the timer, fires nothing
||| otherwise; the gate true before the tick and false after it is no
||| reading, the gate being rising.
export
ltac_5_1__ticked_run : (pg : Lcyc_3_2_1__program) -> (k, fire_at, c, t : Nat) ->
                       iret_11_4__run_ttl_net pg ltim_2_5_1__no_ttl (S (S k)) (ltac_3_4__ticked fire_at c (rarc_5_6_3__next_clock c t))
                         = (ltac_3_4__state fire_at (rarc_5_6_3__next_clock c t), Quiescent, ltim_2_5_1__edge_at (ltac_3_4__due_b fire_at) c t)
ltac_5_1__ticked_run pg k fire_at c t with (iret_12__lte_b fire_at c) proof pc
  ltac_5_1__ticked_run pg k fire_at c t | True with (iret_12__lte_b fire_at (rarc_5_6_3__next_clock c t)) proof pc'
    ltac_5_1__ticked_run pg k fire_at c t | True | True = ltac_4_2__run_idle pg k [] (rarc_5_6_3__next_clock c t)
    ltac_5_1__ticked_run pg k fire_at c t | True | False =
      absurd (trans (sym pc') (ltac_5_3__due_rising fire_at c (rarc_5_6_3__next_clock c t) (rarc_5_6_3__next_clock_lte c t) pc))
  ltac_5_1__ticked_run pg k fire_at c t | False with (iret_12__lte_b fire_at (rarc_5_6_3__next_clock c t)) proof pc'
    ltac_5_1__ticked_run pg k fire_at c t | False | True = ltac_4_2__run_fires pg k fire_at (rarc_5_6_3__next_clock c t) pc'
    ltac_5_1__ticked_run pg k fire_at c t | False | False = ltac_4_2__run_idle pg k [ltac_3_2__timer fire_at] (rarc_5_6_3__next_clock c t)

--@derives [LTAC.5.1]
--@derives [LTAC.4.2]
--@derives [LTAC.3.4]
--@derives [IRET.19.5]
--@derives [RARC.5.6.3]
||| ONE PUMP OF ONE TIMER: from the quiescent state at a clock, the pump at
||| a tick fires the gate's edge -- once, with the timer's retraction, when
||| the sample reaches `fire_at`; nothing otherwise -- and leaves the
||| quiescent state at the new clock. The tick expires nothing and ends no
||| row (no deadline, no row), so it is the re-time alone.
export
ltac_5_1__timer_pump : (pg : Lcyc_3_2_1__program) -> (k, fire_at, c, t : Nat) ->
                       iret_19_5__pump_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed (S (S k)) (Tick t) (ltac_3_4__state fire_at c)
                         = (ltac_3_4__state fire_at (rarc_5_6_3__next_clock c t), Quiescent, ltim_2_5_1__edge_at (ltac_3_4__due_b fire_at) c t)
ltac_5_1__timer_pump pg k fire_at c t =
  let tk = the (iret_19_5__tick_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed t (ltac_3_4__state fire_at c)
                  = MkClockedNet (MkTmsNet (iret_19_5__tick ltac_3_4__timed (rarc_5_6_3__next_clock c t) (MkEngine (ltac_3_4__wm fire_at c) (ltac_3_4__net (ltac_3_4__wm fire_at c) c))) []) [] (rarc_5_6_3__next_clock c t))
               (trans (cong (iret_19_5__retime_clocked pg ltac_3_4__timed)
                            (ldet_5_8__quiet_tick_net pg ltim_2_5_1__no_ttl t (ltac_3_4__wm fire_at c) (ltac_3_4__net (ltac_3_4__wm fire_at c) c) [] [] c Refl Refl))
                      (ltim_2_7_2__no_cascade_is_the_retime pg ltac_3_4__timed (MkEngine (ltac_3_4__wm fire_at c) (ltac_3_4__net (ltac_3_4__wm fire_at c) c)) [] [] (rarc_5_6_3__next_clock c t) Refl))
      tk2 = the (iret_19_5__tick_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed t (ltac_3_4__state fire_at c) = ltac_3_4__ticked fire_at c (rarc_5_6_3__next_clock c t))
                (trans tk (cong (\e => MkClockedNet (MkTmsNet e []) [] (rarc_5_6_3__next_clock c t)) (ltac_3_4__tick_literal fire_at c (rarc_5_6_3__next_clock c t))))
  in replace {p = \x => iret_11_4__run_ttl_net pg ltim_2_5_1__no_ttl (S (S k)) x
                          = (ltac_3_4__state fire_at (rarc_5_6_3__next_clock c t), Quiescent, ltim_2_5_1__edge_at (ltac_3_4__due_b fire_at) c t)}
       (sym tk2) (ltac_5_1__ticked_run pg k fire_at c t)

-- ---------------------------------------------------------------------
-- Over a history: the counts are the edges, at most one
-- ---------------------------------------------------------------------

--@derives [LTAC.5.1]
--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| THE COUNTS ARE THE EDGES: over any tick history from any starting
||| clock, the follow-up's firings are the rising edges of the timer's
||| gate, one count per pump. Rete/NetworkEdges.idr's B2 for the timer
||| chain, whose RHS retracts what it matched.
export
ltac_5_1__timer_counts_are_edges : (pg : Lcyc_3_2_1__program) -> (k, fire_at, c : Nat) -> (ticks : List Nat) ->
                                   iret_19_5__counts_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed (S (S k)) (map Tick ticks) (ltac_3_4__state fire_at c)
                                     = Ltim_2_5_1__edges (ltac_3_4__due_b fire_at) c ticks
ltac_5_1__timer_counts_are_edges pg k fire_at c [] = Refl
ltac_5_1__timer_counts_are_edges pg k fire_at c (t :: ts) =
  trans (iret_19_5__counts_clocked_cons pg ltim_2_5_1__no_ttl ltac_3_4__timed (S (S k)) (Tick t) (map Tick ts)
           (ltac_3_4__state fire_at c) (ltac_3_4__state fire_at (rarc_5_6_3__next_clock c t)) Quiescent
           (ltim_2_5_1__edge_at (ltac_3_4__due_b fire_at) c t) (ltac_5_1__timer_pump pg k fire_at c t))
        (cong (ltim_2_5_1__edge_at (ltac_3_4__due_b fire_at) c t ::) (ltac_5_1__timer_counts_are_edges pg k fire_at (rarc_5_6_3__next_clock c t) ts))

--@derives [LTAC.4.2]
--@derives [LTAC.5.1]
--@derives [LTIM.2.5.1]
||| AT MOST ONCE: over any tick history from any starting clock the
||| follow-up fires at most once -- the timer's gate is rising and
||| Rete/NetworkTwoClocks.idr's C3a bounds a rising gate's edges by one.
export
ltac_5_1__at_most_once_is_an_instance : (pg : Lcyc_3_2_1__program) -> (k, fire_at, c : Nat) -> (ticks : List Nat) ->
                                        LTE (ltim_2_5_1__total (iret_19_5__counts_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed (S (S k)) (map Tick ticks) (ltac_3_4__state fire_at c))) 1
ltac_5_1__at_most_once_is_an_instance pg k fire_at c ticks =
  replace {p = \l => LTE (ltim_2_5_1__total l) 1} (sym (ltac_5_1__timer_counts_are_edges pg k fire_at c ticks))
          (ltim_2_5_1__rising_edges_at_most_one (ltac_3_4__due_b fire_at) (ltac_5_3__due_rising fire_at) c ticks)

-- ---------------------------------------------------------------------
-- The edge is at the first due tick, and never lost
-- ---------------------------------------------------------------------

--@spec [LTAC.5.1]
--@spec [RARC.5.6.3]
||| THE CLOCK AFTER A TICK HISTORY: each sample taken in turn.
public export
ltac_5_1__clock_after : Nat -> List Nat -> Nat
ltac_5_1__clock_after c [] = c
ltac_5_1__clock_after c (t :: ts) = ltac_5_1__clock_after (rarc_5_6_3__next_clock c t) ts

--@derives [LTAC.5.1]
--@derives [LTIM.2.8.2]
||| The clock after a history is at or above the clock before it.
export
ltac_5_1__clock_after_lte : (c : Nat) -> (ticks : List Nat) -> LTE c (ltac_5_1__clock_after c ticks)
ltac_5_1__clock_after_lte c [] = reflexive
ltac_5_1__clock_after_lte c (t :: ts) = transitive (rarc_5_6_3__next_clock_lte c t) (ltac_5_1__clock_after_lte (rarc_5_6_3__next_clock c t) ts)

--@spec [LTAC.5.1]
||| No firing at any of these ticks.
public export
ltac_5_1__zeros : List Nat -> List Nat
ltac_5_1__zeros [] = []
ltac_5_1__zeros (t :: ts) = 0 :: ltac_5_1__zeros ts

--@derives [LTAC.5.1]
export
ltac_5_1__zeros_total : (ticks : List Nat) -> ltim_2_5_1__total (ltac_5_1__zeros ticks) = 0
ltac_5_1__zeros_total [] = Refl
ltac_5_1__zeros_total (t :: ts) = ltac_5_1__zeros_total ts

--@spec [LTAC.5.3]
--@spec [LTAC.5.1]
||| ONE FIRING, OR NONE: a named function, not an inline `if`, so that two
||| statements of it are the same term and not two lifted case blocks with
||| different captured environments (the guide's note).
public export
ltac_5_3__once_if : Bool -> Nat
ltac_5_3__once_if True = 1
ltac_5_3__once_if False = 0

--@spec [LTAC.5.1]
--@spec [LTAC.5.3]
||| THE CLAUSE'S COUNTS: from a clock below `fire_at`, 0 at every tick whose
||| sample stays below it, 1 at the first tick whose sample reaches it --
||| at or past, a skipped sample notwithstanding -- and 0 at every tick
||| after. What "fires on the first tick at or after `fire_at`" says, as a
||| list.
public export
ltac_5_1__due_edges : Nat -> Nat -> List Nat -> List Nat
ltac_5_1__due_edges fire_at c [] = []
ltac_5_1__due_edges fire_at c (t :: ts) =
  if iret_12__lte_b fire_at (rarc_5_6_3__next_clock c t) then 1 :: ltac_5_1__zeros ts else 0 :: ltac_5_1__due_edges fire_at (rarc_5_6_3__next_clock c t) ts

--@derives [LTAC.4.2]
--@derives [LTAC.5.1]
--@derives [LTIM.2.5.1]
||| ONCE THE GATE IS TRUE, NO TICK MAKES AN EDGE: the timer has fired and
||| no later tick re-fires it.
export
ltac_5_1__edges_after_due : (fire_at, c : Nat) -> (ticks : List Nat) -> iret_12__lte_b fire_at c = True ->
                            Ltim_2_5_1__edges (ltac_3_4__due_b fire_at) c ticks = ltac_5_1__zeros ticks
ltac_5_1__edges_after_due fire_at c [] d = Refl
ltac_5_1__edges_after_due fire_at c (t :: ts) d =
  cong2 (::) (ltim_2_5_1__edge_at_true (ltac_3_4__due_b fire_at) c t d)
             (ltac_5_1__edges_after_due fire_at (rarc_5_6_3__next_clock c t) ts
                (ltac_5_3__due_rising fire_at c (rarc_5_6_3__next_clock c t) (rarc_5_6_3__next_clock_lte c t) d))

--@derives [LTAC.5.3]
--@derives [LTAC.5.1]
||| A TICK THAT LANDS PAST `fire_at` STILL MAKES THE EDGE: the gate false
||| before it and true after it, however far past. The `>=`, not an
||| equality against the scheduled instant.
export
ltac_5_3__late_edge : (fire_at, c, t : Nat) -> iret_12__lte_b fire_at c = False -> iret_12__lte_b fire_at (rarc_5_6_3__next_clock c t) = True ->
                      ltim_2_5_1__edge_at (ltac_3_4__due_b fire_at) c t = 1
ltac_5_3__late_edge fire_at c t nd d = rewrite nd in rewrite d in Refl

--@derives [LTAC.5.1]
--@derives [LTAC.5.3]
--@derives [LTIM.2.5.1]
||| THE EDGES ARE THE CLAUSE'S COUNTS: from a clock below `fire_at`, the
||| rising edges of the timer's gate over any history are 1 at the first
||| tick whose sample reaches `fire_at` and 0 everywhere else.
export
ltac_5_1__edges_are_first_due : (fire_at, c : Nat) -> (ticks : List Nat) -> iret_12__lte_b fire_at c = False ->
                                Ltim_2_5_1__edges (ltac_3_4__due_b fire_at) c ticks = ltac_5_1__due_edges fire_at c ticks
ltac_5_1__edges_are_first_due fire_at c [] nd = Refl
ltac_5_1__edges_are_first_due fire_at c (t :: ts) nd with (iret_12__lte_b fire_at (rarc_5_6_3__next_clock c t)) proof d
  ltac_5_1__edges_are_first_due fire_at c (t :: ts) nd | True =
    cong2 (::) (rewrite nd in Refl) (ltac_5_1__edges_after_due fire_at (rarc_5_6_3__next_clock c t) ts d)
  ltac_5_1__edges_are_first_due fire_at c (t :: ts) nd | False =
    cong2 (::) (rewrite nd in Refl) (ltac_5_1__edges_are_first_due fire_at (rarc_5_6_3__next_clock c t) ts d)

--@derives [LTAC.5.3]
--@derives [LTAC.5.1]
||| THE CLAUSE'S COUNTS SUM TO ONE EXACTLY WHEN THE HISTORY REACHES
||| `fire_at`: never lost, and never before.
export
ltac_5_1__due_edges_total : (fire_at, c : Nat) -> (ticks : List Nat) -> iret_12__lte_b fire_at c = False ->
                            ltim_2_5_1__total (ltac_5_1__due_edges fire_at c ticks) = ltac_5_3__once_if (iret_12__lte_b fire_at (ltac_5_1__clock_after c ticks))
ltac_5_1__due_edges_total fire_at c [] nd = rewrite nd in Refl
ltac_5_1__due_edges_total fire_at c (t :: ts) nd with (iret_12__lte_b fire_at (rarc_5_6_3__next_clock c t)) proof d
  ltac_5_1__due_edges_total fire_at c (t :: ts) nd | True =
    rewrite ltac_5_3__due_rising fire_at (rarc_5_6_3__next_clock c t) (ltac_5_1__clock_after (rarc_5_6_3__next_clock c t) ts)
              (ltac_5_1__clock_after_lte (rarc_5_6_3__next_clock c t) ts) d in
    rewrite ltac_5_1__zeros_total ts in Refl
  ltac_5_1__due_edges_total fire_at c (t :: ts) nd | False = ltac_5_1__due_edges_total fire_at (rarc_5_6_3__next_clock c t) ts d

-- ---------------------------------------------------------------------
-- THE THEOREMS
-- ---------------------------------------------------------------------

--@derives [LTAC.5.1]
--@derives [LTAC.5.3]
--@derives [LTAC.3.4]
--@derives [LTIM.2.5.1]
||| THE FOLLOW-UP FIRES ON THE FIRST TICK AT OR AFTER `fire_at`, AND ON NO
||| OTHER: from the quiescent state at a clock below `fire_at`, over any
||| tick history, the firings are 0 at every tick whose sample stays below
||| `fire_at`, 1 at the first whose sample reaches it, and 0 at every tick
||| after. The counts are the gate's edges, and the edges are the clause's.
export
ltac_5_1__fires_on_the_first_due_tick : (pg : Lcyc_3_2_1__program) -> (k, fire_at, c : Nat) -> (ticks : List Nat) -> iret_12__lte_b fire_at c = False ->
                                        iret_19_5__counts_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed (S (S k)) (map Tick ticks) (ltac_3_4__state fire_at c)
                                          = ltac_5_1__due_edges fire_at c ticks
ltac_5_1__fires_on_the_first_due_tick pg k fire_at c ticks nd =
  trans (ltac_5_1__timer_counts_are_edges pg k fire_at c ticks) (ltac_5_1__edges_are_first_due fire_at c ticks nd)

--@derives [LTAC.5.3]
--@derives [LTAC.5.1]
--@derives [LTAC.4.2]
||| NEVER LOST: over any tick history from a clock below `fire_at`, the
||| follow-up has fired exactly once when the history's final clock has
||| reached `fire_at`, whatever ticks were missed on the way, and not at
||| all when it has not.
export
ltac_5_3__never_lost : (pg : Lcyc_3_2_1__program) -> (k, fire_at, c : Nat) -> (ticks : List Nat) -> iret_12__lte_b fire_at c = False ->
                       ltim_2_5_1__total (iret_19_5__counts_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed (S (S k)) (map Tick ticks) (ltac_3_4__state fire_at c))
                         = ltac_5_3__once_if (iret_12__lte_b fire_at (ltac_5_1__clock_after c ticks))
ltac_5_3__never_lost pg k fire_at c ticks nd =
  trans (cong ltim_2_5_1__total (ltac_5_1__fires_on_the_first_due_tick pg k fire_at c ticks nd)) (ltac_5_1__due_edges_total fire_at c ticks nd)

--@derives [LTAC.4.2]
--@derives [LTAC.5.1]
||| THE STATE AFTER A TICK HISTORY IS THE QUIESCENT STATE AT ITS CLOCK:
||| Rete/NetworkClocked.idr's fold, read for its state, lands on
||| `ltac_3_4__state` at the clock the ticks reach.
export
ltac_4_2__after_ticks_is_state : (pg : Lcyc_3_2_1__program) -> (k, fire_at, c : Nat) -> (ticks : List Nat) ->
                                 lfst_9_2_1__after_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed (S (S k)) (map Tick ticks) (ltac_3_4__state fire_at c)
                                   = ltac_3_4__state fire_at (ltac_5_1__clock_after c ticks)
ltac_4_2__after_ticks_is_state pg k fire_at c [] = Refl
ltac_4_2__after_ticks_is_state pg k fire_at c (t :: ts) =
  trans (cong (lfst_9_2_1__after_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed (S (S k)) (map Tick ts)) (cong fst (ltac_5_1__timer_pump pg k fire_at c t)))
        (ltac_4_2__after_ticks_is_state pg k fire_at (rarc_5_6_3__next_clock c t) ts)

--@derives [LTAC.4.2]
--@derives [LTAC.3.4]
||| ONE-SHOT: once a history's clock has reached `fire_at`, the timer is not
||| in working memory -- the follow-up's retraction took it, and the state
||| holds nothing for a later tick to re-fire.
export
ltac_4_2__gone_once_due : (pg : Lcyc_3_2_1__program) -> (k, fire_at, c : Nat) -> (ticks : List Nat) ->
                          iret_12__lte_b fire_at (ltac_5_1__clock_after c ticks) = True ->
                          ewm (ncore (nengine (lfst_9_2_1__after_clocked pg ltim_2_5_1__no_ttl ltac_3_4__timed (S (S k)) (map Tick ticks) (ltac_3_4__state fire_at c)))) = []
ltac_4_2__gone_once_due pg k fire_at c ticks d = rewrite ltac_4_2__after_ticks_is_state pg k fire_at c ticks in rewrite d in Refl

-- ---------------------------------------------------------------------
-- Executed: a missed tick, one-shot, due at assert
-- ---------------------------------------------------------------------

--@derives [LTAC.5.1]
--@derives [LTAC.3.2]
--@derives [RARC.5.6.3]
||| THE TIMER WITH `fire_at` 2, ASSERTED AT CLOCK 0 on the loaded follow-up
||| network, IS the quiescent state at 0: the hand-written state the
||| theorems start from is what the loader and the input leave. Computed.
export
ltac_5_1__loaded_is_state :
  rarc_5_6_3__prepared_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed [Data (Assert 0 1 2)]
    (rdsc_4a_5__load_clocked ltac_3_4__alphas ltac_3_4__follow_up_rules 0)
    = ltac_3_4__state 2 0
ltac_5_1__loaded_is_state = Refl

--@derives [LTAC.5.3]
--@derives [LTAC.5.1]
||| A MISSED TICK FIRES LATE: the timer due at 2, ticks to 1 and 3 -- the
||| tick at 2 never comes -- fire the follow-up at 3, `[0, 1]`. From the
||| loaded network, the input pumped first. Executed.
export
ltac_5_3__missed_tick_fires_late :
  iret_19_5__counts_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 [Data (Assert 0 1 2), Tick 1, Tick 3]
    (rdsc_4a_5__load_clocked ltac_3_4__alphas ltac_3_4__follow_up_rules 0) = [0, 0, 1]
ltac_5_3__missed_tick_fires_late = Refl

--@derives [LTAC.5.3]
--@derives [LTAC.5.1]
||| THE THEOREM AT THE MISSED TICK: from the quiescent state at 0, the
||| counts over ticks 1 and 3 are the clause's, and the clause's are
||| `[0, 1]`. Executed.
export
ltac_5_3__missed_tick_is_an_instance :
  ( iret_19_5__counts_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 [Tick 1, Tick 3] (ltac_3_4__state 2 0) = ltac_5_1__due_edges 2 0 [1, 3]
  , ltac_5_1__due_edges 2 0 [1, 3] = [0, 1] )
ltac_5_3__missed_tick_is_an_instance = (ltac_5_1__fires_on_the_first_due_tick ltac_3_4__program 8 2 0 [1, 3] Refl, Refl)

--@derives [LTAC.4.2]
--@derives [LTAC.5.1]
||| ONE-SHOT, EXECUTED: the timer due at 2 over ticks 1, 2, 3, 4 fires once,
||| at 2, `[0, 1, 0, 0]`; the input pumped first.
export
ltac_4_2__one_shot_executed :
  iret_19_5__counts_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 [Data (Assert 0 1 2), Tick 1, Tick 2, Tick 3, Tick 4]
    (rdsc_4a_5__load_clocked ltac_3_4__alphas ltac_3_4__follow_up_rules 0) = [0, 0, 1, 0, 0]
ltac_4_2__one_shot_executed = Refl

--@derives [LTAC.4.2]
||| AND THE TIMER IS GONE: after those pumps working memory is empty. "A
||| timer fact must not survive its firing." Computed.
export
ltac_4_2__timer_gone_executed :
  ewm (ncore (nengine (lfst_9_2_1__after_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 [Data (Assert 0 1 2), Tick 1, Tick 2, Tick 3, Tick 4]
                                                 (rdsc_4a_5__load_clocked ltac_3_4__alphas ltac_3_4__follow_up_rules 0)))) = []
ltac_4_2__timer_gone_executed = Refl

--@derives [LTAC.4.2]
--@derives [LTAC.5.1]
||| THE THEOREM AT THE ONE-SHOT HISTORY: from the quiescent state at 0, the
||| counts over ticks 1, 2, 3, 4 are the clause's, and the clause's are
||| `[0, 1, 0, 0]` -- the due tick with ticks after it, so the clauses for
||| the ticks after the firing are reached (unit U's first owed witness).
||| Executed.
export
ltac_4_2__one_shot_is_an_instance :
  ( iret_19_5__counts_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 [Tick 1, Tick 2, Tick 3, Tick 4] (ltac_3_4__state 2 0)
      = ltac_5_1__due_edges 2 0 [1, 2, 3, 4]
  , ltac_5_1__due_edges 2 0 [1, 2, 3, 4] = [0, 1, 0, 0] )
ltac_4_2__one_shot_is_an_instance = (ltac_5_1__fires_on_the_first_due_tick ltac_3_4__program 8 2 0 [1, 2, 3, 4] Refl, Refl)

--@derives [LTAC.5.3]
--@derives [LTAC.4.2]
||| NEVER LOST, AT THE ONE-SHOT HISTORY: the counts sum to the one-or-none
||| at the final clock, and the final clock, 4, has reached `fire_at`, so
||| the sum is 1 (unit U's second owed witness). Executed.
export
ltac_5_3__never_lost_is_an_instance :
  ( ltim_2_5_1__total (iret_19_5__counts_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 [Tick 1, Tick 2, Tick 3, Tick 4] (ltac_3_4__state 2 0))
      = ltac_5_3__once_if (iret_12__lte_b 2 (ltac_5_1__clock_after 0 [1, 2, 3, 4]))
  , ltac_5_3__once_if (iret_12__lte_b 2 (ltac_5_1__clock_after 0 [1, 2, 3, 4])) = 1 )
ltac_5_3__never_lost_is_an_instance = (ltac_5_3__never_lost ltac_3_4__program 8 2 0 [1, 2, 3, 4] Refl, Refl)

--@derives [LTAC.4.2]
--@derives [LTAC.3.4]
||| ONE-SHOT, AT THE ONE-SHOT HISTORY, THROUGH THE THEOREM: the history's
||| clock reaches `fire_at` (`lte_b 2 4`, computed), so the timer is not in
||| working memory after it (unit U's third owed witness). Executed.
export
ltac_4_2__gone_is_an_instance :
  ewm (ncore (nengine (lfst_9_2_1__after_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 [Tick 1, Tick 2, Tick 3, Tick 4] (ltac_3_4__state 2 0)))) = []
ltac_4_2__gone_is_an_instance = ltac_4_2__gone_once_due ltac_3_4__program 8 2 0 [1, 2, 3, 4] Refl

--@derives [LTAC.5.1]
--@derives [LTIM.2.5.3]
||| A TIMER ALREADY DUE WHEN ASSERTED fires in that input's pump, with no
||| tick: the gate is true at assert ([LTIM.2.5.3]), the activation is made
||| by the assertion, and the retraction follows. `[1]`, and nothing live.
||| Outside the theorems, which start quiescent. Executed.
export
ltac_5_1__due_at_assert_fires_now :
  ( iret_19_5__counts_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 [Data (Assert 0 1 0)]
      (rdsc_4a_5__load_clocked ltac_3_4__alphas ltac_3_4__follow_up_rules 0) = [1]
  , ewm (ncore (nengine (lfst_9_2_1__after_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 [Data (Assert 0 1 0)]
                                                   (rdsc_4a_5__load_clocked ltac_3_4__alphas ltac_3_4__follow_up_rules 0)))) = [] )
ltac_5_1__due_at_assert_fires_now = (Refl, Refl)

-- ---------------------------------------------------------------------
-- Executed: N timers from N parent firings, independent
-- ---------------------------------------------------------------------

--@spec [LTAC.3.3]
||| THE TIMER THE PARENT EMITS: key 0, `fire_at` copied from the trigger's
||| payload. Not `monotonic_ns() + dur`: an emit reads no clock in this
||| model, and the trigger carries the absolute instant instead. The
||| fixture's departure from [LTAC.3.3], named.
public export
ltac_3_3__timer_value : List Lfac_1_7_1__fact -> (Nat, Nat)
ltac_3_3__timer_value [] = (0, 0)
ltac_3_3__timer_value (f :: _) = (0, fpay f)

--@spec [LTAC.3.3]
--@spec [LTAC.4.3]
||| THE PARENT AND ITS FOLLOW-UP: the follow-up at ordinal 0 on the timer
||| schema (kind 0); the parent at ordinal 1 on the trigger schema (kind 1),
||| its RHS the timer's assertion ([LTAC.3.3]) and nothing else.
public export
ltac_4_3__rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltac_4_3__rules =
  [ ([(0, ltac_3_4__due 0, False)], ltac_4_2__retract_timer)
  , ([(1, iret_7_7__row, False)], [Emit 0 ltac_3_3__timer_value]) ]

--@spec [LTAC.4.3]
||| THE ALPHAS: the timer schema and the trigger schema.
public export
ltac_4_3__alphas : List (Nat, Lfac_1_7_1__fact -> Bool)
ltac_4_3__alphas = [(0, ltim_2_5_1__admits_all), (1, ltim_2_5_1__admits_all)]

--@spec [LTAC.4.3]
--@spec [IRET.19.5]
||| THE TIMED TESTS, by ordinal: the follow-up's gate; the parent untimed.
public export
ltac_4_3__timed : List (Maybe Ltim_2_4_1__timed)
ltac_4_3__timed = [Just ltac_3_4__due, Nothing]

--@spec [LTAC.4.3]
||| THE PROGRAM: both rules, every kind explicit.
public export
ltac_4_3__program : Lcyc_3_2_1__program
ltac_4_3__program = lcyc_3_2_1__program_of (\_ => Explicit) (enet (rdsc_4a_5__load ltac_4_3__alphas ltac_4_3__rules))

--@spec [LTAC.4.3]
--@spec [LTAC.5.1]
||| THE INPUTS: two triggers at clock 0 carrying `fire_at` 2 and 4, each
||| pumped, then ticks to 1, 2, 3, 4, 5.
public export
ltac_4_3__inputs : List Rarc_5_6_2__input
ltac_4_3__inputs = [Data (Assert 1 1 2), Data (Assert 1 2 4), Tick 1, Tick 2, Tick 3, Tick 4, Tick 5]

--@derives [LTAC.4.3]
--@derives [LTAC.3.3]
||| N TIMERS FROM N PARENT FIRINGS: after the two triggers are pumped, the
||| parent has fired twice and two timer facts are live concurrently, each
||| with its own `fire_at` (ids 1 and 3; the triggers 0 and 2). Computed.
export
ltac_4_3__two_timers :
  ewm (ncore (nengine (lfst_9_2_1__after_clocked ltac_4_3__program ltim_2_5_1__no_ttl ltac_4_3__timed 10 [Data (Assert 1 1 2), Data (Assert 1 2 4)]
                                                 (rdsc_4a_5__load_clocked ltac_4_3__alphas ltac_4_3__rules 0))))
    = [MkFact 0 1 1 2, MkFact 1 0 0 2, MkFact 2 1 2 4, MkFact 3 0 0 4]
ltac_4_3__two_timers = Refl

--@derives [LTAC.4.3]
--@derives [LTAC.5.1]
--@derives [LTAC.4.2]
||| INDEPENDENT: the parent fires once per trigger (the first two counts),
||| then the follow-up fires for the first timer at 2 and for the second at
||| 4, each on its own tick and once, `[1, 1, 0, 1, 0, 1, 0]`. Executed.
export
ltac_4_3__independent_counts :
  iret_19_5__counts_clocked ltac_4_3__program ltim_2_5_1__no_ttl ltac_4_3__timed 10 ltac_4_3__inputs
    (rdsc_4a_5__load_clocked ltac_4_3__alphas ltac_4_3__rules 0) = [1, 1, 0, 1, 0, 1, 0]
ltac_4_3__independent_counts = Refl

--@derives [LTAC.4.3]
--@derives [LTAC.4.2]
||| AND BOTH TIMERS ARE GONE, the triggers alone remaining. Computed.
export
ltac_4_3__both_gone :
  ewm (ncore (nengine (lfst_9_2_1__after_clocked ltac_4_3__program ltim_2_5_1__no_ttl ltac_4_3__timed 10 ltac_4_3__inputs
                                                 (rdsc_4a_5__load_clocked ltac_4_3__alphas ltac_4_3__rules 0))))
    = [MkFact 0 1 1 2, MkFact 2 1 2 4]
ltac_4_3__both_gone = Refl

-- ---------------------------------------------------------------------
-- Executed: two timers due on one tick
-- ---------------------------------------------------------------------

--@spec [LTAC.5.4]
||| THE INPUTS: two timers with `fire_at` 2 and 3, then one tick to 5, by
||| which both are due.
public export
ltac_5_4__inputs : List Rarc_5_6_2__input
ltac_5_4__inputs = [Data (Assert 0 1 2), Data (Assert 0 2 3), Tick 5]

--@spec [LTAC.5.4]
||| THE NETWORK AS THE INPUTS LEFT IT, prepared with no run between them:
||| the tick to 5 has re-timed the follow-up and made both matches.
public export
ltac_5_4__ready : Iret_19_3__clocked_net
ltac_5_4__ready =
  rarc_5_6_3__prepared_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed ltac_5_4__inputs
    (rdsc_4a_5__load_clocked ltac_3_4__alphas ltac_3_4__follow_up_rules 0)

--@derives [LTAC.5.4]
--@derives [LDET.5.5]
--@derives [LTIM.2.4.2]
||| BOTH DUE ON ONE TICK: the follow-up holds two activations, one per
||| timer, both unfired, in the order [LDET.5.5] gives matches that
||| complete together -- the earlier-asserted timer first. Computed.
export
ltac_5_4__same_tick_ready :
  rarc_5_6_5__nth 0 (nchains (enet (ncore (nengine ltac_5_4__ready))))
    = Just (MkChain [MkBeta 0 (ltac_3_4__due 5) False [[]] []]
                    [MkAct [MkFact 0 0 1 2] False, MkAct [MkFact 1 0 2 3] False] ltac_4_2__retract_timer)
ltac_5_4__same_tick_ready = Refl

--@derives [LTAC.5.4]
--@derives [LTAC.4.2]
--@derives [IRET.11.3]
||| BOTH FIRE IN THAT TICK: the run fires the follow-up twice, `[0, 0]`,
||| each firing retracting its own timer, and nothing is live after.
||| Executed, with fuel 3.
export
ltac_5_4__same_tick_trace :
  iret_11_4__trace_of_ttl (iret_11_4__run_ttl_net_traced ltac_3_4__program ltim_2_5_1__no_ttl 3 ltac_5_4__ready) = ([0, 0], Quiescent, [])
ltac_5_4__same_tick_trace = Refl

--@derives [LTAC.5.4]
--@derives [LTAC.5.1]
||| AND COUNTED PER PUMP: nothing at either assertion, two at the tick,
||| `[0, 0, 2]`. Executed.
export
ltac_5_4__same_tick_counts :
  iret_19_5__counts_clocked ltac_3_4__program ltim_2_5_1__no_ttl ltac_3_4__timed 10 ltac_5_4__inputs
    (rdsc_4a_5__load_clocked ltac_3_4__alphas ltac_3_4__follow_up_rules 0) = [0, 0, 2]
ltac_5_4__same_tick_counts = Refl

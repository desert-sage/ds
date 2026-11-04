-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE WALL CLOCK ON THE IDRIS MODEL'S ENGINE: `now()` as a re-timed join test
||| that reads the wall sample, and the WALL STEP that moves the wall sample
||| alone ([LTIM.2.8.3], [LTIM.2.1.1], [LTIM.2.1.2], [NTST.3.1], [LTIM.2.8.2],
||| [LTIM.2.4.3], [LTIM.2.5.1], [LTIM.2.5.2], [LTIM.2.5.3], [LDET.5.8],
||| [LLOG.3.11.1], [IRET.12.2], [IRET.19.5]).
|||
||| NORMATIVE COMPANION to Rete/NetworkTimed.idr, whose engine this file
||| runs with its wall sample moved, and to Rete/NetworkTwoClocks.idr, whose
||| C2 (the wall clock moves no monotonic gate) and C3b (a gate on the wall
||| clock can reopen) it carries onto the Idris model's engine.
|||
||| WHAT IS MODELLED. Rete/NetworkTimed.idr already reads the wall sample:
||| `now()` is the clock leaf `ReadNow`, substituted under the state's sample
||| by `ltim_2_4_1__at_sample` with the wall component, and a `where` that
||| reads it is given the GENERAL timed test `ltim_2_4_1__test_of`, which
||| the pump's entry re-time fixes at the held wall ([LTIM.2.4.3],
||| `ltim_2_4_1__tests_at`). What that file held still is the wall sample:
||| the tick moved the monotonic clock alone and nothing moved the wall. This
||| file adds THE WALL STEP (`ltim_2_8_3__wall_set_timed`): the wall sample
||| set to any instant, earlier or later, the clocked net, the stamps and the
||| trackers standing -- [NTST.3.1]'s `ds_engine_wall_clock_set`, and the
||| wall half of an advance, which [LTIM.2.1.2] and [NTST.3.1] say moves both
||| clocks by one duration (the fixture lowering writes an advance as a tick
||| then a wall step, with no pump between). A fixture's steps with the wall
||| (`Ltim_2_8_3__step`, `ltim_2_8_3__run_steps_wall`) are
||| Rete/NetworkTimed.idr's steps and the wall step; with no wall step they
||| are that file's run (`ltim_2_8_3__no_wall_step_is_the_timed_run`).
|||
||| PROVED, each over every program, state, test list, stamp table and
||| tracker table.
|||
|||   * THE WALL STEP MOVES THE WALL ALONE: the gated state under the timed
|||     state -- the net, the clock, the deadlines, the rows, the trackers --
|||     and the stamps are what they were (`ltim_2_8_3__wall_set_projects`,
|||     `ltim_2_8_3__wall_set_keeps_stamps`); the wall sample is the one set
|||     (`ltim_2_8_3__wall_set_sets_the_wall`). Transcriptions, said so.
|||   * C2 ON THIS ENGINE (`ltim_2_8_2__wall_step_moves_no_monotonic_pump`):
|||     with every timed test a monotonic gate over the state's stamps, the
|||     pump after a wall step and the pump without it leave one gated state,
|||     one halt and one trace; the wall sample alone differs. The entry
|||     re-time at two wall samples is one net
|||     (Rete/NetworkTwoClocks.idr's `iret_19_5__retime_clocked_wall`), and
|||     the run projects to Rete/NetworkCooldown.idr's gated run from the
|||     projected state (Rete/NetworkTimed.idr's `ltim_2_4_2__run_timed_projects`),
|||     which reads no wall. [LTIM.2.8.2]'s "a change to the wall clock
|||     therefore moves none of them", for `dwell` and `within` as the Idris model
|||     lowers them: the runner's monotonic form of every `where` with no
|||     `now()` inhabits the hypothesis (`ltim_2_8_2__one_mono_test_monotonic`,
|||     from Rete/NetworkTimed.idr's `ltim_2_8_2__mono_test_of_monotonic`).
|||   * A `now()` TEST IS NOT A MONOTONIC GATE
|||     (`ltim_2_8_3__now_test_is_not_monotonic`): the one-rule test
|||     `now() == 1` answers `true` at the sample `(0, 1)` and `false` at
|||     `(0, 2)`, so C2's hypothesis is not inhabited by a `where` that reads
|||     the wall, and nothing here says a wall step leaves such a rule alone.
|||     What [LTIM.2.8.3]'s second paragraph allows, and C3b executes.
|||   * EXECUTED, `Refl` through the loader, the stamps, the wall steps and
|||     the gated pump, the fixtures' shapes: a `now()` gate against a fixed
|||     instant shuts when the wall clock steps back across it and reopens
|||     when it steps forward, firing once per opening
|||     (`ltim_2_8_3__wall_gate_reopens_timed`, [LTIM.2.8.3], [LTIM.2.5.1]);
|||     the clause's `late` fires once in the third pump and not in the fourth
|||     (`ldet_5_8__late_fires_once_timed`, [LDET.5.8]), nor on two further
|||     ticks with the gate open (`ltim_2_5_1__now_edge_once_multipump_timed`),
|||     nor after an unrelated assert (`ltim_2_5_1__unrelated_change_timed`),
|||     and the tick is not counted (`ldet_5_8__tick_is_not_counted_timed`);
|||     the window `(now() > 0 and now() < 2) or now() > 2` over an advancing
|||     wall fires at 1 and 3 (`ltim_2_5_1__window_second_edge_refires_timed`),
|||     and on a fact that expired while it was shut fires at 1 alone
|||     (`ltim_2_5_1__expired_fact_cannot_reopen_timed`); a retract and a fresh
|||     assert re-arm the edge (`ltim_2_5_2__now_edge_once_rearm_timed`,
|||     [LTIM.2.5.2]); a `now()` condition true at the assert fires on the
|||     next pump and once (`ltim_2_5_3__true_at_assert_fires_once_timed`);
|||     `now()` tracks the advancing clock (`ltim_2_1_1__now_tracks_the_clock_timed`);
|||     a `logical` fact justified by a `now()` match is retracted at the first
|||     pump whose sample refuses the match, its matched fact unchanged
|||     (`llog_3_11_1__clock_where_retracts_timed`, [LLOG.3.11.1]); a fired
|||     `now()` match whose fact a withdraw removes before a later pump loses
|||     its justification, and the fact it justified is gone before a rule
|||     that joins it can fire (`iret_12_2__queued_successor_removed_timed`,
|||     [IRET.12.2]); and a `dwell` gate under two backward and forward wall
|||     steps fires once, when the monotonic clock reaches it
|||     (`ltim_2_8_2__wall_steps_move_no_dwell_timed`, [LTIM.2.8.2]).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. Everything
||| Rete/NetworkTimed.idr relies on: the stamps covering every live fact, the
||| lowered comparison's value on Integer literals (run, not proved), the one
||| timed test per single-positive-pattern chain, the sweep's placement.
||| The wall sample is a `Nat` the fixture lowering carries
||| in nanoseconds unmapped: the model compares it through the evaluator's
||| Integer arithmetic alone and never through the structural `Nat` order the
||| monotonic clock is mapped for (the lowering's TIME MAP), which is why the
||| lowering may. A wall clock with no value ([LTIM.2.8.3]'s third paragraph)
||| is outside the fragment: the lowering refuses a fixture whose wall clock
||| is unset, and the wall sample here is always a value. The witnesses'
||| instants are small naturals in the sample's own units; the lowering's are
||| nanoseconds since the epoch, folded from `calendar.time` by the lowering
||| (glue), and the comparison is the same Integer order.
module Rete.NetworkWall

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
import Rete.NetworkTwoClocks
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
-- The wall step [LTIM.2.8.3], [NTST.3.1]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.3]
--@spec [NTST.3.1]
--@spec [LTIM.2.1.2]
||| THE WALL STEP: the wall sample set alone, to any instant, earlier or
||| later; the clocked net, the stamps and the trackers stand. [NTST.3.1]'s
||| `ds_engine_wall_clock_set` on this engine, and the half of an advance
||| that moves the wall ([LTIM.2.1.2]: an advance moves both clocks by one
||| duration, which the fixture lowering writes as a tick then a wall step).
||| Not a sample ([NTST.3.3]): the next pump reads what it left.
public export
ltim_2_8_3__wall_set_timed : Nat -> Ltim_2_4_1__timed_state -> Ltim_2_4_1__timed_state
ltim_2_8_3__wall_set_timed w (MkSampled net _ st, trk) = (MkSampled net w st, trk)

--@derives [LTIM.2.8.3]
--@derives [NTST.3.1]
||| THE WALL STEP PROJECTS TO THE IDENTITY: the gated state under the timed
||| state -- the clocked net with its clock, deadlines and rows, and the
||| trackers -- is what it was. A TRANSCRIPTION of the definition, said so:
||| it fails if the step is changed to touch the net or the trackers and
||| refutes nothing else.
export
ltim_2_8_3__wall_set_projects : (w : Nat) -> (s : Ltim_2_4_1__timed_state) ->
                                ltim_2_4_1__proj (ltim_2_8_3__wall_set_timed w s) = ltim_2_4_1__proj s
ltim_2_8_3__wall_set_projects w (MkSampled net w0 st, trk) = Refl

--@derives [LTIM.2.8.3]
--@derives [LTIM.2.8.6]
||| THE WALL STEP KEEPS THE STAMPS: `dwell` measures from the entry stamp,
||| and a wall step enters no fact. A transcription.
export
ltim_2_8_3__wall_set_keeps_stamps : (w : Nat) -> (s : Ltim_2_4_1__timed_state) ->
                                    sstamps (fst (ltim_2_8_3__wall_set_timed w s)) = sstamps (fst s)
ltim_2_8_3__wall_set_keeps_stamps w (MkSampled net w0 st, trk) = Refl

--@derives [LTIM.2.8.3]
--@derives [NTST.3.1]
||| AND SETS THE WALL: to the instant named, whatever it was. A
||| transcription.
export
ltim_2_8_3__wall_set_sets_the_wall : (w : Nat) -> (s : Ltim_2_4_1__timed_state) ->
                                     swall (fst (ltim_2_8_3__wall_set_timed w s)) = w
ltim_2_8_3__wall_set_sets_the_wall w (MkSampled net w0 st, trk) = Refl

-- ---------------------------------------------------------------------
-- A fixture's steps with the wall [RARC.5.6.1], [NTST.3.1]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.3]
--@spec [NTST.3.1]
--@spec [RARC.5.6.1]
||| A FIXTURE'S STEP WITH THE WALL: a wall step -- the wall clock jumping
||| forward or moving backward between two samples ([LTIM.2.8.3]) -- or one
||| of Rete/NetworkTimed.idr's: a tick, a data input, a pump. [NTST.3.1]'s
||| three mutations are a tick (a set of the monotonic clock), a tick then a
||| wall step (an advance of both) and a wall step (a set of the wall alone).
public export
data Ltim_2_8_3__step : Type where
  SWall : Nat -> Ltim_2_8_3__step
  SStep : Rarc_5_6_2__step -> Ltim_2_8_3__step

--@spec [NTST.3.1]
--@spec [RARC.5.6.1]
--@spec [LTIM.2.8.3]
||| A FIXTURE'S STEPS on the timed engine with the wall, in its cadence: a
||| wall step moves the wall sample; every other step is
||| Rete/NetworkTimed.idr's; the verdicts of every pump, one list per pump,
||| in order.
public export
ltim_2_8_3__run_steps_wall : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) -> List Ltim_2_8_3__step ->
                             Ltim_2_4_1__timed_state -> (Ltim_2_4_1__timed_state, List (List (Nat, Bool)))
ltim_2_8_3__run_steps_wall pg ttl cools tests [] s = (s, [])
ltim_2_8_3__run_steps_wall pg ttl cools tests (SWall w :: ss) s =
  ltim_2_8_3__run_steps_wall pg ttl cools tests ss (ltim_2_8_3__wall_set_timed w s)
ltim_2_8_3__run_steps_wall pg ttl cools tests (SStep (SInput (Tick t)) :: ss) s =
  ltim_2_8_3__run_steps_wall pg ttl cools tests ss (ltim_2_8_4__tick_timed pg ttl t s)
ltim_2_8_3__run_steps_wall pg ttl cools tests (SStep (SInput (Data ev)) :: ss) s =
  ltim_2_8_3__run_steps_wall pg ttl cools tests ss (ltim_2_8_6__input_timed pg ttl ev s)
ltim_2_8_3__run_steps_wall pg ttl cools tests (SStep (SPumpT fuel) :: ss) s = case ltim_2_4_2__pump_timed pg ttl cools tests fuel s of
  (s', h, tr) => case ltim_2_8_3__run_steps_wall pg ttl cools tests ss s' of
    (s'', vs) => (s'', lcdb_3_2_1__verdicts tr :: vs)

--@derives [LTIM.2.8.3]
--@derives [NTST.3.1]
--@derives [RARC.5.6.1]
||| WITH NO WALL STEP THE RUN IS Rete/NetworkTimed.idr's: step for step,
||| verdict for verdict, the wall sample never moved. By induction on the
||| steps.
export
ltim_2_8_3__no_wall_step_is_the_timed_run : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                                            (tests : List (Maybe Ltim_2_4_1__ttest)) -> (steps : List Rarc_5_6_2__step) -> (s : Ltim_2_4_1__timed_state) ->
                                            ltim_2_8_3__run_steps_wall pg ttl cools tests (map SStep steps) s = ltim_2_4_1__run_steps_timed pg ttl cools tests steps s
ltim_2_8_3__no_wall_step_is_the_timed_run pg ttl cools tests [] s = Refl
ltim_2_8_3__no_wall_step_is_the_timed_run pg ttl cools tests (SInput (Tick t) :: ss) s =
  ltim_2_8_3__no_wall_step_is_the_timed_run pg ttl cools tests ss (ltim_2_8_4__tick_timed pg ttl t s)
ltim_2_8_3__no_wall_step_is_the_timed_run pg ttl cools tests (SInput (Data ev) :: ss) s =
  ltim_2_8_3__no_wall_step_is_the_timed_run pg ttl cools tests ss (ltim_2_8_6__input_timed pg ttl ev s)
ltim_2_8_3__no_wall_step_is_the_timed_run pg ttl cools tests (SPumpT fuel :: ss) s with (ltim_2_4_2__pump_timed pg ttl cools tests fuel s)
  ltim_2_8_3__no_wall_step_is_the_timed_run pg ttl cools tests (SPumpT fuel :: ss) s | (s', h, tr)
    with (ltim_2_4_1__run_steps_timed pg ttl cools tests ss s') proof rr
    ltim_2_8_3__no_wall_step_is_the_timed_run pg ttl cools tests (SPumpT fuel :: ss) s | (s', h, tr) | (s'', vs) =
      -- The two lifted case blocks over the recursive call are not
      -- convertible on an abstract scrutinee (IDRIS_MODEL_GUIDE: two loops
      -- of one shape); the call's result is matched to its tuple and the
      -- induction hypothesis rewritten through it.
      rewrite trans (ltim_2_8_3__no_wall_step_is_the_timed_run pg ttl cools tests ss s') rr in Refl

-- ---------------------------------------------------------------------
-- C2 on this engine: a wall step moves no monotonic `where` [LTIM.2.8.2]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.3]
||| A pump's result with its state projected: the gated state, the halt and
||| the trace. By a triple pattern, so that it reduces on a named result.
public export
ltim_2_8_3__pump_proj : (Ltim_2_4_1__timed_state, Iret_11_4__halt, List (Nat, Iret_7_1__token, Bool)) ->
                        (Lcdb_3_2_1__gated_state, Iret_11_4__halt, List (Nat, Iret_7_1__token, Bool))
ltim_2_8_3__pump_proj (s, h, tr) = (ltim_2_4_1__proj s, h, tr)

--@derives [LTIM.2.8.2]
||| THE RUNNER'S MONOTONIC TEST INHABITS C2'S HYPOTHESIS: the one-rule test
||| list of a `where` with no `now()`, built in Rete/NetworkTimed.idr's
||| monotonic form, is monotonic at every stamp table.
export
ltim_2_8_2__one_mono_test_monotonic : (env : Iret_7_6__env) -> (e : Iret_7_5__expr) -> (st : Ltim_2_8_6__stamps) ->
                                      Ltim_2_8_2__monotonic_all (ltim_2_4_1__tests_fn [Just (ltim_2_8_2__mono_test_of env e)] st)
ltim_2_8_2__one_mono_test_monotonic env e st = (ltim_2_8_2__mono_test_of_monotonic env e st, ())

--@derives [LTIM.2.8.2]
--@derives [LTIM.2.8.3]
--@derives [NTST.3.1]
--@derives [IRET.19.5]
||| C2 ON THIS ENGINE. A WALL STEP MOVES NO FIRING OF A MONOTONIC `where`:
||| with every timed test a monotonic gate over the state's stamps, the pump
||| after a wall step to any instant and the pump without it leave one gated
||| state -- the net, the clock, the deadlines, the rows, the trackers --
||| one halt and one trace; the wall sample alone differs. The entry re-time
||| at the two wall samples is one net
||| (Rete/NetworkTwoClocks.idr's `iret_19_5__retime_clocked_wall`), and the
||| run from it projects to Rete/NetworkCooldown.idr's gated run from the
||| projected state, which carries no wall
||| (Rete/NetworkTimed.idr's `ltim_2_4_2__run_timed_projects`). [LTIM.2.8.2]'s
||| "a change to the wall clock therefore moves none of them", for `dwell`
||| and `within` as the Idris model lowers them, on the engine the Idris model runs.
export
ltim_2_8_2__wall_step_moves_no_monotonic_pump :
  (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (tests : List (Maybe Ltim_2_4_1__ttest)) -> (fuel : Nat) ->
  (net : Iret_19_3__clocked_net) -> (w, w' : Nat) -> (st : Ltim_2_8_6__stamps) -> (trk : Iret_10_4__trackers) ->
  Ltim_2_8_2__monotonic_all (ltim_2_4_1__tests_fn tests st) ->
  ltim_2_8_3__pump_proj (ltim_2_4_2__pump_timed pg ttl cools tests fuel (MkSampled net w st, trk))
    = ltim_2_8_3__pump_proj (ltim_2_4_2__pump_timed pg ttl cools tests fuel (ltim_2_8_3__wall_set_timed w' (MkSampled net w st, trk)))
ltim_2_8_2__wall_step_moves_no_monotonic_pump pg ttl cools tests fuel (MkClockedNet (MkTmsNet eng rows) dl c) w w' st trk mos =
  let netEq = the (iret_19_5__retime_clocked pg (ltim_2_4_1__tests_at w st tests) (MkClockedNet (MkTmsNet eng rows) dl c)
                   = iret_19_5__retime_clocked pg (ltim_2_4_1__tests_at w' st tests) (MkClockedNet (MkTmsNet eng rows) dl c))
                  (iret_19_5__retime_clocked_wall pg (ltim_2_4_1__tests_fn tests st) w w' eng rows dl c mos)
      (s1 ** (h1 ** (tr1 ** (rE1, gE1)))) = ltim_2_4_2__run_timed_projects pg ttl cools fuel
                                               (MkSampled (iret_19_5__retime_clocked pg (ltim_2_4_1__tests_at w st tests) (MkClockedNet (MkTmsNet eng rows) dl c)) w st, trk)
      (s2 ** (h2 ** (tr2 ** (rE2, gE2)))) = ltim_2_4_2__run_timed_projects pg ttl cools fuel
                                               (MkSampled (iret_19_5__retime_clocked pg (ltim_2_4_1__tests_at w' st tests) (MkClockedNet (MkTmsNet eng rows) dl c)) w' st, trk)
      gEq = the (lcdb_3_2_1__run_gated_traced pg ttl cools fuel (iret_19_5__retime_clocked pg (ltim_2_4_1__tests_at w st tests) (MkClockedNet (MkTmsNet eng rows) dl c), trk)
                 = lcdb_3_2_1__run_gated_traced pg ttl cools fuel (iret_19_5__retime_clocked pg (ltim_2_4_1__tests_at w' st tests) (MkClockedNet (MkTmsNet eng rows) dl c), trk))
                (cong (\n => lcdb_3_2_1__run_gated_traced pg ttl cools fuel (n, trk)) netEq)
  in trans (cong ltim_2_8_3__pump_proj rE1)
           (trans (sym gE1) (trans gEq (trans gE2 (sym (cong ltim_2_8_3__pump_proj rE2)))))

-- ---------------------------------------------------------------------
-- `now()`: the leaf, and a test on it is not monotonic [LTIM.2.8.3]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.3]
--@spec [LTIM.2.1.1]
||| `now()` in a `where`: the clock leaf that reads the wall sample.
public export
ltim_2_8_3__now_leaf : Iret_7_5__expr
ltim_2_8_3__now_leaf = EClock ReadNow

--@derives [LTIM.2.8.3]
--@derives [LTIM.2.1.1]
||| THE `now()` LEAF READS THE WALL SAMPLE: under any sample, stamp table
||| and token, the substitution replaces it by the wall component as an
||| Int. 'It drives `now()`'; `now()` 'returns the wall-clock UTC instant'
||| from 'the wall clock's current sample'. A TRANSCRIPTION of
||| Rete/NetworkTimed.idr's `ltim_2_4_1__read_at`'s first clause, said so: it
||| fails if the leaf is changed to read the monotonic sample or a stamp and
||| refutes nothing else.
export
ltim_2_8_3__now_leaf_reads_the_wall : (m, w : Nat) -> (st : Ltim_2_8_6__stamps) -> (fs : List Lfac_1_7_1__fact) ->
                                      ltim_2_4_1__at_sample (m, w) st fs ltim_2_8_3__now_leaf = ELit (VInt (cast w))
ltim_2_8_3__now_leaf_reads_the_wall m w st fs = Refl

--@spec [LTIM.2.8.3]
--@spec [LTIM.2.5.1]
||| `now() == 1`: a gate on the wall clock against a fixed instant,
||| logical/LTIM.2.8.3_wall_gate_reopens's `at_one` in the witnesses' units.
public export
ltim_2_8_3__at_one : Iret_7_5__expr
ltim_2_8_3__at_one = ECmp OpEq ltim_2_8_3__now_leaf (ELit (VInt 1))

--@spec [LTIM.2.8.3]
||| The one Ping the wall witnesses match: kind 0, key 1, no payload.
public export
ltim_2_8_3__ping : Lfac_1_7_1__fact
ltim_2_8_3__ping = MkFact 0 0 1 0

--@derives [LTIM.2.8.3]
--@derives [LTIM.2.8.2]
||| A `now()` TEST IS NOT A MONOTONIC GATE: the timed test of `now() == 1`
||| admits the Ping at the sample `(0, 1)` and refuses it at `(0, 2)`, so
||| no proof that it answers alike at two wall samples exists. C2's
||| hypothesis is not inhabited by a `where` that reads the wall, and
||| nothing in this file says a wall step leaves such a rule alone: what
||| [LTIM.2.8.3]'s second paragraph allows and `wall_gate_reopens_timed`
||| executes. The two answers are computed.
export
ltim_2_8_3__now_test_is_not_monotonic : Not (Ltim_2_8_2__monotonic (ltim_2_4_1__test_of ltim_2_4_1__wenv ltim_2_8_3__at_one []))
ltim_2_8_3__now_test_is_not_monotonic mo =
  let open1 = the (ltim_2_4_1__test_of ltim_2_4_1__wenv ltim_2_8_3__at_one [] (0, 1) [] ltim_2_8_3__ping = True) Refl
      shut2 = the (ltim_2_4_1__test_of ltim_2_4_1__wenv ltim_2_8_3__at_one [] (0, 2) [] ltim_2_8_3__ping = False) Refl
  in absurd (trans (sym open1) (trans (cong (\j => j [] ltim_2_8_3__ping) (mo 0 1 2)) shut2))

-- ---------------------------------------------------------------------
-- Executed: the fixtures' shapes on this engine
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.3]
||| THE VERDICTS OF A SCHEDULE WITH THE WALL from the loaded network: one
||| list per pump.
public export
ltim_2_8_3__verdicts_of : (Nat -> Lscp_1_3__lifecycle) -> Iret_4_2__ttl -> List (Nat, Lfac_1_7_1__fact -> Bool) ->
                          List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) ->
                          List Ltim_2_8_3__step -> List (List (Nat, Bool))
ltim_2_8_3__verdicts_of life ttl alphas rules cools tests steps =
  snd (ltim_2_8_3__run_steps_wall (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ttl cools tests steps (ltim_2_4_1__loaded alphas rules))

--@spec [LTIM.2.8.3]
||| THE WORKING MEMORY after a schedule with the wall from the loaded
||| network.
public export
ltim_2_8_3__wm_after : (Nat -> Lscp_1_3__lifecycle) -> Iret_4_2__ttl -> List (Nat, Lfac_1_7_1__fact -> Bool) ->
                       List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) ->
                       List Ltim_2_8_3__step -> Rarc_5_6_4__wm
ltim_2_8_3__wm_after life ttl alphas rules cools tests steps =
  ewm (ncore (nengine (ltim_2_4_1__net_of (fst (ltim_2_8_3__run_steps_wall (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ttl cools tests steps (ltim_2_4_1__loaded alphas rules))))))

--@spec [NTST.3.1]
--@spec [LTIM.2.1.2]
||| AN ADVANCE to `t`, from clocks that started together: a tick to `t`
||| then a wall step to `t`. 'An advance also moves the wall clock by the
||| same duration.'
public export
ntst_3_1__advance : Nat -> List Ltim_2_8_3__step
ntst_3_1__advance t = [SStep (SInput (Tick t)), SWall t]

--@spec [NTST.3.1]
||| The data steps, named: an assert of the Ping, a pump of fuel 3, a
||| retract by id.
public export
ntst_3_1__assert_ping : Ltim_2_8_3__step
ntst_3_1__assert_ping = SStep (SInput (Data (Assert 0 1 0)))

--@spec [NTST.3.1]
public export
ntst_3_1__pump : Ltim_2_8_3__step
ntst_3_1__pump = SStep (SPumpT 3)

--@derives [LTIM.2.8.3]
--@derives [LTIM.2.5.1]
--@derives [LTIM.2.4.3]
||| C3b ON THIS ENGINE. A GATE ON THE WALL CLOCK CAN REOPEN: the Ping
||| asserted at (0, 0) under `now() == 1`; an advance to 1 and a pump fire;
||| an advance to 2 and a pump find the gate shut, which ends the match; a
||| tick to 3 with the wall stepped BACK to 1 and a pump find it open again,
||| a new match, and fire; an advance to 4 and a pump fire nothing --
||| logical/LTIM.2.8.3_wall_gate_reopens's shape, Rete/NetworkTwoClocks.idr's
||| `ltim_2_8_3__wall_gate_reopens` on the Idris model's engine, through its wall
||| steps. Executed: `[[(0, True)], [], [(0, True)], []]`.
export
ltim_2_8_3__wall_gate_reopens_timed :
  ltim_2_8_3__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ltim_2_8_3__at_one) [Nothing]
    (ltim_2_4_1__one_timed_tests ltim_2_8_3__at_one)
    ( [ntst_3_1__assert_ping] ++ ntst_3_1__advance 1 ++ [ntst_3_1__pump] ++ ntst_3_1__advance 2 ++ [ntst_3_1__pump]
      ++ [SStep (SInput (Tick 3)), SWall 1, ntst_3_1__pump] ++ ntst_3_1__advance 4 ++ [ntst_3_1__pump] )
    = [[(0, True)], [], [(0, True)], []]
ltim_2_8_3__wall_gate_reopens_timed = Refl

--@spec [LDET.5.8]
--@spec [LTIM.2.8.3]
||| THE CLAUSE'S `late`: `now() > 5`, in the witnesses' units.
public export
ldet_5_8__late_gate : Iret_7_5__expr
ldet_5_8__late_gate = ECmp OpGt ltim_2_8_3__now_leaf (ELit (VInt 5))

--@derives [LDET.5.8]
--@derives [LTIM.2.5.1]
||| THE CLAUSE'S OBSERVABLE ON THE IDRIS MODEL'S ENGINE: assert one Ping, pump
||| twice with the gate shut, advance both clocks past it, pump twice more.
||| `late` fires exactly once, in the third pump, and not in the fourth --
||| logical/LDET.5.8_late_fires_once's shape, with the wall the advance
||| moved. Executed: `[[], [], [(0, True)], []]`.
export
ldet_5_8__late_fires_once_timed :
  ltim_2_8_3__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ldet_5_8__late_gate) [Nothing]
    (ltim_2_4_1__one_timed_tests ldet_5_8__late_gate)
    ([ntst_3_1__assert_ping, ntst_3_1__pump, ntst_3_1__pump] ++ ntst_3_1__advance 6 ++ [ntst_3_1__pump, ntst_3_1__pump])
    = [[], [], [(0, True)], []]
ldet_5_8__late_fires_once_timed = Refl

--@derives [LDET.5.8]
||| AND THE TICK IS NOT COUNTED: after the Ping, a pump, an advance to 6
||| and two pumps, working memory holds the Ping alone --
||| temporal/LDET.5.8_tick_is_not_counted's shape. Executed.
export
ldet_5_8__tick_is_not_counted_timed :
  ltim_2_8_3__wm_after lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ldet_5_8__late_gate) [Nothing]
    (ltim_2_4_1__one_timed_tests ldet_5_8__late_gate)
    ([ntst_3_1__assert_ping, ntst_3_1__pump] ++ ntst_3_1__advance 6 ++ [ntst_3_1__pump, ntst_3_1__pump])
    = [ltim_2_8_3__ping]
ldet_5_8__tick_is_not_counted_timed = Refl

--@derives [LTIM.2.1.1]
--@derives [LTIM.2.1.2]
||| `now()` TRACKS THE CLOCK THE HARNESS MOVES: the Ping under `now() > 5`
||| is not fired at (0, 0) and is fired after an advance to 6 --
||| logical/LTIM.2.1's shape: 'the runtime must drive `now()` from the
||| engine's wall clock', which `clock_advance` moves. Executed:
||| `[[], [(0, True)]]`.
export
ltim_2_1_1__now_tracks_the_clock_timed :
  ltim_2_8_3__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ldet_5_8__late_gate) [Nothing]
    (ltim_2_4_1__one_timed_tests ldet_5_8__late_gate)
    ([ntst_3_1__assert_ping, ntst_3_1__pump] ++ ntst_3_1__advance 6 ++ [ntst_3_1__pump])
    = [[], [(0, True)]]
ltim_2_1_1__now_tracks_the_clock_timed = Refl

--@derives [LTIM.2.5.1]
--@derives [LDET.5.8]
||| EDGE-ONCE OVER FURTHER TICKS: after the gate opens at 6 and fires, the
||| advances to 7 and 8 with the gate still true fire nothing --
||| logical/LTIM.2.5_now_edge_once_multipump's shape. 'Must not re-fire on
||| subsequent ticks while the condition remains true.' Executed:
||| `[[], [(0, True)], [], []]`.
export
ltim_2_5_1__now_edge_once_multipump_timed :
  ltim_2_8_3__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ldet_5_8__late_gate) [Nothing]
    (ltim_2_4_1__one_timed_tests ldet_5_8__late_gate)
    ([ntst_3_1__assert_ping, ntst_3_1__pump] ++ ntst_3_1__advance 6 ++ [ntst_3_1__pump] ++ ntst_3_1__advance 7 ++ [ntst_3_1__pump]
      ++ ntst_3_1__advance 8 ++ [ntst_3_1__pump])
    = [[], [(0, True)], [], []]
ltim_2_5_1__now_edge_once_multipump_timed = Refl

--@spec [LTIM.2.5.1]
||| Two alphas, the Sensor's kind 0 and an unrelated Other's kind 1.
public export
ltim_2_5_1__alphas_two : List (Nat, Lfac_1_7_1__fact -> Bool)
ltim_2_5_1__alphas_two = [(0, lcdb_3_2_1__admits_all), (1, lcdb_3_2_1__admits_all)]

--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| AN UNRELATED CHANGE BETWEEN TICKS CLEARS NO REFRACTION: the gate opens
||| at 6 and fires; a fact the rule never matches is asserted and pumped;
||| the clock advances to 7 with the gate open; nothing fires again --
||| logical/LTIM.2.5.1.unrelated_change_between_ticks's shape, on the flag
||| reading. Executed: `[[], [(0, True)], [], []]`.
export
ltim_2_5_1__unrelated_change_timed :
  ltim_2_8_3__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl ltim_2_5_1__alphas_two (ltim_2_4_1__one_timed_rule ldet_5_8__late_gate) [Nothing]
    (ltim_2_4_1__one_timed_tests ldet_5_8__late_gate)
    ([ntst_3_1__assert_ping, ntst_3_1__pump] ++ ntst_3_1__advance 6 ++ [ntst_3_1__pump, SStep (SInput (Data (Assert 1 1 0))), ntst_3_1__pump]
      ++ ntst_3_1__advance 7 ++ [ntst_3_1__pump])
    = [[], [(0, True)], [], []]
ltim_2_5_1__unrelated_change_timed = Refl

--@derives [LTIM.2.5.2]
--@derives [LTIM.2.5.1]
||| THE EDGE RE-ARMS ON A NEW WRAPPER: the gate opens at 6 and fires once;
||| a second pump fires nothing; the Sensor is retracted and asserted again,
||| a new wrapper, which fires once more and then not again --
||| logical/LTIM.2.5.2_now_edge_once_rearm's shape. 'A retracted fact that
||| later re-matches likewise re-arms (new wrapper).' Executed:
||| `[[(0, True)], [], [(0, True)], []]`.
export
ltim_2_5_2__now_edge_once_rearm_timed :
  ltim_2_8_3__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ldet_5_8__late_gate) [Nothing]
    (ltim_2_4_1__one_timed_tests ldet_5_8__late_gate)
    ([ntst_3_1__assert_ping] ++ ntst_3_1__advance 6 ++ [ntst_3_1__pump, ntst_3_1__pump, SStep (SInput (Data (Retract 0))), ntst_3_1__assert_ping, ntst_3_1__pump, ntst_3_1__pump])
    = [[(0, True)], [], [(0, True)], []]
ltim_2_5_2__now_edge_once_rearm_timed = Refl

--@derives [LTIM.2.5.3]
--@derives [LTIM.2.4.3]
||| TRUE AT THE ASSERT, IT FIRES ON THE NEXT PUMP AND ONCE: both clocks
||| advanced to 6 and a pump with no fact; the Ping asserted with the gate
||| already open; an advance to 7 and a pump fire it; an advance to 8 and a
||| pump fire nothing -- logical/LTIM.2.5.3_true_at_assert_fires_once's
||| shape. The firing is the activation the assert made, which the tick
||| from 6 to 7 finds open and leaves. Executed: `[[], [(0, True)], []]`.
export
ltim_2_5_3__true_at_assert_fires_once_timed :
  ltim_2_8_3__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ldet_5_8__late_gate) [Nothing]
    (ltim_2_4_1__one_timed_tests ldet_5_8__late_gate)
    (ntst_3_1__advance 6 ++ [ntst_3_1__pump, ntst_3_1__assert_ping] ++ ntst_3_1__advance 7 ++ [ntst_3_1__pump] ++ ntst_3_1__advance 8 ++ [ntst_3_1__pump])
    = [[], [(0, True)], []]
ltim_2_5_3__true_at_assert_fires_once_timed = Refl

--@spec [LTIM.2.5.1]
--@spec [LTIM.2.8.3]
||| THE WINDOW on the wall clock: `(now() > 0 and now() < 2) or now() > 2`,
||| the witnesses' window of [LTIM.2.5.1] in their units.
public export
ltim_2_5_1__now_window : Iret_7_5__expr
ltim_2_5_1__now_window = EOr (EAnd (ECmp OpGt ltim_2_8_3__now_leaf (ELit (VInt 0))) (ECmp OpLt ltim_2_8_3__now_leaf (ELit (VInt 2))))
                             (ECmp OpGt ltim_2_8_3__now_leaf (ELit (VInt 2)))

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.8.3]
||| A WINDOW THAT SHUTS AND REOPENS FIRES ONCE PER OPENING: the Ping
||| asserted at (0, 0); advances to 1, 2, 3 and 4, each followed by a pump;
||| open at 1, shut at 2 (the match ends), open again at 3 (a new match),
||| still open at 4 -- logical/LTIM.2.5.1_window_second_edge_refires's shape.
||| Executed: `[[(0, True)], [], [(0, True)], []]`.
export
ltim_2_5_1__window_second_edge_refires_timed :
  ltim_2_8_3__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ltim_2_5_1__now_window) [Nothing]
    (ltim_2_4_1__one_timed_tests ltim_2_5_1__now_window)
    ([ntst_3_1__assert_ping] ++ ntst_3_1__advance 1 ++ [ntst_3_1__pump] ++ ntst_3_1__advance 2 ++ [ntst_3_1__pump]
      ++ ntst_3_1__advance 3 ++ [ntst_3_1__pump] ++ ntst_3_1__advance 4 ++ [ntst_3_1__pump])
    = [[(0, True)], [], [(0, True)], []]
ltim_2_5_1__window_second_edge_refires_timed = Refl

--@spec [LTIM.2.5.1]
||| An explicit lifecycle for every kind: the expired-fact fixture's Ping
||| has no key.
public export
ltim_2_5_1__explicit_life : Nat -> Lscp_1_3__lifecycle
ltim_2_5_1__explicit_life _ = Explicit

--@spec [LTIM.2.5.1]
--@spec [IRET.4.2]
||| A default TTL of 2 on every kind.
public export
ltim_2_5_1__ttl_two : Iret_4_2__ttl
ltim_2_5_1__ttl_two _ = 2

--@derives [LTIM.2.5.1]
--@derives [IRET.19.3]
||| AN EXPIRED FACT CANNOT REOPEN: the same window and advances with the
||| Ping under a TTL of 2; open at 1 and fired; the tick to 2 sweeps the
||| Ping, whose deadline is at the clock, before the pump; the window opens
||| at 3 on nothing -- logical/LTIM.2.5.1_expired_fact_cannot_reopen's
||| shape. Executed: `[[(0, True)], [], [], []]`, and working memory empty.
export
ltim_2_5_1__expired_fact_cannot_reopen_timed :
  ( ltim_2_8_3__verdicts_of ltim_2_5_1__explicit_life ltim_2_5_1__ttl_two lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ltim_2_5_1__now_window) [Nothing]
      (ltim_2_4_1__one_timed_tests ltim_2_5_1__now_window)
      ([ntst_3_1__assert_ping] ++ ntst_3_1__advance 1 ++ [ntst_3_1__pump] ++ ntst_3_1__advance 2 ++ [ntst_3_1__pump]
        ++ ntst_3_1__advance 3 ++ [ntst_3_1__pump] ++ ntst_3_1__advance 4 ++ [ntst_3_1__pump])
      = [[(0, True)], [], [], []]
  , ltim_2_8_3__wm_after ltim_2_5_1__explicit_life ltim_2_5_1__ttl_two lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ltim_2_5_1__now_window) [Nothing]
      (ltim_2_4_1__one_timed_tests ltim_2_5_1__now_window)
      ([ntst_3_1__assert_ping] ++ ntst_3_1__advance 1 ++ [ntst_3_1__pump] ++ ntst_3_1__advance 2 ++ [ntst_3_1__pump]
        ++ ntst_3_1__advance 3 ++ [ntst_3_1__pump] ++ ntst_3_1__advance 4 ++ [ntst_3_1__pump])
      = [] )
ltim_2_5_1__expired_fact_cannot_reopen_timed = (Refl, Refl)

--@spec [LLOG.3.11.1]
||| `now() < 2`: the `fresh` gate of the two logical fixtures.
public export
llog_3_11_1__fresh_gate : Iret_7_5__expr
llog_3_11_1__fresh_gate = ECmp OpLt ltim_2_8_3__now_leaf (ELit (VInt 2))

--@spec [LLOG.3.11.1]
||| Every kind a relation: Reading (0), Mark (1) and Fresh (2), each
||| `logical` with one key slot.
public export
llog_3_11_1__relation_life : Nat -> Lscp_1_3__lifecycle
llog_3_11_1__relation_life _ = Relation

--@spec [LLOG.3.11.1]
||| Three alphas, kinds 0 to 2.
public export
llog_3_11_1__alphas_three : List (Nat, Lfac_1_7_1__fact -> Bool)
llog_3_11_1__alphas_three = [(0, lcdb_3_2_1__admits_all), (1, lcdb_3_2_1__admits_all), (2, lcdb_3_2_1__admits_all)]

--@spec [LLOG.3.11.1]
--@spec [LTIM.2.8.3]
||| `fresh`: a Reading under `now() < 2`, emitting Fresh logical.
public export
llog_3_11_1__fresh_rule : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
llog_3_11_1__fresh_rule = [([(0, ltim_2_4_1__test_of ltim_2_4_1__wenv llog_3_11_1__fresh_gate [] (0, 0), False)], [Emit 2 (\_ => (0, 0))])]

--@derives [LLOG.3.11.1]
--@derives [LTIM.2.5.1]
--@derives [LLOG.15.1]
||| A `logical` FACT JUSTIFIED BY A `now()` MATCH IS RETRACTED AT THE FIRST
||| PUMP WHOSE SAMPLE REFUSES THE MATCH, its matched fact unchanged: the
||| Reading at (0, 0) fires `fresh` and Fresh is emitted; an advance to 1, a
||| Mark and a pump leave Fresh standing, the match persisting; an advance
||| to 3, a second Mark and a pump end the match and retract Fresh --
||| logical/LLOG.3.11.1_clock_where_retracts_its_logical_fact's shape.
||| Executed: `[[(0, True)], [], []]`, and working memory after the second
||| pump holds the Reading, Fresh and the Mark, after the third the Reading
||| and the two Marks.
export
llog_3_11_1__clock_where_retracts_timed :
  ( ltim_2_8_3__verdicts_of llog_3_11_1__relation_life lcdb_3_2_1__no_ttl llog_3_11_1__alphas_three llog_3_11_1__fresh_rule [Nothing]
      (ltim_2_4_1__one_timed_tests llog_3_11_1__fresh_gate)
      ([ntst_3_1__assert_ping, ntst_3_1__pump] ++ ntst_3_1__advance 1 ++ [SStep (SInput (Data (Assert 1 1 0))), ntst_3_1__pump]
        ++ ntst_3_1__advance 3 ++ [SStep (SInput (Data (Assert 1 2 0))), ntst_3_1__pump])
      = [[(0, True)], [], []]
  , ltim_2_8_3__wm_after llog_3_11_1__relation_life lcdb_3_2_1__no_ttl llog_3_11_1__alphas_three llog_3_11_1__fresh_rule [Nothing]
      (ltim_2_4_1__one_timed_tests llog_3_11_1__fresh_gate)
      ([ntst_3_1__assert_ping, ntst_3_1__pump] ++ ntst_3_1__advance 1 ++ [SStep (SInput (Data (Assert 1 1 0))), ntst_3_1__pump])
      = [MkFact 0 0 1 0, MkFact 1 2 0 0, MkFact 2 1 1 0]
  , ltim_2_8_3__wm_after llog_3_11_1__relation_life lcdb_3_2_1__no_ttl llog_3_11_1__alphas_three llog_3_11_1__fresh_rule [Nothing]
      (ltim_2_4_1__one_timed_tests llog_3_11_1__fresh_gate)
      ([ntst_3_1__assert_ping, ntst_3_1__pump] ++ ntst_3_1__advance 1 ++ [SStep (SInput (Data (Assert 1 1 0))), ntst_3_1__pump]
        ++ ntst_3_1__advance 3 ++ [SStep (SInput (Data (Assert 1 2 0))), ntst_3_1__pump])
      = [MkFact 0 0 1 0, MkFact 2 1 1 0, MkFact 3 1 2 0] )
llog_3_11_1__clock_where_retracts_timed = (Refl, Refl, Refl)

--@spec [IRET.12.2]
||| The lifecycles of the queued-successor fixture: Reading (0), Kill (1)
||| and Probe (2) explicit, Fresh (3) a relation.
public export
iret_12_2__successor_life : Nat -> Lscp_1_3__lifecycle
iret_12_2__successor_life Z = Explicit
iret_12_2__successor_life (S Z) = Explicit
iret_12_2__successor_life (S (S Z)) = Explicit
iret_12_2__successor_life (S (S (S _))) = Relation

--@spec [IRET.12.2]
||| Four alphas, kinds 0 to 3.
public export
iret_12_2__alphas_four : List (Nat, Lfac_1_7_1__fact -> Bool)
iret_12_2__alphas_four = [(0, lcdb_3_2_1__admits_all), (1, lcdb_3_2_1__admits_all), (2, lcdb_3_2_1__admits_all), (3, lcdb_3_2_1__admits_all)]

--@spec [IRET.12.2]
--@spec [LTIM.2.8.3]
||| The three rules in source order: `kill` (a Kill and a Reading, withdraw
||| the Reading), `fresh` (a Reading under `now() < 2`, emit Fresh logical),
||| `live` (a Fresh and a Probe).
public export
iret_12_2__successor_rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
iret_12_2__successor_rules =
  [ ([(1, lcdb_3_2_1__any_join, False), (0, lcdb_3_2_1__any_join, False)], [Withdraw 1])
  , ([(0, ltim_2_4_1__test_of ltim_2_4_1__wenv llog_3_11_1__fresh_gate [] (0, 0), False)], [Emit 3 (\_ => (0, 0))])
  , ([(3, lcdb_3_2_1__any_join, False), (2, lcdb_3_2_1__any_join, False)], []) ]

--@spec [IRET.12.2]
||| The tests by ordinal: `fresh` alone is timed.
public export
iret_12_2__successor_tests : List (Maybe Ltim_2_4_1__ttest)
iret_12_2__successor_tests = [Nothing, Just (ltim_2_4_1__test_of ltim_2_4_1__wenv llog_3_11_1__fresh_gate), Nothing]

--@derives [IRET.12.2]
--@derives [IRET.19.5]
--@derives [LLOG.15.1]
||| A FIRED `now()` MATCH WHOSE FACT A WITHDRAW REMOVES LOSES ITS
||| JUSTIFICATION: the Reading at (0, 0) fires `fresh`, which emits Fresh;
||| an advance to 1, a Kill and a pump: the re-time keeps `fresh`'s match
||| (the gate is still open), `kill` fires first and withdraws the Reading,
||| the match ends and Fresh is retracted with its one justification; a
||| Probe and a pump: `live`, which joins Fresh with Probe, finds no Fresh
||| and does not fire -- logical/IRET.12.2_queued_successor_removed_withdraws's
||| shape. Executed: `[[(1, True)], [(0, True)], []]`, and working memory
||| ends with the Kill and the Probe.
export
iret_12_2__queued_successor_removed_timed :
  ( ltim_2_8_3__verdicts_of iret_12_2__successor_life lcdb_3_2_1__no_ttl iret_12_2__alphas_four iret_12_2__successor_rules [Nothing, Nothing, Nothing]
      iret_12_2__successor_tests
      ([ntst_3_1__assert_ping, ntst_3_1__pump] ++ ntst_3_1__advance 1 ++ [SStep (SInput (Data (Assert 1 1 0))), ntst_3_1__pump, SStep (SInput (Data (Assert 2 1 0))), ntst_3_1__pump])
      = [[(1, True)], [(0, True)], []]
  , ltim_2_8_3__wm_after iret_12_2__successor_life lcdb_3_2_1__no_ttl iret_12_2__alphas_four iret_12_2__successor_rules [Nothing, Nothing, Nothing]
      iret_12_2__successor_tests
      ([ntst_3_1__assert_ping, ntst_3_1__pump] ++ ntst_3_1__advance 1 ++ [SStep (SInput (Data (Assert 1 1 0))), ntst_3_1__pump, SStep (SInput (Data (Assert 2 1 0))), ntst_3_1__pump])
      = [MkFact 2 1 1 0, MkFact 0 2 1 0] )
iret_12_2__queued_successor_removed_timed = (Refl, Refl)

--@spec [LTIM.2.8.2]
||| `dwell >= 3`: logical/LTIM.2.8.2_wall_step_moves_no_dwell's `held`.
public export
ltim_2_8_2__held : Iret_7_5__expr
ltim_2_8_2__held = ECmp OpGe lexp_9_5_1__dwell_of_head (ELit (VInt 3))

--@spec [LTIM.2.8.2]
||| ONE RULE IN THE RUNNER'S MONOTONIC FORM over kind 0, action-free, its
||| node loaded with the monotonic test at the sample (0, 0): what
||| `Fixture.idr` builds for a `where` with no `now()`.
public export
ltim_2_8_2__one_mono_rule : Iret_7_5__expr -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltim_2_8_2__one_mono_rule e = [([(0, ltim_2_8_2__mono_test_of ltim_2_4_1__wenv e [] (0, 0), False)], [])]

--@spec [LTIM.2.8.2]
||| The one monotonic rule's tests, by ordinal.
public export
ltim_2_8_2__one_mono_tests : Iret_7_5__expr -> List (Maybe Ltim_2_4_1__ttest)
ltim_2_8_2__one_mono_tests e = [Just (ltim_2_8_2__mono_test_of ltim_2_4_1__wenv e)]

--@derives [LTIM.2.8.2]
--@derives [LTIM.2.8.3]
--@derives [LEXP.9.5.1]
||| WALL STEPS MOVE NO `dwell`: the wall set to 10 before the Ping; an
||| advance to 5 and a pump fire `held`; the wall stepped back to 9 and a
||| pump, forward to 16 and a pump, an advance to 6 and a pump fire nothing
||| -- logical/LTIM.2.8.2_wall_step_moves_no_dwell's shape, C2 executed on
||| the Idris model's engine. Executed: `[[(0, True)], [], [], []]`.
export
ltim_2_8_2__wall_steps_move_no_dwell_timed :
  ltim_2_8_3__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_8_2__one_mono_rule ltim_2_8_2__held) [Nothing]
    (ltim_2_8_2__one_mono_tests ltim_2_8_2__held)
    ([SWall 10, ntst_3_1__assert_ping, SStep (SInput (Tick 5)), SWall 15, ntst_3_1__pump, SWall 9, ntst_3_1__pump, SWall 16, ntst_3_1__pump,
      SStep (SInput (Tick 6)), SWall 17, ntst_3_1__pump])
    = [[(0, True)], [], [], []]
ltim_2_8_2__wall_steps_move_no_dwell_timed = Refl

-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| A DATA INPUT THAT SAMPLES THE CLOCK: the engine consumes every input
||| at a sample, as RARC.5.6.3 as repaired and [LTIM.2.8.4] have it, on the
||| engine Rete/NetworkClocked.idr pumps. The clocked-network programme's
||| part E: the gap NetworkClocked's header states ("a data input is Ttl's:
||| it carries no clock in this model"), closed.
|||
||| NORMATIVE COMPANION to Rete/NetworkFrameRetime.idr, which it stands on.
|||
||| WHY. NetworkClocked's `rarc_5_6_3__prepare_clocked (Data ev)` is
||| NetworkTtl's: a data event sweeps and applies, and moves no clock, so a
||| timed test is re-evaluated at ticks alone. RARC.5.6.3 says the loop samples both clocks whenever it consumes
||| an input, whatever `clock_ns` the event carries, and [LTIM.2.8.4] says
||| one sample per step. A STEP here is a sample and what arrives with it:
||| the composed tick at the sample (advance, sweep, re-time, cascade), then
||| the event if there is one. The event carries no clock in the model,
||| which is the clause's "whatever `clock_ns` the event carries": the
||| sample is the source's, and the event's own reading has nowhere to be
||| read. Nothing of the engine changes: a step IS part D's prepared inputs
||| over `[Tick c, Data ev]`, definitionally, so every lemma of parts A, B''
||| and D applies to it as it stood.
|||
||| PROVED.
|||
|||   * A STEP IS A TICK THEN THE EVENT (`rarc_5_6_3__consume_is_prepared`,
|||     `rarc_5_6_3__consumed_cons`): consuming a step is NetworkClocked's
|||     prepare of the tick at the sample, then of the event; a list of
|||     steps is the list of their expansions prepared with no run between
|||     them (`rarc_5_6_3__consumed_is_prepared`).
|||   * THE CLOCK AFTER A STEP IS THE SAMPLE (`rarc_5_6_3__consumed_clock`):
|||     `next_clock` of the clock and the sample, which a conforming source
|||     never runs back ([LTIM.2.8.2]); the sweep, the re-time, the cascade
|||     and the event move no clock (`rarc_5_6_3__sweep_net_clock`,
|||     `iret_19_5__retime_clocked_clock`, `rarc_5_6_4__apply_ttl_net_clock`).
|||   * THE THEOREM (`iret_11_3__framed_fires_once_per_match_sampled`): from
|||     the loaded clocked network, after any steps -- each a sample with a
|||     data event or none -- with no run between them, a run that reaches
|||     quiescence fires a framed chain exactly once per match it holds when
|||     the run begins. Part D's theorem through the expansion.
|||   * EXECUTED: the kind-0 fact ARRIVING AT SAMPLE 1 under the opening gate.
|||     The step's tick runs first and opens the gate on nothing; the fact
|||     then joins under the open test, so A holds the match as the step
|||     leaves it (`ltim_2_8_4__arrives_open_chain`); the run fires A once
|||     with B's cascade inside it, `[1, 0]` (`ltim_2_8_4__arrives_open_trace`);
|||     the theorem at the fixture counts 1 for 1
|||     (`ltim_2_8_4__arrives_open_is_an_instance`). And part D's state, a
|||     fact at clock 0 then a bare tick to 1, is two steps' -- as states,
|||     the step at sample 0 ticking to 0 first, which on the loaded network
|||     is the identity (`ltim_2_8_4__fact_then_tick_is_steps`).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. NetworkFrameRetime's
||| limits but the one it closes. The wall clock is not here: part C's
||| state carries it beside this engine and fixes the timed tests at it,
||| and a step's second sample is C's `at_wall`. An event whose own
||| `clock_ns` is ahead of the source's sample has nothing to show: the
||| clause says the sample wins, and the model's event has no clock to
||| lose. One sample per PUMP ([LTIM.2.8.4]'s "when a pump begins") is
||| Rete/FireClock.idr's held sample, not this file's.
module Rete.NetworkSampled

-- The imports are Rete/NetworkFrameRetime.idr's whole: a run evaluated in a
-- witness reaches dispatch, selection and ordering, and a function unfolds
-- only if its module is imported by the file.
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
import Rete.NetworkOnce
import Rete.NetworkFrame
import Rete.NetworkFrameClocked
import Rete.NetworkFrameRetime
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- A step: a sample, and what arrives with it
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.4]
--@spec [RARC.5.6.3]
||| ONE STEP: the monotonic sample the engine takes as it consumes an
||| input, and the data event that arrived, or none for a bare tick.
public export
Ltim_2_8_4__step : Type
Ltim_2_8_4__step = (Nat, Maybe Rarc_5_6_1__event)

--@spec [LTIM.2.8.4]
--@spec [RARC.5.6.3]
||| A STEP AS INPUTS: the tick at the sample, then the event if any. The
||| sample is the clause's ("samples both clocks ... whatever `clock_ns` the
||| event carries"); the sweep and the re-time NetworkClocked's tick carries
||| run here before the event is applied, where RARC.5.6.3 as RARC left
||| draft with it runs the sweep at the pump's entry and not at an input
||| (Rete/TtlSweep.idr's header).
public export
ltim_2_8_4__expand : Ltim_2_8_4__step -> List Rarc_5_6_2__input
ltim_2_8_4__expand (c, Nothing) = [Tick c]
ltim_2_8_4__expand (c, Just ev) = [Tick c, Data ev]

--@spec [LTIM.2.8.4]
public export
ltim_2_8_4__expand_all : List Ltim_2_8_4__step -> List Rarc_5_6_2__input
ltim_2_8_4__expand_all [] = []
ltim_2_8_4__expand_all (s :: ss) = ltim_2_8_4__expand s ++ ltim_2_8_4__expand_all ss

--@spec [RARC.5.6.3]
--@spec [LTIM.2.8.4]
||| CONSUMING ONE STEP: its expansion prepared with no run between.
public export
rarc_5_6_3__consume : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> Ltim_2_8_4__step -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_3__consume pg ttl ts s cs = rarc_5_6_3__prepared_clocked pg ttl ts (ltim_2_8_4__expand s) cs

--@spec [RARC.5.6.3]
--@spec [LTIM.2.8.4]
--@spec [LFST.9.2.1]
||| CONSUMING STEPS WITH NO RUN BETWEEN THEM: the expansions, prepared.
public export
rarc_5_6_3__consumed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> List Ltim_2_8_4__step -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_3__consumed pg ttl ts ss cs = rarc_5_6_3__prepared_clocked pg ttl ts (ltim_2_8_4__expand_all ss) cs

-- ---------------------------------------------------------------------
-- A step is a tick then the event
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.3]
--@derives [LTIM.2.8.4]
||| A STEP IS THE COMPOSED TICK AT ITS SAMPLE, THEN THE EVENT: the clause's
||| order, sample first. With no event it is the tick alone.
export
rarc_5_6_3__consume_is_prepared : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (ev : Rarc_5_6_1__event) -> (cs : Iret_19_3__clocked_net) ->
                                  rarc_5_6_3__consume pg ttl ts (c, Just ev) cs = rarc_5_6_3__prepare_clocked pg ttl ts (Data ev) (iret_19_5__tick_clocked pg ttl ts c cs)
rarc_5_6_3__consume_is_prepared pg ttl ts c ev cs = Refl

--@derives [RARC.5.6.3]
--@derives [LTIM.2.8.4]
||| STEPS CONSUME ONE AT A TIME: the steps after the first are consumed
||| from the state the first left. Rete/NetworkFrameRetime.idr's
||| `rarc_5_6_3__prepared_clocked_append` at the expansions.
export
rarc_5_6_3__consumed_cons : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (s : Ltim_2_8_4__step) -> (ss : List Ltim_2_8_4__step) -> (cs : Iret_19_3__clocked_net) ->
                            rarc_5_6_3__consumed pg ttl ts (s :: ss) cs = rarc_5_6_3__consumed pg ttl ts ss (rarc_5_6_3__consume pg ttl ts s cs)
rarc_5_6_3__consumed_cons pg ttl ts s ss cs = rarc_5_6_3__prepared_clocked_append pg ttl ts (ltim_2_8_4__expand s) (ltim_2_8_4__expand_all ss) cs

--@derives [RARC.5.6.3]
--@derives [LFST.9.2.1]
||| And consuming steps is preparing their expansions: what lets every
||| lemma of Rete/NetworkFrameRetime.idr over prepared inputs serve.
export
rarc_5_6_3__consumed_is_prepared : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (ss : List Ltim_2_8_4__step) -> (cs : Iret_19_3__clocked_net) ->
                                   rarc_5_6_3__consumed pg ttl ts ss cs = rarc_5_6_3__prepared_clocked pg ttl ts (ltim_2_8_4__expand_all ss) cs
rarc_5_6_3__consumed_is_prepared pg ttl ts ss cs = Refl

-- ---------------------------------------------------------------------
-- The clock after a step is the sample
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.3]
||| The sweep moves no clock.
export
rarc_5_6_3__sweep_net_clock : (pg : Lcyc_3_2_1__program) -> (cs : Iret_19_3__clocked_net) -> nclock (rarc_5_6_3__sweep_net pg cs) = nclock cs
rarc_5_6_3__sweep_net_clock pg (MkClockedNet (MkTmsNet eng rows) dl c) = Refl

--@derives [RARC.5.6.3]
||| The advance sets the clock to `next_clock` of the clock and the sample.
export
rarc_5_6_3__advance_net_clock : (t : Nat) -> (cs : Iret_19_3__clocked_net) -> nclock (rarc_5_6_3__advance_net t cs) = rarc_5_6_3__next_clock (nclock cs) t
rarc_5_6_3__advance_net_clock t (MkClockedNet s dl c) = Refl

--@derives [IRET.19.5]
--@derives [RARC.5.6.3]
||| The re-time stage with its cascade moves no clock.
export
iret_19_5__retime_clocked_clock : (pg : Lcyc_3_2_1__program) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (cs : Iret_19_3__clocked_net) -> nclock (iret_19_5__retime_clocked pg ts cs) = nclock cs
iret_19_5__retime_clocked_clock pg ts (MkClockedNet (MkTmsNet eng rows) dl c) = Refl

--@derives [RARC.5.6.4]
--@derives [RARC.5.6.3]
||| A data event moves no clock.
export
rarc_5_6_4__apply_ttl_net_clock : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ev : Rarc_5_6_1__event) -> (cs : Iret_19_3__clocked_net) -> nclock (rarc_5_6_4__apply_ttl_net pg ttl ev cs) = nclock cs
rarc_5_6_4__apply_ttl_net_clock pg ttl (Assert k key pay) (MkClockedNet (MkTmsNet eng rows) dl c) = Refl
rarc_5_6_4__apply_ttl_net_clock pg ttl (Retract i) (MkClockedNet s dl c) = Refl

--@derives [RARC.5.6.3]
--@derives [IRET.19.5]
||| THE COMPOSED TICK'S CLOCK IS THE SAMPLE: advance, then three stages
||| that move no clock.
export
iret_19_5__tick_clocked_clock : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (t : Nat) -> (cs : Iret_19_3__clocked_net) ->
                                nclock (iret_19_5__tick_clocked pg ttl ts t cs) = rarc_5_6_3__next_clock (nclock cs) t
iret_19_5__tick_clocked_clock pg ttl ts t cs =
  trans (iret_19_5__retime_clocked_clock pg ts (rarc_5_6_3__sweep_net pg (rarc_5_6_3__advance_net t cs)))
        (trans (rarc_5_6_3__sweep_net_clock pg (rarc_5_6_3__advance_net t cs)) (rarc_5_6_3__advance_net_clock t cs))

--@derives [RARC.5.6.3]
--@derives [LTIM.2.8.4]
--@derives [LTIM.2.8.2]
||| THE CLOCK AFTER A STEP IS THE SAMPLE: `next_clock` of the clock before
||| and the sample, whether or not an event arrived -- the event moves
||| nothing. A conforming source's sample never runs back ([LTIM.2.8.2]), so
||| `next_clock` is the sample itself; ClockStep.idr's `rarc_5_6_3__sampled`
||| on the network.
export
rarc_5_6_3__consumed_clock : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (ev : Maybe Rarc_5_6_1__event) -> (cs : Iret_19_3__clocked_net) ->
                             nclock (rarc_5_6_3__consume pg ttl ts (c, ev) cs) = rarc_5_6_3__next_clock (nclock cs) c
rarc_5_6_3__consumed_clock pg ttl ts c Nothing cs = iret_19_5__tick_clocked_clock pg ttl ts c cs
rarc_5_6_3__consumed_clock pg ttl ts c (Just e) cs =
  trans (rarc_5_6_4__apply_ttl_net_clock pg ttl e (rarc_5_6_3__sweep_net pg (iret_19_5__tick_clocked pg ttl ts c cs)))
        (trans (rarc_5_6_3__sweep_net_clock pg (iret_19_5__tick_clocked pg ttl ts c cs)) (iret_19_5__tick_clocked_clock pg ttl ts c cs))

-- ---------------------------------------------------------------------
-- THE THEOREM
-- ---------------------------------------------------------------------

--@derives [IRET.11.3]
--@derives [LTIM.2.5.1]
--@derives [LTIM.2.8.4]
--@derives [RARC.5.6.3]
--@derives [IRET.19.5]
--@derives [RDSC.4a.5]
||| ONCE PER MATCH UNDER THE GENERAL FRAME, WITH EVERY INPUT SAMPLED. From
||| the loaded clocked network, after any steps -- each a sample with a
||| data event or none -- consumed with no run between them, a run that
||| reaches quiescence fires a framed chain exactly as many times as it has
||| matches when the run begins. Rete/NetworkFrameRetime.idr's theorem
||| through the expansion: a step is a tick then its event.
export
iret_11_3__framed_fires_once_per_match_sampled : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (fuel : Nat) -> (c0 : Nat) -> (steps : List Ltim_2_8_4__step) ->
                                                 (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                                 (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                                 ltim_2_5_1__framed (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) nodes = True ->
                                                 rarc_5_6_5__nth ci (nchains (enet (ncore (nengine (rarc_5_6_3__consumed pg ttl ts steps (rdsc_4a_5__load_clocked alphas rules c0)))))) = Just (MkChain nodes acts actions) ->
                                                 (cs' : Iret_19_3__clocked_net) -> (h : Iret_11_4__halt) -> (tr : List Nat) ->
                                                 iret_11_4__run_ttl_net_traced pg ttl fuel (rarc_5_6_3__consumed pg ttl ts steps (rdsc_4a_5__load_clocked alphas rules c0)) = (cs', h, tr) ->
                                                 h = Quiescent ->
                                                 ltim_2_5_1__count ci tr
                                                   = length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__consumed pg ttl ts steps (rdsc_4a_5__load_clocked alphas rules c0))))))
                                                                            (ewm (ncore (nengine (rarc_5_6_3__consumed pg ttl ts steps (rdsc_4a_5__load_clocked alphas rules c0))))) nodes [[]])
iret_11_3__framed_fires_once_per_match_sampled pg ttl ts fuel c0 steps alphas rules ci nodes acts actions fr n cs' h tr rt hq =
  iret_11_3__framed_fires_once_per_match_clocked pg ttl ts fuel c0 (ltim_2_8_4__expand_all steps) alphas rules ci nodes acts actions fr n cs' h tr rt hq

-- ---------------------------------------------------------------------
-- Executed: a fact arriving at the sample the gate opens at
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.4]
--@spec [RARC.5.6.3]
--@spec [LTIM.2.5.1]
||| THE STEP: the kind-0 fact arrives at sample 1, where the opening gate
||| opens. One step, one sample, one event.
public export
ltim_2_8_4__arrives_open : List Ltim_2_8_4__step
ltim_2_8_4__arrives_open = [(1, Just (Assert 0 1 0))]

--@spec [LTIM.2.8.4]
--@spec [LTIM.2.5.1]
||| THE NETWORK AS THE STEP LEFT IT: the opening gate's program, the step
||| consumed, no run after it.
public export
ltim_2_8_4__arrives_open_ready : Iret_19_3__clocked_net
ltim_2_8_4__arrives_open_ready =
  rarc_5_6_3__consumed ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl ltim_2_5_1__gates ltim_2_8_4__arrives_open
    (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated 0)

--@derives [LTIM.2.8.4]
--@derives [RARC.5.6.3]
--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| THE CHAIN AS THE STEP LEFT IT: the step's tick re-timed A to the gate
||| at 1 and opened it on nothing; the fact then joined under the open
||| test, so A holds the match, unfired. The clause's order, sample first,
||| executed. Computed.
export
ltim_2_8_4__arrives_open_chain :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine ltim_2_8_4__arrives_open_ready))))
    = Just (MkChain [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [MkAct [MkFact 0 0 1 0] False] ltim_2_5_1__emit_one)
ltim_2_8_4__arrives_open_chain = Refl

--@derives [RARC.5.6.3]
--@derives [LTIM.2.8.4]
||| And the clock is at the sample. Computed.
export
ltim_2_8_4__arrives_open_clock : nclock ltim_2_8_4__arrives_open_ready = 1
ltim_2_8_4__arrives_open_clock = Refl

--@derives [LTIM.2.8.4]
--@derives [LTIM.2.5.1]
--@derives [IRET.12.2]
--@derives [IRET.11.3]
||| THE TRACE: A fires for the match the step made, B fires and cascades,
||| `[1, 0]`, quiescent, the kind-0 fact alone left. Executed, with fuel 3.
export
ltim_2_8_4__arrives_open_trace :
  iret_11_4__trace_of_ttl (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl 3 ltim_2_8_4__arrives_open_ready)
    = ([1, 0], Quiescent, [0])
ltim_2_8_4__arrives_open_trace = Refl

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.8.4]
--@derives [IRET.11.3]
--@derives [RARC.5.6.3]
||| THE THEOREM AT THE FIXTURE: the frame of the re-timed chain by
||| computation (Rete/NetworkFrameRetime.idr's), the chain as the step left
||| it, the run and the halt by the trace; one firing for the one match the
||| sampled arrival made. Executed.
export
ltim_2_8_4__arrives_open_is_an_instance :
  ltim_2_5_1__count 1 [1, 0]
    = length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_8_4__arrives_open_ready)))) (ewm (ncore (nengine ltim_2_8_4__arrives_open_ready)))
                             [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [[]])
ltim_2_8_4__arrives_open_is_an_instance =
  let (cs' ** rt) = iret_11_4__trace_of_ttl_inv (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl 3 ltim_2_8_4__arrives_open_ready)
                      [1, 0] Quiescent [0] ltim_2_8_4__arrives_open_trace
  in iret_11_3__framed_fires_once_per_match_sampled ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl ltim_2_5_1__gates 3 0 ltim_2_8_4__arrives_open
       ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated
       1 [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [MkAct [MkFact 0 0 1 0] False] ltim_2_5_1__emit_one
       ltim_2_5_1__a_is_framed_gated ltim_2_8_4__arrives_open_chain cs' Quiescent [1, 0] rt Refl

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.8.4]
||| And the number is one. Computed.
export
ltim_2_8_4__arrives_open_fires_once :
  ( ltim_2_5_1__count 1 [1, 0]
  , length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_8_4__arrives_open_ready)))) (ewm (ncore (nengine ltim_2_8_4__arrives_open_ready)))
                           [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [[]]) ) = (1, 1)
ltim_2_8_4__arrives_open_fires_once = Refl

--@derives [LTIM.2.8.4]
--@derives [RARC.5.6.3]
--@derives [LTIM.2.5.1]
||| PART D'S STATE IS TWO STEPS': the fact at sample 0, then a bare tick
||| at 1, consumed, is Rete/NetworkFrameRetime.idr's `ltim_2_5_1__gated_ready`.
||| Not as input lists -- the step at sample 0 ticks to 0 before the fact,
||| and D's inputs have no such tick --
||| but as states: on the loaded network at clock 0 a tick to 0 expires
||| nothing and re-times A to the test it was loaded with, so it is the
||| identity, and the two prepares reach one state. Computed.
export
ltim_2_8_4__fact_then_tick_is_steps :
  rarc_5_6_3__consumed ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl ltim_2_5_1__gates [(0, Just (Assert 0 1 0)), (1, Nothing)]
    (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated 0)
    = ltim_2_5_1__gated_ready
ltim_2_8_4__fact_then_tick_is_steps = Refl

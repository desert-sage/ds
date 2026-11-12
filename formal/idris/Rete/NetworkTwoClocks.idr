-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TWO CLOCKS ON THE CLOCKED NETWORK: the sample, its replay, the wall
||| clock's independence, and which gates can reopen. The clocked-network
||| programme's part C.
|||
||| NORMATIVE COMPANION to Rete/NetworkClocked.idr and TwoClocks.idr, which
||| it joins.
|||
||| HOW THE SAMPLE REACHES THE ENGINE WITHOUT TOUCHING IT. The composed
||| engine's clock IS the monotonic sample ([LTIM.2.8.1]), and its timed
||| tests are functions of that clock. A two-clock test is a function of the
||| sample (`Ltim_2_8_4__timed`), and fixing the wall sample gives a
||| one-clock test (`ltim_2_8_4__at_wall`). So the two-clock pump at a sample
||| `(m, w)` is part A's pump at `Tick m` with every test fixed at `w`, the
||| wall kept beside the state and the entry stamps ([LTIM.2.8.6]) beside the
||| deadline table. No definition of parts A or B changes, and every theorem
||| of theirs applies at each step. The stamp-reading gates (`within`,
||| `dwell`) are two-clock tests computed from the state's stamp table at
||| each pump, which is how a test reads the stamps while A's tick takes its
||| tests as given. A data input is Ttl's, with the stamps updated by
||| Rete/EntryStamp.idr's assert at the HELD sample: a data input moves no
||| clock in this model (RARC.5.6.3 samples at every input; the sample a
||| data input would take is not modelled, only a tick's).
|||
||| PROVED.
|||
|||   * C1, REPLAY DRIVES THE ENGINE WHERE THE RECORDING WENT
|||     (`ltim_2_8_5__replay_run_holds_what_was_held`, generic in the step;
|||     `rfcs_10_5__replay_drives_the_engine`, at the composed pump): for every
|||     clock source, every run and every clocks the replay engine starts at,
|||     the replay engine driven by the recorded atoms alone ends in the state
|||     the recording engine ended in. TwoClocks.idr's theorem lifted from the
|||     samples to what is done with them.
|||   * C2, THE WALL CLOCK MOVES NO FIRING OF A MONOTONIC GATE
|||     (`ltim_2_8_2__pump_ignores_wall`, `ltim_2_8_2__counts_ignore_wall`):
|||     when every test is a gate on elapsed monotonic time
|||     (`Ltim_2_8_2__monotonic`), the pump at `(m, w)` and at `(m, w')` leave
|||     one engine, and a history's counts are unmoved by any rewriting of its
|||     wall samples. `within` and `dwell` over the stamp table are such gates
|||     (`ltim_2_7_1__within_gate_monotonic`, `lexp_9_5_1__dwell_gate_monotonic`).
|||   * C3, WHICH GATES CAN REOPEN. The composed engine's clock never goes
|||     back (`rarc_5_6_3__next_clock_lte`), so a rising gate's edges over ANY
|||     tick history sum to at most one (`ltim_2_5_1__rising_edges_at_most_one`),
|||     and with part B the one-fact program under a rising gate fires at most
|||     once over any history (`ltim_2_5_1__rising_fires_at_most_once`). The
|||     `dwell >= d` gate at a fixed stamp is rising
|||     (`lexp_9_5_1__dwell_gate_rising`): a gate on elapsed monotonic time
|||     cannot reopen. A gate on the wall clock can: over samples whose
|||     monotonic clock rises and whose wall goes back, the one-fact program
|||     fires `[1, 0, 1, 0]` (`ltim_2_8_3__wall_gate_reopens`), which is
|||     [LTIM.2.8.3]'s last sentence, executed.
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. A data input that
||| samples the clocks (RARC.5.6.3; a tick's sample is the only one modelled).
||| That every fact a pump mints is stamped with the pump's held sample
||| ([IRET.19.1], step 4): actions are outside part B's frame and the stamps
||| are updated at data inputs alone. A cascade's retractions dropping stamp
||| rows. A checkpoint on this engine: neither the seek nor that a restored
||| fact keeps its atom's stamp ([RFCS.9.4]) is modelled. That the
||| network's assert enters exactly when
||| FireLoop's does, which the stamps follow, is the transfer
||| (`rlow_4_2_1__assert_agree`). C1 is generic in the step and so says of the
||| engine only that the replay drives it through the same samples, which
||| is the clause's claim and no more.
module Rete.NetworkTwoClocks

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.TmsRun
import Rete.TtlSweep
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkTms
import Rete.NetworkTtl
import Rete.NetworkTick
import Rete.NetworkClocked
import Rete.NetworkEdges
import Rete.EntryStamp
import TwoClocks
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- Two-clock tests, the sampled state, the pump at a sample
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.4]
--@spec [LTIM.2.4.1]
||| A time-dependent join test over the sample: `now()` reads the wall
||| sample, `monotonic_ns()`, `dwell` and `within` the monotonic one.
public export
Ltim_2_8_4__timed : Type
Ltim_2_8_4__timed = Ltim_2_8_1__sample -> Iret_7_5__join

--@spec [LTIM.2.8.4]
||| A two-clock test at a fixed wall sample is a test on the monotonic
||| clock alone: what part A's engine takes.
public export
ltim_2_8_4__at_wall : Nat -> Ltim_2_8_4__timed -> Ltim_2_4_1__timed
ltim_2_8_4__at_wall w tj = \m => tj (m, w)

--@spec [LTIM.2.8.4]
||| The tests of an engine, each read from the stamp table it holds, each
||| fixed at a wall sample.
public export
ltim_2_8_4__tests_at : Nat -> Ltim_2_8_6__stamps -> (Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> List (Maybe Ltim_2_4_1__timed)
ltim_2_8_4__tests_at w st tests = map (map (ltim_2_8_4__at_wall w)) (tests st)

--@spec [LTIM.2.8.1]
--@spec [LTIM.2.8.6]
||| THE SAMPLED STATE: the composed engine, whose clock is the monotonic
||| sample; the wall sample beside it; the entry stamps beside the deadline
||| table.
public export
record Ltim_2_8_1__sampled_net where
  constructor MkSampled
  snet    : Iret_19_3__clocked_net
  swall   : Nat
  sstamps : Ltim_2_8_6__stamps

--@spec [LTIM.2.8.1]
||| The sample the state holds.
public export
ltim_2_8_1__held_sample : Ltim_2_8_1__sampled_net -> Ltim_2_8_1__sample
ltim_2_8_1__held_sample s = (nclock (snet s), swall s)

--@spec [LTIM.2.8.4]
--@spec [IRET.19.5]
||| THE PUMP AT A SAMPLE: part A's pump at `Tick m` with the tests fixed at
||| `w`; the wall sample kept; the stamps untouched, since a tick asserts
||| nothing. With the halt and the count.
public export
ltim_2_8_4__pump_sampled : Lcyc_3_2_1__program -> Iret_4_2__ttl -> (Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> Nat ->
                           Ltim_2_8_1__sample -> Ltim_2_8_1__sampled_net -> (Ltim_2_8_1__sampled_net, Iret_11_4__halt, Nat)
ltim_2_8_4__pump_sampled pg ttl tests fuel sm (MkSampled net wall st) =
  let r = iret_19_5__pump_clocked pg ttl (ltim_2_8_4__tests_at (snd sm) st tests) fuel (Tick (fst sm)) net
  in (MkSampled (fst r) (snd sm) st, fst (snd r), snd (snd r))

--@spec [LTIM.2.8.4]
||| The state after the pump at a sample.
public export
ltim_2_8_4__step_sampled : Lcyc_3_2_1__program -> Iret_4_2__ttl -> (Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> Nat ->
                           Ltim_2_8_1__sample -> Ltim_2_8_1__sampled_net -> Ltim_2_8_1__sampled_net
ltim_2_8_4__step_sampled pg ttl tests fuel sm s = fst (ltim_2_8_4__pump_sampled pg ttl tests fuel sm s)

--@spec [LTIM.2.8.4]
||| The firings of a history of samples, one count per pump.
public export
ltim_2_8_4__counts_sampled : Lcyc_3_2_1__program -> Iret_4_2__ttl -> (Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> Nat ->
                             List Ltim_2_8_1__sample -> Ltim_2_8_1__sampled_net -> List Nat
ltim_2_8_4__counts_sampled pg ttl tests fuel [] s = []
ltim_2_8_4__counts_sampled pg ttl tests fuel (sm :: sms) s =
  let r = ltim_2_8_4__pump_sampled pg ttl tests fuel sm s in snd (snd r) :: ltim_2_8_4__counts_sampled pg ttl tests fuel sms (fst r)

--@spec [LTIM.2.8.4]
--@spec [RARC.5.6.4]
--@spec [LTIM.2.8.6]
--@spec [IRET.4.3]
||| A DATA INPUT at the held sample: Ttl's apply on the engine, and the
||| stamps as Rete/EntryStamp.idr's assert has them, at the held monotonic
||| sample, on the engine's working memory. A retraction stamps nothing.
public export
ltim_2_8_4__apply_sampled : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Rarc_5_6_1__event -> Ltim_2_8_1__sampled_net -> Ltim_2_8_1__sampled_net
ltim_2_8_4__apply_sampled pg ttl (Assert k key pay) (MkSampled net wall st) =
  MkSampled (rarc_5_6_4__apply_ttl_net pg ttl (Assert k key pay) net) wall
            (ltim_2_8_6__assert_stamps (life pg k) [] k key pay (nclock net) (ewm (ncore (nengine net))) st)
ltim_2_8_4__apply_sampled pg ttl (Retract i) (MkSampled net wall st) =
  MkSampled (rarc_5_6_4__apply_ttl_net pg ttl (Retract i) net) wall st

--@derives [LTIM.2.8.6]
||| A tick history leaves the stamp table as it was: only a data input
||| stamps.
export
ltim_2_8_6__ticks_keep_stamps : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (tests : Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> (fuel : Nat) ->
                                (sm : Ltim_2_8_1__sample) -> (net : Iret_19_3__clocked_net) -> (wall : Nat) -> (st : Ltim_2_8_6__stamps) ->
                                sstamps (ltim_2_8_4__step_sampled pg ttl tests fuel sm (MkSampled net wall st)) = st
ltim_2_8_6__ticks_keep_stamps pg ttl tests fuel sm net wall st = Refl

-- ---------------------------------------------------------------------
-- C1: the replay drives the engine where the recording went
-- ---------------------------------------------------------------------

--@spec [RFCS.10.5]
||| THE REPLAY ENGINE, generic in what a step does: it has the recorded
||| atoms and its own clocks and nothing else. A `ClockAdvance` sets its
||| clocks; an input is consumed under the clocks as they then stand.
public export
rfcs_10_5__replay_run : {st : Type} -> (Ltim_2_8_1__sample -> Nat -> st -> st) -> Ltim_2_8_1__sample -> List Rfcs_10_1__atom -> st -> st
rfcs_10_5__replay_run step cur [] s = s
rfcs_10_5__replay_run step cur (Advance sm :: rest) s = rfcs_10_5__replay_run step sm rest s
rfcs_10_5__replay_run step cur (Inject i :: rest) s = rfcs_10_5__replay_run step cur rest (step cur i s)

--@spec [LTIM.2.8.4]
||| THE RECORDING ENGINE, generic in what a step does: the source is called
||| once as each step begins, and the step runs under that sample.
public export
ltim_2_8_4__run_from : {st : Type} -> (Ltim_2_8_1__sample -> Nat -> st -> st) -> Ltim_2_8_1__source -> Nat -> List Nat -> st -> st
ltim_2_8_4__run_from step src n [] s = s
ltim_2_8_4__run_from step src n (i :: is) s = ltim_2_8_4__run_from step src (S n) is (step (src n) i s)

--@derives [LTIM.2.8.5]
||| The replay of a run from its second step on, the replay's clocks being
||| the sample of the step before: whether or not the step wrote a
||| `ClockAdvance`, the replay runs the step under the step's sample.
export
ltim_2_8_5__replay_run_from : {st : Type} -> (step : Ltim_2_8_1__sample -> Nat -> st -> st) -> (src : Ltim_2_8_1__source) -> (n : Nat) ->
                              (p : Ltim_2_8_1__sample) -> (is : List Nat) -> (s : st) ->
                              rfcs_10_5__replay_run step p (ltim_2_8_5__record src n (Just p) is) s = ltim_2_8_4__run_from step src n is s
ltim_2_8_5__replay_run_from step src n p [] s = Refl
ltim_2_8_5__replay_run_from step src n p (i :: is) s with (decEq p (src n))
  ltim_2_8_5__replay_run_from step src n p (i :: is) s | Yes prf =
    rewrite prf in ltim_2_8_5__replay_run_from step src (S n) (src n) is (step (src n) i s)
  ltim_2_8_5__replay_run_from step src n p (i :: is) s | No _ =
    ltim_2_8_5__replay_run_from step src (S n) (src n) is (step (src n) i s)

--@derives [LTIM.2.8.5]
--@derives [RFCS.10.5]
--@derives [LDET.1.1]
||| C1. REPLAY DRIVES THE ENGINE WHERE THE RECORDING WENT, for every step
||| function, every clock source, every run and every clocks the replay
||| engine starts at: the state the replay ends in is the state the
||| recording ended in. TwoClocks.idr's `replay_holds_what_was_held`, lifted
||| from the samples to what the engine does with them.
export
ltim_2_8_5__replay_run_holds_what_was_held : {st : Type} -> (step : Ltim_2_8_1__sample -> Nat -> st -> st) -> (src : Ltim_2_8_1__source) -> (n : Nat) ->
                                             (cur : Ltim_2_8_1__sample) -> (is : List Nat) -> (s : st) ->
                                             rfcs_10_5__replay_run step cur (ltim_2_8_5__record src n Nothing is) s = ltim_2_8_4__run_from step src n is s
ltim_2_8_5__replay_run_holds_what_was_held step src n cur [] s = Refl
ltim_2_8_5__replay_run_holds_what_was_held step src n cur (i :: is) s =
  ltim_2_8_5__replay_run_from step src (S n) (src n) is (step (src n) i s)

--@derives [LTIM.2.8.5]
--@derives [RFCS.10.5]
--@derives [IRET.19.5]
||| C1 AT THE COMPOSED PUMP: a tick history recorded on the two-clock
||| network and replayed from any starting clocks leaves the network where
||| the recording left it -- working memory, every chain, both tables, the
||| wall sample and the stamps.
export
rfcs_10_5__replay_drives_the_engine : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (tests : Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> (fuel : Nat) ->
                                      (src : Ltim_2_8_1__source) -> (n : Nat) -> (cur : Ltim_2_8_1__sample) -> (is : List Nat) -> (s : Ltim_2_8_1__sampled_net) ->
                                      rfcs_10_5__replay_run (\sm, i, x => ltim_2_8_4__step_sampled pg ttl tests fuel sm x) cur (ltim_2_8_5__record src n Nothing is) s
                                        = ltim_2_8_4__run_from (\sm, i, x => ltim_2_8_4__step_sampled pg ttl tests fuel sm x) src n is s
rfcs_10_5__replay_drives_the_engine pg ttl tests fuel src n cur is s =
  ltim_2_8_5__replay_run_holds_what_was_held (\sm, i, x => ltim_2_8_4__step_sampled pg ttl tests fuel sm x) src n cur is s

-- ---------------------------------------------------------------------
-- C2: the wall clock moves no firing of a monotonic gate
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.2]
||| A MONOTONIC GATE: a two-clock test that answers at `(m, w)` what it
||| answers at `(m, w')`. A gate on elapsed monotonic time.
public export
Ltim_2_8_2__monotonic : Ltim_2_8_4__timed -> Type
Ltim_2_8_2__monotonic tj = (m, w, w' : Nat) -> tj (m, w) = tj (m, w')

--@spec [LTIM.2.8.2]
||| Every test monotonic, chain by chain.
public export
Ltim_2_8_2__monotonic_all : List (Maybe Ltim_2_8_4__timed) -> Type
Ltim_2_8_2__monotonic_all [] = ()
Ltim_2_8_2__monotonic_all (Nothing :: ts) = Ltim_2_8_2__monotonic_all ts
Ltim_2_8_2__monotonic_all (Just tj :: ts) = (Ltim_2_8_2__monotonic tj, Ltim_2_8_2__monotonic_all ts)

--@spec [LTIM.2.7.1]
--@spec [LTIM.2.8.6]
||| `within <dur>` at a monotonic sample, over the stamp table: the
||| candidate fact entered less than `dur` ago by its stamp; a fact with no
||| stamp fails it.
public export
ltim_2_7_1__within_at : Nat -> Ltim_2_8_6__stamps -> Nat -> Iret_7_5__join
ltim_2_7_1__within_at m st dur = \t, f => case ltim_2_8_6__stamp_of (fid f) st of
  Nothing => False
  Just s  => lt (minus m s) dur

--@spec [LTIM.2.7.1]
--@spec [LTIM.2.8.6]
||| `within <dur>` as a two-clock test: it reads the monotonic sample and
||| no other, by construction.
public export
ltim_2_7_1__within_gate : Ltim_2_8_6__stamps -> Nat -> Ltim_2_8_4__timed
ltim_2_7_1__within_gate st dur = \sm => ltim_2_7_1__within_at (fst sm) st dur

--@spec [LEXP.9.5.1]
--@spec [LTIM.2.8.6]
||| `dwell >= d` at a monotonic sample, over the stamp table.
public export
lexp_9_5_1__dwell_at : Nat -> Ltim_2_8_6__stamps -> Nat -> Iret_7_5__join
lexp_9_5_1__dwell_at m st d = \t, f => case ltim_2_8_6__stamp_of (fid f) st of
  Nothing => False
  Just s  => lte d (minus m s)

--@spec [LEXP.9.5.1]
--@spec [LTIM.2.8.6]
||| `dwell >= d` as a two-clock test: the monotonic sample and no other.
public export
lexp_9_5_1__dwell_gate : Ltim_2_8_6__stamps -> Nat -> Ltim_2_8_4__timed
lexp_9_5_1__dwell_gate st d = \sm => lexp_9_5_1__dwell_at (fst sm) st d

--@derives [LTIM.2.8.2]
--@derives [LTIM.2.7.1]
||| `within` is a monotonic gate: it reads the monotonic sample alone, so
||| at one monotonic sample it is one function of the pair, whatever the
||| wall.
export
ltim_2_7_1__within_gate_monotonic : (st : Ltim_2_8_6__stamps) -> (dur : Nat) -> Ltim_2_8_2__monotonic (ltim_2_7_1__within_gate st dur)
ltim_2_7_1__within_gate_monotonic st dur m w w' = Refl

--@derives [LTIM.2.8.2]
--@derives [LEXP.9.5.1]
||| And so is `dwell`.
export
lexp_9_5_1__dwell_gate_monotonic : (st : Ltim_2_8_6__stamps) -> (d : Nat) -> Ltim_2_8_2__monotonic (lexp_9_5_1__dwell_gate st d)
lexp_9_5_1__dwell_gate_monotonic st d m w w' = Refl

--@derives [LTIM.2.8.2]
--@derives [IRET.19.5]
||| One chain re-timed under a monotonic gate at two wall samples: one
||| chain.
export
iret_19_5__tick_chain_wall : (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (tj : Ltim_2_8_4__timed) -> (m, w, w' : Nat) ->
                             (ch : Rlow_4_2_1__chain) -> Ltim_2_8_2__monotonic tj ->
                             iret_19_5__tick_chain wm al (Just (ltim_2_8_4__at_wall w tj)) m ch = iret_19_5__tick_chain wm al (Just (ltim_2_8_4__at_wall w' tj)) m ch
iret_19_5__tick_chain_wall wm al tj m w w' (MkChain [] acts actions) mo = Refl
iret_19_5__tick_chain_wall wm al tj m w w' (MkChain [MkBeta a j False lm cs] acts actions) mo =
  cong (\j' => MkChain [fst (iret_19_5__retime wm al j' (MkBeta a j False lm cs) acts)] (snd (iret_19_5__retime wm al j' (MkBeta a j False lm cs) acts)) actions)
       (mo m w w')
iret_19_5__tick_chain_wall wm al tj m w w' (MkChain [MkBeta a j True lm cs] acts actions) mo = Refl
iret_19_5__tick_chain_wall wm al tj m w w' (MkChain (MkBeta a j False lm cs :: b2 :: rest) acts actions) mo = Refl
iret_19_5__tick_chain_wall wm al tj m w w' (MkChain (MkBeta a j True lm cs :: b2 :: rest) acts actions) mo = Refl

--@derives [LTIM.2.8.2]
--@derives [IRET.19.5]
||| And every chain.
export
iret_19_5__tick_chains_wall : (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (ts : List (Maybe Ltim_2_8_4__timed)) -> (m, w, w' : Nat) ->
                              (chains : List Rlow_4_2_1__chain) -> Ltim_2_8_2__monotonic_all ts ->
                              iret_19_5__tick_chains wm al (map (map (ltim_2_8_4__at_wall w)) ts) m chains
                                = iret_19_5__tick_chains wm al (map (map (ltim_2_8_4__at_wall w')) ts) m chains
iret_19_5__tick_chains_wall wm al [] m w w' chains mos = Refl
iret_19_5__tick_chains_wall wm al (t :: ts) m w w' [] mos = Refl
iret_19_5__tick_chains_wall wm al (Nothing :: ts) m w w' (ch :: chs) mos =
  cong (ch ::) (iret_19_5__tick_chains_wall wm al ts m w w' chs mos)
iret_19_5__tick_chains_wall wm al (Just tj :: ts) m w w' (ch :: chs) (mo, mos) =
  cong2 (::) (iret_19_5__tick_chain_wall wm al tj m w w' ch mo) (iret_19_5__tick_chains_wall wm al ts m w w' chs mos)

--@derives [LTIM.2.8.2]
--@derives [IRET.19.5]
||| The re-time stage at two wall samples: one state.
export
iret_19_5__retime_clocked_wall : (pg : Lcyc_3_2_1__program) -> (ts : List (Maybe Ltim_2_8_4__timed)) -> (w, w' : Nat) ->
                                 (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                 Ltim_2_8_2__monotonic_all ts ->
                                 iret_19_5__retime_clocked pg (map (map (ltim_2_8_4__at_wall w)) ts) (MkClockedNet (MkTmsNet eng rows) dl c)
                                   = iret_19_5__retime_clocked pg (map (map (ltim_2_8_4__at_wall w')) ts) (MkClockedNet (MkTmsNet eng rows) dl c)
iret_19_5__retime_clocked_wall pg ts w w' (MkEngine wm (MkNetwork al chains)) rows dl c mos =
  cong (\chs => MkClockedNet (iret_12_2__phase_net pg (MkTmsNet (MkEngine wm (MkNetwork al chs)) rows)) dl c)
       (iret_19_5__tick_chains_wall wm al ts c w w' chains mos)

--@derives [LTIM.2.8.2]
--@derives [IRET.19.5]
--@derives [RARC.5.6.3]
||| The composed tick at two wall samples: one state. The sweep reads no
||| test; the re-time stage is the lemma above.
export
iret_19_5__tick_clocked_wall : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_8_4__timed)) -> (t, w, w' : Nat) ->
                               (cs : Iret_19_3__clocked_net) -> Ltim_2_8_2__monotonic_all ts ->
                               iret_19_5__tick_clocked pg ttl (map (map (ltim_2_8_4__at_wall w)) ts) t cs
                                 = iret_19_5__tick_clocked pg ttl (map (map (ltim_2_8_4__at_wall w')) ts) t cs
iret_19_5__tick_clocked_wall pg ttl ts t w w' cs mos with (rarc_5_6_3__prepare_net pg ttl (Tick t) cs)
  iret_19_5__tick_clocked_wall pg ttl ts t w w' cs mos | MkClockedNet (MkTmsNet eng rows) dl c =
    iret_19_5__retime_clocked_wall pg ts w w' eng rows dl c mos

--@derives [LTIM.2.8.2]
--@derives [IRET.19.5]
||| C2. THE WALL CLOCK MOVES NO FIRING OF A MONOTONIC GATE: when every test
||| is a gate on elapsed monotonic time, the pump at `(m, w)` and the pump
||| at `(m, w')` leave one engine, with one halt and one count. `dwell` and
||| `within` on the composed engine are moved by no wall clock, as
||| [LTIM.2.8.2] requires of every relative-time mechanism.
export
ltim_2_8_2__pump_ignores_wall : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_8_4__timed)) -> (fuel : Nat) ->
                                (m, w, w' : Nat) -> (cs : Iret_19_3__clocked_net) -> Ltim_2_8_2__monotonic_all ts ->
                                iret_19_5__pump_clocked pg ttl (map (map (ltim_2_8_4__at_wall w)) ts) fuel (Tick m) cs
                                  = iret_19_5__pump_clocked pg ttl (map (map (ltim_2_8_4__at_wall w')) ts) fuel (Tick m) cs
ltim_2_8_2__pump_ignores_wall pg ttl ts fuel m w w' cs mos =
  cong (iret_11_4__run_ttl_net pg ttl fuel) (iret_19_5__tick_clocked_wall pg ttl ts m w w' cs mos)

--@spec [LTIM.2.8.3]
||| A history's wall samples rewritten by any function; its monotonic
||| samples kept.
public export
ltim_2_8_3__remap_wall : (Nat -> Nat) -> Ltim_2_8_1__sample -> Ltim_2_8_1__sample
ltim_2_8_3__remap_wall f sm = (fst sm, f (snd sm))

--@derives [LTIM.2.8.4]
||| A triple is its three parts: how a proof names a pump's result without
||| abstracting the pump from its goal.
export
ltim_2_8_4__triple : {a, b, c : Type} -> (x : (a, b, c)) -> (p ** q ** r ** x = (p, q, r))
ltim_2_8_4__triple (p, q, r) = (p ** q ** r ** Refl)

--@derives [LTIM.2.8.4]
||| One pump of a sample history, unfolded.
export
ltim_2_8_4__counts_sampled_cons : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (tests : Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> (fuel : Nat) ->
                                  (sm : Ltim_2_8_1__sample) -> (sms : List Ltim_2_8_1__sample) -> (s, s' : Ltim_2_8_1__sampled_net) ->
                                  (h : Iret_11_4__halt) -> (n : Nat) ->
                                  ltim_2_8_4__pump_sampled pg ttl tests fuel sm s = (s', h, n) ->
                                  ltim_2_8_4__counts_sampled pg ttl tests fuel (sm :: sms) s = n :: ltim_2_8_4__counts_sampled pg ttl tests fuel sms s'
ltim_2_8_4__counts_sampled_cons pg ttl tests fuel sm sms s s' h n eq with (ltim_2_8_4__pump_sampled pg ttl tests fuel sm s)
  ltim_2_8_4__counts_sampled_cons pg ttl tests fuel sm sms s s' h n eq | (s2, h2, n2) =
    rewrite cong fst eq in rewrite cong (\z => snd (snd z)) eq in Refl

--@derives [LTIM.2.8.4]
||| The pump at a sample, as the composed pump: its three parts.
export
ltim_2_8_4__pump_sampled_parts : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (tests : Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> (fuel : Nat) ->
                                 (m, w : Nat) -> (net : Iret_19_3__clocked_net) -> (wall : Nat) -> (st : Ltim_2_8_6__stamps) ->
                                 (net' : Iret_19_3__clocked_net) -> (h : Iret_11_4__halt) -> (n : Nat) ->
                                 iret_19_5__pump_clocked pg ttl (ltim_2_8_4__tests_at w st tests) fuel (Tick m) net = (net', h, n) ->
                                 ltim_2_8_4__pump_sampled pg ttl tests fuel (m, w) (MkSampled net wall st) = (MkSampled net' w st, h, n)
ltim_2_8_4__pump_sampled_parts pg ttl tests fuel m w net wall st net' h n eq
  with (iret_19_5__pump_clocked pg ttl (ltim_2_8_4__tests_at w st tests) fuel (Tick m) net)
  ltim_2_8_4__pump_sampled_parts pg ttl tests fuel m w net wall st net' h n eq | (net2, h2, n2) =
    rewrite cong fst eq in rewrite cong (\z => fst (snd z)) eq in rewrite cong (\z => snd (snd z)) eq in Refl

--@derives [LTIM.2.8.4]
||| The held wall sample is read by nothing on this engine: a history's
||| counts from two states that differ in it alone are one list. (The
||| tests read the sample a pump is given, which is the wall the state then
||| takes.)
export
ltim_2_8_4__counts_sampled_held_wall : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (tests : Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> (fuel : Nat) ->
                                       (sms : List Ltim_2_8_1__sample) -> (net : Iret_19_3__clocked_net) -> (wall, wall' : Nat) -> (st : Ltim_2_8_6__stamps) ->
                                       ltim_2_8_4__counts_sampled pg ttl tests fuel sms (MkSampled net wall st)
                                         = ltim_2_8_4__counts_sampled pg ttl tests fuel sms (MkSampled net wall' st)
ltim_2_8_4__counts_sampled_held_wall pg ttl tests fuel [] net wall wall' st = Refl
ltim_2_8_4__counts_sampled_held_wall pg ttl tests fuel (sm :: sms) net wall wall' st = Refl

--@derives [LTIM.2.8.2]
--@derives [LTIM.2.8.3]
||| C2 OVER A HISTORY: with every test monotonic at every stamp table, the
||| counts of a sample history are unmoved by any rewriting of its wall
||| samples. The wall clock may be set anywhere, at any step, and `dwell`,
||| `within` and every other gate on elapsed monotonic time fire as they
||| would have.
export
ltim_2_8_2__counts_ignore_wall : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (tests : Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)) -> (fuel : Nat) ->
                                 ((st : Ltim_2_8_6__stamps) -> Ltim_2_8_2__monotonic_all (tests st)) -> (f : Nat -> Nat) ->
                                 (sms : List Ltim_2_8_1__sample) -> (net : Iret_19_3__clocked_net) -> (wall : Nat) -> (st : Ltim_2_8_6__stamps) ->
                                 ltim_2_8_4__counts_sampled pg ttl tests fuel sms (MkSampled net wall st)
                                   = ltim_2_8_4__counts_sampled pg ttl tests fuel (map (ltim_2_8_3__remap_wall f) sms) (MkSampled net wall st)
ltim_2_8_2__counts_ignore_wall pg ttl tests fuel mos f [] net wall st = Refl
ltim_2_8_2__counts_ignore_wall pg ttl tests fuel mos f ((m, w) :: sms) net wall st =
  let (net' ** h ** n ** pw) = ltim_2_8_4__triple (iret_19_5__pump_clocked pg ttl (ltim_2_8_4__tests_at w st tests) fuel (Tick m) net)
      pw' = the (iret_19_5__pump_clocked pg ttl (ltim_2_8_4__tests_at (f w) st tests) fuel (Tick m) net = (net', h, n))
                (trans (sym (ltim_2_8_2__pump_ignores_wall pg ttl (tests st) fuel m w (f w) net (mos st))) pw)
  in trans (ltim_2_8_4__counts_sampled_cons pg ttl tests fuel (m, w) sms (MkSampled net wall st) (MkSampled net' w st) h n
              (ltim_2_8_4__pump_sampled_parts pg ttl tests fuel m w net wall st net' h n pw))
           (trans (cong (n ::) (trans (ltim_2_8_2__counts_ignore_wall pg ttl tests fuel mos f sms net' w st)
                                      (ltim_2_8_4__counts_sampled_held_wall pg ttl tests fuel (map (ltim_2_8_3__remap_wall f) sms) net' w (f w) st)))
                  (sym (ltim_2_8_4__counts_sampled_cons pg ttl tests fuel (m, f w) (map (ltim_2_8_3__remap_wall f) sms) (MkSampled net wall st) (MkSampled net' (f w) st) h n
                          (ltim_2_8_4__pump_sampled_parts pg ttl tests fuel m (f w) net wall st net' h n pw'))))

--@spec [LEXP.9.5.1]
--@spec [LTIM.2.8.6]
||| The one rule under a `dwell >= 2` gate, the `Ping` stamped at 0,
||| quiescent at the sample (0, 0), where the gate is false.
public export
lexp_9_5_1__dwell_start : Ltim_2_8_1__sampled_net
lexp_9_5_1__dwell_start = MkSampled (ltim_2_5_1__one_rule (\c => False) 0) 0 [(1, 0)]

--@derives [LTIM.2.8.2]
--@derives [LEXP.9.5.1]
||| C2'S HYPOTHESIS, INHABITED: the one `dwell` test is monotonic at every
||| stamp table.
export
lexp_9_5_1__dwell_tests_monotonic : (st : Ltim_2_8_6__stamps) -> Ltim_2_8_2__monotonic_all [Just (lexp_9_5_1__dwell_gate st 2)]
lexp_9_5_1__dwell_tests_monotonic st = (lexp_9_5_1__dwell_gate_monotonic st 2, ())

--@derives [LTIM.2.8.2]
--@derives [LEXP.9.5.1]
||| AND C2 EXECUTED: over the samples of `wall_gate_reopens`, whose wall goes
||| 1, 2, 1, 2, the `dwell >= 2` gate fires once, at the monotonic sample 2,
||| `[0, 1, 0, 0]`; over the same monotonic samples with every wall sample
||| rewritten to 9, the same.
export
lexp_9_5_1__dwell_ignores_wall_executed :
  ( ltim_2_8_4__counts_sampled ltim_2_5_1__window_program (\_ => 0) (\st => [Just (lexp_9_5_1__dwell_gate st 2)]) 10
      [(1, 1), (2, 2), (3, 1), (4, 2)] lexp_9_5_1__dwell_start = [0, 1, 0, 0]
  , ltim_2_8_4__counts_sampled ltim_2_5_1__window_program (\_ => 0) (\st => [Just (lexp_9_5_1__dwell_gate st 2)]) 10
      (map (ltim_2_8_3__remap_wall (\_ => 9)) [(1, 1), (2, 2), (3, 1), (4, 2)]) lexp_9_5_1__dwell_start = [0, 1, 0, 0] )
lexp_9_5_1__dwell_ignores_wall_executed = (Refl, Refl)

-- ---------------------------------------------------------------------
-- C3: which gates can reopen
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.3]
||| THE COMPOSED ENGINE'S CLOCK NEVER GOES BACK: the clock after a tick is
||| at or above the clock before it. (Rete/TtlSweep.idr's `advance_lte` says
||| it of the clocked state; this is the same fact on the clock alone.)
export
rarc_5_6_3__next_clock_lte : (c, t : Nat) -> LTE c (rarc_5_6_3__next_clock c t)
rarc_5_6_3__next_clock_lte c t with (iret_12__lte_b c t) proof p
  rarc_5_6_3__next_clock_lte c t | True = iret_12__lte_b_true_lte c t p
  rarc_5_6_3__next_clock_lte c t | False = reflexive

--@spec [LTIM.2.5.1]
||| A RISING GATE on the clock: true at a clock, true at every clock at or
||| after it. `now() > t`, `dwell >= d`, `monotonic_ns() >= t`.
public export
Ltim_2_5_1__rising_b : (Nat -> Bool) -> Type
Ltim_2_5_1__rising_b g = (c, c' : Nat) -> LTE c c' -> g c = True -> g c' = True

--@spec [LTIM.2.5.1]
||| The sum of a history's edges: how many times the gate rose.
public export
ltim_2_5_1__total : List Nat -> Nat
ltim_2_5_1__total [] = 0
ltim_2_5_1__total (n :: ns) = n + ltim_2_5_1__total ns

--@derives [LTIM.2.5.1]
||| A tick from a clock at which the gate is true makes no edge.
export
ltim_2_5_1__edge_at_true : (g : Nat -> Bool) -> (c, t : Nat) -> g c = True -> ltim_2_5_1__edge_at g c t = 0
ltim_2_5_1__edge_at_true g c t gc with (g c)
  ltim_2_5_1__edge_at_true g c t gc | True = Refl
  ltim_2_5_1__edge_at_true g c t gc | False = absurd gc

--@derives [LTIM.2.5.1]
||| Once a rising gate is true, no later tick makes an edge: the clock
||| never goes back, so the gate stays true.
export
ltim_2_5_1__rising_edges_none : (g : Nat -> Bool) -> Ltim_2_5_1__rising_b g -> (c : Nat) -> (ticks : List Nat) -> g c = True ->
                                ltim_2_5_1__total (Ltim_2_5_1__edges g c ticks) = 0
ltim_2_5_1__rising_edges_none g rise c [] gc = Refl
ltim_2_5_1__rising_edges_none g rise c (t :: ts) gc =
  cong2 (+) (ltim_2_5_1__edge_at_true g c t gc)
            (ltim_2_5_1__rising_edges_none g rise (rarc_5_6_3__next_clock c t) ts (rise c (rarc_5_6_3__next_clock c t) (rarc_5_6_3__next_clock_lte c t) gc))

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.8.2]
||| C3a. A RISING GATE'S EDGES OVER ANY TICK HISTORY SUM TO AT MOST ONE: it
||| rises once or not at all, because the composed engine's clock never
||| goes back.
export
ltim_2_5_1__rising_edges_at_most_one : (g : Nat -> Bool) -> Ltim_2_5_1__rising_b g -> (c : Nat) -> (ticks : List Nat) ->
                                       LTE (ltim_2_5_1__total (Ltim_2_5_1__edges g c ticks)) 1
ltim_2_5_1__rising_edges_at_most_one g rise c [] = LTEZero
ltim_2_5_1__rising_edges_at_most_one g rise c (t :: ts) with (g c) proof gc
  ltim_2_5_1__rising_edges_at_most_one g rise c (t :: ts) | True =
    replace {p = \k => LTE k 1} (sym (ltim_2_5_1__rising_edges_none g rise (rarc_5_6_3__next_clock c t) ts
                                        (rise c (rarc_5_6_3__next_clock c t) (rarc_5_6_3__next_clock_lte c t) gc)))
            LTEZero
  ltim_2_5_1__rising_edges_at_most_one g rise c (t :: ts) | False with (g (rarc_5_6_3__next_clock c t)) proof gc'
    ltim_2_5_1__rising_edges_at_most_one g rise c (t :: ts) | False | True =
      LTESucc (replace {p = \k => LTE k 0} (sym (ltim_2_5_1__rising_edges_none g rise (rarc_5_6_3__next_clock c t) ts gc')) LTEZero)
    ltim_2_5_1__rising_edges_at_most_one g rise c (t :: ts) | False | False =
      ltim_2_5_1__rising_edges_at_most_one g rise (rarc_5_6_3__next_clock c t) ts

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.8.2]
--@derives [IRET.19.5]
||| C3a ON THE ENGINE, with part B: the one-fact program under a rising
||| gate fires AT MOST ONCE over any tick history from any starting clock.
||| Once per false-to-true edge, and a rising gate has at most one.
export
ltim_2_5_1__rising_fires_at_most_once : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (g : Nat -> Bool) -> Ltim_2_5_1__rising_b g ->
                                        (k : Nat) -> (c : Nat) -> (ticks : List Nat) ->
                                        LTE (ltim_2_5_1__total (iret_19_5__counts_clocked pg ttl [Just (ltim_2_5_1__gate g)] (S (S k)) (map Tick ticks) (ltim_2_5_1__one_rule g c))) 1
ltim_2_5_1__rising_fires_at_most_once pg ttl g rise k c ticks =
  replace {p = \l => LTE (ltim_2_5_1__total l) 1} (sym (ltim_2_5_1__counts_are_edges pg ttl g k c ticks))
          (ltim_2_5_1__rising_edges_at_most_one g rise c ticks)

--@spec [LEXP.9.5.1]
||| `dwell >= d` for a fixed stamp, as a gate on the monotonic clock.
public export
lexp_9_5_1__dwell_gate_b : (stamp, d : Nat) -> Nat -> Bool
lexp_9_5_1__dwell_gate_b stamp d m = lte d (minus m stamp)

--@derives [LEXP.9.5.1]
--@derives [LTIM.2.8.6]
--@derives [LTIM.2.5.1]
||| THE `dwell` GATE IS RISING: Rete/EntryStamp.idr's `dwell_gate_rises`,
||| as the hypothesis of C3a. So a gate on elapsed monotonic time cannot
||| reopen on the composed engine, and fires at most once per entry.
export
lexp_9_5_1__dwell_gate_rising : (stamp, d : Nat) -> Ltim_2_5_1__rising_b (lexp_9_5_1__dwell_gate_b stamp d)
lexp_9_5_1__dwell_gate_rising stamp d c c' le h = ltim_2_8_6__dwell_gate_rises stamp d c c' 0 0 le h

--@derives [LTIM.2.5.1]
--@derives [LEXP.9.5.1]
--@derives [LTIM.2.8.2]
||| C3a EXECUTED: the one-fact program under `dwell >= 2` from a stamp of 0,
||| over ticks 1, 2, 3, 4, fires once, at 2, and never again: `[0, 1, 0, 0]`,
||| total 1. The rising gate `rising_fires_at_most_once` takes is
||| `lexp_9_5_1__dwell_gate_rising 0 2`.
export
lexp_9_5_1__dwell_fires_once_executed :
  ( iret_19_5__counts_clocked ltim_2_5_1__window_program (\_ => 0) [Just (ltim_2_5_1__gate (lexp_9_5_1__dwell_gate_b 0 2))] 10
      [Tick 1, Tick 2, Tick 3, Tick 4] (ltim_2_5_1__one_rule (lexp_9_5_1__dwell_gate_b 0 2) 0) = [0, 1, 0, 0]
  , ltim_2_5_1__total [0, 1, 0, 0] = 1 )
lexp_9_5_1__dwell_fires_once_executed = (Refl, Refl)

--@spec [LTIM.2.8.3]
--@spec [LTIM.2.4.1]
||| A GATE ON THE WALL CLOCK: `now()` reads 1. The window of [LTIM.2.5.1]
||| on the wall sample.
public export
ltim_2_8_3__wall_window : Ltim_2_8_4__timed
ltim_2_8_3__wall_window = \sm, t, f => snd sm == 1

--@spec [LTIM.2.8.3]
||| The one rule under the wall window, quiescent at the sample (0, 0),
||| with no stamps: the gate at that sample is false.
public export
ltim_2_8_3__wall_start : Ltim_2_8_1__sampled_net
ltim_2_8_3__wall_start = MkSampled (ltim_2_5_1__one_rule (\c => False) 0) 0 []

--@derives [LTIM.2.8.3]
--@derives [LTIM.2.5.1]
--@derives [LTIM.2.4.3]
||| C3b. A GATE ON THE WALL CLOCK CAN REOPEN: over samples whose monotonic
||| clock rises 1, 2, 3, 4 and whose wall goes 1, 2, 1, 2, the one-fact
||| program under `now() == 1` fires in the first pump and the third,
||| `[1, 0, 1, 0]`: the wall clock went back and the window reopened. What
||| [LTIM.2.8.3]'s last sentence allows, and what no monotonic gate can do
||| (C3a).
export
ltim_2_8_3__wall_gate_reopens :
  ltim_2_8_4__counts_sampled ltim_2_5_1__window_program (\_ => 0) (\_ => [Just ltim_2_8_3__wall_window]) 10
    [(1, 1), (2, 2), (3, 1), (4, 2)] ltim_2_8_3__wall_start = [1, 0, 1, 0]
ltim_2_8_3__wall_gate_reopens = Refl

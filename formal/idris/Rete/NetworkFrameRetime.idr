-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE GENERAL FRAME ACROSS A TICK THAT RE-TIMES: a chain no rule writes
||| into fires once per match on the engine Rete/NetworkClocked.idr pumps,
||| with the prepare that engine has -- a tick that advances, sweeps,
||| RE-TIMES every timed chain at the new clock and cascades -- and not only
||| Rete/NetworkTtl.idr's. The clocked-network programme's part D: the step
||| Rete/NetworkFrameClocked.idr's header names as later.
|||
||| NORMATIVE COMPANION to Rete/NetworkFrameClocked.idr, which it stands on.
|||
||| WHY. NetworkFrameClocked's theorem is stated over NetworkTtl's prepare,
||| because the frame invariant carried the loaded network's SHAPES -- node
||| by node the same alpha, join test and flag -- and a re-time replaces a
||| timed node's join test by the test at the new clock
||| (Rete/NetworkTick.idr's `iret_19_5__retime`). The frame never reads a
||| test. What it reads of a chain is the kinds its nodes read, which of
||| them are NOT nodes, and the actions. So the invariant is weakened to the
||| KINDS (Rete/NetworkFrame.idr's `Rlow_4_2_1__same_kinds`, introduced with
||| this part), every lemma of the two frame modules holds of it as it
||| stood, and the re-time keeps it: a re-timed node keeps its alpha and its
||| flag.
|||
||| PROVED.
|||
|||   * THE RE-TIME KEEPS THE KINDS (`iret_19_5__tick_chain_kinds`,
|||     `iret_19_5__tick_chains_kinds`, `iret_19_5__tick_shapes`): a timed
|||     chain's one node takes a new test and keeps its alpha and its flag;
|||     every other chain is untouched; so the shapes kept, as the frame
|||     states them, hold across Rete/NetworkTick.idr's tick, and with the
|||     view (Rete/NetworkClocked.idr's A2) the frame invariant does
|||     (`iret_19_5__tick_inv`).
|||   * THE RE-TIME KEEPS EVERY ACTIVATION UNFIRED WHEN ALL WERE
|||     (`iret_19_5__retime_unfired` .. `iret_19_5__tick_unfired_all`): the
|||     matches a tick ends leave, the matches it makes arrive unfired, and
|||     every other activation is as it was.
|||   * THE RE-TIME STAGE KEEPS THE INVARIANT AND ENDS BETWEEN ACTIONS
|||     (`iret_19_5__retime_clocked_inv`, `iret_19_5__retime_clocked_unfired`):
|||     the tick changes no fact and no row, so unique ids and the row
|||     property stand as they were; and the cascade for the rows of the
|||     activations the re-time ended reaches its fixpoint.
|||   * A PREPARE WITH A RE-TIME keeps the invariant and fires nothing
|||     (`rarc_5_6_3__prepare_clocked_inv`, `rarc_5_6_3__prepare_clocked_unfired`),
|||     and so do inputs prepared with no run between them
|||     (`rarc_5_6_3__prepared_clocked`, `_inv`, `_unfired`).
|||   * THE THEOREM (`iret_11_3__framed_fires_once_per_match_clocked`): from
|||     the loaded clocked network, after any inputs -- data events, and
|||     ticks that sweep and re-time -- prepared with no run between them, a
|||     run that reaches quiescence fires a framed chain exactly once per
|||     match it holds when the run begins: the matches a tick made counted,
|||     the matches it ended not. NetworkFrameClocked's theorem with
|||     NetworkClocked's prepare in place of NetworkTtl's.
|||   * EXECUTED, TWICE, on NetworkFrameClocked's two rules with A's test
|||     made time-dependent. A GATE THAT OPENS at clock 1: the kind-0 fact
|||     asserted at clock 0 matches nothing (`ltim_2_5_1__gate_shut_no_match`);
|||     the tick to 1 re-times A's node and the match is born unfired
|||     (`ltim_2_5_1__gated_ready_chain`); the run fires A once and B once,
|||     with B's cascade inside it, `[1, 0]` (`ltim_2_5_1__gated_trace`); the
|||     theorem applied at the fixture counts one firing for one match
|||     (`ltim_2_5_1__gated_is_an_instance`, `ltim_2_5_1__gated_fires_once`).
|||     A GATE THAT SHUTS at clock 1: the fact matches at clock 0
|||     (`ltim_2_5_1__gate_open_match`), the tick ends the match
|||     (`ltim_2_5_1__shut_ready_chain`), the run fires nothing
|||     (`ltim_2_5_1__shut_trace`), and the theorem counts no firing for no
|||     match (`ltim_2_5_1__shut_is_an_instance`, `ltim_2_5_1__shut_fires_none`).
|||   * EXECUTED, TWO MORE, the witnesses unit T owed. A TICK THAT SWEEPS
|||     AND RE-TIMES: the opening fixture under a TTL of 1 on kind 0; the
|||     tick to 1 sweeps the fact before the re-time, so the gate opens on
|||     nothing -- the state as a literal (`ltim_2_5_1__swept_ready_ttl`),
|||     the trace `[]`, the theorem at it, 0 for 0
|||     (`ltim_2_5_1__swept_is_an_instance`). A RE-TIME THAT ENDS A FIRED
|||     LOGICAL ACTIVATION: B under the shutting gate, emitting kind 2 with
|||     no withdraw; one fact, one run (`[1, 0]`, B's row recorded,
|||     `ltim_2_5_1__fired_row`), then the tick to 1: B's activation ended
|||     (`ltim_2_5_1__ended_fired_chain`) and the cascade drops its row and
|||     retracts the kind-2 fact (`ltim_2_5_1__ended_fired_cascade`) --
|||     `iret_19_5__retime_clocked_inv`'s non-trivial case, which the
|||     theorem's prepared inputs from the loaded network never reach, since
|||     a row comes from a firing.
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. NetworkFrameClocked's
||| limits, less the one it closes: the frame is syntactic over the loaded
||| program, inputs are not framed, fuel is not assumed to suffice. A data
||| input samples no clock and re-times nothing in this model (RARC.5.6.3's
||| sample at a data input is Rete/NetworkClocked.idr's stated gap). A timed
||| test is one per single-positive-pattern chain, as Rete/NetworkTick.idr
||| has it, and the loader's pairing of tests with chains is the reading
||| NetworkTick's header states. The matches a run begins with are counted
||| on the re-timed chain: which tick made them is Rete/NetworkEdges.idr's,
||| not this file's.
module Rete.NetworkFrameRetime

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
-- The re-time keeps the kinds
-- ---------------------------------------------------------------------

--@derives [IRET.19.5]
--@derives [RLOW.4.2.1]
||| RE-TIMING A CHAIN KEEPS ITS KINDS: a timed chain's one node takes the
||| test at the new clock and keeps its alpha and its flag; a chain with no
||| timed test, or not of the one-positive-node shape the re-time acts on,
||| is untouched. That it keeps the actions is Rete/NetworkEdges.idr's
||| `iret_19_5__tick_chain_actions`.
export
iret_19_5__tick_chain_kinds : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (t : Maybe Ltim_2_4_1__timed) -> (c : Nat) -> (ch : Rlow_4_2_1__chain) ->
                              Rlow_4_2_1__same_kinds (cnodes ch) (cnodes (iret_19_5__tick_chain wm alphas t c ch))
iret_19_5__tick_chain_kinds wm alphas Nothing c ch = rlow_4_2_1__same_kinds_refl (cnodes ch)
iret_19_5__tick_chain_kinds wm alphas (Just tj) c (MkChain [] acts actions) = SKNil
iret_19_5__tick_chain_kinds wm alphas (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) = SKCons _ _ Refl Refl SKNil
iret_19_5__tick_chain_kinds wm alphas (Just tj) c (MkChain [MkBeta a j True lm cs] acts actions) = rlow_4_2_1__same_kinds_refl _
iret_19_5__tick_chain_kinds wm alphas (Just tj) c (MkChain (MkBeta a j False lm cs :: b2 :: rest) acts actions) = rlow_4_2_1__same_kinds_refl _
iret_19_5__tick_chain_kinds wm alphas (Just tj) c (MkChain (MkBeta a j True lm cs :: b2 :: rest) acts actions) = rlow_4_2_1__same_kinds_refl _

--@derives [IRET.19.5]
||| Re-timing the chains keeps their number.
export
iret_19_5__tick_chains_length : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (chains : List Rlow_4_2_1__chain) ->
                                length (iret_19_5__tick_chains wm alphas ts c chains) = length chains
iret_19_5__tick_chains_length wm alphas [] c chains = Refl
iret_19_5__tick_chains_length wm alphas (t :: ts) c [] = Refl
iret_19_5__tick_chains_length wm alphas (t :: ts) c (ch :: chs) = cong S (iret_19_5__tick_chains_length wm alphas ts c chs)

--@derives [IRET.19.5]
--@derives [RLOW.4.2.1]
||| RE-TIMING THE CHAINS KEEPS EVERY CHAIN'S KINDS AND ACTIONS, ordinal by
||| ordinal: a chain past the timed tests is untouched.
export
iret_19_5__tick_chains_kinds : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (chains : List Rlow_4_2_1__chain) ->
                               (r : Nat) -> (ch, ch' : Rlow_4_2_1__chain) ->
                               rarc_5_6_5__nth r chains = Just ch -> rarc_5_6_5__nth r (iret_19_5__tick_chains wm alphas ts c chains) = Just ch' ->
                               (Rlow_4_2_1__same_kinds (cnodes ch) (cnodes ch'), cactions ch' = cactions ch)
iret_19_5__tick_chains_kinds wm alphas [] c chains r ch ch' n n' =
  replace {p = \z => (Rlow_4_2_1__same_kinds (cnodes ch) (cnodes z), cactions z = cactions ch)} (iret_11_4__just_inj (trans (sym n) n'))
    (rlow_4_2_1__same_kinds_refl (cnodes ch), Refl)
iret_19_5__tick_chains_kinds wm alphas (t :: ts) c [] r ch ch' n n' = absurd n
iret_19_5__tick_chains_kinds wm alphas (t :: ts) c (ch0 :: chs) Z ch ch' n n' =
  let e = the (ch = ch0) (iret_11_4__just_inj (sym n))
      e' = the (ch' = iret_19_5__tick_chain wm alphas t c ch0) (iret_11_4__just_inj (sym n'))
      s = iret_19_5__tick_chain_kinds wm alphas t c ch0
      a = iret_19_5__tick_chain_actions wm alphas t c ch0
  in ( replace {p = \z => Rlow_4_2_1__same_kinds (cnodes z) (cnodes ch')} (sym e)
         (replace {p = \z => Rlow_4_2_1__same_kinds (cnodes ch0) (cnodes z)} (sym e') s)
     , trans (cong cactions e') (trans a (cong cactions (sym e))) )
iret_19_5__tick_chains_kinds wm alphas (t :: ts) c (ch0 :: chs) (S r) ch ch' n n' = iret_19_5__tick_chains_kinds wm alphas ts c chs r ch ch' n n'

--@derives [IRET.19.5]
--@derives [LDET.5.8]
--@derives [RLOW.4.2.1]
||| THE TICK KEEPS THE SHAPES: working memory and the alphas untouched, as
||| many chains, every chain of the kinds and actions it was loaded with.
||| [LDET.5.8]'s "cycling the tick is not a change to the LHS", for what the
||| frame reads of the LHS.
export
iret_19_5__tick_shapes : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (eng : Iret_19__engine) ->
                         Rlow_4_2_1__shapes_kept alphas0 chains0 eng -> Rlow_4_2_1__shapes_kept alphas0 chains0 (iret_19_5__tick ts c eng)
iret_19_5__tick_shapes alphas0 chains0 ts c eng sk =
  rlow_4_2_1__shapes_kept_through_kinds alphas0 chains0 eng (ewm eng)
    (MkNetwork (nalphas (enet eng)) (iret_19_5__tick_chains (ewm eng) (nalphas (enet eng)) ts c (nchains (enet eng)))) sk
    (iret_6_1__same_alphas_refl (nalphas (enet eng)))
    (iret_19_5__tick_chains_length (ewm eng) (nalphas (enet eng)) ts c (nchains (enet eng)))
    (iret_19_5__tick_chains_kinds (ewm eng) (nalphas (enet eng)) ts c (nchains (enet eng)))

--@derives [IRET.19.5]
--@derives [LTIM.2.5.1]
||| THE TICK KEEPS THE FRAME INVARIANT: the view (Rete/NetworkClocked.idr's
||| `iret_19_5__tick_view`) and the shapes.
export
iret_19_5__tick_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (eng : Iret_19__engine) ->
                      Ltim_2_5_1__frame_inv alphas0 chains0 eng -> Ltim_2_5_1__frame_inv alphas0 chains0 (iret_19_5__tick ts c eng)
iret_19_5__tick_inv alphas0 chains0 ts c eng (v, sk) = (iret_19_5__tick_view ts c eng v, iret_19_5__tick_shapes alphas0 chains0 ts c eng sk)

-- ---------------------------------------------------------------------
-- The re-time keeps every activation unfired when all were
-- ---------------------------------------------------------------------

--@derives [IRET.19.5]
--@derives [LTIM.2.4.2]
||| A RE-TIMED NODE'S ACTIVATIONS are unfired when the node's were: the
||| matches the tick ends leave, the matches it makes arrive unfired, and
||| every other activation is as it was.
export
iret_19_5__retime_unfired : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (j' : Iret_7_5__join) -> (b : Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                            ((a : Iret_8_1__act) -> Elem a acts -> afired a = False) ->
                            (a : Iret_8_1__act) -> Elem a (snd (iret_19_5__retime wm alphas j' b acts)) -> afired a = False
iret_19_5__retime_unfired wm alphas j' b acts u a e =
  case iret_8_1__activate_inv wm (iret_19_5__born (bjoin b) j' (iret_6_6__mem_at alphas (balpha b)) (blmem b))
                              (iret_8_1__end (iret_19_5__ended (bjoin b) j' (iret_6_6__mem_at alphas (balpha b)) (blmem b)) acts) a e of
    Left e1 => u a (iret_8_1__end_sub (iret_19_5__ended (bjoin b) j' (iret_6_6__mem_at alphas (balpha b)) (blmem b)) acts a e1)
    Right (f, _) => f

--@derives [IRET.19.5]
||| Re-timing a chain keeps its activations unfired when all were. Not
||| Rete/NetworkEdges.idr's `iret_19_5__tick_chain_unfired`, which counts
||| the unfired after a tick from a quiescent chain; this one carries the
||| frame's premise that nothing has fired.
export
iret_19_5__tick_chain_unfired_all : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (t : Maybe Ltim_2_4_1__timed) -> (c : Nat) -> (ch : Rlow_4_2_1__chain) ->
                                    ((a : Iret_8_1__act) -> Elem a (cacts ch) -> afired a = False) ->
                                    (a : Iret_8_1__act) -> Elem a (cacts (iret_19_5__tick_chain wm alphas t c ch)) -> afired a = False
iret_19_5__tick_chain_unfired_all wm alphas Nothing c ch u = u
iret_19_5__tick_chain_unfired_all wm alphas (Just tj) c (MkChain [] acts actions) u = u
iret_19_5__tick_chain_unfired_all wm alphas (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) u =
  iret_19_5__retime_unfired wm alphas (tj c) (MkBeta a j False lm cs) acts u
iret_19_5__tick_chain_unfired_all wm alphas (Just tj) c (MkChain [MkBeta a j True lm cs] acts actions) u = u
iret_19_5__tick_chain_unfired_all wm alphas (Just tj) c (MkChain (MkBeta a j False lm cs :: b2 :: rest) acts actions) u = u
iret_19_5__tick_chain_unfired_all wm alphas (Just tj) c (MkChain (MkBeta a j True lm cs :: b2 :: rest) acts actions) u = u

--@derives [IRET.19.5]
||| Re-timing the chains keeps every activation unfired when all were.
export
iret_19_5__tick_chains_unfired_all : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (chains : List Rlow_4_2_1__chain) ->
                                     Iret_11_3__unfired_all chains -> Iret_11_3__unfired_all (iret_19_5__tick_chains wm alphas ts c chains)
iret_19_5__tick_chains_unfired_all wm alphas [] c chains u = u
iret_19_5__tick_chains_unfired_all wm alphas (t :: ts) c [] u = u
iret_19_5__tick_chains_unfired_all wm alphas (t :: ts) c (ch :: chs) (pu :: pus) =
  iret_19_5__tick_chain_unfired_all wm alphas t c ch pu :: iret_19_5__tick_chains_unfired_all wm alphas ts c chs pus

--@derives [IRET.19.5]
--@derives [LDET.5.8]
||| THE TICK KEEPS EVERY ACTIVATION UNFIRED WHEN ALL WERE: it fires
||| nothing; the matches it makes are born unfired.
export
iret_19_5__tick_unfired_all : (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (eng : Iret_19__engine) ->
                              Iret_11_3__unfired_all (nchains (enet eng)) -> Iret_11_3__unfired_all (nchains (enet (iret_19_5__tick ts c eng)))
iret_19_5__tick_unfired_all ts c eng u = iret_19_5__tick_chains_unfired_all (ewm eng) (nalphas (enet eng)) ts c (nchains (enet eng)) u

-- ---------------------------------------------------------------------
-- The re-time stage, and the prepare that re-times
-- ---------------------------------------------------------------------

--@derives [IRET.19.5]
--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
||| THE RE-TIME STAGE KEEPS THE INVARIANT AND ENDS BETWEEN ACTIONS: the
||| tick changes no fact and no row, so unique ids and the row property
||| stand as they were, the view and the kinds are kept, and the cascade
||| for the rows of the activations the re-time ended reaches its fixpoint.
export
iret_19_5__retime_clocked_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ts : List (Maybe Ltim_2_4_1__timed)) ->
                                (cs : Iret_19_3__clocked_net) ->
                                Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine (iret_19_5__retime_clocked pg ts cs))
iret_19_5__retime_clocked_inv alphas0 chains0 pg ts (MkClockedNet (MkTmsNet eng rows) dl c) ((inv, uq, re), rl) =
  iret_12_2__phase_net_inv_live alphas0 chains0 pg (MkTmsNet (iret_19_5__tick ts c eng) rows)
    (iret_19_5__tick_inv alphas0 chains0 ts c eng inv, uq, re)

--@derives [IRET.19.5]
--@derives [IRET.12.2]
||| THE RE-TIME STAGE KEEPS EVERY ACTIVATION UNFIRED WHEN ALL WERE: the
||| tick fires nothing and the cascade fires nothing.
export
iret_19_5__retime_clocked_unfired : (pg : Lcyc_3_2_1__program) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (cs : Iret_19_3__clocked_net) ->
                                    Iret_19__view (ncore (nengine cs)) -> Iret_11_3__unfired_all (nchains (enet (ncore (nengine cs)))) ->
                                    Iret_11_3__unfired_all (nchains (enet (ncore (nengine (iret_19_5__retime_clocked pg ts cs)))))
iret_19_5__retime_clocked_unfired pg ts (MkClockedNet (MkTmsNet eng rows) dl c) v u =
  iret_12_2__phase_net_unfired pg (MkTmsNet (iret_19_5__tick ts c eng) rows) (iret_19_5__tick_view ts c eng v) (iret_19_5__tick_unfired_all ts c eng u)

--@derives [RARC.5.6.3]
--@derives [IRET.19.5]
||| A PREPARE WITH A RE-TIME keeps the invariant and ends between actions:
||| a tick advances, sweeps, re-times and cascades; a data event sweeps and
||| applies, as on Rete/NetworkTtl.idr's engine.
export
rarc_5_6_3__prepare_clocked_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                                  (ts : List (Maybe Ltim_2_4_1__timed)) -> (inp : Rarc_5_6_2__input) -> (cs : Iret_19_3__clocked_net) ->
                                  Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine (rarc_5_6_3__prepare_clocked pg ttl ts inp cs))
rarc_5_6_3__prepare_clocked_inv alphas0 chains0 pg ttl ts (Tick t) cs inv =
  iret_19_5__retime_clocked_inv alphas0 chains0 pg ts (rarc_5_6_3__prepare_net pg ttl (Tick t) cs) (rarc_5_6_3__prepare_net_inv alphas0 chains0 pg ttl (Tick t) cs inv)
rarc_5_6_3__prepare_clocked_inv alphas0 chains0 pg ttl ts (Data ev) cs inv = rarc_5_6_3__prepare_net_inv alphas0 chains0 pg ttl (Data ev) cs inv

--@derives [RARC.5.6.3]
--@derives [IRET.19.5]
||| A PREPARE WITH A RE-TIME leaves every activation unfired when all were:
||| it retracts, asserts, re-times and cascades, and none of those fires.
export
rarc_5_6_3__prepare_clocked_unfired : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                                      (ts : List (Maybe Ltim_2_4_1__timed)) -> (inp : Rarc_5_6_2__input) -> (cs : Iret_19_3__clocked_net) ->
                                      Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Iret_11_3__unfired_all (nchains (enet (ncore (nengine cs)))) ->
                                      Iret_11_3__unfired_all (nchains (enet (ncore (nengine (rarc_5_6_3__prepare_clocked pg ttl ts inp cs)))))
rarc_5_6_3__prepare_clocked_unfired alphas0 chains0 pg ttl ts (Tick t) cs inv u =
  iret_19_5__retime_clocked_unfired pg ts (rarc_5_6_3__prepare_net pg ttl (Tick t) cs)
    (fst (fst (fst (rarc_5_6_3__prepare_net_inv alphas0 chains0 pg ttl (Tick t) cs inv))))
    (rarc_5_6_3__prepare_net_unfired alphas0 chains0 pg ttl (Tick t) cs inv u)
rarc_5_6_3__prepare_clocked_unfired alphas0 chains0 pg ttl ts (Data ev) cs inv u = rarc_5_6_3__prepare_net_unfired alphas0 chains0 pg ttl (Data ev) cs inv u

--@spec [RARC.5.6.3]
--@spec [IRET.19.5]
--@spec [LFST.9.2.1]
||| INPUTS PREPARED WITH NO RUN BETWEEN THEM, on the engine with the
||| re-time: Rete/NetworkFrameClocked.idr's `rarc_5_6_3__prepared_net` with
||| Rete/NetworkClocked.idr's prepare.
public export
rarc_5_6_3__prepared_clocked : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> List Rarc_5_6_2__input -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_3__prepared_clocked pg ttl ts [] cs = cs
rarc_5_6_3__prepared_clocked pg ttl ts (inp :: inps) cs = rarc_5_6_3__prepared_clocked pg ttl ts inps (rarc_5_6_3__prepare_clocked pg ttl ts inp cs)

--@derives [RARC.5.6.3]
||| Prepared inputs compose: the inputs of two lists in order are the
||| second list's prepared after the first's.
export
rarc_5_6_3__prepared_clocked_append : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (xs, ys : List Rarc_5_6_2__input) -> (cs : Iret_19_3__clocked_net) ->
                                      rarc_5_6_3__prepared_clocked pg ttl ts (xs ++ ys) cs = rarc_5_6_3__prepared_clocked pg ttl ts ys (rarc_5_6_3__prepared_clocked pg ttl ts xs cs)
rarc_5_6_3__prepared_clocked_append pg ttl ts [] ys cs = Refl
rarc_5_6_3__prepared_clocked_append pg ttl ts (x :: xs) ys cs = rarc_5_6_3__prepared_clocked_append pg ttl ts xs ys (rarc_5_6_3__prepare_clocked pg ttl ts x cs)

--@derives [RARC.5.6.3]
export
rarc_5_6_3__prepared_clocked_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                                   (ts : List (Maybe Ltim_2_4_1__timed)) -> (inps : List Rarc_5_6_2__input) -> (cs : Iret_19_3__clocked_net) ->
                                   Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps cs))
rarc_5_6_3__prepared_clocked_inv alphas0 chains0 pg ttl ts [] cs inv = inv
rarc_5_6_3__prepared_clocked_inv alphas0 chains0 pg ttl ts (inp :: inps) cs inv =
  rarc_5_6_3__prepared_clocked_inv alphas0 chains0 pg ttl ts inps (rarc_5_6_3__prepare_clocked pg ttl ts inp cs)
    (rarc_5_6_3__prepare_clocked_inv alphas0 chains0 pg ttl ts inp cs inv)

--@derives [RARC.5.6.3]
export
rarc_5_6_3__prepared_clocked_unfired : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                                       (ts : List (Maybe Ltim_2_4_1__timed)) -> (inps : List Rarc_5_6_2__input) -> (cs : Iret_19_3__clocked_net) ->
                                       Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Iret_11_3__unfired_all (nchains (enet (ncore (nengine cs)))) ->
                                       Iret_11_3__unfired_all (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps cs)))))
rarc_5_6_3__prepared_clocked_unfired alphas0 chains0 pg ttl ts [] cs inv u = u
rarc_5_6_3__prepared_clocked_unfired alphas0 chains0 pg ttl ts (inp :: inps) cs inv u =
  rarc_5_6_3__prepared_clocked_unfired alphas0 chains0 pg ttl ts inps (rarc_5_6_3__prepare_clocked pg ttl ts inp cs)
    (rarc_5_6_3__prepare_clocked_inv alphas0 chains0 pg ttl ts inp cs inv) (rarc_5_6_3__prepare_clocked_unfired alphas0 chains0 pg ttl ts inp cs inv u)

-- ---------------------------------------------------------------------
-- THE THEOREM
-- ---------------------------------------------------------------------

--@derives [IRET.11.3]
--@derives [IRET.7.7]
--@derives [IRET.11.1]
--@derives [LDET.5.3]
--@derives [LTIM.2.5.1]
--@derives [IRET.12.2]
--@derives [IRET.19.5]
--@derives [RDSC.4a.5]
||| ONCE PER MATCH UNDER THE GENERAL FRAME, WITH TRUTH MAINTENANCE, THE
||| CLOCK AND THE RE-TIME. From the loaded clocked network, after any
||| inputs -- data events, and ticks that sweep and re-time every timed
||| chain -- prepared with no run between them, a run that reaches
||| quiescence fires a framed chain exactly as many times as it has matches
||| when the run begins: the matches the ticks made counted, the matches
||| they ended not. Rete/NetworkFrameClocked.idr's theorem with
||| Rete/NetworkClocked.idr's prepare.
export
iret_11_3__framed_fires_once_per_match_clocked : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (fuel : Nat) -> (c0 : Nat) -> (inps : List Rarc_5_6_2__input) ->
                                                 (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                                 (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                                 ltim_2_5_1__framed (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) nodes = True ->
                                                 rarc_5_6_5__nth ci (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0)))))) = Just (MkChain nodes acts actions) ->
                                                 (cs' : Iret_19_3__clocked_net) -> (h : Iret_11_4__halt) -> (tr : List Nat) ->
                                                 iret_11_4__run_ttl_net_traced pg ttl fuel (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0)) = (cs', h, tr) ->
                                                 h = Quiescent ->
                                                 ltim_2_5_1__count ci tr
                                                   = length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0))))))
                                                                            (ewm (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0))))) nodes [[]])
iret_11_3__framed_fires_once_per_match_clocked pg ttl ts fuel c0 inps alphas rules ci nodes acts actions fr n cs' h tr rt hq =
  let inv0 = rarc_5_6_3__prepared_clocked_inv (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) pg ttl ts inps
               (rdsc_4a_5__load_clocked alphas rules c0) (rdsc_4a_5__load_clocked_inv alphas rules c0)
      v = the (Iret_19__view (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0))))) (fst (fst (fst inv0)))
      (e1 ** h1 ** tr1 ** acts' ** (rt1, _, _, _, cnt, qz)) =
        ltim_2_5_1__run_frame_ttl (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) pg ttl fuel
          (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0)) inv0 ci nodes acts actions fr n
      same = the ((e1, h1, tr1) = (cs', h, tr)) (trans (sym rt1) rt)
      trEq = the (tr1 = tr) (cong (\z => snd (snd z)) same)
      hEq = the (h1 = h) (cong (\z => fst (snd z)) same)
      zero = the (iret_11_4__unfired acts' = 0) (qz (trans hEq hq))
      cntTr = the (ltim_2_5_1__count ci tr = iret_11_4__unfired acts)
                (trans (cong (ltim_2_5_1__count ci) (sym trEq)) (trans (sym (plusZeroLeftNeutral _)) (trans (cong (\z => z + ltim_2_5_1__count ci tr1) (sym zero)) cnt)))
      allUnfired = the ((a : Iret_8_1__act) -> Elem a acts -> afired a = False)
                     (lcyc_1_1__all_lookup (rarc_5_6_3__prepared_clocked_unfired (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) pg ttl ts inps
                                              (rdsc_4a_5__load_clocked alphas rules c0) (rdsc_4a_5__load_clocked_inv alphas rules c0) (rdsc_4a_5__load_unfired alphas rules))
                        (lcyc_1_1__nth_elem ci (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0)))))) n))
      (ss, dt) = snd (rarc_5_6_5__view_recomputed (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0)))) v) (MkChain nodes acts actions)
                   (lcyc_1_1__nth_elem ci (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0)))))) n)
      lenView = the (length (iret_8_1__tuples acts)
                     = length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0))))))
                                              (ewm (ncore (nengine (rarc_5_6_3__prepared_clocked pg ttl ts inps (rdsc_4a_5__load_clocked alphas rules c0))))) nodes [[]]))
                  (iret_11_3__distinct_same_set_length _ _ dt
                     (rarc_5_6_5__view_distinct _ _ (fst v) nodes [[]] (DCons (\e => absurd e) DNil)) ss)
  in trans cntTr (trans (iret_11_4__unfired_is_length acts allUnfired) (trans (sym (lengthMap acts)) lenView))

-- ---------------------------------------------------------------------
-- Executed: a gate that opens on a tick, and one that shuts
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.5.1]
||| THE GATE THAT OPENS: a time-dependent test that admits every pair once
||| the clock has reached 1, and none before. Named, so that the re-timed
||| node's test is spelled `ltim_2_5_1__opens_at_one 1` in a literal and
||| the checker compares it syntactically.
public export
ltim_2_5_1__opens_at_one : Ltim_2_4_1__timed
ltim_2_5_1__opens_at_one c = \t, f => 1 <= c

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.5.1]
||| THE GATE THAT SHUTS: open at clock 0, shut from clock 1 on.
public export
ltim_2_5_1__shuts_at_one : Ltim_2_4_1__timed
ltim_2_5_1__shuts_at_one c = \t, f => c <= 0

--@spec [LTIM.2.5.1]
--@spec [IRET.12.2]
||| THE RULES WITH THE OPENING GATE: Rete/NetworkFrameClocked.idr's two
||| rules, B first, with A's test the opening gate as read at clock 0, the
||| clock the network is loaded at.
public export
ltim_2_5_1__rules_gated : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltim_2_5_1__rules_gated =
  [ ([(1, iret_7_7__row, False)], ltim_2_5_1__emit_two_withdraw)
  , ([(0, ltim_2_5_1__opens_at_one 0, False)], ltim_2_5_1__emit_one) ]

--@spec [LTIM.2.5.1]
--@spec [IRET.12.2]
||| THE RULES WITH THE SHUTTING GATE: the same, with A's test the shutting
||| gate as read at clock 0.
public export
ltim_2_5_1__rules_shutting : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltim_2_5_1__rules_shutting =
  [ ([(1, iret_7_7__row, False)], ltim_2_5_1__emit_two_withdraw)
  , ([(0, ltim_2_5_1__shuts_at_one 0, False)], ltim_2_5_1__emit_one) ]

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.5.1]
--@spec [IRET.19.5]
||| THE TIMED TESTS, by ordinal: B has none; A, at ordinal 1, the opening gate.
public export
ltim_2_5_1__gates : List (Maybe Ltim_2_4_1__timed)
ltim_2_5_1__gates = [Nothing, Just ltim_2_5_1__opens_at_one]

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.5.1]
--@spec [IRET.19.5]
||| THE TIMED TESTS of the shutting fixture: B none; A the shutting gate.
public export
ltim_2_5_1__shutters : List (Maybe Ltim_2_4_1__timed)
ltim_2_5_1__shutters = [Nothing, Just ltim_2_5_1__shuts_at_one]

--@spec [LTIM.2.5.1]
--@spec [IRET.12.2]
||| THE PROGRAM with the opening gate: kind 2 a relation, so B's emit
||| records a row and B's withdrawal ends the activation that recorded it;
||| kinds 0 and 1 explicit.
public export
ltim_2_5_1__two_rules_gated : Lcyc_3_2_1__program
ltim_2_5_1__two_rules_gated =
  lcyc_3_2_1__program_of (\k => if k == 2 then Relation else Explicit) (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated))

--@spec [LTIM.2.5.1]
--@spec [IRET.12.2]
||| THE PROGRAM with the shutting gate.
public export
ltim_2_5_1__two_rules_shutting : Lcyc_3_2_1__program
ltim_2_5_1__two_rules_shutting =
  lcyc_3_2_1__program_of (\k => if k == 2 then Relation else Explicit) (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_shutting))

--@spec [LTIM.2.5.1]
--@spec [RARC.5.6.3]
||| THE INPUTS: one kind-0 fact at clock 0, then a tick to 1, prepared with
||| no run between them. The tick re-times A's node.
public export
ltim_2_5_1__fact_then_tick : List Rarc_5_6_2__input
ltim_2_5_1__fact_then_tick = [Data (Assert 0 1 0), Tick 1]

--@spec [LTIM.2.5.1]
||| THE NETWORK AS THE INPUTS LEFT IT, the opening gate: the loaded clocked
||| network at clock 0, the fact asserted, the tick taken, no run after
||| them. A holds the one match the tick made, unfired; B holds none.
public export
ltim_2_5_1__gated_ready : Iret_19_3__clocked_net
ltim_2_5_1__gated_ready =
  rarc_5_6_3__prepared_clocked ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl ltim_2_5_1__gates ltim_2_5_1__fact_then_tick
    (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated 0)

--@spec [LTIM.2.5.1]
||| THE NETWORK AS THE INPUTS LEFT IT, the shutting gate: the fact
||| asserted while the gate was open, the tick that shut it taken, no run
||| after them. A holds no match; B holds none.
public export
ltim_2_5_1__shut_ready : Iret_19_3__clocked_net
ltim_2_5_1__shut_ready =
  rarc_5_6_3__prepared_clocked ltim_2_5_1__two_rules_shutting ltim_2_5_1__no_ttl ltim_2_5_1__shutters ltim_2_5_1__fact_then_tick
    (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_shutting 0)

--@derives [LTIM.2.5.1]
||| A IS FRAMED in the gated program, with its node re-timed: the frame
||| reads the node's alpha and nothing of its test. Computed.
export
ltim_2_5_1__a_is_framed_gated :
  ltim_2_5_1__framed (nalphas (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated)))
                     (nchains (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated)))
                     [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] = True
ltim_2_5_1__a_is_framed_gated = Refl

--@derives [LTIM.2.5.1]
||| A IS FRAMED in the shutting program, with its node re-timed. Computed.
export
ltim_2_5_1__a_is_framed_shutting :
  ltim_2_5_1__framed (nalphas (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_shutting)))
                     (nchains (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_shutting)))
                     [MkBeta 0 (ltim_2_5_1__shuts_at_one 1) False [[]] []] = True
ltim_2_5_1__a_is_framed_shutting = Refl

--@derives [LTIM.2.4.1]
--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.3]
||| THE GATE SHUT, NO MATCH: the kind-0 fact asserted at clock 0, before
||| any tick, gives A no activation -- its test at clock 0 refuses every
||| pair -- and its node keeps the test it was loaded with. Computed.
|||
||| The fixtures from here evaluate the tick, whose clock advance is
||| Rete/TtlSweep.idr's `rarc_5_6_3__next_clock`, guarded by Rete/TmsRun.idr's
||| `iret_12__lte_b`; a function unfolds only if its module is imported by
||| the file, which is why this module imports Rete.TmsRun (without it a
||| witness sticks on `next_clock 0 1`).
export
ltim_2_5_1__gate_shut_no_match :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_clocked ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl ltim_2_5_1__gates [Data (Assert 0 1 0)]
                                                      (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated 0))))))
    = Just (MkChain [MkBeta 0 (ltim_2_5_1__opens_at_one 0) False [[]] []] [] ltim_2_5_1__emit_one)
ltim_2_5_1__gate_shut_no_match = Refl

--@derives [LTIM.2.4.2]
--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
--@derives [RARC.5.6.3]
||| THE CHAIN AS THE TICK LEFT IT: the clock advanced to 1, A's node
||| re-timed to the gate as read at 1, the one match born unfired. The
||| re-time of RARC.5.6.3's tick, executed. Computed.
export
ltim_2_5_1__gated_ready_chain :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine ltim_2_5_1__gated_ready))))
    = Just (MkChain [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [MkAct [MkFact 0 0 1 0] False] ltim_2_5_1__emit_one)
ltim_2_5_1__gated_ready_chain = Refl

--@derives [RARC.5.6.3]
--@derives [LTIM.2.5.1]
||| And the clock is at 1. Computed.
export
ltim_2_5_1__gated_clock : nclock ltim_2_5_1__gated_ready = 1
ltim_2_5_1__gated_clock = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.12.2]
--@derives [IRET.11.3]
||| THE TRACE, AFTER THE GATE OPENED: A fires for the match the tick made
||| and emits a kind-1 fact; B, now matched and at the lower ordinal,
||| fires next, emitting its kind-2 fact and withdrawing the kind-1 fact
||| it matched, which ends its activation, and the cascade that follows
||| retracts the kind-2 fact it had just recorded. `[1, 0]`, quiescent, and
||| only the kind-0 fact remains. Executed, with fuel 3.
export
ltim_2_5_1__gated_trace :
  iret_11_4__trace_of_ttl (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl 3 ltim_2_5_1__gated_ready)
    = ([1, 0], Quiescent, [0])
ltim_2_5_1__gated_trace = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
--@derives [IRET.19.5]
||| THE THEOREM AT THE OPENING FIXTURE: the frame and the chain as the tick
||| left it discharged by computation, the run and the halt by the trace
||| above, and the count of A's firings is the number of matches it held
||| when the run began, the one the tick made. Executed.
export
ltim_2_5_1__gated_is_an_instance :
  ltim_2_5_1__count 1 [1, 0]
    = length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_5_1__gated_ready)))) (ewm (ncore (nengine ltim_2_5_1__gated_ready)))
                             [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [[]])
ltim_2_5_1__gated_is_an_instance =
  let (cs' ** rt) = iret_11_4__trace_of_ttl_inv (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl 3 ltim_2_5_1__gated_ready)
                      [1, 0] Quiescent [0] ltim_2_5_1__gated_trace
  in iret_11_3__framed_fires_once_per_match_clocked ltim_2_5_1__two_rules_gated ltim_2_5_1__no_ttl ltim_2_5_1__gates 3 0 ltim_2_5_1__fact_then_tick
       ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated
       1 [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [MkAct [MkFact 0 0 1 0] False] ltim_2_5_1__emit_one
       ltim_2_5_1__a_is_framed_gated ltim_2_5_1__gated_ready_chain cs' Quiescent [1, 0] rt Refl

--@derives [LTIM.2.5.1]
||| And the number is one: the gate opened on the tick, A had one match
||| when the run began and fired once, through B's cascade. Computed.
export
ltim_2_5_1__gated_fires_once :
  ( ltim_2_5_1__count 1 [1, 0]
  , length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_5_1__gated_ready)))) (ewm (ncore (nengine ltim_2_5_1__gated_ready)))
                           [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [[]]) ) = (1, 1)
ltim_2_5_1__gated_fires_once = Refl

--@derives [LTIM.2.4.1]
--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.3]
||| THE GATE OPEN, A MATCH: the kind-0 fact asserted at clock 0, before any
||| tick, gives A an activation under the shutting gate -- its test at
||| clock 0 admits every pair. Computed.
export
ltim_2_5_1__gate_open_match :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_clocked ltim_2_5_1__two_rules_shutting ltim_2_5_1__no_ttl ltim_2_5_1__shutters [Data (Assert 0 1 0)]
                                                      (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_shutting 0))))))
    = Just (MkChain [MkBeta 0 (ltim_2_5_1__shuts_at_one 0) False [[]] []] [MkAct [MkFact 0 0 1 0] False] ltim_2_5_1__emit_one)
ltim_2_5_1__gate_open_match = Refl

--@derives [LTIM.2.4.2]
--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
--@derives [RARC.5.6.3]
||| THE CHAIN AS THE SHUTTING TICK LEFT IT: A's node re-timed to the gate
||| as read at 1, which refuses the pair, and the match ended -- no
||| activation, fired or not ([LTIM.2.5.1]: a condition that closes ends
||| the match). Computed.
export
ltim_2_5_1__shut_ready_chain :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine ltim_2_5_1__shut_ready))))
    = Just (MkChain [MkBeta 0 (ltim_2_5_1__shuts_at_one 1) False [[]] []] [] ltim_2_5_1__emit_one)
ltim_2_5_1__shut_ready_chain = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
||| THE TRACE, AFTER THE GATE SHUT: nothing fires; the kind-0 fact stays.
||| `[]`, quiescent. Executed, with fuel 3.
export
ltim_2_5_1__shut_trace :
  iret_11_4__trace_of_ttl (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_shutting ltim_2_5_1__no_ttl 3 ltim_2_5_1__shut_ready)
    = ([], Quiescent, [0])
ltim_2_5_1__shut_trace = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
--@derives [IRET.19.5]
||| THE THEOREM AT THE SHUTTING FIXTURE: the frame and the chain as the
||| tick left it by computation, the run and the halt by the trace above,
||| and the count of A's firings is the number of matches it held when the
||| run began -- none, the tick having ended the one it had. Executed.
export
ltim_2_5_1__shut_is_an_instance :
  ltim_2_5_1__count 1 []
    = length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_5_1__shut_ready)))) (ewm (ncore (nengine ltim_2_5_1__shut_ready)))
                             [MkBeta 0 (ltim_2_5_1__shuts_at_one 1) False [[]] []] [[]])
ltim_2_5_1__shut_is_an_instance =
  let (cs' ** rt) = iret_11_4__trace_of_ttl_inv (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_shutting ltim_2_5_1__no_ttl 3 ltim_2_5_1__shut_ready)
                      [] Quiescent [0] ltim_2_5_1__shut_trace
  in iret_11_3__framed_fires_once_per_match_clocked ltim_2_5_1__two_rules_shutting ltim_2_5_1__no_ttl ltim_2_5_1__shutters 3 0 ltim_2_5_1__fact_then_tick
       ltim_2_5_1__alphas_three ltim_2_5_1__rules_shutting
       1 [MkBeta 0 (ltim_2_5_1__shuts_at_one 1) False [[]] []] [] ltim_2_5_1__emit_one
       ltim_2_5_1__a_is_framed_shutting ltim_2_5_1__shut_ready_chain cs' Quiescent [] rt Refl

--@derives [LTIM.2.5.1]
||| And the number is none: the gate shut on the tick, A held no match
||| when the run began and did not fire. Computed.
export
ltim_2_5_1__shut_fires_none :
  ( ltim_2_5_1__count 1 []
  , length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_5_1__shut_ready)))) (ewm (ncore (nengine ltim_2_5_1__shut_ready)))
                           [MkBeta 0 (ltim_2_5_1__shuts_at_one 1) False [[]] []] [[]]) ) = (0, 0)
ltim_2_5_1__shut_fires_none = Refl

-- ---------------------------------------------------------------------
-- Executed: a tick that sweeps and re-times in one prepare (unit T's
-- first owed witness)
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
--@spec [IRET.19.3]
||| THE TTL OF THE SWEPT FIXTURE: one for kind 0, none for the rest. Named,
||| as `ltim_2_5_1__no_ttl` is, so that every statement spells it the same way.
public export
ltim_2_5_1__ttl_one : Iret_4_2__ttl
ltim_2_5_1__ttl_one Z = 1
ltim_2_5_1__ttl_one (S _) = 0

--@spec [LTIM.2.5.1]
--@spec [RARC.5.6.3]
||| THE NETWORK AS THE SWEPT INPUTS LEFT IT: the opening gate's program and
||| inputs under `ttl_one`. The kind-0 fact asserted at clock 0 has deadline
||| 1; the tick to 1 sweeps it before the re-time, so the gate opens on
||| nothing.
public export
ltim_2_5_1__swept_ready : Iret_19_3__clocked_net
ltim_2_5_1__swept_ready =
  rarc_5_6_3__prepared_clocked ltim_2_5_1__two_rules_gated ltim_2_5_1__ttl_one ltim_2_5_1__gates ltim_2_5_1__fact_then_tick
    (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated 0)

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.3]
--@derives [IRET.19.3]
--@derives [IRET.19.5]
||| THE SWEPT STATE AS A LITERAL: working memory, every alpha memory and
||| every terminal empty; A's node re-timed to the gate as read at 1; the
||| deadline table keeping the swept fact's row, as Rete/NetworkFrameClocked.idr's
||| ticked fixture has it; the clock at 1. The sweep before the re-time, seen
||| under the frame: had the re-time run first, A would hold the match the
||| gate made. Computed once; the claims below reach the state through this
||| equation.
export
ltim_2_5_1__swept_ready_ttl :
  ltim_2_5_1__swept_ready
    = MkClockedNet (MkTmsNet (MkEngine []
                                       (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                                  [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                                  , MkChain [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [] ltim_2_5_1__emit_one ]))
                             []) [(0, 1)] 1
ltim_2_5_1__swept_ready_ttl = Refl

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.3]
||| THE CHAIN AS THE SWEPT TICK LEFT IT: A re-timed, holding no match. Read
||| off the literal.
export
ltim_2_5_1__swept_chain :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine ltim_2_5_1__swept_ready))))
    = Just (MkChain [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [] ltim_2_5_1__emit_one)
ltim_2_5_1__swept_chain =
  replace {p = \x => rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine x))))
                     = Just (MkChain [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [] ltim_2_5_1__emit_one)}
          (sym ltim_2_5_1__swept_ready_ttl) Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
||| THE TRACE FROM THE SWEPT STATE: nothing fires and nothing is live. `[]`,
||| quiescent. Executed, with fuel 3.
export
ltim_2_5_1__swept_trace :
  iret_11_4__trace_of_ttl (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_gated ltim_2_5_1__ttl_one 3 ltim_2_5_1__swept_ready)
    = ([], Quiescent, [])
ltim_2_5_1__swept_trace = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
--@derives [IRET.19.5]
--@derives [RARC.5.6.3]
||| THE THEOREM AT THE SWEPT FIXTURE: the prepare's `Tick` case with a
||| deadline at the clock AND a timed chain, in one tick; the count of A's
||| firings is the number of matches it held when the run began -- none, the
||| fact swept before the gate opened. Executed.
export
ltim_2_5_1__swept_is_an_instance :
  ltim_2_5_1__count 1 []
    = length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_5_1__swept_ready)))) (ewm (ncore (nengine ltim_2_5_1__swept_ready)))
                             [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [[]])
ltim_2_5_1__swept_is_an_instance =
  let (cs' ** rt) = iret_11_4__trace_of_ttl_inv (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_gated ltim_2_5_1__ttl_one 3 ltim_2_5_1__swept_ready)
                      [] Quiescent [] ltim_2_5_1__swept_trace
  in iret_11_3__framed_fires_once_per_match_clocked ltim_2_5_1__two_rules_gated ltim_2_5_1__ttl_one ltim_2_5_1__gates 3 0 ltim_2_5_1__fact_then_tick
       ltim_2_5_1__alphas_three ltim_2_5_1__rules_gated
       1 [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [] ltim_2_5_1__emit_one
       ltim_2_5_1__a_is_framed_gated ltim_2_5_1__swept_chain cs' Quiescent [] rt Refl

--@derives [LTIM.2.5.1]
||| And the number is none: swept, then opened on nothing. Computed.
export
ltim_2_5_1__swept_fires_none :
  ( ltim_2_5_1__count 1 []
  , length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_5_1__swept_ready)))) (ewm (ncore (nengine ltim_2_5_1__swept_ready)))
                           [MkBeta 0 (ltim_2_5_1__opens_at_one 1) False [[]] []] [[]]) ) = (0, 0)
ltim_2_5_1__swept_fires_none = Refl

-- ---------------------------------------------------------------------
-- Executed: a re-time that ends a fired logical activation, so the
-- cascade after it has a row to drop (unit T's second owed witness)
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| B's RHS WITHOUT THE WITHDRAW: emit a kind-2 fact and keep the match, so
||| that the activation that recorded the row stays fired and live until
||| something else ends it.
public export
ltim_2_5_1__emit_two : List Lgra_10_1__action
ltim_2_5_1__emit_two = [Emit 2 (\b => (0, 0))]

--@spec [LTIM.2.5.1]
--@spec [IRET.12.2]
||| THE RULES WITH B UNDER THE SHUTTING GATE: B first, reading kind 1 under
||| the shutting gate as read at clock 0 and emitting kind 2 with no
||| withdraw; A reading kind 0 and emitting kind 1, untimed.
public export
ltim_2_5_1__rules_b_shutting : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltim_2_5_1__rules_b_shutting =
  [ ([(1, ltim_2_5_1__shuts_at_one 0, False)], ltim_2_5_1__emit_two)
  , ([(0, iret_7_7__row, False)], ltim_2_5_1__emit_one) ]

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.5.1]
--@spec [IRET.19.5]
||| THE TIMED TESTS of that fixture, by ordinal: B, at ordinal 0, the
||| shutting gate; A none.
public export
ltim_2_5_1__b_shutters : List (Maybe Ltim_2_4_1__timed)
ltim_2_5_1__b_shutters = [Just ltim_2_5_1__shuts_at_one, Nothing]

--@spec [LTIM.2.5.1]
--@spec [IRET.12.2]
||| THE PROGRAM with B under the shutting gate: kind 2 a relation, so B's
||| emit records a row; kinds 0 and 1 explicit.
public export
ltim_2_5_1__two_rules_b_shutting : Lcyc_3_2_1__program
ltim_2_5_1__two_rules_b_shutting =
  lcyc_3_2_1__program_of (\k => if k == 2 then Relation else Explicit) (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_shutting))

--@spec [LTIM.2.5.1]
||| THE NETWORK with the kind-0 fact asserted at clock 0, no run after it.
public export
ltim_2_5_1__fired_ready : Iret_19_3__clocked_net
ltim_2_5_1__fired_ready =
  rarc_5_6_3__prepared_clocked ltim_2_5_1__two_rules_b_shutting ltim_2_5_1__no_ttl ltim_2_5_1__b_shutters [Data (Assert 0 1 0)]
    (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_shutting 0)

--@spec [LTIM.2.5.1]
--@spec [IRET.11.4]
||| THE RUN FROM IT, with fuel 3: A fires and emits the kind-1 fact; B,
||| matched under the open gate, fires and emits the kind-2 fact, which is
||| logical, so its row is recorded; B's activation stays fired and live.
||| Named, so that the tick after it is spelled once.
public export
ltim_2_5_1__fired_run : (Iret_19_3__clocked_net, Iret_11_4__halt, List Nat)
ltim_2_5_1__fired_run = iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_b_shutting ltim_2_5_1__no_ttl 3 ltim_2_5_1__fired_ready

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
--@derives [IRET.10.2]
||| THE TRACE OF THAT RUN: `[1, 0]`, quiescent, the three facts live.
||| Executed.
export
ltim_2_5_1__fired_trace : iret_11_4__trace_of_ttl ltim_2_5_1__fired_run = ([1, 0], Quiescent, [0, 1, 2])
ltim_2_5_1__fired_trace = Refl

--@derives [IRET.10.2]
--@derives [IRET.12.4]
--@derives [LTIM.2.5.1]
||| THE ROW B's EMIT RECORDED: one row, targeting the kind-2 fact, id 2.
||| Computed.
export
ltim_2_5_1__fired_row : map rtarget (ndeps (nengine (fst ltim_2_5_1__fired_run))) = [2]
ltim_2_5_1__fired_row = Refl

--@spec [LTIM.2.5.1]
--@spec [RARC.5.6.3]
||| THE TICK AFTER THE RUN: to 1, where B's gate shuts. The re-time ends B's
||| fired activation, and the cascade for its row follows.
public export
ltim_2_5_1__fired_then_tick : Iret_19_3__clocked_net
ltim_2_5_1__fired_then_tick =
  rarc_5_6_3__prepare_clocked ltim_2_5_1__two_rules_b_shutting ltim_2_5_1__no_ttl ltim_2_5_1__b_shutters (Tick 1) (fst ltim_2_5_1__fired_run)

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| B's CHAIN AS THAT TICK LEFT IT: re-timed to the gate as read at 1, its
||| fired activation ended -- none remains, fired or not. Computed.
export
ltim_2_5_1__ended_fired_chain :
  rarc_5_6_5__nth 0 (nchains (enet (ncore (nengine ltim_2_5_1__fired_then_tick))))
    = Just (MkChain [MkBeta 1 (ltim_2_5_1__shuts_at_one 1) False [[]] []] [] ltim_2_5_1__emit_two)
ltim_2_5_1__ended_fired_chain = Refl

--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| THE CASCADE AFTER THE RE-TIME, WITH A ROW TO DROP: the ended activation's
||| row is gone from the table and the kind-2 fact it alone supported is
||| retracted; the kind-0 and kind-1 facts stay. `iret_19_5__retime_clocked_inv`'s
||| non-trivial case, executed. Computed.
export
ltim_2_5_1__ended_fired_cascade :
  ( map rtarget (ndeps (nengine ltim_2_5_1__fired_then_tick))
  , map fkind (ewm (ncore (nengine ltim_2_5_1__fired_then_tick))) ) = ([], [0, 1])
ltim_2_5_1__ended_fired_cascade = Refl

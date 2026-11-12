-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| ONE CLOCKED NETWORK ENGINE: Rete/NetworkTtl.idr's tables and clock with
||| Rete/NetworkTick.idr's time-dependent tests, and one tick that does
||| what both did. The clocked-network programme's part A.
|||
||| NORMATIVE COMPANION to the two modules it composes.
|||
||| WHY. Two network engines carried time and did not meet. NetworkTtl's has
||| the dependency table, the deadline table and the clock, and join tests
||| that are predicates of facts; NetworkTick's has one timed test per
||| single-pattern chain, read at the clock, and nothing else. Each proved
||| its half of [LDET.5.8]'s "cycling the tick is not a change to the LHS",
||| and each half was `partial` because the two engines were not one. Here
||| they are one.
|||
||| THE TICK, in [IRET.19.5]'s order: advance the clock (RARC.5.6.3, step 1);
||| sweep every fact whose deadline is at or before it, one at a time in
||| [LDTL.6.1]'s order, then the cascade (step 2, `ds_rete_wm_tick`: Ttl's
||| `rarc_5_6_3__prepare_net`); re-time every timed chain at the new clock
||| (step 3, the re-evaluation: Tick's `iret_19_5__tick`); then the cascade
||| again, for the rows of the activations the re-time ended ([LTIM.2.7.2]).
||| [IRET.19.5] runs these as the PUMP begins; this model runs them as the
||| tick is consumed, which is the same state once the pump runs
||| (Rete/TtlSweep.idr's header on the placement).
||| A data input is Ttl's: it carries no clock in this module (RARC.5.6.3
||| samples both clocks at every input; the sample a data input takes is
||| Rete/NetworkTimed.idr's `ltim_2_8_6__input_timed`), so here it re-times
||| nothing. The run to
||| quiescence is Ttl's
||| (`iret_11_4__run_ttl_net`); a pump is the prepare then the run.
|||
||| PROVED.
|||
|||   * A1, A TICK THAT EXPIRES NOTHING AND MOVES NO VERDICT MOVES ONLY THE
|||     CLOCK (`ldet_5_8__quiet_tick_clocked`): from a state between actions,
|||     when no deadline is at or before the new clock and every timed test
|||     answers at the new clock what the node's test answered on every live
|||     pair, the composed tick leaves working memory, every chain's
|||     activations (tuples and `fired` flags) and left memories, the
|||     dependency table and the deadline table as they were. Stated on
|||     those parts and not on the node records: a re-timed node carries a
|||     new function that is only pointwise the old one. [LDET.5.8] for one
|||     engine with both kinds of test, which is what its `partial` on Ttl
|||     lacked.
|||   * A2, THE TICK KEEPS THE VIEW (`iret_19_5__tick_clocked_view`): the
|||     sweep is retractions and the cascade is retractions, each of which
|||     keeps NetworkDispatch's view; the re-time keeps it chain by chain
|||     (Tick's `iret_19_5__retime_consistent`, whose front for a single-node
|||     chain is the nil token). So the view theorem holds across every
|||     composed tick.
|||   * A3, TICK'S THEOREMS ON THIS ENGINE, for the timed chain at any
|||     ordinal: an activation whose match the new clock still admits is the
|||     same record (`ldet_5_8__tick_keeps_activation_clocked`); a condition
|||     that closes ends the match (`ltim_2_5_1__closing_ends_clocked`); a
|||     reopening is unfired (`ltim_2_5_1__reopening_is_unfired_clocked`);
|||     after a quiescent pump the tick leaves unfired only what it made, and
|||     everything it made (`ltim_2_4_2__unfired_are_born_clocked`,
|||     `ltim_2_4_2__born_unfired_clocked`); a match is made by at most one
|||     of two successive ticks, for any gate (`ltim_2_5_1__edge_once_clocked`).
|||     Each is stated on the RE-TIME STAGE of the composed tick, and
|||     `ltim_2_7_2__no_cascade_is_the_retime` says when that stage IS the
|||     tick's result: when no row ends under it, which holds of every program
|||     whose timed rules support no logical fact.
|||   * EXECUTED: [LTIM.2.5.1]'s window on the composed engine fires once per
|||     opening, `[1, 0, 1, 0]`, as on Tick's
|||     (`ltim_2_5_1__second_edge_refires_clocked`); a fact whose TTL
|||     expires while the window is shut cannot reopen it, `[1, 0, 0, 0]`
|||     (`ltim_2_5_1__expired_fact_cannot_reopen`): the sweep runs before the
|||     re-time, which is the composition, seen; and [LDET.5.8]'s own
|||     observable, `rule late`, fires once in the third of four pumps,
|||     `[0, 0, 1, 0]` (`ldet_5_8__late_fires_once_clocked`), its quiet ticks
|||     inhabiting A1's hypothesis with the fact live
|||     (`ldet_5_8__shut_stays_shut_unmoved`, `ldet_5_8__open_stays_open_unmoved`).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. That a run with fuel
||| fires each activation the tick made once and none twice is part B:
||| nothing here counts a pump's firings against the born
||| set beyond the executed witnesses. That a row whose activation the tick
||| ended is dropped by the cascade that follows is [LTIM.2.7.2] by
||| `iret_12_2__ended_net`'s definition; that the fact it alone supported is
||| then retracted is stated for every program by no theorem of the lane,
||| and executed once by Rete/NetworkTimed.idr
||| (`ltim_2_7_2__lapsed_fact_retracted`). The two clocks, the entry
||| stamp and replay on this engine are part C. The alphas and the timed
||| tests are given as Tick gives them (one `Maybe` per chain, by ordinal);
||| that the loader pairs them with the right chains is the reading
||| NetworkTick's header states.
module Rete.NetworkClocked

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.TmsRun
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkView
import Rete.NetworkDispatch
import Rete.NetworkTms
import Rete.NetworkTmsTransfer
import Rete.NetworkTtl
import Rete.NetworkTick
import Rete.TmsBridge
import Rete.Refcount
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The composed tick, the prepare, the pump
-- ---------------------------------------------------------------------

--@spec [IRET.19.5]
--@spec [LTIM.2.4.2]
--@spec [LTIM.2.7.2]
||| THE RE-TIME STAGE: every timed chain re-evaluated at the state's clock
||| (step 3), then the cascade for the rows of the activations that ended.
public export
iret_19_5__retime_clocked : Lcyc_3_2_1__program -> List (Maybe Ltim_2_4_1__timed) -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
iret_19_5__retime_clocked pg ts (MkClockedNet (MkTmsNet eng rows) dl c) =
  MkClockedNet (iret_12_2__phase_net pg (MkTmsNet (iret_19_5__tick ts c eng) rows)) dl c

--@spec [IRET.19.5]
--@spec [RARC.5.6.3]
--@spec [LDTL.6.1]
||| THE TICK ON THE CLOCKED NETWORK: advance and sweep (Ttl's tick, steps 1
||| and 2), then the re-time stage.
public export
iret_19_5__tick_clocked : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> Nat -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
iret_19_5__tick_clocked pg ttl ts t cs = iret_19_5__retime_clocked pg ts (rarc_5_6_3__prepare_net pg ttl (Tick t) cs)

--@spec [RARC.5.6.3]
||| An input prepared: a tick as above; a data event as Ttl has it, with no
||| re-time, since it moves no clock here.
public export
rarc_5_6_3__prepare_clocked : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> Rarc_5_6_2__input -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_3__prepare_clocked pg ttl ts (Tick t) cs = iret_19_5__tick_clocked pg ttl ts t cs
rarc_5_6_3__prepare_clocked pg ttl ts (Data ev) cs = rarc_5_6_3__prepare_net pg ttl (Data ev) cs

--@spec [IRET.19.5]
--@spec [LTIM.2.4.2]
||| A PUMP: the input prepared, then Ttl's run to quiescence; with its halt
||| and its number of firings.
public export
iret_19_5__pump_clocked : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> Nat -> Rarc_5_6_2__input -> Iret_19_3__clocked_net -> (Iret_19_3__clocked_net, Iret_11_4__halt, Nat)
iret_19_5__pump_clocked pg ttl ts fuel inp cs = iret_11_4__run_ttl_net pg ttl fuel (rarc_5_6_3__prepare_clocked pg ttl ts inp cs)

--@spec [LFST.9.2.1]
||| One input then a pump, on the clocked network.
public export
lfst_9_2_1__boundary_clocked : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> Nat -> Rarc_5_6_2__input -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
lfst_9_2_1__boundary_clocked pg ttl ts fuel inp cs = fst (iret_19_5__pump_clocked pg ttl ts fuel inp cs)

--@spec [IRET.19.5]
--@spec [LFST.9.2.1]
||| A HISTORY PUMPED: every input prepared and run in turn, [LFST.9.2.1]'s
||| cadence folded over the list, returning the state the history leaves
||| and one count per pump. The one fold the state and the counts are read
||| off; the clock after the history is the state's (`nclock`), not a third
||| thing the fold returns.
public export
iret_19_5__run_clocked : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> Nat -> List Rarc_5_6_2__input -> Iret_19_3__clocked_net -> (Iret_19_3__clocked_net, List Nat)
iret_19_5__run_clocked pg ttl ts fuel [] cs = (cs, [])
iret_19_5__run_clocked pg ttl ts fuel (inp :: inps) cs =
  let r = iret_19_5__pump_clocked pg ttl ts fuel inp cs
      rest = iret_19_5__run_clocked pg ttl ts fuel inps (fst r)
  in (fst rest, snd (snd r) :: snd rest)

--@spec [LFST.9.2.1]
||| THE STATE AFTER A HISTORY, each input pumped: the fold's state.
public export
lfst_9_2_1__after_clocked : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> Nat -> List Rarc_5_6_2__input -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
lfst_9_2_1__after_clocked pg ttl ts fuel inps cs = fst (iret_19_5__run_clocked pg ttl ts fuel inps cs)

--@spec [IRET.19.5]
||| The firings of a sequence of inputs, one count per pump: the fold's
||| counts.
public export
iret_19_5__counts_clocked : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Maybe Ltim_2_4_1__timed) -> Nat -> List Rarc_5_6_2__input -> Iret_19_3__clocked_net -> List Nat
iret_19_5__counts_clocked pg ttl ts fuel inps cs = snd (iret_19_5__run_clocked pg ttl ts fuel inps cs)

--@derives [IRET.19.5]
--@derives [LFST.9.2.1]
||| One pump of a history, unfolded: the fold over the rest from the state
||| the pump left, with the pump's count in front. Rete/NetworkEdges.idr's
||| `iret_19_5__counts_clocked_cons` is its second component.
export
iret_19_5__run_clocked_cons : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (fuel : Nat) ->
                              (inp : Rarc_5_6_2__input) -> (inps : List Rarc_5_6_2__input) -> (cs, cs' : Iret_19_3__clocked_net) ->
                              (h : Iret_11_4__halt) -> (n : Nat) ->
                              iret_19_5__pump_clocked pg ttl ts fuel inp cs = (cs', h, n) ->
                              iret_19_5__run_clocked pg ttl ts fuel (inp :: inps) cs
                                = (fst (iret_19_5__run_clocked pg ttl ts fuel inps cs'), n :: snd (iret_19_5__run_clocked pg ttl ts fuel inps cs'))
iret_19_5__run_clocked_cons pg ttl ts fuel inp inps cs cs' h n eq with (iret_19_5__pump_clocked pg ttl ts fuel inp cs)
  iret_19_5__run_clocked_cons pg ttl ts fuel inp inps cs cs' h n eq | (cs2, h2, n2) =
    rewrite cong fst eq in rewrite cong (\z => snd (snd z)) eq in Refl

-- ---------------------------------------------------------------------
-- A1: a tick that moves no verdict and expires nothing
-- ---------------------------------------------------------------------

--@derives [LTIM.2.4.2]
||| A verdict and its negation are not both true.
export
ltim_2_4_2__and_not_self : (b : Bool) -> b && not b = True -> Void
ltim_2_4_2__and_not_self True p = absurd p
ltim_2_4_2__and_not_self False p = absurd p

--@derives [LTIM.2.4.2]
||| A list of tokens with no member is empty.
export
ltim_2_4_2__nil_of_none : (xs : List Iret_7_1__token) -> ((x : Iret_7_1__token) -> Elem x xs -> Void) -> xs = []
ltim_2_4_2__nil_of_none [] f = Refl
ltim_2_4_2__nil_of_none (x :: xs) f = absurd (f x Here)

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| A re-time whose new test answers on every live pair what the old one
||| answered ends nothing.
export
iret_19_5__ended_nil : (j, j' : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (lm : List Iret_7_1__token) ->
                       ((t : Iret_7_1__token) -> Elem t lm -> (f : Lfac_1_7_1__fact) -> Elem f mem -> j t f = j' t f) ->
                       iret_19_5__ended j j' mem lm = []
iret_19_5__ended_nil j j' mem lm same =
  ltim_2_4_2__nil_of_none (iret_19_5__ended j j' mem lm) (\y, e =>
    let (t ** (f ** (et, ef, jt, jf, _))) = iret_19_5__ended_inv j j' mem lm y e
    in absurd (trans (sym (trans (sym (same t et f ef)) jt)) jf))

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| And makes nothing.
export
iret_19_5__born_nil : (j, j' : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (lm : List Iret_7_1__token) ->
                      ((t : Iret_7_1__token) -> Elem t lm -> (f : Lfac_1_7_1__fact) -> Elem f mem -> j t f = j' t f) ->
                      iret_19_5__born j j' mem lm = []
iret_19_5__born_nil j j' mem lm same =
  ltim_2_4_2__nil_of_none (iret_19_5__born j j' mem lm) (\y, e =>
    let (t ** (f ** (et, ef, jf, jt, _))) = iret_19_5__born_inv j j' mem lm y e
    in absurd (trans (sym (trans (same t et f ef) jt)) jf))

--@derives [IRET.8.1]
||| Ending no match keeps every activation.
export
iret_8_1__end_nil : (acts : List Iret_8_1__act) -> iret_8_1__end [] acts = acts
iret_8_1__end_nil [] = Refl
iret_8_1__end_nil (a :: as) = cong (a ::) (iret_8_1__end_nil as)

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| A re-time that moves no verdict leaves the activations as they were.
export
iret_19_5__retime_unmoved : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (j' : Iret_7_5__join) ->
                            (a : Nat) -> (j : Iret_7_5__join) -> (lm : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                            ((t : Iret_7_1__token) -> Elem t lm -> (f : Lfac_1_7_1__fact) -> Elem f (iret_6_6__mem_at alphas a) -> j t f = j' t f) ->
                            iret_8_1__activate wm (iret_19_5__born j j' (iret_6_6__mem_at alphas a) lm)
                              (iret_8_1__end (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts) = acts
iret_19_5__retime_unmoved wm alphas j' a j lm acts same =
  rewrite iret_19_5__born_nil j j' (iret_6_6__mem_at alphas a) lm same in
  rewrite iret_19_5__ended_nil j j' (iret_6_6__mem_at alphas a) lm same in
  iret_8_1__end_nil acts

--@spec [LTIM.2.4.2]
||| A chain's timed test is UNMOVED at a clock when, for the single
||| positive node it re-times, the test at that clock answers on every live
||| pair what the node's test answers. A chain with no timed test, or of
||| another shape, is re-timed by nothing and is unmoved trivially.
public export
Ltim_2_4_2__unmoved : List Iret_6_1__alpha -> Maybe Ltim_2_4_1__timed -> Nat -> Rlow_4_2_1__chain -> Type
Ltim_2_4_2__unmoved alphas Nothing c ch = ()
Ltim_2_4_2__unmoved alphas (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) =
  (t : Iret_7_1__token) -> Elem t lm -> (f : Lfac_1_7_1__fact) -> Elem f (iret_6_6__mem_at alphas a) -> j t f = tj c t f
Ltim_2_4_2__unmoved alphas (Just tj) c ch = ()

--@spec [LTIM.2.4.2]
||| Every chain unmoved, chain by chain beside its test.
public export
Ltim_2_4_2__unmoved_all : List Iret_6_1__alpha -> List (Maybe Ltim_2_4_1__timed) -> Nat -> List Rlow_4_2_1__chain -> Type
Ltim_2_4_2__unmoved_all alphas [] c chains = ()
Ltim_2_4_2__unmoved_all alphas (t :: ts) c [] = ()
Ltim_2_4_2__unmoved_all alphas (t :: ts) c (ch :: chs) = (Ltim_2_4_2__unmoved alphas t c ch, Ltim_2_4_2__unmoved_all alphas ts c chs)

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| An unmoved chain keeps its activations through the tick.
export
iret_19_5__tick_chain_cacts : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (t : Maybe Ltim_2_4_1__timed) -> (c : Nat) ->
                              (ch : Rlow_4_2_1__chain) -> Ltim_2_4_2__unmoved alphas t c ch ->
                              cacts (iret_19_5__tick_chain wm alphas t c ch) = cacts ch
iret_19_5__tick_chain_cacts wm alphas Nothing c ch u = Refl
iret_19_5__tick_chain_cacts wm alphas (Just tj) c (MkChain [] acts actions) u = Refl
iret_19_5__tick_chain_cacts wm alphas (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) u =
  iret_19_5__retime_unmoved wm alphas (tj c) a j lm acts u
iret_19_5__tick_chain_cacts wm alphas (Just tj) c (MkChain [MkBeta a j True lm cs] acts actions) u = Refl
iret_19_5__tick_chain_cacts wm alphas (Just tj) c (MkChain (MkBeta a j False lm cs :: b2 :: rest) acts actions) u = Refl
iret_19_5__tick_chain_cacts wm alphas (Just tj) c (MkChain (MkBeta a j True lm cs :: b2 :: rest) acts actions) u = Refl

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| And its left memories: a re-time changes a node's test and nothing else
||| of the node.
export
iret_19_5__tick_chain_lmems : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (t : Maybe Ltim_2_4_1__timed) -> (c : Nat) ->
                              (ch : Rlow_4_2_1__chain) ->
                              map blmem (cnodes (iret_19_5__tick_chain wm alphas t c ch)) = map blmem (cnodes ch)
iret_19_5__tick_chain_lmems wm alphas Nothing c ch = Refl
iret_19_5__tick_chain_lmems wm alphas (Just tj) c (MkChain [] acts actions) = Refl
iret_19_5__tick_chain_lmems wm alphas (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) = Refl
iret_19_5__tick_chain_lmems wm alphas (Just tj) c (MkChain [MkBeta a j True lm cs] acts actions) = Refl
iret_19_5__tick_chain_lmems wm alphas (Just tj) c (MkChain (MkBeta a j False lm cs :: b2 :: rest) acts actions) = Refl
iret_19_5__tick_chain_lmems wm alphas (Just tj) c (MkChain (MkBeta a j True lm cs :: b2 :: rest) acts actions) = Refl

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| Unmoved chains, one and all, keep their activations.
export
iret_19_5__tick_chains_cacts : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) ->
                               (chains : List Rlow_4_2_1__chain) -> Ltim_2_4_2__unmoved_all alphas ts c chains ->
                               map cacts (iret_19_5__tick_chains wm alphas ts c chains) = map cacts chains
iret_19_5__tick_chains_cacts wm alphas [] c chains u = Refl
iret_19_5__tick_chains_cacts wm alphas (t :: ts) c [] u = Refl
iret_19_5__tick_chains_cacts wm alphas (t :: ts) c (ch :: chs) (u, us) =
  cong2 (::) (iret_19_5__tick_chain_cacts wm alphas t c ch u) (iret_19_5__tick_chains_cacts wm alphas ts c chs us)

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| And every chain keeps its left memories, moved or not.
export
iret_19_5__tick_chains_lmems : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) ->
                               (chains : List Rlow_4_2_1__chain) ->
                               map (\ch => map blmem (cnodes ch)) (iret_19_5__tick_chains wm alphas ts c chains)
                                 = map (\ch => map blmem (cnodes ch)) chains
iret_19_5__tick_chains_lmems wm alphas [] c chains = Refl
iret_19_5__tick_chains_lmems wm alphas (t :: ts) c [] = Refl
iret_19_5__tick_chains_lmems wm alphas (t :: ts) c (ch :: chs) =
  cong2 (::) (iret_19_5__tick_chain_lmems wm alphas t c ch) (iret_19_5__tick_chains_lmems wm alphas ts c chs)

--@derives [IRET.11]
||| The activations at an ordinal depend on the chains' activations alone.
export
iret_11__acts_at_ext : (r : Nat) -> (cs, cs' : List Rlow_4_2_1__chain) -> map cacts cs = map cacts cs' ->
                          iret_11__chain_acts_at r cs = iret_11__chain_acts_at r cs'
iret_11__acts_at_ext r [] [] eq = Refl
iret_11__acts_at_ext Z (c :: cs) (c' :: cs') eq = fst (consInjective eq)
iret_11__acts_at_ext (S r) (c :: cs) (c' :: cs') eq = iret_11__acts_at_ext r cs cs' (snd (consInjective eq))
iret_11__acts_at_ext r [] (c' :: cs') eq impossible
iret_11__acts_at_ext r (c :: cs) [] eq impossible

--@derives [IRET.7.8]
||| So does whether a row's activation is live.
export
iret_7_8__live_ext : (cs, cs' : List Rlow_4_2_1__chain) -> map cacts cs = map cacts cs' -> (row : Iret_12_4__row) ->
                       iret_7_8__activation_live_net cs row = iret_7_8__activation_live_net cs' row
iret_7_8__live_ext cs cs' eq row =
  cong (rarc_5_6_5__any (\a => (iret_11_3__fact_ids (atuple a) == rids row) && afired a)) (iret_11__acts_at_ext (rrule row) cs cs' eq)

--@derives [IRET.12.2]
||| And so do the rows a phase ends.
export
iret_12_2__ended_net_ext : (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (cs, cs' : List Rlow_4_2_1__chain) -> (rows : Iret_12_4__table) ->
                            map cacts cs = map cacts cs' ->
                            iret_12_2__ended_net (MkEngine wm (MkNetwork al cs)) rows = iret_12_2__ended_net (MkEngine wm (MkNetwork al cs')) rows
iret_12_2__ended_net_ext wm al cs cs' rows eq =
  lcyc_1_1__filter_ext (\row => not (iret_7_8__activation_live_net cs row && rarc_5_6_4__is_live (rtarget row) wm))
                       (\row => not (iret_7_8__activation_live_net cs' row && rarc_5_6_4__is_live (rtarget row) wm))
                       (\row => cong (\b => not (b && rarc_5_6_4__is_live (rtarget row) wm)) (iret_7_8__live_ext cs cs' eq row))
                       rows

--@derives [LDET.5.8]
--@derives [RARC.5.6.3]
--@derives [IRET.19.5]
||| THE COMPOSED TICK, when quiet, is the re-time of the state with the
||| clock moved: the sweep retracted nothing and the cascade after the
||| re-time ended nothing.
export
ldet_5_8__quiet_tick_is_retime : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (t : Nat) ->
                                   (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                   (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                   iret_12_2__ended_net (MkEngine wm (MkNetwork al chains)) rows = [] ->
                                   iret_19_3__expired (rarc_5_6_3__next_clock c t) dl = [] ->
                                   Ltim_2_4_2__unmoved_all al ts (rarc_5_6_3__next_clock c t) chains ->
                                   iret_19_5__tick_clocked pg ttl ts t (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c)
                                     = MkClockedNet (MkTmsNet (iret_19_5__tick ts (rarc_5_6_3__next_clock c t) (MkEngine wm (MkNetwork al chains))) rows) dl (rarc_5_6_3__next_clock c t)
ldet_5_8__quiet_tick_is_retime pg ttl ts t wm al chains rows dl c noEnd noExp unmoved =
  trans (cong (iret_19_5__retime_clocked pg ts) (ldet_5_8__quiet_tick_net pg ttl t wm (MkNetwork al chains) rows dl c noEnd noExp))
        (cong (\s => MkClockedNet s dl (rarc_5_6_3__next_clock c t))
           (iret_12_2__phase_n_net_quiet (S (length rows)) pg (iret_19_5__tick ts (rarc_5_6_3__next_clock c t) (MkEngine wm (MkNetwork al chains))) rows
              (trans (iret_12_2__ended_net_ext wm al (iret_19_5__tick_chains wm al ts (rarc_5_6_3__next_clock c t) chains) chains rows
                        (iret_19_5__tick_chains_cacts wm al ts (rarc_5_6_3__next_clock c t) chains unmoved))
                     noEnd)))

--@derives [LDET.5.8]
--@derives [RARC.5.6.3]
--@derives [LTIM.2.4.2]
||| A1. A TICK THAT EXPIRES NOTHING AND MOVES NO VERDICT MOVES ONLY THE
||| CLOCK, on the one engine with both kinds of test: working memory, every
||| chain's activations with their `fired` flags, every chain's left
||| memories, the dependency table and the deadline table are as they were.
||| Cycling the clock is not a change to the LHS, [LDET.5.8]'s requirement,
||| for tests that are predicates of facts and for tests that read the
||| clock, together.
export
ldet_5_8__quiet_tick_clocked : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (t : Nat) ->
                               (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                               (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                               iret_12_2__ended_net (MkEngine wm (MkNetwork al chains)) rows = [] ->
                               iret_19_3__expired (rarc_5_6_3__next_clock c t) dl = [] ->
                               Ltim_2_4_2__unmoved_all al ts (rarc_5_6_3__next_clock c t) chains ->
                               ( ewm (ncore (nengine (iret_19_5__tick_clocked pg ttl ts t (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c)))) = wm
                               , map cacts (nchains (enet (ncore (nengine (iret_19_5__tick_clocked pg ttl ts t (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c)))))) = map cacts chains
                               , map (\ch => map blmem (cnodes ch)) (nchains (enet (ncore (nengine (iret_19_5__tick_clocked pg ttl ts t (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c))))))
                                   = map (\ch => map blmem (cnodes ch)) chains
                               , ndeps (nengine (iret_19_5__tick_clocked pg ttl ts t (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c))) = rows
                               , ndeadlines (iret_19_5__tick_clocked pg ttl ts t (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c)) = dl
                               , nclock (iret_19_5__tick_clocked pg ttl ts t (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c)) = rarc_5_6_3__next_clock c t )
ldet_5_8__quiet_tick_clocked pg ttl ts t wm al chains rows dl c noEnd noExp unmoved =
  let e = ldet_5_8__quiet_tick_is_retime pg ttl ts t wm al chains rows dl c noEnd noExp unmoved
  in ( cong (\x => ewm (ncore (nengine x))) e
     , trans (cong (\x => map cacts (nchains (enet (ncore (nengine x))))) e)
             (iret_19_5__tick_chains_cacts wm al ts (rarc_5_6_3__next_clock c t) chains unmoved)
     , trans (cong (\x => map (\ch => map blmem (cnodes ch)) (nchains (enet (ncore (nengine x))))) e)
             (iret_19_5__tick_chains_lmems wm al ts (rarc_5_6_3__next_clock c t) chains)
     , cong (\x => ndeps (nengine x)) e
     , cong ndeadlines e
     , cong nclock e )

-- ---------------------------------------------------------------------
-- A2: the composed tick keeps the view
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
--@derives [IRET.19.2]
||| Retracting facts by id, one at a time, keeps the view.
export
iret_12_2__retract_ids_net_view : (ids : List Nat) -> (eng : Iret_19__engine) -> Iret_19__view eng ->
                                  Iret_19__view (iret_12_2__retract_ids_net ids eng)
iret_12_2__retract_ids_net_view [] eng v = v
iret_12_2__retract_ids_net_view (i :: is) eng v with (rarc_5_6_4__lookup_fact i (ewm eng)) proof lk
  iret_12_2__retract_ids_net_view (i :: is) eng v | Nothing = iret_12_2__retract_ids_net_view is eng v
  iret_12_2__retract_ids_net_view (i :: is) eng v | Just f =
    iret_12_2__retract_ids_net_view is (iret_19_2__retract f eng)
      (iret_19_2__retract_view f eng (fst (rarc_5_6_4__lookup_elem i (ewm eng) f lk)) v)

--@derives [IRET.12.2]
||| One phase of the cascade keeps the view: it retracts and does nothing
||| else to the network.
export
iret_12_2__phase_step_net_view : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> Iret_19__view eng ->
                                 Iret_19__view (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))
iret_12_2__phase_step_net_view pg eng rows v with (iret_12_2__ended_net eng rows)
  iret_12_2__phase_step_net_view pg eng rows v | [] = v
  iret_12_2__phase_step_net_view pg eng rows v | (r :: rs) =
    iret_12_2__retract_ids_net_view (iret_12_2__zeroed (r :: rs) (iret_12_2__kept_net eng rows)) eng v

--@derives [IRET.12.2]
||| So do any number of phases.
export
iret_12_2__phase_n_net_view : (n : Nat) -> (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) -> Iret_19__view (ncore s) ->
                              Iret_19__view (ncore (iret_12_2__phase_n_net n pg s))
iret_12_2__phase_n_net_view Z pg s v = v
iret_12_2__phase_n_net_view (S n) pg (MkTmsNet eng rows) v with (iret_12_2__phase_step_net pg (MkTmsNet eng rows)) proof p
  iret_12_2__phase_n_net_view (S n) pg (MkTmsNet eng rows) v | MkTmsNet eng' rows' =
    iret_12_2__phase_n_net_view n pg (MkTmsNet eng' rows')
      (replace {p = \x => Iret_19__view (ncore x)} p (iret_12_2__phase_step_net_view pg eng rows v))

--@derives [IRET.12.2]
||| The cascade to its fixpoint keeps the view.
export
iret_12_2__phase_net_view : (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) -> Iret_19__view (ncore s) ->
                            Iret_19__view (ncore (iret_12_2__phase_net pg s))
iret_12_2__phase_net_view pg s v = iret_12_2__phase_n_net_view (S (length (ndeps s))) pg s v

--@derives [RARC.5.6.3]
--@derives [IRET.19.3]
||| The sweep keeps the view: retractions in [LDTL.6.1]'s order, then the
||| cascade.
export
rarc_5_6_3__sweep_net_view : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                             Iret_19__view eng ->
                             Iret_19__view (ncore (nengine (rarc_5_6_3__sweep_net pg (MkClockedNet (MkTmsNet eng rows) dl c))))
rarc_5_6_3__sweep_net_view pg eng rows dl c v =
  iret_12_2__phase_net_view pg (MkTmsNet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng) rows)
    (iret_12_2__retract_ids_net_view (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng v)

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
--@derives [IRET.7.7]
||| The re-time of one chain keeps its consistency from the nil token: a
||| single positive node by Tick's theorem, any other shape by being left
||| alone.
export
iret_19_5__tick_chain_consistent : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas ->
                                   (t : Maybe Ltim_2_4_1__timed) -> (c : Nat) -> (ch : Rlow_4_2_1__chain) ->
                                   Iret_7_7__consistent alphas [[]] (cnodes ch) (cacts ch) ->
                                   Iret_7_7__consistent alphas [[]] (cnodes (iret_19_5__tick_chain wm alphas t c ch)) (cacts (iret_19_5__tick_chain wm alphas t c ch))
iret_19_5__tick_chain_consistent wm alphas dm Nothing c ch con = con
iret_19_5__tick_chain_consistent wm alphas dm (Just tj) c (MkChain [] acts actions) con = con
iret_19_5__tick_chain_consistent wm alphas dm (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) con =
  iret_19_5__retime_consistent wm alphas dm [[]] a j (tj c) lm cs acts con
iret_19_5__tick_chain_consistent wm alphas dm (Just tj) c (MkChain [MkBeta a j True lm cs] acts actions) con = con
iret_19_5__tick_chain_consistent wm alphas dm (Just tj) c (MkChain (MkBeta a j False lm cs :: b2 :: rest) acts actions) con = con
iret_19_5__tick_chain_consistent wm alphas dm (Just tj) c (MkChain (MkBeta a j True lm cs :: b2 :: rest) acts actions) con = con

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
--@derives [IRET.7.7]
||| Every chain, re-timed or not, stays consistent.
export
iret_19_5__tick_chains_consistent : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas ->
                                    (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (chains : List Rlow_4_2_1__chain) ->
                                    All (\ch => Iret_7_7__consistent alphas [[]] (cnodes ch) (cacts ch)) chains ->
                                    All (\ch => Iret_7_7__consistent alphas [[]] (cnodes ch) (cacts ch)) (iret_19_5__tick_chains wm alphas ts c chains)
iret_19_5__tick_chains_consistent wm alphas dm [] c chains cons = cons
iret_19_5__tick_chains_consistent wm alphas dm (t :: ts) c [] cons = cons
iret_19_5__tick_chains_consistent wm alphas dm (t :: ts) c (ch :: chs) (pc :: pcs) =
  iret_19_5__tick_chain_consistent wm alphas dm t c ch pc :: iret_19_5__tick_chains_consistent wm alphas dm ts c chs pcs

--@derives [IRET.19.5]
--@derives [LDET.5.8]
||| THE RE-TIME KEEPS THE VIEW: working memory and the alpha memories are
||| untouched, and every chain stays consistent.
export
iret_19_5__tick_view : (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) -> (eng : Iret_19__engine) ->
                       Iret_19__view eng -> Iret_19__view (iret_19_5__tick ts c eng)
iret_19_5__tick_view ts c (MkEngine wm (MkNetwork al chains)) (dw, dm, mv, cons) =
  (dw, dm, mv, iret_19_5__tick_chains_consistent wm al dm ts c chains cons)

--@derives [IRET.19.5]
--@derives [RARC.5.6.3]
--@derives [LDET.5.8]
||| A2. THE COMPOSED TICK KEEPS THE VIEW: after any tick on the clocked
||| network every alpha memory and every terminal are what the recompute
||| over working memory gives, none twice -- the view theorem of
||| Rete/NetworkDispatch.idr, across ticks that sweep, re-time and cascade.
export
iret_19_5__tick_clocked_view : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (t : Nat) ->
                               (cs : Iret_19_3__clocked_net) -> Iret_19__view (ncore (nengine cs)) ->
                               Iret_19__view (ncore (nengine (iret_19_5__tick_clocked pg ttl ts t cs)))
iret_19_5__tick_clocked_view pg ttl ts t (MkClockedNet (MkTmsNet eng rows) dl c) v
  with (rarc_5_6_3__prepare_net pg ttl (Tick t) (MkClockedNet (MkTmsNet eng rows) dl c)) proof sw
  iret_19_5__tick_clocked_view pg ttl ts t (MkClockedNet (MkTmsNet eng rows) dl c) v | MkClockedNet (MkTmsNet eng' rows') dl' c' =
    iret_12_2__phase_net_view pg (MkTmsNet (iret_19_5__tick ts c' eng') rows')
      (iret_19_5__tick_view ts c' eng'
         (replace {p = \x => Iret_19__view (ncore (nengine x))} sw
            (rarc_5_6_3__sweep_net_view pg eng rows dl (rarc_5_6_3__next_clock c t) v)))

-- ---------------------------------------------------------------------
-- A3: Tick's theorems, on this engine's timed chain at any ordinal
-- ---------------------------------------------------------------------

--@derives [IRET.19.5]
||| The chain at an ordinal after the re-time is that chain re-timed by the
||| test at that ordinal.
export
iret_19_5__tick_chains_nth : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) ->
                             (chains : List Rlow_4_2_1__chain) -> (r : Nat) -> (t : Maybe Ltim_2_4_1__timed) -> (ch : Rlow_4_2_1__chain) ->
                             rarc_5_6_5__nth r ts = Just t -> rarc_5_6_5__nth r chains = Just ch ->
                             rarc_5_6_5__nth r (iret_19_5__tick_chains wm alphas ts c chains) = Just (iret_19_5__tick_chain wm alphas t c ch)
iret_19_5__tick_chains_nth wm alphas [] c chains r t ch p q = absurd p
iret_19_5__tick_chains_nth wm alphas (t0 :: ts) c [] r t ch p q = absurd q
iret_19_5__tick_chains_nth wm alphas (t0 :: ts) c (ch0 :: chs) Z _ _ Refl Refl = Refl
iret_19_5__tick_chains_nth wm alphas (t0 :: ts) c (ch0 :: chs) (S r) t ch p q = iret_19_5__tick_chains_nth wm alphas ts c chs r t ch p q

--@derives [LDET.5.8]
--@derives [LDET.5.3]
--@derives [IRET.11.3.2]
||| A3. A TICK IS NOT A CHANGE TO THE LHS, on this engine: at the re-time
||| stage, an activation of the timed chain at ordinal `r` whose match the
||| test at the new clock still admits is, in the re-timed chain at `r`, the
||| same record, `fired` flag included.
export
ldet_5_8__tick_keeps_activation_clocked : (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) ->
                                          (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                          (r : Nat) -> (tj : Ltim_2_4_1__timed) -> (a : Nat) -> (j : Iret_7_5__join) -> (lm : List Iret_7_1__token) ->
                                          (cs : List (Iret_7_1__token, Nat)) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                          rarc_5_6_5__nth r ts = Just (Just tj) ->
                                          rarc_5_6_5__nth r chains = Just (MkChain [MkBeta a j False lm cs] acts actions) ->
                                          (x : Iret_8_1__act) -> Elem x acts -> (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) ->
                                          atuple x = t ++ [f] -> tj c t f = True ->
                                          ( rarc_5_6_5__nth r (nchains (enet (iret_19_5__tick ts c (MkEngine wm (MkNetwork al chains)))))
                                              = Just (iret_19_5__tick_chain wm al (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions))
                                          , Elem x (cacts (iret_19_5__tick_chain wm al (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions))) )
ldet_5_8__tick_keeps_activation_clocked ts c wm al chains r tj a j lm cs acts actions pt pc x ex t f tx jt =
  ( iret_19_5__tick_chains_nth wm al ts c chains r (Just tj) (MkChain [MkBeta a j False lm cs] acts actions) pt pc
  , ldet_5_8__tick_keeps_activation wm al (tj c) (MkBeta a j False lm cs) acts x t f ex tx jt )

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.7.2]
--@derives [IRET.19.5]
||| A3. A CONDITION THAT CLOSES ENDS THE MATCH, on this engine: under the
||| view, the re-timed chain at `r` holds no activation whose match the new
||| test refuses, fired or not.
export
ltim_2_5_1__closing_ends_clocked : (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) ->
                                   (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                   Iret_19__view (MkEngine wm (MkNetwork al chains)) ->
                                   (r : Nat) -> (tj : Ltim_2_4_1__timed) -> (a : Nat) -> (j : Iret_7_5__join) -> (lm : List Iret_7_1__token) ->
                                   (cs : List (Iret_7_1__token, Nat)) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                   rarc_5_6_5__nth r ts = Just (Just tj) ->
                                   rarc_5_6_5__nth r chains = Just (MkChain [MkBeta a j False lm cs] acts actions) ->
                                   (x : Iret_8_1__act) ->
                                   Elem x (cacts (iret_19_5__tick_chain wm al (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions))) ->
                                   (u : Iret_7_1__token) -> (g : Lfac_1_7_1__fact) -> atuple x = u ++ [g] -> tj c u g = False -> Void
ltim_2_5_1__closing_ends_clocked ts c wm al chains (dw, dm, mv, cons) r tj a j lm cs acts actions pt pc x ex u g tx jf =
  ltim_2_5_1__closing_ends wm al dm [[]] a j (tj c) lm cs acts
    (lcyc_1_1__all_lookup cons (lcyc_1_1__nth_elem r chains pc))
    x ex u g tx jf

--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
--@derives [LDET.5.8]
||| A3. A REOPENING IS A NEW EDGE, on this engine: under the view, an
||| activation of the re-timed chain at `r` whose match the tick made is
||| unfired, whatever fired before the gate shut.
export
ltim_2_5_1__reopening_is_unfired_clocked : (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) ->
                                           (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                           Iret_19__view (MkEngine wm (MkNetwork al chains)) ->
                                           (r : Nat) -> (tj : Ltim_2_4_1__timed) -> (a : Nat) -> (j : Iret_7_5__join) -> (lm : List Iret_7_1__token) ->
                                           (cs : List (Iret_7_1__token, Nat)) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                           rarc_5_6_5__nth r ts = Just (Just tj) ->
                                           rarc_5_6_5__nth r chains = Just (MkChain [MkBeta a j False lm cs] acts actions) ->
                                           (x : Iret_8_1__act) ->
                                           Elem x (cacts (iret_19_5__tick_chain wm al (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions))) ->
                                           Elem (atuple x) (iret_19_5__born j (tj c) (iret_6_6__mem_at al a) lm) -> afired x = False
ltim_2_5_1__reopening_is_unfired_clocked ts c wm al chains (dw, dm, mv, cons) r tj a j lm cs acts actions pt pc x ex eb =
  ltim_2_5_1__reopening_is_unfired wm al dm [[]] a j (tj c) lm cs acts
    (lcyc_1_1__all_lookup cons (lcyc_1_1__nth_elem r chains pc))
    x ex eb

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
--@derives [LTIM.2.5.1]
||| A3. AFTER A QUIESCENT PUMP, THE TICK LEAVES UNFIRED ONLY WHAT IT MADE,
||| on this engine's timed chain at `r`.
export
ltim_2_4_2__unfired_are_born_clocked : (c : Nat) -> (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) ->
                                       (tj : Ltim_2_4_1__timed) -> (a : Nat) -> (j : Iret_7_5__join) -> (lm : List Iret_7_1__token) ->
                                       (cs : List (Iret_7_1__token, Nat)) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                       Ltim_2_4_2__quiescent acts ->
                                       (x : Iret_8_1__act) ->
                                       Elem x (cacts (iret_19_5__tick_chain wm al (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions))) ->
                                       afired x = False -> Elem (atuple x) (iret_19_5__born j (tj c) (iret_6_6__mem_at al a) lm)
ltim_2_4_2__unfired_are_born_clocked c wm al tj a j lm cs acts actions q x ex nf =
  ltim_2_4_2__unfired_are_born wm al (tj c) (MkBeta a j False lm cs) acts q x ex nf

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| A3. AND EVERY MATCH THE TICK MADE IS THERE TO FIRE, on this engine's
||| timed chain.
export
ltim_2_4_2__born_unfired_clocked : (c : Nat) -> (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) ->
                                   (tj : Ltim_2_4_1__timed) -> (a : Nat) -> (j : Iret_7_5__join) -> (lm : List Iret_7_1__token) ->
                                   (cs : List (Iret_7_1__token, Nat)) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                   (y : Iret_7_1__token) -> Elem y (iret_19_5__born j (tj c) (iret_6_6__mem_at al a) lm) ->
                                   Elem (MkAct y False) (cacts (iret_19_5__tick_chain wm al (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions)))
ltim_2_4_2__born_unfired_clocked c wm al tj a j lm cs acts actions y e =
  ltim_2_4_2__born_unfired wm al (tj c) (MkBeta a j False lm cs) acts y e

--@derives [LTIM.2.5.1]
--@derives [LDET.5.8]
||| A3. EDGE-ONCE ACROSS TWO SUCCESSIVE TICKS OF THIS ENGINE, for ANY gate: a
||| chain re-timed at `c1` carries the test at `c1` (`iret_19_5__tick_chain`
||| sets it), so the next tick, at `c2`, re-times from it, and no match is made
||| by both the tick to `c1` and the tick to `c2` -- a match the second tick
||| makes was refused at `c1`, which the first tick admitted. No hypothesis on
||| the gate: Tick's `ltim_2_5_1__edge_once` needs `Ltim_2_5_1__rising` to
||| carry a verdict from the first tick's end to the second's start, and here
||| the two are one clock. With `ltim_2_4_2__unfired_are_born_clocked`, a match
||| fires in at most one pump per opening on the one engine.
export
ltim_2_5_1__edge_once_clocked : (tj : Ltim_2_4_1__timed) -> (c0, c1, c2 : Nat) ->
                                (mem, mem' : List Lfac_1_7_1__fact) -> (lm, lm' : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                                Elem y (iret_19_5__born (tj c0) (tj c1) mem lm) -> Elem y (iret_19_5__born (tj c1) (tj c2) mem' lm') -> Void
ltim_2_5_1__edge_once_clocked tj c0 c1 c2 mem mem' lm lm' y e1 e2 =
  let (t ** (f ** (_, _, _, j1, eq1))) = iret_19_5__born_inv (tj c0) (tj c1) mem lm y e1
      (u ** (g ** (_, _, j1', _, eq2))) = iret_19_5__born_inv (tj c1) (tj c2) mem' lm' y e2
  in iret_19_5__clash (tj c1) t u f g (trans (sym eq1) eq2) j1 j1'

--@derives [IRET.19.5]
||| The re-timed chain carries the test at the new clock: what the next
||| tick re-times from.
export
iret_19_5__tick_chain_sets_test : (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (tj : Ltim_2_4_1__timed) -> (c : Nat) ->
                                  (a : Nat) -> (j : Iret_7_5__join) -> (lm : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) ->
                                  (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                  map bjoin (cnodes (iret_19_5__tick_chain wm al (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions))) = [tj c]
iret_19_5__tick_chain_sets_test wm al tj c a j lm cs acts actions = Refl

--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
||| WHEN THE RE-TIME STAGE IS THE TICK'S RESULT: if no row ends under the
||| re-timed engine -- no logical fact rests on an activation the tick
||| ended -- the cascade after it touches nothing, and the composed tick's
||| state is the re-timed state. Every theorem of A3 then holds of the
||| tick's result.
export
ltim_2_7_2__no_cascade_is_the_retime : (pg : Lcyc_3_2_1__program) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (eng : Iret_19__engine) ->
                                       (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                       iret_12_2__ended_net (iret_19_5__tick ts c eng) rows = [] ->
                                       iret_19_5__retime_clocked pg ts (MkClockedNet (MkTmsNet eng rows) dl c)
                                         = MkClockedNet (MkTmsNet (iret_19_5__tick ts c eng) rows) dl c
ltim_2_7_2__no_cascade_is_the_retime pg ts eng rows dl c noEnd =
  cong (\s => MkClockedNet s dl c) (iret_12_2__phase_n_net_quiet (S (length rows)) pg (iret_19_5__tick ts c eng) rows noEnd)

-- ---------------------------------------------------------------------
-- Executed: the window on the composed engine, and a fact that expires
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| The program the loaded window rule lowers to, every kind explicit.
public export
ltim_2_5_1__window_program : Lcyc_3_2_1__program
ltim_2_5_1__window_program = lcyc_3_2_1__program_of (\_ => Explicit) (enet ltim_2_5_1__window_loaded)

--@spec [LTIM.2.5.1]
||| The window rule loaded, one `Ping` live, no deadline, the clock at 0.
public export
ltim_2_5_1__window_start : Iret_19_3__clocked_net
ltim_2_5_1__window_start = MkClockedNet (MkTmsNet (iret_19_1__insert ldet_5_8__ping ltim_2_5_1__window_loaded) []) [] 0

--@derives [RARC.5.6.3]
--@derives [IRET.19.5]
||| The first tick moves the clock to 1 and nothing else: no deadline, so
||| the sweep retracts nothing, and the window was shut at 0. (The witnesses
||| below compute through `rarc_5_6_3__next_clock`, whose comparison is
||| Rete/TmsRun.idr's: a function unfolds here only if its module is
||| imported by this file, which is why that import is above.)
export
rarc_5_6_3__first_tick_moves_the_clock :
  nclock (iret_19_5__tick_clocked ltim_2_5_1__window_program (\_ => 0) [Just ltim_2_5_1__window_gate] 1 ltim_2_5_1__window_start) = 1
rarc_5_6_3__first_tick_moves_the_clock = Refl

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| And the re-time at 1 makes the `Ping` match, unfired: the one
||| activation of the one chain.
export
ltim_2_4_2__first_tick_opens :
  map cacts (nchains (enet (ncore (nengine (iret_19_5__tick_clocked ltim_2_5_1__window_program (\_ => 0) [Just ltim_2_5_1__window_gate] 1 ltim_2_5_1__window_start)))))
    = [[MkAct [ldet_5_8__ping] False]]
ltim_2_4_2__first_tick_opens = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| THE SECOND EDGE FIRES AGAIN ON THE CLOCKED NETWORK: one `Ping`, no TTL,
||| the window gate; ticks to 1, 2, 3, 4 fire the rule in the first pump and
||| the third, once per opening -- Tick's `[1, 0, 1, 0]`, on the engine with
||| the tables.
export
ltim_2_5_1__second_edge_refires_clocked :
  iret_19_5__counts_clocked ltim_2_5_1__window_program (\_ => 0) [Just ltim_2_5_1__window_gate] 10 [Tick 1, Tick 2, Tick 3, Tick 4]
    ltim_2_5_1__window_start = [1, 0, 1, 0]
ltim_2_5_1__second_edge_refires_clocked = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.19.3]
||| A FACT THAT EXPIRES WHILE THE WINDOW IS SHUT CANNOT REOPEN IT: the same
||| `Ping` with a deadline of 2; the window opens at 1 and the rule fires;
||| at 2 the sweep retracts the fact before the re-time; at 3 the window
||| opens on nothing. `[1, 0, 0, 0]`: the composition, seen. The `Ping` is
||| explicit and expires by its TTL; no logical fact's justification lapses
||| here, so [LTIM.2.7.2] is not what this witness exercises.
export
ltim_2_5_1__expired_fact_cannot_reopen :
  iret_19_5__counts_clocked ltim_2_5_1__window_program (\_ => 2) [Just ltim_2_5_1__window_gate] 10 [Tick 1, Tick 2, Tick 3, Tick 4]
    (MkClockedNet (MkTmsNet (iret_19_1__insert ldet_5_8__ping ltim_2_5_1__window_loaded) []) [(1, 2)] 0) = [1, 0, 0, 0]
ltim_2_5_1__expired_fact_cannot_reopen = Refl

-- ---------------------------------------------------------------------
-- Executed: one window, three models
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| THE WINDOW `{2, 3, 6, 7}` of formal/tla/refraction_readings.tla's
||| stream `tick_edge_twice`: open at 2 and 3, shut at 4 and 5, open again
||| at 6 and 7.
public export
ltim_2_5_1__window_2367 : Nat -> Bool
ltim_2_5_1__window_2367 c = (c == 2) || (c == 3) || (c == 6) || (c == 7)

--@spec [LTIM.2.5.1]
public export
ltim_2_5_1__window_2367_gate : Ltim_2_4_1__timed
ltim_2_5_1__window_2367_gate = \c, t, f => ltim_2_5_1__window_2367 c

--@spec [LTIM.2.5.1]
||| The rule under that window loaded, one `Ping` live, no deadline, the
||| clock at 0.
public export
ltim_2_5_1__window_2367_start : Iret_19_3__clocked_net
ltim_2_5_1__window_2367_start =
  MkClockedNet (MkTmsNet (iret_19_1__insert ldet_5_8__ping (rdsc_4a_5__load [(0, \_ => True)] [([(0, ltim_2_5_1__window_2367_gate 0, False)], [])])) []) [] 0

--@derives [LTIM.2.5.1]
--@derives [LDET.5.3]
||| ONE WINDOW, THREE MODELS. Over ticks 1 to 7 the rule fires in the
||| second pump and the sixth, `[0, 1, 0, 0, 0, 1, 0]`: two firings, one per
||| opening. formal/tla/refraction_readings.tla pins the same window to
||| `1@2 1@6` under the clause's reading (stream `tick_edge_twice`, column
||| `own`); formal/tla/edge_once_firing.tla's `probe.refires` returns the
||| same shape, open, shut, open, two firings, with the clock abstracted;
||| and the conformance fixture `LTIM.2.5.1_window_reopens.json` runs it on
||| the runtimes with `dwell` in `[2 s, 4 s)` or at least `6 s`, pumped at
||| 0, 2, 4 and 6 s. Three models and the fixture, one answer.
export
ltim_2_5_1__window_2367_clocked :
  iret_19_5__counts_clocked (lcyc_3_2_1__program_of (\_ => Explicit) (enet (rdsc_4a_5__load [(0, \_ => True)] [([(0, ltim_2_5_1__window_2367_gate 0, False)], [])])))
    (\_ => 0) [Just ltim_2_5_1__window_2367_gate] 10 [Tick 1, Tick 2, Tick 3, Tick 4, Tick 5, Tick 6, Tick 7] ltim_2_5_1__window_2367_start
    = [0, 1, 0, 0, 0, 1, 0]
ltim_2_5_1__window_2367_clocked = Refl

-- ---------------------------------------------------------------------
-- Executed: [LDET.5.8]'s observable on the composed engine, and A1's
-- hypothesis inhabited with the fact live
-- ---------------------------------------------------------------------

--@spec [LDET.5.8]
||| The program `rule late` lowers to, every kind explicit.
public export
ldet_5_8__late_program : Lcyc_3_2_1__program
ldet_5_8__late_program = lcyc_3_2_1__program_of (\_ => Explicit) (enet ldet_5_8__loaded)

--@spec [LDET.5.8]
||| `rule late` loaded, one `Ping` live, no deadline, the clock at 0.
public export
ldet_5_8__late_start : Iret_19_3__clocked_net
ldet_5_8__late_start = MkClockedNet (MkTmsNet (iret_19_1__insert ldet_5_8__ping ldet_5_8__loaded) []) [] 0

--@derives [LDET.5.8]
--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| THE CLAUSE'S OBSERVABLE ON THE COMPOSED ENGINE: assert one `Ping`, pump
||| twice with the gate shut, advance the clock past it, pump twice more.
||| `late` fires exactly once, in the third pump: `[0, 0, 1, 0]`, on the
||| engine with the tables, as on Rete/NetworkTick.idr's.
export
ldet_5_8__late_fires_once_clocked :
  iret_19_5__counts_clocked ldet_5_8__late_program (\_ => 0) [Just ldet_5_8__gate] 10 [Tick 1, Tick 2, Tick 6, Tick 7] ldet_5_8__late_start
    = [0, 0, 1, 0]
ldet_5_8__late_fires_once_clocked = Refl

--@derives [LTIM.2.4.2]
--@derives [LDET.5.8]
||| A1'S HYPOTHESIS, INHABITED WITH THE FACT LIVE: the tick from 0 to 1,
||| the gate shut at both. The one chain's test at 1 answers on the one live
||| pair what its test at 0 did, `False`, by computation.
export
ldet_5_8__shut_stays_shut_unmoved :
  Ltim_2_4_2__unmoved_all [MkAlpha 0 (\_ => True) [ldet_5_8__ping]] [Just ldet_5_8__gate] 1
    [MkChain [MkBeta 0 (ldet_5_8__gate 0) False [[]] []] [] []]
ldet_5_8__shut_stays_shut_unmoved = (\t, et, f, ef => Refl, ())

--@derives [LTIM.2.4.2]
--@derives [LDET.5.8]
||| AND WITH THE GATE OPEN AT BOTH: the tick from 6 to 7, the `Ping`'s match
||| fired. The test at 7 answers `True` as the test at 6 did.
export
ldet_5_8__open_stays_open_unmoved :
  Ltim_2_4_2__unmoved_all [MkAlpha 0 (\_ => True) [ldet_5_8__ping]] [Just ldet_5_8__gate] 7
    [MkChain [MkBeta 0 (ldet_5_8__gate 6) False [[]] []] [MkAct [ldet_5_8__ping] True] []]
ldet_5_8__open_stays_open_unmoved = (\t, et, f, ef => Refl, ())

--@derives [LDET.5.8]
--@derives [IRET.19.5]
||| And the tick to 1 leaves the one chain's activations as they were,
||| none, with the `Ping` live: what A1 says of it, computed.
export
ldet_5_8__shut_tick_moves_nothing :
  map cacts (nchains (enet (ncore (nengine (iret_19_5__tick_clocked ldet_5_8__late_program (\_ => 0) [Just ldet_5_8__gate] 1 ldet_5_8__late_start)))))
    = [[]]
ldet_5_8__shut_tick_moves_nothing = Refl
